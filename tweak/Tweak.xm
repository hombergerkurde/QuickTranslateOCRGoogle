#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - Prefs

static NSString * const kQTPrefsDomain = @"com.hombergerkurde.quicktranslate";

static inline NSDictionary *QTGetPrefs(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] persistentDomainForName:kQTPrefsDomain];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

// Accept old/new keys (enabled + Enabled)
static inline BOOL QTEnabled(void) {
    NSDictionary *p = QTGetPrefs();
    id v = p[@"enabled"];
    if (!v) v = p[@"Enabled"];
    return v ? [v boolValue] : YES;
}

// Accept old/new keys (targetLang + TargetLang)
static inline NSString *QTTargetLangRaw(void) {
    NSDictionary *p = QTGetPrefs();
    id v = p[@"targetLang"];
    if (!v) v = p[@"TargetLang"];
    if ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0) return (NSString *)v;
    return @"de";
}

#pragma mark - App Filter

static inline BOOL QTIsX(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bid isEqualToString:@"com.atebits.Tweetie2"]; // X
}

#pragma mark - Window / VC Helpers

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

static void QTShowResult(NSString *translated) {
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

#pragma mark - Language Helpers (multi languages)

static NSString *QTLower(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
}

// Normalize common inputs: "de", "de-DE", "DE", "Deutsch", etc.
static NSString *QTNormalizeLang(NSString *lang) {
    NSString *l = QTLower(lang);
    if (l.length == 0) return @"de";

    // If it's like "de-DE" / "pt-BR", keep first part
    NSRange dash = [l rangeOfString:@"-"];
    if (dash.location != NSNotFound && dash.location >= 2) {
        l = [l substringToIndex:dash.location];
    }

    // Map a few names to codes (optional)
    if ([l isEqualToString:@"deutsch"] || [l isEqualToString:@"german"]) return @"de";
    if ([l isEqualToString:@"englisch"] || [l isEqualToString:@"english"]) return @"en";
    if ([l isEqualToString:@"französisch"] || [l isEqualToString:@"french"]) return @"fr";
    if ([l isEqualToString:@"spanisch"] || [l isEqualToString:@"spanish"]) return @"es";
    if ([l isEqualToString:@"italienisch"] || [l isEqualToString:@"italian"]) return @"it";
    if ([l isEqualToString:@"portugiesisch"] || [l isEqualToString:@"portuguese"]) return @"pt";
    if ([l isEqualToString:@"türkisch"] || [l isEqualToString:@"turkish"]) return @"tr";
    if ([l isEqualToString:@"arabisch"] || [l isEqualToString:@"arabic"]) return @"ar";
    if ([l isEqualToString:@"kurdisch"] || [l isEqualToString:@"kurdish"]) return @"ku";
    if ([l isEqualToString:@"russisch"] || [l isEqualToString:@"russian"]) return @"ru";
    if ([l isEqualToString:@"japanisch"] || [l isEqualToString:@"japanese"]) return @"ja";
    if ([l isEqualToString:@"koreanisch"] || [l isEqualToString:@"korean"]) return @"ko";
    if ([l isEqualToString:@"chinesisch"] || [l isEqualToString:@"chinese"]) return @"zh";

    // Basic validation: 2 letters
    if (l.length >= 2) return [l substringToIndex:2];
    return @"de";
}

static inline NSString *QTTargetLang(void) {
    return QTNormalizeLang(QTTargetLangRaw());
}

static NSString *QTDetectSourceLang(NSString *text) {
    NSString *t = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2) return @"en";

    if (@available(iOS 12.0, *)) {
        // NLLanguageRecognizer is best for iOS 12+
        Class NLLanguageRecognizer = NSClassFromString(@"NLLanguageRecognizer");
        if (NLLanguageRecognizer) {
            id rec = [[NLLanguageRecognizer alloc] init];
            if ([rec respondsToSelector:NSSelectorFromString(@"processString:")]) {
                ((void (*)(id, SEL, NSString *))objc_msgSend)(rec, NSSelectorFromString(@"processString:"), t);
            }
            if ([rec respondsToSelector:NSSelectorFromString(@"dominantLanguage")]) {
                id dom = ((id (*)(id, SEL))objc_msgSend)(rec, NSSelectorFromString(@"dominantLanguage"));
                if ([dom isKindOfClass:[NSString class]] && ((NSString *)dom).length > 0) {
                    return QTNormalizeLang((NSString *)dom);
                }
            }
        }
    }

    // Fallback
    return @"en";
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
    if (!v || depth > 20) return;
    if (!v.window || v.hidden || v.alpha < 0.01) return;

    NSString *text = nil;

    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.attributedText.string.length) text = l.attributedText.string;
        else text = l.text;
    } else if ([v isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)v;
        if (tv.attributedText.string.length) text = tv.attributedText.string;
        else text = tv.text;
    } else if ([v isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)v;
        if (tf.attributedText.string.length) text = tf.attributedText.string;
        else text = tf.text;
    }

    if (QTLooksLikeText(text)) {
        NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [out addObject:t];
    }

    for (UIView *sv in v.subviews) QTCollectText(sv, out, depth + 1);
}

