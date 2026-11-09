#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CFNetwork/CFNetwork.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <AVFoundation/AVFoundation.h>
#import <sys/types.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <os/lock.h>
#import <dlfcn.h>
#import <errno.h>
#import <stddef.h>
#import <string.h>
#import <strings.h>
#import <stdlib.h>
#import <time.h>

#if __has_include(<substrate.h>)
#import <substrate.h>
#else
#ifdef __cplusplus
extern "C" {
#endif
void MSHookFunction(void *symbol, void *replace, void **result);
#ifdef __cplusplus
}
#endif
#endif

#ifndef IP_BOUND_IF
#define IP_BOUND_IF 25
#endif

#ifndef IPV6_BOUND_IF
#define IPV6_BOUND_IF 125
#endif

#ifndef CLOCK_UPTIME_RAW
#define CLOCK_UPTIME_RAW 8
#endif

#define GLOBAL_STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define MIRROR_STATE_PLIST @"/var/jb/Library/Application Support/IGFarmShield/state_mirror.plist"
#define CRANE_PREFS_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_PREFS_VAR @"/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_MAIN_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define CRANE_MAIN_VAR @"/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define CURRENT_SCHEMA_VERSION 38

@interface NSMutableURLRequest (HTTP3Disable)
- (void)setAssumesHTTP3Capable:(BOOL)capable;
- (BOOL)assumesHTTP3Capable;
@end

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
static NSUUID *s_cachedSpoofedIDFV = nil;
static NSMutableDictionary *liveContainerProfile = nil;
static CTCarrier *s_syntheticCarrier = nil;
static NSTimeInterval sessionStartTimestamp = 0;
static double s_realMonoAtLaunch = 0.0;
static double s_baseAwakeUptimeSec = 3600.0;
static BOOL bannerShownThisSession = NO;
static BOOL s_proxyCoherenceChecked = NO;
static BOOL s_proxyCheckInFlight = NO;
static BOOL s_proxyMismatchDetected = NO;
static NSString *s_proxyMismatchSummary = nil;
static _UIStatusBarLocalOverlayWindow *persistentBadgeWindow = nil;
static UILabel *persistentBadgePill = nil;
static dispatch_source_t s_tunnelWatchdogTimer = nil;
static int s_lastRenderedBadgeState = -1;

// Estado inmutable en C/RAM para acceso O(1) multihilo sin bloqueos
static volatile BOOL s_profileInitialized = NO;
static BOOL s_shieldActive = NO;
static BOOL s_spoofIDs = NO;
static BOOL s_spoofNetwork = NO;
static BOOL s_spoofLocation = NO;
static BOOL s_spoofHardware = NO;
static BOOL s_spoofSecurity = NO;
static BOOL s_isCellularMode = YES;
static float s_sessionBatteryBase = 0.62f;
static float s_sessionBrightness = 0.48f;
static float s_sessionVolume = 0.40f;
static NSInteger s_sessionPasteboardCount = 8;
static unsigned long long s_cachedFreeBytesBase = 24000000000ULL;
static int32_t s_spoofedFsid0 = 0;
static int32_t s_spoofedFsid1 = 0;
static in_addr_t s_spoofedLanAddr = 0;
static in_addr_t s_spoofedLanMask = 0;
static in_addr_t s_spoofedLanBcast = 0;
static in_addr_t s_spoofedCellularAddr = 0;
static time_t s_spoofedBootSec = 0;
static suseconds_t s_spoofedBootUsec = 0;
static char s_cachedBootUUIDC[64] = {0};

static NSString *s_cachedContainerName = @"Default";
static NSString *s_cachedCarrierName = @"T-Mobile";
static NSString *s_cachedCarrierMCC = @"310";
static NSString *s_cachedCarrierMNC = @"260";
static NSString *s_cachedCarrierISO = @"us";
static NSString *s_cachedSSID = @"HomeWiFi-5G";
static NSString *s_cachedBSSID = @"a4:83:e7:21:9a:10";
static NSData *s_cachedSSIDData = nil;
static NSTimeZone *s_cachedTimeZoneObj = nil;
static NSLocale *s_cachedLocaleObj = nil;
static NSArray<NSString *> *s_cachedPreferredLangs = nil;

static __thread BOOL s_inInternalCall = NO;

static os_unfair_lock s_initLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock s_tunnelCacheLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock s_idfvLock = OS_UNFAIR_LOCK_INIT;
static BOOL s_cachedTunnelUp = NO;
static CFAbsoluteTime s_lastTunnelCheck = 0;

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;
static int (*orig_clock_gettime)(clockid_t, struct timespec *) = NULL;
static int (*orig_statfs)(const char *, struct statfs *) = NULL;
static int (*orig_fstatfs)(int, struct statfs *) = NULL;
static int (*orig_getifaddrs)(struct ifaddrs **) = NULL;
static int (*orig_bind)(int, const struct sockaddr *, socklen_t) = NULL;
static int (*orig_setsockopt)(int, int, int, const void *, socklen_t) = NULL;
static int (*orig_connect)(int, const struct sockaddr *, socklen_t) = NULL;
static int (*orig_connectx)(int, const sa_endpoints_t *, sae_associd_t, unsigned int, const struct iovec *, unsigned int, size_t *, sae_connid_t *) = NULL;
static ssize_t (*orig_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t) = NULL;
static ssize_t (*orig_sendmsg)(int, const struct msghdr *, int) = NULL;
static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef) = NULL;
static Boolean (*orig_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *) = NULL;

