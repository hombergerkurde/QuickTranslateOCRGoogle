#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>

static NSString * const kPrefsDomain = @"com.hombergerkurde.quicktranslate";

#pragma mark - Prefs

static NSDictionary *QTGetPrefs(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] persistentDomainForName:kPrefsDomain];
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

#pragma mark - Bundle helpers

static NSString *QTBundleID(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"";
}
static BOOL QTIsTelegram(void) { return [QTBundleID() isEqualToString:@"ph.telegra.Telegraph"]; }
static BOOL QTIsX(void)        { return [QTBundleID() isEqualToString:@"com.atebits.Tweetie2"]; }
static BOOL QTIsSileo(void)    { return [QTBundleID() isEqualToString:@"org.coolstar.SileoStore"]; }

#pragma mark - Window / VC

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

#pragma mark - HUD / UI

static const NSInteger kQTHUDTag = 998877;

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

#pragma mark - LibreTranslate

static NSURLSession *QTSession(void) {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 35.0;
    cfg.timeoutIntervalForResource = 35.0;
    return [NSURLSession sessionWithConfiguration:cfg];
}

static void QTTranslate_Libre(NSString *serverURL, NSString *apiKey, NSString *text, NSString *target,
                             void (^completion)(NSString *translated, NSError *err)) {

    NSString *base = (serverURL.length ? serverURL : @"https://translate.cutie.dating");
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];

    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/translate"]];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:101 userInfo:@{NSLocalizedDescriptionKey:@"LibreTranslate URL ungültig"}]);
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
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:102 userInfo:@{NSLocalizedDescriptionKey:@"LibreTranslate Antwort ungültig"}]);
            return;
        }

        NSString *translated = ((NSDictionary *)obj)[@"translatedText"];
        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:103 userInfo:@{NSLocalizedDescriptionKey:@"LibreTranslate: keine Übersetzung"}]);
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
    target = [target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (target.length == 0) target = @"de";

    NSString *server = QTGetString(@"ltServer", @"https://translate.cutie.dating");
    NSString *apiKey  = QTGetString(@"ltApiKey", @"");

    dispatch_async(dispatch_get_main_queue(), ^{ QTShowHUD(@"Übersetze…"); });

    QTTranslate_Libre(server, apiKey, trim, target, ^(NSString *translated, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            QTHideHUD();
            if (err) QTShowAlert(@"Übersetzung fehlgeschlagen", err.localizedDescription ?: @"Unbekannter Fehler");
            else QTShowResultPopup(translated);
        });
    });
}

#pragma mark - Selected text (Context Menu like Translomatic)

static NSString *QTGrabSelectedTextByCopy(void) {
    UIPasteboard *pb = UIPasteboard.generalPasteboard;

    // Backup clipboard
    NSArray *oldItems = pb.items;

    BOOL did = [UIApplication.sharedApplication sendAction:@selector(copy:) to:nil from:nil forEvent:nil];
    if (!did) {
        pb.items = oldItems;
        return nil;
    }

    NSString *copied = pb.string;

    // Restore clipboard
    pb.items = oldItems;

    NSString *trim = [copied ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trim.length ? trim : nil;
}

static SEL kQTActionSEL;

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

    for (UIMenuItem *it in items) {
        if (it.action == kQTActionSEL) return;
    }
    mc.menuItems = [items arrayByAddingObject:item];
}

#pragma mark - Helpers: extract visible text from a cell/view (Telegram/X long-press)

static BOOL QTLooksLikeText(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2) return NO;
    if ([t rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound) return NO;
    return YES;
}

static void QTCollectTextFromView(UIView *v, NSMutableArray<NSString *> *out, NSInteger depth) {
    if (!v || depth > 14) return;
    if (!v.window || v.hidden || v.alpha < 0.01) return;

    NSString *text = nil;
    if ([v isKindOfClass:[UILabel class]]) text = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UITextView class]]) text = ((UITextView *)v).text;
    else if ([v isKindOfClass:[UITextField class]]) text = ((UITextField *)v).text;

    if (QTLooksLikeText(text)) {
        NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [out addObject:t];
    }

    for (UIView *sv in v.subviews) QTCollectTextFromView(sv, out, depth + 1);
}

