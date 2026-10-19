#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CFNetwork/CFNetwork.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <AVFoundation/AVFoundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <time.h>
#import <substrate.h>

#define GLOBAL_STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CRANE_PREFS_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_PREFS_VAR @"/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_MAIN_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define CRANE_MAIN_VAR @"/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define CURRENT_SCHEMA_VERSION 32

@interface NSMutableURLRequest (HTTP3Disable)
- (void)setAssumesHTTP3Capable:(BOOL)capable;
- (BOOL)assumesHTTP3Capable;
@end

// Nombre de clase mimetizado con UIKit y filtrado de UIApplication.windows / UIWindowScene.windows
@interface _UIStatusBarLocalOverlayWindow : UIWindow
@end

@implementation _UIStatusBarLocalOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return NO;
}
@end

static NSString *origCraneIDFV = nil;
static NSMutableDictionary *liveContainerProfile = nil;
static NSTimeInterval sessionStartTimestamp = 0;
static BOOL bannerShownThisSession = NO;
static _UIStatusBarLocalOverlayWindow *persistentBadgeWindow = nil;

// Banderas en memoria RAM para ejecución instantánea (O(1)) con 30+ contenedores
static BOOL s_profileInitialized = NO;
static BOOL s_shieldActive = NO;
static BOOL s_spoofIDs = NO;
static BOOL s_spoofNetwork = NO;
static BOOL s_spoofLocation = NO;
static BOOL s_spoofHardware = NO;
static BOOL s_spoofSecurity = NO;
static BOOL s_isCellularMode = YES;
static in_addr_t s_spoofedLanAddr = 0;
static char s_containerHomePath[PATH_MAX] = {0};
static size_t s_containerHomeLen = 0;
static __thread BOOL s_inInternalCall = NO;

static int (*orig_dladdr)(const void *, Dl_info *) = NULL;
static const char *(*orig_dyld_get_image_name)(uint32_t image_index) = NULL;
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*orig_statfs)(const char *, struct statfs *) = NULL;
static FILE *(*orig_fopen)(const char *, const char *) = NULL;
static char *(*orig_getenv)(const char *) = NULL;
static int (*orig_getifaddrs)(struct ifaddrs **) = NULL;
static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef) = NULL;
static CFDictionaryRef (*orig_CFNetworkCopySystemProxySettings)(void) = NULL;
static CFArrayRef (*orig_CFNetworkCopyProxiesForURL)(CFURLRef, CFDictionaryRef) = NULL;

static uint64_t randomSeed64(NSString *salt) {
    uint64_t hash = 14695981039346656037ULL;
    const char *bytes = [salt UTF8String];
    if (bytes) {
        while (*bytes) {
            hash ^= (uint8_t)(*bytes++);
            hash *= 1099511628211ULL;
        }
    }
    uint64_t r = 0;
    arc4random_buf(&r, sizeof(r));
    return hash ^ r;
}

static void applyLowLevelCTimeZone(NSString *tzName) {
    if (!tzName || [tzName hasPrefix:@"Sincronizando"] || [tzName hasPrefix:@"Sin "] || tzName.length == 0) return;
    setenv("TZ", [tzName UTF8String], 1);
    tzset();
}

// Detecta llamadas del binario de la App y de su runtime de Swift,
// excluyendo explícitamente a Crane, CFNetwork, libnetwork y libswiftNetwork
static BOOL isCallerFromTargetApp(const void *retAddr) {
    if (s_inInternalCall || !retAddr || !orig_dladdr) return NO;
    Dl_info info;
    if (orig_dladdr(retAddr, &info) != 0 && info.dli_fname) {
        if (strstr(info.dli_fname, "IGFarmShield") != NULL ||
            strstr(info.dli_fname, "Crane") != NULL ||
            strstr(info.dli_fname, "crane") != NULL ||
            strstr(info.dli_fname, "CFNetwork") != NULL ||
            strstr(info.dli_fname, "libnetwork") != NULL ||
            strstr(info.dli_fname, "libswiftNetwork") != NULL) {
            return NO;
        }
        if (strstr(info.dli_fname, "/Containers/Bundle/Application/") != NULL ||
            strstr(info.dli_fname, "libswift") != NULL) {
            return YES;
        }
    }
    return NO;
}

static void searchNestedMetadata(id node, NSString **outID, NSString **outName, NSString *bundleID) {
    if (!node) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        for (id k in dict) {
            NSString *kl = [[k description] lowercaseString];
            id val = dict[k];
            if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
                NSString *vStr = (NSString *)val;
                if ([kl containsString:@"name"] || [kl containsString:@"label"] || [kl containsString:@"title"]) {
                    if (!*outName) *outName = vStr;
                } else if (([kl containsString:@"id"] || [kl containsString:@"crane"] || [kl containsString:@"container"] || [kl containsString:@"uuid"]) &&
                           ![vStr isEqualToString:bundleID] && ![vStr hasPrefix:@"com."]) {
                    if (!*outID) *outID = vStr;
                }
            } else if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                searchNestedMetadata(val, outID, outName, bundleID);
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) {
            searchNestedMetadata(item, outID, outName, bundleID);
        }
    }
}

static NSString *findCraneNameInNode(id node, NSString *targetID) {
    if (!node || !targetID || targetID.length == 0) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        for (id k in dict) {
            NSString *kStr = [k description];
            id val = dict[k];
            if ([kStr caseInsensitiveCompare:targetID] == NSOrderedSame) {
                if ([val isKindOfClass:[NSString class]] && [val length] > 0) return val;
                if ([val isKindOfClass:[NSDictionary class]]) {
                    for (NSString *nk in @[@"name", @"displayName", @"label", @"title", @"containerName"]) {
                        if ([val[nk] isKindOfClass:[NSString class]] && [val[nk] length] > 0) return val[nk];
                    }
                }
            }
            if ([val isKindOfClass:[NSString class]] && [val caseInsensitiveCompare:targetID] == NSOrderedSame) {
                for (NSString *nk in @[@"name", @"displayName", @"label", @"title", @"containerName"]) {
                    if ([dict[nk] isKindOfClass:[NSString class]] && [dict[nk] length] > 0 && ![dict[nk] isEqualToString:targetID]) {
                        return dict[nk];
                    }
                }
            }
            if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                NSString *found = findCraneNameInNode(val, targetID);
                if (found) return found;
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) {
            NSString *found = findCraneNameInNode(item, targetID);
            if (found) return found;
        }
    }
    return nil;
}

