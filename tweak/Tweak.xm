#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <objc/runtime.h>

static NSString * const kPrefsDomain = @"com.hombergerkurde.quicktranslate";
static const NSInteger kQTInlineBtnTag = 984201;
static const NSInteger kQTHUDTag = 998877;
static const NSInteger kQTSileoBtnTag = 884422;
static const char *kQTTextAssocKey = "kQTTextAssocKey";

#pragma mark - Target apps

static BOOL QTIsTargetApp(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    static NSSet<NSString *> *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSSet setWithArray:@[
            @"ph.telegra.Telegraph",
            @"com.atebits.Tweetie2",
            @"net.whatsapp.WhatsApp",
            @"com.hammerandchisel.discord",
            @"com.facebook.Facebook",
            @"com.burbn.instagram",
            @"org.coolstar.SileoStore"
        ]];
    });
    return [allowed containsObject:bid];
}

static BOOL QTIsSileo(void) {
    return [NSBundle.mainBundle.bundleIdentifier ?: @"" isEqualToString:@"org.coolstar.SileoStore"];
}

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

#pragma mark - UI helpers

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

static UIViewController *QTTopViewController(UIViewController *vc) {
    if (!vc) return nil;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) return QTTopViewController(((UINavigationController *)vc).topViewController);
    if ([vc isKindOfClass:[UITabBarController class]]) return QTTopViewController(((UITabBarController *)vc).selectedViewController);
    return vc;
}

static void QTShowAlert(NSString *title, NSString *message) {
    UIWindow *w = QTGetKeyWindow(); if (!w) return;
    UIViewController *top = QTTopViewController(w.rootViewController); if (!top) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:(title ?: @"")
                                                                message:(message ?: @"")
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

static void QTShowResultPopup(NSString *translated) {
    UIWindow *w = QTGetKeyWindow(); if (!w) return;
    UIViewController *top = QTTopViewController(w.rootViewController); if (!top) return;

    NSString *msg = translated ?: @"";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Übersetzung"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Kopieren" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        UIPasteboard.generalPasteboard.string = msg;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Schließen" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

static void QTHideHUD(void) {
    UIWindow *w = QTGetKeyWindow(); if (!w) return;
    UIView *hud = [w viewWithTag:kQTHUDTag];
    if (hud) [hud removeFromSuperview];
}

static void QTShowHUD(NSString *text) {
    UIWindow *w = QTGetKeyWindow(); if (!w) return;
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
    CGRect r = [lbl.text boundingRectWithSize:maxSize options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: lbl.font} context:nil];

    CGFloat padX = 16.0, padY = 10.0;
    CGFloat width = ceil(r.size.width) + padX * 2.0;
    CGFloat height = ceil(r.size.height) + padY * 2.0;

    lbl.frame = CGRectMake((w.bounds.size.width - width)/2.0, w.safeAreaInsets.top + 18.0, width, height);
    [w addSubview:lbl];
}

#pragma mark - Screenshot + OCR (fallback)

static UIImage *QTScreenSnapshot(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return nil;
    CGSize size = w.bounds.size;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.scale = 1.0;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [w.layer renderInContext:UIGraphicsGetCurrentContext()];
    }];
}

static UIImage *QTNormalizeForOCR(UIImage *src) {
    if (!src) return nil;
    CGFloat maxDim = 1280.0;
    CGFloat w = src.size.width, h = src.size.height;
    CGFloat m = MAX(w, h);
    CGFloat scale = (m > maxDim) ? (maxDim / m) : 1.0;
    CGSize newSize = CGSizeMake(floor(w * scale), floor(h * scale));
    if (newSize.width < 1 || newSize.height < 1) return src;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.scale = 1.0;

    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:newSize format:fmt];
    return [r imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [src drawInRect:(CGRect){CGPointZero, newSize}];
    }];
}

static void QTRunOCR(UIImage *image, void (^completion)(NSString *text, NSError *err)) {
    UIImage *norm = QTNormalizeForOCR(image);
    if (!norm || !norm.CGImage) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Kein Bild für OCR"}]);
        return;
    }

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSMutableArray<NSString *> *lines = [NSMutableArray new];
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *best = [[obs topCandidates:1] firstObject];
            if (best.string.length) [lines addObject:best.string];
        }
        if (completion) completion([lines componentsJoinedByString:@"\n"], nil);
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

