#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CFNetwork/CFNetwork.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <SystemConfiguration/SCNetworkReachability.h>
#import <AVFoundation/AVFoundation.h>
#import <StoreKit/StoreKit.h>
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
#define CURRENT_SCHEMA_VERSION 24

@interface ASAuthorizationController : NSObject
- (void)performRequests;
@end

@interface ASAuthorizationAppleIDProvider : NSObject
- (void)getCredentialStateForUserID:(NSString *)userID completion:(void (^)(NSInteger credentialState, NSError *error))completion;
@end

@interface CKContainer : NSObject
- (void)accountStatusWithCompletionHandler:(void (^)(NSInteger accountStatus, NSError *error))completionHandler;
@end

@interface ACAccountStore : NSObject
- (NSArray *)accounts;
- (NSArray *)accountsWithAccountType:(id)accountType;
- (void)accountTypeWithAccountTypeIdentifier:(NSString *)identifier completion:(void (^)(id accountType, NSError *error))completion;
@end

@interface SSAccountStore : NSObject
- (id)activeAccount;
- (id)activeLockerAccount;
@end

@interface SSAuthenticateRequest : NSObject
- (void)start;
- (void)startWithAuthenticateResponseBlock:(void (^)(id response, NSError *error))block;
@end

@interface AKAppleIDAuthenticationController : NSObject
- (void)authenticateWithContext:(id)context completion:(void (^)(NSDictionary *results, NSError *error))completion;
@end

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
static FILE *(*orig_fopen)(const char *, const char *) = NULL;
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

// Verifica si quien llama es el binario o un framework propio de la App (Instagram / Reddit)
// Esto protege a Crane, Security.framework, Keychain y CFNetwork de recibir datos falsos
static BOOL isCallerFromTargetApp(const void *retAddr) {
    if (!retAddr || !orig_dladdr) return NO;
    Dl_info info;
    if (orig_dladdr(retAddr, &info) != 0 && info.dli_fname) {
        if (strstr(info.dli_fname, "/Containers/Bundle/Application/") != NULL) {
            return YES;
        }
    }
    return NO;
}

