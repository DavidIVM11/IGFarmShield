#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <spawn.h>

extern char **environ;

#define STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CHOICY_PLIST_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define CHOICY_PLIST_VAR @"/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define VPS_AUDIT_URL @"http://162.35.105.151:5001/iphone_audit"
#define CURRENT_SCHEMA_VERSION 9

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

static BOOL nodeMentionsString(id node, NSString *needle) {
    if (!node || !needle) return NO;
    if ([node isKindOfClass:[NSString class]]) {
        return [(NSString *)node rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
    }
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)node;
        for (id k in d) {
            if (nodeMentionsString(k, needle) || nodeMentionsString(d[k], needle)) return YES;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) {
            if (nodeMentionsString(item, needle)) return YES;
        }
    }
    return NO;
}

static void parseCraneNodeForApp(id node, NSMutableDictionary *outContainers, NSString **outActiveID) {
    if (!node) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;

        for (NSString *ak in @[@"activeContainer", @"selectedContainer", @"currentContainer", @"activeContainerIdentifier", @"active", @"defaultContainer"]) {
            if ([dict[ak] isKindOfClass:[NSString class]] && [dict[ak] length] > 0 && outActiveID && !(*outActiveID)) {
                *outActiveID = dict[ak];
            }
        }

        NSString *cID = nil;
        NSString *cName = nil;
        for (NSString *ik in @[@"identifier", @"id", @"UUID", @"uuid", @"containerIdentifier", @"craneIdentifier"]) {
            if ([dict[ik] isKindOfClass:[NSString class]] && [dict[ik] length] > 0) { cID = dict[ik]; break; }
        }
        for (NSString *nk in @[@"name", @"displayName", @"label", @"title", @"containerName"]) {
            if ([dict[nk] isKindOfClass:[NSString class]] && [dict[nk] length] > 0) { cName = dict[nk]; break; }
        }
        if (cID && cName) {
            outContainers[cID] = cName;
        }

        for (id k in dict) {
            NSString *kStr = [k description];
            id val = dict[k];
            if ([val isKindOfClass:[NSDictionary class]]) {
                NSDictionary *sub = (NSDictionary *)val;
                for (NSString *nk in @[@"name", @"displayName", @"label", @"title", @"containerName"]) {
                    if ([sub[nk] isKindOfClass:[NSString class]] && [sub[nk] length] > 0) {
                        outContainers[kStr] = sub[nk];
                    }
                }
            } else if ([val isKindOfClass:[NSString class]]) {
                NSString *vStr = (NSString *)val;
                if (kStr.length >= 8 && [kStr containsString:@"-"] && vStr.length > 0 && vStr.length < 40 && ![vStr containsString:@"/"]) {
                    outContainers[kStr] = vStr;
                }
            }
            if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                parseCraneNodeForApp(val, outContainers, outActiveID);
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) {
            parseCraneNodeForApp(item, outContainers, outActiveID);
        }
    }
}

static NSString *findCraneNameByID(id node, NSString *targetID) {
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
                NSString *found = findCraneNameByID(val, targetID);
                if (found) return found;
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) {
            NSString *found = findCraneNameByID(item, targetID);
            if (found) return found;
        }
    }
    return nil;
}

// ============================================================================
// INTERFACES DE NAVEGACIÓN (ESTILO GHOST / CRANE)
// ============================================================================
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
- (NSMutableDictionary *)ensureProfileForBundle:(NSString *)bundleID uuid:(NSString *)uuid craneID:(NSString *)craneID defaultName:(NSString *)dName path:(NSString *)path forceRotate:(BOOL)rotate;
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
// NIVEL 1: MENÚ PRINCIPAL (IGFarmShield v9.0)
// ============================================================================
@implementation IGFarmRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"IGFarmShield v9.0";

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
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64.0;
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
    if (!choicy) {
        CFDictionaryRef cfDict = CFPreferencesCopyMultiple(NULL, CFSTR("com.opa334.choicyprefs"), CFSTR("mobile"), kCFPreferencesAnyHost);
        if (cfDict) choicy = CFBridgingRelease(cfDict);
    }

    NSDictionary *appSettings = [choicy[@"appSettings"] isKindOfClass:[NSDictionary class]] ? choicy[@"appSettings"] : @{};
    BOOL igOK = ([appSettings[@"com.burbn.instagram"] isKindOfClass:[NSDictionary class]] && [appSettings[@"com.burbn.instagram"] count] > 0);
    BOOL rdOK = ([appSettings[@"com.reddit.Reddit"] isKindOfClass:[NSDictionary class]] && [appSettings[@"com.reddit.Reddit"] count] > 0);

    self.choicyAllSafe = (igOK && rdOK);
    if (igOK && rdOK) {
        self.choicySummary = @"🟢 Seguro • Instagram y Reddit protegidos";
    } else if (igOK || rdOK) {
        self.choicySummary = [NSString stringWithFormat:@"🟡 Parcial • IG: %@ | Reddit: %@", igOK ? @"OK" : @"Pendiente", rdOK ? @"OK" : @"Pendiente"];
    } else {
        self.choicySummary = @"🟠 Escudo interno activo • Toca para ver resumen";
    }

    self.choicyDetailReport = [NSString stringWithFormat:
        @"1. Filtro Choicy en Instagram: %@\n"
        @"2. Filtro Choicy en Reddit: %@\n"
        @"3. Ocultación de Jailbreak (/var/jb): Activa\n"
        @"4. Ocultación de librerías en memoria: Activa",
        igOK ? @"✅ Activo" : @"⚠️ No configurado",
        rdOK ? @"✅ Activo" : @"⚠️ No configurado"];
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

