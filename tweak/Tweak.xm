#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#if __has_include(<NaturalLanguage/NaturalLanguage.h>)
#import <NaturalLanguage/NaturalLanguage.h>
#define QT_HAS_NL 1
#else
#define QT_HAS_NL 0
#endif

static NSString * const kQTPrefsDomain = @"com.hombergerkurde.quicktranslate";

static inline NSDictionary *QTGetPrefs(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] persistentDomainForName:kQTPrefsDomain];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

static inline void QTSetPref(id value, NSString *key) {
    if (!key.length) return;
    NSMutableDictionary *m = [QTGetPrefs() mutableCopy];
    if (!m) m = [NSMutableDictionary new];
    if (value) m[key] = value;
    else [m removeObjectForKey:key];
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:m forName:kQTPrefsDomain];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Accept old/new keys (enabled + Enabled)
static inline BOOL QTEnabled(void) {
    NSDictionary *p = QTGetPrefs();
    id v = p[@"enabled"];
    if (!v) v = p[@"Enabled"];
    return v ? [v boolValue] : YES;
}

// Accept old/new keys (targetLang + TargetLang)
static inline NSString *QTTargetLang(void) {
    NSDictionary *p = QTGetPrefs();
    id v = p[@"targetLang"];
    if (!v) v = p[@"TargetLang"];
    if ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0) return (NSString *)v;
    return @"de";
}

static inline BOOL QTIsX(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bid isEqualToString:@"com.atebits.Tweetie2"]; // X
}

static UIWindow *QTGetKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;

    // iOS 13+ (no deprecated keyWindow usage)
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

    // Pre iOS 13 fallback
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

static void QTAlert(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = QTGetKeyWindow();
        if (!w) return;
        UIViewController *top = QTTopVC(w.rootViewController);
        if (!top) return;

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:(title ?: @"")
                                                                    message:(msg ?: @"")
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

static void QTShowResult(NSString *original, NSString *translated) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = QTGetKeyWindow();
        if (!w) return;
        UIViewController *top = QTTopVC(w.rootViewController);
        if (!top) return;

        NSString *msg = translated ?: @"(leer)";
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Übersetzung"
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];

        [ac addAction:[UIAlertAction actionWithTitle:@"Kopieren"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
            if (translated.length) UIPasteboard.generalPasteboard.string = translated;
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"Schließen" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

#pragma mark - Text extraction

static BOOL QTLooksLikeText(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2) return NO;
    if ([t rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound) return NO;
    return YES;
}

static void QTCollectText(UIView *v, NSMutableArray<NSString *> *out, NSInteger depth) {
    if (!v || depth > 18) return;
    if (!v.window || v.hidden || v.alpha < 0.01) return;

    NSString *text = nil;
    if ([v isKindOfClass:[UILabel class]]) text = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UITextView class]]) text = ((UITextView *)v).text;
    else if ([v isKindOfClass:[UITextField class]]) text = ((UITextField *)v).text;

    if (QTLooksLikeText(text)) {
        NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [out addObject:t];
    }

    for (UIView *sv in v.subviews) QTCollectText(sv, out, depth + 1);
}

static NSString *QTBestTextFromContainer(UIView *container) {
    NSMutableArray<NSString *> *chunks = [NSMutableArray new];
    QTCollectText(container, chunks, 0);

    NSString *best = @"";
    for (NSString *s in chunks) if (s.length > best.length) best = s;

    if (best.length < 20 && chunks.count > 1) {
        NSMutableOrderedSet<NSString *> *uniq = [NSMutableOrderedSet orderedSetWithArray:chunks];
        NSString *joined = [[uniq array] componentsJoinedByString:@"\n"];
        joined = [joined stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (joined.length > best.length) best = joined;
    }

    best = [best stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (best.length > 2000) best = [best substringToIndex:2000];
    return best;
}

#pragma mark - Language detection (fixes "AUTO invalid source")

static NSString *QTNormalizeLang(NSString *code) {
    if (![code isKindOfClass:[NSString class]] || code.length == 0) return @"en";
    NSString *c = [code lowercaseString];

    // Some Apple codes can be like "zh-Hans" / "zh-Hant"
    if ([c hasPrefix:@"zh"]) return @"zh";
    if ([c hasPrefix:@"pt"]) return @"pt";
    if ([c hasPrefix:@"iw"]) return @"he"; // old Hebrew
    if ([c hasPrefix:@"ji"]) return @"yi";
    if ([c hasPrefix:@"in"]) return @"id";

    // Keep only first 2 letters when possible
    if (c.length >= 2) c = [c substringToIndex:2];
    return c;
}

static NSString *QTDetectSourceLang(NSString *text) {
    NSString *t = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2) return @"en";

#if QT_HAS_NL
    if (@available(iOS 12.0, *)) {
        NLLanguageRecognizer *rec = [[NLLanguageRecognizer alloc] init];
        [rec processString:t];
        NLLanguage lang = rec.dominantLanguage;
        if (lang) return QTNormalizeLang((NSString *)lang);
    }
#endif

    // Fallback: very simple heuristic
    // If contains Arabic script -> ar
    NSRange rAr = [t rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:
                                              @"ابتثجحخدذرزسشصضطظعغفقكلمنهويآأإؤئىة"]];
    if (rAr.location != NSNotFound) return @"ar";

    return @"en";
}

