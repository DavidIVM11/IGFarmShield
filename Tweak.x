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
#import <dirent.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <stddef.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <strings.h>
#import <stdlib.h>
#import <stdio.h>
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
#define CURRENT_SCHEMA_VERSION 37

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
static NSMutableDictionary *liveContainerProfile = nil;
static CTCarrier *s_syntheticCarrier = nil;
static NSTimeInterval sessionStartTimestamp = 0;
static double s_realMonoAtLaunch = 0.0;
static double s_baseAwakeUptimeSec = 3600.0;
static BOOL bannerShownThisSession = NO;
static _UIStatusBarLocalOverlayWindow *persistentBadgeWindow = nil;
static UILabel *persistentBadgePill = nil;
static dispatch_source_t s_tunnelWatchdogTimer = nil;
static int s_lastRenderedBadgeState = -1;

// Banderas O(1) en RAM para latencia cero con 30+ contenedores
static BOOL s_profileInitialized = NO;
static BOOL s_shieldActive = NO;
static BOOL s_spoofIDs = NO;
static BOOL s_spoofNetwork = NO;
static BOOL s_spoofLocation = NO;
static BOOL s_spoofHardware = NO;
static BOOL s_spoofSecurity = NO;
static BOOL s_isCellularMode = YES;
static in_addr_t s_spoofedLanAddr = 0;
static in_addr_t s_spoofedLanMask = 0;
static in_addr_t s_spoofedLanBcast = 0;
static in_addr_t s_spoofedCellularAddr = 0;
static time_t s_spoofedBootSec = 0;
static suseconds_t s_spoofedBootUsec = 0;
static char s_containerHomePath[PATH_MAX] = {0};
static size_t s_containerHomeLen = 0;
static __thread BOOL s_inInternalCall = NO;

static int (*orig_dladdr)(const void *, Dl_info *) = NULL;
static void *(*orig_dlopen)(const char *, int) = NULL;
static const char *(*orig_dyld_get_image_name)(uint32_t image_index) = NULL;
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;
static int (*orig_clock_gettime)(clockid_t, struct timespec *) = NULL;
static int (*orig_statfs)(const char *, struct statfs *) = NULL;
static int (*orig_access)(const char *, int) = NULL;
static int (*orig_faccessat)(int, const char *, int, int) = NULL;
static int (*orig_stat)(const char *, struct stat *) = NULL;
static int (*orig_lstat)(const char *, struct stat *) = NULL;
static FILE *(*orig_fopen)(const char *, const char *) = NULL;
static DIR *(*orig_opendir)(const char *) = NULL;
static char *(*orig_getenv)(const char *) = NULL;
static int (*orig_getifaddrs)(struct ifaddrs **) = NULL;
static int (*orig_bind)(int, const struct sockaddr *, socklen_t) = NULL;
static int (*orig_setsockopt)(int, int, int, const void *, socklen_t) = NULL;
static int (*orig_connect)(int, const struct sockaddr *, socklen_t) = NULL;
static ssize_t (*orig_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t) = NULL;
static ssize_t (*orig_sendmsg)(int, const struct msghdr *, int) = NULL;
static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef) = NULL;
static Boolean (*orig_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *) = NULL;
static CFDictionaryRef (*orig_CFNetworkCopySystemProxySettings)(void) = NULL;
static CFArrayRef (*orig_CFNetworkCopyProxiesForURL)(CFURLRef, CFDictionaryRef) = NULL;
static CFTimeZoneRef (*orig_CFTimeZoneCopySystem)(void) = NULL;
static CFTimeZoneRef (*orig_CFTimeZoneCopyDefault)(void) = NULL;

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

static void applyLowLevelCTimeZone(NSString *tzName) {
    if (!tzName || [tzName hasPrefix:@"Sincronizando"] || [tzName hasPrefix:@"Sin "] || tzName.length == 0) return;
    BOOL prev = s_inInternalCall;
    s_inInternalCall = YES;
    setenv("TZ", [tzName UTF8String], 1);
    tzset();
    NSTimeZone *tzObj = [NSTimeZone timeZoneWithName:tzName];
    if (tzObj) {
        [NSTimeZone setDefaultTimeZone:tzObj];
    }
    s_inInternalCall = prev;
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

// Exige una dirección IPv4 real en utun para ignorar los utun0/1/2 IPv6 link-local permanentes de iOS
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
    static BOOL s_cachedUp = NO;
    static CFAbsoluteTime s_lastCheck = 0;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ((now - s_lastCheck) < 0.8) {
        return s_cachedUp;
    }
    s_lastCheck = now;
    s_cachedUp = hasActiveUtunTunnelLive();
    return s_cachedUp;
}

static BOOL isCallerExemptInfrastructure(const void *retAddr) {
    if (s_inInternalCall) return YES;
    if (!retAddr || !orig_dladdr) return NO;
    Dl_info info;
    if (orig_dladdr(retAddr, &info) != 0 && info.dli_fname) {
        if (containsIgnoreCaseC(info.dli_fname, "IGFarmShield") ||
            containsIgnoreCaseC(info.dli_fname, "crane") ||
            containsIgnoreCaseC(info.dli_fname, "ellekit") ||
            containsIgnoreCaseC(info.dli_fname, "MobileSubstrate") ||
            containsIgnoreCaseC(info.dli_fname, "Substitute") ||
            containsIgnoreCaseC(info.dli_fname, "Choicy") ||
            strstr(info.dli_fname, "/usr/lib/dyld") != NULL) {
            return YES;
        }
    }
    return NO;
}

static BOOL isCallerFromTargetAppStrict(const void *retAddr) {
    if (s_inInternalCall || !retAddr || !orig_dladdr) return NO;
    Dl_info info;
    if (orig_dladdr(retAddr, &info) != 0 && info.dli_fname) {
        if (isCallerExemptInfrastructure(retAddr) ||
            strstr(info.dli_fname, "CFNetwork") != NULL ||
            strstr(info.dli_fname, "libnetwork") != NULL ||
            strstr(info.dli_fname, "libswiftNetwork") != NULL) {
            return NO;
        }
        if (containsIgnoreCaseC(info.dli_fname, "/containers/bundle/application/")) {
            return YES;
        }
    }
    return NO;
}