static BOOL isCallerFromCrane(const void *retAddr) {
    if (!retAddr || !orig_dladdr) return NO;
    Dl_info info;
    if (orig_dladdr(retAddr, &info) != 0 && info.dli_fname) {
        if (strstr(info.dli_fname, "Crane") != NULL || strstr(info.dli_fname, "crane") != NULL) {
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

    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    if ([env[@"CRANE_CONTAINER_NAME"] length] > 0) craneName = env[@"CRANE_CONTAINER_NAME"];
    if ([env[@"CRANE_CONTAINER_ID"] length] > 0) craneID = env[@"CRANE_CONTAINER_ID"];
    if ([env[@"CRANE_IDENTIFIER"] length] > 0 && !craneID) craneID = env[@"CRANE_IDENTIFIER"];

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
            if (!craneName && origCraneIDFV) craneName = findCraneNameInNode(cPrefs, origCraneIDFV);
            if (!craneName) craneName = findCraneNameInNode(cPrefs, folderUUID);
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
            NSString *candName = cand[@"containerName"] ?: @"";

            if ([candPath isEqualToString:homePath] ||
                [existingKey caseInsensitiveCompare:keyUUID] == NSOrderedSame ||
                (candCraneID.length > 0 && ![candCraneID isEqualToString:@"Default"] && [candCraneID caseInsensitiveCompare:craneID] == NSOrderedSame) ||
                (craneName.length > 0 && ![craneName isEqualToString:@"Default"] && [candName caseInsensitiveCompare:craneName] == NSOrderedSame)) {
                settingsEntry = cand;
                matchedSettingsKey = existingKey;
                break;
            }
        }

        if (!settingsEntry) {
            for (NSString *existingKey in byUUID) {
                NSDictionary *cand = byUUID[existingKey];
                if (![cand isKindOfClass:[NSDictionary class]] || ![cand[@"bundleID"] isEqualToString:bundleID]) continue;
                NSString *candPath = cand[@"path"] ?: @"";
                NSString *candCraneID = cand[@"craneIdentifier"] ?: @"";
                NSString *candName = cand[@"containerName"] ?: @"";

                BOOL matchesActiveInCrane = (craneActiveIDForApp &&
                    ([existingKey caseInsensitiveCompare:craneActiveIDForApp] == NSOrderedSame ||
                     [candCraneID caseInsensitiveCompare:craneActiveIDForApp] == NSOrderedSame ||
                     [candName caseInsensitiveCompare:craneActiveIDForApp] == NSOrderedSame));

                if (matchesActiveInCrane || ([cand[@"enabled"] boolValue] && candPath.length == 0)) {
                    settingsEntry = cand;
                    matchedSettingsKey = existingKey;
                    break;
                }
            }
        }

        NSMutableDictionary *profile = nil;
        if (settingsEntry && settingsEntry[@"idfv"]) {
            profile = [settingsEntry mutableCopy];
        } else if ([diskLoaded isKindOfClass:[NSDictionary class]] && diskLoaded[@"idfv"]) {
            profile = [diskLoaded mutableCopy];
        }

        if (profile && settingsEntry) {
            for (NSString *k in @[@"enabled", @"containerName", @"craneIdentifier", @"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity", @"locationAnchored", @"timeZone", @"localeID", @"CarrierMode", @"CarrierName", @"CarrierMCC", @"CarrierMNC", @"CarrierISO", @"ispName", @"cityCountry", @"lastSyncedIP", @"localIP", @"ssid", @"bssid", @"idfv", @"bootSessionUUID", @"freeBytes", @"batteryLevel", @"audioVolume", @"brightness", @"uptimeOffset"]) {
                if (settingsEntry[k] != nil) profile[k] = settingsEntry[k];
            }
        }

        // Armonizar siempre el IDFV con el Container ID de Crane para que nunca exista discrepancia en el login de Reddit
        NSString *craneHarmonizedIDFV = nil;
        if (origCraneIDFV && origCraneIDFV.length >= 32) {
            craneHarmonizedIDFV = [origCraneIDFV uppercaseString];
        } else if ([craneID containsString:@"-"] && craneID.length >= 32) {
            craneHarmonizedIDFV = [craneID uppercaseString];
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

            BOOL manualEnabled = (settingsEntry && settingsEntry[@"enabled"] != nil) ? [settingsEntry[@"enabled"] boolValue] : NO;
            NSString *finalIDFV = craneHarmonizedIDFV ?: [[NSUUID UUID] UUIDString];

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
                @"craneOriginalIDFV": finalIDFV,
                @"idfv": finalIDFV,
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
            if (craneHarmonizedIDFV && ![profile[@"customRotatedIDFV"] boolValue]) {
                profile[@"idfv"] = craneHarmonizedIDFV;
                profile[@"craneOriginalIDFV"] = craneHarmonizedIDFV;
            }
            profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
            profile[@"bundleID"] = bundleID;
            profile[@"path"] = homePath;
        }

        [profile writeToFile:localPlist atomically:YES];

        if (matchedSettingsKey && byUUID[matchedSettingsKey]) {
            NSMutableDictionary *updatedEntry = [byUUID[matchedSettingsKey] mutableCopy];
            updatedEntry[@"path"] = homePath;
            if (craneHarmonizedIDFV && ![updatedEntry[@"customRotatedIDFV"] boolValue]) {
                updatedEntry[@"idfv"] = craneHarmonizedIDFV;
            }
            byUUID[matchedSettingsKey] = updatedEntry;
            globalSt[@"containersByUUID"] = byUUID;
            [globalSt writeToFile:GLOBAL_STATE_PLIST atomically:YES];
        }

        if ([profile[@"enabled"] boolValue] && [profile[@"spoofLocation"] boolValue] && profile[@"timeZone"]) {
            applyLowLevelCTimeZone(profile[@"timeZone"]);
        }

        liveContainerProfile = profile;
        isInitializingProfile = NO;
    });
    return liveContainerProfile;
}

