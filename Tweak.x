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
#import <string.h>
#import <substrate.h>

#define STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"

static NSDictionary *getGlobalState() {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    return dict ?: @{};
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

static NSDictionary *getContainerProfile() {
    static NSDictionary *cachedProfile = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *homePath = NSHomeDirectory();
        NSString *profilePath = [homePath stringByAppendingPathComponent:@"Documents/.igshield_profile.plist"];
        NSMutableDictionary *profile = [NSMutableDictionary dictionaryWithContentsOfFile:profilePath];

        NSDictionary *globalState = getGlobalState();
        NSString *resetToken = globalState[@"resetToken"] ?: @"default";

        if (!profile || ![profile[@"resetToken"] isEqualToString:resetToken]) {
            NSUInteger seed = [[NSString stringWithFormat:@"%@-%@", homePath, resetToken] hash];

            uint8_t b3 = (seed >> 8) & 0xFF;
            uint8_t b4 = (seed >> 16) & 0xFF;
            uint8_t b5 = (seed >> 24) & 0xFF;
            NSString *bssid = [NSString stringWithFormat:@"a4:83:e7:%02x:%02x:%02x", b3, b4, b5];
            NSString *ssid = [NSString stringWithFormat:@"HOME-%04X", (unsigned int)(seed & 0xFFFF)];

            int lastOctet = 20 + (seed % 210);
            NSString *localIP = [NSString stringWithFormat:@"192.168.1.%d", lastOctet];

            unsigned long long baseFreeGB = 16500ULL + (seed % 28300ULL);
            unsigned long long freeBytes = baseFreeGB * 1024ULL * 1024ULL + (seed % 1048576ULL);

            NSUInteger uptimeOffset = 600 + (seed % 64800);
            float batteryLvl = 0.38f + ((seed % 56) / 100.0f);
            float brightnessLvl = 0.42f + (((seed >> 4) % 46) / 100.0f);

            profile = [@{
                @"resetToken": resetToken,
                @"cloudUUID": [[NSUUID UUID] UUIDString],
                @"bssid": bssid,
                @"ssid": ssid,
                @"localIP": localIP,
                @"freeBytes": @(freeBytes),
                @"uptimeOffset": @(uptimeOffset),
                @"batteryLevel": @(batteryLvl),
                @"brightness": @(brightnessLvl)
            } mutableCopy];

            [profile writeToFile:profilePath atomically:YES];
        }
        cachedProfile = [profile copy];
    });
    return cachedProfile;
}

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

%hook CTCarrier
- (NSString *)carrierName {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *st = getGlobalState();
    if ([st[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return st[@"CarrierName"] ?: @"T-Mobile";
}
- (NSString *)mobileCountryCode {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *st = getGlobalState();
    if ([st[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return st[@"CarrierMCC"] ?: @"310";
}
- (NSString *)mobileNetworkCode {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *st = getGlobalState();
    if ([st[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return st[@"CarrierMNC"] ?: @"260";
}
- (NSString *)isoCountryCode {
    if (!isTweakEnabled()) return %orig;
    NSDictionary *st = getGlobalState();
    if ([st[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return st[@"CarrierISO"] ?: @"us";
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

%hookf(CFDictionaryRef, CFNetworkCopySystemProxySettings, void) {
    if (!isTweakEnabled()) return %orig();
    return (__bridge_retained CFDictionaryRef)@{};
}

%hookf(CFDictionaryRef, CNCopyCurrentNetworkInfo, CFStringRef interfaceName) {
    if (!isTweakEnabled()) return %orig(interfaceName);
    NSDictionary *prof = getContainerProfile();
    NSDictionary *fakeWifi = @{
        @"SSID": prof[@"ssid"] ?: @"HOME-WIFI",
        @"BSSID": prof[@"bssid"] ?: @"a4:83:e7:21:9a:10",
        @"SSIDDATA": [(prof[@"ssid"] ?: @"HOME-WIFI") dataUsingEncoding:NSUTF8StringEncoding]
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

%hook NSString
- (BOOL)containsString:(NSString *)str {
    if (isTweakEnabled() && str) {
        NSString *low = [str lowercaseString];
        if ([low containsString:@"crane"] || [low containsString:@"jailbreak"] || [low containsString:@"/var/jb"]) {
            return NO;
        }
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

%hook UIDevice
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
}