static NSDictionary *resolveCraneIdentityDict(NSString *homePath, NSString *bundleID) {
    NSString *folderUUID = [homePath lastPathComponent] ?: @"Default";
    NSString *metaPath = [homePath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];

    NSString *craneID = nil;
    NSString *craneName = nil;

    const char *envName = orig_getenv ? orig_getenv("CRANE_CONTAINER_NAME") : getenv("CRANE_CONTAINER_NAME");
    const char *envID = orig_getenv ? orig_getenv("CRANE_CONTAINER_ID") : getenv("CRANE_CONTAINER_ID");
    const char *envIdent = orig_getenv ? orig_getenv("CRANE_IDENTIFIER") : getenv("CRANE_IDENTIFIER");

    if (envName && strlen(envName) > 0) craneName = [NSString stringWithUTF8String:envName];
    if (envID && strlen(envID) > 0) craneID = [NSString stringWithUTF8String:envID];
    if (envIdent && strlen(envIdent) > 0 && !craneID) craneID = [NSString stringWithUTF8String:envIdent];

    if ([meta isKindOfClass:[NSDictionary class]]) {
        for (NSString *rk in @[@"com.opa334.crane.container.name", @"craneContainerName"]) {
            if ([meta[rk] isKindOfClass:[NSString class]] && [meta[rk] length] > 0) craneName = meta[rk];
        }
        for (NSString *ik in @[@"com.opa334.crane.container.identifier", @"com.opa334.crane.container.id", @"craneContainerIdentifier"]) {
            if ([meta[ik] isKindOfClass:[NSString class]] && [meta[ik] length] > 0) craneID = meta[ik];
        }
        NSDictionary *userInfo = meta[@"MCMMetadataUserInfo"];
        if (userInfo) {
            searchNestedMetadata(userInfo, &craneID, &craneName, bundleID);
        }
    }

    for (NSString *pPath in @[CRANE_PREFS_JB, CRANE_MAIN_JB, CRANE_PREFS_VAR, CRANE_MAIN_VAR]) {
        NSDictionary *cPrefs = [NSDictionary dictionaryWithContentsOfFile:pPath];
        if ([cPrefs isKindOfClass:[NSDictionary class]] && [cPrefs count] > 0) {
            if (!craneName && craneID) craneName = findCraneNameInNode(cPrefs, craneID);
            if (!craneName && origCraneIDFV) {
                NSString *foundByIDFV = findCraneNameInNode(cPrefs, origCraneIDFV);
                if (foundByIDFV) {
                    craneName = foundByIDFV;
                    if (!craneID) craneID = origCraneIDFV;
                }
            }
            if (!craneName) craneName = findCraneNameInNode(cPrefs, folderUUID);
        }
    }

    if (!craneID && origCraneIDFV && origCraneIDFV.length >= 32) {
        craneID = origCraneIDFV;
    }
    if (!craneID) craneID = meta[@"MCMMetadataUUID"] ?: folderUUID;

    if (!craneName || craneName.length == 0) {
        NSDictionary *userInfo = [meta isKindOfClass:[NSDictionary class]] ? meta[@"MCMMetadataUserInfo"] : nil;
        if ((!userInfo || [userInfo count] == 0) || [craneID caseInsensitiveCompare:@"default"] == NSOrderedSame) {
            craneName = @"Default";
        } else {
            craneName = craneID;
        }
    }

    return @{
        @"keyUUID": folderUUID ?: @"Default",
        @"craneID": craneID ?: @"Default",
        @"craneName": craneName ?: @"Default"
    };
}

