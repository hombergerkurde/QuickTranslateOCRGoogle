// QuickTranslate - X inline translate button (iOS 17)
// Uses free MyMemory API (no key). Adds language detection + better text extraction.
// IMPORTANT: this file is self-contained; just replace your tweak/Tweak.xm with it.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// Fix for clang modules builds that complain about objc_getAssociatedObject visibility:
@import ObjectiveC.runtime;

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
static inline NSString *QTTargetLang(void) {
    NSDictionary *p = QTGetPrefs();
    id v = p[@"targetLang"];
    if (!v) v = p[@"TargetLang"];
    if ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0) return (NSString *)v;
    return @"de"; // default: German
}

static inline BOOL QTIsX(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bid isEqualToString:@"com.atebits.Tweetie2"]; // X
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
            if (msg.length) UIPasteboard.generalPasteboard.string = msg;
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"Schließen" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

#pragma mark - Text extraction (better for X)

static BOOL QTLooksLikeText(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2) return NO;
    if ([t rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound) return NO;
    return YES;
}

static BOOL QTLooksLikeJunk(NSString *t) {
    if (!t) return YES;
    NSString *s = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return YES;

    // Ignore usernames/handles and tiny UI strings
    if ([s hasPrefix:@"@"] && s.length <= 30) return YES;
    if (s.length <= 3) return YES;

    // Ignore pure numbers / counters like "1h", "12h", "3", "25K"
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    BOOL onlyAlnum = ([[s stringByTrimmingCharactersInSet:alnum] length] == 0);
    if (onlyAlnum) {
        // If it’s mostly digits + maybe K/M + h, ignore
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+([.,][0-9]+)?(K|M)?(h)?$" options:NSRegularExpressionCaseInsensitive error:nil];
        if ([re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)]) return YES;
    }

    // Ignore very common buttons/labels
    NSArray *bad = @[@"Folgen", @"Folge ich", @"Mehr anzeigen", @"Posten", @"Antworten", @"Teilen"];
    for (NSString *b in bad) {
        if ([s caseInsensitiveCompare:b] == NSOrderedSame) return YES;
    }
    return NO;
}

static void QTCollectTextDeep(UIView *v, NSMutableArray<NSString *> *out, NSInteger depth) {
    if (!v || depth > 22) return;
    if (!v.window || v.hidden || v.alpha < 0.01) return;

    NSString *text = nil;
    if ([v isKindOfClass:[UILabel class]]) text = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UITextView class]]) text = ((UITextView *)v).text;
    else if ([v isKindOfClass:[UITextField class]]) text = ((UITextField *)v).text;

    if (QTLooksLikeText(text)) {
        NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length && !QTLooksLikeJunk(t)) [out addObject:t];
    }

    for (UIView *sv in v.subviews) QTCollectTextDeep(sv, out, depth + 1);
}

