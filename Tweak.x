#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CFNetwork/CFNetwork.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <AVFoundation/AVFoundation.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
#import <time.h>
#import <substrate.h>

#define GLOBAL_STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CRANE_PREFS_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_PREFS_VAR @"/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_MAIN_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define CRANE_MAIN_VAR @"/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define CURRENT_SCHEMA_VERSION 18

static NSString *origCraneIDFV = nil;
static NSMutableDictionary *liveContainerProfile = nil;
static NSTimeInterval sessionStartTimestamp = 0;
static BOOL bannerShownThisSession = NO;
static __thread BOOL isInitializingProfile = NO;

static int (*orig_dladdr)(const void *, Dl_info *) = NULL;
static const char *(*orig_dyld_get_image_name)(uint32_t image_index) = NULL;
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*orig_statfs)(const char *, struct statfs *) = NULL;
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
                    } else if ([kl containsString:@"id"] || [kl containsString:@"crane"] || [kl containsString:@"container"] || [kl containsString:@"uuid"]) {
                        if (![val hasPrefix:@"com."]) craneID = val;
                    }
                }
            }
        }
    }

    if (!craneID && origCraneIDFV && origCraneIDFV.length > 0) craneID = origCraneIDFV;
    if (!craneID) craneID = meta[@"MCMMetadataUUID"] ?: folderUUID;

    NSMutableArray *sources = [NSMutableArray array];
    for (NSString *domain in @[@"com.opa334.crane", @"com.opa334.craneprefs"]) {
        NSDictionary *ud = [[[NSUserDefaults alloc] initWithSuiteName:domain] dictionaryRepresentation];
        if ([ud count] > 0) [sources addObject:ud];
    }
    for (NSString *pPath in @[CRANE_MAIN_JB, CRANE_MAIN_VAR, CRANE_PREFS_JB, CRANE_PREFS_VAR]) {
        NSDictionary *cPrefs = [NSDictionary dictionaryWithContentsOfFile:pPath];
        if ([cPrefs count] > 0) [sources addObject:cPrefs];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sDir in @[@"/var/mobile/Library/Application Support/Crane", @"/var/jb/var/mobile/Library/Application Support/Crane"]) {
        if (![fm fileExistsAtPath:sDir]) continue;
        NSArray *subFiles = [fm subpathsOfDirectoryAtPath:sDir error:nil];
        for (NSString *sf in subFiles) {
            if ([sf hasSuffix:@".plist"]) {
                NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[sDir stringByAppendingPathComponent:sf]];
                if ([d isKindOfClass:[NSDictionary class]] && [d count] > 0) [sources addObject:d];
            }
        }
    }

    for (NSDictionary *src in sources) {
        if (!craneName && craneID) craneName = findCraneNameInNode(src, craneID);
        if (!craneName && origCraneIDFV) craneName = findCraneNameInNode(src, origCraneIDFV);
        if (!craneName) craneName = findCraneNameInNode(src, folderUUID);
    }

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
        @"craneID": (origCraneIDFV ?: craneID) ?: @"Default",
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
        NSDictionary *loadedGlobal = [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST];
        NSMutableDictionary *globalSt = loadedGlobal ? [loadedGlobal mutableCopy] : [NSMutableDictionary dictionary];
        NSMutableDictionary *byUUID = [globalSt[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
            ? [globalSt[@"containersByUUID"] mutableCopy]
            : [NSMutableDictionary dictionary];

        NSMutableDictionary *profile = nil;
        NSDictionary *diskLoaded = [NSDictionary dictionaryWithContentsOfFile:localPlist];
        NSDictionary *settingsEntry = [byUUID[keyUUID] isKindOfClass:[NSDictionary class]] ? byUUID[keyUUID] : nil;

        if (!settingsEntry) {
            for (NSString *existingKey in [byUUID allKeys]) {
                if ([existingKey caseInsensitiveCompare:keyUUID] == NSOrderedSame ||
                    [existingKey caseInsensitiveCompare:craneID] == NSOrderedSame) {
                    NSDictionary *cand = byUUID[existingKey];
                    if ([cand isKindOfClass:[NSDictionary class]] && [cand[@"bundleID"] isEqualToString:bundleID] && cand[@"idfv"]) {
                        settingsEntry = cand;
                        if (![existingKey isEqualToString:keyUUID]) {
                            [byUUID removeObjectForKey:existingKey];
                        }
                        break;
                    }
                }
            }
        }

        if (settingsEntry && settingsEntry[@"idfv"]) {
            profile = [settingsEntry mutableCopy];
        } else if ([diskLoaded isKindOfClass:[NSDictionary class]] && diskLoaded[@"idfv"]) {
            profile = [diskLoaded mutableCopy];
        }

        if (profile && settingsEntry) {
            for (NSString *k in @[@"enabled", @"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity", @"locationAnchored", @"timeZone", @"localeID", @"CarrierMode", @"CarrierName", @"CarrierMCC", @"CarrierMNC", @"CarrierISO", @"ispName", @"cityCountry", @"lastSyncedIP", @"localIP", @"ssid", @"bssid", @"bootSessionUUID", @"freeBytes", @"batteryLevel", @"audioVolume", @"brightness"]) {
                if (settingsEntry[k] != nil) profile[k] = settingsEntry[k];
            }
        }

        NSString *nativeCraneUUID = (origCraneIDFV && origCraneIDFV.length >= 32)
            ? [origCraneIDFV uppercaseString]
            : (([craneID containsString:@"-"] && craneID.length >= 32) ? [craneID uppercaseString] : [[NSUUID UUID] UUIDString]);

        if (!profile || !profile[@"idfv"]) {
            BOOL exclusive = globalSt[@"exclusiveMode"] ? [globalSt[@"exclusiveMode"] boolValue] : YES;
            BOOL hasActiveInApp = NO;
            for (NSString *k in byUUID) {
                NSDictionary *p = byUUID[k];
                if ([p isKindOfClass:[NSDictionary class]] && [p[@"bundleID"] isEqualToString:bundleID] && [p[@"enabled"] boolValue]) {
                    hasActiveInApp = YES;
                    break;
                }
            }
            BOOL enableByDefault = (settingsEntry && settingsEntry[@"enabled"] != nil)
                ? [settingsEntry[@"enabled"] boolValue]
                : (!exclusive || !hasActiveInApp);

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

            profile = [@{
                @"schemaVersion": @(CURRENT_SCHEMA_VERSION),
                @"containerUUID": keyUUID,
                @"craneIdentifier": nativeCraneUUID,
                @"containerName": craneName,
                @"bundleID": bundleID,
                @"path": homePath,
                @"enabled": @(enableByDefault),
                @"spoofIDs": @YES,
                @"spoofNetwork": @YES,
                @"spoofLocation": @YES,
                @"spoofHardware": @YES,
                @"spoofSecurity": @YES,
                @"locationAnchored": @NO,
                @"deviceModel": @"iPhone10,4",
                @"craneOriginalIDFV": nativeCraneUUID,
                @"idfv": nativeCraneUUID,
                @"shieldDeviceID": [[NSUUID UUID] UUIDString],
                @"bootSessionUUID": [[NSUUID UUID] UUIDString],
                @"cloudUUID": [[NSUUID UUID] UUIDString],
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
            profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
            profile[@"containerUUID"] = keyUUID;
            profile[@"craneIdentifier"] = nativeCraneUUID;
            profile[@"craneOriginalIDFV"] = nativeCraneUUID;
            profile[@"idfv"] = nativeCraneUUID;
            profile[@"bundleID"] = bundleID;
            profile[@"path"] = homePath;
            if (craneName && ![craneName isEqualToString:keyUUID]) {
                profile[@"containerName"] = craneName;
            }
        }

        if ([profile[@"spoofLocation"] boolValue] && profile[@"timeZone"]) {
            applyLowLevelCTimeZone(profile[@"timeZone"]);
        }

        [profile writeToFile:localPlist atomically:YES];
        byUUID[keyUUID] = profile;
        globalSt[@"containersByUUID"] = byUUID;

        NSMutableDictionary *activeMap = [globalSt[@"activeInCrane"] isKindOfClass:[NSDictionary class]]
            ? [globalSt[@"activeInCrane"] mutableCopy]
            : [NSMutableDictionary dictionary];
        activeMap[bundleID] = keyUUID;
        globalSt[@"activeInCrane"] = activeMap;
        [globalSt writeToFile:GLOBAL_STATE_PLIST atomically:YES];

        liveContainerProfile = profile;
        isInitializingProfile = NO;
    });
    return liveContainerProfile;
}

static BOOL isModuleActive(NSString *moduleKey) {
    if (isInitializingProfile || !liveContainerProfile) return NO;

    NSDictionary *state = getGlobalState();
    if (state[@"masterEnabled"] != nil && ![state[@"masterEnabled"] boolValue]) return NO;

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.burbn.instagram"] && state[@"enableIG"] != nil && ![state[@"enableIG"] boolValue]) return NO;
    if ([bundleID isEqualToString:@"com.reddit.Reddit"] && state[@"enableReddit"] != nil && ![state[@"enableReddit"] boolValue]) return NO;

    NSString *keyUUID = liveContainerProfile[@"containerUUID"];
    NSDictionary *byUUID = state[@"containersByUUID"];
    if (keyUUID && [byUUID isKindOfClass:[NSDictionary class]] && [byUUID[keyUUID] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *savedProf = byUUID[keyUUID];
        if (savedProf[@"enabled"] != nil && ![savedProf[@"enabled"] boolValue]) return NO;
        if (moduleKey && savedProf[moduleKey] != nil) return [savedProf[moduleKey] boolValue];
    }

    if (liveContainerProfile[@"enabled"] != nil && ![liveContainerProfile[@"enabled"] boolValue]) return NO;
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
        toast.backgroundColor = [UIColor colorWithRed:0.75 green:0.15 blue:0.15 alpha:0.92];
        toast.text = [NSString stringWithFormat:@"⚪ %@ • Escudo en Pausa (Datos Nativos)", cName];
    }

    [keyWin addSubview:toast];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.35 animations:^{ toast.alpha = 0.0; } completion:^(BOOL f) { [toast removeFromSuperview]; }];
    });
}

