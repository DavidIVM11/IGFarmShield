#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CFNetwork/CFNetwork.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <DeviceCheck/DeviceCheck.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <AVFoundation/AVFoundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>
#import <time.h>
#import <substrate.h>

#define GLOBAL_STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CRANE_PREFS_PLIST_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_PREFS_PLIST_VAR @"/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CHOICY_PLIST @"/var/jb/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define VPS_AUDIT_URL @"http://162.35.105.151:5001/iphone_audit"
#define CURRENT_SCHEMA_VERSION 6

static NSString *origCraneIDFV = nil;
static NSMutableDictionary *liveContainerProfile = nil;
static NSTimeInterval sessionStartTimestamp = 0;
static BOOL bannerShownThisSession = NO;

static NSDictionary *getGlobalState() {
    return [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST] ?: @{};
}

static uint64_t fnv1aHash(NSString *input) {
    uint64_t hash = 14695981039346656037ULL;
    const char *bytes = [input UTF8String];
    if (!bytes) return arc4random();
    while (*bytes) {
        hash ^= (uint8_t)(*bytes++);
        hash *= 1099511628211ULL;
    }
    return hash;
}

static void applyLowLevelCTimeZone(NSString *tzName) {
    if (!tzName || [tzName isEqualToString:@"REAL"] || tzName.length == 0) return;
    setenv("TZ", [tzName UTF8String], 1);
    tzset();
}

static NSString *extractContainerUUID(NSString *homePath) {
    NSRange r = [homePath rangeOfString:@"___Crane_Containers/"];
    if (r.location != NSNotFound) {
        return [homePath substringFromIndex:NSMaxRange(r)];
    }
    NSString *last = [homePath lastPathComponent];
    return (last && last.length > 0) ? last : @"Default_UUID";
}

static NSString *recursiveFindCraneName(id node, NSString *targetKey) {
    if (!node || !targetKey || targetKey.length == 0) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        for (id k in dict) {
            NSString *kStr = [k description];
            id val = dict[k];
            if ([kStr caseInsensitiveCompare:targetKey] == NSOrderedSame) {
                if ([val isKindOfClass:[NSString class]] && [val length] > 0) return val;
                if ([val isKindOfClass:[NSDictionary class]]) {
                    for (NSString *nk in @[@"name", @"displayName", @"label", @"title", @"containerName"]) {
                        if ([val[nk] isKindOfClass:[NSString class]] && [val[nk] length] > 0) return val[nk];
                    }
                }
            }
            if ([val isKindOfClass:[NSString class]] && [val caseInsensitiveCompare:targetKey] == NSOrderedSame) {
                for (NSString *nk in @[@"name", @"displayName", @"label", @"title", @"containerName"]) {
                    if ([dict[nk] isKindOfClass:[NSString class]] && [dict[nk] length] > 0 && ![dict[nk] isEqualToString:targetKey]) {
                        return dict[nk];
                    }
                }
            }
            if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                NSString *found = recursiveFindCraneName(val, targetKey);
                if (found) return found;
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) {
            NSString *found = recursiveFindCraneName(item, targetKey);
            if (found) return found;
        }
    }
    return nil;
}

