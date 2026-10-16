#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <AVFoundation/AVFoundation.h>
#import <stdlib.h>
#import <time.h>

#define GLOBAL_STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CRANE_PREFS_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_PREFS_VAR @"/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_MAIN_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define CRANE_MAIN_VAR @"/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define CURRENT_SCHEMA_VERSION 21

@interface ASAuthorizationController : NSObject
- (void)performRequests;
@end

static NSMutableDictionary *liveProfile = nil;
static NSTimeInterval sessionStart = 0;
static BOOL bannerShown = NO;
static __thread BOOL isResolving = NO;

static NSDictionary *loadGlobalState() {
    return [NSDictionary dictionaryWithContentsOfFile:GLOBAL_STATE_PLIST] ?: @{};
}

static void applyTimezoneEnv(NSString *tzName) {
    if (!tzName || [tzName hasPrefix:@"Sin "] || [tzName hasPrefix:@"Sincronizando"] || tzName.length == 0) return;
    setenv("TZ", [tzName UTF8String], 1);
    tzset();
}

static NSString *extractActiveCraneIDFromNode(id node, NSString *bundleID) {
    if (![node isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)node;
    for (id k in d) {
        NSString *ks = [k description];
        id v = d[k];
        if ([ks rangeOfString:bundleID options:NSCaseInsensitiveSearch].location != NSNotFound && [v isKindOfClass:[NSDictionary class]]) {
            NSDictionary *sub = (NSDictionary *)v;
            for (NSString *ak in @[@"activeContainer", @"selectedContainer", @"currentContainer", @"activeContainerIdentifier", @"active"]) {
                if ([sub[ak] isKindOfClass:[NSString class]] && [sub[ak] length] > 0) return sub[ak];
            }
        }
        if ([v isKindOfClass:[NSDictionary class]]) {
            NSString *found = extractActiveCraneIDFromNode(v, bundleID);
            if (found) return found;
        }
    }
    return nil;
}

static NSString *detectCurrentCraneContainerID(NSString *bundleID) {
    NSString *home = NSHomeDirectory();
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    if ([env[@"CRANE_CONTAINER_ID"] length] > 0) return env[@"CRANE_CONTAINER_ID"];

    NSString *metaPath = [home stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
    if ([meta isKindOfClass:[NSDictionary class]]) {
        for (NSString *ik in @[@"com.opa334.crane.container.identifier", @"com.opa334.crane.container.id", @"craneContainerIdentifier"]) {
            if ([meta[ik] isKindOfClass:[NSString class]] && [meta[ik] length] > 0) return meta[ik];
        }
        NSDictionary *userInfo = meta[@"MCMMetadataUserInfo"];
        if ([userInfo isKindOfClass:[NSDictionary class]]) {
            for (NSString *k in userInfo) {
                NSString *kl = [k lowercaseString];
                id val = userInfo[k];
                if ([val isKindOfClass:[NSString class]] && [val length] > 0 &&
                    ([kl containsString:@"id"] || [kl containsString:@"container"] || [kl containsString:@"crane"]) &&
                    ![val isEqualToString:bundleID]) {
                    return val;
                }
            }
        }
    }

    for (NSString *p in @[CRANE_PREFS_JB, CRANE_PREFS_VAR, CRANE_MAIN_JB, CRANE_MAIN_VAR]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d.count) {
            NSString *act = extractActiveCraneIDFromNode(d, bundleID);
            if (act.length > 0) return act;
        }
    }

    NSDictionary *st = loadGlobalState();
    NSDictionary *actMap = st[@"activeInCrane"];
    if ([actMap isKindOfClass:[NSDictionary class]] && [actMap[bundleID] length] > 0) {
        return actMap[bundleID];
    }

    return @"Default";
}

static NSMutableDictionary *getActiveProfile() {
    if (liveProfile) return liveProfile;
    if (isResolving) return nil;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        isResolving = YES;
        sessionStart = [[NSDate date] timeIntervalSince1970];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.burbn.instagram";
        NSString *craneID = detectCurrentCraneContainerID(bundleID);
        if ([craneID caseInsensitiveCompare:@"default"] == NSOrderedSame) craneID = @"Default";

        NSDictionary *st = loadGlobalState();
        NSDictionary *byU = [st[@"containersByUUID"] isKindOfClass:[NSDictionary class]] ? st[@"containersByUUID"] : @{};

        NSDictionary *found = byU[craneID];
        if (!found) {
            for (NSString *k in byU) {
                NSDictionary *cand = byU[k];
                if (![cand isKindOfClass:[NSDictionary class]] || ![cand[@"bundleID"] isEqualToString:bundleID]) continue;
                if ([k caseInsensitiveCompare:craneID] == NSOrderedSame ||
                    [cand[@"craneIdentifier"] caseInsensitiveCompare:craneID] == NSOrderedSame ||
                    [cand[@"containerName"] caseInsensitiveCompare:craneID] == NSOrderedSame) {
                    found = cand;
                    break;
                }
            }
        }

        // Si en Modo Exclusivo el usuario encendió manualmente 1 contenedor de esta app, usar ese perfil
        if (!found) {
            for (NSString *k in byU) {
                NSDictionary *cand = byU[k];
                if ([cand isKindOfClass:[NSDictionary class]] &&
                    [cand[@"bundleID"] isEqualToString:bundleID] &&
                    [cand[@"enabled"] boolValue]) {
                    found = cand;
                    break;
                }
            }
        }

        if ([found isKindOfClass:[NSDictionary class]]) {
            liveProfile = [found mutableCopy];
        } else {
            // Si no existe perfil previo, nace 100% APAGADO (Manual)
            liveProfile = [@{
                @"schemaVersion": @(CURRENT_SCHEMA_VERSION),
                @"containerUUID": craneID,
                @"containerName": craneID,
                @"bundleID": bundleID,
                @"enabled": @NO,
                @"spoofIDs": @NO,
                @"spoofLocation": @NO,
                @"spoofNetwork": @NO,
                @"spoofHardware": @NO,
                @"spoofSecurity": @NO
            } mutableCopy];
        }

        BOOL masterOn = [st[@"masterEnabled"] boolValue];
        BOOL appOn = [bundleID isEqualToString:@"com.burbn.instagram"] ? [st[@"enableIG"] boolValue] : [st[@"enableReddit"] boolValue];
        BOOL contOn = [liveProfile[@"enabled"] boolValue];

        if (masterOn && appOn && contOn && [liveProfile[@"spoofLocation"] boolValue]) {
            applyTimezoneEnv(liveProfile[@"timeZone"]);
        }

        isResolving = NO;
    });
    return liveProfile;
}

