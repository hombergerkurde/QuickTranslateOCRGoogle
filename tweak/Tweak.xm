#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <NaturalLanguage/NaturalLanguage.h>

#pragma mark - Prefs

static NSString * const kQTPrefsDomain = @"com.hombergerkurde.quicktranslate";

static NSDictionary *QTGetPrefs(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] persistentDomainForName:kQTPrefsDomain];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}
static BOOL QTGetBool(NSString *key, BOOL def) {
    id v = QTGetPrefs()[key];
    return v ? [v boolValue] : def;
}
static NSString *QTGetString(NSString *key, NSString *def) {
    id v = QTGetPrefs()[key];
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : def;
}

#pragma mark - Window / Top VC

static UIWindow *QTGetKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;

            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }

        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }
        return nil;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow ?: app.windows.firstObject;
#pragma clang diagnostic pop
}

static UIViewController *QTTopViewController(UIViewController *vc) {
    if (!vc) return nil;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return QTTopViewController(((UINavigationController *)vc).topViewController);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        return QTTopViewController(((UITabBarController *)vc).selectedViewController);
    }
    return vc;
}

#pragma mark - UI Helpers

static const NSInteger kQTHUDTag = 880011;

static void QTHideHUD(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIView *hud = [w viewWithTag:kQTHUDTag];
    if (hud) [hud removeFromSuperview];
}

static void QTShowHUD(NSString *text) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    QTHideHUD();

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectZero];
    lbl.tag = kQTHUDTag;
    lbl.text = text ?: @"…";
    lbl.textColor = UIColor.whiteColor;
    lbl.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.numberOfLines = 2;
    lbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    lbl.layer.cornerRadius = 12.0;
    lbl.clipsToBounds = YES;

    CGFloat maxW = MIN(360.0, w.bounds.size.width - 40.0);
    CGRect r = [lbl.text boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX)
                                      options:NSStringDrawingUsesLineFragmentOrigin
                                   attributes:@{NSFontAttributeName: lbl.font}
                                      context:nil];

    CGFloat padX = 16.0, padY = 10.0;
    CGFloat width = ceil(r.size.width) + padX * 2.0;
    CGFloat height = ceil(r.size.height) + padY * 2.0;

    lbl.frame = CGRectMake((w.bounds.size.width - width)/2.0,
                           w.safeAreaInsets.top + 18.0,
                           width, height);
    [w addSubview:lbl];
}

static void QTShowAlert(NSString *title, NSString *message) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopViewController(w.rootViewController);
    if (!top) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:(title ?: @"")
                                                                message:(message ?: @"")
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

static void QTShowResultPopup(NSString *translated) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopViewController(w.rootViewController);
    if (!top) return;

    NSString *msg = translated ?: @"";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Übersetzung"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Kopieren"
                                          style:UIAlertActionStyleDefault
                                        handler:^(__unused UIAlertAction *a){
        UIPasteboard.generalPasteboard.string = msg;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Schließen" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Translator (LibreTranslate)

static NSURLSession *QTSession(void) {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 25.0;
    cfg.timeoutIntervalForResource = 25.0;
    return [NSURLSession sessionWithConfiguration:cfg];
}

static void QTLibreTranslate(NSString *serverURL,
                            NSString *apiKey,
                            NSString *text,
                            NSString *target,
                            void (^completion)(NSString *translated, NSError *err))
{
    NSString *base = (serverURL.length ? serverURL : @"https://translate.cutie.dating");
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];

    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/translate"]];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:100 userInfo:@{NSLocalizedDescriptionKey:@"LibreTranslate URL ungültig"}]);
        return;
    }

    NSString *q = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
    NSString *t = [target stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"de";

    NSMutableString *bodyStr = [NSMutableString stringWithFormat:@"q=%@&source=auto&target=%@&format=text", q, t];
    if (apiKey.length) {
        NSString *k = [apiKey stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
        [bodyStr appendFormat:@"&api_key=%@", k];
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionDataTask *task = [QTSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }

        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        if (http && http.statusCode >= 400) {
            NSString *msg = [NSString stringWithFormat:@"LibreTranslate Fehler (HTTP %ld)", (long)http.statusCode];
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:(int)http.statusCode userInfo:@{NSLocalizedDescriptionKey: msg}]);
            return;
        }

        NSError *parseErr = nil;
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr] : nil;
        if (parseErr || ![obj isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:101 userInfo:@{NSLocalizedDescriptionKey:@"Ungültige Antwort vom Server"}]);
            return;
        }

        NSString *translated = ((NSDictionary *)obj)[@"translatedText"];
        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:102 userInfo:@{NSLocalizedDescriptionKey:@"Keine Übersetzung erhalten"}]);
            return;
        }
        if (completion) completion(translated, nil);
    }];
    [task resume];
}