#pragma mark - Providers (LibreTranslate + DeepL + Microsoft + Google)

static NSURLSession *QTSession(void) {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 35.0;
    cfg.timeoutIntervalForResource = 35.0;
    return [NSURLSession sessionWithConfiguration:cfg];
}

static NSString *QTHTTPErrorMessage(NSHTTPURLResponse *http, id jsonObj, NSString *fallback) {
    NSInteger code = http ? http.statusCode : 0;
    NSString *msg = fallback ?: @"Fehler";
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSString *m = ((NSDictionary *)jsonObj)[@"message"];
        if ([m isKindOfClass:[NSString class]] && m.length) msg = m;
        NSString *e = ((NSDictionary *)jsonObj)[@"error"];
        if ([e isKindOfClass:[NSString class]] && e.length) msg = e;
    }
    if (code > 0) msg = [NSString stringWithFormat:@"%@ (HTTP %ld)", msg, (long)code];
    return msg;
}

static void QTTranslate_Libre(NSString *serverURL, NSString *apiKey, NSString *text, NSString *target, void (^completion)(NSString *, NSError *)) {
    NSString *base = (serverURL.length ? serverURL : @"https://translate.cutie.dating");
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/translate"]];
    if (!url) { if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:101 userInfo:@{NSLocalizedDescriptionKey:@"LibreTranslate URL ungültig"}]); return; }

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

    [[QTSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;

        NSError *parseErr = nil;
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr] : nil;

        if (http && http.statusCode >= 400) {
            NSString *msg = QTHTTPErrorMessage(http, obj, @"LibreTranslate fehlgeschlagen");
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:(int)http.statusCode userInfo:@{NSLocalizedDescriptionKey: msg}]);
            return;
        }
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
    }] resume];
}

static void QTTranslate_DeepL(NSString *authKey, BOOL pro, NSString *text, NSString *target, void (^completion)(NSString *, NSError *)) {
    if (authKey.length == 0) { if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:201 userInfo:@{NSLocalizedDescriptionKey:@"DeepL Key fehlt"}]); return; }
    NSString *host = pro ? @"https://api.deepl.com/v2/translate" : @"https://api-free.deepl.com/v2/translate";
    NSURL *url = [NSURL URLWithString:host];
    if (!url) { if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:202 userInfo:@{NSLocalizedDescriptionKey:@"DeepL URL ungültig"}]); return; }

    NSString *q = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
    NSString *tg = (target.length ? target : @"DE");
    tg = [tg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (tg.length == 2) tg = tg.uppercaseString;

    NSString *bodyStr = [NSString stringWithFormat:@"text=%@&target_lang=%@",
                         q,
                         [tg stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"DE"];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"DeepL-Auth-Key %@", authKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];

    [[QTSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;

        NSError *parseErr = nil;
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr] : nil;

        if (http && http.statusCode >= 400) {
            NSString *msg = QTHTTPErrorMessage(http, obj, @"DeepL fehlgeschlagen");
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:(int)http.statusCode userInfo:@{NSLocalizedDescriptionKey: msg}]);
            return;
        }
        if (parseErr || ![obj isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:203 userInfo:@{NSLocalizedDescriptionKey:@"DeepL Antwort ungültig"}]);
            return;
        }

        NSArray *translations = ((NSDictionary *)obj)[@"translations"];
        NSDictionary *first = ([translations isKindOfClass:[NSArray class]] && translations.count) ? translations.firstObject : nil;
        NSString *translated = [first isKindOfClass:[NSDictionary class]] ? first[@"text"] : nil;

        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:204 userInfo:@{NSLocalizedDescriptionKey:@"DeepL: keine Übersetzung"}]);
            return;
        }
        if (completion) completion(translated, nil);
    }] resume];
}