static float clampFloat(float val, float minVal, float maxVal) {
    if (val < minVal) return minVal;
    if (val > maxVal) return maxVal;
    return val;
}

static BOOL containsIgnoreCaseC(const char *haystack, const char *needle) {
    if (!haystack || !needle || !*needle) return NO;
    size_t nLen = strlen(needle);
    for (const char *p = haystack; *p != '\0'; p++) {
        if (strncasecmp(p, needle, nLen) == 0) return YES;
    }
    return NO;
}

static uint64_t deterministicHash64(NSString *salt) {
    uint64_t hash = 14695981039346656037ULL;
    const char *bytes = [salt UTF8String];
    if (bytes) {
        while (*bytes) {
            hash ^= (uint8_t)(*bytes++);
            hash *= 1099511628211ULL;
        }
    }
    return hash;
}

static uint64_t randomSeed64(NSString *salt) {
    uint64_t hash = deterministicHash64(salt);
    uint64_t r = 0;
    arc4random_buf(&r, sizeof(r));
    return hash ^ r;
}

static NSString *deterministicUUIDStringFromSalt(NSString *salt) {
    uint64_t h1 = deterministicHash64(salt ?: @"IGFarmShield");
    uint64_t h2 = deterministicHash64([NSString stringWithFormat:@"%@_v4_%llu", salt ?: @"IG", h1]);
    uint32_t d1 = (uint32_t)(h1 >> 32);
    uint16_t d2 = (uint16_t)(h1 & 0xFFFF);
    uint16_t d3 = (uint16_t)(((h1 >> 16) & 0x0FFF) | 0x4000);
    uint16_t d4 = (uint16_t)(((h2 >> 48) & 0x3FFF) | 0x8000);
    uint64_t d5 = (h2 & 0xFFFFFFFFFFFFULL);
    return [NSString stringWithFormat:@"%08X-%04X-%04X-%04X-%012llX", d1, d2, d3, d4, d5];
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

static BOOL isSecondaryWifiInterfaceNameC(const char *ifName) {
    if (!ifName) return NO;
    return (strncmp(ifName, "awdl", 4) == 0 ||
            strncmp(ifName, "llw", 3) == 0 ||
            strncmp(ifName, "ap", 2) == 0 ||
            strncmp(ifName, "bridge", 6) == 0);
}

static BOOL hasActiveUtunTunnelLive(void) {
    struct ifaddrs *interfaces = NULL;
    int (*fn)(struct ifaddrs **) = orig_getifaddrs ? orig_getifaddrs : getifaddrs;
    if (fn(&interfaces) != 0 || !interfaces) return NO;
    BOOL found = NO;
    for (struct ifaddrs *cur = interfaces; cur != NULL; cur = cur->ifa_next) {
        if (cur->ifa_name && (cur->ifa_flags & IFF_UP) && isTunnelInterfaceNameC(cur->ifa_name)) {
            if (cur->ifa_addr && cur->ifa_addr->sa_family == AF_INET) {
                struct sockaddr_in sin;
                memcpy(&sin, cur->ifa_addr, sizeof(sin));
                if (sin.sin_addr.s_addr != 0) {
                    found = YES;
                    break;
                }
            }
        }
    }
    freeifaddrs(interfaces);
    return found;
}

static BOOL hasActiveUtunTunnelCached(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&s_tunnelCacheLock);
    if ((now - s_lastTunnelCheck) < 0.8) {
        BOOL cached = s_cachedTunnelUp;
        os_unfair_lock_unlock(&s_tunnelCacheLock);
        return cached;
    }
    os_unfair_lock_unlock(&s_tunnelCacheLock);

    BOOL liveUp = hasActiveUtunTunnelLive();

    os_unfair_lock_lock(&s_tunnelCacheLock);
    s_lastTunnelCheck = now;
    s_cachedTunnelUp = liveUp;
    os_unfair_lock_unlock(&s_tunnelCacheLock);
    return liveUp;
}