static void ensureProfileLoaded() {
    if (s_profileInitialized || s_inInternalCall) return;
    s_inInternalCall = YES;
    s_profileInitialized = YES;

    sessionStartTimestamp = [[NSDate date] timeIntervalSince1970];
    NSString *homePath = NSHomeDirectory();
    if (homePath.length > 0) {
        strncpy(s_containerHomePath, [homePath UTF8String], sizeof(s_containerHomePath) - 1);
        s_containerHomePath[sizeof(s_containerHomePath) - 1] = '\0';
        s_containerHomeLen = strlen(s_containerHomePath);
    }

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.burbn.instagram";

    NSDictionary *ident = resolveCraneIdentityDict(homePath, bundleID);
    NSString *keyUUID = ident[@"keyUUID"];
    NSString *craneID = ident[@"craneID"];
    NSString *craneName = ident[@"craneName"];

    NSString *localPlist = [homePath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
    NSDictionary *diskLoaded = [NSDictionary dictionaryWithContentsOfFile:localPlist];

    NSDictionary *loadedGlobal = [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST];
    NSMutableDictionary *globalSt = loadedGlobal ? [loadedGlobal mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *byUUID = [globalSt[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
        ? [globalSt[@"containersByUUID"] mutableCopy]
        : [NSMutableDictionary dictionary];

    NSDictionary *activeMap = [globalSt[@"activeInCrane"] isKindOfClass:[NSDictionary class]] ? globalSt[@"activeInCrane"] : @{};
    NSString *craneActiveIDForApp = activeMap[bundleID];

    NSDictionary *settingsEntry = nil;
    NSString *matchedSettingsKey = nil;

    for (NSString *existingKey in byUUID) {
        NSDictionary *cand = byUUID[existingKey];
        if (![cand isKindOfClass:[NSDictionary class]] || ![cand[@"bundleID"] isEqualToString:bundleID]) continue;
        NSString *candPath = cand[@"path"] ?: @"";
        NSString *candCraneID = cand[@"craneIdentifier"] ?: @"";
        NSString *candIDFV = cand[@"idfv"] ?: @"";
        NSString *candName = cand[@"containerName"] ?: @"";

        if ([candPath isEqualToString:homePath] ||
            [existingKey caseInsensitiveCompare:keyUUID] == NSOrderedSame ||
            (origCraneIDFV.length > 0 && ([existingKey caseInsensitiveCompare:origCraneIDFV] == NSOrderedSame ||
                                          [candCraneID caseInsensitiveCompare:origCraneIDFV] == NSOrderedSame ||
                                          [candIDFV caseInsensitiveCompare:origCraneIDFV] == NSOrderedSame)) ||
            (candCraneID.length > 0 && ![candCraneID isEqualToString:@"Default"] && [candCraneID caseInsensitiveCompare:craneID] == NSOrderedSame) ||
            (craneName.length > 0 && ![craneName isEqualToString:@"Default"] && [candName caseInsensitiveCompare:craneName] == NSOrderedSame)) {
            settingsEntry = cand;
            matchedSettingsKey = existingKey;
            break;
        }
    }

    if (!settingsEntry && craneActiveIDForApp.length > 0) {
        for (NSString *existingKey in byUUID) {
            NSDictionary *cand = byUUID[existingKey];
            if (![cand isKindOfClass:[NSDictionary class]] || ![cand[@"bundleID"] isEqualToString:bundleID]) continue;
            NSString *candPath = cand[@"path"] ?: @"";
            if (candPath.length > 0 && ![candPath isEqualToString:homePath]) continue;

            NSString *candCraneID = cand[@"craneIdentifier"] ?: @"";
            NSString *candName = cand[@"containerName"] ?: @"";

            if ([existingKey caseInsensitiveCompare:craneActiveIDForApp] == NSOrderedSame ||
                [candCraneID caseInsensitiveCompare:craneActiveIDForApp] == NSOrderedSame ||
                [candName caseInsensitiveCompare:craneActiveIDForApp] == NSOrderedSame) {
                settingsEntry = cand;
                matchedSettingsKey = existingKey;
                break;
            }
        }
    }

    NSMutableDictionary *profile = nil;
    if (settingsEntry && settingsEntry[@"bootSessionUUID"]) {
        profile = [settingsEntry mutableCopy];
    } else if ([diskLoaded isKindOfClass:[NSDictionary class]] && diskLoaded[@"bootSessionUUID"]) {
        profile = [diskLoaded mutableCopy];
    }

    if (profile && settingsEntry) {
        for (NSString *k in @[@"enabled", @"containerName", @"craneIdentifier", @"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity", @"locationAnchored", @"timeZone", @"localeID", @"CarrierMode", @"CarrierName", @"CarrierMCC", @"CarrierMNC", @"CarrierISO", @"ispName", @"cityCountry", @"lastSyncedIP", @"localIP", @"ssid", @"bssid", @"bootSessionUUID", @"freeBytes", @"batteryLevel", @"audioVolume", @"brightness", @"pasteboardCount"]) {
            if (settingsEntry[k] != nil) profile[k] = settingsEntry[k];
        }
    }

    NSString *nativeCraneUUID = (origCraneIDFV && origCraneIDFV.length >= 32)
        ? [origCraneIDFV uppercaseString]
        : (([craneID containsString:@"-"] && craneID.length >= 32) ? [craneID uppercaseString] : [[NSUUID UUID] UUIDString]);

    if (!profile || !profile[@"bootSessionUUID"]) {
        uint64_t seed = randomSeed64(keyUUID);
        NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59", @"f0:9f:c2", @"04:d6:aa"];
        NSArray *ssidPrefixes = @[@"HomeWiFi", @"ATT-Fiber", @"Xfinity-WiFi", @"SpectrumSetup", @"NETGEAR", @"TP-Link"];
        NSArray *subnets = @[@"192.168.1", @"192.168.0", @"10.0.0", @"192.168.50", @"172.16.0", @"192.168.10"];

        NSString *oui = ouis[seed % ouis.count];
        NSString *ssidPref = ssidPrefixes[(seed >> 3) % ssidPrefixes.count];
        NSString *subnet = subnets[(seed >> 5) % subnets.count];

        NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x",
                           oui, (unsigned int)((seed >> 8) & 0xFF), (unsigned int)((seed >> 16) & 0xFF), (unsigned int)((seed >> 24) & 0xFF)];
        NSString *ssid = [NSString stringWithFormat:@"%@-%02X-5G", ssidPref, (unsigned int)(seed & 0xFF)];
        NSString *localIP = [NSString stringWithFormat:@"%@.%d", subnet, 15 + (int)(seed % 220)];
        unsigned long long freeBytes = ((14800ULL + (seed % 31500ULL)) * 1024ULL * 1024ULL) + ((seed >> 12) % 1048576ULL);

        BOOL manualEnabled = (settingsEntry && settingsEntry[@"enabled"] != nil) ? [settingsEntry[@"enabled"] boolValue] : NO;

        profile = [@{
            @"schemaVersion": @(CURRENT_SCHEMA_VERSION),
            @"containerUUID": matchedSettingsKey ?: keyUUID,
            @"craneIdentifier": craneID,
            @"containerName": craneName,
            @"bundleID": bundleID,
            @"path": homePath,
            @"enabled": @(manualEnabled),
            @"spoofIDs": @YES,
            @"spoofNetwork": @YES,
            @"spoofLocation": @YES,
            @"spoofHardware": @YES,
            @"spoofSecurity": @YES,
            @"locationAnchored": @NO,
            @"deviceModel": @"iPhone10,4",
            @"craneOriginalIDFV": nativeCraneUUID,
            @"idfv": nativeCraneUUID,
            @"bootSessionUUID": [[NSUUID UUID] UUIDString],
            @"bssid": bssid,
            @"ssid": ssid,
            @"localIP": localIP,
            @"freeBytes": @(freeBytes),
            @"batteryLevel": @(0.32f + ((seed % 60) / 100.0f)),
            @"brightness": @(0.30f + (((seed >> 4) % 60) / 100.0f)),
            @"audioVolume": @(0.20f + (((seed >> 6) % 70) / 100.0f)),
            @"pasteboardCount": @(5 + (seed % 90)),
            @"lastSyncedIP": @"Sin sincronizar",
            @"ispName": @"Pendiente",
            @"cityCountry": @"Sincroniza en el contenedor",
            @"timeZone": @"America/New_York",
            @"localeID": @"en_US",
            @"CarrierMode": @"CELLULAR",
            @"CarrierName": @"T-Mobile",
            @"CarrierMCC": @"310",
            @"CarrierMNC": @"260",
            @"CarrierISO": @"us"
        } mutableCopy];
    } else {
        profile[@"idfv"] = nativeCraneUUID;
        profile[@"craneOriginalIDFV"] = nativeCraneUUID;
        profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
        profile[@"bundleID"] = bundleID;
        profile[@"path"] = homePath;
        if (craneName.length > 0 && ![craneName isEqualToString:keyUUID] && [profile[@"containerName"] isEqualToString:@"Default"]) {
            profile[@"containerName"] = craneName;
        }
    }

    [profile writeToFile:localPlist atomically:YES];

    if (matchedSettingsKey && byUUID[matchedSettingsKey]) {
        NSMutableDictionary *updatedEntry = [byUUID[matchedSettingsKey] mutableCopy];
        if (![updatedEntry[@"path"] isEqualToString:homePath] || ![updatedEntry[@"idfv"] isEqualToString:nativeCraneUUID]) {
            updatedEntry[@"path"] = homePath;
            updatedEntry[@"idfv"] = nativeCraneUUID;
            byUUID[matchedSettingsKey] = updatedEntry;
            globalSt[@"containersByUUID"] = byUUID;
            [globalSt writeToFile:GLOBAL_STATE_PLIST atomically:YES];
        }
    }

    liveContainerProfile = profile;

    BOOL masterOn = [globalSt[@"masterEnabled"] boolValue];
    BOOL appOn = NO;
    if ([bundleID isEqualToString:@"com.burbn.instagram"]) appOn = [globalSt[@"enableIG"] boolValue];
    else if ([bundleID isEqualToString:@"com.reddit.Reddit"]) appOn = [globalSt[@"enableReddit"] boolValue];

    BOOL contOn = [profile[@"enabled"] boolValue];
    s_shieldActive = (masterOn && appOn && contOn);

    s_spoofIDs = s_shieldActive && (profile[@"spoofIDs"] == nil ? YES : [profile[@"spoofIDs"] boolValue]);
    s_spoofNetwork = s_shieldActive && (profile[@"spoofNetwork"] == nil ? YES : [profile[@"spoofNetwork"] boolValue]);
    s_spoofLocation = s_shieldActive && (profile[@"spoofLocation"] == nil ? YES : [profile[@"spoofLocation"] boolValue]);
    s_spoofHardware = s_shieldActive && (profile[@"spoofHardware"] == nil ? YES : [profile[@"spoofHardware"] boolValue]);
    s_spoofSecurity = s_shieldActive && (profile[@"spoofSecurity"] == nil ? YES : [profile[@"spoofSecurity"] boolValue]);
    s_isCellularMode = ![profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"];

    NSString *lanIP = profile[@"localIP"] ?: @"192.168.1.45";
    s_spoofedLanAddr = inet_addr([lanIP UTF8String]);

    if (s_spoofLocation && profile[@"timeZone"]) {
        applyLowLevelCTimeZone(profile[@"timeZone"]);
    }

    s_inInternalCall = NO;
}

// ============================================================================
// CÁPSULA FIJA EN BARRA SUPERIOR (OCULTA DE LOS ARREGLOS DE VENTANAS DE LA APP)
// ============================================================================
static void showStartupBannerAndPersistentIcon(int attempt) {
    if (bannerShownThisSession) return;
    ensureProfileLoaded();
    if (!liveContainerProfile) return;

    s_inInternalCall = YES;
    UIWindowScene *activeScene = nil;
    UIWindow *targetWin = nil;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (!activeScene || ws.activationState == UISceneActivationStateForegroundActive) {
                activeScene = ws;
            }
            for (UIWindow *w in ws.windows) {
                if (w != persistentBadgeWindow && !w.hidden && w.alpha > 0.01 && w.bounds.size.width > 100) {
                    if (w.isKeyWindow || !targetWin) {
                        targetWin = w;
                    }
                }
            }
        }
    }

    if (!targetWin) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w != persistentBadgeWindow && !w.hidden && w.bounds.size.width > 100) {
                targetWin = w;
                if (!activeScene) activeScene = w.windowScene;
                break;
            }
        }
    }
    s_inInternalCall = NO;

    if (!targetWin) {
        if (attempt < 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                showStartupBannerAndPersistentIcon(attempt + 1);
            });
        }
        return;
    }

    bannerShownThisSession = YES;

    NSDictionary *prof = liveContainerProfile;
    NSString *cName = prof[@"containerName"] ?: @"Default";
    CGRect screenBounds = [UIScreen mainScreen].bounds;

    if (!persistentBadgeWindow) {
        if (activeScene) {
            persistentBadgeWindow = [[_UIStatusBarLocalOverlayWindow alloc] initWithWindowScene:activeScene];
        } else {
            persistentBadgeWindow = [[_UIStatusBarLocalOverlayWindow alloc] initWithFrame:screenBounds];
        }
        persistentBadgeWindow.frame = CGRectMake(0, 0, screenBounds.size.width, 44);
        persistentBadgeWindow.backgroundColor = [UIColor clearColor];
        persistentBadgeWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
        persistentBadgeWindow.userInteractionEnabled = NO;

        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        rootVC.view.userInteractionEnabled = NO;
        persistentBadgeWindow.rootViewController = rootVC;

        UILabel *badgePill = [[UILabel alloc] init];
        badgePill.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold];
        badgePill.textColor = [UIColor whiteColor];
        badgePill.textAlignment = NSTextAlignmentCenter;
        badgePill.layer.cornerRadius = 8.0;
        badgePill.layer.borderWidth = 0.8;
        badgePill.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
        badgePill.clipsToBounds = YES;

        if (s_shieldActive) {
            badgePill.backgroundColor = [UIColor colorWithRed:0.04 green:0.52 blue:0.24 alpha:0.94];
            badgePill.text = [NSString stringWithFormat:@" 🛡️ %@ ", cName];
        } else {
            badgePill.backgroundColor = [UIColor colorWithRed:0.38 green:0.38 blue:0.42 alpha:0.90];
            badgePill.text = [NSString stringWithFormat:@" ⚪ %@ ", cName];
        }

        [badgePill sizeToFit];
        CGFloat pillW = MIN(MAX(badgePill.bounds.size.width + 12.0, 62.0), 160.0);
        badgePill.frame = CGRectMake((screenBounds.size.width - pillW) / 2.0, 18.0, pillW, 16.0);

        [rootVC.view addSubview:badgePill];
        persistentBadgeWindow.hidden = NO;
    }

    NSString *netMode = s_isCellularMode
        ? [NSString stringWithFormat:@"Red: %@", prof[@"CarrierName"] ?: @"Móvil"]
        : [NSString stringWithFormat:@"Wi-Fi (%@)", prof[@"localIP"] ?: @"LAN"];
    int batPct = (int)([prof[@"batteryLevel"] floatValue] * 100.0f);

    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, screenBounds.size.width - 32, 42)];
    toast.layer.cornerRadius = 10.0;
    toast.clipsToBounds = YES;
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont boldSystemFontOfSize:11.5];
    toast.numberOfLines = 2;
    toast.textColor = [UIColor whiteColor];

    if (s_shieldActive) {
        toast.backgroundColor = [UIColor colorWithRed:0.06 green:0.48 blue:0.24 alpha:0.94];
        toast.text = [NSString stringWithFormat:@"🛡️ %@ • %@ • Bat: %d%%\n%@ • %@",
                      cName, netMode, batPct, prof[@"lastSyncedIP"] ?: @"IP Aislada", prof[@"timeZone"] ?: @""];
    } else {
        toast.backgroundColor = [UIColor colorWithRed:0.45 green:0.45 blue:0.48 alpha:0.92];
        toast.text = [NSString stringWithFormat:@"⚪ %@ • En Pausa Manual (Datos Nativos)", cName];
    }

    [targetWin addSubview:toast];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.35 animations:^{ toast.alpha = 0.0; } completion:^(BOOL f) { [toast removeFromSuperview]; }];
    });
}