static BOOL isCallerAppOrSwift(const void *retAddr) {
    if (s_inInternalCall || !retAddr || !orig_dladdr) return NO;
    Dl_info info;
    if (orig_dladdr(retAddr, &info) != 0 && info.dli_fname) {
        if (isCallerExemptInfrastructure(retAddr) ||
            strstr(info.dli_fname, "CFNetwork") != NULL ||
            strstr(info.dli_fname, "libnetwork") != NULL ||
            strstr(info.dli_fname, "libswiftNetwork") != NULL ||
            strstr(info.dli_fname, "SystemConfiguration") != NULL ||
            strstr(info.dli_fname, "libsystem_c.dylib") != NULL) {
            return NO;
        }
        if (containsIgnoreCaseC(info.dli_fname, "/containers/bundle/application/") ||
            strstr(info.dli_fname, "libswift") != NULL) {
            return YES;
        }
    }
    return NO;
}

static void persistCurrentProfileToSandboxIfNeeded(NSDictionary *previousDiskSnapshot) {
    if (!liveContainerProfile || s_containerHomeLen == 0) return;
    if (previousDiskSnapshot && [previousDiskSnapshot isEqualToDictionary:liveContainerProfile]) return;

    BOOL prev = s_inInternalCall;
    s_inInternalCall = YES;
    NSString *homePath = [NSString stringWithUTF8String:s_containerHomePath];
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

    const char *envName = orig_getenv ? orig_getenv("CRANE_CONTAINER_NAME") : getenv("CRANE_CONTAINER_NAME");
    const char *envID = orig_getenv ? orig_getenv("CRANE_CONTAINER_ID") : getenv("CRANE_CONTAINER_ID");
    const char *envIdent = orig_getenv ? orig_getenv("CRANE_IDENTIFIER") : getenv("CRANE_IDENTIFIER");

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
    s_inInternalCall = YES;
    s_profileInitialized = YES;

    sessionStartTimestamp = [[NSDate date] timeIntervalSince1970];
    struct timespec tsInit;
    int (*clkInitFn)(clockid_t, struct timespec *) = orig_clock_gettime ? orig_clock_gettime : clock_gettime;
    if (clkInitFn(CLOCK_UPTIME_RAW, &tsInit) == 0) {
        s_realMonoAtLaunch = (double)tsInit.tv_sec + ((double)tsInit.tv_nsec / 1000000000.0);
    }

    NSString *homePath = NSHomeDirectory();
    if (homePath.length > 0) {
        strncpy(s_containerHomePath, [homePath UTF8String], sizeof(s_containerHomePath) - 1);
        s_containerHomePath[sizeof(s_containerHomePath) - 1] = '\0';
        s_containerHomeLen = strlen(s_containerHomePath);
    }

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.burbn.instagram";
    NSString *localPlist = [homePath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
    NSDictionary *diskLoaded = [NSDictionary dictionaryWithContentsOfFile:localPlist];

    NSDictionary *ident = resolveCraneIdentityDict(homePath, bundleID, diskLoaded);
    NSString *keyUUID = ident[@"keyUUID"];
    NSString *craneID = ident[@"craneID"];
    NSString *craneName = ident[@"craneName"];

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
            for (NSString *k in @[@"enabled", @"masterEnabled", @"appEnabled", @"effectiveShieldActive", @"containerName", @"craneIdentifier", @"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity", @"locationAnchored", @"timeZone", @"localeID", @"CarrierMode", @"CarrierName", @"CarrierMCC", @"CarrierMNC", @"CarrierISO", @"ispName", @"cityCountry", @"lastSyncedIP", @"localIP", @"cellularLocalIP", @"ssid", @"bssid", @"bootSessionUUID", @"spoofedBootEpoch", @"spoofedBootUsec", @"lastBootUUIDForTime", @"freeBytes", @"batteryLevel", @"audioVolume", @"brightness", @"pasteboardCount"]) {
                if (settingsEntry[k] != nil) profile[k] = settingsEntry[k];
            }
        }
    }

    NSString *existingIDFV = ([profile[@"idfv"] isKindOfClass:[NSString class]] && [profile[@"idfv"] length] >= 32)
        ? [profile[@"idfv"] uppercaseString]
        : nil;
    NSString *nativeCraneUUID = (origCraneIDFV && origCraneIDFV.length >= 32)
        ? origCraneIDFV
        : (existingIDFV ?: (([craneID containsString:@"-"] && craneID.length >= 32) ? [craneID uppercaseString] : nil));

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
        BOOL manualEnabled = (settingsEntry && settingsEntry[@"enabled"] != nil) ? [settingsEntry[@"enabled"] boolValue] : NO;
        NSString *initialIDFV = nativeCraneUUID ?: @"";

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
            @"craneOriginalIDFV": initialIDFV,
            @"idfv": initialIDFV,
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
        if (nativeCraneUUID.length >= 32) {
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

    NSString *currentBootUUID = profile[@"bootSessionUUID"] ?: @"";
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
// CÁPSULA SUPERIOR CON MONITOR EN VIVO DEL TÚNEL IPV4 SHADOWROCKET
// ============================================================================
static void refreshBadgePillStateOnMain(void) {
    if (!persistentBadgePill || !liveContainerProfile) return;
    BOOL tunnelUp = hasActiveUtunTunnelLive();
    int desiredState = 0;
    if (s_shieldActive && s_spoofNetwork && !tunnelUp) {
        desiredState = 2;
    } else if (s_shieldActive) {
        desiredState = 1;
    } else {
        desiredState = 0;
    }

    if (desiredState == s_lastRenderedBadgeState) return;
    s_lastRenderedBadgeState = desiredState;

    NSString *cName = liveContainerProfile[@"containerName"] ?: @"Default";
    CGRect screenBounds = [UIScreen mainScreen].bounds;

    if (desiredState == 2) {
        persistentBadgePill.backgroundColor = [UIColor colorWithRed:0.80 green:0.12 blue:0.12 alpha:0.96];
        persistentBadgePill.text = [NSString stringWithFormat:@" ⛔ %@ (SIN TÚNEL) ", cName];
    } else if (desiredState == 1) {
        persistentBadgePill.backgroundColor = [UIColor colorWithRed:0.04 green:0.52 blue:0.24 alpha:0.94];
        persistentBadgePill.text = [NSString stringWithFormat:@" 🛡️ %@ ", cName];
    } else {
        persistentBadgePill.backgroundColor = [UIColor colorWithRed:0.38 green:0.38 blue:0.42 alpha:0.90];
        persistentBadgePill.text = [NSString stringWithFormat:@" ⚪ %@ ", cName];
    }

    [persistentBadgePill sizeToFit];
    CGFloat pillW = MIN(MAX(persistentBadgePill.bounds.size.width + 12.0, 62.0), 220.0);
    persistentBadgePill.frame = CGRectMake((screenBounds.size.width - pillW) / 2.0, 18.0, pillW, 16.0);
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
    ensureProfileLoaded();
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

    if (liveVendorUUID && (!liveContainerProfile[@"idfv"] || [liveContainerProfile[@"idfv"] length] < 32)) {
        NSString *captured = [[liveVendorUUID UUIDString] uppercaseString];
        if (captured.length >= 32) {
            NSDictionary *snap = [liveContainerProfile copy];
            origCraneIDFV = captured;
            liveContainerProfile[@"idfv"] = captured;
            liveContainerProfile[@"craneOriginalIDFV"] = captured;
            persistCurrentProfileToSandboxIfNeeded(snap);
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
    NSString *cName = prof[@"containerName"] ?: @"Default";
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
        ? [NSString stringWithFormat:@"4G: %@ (%@)", prof[@"CarrierName"] ?: @"Móvil", prof[@"cellularLocalIP"] ?: @"CGNAT"]
        : [NSString stringWithFormat:@"Wi-Fi (%@)", prof[@"localIP"] ?: @"LAN"];
    int batPct = (int)([prof[@"batteryLevel"] floatValue] * 100.0f);

    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, screenBounds.size.width - 32, 42)];
    toast.layer.cornerRadius = 10.0;
    toast.clipsToBounds = YES;
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont boldSystemFontOfSize:11.5];
    toast.numberOfLines = 2;
    toast.textColor = [UIColor whiteColor];
    toast.userInteractionEnabled = NO;

    if (killSwitchTriggered) {
        toast.backgroundColor = [UIColor colorWithRed:0.80 green:0.12 blue:0.12 alpha:0.96];
        toast.text = [NSString stringWithFormat:@"⛔ %@ (SIN TÚNEL IPV4) • Kill-Switch Activo\nEnciende Shadowrocket para habilitar conexión", cName];
    } else if (s_shieldActive) {
        toast.backgroundColor = [UIColor colorWithRed:0.06 green:0.48 blue:0.24 alpha:0.94];
        toast.text = [NSString stringWithFormat:@"🛡️ %@ • %@ • Bat: %d%%\n%@ • %@",
                      cName, netMode, batPct, prof[@"lastSyncedIP"] ?: @"TCP Puro", prof[@"timeZone"] ?: @""];
    } else {
        toast.backgroundColor = [UIColor colorWithRed:0.45 green:0.45 blue:0.48 alpha:0.92];
        toast.text = [NSString stringWithFormat:@"⚪ %@ • En Pausa Manual (Datos Nativos)", cName];
    }

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
// MODO INVISIBLE EN C, DLOPEN, FOUNDATION, SWIFT Y OBJECTIVE-C
// ============================================================================
static BOOL isHiddenPathForTargetAppC(const char *path) {
    if (!path || !*path) return NO;

    if (containsIgnoreCaseC(path, "cryptex")) return NO;

    if (s_containerHomeLen > 0 && strncmp(path, s_containerHomePath, s_containerHomeLen) == 0) {
        if (strstr(path, ".igshield_container") != NULL || containsIgnoreCaseC(path, "igfarmshield")) {
            return YES;
        }
        return NO;
    }

    if (containsIgnoreCaseC(path, "igfarmshield") || strstr(path, ".igshield_container") != NULL) {
        return YES;
    }

    if (containsIgnoreCaseC(path, "crane.dylib") ||
        containsIgnoreCaseC(path, "libcrane") ||
        containsIgnoreCaseC(path, "cranegui") ||
        containsIgnoreCaseC(path, "com.opa334.crane") ||
        containsIgnoreCaseC(path, "/application support/crane") ||
        containsIgnoreCaseC(path, "/library/crane") ||
        strstr(path, "___Crane_Containers") != NULL) {
        return YES;
    }

    if (strncmp(path, "/var/jb", 7) == 0 ||
        strncmp(path, "/private/var/jb", 15) == 0 ||
        strncmp(path, "/private/preboot", 16) == 0 ||
        containsIgnoreCaseC(path, "/applications/sileo.app") ||
        containsIgnoreCaseC(path, "/applications/zebra.app") ||
        containsIgnoreCaseC(path, "/applications/filza.app") ||
        containsIgnoreCaseC(path, "/applications/cydia.app") ||
        strncmp(path, "/Library/MobileSubstrate", 24) == 0 ||
        containsIgnoreCaseC(path, "ellekit") ||
        containsIgnoreCaseC(path, "choicy") ||
        containsIgnoreCaseC(path, "shadow.dylib") ||
        containsIgnoreCaseC(path, "sileo") ||
        containsIgnoreCaseC(path, "filza") ||
        containsIgnoreCaseC(path, "palera1n") ||
        containsIgnoreCaseC(path, "dopamine") ||
        containsIgnoreCaseC(path, "mobilesubstrate") ||
        containsIgnoreCaseC(path, "substrate") ||
        containsIgnoreCaseC(path, "substitute") ||
        containsIgnoreCaseC(path, "tweakinject") ||
        containsIgnoreCaseC(path, "apt/sources.list")) {
        return YES;
    }
    return NO;
}

static int custom_access(const char *path, int amode) {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC(path)) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_access(path, amode);
}