static NSString *detectCraneHumanName(NSString *homePath, NSString *containerUUID, NSString *bundleID) {
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    for (NSString *ek in @[@"CRANE_CONTAINER_NAME", @"CRANE_CONTAINER_DISPLAY_NAME"]) {
        if ([env[ek] isKindOfClass:[NSString class]] && [env[ek] length] > 0) return env[ek];
    }

    NSString *metaPath = [homePath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
    NSString *craneInternalID = nil;

    if ([meta isKindOfClass:[NSDictionary class]]) {
        for (NSString *rk in @[@"com.opa334.crane.container.name", @"craneContainerName"]) {
            if ([meta[rk] isKindOfClass:[NSString class]] && [meta[rk] length] > 0) return meta[rk];
        }
        for (NSString *ik in @[@"com.opa334.crane.container.identifier", @"com.opa334.crane.container.id"]) {
            if ([meta[ik] isKindOfClass:[NSString class]] && [meta[ik] length] > 0) craneInternalID = meta[ik];
        }
        NSDictionary *userInfo = meta[@"MCMMetadataUserInfo"];
        if ([userInfo isKindOfClass:[NSDictionary class]]) {
            for (NSString *k in userInfo) {
                NSString *kl = [k lowercaseString];
                if ([kl containsString:@"name"] && [userInfo[k] isKindOfClass:[NSString class]] && [userInfo[k] length] > 0) {
                    return userInfo[k];
                }
                if ([userInfo[k] isKindOfClass:[NSString class]] && [userInfo[k] length] > 0) {
                    craneInternalID = userInfo[k];
                }
            }
        }
    }

    if (!craneInternalID && [env[@"CRANE_CONTAINER_ID"] length] > 0) {
        craneInternalID = env[@"CRANE_CONTAINER_ID"];
    }

    // Consultar NSUserDefaults en memoria (cfprefsd) + archivos de Crane en disco
    NSMutableArray *sources = [NSMutableArray array];
    NSDictionary *ud1 = [[[NSUserDefaults alloc] initWithSuiteName:@"com.opa334.craneprefs"] dictionaryRepresentation];
    if (ud1) [sources addObject:ud1];
    NSDictionary *ud2 = [[[NSUserDefaults alloc] initWithSuiteName:@"com.opa334.crane"] dictionaryRepresentation];
    if (ud2) [sources addObject:ud2];
    for (NSString *pPath in @[CRANE_PREFS_PLIST_JB, CRANE_PREFS_PLIST_VAR]) {
        NSDictionary *cPrefs = [NSDictionary dictionaryWithContentsOfFile:pPath];
        if (cPrefs) [sources addObject:cPrefs];
    }

    for (NSDictionary *src in sources) {
        if (craneInternalID) {
            NSString *n = recursiveFindCraneName(src, craneInternalID);
            if (n) return n;
        }
        NSString *n2 = recursiveFindCraneName(src, containerUUID);
        if (n2) return n2;
    }

    if (craneInternalID && ![craneInternalID isEqualToString:containerUUID]) {
        if ([craneInternalID caseInsensitiveCompare:@"default"] == NSOrderedSame) return @"Default";
        return craneInternalID;
    }

    if (meta && (!meta[@"MCMMetadataUserInfo"] || [meta[@"MCMMetadataUserInfo"] count] == 0)) {
        return @"Default";
    }

    NSString *shortID = (containerUUID.length > 6) ? [containerUUID substringToIndex:6] : containerUUID;
    return [NSString stringWithFormat:@"Crane-%@", shortID];
}

static NSMutableDictionary *getContainerProfile() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sessionStartTimestamp = [[NSDate date] timeIntervalSince1970];
        NSString *homePath = NSHomeDirectory();
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.burbn.instagram";
        NSString *containerUUID = extractContainerUUID(homePath);
        NSString *craneHumanName = detectCraneHumanName(homePath, containerUUID, bundleID);
        NSString *localPlist = [homePath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];

        NSDictionary *loadedGlobal = [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST];
        NSMutableDictionary *globalSt = loadedGlobal ? [loadedGlobal mutableCopy] : [NSMutableDictionary dictionary];
        NSMutableDictionary *byUUID = [globalSt[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
            ? [globalSt[@"containersByUUID"] mutableCopy]
            : [NSMutableDictionary dictionary];

        NSMutableDictionary *profile = nil;
        NSDictionary *diskLoaded = [NSDictionary dictionaryWithContentsOfFile:localPlist];

        // Exigir versión 6 y coincidencia exacta de containerUUID para destruir cualquier plist clonado viejo
        if ([diskLoaded isKindOfClass:[NSDictionary class]] &&
            [diskLoaded[@"schemaVersion"] intValue] == CURRENT_SCHEMA_VERSION &&
            [diskLoaded[@"containerUUID"] isEqualToString:containerUUID] &&
            diskLoaded[@"idfv"]) {
            profile = [diskLoaded mutableCopy];
        } else if ([byUUID[containerUUID] isKindOfClass:[NSDictionary class]] &&
                   [byUUID[containerUUID][@"schemaVersion"] intValue] == CURRENT_SCHEMA_VERSION &&
                   [byUUID[containerUUID][@"containerUUID"] isEqualToString:containerUUID] &&
                   byUUID[containerUUID][@"idfv"]) {
            profile = [byUUID[containerUUID] mutableCopy];
        }

        // Sincronizar interruptores o cambios hechos desde Configuración
        if (profile && [byUUID[containerUUID] isKindOfClass:[NSDictionary class]]) {
            NSDictionary *stCopy = byUUID[containerUUID];
            for (NSString *k in @[@"enabled", @"customAlias", @"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity", @"CarrierMode", @"CarrierName", @"CarrierMCC", @"CarrierMNC", @"CarrierISO", @"timeZone", @"localeID"]) {
                if (stCopy[k] != nil) profile[k] = stCopy[k];
            }
        }

        if (!profile || !profile[@"idfv"]) {
            // Semilla determinista basada en el UUID físico de la carpeta + entropía criptográfica
            uint64_t seed = fnv1aHash(containerUUID) ^ (((uint64_t)arc4random() << 32) | arc4random());
            NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59", @"f0:9f:c2", @"04:d6:aa"];
            NSArray *ssidPrefixes = @[@"HomeWiFi", @"ATT-Fiber", @"Xfinity-WiFi", @"SpectrumSetup", @"NETGEAR", @"TP-Link", @"Verizon-5G"];
            NSArray *subnets = @[@"192.168.1", @"192.168.0", @"10.0.0", @"192.168.50", @"172.16.0", @"192.168.86"];
            NSArray *osBuilds = @[@"20G75", @"20G81", @"20H19", @"20H30", @"20F66", @"20E252"];

            NSString *oui = ouis[seed % ouis.count];
            NSString *ssidPref = ssidPrefixes[(seed >> 3) % ssidPrefixes.count];
            NSString *subnet = subnets[(seed >> 5) % subnets.count];
            NSString *osBuild = osBuilds[(seed >> 7) % osBuilds.count];

            NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x",
                               oui, (unsigned int)((seed >> 8) & 0xFF), (unsigned int)((seed >> 16) & 0xFF), (unsigned int)((seed >> 24) & 0xFF)];
            NSString *ssid = [NSString stringWithFormat:@"%@-%02X-5G", ssidPref, (unsigned int)(seed & 0xFF)];
            NSString *localIP = [NSString stringWithFormat:@"%@.%d", subnet, 15 + (int)(seed % 220)];

            unsigned long long baseFreeMB = 14800ULL + (seed % 31500ULL);
            unsigned long long freeBytes = (baseFreeMB * 1024ULL * 1024ULL) + ((seed >> 12) % 1048576ULL);

            profile = [@{
                @"schemaVersion": @(CURRENT_SCHEMA_VERSION),
                @"containerUUID": containerUUID,
                @"containerName": craneHumanName,
                @"customAlias": craneHumanName,
                @"bundleID": bundleID,
                @"path": homePath,
                @"enabled": @YES,
                @"spoofIDs": @YES,
                @"spoofNetwork": @YES,
                @"spoofLocation": @YES,
                @"spoofHardware": @YES,
                @"spoofSecurity": @YES,
                @"deviceModel": @"iPhone10,4",
                @"osBuild": osBuild,
                @"deviceName": [NSString stringWithFormat:@"iPhone-%02X", (unsigned int)(seed & 0xFF)],
                @"craneOriginalIDFV": origCraneIDFV ?: @"Capturando...",
                @"idfv": [[NSUUID UUID] UUIDString],
                @"shieldDeviceID": [[NSUUID UUID] UUIDString],
                @"bootSessionUUID": [[NSUUID UUID] UUIDString],
                @"cloudUUID": [[NSUUID UUID] UUIDString],
                @"bssid": bssid,
                @"ssid": ssid,
                @"localIP": localIP,
                @"freeBytes": @(freeBytes),
                @"uptimeOffset": @(1800 + (NSUInteger)(seed % 82000)),
                @"batteryLevel": @(0.35f + ((seed % 58) / 100.0f)),
                @"brightness": @(0.30f + (((seed >> 4) % 60) / 100.0f)),
                @"audioVolume": @(0.20f + (((seed >> 6) % 70) / 100.0f)),
                @"pasteboardCount": @(5 + (seed % 90)),
                @"timeZone": globalSt[@"defaultTimeZone"] ?: @"America/New_York",
                @"localeID": globalSt[@"defaultLocale"] ?: @"en_US",
                @"CarrierMode": globalSt[@"defaultCarrierMode"] ?: @"CELLULAR",
                @"CarrierName": globalSt[@"defaultCarrierName"] ?: @"T-Mobile",
                @"CarrierMCC": globalSt[@"defaultCarrierMCC"] ?: @"310",
                @"CarrierMNC": globalSt[@"defaultCarrierMNC"] ?: @"260",
                @"CarrierISO": globalSt[@"defaultCarrierISO"] ?: @"us"
            } mutableCopy];
        } else {
            profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
            profile[@"containerUUID"] = containerUUID;
            profile[@"bundleID"] = bundleID;
            profile[@"path"] = homePath;
            profile[@"deviceModel"] = @"iPhone10,4";
            if (!profile[@"osBuild"]) profile[@"osBuild"] = @"20G81";
            if (craneHumanName && ![craneHumanName hasPrefix:@"Crane-"] && ![craneHumanName isEqualToString:@"Default"]) {
                profile[@"containerName"] = craneHumanName;
                if ([profile[@"customAlias"] isEqualToString:@"Default"] || [profile[@"customAlias"] hasPrefix:@"Crane-"]) {
                    profile[@"customAlias"] = craneHumanName;
                }
            }
        }

        if ([profile[@"spoofLocation"] boolValue]) {
            applyLowLevelCTimeZone(profile[@"timeZone"]);
        }

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        profile[@"lastInjectedTime"] = [df stringFromDate:[NSDate date]];
        profile[@"lastOpened"] = @(sessionStartTimestamp);

        [profile writeToFile:localPlist atomically:YES];

        byUUID[containerUUID] = profile;
        globalSt[@"containersByUUID"] = byUUID;

        NSMutableDictionary *activeMap = [globalSt[@"activeInCrane"] isKindOfClass:[NSDictionary class]]
            ? [globalSt[@"activeInCrane"] mutableCopy]
            : [NSMutableDictionary dictionary];
        activeMap[bundleID] = containerUUID;
        globalSt[@"activeInCrane"] = activeMap;
        [globalSt writeToFile:GLOBAL_STATE_PLIST atomically:YES];

        liveContainerProfile = profile;
    });
    return liveContainerProfile;
}

