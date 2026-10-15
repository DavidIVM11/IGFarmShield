#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <spawn.h>

extern char **environ;

#define STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CRANE_PREFS_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_PREFS_VAR @"/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CHOICY_PLIST_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define CHOICY_PLIST_VAR @"/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define VPS_AUDIT_URL @"http://162.35.105.151:5001/iphone_audit"
#define CURRENT_SCHEMA_VERSION 6

@interface PSViewController : UIViewController
@end

@class IGFarmRootListController;

static uint64_t fnv1aHashPrefs(NSString *input) {
    uint64_t hash = 14695981039346656037ULL;
    const char *bytes = [input UTF8String];
    if (!bytes) return arc4random();
    while (*bytes) {
        hash ^= (uint8_t)(*bytes++);
        hash *= 1099511628211ULL;
    }
    return hash;
}

static void killAppProcess(NSString *procName) {
    pid_t pid;
    const char *args[] = {"/var/jb/usr/bin/killall", "-9", [procName UTF8String], NULL};
    posix_spawn(&pid, args[0], NULL, NULL, (char *const *)args, environ);
}

static NSString *recursiveSearchCraneNamePrefs(id node, NSString *targetKey) {
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
                NSString *found = recursiveSearchCraneNamePrefs(val, targetKey);
                if (found) return found;
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) {
            NSString *found = recursiveSearchCraneNamePrefs(item, targetKey);
            if (found) return found;
        }
    }
    return nil;
}

@interface IGFarmRootListController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableDictionary *state;
@property (nonatomic, strong) NSMutableArray *igContainersList;
@property (nonatomic, strong) NSMutableArray *redditContainersList;
@property (nonatomic, assign) BOOL vpnActive;
@property (nonatomic, strong) NSString *vpnInterfaceName;
@property (nonatomic, strong) NSString *choicySummary;
@property (nonatomic, strong) NSString *choicyDetailReport;
@property (nonatomic, assign) BOOL choicyAllSafe;
@property (nonatomic, strong) NSString *residualSummary;
- (void)saveState;
- (void)auditChoicyStatus;
- (void)scanAndSyncAllContainers;
- (void)calculateResidualTraces;
- (void)cleanResidualTracesAndKillApps:(BOOL)showPopup;
- (void)detectCurrentNetworkSilently:(BOOL)silent;
- (NSMutableDictionary *)profileForUUID:(NSString *)uuid;
- (NSMutableDictionary *)ensureProfileForBundle:(NSString *)bundleID uuid:(NSString *)uuid defaultName:(NSString *)dName path:(NSString *)path forceRotate:(BOOL)rotate;
- (void)saveProfile:(NSMutableDictionary *)profile forUUID:(NSString *)uuid;
- (void)setContainer:(NSString *)targetUUID enabled:(BOOL)enabled inBundle:(NSString *)bundleID;
@end

@interface IGFarmAppContainersController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSString *bundleID;
@property (nonatomic, strong) NSString *appTitle;
@property (nonatomic, strong) NSString *appStateKey;
@property (nonatomic, strong) NSMutableArray *containers;
@property (nonatomic, weak) IGFarmRootListController *parentRoot;
@property (nonatomic, strong) UITableView *tableView;
@end

@interface IGFarmContainerDetailController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSString *bundleID;
@property (nonatomic, strong) NSString *containerUUID;
@property (nonatomic, strong) NSMutableDictionary *profile;
@property (nonatomic, weak) IGFarmRootListController *parentRoot;
@property (nonatomic, strong) UITableView *tableView;
@end

// ============================================================================
// NIVEL 1: MENÚ PRINCIPAL (CHOICY + RED TRANSPARENTE + SELECTORES CRANE)
// ============================================================================
@implementation IGFarmRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"IGFarmShield";

    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    self.state = loaded ? [loaded mutableCopy] : [NSMutableDictionary dictionary];
    if (!self.state[@"masterEnabled"]) self.state[@"masterEnabled"] = @YES;
    if (!self.state[@"exclusiveMode"]) self.state[@"exclusiveMode"] = @YES;
    if (!self.state[@"enableIG"]) self.state[@"enableIG"] = @YES;
    if (!self.state[@"enableReddit"]) self.state[@"enableReddit"] = @YES;
    if (![self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]) {
        self.state[@"containersByUUID"] = [NSMutableDictionary dictionary];
    }
    [self saveState];

    [self auditChoicyStatus];
    [self scanAndSyncAllContainers];
    [self calculateResidualTraces];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    [self detectCurrentNetworkSilently:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    if (loaded) self.state = [loaded mutableCopy];
    [self auditChoicyStatus];
    [self scanAndSyncAllContainers];
    [self calculateResidualTraces];
    [self.tableView reloadData];
}

- (void)saveState {
    [self.state writeToFile:STATE_PLIST atomically:YES];
}

- (void)auditChoicyStatus {
    NSDictionary *choicy = [NSDictionary dictionaryWithContentsOfFile:CHOICY_PLIST_JB];
    if (!choicy) choicy = [NSDictionary dictionaryWithContentsOfFile:CHOICY_PLIST_VAR];
    if (!choicy) choicy = [[[NSUserDefaults alloc] initWithSuiteName:@"com.opa334.choicyprefs"] dictionaryRepresentation];

    NSDictionary *appSettings = [choicy[@"appSettings"] isKindOfClass:[NSDictionary class]] ? choicy[@"appSettings"] : @{};
    NSDictionary *igCfg = appSettings[@"com.burbn.instagram"];
    NSDictionary *rdCfg = appSettings[@"com.reddit.Reddit"];

    BOOL igOK = ([igCfg isKindOfClass:[NSDictionary class]] && [igCfg count] > 0);
    BOOL rdOK = ([rdCfg isKindOfClass:[NSDictionary class]] && [rdCfg count] > 0);

    self.choicyAllSafe = (igOK && rdOK);
    if (igOK && rdOK) {
        self.choicySummary = @"🟢 Blindado (IG y Reddit en Whitelist) + Escudo Choicy+";
    } else if (igOK || rdOK) {
        self.choicySummary = [NSString stringWithFormat:@"🟡 Parcial (IG:%@ • Reddit:%@) + Escudo Choicy+", igOK ? @"OK" : @"Falta", rdOK ? @"OK" : @"Falta"];
    } else {
        self.choicySummary = @"🟠 Escudo Choicy+ Activo (Toca para ver estado de Choicy)";
    }

    self.choicyDetailReport = [NSString stringWithFormat:
        @"Estado de Choicy en el Sistema:\n• Instagram: %@\n• Reddit: %@\n\n"
        @"Funciones de Seguridad Choicy+ (Activas en IGFarmShield):\n"
        @"• Hook dladdr(): Oculta en RAM los punteros de IGFarmShield y Crane.\n"
        @"• Hook stat() / lstat() / access(): Bloquea escaneos en C de /var/jb y palera1n.\n"
        @"• Hook dyld: Camufla las librerías inyectadas como UIKitCore.",
        igOK ? @"🟢 Whitelist Activa" : @"⚠️ Sin Whitelist en Choicy",
        rdOK ? @"🟢 Whitelist Activa" : @"⚠️ Sin Whitelist en Choicy"];
}

