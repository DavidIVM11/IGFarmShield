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
#import <sys/utsname.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <substrate.h>

#define GLOBAL_STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"

static NSMutableDictionary *liveContainerProfile = nil;
static NSTimeInterval sessionStartTimestamp = 0;

static NSDictionary *getGlobalState() {
    return [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST] ?: @{};
}

static NSString *detectCraneContainerName(NSString *homePath) {
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    if (env[@"CRANE_CONTAINER_NAME"] && [env[@"CRANE_CONTAINER_NAME"] length] > 0) {
        return env[@"CRANE_CONTAINER_NAME"];
    }
    if (env[@"CRANE_CONTAINER_ID"] && [env[@"CRANE_CONTAINER_ID"] length] > 0) {
        return env[@"CRANE_CONTAINER_ID"];
    }
    NSString *metaPath = [homePath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
    if (meta[@"com.opa334.crane.container.name"]) {
        return meta[@"com.opa334.crane.container.name"];
    }
    NSRange r = [homePath rangeOfString:@"___Crane_Containers/"];
    if (r.location != NSNotFound) {
        return [homePath substringFromIndex:NSMaxRange(r)];
    }
    return @"Default";
}

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
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.burbn.instagram";
        NSString *craneName = detectCraneContainerName(homePath);
        NSString *localPlist = [homePath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];

        NSDictionary *loadedGlobal = [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST];
        NSMutableDictionary *globalSt = loadedGlobal ? [loadedGlobal mutableCopy] : [NSMutableDictionary dictionary];
        NSMutableDictionary *containersMap = [globalSt[@"containers"] isKindOfClass:[NSDictionary class]]
            ? [globalSt[@"containers"] mutableCopy]
            : [NSMutableDictionary dictionary];

        NSMutableDictionary *profile = nil;
        if (containersMap[craneName] && [containersMap[craneName] isKindOfClass:[NSDictionary class]]) {
            profile = [containersMap[craneName] mutableCopy];
        } else {
            NSDictionary *diskLoaded = [NSDictionary dictionaryWithContentsOfFile:localPlist];
            if (diskLoaded) profile = [diskLoaded mutableCopy];
        }

        if (!profile || !profile[@"idfv"]) {
            uint64_t seed = fnv1aHash([NSString stringWithFormat:@"%@_%@", craneName, [[NSUUID UUID] UUIDString]]);
            NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59", @"f0:9f:c2", @"04:d6:aa"];
            NSArray *ssidPrefixes = @[@"HomeWiFi", @"ATT-Fiber", @"Xfinity-WiFi", @"SpectrumSetup", @"NETGEAR", @"TP-Link"];
            NSArray *models = @[@"iPhone14,5", @"iPhone13,2", @"iPhone14,2", @"iPhone15,2", @"iPhone12,1"];
            NSArray *subnets = @[@"192.168.1", @"192.168.0", @"10.0.0", @"192.168.50", @"172.16.0"];

            NSString *oui = ouis[seed % ouis.count];
            NSString *ssidPref = ssidPrefixes[(seed >> 3) % ssidPrefixes.count];
            NSString *model = models[(seed >> 7) % models.count];
            NSString *subnet = subnets[(seed >> 5) % subnets.count];

            NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x",
                               oui, (unsigned int)((seed >> 8) & 0xFF), (unsigned int)((seed >> 16) & 0xFF), (unsigned int)((seed >> 24) & 0xFF)];
            NSString *ssid = [NSString stringWithFormat:@"%@-%02X-5G", ssidPref, (unsigned int)(seed & 0xFF)];
            NSString *localIP = [NSString stringWithFormat:@"%@.%d", subnet, 15 + (int)(seed % 220)];

            unsigned long long baseFreeMB = 18400ULL + (seed % 29000ULL);
            unsigned long long freeBytes = baseFreeMB * 1024ULL * 1024ULL;

            profile = [@{
                @"containerName": craneName,
                @"enabled": @YES,
                @"enableIG": @YES,
                @"enableReddit": @YES,
                @"spoofIDs": @YES,
                @"spoofNetwork": @YES,
                @"spoofLocation": @YES,
                @"spoofHardware": @YES,
                @"spoofSecurity": @YES,
                @"deviceModel": model,
                @"idfv": [[NSUUID UUID] UUIDString],
                @"shieldDeviceID": [[NSUUID UUID] UUIDString],
                @"bootSessionUUID": [[NSUUID UUID] UUIDString],
                @"cloudUUID": [[NSUUID UUID] UUIDString],
                @"bssid": bssid,
                @"ssid": ssid,
                @"localIP": localIP,
                @"freeBytes": @(freeBytes),
                @"uptimeOffset": @(1800 + (NSUInteger)(seed % 72000)),
                @"batteryLevel": @(0.42f + ((seed % 52) / 100.0f)),
                @"brightness": @(0.40f + (((seed >> 4) % 50) / 100.0f)),
                @"audioVolume": @(0.25f + (((seed >> 6) % 65) / 100.0f)),
                @"pasteboardCount": @(5 + (seed % 80)),
                @"timeZone": globalSt[@"defaultTimeZone"] ?: @"America/New_York",
                @"localeID": globalSt[@"defaultLocale"] ?: @"en_US",
                @"CarrierMode": @"CELLULAR",
                @"CarrierName": @"T-Mobile",
                @"CarrierMCC": @"310",
                @"CarrierMNC": @"260",
                @"CarrierISO": @"us"
            } mutableCopy];
        }

        NSMutableDictionary *pathsDict = [profile[@"paths"] isKindOfClass:[NSDictionary class]]
            ? [profile[@"paths"] mutableCopy]
            : [NSMutableDictionary dictionary];
        pathsDict[bundleID] = homePath;
        profile[@"paths"] = pathsDict;

        [profile writeToFile:localPlist atomically:YES];
        containersMap[craneName] = profile;
        globalSt[@"containers"] = containersMap;
        [globalSt writeToFile:GLOBAL_STATE_PLIST atomically:YES];

        liveContainerProfile = profile;
    });
    return liveContainerProfile;
}