// ============================================================================
// MODO INVISIBLE ESTABLE (RESPETA LA CARPETA DE DATOS DEL CONTENEDOR Y CRANE)
// ============================================================================
static BOOL isHiddenPathForTargetAppC(const char *path) {
    if (!path) return NO;

    // 1. Permitir siempre los Cryptexes nativos de iOS 16 (WebKit / OAuth)
    if (strstr(path, "Cryptex") != NULL || strstr(path, "cryptex") != NULL) {
        return NO;
    }

    // 2. Si la ruta pertenece al propio directorio de datos del contenedor activo,
    // permitir todo (incluyendo redirecciones de Crane) excepto el plist de IGFarmShield
    if (s_containerHomeLen > 0 && strncmp(path, s_containerHomePath, s_containerHomeLen) == 0) {
        if (strstr(path, ".igshield_container") != NULL || strstr(path, "igfarmshield") != NULL) {
            return YES;
        }
        return NO;
    }

    // 3. Ocultar el propio tweak IGFarmShield y sus archivos globales
    if (strstr(path, "IGFarmShield") != NULL ||
        strstr(path, "igfarmshield") != NULL ||
        strstr(path, ".igshield_container") != NULL) {
        return YES;
    }

    // 4. Ocultar los dylibs y plists globales de Crane fuera del contenedor
    if (strstr(path, "Crane.dylib") != NULL ||
        strstr(path, "libcrane") != NULL ||
        strstr(path, "CraneGUI") != NULL ||
        strstr(path, "com.opa334.crane") != NULL ||
        strstr(path, "/Application Support/Crane") != NULL ||
        strstr(path, "/Library/Crane") != NULL) {
        return YES;
    }

    // 5. Ocultar rutas de Jailbreak rootless / rootful, gestores de paquetes y hooks
    if (strncmp(path, "/var/jb", 7) == 0 ||
        strncmp(path, "/private/var/jb", 15) == 0 ||
        strncmp(path, "/private/preboot", 16) == 0 ||
        strncmp(path, "/Applications/Sileo.app", 23) == 0 ||
        strncmp(path, "/Applications/Zebra.app", 23) == 0 ||
        strncmp(path, "/Applications/Filza.app", 23) == 0 ||
        strncmp(path, "/Applications/Cydia.app", 23) == 0 ||
        strstr(path, "ellekit") != NULL ||
        strstr(path, "Choicy") != NULL ||
        strstr(path, "choicy") != NULL ||
        strstr(path, "Shadow.dylib") != NULL ||
        strstr(path, "Sileo") != NULL ||
        strstr(path, "sileo") != NULL ||
        strstr(path, "Filza") != NULL ||
        strstr(path, "filza") != NULL ||
        strstr(path, "palera1n") != NULL ||
        strstr(path, "Dopamine") != NULL ||
        strstr(path, "MobileSubstrate") != NULL ||
        strstr(path, "substrate") != NULL ||
        strstr(path, "Substitute") != NULL ||
        strstr(path, "TweakInject") != NULL ||
        strstr(path, "apt/sources.list") != NULL) {
        return YES;
    }
    return NO;
}

