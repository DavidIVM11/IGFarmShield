#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CFNetwork/CFNetwork.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <SystemConfiguration/SCNetworkReachability.h>
#import <AVFoundation/AVFoundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
#import <time.h>
#import <substrate.h>

#define GLOBAL_STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CURRENT_SCHEMA_VERSION 22

static NSString *origCraneIDFV = nil;
static NSMutableDictionary *liveContainerProfile = nil;
static NSTimeInterval sessionStartTimestamp = 0;
static BOOL bannerShownThisSession = NO;
static __thread BOOL isInitializingProfile = NO;

static int (*orig_dladdr)(const void *, Dl_info *) = NULL;
static const char *(*orig_dyld_get_image_name)(uint32_t image_index) = NULL;
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*orig_statfs)(const char *, struct statfs *) = NULL;
static int (*orig_access)(const char *, int) = NULL;
static int (*orig_stat)(const char *, struct stat *) = NULL;
static int (*orig_lstat)(const char *, struct stat *) = NULL;
static int (*orig_getifaddrs)(struct ifaddrs **) = NULL;
static Boolean (*orig_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *) = NULL;
static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef) = NULL;

static NSDictionary *getGlobalState() {
    return [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST] ?: @{};
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

static BOOL isCallerFromTargetApp(const void *retAddr) {
    if (!retAddr || !orig_dladdr) return YES;
    Dl_info info;
    if (orig_dladdr(retAddr, &info) != 0 && info.dli_fname) {
        if (strstr(info.dli_fname, "/Containers/Bundle/Application/") != NULL) {
            return YES;
        }
        return NO;
    }
    return YES;
}

static NSDictionary *resolveCraneIdentityDict(NSString *homePath) {
    NSString *folderUUID = [homePath lastPathComponent] ?: @"Default";
    NSString *metaPath = [homePath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];

    NSString *craneID = nil;
    NSString *craneName = nil;

    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    if ([env[@"CRANE_CONTAINER_NAME"] length] > 0) craneName = env[@"CRANE_CONTAINER_NAME"];
    if ([env[@"CRANE_CONTAINER_ID"] length] > 0) craneID = env[@"CRANE_CONTAINER_ID"];

    if ([meta isKindOfClass:[NSDictionary class]]) {
        for (NSString *rk in @[@"com.opa334.crane.container.name", @"craneContainerName"]) {
            if ([meta[rk] isKindOfClass:[NSString class]] && [meta[rk] length] > 0) craneName = meta[rk];
        }
        for (NSString *ik in @[@"com.opa334.crane.container.identifier", @"com.opa334.crane.container.id", @"craneContainerIdentifier"]) {
            if ([meta[ik] isKindOfClass:[NSString class]] && [meta[ik] length] > 0) craneID = meta[ik];
        }
        NSDictionary *userInfo = meta[@"MCMMetadataUserInfo"];
        if ([userInfo isKindOfClass:[NSDictionary class]]) {
            for (NSString *k in userInfo) {
                NSString *kl = [k lowercaseString];
                id val = userInfo[k];
                if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
                    if ([kl containsString:@"name"] || [kl containsString:@"label"] || [kl containsString:@"title"]) {
                        craneName = val;
                    } else if (([kl containsString:@"id"] || [kl containsString:@"crane"] || [kl containsString:@"container"] || [kl containsString:@"uuid"]) && ![val hasPrefix:@"com."]) {
                        craneID = val;
                    }
                }
            }
        }
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

static NSMutableDictionary *getContainerProfile() {
    if (liveContainerProfile) return liveContainerProfile;
    if (isInitializingProfile) return nil;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        isInitializingProfile = YES;
        sessionStartTimestamp = [[NSDate date] timeIntervalSince1970];
        NSString *homePath = NSHomeDirectory();
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.burbn.instagram";

        NSDictionary *ident = resolveCraneIdentityDict(homePath);
        NSString *keyUUID = ident[@"keyUUID"];
        NSString *craneID = ident[@"craneID"];
        NSString *craneName = ident[@"craneName"];

        NSString *localPlist = [homePath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        NSDictionary *globalSt = getGlobalState();
        BOOL globalSchemaUpToDate = ([globalSt[@"schemaVersion"] intValue] == CURRENT_SCHEMA_VERSION);
        NSDictionary *byUUID = (globalSchemaUpToDate && [globalSt[@"containersByUUID"] isKindOfClass:[NSDictionary class]])
            ? globalSt[@"containersByUUID"]
            : @{};

        NSDictionary *settingsEntry = [byUUID[keyUUID] isKindOfClass:[NSDictionary class]] ? byUUID[keyUUID] : nil;
        if (!settingsEntry) {
            for (NSString *existingKey in byUUID) {
                NSDictionary *cand = byUUID[existingKey];
                if (![cand isKindOfClass:[NSDictionary class]] || ![cand[@"bundleID"] isEqualToString:bundleID]) continue;
                NSString *candPath = cand[@"path"] ?: @"";
                NSString *candCraneID = cand[@"craneIdentifier"] ?: @"";
                NSString *candName = cand[@"containerName"] ?: @"";
                if ([candPath isEqualToString:homePath] ||
                    [existingKey caseInsensitiveCompare:keyUUID] == NSOrderedSame ||
                    (candCraneID.length > 0 && [candCraneID caseInsensitiveCompare:craneID] == NSOrderedSame) ||
                    (craneName.length > 0 && [candName caseInsensitiveCompare:craneName] == NSOrderedSame)) {
                    settingsEntry = cand;
                    break;
                }
            }
        }

        NSDictionary *diskLoaded = [NSDictionary dictionaryWithContentsOfFile:localPlist];
        NSMutableDictionary *profile = nil;

        if (settingsEntry && settingsEntry[@"idfv"]) {
            profile = [settingsEntry mutableCopy];
        } else if ([diskLoaded isKindOfClass:[NSDictionary class]] &&
                   [diskLoaded[@"schemaVersion"] intValue] == CURRENT_SCHEMA_VERSION &&
                   diskLoaded[@"idfv"]) {
            profile = [diskLoaded mutableCopy];
        }

        if (profile && settingsEntry) {
            for (NSString *k in @[@"enabled", @"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity", @"locationAnchored", @"timeZone", @"localeID", @"CarrierMode", @"CarrierName", @"CarrierMCC", @"CarrierMNC", @"CarrierISO", @"ispName", @"cityCountry", @"lastSyncedIP", @"localIP", @"ssid", @"bssid", @"idfv", @"bootSessionUUID", @"freeBytes", @"batteryLevel", @"audioVolume", @"brightness", @"uptimeOffset"]) {
                if (settingsEntry[k] != nil) profile[k] = settingsEntry[k];
            }
        }

        if (!profile || !profile[@"idfv"]) {
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

            // Nace SIEMPRE EN PAUSA (@NO) hasta que el usuario lo active manualmente en Settings
            BOOL manualEnabled = (settingsEntry && settingsEntry[@"enabled"] != nil) ? [settingsEntry[@"enabled"] boolValue] : NO;

            profile = [@{
                @"schemaVersion": @(CURRENT_SCHEMA_VERSION),
                @"containerUUID": keyUUID,
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
                @"craneOriginalIDFV": origCraneIDFV ?: craneID,
                @"idfv": [[NSUUID UUID] UUIDString],
                @"shieldDeviceID": [[NSUUID UUID] UUIDString],
                @"bootSessionUUID": [[NSUUID UUID] UUIDString],
                @"cloudUUID": [[NSUUID UUID] UUIDString],
                @"bssid": bssid,
                @"ssid": ssid,
                @"localIP": localIP,
                @"freeBytes": @(freeBytes),
                @"uptimeOffset": @(1800 + (NSUInteger)(seed % 82000)),
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
            if (!profile[@"uptimeOffset"]) profile[@"uptimeOffset"] = @(3600 + arc4random_uniform(50000));
            profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
            profile[@"containerUUID"] = keyUUID;
            profile[@"bundleID"] = bundleID;
            profile[@"path"] = homePath;
        }

        [profile writeToFile:localPlist atomically:YES];

        if ([profile[@"enabled"] boolValue] && [profile[@"spoofLocation"] boolValue] && profile[@"timeZone"]) {
            applyLowLevelCTimeZone(profile[@"timeZone"]);
        }

        liveContainerProfile = profile;
        isInitializingProfile = NO;
    });
    return liveContainerProfile;
}

static BOOL isModuleActive(NSString *moduleKey) {
    if (isInitializingProfile || !liveContainerProfile) return NO;

    NSDictionary *state = getGlobalState();
    if ([state[@"schemaVersion"] intValue] != CURRENT_SCHEMA_VERSION) return NO;
    if (!state[@"masterEnabled"] || ![state[@"masterEnabled"] boolValue]) return NO;

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.burbn.instagram"] && (!state[@"enableIG"] || ![state[@"enableIG"] boolValue])) return NO;
    if ([bundleID isEqualToString:@"com.reddit.Reddit"] && (!state[@"enableReddit"] || ![state[@"enableReddit"] boolValue])) return NO;

    NSString *keyUUID = liveContainerProfile[@"containerUUID"];
    NSString *craneID = liveContainerProfile[@"craneIdentifier"];
    NSString *cName = liveContainerProfile[@"containerName"];
    NSDictionary *byUUID = state[@"containersByUUID"];

    if ([byUUID isKindOfClass:[NSDictionary class]]) {
        NSDictionary *savedProf = byUUID[keyUUID];
        if (!savedProf && craneID) savedProf = byUUID[craneID];
        if (!savedProf) {
            for (NSString *k in byUUID) {
                NSDictionary *cand = byUUID[k];
                if (![cand isKindOfClass:[NSDictionary class]] || ![cand[@"bundleID"] isEqualToString:bundleID]) continue;
                if ((craneID && [cand[@"craneIdentifier"] caseInsensitiveCompare:craneID] == NSOrderedSame) ||
                    (cName && [cand[@"containerName"] caseInsensitiveCompare:cName] == NSOrderedSame)) {
                    savedProf = cand;
                    break;
                }
            }
        }
        if (savedProf) {
            if (!savedProf[@"enabled"] || ![savedProf[@"enabled"] boolValue]) return NO;
            if (moduleKey && savedProf[moduleKey] != nil) return [savedProf[moduleKey] boolValue];
            return YES;
        }
    }

    if (!liveContainerProfile[@"enabled"] || ![liveContainerProfile[@"enabled"] boolValue]) return NO;
    if (moduleKey && liveContainerProfile[moduleKey] != nil) return [liveContainerProfile[moduleKey] boolValue];
    return YES;
}

static void showStartupBanner() {
    if (bannerShownThisSession) return;
    bannerShownThisSession = YES;

    NSMutableDictionary *prof = getContainerProfile();
    if (!prof) return;
    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
    if (!keyWin) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { keyWin = w; break; }
        }
    }
    if (!keyWin) return;

    BOOL active = isModuleActive(nil);
    NSString *cName = prof[@"containerName"] ?: @"Default";
    BOOL isCell = [prof[@"CarrierMode"] isEqualToString:@"CELLULAR"];
    NSString *netMode = isCell
        ? [NSString stringWithFormat:@"📱 4G (%@)", prof[@"CarrierName"] ?: @"LTE"]
        : [NSString stringWithFormat:@"🛜 Wi-Fi (%@)", prof[@"localIP"] ?: @"LAN"];
    int batPct = (int)([prof[@"batteryLevel"] floatValue] * 100.0f);

    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(16, 44, keyWin.bounds.size.width - 32, 42)];
    toast.layer.cornerRadius = 10.0;
    toast.clipsToBounds = YES;
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont boldSystemFontOfSize:11.5];
    toast.numberOfLines = 2;
    toast.textColor = [UIColor whiteColor];

    if (active) {
        toast.backgroundColor = [UIColor colorWithRed:0.06 green:0.48 blue:0.24 alpha:0.92];
        toast.text = [NSString stringWithFormat:@"🛡️ %@ • %@ • Bat: %d%%\n%@ • %@",
                      cName, netMode, batPct, prof[@"lastSyncedIP"] ?: @"IP Aislada", prof[@"timeZone"] ?: @""];
    } else {
        toast.backgroundColor = [UIColor colorWithRed:0.45 green:0.45 blue:0.48 alpha:0.90];
        toast.text = [NSString stringWithFormat:@"⚪ %@ • Escudo en Pausa Manual (Datos Nativos)", cName];
    }