#pragma mark - REAL translation (MyMemory - free, no API key)

static NSString *QTURLEncode(NSString *s) {
    if (!s) return @"";
    // URLQueryAllowedCharacterSet still allows some reserved characters -> remove them
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&=?+/"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static void QTTranslateMyMemory(NSString *text) {
    NSString *trim = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) {
        QTAlert(@"QuickTranslate", @"Kein Text gefunden.");
        return;
    }

    NSString *to = QTTargetLang();
    if (to.length < 2) to = @"de";
    to = QTNormalizeLang(to);

    NSString *src = QTDetectSourceLang(trim);
    if (src.length < 2) src = @"en";

    // MyMemory requires 2-letter ISO or RFC3066. We send "src|to" (NO auto).
    NSString *q = QTURLEncode(trim);
    NSString *urlStr = [NSString stringWithFormat:
                        @"https://api.mymemory.translated.net/get?q=%@&langpair=%@|%@",
                        q, QTURLEncode(src), QTURLEncode(to)];

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        QTAlert(@"QuickTranslate", @"Ungültige URL.");
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 12.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task =
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {

        if (err || !data) {
            QTAlert(@"QuickTranslate", @"Übersetzung fehlgeschlagen (Netzwerk).");
            return;
        }

        NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
        if ([h isKindOfClass:[NSHTTPURLResponse class]] && (h.statusCode < 200 || h.statusCode >= 300)) {
            QTAlert(@"QuickTranslate", [NSString stringWithFormat:@"Übersetzung fehlgeschlagen (HTTP %ld).", (long)h.statusCode]);
            return;
        }

        NSError *jerr = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jerr];
        if (jerr || ![json isKindOfClass:[NSDictionary class]]) {
            QTAlert(@"QuickTranslate", @"Übersetzung fehlgeschlagen (JSON).");
            return;
        }

        NSDictionary *dict = (NSDictionary *)json;

        // If MyMemory returns an error string in responseData, show it (helps debugging)
        NSDictionary *rd = dict[@"responseData"];
        NSString *translated = nil;
        if ([rd isKindOfClass:[NSDictionary class]]) translated = rd[@"translatedText"];

        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            id msg = dict[@"responseDetails"];
            if ([msg isKindOfClass:[NSString class]] && [msg length] > 0) {
                QTAlert(@"Übersetzung", (NSString *)msg);
            } else {
                QTAlert(@"QuickTranslate", @"Übersetzung fehlgeschlagen (leer).");
            }
            return;
        }

        QTShowResult(trim, translated);
    }];

    [task resume];
}

#pragma mark - Long press language picker

static NSArray<NSDictionary *> *QTLanguages(void) {
    // Add as many as you want; German must stay
    return @[
        @{@"code":@"de", @"name":@"Deutsch"},
        @{@"code":@"en", @"name":@"English"},
        @{@"code":@"tr", @"name":@"Türkisch"},
        @{@"code":@"ar", @"name":@"Arabisch"},
        @{@"code":@"ku", @"name":@"Kurdisch"},
        @{@"code":@"fa", @"name":@"Persisch"},
        @{@"code":@"ru", @"name":@"Russisch"},
        @{@"code":@"fr", @"name":@"Französisch"},
        @{@"code":@"es", @"name":@"Spanisch"},
        @{@"code":@"it", @"name":@"Italienisch"}
    ];
}

static void QTPresentLanguagePicker(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = QTGetKeyWindow();
        if (!w) return;
        UIViewController *top = QTTopVC(w.rootViewController);
        if (!top) return;

        NSString *current = QTTargetLang();
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Zielsprache"
                                                                    message:@"Wähle die Sprache für die Übersetzung"
                                                             preferredStyle:UIAlertControllerStyleActionSheet];

        for (NSDictionary *l in QTLanguages()) {
            NSString *code = l[@"code"];
            NSString *name = l[@"name"];
            if (![code isKindOfClass:[NSString class]] || ![name isKindOfClass:[NSString class]]) continue;

            NSString *title = [NSString stringWithFormat:@"%@ (%@)%@", name, code, [code isEqualToString:current] ? @" ✓" : @""];
            [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                QTSetPref(code, @"targetLang");
            }]];
        }

        [ac addAction:[UIAlertAction actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];

        if (ac.popoverPresentationController) {
            ac.popoverPresentationController.sourceView = top.view;
            ac.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width/2.0, top.view.safeAreaInsets.top + 40.0, 1, 1);
        }

        [top presentViewController:ac animated:YES completion:nil];
    });
}

