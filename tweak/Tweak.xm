#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>

static NSString * const kPrefsDomain = @"com.hombergerkurde.quicktranslate";
static const NSInteger kQTButtonTag = 987654;
static const NSInteger kQTHUDTag = 998877;

#pragma mark - Prefs (Simple Approach)

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

#pragma mark - Window / Top VC (iOS 15+ safe)

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
    [ac addAction:[UIAlertAction actionWithTitle:@"Kopieren" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        UIPasteboard.generalPasteboard.string = msg;
    }]];
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

#pragma mark - OCR (Vision)

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

#pragma mark - Network helpers

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
        NSString *e = ((NSDictionary *)jsonObj)[@"error"];
        if ([e isKindOfClass:[NSString class]] && e.length) msg = e;
        NSString *m = ((NSDictionary *)jsonObj)[@"message"];
        if ([m isKindOfClass:[NSString class]] && m.length) msg = m;
    }
    if (code > 0) msg = [NSString stringWithFormat:@"%@ (HTTP %ld)", msg, (long)code];
    return msg;
}

#pragma mark - Providers

static void QTTranslate_Libre(NSString *serverURL, NSString *apiKey, NSString *text, NSString *target, void (^completion)(NSString *, NSError *)) {
    NSString *base = (serverURL.length ? serverURL : @"https://translate.cutie.dating");
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];

    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/translate"]];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:101 userInfo:@{NSLocalizedDescriptionKey:@"LibreTranslate URL ungültig"}]);
        return;
    }

    NSString *q = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
    NSString *t = [target stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"de";
    NSString *k = [apiKey stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";

    NSMutableString *bodyStr = [NSMutableString stringWithFormat:@"q=%@&source=auto&target=%@&format=text", q, t];
    if (k.length) [bodyStr appendFormat:@"&api_key=%@", k];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionDataTask *task = [QTSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
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
    }];
    [task resume];
}

static void QTTranslate_DeepL(NSString *authKey, BOOL pro, NSString *text, NSString *target, void (^completion)(NSString *, NSError *)) {
    if (authKey.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:201 userInfo:@{NSLocalizedDescriptionKey:@"DeepL Key fehlt"}]);
        return;
    }

    NSString *host = pro ? @"https://api.deepl.com/v2/translate" : @"https://api-free.deepl.com/v2/translate";
    NSURL *url = [NSURL URLWithString:host];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:202 userInfo:@{NSLocalizedDescriptionKey:@"DeepL URL ungültig"}]);
        return;
    }

    NSString *q = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
    NSString *t = [target stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"DE";
    NSString *bodyStr = [NSString stringWithFormat:@"text=%@&target_lang=%@", q, t];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"DeepL-Auth-Key %@", authKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionDataTask *task = [QTSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
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
    }];
    [task resume];
}

static void QTTranslate_MS(NSString *key, NSString *region, NSString *text, NSString *target, void (^completion)(NSString *, NSError *)) {
    if (key.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:301 userInfo:@{NSLocalizedDescriptionKey:@"Microsoft Key fehlt"}]);
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=%@",
                        [target stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"de"];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:302 userInfo:@{NSLocalizedDescriptionKey:@"Microsoft URL ungültig"}]);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:key forHTTPHeaderField:@"Ocp-Apim-Subscription-Key"];
    if (region.length) [req setValue:region forHTTPHeaderField:@"Ocp-Apim-Subscription-Region"];

    NSArray *bodyArr = @[@{@"Text": text ?: @""}];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:bodyArr options:0 error:nil];

    NSURLSessionDataTask *task = [QTSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }

        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        NSError *parseErr = nil;
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr] : nil;

        if (http && http.statusCode >= 400) {
            NSString *msg = QTHTTPErrorMessage(http, obj, @"Microsoft Übersetzung fehlgeschlagen");
            if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:(int)http.statusCode userInfo:@{NSLocalizedDescriptionKey: msg}]);
            return;
        }
        if (parseErr || ![obj isKindOfClass:[NSArray class]] || [(NSArray *)obj count] == 0) {
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
    }];
    [task resume];
}

static void QTTranslate_GoogleV2(NSString *apiKey, NSString *text, NSString *target, void (^completion)(NSString *, NSError *)) {
    if (apiKey.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:401 userInfo:@{NSLocalizedDescriptionKey:@"Google API Key fehlt"}]);
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"https://translation.googleapis.com/language/translate/v2?key=%@",
                        [apiKey stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @""];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"QT" code:402 userInfo:@{NSLocalizedDescriptionKey:@"Google URL ungültig"}]);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *payload = @{@"q": text ?: @"", @"target": target ?: @"de", @"format": @"text"};
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    NSURLSessionDataTask *task = [QTSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
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
    }];
    [task resume];
}

