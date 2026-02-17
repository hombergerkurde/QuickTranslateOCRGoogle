#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <objc/runtime.h>

static NSString * const kPrefsDomain = @"1.com.quicktranslate.prefsfixed";
static const NSInteger kQTButtonTag = 987654;

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
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return (NSString *)v;
    return def;
}
static NSInteger QTInt(NSString *key, NSInteger def) {
    id v = QTPreferencesValue(key);
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    return def;
}

static BOOL QTIsEnabledForCurrentApp(void) {
    if (!QTBool(@"enabled", YES)) return NO;

    BOOL useWL = QTBool(@"useWhitelist", NO);
    if (!useWL) return YES;

    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
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

static UIWindow *QTGetKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;

            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
            if (ws.windows.count) return ws.windows.firstObject;
        }
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.windows.count) return ws.windows.firstObject;
        }
        return nil;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow ?: app.windows.firstObject;
#pragma clang diagnostic pop
}

static UIViewController *QTTopVC(UIViewController *vc) {
    if (!vc) return nil;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) return QTTopVC(((UINavigationController *)vc).topViewController);
    if ([vc isKindOfClass:[UITabBarController class]]) return QTTopVC(((UITabBarController *)vc).selectedViewController);
    return vc;
}

static void QTShowAlert(NSString *title, NSString *message, BOOL allowCopy) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopVC(w.rootViewController);
    if (!top) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title ?: @"QuickTranslate"
                                                                message:message ?: @""
                                                         preferredStyle:UIAlertControllerStyleAlert];
    if (allowCopy) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Kopieren" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
            UIPasteboard.generalPasteboard.string = message ?: @"";
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Schließen" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Pick overlay

@interface QTPickOverlay : UIView
@property(nonatomic, copy) void (^onPick)(CGPoint point);
@end

@implementation QTPickOverlay
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.12];
    self.userInteractionEnabled = YES;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectZero];
    lbl.text = @"Tippe auf den Text, den du übersetzen willst";
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.numberOfLines = 2;
    lbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    lbl.textColor = UIColor.whiteColor;
    lbl.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    lbl.layer.cornerRadius = 12;
    lbl.clipsToBounds = YES;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:lbl];

    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [lbl.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [lbl.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-18],
        [lbl.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];

    return self;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint p = [t locationInView:self];
    if (self.onPick) self.onPick(p);
}
@end

#pragma mark - OCR + LibreTranslate

static UIImage *QTScreenshot(UIWindow *w) {
    if (!w) return nil;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:w.bounds];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:NO];
    }];
}

static UIImage *QTCrop(UIImage *img, CGRect rectPoints) {
    if (!img) return nil;
    CGFloat scale = img.scale;
    CGRect r = CGRectMake(rectPoints.origin.x * scale,
                          rectPoints.origin.y * scale,
                          rectPoints.size.width * scale,
                          rectPoints.size.height * scale);
    CGImageRef cg = CGImageCreateWithImageInRect(img.CGImage, r);
    if (!cg) return nil;
    UIImage *out = [UIImage imageWithCGImage:cg scale:img.scale orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return out;
}

static void QTOCRImage(UIImage *img, void (^completion)(NSString *text)) {
    if (!img) { completion(nil); return; }
    CGImageRef cg = img.CGImage;
    if (!cg) { completion(nil); return; }

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(__unused VNRequest *request, NSError * _Nullable error) {
        if (error) { completion(nil); return; }

        NSMutableArray<NSString *> *lines = [NSMutableArray new];
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *best = [[obs topCandidates:1] firstObject];
            if (best.string.length) [lines addObject:best.string];
        }
        NSString *joined = [lines componentsJoinedByString:@"\n"];
        completion(joined.length ? joined : nil);
    }];

    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = YES;

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        [handler performRequests:@[req] error:&err];
        if (err) completion(nil);
    });
}