static BOOL isModuleActive(NSString *moduleKey) {
    if (isInitializingProfile) return NO;
    if (!liveContainerProfile) {
        getContainerProfile();
        if (!liveContainerProfile) return NO;
    }

    NSDictionary *state = getGlobalState();
    if (!state[@"masterEnabled"] || ![state[@"masterEnabled"] boolValue]) return NO;

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.burbn.instagram"] && (!state[@"enableIG"] || ![state[@"enableIG"] boolValue])) return NO;
    if ([bundleID isEqualToString:@"com.reddit.Reddit"] && (!state[@"enableReddit"] || ![state[@"enableReddit"] boolValue])) return NO;

    NSString *homePath = NSHomeDirectory();
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
                if ([cand isKindOfClass:[NSDictionary class]] && [cand[@"bundleID"] isEqualToString:bundleID]) {
                    if ([cand[@"path"] isEqualToString:homePath] ||
                        (craneID && [cand[@"craneIdentifier"] caseInsensitiveCompare:craneID] == NSOrderedSame) ||
                        (cName && [cand[@"containerName"] caseInsensitiveCompare:cName] == NSOrderedSame)) {
                        savedProf = cand;
                        break;
                    }
                }
            }
        }
        if ([savedProf isKindOfClass:[NSDictionary class]]) {
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
        toast.text = [NSString stringWithFormat:@"⚪ %@ • En Pausa Manual (Datos Nativos)", cName];
    }

    [keyWin addSubview:toast];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.35 animations:^{ toast.alpha = 0.0; } completion:^(BOOL f) { [toast removeFromSuperview]; }];
    });
}

// ============================================================================
// ANTI-JAILBREAK EN C Y OBJECTIVE-C (SIN INTERFERIR CON FRAMEWORKS DE SISTEMA)
// ============================================================================
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
        strncmp(path, "/Applications/Sileo.app", 23) == 0 ||
        strncmp(path, "/Applications/Filza.app", 23) == 0 ||
        strstr(path, "ellekit") != NULL ||
        strstr(path, "Choicy") != NULL ||
        strstr(path, "choicy") != NULL ||
        strstr(path, "Sileo") != NULL ||
        strstr(path, "sileo") != NULL ||
        strstr(path, "Filza") != NULL ||
        strstr(path, "palera1n") != NULL ||
        strstr(path, "Dopamine") != NULL ||
        strstr(path, "MobileSubstrate") != NULL ||
        strstr(path, "substrate") != NULL ||
        strstr(path, "Substitute") != NULL ||
        strstr(path, "TweakInject") != NULL) {
        return YES;
    }
    return NO;
}

static int custom_access(const char *path, int amode) {
    if (path && isModuleActive(@"spoofSecurity") && !isCallerFromCrane(__builtin_return_address(0))) {
        if (isSuspiciousJailbreakPathC(path)) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_access(path, amode);
}

static int custom_stat(const char *path, struct stat *buf) {
    if (path && isModuleActive(@"spoofSecurity") && !isCallerFromCrane(__builtin_return_address(0))) {
        if (isSuspiciousJailbreakPathC(path)) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_stat(path, buf);
}

static int custom_lstat(const char *path, struct stat *buf) {
    if (path && isModuleActive(@"spoofSecurity") && !isCallerFromCrane(__builtin_return_address(0))) {
        if (isSuspiciousJailbreakPathC(path)) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_lstat(path, buf);
}

static FILE *custom_fopen(const char *path, const char *mode) {
    if (path && isModuleActive(@"spoofSecurity") && !isCallerFromCrane(__builtin_return_address(0))) {
        if (isSuspiciousJailbreakPathC(path)) {
            errno = ENOENT;
            return NULL;
        }
    }
    return orig_fopen(path, mode);
}

// Solo falsifica nombres de imagen dyld/dladdr cuando pregunta el binario de la App (no Security.framework)
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

// ============================================================================
// BLOQUEO TOTAL DE STOREKIT, APPLE ID Y DEMONIOS DE ICLOUD ("SIGN IN WITH APPLE ID")
// ============================================================================
%hook SKPaymentQueue
- (void)addTransactionObserver:(id)observer {
    // Evita que Reddit despierte al demonio itunesstored/storekitd pidiendo Apple ID al arrancar
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) {
        return;
    }
    %orig;
}
- (void)restoreCompletedTransactions {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) {
        return;
    }
    %orig;
}
%end

%hook SKReceiptRefreshRequest
- (void)start {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) {
        return;
    }
    %orig;
}
%end

