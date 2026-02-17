#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <objc/runtime.h>

static NSString * const kPrefsDomain = @"1.com.quicktranslate.prefsfixed";
static const NSInteger kQTButtonTag = 987654;

#pragma mark - Prefs helpers

static id QTPreferencesValue(NSString *key) {
    CFPropertyListRef pl = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                     (__bridge CFStringRef)kPrefsDomain);
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

    // AltList: häufig NSArray<bundleID>
    if ([wl isKindOfClass:[NSArray class]]) {
        return [(NSArray *)wl containsObject:bid];
    }
    // oder NSDictionary<bundleID, bool>
    if ([wl isKindOfClass:[NSDictionary class]]) {
        id x = ((NSDictionary *)wl)[bid];
        return x ? [x boolValue] : NO;
    }
    return NO;
}

#pragma mark - Window / Top VC (iOS 15+ safe)

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

static void QTShowAlert(NSString *title, NSString *message) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopViewController(w.rootViewController);
    if (!top) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title ?: @""
                                                                message:message ?: @""
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

static void QTShowResultPopup(NSString *original, NSString *translated) {
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
        UIPasteboard.generalPasteboard.string = msg ?: @"";
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Schließen"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];

    [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Screenshot

static UIImage *QTScreenSnapshot(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return nil;

    CGSize size = w.bounds.size;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        [w drawViewHierarchyInRect:(CGRect){CGPointZero, size} afterScreenUpdates:NO];
    }];
    return img;
}

#pragma mark - Vision OCR

static void QTRunOCR(UIImage *image, void (^completion)(NSString *text, NSError *err)) {
    if (!image || !image.CGImage) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Kein Bild für OCR"}]);
        return;
    }

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }

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

static void QTLibreTranslate(NS
