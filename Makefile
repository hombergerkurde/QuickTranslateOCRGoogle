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
# --- Prefs Bundle ---
BUNDLE_NAME = QuickTranslatePrefs
QuickTranslatePrefs_FILES = prefs/QTCRootListController.m
QuickTranslatePrefs_INSTALL_PATH = /Library/PreferenceBundles
QuickTranslatePrefs_FRAMEWORKS = UIKit
QuickTranslatePrefs_CFLAGS += -fobjc-arc

# WICHTIG: nicht gegen Preferences.framework linken (fehlt im GitHub SDK)
# Stattdessen Symbole zur Laufzeit auflösen:
QuickTranslatePrefs_LDFLAGS += -Wl,-undefined,dynamic_lookup


include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
