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
#import <sys/sysctl.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <substrate.h>

#define GLOBAL_STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CHOICY_PLIST @"/var/jb/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define VPS_AUDIT_URL @"http://162.35.105.151:5001/iphone_audit"

static NSString *origCraneIDFV = nil;
static NSMutableDictionary *liveContainerProfile = nil;
static NSTimeInterval sessionStartTimestamp = 0;

static NSDictionary *getGlobalState() {
    return [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST] ?: @{};
}

static NSString *detectCraneContainerName(NSString *homePath) {
    NSString *metaPath = [homePath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
    if (meta[@"com.opa334.crane.container.name"]) {
        return meta[@"com.opa334.crane.container.name"];
    }
    NSRange r = [homePath rangeOfString:@"___Crane_Containers/"];
    if (r.location != NSNotFound) {
        return [homePath substringFromIndex:NSMaxRange(r)];
    }
    return [homePath lastPathComponent] ?: @"Default";
}

// Hash FNV-1a de 64 bits para garantizar distribución sin colisiones entre 40 contenedores
static uint64_t fnv1aHash(NSString *input) {
    uint64_t hash = 14695981039346656037ULL;
    const char *bytes = [input UTF8String];
    if (!bytes) return arc4random();
    while (*bytes) {
        hash ^= (uint8_t)(*bytes++);
        hash *= 1099511628211ULL;
    }
    return hash ^ ((uint64_t)arc4random() << 32) ^ arc4random();
}

static NSMutableDictionary *getContainerProfile() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sessionStartTimestamp = [[NSDate date] timeIntervalSince1970];
        NSString *homePath = NSHomeDirectory();
        NSString *profilePath = [homePath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        NSMutableDictionary *profile = [NSMutableDictionary dictionaryWithContentsOfFile:profilePath];
        NSString *craneName = detectCraneContainerName(homePath);

        if (!profile || !profile[@"idfv"]) {
            uint64_t seed = fnv1aHash([NSString stringWithFormat:@"%@_%@", homePath, [[NSUUID UUID] UUIDString]]);
            
            // Diversidad real de fabricantes Wi-Fi (Apple, Netgear, Cisco, TP-Link, Asus, Ubiquiti)
            NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59", @"f0:9f:c2", @"04:d6:aa"];
            NSArray *ssidPrefixes = @[@"HomeWiFi", @"ATT-Fiber", @"Xfinity-WiFi", @"SpectrumSetup", @"NETGEAR", @"TP-Link"];
            NSString *oui = ouis[seed % ouis.count];
            NSString *ssidPref = ssidPrefixes[(seed >> 3) % ssidPrefixes.count];

            uint8_t b3 = (seed >> 8) & 0xFF;
            uint8_t b4 = (seed >> 16) & 0xFF;
            uint8_t b5 = (seed >> 24) & 0xFF;
            NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x", oui, b3, b4, b5];
            NSString *ssid = [NSString stringWithFormat:@"%@-%02X-5G", ssidPref, (unsigned int)(seed & 0xFF)];

            // Subredes domésticas variadas para no coincidir jamás en la estructura LAN
            NSArray *subnets = @[@"192.168.1", @"192.168.0", @"10.0.0", @"192.168.50", @"172.16.0"];
            NSString *subnet = subnets[(seed >> 5) % subnets.count];
            int lastOctet = 15 + (int)(seed % 225);
            NSString *localIP = [NSString stringWithFormat:@"%@.%d", subnet, lastOctet];

            unsigned long long baseFreeMB = 14800ULL + (seed % 31500ULL);
            unsigned long long freeBytes = (baseFreeMB * 1024ULL * 1024ULL) + ((seed >> 12) % 1048576ULL);
            NSUInteger uptimeOffset = 1200 + (NSUInteger)(seed % 86400);
            float batteryLvl = 0.38f + ((seed % 56) / 100.0f);
            float brightnessLvl = 0.35f + (((seed >> 4) % 55) / 100.0f);
            float audioVol = 0.20f + (((seed >> 6) % 70) / 100.0f);

            NSDictionary *st = getGlobalState();
            profile = [@{
                @"enabled": @YES,
                @"spoofIDs": @YES,
                @"spoofNetwork": @YES,
                @"spoofLocation": @YES,
                @"spoofHardware": @YES,
                @"spoofSecurity": @YES,
                @"craneContainerID": craneName,
                @"craneOriginalIDFV": origCraneIDFV ?: @"Aislado por Crane",
                @"idfv": [[NSUUID UUID] UUIDString],
                @"shieldDeviceID": [[NSUUID UUID] UUIDString],
                @"bootSessionUUID": [[NSUUID UUID] UUIDString],
                @"cloudUUID": [[NSUUID UUID] UUIDString],
                @"bssid": bssid,
                @"ssid": ssid,
                @"localIP": localIP,
                @"freeBytes": @(freeBytes),
                @"uptimeOffset": @(uptimeOffset),
                @"batteryLevel": @(batteryLvl),
                @"brightness": @(brightnessLvl),
                @"audioVolume": @(audioVol),
                @"pasteboardCount": @(5 + (seed % 120)),
                @"timeZone": st[@"defaultTimeZone"] ?: @"America/New_York",
                @"localeID": st[@"defaultLocale"] ?: @"en_US",
                @"CarrierMode": st[@"CarrierMode"] ?: @"CELLULAR",
                @"CarrierName": st[@"CarrierName"] ?: @"T-Mobile",
                @"CarrierMCC": st[@"CarrierMCC"] ?: @"310",
                @"CarrierMNC": st[@"CarrierMNC"] ?: @"260",
                @"CarrierISO": st[@"CarrierISO"] ?: @"us"
            } mutableCopy];
        } else {
            if (!profile[@"shieldDeviceID"]) profile[@"shieldDeviceID"] = [[NSUUID UUID] UUIDString];
            if (!profile[@"craneContainerID"]) profile[@"craneContainerID"] = craneName;
        }

        [profile writeToFile:profilePath atomically:YES];

        // Registrar contenedor en el estado global
        NSMutableDictionary *globalSt = [NSMutableDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST] ?: [NSMutableDictionary dictionary];
        NSMutableDictionary *known = [globalSt[@"knownContainers"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        known[homePath] = @{
            @"bundleID": bundleID,
            @"craneName": craneName,
            @"lastOpened": @(sessionStartTimestamp)
        };
        globalSt[@"knownContainers"] = known;
        [globalSt writeToFile:GLOBAL_STATE_PLIST atomically:YES];

        liveContainerProfile = profile;
    });
    return liveContainerProfile;
}

static BOOL isModuleActive(NSString *moduleKey) {
    NSDictionary *state = getGlobalState();
    if (state[@"masterEnabled"] != nil && ![state[@"masterEnabled"] boolValue]) return NO;

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.burbn.instagram"]) {
        if (state[@"enableIG"] != nil && ![state[@"enableIG"] boolValue]) return NO;
    } else if ([bundleID isEqualToString:@"com.reddit.Reddit"]) {
        if (state[@"enableReddit"] != nil && ![state[@"enableReddit"] boolValue]) return NO;
    }

    NSDictionary *prof = getContainerProfile();
    if (prof[@"enabled"] != nil && ![prof[@"enabled"] boolValue]) return NO;
    if (moduleKey && prof[moduleKey] != nil) return [prof[moduleKey] boolValue];
    return YES;
}