static BOOL isSuspiciousJailbreakPathC(const char *path) {
    if (!path) return NO;
    if (strstr(path, "igfarmshield") != NULL ||
        strstr(path, ".igshield_container") != NULL ||
        strstr(path, "Crane") != NULL ||
        strstr(path, "crane") != NULL) {
        return NO;
    }
    if (strncmp(path, "/var/jb", 7) == 0 ||
        strncmp(path, "/private/preboot", 16) == 0 ||
        strstr(path, "ellekit") != NULL ||
        strstr(path, "Choicy") != NULL ||
        strstr(path, "choicy") != NULL ||
        strstr(path, "Sileo") != NULL ||
        strstr(path, "sileo") != NULL ||
        strstr(path, "Filza") != NULL ||
        strstr(path, "palera1n") != NULL ||
        strstr(path, "MobileSubstrate") != NULL ||
        strstr(path, "substrate") != NULL) {
        return YES;
    }
    return NO;
}

static const char *custom_dyld_get_image_name(uint32_t image_index) {
    const char *name = orig_dyld_get_image_name(image_index);
    if (name && isModuleActive(@"spoofSecurity") && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (strstr(name, "IGFarmShield") != NULL || isSuspiciousJailbreakPathC(name)) {
            return "/System/Library/Frameworks/Foundation.framework/Foundation";
        }
    }
    return name;
}

