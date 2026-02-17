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

static CGFloat QTFloat(NSString *key, CGFloat def) {
    id v = QTPreferencesValue(key);
    if ([v respondsToSelector:@selector(doubleValue)]) return (CGFloat)[v doubleValue];
    return def;
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
        // Prefer active foreground scene
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;

            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }

        // Fallback: any window scene
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

#pragma mark - Pick Overlay

@interface QTPickOverlayView : UIView
@property (nonatomic, copy) void (^onPick)(CGPoint point);
@end

@implementation QTPickOverlayView {
    UILabel *_label;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.15];

        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.text = @"Tippe auf den Text, den du übersetzen willst";
        _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 2;
        _label.textColor = UIColor.whiteColor;
        _label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        _label.layer.cornerRadius = 10.0;
        _label.clipsToBounds = YES;

        [self addSubview:_label];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = MIN(self.bounds.size.width - 40, 520);
    _label.frame = CGRectMake((self.bounds.size.width - w)/2.0, 60, w, 54);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint p = [t locationInView:self];
    if (self.onPick) self.onPick(p);
}
@end

#pragma mark - Screenshot ROI

static CGRect QTMakeROI(CGPoint point, CGSize screenSize, CGFloat roiSize) {
    CGFloat half = roiSize / 2.0;
    CGFloat x = point.x - half;
    CGFloat y = point.y - half;

    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x + roiSize > screenSize.width)  x = MAX(0, screenSize.width - roiSize);
    if (y + roiSize > screenSize.height) y = MAX(0, screenSize.height - roiSize);

    return CGRectMake(x, y, MIN(roiSize, screenSize.width), MIN(roiSize, screenSize.height));
}

static UIImage *QTCropImage(UIImage *img, CGRect cropRectInPoints) {
    if (!img) return nil;

    CGFloat scale = img.scale;
    CGRect r = CGRectMake(cropRectInPoints.origin.x * scale,
                          cropRectInPoints.origin.y * scale,
                          cropRectInPoints.size.width * scale,
                          cropRectInPoints.size.height * scale);

    CGImageRef cg = CGImageCreateWithImageInRect(img.CGImage, r);
    if (!cg) return nil;
    UIImage *out = [UIImage imageWithCGImage:cg scale:img.scale orientation:img.imageOrientation];
    CGImageRelease(cg);
    return out;
}

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
    if (!image.CGImage) {
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

#pragma mark - LibreTranslate request

static void QTLibreTranslate(NSString *serverURL, NSString *text, NSString *targetLang, void (^completion)(NSString *translated, NSError *err)) {
    if (text.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Kein Text erkannt"}]);
        return;
    }

    NSString *base = serverURL.length ? serverURL : @"https://libretranslate.com";
    // normalize: remove trailing slash
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];

    NSString *urlString = [base stringByAppendingString:@"/translate"];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Ungültige LibreTranslate URL"}]);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *payload = @{
        @"q": text,
        @"source": @"auto",
        @"target": targetLang.length ? targetLang : @"de",
        @"format": @"text"
    };

    NSError *jsonErr = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonErr];
    if (!body) {
        if (completion) completion(nil, jsonErr ?: [NSError errorWithDomain:@"QT" code:4 userInfo:@{NSLocalizedDescriptionKey:@"JSON Fehler"}]);
        return;
    }
    req.HTTPBody = body;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 12.0;
    cfg.timeoutIntervalForResource = 12.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        if (!data) {
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:5 userInfo:@{NSLocalizedDescriptionKey:@"Keine Antwort"}]);
            return;
        }

        NSError *parseErr = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (!obj || parseErr) {
            if (completion) completion(nil, parseErr ?: [NSError errorWithDomain:@"QT" code:6 userInfo:@{NSLocalizedDescriptionKey:@"Antwort konnte nicht gelesen werden"}]);
            return;
        }

        NSString *translated = nil;
        if ([obj isKindOfClass:[NSDictionary class]]) {
            translated = ((NSDictionary *)obj)[@"translatedText"];
            // manche Instanzen liefern auch "translation"
            if (!translated) translated = ((NSDictionary *)obj)[@"translation"];
        }

        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:7 userInfo:@{NSLocalizedDescriptionKey:@"Keine Übersetzung erhalten"}]);
            return;
        }

        if (completion) completion(translated, nil);
    }];

    [task resume];
}