- (NSMutableDictionary *)ensureProfileForBundle:(NSString *)bundleID uuid:(NSString *)uuid craneID:(NSString *)craneID defaultName:(NSString *)dName path:(NSString *)path forceRotate:(BOOL)rotate {
    if (!bundleID) bundleID = @"com.burbn.instagram";
    if (!uuid || uuid.length == 0) uuid = craneID ?: @"Default";
    if (!craneID || craneID.length == 0) craneID = uuid;

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
        [byUUID[uuid][@"schemaVersion"] intValue] == CURRENT_SCHEMA_VERSION) {
        profile = [byUUID[uuid] mutableCopy];
    }

    NSString *cleanCraneName = (dName && dName.length > 0) ? dName : @"Default";

    if (!profile || !profile[@"idfv"] || rotate) {
        BOOL wasEnabled = (profile && profile[@"enabled"] != nil) ? [profile[@"enabled"] boolValue] : YES;

        uint64_t seed = fnv1aHashPrefs(uuid) ^ (((uint64_t)arc4random() << 32) | arc4random());
        NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59", @"f0:9f:c2", @"04:d6:aa"];
        NSArray *ssidPrefixes = @[@"HomeWiFi", @"ATT-Fiber", @"Xfinity-WiFi", @"SpectrumSetup", @"NETGEAR", @"TP-Link"];
        NSArray *subnets = @[@"192.168.1", @"192.168.0", @"10.0.0", @"192.168.50", @"172.16.0"];
        NSArray *osBuilds = @[@"20G75", @"20G81", @"20H19", @"20H30", @"20F66"];

        NSString *oui = ouis[seed % ouis.count];
        NSString *ssidPref = ssidPrefixes[(seed >> 3) % ssidPrefixes.count];
        NSString *subnet = subnets[(seed >> 5) % subnets.count];
        NSString *osBuild = osBuilds[(seed >> 7) % osBuilds.count];

        NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x",
                           oui, (unsigned int)((seed >> 8) & 0xFF), (unsigned int)((seed >> 16) & 0xFF), (unsigned int)((seed >> 24) & 0xFF)];
        NSString *ssid = [NSString stringWithFormat:@"%@-%02X-5G", ssidPref, (unsigned int)(seed & 0xFF)];
        NSString *localIP = [NSString stringWithFormat:@"%@.%d", subnet, 15 + (int)(seed % 220)];
        unsigned long long freeBytes = ((14800ULL + (seed % 31500ULL)) * 1024ULL * 1024ULL) + ((seed >> 12) % 1048576ULL);

        // Si Crane tiene "Use Container Identifier" activo, respetamos el UUID de Crane como base y generamos los complementarios
        NSString *shieldIDFV = ([craneID containsString:@"-"] && craneID.length >= 32 && !rotate)
            ? [craneID uppercaseString]
            : [[NSUUID UUID] UUIDString];

        profile = [@{
            @"schemaVersion": @(CURRENT_SCHEMA_VERSION),
            @"containerUUID": uuid,
            @"craneIdentifier": craneID,
            @"containerName": cleanCraneName,
            @"bundleID": bundleID,
            @"path": path ?: @"",
            @"enabled": @(wasEnabled),
            @"spoofIDs": @YES,
            @"spoofNetwork": @YES,
            @"spoofLocation": @YES,
            @"spoofHardware": @YES,
            @"spoofSecurity": @YES,
            @"locationAnchored": @(self.state[@"last_ip"] != nil),
            @"deviceModel": @"iPhone10,4",
            @"osBuild": osBuild,
            @"deviceName": [NSString stringWithFormat:@"iPhone-%02X", (unsigned int)(seed & 0xFF)],
            @"craneOriginalIDFV": craneID,
            @"idfv": shieldIDFV,
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
            @"lastSyncedIP": self.state[@"last_ip"] ?: @"Pendiente de sincronizar",
            @"ispName": self.state[@"last_isp"] ?: @"ISP",
            @"cityCountry": self.state[@"last_city_country"] ?: @"Toca Sincronizar con IP",
            @"timeZone": self.state[@"defaultTimeZone"] ?: @"America/New_York",
            @"localeID": self.state[@"defaultLocale"] ?: @"en_US",
            @"CarrierMode": self.state[@"defaultCarrierMode"] ?: @"WIFI_ONLY",
            @"CarrierName": self.state[@"defaultCarrierName"] ?: @"ISP",
            @"CarrierMCC": self.state[@"defaultCarrierMCC"] ?: @"310",
            @"CarrierMNC": self.state[@"defaultCarrierMNC"] ?: @"260",
            @"CarrierISO": self.state[@"defaultCarrierISO"] ?: @"us"
        } mutableCopy];
    } else {
        profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
        profile[@"containerUUID"] = uuid;
        profile[@"craneIdentifier"] = craneID;
        profile[@"containerName"] = cleanCraneName;
        profile[@"bundleID"] = bundleID;
        profile[@"deviceModel"] = @"iPhone10,4";
        if (path.length > 0) profile[@"path"] = path;
    }

    [self saveProfile:profile forUUID:uuid];
    return profile;
}

