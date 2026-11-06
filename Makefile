TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Instagram Reddit Preferences
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IGFarmShield

IGFarmShield_FILES = Tweak.x
IGFarmShield_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
IGFarmShield_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore CoreTelephony SystemConfiguration Security LocalAuthentication AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += igfarmshieldprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