static NSString *QTExtractTextFromContainer(UIView *container) {
    NSMutableArray<NSString *> *chunks = [NSMutableArray new];
    QTCollectTextFromView(container, chunks, 0);

    NSMutableOrderedSet<NSString *> *uniq = [NSMutableOrderedSet orderedSet];
    for (NSString *s in chunks) if (s.length) [uniq addObject:s];

    NSString *joined = [[uniq array] componentsJoinedByString:@"\n"];
    joined = [joined stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (joined.length > 2000) joined = [joined substringToIndex:2000];
    return joined;
}

#pragma mark - Telegram/X: show ONE button near long-pressed message/post

static const NSInteger kQTFlyBtnTag = 445566;

static void QTRemoveFlyButton(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIView *b = [w viewWithTag:kQTFlyBtnTag];
    if (b) [b removeFromSuperview];
}

@interface QTFlyButton : UIButton
@property (nonatomic, copy) NSString *qt_text;
@end
@implementation QTFlyButton
@end

static void QTFlyTapped(QTFlyButton *btn) {
    NSString *t = btn.qt_text ?: @"";
    QTRemoveFlyButton();
    QTTranslateText(t);
}

static void QTShowFlyButtonForView(UIView *anchor, NSString *text) {
    UIWindow *w = QTGetKeyWindow();
    if (!w || !anchor) return;

    QTRemoveFlyButton();

    CGRect r = [anchor convertRect:anchor.bounds toView:w];
    if (CGRectIsEmpty(r)) return;

    QTFlyButton *btn = [QTFlyButton buttonWithType:UIButtonTypeSystem];
    btn.tag = kQTFlyBtnTag;
    btn.qt_text = text ?: @"";
    btn.tintColor = UIColor.systemBlueColor;
    btn.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.90];
    btn.layer.cornerRadius = 14.0;
    btn.clipsToBounds = YES;
    btn.exclusiveTouch = YES;

    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:@"globe" withConfiguration:cfg];
        if (img) [btn setImage:img forState:UIControlStateNormal];
        else [btn setTitle:@"🌐" forState:UIControlStateNormal];
    } else {
        [btn setTitle:@"🌐" forState:UIControlStateNormal];
    }

    [btn addTarget:btn action:@selector(qt_flyTap) forControlEvents:UIControlEventTouchUpInside];

    // position: bottom-left under the bubble/post area (like Translomatic vibe)
    CGFloat size = 28.0;
    CGFloat x = MAX(10.0, MIN(CGRectGetMinX(r), w.bounds.size.width - size - 10.0));
    CGFloat y = MIN(w.bounds.size.height - size - 10.0, CGRectGetMaxY(r) + 6.0);
    btn.frame = CGRectMake(x, y, size, size);

    [w addSubview:btn];
    [w bringSubviewToFront:btn];
}

@interface UIButton (QTFly)
- (void)qt_flyTap;
@end
@implementation UIButton (QTFly)
- (void)qt_flyTap { QTFlyTapped((QTFlyButton *)self); }
@end

static char kQTLongPressKey;

static void QTAttachLongPressIfNeeded(UIView *v) {
    if (!v) return;
    if (!(QTIsTelegram() || QTIsX())) return;
    if (!QTGetBool(@"enabled", YES)) return;

    if (objc_getAssociatedObject(v, &kQTLongPressKey)) return;

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:v action:@selector(qt_lp:)];
    lp.minimumPressDuration = 0.35;
    lp.cancelsTouchesInView = NO;
    [v addGestureRecognizer:lp];

    objc_setAssociatedObject(v, &kQTLongPressKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface UIView (QTLP)
- (void)qt_lp:(UILongPressGestureRecognizer *)gr;
@end

@implementation UIView (QTLP)
- (void)qt_lp:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;

    // find a cell-ish container up the chain
    UIView *cur = self;
    UIView *cell = nil;
    while (cur) {
        if ([cur isKindOfClass:[UITableViewCell class]] || [cur isKindOfClass:[UICollectionViewCell class]]) { cell = cur; break; }
        cur = cur.superview;
    }
    if (!cell) return;

    UIView *content = nil;
    if ([cell isKindOfClass:[UITableViewCell class]]) content = ((UITableViewCell *)cell).contentView;
    else if ([cell isKindOfClass:[UICollectionViewCell class]]) content = ((UICollectionViewCell *)cell).contentView;
    if (!content) return;

    NSString *t = QTExtractTextFromContainer(content);
    if (t.length == 0) return;

    QTShowFlyButtonForView(content, t);
}
@end

