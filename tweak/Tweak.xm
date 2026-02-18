#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

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
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return QTTopVC(((UINavigationController *)vc).topViewController);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        return QTTopVC(((UITabBarController *)vc).selectedViewController);
    }
    return vc;
}

static void QTShowAlert(NSString *title, NSString *msg) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopVC(w.rootViewController);
    if (!top) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

static NSInteger QTCountControls(UIView *v) {
    NSInteger c = 0;
    for (UIView *s in v.subviews) if ([s isKindOfClass:[UIControl class]]) c++;
    return c;
}

static NSInteger QTCountButtonsDeep(UIView *v, NSInteger depth) {
    if (!v || depth > 8) return 0;
    NSInteger c = 0;
    if ([v isKindOfClass:[UIButton class]] || [v isKindOfClass:[UIControl class]]) c++;
    for (UIView *s in v.subviews) c += QTCountButtonsDeep(s, depth + 1);
    return c;
}

static BOOL QTPointInsideViewInWindow(UIView *v, CGPoint p, UIWindow *w) {
    if (!v || !w) return NO;
    if (v.hidden || v.alpha < 0.01) return NO;
    CGRect r = [v convertRect:v.bounds toView:w];
    return CGRectContainsPoint(r, p);
}

static void QTCollectViewsAtPoint(UIView *root, CGPoint p, UIWindow *w, NSMutableArray<UIView *> *out, NSInteger depth) {
    if (!root || depth > 40) return;
    if (root.hidden || root.alpha < 0.01) return;

    // traverse front-to-back: subviews last are on top
    for (UIView *sv in [root.subviews reverseObjectEnumerator]) {
        QTCollectViewsAtPoint(sv, p, w, out, depth + 1);
    }

    if (QTPointInsideViewInWindow(root, p, w)) {
        [out addObject:root];
    }
}

static NSInteger QTScoreActionBar(UIView *v, UIWindow *w, CGPoint p) {
    // Higher score = more likely action bar
    if (!v || !w) return -9999;

    CGRect r = [v convertRect:v.bounds toView:w];
    if (!CGRectContainsPoint(r, p)) return -9999;

    CGFloat area = r.size.width * r.size.height;
    if (area < 2000 || area > 200000) return -9999;

    NSInteger directControls = QTCountControls(v);
    NSInteger deepButtons = QTCountButtonsDeep(v, 0);

    NSInteger score = 0;

    // Typical action row has some controls/buttons
    score += MIN(directControls, 10) * 30;
    score += MIN(deepButtons, 20) * 8;

    // height preference ~ 30-80
    if (r.size.height >= 25 && r.size.height <= 90) score += 40;
    else if (r.size.height < 20) score -= 20;
    else if (r.size.height > 120) score -= 30;

    // width preference large
    if (r.size.width > 240) score += 30;

    // prefer views that actually have subviews
    if (v.subviews.count == 0) score -= 80;

    // prefer view closer to tap (center distance)
    CGFloat cx = CGRectGetMidX(r), cy = CGRectGetMidY(r);
    CGFloat dx = cx - p.x, dy = cy - p.y;
    CGFloat dist = sqrt(dx*dx + dy*dy);
    score += (NSInteger)MAX(0, 60 - dist);

    return score;
}

static NSString *QTChain(UIView *v, NSInteger max) {
    NSMutableArray<NSString *> *arr = [NSMutableArray array];
    UIView *cur = v;
    NSInteger i = 0;
    while (cur && i < max) {
        [arr addObject:NSStringFromClass(cur.class)];
        cur = cur.superview;
        i++;
    }
    return [arr componentsJoinedByString:@" -> "];
}

static NSString *QTDescribe(UIView *v, UIWindow *w, CGPoint p) {
    if (!v) return @"(nil)";
    CGRect r = [v convertRect:v.bounds toView:w];
    NSString *cls = NSStringFromClass(v.class);
    NSString *sup = v.superview ? NSStringFromClass(v.superview.class) : @"(nil)";
    NSString *ax = v.accessibilityIdentifier ?: @"";
    NSInteger dc = QTCountControls(v);
    NSInteger db = QTCountButtonsDeep(v, 0);
    NSInteger score = QTScoreActionBar(v, w, p);
    return [NSString stringWithFormat:@"view=%@\nsuper=%@\naxid=%@\nwinFrame={{%.1f,%.1f},{%.1f,%.1f}}\nsubviews=%lu\ndirectControls=%ld\ndeepButtons=%ld\nscore=%ld\nchain=%@",
            cls, sup, ax, r.origin.x, r.origin.y, r.size.width, r.size.height,
            (unsigned long)v.subviews.count,
            (long)dc, (long)db, (long)score, QTChain(v, 10)];
}

@interface QTDBGPicker : NSObject
@property (nonatomic, strong) UITapGestureRecognizer *tripleTap;
@end

@implementation QTDBGPicker

- (instancetype)init {
    self = [super init];
    if (self) {
        self.tripleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
        self.tripleTap.numberOfTapsRequired = 3;
        self.tripleTap.cancelsTouchesInView = NO;
    }
    return self;
}

- (void)attach {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    for (UIGestureRecognizer *g in w.gestureRecognizers ?: @[]) {
        if (g == self.tripleTap) return;
    }
    [w addGestureRecognizer:self.tripleTap];
}

- (void)onTap:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateRecognized) return;

    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    CGPoint p = [gr locationInView:w];

    NSMutableArray<UIView *> *views = [NSMutableArray array];
    QTCollectViewsAtPoint(w, p, w, views, 0);

    // pick best scored view
    UIView *best = nil;
    NSInteger bestScore = -9999;

    for (UIView *v in views) {
        NSInteger s = QTScoreActionBar(v, w, p);
        if (s > bestScore) { bestScore = s; best = v; }
    }

    // Also capture the raw hitTest view for reference
    UIView *hit = [w hitTest:p withEvent:nil];

    NSString *msg = [NSString stringWithFormat:
                     @"📌 Tip: 3x Tap genau auf Reply/Repost/Like/Share\n\nHITTEST:\n%@\n\nBEST (score=%ld):\n%@\n\nFound %lu views under point.",
                     QTDescribe(hit, w, p),
                     (long)bestScore,
                     QTDescribe(best, w, p),
                     (unsigned long)views.count];

    UIPasteboard.generalPasteboard.string = msg;
    QTShowAlert(@"QT Debug (kopiert)", msg);
}

@end

static QTDBGPicker *gPicker;

%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    if (!QTIsX()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPicker) gPicker = [QTDBGPicker new];
        [gPicker attach];
    });
}
%end

%hook UIWindow
- (void)becomeKeyWindow {
    %orig;
    if (!QTIsX()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPicker) gPicker = [QTDBGPicker new];
        [gPicker attach];
    });
}
%end

%ctor {
    if (!QTIsX()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPicker) gPicker = [QTDBGPicker new];
        [gPicker attach];
    });
}
