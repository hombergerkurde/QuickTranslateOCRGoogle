#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <QuartzCore/QuartzCore.h>

static NSString * const kPrefsDomain = @"com.hombergerkurde.quicktranslate";
static const NSInteger kQTButtonTag = 987654;
static const NSInteger kQTHUDTag = 998877;

#pragma mark - Prefs

static NSDictionary *QTGetPrefs(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] persistentDomainForName:kPrefsDomain];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

static NSString *QTGetString(NSString *key, NSString *def) {
    id v = QTGetPrefs()[key];
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : def;
}

static BOOL QTGetBool(NSString *key, BOOL def) {
    id v = QTGetPrefs()[key];
    return v ? [v boolValue] : def;
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

#pragma mark - HUD / UI

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

    CGFloat maxW = MIN(340.0, w.bounds.size.width - 40.0);
    CGSize maxSize = CGSizeMake(maxW, CGFLOAT_MAX);

    CGRect r = [lbl.text boundingRectWithSize:maxSize
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

    [ac addAction:[UIAlertAction actionWithTitle:@"Kopieren"
                                          style:UIAlertActionStyleDefault
                                        handler:^(__unused UIAlertAction *a){
        UIPasteboard.generalPasteboard.string = msg;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Schließen" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Screenshot (stable)

static UIImage *QTScreenSnapshot(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return nil;

    CGSize size = w.bounds.size;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.scale = 1.0;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    UIImage *img = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [w.layer renderInContext:UIGraphicsGetCurrentContext()];
    }];
    return img;
}

static UIImage *QTNormalizeForOCR(UIImage *src) {
    if (!src) return nil;

    CGFloat maxDim = 1280.0;
    CGFloat w = src.size.width;
    CGFloat h = src.size.height;
    CGFloat m = MAX(w, h);
    CGFloat scale = (m > maxDim) ? (maxDim / m) : 1.0;

    CGSize newSize = CGSizeMake(floor(w * scale), floor(h * scale));
    if (newSize.width < 1 || newSize.height < 1) return src;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.scale = 1.0;

    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:newSize format:fmt];
    UIImage *out = [r imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [src drawInRect:(CGRect){CGPointZero, newSize}];
    }];
    return out;
}

#pragma mark - OCR (Vision) with boxes

static void QTRunOCR_Boxes(UIImage *image, void (^completion)(NSArray<VNRecognizedTextObservation *> *obs, NSError *err)) {
    UIImage *norm = QTNormalizeForOCR(image);
    if (!norm || !norm.CGImage) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Kein Bild für OCR"}]);
        return;
    }

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSArray *results = request.results ?: @[];
        if (completion) completion((NSArray<VNRecognizedTextObservation *> *)results, nil);
    }];

    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = YES;

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:norm.CGImage options:@{}];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        [handler performRequests:@[req] error:&err];
        if (err && completion) completion(nil, err);
    });
}

static CGRect QTVisionRectToImageRect(CGRect bb, CGSize imgSize) {
    CGFloat W = imgSize.width;
    CGFloat H = imgSize.height;
    return CGRectMake(bb.origin.x * W,
                      (1.0 - bb.origin.y - bb.size.height) * H,
                      bb.size.width * W,
                      bb.size.height * H);
}

static NSString *QTTextFromObs(VNRecognizedTextObservation *o) {
    VNRecognizedText *best = [[o topCandidates:1] firstObject];
    return best.string ?: @"";
}