static int custom_faccessat(int fd, const char *path, int mode, int flag) {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC(path)) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_faccessat(fd, path, mode, flag);
}

static int custom_stat(const char *path, struct stat *buf) {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC(path)) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_stat(path, buf);
}

static int custom_lstat(const char *path, struct stat *buf) {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC(path)) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_lstat(path, buf);
}

static FILE *custom_fopen(const char *path, const char *mode) {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC(path)) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) {
            errno = ENOENT;
            return NULL;
        }
    }
    return orig_fopen(path, mode);
}

static DIR *custom_opendir(const char *dirname) {
    if (s_spoofSecurity && dirname && isHiddenPathForTargetAppC(dirname)) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) {
            errno = ENOENT;
            return NULL;
        }
    }
    return orig_opendir(dirname);
}

static void *custom_dlopen(const char *path, int mode) {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC(path)) {
        if (isCallerAppOrSwift(__builtin_return_address(0))) {
            return NULL;
        }
    }
    return orig_dlopen(path, mode);
}

static char *custom_getenv(const char *name) {
    if (s_spoofSecurity && name && isCallerFromTargetAppStrict(__builtin_return_address(0))) {
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
    if (s_spoofSecurity && name && isHiddenPathForTargetAppC(name)) {
        if (isCallerAppOrSwift(__builtin_return_address(0))) {
            static const char *cleanSystemPaths[] = {
                "/usr/lib/libSystem.B.dylib",
                "/usr/lib/libc++.1.dylib",
                "/usr/lib/libsqlite3.dylib",
                "/usr/lib/libz.1.dylib",
                "/usr/lib/libxml2.2.dylib",
                "/usr/lib/libicucore.A.dylib",
                "/usr/lib/libcompression.dylib",
                "/usr/lib/libarchive.2.dylib",
                "/usr/lib/libbsm.0.dylib",
                "/usr/lib/libCRFSuite.dylib",
                "/usr/lib/libenergytrace.dylib",
                "/usr/lib/liblangid.dylib",
                "/usr/lib/liblzma.5.dylib",
                "/usr/lib/libMobileGestalt.dylib",
                "/usr/lib/libnetwork.dylib",
                "/usr/lib/libresolv.9.dylib"
            };
            return cleanSystemPaths[(image_index * 7U) % 16U];
        }
    }
    return name;
}

static int custom_dladdr(const void *addr, Dl_info *info) {
    int ret = orig_dladdr(addr, info);
    if (s_spoofSecurity && ret != 0 && info && info->dli_fname && isHiddenPathForTargetAppC(info->dli_fname)) {
        if (isCallerAppOrSwift(__builtin_return_address(0))) {
            info->dli_fname = "/System/Library/Frameworks/UIKitCore.framework/UIKitCore";
        }
    }
    return ret;
}

%hook NSData
+ (instancetype)dataWithContentsOfFile:(NSString *)path {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC([path UTF8String])) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) return nil;
    }
    return %orig;
}
+ (instancetype)dataWithContentsOfFile:(NSString *)path options:(NSDataReadingOptions)readOptionsMask error:(NSError * _Nullable *)errorPtr {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC([path UTF8String])) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) {
            if (errorPtr) *errorPtr = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
            return nil;
        }
    }
    return %orig;
}
%end

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
        if ([@[@"sileo", @"zbra", @"filza", @"cydia", @"palera1n", @"dopamine", @"santander"] containsObject:s]) {
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
// ZONA HORARIA (COREFOUNDATION + OBJC + C) E IDIOMA POR CONTENEDOR
// ============================================================================
static CFTimeZoneRef createSpoofedCFTimeZoneOrNull(void) {
    if (!s_spoofLocation || !liveContainerProfile || s_inInternalCall) return NULL;
    NSString *tzName = liveContainerProfile[@"timeZone"];
    if (![tzName isKindOfClass:[NSString class]] || tzName.length == 0 ||
        [tzName hasPrefix:@"Sincronizando"] || [tzName hasPrefix:@"Sin "]) {
        return NULL;
    }
    return CFTimeZoneCreateWithName(kCFAllocatorDefault, (__bridge CFStringRef)tzName, true);
}

static CFTimeZoneRef custom_CFTimeZoneCopySystem(void) {
    CFTimeZoneRef tz = createSpoofedCFTimeZoneOrNull();
    if (tz) return tz;
    return orig_CFTimeZoneCopySystem ? orig_CFTimeZoneCopySystem() : NULL;
}

static CFTimeZoneRef custom_CFTimeZoneCopyDefault(void) {
    CFTimeZoneRef tz = createSpoofedCFTimeZoneOrNull();
    if (tz) return tz;
    return orig_CFTimeZoneCopyDefault ? orig_CFTimeZoneCopyDefault() : NULL;
}

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
    if ([lang caseInsensitiveCompare:@"en-US"] == NSOrderedSame) {
        return @[@"en-US"];
    }
    return @[lang, @"en-US"];
}
%end