- (void)scanAndSyncAllContainers {
    self.igContainersList = [NSMutableArray array];
    self.redditContainersList = [NSMutableArray array];
    NSMutableSet *seenUUIDs = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Leer la base de datos de Crane desde CFPreferences (com.opa334.crane) y todos los plists de Crane en disco
    NSMutableArray *craneSources = [NSMutableArray array];
    for (NSString *domain in @[@"com.opa334.crane", @"com.opa334.craneprefs"]) {
        CFDictionaryRef cfDict = CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)domain, CFSTR("mobile"), kCFPreferencesAnyHost);
        if (cfDict) {
            NSDictionary *d = CFBridgingRelease(cfDict);
            if ([d count] > 0) [craneSources addObject:d];
        }
        NSDictionary *ud = [[[NSUserDefaults alloc] initWithSuiteName:domain] dictionaryRepresentation];
        if ([ud count] > 0) [craneSources addObject:ud];
    }

    NSArray *prefDirs = @[
        @"/var/mobile/Library/Preferences",
        @"/var/jb/var/mobile/Library/Preferences",
        @"/var/mobile/Library/Application Support/Crane",
        @"/var/jb/var/mobile/Library/Application Support/Crane"
    ];
    for (NSString *pDir in prefDirs) {
        NSArray *files = [fm subpathsOfDirectoryAtPath:pDir error:nil];
        for (NSString *f in files) {
            if ([[f lowercaseString] containsString:@"crane"] && [f hasSuffix:@".plist"]) {
                NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[pDir stringByAppendingPathComponent:f]];
                if ([d isKindOfClass:[NSDictionary class]] && [d count] > 0) {
                    [craneSources addObject:d];
                }
            }
        }
    }

    NSMutableDictionary *igCraneMap = [NSMutableDictionary dictionary];
    NSMutableDictionary *rdCraneMap = [NSMutableDictionary dictionary];
    NSString *igActiveCraneID = nil;
    NSString *rdActiveCraneID = nil;

    for (NSDictionary *src in craneSources) {
        for (id k in src) {
            NSString *kStr = [k description];
            id val = src[k];
            if ([kStr rangeOfString:@"com.burbn.instagram" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                nodeMentionsString(val, @"com.burbn.instagram")) {
                parseCraneNodeForApp(val, igCraneMap, &igActiveCraneID);
            }
            if ([kStr rangeOfString:@"com.reddit.Reddit" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                nodeMentionsString(val, @"com.reddit.Reddit")) {
                parseCraneNodeForApp(val, rdCraneMap, &rdActiveCraneID);
            }
        }
    }

    // 2. Escanear todas las carpetas en /var/mobile/Containers/Data/Application
    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:appsDir error:nil];

    for (NSString *folderUUID in uuids) {
        NSString *fullPath = [appsDir stringByAppendingPathComponent:folderUUID];
        NSString *metaPath = [fullPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        if (![meta isKindOfClass:[NSDictionary class]]) continue;

        BOOL isIG = nodeMentionsString(meta, @"com.burbn.instagram");
        BOOL isRD = nodeMentionsString(meta, @"com.reddit.Reddit");
        if (!isIG && !isRD) continue;

        NSString *bundleID = isIG ? @"com.burbn.instagram" : @"com.reddit.Reddit";
        NSMutableDictionary *craneMap = isIG ? igCraneMap : rdCraneMap;

        NSString *craneID = meta[@"MCMMetadataUUID"] ?: folderUUID;
        NSString *detectedName = nil;

        for (NSString *rk in @[@"com.opa334.crane.container.name", @"craneContainerName"]) {
            if ([meta[rk] isKindOfClass:[NSString class]] && [meta[rk] length] > 0) detectedName = meta[rk];
        }
        for (NSString *ik in @[@"com.opa334.crane.container.identifier", @"com.opa334.crane.container.id", @"craneContainerIdentifier"]) {
            if ([meta[ik] isKindOfClass:[NSString class]] && [meta[ik] length] > 0) craneID = meta[ik];
        }

        NSDictionary *userInfo = meta[@"MCMMetadataUserInfo"];
        if ([userInfo isKindOfClass:[NSDictionary class]] && [userInfo count] > 0) {
            for (NSString *k in userInfo) {
                NSString *kl = [k lowercaseString];
                id val = userInfo[k];
                if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
                    if ([kl containsString:@"name"]) detectedName = val;
                    else if (([kl containsString:@"id"] || [kl containsString:@"crane"] || [kl containsString:@"container"]) && ![val isEqualToString:bundleID]) {
                        craneID = val;
                    }
                }
            }
        }

        if (!detectedName && craneMap[craneID]) detectedName = craneMap[craneID];
        if (!detectedName && craneMap[folderUUID]) detectedName = craneMap[folderUUID];

        if (!detectedName) {
            for (NSDictionary *src in craneSources) {
                detectedName = findCraneNameByID(src, craneID);
                if (detectedName) break;
                detectedName = findCraneNameByID(src, folderUUID);
                if (detectedName) break;
            }
        }

        if (!detectedName || detectedName.length == 0) {
            if (!userInfo || [userInfo count] == 0 || [craneID caseInsensitiveCompare:@"default"] == NSOrderedSame) {
                detectedName = @"Default";
            } else {
                detectedName = craneID;
            }
        }

        craneMap[craneID] = detectedName;
        NSMutableDictionary *prof = [self ensureProfileForBundle:bundleID uuid:craneID craneID:craneID defaultName:detectedName path:fullPath forceRotate:NO];
        [seenUUIDs addObject:craneID];
        [seenUUIDs addObject:folderUUID];

        if (isIG) [self.igContainersList addObject:prof];
        else [self.redditContainersList addObject:prof];

        // Escanear subcarpetas si Crane anida contenedores dentro de la carpeta principal
        for (NSString *subFolder in @[@"___Crane_Containers", @"Library/Application Support/Crane/Containers", @"Library/Crane/Containers"]) {
            NSString *subDir = [fullPath stringByAppendingPathComponent:subFolder];
            if ([fm fileExistsAtPath:subDir]) {
                NSArray *subItems = [fm contentsOfDirectoryAtPath:subDir error:nil];
                for (NSString *subID in subItems) {
                    if ([seenUUIDs containsObject:subID]) continue;
                    NSString *subPath = [subDir stringByAppendingPathComponent:subID];
                    NSString *subName = craneMap[subID] ?: subID;
                    NSMutableDictionary *subProf = [self ensureProfileForBundle:bundleID uuid:subID craneID:subID defaultName:subName path:subPath forceRotate:NO];
                    [seenUUIDs addObject:subID];
                    if (isIG) [self.igContainersList addObject:subProf];
                    else [self.redditContainersList addObject:subProf];
                }
            }
        }
    }

    // 3. Escanear directorios dedicados de Crane (/var/mobile/Library/Application Support/Crane/Containers/<bundleID>)
    for (NSString *base in @[@"/var/mobile/Library/Application Support/Crane/Containers", @"/var/jb/var/mobile/Library/Application Support/Crane/Containers"]) {
        for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
            NSString *appCraneDir = [base stringByAppendingPathComponent:bID];
            if (![fm fileExistsAtPath:appCraneDir]) continue;
            BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
            NSMutableDictionary *craneMap = isIG ? igCraneMap : rdCraneMap;
            NSMutableArray *targetList = isIG ? self.igContainersList : self.redditContainersList;

            NSArray *cDirs = [fm contentsOfDirectoryAtPath:appCraneDir error:nil];
            for (NSString *cID in cDirs) {
                if ([seenUUIDs containsObject:cID]) continue;
                NSString *cPath = [appCraneDir stringByAppendingPathComponent:cID];
                NSString *cName = craneMap[cID];
                if (!cName) {
                    for (NSDictionary *src in craneSources) {
                        cName = findCraneNameByID(src, cID);
                        if (cName) break;
                    }
                }
                if (!cName) cName = cID;
                NSMutableDictionary *prof = [self ensureProfileForBundle:bID uuid:cID craneID:cID defaultName:cName path:cPath forceRotate:NO];
                [targetList addObject:prof];
                [seenUUIDs addObject:cID];
            }
        }
    }

    // 4. Agregar cualquier contenedor de Crane listado en sus preferencias aunque aún no se haya abierto
    for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
        BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
        NSMutableDictionary *craneMap = isIG ? igCraneMap : rdCraneMap;
        NSMutableArray *targetList = isIG ? self.igContainersList : self.redditContainersList;

        for (NSString *cID in craneMap) {
            if ([seenUUIDs containsObject:cID]) continue;
            NSString *cName = craneMap[cID];
            NSMutableDictionary *prof = [self ensureProfileForBundle:bID uuid:cID craneID:cID defaultName:cName path:@"" forceRotate:NO];
            [targetList addObject:prof];
            [seenUUIDs addObject:cID];
        }
    }

    // 5. Incluir contenedores auto-registrados en tiempo de ejecución por Tweak.x
    NSDictionary *savedByUUID = self.state[@"containersByUUID"];
    if ([savedByUUID isKindOfClass:[NSDictionary class]]) {
        for (NSString *uKey in savedByUUID) {
            if ([seenUUIDs containsObject:uKey]) continue;
            NSDictionary *p = savedByUUID[uKey];
            if (![p isKindOfClass:[NSDictionary class]] || [p[@"schemaVersion"] intValue] != CURRENT_SCHEMA_VERSION) continue;
            NSString *bID = p[@"bundleID"];
            if ([bID isEqualToString:@"com.burbn.instagram"]) {
                [self.igContainersList addObject:[p mutableCopy]];
                [seenUUIDs addObject:uKey];
            } else if ([bID isEqualToString:@"com.reddit.Reddit"]) {
                [self.redditContainersList addObject:[p mutableCopy]];
                [seenUUIDs addObject:uKey];
            }
        }
    }

    NSMutableDictionary *activeMap = [self.state[@"activeInCrane"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"activeInCrane"] mutableCopy]
        : [NSMutableDictionary dictionary];
    if (igActiveCraneID) activeMap[@"com.burbn.instagram"] = igActiveCraneID;
    if (rdActiveCraneID) activeMap[@"com.reddit.Reddit"] = rdActiveCraneID;
    self.state[@"activeInCrane"] = activeMap;
    [self saveState];
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
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Limpieza Completada"
                                                                    message:[NSString stringWithFormat:@"• Instagram y Reddit cerrados.\n• %lu archivos temporales eliminados.\n• Portapapeles limpio.", (unsigned long)removedCount]
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

