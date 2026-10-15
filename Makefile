TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Instagram Reddit Preferences
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IGFarmShield

IGFarmShield_FILES = Tweak.x
IGFarmShield_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
IGFarmShield_FRAMEWORKS = UIKit Foundation CFNetwork LocalAuthentication CoreTelephony DeviceCheck SystemConfiguration AVFoundation

SUBPROJECTS += igfarmshieldprefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
