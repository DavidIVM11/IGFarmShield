TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = IGFarmShieldPrefs

IGFarmShieldPrefs_FILES = IGFarmRootListController.m
IGFarmShieldPrefs_FRAMEWORKS = UIKit Foundation CoreGraphics
IGFarmShieldPrefs_PRIVATE_FRAMEWORKS = Preferences
IGFarmShieldPrefs_INSTALL_PATH = /Library/PreferenceBundles
IGFarmShieldPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceLoader/Preferences/IGFarmShieldPrefs.plist$(ECHO_END)
