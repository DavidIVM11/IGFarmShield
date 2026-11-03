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
#import <netinet/in.h>
#import <sys/socket.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <os/lock.h>
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
#define CURRENT_SCHEMA_VERSION 33

@interface NSMutableURLRequest (HTTP3Disable)
- (void)setAssumesHTTP3Capable:(BOOL)capable;
- (BOOL)assumesHTTP3Capable;
@end

// Ventana superpuesta aislada de eventos táctiles y filtrada de UIApplication/UIWindowScene.windows
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

// Banderas en RAM para evaluación O(1)
static BOOL s_profileInitialized = NO;
static BOOL s_shieldActive = NO;
static BOOL s_spoofIDs = NO;
static BOOL s_spoofNetwork = NO;
static BOOL s_spoofLocation = NO;
static BOOL s_spoofHardware = NO;
static BOOL s_spoofSecurity = NO;
static BOOL s_isCellularMode = YES;
static char s_containerHomePath[PATH_MAX] = {0};
static size_t s_containerHomeLen = 0;
static __thread BOOL s_inInternalCall = NO;

// Caché ligera de verificación de túnel activo para no penalizar sockets
static os_unfair_lock s_tunnelCacheLock = OS_UNFAIR_LOCK_INIT;
static CFAbsoluteTime s_lastTunnelCheckTime = 0;
static BOOL s_cachedTunnelActive = NO;
static BOOL s_cachedUtunOnlyActive = NO;

static int (*orig_dladdr)(const void *, Dl_info *) = NULL;
static const char *(*orig_dyld_get_image_name)(uint32_t image_index) = NULL;
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*orig_statfs)(const char *, struct statfs *) = NULL;
static int (*orig_access)(const char *, int) = NULL;
static int (*orig_stat)(const char *, struct stat *) = NULL;
static int (*orig_lstat)(const char *, struct stat *) = NULL;
static FILE *(*orig_fopen)(const char *, const char *) = NULL;
static char *(*orig_getenv)(const char *) = NULL;
static int (*orig_getifaddrs)(struct ifaddrs **) = NULL;
static int (*orig_connect)(int, const struct sockaddr *, socklen_t) = NULL;
static ssize_t (*orig_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t) = NULL;
static ssize_t (*orig_sendmsg)(int, const struct msghdr *, int) = NULL;
static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef) = NULL;
static CFDictionaryRef (*orig_CFNetworkCopySystemProxySettings)(void) = NULL;
static CFArrayRef (*orig_CFNetworkCopyProxiesForURL)(CFURLRef, CFDictionaryRef) = NULL;

static NSString *s_cfProxyTypeKey = nil;
static NSString *s_cfProxyTypeNone = nil;

static NSString *resolveCFStringSymbol(const char *symName, NSString *fallback) {
    void *sym = dlsym(RTLD_DEFAULT, symName);
    if (sym) {
        CFStringRef ref = *(CFStringRef *)sym;
        if (ref) return (__bridge NSString *)ref;
    }
    return fallback;
}

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

static BOOL isTunnelInterfaceNameC(const char *ifName) {
    if (!ifName) return NO;
    return (strncmp(ifName, "utun", 4) == 0 ||
            strncmp(ifName, "ppp", 3) == 0 ||
            strncmp(ifName, "ipsec", 5) == 0 ||
            strncmp(ifName, "tun", 3) == 0 ||
            strncmp(ifName, "tap", 3) == 0 ||
            strncmp(ifName, "wg", 2) == 0);
}