static void QTTranslate_MS(NSString *key, NSString *region, NSString *text, NSString *target, void (^completion)(NSString *, NSError *)) {
    if (key.length == 0) { if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:301 userInfo:@{NSLocalizedDescriptionKey:@"Microsoft Key fehlt"}]); return; }

    NSString *to = [target stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"de";
    NSString *urlStr = [NSString stringWithFormat:@"https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=%@", to];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:302 userInfo:@{NSLocalizedDescriptionKey:@"Microsoft URL ungültig"}]); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:key forHTTPHeaderField:@"Ocp-Apim-Subscription-Key"];
    if (region.length) [req setValue:region forHTTPHeaderField:@"Ocp-Apim-Subscription-Region"];

    NSArray *bodyArr = @[@{@"Text": (text ?: @"")}];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:bodyArr options:0 error:nil];

    [[QTSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;

        NSError *parseErr = nil;
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr] : nil;

        if (http && http.statusCode >= 400) {
            NSString *msg = QTHTTPErrorMessage(http, obj, @"Microsoft Übersetzung fehlgeschlagen");
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:(int)http.statusCode userInfo:@{NSLocalizedDescriptionKey: msg}]);
            return;
        }

        if (parseErr || ![obj isKindOfClass:[NSArray class]] || ((NSArray *)obj).count == 0) {
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:303 userInfo:@{NSLocalizedDescriptionKey:@"Microsoft Antwort ungültig"}]);
            return;
        }

        NSDictionary *first = ((NSArray *)obj).firstObject;
        NSArray *translations = [first isKindOfClass:[NSDictionary class]] ? first[@"translations"] : nil;
        NSDictionary *t0 = ([translations isKindOfClass:[NSArray class]] && translations.count) ? translations.firstObject : nil;
        NSString *translated = [t0 isKindOfClass:[NSDictionary class]] ? t0[@"text"] : nil;

        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:304 userInfo:@{NSLocalizedDescriptionKey:@"Microsoft: keine Übersetzung"}]);
            return;
        }
        if (completion) completion(translated, nil);
    }] resume];
}

static void QTTranslate_GoogleV2(NSString *apiKey, NSString *text, NSString *target, void (^completion)(NSString *, NSError *)) {
    if (apiKey.length == 0) { if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:401 userInfo:@{NSLocalizedDescriptionKey:@"Google API Key fehlt"}]); return; }

    NSString *k = [apiKey stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
    NSString *urlStr = [NSString stringWithFormat:@"https://translation.googleapis.com/language/translate/v2?key=%@", k];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:402 userInfo:@{NSLocalizedDescriptionKey:@"Google URL ungültig"}]); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *payload = @{@"q": (text ?: @""), @"target": (target ?: @"de"), @"format": @"text"};
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [[QTSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;

        NSError *parseErr = nil;
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr] : nil;

        if (http && http.statusCode >= 400) {
            NSString *msg = QTHTTPErrorMessage(http, obj, @"Google Übersetzung fehlgeschlagen");
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:(int)http.statusCode userInfo:@{NSLocalizedDescriptionKey: msg}]);
            return;
        }

        if (parseErr || ![obj isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:403 userInfo:@{NSLocalizedDescriptionKey:@"Google Antwort ungültig"}]);
            return;
        }

        NSDictionary *dataObj = ((NSDictionary *)obj)[@"data"];
        NSArray *translations = [dataObj isKindOfClass:[NSDictionary class]] ? dataObj[@"translations"] : nil;
        NSDictionary *t0 = ([translations isKindOfClass:[NSArray class]] && translations.count) ? translations.firstObject : nil;
        NSString *translated = [t0 isKindOfClass:[NSDictionary class]] ? t0[@"translatedText"] : nil;

        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:404 userInfo:@{NSLocalizedDescriptionKey:@"Google: keine Übersetzung"}]);
            return;
        }
        if (completion) completion(translated, nil);
    }] resume];
}

#pragma mark - Provider chain

static NSArray<NSString *> *QTProviderChain(void) {
    NSString *p = QTGetString(@"providerPrimary", @"libre");
    NSString *f1 = QTGetString(@"providerFallback1", @"deepl");
    NSString *f2 = QTGetString(@"providerFallback2", @"microsoft");
    NSMutableArray *arr = [NSMutableArray new];
    if (p.length) [arr addObject:p];
    if (f1.length && ![f1 isEqualToString:@"off"]) [arr addObject:f1];
    if (f2.length && ![f2 isEqualToString:@"off"]) [arr addObject:f2];
    return arr;
}