static void persistCurrentProfileToSandboxIfNeeded(NSDictionary *previousDiskSnapshot) {
    if (!liveContainerProfile) return;
    if (previousDiskSnapshot && [previousDiskSnapshot isEqualToDictionary:liveContainerProfile]) return;

    BOOL prev = s_inInternalCall;
    s_inInternalCall = YES;
    NSString *homePath = NSHomeDirectory();
    if (homePath.length > 0) {
        NSString *libDir = [homePath stringByAppendingPathComponent:@"Library"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:libDir]) {
            [fm createDirectoryAtPath:libDir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSString *localPlist = [libDir stringByAppendingPathComponent:@".igshield_container.plist"];
        [liveContainerProfile writeToFile:localPlist atomically:YES];
    }
    s_inInternalCall = prev;
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

static NSDictionary *resolveCraneIdentityDict(NSString *homePath, NSString *bundleID, NSDictionary *cachedLocal) {
    NSString *folderUUID = [homePath lastPathComponent] ?: @"Default";
    NSString *craneID = nil;
    NSString *craneName = nil;

    const char *envName = getenv("CRANE_CONTAINER_NAME");
    const char *envID = getenv("CRANE_CONTAINER_ID");
    const char *envIdent = getenv("CRANE_IDENTIFIER");

    if (envName && strlen(envName) > 0) craneName = [NSString stringWithUTF8String:envName];
    if (envID && strlen(envID) > 0) craneID = [NSString stringWithUTF8String:envID];
    if (envIdent && strlen(envIdent) > 0 && !craneID) craneID = [NSString stringWithUTF8String:envIdent];

    if (craneID.length > 0 && craneName.length > 0) {
        return @{
            @"keyUUID": folderUUID,
            @"craneID": craneID,
            @"craneName": craneName
        };
    }

    if ([cachedLocal isKindOfClass:[NSDictionary class]]) {
        NSString *savedCID = cachedLocal[@"craneIdentifier"];
        NSString *savedCName = cachedLocal[@"containerName"];
        if (!craneID && [savedCID isKindOfClass:[NSString class]] && savedCID.length > 0) {
            craneID = savedCID;
        }
        if (!craneName && [savedCName isKindOfClass:[NSString class]] && savedCName.length > 0 &&
            ![savedCName isEqualToString:folderUUID]) {
            craneName = savedCName;
        }
        if (craneID.length > 0 && craneName.length > 0) {
            return @{
                @"keyUUID": folderUUID,
                @"craneID": craneID,
                @"craneName": craneName
            };
        }
    }

    NSString *metaPath = [homePath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
    if ([meta isKindOfClass:[NSDictionary class]]) {
        for (NSString *rk in @[@"com.opa334.crane.container.name", @"craneContainerName"]) {
            if (!craneName && [meta[rk] isKindOfClass:[NSString class]] && [meta[rk] length] > 0) craneName = meta[rk];
        }
        for (NSString *ik in @[@"com.opa334.crane.container.identifier", @"com.opa334.crane.container.id", @"craneContainerIdentifier"]) {
            if (!craneID && [meta[ik] isKindOfClass:[NSString class]] && [meta[ik] length] > 0) craneID = meta[ik];
        }
        NSDictionary *userInfo = meta[@"MCMMetadataUserInfo"];
        if (userInfo) searchNestedMetadata(userInfo, &craneID, &craneName, bundleID);
    }

    if (!craneName) {
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
    }

    if (!craneID && origCraneIDFV && origCraneIDFV.length >= 32) craneID = origCraneIDFV;
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
        @"keyUUID": folderUUID,
        @"craneID": craneID ?: @"Default",
        @"craneName": craneName ?: @"Default"
    };
}

static NSTimeInterval spoofedSystemUptime(void) {
    struct timespec tsNow;
    int (*clkFn)(clockid_t, struct timespec *) = orig_clock_gettime ? orig_clock_gettime : clock_gettime;
    if (clkFn(CLOCK_UPTIME_RAW, &tsNow) == 0 && s_realMonoAtLaunch > 0.0) {
        double monoNow = (double)tsNow.tv_sec + ((double)tsNow.tv_nsec / 1000000000.0);
        double delta = monoNow - s_realMonoAtLaunch;
        if (delta < 0.0) delta = 0.0;
        return s_baseAwakeUptimeSec + delta;
    }
    return s_baseAwakeUptimeSec;
}

static void ensureProfileLoaded(void) {
    if (s_profileInitialized || s_inInternalCall) return;
    os_unfair_lock_lock(&s_initLock);
    if (s_profileInitialized) {
        os_unfair_lock_unlock(&s_initLock);
        return;
    }
    s_inInternalCall = YES;

    sessionStartTimestamp = CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970;
    struct timespec tsInit;
    int (*clkInitFn)(clockid_t, struct timespec *) = orig_clock_gettime ? orig_clock_gettime : clock_gettime;
    if (clkInitFn(CLOCK_UPTIME_RAW, &tsInit) == 0) {
        s_realMonoAtLaunch = (double)tsInit.tv_sec + ((double)tsInit.tv_nsec / 1000000000.0);
    }

    NSString *homePath = NSHomeDirectory() ?: @"";
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.burbn.instagram";
    NSString *localPlist = [homePath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
    NSDictionary *diskLoaded = [NSDictionary dictionaryWithContentsOfFile:localPlist];

    NSDictionary *ident = resolveCraneIdentityDict(homePath, bundleID, diskLoaded);
    NSString *keyUUID = ident[@"keyUUID"];
    NSString *craneID = ident[@"craneID"];
    NSString *craneName = ident[@"craneName"];

    uint64_t fsidHash = deterministicHash64([NSString stringWithFormat:@"APFS_%@_%@", bundleID, keyUUID]);
    s_spoofedFsid0 = (int32_t)((fsidHash >> 32) & 0x7FFFFFFFU);
    s_spoofedFsid1 = (int32_t)(fsidHash & 0x7FFFFFFFU);
    if (s_spoofedFsid0 == 0) s_spoofedFsid0 = 0x1A2B3C4D;
    if (s_spoofedFsid1 == 0) s_spoofedFsid1 = 0x5E6F7A8B;

    NSDictionary *loadedGlobal = [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST];
    if (![loadedGlobal isKindOfClass:[NSDictionary class]] || loadedGlobal.count == 0) {
        loadedGlobal = [NSDictionary dictionaryWithContentsOfFile:MIRROR_STATE_PLIST];
    }
    BOOL canReadGlobalPlist = ([loadedGlobal isKindOfClass:[NSDictionary class]] && loadedGlobal.count > 0);
    NSDictionary *byUUID = (canReadGlobalPlist && [loadedGlobal[@"containersByUUID"] isKindOfClass:[NSDictionary class]])
        ? loadedGlobal[@"containersByUUID"]
        : nil;

    NSDictionary *activeMap = (canReadGlobalPlist && [loadedGlobal[@"activeInCrane"] isKindOfClass:[NSDictionary class]])
        ? loadedGlobal[@"activeInCrane"]
        : @{};
    NSString *craneActiveIDForApp = activeMap[bundleID];

    NSDictionary *settingsEntry = nil;
    if (byUUID) {
        if ([byUUID[keyUUID] isKindOfClass:[NSDictionary class]]) {
            settingsEntry = byUUID[keyUUID];
        } else {
            for (NSString *existingKey in byUUID) {
                NSDictionary *cand = byUUID[existingKey];
                if (![cand isKindOfClass:[NSDictionary class]] || ![cand[@"bundleID"] isEqualToString:bundleID]) continue;
                NSString *candPath = cand[@"path"] ?: @"";
                NSString *candCraneID = cand[@"craneIdentifier"] ?: @"";
                NSString *candIDFV = cand[@"idfv"] ?: @"";
                NSString *candName = cand[@"containerName"] ?: @"";
                if ([candPath isEqualToString:homePath] ||
                    (origCraneIDFV.length > 0 && ([existingKey caseInsensitiveCompare:origCraneIDFV] == NSOrderedSame ||
                                                  [candCraneID caseInsensitiveCompare:origCraneIDFV] == NSOrderedSame ||
                                                  [candIDFV caseInsensitiveCompare:origCraneIDFV] == NSOrderedSame)) ||
                    (candCraneID.length > 0 && ![candCraneID isEqualToString:@"Default"] && [candCraneID caseInsensitiveCompare:craneID] == NSOrderedSame) ||
                    (craneName.length > 0 && ![craneName isEqualToString:@"Default"] && [candName caseInsensitiveCompare:craneName] == NSOrderedSame)) {
                    settingsEntry = cand;
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
                        break;
                    }
                }
            }
        }
    }

    NSMutableDictionary *profile = nil;
    if ([diskLoaded isKindOfClass:[NSDictionary class]] && diskLoaded[@"bootSessionUUID"]) {
        profile = [diskLoaded mutableCopy];
    }
    if (settingsEntry && settingsEntry[@"bootSessionUUID"]) {
        if (!profile) {
            profile = [settingsEntry mutableCopy];
        } else {
            for (NSString *k in @[@"enabled", @"masterEnabled", @"appEnabled", @"effectiveShieldActive", @"containerName", @"craneIdentifier", @"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity", @"locationAnchored", @"timeZone", @"localeID", @"CarrierMode", @"CarrierName", @"CarrierMCC", @"CarrierMNC", @"CarrierISO", @"ispName", @"cityCountry", @"lastSyncedIP", @"batteryLevel", @"brightness", @"audioVolume", @"pasteboardCount", @"freeBytes", @"cellularLocalIP", @"localIP", @"bssid", @"ssid"]) {
                if (settingsEntry[k] != nil) profile[k] = settingsEntry[k];
            }
            BOOL settingsAnchored = [settingsEntry[@"locationAnchored"] boolValue];
            BOOL diskAnchored = [profile[@"locationAnchored"] boolValue];
            if (settingsAnchored || !diskAnchored) {
                for (NSString *locKey in @[@"locationAnchored", @"timeZone", @"localeID", @"CarrierMode", @"CarrierName", @"CarrierMCC", @"CarrierMNC", @"CarrierISO", @"ispName", @"cityCountry", @"lastSyncedIP"]) {
                    if (settingsEntry[locKey] != nil) profile[locKey] = settingsEntry[locKey];
                }
            }
        }
    }

    NSString *existingIDFV = ([profile[@"idfv"] isKindOfClass:[NSString class]] && [profile[@"idfv"] length] >= 32)
        ? [profile[@"idfv"] uppercaseString]
        : nil;
    NSString *nativeCraneUUID = (origCraneIDFV && origCraneIDFV.length >= 32)
        ? origCraneIDFV
        : (existingIDFV ?: (([craneID containsString:@"-"] && craneID.length >= 32) ? [craneID uppercaseString] : deterministicUUIDStringFromSalt(keyUUID)));

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
        NSString *cellIP = [NSString stringWithFormat:@"100.%d.%d.%d",
                            64 + (int)(seed % 60),
                            1 + (int)((seed >> 8) % 250),
                            2 + (int)((seed >> 16) % 250)];
        unsigned long long freeBytes = ((14800ULL + (seed % 31500ULL)) * 1024ULL * 1024ULL) + ((seed >> 12) % 1048576ULL);
        BOOL manualEnabled = (settingsEntry && settingsEntry[@"enabled"] != nil) ? [settingsEntry[@"enabled"] boolValue] : YES;

        profile = [@{
            @"schemaVersion": @(CURRENT_SCHEMA_VERSION),
            @"containerUUID": keyUUID,
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
            @"cellularLocalIP": cellIP,
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
        if (!profile[@"idfv"] || [profile[@"idfv"] length] < 32) {
            profile[@"idfv"] = nativeCraneUUID;
            profile[@"craneOriginalIDFV"] = nativeCraneUUID;
        }
        profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
        profile[@"bundleID"] = bundleID;
        profile[@"path"] = homePath;
        if (craneName.length > 0 && ![craneName isEqualToString:keyUUID] &&
            ![profile[@"containerName"] isEqualToString:craneName]) {
            profile[@"containerName"] = craneName;
        }
    }

    NSString *lanIP = profile[@"localIP"] ?: @"192.168.1.45";
    if (![lanIP hasPrefix:@"192.168.1."]) {
        uint64_t fixSeed = randomSeed64(keyUUID);
        lanIP = [NSString stringWithFormat:@"192.168.1.%d", 15 + (int)(fixSeed % 220)];
        profile[@"localIP"] = lanIP;
    }
    s_spoofedLanAddr = inet_addr([lanIP UTF8String]);
    s_spoofedLanMask = htonl(0xFFFFFF00U);
    s_spoofedLanBcast = (s_spoofedLanAddr & s_spoofedLanMask) | htonl(0x000000FFU);

    NSString *cellIP = profile[@"cellularLocalIP"];
    if (![cellIP isKindOfClass:[NSString class]] || ![cellIP hasPrefix:@"100."]) {
        uint64_t cellSeed = randomSeed64(profile[@"bootSessionUUID"] ?: keyUUID);
        cellIP = [NSString stringWithFormat:@"100.%d.%d.%d",
                  64 + (int)(cellSeed % 60),
                  1 + (int)((cellSeed >> 8) % 250),
                  2 + (int)((cellSeed >> 16) % 250)];
        profile[@"cellularLocalIP"] = cellIP;
    }
    s_spoofedCellularAddr = inet_addr([cellIP UTF8String]);

    NSString *currentBootUUID = profile[@"bootSessionUUID"] ?: [[NSUUID UUID] UUIDString];
    strncpy(s_cachedBootUUIDC, [currentBootUUID UTF8String], sizeof(s_cachedBootUUIDC) - 1);
    s_cachedBootUUIDC[sizeof(s_cachedBootUUIDC) - 1] = '\0';

    NSString *savedBootUUIDRef = profile[@"lastBootUUIDForTime"] ?: @"";
    long long savedBootSec = [profile[@"spoofedBootEpoch"] longLongValue];
    int savedBootUsec = [profile[@"spoofedBootUsec"] intValue];
    time_t nowEpoch = time(NULL);

    BOOL hadPreviousBootRecord = (savedBootUUIDRef.length > 0);
    BOOL bootUUIDRotated = ![savedBootUUIDRef isEqualToString:currentBootUUID];
    BOOL bootOutOfRange = (savedBootSec <= 0 || savedBootSec >= (nowEpoch - 600) || (nowEpoch - savedBootSec) > (30 * 86400));

    if (bootUUIDRotated || bootOutOfRange) {
        uint64_t bSeed = randomSeed64(currentBootUUID);
        long long offsetSec = (hadPreviousBootRecord && bootUUIDRotated)
            ? (1800LL + (long long)(bSeed % 9000ULL))
            : (21600LL + (long long)(bSeed % 669600ULL));
        savedBootSec = (long long)nowEpoch - offsetSec;
        savedBootUsec = (int)((bSeed >> 12) % 999999ULL);
        profile[@"spoofedBootEpoch"] = @(savedBootSec);
        profile[@"spoofedBootUsec"] = @(savedBootUsec);
        profile[@"lastBootUUIDForTime"] = currentBootUUID;
    }
    s_spoofedBootSec = (time_t)savedBootSec;
    s_spoofedBootUsec = (suseconds_t)savedBootUsec;

    double wallSinceBoot = (double)(nowEpoch - s_spoofedBootSec);
    if (wallSinceBoot < 600.0) wallSinceBoot = 600.0;
    uint64_t ratioSeed = deterministicHash64(currentBootUUID);
    double awakeRatio = 0.72 + ((double)(ratioSeed % 17ULL) / 100.0);
    s_baseAwakeUptimeSec = wallSinceBoot * awakeRatio;

    BOOL contOn = [profile[@"enabled"] boolValue];
    if (canReadGlobalPlist) {
        BOOL masterOn = [loadedGlobal[@"masterEnabled"] boolValue];
        BOOL appOn = [bundleID isEqualToString:@"com.burbn.instagram"]
            ? [loadedGlobal[@"enableIG"] boolValue]
            : [loadedGlobal[@"enableReddit"] boolValue];
        s_shieldActive = (masterOn && appOn && contOn);
        profile[@"masterEnabled"] = @(masterOn);
        profile[@"appEnabled"] = @(appOn);
        profile[@"effectiveShieldActive"] = @(s_shieldActive);
    } else if (profile[@"effectiveShieldActive"] != nil) {
        s_shieldActive = [profile[@"effectiveShieldActive"] boolValue];
    } else {
        BOOL localMaster = (profile[@"masterEnabled"] == nil) ? NO : [profile[@"masterEnabled"] boolValue];
        BOOL localApp = (profile[@"appEnabled"] == nil) ? NO : [profile[@"appEnabled"] boolValue];
        s_shieldActive = (localMaster && localApp && contOn);
    }

    liveContainerProfile = profile;
    persistCurrentProfileToSandboxIfNeeded(diskLoaded);

    s_cachedContainerName = [profile[@"containerName"] ?: @"Default" copy];
    s_cachedCarrierName = [profile[@"CarrierName"] ?: @"T-Mobile" copy];
    s_cachedCarrierMCC = [profile[@"CarrierMCC"] ?: @"310" copy];
    s_cachedCarrierMNC = [profile[@"CarrierMNC"] ?: @"260" copy];
    s_cachedCarrierISO = [profile[@"CarrierISO"] ?: @"us" copy];
    s_cachedSSID = [profile[@"ssid"] ?: @"HomeWiFi-5G" copy];
    s_cachedBSSID = [profile[@"bssid"] ?: @"a4:83:e7:21:9a:10" copy];
    s_cachedSSIDData = [s_cachedSSID dataUsingEncoding:NSUTF8StringEncoding];
    s_cachedFreeBytesBase = profile[@"freeBytes"] ? [profile[@"freeBytes"] unsignedLongLongValue] : 24000000000ULL;

    NSString *idfvStr = profile[@"idfv"];
    if ([idfvStr isKindOfClass:[NSString class]] && idfvStr.length >= 32) {
        s_cachedSpoofedIDFV = [[NSUUID alloc] initWithUUIDString:idfvStr];
    }

    NSString *locID = profile[@"localeID"] ?: @"en_US";
    s_cachedLocaleObj = [NSLocale localeWithLocaleIdentifier:locID];
    NSString *lang = [locID stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    if ([lang caseInsensitiveCompare:@"en-US"] == NSOrderedSame) {
        s_cachedPreferredLangs = @[@"en-US"];
    } else {
        s_cachedPreferredLangs = @[lang, @"en-US"];
    }

    float rawBat = profile[@"batteryLevel"] ? [profile[@"batteryLevel"] floatValue] : 0.62f;
    float rawBri = profile[@"brightness"] ? [profile[@"brightness"] floatValue] : 0.48f;
    float rawVol = profile[@"audioVolume"] ? [profile[@"audioVolume"] floatValue] : 0.40f;
    NSInteger rawPb = profile[@"pasteboardCount"] ? [profile[@"pasteboardCount"] integerValue] : 8;

    float batJitter = ((int)arc4random_uniform(5) - 2) * 0.01f;
    float briJitter = ((int)arc4random_uniform(5) - 2) * 0.01f;
    float volJitter = ((int)arc4random_uniform(5) - 2) * 0.01f;

    s_sessionBatteryBase = clampFloat(rawBat + batJitter, 0.18f, 0.95f);
    s_sessionBrightness = clampFloat(rawBri + briJitter, 0.15f, 0.92f);
    s_sessionVolume = clampFloat(rawVol + volJitter, 0.10f, 0.90f);
    s_sessionPasteboardCount = MAX(1, rawPb + (NSInteger)arc4random_uniform(3));

    s_spoofIDs = s_shieldActive && (profile[@"spoofIDs"] == nil ? YES : [profile[@"spoofIDs"] boolValue]);
    s_spoofNetwork = s_shieldActive && (profile[@"spoofNetwork"] == nil ? YES : [profile[@"spoofNetwork"] boolValue]);
    s_spoofLocation = s_shieldActive && (profile[@"spoofLocation"] == nil ? YES : [profile[@"spoofLocation"] boolValue]);
    s_spoofHardware = s_shieldActive && (profile[@"spoofHardware"] == nil ? YES : [profile[@"spoofHardware"] boolValue]);
    s_spoofSecurity = s_shieldActive && (profile[@"spoofSecurity"] == nil ? YES : [profile[@"spoofSecurity"] boolValue]);
    s_isCellularMode = ![profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"];

    NSString *tzName = profile[@"timeZone"];
    if (tzName && ![tzName hasPrefix:@"Sincronizando"] && ![tzName hasPrefix:@"Sin "] && tzName.length > 0) {
        NSTimeZone *tzObj = [NSTimeZone timeZoneWithName:tzName];
        if (tzObj) {
            s_cachedTimeZoneObj = tzObj;
            if (s_spoofLocation) {
                [NSTimeZone setDefaultTimeZone:tzObj];
            }
        }
    }

    s_profileInitialized = YES;
    s_inInternalCall = NO;
    os_unfair_lock_unlock(&s_initLock);
}

// ============================================================================
// CÁPSULA SUPERIOR CON MONITOR DE TÚNEL Y DETECTOR DE DESFASE DE PROXY
// ============================================================================
static void refreshBadgePillStateOnMain(void) {
    if (!persistentBadgePill) return;
    BOOL tunnelUp = hasActiveUtunTunnelLive();
    int desiredState = 0;
    if (s_shieldActive && s_spoofNetwork && !tunnelUp) {
        desiredState = 2;
    } else if (s_shieldActive && s_proxyMismatchDetected) {
        desiredState = 3;
    } else if (s_shieldActive) {
        desiredState = 1;
    } else {
        desiredState = 0;
    }

    if (desiredState == s_lastRenderedBadgeState) return;
    s_lastRenderedBadgeState = desiredState;

    NSString *cName = s_cachedContainerName ?: @"Default";
    CGRect screenBounds = [UIScreen mainScreen].bounds;

    if (desiredState == 2) {
        persistentBadgePill.backgroundColor = [UIColor colorWithRed:0.80 green:0.12 blue:0.12 alpha:0.96];
        persistentBadgePill.text = [NSString stringWithFormat:@" ⛔ %@ (SIN TÚNEL) ", cName];
    } else if (desiredState == 3) {
        persistentBadgePill.backgroundColor = [UIColor colorWithRed:0.86 green:0.45 blue:0.04 alpha:0.96];
        persistentBadgePill.text = [NSString stringWithFormat:@" ⚠️ %@ (ZONA/PROXY) ", cName];
    } else if (desiredState == 1) {
        persistentBadgePill.backgroundColor = [UIColor colorWithRed:0.04 green:0.52 blue:0.24 alpha:0.94];
        persistentBadgePill.text = [NSString stringWithFormat:@" 🛡️ %@ ", cName];
    } else {
        persistentBadgePill.backgroundColor = [UIColor colorWithRed:0.38 green:0.38 blue:0.42 alpha:0.90];
        persistentBadgePill.text = [NSString stringWithFormat:@" ⚪ %@ ", cName];
    }

    [persistentBadgePill sizeToFit];
    CGFloat pillW = MIN(MAX(persistentBadgePill.bounds.size.width + 12.0, 62.0), 235.0);
    persistentBadgePill.frame = CGRectMake((screenBounds.size.width - pillW) / 2.0, 18.0, pillW, 16.0);
}

static void verifyLiveProxyCoherenceOnStartup(void) {
    if (s_proxyCoherenceChecked || s_proxyCheckInFlight || !s_shieldActive || !s_spoofNetwork || !liveContainerProfile) return;
    if (!hasActiveUtunTunnelCached()) return;

    s_proxyCheckInFlight = YES;

    NSURL *url = [NSURL URLWithString:@"https://ipwho.is/"];
    if (!url) {
        s_proxyCoherenceChecked = YES;
        s_proxyCheckInFlight = NO;
        return;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.URLCache = nil;
    cfg.HTTPCookieStorage = nil;
    cfg.timeoutIntervalForRequest = 7.0;

    __block NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (err || !data) {
                    s_proxyCoherenceChecked = YES;
                    s_proxyCheckInFlight = NO;
                    [session finishTasksAndInvalidate];
                    return;
                }

                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (![json isKindOfClass:[NSDictionary class]] || ![json[@"success"] boolValue]) {
                    s_proxyCoherenceChecked = YES;
                    s_proxyCheckInFlight = NO;
                    [session finishTasksAndInvalidate];
                    return;
                }

                NSString *liveIP = [json[@"ip"] isKindOfClass:[NSString class]] ? json[@"ip"] : nil;
                NSString *liveCC = [json[@"country_code"] isKindOfClass:[NSString class]] ? [json[@"country_code"] lowercaseString] : nil;
                NSDictionary *tzDict = [json[@"timezone"] isKindOfClass:[NSDictionary class]] ? json[@"timezone"] : @{};
                NSString *liveTZ = [tzDict[@"id"] isKindOfClass:[NSString class]] ? tzDict[@"id"] : nil;

                if (!liveIP || !liveTZ || liveTZ.length == 0) {
                    s_proxyCoherenceChecked = YES;
                    s_proxyCheckInFlight = NO;
                    [session finishTasksAndInvalidate];
                    return;
                }

                BOOL anchored = [liveContainerProfile[@"locationAnchored"] boolValue];
                if (!anchored) {
                    s_proxyCoherenceChecked = YES;
                    s_proxyCheckInFlight = NO;
                    [session finishTasksAndInvalidate];
                    return;
                }

                NSString *savedTZ = liveContainerProfile[@"timeZone"] ?: @"";
                NSString *savedISO = [liveContainerProfile[@"CarrierISO"] ?: @"us" lowercaseString];
                BOOL tzDiffers = (savedTZ.length > 0 && ![savedTZ isEqualToString:liveTZ]);
                BOOL ccDiffers = (liveCC.length > 0 && savedISO.length > 0 && ![savedISO isEqualToString:liveCC]);

                if (tzDiffers || ccDiffers) {
                    s_proxyMismatchDetected = YES;
                    s_proxyMismatchSummary = [NSString stringWithFormat:@"Proxy: %@ (%@) ≠ Perfil: %@", liveIP, liveTZ, savedTZ];
                    s_lastRenderedBadgeState = -1;
                    refreshBadgePillStateOnMain();
                    if (persistentBadgeWindow && persistentBadgeWindow.rootViewController) {
                        CGRect screenBounds = [UIScreen mainScreen].bounds;
                        persistentBadgeWindow.frame = CGRectMake(0, 0, screenBounds.size.width, 92);
                        UILabel *warnToast = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, screenBounds.size.width - 32, 42)];
                        warnToast.layer.cornerRadius = 10.0;
                        warnToast.clipsToBounds = YES;
                        warnToast.textAlignment = NSTextAlignmentCenter;
                        warnToast.font = [UIFont boldSystemFontOfSize:11.0];
                        warnToast.numberOfLines = 2;
                        warnToast.textColor = [UIColor whiteColor];
                        warnToast.backgroundColor = [UIColor colorWithRed:0.86 green:0.45 blue:0.04 alpha:0.96];
                        warnToast.text = [NSString stringWithFormat:@"⚠️ Zona del Proxy Cambió en %@\n%@",
                                          s_cachedContainerName ?: @"Contenedor", s_proxyMismatchSummary];
                        [persistentBadgeWindow.rootViewController.view addSubview:warnToast];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [UIView animateWithDuration:0.35 animations:^{ warnToast.alpha = 0.0; } completion:^(BOOL f) {
                                [warnToast removeFromSuperview];
                                persistentBadgeWindow.frame = CGRectMake(0, 0, screenBounds.size.width, 40);
                            }];
                        });
                    }
                }
            } @finally {
                s_proxyCoherenceChecked = YES;
                s_proxyCheckInFlight = NO;
                [session finishTasksAndInvalidate];
            }
        });
    }] resume];
}