static BOOL isModuleActive(NSString *moduleKey) {
    NSDictionary *state = getGlobalState();
    if (state[@"masterEnabled"] != nil && ![state[@"masterEnabled"] boolValue]) return NO;

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.burbn.instagram"] && state[@"enableIG"] != nil && ![state[@"enableIG"] boolValue]) return NO;
    if ([bundleID isEqualToString:@"com.reddit.Reddit"] && state[@"enableReddit"] != nil && ![state[@"enableReddit"] boolValue]) return NO;

    NSDictionary *prof = getContainerProfile();
    if (prof[@"enabled"] != nil && ![prof[@"enabled"] boolValue]) {
        return NO;
    }
    if (moduleKey && prof[moduleKey] != nil) return [prof[moduleKey] boolValue];
    return YES;
}

// ============================================================================
// BANNER EN VIVO AL ABRIR LA APP + TRANSPARENCIA REAL DE RED CADA 15 MINUTOS
// ============================================================================
static void verifyAndShowLiveInjectionBanner() {
    if (bannerShownThisSession) return;
    bannerShownThisSession = YES;

    NSMutableDictionary *prof = getContainerProfile();
    NSString *localPlist = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/.igshield_container.plist"];

    NSString *liveIDFV = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"N/A";
    NSString *liveTZ = [[NSTimeZone systemTimeZone] name] ?: @"N/A";
    float liveBat = [[UIDevice currentDevice] batteryLevel];

    prof[@"verifiedLiveIDFV"] = liveIDFV;
    prof[@"verifiedLiveTZ"] = liveTZ;
    prof[@"verifiedLiveBat"] = @((int)(liveBat * 100.0f));
    [prof writeToFile:localPlist atomically:YES];

    NSDictionary *loadedGlobal = [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST];
    if (loadedGlobal && prof[@"containerUUID"]) {
        NSMutableDictionary *gSt = [loadedGlobal mutableCopy];
        NSMutableDictionary *byUUID = [gSt[@"containersByUUID"] isKindOfClass:[NSDictionary class]] ? [gSt[@"containersByUUID"] mutableCopy] : [NSMutableDictionary dictionary];
        byUUID[prof[@"containerUUID"]] = prof;
        gSt[@"containersByUUID"] = byUUID;
        [gSt writeToFile:GLOBAL_STATE_PLIST atomically:YES];
    }

    BOOL contEnabled = (prof[@"enabled"] == nil) ? YES : [prof[@"enabled"] boolValue];
    BOOL masterOn = (!loadedGlobal || loadedGlobal[@"masterEnabled"] == nil) ? YES : [loadedGlobal[@"masterEnabled"] boolValue];

    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
    if (!keyWin) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { keyWin = w; break; }
        }
    }
    if (!keyWin) return;

    NSString *alias = prof[@"customAlias"] ?: (prof[@"containerName"] ?: @"Contenedor");
    NSString *shortID = (liveIDFV.length > 8) ? [liveIDFV substringToIndex:8] : liveIDFV;
    NSString *netTxt = [prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"] ? @"Wi-Fi" : (prof[@"CarrierName"] ?: @"T-Mobile");

    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(16, 44, keyWin.bounds.size.width - 32, 42)];
    toast.layer.cornerRadius = 12;
    toast.layer.masksToBounds = YES;
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont boldSystemFontOfSize:12.0];
    toast.numberOfLines = 2;

    if (masterOn && contEnabled) {
        toast.backgroundColor = [[UIColor colorWithRed:0.06 green:0.48 blue:0.24 alpha:0.94] colorWithAlphaComponent:0.94];
        toast.textColor = [UIColor whiteColor];
        toast.text = [NSString stringWithFormat:@"🛡️ IGFarmShield Activo: %@\nIDFV: %@... • %@ • %@", alias, shortID, netTxt, liveTZ];
    } else {
        toast.backgroundColor = [[UIColor colorWithRed:0.75 green:0.15 blue:0.15 alpha:0.94] colorWithAlphaComponent:0.94];
        toast.textColor = [UIColor whiteColor];
        toast.text = [NSString stringWithFormat:@"⚠️ IGFarmShield DESACTIVADO en %@\nUsando datos sin protección en este contenedor", alias];
    }

    [keyWin addSubview:toast];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.4 animations:^{
            toast.alpha = 0.0;
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

// Auto-auditoría transparente cada 15 minutos: refleja fielmente la IP, Zona Horaria e ISP actual
static void runPeriodicContainerNetworkAudit() {
    if (!isModuleActive(@"spoofNetwork")) return;

    NSURL *ipUrl = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,countryCode,city,timezone,isp,query"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 6.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:ipUrl completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) return;
        NSDictionary *ipJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![ipJson isKindOfClass:[NSDictionary class]] || ![ipJson[@"status"] isEqualToString:@"success"]) return;

        NSString *ip = ipJson[@"query"] ?: @"";
        NSString *ispRaw = ipJson[@"isp"] ?: @"";
        NSString *ispUp = [ispRaw uppercaseString];
        NSString *cc = [ipJson[@"countryCode"] lowercaseString] ?: @"us";
        NSString *tz = ipJson[@"timezone"] ?: @"America/New_York";

        NSMutableDictionary *prof = getContainerProfile();
        NSString *localPlist = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/.igshield_container.plist"];

        prof[@"lastSyncedIP"] = ip;
        prof[@"timeZone"] = tz;
        prof[@"localeID"] = [NSString stringWithFormat:@"en_%@", [cc uppercaseString]];
        if (isModuleActive(@"spoofLocation")) {
            applyLowLevelCTimeZone(tz);
        }

        if ([ispUp containsString:@"T-MOBILE"] || [ispUp containsString:@"METRO"] || [ispUp containsString:@"MINT"]) {
            prof[@"CarrierMode"] = @"CELLULAR"; prof[@"CarrierName"] = @"T-Mobile";
            prof[@"CarrierMCC"] = @"310"; prof[@"CarrierMNC"] = @"260"; prof[@"CarrierISO"] = @"us";
        } else if ([ispUp containsString:@"AT&T"] || [ispUp containsString:@"CRICKET"]) {
            prof[@"CarrierMode"] = @"CELLULAR"; prof[@"CarrierName"] = @"AT&T";
            prof[@"CarrierMCC"] = @"310"; prof[@"CarrierMNC"] = @"410"; prof[@"CarrierISO"] = @"us";
        } else if ([ispUp containsString:@"VERIZON"] || [ispUp containsString:@"VISIBLE"]) {
            prof[@"CarrierMode"] = @"CELLULAR"; prof[@"CarrierName"] = @"Verizon";
            prof[@"CarrierMCC"] = @"311"; prof[@"CarrierMNC"] = @"480"; prof[@"CarrierISO"] = @"us";
        } else if ([ispUp containsString:@"VODAFONE"] && [cc isEqualToString:@"gb"]) {
            prof[@"CarrierMode"] = @"CELLULAR"; prof[@"CarrierName"] = @"Vodafone UK";
            prof[@"CarrierMCC"] = @"234"; prof[@"CarrierMNC"] = @"15"; prof[@"CarrierISO"] = @"gb";
        } else if ([ispUp containsString:@"MOVISTAR"] && [cc isEqualToString:@"es"]) {
            prof[@"CarrierMode"] = @"CELLULAR"; prof[@"CarrierName"] = @"Movistar";
            prof[@"CarrierMCC"] = @"214"; prof[@"CarrierMNC"] = @"07"; prof[@"CarrierISO"] = @"es";
        } else {
            prof[@"CarrierMode"] = @"WIFI_ONLY"; prof[@"CarrierName"] = @"Wi-Fi";
            prof[@"CarrierMCC"] = @""; prof[@"CarrierMNC"] = @""; prof[@"CarrierISO"] = cc;
        }

        [prof writeToFile:localPlist atomically:YES];

        NSDictionary *loadedGlobal = [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST];
        if (loadedGlobal && prof[@"containerUUID"]) {
            NSMutableDictionary *gSt = [loadedGlobal mutableCopy];
            NSMutableDictionary *byUUID = [gSt[@"containersByUUID"] isKindOfClass:[NSDictionary class]] ? [gSt[@"containersByUUID"] mutableCopy] : [NSMutableDictionary dictionary];
            byUUID[prof[@"containerUUID"]] = prof;
            gSt[@"containersByUUID"] = byUUID;
            [gSt writeToFile:GLOBAL_STATE_PLIST atomically:YES];
        }

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSString *plat = [bundleID isEqualToString:@"com.burbn.instagram"] ? @"INSTAGRAM" : @"REDDIT";
        NSString *contName = [(prof[@"customAlias"] ?: prof[@"containerName"]) stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"Default";
        NSString *ispEnc = [ispRaw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
        NSString *bssidEnc = [(prof[@"bssid"] ?: @"") stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";

        NSString *vpsUrlStr = [NSString stringWithFormat:@"%@?ip=%@&contenedor=%@&plataforma=%@&choicy=1&bssid=%@&isp=%@&cc=%@",
                               VPS_AUDIT_URL, ip, contName, plat, bssidEnc, ispEnc, cc];

        [[session dataTaskWithURL:[NSURL URLWithString:vpsUrlStr] completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
            if (!vData || vErr) return;
            NSDictionary *vpsJson = [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil];
            if (![vpsJson isKindOfClass:[NSDictionary class]]) return;
            NSString *status = vpsJson[@"status"] ?: @"LIMPIA";
            prof[@"lastAuditVerdict"] = [NSString stringWithFormat:@"%@ %@", vpsJson[@"icono"] ?: @"🟢", status];
            [prof writeToFile:localPlist atomically:YES];

            if ([status isEqualToString:@"BANEADA"] || [status isEqualToString:@"COOLDOWN"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
                    UIViewController *rootVC = keyWin.rootViewController;
                    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
                    if (rootVC) {
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ Alerta de Red (Auto-Audit 15m)"
                                                                                       message:vpsJson[@"mensaje_iphone"] ?: @"IP en conflicto detectada en Proxy Center."
                                                                                preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"Entendido" style:UIAlertActionStyleDestructive handler:nil]];
                        [rootVC presentViewController:alert animated:YES completion:nil];
                    }
                });
            }
        }] resume];
    }] resume];
}