#pragma mark - Inline globe button on X post cells

static char kQTInlineBtnKey;

@interface QTInlineButton : UIButton
@property (nonatomic, weak) UIView *qt_container;
@end
@implementation QTInlineButton @end

static void QTConfigureGlobe(QTInlineButton *btn) {
    btn.exclusiveTouch = YES;

    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        cfg.baseForegroundColor = UIColor.systemBlueColor;
        cfg.baseBackgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.85];
        cfg.image = [UIImage systemImageNamed:@"globe"];
        btn.configuration = cfg;
    } else if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *sc = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:@"globe" withConfiguration:sc];
        [btn setImage:img forState:UIControlStateNormal];
        btn.tintColor = UIColor.systemBlueColor;
        btn.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.85];
        btn.layer.cornerRadius = 14.0;
        btn.clipsToBounds = YES;
    } else {
        [btn setTitle:@"🌐" forState:UIControlStateNormal];
    }

    // long press = language picker
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:btn action:@selector(qt_longPress:)];
    lp.minimumPressDuration = 0.35;
    [btn addGestureRecognizer:lp];
}

static UIView *QTCellContent(UIView *cell) {
    if ([cell isKindOfClass:[UITableViewCell class]]) return ((UITableViewCell *)cell).contentView;
    if ([cell isKindOfClass:[UICollectionViewCell class]]) return ((UICollectionViewCell *)cell).contentView;
    return nil;
}

static UIView *QTFindHostCell(UIView *v) {
    UIView *cur = v;
    while (cur) {
        if ([cur isKindOfClass:[UITableViewCell class]] || [cur isKindOfClass:[UICollectionViewCell class]]) return cur;
        cur = cur.superview;
    }
    return nil;
}

static BOOL QTShouldAttachToContent(UIView *contentView) {
    if (!contentView || !contentView.window) return NO;
    if (contentView.hidden || contentView.alpha < 0.01) return NO;
    if (contentView.bounds.size.height < 80) return NO;

    NSString *t = QTBestTextFromContainer(contentView);
    return (t.length >= 15);
}

static void QTInlineTapped(QTInlineButton *btn) {
    if (!QTEnabled()) return;

    UIView *cell = QTFindHostCell(btn);
    UIView *content = QTCellContent(cell);
    if (!content) return;

    NSString *text = QTBestTextFromContainer(content);
    QTTranslateMyMemory(text);
}

@interface QTInlineButton (QTHandlers)
- (void)qt_inlineTap;
- (void)qt_longPress:(UILongPressGestureRecognizer *)gr;
@end

@implementation QTInlineButton (QTHandlers)
- (void)qt_inlineTap { QTInlineTapped((QTInlineButton *)self); }
- (void)qt_longPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        QTPresentLanguagePicker();
    }
}
@end

static void QTEnsureInlineButton(UIView *contentView) {
    if (!QTIsX()) return;
    if (!QTEnabled()) return;

    QTInlineButton *btn = objc_getAssociatedObject(contentView, &kQTInlineBtnKey);

    if (!QTShouldAttachToContent(contentView)) {
        if (btn) {
            [btn removeFromSuperview];
            objc_setAssociatedObject(contentView, &kQTInlineBtnKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        return;
    }

    if (!btn) {
        btn = [QTInlineButton buttonWithType:UIButtonTypeSystem];
        btn.qt_container = contentView;
        QTConfigureGlobe(btn);
        [btn addTarget:btn action:@selector(qt_inlineTap) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(contentView, &kQTInlineBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [contentView addSubview:btn];
    }

    CGFloat size = 28.0;
    CGFloat x = 10.0;
    CGFloat y = MAX(8.0, contentView.bounds.size.height - size - 8.0);
    btn.frame = CGRectMake(x, y, size, size);
    [contentView bringSubviewToFront:btn];
}

%hook UITableViewCell
- (void)layoutSubviews {
    %orig;
    if (!QTIsX()) return;
    QTEnsureInlineButton(self.contentView);
}
%end

%hook UICollectionViewCell
- (void)layoutSubviews {
    %orig;
    if (!QTIsX()) return;
    QTEnsureInlineButton(self.contentView);
}
%end

%ctor {
    // Settings handled by PreferenceLoader; tweak reads prefs domain directly.
}