// ============================================================================
// CORTAFUEGOS POSIX: KILL-SWITCH IPV4, BLOQUEO LAN RFC1918, DNS TUN Y ANTI-QUIC
// ============================================================================
static BOOL isSocketDatagram(int sockfd) {
    int sockType = 0;
    socklen_t optLen = sizeof(sockType);
    if (getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &sockType, &optLen) == 0) {
        return (sockType == SOCK_DGRAM);
    }
    return NO;
}

static BOOL isRFC1918OrLinkLocalIPv4(uint32_t ipHost) {
    if ((ipHost >> 24) == 10) return YES;                        // 10.0.0.0/8
    if ((ipHost & 0xFFF00000U) == 0xAC100000U) return YES;       // 172.16.0.0/12
    if ((ipHost & 0xFFFF0000U) == 0xC0A80000U) return YES;       // 192.168.0.0/16
    if ((ipHost & 0xFFFF0000U) == 0xA9FE0000U) return YES;       // 169.254.0.0/16
    return NO;
}

static int evaluateSocketPolicy(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    if (!s_spoofNetwork || s_inInternalCall || !addr) return 0;

    if (addr->sa_family == AF_INET && addrlen >= (socklen_t)sizeof(struct sockaddr_in)) {
        struct sockaddr_in sin;
        memcpy(&sin, addr, sizeof(sin));
        uint32_t ipHost = ntohl(sin.sin_addr.s_addr);
        if (ipHost == 0 || (ipHost >> 24) == 127) return 0;

        // 1. Kill-Switch real: exige interfaz utun IPv4 activa de Shadowrocket
        if (!hasActiveUtunTunnelCached()) {
            return ENETUNREACH;
        }

        // 2. Bloquear acceso al router/LAN física (RFC1918) y multicast incluso en puerto 53
        // Nota: 198.18.0.0/15 (Fake-IP / DNS TUN de Shadowrocket), 1.1.1.1 y 8.8.8.8 pasan limpios
        if (isRFC1918OrLinkLocalIPv4(ipHost) || ipHost >= 0xE0000000U) {
            return EHOSTUNREACH;
        }

        // 3. Permitir consultas DNS (:53) hacia IPs no-LAN interceptadas por el túnel utun
        uint16_t dstPort = ntohs(sin.sin_port);
        if (dstPort == 53) {
            return 0;
        }

        // 4. Bloquear QUIC (UDP 443/80), STUN/WebRTC y cualquier otro UDP externo
        if (isSocketDatagram(sockfd)) {
            return EHOSTUNREACH;
        }
        return 0;
    }

    if (addr->sa_family == AF_INET6 && addrlen >= (socklen_t)sizeof(struct sockaddr_in6)) {
        struct sockaddr_in6 sin6;
        memcpy(&sin6, addr, sizeof(sin6));

        static const uint8_t loop6[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1};
        static const uint8_t zero6[16] = {0};
        if (memcmp(sin6.sin6_addr.s6_addr, loop6, 16) == 0 ||
            memcmp(sin6.sin6_addr.s6_addr, zero6, 16) == 0) {
            return 0;
        }

        static const uint8_t v4mapPrefix[12] = {0,0,0,0,0,0,0,0,0,0,0xff,0xff};
        if (memcmp(sin6.sin6_addr.s6_addr, v4mapPrefix, 12) == 0) {
            uint32_t mappedIPv4 = 0;
            memcpy(&mappedIPv4, &sin6.sin6_addr.s6_addr[12], 4);
            uint32_t ipHost = ntohl(mappedIPv4);
            if (ipHost == 0 || (ipHost >> 24) == 127) return 0;

            if (!hasActiveUtunTunnelCached()) {
                return ENETUNREACH;
            }
            if (isRFC1918OrLinkLocalIPv4(ipHost) || ipHost >= 0xE0000000U) {
                return EHOSTUNREACH;
            }
            uint16_t dstPort = ntohs(sin6.sin6_port);
            if (dstPort == 53) {
                return 0;
            }
            if (isSocketDatagram(sockfd)) {
                return EHOSTUNREACH;
            }
            return 0;
        }

        return ENETUNREACH;
    }

    return 0;
}

