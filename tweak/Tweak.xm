#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
static void QTInstallFloatingButton(void) {
    UIWindow *w = QTGetKeyWindow();
    if (!w) return;

    // nur einmal hinzufügen
    if ([w viewWithTag:987654] != nil) return;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = 987654;
    [btn setTitle:@"🌐" forState:UIControlStateNormal];
    btn.frame = CGRectMake(20, 200, 44, 44);
    btn.layer.cornerRadius = 22;
    btn.clipsToBounds = YES;

    // Test: zeigt erstmal nur ein Popup
    [btn addTarget:nil action:@selector(qt_testTap) forControlEvents:UIControlEventTouchUpInside];

    [w addSubview:btn];
}

// wir hängen den Handler an UIWindow an (einfacher, ohne neue Klassen)
@interface UIWindow (QTTest)
- (void)qt_testTap;
@end

@implementation UIWindow (QTTest)
- (void)qt_testTap {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:@"QuickTranslate"
                                            message:@"Button funktioniert ✅"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *root = self.rootViewController;
    if (!root) return;

    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:ac animated:YES completion:nil];
}
@end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        QTInstallFloatingButton();
    });
}

