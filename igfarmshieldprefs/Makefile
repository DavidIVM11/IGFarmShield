TARGET := iphone:clang:latest:14.0
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = IGFarmShieldPrefs

IGFarmShieldPrefs_FILES = IGFarmRootListController.m
IGFarmShieldPrefs_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AVFoundation
IGFarmShieldPrefs_INSTALL_PATH = /Library/PreferenceBundles
IGFarmShieldPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-error
IGFarmShieldPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceBundles/IGFarmShieldPrefs.bundle$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/IGFarmShieldPrefs.plist$(ECHO_END)
	$(ECHO_NOTHING)cp Info.plist $(THEOS_STAGING_DIR)/Library/PreferenceBundles/IGFarmShieldPrefs.bundle/Info.plist$(ECHO_END)
	$(ECHO_NOTHING)cp IGFarmShieldIcon*.png $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)cp IGFarmShieldIcon*.png $(THEOS_STAGING_DIR)/Library/PreferenceBundles/IGFarmShieldPrefs.bundle/ 2>/dev/null || true$(ECHO_END)