static void startTunnelWatchdogTimer(void) {
    if (s_tunnelWatchdogTimer != nil || !s_shieldActive || !s_spoofNetwork) return;
    s_tunnelWatchdogTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!s_tunnelWatchdogTimer) return;
    dispatch_source_set_timer(s_tunnelWatchdogTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                              (uint64_t)(2.5 * NSEC_PER_SEC),
                              (uint64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(s_tunnelWatchdogTimer, ^{
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            refreshBadgePillStateOnMain();
        }
    });
    dispatch_resume(s_tunnelWatchdogTimer);
}

static void showStartupBannerAndPersistentIcon(int attempt) {
    if (bannerShownThisSession) return;
    if (!s_profileInitialized) ensureProfileLoaded();
    if (!liveContainerProfile) return;

    s_inInternalCall = YES;
    NSUUID *liveVendorUUID = [[UIDevice currentDevice] identifierForVendor];
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
                    if (w.isKeyWindow || !targetWin) targetWin = w;
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

    if (liveVendorUUID) {
        NSString *captured = [[liveVendorUUID UUIDString] uppercaseString];
        if (captured.length >= 32) {
            os_unfair_lock_lock(&s_idfvLock);
            if (!origCraneIDFV) origCraneIDFV = captured;
            if (!s_cachedSpoofedIDFV) s_cachedSpoofedIDFV = liveVendorUUID;
            os_unfair_lock_unlock(&s_idfvLock);
            if (!liveContainerProfile[@"idfv"] || [liveContainerProfile[@"idfv"] length] < 32) {
                NSDictionary *snap = [liveContainerProfile copy];
                liveContainerProfile[@"idfv"] = captured;
                liveContainerProfile[@"craneOriginalIDFV"] = captured;
                persistCurrentProfileToSandboxIfNeeded(snap);
            }
        }
    }

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
    NSString *cName = s_cachedContainerName ?: @"Default";
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    BOOL tunnelUp = hasActiveUtunTunnelLive();
    BOOL killSwitchTriggered = (s_shieldActive && s_spoofNetwork && !tunnelUp);

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

        persistentBadgePill = [[UILabel alloc] init];
        persistentBadgePill.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold];
        persistentBadgePill.textColor = [UIColor whiteColor];
        persistentBadgePill.textAlignment = NSTextAlignmentCenter;
        persistentBadgePill.layer.cornerRadius = 8.0;
        persistentBadgePill.layer.borderWidth = 0.8;
        persistentBadgePill.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
        persistentBadgePill.clipsToBounds = YES;

        [rootVC.view addSubview:persistentBadgePill];
        s_lastRenderedBadgeState = -1;
        refreshBadgePillStateOnMain();
        persistentBadgeWindow.hidden = NO;
        startTunnelWatchdogTimer();
    }

    NSString *netMode = s_isCellularMode
        ? [NSString stringWithFormat:@"4G: %@ (%@)", s_cachedCarrierName, prof[@"cellularLocalIP"] ?: @"CGNAT"]
        : [NSString stringWithFormat:@"Wi-Fi (%@)", prof[@"localIP"] ?: @"LAN"];
    int batPct = (int)(s_sessionBatteryBase * 100.0f);

    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, screenBounds.size.width - 32, 42)];
    toast.layer.cornerRadius = 10.0;
    toast.clipsToBounds = YES;
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont boldSystemFontOfSize:11.5];
    toast.numberOfLines = 2;
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [UIColor colorWithRed:0.06 green:0.48 blue:0.24 alpha:0.94];
    toast.text = [NSString stringWithFormat:@"🛡️ %@\n%@\nBatería %d%%", cName, netMode, batPct];
    if (killSwitchTriggered) {
        toast.backgroundColor = [UIColor colorWithRed:0.80 green:0.12 blue:0.12 alpha:0.96];
        toast.text = [NSString stringWithFormat:@"⛔ %@\nSIN TÚNEL\n%@", cName, netMode];
    }

    [persistentBadgeWindow.rootViewController.view addSubview:toast];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.35 animations:^{ toast.alpha = 0.0; } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

// Continuación del archivo original...

#ifdef __OBJC__

#endif

// END
