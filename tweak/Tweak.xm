#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <NaturalLanguage/NaturalLanguage.h>

static NSString * const kQTPrefsDomain = @"com.hombergerkurde.quicktranslate";

static inline NSDictionary *QTGetPrefs(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] persistentDomainForName:kQTPrefsDomain];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

static inline BOOL QTEnabled(void) {
    NSDictionary *p = QTGetPrefs();
    id v = p[@"enabled"];
    if (!v) v = p[@"Enabled"];
    return v ? [v boolValue] : YES;
}

static inline NSString *QTTargetLang(void) {
    NSDictionary *p = QTGetPrefs();
    id v = p[@"targetLang"];
    if (!v) v = p[@"TargetLang"];
    if ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0) return (NSString *)v;
    return @"de"; // default
}

static inline BOOL QTIsX(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bid isEqualToString:@"com.atebits.Tweetie2"];
}

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
    }
    return nil;
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

static NSString *QTDecodeHTML(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return s ?: @"";
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return s;

    NSDictionary *opt = @{
        NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType,
        NSCharacterEncodingDocumentAttribute: @(NSUTF8StringEncoding)
    };
    NSAttributedString *attr = [[NSAttributedString alloc] initWithData:data options:opt documentAttributes:nil error:nil];
    return attr.string ?: s;
}

static NSString *QTDecodeWeird(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return s ?: @"";
    // 1) Percent decode (fixes %D9%83...)
    NSString *p = [s stringByRemovingPercentEncoding];
    if (!p) p = s;
    // 2) HTML entities decode
    p = QTDecodeHTML(p);
    // 3) Trim
    p = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return p;
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

#pragma mark - Language detect (SRC) + normalize

static NSString *QTNormalizeLang(NSString *code) {
    if (![code isKindOfClass:[NSString class]] || code.length == 0) return @"en";
    NSString *c = [code lowercaseString];

    // NaturalLanguage can return "und"
    if ([c isEqualToString:@"und"]) return @"en";

    // keep only primary subtag (e.g. "zh-Hans" -> "zh")
    NSArray *parts = [c componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]];
    NSString *p0 = parts.count ? parts[0] : c;
    if (p0.length >= 2) return [p0 substringToIndex:2];
    return @"en";
}

static NSString *QTDetectSourceLang(NSString *text) {
    NSString *t = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2) return @"en";

    if (@available(iOS 12.0, *)) {
        NLLanguageRecognizer *rec = [NLLanguageRecognizer new];
        [rec processString:t];
        NSString *dom = rec.dominantLanguage;
        if ([dom isKindOfClass:[NSString class]] && dom.length > 0) {
            return QTNormalizeLang(dom);
        }
    }
    return @"en";
}

#pragma mark - UI Result

static void QTShowResult(NSString *translated) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = QTGetKeyWindow();
        if (!w) return;
        UIViewController *top = QTTopVC(w.rootViewController);
        if (!top) return;

        NSString *msg = translated.length ? translated : @"(leer)";
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Übersetzung"
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];

        [ac addAction:[UIAlertAction actionWithTitle:@"Kopieren"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
            if (msg.length) UIPasteboard.generalPasteboard.string = msg;
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"Schließen" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

#pragma mark - MyMemory translate (no key)

static void QTTranslateMyMemory(NSString *text) {
    NSString *trim = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) {
        QTAlert(@"QuickTranslate", @"Kein Text gefunden.");
        return;
    }

    NSString *to = QTNormalizeLang(QTTargetLang());
    if (to.length < 2) to = @"de";

    NSString *src = QTDetectSourceLang(trim);
    if ([src isEqualToString:to]) src = @"en"; // avoid same-lang issues

    NSURLComponents *c = [NSURLComponents componentsWithString:@"https://api.mymemory.translated.net/get"];
    c.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:trim],
        [NSURLQueryItem queryItemWithName:@"langpair" value:[NSString stringWithFormat:@"%@|%@", src, to]]
    ];

    NSURL *url = c.URL;
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

        // Primary path
        NSString *translated = nil;
        NSDictionary *rd = dict[@"responseData"];
        if ([rd isKindOfClass:[NSDictionary class]]) {
            id tt = rd[@"translatedText"];
            if ([tt isKindOfClass:[NSString class]]) translated = (NSString *)tt;
        }

        // Fallback path (sometimes in matches)
        if (translated.length == 0) {
            NSArray *matches = dict[@"matches"];
            if ([matches isKindOfClass:[NSArray class]] && matches.count) {
                id m0 = matches.firstObject;
                if ([m0 isKindOfClass:[NSDictionary class]]) {
                    id t2 = ((NSDictionary *)m0)[@"translation"];
                    if ([t2 isKindOfClass:[NSString class]]) translated = (NSString *)t2;
                }
            }
        }

        translated = QTDecodeWeird(translated);

        if (translated.length == 0) {
            QTAlert(@"QuickTranslate", @"Übersetzung fehlgeschlagen (leer).");
            return;
        }

        QTShowResult(translated);
    }];

    [task resume];
}

#pragma mark - Inline globe button on X cells

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
    return (t.length >= 10);
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
    // Preferences via PreferenceLoader; tweak reads NSUserDefaults domain.
}
