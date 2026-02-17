#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <spawn.h>

extern char **environ;

@interface QTCRootListController : PSListController
@end

@implementation QTCRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// Action from Root.plist button: "respring"
- (void)respring {
    pid_t pid;
    const char *path = "/var/jb/usr/bin/killall";

    // rootless fallback: some setups also have /usr/bin/killall
    if (access(path, X_OK) != 0) path = "/usr/bin/killall";

    char *const args[] = {
        (char *)path,
        (char *)"-9",
        (char *)"SpringBoard",
        NULL
    };

    posix_spawn(&pid, path, NULL, NULL, args, environ);
}

@end