#pragma mark - TableView Nivel 1

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"1. CONTROL GENERAL DEL ESCUDO";
    if (section == 1) return @"2. APLICACIONES Y CONTENEDORES DE CRANE";
    if (section == 2) return @"3. RED EN VIVO Y ESTADO DE SEGURIDAD";
    return @"4. MANTENIMIENTO RÁPIDO (64 GB)";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (section == 1) return 2;
    if (section == 2) return 2;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL masterOn = [self.state[@"masterEnabled"] boolValue];

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;

        if (indexPath.row == 0) {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = @"Habilitar IGFarmShield";
            cell.detailTextLabel.text = masterOn ? @"🟢 Activo • Complemento de aislamiento para Crane" : @"⚪ Desactivado";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = masterOn;
            sw.tag = 10;
            [sw addTarget:self action:@selector(toggleRootSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            BOOL excl = [self.state[@"exclusiveMode"] boolValue];
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
            cell.textLabel.text = @"Modo Exclusivo (1 Contenedor a la vez)";
            cell.detailTextLabel.text = excl ? @"🔒 Al activar un contenedor se apagan los demás y cierra la app" : @"🔓 Múltiples contenedores activos simultáneos";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = excl;
            sw.tag = 11;
            [sw addTarget:self action:@selector(toggleRootSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
        NSDictionary *activeMap = self.state[@"activeInCrane"];

        if (indexPath.row == 0) {
            NSString *actID = activeMap[@"com.burbn.instagram"];
            NSString *actName = @"Toca para ver contenedores";
            for (NSDictionary *p in self.igContainersList) {
                if ([p[@"containerUUID"] isEqualToString:actID] || [p[@"craneIdentifier"] isEqualToString:actID] || [p[@"containerName"] isEqualToString:actID]) {
                    actName = [NSString stringWithFormat:@"🎯 Activo en Crane: %@", p[@"containerName"]];
                    break;
                }
            }
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = [NSString stringWithFormat:@"📸 Instagram (%lu Contenedores)", (unsigned long)self.igContainersList.count];
            cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            cell.detailTextLabel.text = actName;
        } else {
            NSString *actID = activeMap[@"com.reddit.Reddit"];
            NSString *actName = @"Toca para ver contenedores";
            for (NSDictionary *p in self.redditContainersList) {
                if ([p[@"containerUUID"] isEqualToString:actID] || [p[@"craneIdentifier"] isEqualToString:actID] || [p[@"containerName"] isEqualToString:actID]) {
                    actName = [NSString stringWithFormat:@"🎯 Activo en Crane: %@", p[@"containerName"]];
                    break;
                }
            }
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = [NSString stringWithFormat:@"🤖 Reddit (%lu Contenedores)", (unsigned long)self.redditContainersList.count];
            cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            cell.detailTextLabel.text = actName;
        }
        return cell;
    }

    if (indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;

        if (indexPath.row == 0) {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"🌐 Red Saliente Actual (Toca para actualizar)";
            NSString *vpnTxt = self.vpnActive ? [NSString stringWithFormat:@"🟢 VPN (%@)", self.vpnInterfaceName] : @"⚠️ Red Directa";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • IP: %@\nISP: %@ • Zona: %@",
                                         vpnTxt,
                                         self.state[@"last_ip"] ?: @"Consultando...",
                                         self.state[@"last_isp"] ?: @"...",
                                         self.state[@"defaultTimeZone"] ?: @"..."];
        } else {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"🛡️ Estado de Seguridad y Choicy";
            cell.detailTextLabel.textColor = self.choicyAllSafe ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
            cell.detailTextLabel.text = self.choicySummary;
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.textLabel.textColor = [UIColor systemRedColor];
    cell.textLabel.text = @"🧹 Cerrar Apps y Limpiar Caché Temporal";
    cell.detailTextLabel.text = self.residualSummary;
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

    if (indexPath.section == 1) {
        IGFarmAppContainersController *appVC = [[IGFarmAppContainersController alloc] init];
        appVC.parentRoot = self;
        if (indexPath.row == 0) {
            appVC.bundleID = @"com.burbn.instagram";
            appVC.appTitle = @"📸 Instagram";
            appVC.appStateKey = @"enableIG";
            appVC.containers = self.igContainersList;
        } else {
            appVC.bundleID = @"com.reddit.Reddit";
            appVC.appTitle = @"🤖 Reddit";
            appVC.appStateKey = @"enableReddit";
            appVC.containers = self.redditContainersList;
        }
        [self.navigationController pushViewController:appVC animated:YES];
        return;
    }

    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            [self detectCurrentNetworkSilently:NO];
        } else {
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🛡️ Estado de Seguridad"
                                                                        message:self.choicyDetailReport
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        }
        return;
    }

    if (indexPath.section == 3) {
        [self cleanResidualTracesAndKillApps:YES];
    }
}

- (void)detectCurrentNetworkSilently:(BOOL)silent {
    NSURL *url = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,country,countryCode,regionName,city,timezone,isp,mobile,query"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 6.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]] || ![json[@"status"] isEqualToString:@"success"]) return;

        NSString *ip = json[@"query"] ?: @"Desconocida";
        NSString *ispRaw = json[@"isp"] ?: @"ISP";
        NSString *ispUp = [ispRaw uppercaseString];
        NSString *cc = [json[@"countryCode"] lowercaseString] ?: @"us";
        NSString *city = json[@"city"] ?: @"";
        NSString *region = json[@"regionName"] ?: @"";
        NSString *tz = json[@"timezone"] ?: @"America/New_York";
        BOOL isMobileISP = [json[@"mobile"] boolValue];

        self.state[@"last_ip"] = ip;
        self.state[@"last_isp"] = [NSString stringWithFormat:@"%@ (%@)", ispRaw, [cc uppercaseString]];
        self.state[@"last_city_country"] = [NSString stringWithFormat:@"%@, %@ (%@)", city, region, [cc uppercaseString]];
        self.state[@"defaultTimeZone"] = tz;
        self.state[@"defaultLocale"] = [NSString stringWithFormat:@"en_%@", [cc uppercaseString]];

        if ([ispUp containsString:@"T-MOBILE"] || [ispUp containsString:@"METRO"] || [ispUp containsString:@"MINT"]) {
            self.state[@"defaultCarrierMode"] = @"CELLULAR"; self.state[@"defaultCarrierName"] = @"T-Mobile";
            self.state[@"defaultCarrierMCC"] = @"310"; self.state[@"defaultCarrierMNC"] = @"260"; self.state[@"defaultCarrierISO"] = cc;
        } else if ([ispUp containsString:@"AT&T"] || [ispUp containsString:@"CRICKET"]) {
            self.state[@"defaultCarrierMode"] = @"CELLULAR"; self.state[@"defaultCarrierName"] = @"AT&T";
            self.state[@"defaultCarrierMCC"] = @"310"; self.state[@"defaultCarrierMNC"] = @"410"; self.state[@"defaultCarrierISO"] = cc;
        } else if ([ispUp containsString:@"VERIZON"] || [ispUp containsString:@"VISIBLE"]) {
            self.state[@"defaultCarrierMode"] = @"CELLULAR"; self.state[@"defaultCarrierName"] = @"Verizon";
            self.state[@"defaultCarrierMCC"] = @"311"; self.state[@"defaultCarrierMNC"] = @"480"; self.state[@"defaultCarrierISO"] = cc;
        } else if (isMobileISP) {
            self.state[@"defaultCarrierMode"] = @"CELLULAR"; self.state[@"defaultCarrierName"] = ispRaw;
            self.state[@"defaultCarrierMCC"] = @"310"; self.state[@"defaultCarrierMNC"] = @"260"; self.state[@"defaultCarrierISO"] = cc;
        } else {
            self.state[@"defaultCarrierMode"] = @"WIFI_ONLY"; self.state[@"defaultCarrierName"] = ispRaw;
            self.state[@"defaultCarrierMCC"] = @""; self.state[@"defaultCarrierMNC"] = @""; self.state[@"defaultCarrierISO"] = cc;
        }
        [self saveState];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self calculateResidualTraces];
            [self.tableView reloadData];
            if (!silent) {
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Red Saliente Detectada"
                                                                            message:[NSString stringWithFormat:@"• IP Pública: %@\n• ISP: %@\n• Ubicación: %@, %@ (%@)\n• Zona Horaria: %@",
                                                                                     ip, ispRaw, city, region, [cc uppercaseString], tz]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            }
        });
    }] resume];
}