#pragma mark - Provider selection + fallback

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

static BOOL QTProviderIsConfigured(NSString *provider) {
    if ([provider isEqualToString:@"libre"]) return YES;
    if ([provider isEqualToString:@"deepl"]) return QTGetString(@"deeplKey", @"").length > 0;
    if ([provider isEqualToString:@"microsoft"]) return QTGetString(@"msKey", @"").length > 0;
    if ([provider isEqualToString:@"google"]) return QTGetString(@"googleKey", @"").length > 0;
    return NO;
}

static void QTTranslate_WithProvider(NSString *provider, NSString *text, NSString *target, void (^completion)(NSString *, NSError *)) {
    if ([provider isEqualToString:@"libre"]) {
        NSString *server = QTGetString(@"ltServer", @"https://translate.cutie.dating");
        NSString *key = QTGetString(@"ltApiKey", @"");
        QTTranslate_Libre(server, key, text, target, completion);
        return;
    }
    if ([provider isEqualToString:@"deepl"]) {
        NSString *key = QTGetString(@"deeplKey", @"");
        BOOL pro = QTGetBool(@"deeplPro", NO);
        NSString *tg = target.uppercaseString;
        if (tg.length == 2) tg = tg; // DE, EN, FR etc.
        QTTranslate_DeepL(key, pro, text, tg, completion);
        return;
    }
    if ([provider isEqualToString:@"microsoft"]) {
        NSString *key = QTGetString(@"msKey", @"");
        NSString *region = QTGetString(@"msRegion", @"");
        QTTranslate_MS(key, region, text, target, completion);
        return;
    }
    if ([provider isEqualToString:@"google"]) {
        NSString *key = QTGetString(@"googleKey", @"");
        QTTranslate_GoogleV2(key, text, target, completion);
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
    if (!QTProviderIsConfigured(p)) {
        QTTranslate_WithFallbacks(chain, idx + 1, text, target, completion);
        return;
    }

    QTTranslate_WithProvider(p, text, target, ^(NSString *translated, NSError *err) {
        if (translated.length) {
            if (completion) completion(translated, nil);
            return;
        }
        QTTranslate_WithFallbacks(chain, idx + 1, text, target, completion);
    });
}

#pragma mark - Main translate flow

static BOOL gQTBusy = NO;

static void QTTranslateVisibleScreen(void) {
    if (gQTBusy) return;
    if (!QTGetBool(@"enabled", YES)) return;
    gQTBusy = YES;

    NSString *target = QTGetString(@"targetLang", @"de");

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

        NSArray<NSString *> *chain = QTProviderChain();
        QTTranslate_WithFallbacks(chain, 0, trim, target, ^(NSString *translated, NSError *tErr) {
            dispatch_async(dispatch_get_main_queue(), ^{
                QTHideHUD();
                if (tErr) QTShowAlert(@"Übersetzung fehlgeschlagen", tErr.localizedDescription ?: @"Unbekannter Fehler");
                else QTShowResultPopup(translated);
            });
            gQTBusy = NO;
        });
    });
}

#pragma mark - Floating button (tap reliability)

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

@interface UIWindow (QTTapHandler)
- (void)qt_qtTap;
@end
@implementation UIWindow (QTTapHandler)
- (void)qt_qtTap { QTTranslateVisibleScreen(); }
@end

static void QTInstallFloatingButton(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    if (!QTGetBool(@"enabled", YES)) {
        UIView *old = [w viewWithTag:kQTButtonTag];
        if (old) [old removeFromSuperview];
        return;
    }

    UIButton *btn = (UIButton *)[w viewWithTag:kQTButtonTag];
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.tag = kQTButtonTag;
        [btn setTitle:@"🌐" forState:UIControlStateNormal];
        btn.frame = CGRectMake(20, 200, 52, 52);
        btn.layer.cornerRadius = 26.0;
        btn.clipsToBounds = YES;
        btn.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.92];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(qt_pan:)];
        [btn addGestureRecognizer:pan];

        // IMPORTANT: always use addTarget for reliability in all apps
        [btn addTarget:w action:@selector(qt_qtTap) forControlEvents:UIControlEventTouchUpInside];

        [w addSubview:btn];
    }

    [w bringSubviewToFront:btn];
}

%hook UIApplication
- (void)applicationDidBecomeActive:(id)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ QTInstallFloatingButton(); });
}
%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{ QTInstallFloatingButton(); });
}
