#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <spawn.h>

extern char **environ;

#define STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CRANE_PREFS_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_PREFS_VAR @"/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_MAIN_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define CRANE_MAIN_VAR @"/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define CHOICY_PLIST_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define CHOICY_PLIST_VAR @"/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define VPS_AUDIT_URL @"http://162.35.105.151:5001/iphone_audit"
#define CURRENT_SCHEMA_VERSION 12

@interface PSViewController : UIViewController
@end

@class IGFarmRootListController;

static uint64_t randomSeedPrefs64(NSString *input) {
    uint64_t hash = 14695981039346656037ULL;
    const char *bytes = [input UTF8String];
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

static void parseCraneNodeIntoMap(id node, NSMutableDictionary *outContainers) {
    if (!node || !outContainers) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;

        for (NSString *ak in @[@"activeContainer", @"selectedContainer", @"currentContainer", @"activeContainerIdentifier", @"active", @"defaultContainer"]) {
            if ([dict[ak] isKindOfClass:[NSString class]] && [dict[ak] length] > 0 && !outContainers[@"__ACTIVE_ID__"]) {
                outContainers[@"__ACTIVE_ID__"] = dict[ak];
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
        if (cID && cName) outContainers[cID] = cName;

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
                parseCraneNodeIntoMap(val, outContainers);
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) {
            parseCraneNodeIntoMap(item, outContainers);
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

@interface IGFarmRootListController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableDictionary *state;
@property (nonatomic, strong) NSMutableArray *igContainersList;
@property (nonatomic, strong) NSMutableArray *redditContainersList;
@property (nonatomic, assign) BOOL vpnActive;
@property (nonatomic, strong) NSString *vpnInterfaceName;
@property (nonatomic, strong) NSString *realLocalIP;
@property (nonatomic, strong) NSString *realFreeDisk;
@property (nonatomic, assign) int realBatteryPct;
@property (nonatomic, assign) int realVolumePct;
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
- (void)toggleRootSwitch:(UISwitch *)sender;
- (NSString *)enforceExclusiveModeAutomatic;
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
- (void)toggleAppMaster:(UISwitch *)sender;
- (void)toggleContainerRowSwitch:(UISwitch *)sender;
@end

@interface IGFarmContainerDetailController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSString *bundleID;
@property (nonatomic, strong) NSString *containerUUID;
@property (nonatomic, strong) NSMutableDictionary *profile;
@property (nonatomic, weak) IGFarmRootListController *parentRoot;
@property (nonatomic, strong) UITableView *tableView;
- (void)saveCurrentProfile;
- (BOOL)isModOn:(NSString *)key;
- (void)toggleSwitch:(UISwitch *)sender;
- (void)showNetworkCoherenceSelector;
- (void)refreshPurePhoneTelemetryWithPopup;
- (void)syncWithLiveIPAndAuditVPS:(BOOL)sendToVPS;
@end

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
    if (!choicy) choicy = [[[NSUserDefaults alloc] initWithSuiteName:@"com.opa334.choicyprefs"] dictionaryRepresentation];

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
        @"3. Apple DeviceCheck (Login Reddit): Permitido\n"
        @"4. Ocultación de Jailbreak (/var/jb): Activa",
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

- (NSString *)enforceExclusiveModeAutomatic {
    NSDictionary *activeMap = self.state[@"activeInCrane"];
    NSMutableArray *keptNames = [NSMutableArray array];

    for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
        BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
        NSMutableArray *list = isIG ? self.igContainersList : self.redditContainersList;
        if (list.count == 0) continue;

        NSString *preferredID = activeMap[bID];
        NSString *chosenUUID = nil;

        for (NSMutableDictionary *p in list) {
            if ([p[@"containerUUID"] isEqualToString:preferredID] ||
                [p[@"craneIdentifier"] isEqualToString:preferredID] ||
                [p[@"containerName"] isEqualToString:preferredID]) {
                chosenUUID = p[@"containerUUID"];
                break;
            }
        }
        if (!chosenUUID) {
            for (NSMutableDictionary *p in list) {
                if ([p[@"enabled"] boolValue]) {
                    chosenUUID = p[@"containerUUID"];
                    break;
                }
            }
        }
        if (!chosenUUID) {
            chosenUUID = list.firstObject[@"containerUUID"];
        }

        for (NSMutableDictionary *p in list) {
            NSString *u = p[@"containerUUID"];
            BOOL keepOn = [u isEqualToString:chosenUUID];
            p[@"enabled"] = @(keepOn);
            [self saveProfile:p forUUID:u];
            if (keepOn) {
                [keptNames addObject:[NSString stringWithFormat:@"%@: %@", isIG ? @"IG" : @"Reddit", p[@"containerName"] ?: @"Default"]];
            }
        }
    }

    killAppProcess(@"Instagram");
    killAppProcess(@"Reddit");
    return [keptNames componentsJoinedByString:@"\n• "];
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
        if ([disk isKindOfClass:[NSDictionary class]] && [disk[@"containerUUID"] isEqualToString:uuid] && disk[@"idfv"]) {
            profile = [disk mutableCopy];
        }
    }
    if (!profile && [byUUID[uuid] isKindOfClass:[NSDictionary class]] && byUUID[uuid][@"idfv"]) {
        profile = [byUUID[uuid] mutableCopy];
    }

    NSString *cleanCraneName = (dName && dName.length > 0) ? dName : @"Default";

    if (!profile || !profile[@"idfv"] || rotate) {
        BOOL wasEnabled = (profile && profile[@"enabled"] != nil) ? [profile[@"enabled"] boolValue] : YES;

        uint64_t seed = randomSeedPrefs64(uuid);
        NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59", @"f0:9f:c2", @"04:d6:aa"];
        NSArray *ssidPrefixes = @[@"HomeWiFi", @"ATT-Fiber", @"Xfinity-WiFi", @"SpectrumSetup", @"NETGEAR", @"TP-Link"];
        NSArray *subnets = @[@"192.168.1", @"192.168.0", @"10.0.0", @"192.168.50", @"172.16.0", @"192.168.10"];

        NSString *oui = ouis[seed % ouis.count];
        NSString *ssidPref = ssidPrefixes[(seed >> 3) % ssidPrefixes.count];
        NSString *subnet = subnets[(seed >> 5) % subnets.count];

        NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x",
                           oui, (unsigned int)((seed >> 8) & 0xFF), (unsigned int)((seed >> 16) & 0xFF), (unsigned int)((seed >> 24) & 0xFF)];
        NSString *ssid = [NSString stringWithFormat:@"%@-%02X-5G", ssidPref, (unsigned int)(seed & 0xFF)];
        NSString *localIP = [NSString stringWithFormat:@"%@.%d", subnet, 12 + (int)(seed % 230)];
        NSString *cellIP = [NSString stringWithFormat:@"100.%d.%d.%d", 64 + (int)(seed % 30), 1 + (int)((seed >> 4) % 250), 2 + (int)((seed >> 8) % 250)];
        unsigned long long freeBytes = ((14200ULL + (seed % 32000ULL)) * 1024ULL * 1024ULL) + ((seed >> 12) % 1048576ULL);

        // Si no es rotación forzada y Crane ya dio un UUID válido, lo conserva para evitar error de Keychain en Reddit
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
            @"spoofIDs": profile[@"spoofIDs"] ?: @YES,
            @"spoofNetwork": profile[@"spoofNetwork"] ?: @YES,
            @"spoofLocation": profile[@"spoofLocation"] ?: @YES,
            @"spoofHardware": profile[@"spoofHardware"] ?: @YES,
            @"spoofSecurity": profile[@"spoofSecurity"] ?: @YES,
            @"locationAnchored": @(self.state[@"last_ip"] != nil),
            @"deviceModel": @"iPhone10,4",
            @"craneOriginalIDFV": craneID,
            @"idfv": shieldIDFV,
            @"shieldDeviceID": [[NSUUID UUID] UUIDString],
            @"bootSessionUUID": [[NSUUID UUID] UUIDString],
            @"cloudUUID": [[NSUUID UUID] UUIDString],
            @"bssid": bssid,
            @"ssid": ssid,
            @"localIP": localIP,
            @"cellularIP": cellIP,
            @"freeBytes": @(freeBytes),
            @"uptimeOffset": @(1800 + (NSUInteger)(seed % 82000)),
            @"batteryLevel": @(0.28f + ((seed % 64) / 100.0f)),
            @"brightness": @(0.25f + (((seed >> 4) % 65) / 100.0f)),
            @"audioVolume": @(0.18f + (((seed >> 6) % 72) / 100.0f)),
            @"pasteboardCount": @(4 + (seed % 95)),
            @"lastSyncedIP": profile[@"lastSyncedIP"] ?: (self.state[@"last_ip"] ?: @"Pendiente de sincronizar"),
            @"ispName": profile[@"ispName"] ?: (self.state[@"last_isp"] ?: @"ISP"),
            @"cityCountry": profile[@"cityCountry"] ?: (self.state[@"last_city_country"] ?: @"Toca Sincronizar con IP"),
            @"timeZone": profile[@"timeZone"] ?: (self.state[@"defaultTimeZone"] ?: @"America/New_York"),
            @"localeID": profile[@"localeID"] ?: (self.state[@"defaultLocale"] ?: @"en_US"),
            @"CarrierMode": profile[@"CarrierMode"] ?: (self.state[@"defaultCarrierMode"] ?: @"CELLULAR"),
            @"CarrierName": profile[@"CarrierName"] ?: (self.state[@"defaultCarrierName"] ?: @"T-Mobile"),
            @"CarrierMCC": profile[@"CarrierMCC"] ?: (self.state[@"defaultCarrierMCC"] ?: @"310"),
            @"CarrierMNC": profile[@"CarrierMNC"] ?: (self.state[@"defaultCarrierMNC"] ?: @"260"),
            @"CarrierISO": profile[@"CarrierISO"] ?: (self.state[@"defaultCarrierISO"] ?: @"us")
        } mutableCopy];
    } else {
        if (!profile[@"cellularIP"]) {
            uint64_t s = randomSeedPrefs64(uuid);
            profile[@"cellularIP"] = [NSString stringWithFormat:@"100.%d.%d.%d", 64 + (int)(s % 30), 1 + (int)((s >> 4) % 250), 2 + (int)((s >> 8) % 250)];
        }
        profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
        profile[@"containerUUID"] = uuid;
        profile[@"craneIdentifier"] = craneID;
        profile[@"containerName"] = cleanCraneName;
        profile[@"bundleID"] = bundleID;
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

    NSMutableArray *craneSources = [NSMutableArray array];
    for (NSString *domain in @[@"com.opa334.crane", @"com.opa334.craneprefs"]) {
        NSDictionary *ud = [[[NSUserDefaults alloc] initWithSuiteName:domain] dictionaryRepresentation];
        if ([ud count] > 0) [craneSources addObject:ud];
    }
    for (NSString *pPath in @[CRANE_PREFS_JB, CRANE_PREFS_VAR, CRANE_MAIN_JB, CRANE_MAIN_VAR]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:pPath];
        if ([d count] > 0) [craneSources addObject:d];
    }

    NSMutableDictionary *igCraneMap = [NSMutableDictionary dictionary];
    NSMutableDictionary *rdCraneMap = [NSMutableDictionary dictionary];

    for (NSDictionary *src in craneSources) {
        for (id k in src) {
            NSString *kStr = [k description];
            id val = src[k];
            if ([kStr rangeOfString:@"com.burbn.instagram" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                nodeMentionsString(val, @"com.burbn.instagram")) {
                parseCraneNodeIntoMap(val, igCraneMap);
            }
            if ([kStr rangeOfString:@"com.reddit.Reddit" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                nodeMentionsString(val, @"com.reddit.Reddit")) {
                parseCraneNodeIntoMap(val, rdCraneMap);
            }
        }
    }

    NSString *igActiveCraneID = igCraneMap[@"__ACTIVE_ID__"];
    NSString *rdActiveCraneID = rdCraneMap[@"__ACTIVE_ID__"];
    [igCraneMap removeObjectForKey:@"__ACTIVE_ID__"];
    [rdCraneMap removeObjectForKey:@"__ACTIVE_ID__"];

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

        NSMutableDictionary *prof = [self ensureProfileForBundle:bundleID uuid:folderUUID craneID:craneID defaultName:detectedName path:fullPath forceRotate:NO];
        [seenUUIDs addObject:folderUUID];
        [seenUUIDs addObject:craneID];

        if (isIG) [self.igContainersList addObject:prof];
        else [self.redditContainersList addObject:prof];
    }

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
    self.realLocalIP = @"192.168.1.x";

    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    float rawBat = [UIDevice currentDevice].batteryLevel;
    self.realBatteryPct = (rawBat > 0) ? (int)(rawBat * 100.0f) : 75;
    self.realVolumePct = (int)([[AVAudioSession sharedInstance] outputVolume] * 100.0f);

    NSDictionary *fsAttr = [[NSFileManager defaultManager] attributesOfFileSystemForPath:@"/var/mobile" error:nil];
    unsigned long long freeBytes = [fsAttr[NSFileSystemFreeSize] unsignedLongLongValue];
    self.realFreeDisk = [NSString stringWithFormat:@"%.2f GB libres", (double)freeBytes / (1024.0*1024.0*1024.0)];

    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        struct ifaddrs *temp = interfaces;
        while (temp != NULL) {
            if (temp->ifa_addr && temp->ifa_addr->sa_family == AF_INET && (temp->ifa_flags & IFF_UP)) {
                NSString *ifName = [NSString stringWithUTF8String:temp->ifa_name];
                char addrBuf[INET_ADDRSTRLEN];
                inet_ntop(AF_INET, &((struct sockaddr_in *)temp->ifa_addr)->sin_addr, addrBuf, INET_ADDRSTRLEN);
                NSString *ipStr = [NSString stringWithUTF8String:addrBuf];
                if ([ifName isEqualToString:@"en0"] && ipStr) {
                    self.realLocalIP = ipStr;
                } else if ([ifName hasPrefix:@"utun"] || [ifName hasPrefix:@"ppp"] || [ifName hasPrefix:@"ipsec"]) {
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
                                                                    message:[NSString stringWithFormat:@"• Instagram y Reddit cerrados.\n• %lu archivos temporales eliminados.\n• Portapapeles vaciado.", (unsigned long)removedCount]
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

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
            cell.detailTextLabel.text = masterOn ? @"🟢 Activo • Aislamiento de huella por contenedor" : @"⚪ Desactivado";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = masterOn;
            sw.tag = 10;
            [sw addTarget:self action:@selector(toggleRootSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            BOOL excl = [self.state[@"exclusiveMode"] boolValue];
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
            cell.textLabel.text = @"Modo Exclusivo Automático (1 Contenedor)";
            cell.detailTextLabel.text = excl ? @"🔒 Deja 1 solo contenedor activo automáticamente y apaga los demás" : @"🔓 Múltiples contenedores activos simultáneos";
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

        if (indexPath.row == 0) {
            NSUInteger onCount = 0;
            NSString *activeName = @"Ninguno";
            for (NSDictionary *p in self.igContainersList) {
                if ([p[@"enabled"] boolValue]) {
                    onCount++;
                    activeName = p[@"containerName"] ?: @"Default";
                }
            }
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = [NSString stringWithFormat:@"📸 Instagram (%lu Contenedores)", (unsigned long)self.igContainersList.count];
            cell.detailTextLabel.textColor = (onCount > 0) ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            cell.detailTextLabel.text = (onCount == 1)
                ? [NSString stringWithFormat:@"🎯 Exclusivo activo: %@", activeName]
                : [NSString stringWithFormat:@"🟢 %lu contenedores con escudo activo", (unsigned long)onCount];
        } else {
            NSUInteger onCount = 0;
            NSString *activeName = @"Ninguno";
            for (NSDictionary *p in self.redditContainersList) {
                if ([p[@"enabled"] boolValue]) {
                    onCount++;
                    activeName = p[@"containerName"] ?: @"Default";
                }
            }
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = [NSString stringWithFormat:@"🤖 Reddit (%lu Contenedores)", (unsigned long)self.redditContainersList.count];
            cell.detailTextLabel.textColor = (onCount > 0) ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            cell.detailTextLabel.text = (onCount == 1)
                ? [NSString stringWithFormat:@"🎯 Exclusivo activo: %@", activeName]
                : [NSString stringWithFormat:@"🟢 %lu contenedores con escudo activo", (unsigned long)onCount];
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
    if (sender.tag == 10) {
        self.state[@"masterEnabled"] = @(sender.isOn);
        [self saveState];
        killAppProcess(@"Instagram");
        killAppProcess(@"Reddit");
        [self.tableView reloadData];
    } else if (sender.tag == 11) {
        self.state[@"exclusiveMode"] = @(sender.isOn);
        [self saveState];
        if (sender.isOn) {
            NSString *keptSummary = [self enforceExclusiveModeAutomatic];
            [self.tableView reloadData];
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔒 Modo Exclusivo Aplicado"
                                                                        message:[NSString stringWithFormat:@"Se desactivaron automáticamente los contenedores secundarios.\n\nContenedores activos ahora:\n• %@", keptSummary ?: @"Default"]
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"Entendido" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        } else {
            [self.tableView reloadData];
        }
    }
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
                                                                            message:[NSString stringWithFormat:@"• IP Pública: %@\n• ISP: %@\n• Modo Coherente: %@\n• Ubicación: %@, %@ (%@)\n• Zona Horaria: %@",
                                                                                     ip, ispRaw, [self.state[@"defaultCarrierMode"] isEqualToString:@"CELLULAR"] ? @"4G Móvil (Wi-Fi Oculto)" : @"Wi-Fi Residencial", city, region, [cc uppercaseString], tz]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            }
        });
    }] resume];
}