// ============================================================================
// ESCUDO COMPLEMENTARIO A CHOICY (DYLD, DLADDR, STAT, ACCESS)
// ============================================================================
static BOOL isSuspiciousPathC(const char *path) {
    if (!path) return NO;
    if (strstr(path, "igfarmshield") != NULL || strstr(path, ".igshield_container") != NULL) {
        return NO;
    }
    if (strncmp(path, "/var/jb", 7) == 0 ||
        strncmp(path, "/private/preboot", 16) == 0 ||
        strstr(path, "ellekit") != NULL ||
        strstr(path, "Crane") != NULL ||
        strstr(path, "crane") != NULL ||
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

static const char *(*orig_dyld_get_image_name)(uint32_t image_index);
static const char *custom_dyld_get_image_name(uint32_t image_index) {
    const char *name = orig_dyld_get_image_name(image_index);
    if (name && isModuleActive(@"spoofSecurity")) {
        if (strstr(name, "IGFarmShield") != NULL || isSuspiciousPathC(name)) {
            return "/System/Library/Frameworks/Foundation.framework/Foundation";
        }
    }
    return name;
}

static int (*orig_dladdr)(const void *, Dl_info *);
static int custom_dladdr(const void *addr, Dl_info *info) {
    int ret = orig_dladdr(addr, info);
    if (ret != 0 && info && info->dli_fname && isModuleActive(@"spoofSecurity")) {
        if (strstr(info->dli_fname, "IGFarmShield") != NULL || isSuspiciousPathC(info->dli_fname)) {
            info->dli_fname = "/System/Library/Frameworks/UIKitCore.framework/UIKitCore";
        }
    }
    return ret;
}

static int (*orig_access)(const char *, int);
static int custom_access(const char *path, int amode) {
    if (path && isModuleActive(@"spoofSecurity") && isSuspiciousPathC(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_access(path, amode);
}

static int (*orig_stat)(const char *, struct stat *);
static int custom_stat(const char *path, struct stat *buf) {
    if (path && isModuleActive(@"spoofSecurity") && isSuspiciousPathC(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_stat(path, buf);
}

static int (*orig_lstat)(const char *, struct stat *);
static int custom_lstat(const char *path, struct stat *buf) {
    if (path && isModuleActive(@"spoofSecurity") && isSuspiciousPathC(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_lstat(path, buf);
}

%hook LAContext
- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError * __autoreleasing *)error {
    if (!isModuleActive(@"spoofSecurity")) return %orig;
    if (error) *error = nil;
    return YES;
}
%end

%hook UIApplication
- (BOOL)isProtectedDataAvailable {
    if (!isModuleActive(@"spoofSecurity")) return %orig;
    return YES;
}
- (void)registerForRemoteNotifications {
    if (isModuleActive(@"spoofSecurity")) return;
    %orig;
}
- (BOOL)isRegisteredForRemoteNotifications {
    if (isModuleActive(@"spoofSecurity")) return NO;
    return %orig;
}
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

%hook DCDevice
- (BOOL)isSupported {
    if (!isModuleActive(@"spoofSecurity")) return %orig;
    return NO;
}
%end

%hook UIPasteboard
- (NSInteger)changeCount {
    if (!isModuleActive(@"spoofSecurity")) return %orig;
    NSDictionary *prof = getContainerProfile();
    return [prof[@"pasteboardCount"] integerValue];
}
%end

// ============================================================================
// ZONA HORARIA, REGIÓN Y RED (TRANSPARENTES SEGÚN EL PERFIL ACTIVO)
// ============================================================================
%hook NSTimeZone
+ (NSTimeZone *)systemTimeZone {
    if (!isModuleActive(@"spoofLocation")) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSString *tzName = prof[@"timeZone"];
    if (!tzName || [tzName isEqualToString:@"REAL"]) return %orig;
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

static CFTimeZoneRef (*orig_CFTimeZoneCopySystem)(void);
static CFTimeZoneRef custom_CFTimeZoneCopySystem(void) {
    if (!isModuleActive(@"spoofLocation")) return orig_CFTimeZoneCopySystem();
    NSDictionary *prof = getContainerProfile();
    NSString *tzName = prof[@"timeZone"];
    if (tzName && ![tzName isEqualToString:@"REAL"]) {
        CFTimeZoneRef tz = CFTimeZoneCreateWithName(kCFAllocatorDefault, (__bridge CFStringRef)tzName, true);
        if (tz) return tz;
    }
    return orig_CFTimeZoneCopySystem();
}

static CFTimeZoneRef (*orig_CFTimeZoneCopyDefault)(void);
static CFTimeZoneRef custom_CFTimeZoneCopyDefault(void) {
    if (!isModuleActive(@"spoofLocation")) return orig_CFTimeZoneCopyDefault();
    return custom_CFTimeZoneCopySystem();
}

%hook NSLocale
+ (NSLocale *)currentLocale {
    if (!isModuleActive(@"spoofLocation")) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSString *locID = prof[@"localeID"];
    if (!locID || [locID isEqualToString:@"REAL"]) return %orig;
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
- (BOOL)allowsVOIP {
    return YES;
}
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

static CFDictionaryRef (*orig_CFNetworkCopySystemProxySettings)(void);
static CFDictionaryRef custom_CFNetworkCopySystemProxySettings(void) {
    if (!isModuleActive(@"spoofNetwork")) return orig_CFNetworkCopySystemProxySettings();
    return (__bridge_retained CFDictionaryRef)@{};
}

static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef);
static CFDictionaryRef custom_CNCopyCurrentNetworkInfo(CFStringRef interfaceName) {
    if (!isModuleActive(@"spoofNetwork")) return orig_CNCopyCurrentNetworkInfo(interfaceName);
    NSDictionary *prof = getContainerProfile();
    NSDictionary *fakeWifi = @{
        @"SSID": prof[@"ssid"] ?: @"HomeWiFi-5G",
        @"BSSID": prof[@"bssid"] ?: @"a4:83:e7:21:9a:10",
        @"SSIDDATA": [(prof[@"ssid"] ?: @"HomeWiFi-5G") dataUsingEncoding:NSUTF8StringEncoding]
    };
    return (__bridge_retained CFDictionaryRef)fakeWifi;
}

static int (*orig_getifaddrs)(struct ifaddrs **);
static int custom_getifaddrs(struct ifaddrs **ifap) {
    int res = orig_getifaddrs(ifap);
    if (!isModuleActive(@"spoofNetwork") || res != 0 || !ifap || !*ifap) return res;

    NSDictionary *prof = getContainerProfile();
    const char *spoofedIP = [prof[@"localIP"] ?: @"192.168.1.45" UTF8String];

    struct ifaddrs *curr = *ifap;
    while (curr) {
        if (curr->ifa_name) {
            if (strncmp(curr->ifa_name, "utun", 4) == 0 ||
                strncmp(curr->ifa_name, "ppp", 3) == 0 ||
                strncmp(curr->ifa_name, "ipsec", 5) == 0 ||
                strncmp(curr->ifa_name, "tun", 3) == 0 ||
                strncmp(curr->ifa_name, "tap", 3) == 0) {
                strcpy(curr->ifa_name, "en0");
                curr->ifa_flags &= ~IFF_POINTOPOINT;
            }
            if (strcmp(curr->ifa_name, "en0") == 0 && curr->ifa_addr && curr->ifa_addr->sa_family == AF_INET && spoofedIP) {
                struct sockaddr_in *addr = (struct sockaddr_in *)curr->ifa_addr;
                addr->sin_addr.s_addr = inet_addr(spoofedIP);
            }
        }
        curr = curr->ifa_next;
    }
    return res;
}

// ============================================================================
// HARDWARE IPHONE 8 INDEPENDIENTE POR CONTENEDOR (IDFV, STATFS, KERNEL)
// ============================================================================
%hook UIDevice
- (NSString *)name {
    if (!isModuleActive(@"spoofHardware")) return %orig;
    NSDictionary *prof = getContainerProfile();
    return prof[@"deviceName"] ?: @"iPhone";
}
- (NSUUID *)identifierForVendor {
    NSUUID *origUUID = %orig;
    if (!origCraneIDFV && origUUID) {
        origCraneIDFV = [origUUID UUIDString];
        if (liveContainerProfile) {
            liveContainerProfile[@"craneOriginalIDFV"] = origCraneIDFV;
            NSString *localPlist = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
            [liveContainerProfile writeToFile:localPlist atomically:YES];
        }
    }
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
    float drop = (float)((int)(elapsedMinutes / 15.0)) * 0.01f;
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

static int (*orig_statfs)(const char *, struct statfs *);
static int custom_statfs(const char *path, struct statfs *buf) {
    int ret = orig_statfs(path, buf);
    if (ret == 0 && buf && isModuleActive(@"spoofHardware")) {
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
    if (!isModuleActive(@"spoofIDs")) return %orig;
    NSDictionary *prof = getContainerProfile();
    return [prof[@"cloudUUID"] dataUsingEncoding:NSUTF8StringEncoding];
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
    if (isSuspiciousPathC([path UTF8String])) {
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
    if (!isModuleActive(@"spoofSecurity") || !orig) return orig;
    NSMutableDictionary *cleanEnv = [orig mutableCopy];
    [cleanEnv removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    [cleanEnv removeObjectForKey:@"_MSSafeMode"];
    for (NSString *key in [cleanEnv allKeys]) {
        if ([[key uppercaseString] containsString:@"CRANE"]) {
            [cleanEnv removeObjectForKey:key];
        }
    }
    return cleanEnv;
}
%end

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int custom_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (ret == 0 && name && oldlenp) {
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
        } else if (strcmp(name, "kern.osversion") == 0 && isModuleActive(@"spoofHardware")) {
            NSString *osBuild = prof[@"osBuild"] ?: @"20G81";
            const char *bStr = [osBuild UTF8String];
            size_t len = strlen(bStr) + 1;
            if (oldp && *oldlenp >= len) memcpy(oldp, bStr, len);
            *oldlenp = len;
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
    %init;
    getContainerProfile();
    MSHookFunction((void *)sysctlbyname, (void *)custom_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)statfs, (void *)custom_statfs, (void **)&orig_statfs);
    MSHookFunction((void *)CFTimeZoneCopySystem, (void *)custom_CFTimeZoneCopySystem, (void **)&orig_CFTimeZoneCopySystem);
    MSHookFunction((void *)CFTimeZoneCopyDefault, (void *)custom_CFTimeZoneCopyDefault, (void **)&orig_CFTimeZoneCopyDefault);
    MSHookFunction((void *)_dyld_get_image_name, (void *)custom_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
    MSHookFunction((void *)dladdr, (void *)custom_dladdr, (void **)&orig_dladdr);
    MSHookFunction((void *)access, (void *)custom_access, (void **)&orig_access);
    MSHookFunction((void *)stat, (void *)custom_stat, (void **)&orig_stat);
    MSHookFunction((void *)lstat, (void *)custom_lstat, (void **)&orig_lstat);
    MSHookFunction((void *)CFNetworkCopySystemProxySettings, (void *)custom_CFNetworkCopySystemProxySettings, (void **)&orig_CFNetworkCopySystemProxySettings);
    MSHookFunction((void *)CNCopyCurrentNetworkInfo, (void *)custom_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo);
    MSHookFunction((void *)getifaddrs, (void *)custom_getifaddrs, (void **)&orig_getifaddrs);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        verifyAndShowLiveInjectionBanner();
        runPeriodicContainerNetworkAudit();
        [NSTimer scheduledTimerWithTimeInterval:900.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
            runPeriodicContainerNetworkAudit();
        }];
    });
}