static FILE *custom_fopen(const char *path, const char *mode) {
    if (s_spoofSecurity && path && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (isHiddenPathForTargetAppC(path)) {
            errno = ENOENT;
            return NULL;
        }
    }
    return orig_fopen(path, mode);
}

static char *custom_getenv(const char *name) {
    if (s_spoofSecurity && name && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
            strcmp(name, "_MSSafeMode") == 0 ||
            strcmp(name, "_SafeMode") == 0 ||
            strcmp(name, "TZ") == 0 ||
            strncmp(name, "CRANE_", 6) == 0) {
            return NULL;
        }
    }
    return orig_getenv(name);
}

static const char *custom_dyld_get_image_name(uint32_t image_index) {
    const char *name = orig_dyld_get_image_name(image_index);
    if (s_spoofSecurity && name && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (strstr(name, "IGFarmShield") != NULL ||
            strstr(name, "Crane") != NULL ||
            strstr(name, "crane") != NULL ||
            isHiddenPathForTargetAppC(name)) {
            static const char *cleanSystemPaths[] = {
                "/usr/lib/libobjc.A.dylib",
                "/usr/lib/libSystem.B.dylib",
                "/usr/lib/libc++.1.dylib",
                "/usr/lib/libsqlite3.dylib",
                "/usr/lib/libz.1.dylib",
                "/usr/lib/libxml2.2.dylib",
                "/usr/lib/libicucore.A.dylib",
                "/usr/lib/libcompression.dylib"
            };
            return cleanSystemPaths[image_index % 8];
        }
    }
    return name;
}

