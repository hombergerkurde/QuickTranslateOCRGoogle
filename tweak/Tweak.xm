#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const kPrefsDomain = @"com.hombergerkurde.quicktranslate";

// ---- Target apps (hard-coded) ----
static BOOL QTIsTargetApp(void) {
    static dispatch_once_t onceToken;
    static NSSet<NSString *> *targets;
    dispatch_once(&onceToken, ^{
        targets = [NSSet setWithArray:@[
            @"ph.telegra.Telegraph",            // Telegram
            @"com.atebits.Tweetie2",            // X/Twitter
            @"net.whatsapp.WhatsApp",           // WhatsApp
            @"com.hammerandchisel.discord",     // Discord
            @"com.facebook.Facebook",           // Facebook
            @"com.burbn.instagram",             // Instagram
            @"org.coolstar.SileoStore"          // Sileo
        ]];
    });

    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [targets containsObject:bid];
}

// ---- Prefs ----
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

// ---- Window / VC ----
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

// ---- UI helpers ----
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
                           width,
                           height);

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

    [ac addAction:[UIAlertAction actionWithTitle:@"Kopieren" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = msg;
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"Schließen" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

// ---- Translation (LibreTranslate) ----
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

// ---- Text extraction from a cell (NO OCR) ----
static BOOL QTLooksLikeRealText(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2) return NO;

    NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    if ([t rangeOfCharacterFromSet:letters].location == NSNotFound) return NO;

    if ([t.lowercaseString isEqualToString:@"ok"]) return NO;
    return YES;
}

static void QTCollectTextAndBounds(UIView *container, UIView *v, NSMutableArray<NSString *> *out, CGRect *boundsUnion, NSInteger depth) {
    if (!v || depth > 14) return;

    if (!v.window || v.hidden || v.alpha < 0.01) {
        return;
    }

    NSString *text = nil;
    if ([v isKindOfClass:[UILabel class]]) {
        text = ((UILabel *)v).text;
    } else if ([v isKindOfClass:[UITextView class]]) {
        text = ((UITextView *)v).text;
    } else if ([v isKindOfClass:[UITextField class]]) {
        text = ((UITextField *)v).text;
    }

    if (QTLooksLikeRealText(text)) {
        NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [out addObject:t];

        if (container) {
            CGRect r = [v convertRect:v.bounds toView:container];
            if (!CGRectIsEmpty(r)) {
                if (CGRectIsEmpty(*boundsUnion)) *boundsUnion = r;
                else *boundsUnion = CGRectUnion(*boundsUnion, r);
            }
        }
    }

    for (UIView *sv in v.subviews) {
        QTCollectTextAndBounds(container, sv, out, boundsUnion, depth + 1);
    }
}

static NSString *QTExtractTextFromContainer(UIView *container, CGRect *textBoundsOut) {
    NSMutableArray<NSString *> *chunks = [NSMutableArray new];
    CGRect u = CGRectZero;
    QTCollectTextAndBounds(container, container, chunks, &u, 0);

    if (textBoundsOut) *textBoundsOut = u;

    NSMutableOrderedSet<NSString *> *uniq = [NSMutableOrderedSet orderedSet];
    for (NSString *s in chunks) {
        if (s.length) [uniq addObject:s];
    }

    NSString *joined = [[uniq array] componentsJoinedByString:@"\n"];
    joined = [joined stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (joined.length > 1400) joined = [joined substringToIndex:1400];
    return joined;
}

// ---- Inline translate button ----
static char kQTInlineBtnKey;

@interface QTInlineButton : UIButton
@end
@implementation QTInlineButton
@end

static UIImage *QTButtonImage(void) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:@"globe" withConfiguration:cfg];
        if (img) return img;
    }
    return nil;
}

