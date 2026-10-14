#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CFNetwork/CFNetwork.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <DeviceCheck/DeviceCheck.h>
#import <SystemConfiguration/CaptiveNetwork.h>
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

static BOOL isTweakEnabled() {
    NSDictionary *state = getGlobalState();
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.burbn.instagram"]) {
        return state[@"enableIG"] ? [state[@"enableIG"] boolValue] : YES;
    }
    if ([bundleID isEqualToString:@"com.reddit.Reddit"]) {
        return state[@"enableReddit"] ? [state[@"enableReddit"] boolValue] : YES;
    }
    return YES;
}

// Lee o crea la huella única DENTRO del propio contenedor de Crane (Sin romper el Sandbox)
static NSDictionary *getContainerProfile() {
    static NSDictionary *cachedProfile = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *homePath = NSHomeDirectory();
        NSString *profilePath = [homePath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        NSMutableDictionary *profile = [NSMutableDictionary dictionaryWithContentsOfFile:profilePath];

        if (!profile || !profile[@"idfv"]) {
            NSUInteger seed = [homePath hash] ^ (NSUInteger)[[NSDate date] timeIntervalSince1970];

            // Prefijos OUI reales de routers domésticos en EE.UU. (Arris, Netgear, Cisco)
            NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59"];
            NSString *oui = ouis[seed % ouis.count];
            uint8_t b3 = (seed >> 8) & 0xFF;
            uint8_t b4 = (seed >> 16) & 0xFF;
            uint8_t b5 = (seed >> 24) & 0xFF;
            NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x", oui, b3, b4, b5];
            NSString *ssid = [NSString stringWithFormat:@"MySpectrumWiFi%02X-5G", (unsigned int)(seed & 0xFF)];

            int lastOctet = 20 + (seed % 210);
            NSString *localIP = [NSString stringWithFormat:@"192.168.1.%d", lastOctet];

            unsigned long long baseFreeGB = 16500ULL + (seed % 28300ULL);
            unsigned long long freeBytes = baseFreeGB * 1024ULL * 1024ULL + (seed % 1048576ULL);

            NSUInteger uptimeOffset = 900 + (seed % 54000);
            float batteryLvl = 0.35f + ((seed % 58) / 100.0f);
            float brightnessLvl = 0.40f + (((seed >> 4) % 48) / 100.0f);

            profile = [@{
                @"idfv": [[NSUUID UUID] UUIDString],
                @"cloudUUID": [[NSUUID UUID] UUIDString],
                @"bssid": bssid,
                @"ssid": ssid,
                @"localIP": localIP,
                @"freeBytes": @(freeBytes),
                @"uptimeOffset": @(uptimeOffset),
                @"batteryLevel": @(batteryLvl),
                @"brightness": @(brightnessLvl),
                @"CarrierMode": @"CELLULAR",
                @"CarrierName": @"T-Mobile",
                @"CarrierMCC": @"310",
                @"CarrierMNC": @"260",
                @"CarrierISO": @"us",
                @"createdAt": [[NSDate date] description]
            } mutableCopy];

            [profile writeToFile:profilePath atomically:YES];
        }
        cachedProfile = [profile copy];
    });
    return cachedProfile;
}

// ============================================================================
// 1. OCULTAR TWEAK Y ELLEKIT EN MEMORIA RAM (ANTI-DETECCIÓN DYLD)
// ============================================================================
static const char *(*orig_dyld_get_image_name)(uint32_t image_index);
static const char *custom_dyld_get_image_name(uint32_t image_index) {
    const char *name = orig_dyld_get_image_name(image_index);
    if (name && isTweakEnabled()) {
        if (strstr(name, "IGFarmShield") != NULL ||
            strstr(name, "ellekit") != NULL ||
            strstr(name, "Substrate") != NULL ||
            strstr(name, "Choicy") != NULL) {
            return "/System/Library/Frameworks/Foundation.framework/Foundation";
        }
    }
    return name;
}

// ============================================================================
// 2. BYPASS PASSCODE (A11 PALERA1N) Y BLOQUEO DE DEVICECHECK / APP ATTEST
// ============================================================================
%hook LAContext
- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError * __autoreleasing *)error {
    if (!isTweakEnabled()) return %orig;
    if (error) *error = nil;
    return YES;
}
%end

%hook DCDevice
- (BOOL)isSupported {
    if (!isTweakEnabled()) return %orig;
    return NO;
}
%end

%hook DCAppAttestService
- (BOOL)isSupported {
    if (!isTweakEnabled()) return %orig;
    return NO;
}
%end

