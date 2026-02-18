#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>

static inline BOOL QTIsX(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bid isEqualToString:@"com.atebits.Tweetie2"];
}

static NSString * const kQTLogPath = @"/var/jb/var/mobile/Documents/qt_x_debug.txt";

static void QTAppendLine(NSString *line) {
    if (!line.length) return;

    @autoreleasepool {
        NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return;

        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:kQTLogPath]) {
            [fm createFileAtPath:kQTLogPath contents:nil attributes:nil];
        }

        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kQTLogPath];
        if (!fh) return;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:data];
        } @catch (__unused NSException *e) {
        }
        @try { [fh closeFile]; } @catch (__unused NSException *e2) {}
    }
}

static void QTLogF(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    QTAppendLine(s ?: @"(nil)");
}

static NSInteger QTCountControls(UIView *v) {
    NSInteger c = 0;
    for (UIView *s in v.subviews) if ([s isKindOfClass:[UIControl class]]) c++;
    return c;
}

static BOOL QTLooksLikeActionBarCandidate(UIView *v, UIView *cellContent) {
    if (!v || !cellContent) return NO;
    if (v.hidden || v.alpha < 0.01) return NO;
    if (!v.window) return NO;

    NSInteger controls = QTCountControls(v);
    if (controls < 3 || controls > 6) return NO;

    CGRect r = v.frame;
    if (r.size.height <= 0 || r.size.width <= 0) return NO;
    if (r.size.height > 90) return NO;
    if (r.size.width < 150) return NO;

    CGFloat yBottom = CGRectGetMaxY(r);
    CGFloat contentH = cellContent.bounds.size.height;
    if (contentH > 0) {
        if (yBottom < contentH * 0.45) return NO;
    }
    return YES;
}

static NSString *QTShort(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length > 80) t = [[t substringToIndex:80] stringByAppendingString:@"…"];
    return t;
}

static void QTLogCandidate(UIView *v) {
    NSString *cls = NSStringFromClass(v.class);
    NSString *superCls = v.superview ? NSStringFromClass(v.superview.class) : @"(nil)";
    NSString *ax = v.accessibilityIdentifier ?: @"";
    CGRect r = v.frame;

    NSMutableArray<NSString *> *controlClasses = [NSMutableArray array];
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UIControl class]]) {
            [controlClasses addObject:NSStringFromClass(s.class)];
        }
    }

    QTLogF(@"QT:X candidate actionbar view=%@ super=%@ axid=%@ frame={{%.1f,%.1f},{%.1f,%.1f}} controls=%ld controlClasses=%@",
           cls, superCls, ax, r.origin.x, r.origin.y, r.size.width, r.size.height,
           (long)QTCountControls(v), controlClasses);
}

static void QTScanText(UIView *root, NSInteger depth) {
    if (!root || depth > 10) return;
    if (root.hidden || root.alpha < 0.01) return;

    if ([root isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)root;
        NSString *t = l.text;
        if (t.length >= 20) {
            QTLogF(@"QT:X label class=%@ super=%@ text=%@",
                   NSStringFromClass(l.class),
                   l.superview ? NSStringFromClass(l.superview.class) : @"(nil)",
                   QTShort(t));
        }
    }
    for (UIView *s in root.subviews) QTScanText(s, depth + 1);
}

static void QTScanCandidates(UIView *root, UIView *cellContent, NSInteger depth) {
    if (!root || depth > 10) return;
    if (root.hidden || root.alpha < 0.01) return;

    if (QTLooksLikeActionBarCandidate(root, cellContent)) {
        QTLogCandidate(root);
    }
    for (UIView *s in root.subviews) QTScanCandidates(s, cellContent, depth + 1);
}

static char kQTDidLogKey;

static void QTDebugScanCellContent(UIView *cellContent) {
    if (!QTIsX()) return;
    if (!cellContent) return;

    if (objc_getAssociatedObject(cellContent, &kQTDidLogKey)) return;
    objc_setAssociatedObject(cellContent, &kQTDidLogKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    QTLogF(@"QT:X ---- scanning cellContent=%@ frame={{%.1f,%.1f},{%.1f,%.1f}} ----",
           NSStringFromClass(cellContent.class),
           cellContent.frame.origin.x, cellContent.frame.origin.y,
           cellContent.frame.size.width, cellContent.frame.size.height);

    QTScanCandidates(cellContent, cellContent, 0);
    QTScanText(cellContent, 0);
}

%hook UITableViewCell
- (void)layoutSubviews {
    %orig;
    if (!QTIsX()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        QTDebugScanCellContent(self.contentView);
    });
}
%end

%hook UICollectionViewCell
- (void)layoutSubviews {
    %orig;
    if (!QTIsX()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        QTDebugScanCellContent(self.contentView);
    });
}
%end

%ctor {
    if (!QTIsX()) return;

    // Clear file on load so each run is clean
    [[NSFileManager defaultManager] removeItemAtPath:kQTLogPath error:nil];
    QTAppendLine(@"QT:X debug loaded (file logger) — scroll timeline now.");
    QTAppendLine([NSString stringWithFormat:@"QT:X bundle=%@", NSBundle.mainBundle.bundleIdentifier ?: @"(nil)"]);
}