static BOOL QTProviderConfigured(NSString *provider) {
    if ([provider isEqualToString:@"libre"]) return YES;
    if ([provider isEqualToString:@"deepl"]) return QTGetString(@"deeplKey", @"").length > 0;
    if ([provider isEqualToString:@"microsoft"]) return QTGetString(@"msKey", @"").length > 0;
    if ([provider isEqualToString:@"google"]) return QTGetString(@"googleKey", @"").length > 0;
    return NO;
}

static void QTTranslate_WithProvider(NSString *provider, NSString *text, NSString *target, void (^completion)(NSString *, NSError *)) {
    if ([provider isEqualToString:@"libre"]) {
        QTTranslate_Libre(QTGetString(@"ltServer", @"https://translate.cutie.dating"),
                          QTGetString(@"ltApiKey", @""),
                          text, target, completion);
        return;
    }
    if ([provider isEqualToString:@"deepl"]) {
        QTTranslate_DeepL(QTGetString(@"deeplKey", @""),
                          QTGetBool(@"deeplPro", NO),
                          text, target, completion);
        return;
    }
    if ([provider isEqualToString:@"microsoft"]) {
        QTTranslate_MS(QTGetString(@"msKey", @""),
                       QTGetString(@"msRegion", @""),
                       text, target, completion);
        return;
    }
    if ([provider isEqualToString:@"google"]) {
        QTTranslate_GoogleV2(QTGetString(@"googleKey", @""),
                             text, target, completion);
        return;
    }
    if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:999 userInfo:@{NSLocalizedDescriptionKey:@"Unbekannter Anbieter"}]);
}

static void QTTranslate_WithFallbacks(NSArray<NSString *> *chain, NSInteger idx, NSString *text, NSString *target, void (^completion)(NSString *, NSError *)) {
    if (idx >= (NSInteger)chain.count) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:998 userInfo:@{NSLocalizedDescriptionKey:@"Alle Anbieter fehlgeschlagen (oder keine Keys gesetzt)."}]);
        return;
    }
    NSString *p = chain[idx];
    if (!QTProviderConfigured(p)) {
        QTTranslate_WithFallbacks(chain, idx + 1, text, target, completion);
        return;
    }
    QTTranslate_WithProvider(p, text, target, ^(NSString *translated, NSError *err) {
        if (translated.length && !err) {
            if (completion) completion(translated, nil);
            return;
        }
        QTTranslate_WithFallbacks(chain, idx + 1, text, target, completion);
    });
}

#pragma mark - Main translate functions

static BOOL gQTBusy = NO;

static void QTTranslateText(NSString *text) {
    if (gQTBusy) return;
    if (!QTGetBool(@"enabled", YES)) return;

    NSString *trim = [(text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) { QTShowAlert(@"QuickTranslate", @"Kein Text gefunden."); return; }

    const NSUInteger kMaxChars = 1400;
    if (trim.length > kMaxChars) trim = [trim substringToIndex:kMaxChars];

    NSString *target = QTGetString(@"targetLang", @"de");
    target = [target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (target.length == 0) target = @"de";

    gQTBusy = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ QTShowHUD(@"Übersetze…"); });

    NSArray *chain = QTProviderChain();
    QTTranslate_WithFallbacks(chain, 0, trim, target, ^(NSString *translated, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            QTHideHUD();
            if (err) QTShowAlert(@"Übersetzung fehlgeschlagen", err.localizedDescription ?: @"Unbekannter Fehler");
            else QTShowResultPopup(translated);
        });
        gQTBusy = NO;
    });
}

static void QTTranslateVisibleScreenOCR(void) {
    if (gQTBusy) return;
    if (!QTGetBool(@"enabled", YES)) return;

    gQTBusy = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ QTShowHUD(@"Erkenne Text…"); });

    UIImage *snap = QTScreenSnapshot();
    if (!snap) {
        dispatch_async(dispatch_get_main_queue(), ^{ QTHideHUD(); QTShowAlert(@"QuickTranslate", @"Screenshot fehlgeschlagen."); });
        gQTBusy = NO;
        return;
    }

    QTRunOCR(snap, ^(NSString *text, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{ QTHideHUD(); });
        gQTBusy = NO;
        if (err) { QTShowAlert(@"OCR Fehler", err.localizedDescription ?: @"Unbekannter Fehler"); return; }
        QTTranslateText(text);
    });
}

#pragma mark - Text extraction + Inline button

