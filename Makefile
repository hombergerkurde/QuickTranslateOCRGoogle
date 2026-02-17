TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QuickTranslate
QuickTranslate_FILES = tweak/Tweak.xm
QuickTranslate_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Preferences || true"