static void QTTranslateText(NSString *text) {
    if (!QTGetBool(@"enabled", YES)) return;

    NSString *trim = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) {
        QTShowAlert(@"QuickTranslate", @"Kein Text gefunden.");
        return;
    }
    if (trim.length > 2000) trim = [trim substringToIndex:2000];

    NSString *target = QTGetString(@"targetLang", @"de");
    target = [[target lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (target.length == 0) target = @"de";

    NSString *server = QTGetString(@"ltServer", @"https://translate.cutie.dating");
    NSString *apiKey = QTGetString(@"ltApiKey", @"");

    dispatch_async(dispatch_get_main_queue(), ^{ QTShowHUD(@"Übersetze…"); });

    QTLibreTranslate(server, apiKey, trim, target, ^(NSString *translated, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            QTHideHUD();
            if (err) QTShowAlert(@"Übersetzung fehlgeschlagen", err.localizedDescription ?: @"Unbekannter Fehler");
            else QTShowResultPopup(translated);
        });
    });
}

#pragma mark - Language filter (optional)

static BOOL QTShouldShowForText(NSString *text) {
    if (QTGetBool(@"alwaysShowButton", YES)) return YES; // default: show everywhere

    NSString *trim = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length < 3) return NO;

    NSString *target = QTGetString(@"targetLang", @"de");
    target = [[target lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (target.length == 0) target = @"de";

    NLLanguageRecognizer *rec = [NLLanguageRecognizer new];
    [rec processString:trim];
    NLLanguage lang = rec.dominantLanguage;
    if (!lang) return YES;

    NSString *det = [[lang description] lowercaseString];
    if (det.length && [det hasPrefix:target]) return NO;
    return YES;
}

#pragma mark - Text extraction from cell content

static BOOL QTLooksLikeText(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2) return NO;
    if ([t rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound) return NO;
    return YES;
}

static BOOL QTIsProbablyUIJunk(NSString *t) {
    if (!t.length) return YES;
    static NSArray<NSString *> *junk = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        junk = @[
            @"Like", @"Gefällt mir", @"Reply", @"Antworten", @"Repost", @"Retweet", @"Share", @"Teilen",
            @"Follow", @"Folgen", @"Message", @"Nachricht", @"Send", @"Senden", @"Copy", @"Kopieren",
            @"More", @"Mehr", @"Options", @"Optionen"
        ];
    });
    for (NSString *j in junk) {
        if ([t isEqualToString:j]) return YES;
    }
    return NO;
}

static void QTCollectCandidateTexts(UIView *v, NSMutableArray<NSString *> *out, NSInteger depth) {
    if (!v || depth > 18) return;
    if (!v.window || v.hidden || v.alpha < 0.01) return;

    NSString *text = nil;
    if ([v isKindOfClass:[UILabel class]]) text = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UITextView class]]) text = ((UITextView *)v).text;
    else if ([v isKindOfClass:[UITextField class]]) text = ((UITextField *)v).text;

    if (QTLooksLikeText(text)) {
        NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length && !QTIsProbablyUIJunk(t)) [out addObject:t];
    }

    for (UIView *sv in v.subviews) QTCollectCandidateTexts(sv, out, depth + 1);
}

static NSString *QTBestTextFromContainer(UIView *container) {
    NSMutableArray<NSString *> *chunks = [NSMutableArray new];
    QTCollectCandidateTexts(container, chunks, 0);

    // Choose the "best" text: prefer longest chunk, but allow multi-line joined.
    NSString *best = @"";
    for (NSString *s in chunks) {
        if (s.length > best.length) best = s;
    }

    // If longest is short, join a few
    if (best.length < 40 && chunks.count > 1) {
        NSMutableOrderedSet<NSString *> *uniq = [NSMutableOrderedSet orderedSet];
        for (NSString *s in chunks) if (s.length) [uniq addObject:s];
        NSString *joined = [[uniq array] componentsJoinedByString:@"\n"];
        joined = [joined stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (joined.length > best.length) best = joined;
    }

    best = [best stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (best.length > 2000) best = [best substringToIndex:2000];
    return best;
}

#pragma mark - Inline globe button per cell

static char kQTInlineBtnKey;

@interface QTInlineButton : UIButton
@property (nonatomic, weak) UIView *qt_host;
@end
@implementation QTInlineButton @end

static void QTConfigureInlineButton(QTInlineButton *btn) {
    btn.exclusiveTouch = YES;
    btn.clipsToBounds = YES;

    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        cfg.baseForegroundColor = UIColor.systemBlueColor;
        cfg.baseBackgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.80];
        cfg.image = [UIImage systemImageNamed:@"globe"];
        btn.configuration = cfg;
    } else if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *scfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:@"globe" withConfiguration:scfg];
        [btn setImage:img forState:UIControlStateNormal];
        btn.tintColor = UIColor.systemBlueColor;
        btn.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.80];
        btn.layer.cornerRadius = 14.0;
    } else {
        [btn setTitle:@"🌐" forState:UIControlStateNormal];
        btn.layer.cornerRadius = 14.0;
        btn.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.8];
    }
}

static UIView *QTFindHostCell(UIView *v) {
    UIView *cur = v;
    while (cur) {
        if ([cur isKindOfClass:[UITableViewCell class]] || [cur isKindOfClass:[UICollectionViewCell class]]) return cur;
        cur = cur.superview;
    }
    return nil;
}