static NSString *QTExtractTextFromView(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length) return t;
    }
    if ([v isKindOfClass:[UITextView class]]) {
        NSString *t = ((UITextView *)v).text;
        if (t.length) return t;
    }
    if ([v isKindOfClass:[UITextField class]]) {
        NSString *t = ((UITextField *)v).text;
        if (t.length) return t;
    }
    for (UIView *sv in v.subviews) {
        NSString *t = QTExtractTextFromView(sv);
        if (t.length) return t;
    }
    return nil;
}

@interface UIWindow (QTInlineTap)
- (void)qt_inlineTap:(UIButton *)sender;
@end

@implementation UIWindow (QTInlineTap)
- (void)qt_inlineTap:(UIButton *)sender {
    NSString *t = objc_getAssociatedObject(sender, kQTTextAssocKey);
    if (![t isKindOfClass:[NSString class]] || t.length == 0) {
        QTTranslateVisibleScreenOCR();
        return;
    }
    QTTranslateText(t);
}
@end

static void QTAddInlineButtonToCell(UIView *cellContent) {
    if (!QTGetBool(@"enabled", YES)) return;
    if (!cellContent) return;

    NSString *text = QTExtractTextFromView(cellContent);
    NSString *trim = [(text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length < 10) return;

    UIButton *btn = (UIButton *)[cellContent viewWithTag:kQTInlineBtnTag];
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.tag = kQTInlineBtnTag;
        [btn setTitle:@"🌐" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        btn.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.85];
        btn.layer.cornerRadius = 14.0;
        btn.clipsToBounds = YES;

        UIWindow *w = QTGetKeyWindow();
        if (w) [btn addTarget:w action:@selector(qt_inlineTap:) forControlEvents:UIControlEventTouchUpInside];

        [cellContent addSubview:btn];
    }

    objc_setAssociatedObject(btn, kQTTextAssocKey, trim, OBJC_ASSOCIATION_COPY_NONATOMIC);

    CGFloat pad = 8.0;
    CGFloat bw = 28.0, bh = 28.0;
    CGRect b = cellContent.bounds;
    btn.frame = CGRectMake(MAX(pad, b.size.width - bw - pad),
                           MAX(pad, b.size.height - bh - pad),
                           bw, bh);
    [cellContent bringSubviewToFront:btn];
}

%hook UITableViewCell
- (void)layoutSubviews {
    %orig;
    if (!QTIsTargetApp()) return;
    if (QTIsSileo()) return;
    QTAddInlineButtonToCell(self.contentView);
}
%end

%hook UICollectionViewCell
- (void)layoutSubviews {
    %orig;
    if (!QTIsTargetApp()) return;
    if (QTIsSileo()) return;
    QTAddInlineButtonToCell(self.contentView);
}
%end

#pragma mark - Sileo NavBar button

static void QTInstallSileoNavButton(void) {
    if (!QTIsSileo()) return;
    if (!QTGetBool(@"enabled", YES)) return;

    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopViewController(w.rootViewController);
    if (!top) return;
    UINavigationItem *item = top.navigationItem;
    if (!item) return;

    for (UIBarButtonItem *it in item.rightBarButtonItems ?: @[]) {
        if (it.tag == kQTSileoBtnTag) return;
    }

    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"🌐"
                                                            style:UIBarButtonItemStylePlain
                                                           target:nil
                                                           action:nil];
    btn.tag = kQTSileoBtnTag;

    if (@available(iOS 14.0, *)) {
        btn.primaryAction = [UIAction actionWithHandler:^(__unused UIAction *a) {
            NSString *t = QTExtractTextFromView(top.view);
            if (t.length) QTTranslateText(t);
            else QTTranslateVisibleScreenOCR();
        }];
    } else {
        // fallback: OCR
        btn.target = w;
        btn.action = @selector(qt_inlineTap:);
    }

    NSMutableArray *arr = [NSMutableArray arrayWithArray:(item.rightBarButtonItems ?: @[])];
    [arr addObject:btn];
    item.rightBarButtonItems = arr;
}

%hook UIApplication
- (void)applicationDidBecomeActive:(id)application {
    %orig;
    if (!QTIsTargetApp()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        QTInstallSileoNavButton();
    });
}
%end

%ctor {
    if (!QTIsTargetApp()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        QTInstallSileoNavButton();
    });
}
