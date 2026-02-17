TARGET := iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QuickTranslate
QuickTranslate_FILES = tweak/Tweak.xm
QuickTranslate_CFLAGS = -fobjc-arc
QuickTranslate_FRAMEWORKS = UIKit Vision

BUNDLE_NAME = QuickTranslatePrefs
QuickTranslatePrefs_FILES = prefs/PrefsRootListController.m
QuickTranslatePrefs_INSTALL_PATH = /Library/PreferenceBundles
QuickTranslatePrefs_FRAMEWORKS = UIKit
QuickTranslatePrefs_PRIVATE_FRAMEWORKS = Preferences
QuickTranslatePrefs_EXTRA_FRAMEWORKS = AltList
QuickTranslatePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard"