// ============================================================================
// AUDITORÍA AUTOMÁTICA DE RED CADA 15 MINUTOS + AUTO-ADAPTACIÓN A LA IP REAL
// ============================================================================
static void runPeriodicContainerNetworkAudit() {
    if (!isModuleActive(@"spoofNetwork")) return;

    NSURL *ipUrl = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,countryCode,city,timezone,isp,query"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 6.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:ipUrl completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) return;
        NSDictionary *ipJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![ipJson[@"status"] isEqualToString:@"success"]) return;

        NSString *ip = ipJson[@"query"] ?: @"";
        NSString *ispRaw = ipJson[@"isp"] ?: @"";
        NSString *ispUp = [ispRaw uppercaseString];
        NSString *cc = [ipJson[@"countryCode"] lowercaseString] ?: @"us";
        NSString *tz = ipJson[@"timezone"] ?: @"America/New_York";

        NSMutableDictionary *prof = getContainerProfile();
        prof[@"lastSyncedIP"] = ip;
        prof[@"timeZone"] = tz;
        prof[@"localeID"] = [NSString stringWithFormat:@"en_%@", [cc uppercaseString]];

        // Adaptación automática transparente según el ISP real del proxy
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

        NSString *profilePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        [prof writeToFile:profilePath atomically:YES];

        // Consultar a tu VPS (Proxy Center) cada 15 min para chequear que la IP no esté quemada
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSString *plat = [bundleID isEqualToString:@"com.burbn.instagram"] ? @"INSTAGRAM" : @"REDDIT";
        NSString *contName = [prof[@"craneContainerID"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"Default";
        NSString *ispEnc = [ispRaw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
        NSString *bssidEnc = [prof[@"bssid"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
        BOOL choicyOK = ([[NSFileManager defaultManager] fileExistsAtPath:CHOICY_PLIST]);

        NSString *vpsUrlStr = [NSString stringWithFormat:@"%@?ip=%@&contenedor=%@&plataforma=%@&choicy=%d&bssid=%@&isp=%@&cc=%@",
                               VPS_AUDIT_URL, ip, contName, plat, choicyOK ? 1 : 0, bssidEnc, ispEnc, cc];

        [[session dataTaskWithURL:[NSURL URLWithString:vpsUrlStr] completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
            if (!vData || vErr) return;
            NSDictionary *vpsJson = [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil];
            NSString *status = vpsJson[@"status"] ?: @"LIMPIA";
            prof[@"lastAuditVerdict"] = [NSString stringWithFormat:@"%@ %@", vpsJson[@"icono"] ?: @"🟢", status];
            [prof writeToFile:profilePath atomically:YES];

            // Si en el chequeo de 15 min se detecta IP BANEADA o COOLDOWN, avisar en pantalla de inmediato
            if ([status isEqualToString:@"BANEADA"] || [status isEqualToString:@"COOLDOWN"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
                    UIViewController *rootVC = keyWin.rootViewController;
                    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
                    if (rootVC) {
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ Alerta de Red (Auto-Audit 15m)"
                                                                                       message:vpsJson[@"mensaje_iphone"]
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
// MÓDULO 1: ESCUDOS DE SEGURIDAD (HIDE CRANE, PASSCODE, DEVICECHECK, NO-PUSH)
// ============================================================================
static const char *(*orig_dyld_get_image_name)(uint32_t image_index);
static const char *custom_dyld_get_image_name(uint32_t image_index) {
    const char *name = orig_dyld_get_image_name(image_index);
    if (name && isModuleActive(@"spoofSecurity")) {
        if (strstr(name, "IGFarmShield") != NULL ||
            strstr(name, "Crane") != NULL ||
            strstr(name, "crane") != NULL ||
            strstr(name, "ellekit") != NULL ||
            strstr(name, "Substrate") != NULL ||
            strstr(name, "Choicy") != NULL) {
            return "/System/Library/Frameworks/Foundation.framework/Foundation";
        }
    }
    return name;
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
// MÓDULO 2: ZONA HORARIA E IDIOMA/REGIÓN POR CONTENEDOR
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

%hook NSLocale
+ (NSLocale *)currentLocale {
    if (!isModuleActive(@"spoofLocation")) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSString *locID = prof[@"localeID"];
    if (!locID || [locID isEqualToString:@"REAL"]) return %orig;
    return [NSLocale localeWithLocaleIdentifier:locID] ?: %orig;
}
%end

// ============================================================================
// MÓDULO 3: RED, PROXY, OPERADORA (CTCARRIER) Y OCULTACIÓN DE VPN POR CUENTA
// ============================================================================
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
    const char *spoofedIP = [prof[@"localIP"] UTF8String];

    struct ifaddrs *curr = *ifap;
    while (curr) {
        if (curr->ifa_name) {
            if (strncmp(curr->ifa_name, "utun", 4) == 0 ||
                strncmp(curr->ifa_name, "ppp", 3) == 0 ||
                strncmp(curr->ifa_name, "ipsec", 5) == 0 ||
                strncmp(curr->ifa_name, "tap", 3) == 0) {
                strcpy(curr->ifa_name, "en0");
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
// MÓDULO 4: HARDWARE REALISTA CON DERIVA VIVA (DISCO, BATERÍA, UPTIME, IDFV)
// ============================================================================
%hook UIDevice
- (NSString *)name {
    if (!isModuleActive(@"spoofHardware")) return %orig;
    return @"iPhone";
}
- (NSUUID *)identifierForVendor {
    NSUUID *origUUID = %orig;
    if (!origCraneIDFV && origUUID) {
        origCraneIDFV = [origUUID UUIDString];
        if (liveContainerProfile && (!liveContainerProfile[@"craneOriginalIDFV"] || [liveContainerProfile[@"craneOriginalIDFV"] isEqualToString:@"Aislado por Crane"])) {
            liveContainerProfile[@"craneOriginalIDFV"] = origCraneIDFV;
            NSString *profilePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
            [liveContainerProfile writeToFile:profilePath atomically:YES];
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
    // Baja 1% cada 15 minutos de sesión activa para simular consumo real de batería
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
    return prof[@"audioVolume"] ? [prof[@"audioVolume"] floatValue] : 0.55f;
}
%end

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
        // Fluctuación realista de caché en tiempo de uso (varía unos KB por minuto)
        unsigned long long driftBytes = (unsigned long long)(([[NSDate date] timeIntervalSince1970] - sessionStartTimestamp) * 4096.0);
        modified[NSFileSystemFreeSize] = @(baseFree - (driftBytes % (20 * 1024 * 1024)));
    }
    return modified;
}

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (!path || !isModuleActive(@"spoofSecurity")) return %orig;
    NSString *lower = [path lowercaseString];
    if ([lower hasPrefix:@"/var/jb"] ||
        [lower hasPrefix:@"/private/preboot"] ||
        [lower containsString:@"ellekit"] ||
        [lower containsString:@"crane"] ||
        [lower containsString:@"choicy"] ||
        [lower containsString:@"sileo"] ||
        [lower containsString:@"filza"] ||
        [lower containsString:@"palera1n"] ||
        [lower containsString:@".igshield_container"]) {
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
    if (ret == 0 && name && oldp && oldlenp) {
        NSDictionary *prof = getContainerProfile();
        if (strcmp(name, "kern.boottime") == 0 && isModuleActive(@"spoofHardware") && *oldlenp >= sizeof(struct timeval)) {
            struct timeval *tv = (struct timeval *)oldp;
            tv->tv_sec -= [prof[@"uptimeOffset"] longValue];
        } else if (strcmp(name, "kern.bootsessionuuid") == 0 && isModuleActive(@"spoofIDs")) {
            NSString *bootUUID = prof[@"bootSessionUUID"];
            if (bootUUID) {
                const char *uuidStr = [bootUUID UTF8String];
                size_t len = strlen(uuidStr) + 1;
                if (*oldlenp >= len) {
                    memcpy(oldp, uuidStr, len);
                }
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
    %init;
    getContainerProfile();
    MSHookFunction((void *)sysctlbyname, (void *)custom_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)_dyld_get_image_name, (void *)custom_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
    MSHookFunction((void *)CFNetworkCopySystemProxySettings, (void *)custom_CFNetworkCopySystemProxySettings, (void **)&orig_CFNetworkCopySystemProxySettings);
    MSHookFunction((void *)CNCopyCurrentNetworkInfo, (void *)custom_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo);
    MSHookFunction((void *)getifaddrs, (void *)custom_getifaddrs, (void **)&orig_getifaddrs);

    // Iniciar auto-auditoría al abrir la app y repetir automáticamente cada 15 minutos (900 segundos)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        runPeriodicContainerNetworkAudit();
        [NSTimer scheduledTimerWithTimeInterval:900.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
            runPeriodicContainerNetworkAudit();
        }];
    });
}