#pragma mark - Result UI

static void QTShowResultPopup(NSString *original, NSString *translated) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopViewController(w.rootViewController);
    if (!top) return;

    NSString *msg = translated ?: @"";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Übersetzung"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];

    [ac addAction:[UIAlertAction actionWithTitle:@"Kopieren" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        UIPasteboard.generalPasteboard.string = msg ?: @"";
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Schließen" style:UIAlertActionStyleCancel handler:nil]];

    [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Floating button

static void QTStartPickMode(void);

static void QTInstallFloatingButton(void) {
    if (!QTIsEnabledForCurrentApp()) return;

    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    if ([w viewWithTag:kQTButtonTag] != nil) return;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = kQTButtonTag;
    [btn setTitle:@"🌐" forState:UIControlStateNormal];
    btn.frame = CGRectMake(20, 200, 48, 48);
    btn.layer.cornerRadius = 24;
    btn.clipsToBounds = YES;
    btn.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.85];

    // Drag
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(qt_pan:)];
    [btn addGestureRecognizer:pan];

    // Tap
    if (@available(iOS 14.0, *)) {
        [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            QTStartPickMode();
        }] forControlEvents:UIControlEventTouchUpInside];
    } else {
        [btn addTarget:w action:@selector(qt_fallbackTap) forControlEvents:UIControlEventTouchUpInside];
    }

    [w addSubview:btn];
}

// Drag implementation via category on UIView (UIButton)
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
- (void)qt_fallbackTap { QTStartPickMode(); }
@end

#pragma mark - Pick flow (OCR -> LibreTranslate)

static void QTStartPickMode(void) {
    if (!QTIsEnabledForCurrentApp()) {
        QTShowAlert(@"QuickTranslate", @"In dieser App deaktiviert.");
        return;
    }

    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    // avoid stacking overlays
    UIView *existing = [w viewWithTag:987655];
    if (existing) [existing removeFromSuperview];

    QTPickOverlayView *ov = [[QTPickOverlayView alloc] initWithFrame:w.bounds];
    ov.tag = 987655;

    // --- retain-cycle safe block ---
    __weak typeof(ov) weakOv = ov;
    ov.onPick = ^(CGPoint point) {
        __strong typeof(weakOv) ovStrong = weakOv;
        if (!ovStrong) return;

        [ovStrong removeFromSuperview];

        // Preferences
        NSString *server = QTString(@"ltServer", @"https://libretranslate.com");
        NSString *target = QTString(@"targetLang", @"de");
        CGFloat roiSize = QTFloat(@"roiSize", 900.0);
        if (roiSize < 300.0) roiSize = 300.0;
        if (roiSize > 1600.0) roiSize = 1600.0;

        // Screenshot + crop ROI
        UIImage *snap = QTScreenSnapshot();
        if (!snap) {
            dispatch_async(dispatch_get_main_queue(), ^{
                QTShowAlert(@"QuickTranslate", @"Screenshot fehlgeschlagen.");
            });
            return;
        }

        CGSize screenSize = snap.size; // points (because renderer uses points)
        CGRect roi = QTMakeROI(point, screenSize, roiSize);
        UIImage *crop = QTCropImage(snap, roi);
        if (!crop) crop = snap;

        // OCR
        QTRunOCR(crop, ^(NSString *text, NSError *err) {
            if (err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    QTShowAlert(@"OCR Fehler", err.localizedDescription ?: @"Unbekannter Fehler");
                });
                return;
            }

            NSString *trim = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trim.length == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    QTShowAlert(@"QuickTranslate", @"Kein Text erkannt. Tipp näher an den Text oder ROI erhöhen.");
                });
                return;
            }

            // Translate via LibreTranslate
            QTLibreTranslate(server, trim, target, ^(NSString *translated, NSError *tErr) {
                if (tErr) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        QTShowAlert(@"Übersetzung fehlgeschlagen", tErr.localizedDescription ?: @"Unbekannter Fehler");
                    });
                    return;
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    QTShowResultPopup(trim, translated);
                });
            });
        });
    };

    [w addSubview:ov];
}

#pragma mark - Lifecycle hook

%hook UIApplication
- (void)applicationDidBecomeActive:(id)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        QTInstallFloatingButton();
    });
}
%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        QTInstallFloatingButton();
    });
}