static void QTTranslateText(NSString *text) {
    if (!QTGetBool(@"enabled", YES)) return;

    NSString *trim = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) {
        QTShowAlert(@"QuickTranslate", @"Kein Text gefunden.");
        return;
    }

    NSString *target = QTGetString(@"targetLang", @"de");
    target = [target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (target.length == 0) target = @"de";

    NSString *server = QTGetString(@"ltServer", @"https://translate.cutie.dating");
    NSString *apiKey = QTGetString(@"ltApiKey", @"");

    QTShowHUD(@"Übersetze…");
    QTTranslate_Libre(server, apiKey, trim, target, ^(NSString *translated, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            QTHideHUD();
            if (err) QTShowAlert(@"Übersetzung fehlgeschlagen", err.localizedDescription ?: @"Unbekannter Fehler");
            else QTShowResultPopup(translated);
        });
    });
}

static UIView *QTFindHostCell(UIView *v) {
    UIView *cur = v;
    while (cur) {
        if ([cur isKindOfClass:[UITableViewCell class]] || [cur isKindOfClass:[UICollectionViewCell class]]) return cur;
        cur = cur.superview;
    }
    return nil;
}

static void QTInlineButtonTapped(QTInlineButton *btn) {
    UIView *cell = QTFindHostCell(btn);
    if (!cell) return;

    UIView *container = nil;
    if ([cell isKindOfClass:[UITableViewCell class]]) {
        container = ((UITableViewCell *)cell).contentView;
    } else if ([cell isKindOfClass:[UICollectionViewCell class]]) {
        container = ((UICollectionViewCell *)cell).contentView;
    }
    if (!container) return;

    CGRect tb = CGRectZero;
    NSString *text = QTExtractTextFromContainer(container, &tb);
    QTTranslateText(text);
}

@interface UIButton (QTInline)
- (void)qt_inlineTap;
@end
@implementation UIButton (QTInline)
- (void)qt_inlineTap {
    QTInlineButtonTapped((QTInlineButton *)self);
}
@end

static void QTEnsureInlineButtonForContainer(UIView *container) {
    if (!container) return;
    if (!QTIsTargetApp()) return;
    if (!QTGetBool(@"enabled", YES)) return;

    QTInlineButton *btn = objc_getAssociatedObject(container, &kQTInlineBtnKey);
    if (!btn) {
        btn = [QTInlineButton buttonWithType:UIButtonTypeSystem];
        btn.tintColor = UIColor.systemBlueColor;
        btn.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.70];
        btn.layer.cornerRadius = 12.0;
        btn.clipsToBounds = YES;
        btn.contentEdgeInsets = UIEdgeInsetsMake(4, 4, 4, 4);
        btn.exclusiveTouch = YES;

        UIImage *img = QTButtonImage();
        if (img) [btn setImage:img forState:UIControlStateNormal];
        else [btn setTitle:@"🌐" forState:UIControlStateNormal];

        [btn addTarget:btn action:@selector(qt_inlineTap) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(container, &kQTInlineBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [container addSubview:btn];
    }

    // Position: "under" the main text block.
    CGRect tb = CGRectZero;
    (void)QTExtractTextFromContainer(container, &tb);

    CGFloat size = 24.0;
    CGFloat pad = 6.0;

    CGRect frame;
    if (!CGRectIsEmpty(tb)) {
        CGFloat x = MAX(pad, MIN(tb.origin.x, container.bounds.size.width - size - pad));
        CGFloat y = MIN(container.bounds.size.height - size - pad, CGRectGetMaxY(tb) + pad);
        frame = CGRectMake(x, y, size, size);
    } else {
        frame = CGRectMake(pad, MAX(pad, container.bounds.size.height - size - pad), size, size);
    }

    btn.frame = frame;
    [container bringSubviewToFront:btn];
}

// ---- Hooks: place button on each cell ----
%hook UITableViewCell
- (void)layoutSubviews {
    %orig;
    if (!QTIsTargetApp()) return;
    QTEnsureInlineButtonForContainer(self.contentView);
}
%end

%hook UICollectionViewCell
- (void)layoutSubviews {
    %orig;
    if (!QTIsTargetApp()) return;
    QTEnsureInlineButtonForContainer(self.contentView);
}
%end

%ctor {
    // No floating button; per-cell only.
}