static int custom_dladdr(const void *addr, Dl_info *info) {
    int ret = orig_dladdr(addr, info);
    if (ret != 0 && info && info->dli_fname && isModuleActive(@"spoofSecurity") && isCallerFromTargetApp(__builtin_return_address(0))) {
        if (strstr(info->dli_fname, "IGFarmShield") != NULL || isSuspiciousJailbreakPathC(info->dli_fname)) {
            info->dli_fname = "/System/Library/Frameworks/UIKitCore.framework/UIKitCore";
        }
    }
    return ret;
}

%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if (isModuleActive(@"spoofSecurity") && url && url.scheme) {
        NSString *s = url.scheme.lowercaseString;
        if ([@[@"sileo", @"zbra", @"filza", @"cydia", @"palera1n", @"santander"] containsObject:s]) {
            return NO;
        }
    }
    return %orig;
}
%end

%hook UIPasteboard
- (NSInteger)changeCount {
    if (!isModuleActive(@"spoofSecurity")) return %orig;
    NSDictionary *prof = getContainerProfile();
    return [prof[@"pasteboardCount"] integerValue];
}
%end

%hook NSTimeZone
+ (NSTimeZone *)systemTimeZone {
    if (!isModuleActive(@"spoofLocation")) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSString *tzName = prof[@"timeZone"];
    if (!tzName || [tzName hasPrefix:@"Sincronizando"] || [tzName hasPrefix:@"Sin "]) return %orig;
    return [NSTimeZone timeZoneWithName:tzName] ?: %orig;
}
+ (NSTimeZone *)localTimeZone {
    if (!isModuleActive(@"spoofLocation")) return %orig;
    return [self systemTimeZone];
}
+ (NSTimeZone *)defaultTimeZone {
    if (!isModuleActive(@"spoofLocation")) return %orig;
    return [self systemTimeZone];
}
%end

