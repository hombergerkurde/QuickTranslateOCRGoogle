TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# -------------------------
# TWEAK
# -------------------------
TWEAK_NAME = QuickTranslate

QuickTranslate_FILES = tweak/Tweak.xm
QuickTranslate_CFLAGS = -fobjc-arc

# iOS 15+ safe: keine deprecated windows errors, etc.
# (Optional, falls du wieder Werror-Probleme bekommst)
# QuickTranslate_CFLAGS += -Wno-deprecated-declarations -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk

# -------------------------
# PREFS BUNDLE
# -------------------------
BUNDLE_NAME = QuickTranslatePrefs

QuickTranslatePrefs_FILES = prefs/PrefsRootListController.m
QuickTranslatePrefs_INSTALL_PATH = /Library/PreferenceBundles
QuickTranslatePrefs_FRAMEWORKS = UIKit
QuickTranslatePrefs_CFLAGS = -fobjc-arc

# WICHTIG:
# NICHT Preferences.framework linken (CI SDK hat kein PrivateFrameworks-Verzeichnis)
# Also KEIN:
# QuickTranslatePrefs_PRIVATE_FRAMEWORKS = Preferences

# WICHTIG:
# AltList NICHT als Framework linken (sonst "framework AltList not found")
# AltList wird als Dependency installiert und der Controller-Name in der plist ist ein String.

include $(THEOS_MAKE_PATH)/bundle.mk

# -------------------------
# PACKAGE / LAYOUT FILES
# -------------------------
# Stelle sicher, dass du diese Struktur im Repo hast:
# layout/Library/PreferenceLoader/Preferences/QuickTranslate.plist
# prefs/Resources/Root.plist
# (Theos kopiert layout automatisch ins package)

after-install::
	install.exec "killall -9 Preferences || true"