static void QTInlineTapped(QTInlineButton *btn) {
    UIView *cell = QTFindHostCell(btn);
    UIView *container = nil;

    if ([cell isKindOfClass:[UITableViewCell class]]) container = ((UITableViewCell *)cell).contentView;
    else if ([cell isKindOfClass:[UICollectionViewCell class]]) container = ((UICollectionViewCell *)cell).contentView;

    if (!container) return;

    NSString *text = QTBestTextFromContainer(container);
    if (!QTShouldShowForText(text)) {
        // still translate on tap even if hidden by filter
    }
    QTTranslateText(text);
}

@interface UIButton (QTInlineTap)
- (void)qt_inlineTap;
@end
@implementation UIButton (QTInlineTap)
- (void)qt_inlineTap { QTInlineTapped((QTInlineButton *)self); }
@end

static BOOL QTCellLooksLikeContent(UIView *contentView) {
    if (!contentView || !contentView.window) return NO;
    if (contentView.hidden || contentView.alpha < 0.01) return NO;

    // avoid tiny cells / headers
    if (contentView.bounds.size.height < 60) return NO;

    NSString *text = QTBestTextFromContainer(contentView);
    if (text.length < 8) return NO;

    // optionally hide button if language equals target
    if (!QTShouldShowForText(text)) return NO;

    return YES;
}

static void QTEnsureInlineButton(UIView *contentView) {
    if (!QTGetBool(@"enabled", YES)) return;
    if (!QTCellLooksLikeContent(contentView)) {
        QTInlineButton *existing = objc_getAssociatedObject(contentView, &kQTInlineBtnKey);
        if (existing) [existing removeFromSuperview];
        objc_setAssociatedObject(contentView, &kQTInlineBtnKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    QTInlineButton *btn = objc_getAssociatedObject(contentView, &kQTInlineBtnKey);
    if (!btn) {
        btn = [QTInlineButton buttonWithType:UIButtonTypeSystem];
        btn.qt_host = contentView;
        QTConfigureInlineButton(btn);
        [btn addTarget:btn action:@selector(qt_inlineTap) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(contentView, &kQTInlineBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [contentView addSubview:btn];
    }

    // Translomatic-like: bottom-left in cell
    CGFloat size = 28.0;
    CGFloat padX = 10.0;
    CGFloat padBottom = 8.0;

    CGFloat x = padX;
    CGFloat y = MAX(8.0, contentView.bounds.size.height - size - padBottom);

    btn.frame = CGRectMake(x, y, size, size);
    [contentView bringSubviewToFront:btn];
}

%hook UITableViewCell
- (void)layoutSubviews {
    %orig;
    // Works across most apps that use UITableView
    QTEnsureInlineButton(self.contentView);
}
%end

%hook UICollectionViewCell
- (void)layoutSubviews {
    %orig;
    // Works across most apps that use UICollectionView
    QTEnsureInlineButton(self.contentView);
}
%end

#pragma mark - Context menu (Select text -> QuickTranslate)

static SEL kQTActionSEL;

static NSString *QTGrabSelectedTextByCopy(void) {
    UIPasteboard *pb = UIPasteboard.generalPasteboard;
    NSArray *oldItems = pb.items;

    BOOL did = [UIApplication.sharedApplication sendAction:@selector(copy:) to:nil from:nil forEvent:nil];
    if (!did) { pb.items = oldItems; return nil; }

    NSString *copied = pb.string;
    pb.items = oldItems;

    NSString *trim = [copied ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trim.length ? trim : nil;
}

@interface UIResponder (QTMenu)
- (void)qt_quickTranslate:(id)sender;
@end

@implementation UIResponder (QTMenu)
- (void)qt_quickTranslate:(id)sender {
    (void)sender;
    if (!QTGetBool(@"enabled", YES)) return;
    NSString *selText = QTGrabSelectedTextByCopy();
    if (!selText) {
        QTShowAlert(@"QuickTranslate", @"Bitte Text markieren und dann QuickTranslate auswählen.");
        return;
    }
    QTTranslateText(selText);
}
@end

%hook UIResponder
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    BOOL orig = %orig;
    if (action == kQTActionSEL) {
        if (!QTGetBool(@"enabled", YES)) return NO;
        BOOL canCopy = %orig(@selector(copy:), sender);
        return canCopy;
    }
    return orig;
}
%end

static void QTInstallMenuItem(void) {
    kQTActionSEL = @selector(qt_quickTranslate:);
    UIMenuItem *item = [[UIMenuItem alloc] initWithTitle:@"QuickTranslate" action:kQTActionSEL];
    UIMenuController *mc = UIMenuController.sharedMenuController;
    NSArray *items = mc.menuItems ?: @[];
    for (UIMenuItem *it in items) if (it.action == kQTActionSEL) return;
    mc.menuItems = [items arrayByAddingObject:item];
}

%ctor {
    @autoreleasepool {
        QTInstallMenuItem();
    }
}