%hook ASAuthorizationAppleIDProvider
- (void)getCredentialStateForUserID:(NSString *)userID completion:(void (^)(NSInteger credentialState, NSError *error))completion {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) {
        if (completion) completion(2, nil); // 2 = CredentialNotFound (sin abrir popup de Apple ID)
        return;
    }
    %orig;
}
%end

%hook ASAuthorizationController
- (void)performRequests {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) {
        return;
    }
    %orig;
}
%end

%hook CKContainer
- (void)accountStatusWithCompletionHandler:(void (^)(NSInteger accountStatus, NSError *error))completionHandler {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) {
        if (completionHandler) completionHandler(3, nil);
        return;
    }
    %orig;
}
%end

%hook ACAccountStore
- (NSArray *)accounts {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) return @[];
    return %orig;
}
- (NSArray *)accountsWithAccountType:(id)accountType {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) return @[];
    return %orig;
}
- (void)accountTypeWithAccountTypeIdentifier:(NSString *)identifier completion:(void (^)(id accountType, NSError *error))completion {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) {
        if (completion) completion(nil, nil);
        return;
    }
    %orig;
}
%end

%hook SSAccountStore
- (id)activeAccount {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) return nil;
    return %orig;
}
- (id)activeLockerAccount {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) return nil;
    return %orig;
}
%end

%hook SSAuthenticateRequest
- (void)start {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) return;
    %orig;
}
- (void)startWithAuthenticateResponseBlock:(void (^)(id response, NSError *error))block {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) {
        if (block) block(nil, nil);
        return;
    }
    %orig;
}
%end

%hook AKAppleIDAuthenticationController
- (void)authenticateWithContext:(id)context completion:(void (^)(NSDictionary *results, NSError *error))completion {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"AKAuthenticationError" code:-7003 userInfo:nil]);
        }
        return;
    }
    %orig;
}
%end