static void QTLibreTranslate(NSString *text, void (^completion)(NSString *translated, NSString *errMsg)) {
    if (text.length == 0) { completion(nil, @"Kein Text erkannt."); return; }

    NSString *server = QTString(@"ltServer", @"https://libretranslate.com");
    NSString *target = QTString(@"targetLang", @"de");

    // normalize server (no trailing slash)
    while ([server hasSuffix:@"/"]) server = [server substringToIndex:server.length-1];
    NSString *urlStr = [server stringByAppendingString:@"/translate"];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { completion(nil, @"LibreTranslate URL ungültig."); return; }

    NSDictionary *body = @{
        @"q": text,
        @"source": @"auto",
        @"target": target,
        @"format": @"text"
    };

    NSError *jsonErr = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (!data || jsonErr) { completion(nil, @"JSON Fehler."); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = data;
    req.timeoutInterval = 20.0;

    NSURLSessionDataTask *task =
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable d, NSURLResponse * _Nullable r, NSError * _Nullable e) {
        if (e) { completion(nil, e.localizedDescription ?: @"Netzwerkfehler."); return; }
        if (!d) { completion(nil, @"Keine Antwort."); return; }

        NSError *parseErr = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:&parseErr];
        if (parseErr || ![obj isKindOfClass:[NSDictionary class]]) {
            completion(nil, @"Antwort konnte nicht gelesen werden.");
            return;
        }
        NSString *translated = ((NSDictionary *)obj)[@"translatedText"];
        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            // Manche Instanzen liefern Fehler als "error"
            NSString *err = ((NSDictionary *)obj)[@"error"];
            if ([err isKindOfClass:[NSString class]] && err.length) completion(nil, err);
            else completion(nil, @"Keine Übersetzung erhalten.");
            return;
        }
        completion(translated, nil);
    }];
    [task resume];
}

#pragma mark - Button + flow

static void QTStartPickFlow(void) {
    if (!QTIsEnabledForCurrentApp()) return;

    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    QTPickOverlay *ov = [[QTPickOverlay alloc] initWithFrame:w.bounds];
    ov.onPick = ^(CGPoint point) {
        [ov removeFromSuperview];

        // Screenshot + ROI crop
        NSInteger roi = QTInt(@"roiSize", 700);
        if (roi < 200) roi = 200;
        CGFloat half = (CGFloat)roi / 2.0;

        CGRect roiRect = CGRectMake(point.x - half, point.y - half, (CGFloat)roi, (CGFloat)roi);
        roiRect = CGRectIntersection(roiRect, w.bounds);

        UIImage *shot = QTScreenshot(w);
        UIImage *cropped = QTCrop(shot, roiRect);

        QTShowAlert(@"QuickTranslate", @"OCR läuft…", NO);

        QTOCRImage(cropped, ^(NSString *text) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (text.length == 0) {
                    QTShowAlert(@"QuickTranslate", @"Kein Text erkannt.\n(Tipp: OCR Bereich vergrößern)", NO);
                    return;
                }

                QTLibreTranslate(text, ^(NSString *translated, NSString *errMsg) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (errMsg.length) {
                            QTShowAlert(@"Übersetzung fehlgeschlagen", errMsg, NO);
                            return;
                        }
                        QTShowAlert(@"Übersetzung", translated ?: @"", YES);
                    });
                });
            });
        });
    };

    [w addSubview:ov];
}

static void QTInstallButton(void) {
    if (!QTIsEnabledForCurrentApp()) return;

    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    if ([w viewWithTag:kQTButtonTag]) return;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = kQTButtonTag;
    [btn setTitle:@"🌐" forState:UIControlStateNormal];
    btn.frame = CGRectMake(20, 200, 48, 48);
    btn.layer.cornerRadius = 24;
    btn.clipsToBounds = YES;
    btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85];

    // Drag
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(qt_pan:)];
    [btn addGestureRecognizer:pan];

    if (@available(iOS 14.0, *)) {
        [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            QTStartPickFlow();
        }] forControlEvents:UIControlEventTouchUpInside];
    } else {
        [btn addTarget:w action:@selector(qt_fallbackTap) forControlEvents:UIControlEventTouchUpInside];
    }

    [w addSubview:btn];
}

@interface UIButton (QTDrag)
- (void)qt_pan:(UIPanGestureRecognizer *)gr;
@end

@implementation UIButton (QTDrag)
- (void)qt_pan:(UIPanGestureRecognizer *)gr {
    UIView *superv = self.superview;
    if (!superv) return;
    CGPoint tr = [gr translationInView:superv];
    self.center = CGPointMake(self.center.x + tr.x, self.center.y + tr.y);
    [gr setTranslation:CGPointZero inView:superv];
}
@end

@interface UIWindow (QTFallback)
- (void)qt_fallbackTap;
@end
@implementation UIWindow (QTFallback)
- (void)qt_fallbackTap { QTStartPickFlow(); }
@end

%hook UIApplication
- (void)applicationDidBecomeActive:(id)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        QTInstallButton();
    });
}
%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        QTInstallButton();
    });
}
