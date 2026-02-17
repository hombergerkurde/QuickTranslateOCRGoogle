#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>

static NSString * const kPrefsDomain = @"1.com.quicktranslate.prefsfixed";
static const NSInteger kQTButtonTag = 987654;
static const NSInteger kQTHUDTag = 998877;

#pragma mark - Prefs helpers

static id QTPreferencesValue(NSString *key) {
    CFPropertyListRef pl = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kPrefsDomain);
    return pl ? (__bridge_transfer id)pl : nil;
}

static BOOL QTBool(NSString *key, BOOL def) {
    id v = QTPreferencesValue(key);
    return v ? [v boolValue] : def;
}

static NSString *QTString(NSString *key, NSString *def) {
    id v = QTPreferencesValue(key);
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : def;
}

static BOOL QTIsEnabledForCurrentApp(void) {
    if (!QTBool(@"enabled", YES)) return NO;
    BOOL useWL = QTBool(@"useWhitelist", NO);
    if (!useWL) return YES;

    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    id wl = QTPreferencesValue(@"whitelist");

    if ([wl isKindOfClass:[NSArray class]]) {
        return [(NSArray *)wl containsObject:bid];
    }
    if ([wl isKindOfClass:[NSDictionary class]]) {
        id x = ((NSDictionary *)wl)[bid];
        return x ? [x boolValue] : NO;
    }
    return NO;
}

#pragma mark - Window / Top VC

static UIWindow *QTGetKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
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
    if ([vc isKindOfClass:[UINavigationController class]]) return QTTopViewController(((UINavigationController *)vc).topViewController);
    if ([vc isKindOfClass:[UITabBarController class]]) return QTTopViewController(((UITabBarController *)vc).selectedViewController);
    return vc;
}

static void QTShowAlert(NSString *title, NSString *message) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopViewController(w.rootViewController);
    if (!top) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:(title ?: @"") message:(message ?: @"") preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

static void QTShowResultPopup(NSString *translated) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopViewController(w.rootViewController);
    if (!top) return;

    NSString *msg = translated ?: @"";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Übersetzung" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Kopieren" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ UIPasteboard.generalPasteboard.string = msg; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Schließen" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - HUD

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

    CGFloat maxW = MIN(320.0, w.bounds.size.width - 40.0);
    CGSize maxSize = CGSizeMake(maxW, CGFLOAT_MAX);
    CGRect r = [lbl.text boundingRectWithSize:maxSize options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: lbl.font} context:nil];

    CGFloat padX = 16.0, padY = 10.0;
    CGFloat width = ceil(r.size.width) + padX * 2.0;
    CGFloat height = ceil(r.size.height) + padY * 2.0;

    lbl.frame = CGRectMake((w.bounds.size.width - width) / 2.0, w.safeAreaInsets.top + 18.0, width, height);
    [w addSubview:lbl];
}

#pragma mark - Screenshot

static UIImage *QTScreenSnapshot(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return nil;
    CGSize size = w.bounds.size;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        [w drawViewHierarchyInRect:(CGRect){CGPointZero, size} afterScreenUpdates:NO];
    }];
    return img;
}

#pragma mark - OCR

static void QTRunOCR(UIImage *image, void (^completion)(NSString *text, NSError *err)) {
    if (!image || !image.CGImage) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Kein Bild für OCR"}]);
        return;
    }

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }

        NSMutableArray<NSString *> *lines = [NSMutableArray new];
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *best = [[obs topCandidates:1] firstObject];
            if (best.string.length > 0) [lines addObject:best.string];
        }
        NSString *joined = [lines componentsJoinedByString:@"\n"];
        if (completion) completion(joined, nil);
    }];

    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = YES;

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        [handler performRequests:@[req] error:&err];
        if (err && completion) completion(nil, err);
    });
}

#pragma mark - LibreTranslate

static void QTLibreTranslate(NSString *serverURL, NSString *text, NSString *targetLang, void (^completion)(NSString *translated, NSError *err)) {
    if (text.length == 0) { if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Kein Text erkannt"}]); return; }

    NSString *base = (serverURL.length ? serverURL : @"https://libretranslate.com");
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];

    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/translate"]];
    if (!url) { if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Ungültige LibreTranslate URL"}]); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *payload = @{@"q": (text ?: @""), @"source": @"auto", @"target": (targetLang.length ? targetLang : @"de"), @"format": @"text"};
    NSError *jsonErr = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonErr];
    if (!body) { if (completion) completion(nil, jsonErr ?: [NSError errorWithDomain:@"QT" code:4 userInfo:@{NSLocalizedDescriptionKey:@"JSON Fehler"}]); return; }
    req.HTTPBody = body;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15.0;
    cfg.timeoutIntervalForResource = 15.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:5 userInfo:@{NSLocalizedDescriptionKey:@"Keine Antwort"}]); return; }

        NSError *parseErr = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (!obj || parseErr) { if (completion) completion(nil, parseErr ?: [NSError errorWithDomain:@"QT" code:6 userInfo:@{NSLocalizedDescriptionKey:@"Antwort konnte nicht gelesen werden"}]); return; }

        NSString *translated = nil;
        if ([obj isKindOfClass:[NSDictionary class]]) {
            translated = ((NSDictionary *)obj)[@"translatedText"];
            if (!translated) translated = ((NSDictionary *)obj)[@"translation"];
        }
        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) { if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:7 userInfo:@{NSLocalizedDescriptionKey:@"Keine Übersetzung erhalten"}]); return; }

        if (completion) completion(translated, nil);
    }] resume];
}

