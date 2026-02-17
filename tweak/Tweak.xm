#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <objc/runtime.h>

static NSString * const kPrefsDomain = @"1.com.quicktranslate.prefsfixed";

static id QTPreferencesValue(NSString *key) {
    CFPropertyListRef pl = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                     (__bridge CFStringRef)kPrefsDomain);
    return pl ? (__bridge_transfer id)pl : nil;
}

static BOOL QTBool(NSString *key, BOOL def) {
    id v = QTPreferencesValue(key);
    return v ? [v boolValue] : def;
}

static NSString * QTString(NSString *key, NSString *def) {
    id v = QTPreferencesValue(key);
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : def;
}

static BOOL QTWhitelistAllowsCurrentApp(void) {
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

static UIWindow *QTGetKeyWindow(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static UIViewController *QTTopViewController(UIViewController *root) {
    UIViewController *vc = root;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return QTTopViewController(((UINavigationController *)vc).topViewController);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        return QTTopViewController(((UITabBarController *)vc).selectedViewController);
    }
    return vc;
}

static UIImage *QTScreenshot(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return nil;

    CGSize size = w.bounds.size;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];

    return [r imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        // drawViewHierarchyInRect is usually best for UIKit/WebKit
        [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:NO];
    }];
}

static CGRect QTMakeROI(CGPoint p, CGSize imgSize, BOOL large) {
    CGFloat w = large ? 520.0 : 360.0;
    CGFloat h = large ? 360.0 : 240.0;
    CGFloat x = p.x - w/2.0;
    CGFloat y = p.y - h/2.0;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x + w > imgSize.width) x = imgSize.width - w;
    if (y + h > imgSize.height) y = imgSize.height - h;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    return CGRectMake(x, y, w, h);
}

static UIImage *QTCrop(UIImage *img, CGRect roiPoints) {
    if (!img) return nil;
    CGFloat scale = img.scale;
    CGRect roiPx = CGRectMake(roiPoints.origin.x * scale,
                              roiPoints.origin.y * scale,
                              roiPoints.size.width * scale,
                              roiPoints.size.height * scale);
    CGImageRef cg = CGImageCreateWithImageInRect(img.CGImage, roiPx);
    if (!cg) return nil;
    UIImage *out = [UIImage imageWithCGImage:cg scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return out;
}

static NSString *QTDecodeHTMLEntities(NSString *s) {
    if (!s.length) return s;
    NSDictionary *map = @{
        @"&amp;": @"&",
        @"&quot;": @"\"",
        @"&#39;": @"'",
        @"&lt;": @"<",
        @"&gt;": @">"
    };
    NSString *out = s;
    for (NSString *k in map) out = [out stringByReplacingOccurrencesOfString:k withString:map[k]];
    return out;
}

@interface QTOverlayButton : UIButton
@end
@implementation QTOverlayButton
@end

@interface QTTranslatorManager : NSObject
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) QTOverlayButton *button;
@property (nonatomic, strong) UIView *pickOverlay;
@property (nonatomic, assign) BOOL pickMode;
+ (instancetype)shared;
- (void)startIfNeeded;
@end

@implementation QTTranslatorManager

+ (instancetype)shared {
    static QTTranslatorManager *m;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ m = [QTTranslatorManager new]; });
    return m;
}

- (void)startIfNeeded {
    if (!QTWhitelistAllowsCurrentApp()) return;
    if (self.overlayWindow) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        self.overlayWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        self.overlayWindow.backgroundColor = UIColor.clearColor;
        self.overlayWindow.windowLevel = UIWindowLevelAlert + 50;
        self.overlayWindow.hidden = NO;

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = UIColor.clearColor;
        self.overlayWindow.rootViewController = vc;

        // Button
        self.button = [QTOverlayButton buttonWithType:UIButtonTypeSystem];
        self.button.frame = CGRectMake(20, 160, 56, 56);
        self.button.layer.cornerRadius = 28;
        self.button.clipsToBounds = YES;
        self.button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.65];
        [self.button setTitle:@"🌐" forState:UIControlStateNormal];
        self.button.titleLabel.font = [UIFont systemFontOfSize:26];
        [self.button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [self.button addTarget:self action:@selector(onButtonTap) forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [self.button addGestureRecognizer:pan];

        [vc.view addSubview:self.button];
    });
}

- (void)onPan:(UIPanGestureRecognizer *)gr {
    UIView *v = gr.view;
    CGPoint t = [gr translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [gr setTranslation:CGPointZero inView:v.superview];
}

- (void)onButtonTap {
    if (self.pickMode) {
        [self exitPickMode];
        return;
    }
    [self enterPickMode];
}

- (void)enterPickMode {
    self.pickMode = YES;

    UIView *ov = [[UIView alloc] initWithFrame:self.overlayWindow.bounds];
    ov.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.18];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(ov.bounds, 20, 80)];
    label.text = @"Tippe auf den Text, den du übersetzen willst";
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont boldSystemFontOfSize:18];
    [ov addSubview:label];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onPickTap:)];
    [ov addGestureRecognizer:tap];

    self.pickOverlay = ov;
    [self.overlayWindow.rootViewController.view addSubview:ov];

    // give user visual feedback
    self.button.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.75];
}

- (void)exitPickMode {
    self.pickMode = NO;
    [self.pickOverlay removeFromSuperview];
    self.pickOverlay = nil;
    self.button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.65];
}