// Verifica en <1ms (con caché de 0.75s) si Shadowrocket tiene interfaz utun IPv4 o Proxy de sistema activo
static void refreshTunnelStatusIfNeeded(BOOL *outAnyTunnelOrProxy, BOOL *outUtunActive) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&s_tunnelCacheLock);
    if ((now - s_lastTunnelCheckTime) < 0.75) {
        if (outAnyTunnelOrProxy) *outAnyTunnelOrProxy = s_cachedTunnelActive;
        if (outUtunActive) *outUtunActive = s_cachedUtunOnlyActive;
        os_unfair_lock_unlock(&s_tunnelCacheLock);
        return;
    }
    os_unfair_lock_unlock(&s_tunnelCacheLock);

    BOOL utunUp = NO;
    BOOL proxyUp = NO;

    struct ifaddrs *interfaces = NULL;
    int (*getif_fn)(struct ifaddrs **) = orig_getifaddrs ? orig_getifaddrs : getifaddrs;
    if (getif_fn(&interfaces) == 0 && interfaces != NULL) {
        struct ifaddrs *cur = interfaces;
        while (cur) {
            if (cur->ifa_name && (cur->ifa_flags & IFF_UP) && cur->ifa_addr) {
                if (isTunnelInterfaceNameC(cur->ifa_name) && cur->ifa_addr->sa_family == AF_INET) {
                    struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
                    if (sin->sin_addr.s_addr != 0) {
                        utunUp = YES;
                        break;
                    }
                }
            }
            cur = cur->ifa_next;
        }
        freeifaddrs(interfaces);
    }

    if (!utunUp && orig_CFNetworkCopySystemProxySettings) {
        s_inInternalCall = YES;
        CFDictionaryRef pRef = orig_CFNetworkCopySystemProxySettings();
        s_inInternalCall = NO;
        if (pRef) {
            NSDictionary *pDict = (__bridge NSDictionary *)pRef;
            if ([pDict[@"HTTPEnable"] intValue] != 0 ||
                [pDict[@"HTTPSEnable"] intValue] != 0 ||
                [pDict[@"SOCKSEnable"] intValue] != 0 ||
                [pDict[@"ProxyAutoConfigEnable"] intValue] != 0) {
                proxyUp = YES;
            }
            CFRelease(pRef);
        }
    }

    BOOL anyActive = (utunUp || proxyUp);
    os_unfair_lock_lock(&s_tunnelCacheLock);
    s_lastTunnelCheckTime = now;
    s_cachedTunnelActive = anyActive;
    s_cachedUtunOnlyActive = utunUp;
    os_unfair_lock_unlock(&s_tunnelCacheLock);

    if (outAnyTunnelOrProxy) *outAnyTunnelOrProxy = anyActive;
    if (outUtunActive) *outUtunActive = utunUp;
}