// ============================================================================
// 3. OPERADORA POR CONTENEDOR / PROXY (CTCARRIER)
// ============================================================================
%hook CTCarrier
- (NSString *)carrierName {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSDictionary *st = getGlobalState();
    NSString *mode = st[@"CarrierMode"] ?: prof[@"CarrierMode"];
    if ([mode isEqualToString:@"WIFI_ONLY"]) return nil;
    return st[@"CarrierName"] ?: (prof[@"CarrierName"] ?: @"T-Mobile");
}
- (NSString *)mobileCountryCode {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSDictionary *st = getGlobalState();
    NSString *mode = st[@"CarrierMode"] ?: prof[@"CarrierMode"];
    if ([mode isEqualToString:@"WIFI_ONLY"]) return nil;
    return st[@"CarrierMCC"] ?: (prof[@"CarrierMCC"] ?: @"310");
}
- (NSString *)mobileNetworkCode {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSDictionary *st = getGlobalState();
    NSString *mode = st[@"CarrierMode"] ?: prof[@"CarrierMode"];
    if ([mode isEqualToString:@"WIFI_ONLY"]) return nil;
    return st[@"CarrierMNC"] ?: (prof[@"CarrierMNC"] ?: @"260");
}
- (NSString *)isoCountryCode {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSDictionary *st = getGlobalState();
    NSString *mode = st[@"CarrierMode"] ?: prof[@"CarrierMode"];
    if ([mode isEqualToString:@"WIFI_ONLY"]) return nil;
    return st[@"CarrierISO"] ?: (prof[@"CarrierISO"] ?: @"us");
}
- (BOOL)allowsVOIP {
    return YES;
}
%end

%hook CTTelephonyNetworkInfo
- (NSString *)currentRadioAccessTechnology {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *st = getGlobalState();
    if ([st[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return CTRadioAccessTechnologyLTE;
}
- (NSDictionary<NSString *, NSString *> *)serviceCurrentRadioAccessTechnology {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *st = getGlobalState();
    if ([st[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return @{@"0000000100000001": CTRadioAccessTechnologyLTE};
}
%end

// ============================================================================
// 4. OCULTAR VPN (UTUN) + ROUTER WIFI Y DIRECCIÓN IP LOCAL POR CONTENEDOR
// ============================================================================
%hookf(CFDictionaryRef, CFNetworkCopySystemProxySettings, void) {
    if (!isTweakEnabled()) return %orig();
    return (__bridge_retained CFDictionaryRef)@{};
}

%hookf(CFDictionaryRef, CNCopyCurrentNetworkInfo, CFStringRef interfaceName) {
    if (!isTweakEnabled()) return %orig(interfaceName);
    NSDictionary *prof = getContainerProfile();
    NSDictionary *fakeWifi = @{
        @"SSID": prof[@"ssid"] ?: @"MySpectrumWiFi-5G",
        @"BSSID": prof[@"bssid"] ?: @"a4:83:e7:21:9a:10",
        @"SSIDDATA": [(prof[@"ssid"] ?: @"MySpectrumWiFi-5G") dataUsingEncoding:NSUTF8StringEncoding]
    };
    return (__bridge_retained CFDictionaryRef)fakeWifi;
}

%hookf(int, getifaddrs, struct ifaddrs **ifap) {
    int res = %orig(ifap);
    if (!isTweakEnabled() || res != 0 || !ifap || !*ifap) return res;

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
// 5. IDFV, BATERÍA, BRILLO, ESPACIO LIBRE (64GB) Y OCULTACIÓN DE ARCHIVOS JB
// ============================================================================
%hook UIDevice
- (NSUUID *)identifierForVendor {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *prof = getContainerProfile();
    NSUUID *customUUID = [[NSUUID alloc] initWithUUIDString:prof[@"idfv"]];
    return customUUID ?: %orig;
}
- (float)batteryLevel {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *prof = getContainerProfile();
    return [prof[@"batteryLevel"] floatValue];
}
- (UIDeviceBatteryState)batteryState {
    if (!isTweakEnabled()) return %orig;
    return UIDeviceBatteryStateUnplugged;
}
%end

%hook NSFileManager
- (id)ubiquityIdentityToken {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *prof = getContainerProfile();
    return [prof[@"cloudUUID"] dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSDictionary<NSFileAttributeKey, id> *)attributesOfFileSystemForPath:(NSString *)path error:(NSError * _Nullable *)error {
    NSDictionary *orig = %orig;
    if (!isTweakEnabled() || !orig) return orig;
    NSMutableDictionary *modified = [orig mutableCopy];
    NSDictionary *prof = getContainerProfile();
    if (prof[@"freeBytes"]) {
        modified[NSFileSystemFreeSize] = prof[@"freeBytes"];
    }
    return modified;
}

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (!path || !isTweakEnabled()) return %orig;
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
    if (!isTweakEnabled()) return orig;
    NSDictionary *prof = getContainerProfile();
    return orig + [prof[@"uptimeOffset"] doubleValue];
}
%end

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int custom_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (ret == 0 && name && isTweakEnabled() && strcmp(name, "kern.boottime") == 0 && oldp && *oldlenp >= sizeof(struct timeval)) {
        struct timeval *tv = (struct timeval *)oldp;
        NSDictionary *prof = getContainerProfile();
        tv->tv_sec -= [prof[@"uptimeOffset"] longValue];
    }
    return ret;
}

%hook UIScreen
- (CGFloat)brightness {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *prof = getContainerProfile();
    return [prof[@"brightness"] floatValue];
}
- (BOOL)isCaptured {
    if (!isTweakEnabled()) return %orig;
    return NO;
}
%end

%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if (isTweakEnabled() && url && url.scheme) {
        NSString *s = url.scheme.lowercaseString;
        if ([@[@"sileo", @"zbra", @"filza", @"cydia", @"palera1n", @"santander"] containsObject:s]) {
            return NO;
        }
    }
    return %orig;
}
%end

%ctor {
    %init;
    MSHookFunction((void *)sysctlbyname, (void *)custom_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)_dyld_get_image_name, (void *)custom_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
}