static int custom_bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    if (s_spoofNetwork && !s_inInternalCall && addr &&
        addr->sa_family == AF_INET && addrlen >= (socklen_t)sizeof(struct sockaddr_in)) {
        struct sockaddr_in sin;
        memcpy(&sin, addr, sizeof(sin));
        if ((s_spoofedCellularAddr != 0 && sin.sin_addr.s_addr == s_spoofedCellularAddr) ||
            (s_spoofedLanAddr != 0 && sin.sin_addr.s_addr == s_spoofedLanAddr)) {
            sin.sin_addr.s_addr = htonl(INADDR_ANY);
            return orig_bind(sockfd, (const struct sockaddr *)&sin, sizeof(sin));
        }
    }
    return orig_bind(sockfd, addr, addrlen);
}

static int custom_setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen) {
    if (s_spoofNetwork && !s_inInternalCall && optval && optlen >= (socklen_t)sizeof(int)) {
        if ((level == IPPROTO_IP && optname == IP_BOUND_IF) ||
            (level == IPPROTO_IPV6 && optname == IPV6_BOUND_IF)) {
            int reqIndex = 0;
            memcpy(&reqIndex, optval, sizeof(int));
            if (reqIndex > 0) {
                char ifName[IF_NAMESIZE] = {0};
                if (if_indextoname((unsigned int)reqIndex, ifName) != NULL) {
                    if (strcmp(ifName, "lo0") != 0 && !isTunnelInterfaceNameC(ifName)) {
                        return 0;
                    }
                }
            }
        }
    }
    return orig_setsockopt(sockfd, level, optname, optval, optlen);
}

static int custom_connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    int blockErr = evaluateSocketPolicy(sockfd, addr, addrlen);
    if (blockErr != 0) {
        errno = blockErr;
        return -1;
    }
    return orig_connect(sockfd, addr, addrlen);
}

static ssize_t custom_sendto(int sockfd, const void *buf, size_t len, int flags, const struct sockaddr *dest_addr, socklen_t addrlen) {
    if (dest_addr) {
        int blockErr = evaluateSocketPolicy(sockfd, dest_addr, addrlen);
        if (blockErr != 0) {
            errno = blockErr;
            return -1;
        }
    }
    return orig_sendto(sockfd, buf, len, flags, dest_addr, addrlen);
}

static ssize_t custom_sendmsg(int sockfd, const struct msghdr *msg, int flags) {
    if (msg && msg->msg_name && msg->msg_namelen >= (socklen_t)sizeof(struct sockaddr)) {
        int blockErr = evaluateSocketPolicy(sockfd, (const struct sockaddr *)msg->msg_name, msg->msg_namelen);
        if (blockErr != 0) {
            errno = blockErr;
            return -1;
        }
    }
    return orig_sendmsg(sockfd, msg, flags);
}

// ============================================================================
// COHERENCIA DE RED, CARRIER SINTÉTICO SIN SIM Y GETIFADDRS ALINEADO EN ARM64
// ============================================================================
static Boolean custom_SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    Boolean ok = orig_SCNetworkReachabilityGetFlags ? orig_SCNetworkReachabilityGetFlags(target, flags) : FALSE;
    if (!ok || !flags || !s_spoofNetwork) return ok;
    if (!isCallerAppOrSwift(__builtin_return_address(0))) return ok;

    if (!hasActiveUtunTunnelCached()) {
        *flags = 0;
        return TRUE;
    }

    *flags &= ~((SCNetworkReachabilityFlags)kSCNetworkReachabilityFlagsTransientConnection);
    if ((*flags & kSCNetworkReachabilityFlagsReachable) != 0) {
        if (s_isCellularMode) {
            *flags |= kSCNetworkReachabilityFlagsIsWWAN;
        } else {
            *flags &= ~((SCNetworkReachabilityFlags)kSCNetworkReachabilityFlagsIsWWAN);
        }
    }
    return ok;
}