@end

@implementation IGFarmAppContainersController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.appTitle;
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
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
    return [NSString stringWithFormat:@"CONTENEDORES EN CRANE (%lu) — TOCA UNO PARA CONFIGURAR SU SPOOF", (unsigned long)self.containers.count];
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
        cell.detailTextLabel.text = (masterOn && appOn) ? @"🟢 Activo para los contenedores seleccionados" : @"⚪ Desactivado";
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

    NSString *shortIDFV = [prof[@"idfv"] length] >= 8 ? [prof[@"idfv"] substringToIndex:8] : prof[@"idfv"];
    BOOL isCell = [prof[@"CarrierMode"] isEqualToString:@"CELLULAR"];
    NSString *netDesc = isCell
        ? [NSString stringWithFormat:@"4G %@ (Sin Wi-Fi)", prof[@"CarrierName"] ?: @"LTE"]
        : [NSString stringWithFormat:@"Wi-Fi (%@)", prof[@"localIP"] ?: @"LAN"];
    int batPct = (int)([prof[@"batteryLevel"] floatValue] * 100.0f);

    if (masterOn && appOn && contOn) {
        cell.detailTextLabel.textColor = [UIColor systemGreenColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 ON • IDFV: %@... • %@\nIP: %@ • Bat: %d%%",
                                     shortIDFV, netDesc, prof[@"lastSyncedIP"] ?: @"Sincronizar", batPct];
    } else {
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"⚪ En pausa (Datos reales) • IDFV: %@...", shortIDFV];
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
    NSString *cName = targetProf[@"containerName"] ?: @"Contenedor";
    BOOL excl = [self.parentRoot.state[@"exclusiveMode"] boolValue];

    [self.parentRoot setContainer:targetUUID enabled:sender.isOn inBundle:self.bundleID];
    [self.tableView reloadData];

    if (sender.isOn && excl) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔒 Contenedor Exclusivo Activo"
                                                                    message:[NSString stringWithFormat:@"Se activó el escudo en \"%@\" y se apagaron automáticamente los demás contenedores de %@.", cName, self.appTitle]
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
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

