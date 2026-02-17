#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Forward declaration
static UIWindow *QTGetKeyWindow(void);

#pragma mark - Window helper (iOS 15+ safe)

static UIWindow *QTGetKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        // Prefer active foreground scene
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;

            UIWindowScene *ws = (UIWindowScene *)scene;

            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }

        // Fallback: any window scene
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }

        return nil;
    }

    // iOS < 13 fallback (won't be used for your target range, but keeps it clean)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow ?: app.windows.firstObject;
#pragma clang diagnostic pop
}

#pragma mark - Simple floating button (build test)

static const NSInteger kQTButtonTag = 987654;

static UIViewController *QTTopViewController(UIViewController *vc) {
    if (!vc) return nil;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return QTTopViewController(((UINavigationController *)vc).topViewController);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        return QTTopViewController(((UITabBarController *)vc).selectedViewController);
    }
    return vc;
}

static void QTShowTestPopup(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    UIViewController *root = w.rootViewController;
    UIViewController *top = QTTopViewController(root);
    if (!top) return;

    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:@"QuickTranslate"
                                            message:@"Button funktioniert ✅\n(Nächster Schritt: OCR + Google Translate)"
                                     preferredStyle:UIAlertControllerStyleAlert];

    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

static void QTInstallFloatingButton(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    if ([w viewWithTag:kQTButtonTag] != nil) return;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = kQTButtonTag;
    [btn setTitle:@"🌐" forState:UIControlStateNormal];
    btn.frame = CGRectMake(20, 200, 44, 44);
    btn.layer.cornerRadius = 22;
    btn.clipsToBounds = YES;

    // Tap handler (block-based via UIAction for iOS 14+)
    if (@available(iOS 14.0, *)) {
        [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            QTShowTestPopup();
        }] forControlEvents:UIControlEventTouchUpInside];
    } else {
        // Very old fallback (not relevant for iOS 15–17)
        [btn addTarget:w action:@selector(qt_fallbackTap) forControlEvents:UIControlEventTouchUpInside];
    }

    [w addSubview:btn];
}

// Fallback selector target
@interface UIWindow (QTFallback)
- (void)qt_fallbackTap;
@end
@implementation UIWindow (QTFallback)
- (void)qt_fallbackTap { QTShowTestPopup(); }
@end

// Re-attach button when app becomes active (handles app switching / scenes)
%hook UIApplication
- (void)applicationDidBecomeActive:(id)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        QTInstallFloatingButton();
    });
}
%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        QTInstallFloatingButton();
    });
}