static BOOL QTLooksURLEncoded(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 6) return NO;

    NSUInteger hits = 0;
    for (NSUInteger i = 0; i + 2 < s.length; i++) {
        if ([s characterAtIndex:i] == '%') {
            unichar a = [s characterAtIndex:i+1];
            unichar b = [s characterAtIndex:i+2];
            BOOL ha = ((a >= '0' && a <= '9') || (a >= 'a' && a <= 'f') || (a >= 'A' && a <= 'F'));
            BOOL hb = ((b >= '0' && b <= '9') || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F'));
            if (ha && hb) hits++;
        }
    }
    return hits >= 3;
}

static NSString *QTMaybeURLDecode(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    if (!QTLooksURLEncoded(s)) return s;

    NSString *d = [s stringByRemovingPercentEncoding];
    if ([d isKindOfClass:[NSString class]] && d.length > 0) return d;
    return s;
}

static NSString *QTBestTextFromContainer(UIView *container) {
    NSMutableArray<NSString *> *chunks = [NSMutableArray new];
    QTCollectText(container, chunks, 0);

    // Prefer NON-URL-encoded chunks first
    NSString *best = @"";
    for (NSString *s in chunks) {
        if (QTLooksURLEncoded(s)) continue;
        if (s.length > best.length) best = s;
    }
    // If we found nothing, fall back to any chunk (and decode later)
    if (best.length == 0) {
        for (NSString *s in chunks) if (s.length > best.length) best = s;
    }

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

#pragma mark - REAL translation (MyMemory - free, no API key)

static NSString *QTURLEncode(NSString *s) {
    if (!s) return @"";
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static void QTTranslateMyMemory(NSString *text) {
    NSString *trim = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) {
        QTAlert(@"QuickTranslate", @"Kein Text gefunden.");
        return;
    }

    // ✅ FIX: falls X uns URL-encoded Text gibt -> decoden
    trim = QTMaybeURLDecode(trim);

    NSString *to = QTTargetLang();
    if (to.length < 2) to = @"de";
    to = QTNormalizeLang(to);

    // ✅ MyMemory mag "auto" als source NICHT zuverlässig -> wir erkennen eine Source
    NSString *src = QTDetectSourceLang(trim);
    if (src.length < 2) src = @"en";
    src = QTNormalizeLang(src);

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
        NSDictionary *rd = dict[@"responseData"];
        NSString *translated = nil;
        if ([rd isKindOfClass:[NSDictionary class]]) translated = rd[@"translatedText"];

        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            // Falls MyMemory "AUTO invalid" o.ä. liefert, zeigen wir die "responseDetails" falls vorhanden
            NSString *details = nil;
            id det = dict[@"responseDetails"];
            if ([det isKindOfClass:[NSString class]] && ((NSString *)det).length) details = (NSString *)det;
            if (details.length) QTAlert(@"Übersetzung", details);
            else QTAlert(@"QuickTranslate", @"Übersetzung fehlgeschlagen (leer).");
            return;
        }

        QTShowResult(translated);
    }];

    [task resume];
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
    // decode check here too (so url-encoded still counts)
    t = QTMaybeURLDecode(t);
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

@interface UIButton (QTInlineTap)
- (void)qt_inlineTap;
@end
@implementation UIButton (QTInlineTap)
- (void)qt_inlineTap { QTInlineTapped((QTInlineButton *)self); }
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

    // Position: bottom-left inside the cell content
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
    // Prefs UI is handled by PreferenceLoader (plist / pref bundle).
    // Tweak reads prefs from domain: com.hombergerkurde.quicktranslate
}
