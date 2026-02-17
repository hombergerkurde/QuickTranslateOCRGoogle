#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// NOTE: This file is intentionally minimal scaffolding.
// Keep your existing translation/inline-button logic here.
// The critical fixes in this package are:
// 1) Proper PreferenceBundle + PreferenceLoader entry (like Translomatic)
// 2) Rootless+ElleKit injection fallback to /var/jb/usr/lib/TweakInject

static BOOL QTEnabled(void) {
    NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.hombergerkurde.quicktranslate"];
    id v = prefs[@"enabled"]; 
    return v ? [v boolValue] : YES;
}

static void QTToast(NSString *msg) {
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    if (!w) return;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = msg;
    l.textColor = UIColor.whiteColor;
    l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
    l.textAlignment = NSTextAlignmentCenter;
    l.layer.cornerRadius = 10;
    l.clipsToBounds = YES;
    [l sizeToFit];
    l.frame = CGRectInset(l.frame, -16, -10);
    l.center = CGPointMake(w.bounds.size.width/2.0, w.safeAreaInsets.top + 40);
    [w addSubview:l];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [l removeFromSuperview]; });
}

%ctor {
    // If your injection is correct, this should fire inside target apps.
    if (QTEnabled()) {
        dispatch_async(dispatch_get_main_queue(), ^{ QTToast(@"QuickTranslate loaded"); });
    }
}