static NSString *QTBestTextFromCell(UIView *cell) {
    if (!cell) return @"";

    NSMutableArray<NSString *> *chunks = [NSMutableArray new];

    // Search in the entire cell (NOT only contentView) because X sometimes keeps text outside contentView.
    QTCollectTextDeep(cell, chunks, 0);

    // Deduplicate while keeping order
    NSMutableOrderedSet<NSString *> *uniq = [NSMutableOrderedSet orderedSetWithArray:chunks];
    NSArray<NSString *> *u = [uniq array];

    // Score candidates
    NSString *best = @"";
    NSInteger bestScore = -999999;

    for (NSString *s in u) {
        NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (QTLooksLikeJunk(t)) continue;

        NSInteger score = (NSInteger)t.length;

        // Prefer multi-line / sentence-like text (the tweet body)
        if ([t rangeOfString:@"\n"].location != NSNotFound) score += 80;
        if ([t rangeOfString:@" "].location != NSNotFound) score += 40;

        // Penalize very short pieces (names/handles)
        if (t.length < 25) score -= 60;

        // Prefer text with punctuation or Arabic/Hebrew etc.
        if ([t rangeOfCharacterFromSet:[NSCharacterSet punctuationCharacterSet]].location != NSNotFound) score += 20;

        if (score > bestScore) { bestScore = score; best = t; }
    }

    // If we didn’t find a strong single block, join the top few
    if (best.length < 40 && u.count > 1) {
        NSMutableArray<NSString *> *sorted = [u mutableCopy];
        [sorted sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return (a.length > b.length) ? NSOrderedAscending : NSOrderedDescending;
        }];

        NSMutableArray<NSString *> *take = [NSMutableArray new];
        for (NSString *s in sorted) {
            NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (QTLooksLikeJunk(t)) continue;
            if (t.length < 10) continue;
            [take addObject:t];
            if (take.count >= 3) break;
        }
        NSString *joined = [take componentsJoinedByString:@"\n\n"];
        if (joined.length > best.length) best = joined;
    }

    best = [best stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (best.length > 2400) best = [best substringToIndex:2400];
    return best ?: @"";
}

#pragma mark - Language detection (built-in, no private APIs)

static NSString *QTMapLang(NSString *lang) {
    if (![lang isKindOfClass:[NSString class]] || lang.length == 0) return nil;

    // NSLinguisticTagger can return tags like "zh-Hans" -> map to "zh-CN"
    if ([lang hasPrefix:@"zh"]) return @"zh-CN";
    if ([lang hasPrefix:@"pt"]) return @"pt-PT"; // MyMemory accepts pt-PT / pt-BR (good enough)
    if ([lang hasPrefix:@"nb"] || [lang hasPrefix:@"no"]) return @"no";
    if ([lang hasPrefix:@"und"]) return nil;

    // Use first 2 letters when possible (e.g. "ar", "fa", "de", "en")
    if (lang.length >= 2) return [[lang substringToIndex:2] lowercaseString];
    return [lang lowercaseString];
}

static NSString *QTDetectLang(NSString *text) {
    NSString *t = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return nil;

    // NSLinguisticTagger language detection
    NSLinguisticTagger *tagger = [[NSLinguisticTagger alloc] initWithTagSchemes:@[NSLinguisticTagSchemeLanguage] options:0];
    tagger.string = t;

    NSString *lang = [tagger dominantLanguage];
    return QTMapLang(lang);
}

#pragma mark - REAL translation (MyMemory - free, no API key)

static NSString *QTURLEncode(NSString *s) {
    if (!s) return @"";
    // Encode everything unsafe in query. (Important: keep it single-pass only)
    NSCharacterSet *allowed = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"] invertedSet];
    // The above is inverted; we want allowed = unreserved, but easiest is using URLQueryAllowed then fixing '+'/'&' etc.
    // We'll do a safe approach using NSURLComponents instead in the request builder.
    return [s stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
}

static void QTTranslateMyMemory(NSString *text) {
    NSString *trim = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) {
        QTAlert(@"QuickTranslate", @"Kein Text gefunden.");
        return;
    }

    NSString *to = QTTargetLang();
    if (to.length < 2) to = @"de";

    NSString *from = QTDetectLang(trim);
    if (!from) from = @"en"; // fallback

    // Build URL using NSURLComponents to avoid double-encoding issues
    NSURLComponents *c = [NSURLComponents componentsWithString:@"https://api.mymemory.translated.net/get"];
    if (!c) { QTAlert(@"QuickTranslate", @"Ungültige URL."); return; }

    c.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:trim],
        [NSURLQueryItem queryItemWithName:@"langpair" value:[NSString stringWithFormat:@"%@|%@", from, to]]
    ];

    NSURL *url = c.URL;
    if (!url) { QTAlert(@"QuickTranslate", @"Ungültige URL."); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"QuickTranslate/1.0 (iOS)" forHTTPHeaderField:@"User-Agent"];

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

        // MyMemory returns "responseData": {"translatedText": "..."}
        NSDictionary *rd = dict[@"responseData"];
        NSString *translated = ([rd isKindOfClass:[NSDictionary class]] ? rd[@"translatedText"] : nil);

        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            // If there is a message field, show it
            NSString *msg = nil;
            id ms = dict[@"responseDetails"];
            if ([ms isKindOfClass:[NSString class]] && ((NSString *)ms).length) msg = (NSString *)ms;
            QTAlert(@"QuickTranslate", msg ?: @"Übersetzung fehlgeschlagen (leer).");
            return;
        }

        // Safety: if API ever returns percent-escaped text, decode once
        NSString *decoded = [translated stringByRemovingPercentEncoding];
        if (decoded && decoded.length >= 2) translated = decoded;

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