- (void)onPickTap:(UITapGestureRecognizer *)gr {
    CGPoint p = [gr locationInView:self.overlayWindow];
    [self exitPickMode];

    // OCR + Translate pipeline
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *apiKey = QTString(@"googleApiKey", @"");
        if (!apiKey.length) {
            [self showMessage:@"Bitte in Einstellungen einen Google API Key setzen." title:@"QuickTranslate"]; 
            return;
        }

        UIImage *shot = QTScreenshot();
        if (!shot) {
            [self showMessage:@"Screenshot fehlgeschlagen." title:@"QuickTranslate"]; 
            return;
        }

        BOOL large = QTBool(@"largeROI", NO);
        CGRect roi = QTMakeROI(p, shot.size, large);
        UIImage *crop = QTCrop(shot, roi);
        if (!crop) {
            [self showMessage:@"OCR Crop fehlgeschlagen." title:@"QuickTranslate"]; 
            return;
        }

        [self recognizeTextInImage:crop completion:^(NSString *text) {
            if (!text.length) {
                [self showMessage:@"Kein Text erkannt. Tippe näher an den Text oder aktiviere 'OCR Bereich vergrößern'." title:@"QuickTranslate"]; 
                return;
            }

            [self translate:text apiKey:apiKey completion:^(NSString *translated, NSString *err) {
                if (err.length) {
                    [self showMessage:err title:@"Google Translate"]; 
                    return;
                }
                if (!translated.length) {
                    [self showMessage:@"Keine Übersetzung erhalten." title:@"Google Translate"]; 
                    return;
                }
                [self showTranslation:translated original:text];
            }];
        }];
    });
}

- (void)recognizeTextInImage:(UIImage *)image completion:(void(^)(NSString *text))completion {
    CGImageRef cg = image.CGImage;
    if (!cg) { completion(@""); return; }

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        if (error) { completion(@""); return; }
        NSMutableArray<NSString *> *lines = [NSMutableArray new];
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *top = [[obs topCandidates:1] firstObject];
            if (top.string.length) [lines addObject:top.string];
        }
        NSString *joined = [lines componentsJoinedByString:@"\n"]; 
        completion(joined);
    }];

    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = YES;

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    NSError *err = nil;
    [handler performRequests:@[req] error:&err];
    if (err) completion(@"");
}

- (void)translate:(NSString *)text apiKey:(NSString *)apiKey completion:(void(^)(NSString *translated, NSString *err))completion {
    NSString *target = QTString(@"targetLang", @"de");

    // Google Cloud Translation API v2
    // POST https://translation.googleapis.com/language/translate/v2?key=API_KEY
    NSURLComponents *c = [NSURLComponents componentsWithString:@"https://translation.googleapis.com/language/translate/v2"]; 
    c.queryItems = @[[NSURLQueryItem queryItemWithName:@"key" value:apiKey]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:c.URL];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; 

    NSDictionary *body = @{
        @"q": text,
        @"target": target,
        // source optional - let Google detect
        @"format": @"text"
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    req.HTTPBody = data;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable d, NSURLResponse * _Nullable r, NSError * _Nullable e) {
        if (e) { completion(@"", e.localizedDescription ?: @"Netzwerkfehler"); return; }
        if (!d.length) { completion(@"", @"Leere Antwort von Google"); return; }

        NSError *je = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:&je];
        if (je || ![json isKindOfClass:[NSDictionary class]]) {
            completion(@"", @"Ungültige Google-Antwort");
            return;
        }

        // Error block
        NSDictionary *errObj = json[@"error"]; 
        if ([errObj isKindOfClass:[NSDictionary class]]) {
            NSString *msg = errObj[@"message"]; 
            completion(@"", msg.length ? msg : @"Google API Fehler");
            return;
        }

        NSDictionary *dataObj = json[@"data"]; 
        NSArray *translations = [dataObj isKindOfClass:[NSDictionary class]] ? dataObj[@"translations"] : nil;
        NSDictionary *first = [translations isKindOfClass:[NSArray class]] ? translations.firstObject : nil;
        NSString *translated = [first isKindOfClass:[NSDictionary class]] ? first[@"translatedText"] : nil;
        translated = QTDecodeHTMLEntities(translated ?: @"");
        completion(translated, @"");
    }];
    [task resume];
}

- (void)showTranslation:(NSString *)translated original:(NSString *)original {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *key = QTGetKeyWindow();
        UIViewController *root = key.rootViewController;
        UIViewController *top = QTTopViewController(root);
        if (!top) return;

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Übersetzung" message:translated preferredStyle:UIAlertControllerStyleAlert];

        [ac addAction:[UIAlertAction actionWithTitle:@"Kopieren" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull action) {
            UIPasteboard.generalPasteboard.string = translated;
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"Schließen" style:UIAlertActionStyleCancel handler:nil]];

        [top presentViewController:ac animated:YES completion:nil];
    });
}

- (void)showMessage:(NSString *)msg title:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *key = QTGetKeyWindow();
        UIViewController *top = QTTopViewController(key.rootViewController);
        if (!top) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

@end

%ctor {
    @autoreleasepool {
        // only start in allowed apps
        if (!QTWhitelistAllowsCurrentApp()) return;

        // start when app is active (covers Safari/Telegram/etc.)
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(__unused NSNotification *note) {
                [[QTTranslatorManager shared] startIfNeeded];
            }];

            // also attempt immediately
            [[QTTranslatorManager shared] startIfNeeded];
        });
    }
}