static CFDictionaryRef custom_CFNetworkCopySystemProxySettings(void) {
    CFDictionaryRef origRef = orig_CFNetworkCopySystemProxySettings ? orig_CFNetworkCopySystemProxySettings() : NULL;
    if (!origRef || !s_spoofNetwork) return origRef;
    if (!isCallerFromTargetAppStrict(__builtin_return_address(0))) return origRef;
    if (!hasActiveUtunTunnelCached()) return origRef;

    NSDictionary *origDict = (__bridge NSDictionary *)origRef;
    NSMutableDictionary *cleanDict = [NSMutableDictionary dictionary];
    NSString *primaryIf = s_isCellularMode ? @"pdp_ip0" : @"en0";

    NSDictionary *scoped = origDict[@"__SCOPED__"];
    if ([scoped isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *cleanScoped = [NSMutableDictionary dictionary];
        for (NSString *ifKey in scoped) {
            if (isTunnelInterfaceNameC([ifKey UTF8String])) continue;
            if (s_isCellularMode && ([ifKey isEqualToString:@"en0"] || isSecondaryWifiInterfaceNameC([ifKey UTF8String]))) {
                continue;
            }
            if (!s_isCellularMode && [ifKey hasPrefix:@"pdp_ip"]) continue;
            cleanScoped[ifKey] = @{};
        }
        if (cleanScoped.count == 0) cleanScoped[primaryIf] = @{};
        cleanDict[@"__SCOPED__"] = cleanScoped;
    } else {
        cleanDict[@"__SCOPED__"] = @{primaryIf: @{}};
    }

    CFRelease(origRef);
    return (__bridge_retained CFDictionaryRef)cleanDict;
}

static CFArrayRef custom_CFNetworkCopyProxiesForURL(CFURLRef url, CFDictionaryRef proxySettings) {
    if (s_spoofNetwork && isCallerFromTargetAppStrict(__builtin_return_address(0))) {
        if (hasActiveUtunTunnelCached()) {
            NSDictionary *directProxy = @{
                (__bridge NSString *)kCFProxyTypeKey : (__bridge NSString *)kCFProxyTypeNone
            };
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
    NSDictionary *orig = %orig;
    if (s_spoofNetwork && orig != nil && isCallerFromTargetAppStrict(__builtin_return_address(0))) {
        if (hasActiveUtunTunnelCached()) return nil;
    }
    return orig;
}
%end

static CTCarrier *sharedSyntheticCarrier(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_syntheticCarrier = [[CTCarrier alloc] init];
    });
    return s_syntheticCarrier;
}

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
- (CTCarrier *)subscriberCellularProvider {
    if (!s_spoofNetwork || !liveContainerProfile) return %orig;
    if (!s_isCellularMode) return nil;
    return %orig ?: sharedSyntheticCarrier();
}
- (NSDictionary<NSString *, CTCarrier *> *)serviceSubscriberCellularProviders {
    if (!s_spoofNetwork || !liveContainerProfile) return %orig;
    if (!s_isCellularMode) return @{};
    NSDictionary *orig = %orig;
    if (orig && orig.count > 0) return orig;
    return @{@"0000000100000001": sharedSyntheticCarrier()};
}
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

static void writeSockaddrInAddrSafely(struct sockaddr *sa, in_addr_t ipv4NetOrder) {
    if (!sa || sa->sa_family != AF_INET) return;
    memcpy((char *)sa + offsetof(struct sockaddr_in, sin_addr), &ipv4NetOrder, sizeof(in_addr_t));
}

static void applySpoofedCellularNode(struct ifaddrs *node) {
    if (!node || s_spoofedCellularAddr == 0) return;
    node->ifa_name = (char *)"pdp_ip0";
    writeSockaddrInAddrSafely(node->ifa_addr, s_spoofedCellularAddr);
    writeSockaddrInAddrSafely(node->ifa_netmask, htonl(0xFFFFFFFFU));
    writeSockaddrInAddrSafely(node->ifa_dstaddr, s_spoofedCellularAddr);
}

static void applySpoofedWifiLanNode(struct ifaddrs *node) {
    if (!node || s_spoofedLanAddr == 0) return;
    writeSockaddrInAddrSafely(node->ifa_addr, s_spoofedLanAddr);
    writeSockaddrInAddrSafely(node->ifa_netmask, s_spoofedLanMask);
    writeSockaddrInAddrSafely(node->ifa_dstaddr, s_spoofedLanBcast);
}

static int custom_getifaddrs(struct ifaddrs **ifap) {
    int res = orig_getifaddrs(ifap);
    if (res != 0 || !ifap || !*ifap || !s_spoofNetwork) return res;
    if (!isCallerAppOrSwift(__builtin_return_address(0))) return res;

    BOOL hasLiveCellularIPv4 = NO;
    for (struct ifaddrs *scan = *ifap; scan != NULL; scan = scan->ifa_next) {
        if (scan->ifa_name && strcmp(scan->ifa_name, "pdp_ip0") == 0 &&
            (scan->ifa_flags & IFF_UP) && scan->ifa_addr && scan->ifa_addr->sa_family == AF_INET) {
            struct sockaddr_in sin;
            memcpy(&sin, scan->ifa_addr, sizeof(sin));
            if (sin.sin_addr.s_addr != 0) {
                hasLiveCellularIPv4 = YES;
                break;
            }
        }
    }

    struct ifaddrs *head = *ifap;
    if (head->ifa_name) {
        if (isTunnelInterfaceNameC(head->ifa_name)) {
            head->ifa_name = (char *)"lo0";
            head->ifa_flags &= ~IFF_POINTOPOINT;
        } else if (strcmp(head->ifa_name, "en0") == 0) {
            if (s_isCellularMode) {
                if (!hasLiveCellularIPv4 && head->ifa_addr && head->ifa_addr->sa_family == AF_INET) {
                    applySpoofedCellularNode(head);
                } else {
                    head->ifa_name = (char *)"lo0";
                }
            } else if (head->ifa_addr && head->ifa_addr->sa_family == AF_INET) {
                applySpoofedWifiLanNode(head);
            }
        }
    }

    struct ifaddrs *prev = head;
    struct ifaddrs *curr = head->ifa_next;

    while (curr != NULL) {
        BOOL shouldHide = NO;
        if (curr->ifa_name) {
            if (isTunnelInterfaceNameC(curr->ifa_name)) {
                shouldHide = YES;
            } else if (s_isCellularMode && isSecondaryWifiInterfaceNameC(curr->ifa_name)) {
                shouldHide = YES;
            } else if (strcmp(curr->ifa_name, "en0") == 0) {
                if (s_isCellularMode) {
                    if (hasLiveCellularIPv4) {
                        shouldHide = YES;
                    } else if (curr->ifa_addr && curr->ifa_addr->sa_family == AF_INET) {
                        applySpoofedCellularNode(curr);
                    } else {
                        shouldHide = YES;
                    }
                } else {
                    if (curr->ifa_addr && curr->ifa_addr->sa_family == AF_INET) {
                        applySpoofedWifiLanNode(curr);
                    } else if (curr->ifa_addr && curr->ifa_addr->sa_family == AF_INET6) {
                        shouldHide = YES;
                    }
                }
            } else if (strncmp(curr->ifa_name, "pdp_ip", 6) == 0) {
                if (!s_isCellularMode) {
                    shouldHide = YES;
                } else if (curr->ifa_addr && curr->ifa_addr->sa_family == AF_INET) {
                    applySpoofedCellularNode(curr);
                } else if (curr->ifa_addr && curr->ifa_addr->sa_family == AF_INET6) {
                    shouldHide = YES;
                }
            } else if (curr->ifa_addr && curr->ifa_addr->sa_family == AF_INET6 && strcmp(curr->ifa_name, "lo0") != 0) {
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
    if (s_isCellularMode) return NULL;
    NSDictionary *fakeWifi = @{
        @"SSID": liveContainerProfile[@"ssid"] ?: @"HomeWiFi-5G",
        @"BSSID": liveContainerProfile[@"bssid"] ?: @"a4:83:e7:21:9a:10",
        @"SSIDDATA": [(liveContainerProfile[@"ssid"] ?: @"HomeWiFi-5G") dataUsingEncoding:NSUTF8StringEncoding]
    };
    return (__bridge_retained CFDictionaryRef)fakeWifi;
}

// ============================================================================
// TELEMETRÍA ORGÁNICA, RELOJ UPTIME O(1) Y BOOTTIME COHERENTE POR CONTENEDOR
// ============================================================================
%hook UIDevice
- (NSString *)name {
    if (!s_spoofHardware) return %orig;
    return @"iPhone";
}
- (NSUUID *)identifierForVendor {
    NSUUID *origUUID = %orig;
    if (origUUID && !origCraneIDFV) {
        origCraneIDFV = [[origUUID UUIDString] uppercaseString];
        if (liveContainerProfile && (!liveContainerProfile[@"idfv"] || [liveContainerProfile[@"idfv"] length] < 32)) {
            NSDictionary *snap = [liveContainerProfile copy];
            liveContainerProfile[@"idfv"] = origCraneIDFV;
            liveContainerProfile[@"craneOriginalIDFV"] = origCraneIDFV;
            persistCurrentProfileToSandboxIfNeeded(snap);
        }
    }
    if (s_spoofIDs && liveContainerProfile) {
        NSString *profUUIDStr = liveContainerProfile[@"idfv"];
        if ([profUUIDStr isKindOfClass:[NSString class]] && profUUIDStr.length >= 32) {
            NSUUID *customUUID = [[NSUUID alloc] initWithUUIDString:profUUIDStr];
            if (customUUID) return customUUID;
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

static unsigned long long currentSmoothFreeDiskBytes(void) {
    unsigned long long baseFree = [liveContainerProfile[@"freeBytes"] unsignedLongLongValue];
    double elapsed = [[NSDate date] timeIntervalSince1970] - sessionStartTimestamp;
    if (elapsed < 0.0) elapsed = 0.0;
    unsigned long long consumed = (unsigned long long)(elapsed * 2048.0);
    unsigned long long cap = 16ULL * 1024ULL * 1024ULL;
    if (consumed > cap) consumed = cap;
    return (baseFree > consumed) ? (baseFree - consumed) : baseFree;
}

static int custom_statfs(const char *path, struct statfs *buf) {
    int ret = orig_statfs(path, buf);
    if (ret == 0 && buf && s_spoofHardware && liveContainerProfile && isCallerAppOrSwift(__builtin_return_address(0))) {
        if (liveContainerProfile[@"freeBytes"] && buf->f_bsize > 0) {
            unsigned long long finalFree = currentSmoothFreeDiskBytes();
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
    if (!s_spoofHardware || !orig || !liveContainerProfile || !isCallerAppOrSwift(__builtin_return_address(0))) return orig;
    NSMutableDictionary *modified = [orig mutableCopy];
    if (liveContainerProfile[@"freeBytes"]) {
        modified[NSFileSystemFreeSize] = @(currentSmoothFreeDiskBytes());
    }
    return modified;
}
- (BOOL)fileExistsAtPath:(NSString *)path {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC([path UTF8String])) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) return NO;
    }
    return %orig;
}
- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC([path UTF8String])) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) return NO;
    }
    return %orig;
}
- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC([path UTF8String])) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
            return nil;
        }
    }
    return %orig;
}
- (NSDictionary<NSFileAttributeKey, id> *)attributesOfItemAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if (s_spoofSecurity && path && isHiddenPathForTargetAppC([path UTF8String])) {
        if (!isCallerExemptInfrastructure(__builtin_return_address(0))) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
            return nil;
        }
    }
    return %orig;
}
%end