%hook NSLocale
+ (NSLocale *)currentLocale {
    if (!isModuleActive(@"spoofLocation")) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSString *locID = prof[@"localeID"];
    if (!locID) return %orig;
    return [NSLocale localeWithLocaleIdentifier:locID] ?: %orig;
}
+ (NSLocale *)autoupdatingCurrentLocale {
    if (!isModuleActive(@"spoofLocation")) return %orig;
    return [self currentLocale];
}
%end

%hook CTCarrier
- (NSString *)carrierName {
    if (!isModuleActive(@"spoofNetwork")) return %orig;
    NSDictionary *prof = getContainerProfile();
    if ([prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return prof[@"CarrierName"] ?: @"T-Mobile";
}
- (NSString *)mobileCountryCode {
    if (!isModuleActive(@"spoofNetwork")) return %orig;
    NSDictionary *prof = getContainerProfile();
    if ([prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return prof[@"CarrierMCC"] ?: @"310";
}
- (NSString *)mobileNetworkCode {
    if (!isModuleActive(@"spoofNetwork")) return %orig;
    NSDictionary *prof = getContainerProfile();
    if ([prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return prof[@"CarrierMNC"] ?: @"260";
}
- (NSString *)isoCountryCode {
    if (!isModuleActive(@"spoofNetwork")) return %orig;
    NSDictionary *prof = getContainerProfile();
    if ([prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return prof[@"CarrierISO"] ?: @"us";
}
- (BOOL)allowsVOIP { return YES; }
%end

%hook CTTelephonyNetworkInfo
- (NSString *)currentRadioAccessTechnology {
    if (!isModuleActive(@"spoofNetwork")) return %orig;
    NSDictionary *prof = getContainerProfile();
    if ([prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return CTRadioAccessTechnologyLTE;
}
- (NSDictionary<NSString *, NSString *> *)serviceCurrentRadioAccessTechnology {
    if (!isModuleActive(@"spoofNetwork")) return %orig;
    NSDictionary *prof = getContainerProfile();
    if ([prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return @{@"0000000100000001": CTRadioAccessTechnologyLTE};
}
%end

static CFDictionaryRef custom_CNCopyCurrentNetworkInfo(CFStringRef interfaceName) {
    if (!isModuleActive(@"spoofNetwork")) return orig_CNCopyCurrentNetworkInfo(interfaceName);
    NSDictionary *prof = getContainerProfile();
    if ([prof[@"CarrierMode"] isEqualToString:@"CELLULAR"]) {
        return NULL;
    }
    NSDictionary *fakeWifi = @{
        @"SSID": prof[@"ssid"] ?: @"HomeWiFi-5G",
        @"BSSID": prof[@"bssid"] ?: @"a4:83:e7:21:9a:10",
        @"SSIDDATA": [(prof[@"ssid"] ?: @"HomeWiFi-5G") dataUsingEncoding:NSUTF8StringEncoding]
    };
    return (__bridge_retained CFDictionaryRef)fakeWifi;
}

%hook UIDevice
- (NSString *)name {
    if (!isModuleActive(@"spoofHardware")) return %orig;
    return @"iPhone";
}
- (NSUUID *)identifierForVendor {
    NSUUID *origUUID = %orig;
    if (!origCraneIDFV && origUUID) {
        origCraneIDFV = [origUUID UUIDString];
    }
    if (origUUID) return origUUID;
    if (!isModuleActive(@"spoofIDs")) return origUUID;
    NSDictionary *prof = getContainerProfile();
    NSUUID *customUUID = [[NSUUID alloc] initWithUUIDString:prof[@"idfv"]];
    return customUUID ?: origUUID;
}
- (float)batteryLevel {
    if (!isModuleActive(@"spoofHardware")) return %orig;
    NSDictionary *prof = getContainerProfile();
    float baseBat = [prof[@"batteryLevel"] floatValue];
    NSTimeInterval elapsedMinutes = ([[NSDate date] timeIntervalSince1970] - sessionStartTimestamp) / 60.0;
    float drop = (float)((int)(elapsedMinutes / 12.0)) * 0.01f;
    return MAX(0.15f, baseBat - drop);
}
- (UIDeviceBatteryState)batteryState {
    if (!isModuleActive(@"spoofHardware")) return %orig;
    return UIDeviceBatteryStateUnplugged;
}
%end

%hook AVAudioSession
- (float)outputVolume {
    if (!isModuleActive(@"spoofHardware")) return %orig;
    NSDictionary *prof = getContainerProfile();
    return prof[@"audioVolume"] ? [prof[@"audioVolume"] floatValue] : 0.50f;
}
%end

static int custom_statfs(const char *path, struct statfs *buf) {
    int ret = orig_statfs(path, buf);
    if (ret == 0 && buf && isModuleActive(@"spoofHardware") && isCallerFromTargetApp(__builtin_return_address(0))) {
        NSDictionary *prof = getContainerProfile();
        if (prof[@"freeBytes"] && buf->f_bsize > 0) {
            unsigned long long baseFree = [prof[@"freeBytes"] unsignedLongLongValue];
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
- (id)ubiquityIdentityToken {
    if (isModuleActive(@"spoofIDs") || isModuleActive(@"spoofSecurity")) return nil;
    return %orig;
}
- (NSDictionary<NSFileAttributeKey, id> *)attributesOfFileSystemForPath:(NSString *)path error:(NSError * _Nullable *)error {
    NSDictionary *orig = %orig;
    if (!isModuleActive(@"spoofHardware") || !orig) return orig;
    NSMutableDictionary *modified = [orig mutableCopy];
    NSDictionary *prof = getContainerProfile();
    if (prof[@"freeBytes"]) {
        unsigned long long baseFree = [prof[@"freeBytes"] unsignedLongLongValue];
        unsigned long long driftBytes = (unsigned long long)(([[NSDate date] timeIntervalSince1970] - sessionStartTimestamp) * 4096.0);
        modified[NSFileSystemFreeSize] = @(baseFree - (driftBytes % (20 * 1024 * 1024)));
    }
    return modified;
}
- (BOOL)fileExistsAtPath:(NSString *)path {
    if (!path || !isModuleActive(@"spoofSecurity")) return %orig;
    if (isCallerFromTargetApp(__builtin_return_address(0)) && isSuspiciousJailbreakPathC([path UTF8String])) {
        return NO;
    }
    return %orig;
}
%end

%hook NSProcessInfo
- (NSDictionary<NSString *, NSString *> *)environment {
    NSDictionary *orig = %orig;
    if (!isModuleActive(@"spoofSecurity") || !orig || !isCallerFromTargetApp(__builtin_return_address(0))) return orig;
    NSMutableDictionary *cleanEnv = [orig mutableCopy];
    [cleanEnv removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    [cleanEnv removeObjectForKey:@"_MSSafeMode"];
    [cleanEnv removeObjectForKey:@"_SafeMode"];
    return cleanEnv;
}
%end

static int custom_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (ret == 0 && name && oldlenp && !isInitializingProfile) {
        if (strcmp(name, "kern.bootsessionuuid") == 0 && isModuleActive(@"spoofIDs") && isCallerFromTargetApp(__builtin_return_address(0))) {
            NSDictionary *prof = getContainerProfile();
            NSString *bootUUID = prof[@"bootSessionUUID"];
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
    if (!isModuleActive(@"spoofHardware")) return %orig;
    NSDictionary *prof = getContainerProfile();
    return [prof[@"brightness"] floatValue];
}
- (BOOL)isCaptured {
    if (!isModuleActive(@"spoofSecurity")) return %orig;
    return NO;
}
%end

%ctor {
    MSHookFunction((void *)dladdr, (void *)custom_dladdr, (void **)&orig_dladdr);
    MSHookFunction((void *)_dyld_get_image_name, (void *)custom_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
    MSHookFunction((void *)sysctlbyname, (void *)custom_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)statfs, (void *)custom_statfs, (void **)&orig_statfs);
    MSHookFunction((void *)CNCopyCurrentNetworkInfo, (void *)custom_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo);

    %init;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        origCraneIDFV = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
        getContainerProfile();
        showStartupBanner();
    });
}
