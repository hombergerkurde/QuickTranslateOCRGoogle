#import "QTCRootListController.h"

@implementation QTCRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)respring {
    // Light respring: close Preferences and restart SpringBoard
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/var/jb/usr/bin/killall";
    task.arguments = @[ @"-9", @"SpringBoard" ];
    @try { [task launch]; } @catch (__unused NSException *e) {}
}

@end