static UIView *QTFindHostCell(UIView *v) {
    UIView *cur = v;
    while (cur) {
        if ([cur isKindOfClass:[UITableViewCell class]] || [cur isKindOfClass:[UICollectionViewCell class]]) return cur;
        cur = cur.superview;
    }
    return nil;
}

static BOOL QTShouldAttachToCell(UIView *cell) {
    if (!cell || !cell.window) return NO;
    if (cell.hidden || cell.alpha < 0.01) return NO;
    if (cell.bounds.size.height < 90) return NO;

    NSString *t = QTBestTextFromCell(cell);
    return (t.length >= 25);
}

static void QTInlineTapped(QTInlineButton *btn) {
    if (!QTEnabled()) return;

    UIView *cell = QTFindHostCell(btn);
    if (!cell) return;

    NSString *text = QTBestTextFromCell(cell);
    if (text.length == 0) {
        QTAlert(@"QuickTranslate", @"Kein Text gefunden.");
        return;
    }
    QTTranslateMyMemory(text);
}

@interface UIButton (QTInlineTap)
- (void)qt_inlineTap;
@end
@implementation UIButton (QTInlineTap)
- (void)qt_inlineTap { QTInlineTapped((QTInlineButton *)self); }
@end

static void QTEnsureInlineButton(UIView *cellOrContent) {
    if (!QTIsX()) return;
    if (!QTEnabled()) return;

    UIView *cell = cellOrContent;
    if (![cell isKindOfClass:[UITableViewCell class]] && ![cell isKindOfClass:[UICollectionViewCell class]]) {
        cell = QTFindHostCell(cellOrContent);
    }
    if (!cell) return;

    QTInlineButton *btn = (QTInlineButton *)objc_getAssociatedObject(cell, &kQTInlineBtnKey);

    if (!QTShouldAttachToCell(cell)) {
        if (btn) {
            [btn removeFromSuperview];
            objc_setAssociatedObject(cell, &kQTInlineBtnKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        return;
    }

    if (!btn) {
        btn = [QTInlineButton buttonWithType:UIButtonTypeSystem];
        btn.qt_container = cell;
        QTConfigureGlobe(btn);
        [btn addTarget:btn action:@selector(qt_inlineTap) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(cell, &kQTInlineBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell addSubview:btn];
    }

    // Place it bottom-left of the cell (looks similar to Translomatic style)
    CGFloat size = 30.0;
    CGFloat x = 10.0;
    CGFloat y = MAX(8.0, cell.bounds.size.height - size - 10.0);
    btn.frame = CGRectMake(x, y, size, size);
    [cell bringSubviewToFront:btn];
}

%hook UITableViewCell
- (void)layoutSubviews {
    %orig;
    if (!QTIsX()) return;
    QTEnsureInlineButton(self);
}
%end

%hook UICollectionViewCell
- (void)layoutSubviews {
    %orig;
    if (!QTIsX()) return;
    QTEnsureInlineButton(self);
}
%end

%ctor {
    // prefs are read directly from domain; PreferenceLoader bundle can exist separately.
}
