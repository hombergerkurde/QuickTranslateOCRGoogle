#import <Preferences/PSListController.h>

@interface QuickTranslatePrefsRootListController : PSListController
@end

@implementation QuickTranslatePrefsRootListController
- (instancetype)init {
    self = [super init];
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}
@end