- (NSMutableDictionary *)profileForUUID:(NSString *)uuid {
    if (!uuid) return nil;
    NSDictionary *byUUID = self.state[@"containersByUUID"];
    if ([byUUID isKindOfClass:[NSDictionary class]] && [byUUID[uuid] isKindOfClass:[NSDictionary class]]) {
        return [byUUID[uuid] mutableCopy];
    }
    return nil;
}

- (void)saveProfile:(NSMutableDictionary *)profile forUUID:(NSString *)uuid {
    if (!uuid || uuid.length == 0 || !profile) return;
    profile[@"containerUUID"] = uuid;
    profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);

    NSMutableDictionary *byUUID = [self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containersByUUID"] mutableCopy]
        : [NSMutableDictionary dictionary];
    byUUID[uuid] = profile;
    self.state[@"containersByUUID"] = byUUID;
    [self saveState];

    NSString *p = profile[@"path"];
    if ([p isKindOfClass:[NSString class]] && p.length > 0) {
        NSString *localPlist = [p stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        [profile writeToFile:localPlist atomically:YES];
    }
}

- (void)setContainer:(NSString *)targetUUID enabled:(BOOL)enabled inBundle:(NSString *)bundleID {
    if (!targetUUID || !bundleID) return;
    BOOL exclusive = [self.state[@"exclusiveMode"] boolValue];
    NSMutableArray *list = [bundleID isEqualToString:@"com.burbn.instagram"] ? self.igContainersList : self.redditContainersList;

    for (NSMutableDictionary *p in list) {
        NSString *u = p[@"containerUUID"];
        if (!u) continue;
        if ([u isEqualToString:targetUUID]) {
            p[@"enabled"] = @(enabled);
            [self saveProfile:p forUUID:u];
        } else if (enabled && exclusive) {
            p[@"enabled"] = @NO;
            [self saveProfile:p forUUID:u];
        }
    }

    killAppProcess([bundleID isEqualToString:@"com.burbn.instagram"] ? @"Instagram" : @"Reddit");
}

- (NSMutableDictionary *)ensureProfileForBundle:(NSString *)bundleID uuid:(NSString *)uuid defaultName:(NSString *)dName path:(NSString *)path forceRotate:(BOOL)rotate {
    if (!bundleID) bundleID = @"com.burbn.instagram";
    if (!uuid || uuid.length == 0) uuid = [path lastPathComponent] ?: @"Default_UUID";

    NSMutableDictionary *byUUID = [self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containersByUUID"] mutableCopy]
        : [NSMutableDictionary dictionary];

    NSMutableDictionary *profile = nil;
    if (path.length > 0) {
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Library/.igshield_container.plist"]];
        if ([disk isKindOfClass:[NSDictionary class]] &&
            [disk[@"schemaVersion"] intValue] == CURRENT_SCHEMA_VERSION &&
            [disk[@"containerUUID"] isEqualToString:uuid]) {
            profile = [disk mutableCopy];
        }
    }
    if (!profile && [byUUID[uuid] isKindOfClass:[NSDictionary class]] &&
        [byUUID[uuid][@"schemaVersion"] intValue] == CURRENT_SCHEMA_VERSION &&
        [byUUID[uuid][@"containerUUID"] isEqualToString:uuid]) {
        profile = [byUUID[uuid] mutableCopy];
    }

    if (!profile || !profile[@"idfv"] || rotate) {
        BOOL wasEnabled = (profile && profile[@"enabled"] != nil) ? [profile[@"enabled"] boolValue] : YES;
        NSString *cleanName = (dName && dName.length > 0) ? dName : uuid;
        NSString *savedAlias = (profile[@"customAlias"] && ![profile[@"customAlias"] isEqualToString:@"Default"]) ? profile[@"customAlias"] : cleanName;

        // Semilla única por carpeta UUID + entropía aleatoria para que dos contenedores jamás coincidan
        uint64_t seed = fnv1aHashPrefs(uuid) ^ (((uint64_t)arc4random() << 32) | arc4random());
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
        unsigned long long freeBytes = ((14800ULL + (seed % 31500ULL)) * 1024ULL * 1024ULL) + ((seed >> 12) % 1048576ULL);

        profile = [@{
            @"schemaVersion": @(CURRENT_SCHEMA_VERSION),
            @"containerUUID": uuid,
            @"containerName": cleanName,
            @"customAlias": savedAlias,
            @"bundleID": bundleID,
            @"path": path ?: @"",
            @"enabled": @(wasEnabled),
            @"spoofIDs": @YES,
            @"spoofNetwork": @YES,
            @"spoofLocation": @YES,
            @"spoofHardware": @YES,
            @"spoofSecurity": @YES,
            @"deviceModel": @"iPhone10,4",
            @"osBuild": osBuild,
            @"deviceName": [NSString stringWithFormat:@"iPhone-%02X", (unsigned int)(seed & 0xFF)],
            @"craneOriginalIDFV": profile[@"craneOriginalIDFV"] ?: @"Se captura al abrir la app",
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
            @"timeZone": self.state[@"defaultTimeZone"] ?: @"America/New_York",
            @"localeID": self.state[@"defaultLocale"] ?: @"en_US",
            @"CarrierMode": self.state[@"defaultCarrierMode"] ?: @"CELLULAR",
            @"CarrierName": self.state[@"defaultCarrierName"] ?: @"T-Mobile",
            @"CarrierMCC": self.state[@"defaultCarrierMCC"] ?: @"310",
            @"CarrierMNC": self.state[@"defaultCarrierMNC"] ?: @"260",
            @"CarrierISO": self.state[@"defaultCarrierISO"] ?: @"us"
        } mutableCopy];
    } else {
        profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
        profile[@"containerUUID"] = uuid;
        profile[@"bundleID"] = bundleID;
        profile[@"deviceModel"] = @"iPhone10,4";
        if (!profile[@"osBuild"]) profile[@"osBuild"] = @"20G81";
        if (path.length > 0) profile[@"path"] = path;
        if (dName && dName.length > 0 && ![dName isEqualToString:@"Default"]) {
            profile[@"containerName"] = dName;
            if (!profile[@"customAlias"] || [profile[@"customAlias"] isEqualToString:@"Default"] || [profile[@"customAlias"] hasPrefix:@"Contenedor"]) {
                profile[@"customAlias"] = dName;
            }
        }
    }

    [self saveProfile:profile forUUID:uuid];
    return profile;
}

- (void)scanAndSyncAllContainers {
    self.igContainersList = [NSMutableArray array];
    self.redditContainersList = [NSMutableArray array];
    NSMutableSet *seenIDFVs = [NSMutableSet set];
    NSMutableSet *seenIPs = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSMutableArray *craneSources = [NSMutableArray array];
    NSDictionary *ud1 = [[[NSUserDefaults alloc] initWithSuiteName:@"com.opa334.craneprefs"] dictionaryRepresentation];
    if (ud1) [craneSources addObject:ud1];
    NSDictionary *ud2 = [[[NSUserDefaults alloc] initWithSuiteName:@"com.opa334.crane"] dictionaryRepresentation];
    if (ud2) [craneSources addObject:ud2];
    for (NSString *cp in @[CRANE_PREFS_JB, CRANE_PREFS_VAR]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:cp];
        if (d) [craneSources addObject:d];
    }

    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:appsDir error:nil];

    NSUInteger igCustomCount = 0;
    NSUInteger rdCustomCount = 0;

    for (NSString *uuid in uuids) {
        NSString *fullPath = [appsDir stringByAppendingPathComponent:uuid];
        NSString *metaPath = [fullPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        if (![meta isKindOfClass:[NSDictionary class]]) continue;

        NSString *bundleID = meta[@"MCMMetadataIdentifier"] ?: @"";
        BOOL isIG = [bundleID isEqualToString:@"com.burbn.instagram"];
        BOOL isRD = [bundleID isEqualToString:@"com.reddit.Reddit"];
        if (!isIG && !isRD) continue;

        NSString *detectedName = nil;
        NSString *craneInternalID = nil;

        for (NSString *rk in @[@"com.opa334.crane.container.name", @"craneContainerName"]) {
            if ([meta[rk] isKindOfClass:[NSString class]] && [meta[rk] length] > 0) detectedName = meta[rk];
        }
        for (NSString *ik in @[@"com.opa334.crane.container.identifier", @"com.opa334.crane.container.id"]) {
            if ([meta[ik] isKindOfClass:[NSString class]] && [meta[ik] length] > 0) craneInternalID = meta[ik];
        }

        NSDictionary *userInfo = meta[@"MCMMetadataUserInfo"];
        if ([userInfo isKindOfClass:[NSDictionary class]] && [userInfo count] > 0) {
            for (NSString *k in userInfo) {
                NSString *kl = [k lowercaseString];
                if ([kl containsString:@"name"] && [userInfo[k] isKindOfClass:[NSString class]] && [userInfo[k] length] > 0) {
                    detectedName = userInfo[k];
                } else if ([userInfo[k] isKindOfClass:[NSString class]] && [userInfo[k] length] > 0) {
                    craneInternalID = userInfo[k];
                }
            }
        }

        if (!detectedName) {
            for (NSDictionary *src in craneSources) {
                if (craneInternalID) {
                    detectedName = recursiveSearchCraneNamePrefs(src, craneInternalID);
                    if (detectedName) break;
                }
                detectedName = recursiveSearchCraneNamePrefs(src, uuid);
                if (detectedName) break;
            }
        }

        if (!detectedName || detectedName.length == 0) {
            if ((!userInfo || [userInfo count] == 0) && !craneInternalID) {
                detectedName = @"Default";
            } else if ([craneInternalID caseInsensitiveCompare:@"default"] == NSOrderedSame) {
                detectedName = @"Default";
            } else if (craneInternalID && ![craneInternalID isEqualToString:uuid]) {
                detectedName = craneInternalID;
            } else {
                NSUInteger idx = isIG ? (++igCustomCount) : (++rdCustomCount);
                detectedName = [NSString stringWithFormat:@"Contenedor #%lu (%@)", (unsigned long)idx, [uuid substringToIndex:MIN(6, uuid.length)]];
            }
        }

        NSMutableDictionary *prof = [self ensureProfileForBundle:bundleID uuid:uuid defaultName:detectedName path:fullPath forceRotate:NO];

        // Garantía anti-colisión absoluta: si algún IDFV o IP LAN se repite entre dos carpetas, regenerar al instante
        if ([seenIDFVs containsObject:prof[@"idfv"]] || [seenIPs containsObject:prof[@"localIP"]]) {
            prof = [self ensureProfileForBundle:bundleID uuid:uuid defaultName:detectedName path:fullPath forceRotate:YES];
        }
        if (prof[@"idfv"]) [seenIDFVs addObject:prof[@"idfv"]];
        if (prof[@"localIP"]) [seenIPs addObject:prof[@"localIP"]];

        if (isIG) [self.igContainersList addObject:prof];
        else [self.redditContainersList addObject:prof];
    }
}

- (void)calculateResidualTraces {
    self.vpnActive = NO;
    self.vpnInterfaceName = @"Inactivo";
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        struct ifaddrs *temp = interfaces;
        while (temp != NULL) {
            if (temp->ifa_addr && temp->ifa_addr->sa_family == AF_INET && (temp->ifa_flags & IFF_UP)) {
                NSString *ifName = [NSString stringWithUTF8String:temp->ifa_name];
                if ([ifName hasPrefix:@"utun"] || [ifName hasPrefix:@"ppp"] || [ifName hasPrefix:@"ipsec"]) {
                    self.vpnActive = YES;
                    self.vpnInterfaceName = ifName;
                }
            }
            temp = temp->ifa_next;
        }
        freeifaddrs(interfaces);
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long residualBytes = 0;
    NSUInteger residualFiles = 0;

    for (NSArray *list in @[self.igContainersList, self.redditContainersList]) {
        for (NSDictionary *prof in list) {
            NSString *cPath = prof[@"path"];
            if (![cPath isKindOfClass:[NSString class]] || cPath.length == 0) continue;
            for (NSString *sub in @[@"tmp", @"Library/Caches", @"Library/WebKit/WebsiteData"]) {
                NSString *dir = [cPath stringByAppendingPathComponent:sub];
                NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
                for (NSString *item in items) {
                    NSString *full = [dir stringByAppendingPathComponent:item];
                    NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
                    residualBytes += [attr[NSFileSize] unsignedLongLongValue];
                    residualFiles++;
                }
            }
        }
    }

    double mb = (double)residualBytes / (1024.0 * 1024.0);
    self.residualSummary = [NSString stringWithFormat:@"%lu archivos temporales (%.2f MB) + Portapapeles", (unsigned long)residualFiles, mb];
}

- (void)cleanResidualTracesAndKillApps:(BOOL)showPopup {
    killAppProcess(@"Instagram");
    killAppProcess(@"Reddit");

    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger removedCount = 0;

    [UIPasteboard generalPasteboard].items = @[];
    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    for (NSArray *list in @[self.igContainersList, self.redditContainersList]) {
        for (NSDictionary *prof in list) {
            NSString *cPath = prof[@"path"];
            if (![cPath isKindOfClass:[NSString class]] || cPath.length == 0) continue;
            for (NSString *sub in @[@"tmp", @"Library/Caches", @"Library/WebKit/WebsiteData"]) {
                NSString *dir = [cPath stringByAppendingPathComponent:sub];
                NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
                for (NSString *item in items) {
                    [fm removeItemAtPath:[dir stringByAppendingPathComponent:item] error:nil];
                    removedCount++;
                }
            }
        }
    }

    [self calculateResidualTraces];
    [self.tableView reloadData];

    if (showPopup) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Rotación Segura Lista"
                                                                    message:[NSString stringWithFormat:@"• Instagram y Reddit cerrados.\n• %lu archivos residuales eliminados (tmp, Caches, WebKit).\n• Portapapeles vaciado.\n\nYa puedes rotar tu IP y cambiar de contenedor en Crane.", (unsigned long)removedCount]
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

#pragma mark - TableView Nivel 1 (Menú Principal)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"1. ESCUDO MAESTRO, CHOICY+ Y RED EN VIVO";
    if (section == 1) return @"2. SELECTOR DE CONTENEDORES POR APP (CRANE)";
    return @"3. LIMPIEZA PROFUNDA ANTES DE CAMBIAR DE CUENTA";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 4;
    if (section == 1) return 2;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL masterOn = [self.state[@"masterEnabled"] boolValue];

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = @"Habilitar IGFarmShield";
            cell.detailTextLabel.text = masterOn ? @"🟢 Escudo maestro activo (iPhone 8 Coherente)" : @"⚪ Desactivado";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = masterOn;
            sw.tag = 10;
            [sw addTarget:self action:@selector(toggleRootSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            BOOL excl = [self.state[@"exclusiveMode"] boolValue];
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
            cell.textLabel.text = @"Modo Exclusivo (1 Contenedor Activo)";
            cell.detailTextLabel.text = excl ? @"🔒 Al encender uno se apagan los demás + Cierra App" : @"🔓 Múltiples contenedores activos simultáneos";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = excl;
            sw.tag = 11;
            [sw addTarget:self action:@selector(toggleRootSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 2) {
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"🛡️ Estado de Choicy y Escudo Choicy+";
            cell.detailTextLabel.textColor = self.choicyAllSafe ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
            cell.detailTextLabel.text = self.choicySummary;
        } else {
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.textLabel.text = @"📡 Estado de Red / Proxy Actual (Transparente)";
            NSString *vpnTxt = self.vpnActive ? [NSString stringWithFormat:@"🟢 VPN (%@)", self.vpnInterfaceName] : @"⚠️ Sin VPN";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • IP: %@ (%@)",
                                         vpnTxt,
                                         self.state[@"last_ip"] ?: @"Toca para auditar",
                                         self.state[@"last_isp"] ?: @"..."];
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        NSDictionary *activeMap = self.state[@"activeInCrane"];

        if (indexPath.row == 0) {
            NSString *actUUID = activeMap[@"com.burbn.instagram"];
            NSString *actName = @"Abre IG para detectar";
            for (NSDictionary *p in self.igContainersList) {
                if ([p[@"containerUUID"] isEqualToString:actUUID]) {
                    actName = p[@"customAlias"] ?: p[@"containerName"];
                    break;
                }
            }
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = [NSString stringWithFormat:@"📸 Instagram (%lu Contenedores)", (unsigned long)self.igContainersList.count];
            cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"🎯 Último abierto en Crane: %@", actName];
        } else {
            NSString *actUUID = activeMap[@"com.reddit.Reddit"];
            NSString *actName = @"Abre Reddit para detectar";
            for (NSDictionary *p in self.redditContainersList) {
                if ([p[@"containerUUID"] isEqualToString:actUUID]) {
                    actName = p[@"customAlias"] ?: p[@"containerName"];
                    break;
                }
            }
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = [NSString stringWithFormat:@"🤖 Reddit (%lu Contenedores)", (unsigned long)self.redditContainersList.count];
            cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"🎯 Último abierto en Crane: %@", actName];
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.textLabel.textColor = [UIColor systemRedColor];
    cell.textLabel.text = @"🧹 Cerrar Apps + Limpiar Rastro y Caché (64GB)";
    cell.detailTextLabel.text = self.residualSummary ?: @"Cierra IG/Reddit y purga tmp, Caches y Portapapeles";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)toggleRootSwitch:(UISwitch *)sender {
    if (sender.tag == 10) self.state[@"masterEnabled"] = @(sender.isOn);
    else if (sender.tag == 11) self.state[@"exclusiveMode"] = @(sender.isOn);
    [self saveState];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        if (indexPath.row == 2) {
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🛡️ Diagnóstico Choicy + Choicy+"
                                                                        message:self.choicyDetailReport
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"Entendido" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        } else if (indexPath.row == 3) {
            [self detectCurrentNetworkSilently:NO];
        }
        return;
    }

    if (indexPath.section == 1) {
        IGFarmAppContainersController *appVC = [[IGFarmAppContainersController alloc] init];
        appVC.parentRoot = self;
        if (indexPath.row == 0) {
            appVC.bundleID = @"com.burbn.instagram";
            appVC.appTitle = @"📸 Instagram (Crane)";
            appVC.appStateKey = @"enableIG";
            appVC.containers = self.igContainersList;
        } else {
            appVC.bundleID = @"com.reddit.Reddit";
            appVC.appTitle = @"🤖 Reddit (Crane)";
            appVC.appStateKey = @"enableReddit";
            appVC.containers = self.redditContainersList;
        }
        [self.navigationController pushViewController:appVC animated:YES];
        return;
    }

    if (indexPath.section == 2) {
        [self cleanResidualTracesAndKillApps:YES];
    }
}

// Detección 100% transparente de la IP y red actual (sin ocultar ni bloquear nada)
- (void)detectCurrentNetworkSilently:(BOOL)silent {
    NSURL *url = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,countryCode,city,timezone,isp,query"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 6.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) return;

        NSString *ip = json[@"query"] ?: @"Desconocida";
        NSString *ispRaw = json[@"isp"] ?: @"ISP";
        NSString *ispUp = [ispRaw uppercaseString];
        NSString *cc = [json[@"countryCode"] lowercaseString] ?: @"us";
        NSString *tz = json[@"timezone"] ?: @"America/New_York";

        self.state[@"last_ip"] = ip;
        self.state[@"last_isp"] = [NSString stringWithFormat:@"%@ (%@)", ispRaw, [cc uppercaseString]];
        self.state[@"defaultTimeZone"] = tz;
        self.state[@"defaultLocale"] = [NSString stringWithFormat:@"en_%@", [cc uppercaseString]];

        if ([ispUp containsString:@"T-MOBILE"] || [ispUp containsString:@"METRO"] || [ispUp containsString:@"MINT"]) {
            self.state[@"defaultCarrierMode"] = @"CELLULAR"; self.state[@"defaultCarrierName"] = @"T-Mobile";
            self.state[@"defaultCarrierMCC"] = @"310"; self.state[@"defaultCarrierMNC"] = @"260"; self.state[@"defaultCarrierISO"] = @"us";
        } else if ([ispUp containsString:@"AT&T"] || [ispUp containsString:@"CRICKET"]) {
            self.state[@"defaultCarrierMode"] = @"CELLULAR"; self.state[@"defaultCarrierName"] = @"AT&T";
            self.state[@"defaultCarrierMCC"] = @"310"; self.state[@"defaultCarrierMNC"] = @"410"; self.state[@"defaultCarrierISO"] = @"us";
        } else if ([ispUp containsString:@"VERIZON"] || [ispUp containsString:@"VISIBLE"]) {
            self.state[@"defaultCarrierMode"] = @"CELLULAR"; self.state[@"defaultCarrierName"] = @"Verizon";
            self.state[@"defaultCarrierMCC"] = @"311"; self.state[@"defaultCarrierMNC"] = @"480"; self.state[@"defaultCarrierISO"] = @"us";
        } else {
            self.state[@"defaultCarrierMode"] = @"WIFI_ONLY"; self.state[@"defaultCarrierName"] = @"Wi-Fi";
            self.state[@"defaultCarrierMCC"] = @""; self.state[@"defaultCarrierMNC"] = @""; self.state[@"defaultCarrierISO"] = cc;
        }
        [self saveState];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self calculateResidualTraces];
            [self.tableView reloadData];
            if (!silent) {
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Estado de Red Transparente"
                                                                            message:[NSString stringWithFormat:@"VPN: %@\nIP Saliente: %@\nISP: %@ (%@)\nZona Horaria Real de la IP: %@",
                                                                                     self.vpnActive ? @"🟢 Activa" : @"⚠️ Inactiva (Red Directa)", ip, ispRaw, [cc uppercaseString], tz]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            }
        });
    }] resume];
}