static BOOL isModuleEnabled(NSString *modKey) {
    if (isResolving) return NO;
    NSDictionary *st = loadGlobalState();
    if (![st[@"masterEnabled"] boolValue]) return NO;

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.burbn.instagram"] && ![st[@"enableIG"] boolValue]) return NO;
    if ([bundleID isEqualToString:@"com.reddit.Reddit"] && ![st[@"enableReddit"] boolValue]) return NO;

    NSDictionary *prof = getActiveProfile();
    if (!prof || ![prof[@"enabled"] boolValue]) return NO;
    if (modKey) return [prof[modKey] boolValue];
    return YES;
}

static void showBannerIfNeeded() {
    if (bannerShown) return;
    bannerShown = YES;

    NSDictionary *st = loadGlobalState();
    if (![st[@"masterEnabled"] boolValue]) return;

    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
    }
    if (!win) return;

    NSDictionary *prof = getActiveProfile();
    BOOL active = isModuleEnabled(nil);
    NSString *cName = prof[@"containerName"] ?: @"Default";

    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(16, 44, win.bounds.size.width - 32, 38)];
    toast.clipsToBounds = YES;
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont boldSystemFontOfSize:11.5];
    toast.numberOfLines = 2;
    toast.textColor = [UIColor whiteColor];

    if (active) {
        toast.backgroundColor = [UIColor colorWithRed:0.06 green:0.48 blue:0.24 alpha:0.92];
        toast.text = [NSString stringWithFormat:@"🛡️ %@ • Manual ON\nIP: %@ • Zona: %@",
                      cName, prof[@"lastSyncedIP"] ?: @"Nativa", prof[@"timeZone"] ?: @"Nativa"];
    } else {
        toast.backgroundColor = [UIColor colorWithRed:0.35 green:0.35 blue:0.38 alpha:0.90];
        toast.text = [NSString stringWithFormat:@"⚪ %@ • En Pausa (Modo Nativo Puro)", cName];
    }

    [win addSubview:toast];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0.0; } completion:^(BOOL f) { [toast removeFromSuperview]; }];
    });
}

// ============================================================================
// MÓDULO 1 (spoofIDs): BLOQUEAR CARTEL DE ICLOUD / APPLE ID EN CONTENEDORES
// ============================================================================
%hook NSUbiquitousKeyValueStore
- (BOOL)synchronize {
    if (isModuleEnabled(@"spoofIDs")) return NO;
    return %orig;
}
- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    if (isModuleEnabled(@"spoofIDs")) return @{};
    return %orig;
}
- (id)objectForKey:(NSString *)aKey {
    if (isModuleEnabled(@"spoofIDs")) return nil;
    return %orig;
}
- (NSString *)stringForKey:(NSString *)aKey {
    if (isModuleEnabled(@"spoofIDs")) return nil;
    return %orig;
}
%end

%hook ASAuthorizationController
- (void)performRequests {
    if (isModuleEnabled(@"spoofIDs")) return;
    %orig;
}
%end