@implementation IGFarmContainerDetailController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
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
        killAppProcess([self.bundleID isEqualToString:@"com.burbn.instagram"] ? @"Instagram" : @"Reddit");
    }
}

- (BOOL)isModOn:(NSString *)key {
    BOOL contOn = self.profile[@"enabled"] ? [self.profile[@"enabled"] boolValue] : YES;
    if (!contOn) return NO;
    return (self.profile[key] == nil) ? YES : [self.profile[key] boolValue];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"1. ESTADO, MODO DE RED Y SINCRONIZACIÓN IP";
        case 1: return @"2. OPCIONES DE SPOOFING (CON CONFIRMACIÓN EN VIVO)";
        case 2: return @"3. FINGERPRINT EN VIVO DE ESTE CONTENEDOR";
        case 3: return @"4. ACTUALIZAR DATOS PUROS DEL TELÉFONO Y ROTACIÓN";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 4;
        case 1: return 5;
        case 2: return 6;
        case 3: return 2;
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
            cell.detailTextLabel.text = contOn ? @"🟢 Activo • Inyectando Fingerprint aislado" : @"⚪ En pausa (Usando datos reales del iPhone)";
            cell.detailTextLabel.textColor = contOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = contOn;
            sw.tag = 100;
            [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"📶 Modo de Coherencia de Red (4G vs Wi-Fi)";
            BOOL isCell = [self.profile[@"CarrierMode"] isEqualToString:@"CELLULAR"];
            cell.detailTextLabel.textColor = [UIColor systemBlueColor];
            cell.detailTextLabel.text = isCell
                ? [NSString stringWithFormat:@"📱 Proxy Móvil 4G (%@) • Oculta Wi-Fi y usa interfaz pdp_ip0", self.profile[@"CarrierName"] ?: @"T-Mobile"]
                : [NSString stringWithFormat:@"🛜 Proxy Residencial Wi-Fi • Usa LAN %@ y Router %@", self.profile[@"localIP"], self.profile[@"ssid"]];
        } else if (indexPath.row == 2) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.text = @"⚡ Sincronizar con la IP Actual en Vivo";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Detecta automáticamente si tu IP es Móvil 4G o Wi-Fi Residencial (%@)",
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
            @"2. Coherencia de Red y Ocultación de VPN",
            @"3. Ubicación de Red (Hora e Idioma por IP)",
            @"4. Datos Puros del Teléfono (Batería, Volumen, Disco)",
            @"5. Ocultación de Jailbreak y Crane"
        ];
        NSArray *subtitles = @[
            @"Aísla IDFV (compatible con Keychain de Reddit) y BootSessionUUID",
            @"Si es Proxy Móvil apaga Wi-Fi y usa pdp_ip0; si es Residencial usa Wi-Fi LAN",
            @"Sincroniza huso horario y región del contenedor con los datos de tu IP",
            @"Aísla porcentaje de batería, volumen, brillo, gigabytes libres y arranque",
            @"Bloquea el escaneo de /var/jb, palera1n, Choicy y librerías en memoria"
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
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];

        double freeGB = [self.profile[@"freeBytes"] unsignedLongLongValue] / (1024.0*1024.0*1024.0);
        int batPct = (int)([self.profile[@"batteryLevel"] floatValue] * 100.0f);
        int volPct = (int)([self.profile[@"audioVolume"] floatValue] * 100.0f);
        int briPct = (int)([self.profile[@"brightness"] floatValue] * 100.0f);
        NSUInteger upMin = [self.profile[@"uptimeOffset"] unsignedIntegerValue] / 60;
        NSString *craneID = self.profile[@"craneIdentifier"] ?: self.containerUUID;

        switch (indexPath.row) {
            case 0: {
                cell.textLabel.text = @"📦 Identidad del Contenedor en Crane";
                cell.detailTextLabel.textColor = contOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Contenedor:   %@\nContainer ID: %@",
                                             self.profile[@"containerName"] ?: @"Default", craneID];
                break;
            }
            case 1: {
                BOOL on = [self isModOn:@"spoofIDs"];
                cell.textLabel.text = @"🔑 1. Identificadores del Sistema";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? [NSString stringWithFormat:@"🟢 SPOOF ACTIVO:\nIDFV:     %@\nBootUUID: %@",
                       self.profile[@"idfv"], self.profile[@"bootSessionUUID"]]
                    : @"⚪ DESACTIVADO (Exponiendo UUIDs nativos del sistema)";
                break;
            }
            case 2: {
                BOOL on = [self isModOn:@"spoofNetwork"];
                BOOL isCell = [self.profile[@"CarrierMode"] isEqualToString:@"CELLULAR"];
                cell.textLabel.text = @"📡 2. Interfaz de Red y Anti-VPN";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                if (!on) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"⚪ DESACTIVADO (Exponiendo IP real %@ y estado VPN)", self.parentRoot.realLocalIP ?: @"LAN"];
                } else if (isCell) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 MODO 4G MÓVIL PURO (Wi-Fi Apagado / VPN Oculto):\nInterfaz: pdp_ip0 (%@)\nOperadora: %@ 4G LTE (MCC %@ / MNC %@)",
                                                 self.profile[@"cellularIP"] ?: @"100.68.42.19",
                                                 self.profile[@"CarrierName"] ?: @"T-Mobile",
                                                 self.profile[@"CarrierMCC"] ?: @"310",
                                                 self.profile[@"CarrierMNC"] ?: @"260"];
                } else {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 MODO WI-FI RESIDENCIAL (VPN Oculto):\nIP LAN (en0): %@\nWi-Fi SSID:   %@\nRouter BSSID: %@",
                                                 self.profile[@"localIP"], self.profile[@"ssid"], self.profile[@"bssid"]];
                }
                break;
            }
            case 3: {
                BOOL on = [self isModOn:@"spoofLocation"];
                cell.textLabel.text = @"🌎 3. Ubicación de Red, ISP y Zona Horaria";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? [NSString stringWithFormat:@"🟢 SPOOF ACTIVO:\nIP / ISP:      %@ (%@)\nUbicación:     %@\nZona / Idioma: %@ (%@)",
                       self.profile[@"lastSyncedIP"] ?: @"Sincronizar", self.profile[@"ispName"] ?: @"ISP",
                       self.profile[@"cityCountry"] ?: @"USA", self.profile[@"timeZone"], self.profile[@"localeID"]]
                    : [NSString stringWithFormat:@"⚪ DESACTIVADO (Usando hora local %@)", [[NSTimeZone localTimeZone] name]];
                break;
            }
            case 4: {
                BOOL on = [self isModOn:@"spoofHardware"];
                cell.textLabel.text = @"🔋 4. Datos Puros del Teléfono (Sin tocar OS Build)";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? [NSString stringWithFormat:@"🟢 SPOOF ACTIVO (iPhone10,4 • iOS Nativo):\nBatería: %d%% (Desconectado) • Volumen: %d%% • Brillo: %d%%\nDisco Libre: %.2f GB • Uptime: +%lu min",
                       batPct, volPct, briPct, freeGB, (unsigned long)upMin]
                    : [NSString stringWithFormat:@"⚪ DESACTIVADO (Real: Bat %d%% • Vol %d%% • %@)",
                       self.parentRoot.realBatteryPct, self.parentRoot.realVolumePct, self.parentRoot.realFreeDisk ?: @"64GB"];
                break;
            }
            case 5: {
                BOOL on = [self isModOn:@"spoofSecurity"];
                cell.textLabel.text = @"🛡️ 5. Protocolo Anti-Leak (Jailbreak / Crane)";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? @"🟢 BLINDAJE ACTIVO:\ndyld / dladdr / /var/jb ocultos • DeviceCheck nativo para Reddit"
                    : @"⚪ DESACTIVADO (Rutas de Jailbreak visibles)";
                break;
            }
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    if (indexPath.row == 0) {
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.textLabel.text = @"🔋 Actualizar Datos Puros del Teléfono (Batería, Volumen, Disco)";
        cell.detailTextLabel.text = @"Renueva batería, volumen, brillo, espacio libre y uptime (mantiene iOS Build y IDFV intactos)";
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.textLabel.text = @"🔄 Regenerar Huella Completa del Contenedor";
        cell.detailTextLabel.text = @"Genera un nuevo IDFV, BootUUID, IP y telemetría desde cero";
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    return cell;
}