static int custom_dladdr(const void *addr, Dl_info *info) {
    int ret = orig_dladdr(addr, info);
    if (s_spoofSecurity && ret != 0 && info && info->dli_fname && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (strstr(info->dli_fname, "IGFarmShield") != NULL ||
            strstr(info->dli_fname, "Crane") != NULL ||
            strstr(info->dli_fname, "crane") != NULL ||
            isHiddenPathForTargetAppC(info->dli_fname)) {
            info->dli_fname = "/System/Library/Frameworks/UIKitCore.framework/UIKitCore";
        }
    }
    return ret;
}

// Silencia únicamente alertas intrusivas de Apple ID / iCloud sin bloquear ASAuthorizationController en el login
%hook UIViewController
- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if ((s_spoofSecurity || s_spoofIDs) && [viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
        UIAlertController *ac = (UIAlertController *)viewControllerToPresent;
        NSString *t = [ac.title ?: @"" lowercaseString];
        NSString *m = [ac.message ?: @"" lowercaseString];
        if ([t containsString:@"apple id"] || [t containsString:@"icloud"] ||
            [m containsString:@"apple id"] || [m containsString:@"icloud"]) {
            if (completion) completion();
            return;
        }
    }
    %orig;
}
%end

// Filtra la ventana de la cápsula superior para que la App nunca la vea en .windows
%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if (s_spoofSecurity && url && url.scheme) {
        NSString *s = url.scheme.lowercaseString;
        if ([@[@"sileo", @"zbra", @"filza", @"cydia", @"palera1n", @"santander"] containsObject:s]) {
            return NO;
        }
    }
    return %orig;
}
- (NSArray<UIWindow *> *)windows {
    NSArray<UIWindow *> *orig = %orig;
    if (!persistentBadgeWindow || s_inInternalCall || !orig) return orig;
    if (![orig containsObject:persistentBadgeWindow]) return orig;
    NSMutableArray<UIWindow *> *filtered = [orig mutableCopy];
    [filtered removeObject:persistentBadgeWindow];
    return filtered;
}
%end

%hook UIWindowScene
- (NSArray<UIWindow *> *)windows {
    NSArray<UIWindow *> *orig = %orig;
    if (!persistentBadgeWindow || s_inInternalCall || !orig) return orig;
    if (![orig containsObject:persistentBadgeWindow]) return orig;
    NSMutableArray<UIWindow *> *filtered = [orig mutableCopy];
    [filtered removeObject:persistentBadgeWindow];
    return filtered;
}
%end

%hook UIPasteboard
- (NSInteger)changeCount {
    if (!s_spoofSecurity || !liveContainerProfile) return %orig;
    return [liveContainerProfile[@"pasteboardCount"] integerValue];
}
%end

// ============================================================================
// ZONA HORARIA E IDIOMA SINCRONIZADOS CON LA IP DEL CONTENEDOR
// ============================================================================
%hook NSTimeZone
+ (NSTimeZone *)systemTimeZone {
    if (!s_spoofLocation || !liveContainerProfile) return %orig;
    NSString *tzName = liveContainerProfile[@"timeZone"];
    if (!tzName || [tzName hasPrefix:@"Sincronizando"] || [tzName hasPrefix:@"Sin "]) return %orig;
    return [NSTimeZone timeZoneWithName:tzName] ?: %orig;
}
+ (NSTimeZone *)localTimeZone {
    if (!s_spoofLocation) return %orig;
    return [self systemTimeZone];
}
+ (NSTimeZone *)defaultTimeZone {
    if (!s_spoofLocation) return %orig;
    return [self systemTimeZone];
}
%end