@end

// ============================================================================
// NIVEL 2: LISTA DE CONTENEDORES DE UNA APP (SINCRONIZACIÓN REAL DE SWITCHES)
// ============================================================================
@implementation IGFarmAppContainersController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.appTitle;
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.parentRoot scanAndSyncAllContainers];
    self.containers = [self.bundleID isEqualToString:@"com.burbn.instagram"]
        ? self.parentRoot.igContainersList
        : self.parentRoot.redditContainersList;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"INTERRUPTOR GENERAL DE LA APLICACIÓN";
    return [NSString stringWithFormat:@"CONTENEDORES INDEPENDIENTES (%lu) — TOCA PARA VER SU HUELLA", (unsigned long)self.containers.count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return MAX(1, self.containers.count);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL masterOn = [self.parentRoot.state[@"masterEnabled"] boolValue];
    BOOL appOn = [self.parentRoot.state[self.appStateKey] boolValue];

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        cell.textLabel.text = [NSString stringWithFormat:@"Proteger %@", self.appTitle];
        cell.detailTextLabel.text = (masterOn && appOn) ? @"🟢 Activo para esta aplicación" : @"⚪ Desactivado";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = appOn;
        sw.enabled = masterOn;
        [sw addTarget:self action:@selector(toggleAppMaster:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (self.containers.count == 0) {
        UITableViewCell *empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        empty.textLabel.text = @"No se detectaron contenedores";
        empty.detailTextLabel.text = @"Abre la app una vez para que se registre";
        return empty;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSMutableDictionary *prof = self.containers[indexPath.row];
    NSString *uuid = prof[@"containerUUID"] ?: @"Default_UUID";
    NSString *displayName = prof[@"customAlias"] ?: (prof[@"containerName"] ?: uuid);
    BOOL contOn = prof[@"enabled"] ? [prof[@"enabled"] boolValue] : YES;

    NSDictionary *activeMap = self.parentRoot.state[@"activeInCrane"];
    BOOL isCurrentInCrane = [activeMap[self.bundleID] isEqualToString:uuid];

    cell.textLabel.font = [UIFont boldSystemFontOfSize:15.5];
    cell.textLabel.text = isCurrentInCrane
        ? [NSString stringWithFormat:@"🎯 %@ (Activo en Crane)", displayName]
        : [NSString stringWithFormat:@"📦 %@", displayName];

    NSString *shortIDFV = [prof[@"idfv"] length] > 8 ? [prof[@"idfv"] substringToIndex:8] : (prof[@"idfv"] ?: @"");
    NSString *netTxt = [prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"] ? @"Wi-Fi" : (prof[@"CarrierName"] ?: @"T-Mobile");

    if (masterOn && appOn && contOn) {
        cell.detailTextLabel.textColor = [UIColor systemGreenColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 ON • %@ • LAN:%@ • IDFV:%@...",
                                     netTxt, prof[@"localIP"] ?: @"", shortIDFV];
    } else {
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"⚪ En pausa • LAN:%@ • IDFV:%@...", prof[@"localIP"] ?: @"", shortIDFV];
    }

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = contOn;
    sw.enabled = (masterOn && appOn);
    sw.tag = indexPath.row;
    [sw addTarget:self action:@selector(toggleContainerRowSwitch:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (void)toggleAppMaster:(UISwitch *)sender {
    self.parentRoot.state[self.appStateKey] = @(sender.isOn);
    [self.parentRoot saveState];
    [self.tableView reloadData];
}

- (void)toggleContainerRowSwitch:(UISwitch *)sender {
    if (sender.tag < 0 || sender.tag >= self.containers.count) return;
    NSMutableDictionary *targetProf = self.containers[sender.tag];
    NSString *targetUUID = targetProf[@"containerUUID"];
    [self.parentRoot setContainer:targetUUID enabled:sender.isOn inBundle:self.bundleID];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || self.containers.count == 0) return;

    NSMutableDictionary *prof = self.containers[indexPath.row];
    IGFarmContainerDetailController *detailVC = [[IGFarmContainerDetailController alloc] init];
    detailVC.bundleID = self.bundleID;
    detailVC.containerUUID = prof[@"containerUUID"];
    detailVC.profile = prof;
    detailVC.parentRoot = self.parentRoot;
    [self.navigationController pushViewController:detailVC animated:YES];
}

@end

// ============================================================================
// NIVEL 3: DETALLE DEL CONTENEDOR (HUELLA ÚNICA VERIFICADA + RED TRANSPARENTE)
// ============================================================================
@implementation IGFarmContainerDetailController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSMutableDictionary *fresh = [self.parentRoot profileForUUID:self.containerUUID];
    if (fresh) self.profile = fresh;
    self.title = self.profile[@"customAlias"] ?: (self.profile[@"containerName"] ?: @"Contenedor");
    [self.tableView reloadData];
}

- (void)saveCurrentProfile {
    if (self.parentRoot && self.profile && self.containerUUID) {
        [self.parentRoot saveProfile:self.profile forUUID:self.containerUUID];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"1. CONTROL DEL CONTENEDOR Y NOMBRE DE CUENTA";
        case 1: return @"2. OPERADORA, ZONA HORARIA Y SINCRONIZACIÓN TRANSPARENTE";
        case 2: return @"3. MÓDULOS DE AISLAMIENTO ACTIVOS";
        case 3: return @"4. HUELLA ÚNICA INYECTADA + RECIBO DE LA APP EN VIVO";
        case 4: return @"5. ACCIONES DE ESTE CONTENEDOR";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 2;
        case 1: return 3;
        case 2: return 5;
        case 3: return 9;
        case 4: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL contOn = self.profile[@"enabled"] ? [self.profile[@"enabled"] boolValue] : YES;

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        if (indexPath.row == 0) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = @"Habilitar Contenedor para Operar";
            cell.detailTextLabel.text = contOn ? @"🟢 Activo (Inyectando identidad en la App)" : @"⚪ En pausa";
            cell.detailTextLabel.textColor = contOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = contOn;
            sw.tag = 100;
            [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.text = @"✏️ Cambiar Etiqueta / @Usuario de este Contenedor";
            NSString *shortUUID = (self.containerUUID.length > 8) ? [self.containerUUID substringToIndex:8] : self.containerUUID;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Nombre: %@ • Carpeta UUID: %@...",
                                         self.profile[@"customAlias"] ?: self.profile[@"containerName"], shortUUID];
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.detailTextLabel.textColor = [UIColor systemBlueColor];

        if (indexPath.row == 0) {
            cell.textLabel.text = @"📡 Operadora / Modo de Red";
            if ([self.profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"🛜 Wi-Fi Residencial Puro (Sin SIM • %@)", [self.profile[@"CarrierISO"] ?: @"us" uppercaseString]];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"📱 4G LTE %@ (MCC %@ / MNC %@)",
                                             self.profile[@"CarrierName"] ?: @"T-Mobile",
                                             self.profile[@"CarrierMCC"] ?: @"310",
                                             self.profile[@"CarrierMNC"] ?: @"260"];
            }
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"🌎 Zona Horaria e Idioma (C + ObjC)";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • Locale: %@",
                                         self.profile[@"timeZone"] ?: @"America/New_York",
                                         self.profile[@"localeID"] ?: @"en_US"];
        } else {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.text = @"⚡ Sincronizar con la IP Actual en Vivo";
            cell.detailTextLabel.text = self.profile[@"lastSyncedIP"]
                ? [NSString stringWithFormat:@"Última IP sincronizada: %@", self.profile[@"lastSyncedIP"]]
                : @"Refleja de forma transparente el ISP, país y hora de la IP actual";
        }
        return cell;
    }

    if (indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSArray *titles = @[
            @"Camuflar IDs (Shield IDFV / BootUUID / iCloud)",
            @"Camuflar Subred Local y Ocultar VPN (utun)",
            @"Camuflar Zona Horaria e Idioma (TZ + NSLocale)",
            @"Camuflar Disco (statfs), Batería y Audio (iPhone 8)",
            @"Escudo Choicy+ (dladdr / stat / Ocultar JB y Crane)"
        ];
        NSArray *keys = @[@"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity"];
        cell.textLabel.font = [UIFont systemFontOfSize:14.5];
        cell.textLabel.text = titles[indexPath.row];
        UISwitch *sw = [[UISwitch alloc] init];
        NSString *k = keys[indexPath.row];
        sw.on = (self.profile[k] == nil) ? YES : [self.profile[k] boolValue];
        sw.tag = 200 + indexPath.row;
        [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (indexPath.section == 3) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:13];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.textColor = contOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];

        double freeGB = [self.profile[@"freeBytes"] unsignedLongLongValue] / (1024.0*1024.0*1024.0);
        int batPct = (int)([self.profile[@"batteryLevel"] floatValue] * 100.0f);
        int volPct = (int)([self.profile[@"audioVolume"] floatValue] * 100.0f);
        NSUInteger upMin = [self.profile[@"uptimeOffset"] unsignedIntegerValue] / 60;

        if (indexPath.row == 0) {
            cell.textLabel.text = @"✅ Prueba Real en Vivo (Leído por la App)";
            if (self.profile[@"verifiedLiveIDFV"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Hora: %@ • App recibió IDFV: %@...\nApp recibió TZ: %@ • Bat: %@%%",
                                             self.profile[@"lastInjectedTime"] ?: @"Hoy",
                                             [self.profile[@"verifiedLiveIDFV"] substringToIndex:MIN(12, [self.profile[@"verifiedLiveIDFV"] length])],
                                             self.profile[@"verifiedLiveTZ"] ?: @"",
                                             self.profile[@"verifiedLiveBat"] ?: @50];
            } else {
                cell.detailTextLabel.text = @"Abre la app en este contenedor para registrar el recibo de inyección en vivo";
            }
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"📦 UUID Carpeta Contenedor + IDFV Base de Crane";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Carpeta: %@\nCrane IDFV: %@",
                                         self.containerUUID, self.profile[@"craneOriginalIDFV"] ?: @"Se captura al abrir la app"];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"🔑 Nuevo Vendor ID (Shield IDFV Único)";
            cell.detailTextLabel.text = self.profile[@"idfv"] ?: @"N/A";
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"🛡️ Nuevo Shield Device ID + iCloud Token";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"DevID: %@\niCloud: %@",
                                         self.profile[@"shieldDeviceID"] ?: @"N/A", self.profile[@"cloudUUID"] ?: @"N/A"];
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"🔄 Kernel BootSession UUID + Build OS";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nBuild iOS (kern.osversion): %@",
                                         self.profile[@"bootSessionUUID"] ?: @"N/A",
                                         self.profile[@"osBuild"] ?: @"20G81"];
        } else if (indexPath.row == 5) {
            cell.textLabel.text = @"📱 Modelo Físico Coherente + Disco (statfs + NSFileManager)";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"iPhone 8 (iPhone10,4) • %.2f GB libres de 64 GB", freeGB];
        } else if (indexPath.row == 6) {
            cell.textLabel.text = @"🔋 Batería Simulada + Volumen Audio + Uptime";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Bat: %d%% (Unplugged) • Vol: %d%% • Boot: +%lu min",
                                         batPct, volPct, (unsigned long)upMin];
        } else if (indexPath.row == 7) {
            cell.textLabel.text = @"📡 Subred LAN (en0) y Router Wi-Fi (BSSID)";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"IP LAN: %@ • %@ (%@)",
                                         self.profile[@"localIP"], self.profile[@"ssid"], self.profile[@"bssid"]];
        } else {
            cell.textLabel.text = @"🌎 Operadora y Zona Horaria Activa";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@) • %@ (%@)",
                                         self.profile[@"CarrierName"], self.profile[@"CarrierMode"],
                                         self.profile[@"timeZone"], self.profile[@"localeID"]];
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.row == 0) {
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.textLabel.text = @"🔍 Auditar Contenedor + IP en Proxy Center (Telegram)";
    } else {
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.textLabel.text = @"🔄 Regenerar Todos los IDs de este Contenedor";
    }
    return cell;
}