static BOOL isCallerFromTargetApp(const void *retAddr) {
    if (s_inInternalCall || !retAddr || !orig_dladdr) return NO;
    Dl_info info;
    if (orig_dladdr(retAddr, &info) != 0 && info.dli_fname) {
        if (strstr(info.dli_fname, "IGFarmShield") != NULL ||
            strstr(info.dli_fname, "Crane") != NULL ||
            strstr(info.dli_fname, "crane") != NULL ||
            strstr(info.dli_fname, "CFNetwork") != NULL ||
            strstr(info.dli_fname, "libnetwork") != NULL ||
            strstr(info.dli_fname, "libswift") != NULL) {
            return NO;
        }
        if (strstr(info.dli_fname, "/Containers/Bundle/Application/") != NULL) {
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

    // Intento de lectura global; si Seatbelt bloquea /var/jb/var/mobile, respaldamos con localPlist
    NSDictionary *loadedGlobal = [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST];
    BOOL canReadGlobalPlist = ([loadedGlobal isKindOfClass:[NSDictionary class]] && loadedGlobal.count > 0);
    NSMutableDictionary *globalSt = canReadGlobalPlist ? [loadedGlobal mutableCopy] : [NSMutableDictionary dictionary];
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
    if ([diskLoaded isKindOfClass:[NSDictionary class]] && diskLoaded[@"bootSessionUUID"]) {
        profile = [diskLoaded mutableCopy];
    } else if (settingsEntry && settingsEntry[@"bootSessionUUID"]) {
        profile = [settingsEntry mutableCopy];
    }

    if (profile && settingsEntry) {
        for (NSString *k in @[@"enabled", @"effectiveShieldActive", @"containerName", @"craneIdentifier", @"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity", @"locationAnchored", @"timeZone", @"localeID", @"CarrierMode", @"CarrierName", @"CarrierMCC", @"CarrierMNC", @"CarrierISO", @"ispName", @"cityCountry", @"lastSyncedIP", @"localIP", @"ssid", @"bssid", @"bootSessionUUID", @"freeBytes", @"batteryLevel", @"audioVolume", @"brightness", @"pasteboardCount"]) {
            if (settingsEntry[k] != nil) profile[k] = settingsEntry[k];
        }
    }

    NSString *existingProfileIDFV = ([profile[@"idfv"] isKindOfClass:[NSString class]] && [profile[@"idfv"] length] >= 32)
        ? [profile[@"idfv"] uppercaseString]
        : nil;
    NSString *nativeCraneUUID = (origCraneIDFV && origCraneIDFV.length >= 32)
        ? [origCraneIDFV uppercaseString]
        : (([craneID containsString:@"-"] && craneID.length >= 32)
            ? [craneID uppercaseString]
            : (existingProfileIDFV ?: [[NSUUID UUID] UUIDString]));

    if (!profile || !profile[@"bootSessionUUID"]) {
        uint64_t seed = randomSeed64(keyUUID);
        NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59", @"f0:9f:c2", @"04:d6:aa"];
        NSArray *ssidPrefixes = @[@"HomeWiFi", @"ATT-Fiber", @"Xfinity-WiFi", @"SpectrumSetup", @"NETGEAR", @"TP-Link"];

        NSString *oui = ouis[seed % ouis.count];
        NSString *ssidPref = ssidPrefixes[(seed >> 3) % ssidPrefixes.count];
        NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x",
                           oui, (unsigned int)((seed >> 8) & 0xFF), (unsigned int)((seed >> 16) & 0xFF), (unsigned int)((seed >> 24) & 0xFF)];
        NSString *ssid = [NSString stringWithFormat:@"%@-%02X-5G", ssidPref, (unsigned int)(seed & 0xFF)];
        NSString *localIP = [NSString stringWithFormat:@"192.168.1.%d", 15 + (int)(seed % 220)];
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
            @"effectiveShieldActive": @(manualEnabled),
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

    BOOL contOn = [profile[@"enabled"] boolValue];
    if (canReadGlobalPlist) {
        BOOL masterOn = [globalSt[@"masterEnabled"] boolValue];
        BOOL appOn = NO;
        if ([bundleID isEqualToString:@"com.burbn.instagram"]) appOn = [globalSt[@"enableIG"] boolValue];
        else if ([bundleID isEqualToString:@"com.reddit.Reddit"]) appOn = [globalSt[@"enableReddit"] boolValue];
        s_shieldActive = (masterOn && appOn && contOn);
        profile[@"effectiveShieldActive"] = @(s_shieldActive);
    } else {
        // Respaldo inmune al Sandbox usando el estado precalculado en el propio contenedor
        if (profile[@"effectiveShieldActive"] != nil) {
            s_shieldActive = [profile[@"effectiveShieldActive"] boolValue];
        } else {
            s_shieldActive = contOn;
        }
    }

    [profile writeToFile:localPlist atomically:YES];

    if (canReadGlobalPlist && matchedSettingsKey && byUUID[matchedSettingsKey]) {
        NSMutableDictionary *updatedEntry = [byUUID[matchedSettingsKey] mutableCopy];
        if (![updatedEntry[@"path"] isEqualToString:homePath] ||
            ![updatedEntry[@"idfv"] isEqualToString:nativeCraneUUID]) {
            updatedEntry[@"path"] = homePath;
            updatedEntry[@"idfv"] = nativeCraneUUID;
            byUUID[matchedSettingsKey] = updatedEntry;
            globalSt[@"containersByUUID"] = byUUID;
            [globalSt writeToFile:GLOBAL_STATE_PLIST atomically:YES];
        }
    }

    liveContainerProfile = profile;

    s_spoofIDs = s_shieldActive && (profile[@"spoofIDs"] == nil ? YES : [profile[@"spoofIDs"] boolValue]);
    s_spoofNetwork = s_shieldActive && (profile[@"spoofNetwork"] == nil ? YES : [profile[@"spoofNetwork"] boolValue]);
    s_spoofLocation = s_shieldActive && (profile[@"spoofLocation"] == nil ? YES : [profile[@"spoofLocation"] boolValue]);
    s_spoofHardware = s_shieldActive && (profile[@"spoofHardware"] == nil ? YES : [profile[@"spoofHardware"] boolValue]);
    s_spoofSecurity = s_shieldActive && (profile[@"spoofSecurity"] == nil ? YES : [profile[@"spoofSecurity"] boolValue]);
    s_isCellularMode = ![profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"];

    if (s_spoofLocation && profile[@"timeZone"]) {
        applyLowLevelCTimeZone(profile[@"timeZone"]);
    }

    s_inInternalCall = NO;
}

// ============================================================================
// CÁPSULA Y TOAST 100% AISLADOS EN OVERLAY PROPIO (CERO HUELLA EN KEYWINDOW)
// ============================================================================
static void showStartupBannerAndPersistentIcon(int attempt) {
    if (bannerShownThisSession) return;
    ensureProfileLoaded();
    if (!liveContainerProfile) return;

    s_inInternalCall = YES;
    if (!origCraneIDFV) {
        NSUUID *u = [[UIDevice currentDevice] identifierForVendor];
        if (u) origCraneIDFV = [[u UUIDString] uppercaseString];
    }

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

    BOOL tunnelUp = NO;
    refreshTunnelStatusIfNeeded(&tunnelUp, NULL);

    if (!persistentBadgeWindow) {
        if (activeScene) {
            persistentBadgeWindow = [[_UIStatusBarLocalOverlayWindow alloc] initWithWindowScene:activeScene];
        } else {
            persistentBadgeWindow = [[_UIStatusBarLocalOverlayWindow alloc] initWithFrame:screenBounds];
        }
        persistentBadgeWindow.frame = CGRectMake(0, 0, screenBounds.size.width, 92);
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
            if (s_spoofNetwork && !tunnelUp) {
                badgePill.backgroundColor = [UIColor colorWithRed:0.78 green:0.16 blue:0.16 alpha:0.95];
                badgePill.text = [NSString stringWithFormat:@" ⛔ %@ (SIN PROXY) ", cName];
            } else {
                badgePill.backgroundColor = [UIColor colorWithRed:0.04 green:0.52 blue:0.24 alpha:0.94];
                badgePill.text = [NSString stringWithFormat:@" 🛡️ %@ ", cName];
            }
        } else {
            badgePill.backgroundColor = [UIColor colorWithRed:0.38 green:0.38 blue:0.42 alpha:0.90];
            badgePill.text = [NSString stringWithFormat:@" ⚪ %@ ", cName];
        }

        [badgePill sizeToFit];
        CGFloat pillW = MIN(MAX(badgePill.bounds.size.width + 12.0, 62.0), 210.0);
        badgePill.frame = CGRectMake((screenBounds.size.width - pillW) / 2.0, 18.0, pillW, 16.0);

        [rootVC.view addSubview:badgePill];
        persistentBadgeWindow.hidden = NO;
    }

    NSString *netMode = s_isCellularMode
        ? [NSString stringWithFormat:@"4G: %@", prof[@"CarrierName"] ?: @"Móvil"]
        : @"Wi-Fi Residencial";
    int batPct = (int)([prof[@"batteryLevel"] floatValue] * 100.0f);

    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, screenBounds.size.width - 32, 42)];
    toast.layer.cornerRadius = 10.0;
    toast.clipsToBounds = YES;
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont boldSystemFontOfSize:11.5];
    toast.numberOfLines = 2;
    toast.textColor = [UIColor whiteColor];
    toast.userInteractionEnabled = NO;

    if (s_shieldActive) {
        if (s_spoofNetwork && !tunnelUp) {
            toast.backgroundColor = [UIColor colorWithRed:0.78 green:0.16 blue:0.16 alpha:0.95];
            toast.text = [NSString stringWithFormat:@"⛔ Kill-Switch Activo en %@\nEnciende Shadowrocket para desbloquear la red", cName];
        } else {
            toast.backgroundColor = [UIColor colorWithRed:0.06 green:0.48 blue:0.24 alpha:0.94];
            toast.text = [NSString stringWithFormat:@"🛡️ %@ • %@ • Bat: %d%%\n%@ • %@",
                          cName, netMode, batPct, prof[@"lastSyncedIP"] ?: @"TCP Protegido", prof[@"timeZone"] ?: @""];
        }
    } else {
        toast.backgroundColor = [UIColor colorWithRed:0.45 green:0.45 blue:0.48 alpha:0.92];
        toast.text = [NSString stringWithFormat:@"⚪ %@ • En Pausa Manual (Datos Nativos)", cName];
    }

    // Se inserta en nuestra propia ventana invisible, jamás en targetWin de Instagram
    [persistentBadgeWindow.rootViewController.view addSubview:toast];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.35 animations:^{
            toast.alpha = 0.0;
        } completion:^(BOOL f) {
            [toast removeFromSuperview];
            if (persistentBadgeWindow) {
                persistentBadgeWindow.frame = CGRectMake(0, 0, screenBounds.size.width, 40);
            }
        }];
    });
}