#pragma mark - Auto translate whole screen

static BOOL gQTBusy = NO;

static void QTTranslateVisibleScreen(void) {
    if (gQTBusy) return;
    if (!QTIsEnabledForCurrentApp()) return;
    gQTBusy = YES;

    NSString *server = QTString(@"ltServer", @"https://libretranslate.com");
    NSString *target = QTString(@"targetLang", @"de");

    dispatch_async(dispatch_get_main_queue(), ^{ QTShowHUD(@"Erkenne Text…"); });

    UIImage *snap = QTScreenSnapshot();
    if (!snap) {
        dispatch_async(dispatch_get_main_queue(), ^{ QTHideHUD(); QTShowAlert(@"QuickTranslate", @"Screenshot fehlgeschlagen."); });
        gQTBusy = NO;
        return;
    }

    QTRunOCR(snap, ^(NSString *text, NSError *err) {
        if (err) {
            dispatch_async(dispatch_get_main_queue(), ^{ QTHideHUD(); QTShowAlert(@"OCR Fehler", err.localizedDescription ?: @"Unbekannter Fehler"); });
            gQTBusy = NO;
            return;
        }

        NSString *trim = [(text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trim.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ QTHideHUD(); QTShowAlert(@"QuickTranslate", @"Kein Text erkannt."); });
            gQTBusy = NO;
            return;
        }

        const NSUInteger kMaxChars = 1400;
        if (trim.length > kMaxChars) trim = [trim substringToIndex:kMaxChars];

        dispatch_async(dispatch_get_main_queue(), ^{ QTShowHUD(@"Übersetze…"); });

        QTLibreTranslate(server, trim, target, ^(NSString *translated, NSError *tErr) {
            if (tErr) {
                dispatch_async(dispatch_get_main_queue(), ^{ QTHideHUD(); QTShowAlert(@"Übersetzung fehlgeschlagen", tErr.localizedDescription ?: @"Unbekannter Fehler"); });
                gQTBusy = NO;
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{ QTHideHUD(); QTShowResultPopup(translated); });
            gQTBusy = NO;
        });
    });
}

#pragma mark - Floating button

static void QTInstallFloatingButton(void);

@interface UIView (QTDrag)
- (void)qt_pan:(UIPanGestureRecognizer *)gr;
@end

@implementation UIView (QTDrag)
- (void)qt_pan:(UIPanGestureRecognizer *)gr {
    UIView *v = gr.view;
    if (!v) return;
    CGPoint tr = [gr translationInView:v.superview];
    v.center = CGPointMake(v.center.x + tr.x, v.center.y + tr.y);
    [gr setTranslation:CGPointZero inView:v.superview];
}
@end

@interface UIWindow (QTFallbackTap)
- (void)qt_fallbackTap;
@end

@implementation UIWindow (QTFallbackTap)
- (void)qt_fallbackTap { QTTranslateVisibleScreen(); }
@end

static void QTInstallFloatingButton(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    if (!QTIsEnabledForCurrentApp()) {
        UIView *old = [w viewWithTag:kQTButtonTag];
        if (old) [old removeFromSuperview];
        return;
    }

    if ([w viewWithTag:kQTButtonTag]) return;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = kQTButtonTag;
    [btn setTitle:@"🌐" forState:UIControlStateNormal];
    btn.frame = CGRectMake(20, 200, 48, 48);
    btn.layer.cornerRadius = 24.0;
    btn.clipsToBounds = YES;
    btn.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.92];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(qt_pan:)];
    [btn addGestureRecognizer:pan];

    if (@available(iOS 14.0, *)) {
        [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) { QTTranslateVisibleScreen(); }] forControlEvents:UIControlEventTouchUpInside];
    } else {
        [btn addTarget:w action:@selector(qt_fallbackTap) forControlEvents:UIControlEventTouchUpInside];
    }

    [w addSubview:btn];
}

#pragma mark - Hooks

%hook UIApplication
- (void)applicationDidBecomeActive:(id)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ QTInstallFloatingButton(); });
}
%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{ QTInstallFloatingButton(); });
}