// ============================================================================
// MÓDULO 2 (spoofLocation): ZONA HORARIA SINCRONIZADA CON LA IP
// ============================================================================
%hook NSTimeZone
+ (NSTimeZone *)systemTimeZone {
    if (!isModuleEnabled(@"spoofLocation")) return %orig;
    NSDictionary *prof = getActiveProfile();
    NSString *tz = prof[@"timeZone"];
    if (!tz || [tz hasPrefix:@"Sin "] || tz.length == 0) return %orig;
    return [NSTimeZone timeZoneWithName:tz] ?: %orig;
}
+ (NSTimeZone *)localTimeZone {
    if (!isModuleEnabled(@"spoofLocation")) return %orig;
    return [self systemTimeZone];
}
+ (NSTimeZone *)defaultTimeZone {
    if (!isModuleEnabled(@"spoofLocation")) return %orig;
    return [self systemTimeZone];
}
%end

// ============================================================================
// MÓDULO 3 (spoofNetwork): OPERADORA MÓVIL / WI-FI COHERENTE CON LA IP
// ============================================================================
%hook CTCarrier
- (NSString *)carrierName {
    if (!isModuleEnabled(@"spoofNetwork")) return %orig;
    NSDictionary *prof = getActiveProfile();
    if ([prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return prof[@"CarrierName"] ?: @"T-Mobile";
}
- (NSString *)mobileCountryCode {
    if (!isModuleEnabled(@"spoofNetwork")) return %orig;
    NSDictionary *prof = getActiveProfile();
    if ([prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return prof[@"CarrierMCC"] ?: @"310";
}
- (NSString *)mobileNetworkCode {
    if (!isModuleEnabled(@"spoofNetwork")) return %orig;
    NSDictionary *prof = getActiveProfile();
    if ([prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return prof[@"CarrierMNC"] ?: @"260";
}
- (NSString *)isoCountryCode {
    if (!isModuleEnabled(@"spoofNetwork")) return %orig;
    NSDictionary *prof = getActiveProfile();
    if ([prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) return nil;
    return prof[@"CarrierISO"] ?: @"us";
}
%end

// ============================================================================
// MÓDULO 4 (spoofHardware): SENSORES FÍSICOS AISLADOS (BATERÍA, AUDIO, BRILLO)
// ============================================================================
%hook UIDevice
- (float)batteryLevel {
    if (!isModuleEnabled(@"spoofHardware")) return %orig;
    NSDictionary *prof = getActiveProfile();
    float baseBat = [prof[@"batteryLevel"] floatValue];
    if (baseBat <= 0.05f) return %orig;
    NSTimeInterval mins = ([[NSDate date] timeIntervalSince1970] - sessionStart) / 60.0;
    float drop = (float)((int)(mins / 15.0)) * 0.01f;
    return MAX(0.15f, baseBat - drop);
}
%end

%hook AVAudioSession
- (float)outputVolume {
    if (!isModuleEnabled(@"spoofHardware")) return %orig;
    NSDictionary *prof = getActiveProfile();
    return prof[@"audioVolume"] ? [prof[@"audioVolume"] floatValue] : %orig;
}
%end

%hook UIScreen
- (CGFloat)brightness {
    if (!isModuleEnabled(@"spoofHardware")) return %orig;
    NSDictionary *prof = getActiveProfile();
    return prof[@"brightness"] ? [prof[@"brightness"] floatValue] : %orig;
}
- (BOOL)isCaptured {
    if (!isModuleEnabled(@"spoofSecurity")) return %orig;
    return NO;
}
%end

// ============================================================================
// MÓDULO 5 (spoofSecurity): OCULTAR RUTAS /var/jb EN OBJETIVE-C (SIN HOOKS C)
// ============================================================================
%hook NSFileManager
- (id)ubiquityIdentityToken {
    if (isModuleEnabled(@"spoofIDs")) return nil;
    return %orig;
}
- (NSURL *)URLForUbiquityContainerIdentifier:(NSString *)containerIdentifier {
    if (isModuleEnabled(@"spoofIDs")) return nil;
    return %orig;
}
- (BOOL)fileExistsAtPath:(NSString *)path {
    if (path && isModuleEnabled(@"spoofSecurity")) {
        if ([path hasPrefix:@"/var/jb"] ||
            [path hasPrefix:@"/private/preboot"] ||
            [path containsString:@"palera1n"] ||
            [path containsString:@"Sileo"] ||
            [path containsString:@"Filza"]) {
            return NO;
        }
    }
    return %orig;
}
%end

%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if (url && url.scheme && isModuleEnabled(@"spoofSecurity")) {
        NSString *s = url.scheme.lowercaseString;
        if ([@[@"sileo", @"zbra", @"filza", @"cydia", @"palera1n"] containsObject:s]) {
            return NO;
        }
    }
    return %orig;
}
%end

%ctor {
    %init;
    getActiveProfile();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showBannerIfNeeded();
    });
}