%hook UIViewController
- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if ([viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
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

%hook NSUbiquitousKeyValueStore
+ (id)defaultStore {
    if (isModuleActive(@"spoofSecurity") || isModuleActive(@"spoofIDs")) return nil;
    return %orig;
}
%end

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
+ (NSArray<NSString *> *)preferredLanguages {
    if (!isModuleActive(@"spoofLocation")) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSString *locID = prof[@"localeID"] ?: @"en_US";
    NSString *lang = [locID stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    return @[lang, @"en-US"];
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

static Boolean custom_SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    Boolean ok = orig_SCNetworkReachabilityGetFlags(target, flags);
    if (ok && flags && isModuleActive(@"spoofNetwork")) {
        NSDictionary *prof = getContainerProfile();
        *flags &= ~kSCNetworkReachabilityFlagsTransientConnection;
        if ([prof[@"CarrierMode"] isEqualToString:@"CELLULAR"]) {
            *flags |= kSCNetworkReachabilityFlagsIsWWAN;
        } else {
            *flags &= ~kSCNetworkReachabilityFlagsIsWWAN;
        }
    }
    return ok;
}

// Enmascara utun como lo0 (loopback normal) sin duplicar en0 ni alterar el enrutamiento de sockets de Reddit
static int custom_getifaddrs(struct ifaddrs **ifap) {
    int res = orig_getifaddrs(ifap);
    if (res != 0 || !ifap || !*ifap || !isModuleActive(@"spoofNetwork")) return res;

    struct ifaddrs *curr = *ifap;
    while (curr) {
        if (curr->ifa_name) {
            if (strncmp(curr->ifa_name, "utun", 4) == 0 ||
                strncmp(curr->ifa_name, "ppp", 3) == 0 ||
                strncmp(curr->ifa_name, "ipsec", 5) == 0 ||
                strncmp(curr->ifa_name, "tun", 3) == 0 ||
                strncmp(curr->ifa_name, "tap", 3) == 0) {
                strcpy(curr->ifa_name, "lo0");
                curr->ifa_flags &= ~IFF_POINTOPOINT;
            }
        }
        curr = curr->ifa_next;
    }
    return res;
}

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
    if (!isModuleActive(@"spoofIDs")) return origUUID;
    NSDictionary *prof = getContainerProfile();
    if (prof[@"idfv"]) {
        NSUUID *customUUID = [[NSUUID alloc] initWithUUIDString:prof[@"idfv"]];
        if (customUUID) return customUUID;
    }
    return origUUID;
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
- (NSURL *)URLForUbiquityContainerIdentifier:(NSString *)containerIdentifier {
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
    if (!isCallerFromCrane(__builtin_return_address(0)) && isSuspiciousJailbreakPathC([path UTF8String])) {
        return NO;
    }
    return %orig;
}
%end

%hook NSProcessInfo
- (NSTimeInterval)systemUptime {
    NSTimeInterval orig = %orig;
    if (!isModuleActive(@"spoofHardware")) return orig;
    NSDictionary *prof = getContainerProfile();
    return orig + [prof[@"uptimeOffset"] doubleValue];
}
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
    if (ret == 0 && name && oldlenp && !isInitializingProfile && isCallerFromTargetApp(__builtin_return_address(0))) {
        NSDictionary *prof = getContainerProfile();
        if (strcmp(name, "kern.boottime") == 0 && isModuleActive(@"spoofHardware") && oldp && *oldlenp >= sizeof(struct timeval)) {
            struct timeval *tv = (struct timeval *)oldp;
            tv->tv_sec -= [prof[@"uptimeOffset"] longValue];
        } else if (strcmp(name, "kern.bootsessionuuid") == 0 && isModuleActive(@"spoofIDs")) {
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
    // 1. Capturar el IDFV de Crane e inicializar el perfil ANTES de %init para que nunca cambie a mitad de arranque
    origCraneIDFV = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    getContainerProfile();

    // 2. Cargar StoreKit y AuthenticationServices antes de %init para que los hooks contra el popup de Apple ID siempre enganchen
    dlopen("/System/Library/Frameworks/StoreKit.framework/StoreKit", RTLD_NOW);
    dlopen("/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices", RTLD_NOW);

    MSHookFunction((void *)dladdr, (void *)custom_dladdr, (void **)&orig_dladdr);
    MSHookFunction((void *)_dyld_get_image_name, (void *)custom_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
    MSHookFunction((void *)access, (void *)custom_access, (void **)&orig_access);
    MSHookFunction((void *)stat, (void *)custom_stat, (void **)&orig_stat);
    MSHookFunction((void *)lstat, (void *)custom_lstat, (void **)&orig_lstat);
    MSHookFunction((void *)fopen, (void *)custom_fopen, (void **)&orig_fopen);
    MSHookFunction((void *)sysctlbyname, (void *)custom_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)statfs, (void *)custom_statfs, (void **)&orig_statfs);
    MSHookFunction((void *)getifaddrs, (void *)custom_getifaddrs, (void **)&orig_getifaddrs);
    MSHookFunction((void *)SCNetworkReachabilityGetFlags, (void *)custom_SCNetworkReachabilityGetFlags, (void **)&orig_SCNetworkReachabilityGetFlags);
    MSHookFunction((void *)CNCopyCurrentNetworkInfo, (void *)custom_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo);

    %init;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showStartupBanner();
    });
}
