ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QuickTranslate
QuickTranslate_FILES = tweak/Tweak.xm
QuickTranslate_CFLAGS = -fobjc-arc
QuickTranslate_FRAMEWORKS = UIKit Foundation Vision

BUNDLE_NAME = QuickTranslatePrefs
QuickTranslatePrefs_FILES = prefs/QTCRootListController.m
QuickTranslatePrefs_INSTALL_PATH = /Library/PreferenceBundles
QuickTranslatePrefs_CFLAGS = -fobjc-arc
QuickTranslatePrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
