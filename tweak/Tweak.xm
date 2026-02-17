#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static UIWindow *QTGetKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        // 1) Foreground Active Scene bevorzugen
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;

            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }

        // 2) Fallback: irgendeine WindowScene
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }

        return nil;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // iOS 12 und älter – wird bei dir eh nicht relevant sein, aber safe:
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

static void QTShowToast(NSString *msg) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectZero];
    lbl.text = msg ?: @"QuickTranslate loaded";
    lbl.textColor = UIColor.whiteColor;
    lbl.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.numberOfLines = 2;
    lbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    lbl.layer.cornerRadius = 12.0;
    lbl.clipsToBounds = YES;

    CGFloat maxW = MIN(320.0, w.bounds.size.width - 40.0);
    CGSize maxSize = CGSizeMake(maxW, CGFLOAT_MAX);

    CGRect r = [lbl.text boundingRectWithSize:maxSize
                                      options:NSStringDrawingUsesLineFragmentOrigin
                                   attributes:@{NSFontAttributeName: lbl.font}
                                      context:nil];

    CGFloat padX = 16.0, padY = 10.0;
    CGFloat width = ceil(r.size.width) + padX * 2.0;
    CGFloat height = ceil(r.size.height) + padY * 2.0;

    lbl.frame = CGRectMake((w.bounds.size.width - width)/2.0,
                           w.safeAreaInsets.top + 20.0,
                           width,
                           height);

    [w addSubview:lbl];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.2 animations:^{
            lbl.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            [lbl removeFromSuperview];
        }];
    });
}

%hook UIApplication
- (void)applicationDidBecomeActive:(id)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        QTShowToast(@"QuickTranslate injected ✅");
    });
}
%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        QTShowToast(@"QuickTranslate loaded ✅");
    });
}
