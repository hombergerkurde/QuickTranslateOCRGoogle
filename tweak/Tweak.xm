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

static NSInteger QTCountControls(UIView *v) {
    NSInteger c = 0;
    for (UIView *s in v.subviews) if ([s isKindOfClass:[UIControl class]]) c++;
    return c;
}

static NSString *QTDescribeView(UIView *v) {
    if (!v) return @"(nil)";
    NSString *cls = NSStringFromClass(v.class);
    NSString *sup = v.superview ? NSStringFromClass(v.superview.class) : @"(nil)";
    NSString *ax = v.accessibilityIdentifier ?: @"";
    CGRect r = v.frame;

    NSMutableArray<NSString *> *subControlClasses = [NSMutableArray array];
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UIControl class]]) [subControlClasses addObject:NSStringFromClass(s.class)];
    }

    return [NSString stringWithFormat:
            @"view=%@\nsuper=%@\naxid=%@\nframe={{%.1f,%.1f},{%.1f,%.1f}}\nsubviews=%lu\ncontrols=%ld\ncontrolClasses=%@",
            cls, sup, ax,
            r.origin.x, r.origin.y, r.size.width, r.size.height,
            (unsigned long)v.subviews.count,
            (long)QTCountControls(v),
            subControlClasses];
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

static void QTShowAlert(NSString *title, NSString *msg) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    UIViewController *top = QTTopVC(w.rootViewController);
    if (!top) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

@interface QTDBGTapCatcher : NSObject
@property (nonatomic, strong) UITapGestureRecognizer *tripleTap;
@end

@implementation QTDBGTapCatcher

- (instancetype)init {
    self = [super init];
    if (self) {
        self.tripleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
        self.tripleTap.numberOfTapsRequired = 3;     // 3x Tap
        self.tripleTap.numberOfTouchesRequired = 1;
        self.tripleTap.cancelsTouchesInView = NO;
    }
    return self;
}

- (void)attachIfPossible {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;
    // Avoid duplicates
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
    UIView *hit = [w hitTest:p withEvent:nil];
    if (!hit) {
        QTShowAlert(@"QT Debug", @"Kein View getroffen.");
        return;
    }

    // Wir suchen in der Superview-Kette einen "Action-Bar Kandidaten":
    // 3-6 UIControls (Reply/Repost/Like/Share etc.)
    UIView *cur = hit;
    UIView *best = nil;
    NSInteger depth = 0;

    while (cur && depth < 20) {
        NSInteger controls = QTCountControls(cur);
        if (controls >= 3 && controls <= 6 && cur.bounds.size.width > 150 && cur.bounds.size.height < 120) {
            best = cur;
            break;
        }
        cur = cur.superview;
        depth++;
    }
    if (!best) best = hit;

    NSString *msg =
    [NSString stringWithFormat:
     @"✅ HIT VIEW\n%@\n\n🔗 CHAIN (hit)\n%@\n\n✅ BEST CANDIDATE\n%@\n\n🔗 CHAIN (candidate)\n%@\n\n📌 Tipp: Tippe 3x direkt auf Reply/Repost/Like-Leiste.",
     QTDescribeView(hit),
     QTChain(hit, 12),
     QTDescribeView(best),
     QTChain(best, 12)];

    // Copy to clipboard so you can paste it here
    UIPasteboard.generalPasteboard.string = msg;

    QTShowAlert(@"QT Debug (kopiert)", msg);
}

@end

static QTDBGTapCatcher *gCatcher;

%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    if (!QTIsX()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gCatcher) gCatcher = [QTDBGTapCatcher new];
        [gCatcher attachIfPossible];
    });
}
%end

%hook UIWindow
- (void)becomeKeyWindow {
    %orig;
    if (!QTIsX()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gCatcher) gCatcher = [QTDBGTapCatcher new];
        [gCatcher attachIfPossible];
    });
}
%end

%ctor {
    if (!QTIsX()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gCatcher) gCatcher = [QTDBGTapCatcher new];
        [gCatcher attachIfPossible];
    });
}