%hook UITableViewCell
- (void)layoutSubviews {
    %orig;
    if (QTIsTelegram() || QTIsX()) {
        QTAttachLongPressIfNeeded(self.contentView);
    }
}
%end

%hook UICollectionViewCell
- (void)layoutSubviews {
    %orig;
    if (QTIsTelegram() || QTIsX()) {
        QTAttachLongPressIfNeeded(self.contentView);
    }
}
%end

#pragma mark - Sileo: navbar button to translate depictions (WKWebView innerText)

static WKWebView *QTFindWKWebView(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[WKWebView class]]) return (WKWebView *)root;
    for (UIView *v in root.subviews) {
        WKWebView *w = QTFindWKWebView(v);
        if (w) return w;
    }
    return nil;
}

static void QTSileoTranslateVisibleDepiction(UIViewController *vc) {
    if (!vc) return;

    WKWebView *wv = QTFindWKWebView(vc.view);
    if (!wv) {
        QTShowAlert(@"QuickTranslate", @"Keine Depiction-WebView gefunden.");
        return;
    }

    QTShowHUD(@"Lese Depiction…");
    [wv evaluateJavaScript:@"document.body && document.body.innerText ? document.body.innerText : ''" completionHandler:^(id result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            QTHideHUD();
            if (error) {
                QTShowAlert(@"QuickTranslate", @"Konnte Depiction-Text nicht lesen.");
                return;
            }
            NSString *text = [result isKindOfClass:[NSString class]] ? (NSString *)result : @"";
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text.length == 0) {
                QTShowAlert(@"QuickTranslate", @"Kein Text gefunden.");
                return;
            }
            QTTranslateText(text);
        });
    }];
}

static void QTInstallSileoNavButton(UIViewController *vc) {
    if (!QTIsSileo()) return;
    if (!QTGetBool(@"enabled", YES)) return;
    if (!vc || !vc.navigationItem) return;

    // only install when a WKWebView is on screen (depiction/pages)
    WKWebView *wv = QTFindWKWebView(vc.view);
    if (!wv) return;

    // avoid duplicates
    UIBarButtonItem *existing = nil;
    for (UIBarButtonItem *it in vc.navigationItem.rightBarButtonItems ?: @[]) {
        if ([it.accessibilityIdentifier isEqualToString:@"qt_nav"]) { existing = it; break; }
    }
    if (existing) return;

    UIBarButtonItem *btn = nil;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:@"globe" withConfiguration:cfg];
        btn = [[UIBarButtonItem alloc] initWithImage:img style:UIBarButtonItemStylePlain target:vc action:@selector(qt_sileoTap)];
    } else {
        btn = [[UIBarButtonItem alloc] initWithTitle:@"🌐" style:UIBarButtonItemStylePlain target:vc action:@selector(qt_sileoTap)];
    }

    btn.accessibilityIdentifier = @"qt_nav";

    NSMutableArray *items = [NSMutableArray arrayWithArray:(vc.navigationItem.rightBarButtonItems ?: @[])];
    [items addObject:btn];
    vc.navigationItem.rightBarButtonItems = items;
}

@interface UIViewController (QTSileo)
- (void)qt_sileoTap;
@end

@implementation UIViewController (QTSileo)
- (void)qt_sileoTap {
    QTSileoTranslateVisibleDepiction(self);
}
@end

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (QTIsSileo()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            QTInstallSileoNavButton(self);
        });
    }
}
%end

#pragma mark - ctor

%ctor {
    @autoreleasepool {
        QTInstallMenuItem();
    }
}