%hook NSLocale
+ (NSLocale *)currentLocale {
    if (!s_spoofLocation || !liveContainerProfile) return %orig;
    NSString *locID = liveContainerProfile[@"localeID"];
    if (!locID) return %orig;
    return [NSLocale localeWithLocaleIdentifier:locID] ?: %orig;
}
+ (NSLocale *)autoupdatingCurrentLocale {
    if (!s_spoofLocation) return %orig;
    return [self currentLocale];
}
+ (NSArray<NSString *> *)preferredLanguages {
    if (!s_spoofLocation || !liveContainerProfile) return %orig;
    NSString *locID = liveContainerProfile[@"localeID"] ?: @"en_US";
    NSString *lang = [locID stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    return @[lang, @"en-US"];
}
%end

// ============================================================================
// OCULTACIÓN DE TÚNEL/PROXY (__SCOPED__ + GETIFADDRS) Y BLOQUEO DE HTTP/3
// ============================================================================
static CFDictionaryRef custom_CFNetworkCopySystemProxySettings(void) {
    CFDictionaryRef origRef = orig_CFNetworkCopySystemProxySettings ? orig_CFNetworkCopySystemProxySettings() : NULL;
    if (!origRef || !s_spoofNetwork) return origRef;
    if (!isCallerFromTargetApp(__builtin_return_address(0))) return origRef;

    NSDictionary *origDict = (__bridge NSDictionary *)origRef;
    NSMutableDictionary *cleanDict = [NSMutableDictionary dictionary];

    NSDictionary *scoped = origDict[@"__SCOPED__"];
    if ([scoped isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *cleanScoped = [NSMutableDictionary dictionary];
        for (NSString *ifKey in scoped) {
            NSString *low = [ifKey lowercaseString];
            if ([low containsString:@"utun"] ||
                [low containsString:@"tun"] ||
                [low containsString:@"tap"] ||
                [low containsString:@"ppp"] ||
                [low containsString:@"ipsec"] ||
                [low containsString:@"wg"]) {
                continue;
            }
            cleanScoped[ifKey] = scoped[ifKey];
        }
        if (cleanScoped.count == 0) {
            cleanScoped[@"en0"] = @{};
        }
        cleanDict[@"__SCOPED__"] = cleanScoped;
    } else {
        cleanDict[@"__SCOPED__"] = @{@"en0": @{}};
    }

    CFRelease(origRef);
    return (__bridge_retained CFDictionaryRef)cleanDict;
}

static CFArrayRef custom_CFNetworkCopyProxiesForURL(CFURLRef url, CFDictionaryRef proxySettings) {
    if (s_spoofNetwork && isCallerFromTargetApp(__builtin_return_address(0))) {
        NSDictionary *directProxy = @{ @"kCFProxyTypeKey" : @"kCFProxyTypeNone" };
        NSArray *arr = @[ directProxy ];
        return (__bridge_retained CFArrayRef)arr;
    }
    return orig_CFNetworkCopyProxiesForURL ? orig_CFNetworkCopyProxiesForURL(url, proxySettings) : NULL;
}

%hook NSMutableURLRequest
- (void)setAssumesHTTP3Capable:(BOOL)capable {
    if (s_spoofNetwork) {
        %orig(NO);
        return;
    }
    %orig(capable);
}
- (BOOL)assumesHTTP3Capable {
    if (s_spoofNetwork) return NO;
    return %orig;
}
%end

%hook NSURLSessionConfiguration
- (NSDictionary *)connectionProxyDictionary {
    if (s_spoofNetwork && isCallerFromTargetApp(__builtin_return_address(0))) {
        return @{};
    }
    return %orig;
}
%end

%hook CTCarrier
- (NSString *)carrierName {
    if (!s_spoofNetwork || !liveContainerProfile) return %orig;
    if (!s_isCellularMode) return nil;
    return liveContainerProfile[@"CarrierName"] ?: @"T-Mobile";
}
- (NSString *)mobileCountryCode {
    if (!s_spoofNetwork || !liveContainerProfile) return %orig;
    if (!s_isCellularMode) return nil;
    return liveContainerProfile[@"CarrierMCC"] ?: @"310";
}
- (NSString *)mobileNetworkCode {
    if (!s_spoofNetwork || !liveContainerProfile) return %orig;
    if (!s_isCellularMode) return nil;
    return liveContainerProfile[@"CarrierMNC"] ?: @"260";
}
- (NSString *)isoCountryCode {
    if (!s_spoofNetwork || !liveContainerProfile) return %orig;
    if (!s_isCellularMode) return nil;
    return liveContainerProfile[@"CarrierISO"] ?: @"us";
}
- (BOOL)allowsVOIP { return YES; }
%end

%hook CTTelephonyNetworkInfo
- (NSString *)currentRadioAccessTechnology {
    if (!s_spoofNetwork || !liveContainerProfile) return %orig;
    if (!s_isCellularMode) return nil;
    return CTRadioAccessTechnologyLTE;
}
- (NSDictionary<NSString *, NSString *> *)serviceCurrentRadioAccessTechnology {
    if (!s_spoofNetwork || !liveContainerProfile) return %orig;
    if (!s_isCellularMode) return nil;
    return @{@"0000000100000001": CTRadioAccessTechnologyLTE};
}
%end

// Desvincula limpiamente los nodos utun/ppp/ipsec sin duplicar lo0 y aísla la IP privada en en0
static int custom_getifaddrs(struct ifaddrs **ifap) {
    int res = orig_getifaddrs(ifap);
    if (res != 0 || !ifap || !*ifap || !s_spoofNetwork || s_spoofedLanAddr == 0) return res;
    if (!isCallerFromTargetApp(__builtin_return_address(0))) return res;

    struct ifaddrs *head = *ifap;
    struct ifaddrs *prev = NULL;
    struct ifaddrs *curr = head;

    while (curr) {
        BOOL isTunnelIf = NO;
        if (curr->ifa_name) {
            if (strncmp(curr->ifa_name, "utun", 4) == 0 ||
                strncmp(curr->ifa_name, "ppp", 3) == 0 ||
                strncmp(curr->ifa_name, "ipsec", 5) == 0 ||
                strncmp(curr->ifa_name, "tun", 3) == 0 ||
                strncmp(curr->ifa_name, "tap", 3) == 0) {
                isTunnelIf = YES;
            } else if (strcmp(curr->ifa_name, "en0") == 0 &&
                       curr->ifa_addr && curr->ifa_addr->sa_family == AF_INET) {
                struct sockaddr_in *addr = (struct sockaddr_in *)curr->ifa_addr;
                addr->sin_addr.s_addr = s_spoofedLanAddr;
            }
        }

        if (isTunnelIf) {
            if (prev) {
                prev->ifa_next = curr->ifa_next;
            } else {
                head = curr->ifa_next;
            }
        } else {
            prev = curr;
        }
        curr = curr->ifa_next;
    }
    *ifap = head;
    return res;
}

static CFDictionaryRef custom_CNCopyCurrentNetworkInfo(CFStringRef interfaceName) {
    if (!s_spoofNetwork || !liveContainerProfile) return orig_CNCopyCurrentNetworkInfo(interfaceName);
    if (s_isCellularMode) {
        return NULL;
    }
    NSDictionary *fakeWifi = @{
        @"SSID": liveContainerProfile[@"ssid"] ?: @"HomeWiFi-5G",
        @"BSSID": liveContainerProfile[@"bssid"] ?: @"a4:83:e7:21:9a:10",
        @"SSIDDATA": [(liveContainerProfile[@"ssid"] ?: @"HomeWiFi-5G") dataUsingEncoding:NSUTF8StringEncoding]
    };
    return (__bridge_retained CFDictionaryRef)fakeWifi;
}

// ============================================================================
// TELEMETRÍA ORGÁNICA DEL TELÉFONO (RESPETANDO EL IDFV NATIVO DE CRANE)
// ============================================================================
%hook UIDevice
- (NSString *)name {
    if (!s_spoofHardware) return %orig;
    return @"iPhone";
}
- (NSUUID *)identifierForVendor {
    NSUUID *origUUID = %orig;
    if (!origCraneIDFV && origUUID) {
        origCraneIDFV = [origUUID UUIDString];
    }
    return origUUID;
}
- (float)batteryLevel {
    if (!s_spoofHardware || !liveContainerProfile) return %orig;
    float baseBat = [liveContainerProfile[@"batteryLevel"] floatValue];
    NSTimeInterval elapsedMinutes = ([[NSDate date] timeIntervalSince1970] - sessionStartTimestamp) / 60.0;
    float drop = (float)((int)(elapsedMinutes / 12.0)) * 0.01f;
    return MAX(0.15f, baseBat - drop);
}
- (UIDeviceBatteryState)batteryState {
    if (!s_spoofHardware) return %orig;
    return UIDeviceBatteryStateUnplugged;
}
%end

%hook AVAudioSession
- (float)outputVolume {
    if (!s_spoofHardware || !liveContainerProfile) return %orig;
    return liveContainerProfile[@"audioVolume"] ? [liveContainerProfile[@"audioVolume"] floatValue] : 0.50f;
}
%end

static int custom_statfs(const char *path, struct statfs *buf) {
    int ret = orig_statfs(path, buf);
    if (ret == 0 && buf && s_spoofHardware && liveContainerProfile && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (liveContainerProfile[@"freeBytes"] && buf->f_bsize > 0) {
            unsigned long long baseFree = [liveContainerProfile[@"freeBytes"] unsignedLongLongValue];
            unsigned long long driftBytes = (unsigned long long)(([[NSDate date] timeIntervalSince1970] - sessionStartTimestamp) * 4096.0);
            unsigned long long finalFree = baseFree - (driftBytes % (20 * 1024 * 1024));
            uint64_t blocks = finalFree / buf->f_bsize;
            buf->f_bavail = blocks;
            buf->f_bfree = blocks;
        }
    }
    return ret;
}

%hook NSFileManager
- (NSDictionary<NSFileAttributeKey, id> *)attributesOfFileSystemForPath:(NSString *)path error:(NSError * _Nullable *)error {
    NSDictionary *orig = %orig;
    if (!s_spoofHardware || !orig || !liveContainerProfile || !isCallerFromTargetApp(__builtin_return_address(0))) return orig;
    NSMutableDictionary *modified = [orig mutableCopy];
    if (liveContainerProfile[@"freeBytes"]) {
        unsigned long long baseFree = [liveContainerProfile[@"freeBytes"] unsignedLongLongValue];
        unsigned long long driftBytes = (unsigned long long)(([[NSDate date] timeIntervalSince1970] - sessionStartTimestamp) * 4096.0);
        modified[NSFileSystemFreeSize] = @(baseFree - (driftBytes % (20 * 1024 * 1024)));
    }
    return modified;
}
- (BOOL)fileExistsAtPath:(NSString *)path {
    if (s_spoofSecurity && path && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (isHiddenPathForTargetAppC([path UTF8String])) {
            return NO;
        }
    }
    return %orig;
}
- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (s_spoofSecurity && path && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (isHiddenPathForTargetAppC([path UTF8String])) {
            return NO;
        }
    }
    return %orig;
}
- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if (s_spoofSecurity && path && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (isHiddenPathForTargetAppC([path UTF8String])) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
            return nil;
        }
    }
    return %orig;
}
- (NSDictionary<NSFileAttributeKey, id> *)attributesOfItemAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if (s_spoofSecurity && path && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (isHiddenPathForTargetAppC([path UTF8String])) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
            return nil;
        }
    }
    return %orig;
}
%end