static BOOL isModuleActive(NSString *moduleKey) {
    NSDictionary *state = getGlobalState();
    if (state[@"masterEnabled"] != nil && ![state[@"masterEnabled"] boolValue]) return NO;

    NSDictionary *prof = getContainerProfile();
    if (prof[@"enabled"] != nil && ![prof[@"enabled"] boolValue]) return NO;

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.burbn.instagram"]) {
        if (prof[@"enableIG"] != nil && ![prof[@"enableIG"] boolValue]) return NO;
    } else if ([bundleID isEqualToString:@"com.reddit.Reddit"]) {
        if (prof[@"enableReddit"] != nil && ![prof[@"enableReddit"] boolValue]) return NO;
    }

    if (moduleKey && prof[moduleKey] != nil) return [prof[moduleKey] boolValue];
    return YES;
}

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

%hook UIDevice
- (NSString *)name {
    if (!isModuleActive(@"spoofHardware")) return %orig;
    return @"iPhone";
}
- (NSUUID *)identifierForVendor {
    NSUUID *origUUID = %orig;
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
        } else if (strcmp(name, "hw.machine") == 0 && isModuleActive(@"spoofHardware")) {
            NSString *model = prof[@"deviceModel"];
            if (model && ![model isEqualToString:@"REAL"]) {
                const char *mStr = [model UTF8String];
                size_t len = strlen(mStr) + 1;
                if (oldp && *oldlenp >= len) memcpy(oldp, mStr, len);
                *oldlenp = len;
            }
        }
    }
    return ret;
}

static int (*orig_uname)(struct utsname *);
static int custom_uname(struct utsname *buf) {
    int ret = orig_uname(buf);
    if (ret == 0 && buf && isModuleActive(@"spoofHardware")) {
        NSDictionary *prof = getContainerProfile();
        NSString *model = prof[@"deviceModel"];
        if (model && ![model isEqualToString:@"REAL"]) {
            strncpy(buf->machine, [model UTF8String], sizeof(buf->machine) - 1);
            buf->machine[sizeof(buf->machine) - 1] = '\0';
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
    MSHookFunction((void *)uname, (void *)custom_uname, (void **)&orig_uname);
    MSHookFunction((void *)_dyld_get_image_name, (void *)custom_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
    MSHookFunction((void *)CFNetworkCopySystemProxySettings, (void *)custom_CFNetworkCopySystemProxySettings, (void **)&orig_CFNetworkCopySystemProxySettings);
    MSHookFunction((void *)CNCopyCurrentNetworkInfo, (void *)custom_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo);
    MSHookFunction((void *)getifaddrs, (void *)custom_getifaddrs, (void **)&orig_getifaddrs);
}
