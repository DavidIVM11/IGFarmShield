TARGET := iphone:clang:latest:14.0
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64
GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = IGFarmShieldPrefs

IGFarmShieldPrefs_FILES = IGFarmRootListController.m
IGFarmShieldPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation CoreGraphics QuartzCore AVFoundation SystemConfiguration
IGFarmShieldPrefs_INSTALL_PATH = /Library/PreferenceBundles
IGFarmShieldPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-error
IGFarmShieldPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage:: ; mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences $(THEOS_STAGING_DIR)/Library/PreferenceBundles/IGFarmShieldPrefs.bundle && cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/IGFarmShieldPrefs.plist && cp Info.plist $(THEOS_STAGING_DIR)/Library/PreferenceBundles/IGFarmShieldPrefs.bundle/Info.plist && (cp IGFarmShieldIcon*.png $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ 2>/dev/null || true) && (cp IGFarmShieldIcon*.png $(THEOS_STAGING_DIR)/Library/PreferenceBundles/IGFarmShieldPrefs.bundle/ 2>/dev/null || true)