static NSString *QTExtractTextNearPoint(NSArray<VNRecognizedTextObservation *> *obs,
                                       CGPoint tapPoint,
                                       CGSize imgSize) {
    if (obs.count == 0) return @"";

    NSMutableArray<VNRecognizedTextObservation *> *hit = [NSMutableArray new];

    for (VNRecognizedTextObservation *o in obs) {
        CGRect r = QTVisionRectToImageRect(o.boundingBox, imgSize);
        if (CGRectContainsPoint(r, tapPoint)) {
            [hit addObject:o];
        }
    }

    if (hit.count == 0) {
        VNRecognizedTextObservation *best = nil;
        CGFloat bestDist = CGFLOAT_MAX;

        for (VNRecognizedTextObservation *o in obs) {
            CGRect r = QTVisionRectToImageRect(o.boundingBox, imgSize);
            CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
            CGFloat dx = c.x - tapPoint.x;
            CGFloat dy = c.y - tapPoint.y;
            CGFloat d = dx*dx + dy*dy;
            if (d < bestDist) { bestDist = d; best = o; }
        }
        if (best) [hit addObject:best];
    }

    [hit sortUsingComparator:^NSComparisonResult(VNRecognizedTextObservation *a, VNRecognizedTextObservation *b) {
        CGRect ra = QTVisionRectToImageRect(a.boundingBox, imgSize);
        CGRect rb = QTVisionRectToImageRect(b.boundingBox, imgSize);
        if (fabs(CGRectGetMinY(ra) - CGRectGetMinY(rb)) > 6.0) {
            return CGRectGetMinY(ra) < CGRectGetMinY(rb) ? NSOrderedAscending : NSOrderedDescending;
        }
        return CGRectGetMinX(ra) < CGRectGetMinX(rb) ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (VNRecognizedTextObservation *o in hit) {
        NSString *s = [QTTextFromObs(o) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length) [lines addObject:s];
    }
    return [lines componentsJoinedByString:@"\n"];
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

#pragma mark - Pick Mode Overlay

@interface QTOverlayView : UIView
@property (nonatomic, copy) void (^onPick)(CGPoint p);
@end

@implementation QTOverlayView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.15];
        self.userInteractionEnabled = YES;

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
        hint.text = @"Tippe auf den Text, den du übersetzen willst";
        hint.textColor = UIColor.whiteColor;
        hint.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
        hint.textAlignment = NSTextAlignmentCenter;
        hint.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        hint.layer.cornerRadius = 12;
        hint.clipsToBounds = YES;
        hint.tag = 101;

        [self addSubview:hint];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UILabel *hint = [self viewWithTag:101];
    CGFloat w = MIN(self.bounds.size.width - 40.0, 360.0);
    hint.frame = CGRectMake((self.bounds.size.width - w)/2.0,
                            self.safeAreaInsets.top + 18.0,
                            w, 44.0);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    if (self.onPick) self.onPick(p);
}
@end

#pragma mark - Main Action (pick + translate)

static BOOL gQTBusy = NO;
static BOOL gQTPicking = NO;

static void QTStartPickMode(void) {
    if (gQTBusy || gQTPicking) return;
    if (!QTGetBool(@"enabled", YES)) return;

    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    gQTPicking = YES;
    QTShowHUD(@"Tippe auf den Text…");

    QTOverlayView *ov = [[QTOverlayView alloc] initWithFrame:w.bounds];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    __weak QTOverlayView *weakOv = ov;
    ov.onPick = ^(CGPoint p) {
        QTOverlayView *strongOv = weakOv;
        [strongOv removeFromSuperview];
        QTHideHUD();

        gQTBusy = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ QTShowHUD(@"Erkenne Text…"); });

        UIImage *snap = QTScreenSnapshot();
        if (!snap) {
            dispatch_async(dispatch_get_main_queue(), ^{
                QTHideHUD();
                QTShowAlert(@"QuickTranslate", @"Screenshot fehlgeschlagen.");
            });
            gQTBusy = NO;
            gQTPicking = NO;
            return;
        }

        QTRunOCR_Boxes(snap, ^(NSArray<VNRecognizedTextObservation *> *obs, NSError *err) {
            if (err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    QTHideHUD();
                    QTShowAlert(@"OCR Fehler", err.localizedDescription ?: @"Unbekannter Fehler");
                });
                gQTBusy = NO;
                gQTPicking = NO;
                return;
            }

            NSString *pickedText = QTExtractTextNearPoint(obs, p, snap.size);
            NSString *trim = [pickedText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trim.length == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    QTHideHUD();
                    QTShowAlert(@"QuickTranslate", @"Kein Text an der Stelle gefunden. Tippe näher an den Text.");
                });
                gQTBusy = NO;
                gQTPicking = NO;
                return;
            }

            if (trim.length > 1400) trim = [trim substringToIndex:1400];
            dispatch_async(dispatch_get_main_queue(), ^{ QTShowHUD(@"Übersetze…"); });

            NSString *target = QTGetString(@"targetLang", @"de");
            target = [target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (target.length == 0) target = @"de";

            NSString *server = QTGetString(@"ltServer", @"https://translate.cutie.dating");
            NSString *apiKey  = QTGetString(@"ltApiKey", @"");

            QTTranslate_Libre(server, apiKey, trim, target, ^(NSString *translated, NSError *tErr) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    QTHideHUD();
                    if (tErr) QTShowAlert(@"Übersetzung fehlgeschlagen", tErr.localizedDescription ?: @"Unbekannter Fehler");
                    else QTShowResultPopup(translated);
                });
                gQTBusy = NO;
                gQTPicking = NO;
            });
        });
    };

    [w addSubview:ov];
    [w bringSubviewToFront:ov];
}

#pragma mark - Floating button

static void QTInstallFloatingButton(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    BOOL enabled = QTGetBool(@"enabled", YES);
    UIView *old = [w viewWithTag:kQTButtonTag];

    if (!enabled) {
        if (old) [old removeFromSuperview];
        return;
    }

    UIButton *btn = (UIButton *)old;
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.tag = kQTButtonTag;
        [btn setTitle:@"🌐" forState:UIControlStateNormal];
        btn.frame = CGRectMake(20, 220, 52, 52);
        btn.layer.cornerRadius = 26.0;
        btn.clipsToBounds = YES;
        btn.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.92];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(qt_pan:)];
        [btn addGestureRecognizer:pan];

        [btn addTarget:btn action:@selector(qt_tap) forControlEvents:UIControlEventTouchUpInside];

        [w addSubview:btn];
    }

    [w bringSubviewToFront:btn];
}

@interface UIButton (QTBtn)
- (void)qt_pan:(UIPanGestureRecognizer *)gr;
- (void)qt_tap;
@end

@implementation UIButton (QTBtn)
- (void)qt_pan:(UIPanGestureRecognizer *)gr {
    UIView *v = gr.view;
    if (!v) return;
    CGPoint tr = [gr translationInView:v.superview];
    v.center = CGPointMake(v.center.x + tr.x, v.center.y + tr.y);
    [gr setTranslation:CGPointZero inView:v.superview];
}
- (void)qt_tap {
    QTStartPickMode();
}
@end

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
