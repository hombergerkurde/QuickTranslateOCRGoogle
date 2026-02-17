THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QuickTranslate
QuickTranslate_FILES = tweak/Tweak.xm
QuickTranslate_CFLAGS = -fobjc-arc
QuickTranslate_FRAMEWORKS = UIKit Foundation Vision

include $(THEOS_MAKE_PATH)/tweak.mk