%hook NSURL
- (BOOL)checkResourceIsReachableAndReturnError:(NSError * _Nullable *)error {
    if (s_spoofSecurity && [self isFileURL]) {
        NSString *p = [self path];
        if (p && isHiddenPathForTargetAppC([p UTF8String])) {
            if (!isCallerExemptInfrastructure(__builtin_return_address(0))) {
                if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
                return NO;
            }
        }
    }
    return %orig;
}
%end

%hook NSProcessInfo
- (NSString *)hostName {
    if (s_spoofHardware || s_spoofIDs) {
        return @"iphone.local";
    }
    return %orig;
}
- (NSTimeInterval)systemUptime {
    if ((s_spoofIDs || s_spoofHardware) && s_spoofedBootSec > 0 && !s_inInternalCall) {
        return spoofedSystemUptime();
    }
    return %orig;
}
- (NSDictionary<NSString *, NSString *> *)environment {
    NSDictionary *orig = %orig;
    if (!s_spoofSecurity || !orig || !isCallerAppOrSwift(__builtin_return_address(0))) {
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

// Sincroniza CLOCK_UPTIME_RAW en O(1) sin tocar CLOCK_MONOTONIC (evita bloqueos en condition_variable)
static int custom_clock_gettime(clockid_t clk_id, struct timespec *tp) {
    int ret = orig_clock_gettime(clk_id, tp);
    if (ret == 0 && tp && !s_inInternalCall && (s_spoofIDs || s_spoofHardware) &&
        clk_id == CLOCK_UPTIME_RAW && s_spoofedBootSec > 0 && s_realMonoAtLaunch > 0.0) {
        double monoNow = (double)tp->tv_sec + ((double)tp->tv_nsec / 1000000000.0);
        double delta = monoNow - s_realMonoAtLaunch;
        if (delta < 0.0) delta = 0.0;
        double totalSpoofed = s_baseAwakeUptimeSec + delta;
        time_t secPart = (time_t)totalSpoofed;
        long nsecPart = (long)((totalSpoofed - (double)secPart) * 1000000000.0);
        if (nsecPart < 0L) nsecPart = 0L;
        if (nsecPart >= 1000000000L) nsecPart = 999999999L;
        tp->tv_sec = secPart;
        tp->tv_nsec = nsecPart;
    }
    return ret;
}

static int custom_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (ret == 0 && name && oldlenp && liveContainerProfile && isCallerAppOrSwift(__builtin_return_address(0))) {
        if (strcmp(name, "kern.bootsessionuuid") == 0 && s_spoofIDs) {
            NSString *bootUUID = liveContainerProfile[@"bootSessionUUID"];
            if (bootUUID) {
                const char *uuidStr = [bootUUID UTF8String];
                size_t len = strlen(uuidStr) + 1;
                if (oldp && *oldlenp >= len) memcpy(oldp, uuidStr, len);
                *oldlenp = len;
            }
        } else if (strcmp(name, "kern.boottime") == 0 && (s_spoofIDs || s_spoofHardware) && s_spoofedBootSec > 0) {
            struct timeval tv;
            tv.tv_sec = s_spoofedBootSec;
            tv.tv_usec = s_spoofedBootUsec;
            if (oldp && *oldlenp >= sizeof(struct timeval)) {
                memcpy(oldp, &tv, sizeof(struct timeval));
            }
            *oldlenp = sizeof(struct timeval);
        } else if (strcmp(name, "kern.hostname") == 0 && (s_spoofHardware || s_spoofIDs)) {
            static const char *cleanHost = "iPhone";
            size_t len = strlen(cleanHost) + 1;
            if (oldp && *oldlenp >= len) memcpy(oldp, cleanHost, len);
            *oldlenp = len;
        }
    }
    return ret;
}

static int custom_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (ret == 0 && name && namelen == 2 && oldlenp &&
        name[0] == CTL_KERN && name[1] == KERN_BOOTTIME &&
        (s_spoofIDs || s_spoofHardware) && s_spoofedBootSec > 0 &&
        isCallerAppOrSwift(__builtin_return_address(0))) {
        struct timeval tv;
        tv.tv_sec = s_spoofedBootSec;
        tv.tv_usec = s_spoofedBootUsec;
        if (oldp && *oldlenp >= sizeof(struct timeval)) {
            memcpy(oldp, &tv, sizeof(struct timeval));
        }
        *oldlenp = sizeof(struct timeval);
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
    MSHookFunction((void *)dladdr, (void *)custom_dladdr, (void **)&orig_dladdr);
    MSHookFunction((void *)getenv, (void *)custom_getenv, (void **)&orig_getenv);
    MSHookFunction((void *)getifaddrs, (void *)custom_getifaddrs, (void **)&orig_getifaddrs);

    ensureProfileLoaded();

    MSHookFunction((void *)_dyld_get_image_name, (void *)custom_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
    MSHookFunction((void *)access, (void *)custom_access, (void **)&orig_access);
    MSHookFunction((void *)stat, (void *)custom_stat, (void **)&orig_stat);
    MSHookFunction((void *)lstat, (void *)custom_lstat, (void **)&orig_lstat);
    MSHookFunction((void *)fopen, (void *)custom_fopen, (void **)&orig_fopen);
    MSHookFunction((void *)sysctlbyname, (void *)custom_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)sysctl, (void *)custom_sysctl, (void **)&orig_sysctl);
    MSHookFunction((void *)statfs, (void *)custom_statfs, (void **)&orig_statfs);
    MSHookFunction((void *)CNCopyCurrentNetworkInfo, (void *)custom_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo);

    void *symDlopen = dlsym(RTLD_DEFAULT, "dlopen");
    if (symDlopen) MSHookFunction(symDlopen, (void *)custom_dlopen, (void **)&orig_dlopen);

    void *symClockGettime = dlsym(RTLD_DEFAULT, "clock_gettime");
    if (symClockGettime) MSHookFunction(symClockGettime, (void *)custom_clock_gettime, (void **)&orig_clock_gettime);

    void *symCFTimeZoneSys = dlsym(RTLD_DEFAULT, "CFTimeZoneCopySystem");
    if (symCFTimeZoneSys) MSHookFunction(symCFTimeZoneSys, (void *)custom_CFTimeZoneCopySystem, (void **)&orig_CFTimeZoneCopySystem);

    void *symCFTimeZoneDef = dlsym(RTLD_DEFAULT, "CFTimeZoneCopyDefault");
    if (symCFTimeZoneDef) MSHookFunction(symCFTimeZoneDef, (void *)custom_CFTimeZoneCopyDefault, (void **)&orig_CFTimeZoneCopyDefault);

    void *symFaccessat = dlsym(RTLD_DEFAULT, "faccessat");
    if (symFaccessat) MSHookFunction(symFaccessat, (void *)custom_faccessat, (void **)&orig_faccessat);

    void *symOpendir = dlsym(RTLD_DEFAULT, "opendir");
    if (symOpendir) MSHookFunction(symOpendir, (void *)custom_opendir, (void **)&orig_opendir);

    void *symReachFlags = dlsym(RTLD_DEFAULT, "SCNetworkReachabilityGetFlags");
    if (symReachFlags) MSHookFunction(symReachFlags, (void *)custom_SCNetworkReachabilityGetFlags, (void **)&orig_SCNetworkReachabilityGetFlags);

    void *symBind = dlsym(RTLD_DEFAULT, "bind");
    if (symBind) MSHookFunction(symBind, (void *)custom_bind, (void **)&orig_bind);

    void *symSetsockopt = dlsym(RTLD_DEFAULT, "setsockopt");
    if (symSetsockopt) MSHookFunction(symSetsockopt, (void *)custom_setsockopt, (void **)&orig_setsockopt);

    void *symConnect = dlsym(RTLD_DEFAULT, "connect");
    if (symConnect) MSHookFunction(symConnect, (void *)custom_connect, (void **)&orig_connect);

    void *symSendto = dlsym(RTLD_DEFAULT, "sendto");
    if (symSendto) MSHookFunction(symSendto, (void *)custom_sendto, (void **)&orig_sendto);

    void *symSendmsg = dlsym(RTLD_DEFAULT, "sendmsg");
    if (symSendmsg) MSHookFunction(symSendmsg, (void *)custom_sendmsg, (void **)&orig_sendmsg);

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