// ============================================================================
// MODO INVISIBLE EN C Y OBJECTIVE-C
// ============================================================================
static BOOL isHiddenPathForTargetAppC(const char *path) {
    if (!path) return NO;

    if (strstr(path, "Cryptex") != NULL || strstr(path, "cryptex") != NULL) {
        return NO;
    }

    if (s_containerHomeLen > 0 && strncmp(path, s_containerHomePath, s_containerHomeLen) == 0) {
        if (strstr(path, ".igshield_container") != NULL || strstr(path, "igfarmshield") != NULL) {
            return YES;
        }
        return NO;
    }

    if (strstr(path, "IGFarmShield") != NULL ||
        strstr(path, "igfarmshield") != NULL ||
        strstr(path, ".igshield_container") != NULL) {
        return YES;
    }

    if (strstr(path, "Crane.dylib") != NULL ||
        strstr(path, "libcrane") != NULL ||
        strstr(path, "CraneGUI") != NULL ||
        strstr(path, "com.opa334.crane") != NULL ||
        strstr(path, "/Application Support/Crane") != NULL ||
        strstr(path, "/Library/Crane") != NULL) {
        return YES;
    }

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

static int custom_access(const char *path, int amode) {
    if (s_spoofSecurity && path && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (isHiddenPathForTargetAppC(path)) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_access(path, amode);
}

static int custom_stat(const char *path, struct stat *buf) {
    if (s_spoofSecurity && path && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (isHiddenPathForTargetAppC(path)) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_stat(path, buf);
}

static int custom_lstat(const char *path, struct stat *buf) {
    if (s_spoofSecurity && path && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (isHiddenPathForTargetAppC(path)) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_lstat(path, buf);
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
// CAPA POSIX ANTI-FUGAS: BLOQUEO REAL DE QUIC (UDP 443), IPV6 Y KILL-SWITCH
// ============================================================================
static BOOL isSocketDatagram(int sockfd) {
    int sockType = 0;
    socklen_t optLen = sizeof(sockType);
    if (getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &sockType, &optLen) == 0) {
        return (sockType == SOCK_DGRAM);
    }
    return NO;
}

static BOOL isPrivateOrLoopbackIPv4(uint32_t hostOrderIP, BOOL *outIsLoopback) {
    if (hostOrderIP == 0 || (hostOrderIP >> 24) == 127) {
        if (outIsLoopback) *outIsLoopback = YES;
        return YES;
    }
    if (outIsLoopback) *outIsLoopback = NO;
    // 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16
    if ((hostOrderIP >> 24) == 10) return YES;
    if ((hostOrderIP & 0xFFF00000) == 0xAC100000) return YES;
    if ((hostOrderIP & 0xFFFF0000) == 0xC0A80000) return YES;
    if ((hostOrderIP & 0xFFFF0000) == 0xA9FE0000) return YES;
    return NO;
}

// Evalúa si un destino POSIX debe bloquearse; devuelve 0 si es seguro o el código errno a rechazar
static int evaluateSocketPolicyForAddress(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    if (!s_spoofNetwork || s_inInternalCall || !addr) return 0;

    if (addr->sa_family == AF_INET && addrlen >= sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
        uint32_t ipHost = ntohl(sin->sin_addr.s_addr);
        BOOL isLoopback = NO;
        BOOL isLan = isPrivateOrLoopbackIPv4(ipHost, &isLoopback);
        if (isLoopback) return 0;

        uint16_t dstPort = ntohs(sin->sin_port);
        // 1. Bloqueo inmediato de QUIC / HTTP/3 (UDP 443 y 80) para forzar fallback TCP instantáneo
        if ((dstPort == 443 || dstPort == 80) && isSocketDatagram(sockfd)) {
            return EHOSTUNREACH;
        }

        // 2. Kill-Switch: si no es tráfico LAN/Fake-IP local y Shadowrocket está caído, impide salir por el ISP real
        if (!isLan) {
            BOOL tunnelOrProxyUp = NO;
            refreshTunnelStatusIfNeeded(&tunnelOrProxyUp, NULL);
            if (!tunnelOrProxyUp) {
                return ENETUNREACH;
            }
        }
        return 0;
    }

    if (addr->sa_family == AF_INET6 && addrlen >= sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
        if (IN6_IS_ADDR_LOOPBACK(&sin6->sin6_addr) || IN6_IS_ADDR_UNSPECIFIED(&sin6->sin6_addr)) {
            return 0;
        }
        // Si es IPv4-mapped IPv6 (::ffff:a.b.c.d), aplicamos la misma política IPv4
        if (IN6_IS_ADDR_V4MAPPED(&sin6->sin6_addr)) {
            uint32_t v4Host = ntohl(*(const uint32_t *)(&sin6->sin6_addr.s6_addr[12]));
            BOOL isLoop = NO;
            BOOL isLan = isPrivateOrLoopbackIPv4(v4Host, &isLoop);
            if (isLoop) return 0;
            uint16_t dstPort = ntohs(sin6->sin6_port);
            if ((dstPort == 443 || dstPort == 80) && isSocketDatagram(sockfd)) {
                return EHOSTUNREACH;
            }
            if (!isLan) {
                BOOL tunnelOrProxyUp = NO;
                refreshTunnelStatusIfNeeded(&tunnelOrProxyUp, NULL);
                if (!tunnelOrProxyUp) return ENETUNREACH;
            }
            return 0;
        }
        // Bloquea cualquier salida IPv6 nativa para impedir bypass fuera del túnel IPv4 de Shadowrocket
        return ENETUNREACH;
    }

    return 0;
}

static int custom_connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    int blockErr = evaluateSocketPolicyForAddress(sockfd, addr, addrlen);
    if (blockErr != 0) {
        errno = blockErr;
        return -1;
    }
    return orig_connect(sockfd, addr, addrlen);
}

static ssize_t custom_sendto(int sockfd, const void *buf, size_t len, int flags, const struct sockaddr *dest_addr, socklen_t addrlen) {
    if (dest_addr) {
        int blockErr = evaluateSocketPolicyForAddress(sockfd, dest_addr, addrlen);
        if (blockErr != 0) {
            errno = blockErr;
            return -1;
        }
    }
    return orig_sendto(sockfd, buf, len, flags, dest_addr, addrlen);
}

static ssize_t custom_sendmsg(int sockfd, const struct msghdr *msg, int flags) {
    if (msg && msg->msg_name && msg->msg_namelen >= sizeof(struct sockaddr)) {
        int blockErr = evaluateSocketPolicyForAddress(sockfd, (const struct sockaddr *)msg->msg_name, msg->msg_namelen);
        if (blockErr != 0) {
            errno = blockErr;
            return -1;
        }
    }
    return orig_sendmsg(sockfd, msg, flags);
}

// ============================================================================
// OCULTACIÓN DE TÚNEL/PROXY (__SCOPED__ + GETIFADDRS SEGURO EN MEMORIA)
// ============================================================================
static CFDictionaryRef custom_CFNetworkCopySystemProxySettings(void) {
    CFDictionaryRef origRef = orig_CFNetworkCopySystemProxySettings ? orig_CFNetworkCopySystemProxySettings() : NULL;
    if (!origRef || !s_spoofNetwork) return origRef;
    if (!isCallerFromTargetApp(__builtin_return_address(0))) return origRef;

    BOOL utunActive = NO;
    refreshTunnelStatusIfNeeded(NULL, &utunActive);
    // Solo limpiamos el diccionario si el tráfico ya viaja por interfaz kernel utun
    if (!utunActive) return origRef;

    NSDictionary *origDict = (__bridge NSDictionary *)origRef;
    NSMutableDictionary *cleanDict = [NSMutableDictionary dictionary];

    NSDictionary *scoped = origDict[@"__SCOPED__"];
    if ([scoped isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *cleanScoped = [NSMutableDictionary dictionary];
        for (NSString *ifKey in scoped) {
            if (isTunnelInterfaceNameC([ifKey UTF8String])) {
                continue;
            }
            cleanScoped[ifKey] = @{};
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
        BOOL utunActive = NO;
        refreshTunnelStatusIfNeeded(NULL, &utunActive);
        if (utunActive && s_cfProxyTypeKey && s_cfProxyTypeNone) {
            NSDictionary *directProxy = @{ s_cfProxyTypeKey : s_cfProxyTypeNone };
            NSArray *arr = @[ directProxy ];
            return (__bridge_retained CFArrayRef)arr;
        }
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
        BOOL utunActive = NO;
        refreshTunnelStatusIfNeeded(NULL, &utunActive);
        if (utunActive) return @{};
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

static int custom_getifaddrs(struct ifaddrs **ifap) {
    int res = orig_getifaddrs(ifap);
    if (res != 0 || !ifap || !*ifap || !s_spoofNetwork) return res;
    if (!isCallerFromTargetApp(__builtin_return_address(0))) return res;

    // Verificar si pdp_ip0 tiene realmente una dirección IPv4 activa antes de decidir si ocultar en0
    BOOL hasLiveCellularIPv4 = NO;
    for (struct ifaddrs *scan = *ifap; scan != NULL; scan = scan->ifa_next) {
        if (scan->ifa_name && strcmp(scan->ifa_name, "pdp_ip0") == 0 &&
            (scan->ifa_flags & IFF_UP) && scan->ifa_addr && scan->ifa_addr->sa_family == AF_INET) {
            struct sockaddr_in *sin = (struct sockaddr_in *)scan->ifa_addr;
            if (sin->sin_addr.s_addr != 0) {
                hasLiveCellularIPv4 = YES;
                break;
            }
        }
    }

    // Darwin freeifaddrs() ejecuta free(*ifap) sobre el primer nodo: NUNCA debemos desplazar *ifap
    struct ifaddrs *head = *ifap;
    if (head->ifa_name && isTunnelInterfaceNameC(head->ifa_name) && strlen(head->ifa_name) >= 3) {
        memcpy(head->ifa_name, "lo0", 4);
    }

    struct ifaddrs *prev = head;
    struct ifaddrs *curr = head->ifa_next;

    while (curr) {
        BOOL shouldHide = NO;
        if (curr->ifa_name) {
            if (isTunnelInterfaceNameC(curr->ifa_name)) {
                shouldHide = YES;
            } else if (strcmp(curr->ifa_name, "en0") == 0 && s_isCellularMode && hasLiveCellularIPv4) {
                // Solo ocultamos en0 si pdp_ip0 tiene sesión IPv4 real, evitando dejar a la app con 0 interfaces en Wi-Fi
                shouldHide = YES;
            } else if (curr->ifa_addr && curr->ifa_addr->sa_family == AF_INET6 && strcmp(curr->ifa_name, "lo0") != 0) {
                // Oculta direcciones IPv6 en interfaces físicas para evitar fugas fuera del túnel IPv4
                shouldHide = YES;
            }
        }

        if (shouldHide) {
            prev->ifa_next = curr->ifa_next;
        } else {
            prev = curr;
        }
        curr = curr->ifa_next;
    }

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
        origCraneIDFV = [[origUUID UUIDString] uppercaseString];
        if (liveContainerProfile && origCraneIDFV.length >= 32) {
            liveContainerProfile[@"idfv"] = origCraneIDFV;
            liveContainerProfile[@"craneOriginalIDFV"] = origCraneIDFV;
        }
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
    s_cfProxyTypeKey = resolveCFStringSymbol("kCFProxyTypeKey", @"ProxyType");
    s_cfProxyTypeNone = resolveCFStringSymbol("kCFProxyTypeNone", @"kCFProxyTypeNone");

    // 1. Hookear dladdr, getenv y getifaddrs primero para utilidades internas
    MSHookFunction((void *)dladdr, (void *)custom_dladdr, (void **)&orig_dladdr);
    MSHookFunction((void *)getenv, (void *)custom_getenv, (void **)&orig_getenv);
    MSHookFunction((void *)getifaddrs, (void *)custom_getifaddrs, (void **)&orig_getifaddrs);

    // 2. Inicializar hooks de Objective-C antes de tocar clases de Foundation/UIKit
    %init;

    // 3. Cargar perfil del contenedor sin bloquear dyld con llamadas tempranas a UIKit
    ensureProfileLoaded();

    // 4. Activar hooks C de ocultamiento y cortafuegos POSIX anti-QUIC / anti-fugas
    MSHookFunction((void *)_dyld_get_image_name, (void *)custom_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
    MSHookFunction((void *)access, (void *)custom_access, (void **)&orig_access);
    MSHookFunction((void *)stat, (void *)custom_stat, (void **)&orig_stat);
    MSHookFunction((void *)lstat, (void *)custom_lstat, (void **)&orig_lstat);
    MSHookFunction((void *)fopen, (void *)custom_fopen, (void **)&orig_fopen);
    MSHookFunction((void *)sysctlbyname, (void *)custom_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)statfs, (void *)custom_statfs, (void **)&orig_statfs);
    MSHookFunction((void *)connect, (void *)custom_connect, (void **)&orig_connect);
    MSHookFunction((void *)sendto, (void *)custom_sendto, (void **)&orig_sendto);
    MSHookFunction((void *)sendmsg, (void *)custom_sendmsg, (void **)&orig_sendmsg);
    MSHookFunction((void *)CNCopyCurrentNetworkInfo, (void *)custom_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo);

    void *symProxySettings = dlsym(RTLD_DEFAULT, "CFNetworkCopySystemProxySettings");
    if (symProxySettings) {
        MSHookFunction(symProxySettings, (void *)custom_CFNetworkCopySystemProxySettings, (void **)&orig_CFNetworkCopySystemProxySettings);
    }
    void *symProxiesForURL = dlsym(RTLD_DEFAULT, "CFNetworkCopyProxiesForURL");
    if (symProxiesForURL) {
        MSHookFunction(symProxiesForURL, (void *)custom_CFNetworkCopyProxiesForURL, (void **)&orig_CFNetworkCopyProxiesForURL);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showStartupBannerAndPersistentIcon(0);
    });
}
