\
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const kQTPrefsDomain = @"com.hombergerkurde.quicktranslate";

static inline NSDictionary *QTGetPrefs(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] persistentDomainForName:kQTPrefsDomain];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}
static inline BOOL QTEnabled(void) {
    id v = QTGetPrefs()[@"enabled"];
    return v ? [v boolValue] : YES;
}
static inline NSString *QTTargetLang(void) {
    id v = QTGetPrefs()[@"targetLang"];
    if ([v isKindOfClass:[NSString class]] && [((NSString*)v) length] > 0) return (NSString*)v;
    return @"de";
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
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopVC(w.rootViewController);
    if (!top) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:(title ?: @"")
                                                                message:(msg ?: @"")
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Extract text from a post cell (generic)

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

#pragma mark - Apple "system translate" UI (Share Sheet)

static void QTPresentSystemTranslateUI(NSString *text) {
    NSString *trim = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) {
        QTAlert(@"QuickTranslate", @"Kein Text gefunden.");
        return;
    }

    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopVC(w.rootViewController);
    if (!top) return;

    // NOTE:
    // On iOS 17, Apple’s official Translation.framework is primarily Swift/SwiftUI and (per Apple docs) iOS 17.4+.
    // This tweak uses the built-in system “Übersetzen/Translate” action inside the share sheet (free, no API key).
    // The user picks “Übersetzen” there.
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[trim] applicationActivities:nil];

    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = top.view;
        avc.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width/2.0, top.view.safeAreaInsets.top + 40.0, 1, 1);
    }

    [top presentViewController:avc animated:YES completion:nil];

    // Small hint for target language (doesn't force it, but helps)
    NSString *hint = [NSString stringWithFormat:@"Zielsprache: %@", QTTargetLang()];
    (void)hint;
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

static void QTInlineTapped(QTInlineButton *btn) {
    if (!QTEnabled()) return;
    UIView *cell = QTFindHostCell(btn);
    UIView *content = QTCellContent(cell);
    if (!content) return;
    NSString *text = QTBestTextFromContainer(content);
    QTPresentSystemTranslateUI(text);
}

@interface UIButton (QTInlineTap)
- (void)qt_inlineTap;
@end
@implementation UIButton (QTInlineTap)
- (void)qt_inlineTap { QTInlineTapped((QTInlineButton *)self); }
@end

static BOOL QTShouldAttachToContent(UIView *contentView) {
    if (!contentView || !contentView.window) return NO;
    if (contentView.hidden || contentView.alpha < 0.01) return NO;
    if (contentView.bounds.size.height < 80) return NO;
    NSString *t = QTBestTextFromContainer(contentView);
    return (t.length >= 15);
}

static void QTEnsureInlineButton(UIView *contentView) {
    if (!QTIsX()) return;
    if (!QTEnabled()) return;

    QTInlineButton *btn = objc_getAssociatedObject(contentView, &kQTInlineBtnKey);

    if (!QTShouldAttachToContent(contentView)) {
        if (btn) { [btn removeFromSuperview]; objc_setAssociatedObject(contentView, &kQTInlineBtnKey, nil, OBJC_ASSOCIATION_ASSIGN); }
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
    // Settings/UI provided via PreferenceLoader simple approach.
}