- (void)toggleSwitch:(UISwitch *)sender {
    if (sender.tag == 100) {
        [self.parentRoot setContainer:self.containerUUID enabled:sender.isOn inBundle:self.bundleID];
        self.profile[@"enabled"] = @(sender.isOn);
        [self.tableView reloadData];

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:sender.isOn ? @"🟢 Contenedor Protegido" : @"⚪ Contenedor en Pausa"
                                                                    message:sender.isOn ? @"Escudo activado para este contenedor." : @"Escudo pausado en este contenedor."
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    if (sender.tag >= 200) {
        NSInteger idx = sender.tag - 200;
        NSArray *keys = @[@"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity"];
        NSString *key = keys[idx];
        self.profile[key] = @(sender.isOn);

        uint64_t seed = randomSeedPrefs64(self.containerUUID);
        NSString *popupTitle = @"";
        NSString *popupMsg = @"";

        if (idx == 0) {
            popupTitle = sender.isOn ? @"🔑 Identificadores Aplicados" : @"⚪ Identificadores Desactivados";
            popupMsg = sender.isOn
                ? [NSString stringWithFormat:@"Aislamiento de IDs activo:\n\n• IDFV: %@\n• BootUUID: %@", self.profile[@"idfv"], self.profile[@"bootSessionUUID"]]
                : @"Usando UUIDs nativos del sistema.";
        } else if (idx == 1) {
            if (sender.isOn) {
                BOOL isCell = [self.profile[@"CarrierMode"] isEqualToString:@"CELLULAR"];
                if (isCell) {
                    self.profile[@"cellularIP"] = [NSString stringWithFormat:@"100.%d.%d.%d", 64 + (int)(seed % 30), 1 + (int)((seed >> 4) % 250), 2 + (int)((seed >> 8) % 250)];
                    popupTitle = @"📱 Modo 4G Móvil Puro Aplicado";
                    popupMsg = [NSString stringWithFormat:@"Coherencia con Proxy Móvil activada:\n\n• Wi-Fi Simulado: Apagado (NULL)\n• Interfaz Celular: pdp_ip0 (%@)\n• Operadora: %@ 4G LTE\n• Túnel VPN utun: Oculto",
                                self.profile[@"cellularIP"], self.profile[@"CarrierName"] ?: @"T-Mobile"];
                } else {
                    NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59", @"f0:9f:c2"];
                    NSArray *ssidPrefixes = @[@"HomeWiFi", @"ATT-Fiber", @"Xfinity-WiFi", @"SpectrumSetup", @"NETGEAR"];
                    NSArray *subnets = @[@"192.168.1", @"192.168.0", @"10.0.0", @"192.168.50"];
                    self.profile[@"bssid"] = [NSString stringWithFormat:@"%@:%02x:%02x:%02x",
                                              ouis[seed % ouis.count], (unsigned int)((seed >> 8) & 0xFF), (unsigned int)((seed >> 16) & 0xFF), (unsigned int)((seed >> 24) & 0xFF)];
                    self.profile[@"ssid"] = [NSString stringWithFormat:@"%@-%02X-5G", ssidPrefixes[(seed >> 3) % ssidPrefixes.count], (unsigned int)(seed & 0xFF)];
                    self.profile[@"localIP"] = [NSString stringWithFormat:@"%@.%d", subnets[(seed >> 5) % subnets.count], 12 + (int)(seed % 230)];
                    popupTitle = @"🛜 Modo Wi-Fi Residencial Aplicado";
                    popupMsg = [NSString stringWithFormat:@"Coherencia con Proxy Residencial activada:\n\n• IP LAN (en0): %@\n• Wi-Fi SSID: %@\n• Router BSSID: %@\n• Túnel VPN utun: Oculto",
                                self.profile[@"localIP"], self.profile[@"ssid"], self.profile[@"bssid"]];
                }
            } else {
                popupTitle = @"⚪ Spoof de Red Desactivado";
                popupMsg = @"Mostrando red real del teléfono.";
            }
        } else if (idx == 2) {
            popupTitle = sender.isOn ? @"🌎 Ubicación de Red Aplicada" : @"⚪ Ubicación de Red Desactivada";
            popupMsg = sender.isOn
                ? [NSString stringWithFormat:@"• Región: %@\n• Zona Horaria: %@\n• Idioma: %@", self.profile[@"cityCountry"], self.profile[@"timeZone"], self.profile[@"localeID"]]
                : @"Usando reloj e idioma reales del iPhone.";
        } else if (idx == 3) {
            if (sender.isOn) {
                [self refreshPurePhoneTelemetryValuesOnly];
                double freeGB = [self.profile[@"freeBytes"] unsignedLongLongValue] / (1024.0*1024.0*1024.0);
                int batPct = (int)([self.profile[@"batteryLevel"] floatValue] * 100.0f);
                int volPct = (int)([self.profile[@"audioVolume"] floatValue] * 100.0f);
                int briPct = (int)([self.profile[@"brightness"] floatValue] * 100.0f);
                popupTitle = @"🔋 Datos Puros del Teléfono Aplicados";
                popupMsg = [NSString stringWithFormat:@"Métricas renovadas (sin alterar el Build de iOS):\n\n• Batería: %d%%\n• Volumen: %d%%\n• Brillo: %d%%\n• Espacio Libre: %.2f GB",
                            batPct, volPct, briPct, freeGB];
            } else {
                popupTitle = @"⚪ Datos de Hardware Desactivados";
                popupMsg = @"Reportando batería, volumen y disco reales.";
            }
        } else if (idx == 4) {
            popupTitle = sender.isOn ? @"🛡️ Escudo Anti-Jailbreak Aplicado" : @"⚪ Escudo Anti-Jailbreak Desactivado";
            popupMsg = sender.isOn
                ? @"Rutas /var/jb, palera1n y librerías dyld/dladdr ocultas."
                : @"Filtro de rutas de Jailbreak desactivado.";
        }

        [self saveCurrentProfile];
        [self.tableView reloadData];

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:popupTitle
                                                                    message:popupMsg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

// Solo actualiza sensores puros (Batería, Volumen, Brillo, Disco, Uptime) SIN tocar osBuild
- (void)refreshPurePhoneTelemetryValuesOnly {
    uint64_t seed = randomSeedPrefs64(self.containerUUID);
    unsigned long long freeBytes = ((14200ULL + (seed % 32000ULL)) * 1024ULL * 1024ULL) + ((seed >> 12) % 1048576ULL);

    self.profile[@"batteryLevel"] = @(0.26f + ((seed % 66) / 100.0f));
    self.profile[@"audioVolume"] = @(0.15f + (((seed >> 6) % 75) / 100.0f));
    self.profile[@"brightness"] = @(0.22f + (((seed >> 4) % 68) / 100.0f));
    self.profile[@"freeBytes"] = @(freeBytes);
    self.profile[@"uptimeOffset"] = @(1800 + (NSUInteger)(seed % 82000));
    self.profile[@"pasteboardCount"] = @(4 + (seed % 95));
}

- (void)refreshPurePhoneTelemetryWithPopup {
    [self refreshPurePhoneTelemetryValuesOnly];
    [self saveCurrentProfile];
    [self.tableView reloadData];

    double freeGB = [self.profile[@"freeBytes"] unsignedLongLongValue] / (1024.0*1024.0*1024.0);
    int batPct = (int)([self.profile[@"batteryLevel"] floatValue] * 100.0f);
    int volPct = (int)([self.profile[@"audioVolume"] floatValue] * 100.0f);
    int briPct = (int)([self.profile[@"brightness"] floatValue] * 100.0f);
    NSUInteger upMin = [self.profile[@"uptimeOffset"] unsignedIntegerValue] / 60;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔋 Datos Puros del Teléfono Renovados"
                                                                message:[NSString stringWithFormat:@"Sensores actualizados en \"%@\" (conservando iOS Build nativo e IDFV):\n\n• Batería Simulada: %d%%\n• Volumen de Audio: %d%%\n• Brillo de Pantalla: %d%%\n• Espacio Libre: %.2f GB\n• Uptime / Arranque: +%lu min",
                                                                         self.profile[@"containerName"], batPct, volPct, briPct, freeGB, (unsigned long)upMin]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Perfecto" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showNetworkCoherenceSelector {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Modo de Coherencia de Red"
                                                                message:@"Elige según el tipo de Proxy que uses en este contenedor para no generar contradicciones:"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *presets = @[
        @{@"title": @"📱 Proxy Móvil 4G: T-Mobile US (Apaga Wi-Fi, usa pdp_ip0)", @"mode": @"CELLULAR", @"name": @"T-Mobile", @"mcc": @"310", @"mnc": @"260", @"iso": @"us"},
        @{@"title": @"📱 Proxy Móvil 4G: AT&T US (Apaga Wi-Fi, usa pdp_ip0)", @"mode": @"CELLULAR", @"name": @"AT&T", @"mcc": @"310", @"mnc": @"410", @"iso": @"us"},
        @{@"title": @"📱 Proxy Móvil 4G: Verizon US (Apaga Wi-Fi, usa pdp_ip0)", @"mode": @"CELLULAR", @"name": @"Verizon", @"mcc": @"311", @"mnc": @"480", @"iso": @"us"},
        @{@"title": @"🛜 Proxy Residencial / ISP Fijo (Activa Wi-Fi LAN en0)", @"mode": @"WIFI_ONLY", @"name": @"Wi-Fi", @"mcc": @"", @"mnc": @"", @"iso": @"us"}
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

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        if (indexPath.row == 1) [self showNetworkCoherenceSelector];
        else if (indexPath.row == 2) [self syncWithLiveIPAndAuditVPS:NO];
        else if (indexPath.row == 3) [self syncWithLiveIPAndAuditVPS:YES];
        return;
    }

    if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            [self refreshPurePhoneTelemetryWithPopup];
        } else {
            self.profile = [self.parentRoot ensureProfileForBundle:self.bundleID
                                                              uuid:self.containerUUID
                                                           craneID:self.profile[@"craneIdentifier"]
                                                       defaultName:self.profile[@"containerName"]
                                                              path:self.profile[@"path"]
                                                       forceRotate:YES];
            killAppProcess([self.bundleID isEqualToString:@"com.burbn.instagram"] ? @"Instagram" : @"Reddit");
            [self.tableView reloadData];
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔄 Huella Completa Regenerada"
                                                                        message:[NSString stringWithFormat:@"Nuevos datos asignados a \"%@\":\n\n• Nuevo IDFV: %@\n• Nueva IP LAN: %@\n• Nuevo Wi-Fi: %@ (%@)",
                                                                                 self.profile[@"containerName"], self.profile[@"idfv"], self.profile[@"localIP"], self.profile[@"ssid"], self.profile[@"bssid"]]
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        }
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
            self.profile[@"CarrierMCC"] = @"310"; self.profile[@"CarrierMNC"] = @"260"; self.profile[@"CarrierISO"] = cc;
        } else {
            self.profile[@"CarrierMode"] = @"WIFI_ONLY"; self.profile[@"CarrierName"] = ispRaw;
            self.profile[@"CarrierMCC"] = @""; self.profile[@"CarrierMNC"] = @""; self.profile[@"CarrierISO"] = cc;
        }

        [self saveCurrentProfile];

        if (!sendToVPS) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                BOOL isCell = [self.profile[@"CarrierMode"] isEqualToString:@"CELLULAR"];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"IP y Coherencia Sincronizadas"
                                                                            message:[NSString stringWithFormat:@"• Contenedor: %@\n• IP: %@\n• ISP: %@\n• Modo Aplicado: %@\n• Ubicación: %@, %@ (%@)\n• Zona Horaria: %@",
                                                                                     self.profile[@"containerName"], ip, ispRaw, isCell ? @"4G Móvil (Wi-Fi Apagado / pdp_ip0)" : @"Wi-Fi Residencial (en0)", city, region, [cc uppercaseString], tz]
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
