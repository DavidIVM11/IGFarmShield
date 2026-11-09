TARGET := iphone:clang:latest:15.0
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

internal-stage:: ; mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences $(THEOS_STAGING_DIR)/Library/PreferenceBundles/IGFarmShieldPrefs.bundle && (/usr/bin/swift -e 'import AppKit; for (n, s) in [("IGFarmShieldIcon.png", 29.0), ("IGFarmShieldIcon@2x.png", 58.0), ("IGFarmShieldIcon@3x.png", 87.0)] { let img = NSImage(size: NSSize(width: s, height: s)); img.lockFocus(); let r = NSRect(x: 0, y: 0, width: s, height: s); NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.22, alpha: 1.0).setFill(); NSBezierPath(roundedRect: r, xRadius: s*0.22, yRadius: s*0.22).fill(); let g = NSBezierPath(); g.move(to: NSPoint(x: s*0.24, y: s*0.22)); g.line(to: NSPoint(x: s*0.24, y: s*0.56)); g.appendArc(withCenter: NSPoint(x: s*0.50, y: s*0.56), radius: s*0.26, startAngle: 180, endAngle: 0, clockwise: true); g.line(to: NSPoint(x: s*0.76, y: s*0.22)); g.line(to: NSPoint(x: s*0.67, y: s*0.31)); g.line(to: NSPoint(x: s*0.58, y: s*0.22)); g.line(to: NSPoint(x: s*0.50, y: s*0.31)); g.line(to: NSPoint(x: s*0.42, y: s*0.22)); g.line(to: NSPoint(x: s*0.33, y: s*0.31)); g.close(); NSColor.white.setFill(); g.fill(); NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.22, alpha: 1.0).setFill(); NSBezierPath(ovalIn: NSRect(x: s*0.35, y: s*0.50, width: s*0.10, height: s*0.13)).fill(); NSBezierPath(ovalIn: NSRect(x: s*0.55, y: s*0.50, width: s*0.10, height: s*0.13)).fill(); img.unlockFocus(); if let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let p = b.representation(using: .png, properties: [:]) { try? p.write(to: URL(fileURLWithPath: n)) } }' || true) && cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/IGFarmShieldPrefs.plist && cp Info.plist $(THEOS_STAGING_DIR)/Library/PreferenceBundles/IGFarmShieldPrefs.bundle/Info.plist && (cp IGFarmShieldIcon*.png $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ 2>/dev/null || true) && (cp IGFarmShieldIcon*.png $(THEOS_STAGING_DIR)/Library/PreferenceBundles/IGFarmShieldPrefs.bundle/ 2>/dev/null || true)