@end

// ============================================================================
// NIVEL 2: LISTA DE CONTENEDORES DE LA APLICACIÓN (ESTILO GHOST / CRANE)
// ============================================================================
@implementation IGFarmAppContainersController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.appTitle;
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 66.0;
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
    if (section == 0) return @"INTERRUPTOR DE LA APLICACIÓN";
    return [NSString stringWithFormat:@"CONTENEDORES EN CRANE (%lu) — TOCA UNO PARA VER SU FINGERPRINT", (unsigned long)self.containers.count];
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
        cell.textLabel.text = [NSString stringWithFormat:@"Habilitar Escudo en %@", self.appTitle];
        cell.detailTextLabel.text = (masterOn && appOn) ? @"🟢 Activo para los contenedores habilitados" : @"⚪ Desactivado";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = appOn;
        sw.enabled = masterOn;
        [sw addTarget:self action:@selector(toggleAppMaster:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (self.containers.count == 0) {
        UITableViewCell *empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        empty.textLabel.text = @"No se encontraron contenedores";
        empty.detailTextLabel.text = @"Abre la aplicación en tu contenedor de Crane para sincronizarlo";
        return empty;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;

    NSMutableDictionary *prof = self.containers[indexPath.row];
    NSString *uuid = prof[@"containerUUID"] ?: @"Default";
    NSString *craneID = prof[@"craneIdentifier"] ?: uuid;
    NSString *cName = prof[@"containerName"] ?: @"Default";
    BOOL contOn = prof[@"enabled"] ? [prof[@"enabled"] boolValue] : YES;

    NSDictionary *activeMap = self.parentRoot.state[@"activeInCrane"];
    NSString *activeID = activeMap[self.bundleID];
    BOOL isCurrentInCrane = ([activeID isEqualToString:uuid] || [activeID isEqualToString:craneID] || [activeID isEqualToString:cName]);

    cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
    cell.textLabel.text = isCurrentInCrane
        ? [NSString stringWithFormat:@"🎯 %@ (Activo en Crane)", cName]
        : [NSString stringWithFormat:@"📦 %@", cName];

    NSString *shortCraneID = (craneID.length > 13) ? [craneID substringToIndex:13] : craneID;
    NSString *tz = prof[@"timeZone"] ?: @"Sin sincronizar";
    NSString *ip = prof[@"lastSyncedIP"] ?: @"Sin IP";

    if (masterOn && appOn && contOn) {
        cell.detailTextLabel.textColor = [UIColor systemGreenColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 ON • Container ID: %@...\nIP: %@ • %@", shortCraneID, ip, tz];
    } else {
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"⚪ En pausa • Container ID: %@...", shortCraneID];
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
// NIVEL 3: SPOOFING Y FINGERPRINT ESTRUCTURADO DEL CONTENEDOR
// ============================================================================
@implementation IGFarmContainerDetailController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64.0;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSMutableDictionary *fresh = [self.parentRoot profileForUUID:self.containerUUID];
    if (fresh) self.profile = fresh;
    self.title = self.profile[@"containerName"] ?: @"Contenedor";
    [self.tableView reloadData];
}

- (void)saveCurrentProfile {
    if (self.parentRoot && self.profile && self.containerUUID) {
        [self.parentRoot saveProfile:self.profile forUUID:self.containerUUID];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"1. ESTADO Y SINCRONIZACIÓN CON LA IP EN VIVO";
        case 1: return @"2. OPCIONES DE SPOOFING (ACTIVA O DESACTIVA)";
        case 2: return @"3. FINGERPRINT ASIGNADO A ESTE CONTENEDOR";
        case 3: return @"4. ROTACIÓN DE FINGERPRINT";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 3;
        case 1: return 5;
        case 2: return 6;
        case 3: return 1;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL contOn = self.profile[@"enabled"] ? [self.profile[@"enabled"] boolValue] : YES;

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;

        if (indexPath.row == 0) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = @"Habilitar Escudo en este Contenedor";
            cell.detailTextLabel.text = contOn ? @"🟢 Activo • Aplicando Fingerprint en la app" : @"⚪ En pausa";
            cell.detailTextLabel.textColor = contOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = contOn;
            sw.tag = 100;
            [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.text = @"⚡ Sincronizar con la IP Actual en Vivo";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Asigna ISP, País y Zona Horaria de tu IP actual (%@)",
                                         self.profile[@"lastSyncedIP"] ?: @"Sin sincronizar"];
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.text = @"🔍 Auditar IP en Proxy Center (Telegram)";
            cell.detailTextLabel.text = @"Verifica en tu servidor si la IP actual está limpia o en cooldown";
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;

        NSArray *titles = @[
            @"1. Identificadores del Sistema",
            @"2. Red Local y Ocultación de VPN",
            @"3. Ubicación de Red (Hora e Idioma por IP)",
            @"4. Hardware iPhone 8 (Disco, Batería y Audio)",
            @"5. Ocultación de Jailbreak y Crane"
        ];
        NSArray *subtitles = @[
            @"Complementa el ID de Crane aislando BootUUID y el token de iCloud",
            @"Asigna una IP doméstica y router propios; oculta el túnel utun del VPN",
            @"Sincroniza el huso horario y el idioma del contenedor con los datos de la IP",
            @"Aísla gigabytes libres en disco, porcentaje de batería, volumen y arranque",
            @"Impide que la app detecte /var/jb, palera1n o librerías inyectadas"
        ];
        NSArray *keys = @[@"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity"];

        cell.textLabel.font = [UIFont boldSystemFontOfSize:14.5];
        cell.textLabel.text = titles[indexPath.row];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = subtitles[indexPath.row];

        UISwitch *sw = [[UISwitch alloc] init];
        NSString *k = keys[indexPath.row];
        sw.on = (self.profile[k] == nil) ? YES : [self.profile[k] boolValue];
        sw.enabled = contOn;
        sw.tag = 200 + indexPath.row;
        [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:13.5];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = contOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];

        double freeGB = [self.profile[@"freeBytes"] unsignedLongLongValue] / (1024.0*1024.0*1024.0);
        int batPct = (int)([self.profile[@"batteryLevel"] floatValue] * 100.0f);
        int volPct = (int)([self.profile[@"audioVolume"] floatValue] * 100.0f);
        NSUInteger upMin = [self.profile[@"uptimeOffset"] unsignedIntegerValue] / 60;
        NSString *craneID = self.profile[@"craneIdentifier"] ?: self.containerUUID;

        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = @"📦 Identidad Base de Crane";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Container Name: %@\nContainer ID:   %@",
                                             self.profile[@"containerName"] ?: @"Default", craneID];
                break;
            case 1:
                cell.textLabel.text = @"🔑 Identificadores Complementarios (Sistema)";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"IDFV:     %@\nBootUUID: %@\niCloud:   %@",
                                             self.profile[@"idfv"] ?: @"N/A",
                                             self.profile[@"bootSessionUUID"] ?: @"N/A",
                                             self.profile[@"cloudUUID"] ?: @"N/A"];
                break;
            case 2:
                cell.textLabel.text = @"🌐 Red e ISP Sincronizado con la IP";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"IP Actual: %@\nISP:       %@\nTipo Red:  %@",
                                             self.profile[@"lastSyncedIP"] ?: @"Sin sincronizar",
                                             self.profile[@"ispName"] ?: @"ISP",
                                             [self.profile[@"CarrierMode"] isEqualToString:@"CELLULAR"] ? @"Datos Móviles 4G LTE" : @"ISP Residencial / Fijo"];
                break;
            case 3:
                cell.textLabel.text = @"🌎 Ubicación Asignada al Contenedor";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Región:       %@\nZona Horaria: %@\nIdioma/País:  %@",
                                             self.profile[@"cityCountry"] ?: @"Toca Sincronizar con IP",
                                             self.profile[@"timeZone"] ?: @"America/New_York",
                                             self.profile[@"localeID"] ?: @"en_US"];
                break;
            case 4:
                cell.textLabel.text = @"📡 Red Doméstica Aislada (LAN y Router)";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"IP Local (en0): %@\nWi-Fi SSID:     %@\nRouter BSSID:   %@",
                                             self.profile[@"localIP"] ?: @"",
                                             self.profile[@"ssid"] ?: @"",
                                             self.profile[@"bssid"] ?: @""];
                break;
            case 5:
                cell.textLabel.text = @"📱 Hardware iPhone 8 (iPhone10,4)";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Disco Libre: %.2f GB de 64 GB (Build %@)\nBatería:     %d%% • Volumen: %d%% • Uptime: +%lu min",
                                             freeGB, self.profile[@"osBuild"] ?: @"20G81", batPct, volPct, (unsigned long)upMin];
                break;
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.textColor = [UIColor systemRedColor];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.textLabel.text = @"🔄 Regenerar Métricas Complementarias";
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

    if (indexPath.section == 0) {
        if (indexPath.row == 1) [self syncWithLiveIPAndAuditVPS:NO];
        else if (indexPath.row == 2) [self syncWithLiveIPAndAuditVPS:YES];
        return;
    }

    if (indexPath.section == 3 && indexPath.row == 0) {
        self.profile = [self.parentRoot ensureProfileForBundle:self.bundleID
                                                          uuid:self.containerUUID
                                                       craneID:self.profile[@"craneIdentifier"]
                                                   defaultName:self.profile[@"containerName"]
                                                          path:self.profile[@"path"]
                                                   forceRotate:YES];
        [self.tableView reloadData];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Fingerprint Renovado"
                                                                    message:@"Se generaron nuevas métricas complementarias conservando intacto el Container ID de Crane."
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

- (void)syncWithLiveIPAndAuditVPS:(BOOL)sendToVPS {
    NSURL *ipUrl = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,country,countryCode,regionName,city,timezone,isp,mobile,query"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 6.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:ipUrl completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Error de Conexión" message:@"No se pudo leer la IP actual." preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
            return;
        }

        NSDictionary *ipJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![ipJson isKindOfClass:[NSDictionary class]] || ![ipJson[@"status"] isEqualToString:@"success"]) return;

        NSString *ip = ipJson[@"query"] ?: @"";
        NSString *ispRaw = ipJson[@"isp"] ?: @"ISP";
        NSString *ispUp = [ispRaw uppercaseString];
        NSString *cc = [ipJson[@"countryCode"] lowercaseString] ?: @"us";
        NSString *city = ipJson[@"city"] ?: @"";
        NSString *region = ipJson[@"regionName"] ?: @"";
        NSString *tz = ipJson[@"timezone"] ?: @"America/New_York";
        BOOL isMobileISP = [ipJson[@"mobile"] boolValue];

        self.profile[@"locationAnchored"] = @YES;
        self.profile[@"lastSyncedIP"] = ip;
        self.profile[@"ispName"] = ispRaw;
        self.profile[@"cityCountry"] = [NSString stringWithFormat:@"%@, %@ (%@)", city, region, [cc uppercaseString]];
        self.profile[@"timeZone"] = tz;
        self.profile[@"localeID"] = [NSString stringWithFormat:@"en_%@", [cc uppercaseString]];

        if ([ispUp containsString:@"T-MOBILE"] || [ispUp containsString:@"METRO"] || [ispUp containsString:@"MINT"]) {
            self.profile[@"CarrierMode"] = @"CELLULAR"; self.profile[@"CarrierName"] = @"T-Mobile";
            self.profile[@"CarrierMCC"] = @"310"; self.profile[@"CarrierMNC"] = @"260"; self.profile[@"CarrierISO"] = cc;
        } else if ([ispUp containsString:@"AT&T"] || [ispUp containsString:@"CRICKET"]) {
            self.profile[@"CarrierMode"] = @"CELLULAR"; self.profile[@"CarrierName"] = @"AT&T";
            self.profile[@"CarrierMCC"] = @"310"; self.profile[@"CarrierMNC"] = @"410"; self.profile[@"CarrierISO"] = cc;
        } else if ([ispUp containsString:@"VERIZON"] || [ispUp containsString:@"VISIBLE"]) {
            self.profile[@"CarrierMode"] = @"CELLULAR"; self.profile[@"CarrierName"] = @"Verizon";
            self.profile[@"CarrierMCC"] = @"311"; self.profile[@"CarrierMNC"] = @"480"; self.profile[@"CarrierISO"] = cc;
        } else if (isMobileISP) {
            self.profile[@"CarrierMode"] = @"CELLULAR"; self.profile[@"CarrierName"] = ispRaw;
            self.profile[@"CarrierMCC"] = @"310"; self.state[@"defaultCarrierMNC"] = @"260"; self.profile[@"CarrierISO"] = cc;
        } else {
            self.profile[@"CarrierMode"] = @"WIFI_ONLY"; self.profile[@"CarrierName"] = ispRaw;
            self.profile[@"CarrierMCC"] = @""; self.profile[@"CarrierMNC"] = @""; self.profile[@"CarrierISO"] = cc;
        }

        [self saveCurrentProfile];

        if (!sendToVPS) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"IP y Ubicación Sincronizadas"
                                                                            message:[NSString stringWithFormat:@"• Contenedor: %@\n• IP: %@\n• ISP: %@\n• Ubicación fijada: %@, %@ (%@)\n• Zona Horaria: %@",
                                                                                     self.profile[@"containerName"], ip, ispRaw, city, region, [cc uppercaseString], tz]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
            return;
        }

        NSString *plat = [self.bundleID isEqualToString:@"com.burbn.instagram"] ? @"INSTAGRAM" : @"REDDIT";
        NSString *cName = self.profile[@"containerName"] ?: @"Default";
        NSString *contEnc = [cName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"Default";
        NSString *ispEnc = [ispRaw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
        NSString *vpsUrlStr = [NSString stringWithFormat:@"%@?ip=%@&contenedor=%@&plataforma=%@&choicy=1&bssid=%@&isp=%@&cc=%@",
                               VPS_AUDIT_URL, ip, contEnc, plat, self.profile[@"bssid"] ?: @"", ispEnc, cc];

        [[session dataTaskWithURL:[NSURL URLWithString:vpsUrlStr] completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
            NSDictionary *vpsJson = vData ? [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil] : nil;
            NSString *msj = ([vpsJson isKindOfClass:[NSDictionary class]] && vpsJson[@"mensaje_iphone"])
                ? vpsJson[@"mensaje_iphone"]
                : [NSString stringWithFormat:@"IP: %@ (%@)\nUbicación sincronizada en el contenedor.", ip, ispRaw];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Auditoría Proxy Center" message:msj preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
        }] resume];
    }] resume];
}

@end
