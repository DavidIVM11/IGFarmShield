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

static NSDictionary *getGlobalState() {
    return [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST] ?: @{};
}

// Carga o inicializa el perfil individual alojado dentro del contenedor actual de Crane
static NSDictionary *getContainerProfile() {
    static NSDictionary *cachedProfile = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *homePath = NSHomeDirectory();
        NSString *profilePath = [homePath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        NSMutableDictionary *profile = [NSMutableDictionary dictionaryWithContentsOfFile:profilePath];

        if (!profile || !profile[@"idfv"]) {
            NSUInteger seed = [homePath hash] ^ (NSUInteger)[[NSDate date] timeIntervalSince1970];
            NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59"];
            NSString *oui = ouis[seed % ouis.count];
            uint8_t b3 = (seed >> 8) & 0xFF;
            uint8_t b4 = (seed >> 16) & 0xFF;
            uint8_t b5 = (seed >> 24) & 0xFF;
            NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x", oui, b3, b4, b5];
            NSString *ssid = [NSString stringWithFormat:@"HomeWiFi-%02X-5G", (unsigned int)(seed & 0xFF)];
            int lastOctet = 20 + (seed % 210);
            NSString *localIP = [NSString stringWithFormat:@"192.168.1.%d", lastOctet];

            unsigned long long baseFreeGB = 16500ULL + (seed % 28300ULL);
            unsigned long long freeBytes = baseFreeGB * 1024ULL * 1024ULL + (seed % 1048576ULL);
            NSUInteger uptimeOffset = 900 + (seed % 54000);
            float batteryLvl = 0.35f + ((seed % 58) / 100.0f);
            float brightnessLvl = 0.40f + (((seed >> 4) % 48) / 100.0f);
            float audioVol = 0.25f + (((seed >> 6) % 65) / 100.0f);

            NSDictionary *st = getGlobalState();
            profile = [@{
                @"enabled": @YES,
                @"spoofIDs": @YES,
                @"spoofNetwork": @YES,
                @"spoofLocation": @YES,
                @"spoofHardware": @YES,
                @"spoofSecurity": @YES,
                @"idfv": [[NSUUID UUID] UUIDString],
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
                @"pasteboardCount": @(10 + (seed % 90)),
                @"timeZone": st[@"defaultTimeZone"] ?: @"America/New_York",
                @"localeID": st[@"defaultLocale"] ?: @"en_US",
                @"CarrierMode": st[@"CarrierMode"] ?: @"CELLULAR",
                @"CarrierName": st[@"CarrierName"] ?: @"T-Mobile",
                @"CarrierMCC": st[@"CarrierMCC"] ?: @"310",
                @"CarrierMNC": st[@"CarrierMNC"] ?: @"260",
                @"CarrierISO": st[@"CarrierISO"] ?: @"us"
            } mutableCopy];

            [profile writeToFile:profilePath atomically:YES];
        }
        cachedProfile = [profile copy];
    });
    return cachedProfile;
}

// Verifica jerarquía: 1. Master Switch -> 2. App Switch -> 3. Container Switch -> 4. Módulo específico
static BOOL isModuleActive(NSString *moduleKey) {
    NSDictionary *state = getGlobalState();
    if (state[@"masterEnabled"] != nil && ![state[@"masterEnabled"] boolValue]) {
        return NO;
    }

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.burbn.instagram"]) {
        if (state[@"enableIG"] != nil && ![state[@"enableIG"] boolValue]) return NO;
    } else if ([bundleID isEqualToString:@"com.reddit.Reddit"]) {
        if (state[@"enableReddit"] != nil && ![state[@"enableReddit"] boolValue]) return NO;
    }

    NSDictionary *prof = getContainerProfile();
    if (prof[@"enabled"] != nil && ![prof[@"enabled"] boolValue]) {
        return NO;
    }
    if (moduleKey && prof[moduleKey] != nil) {
        return [prof[moduleKey] boolValue];
    }
    return YES;
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

%hook DCAppAttestService
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
// MÓDULO 2: ZONA HORARIA E IDIOMA/REGIÓN POR CONTENEDOR (OPCIONAL/SELECCIONABLE)
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

%hookf(CFDictionaryRef, CFNetworkCopySystemProxySettings, void) {
    if (!isModuleActive(@"spoofNetwork")) return %orig();
    return (__bridge_retained CFDictionaryRef)@{};
}

%hookf(CFDictionaryRef, CNCopyCurrentNetworkInfo, CFStringRef interfaceName) {
    if (!isModuleActive(@"spoofNetwork")) return %orig(interfaceName);
    NSDictionary *prof = getContainerProfile();
    NSDictionary *fakeWifi = @{
        @"SSID": prof[@"ssid"] ?: @"HomeWiFi-5G",
        @"BSSID": prof[@"bssid"] ?: @"a4:83:e7:21:9a:10",
        @"SSIDDATA": [(prof[@"ssid"] ?: @"HomeWiFi-5G") dataUsingEncoding:NSUTF8StringEncoding]
    };
    return (__bridge_retained CFDictionaryRef)fakeWifi;
}

%hookf(int, getifaddrs, struct ifaddrs **ifap) {
    int res = %orig(ifap);
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
// MÓDULO 4: IDENTIFICADORES (IDFV / ICLOUD / BOOTSESSIONUUID) Y HARDWARE
// ============================================================================
%hook UIDevice
- (NSString *)name {
    if (!isModuleActive(@"spoofHardware")) return %orig;
    return @"iPhone";
}
- (NSUUID *)identifierForVendor {
    if (!isModuleActive(@"spoofIDs")) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSUUID *customUUID = [[NSUUID alloc] initWithUUIDString:prof[@"idfv"]];
    return customUUID ?: %orig;
}
- (float)batteryLevel {
    if (!isModuleActive(@"spoofHardware")) return %orig;
    NSDictionary *prof = getContainerProfile();
    return [prof[@"batteryLevel"] floatValue];
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
        modified[NSFileSystemFreeSize] = prof[@"freeBytes"];
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
        [lower containsString:@"palera1n"]) {
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
    MSHookFunction((void *)sysctlbyname, (void *)custom_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)_dyld_get_image_name, (void *)custom_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
}