- (void)toggleSwitch:(UISwitch *)sender {
    if (sender.tag == 100) {
        [self.parentRoot setContainer:self.containerUUID enabled:sender.isOn inBundle:self.bundleID];
        self.profile[@"enabled"] = @(sender.isOn);
    } else if (sender.tag >= 200) {
        NSArray *keys = @[@"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity"];
        self.profile[keys[sender.tag - 200]] = @(sender.isOn);
        [self saveCurrentProfile];
    }
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0 && indexPath.row == 1) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Renombrar Contenedor"
                                                                    message:@"Ponle el nombre o @usuario de la cuenta que manejas en este contenedor de Crane:"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = self.profile[@"customAlias"] ?: self.profile[@"containerName"];
            tf.placeholder = @"Ej: @cheekychiix, Reddit_02...";
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Guardar" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *newName = ac.textFields.firstObject.text;
            if (newName && newName.length > 0) {
                self.profile[@"customAlias"] = newName;
                self.title = newName;
                [self saveCurrentProfile];
                [self.tableView reloadData];
            }
        }]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    if (indexPath.section == 1) {
        if (indexPath.row == 0) [self showCarrierSelector];
        else if (indexPath.row == 1) [self showTimeZoneSelector];
        else [self autoSyncNetworkAndAuditOnVPS:NO];
        return;
    }

    if (indexPath.section == 4) {
        if (indexPath.row == 0) {
            [self autoSyncNetworkAndAuditOnVPS:YES];
        } else {
            self.profile = [self.parentRoot ensureProfileForBundle:self.bundleID
                                                              uuid:self.containerUUID
                                                       defaultName:self.profile[@"containerName"]
                                                              path:self.profile[@"path"]
                                                       forceRotate:YES];
            [self.tableView reloadData];
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Huella Regenerada"
                                                                        message:@"Se generaron nuevos Shield IDFV, Device ID, BootSession UUID, Build iOS, Subred LAN, Router BSSID y métricas de iPhone 8 exclusivos para este contenedor."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        }
    }
}