%hook NSURL
- (BOOL)checkResourceIsReachableAndReturnError:(NSError * _Nullable *)error {
    if (s_spoofSecurity && [self isFileURL] && isCallerFromTargetApp(__builtin_return_address(0))) {
        NSString *p = [self path];
        if (p && isHiddenPathForTargetAppC([p UTF8String])) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
            return NO;
        }
    }
    return %orig;
}
%end

%hook NSProcessInfo
- (NSDictionary<NSString *, NSString *> *)environment {
    NSDictionary *orig = %orig;
    if (!s_spoofSecurity || !orig || !isCallerFromTargetApp(__builtin_return_address(0))) {
        return orig;
    }
    NSMutableDictionary *cleanEnv = [orig mutableCopy];
    for (NSString *k in [orig allKeys]) {
        if ([k isEqualToString:@"DYLD_INSERT_LIBRARIES"] ||
            [k isEqualToString:@"_MSSafeMode"] ||
            [k isEqualToString:@"_SafeMode"] ||
            [k isEqualToString:@"TZ"] ||
            [k hasPrefix:@"CRANE_"]) {
            [cleanEnv removeObjectForKey:k];
        }
    }
    return cleanEnv;
}
%end

static int custom_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (ret == 0 && name && oldlenp && liveContainerProfile && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (strcmp(name, "kern.bootsessionuuid") == 0 && s_spoofIDs) {
            NSString *bootUUID = liveContainerProfile[@"bootSessionUUID"];
            if (bootUUID) {
                const char *uuidStr = [bootUUID UTF8String];
                size_t len = strlen(uuidStr) + 1;
                if (oldp && *oldlenp >= len) memcpy(oldp, uuidStr, len);
                *oldlenp = len;
            }
        }
    }
    return ret;
}

%hook UIScreen
- (CGFloat)brightness {
    if (!s_spoofHardware || !liveContainerProfile) return %orig;
    return [liveContainerProfile[@"brightness"] floatValue];
}
- (BOOL)isCaptured {
    if (!s_spoofSecurity) return %orig;
    return NO;
}
%end

%ctor {
    // 1. Hookear dladdr y getenv primero para que ensureProfileLoaded resuelva limpio
    MSHookFunction((void *)dladdr, (void *)custom_dladdr, (void **)&orig_dladdr);
    MSHookFunction((void *)getenv, (void *)custom_getenv, (void **)&orig_getenv);

    // 2. Cargar perfil en memoria desde Foundation sin tocar UIKit en %ctor
    ensureProfileLoaded();

    // 3. Activar el resto de hooks C seguros en ElleKit
    MSHookFunction((void *)_dyld_get_image_name, (void *)custom_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
    MSHookFunction((void *)fopen, (void *)custom_fopen, (void **)&orig_fopen);
    MSHookFunction((void *)sysctlbyname, (void *)custom_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)statfs, (void *)custom_statfs, (void **)&orig_statfs);
    MSHookFunction((void *)getifaddrs, (void *)custom_getifaddrs, (void **)&orig_getifaddrs);
    MSHookFunction((void *)CNCopyCurrentNetworkInfo, (void *)custom_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo);

    void *symProxySettings = dlsym(RTLD_DEFAULT, "CFNetworkCopySystemProxySettings");
    if (symProxySettings) {
        MSHookFunction(symProxySettings, (void *)custom_CFNetworkCopySystemProxySettings, (void **)&orig_CFNetworkCopySystemProxySettings);
    }
    void *symProxiesForURL = dlsym(RTLD_DEFAULT, "CFNetworkCopyProxiesForURL");
    if (symProxiesForURL) {
        MSHookFunction(symProxiesForURL, (void *)custom_CFNetworkCopyProxiesForURL, (void **)&orig_CFNetworkCopyProxiesForURL);
    }

    %init;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showStartupBannerAndPersistentIcon(0);
    });
}