- (void)showCarrierSelector {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Operadora / Red del Contenedor"
                                                                message:@"Elige cómo se identificará la red en este contenedor:"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *presets = @[
        @{@"title": @"📱 T-Mobile US 4G LTE (310 / 260)", @"mode": @"CELLULAR", @"name": @"T-Mobile", @"mcc": @"310", @"mnc": @"260", @"iso": @"us"},
        @{@"title": @"📱 AT&T US 4G LTE (310 / 410)", @"mode": @"CELLULAR", @"name": @"AT&T", @"mcc": @"310", @"mnc": @"410", @"iso": @"us"},
        @{@"title": @"📱 Verizon US 4G LTE (311 / 480)", @"mode": @"CELLULAR", @"name": @"Verizon", @"mcc": @"311", @"mnc": @"480", @"iso": @"us"},
        @{@"title": @"🛜 Wi-Fi Residencial Puro (Sin SIM • US)", @"mode": @"WIFI_ONLY", @"name": @"Wi-Fi", @"mcc": @"", @"mnc": @"", @"iso": @"us"},
        @{@"title": @"🇬🇧 Vodafone UK 4G LTE (234 / 15)", @"mode": @"CELLULAR", @"name": @"Vodafone UK", @"mcc": @"234", @"mnc": @"15", @"iso": @"gb"},
        @{@"title": @"🇪🇸 Movistar ES 4G LTE (214 / 07)", @"mode": @"CELLULAR", @"name": @"Movistar", @"mcc": @"214", @"mnc": @"07", @"iso": @"es"}
    ];
    for (NSDictionary *p in presets) {
        [ac addAction:[UIAlertAction actionWithTitle:p[@"title"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self.profile[@"CarrierMode"] = p[@"mode"];
            self.profile[@"CarrierName"] = p[@"name"];
            self.profile[@"CarrierMCC"] = p[@"mcc"];
            self.profile[@"CarrierMNC"] = p[@"mnc"];
            self.profile[@"CarrierISO"] = p[@"iso"];
            [self saveCurrentProfile];
            [self.tableView reloadData];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showTimeZoneSelector {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Zona Horaria y Región"
                                                                message:@"Selecciona la ubicación horaria de este contenedor:"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *zones = @[
        @{@"title": @"🇺🇸 USA Este - Miami / NY (America/New_York)", @"tz": @"America/New_York", @"loc": @"en_US"},
        @{@"title": @"🇺🇸 USA Centro - Texas / Chicago (America/Chicago)", @"tz": @"America/Chicago", @"loc": @"en_US"},
        @{@"title": @"🇺🇸 USA Montaña - Denver (America/Denver)", @"tz": @"America/Denver", @"loc": @"en_US"},
        @{@"title": @"🇺🇸 USA Oeste - Los Ángeles (America/Los_Angeles)", @"tz": @"America/Los_Angeles", @"loc": @"en_US"},
        @{@"title": @"🇬🇧 Reino Unido - Londres (Europe/London)", @"tz": @"Europe/London", @"loc": @"en_GB"},
        @{@"title": @"🇪🇸 España - Madrid (Europe/Madrid)", @"tz": @"Europe/Madrid", @"loc": @"es_ES"}
    ];
    for (NSDictionary *z in zones) {
        [ac addAction:[UIAlertAction actionWithTitle:z[@"title"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self.profile[@"timeZone"] = z[@"tz"];
            self.profile[@"localeID"] = z[@"loc"];
            [self saveCurrentProfile];
            [self.tableView reloadData];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

// Sincronización 100% transparente con la IP actual (muestra y aplica la IP/Zona Horaria real de la conexión)
- (void)autoSyncNetworkAndAuditOnVPS:(BOOL)sendToVPS {
    NSURL *ipUrl = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,countryCode,city,timezone,isp,query"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 6.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:ipUrl completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Error de Red" message:@"No se pudo detectar la IP saliente." preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
            return;
        }

        NSDictionary *ipJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![ipJson isKindOfClass:[NSDictionary class]]) return;
        NSString *ip = ipJson[@"query"] ?: @"";
        NSString *ispRaw = ipJson[@"isp"] ?: @"ISP";
        NSString *ispUp = [ispRaw uppercaseString];
        NSString *cc = [ipJson[@"countryCode"] lowercaseString] ?: @"us";
        NSString *tz = ipJson[@"timezone"] ?: @"America/New_York";

        self.profile[@"lastSyncedIP"] = ip;
        self.profile[@"timeZone"] = tz;
        self.profile[@"localeID"] = [NSString stringWithFormat:@"en_%@", [cc uppercaseString]];

        if ([ispUp containsString:@"T-MOBILE"] || [ispUp containsString:@"METRO"] || [ispUp containsString:@"MINT"]) {
            self.profile[@"CarrierMode"] = @"CELLULAR"; self.profile[@"CarrierName"] = @"T-Mobile";
            self.profile[@"CarrierMCC"] = @"310"; self.profile[@"CarrierMNC"] = @"260"; self.profile[@"CarrierISO"] = @"us";
        } else if ([ispUp containsString:@"AT&T"] || [ispUp containsString:@"CRICKET"]) {
            self.profile[@"CarrierMode"] = @"CELLULAR"; self.profile[@"CarrierName"] = @"AT&T";
            self.profile[@"CarrierMCC"] = @"310"; self.profile[@"CarrierMNC"] = @"410"; self.profile[@"CarrierISO"] = @"us";
        } else if ([ispUp containsString:@"VERIZON"] || [ispUp containsString:@"VISIBLE"]) {
            self.profile[@"CarrierMode"] = @"CELLULAR"; self.profile[@"CarrierName"] = @"Verizon";
            self.profile[@"CarrierMCC"] = @"311"; self.profile[@"CarrierMNC"] = @"480"; self.profile[@"CarrierISO"] = @"us";
        } else if ([ispUp containsString:@"VODAFONE"] && [cc isEqualToString:@"gb"]) {
            self.profile[@"CarrierMode"] = @"CELLULAR"; self.profile[@"CarrierName"] = @"Vodafone UK";
            self.profile[@"CarrierMCC"] = @"234"; self.profile[@"CarrierMNC"] = @"15"; self.profile[@"CarrierISO"] = @"gb";
        } else if ([ispUp containsString:@"MOVISTAR"] && [cc isEqualToString:@"es"]) {
            self.profile[@"CarrierMode"] = @"CELLULAR"; self.profile[@"CarrierName"] = @"Movistar";
            self.profile[@"CarrierMCC"] = @"214"; self.profile[@"CarrierMNC"] = @"07"; self.profile[@"CarrierISO"] = @"es";
        } else {
            self.profile[@"CarrierMode"] = @"WIFI_ONLY"; self.profile[@"CarrierName"] = @"Wi-Fi";
            self.profile[@"CarrierMCC"] = @""; self.profile[@"CarrierMNC"] = @""; self.profile[@"CarrierISO"] = cc;
        }

        [self saveCurrentProfile];

        if (!sendToVPS) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Red Sincronizada (Transparente)"
                                                                            message:[NSString stringWithFormat:@"IP Actual: %@ (%@)\n\n• Modo Red: %@ (%@)\n• Zona Horaria: %@\n• Locale: %@",
                                                                                     ip, ispRaw, self.profile[@"CarrierMode"], self.profile[@"CarrierName"], tz, self.profile[@"localeID"]]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
            return;
        }

        NSString *plat = [self.bundleID isEqualToString:@"com.burbn.instagram"] ? @"INSTAGRAM" : @"REDDIT";
        NSString *alias = self.profile[@"customAlias"] ?: self.profile[@"containerName"];
        NSString *contEnc = [alias stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"Default";
        NSString *ispEnc = [ispRaw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
        NSString *vpsUrlStr = [NSString stringWithFormat:@"%@?ip=%@&contenedor=%@&plataforma=%@&choicy=1&bssid=%@&isp=%@&cc=%@",
                               VPS_AUDIT_URL, ip, contEnc, plat, self.profile[@"bssid"] ?: @"", ispEnc, cc];

        [[session dataTaskWithURL:[NSURL URLWithString:vpsUrlStr] completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
            NSDictionary *vpsJson = vData ? [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil] : nil;
            NSString *msj = ([vpsJson isKindOfClass:[NSDictionary class]] && vpsJson[@"mensaje_iphone"])
                ? vpsJson[@"mensaje_iphone"]
                : [NSString stringWithFormat:@"IP: %@ (%@)\nSincronizado localmente.", ip, ispRaw];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Auditoría Proxy Center + Telegram" message:msj preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
        }] resume];
    }] resume];
}

@end
