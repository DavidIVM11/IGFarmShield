#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>

#define STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CHOICY_PLIST @"/var/jb/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define CRANE_PLIST_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_PLIST_ROOT @"/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define VPS_AUDIT_URL @"http://162.35.105.151:5001/iphone_audit"

@interface PSViewController : UIViewController
@end

@class IGFarmRootListController;

// ============================================================================
// NIVEL 1: CONTROLADOR PRINCIPAL (SIEMPRE DE PRIMERO EN EL ARCHIVO)
// ============================================================================
@interface IGFarmRootListController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableDictionary *state;
@property (nonatomic, strong) NSMutableArray *igContainers;
@property (nonatomic, strong) NSMutableArray *redditContainers;
@property (nonatomic, assign) BOOL vpnActive;
@property (nonatomic, assign) BOOL choicySafe;
@property (nonatomic, strong) NSString *choicyStatusText;
@property (nonatomic, strong) NSString *vpnInterfaceName;
@property (nonatomic, strong) NSString *realLocalIP;
@property (nonatomic, strong) NSString *realHardwareModel;
@property (nonatomic, strong) NSString *realFreeDisk;
@property (nonatomic, strong) NSString *realTimeZone;
@property (nonatomic, assign) int realBatteryPct;
- (void)saveState;
- (void)refreshRealPhoneTelemetry;
- (void)scanAllRealContainersOnDisk;
- (BOOL)auditChoicyConfiguration;
- (void)syncCurrentNetworkSilently:(BOOL)silent;
- (void)purgeContainersCache;
- (void)showAlert:(NSString *)title msg:(NSString *)msg;
- (NSMutableDictionary *)ensureProfileForKey:(NSString *)profileKey containerName:(NSString *)cName path:(NSString *)cPath forceRotate:(BOOL)rotate;
@end

// ============================================================================
// NIVEL 2: LISTA DE CONTENEDORES DE UNA APP (INSTAGRAM O REDDIT)
// ============================================================================
@interface IGFarmAppContainersController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSString *appTitle;
@property (nonatomic, strong) NSString *bundleID;
@property (nonatomic, strong) NSString *stateKey;
@property (nonatomic, assign) BOOL isIG;
@property (nonatomic, strong) NSMutableDictionary *state;
@property (nonatomic, strong) NSMutableArray *appContainers;
@property (nonatomic, weak) IGFarmRootListController *parentRoot;
@property (nonatomic, strong) UITableView *tableView;
@end

// ============================================================================
// NIVEL 3: PANEL DE CONFIGURACIÓN Y HUELLA DE UN CONTENEDOR
// ============================================================================
@interface IGFarmContainerDetailController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSDictionary *containerItem;
@property (nonatomic, strong) NSMutableDictionary *profile;
@property (nonatomic, assign) BOOL isIG;
@property (nonatomic, weak) IGFarmRootListController *parentRoot;
@property (nonatomic, strong) UITableView *tableView;
@end

static uint64_t fnv1aHashPrefs(NSString *input) {
    uint64_t hash = 14695981039346656037ULL;
    const char *bytes = [input UTF8String];
    if (!bytes) return arc4random();
    while (*bytes) {
        hash ^= (uint8_t)(*bytes++);
        hash *= 1099511628211ULL;
    }
    return hash ^ ((uint64_t)arc4random() << 32) ^ arc4random();
}

// ============================================================================
// IMPLEMENTACIÓN NIVEL 1: MENÚ RAÍZ (IGFARMSHIELD)
// ============================================================================
@implementation IGFarmRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"IGFarmShield";

    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    self.state = loaded ? [loaded mutableCopy] : [NSMutableDictionary dictionary];
    if (!self.state[@"masterEnabled"]) self.state[@"masterEnabled"] = @YES;
    if (!self.state[@"enableIG"]) self.state[@"enableIG"] = @YES;
    if (!self.state[@"enableReddit"]) self.state[@"enableReddit"] = @YES;
    if (!self.state[@"profilesByContainer"]) self.state[@"profilesByContainer"] = [NSMutableDictionary dictionary];
    [self saveState];

    [self auditChoicyConfiguration];
    [self refreshRealPhoneTelemetry];
    [self scanAllRealContainersOnDisk];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    [self syncCurrentNetworkSilently:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    if (loaded) self.state = [loaded mutableCopy];
    [self auditChoicyConfiguration];
    [self refreshRealPhoneTelemetry];
    [self scanAllRealContainersOnDisk];
    [self.tableView reloadData];
}

- (void)saveState {
    [self.state writeToFile:STATE_PLIST atomically:YES];
}

- (BOOL)auditChoicyConfiguration {
    NSDictionary *choicy = [NSDictionary dictionaryWithContentsOfFile:CHOICY_PLIST];
    if (!choicy) {
        self.choicySafe = NO;
        self.choicyStatusText = @"No detectado";
        return NO;
    }
    NSDictionary *appSettings = choicy[@"appSettings"];
    if (appSettings[@"com.burbn.instagram"] || appSettings[@"com.reddit.Reddit"]) {
        self.choicySafe = YES;
        self.choicyStatusText = @"Activo (Whitelist OK)";
        return YES;
    }
    self.choicySafe = NO;
    self.choicyStatusText = @"Configurar Whitelist";
    return NO;
}

- (void)refreshRealPhoneTelemetry {
    size_t size = 0;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    if (size > 0) {
        char *machine = malloc(size);
        sysctlbyname("hw.machine", machine, &size, NULL, 0);
        self.realHardwareModel = [NSString stringWithUTF8String:machine] ?: @"iPhone";
        free(machine);
    } else {
        self.realHardwareModel = @"iPhone";
    }

    self.realTimeZone = [[NSTimeZone localTimeZone] name] ?: @"America/New_York";

    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    float rawBat = [UIDevice currentDevice].batteryLevel;
    self.realBatteryPct = (rawBat > 0) ? (int)(rawBat * 100.0f) : 75;

    NSDictionary *fsAttr = [[NSFileManager defaultManager] attributesOfFileSystemForPath:@"/var/mobile" error:nil];
    unsigned long long freeBytes = [fsAttr[NSFileSystemFreeSize] unsignedLongLongValue];
    unsigned long long totalBytes = [fsAttr[NSFileSystemSize] unsignedLongLongValue];
    self.realFreeDisk = [NSString stringWithFormat:@"%.1f GB libres de %.0f GB",
                         (double)freeBytes / (1024.0*1024.0*1024.0),
                         (double)totalBytes / (1024.0*1024.0*1024.0)];

    self.vpnActive = NO;
    self.vpnInterfaceName = @"Inactivo";
    self.realLocalIP = @"Sin Wi-Fi";

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
                    if (ipStr && ![ipStr hasPrefix:@"127."] && ![ipStr hasPrefix:@"169.254."]) {
                        self.vpnActive = YES;
                        self.vpnInterfaceName = [NSString stringWithFormat:@"%@ (%@)", ifName, ipStr];
                    }
                }
            }
            temp = temp->ifa_next;
        }
        freeifaddrs(interfaces);
    }
}

- (NSMutableDictionary *)ensureProfileForKey:(NSString *)profileKey containerName:(NSString *)cName path:(NSString *)cPath forceRotate:(BOOL)rotate {
    NSMutableDictionary *allProfiles = [self.state[@"profilesByContainer"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"profilesByContainer"] mutableCopy]
        : [NSMutableDictionary dictionary];

    NSMutableDictionary *profile = nil;
    if (allProfiles[profileKey] && [allProfiles[profileKey] isKindOfClass:[NSDictionary class]]) {
        profile = [allProfiles[profileKey] mutableCopy];
    }
    if (!profile && cPath.length > 0) {
        NSString *diskPlist = [cPath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        NSDictionary *diskLoaded = [NSDictionary dictionaryWithContentsOfFile:diskPlist];
        if (diskLoaded) profile = [diskLoaded mutableCopy];
    }

    if (!profile || !profile[@"idfv"] || rotate) {
        BOOL wasEnabled = (profile && profile[@"enabled"] != nil) ? [profile[@"enabled"] boolValue] : YES;
        uint64_t seed = fnv1aHashPrefs([NSString stringWithFormat:@"%@_%@", profileKey, [[NSUUID UUID] UUIDString]]);

        NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59", @"f0:9f:c2", @"04:d6:aa"];
        NSArray *ssidPrefixes = @[@"HomeWiFi", @"ATT-Fiber", @"Xfinity-WiFi", @"SpectrumSetup", @"NETGEAR", @"TP-Link"];
        NSString *oui = ouis[seed % ouis.count];
        NSString *ssidPref = ssidPrefixes[(seed >> 3) % ssidPrefixes.count];

        uint8_t b3 = (seed >> 8) & 0xFF;
        uint8_t b4 = (seed >> 16) & 0xFF;
        uint8_t b5 = (seed >> 24) & 0xFF;
        NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x", oui, b3, b4, b5];
        NSString *ssid = [NSString stringWithFormat:@"%@-%02X-5G", ssidPref, (unsigned int)(seed & 0xFF)];

        NSArray *subnets = @[@"192.168.1", @"192.168.0", @"10.0.0", @"192.168.50", @"172.16.0"];
        NSString *subnet = subnets[(seed >> 5) % subnets.count];
        int lastOctet = 15 + (int)(seed % 225);
        NSString *localIP = [NSString stringWithFormat:@"%@.%d", subnet, lastOctet];

        unsigned long long baseFreeMB = 16500ULL + (seed % 28000ULL);
        unsigned long long freeBytes = (baseFreeMB * 1024ULL * 1024ULL);
        NSUInteger uptimeOffset = 1800 + (NSUInteger)(seed % 72000);
        float batteryLvl = 0.42f + ((seed % 52) / 100.0f);
        float brightnessLvl = 0.40f + (((seed >> 4) % 50) / 100.0f);
        float audioVol = 0.25f + (((seed >> 6) % 65) / 100.0f);

        profile = [@{
            @"profileKey": profileKey,
            @"enabled": @(wasEnabled),
            @"spoofIDs": profile[@"spoofIDs"] ?: @YES,
            @"spoofNetwork": profile[@"spoofNetwork"] ?: @YES,
            @"spoofLocation": profile[@"spoofLocation"] ?: @YES,
            @"spoofHardware": profile[@"spoofHardware"] ?: @YES,
            @"spoofSecurity": profile[@"spoofSecurity"] ?: @YES,
            @"craneContainerID": cName ?: @"Default",
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
            @"pasteboardCount": @(5 + (seed % 90)),
            @"timeZone": profile[@"timeZone"] ?: (self.state[@"defaultTimeZone"] ?: @"America/New_York"),
            @"localeID": profile[@"localeID"] ?: (self.state[@"defaultLocale"] ?: @"en_US"),
            @"CarrierMode": profile[@"CarrierMode"] ?: (self.state[@"CarrierMode"] ?: @"CELLULAR"),
            @"CarrierName": profile[@"CarrierName"] ?: (self.state[@"CarrierName"] ?: @"T-Mobile"),
            @"CarrierMCC": profile[@"CarrierMCC"] ?: (self.state[@"CarrierMCC"] ?: @"310"),
            @"CarrierMNC": profile[@"CarrierMNC"] ?: (self.state[@"CarrierMNC"] ?: @"260"),
            @"CarrierISO": profile[@"CarrierISO"] ?: (self.state[@"CarrierISO"] ?: @"us")
        } mutableCopy];
    }

    allProfiles[profileKey] = profile;
    self.state[@"profilesByContainer"] = allProfiles;
    [self saveState];

    if (cPath.length > 0) {
        NSString *diskPlist = [cPath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        [profile writeToFile:diskPlist atomically:YES];
    }
    return profile;
}

- (void)scanAllRealContainersOnDisk {
    self.igContainers = [NSMutableArray array];
    self.redditContainers = [NSMutableArray array];
    NSMutableSet *seenKeys = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Contenedores registrados automáticamente por Tweak.x al abrir Instagram o Reddit
    NSDictionary *freshState = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    if (freshState) self.state = [freshState mutableCopy];
    NSDictionary *known = self.state[@"knownContainers"];
    if ([known isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in known) {
            NSDictionary *info = known[key];
            if (![info isKindOfClass:[NSDictionary class]]) continue;
            NSString *bID = info[@"bundleID"] ?: @"";
            NSString *cName = info[@"craneName"] ?: @"Default";
            NSString *cPath = info[@"path"] ?: @"";
            BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
            BOOL isReddit = [bID isEqualToString:@"com.reddit.Reddit"];
            if (!isIG && !isReddit) continue;

            NSString *pKey = [NSString stringWithFormat:@"%@_%@", bID, cName];
            if ([seenKeys containsObject:pKey]) continue;
            NSMutableDictionary *prof = [self ensureProfileForKey:pKey containerName:cName path:cPath forceRotate:NO];
            NSMutableArray *target = isIG ? self.igContainers : self.redditContainers;
            [target addObject:@{@"title": cName, @"profileKey": pKey, @"path": cPath, @"profile": prof}];
            [seenKeys addObject:pKey];
        }
    }

    // 2. Escanear contenedores directamente en /var/mobile/Containers/Data/Application
    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:appsDir error:nil];
    for (NSString *uuid in uuids) {
        NSString *fullPath = [appsDir stringByAppendingPathComponent:uuid];
        NSString *metaPath = [fullPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        NSString *bundleID = meta[@"MCMMetadataIdentifier"] ?: @"";
        BOOL isIG = [bundleID isEqualToString:@"com.burbn.instagram"];
        BOOL isReddit = [bundleID isEqualToString:@"com.reddit.Reddit"];
        if (!isIG && !isReddit) continue;

        NSString *craneName = meta[@"com.opa334.crane.container.name"] ?: @"Default";
        NSString *pKey = [NSString stringWithFormat:@"%@_%@", bundleID, craneName];
        if (![seenKeys containsObject:pKey]) {
            NSMutableDictionary *prof = [self ensureProfileForKey:pKey containerName:craneName path:fullPath forceRotate:NO];
            NSMutableArray *target = isIG ? self.igContainers : self.redditContainers;
            [target addObject:@{@"title": craneName, @"profileKey": pKey, @"path": fullPath, @"profile": prof}];
            [seenKeys addObject:pKey];
        }
    }

    // 3. Garantizar siempre al menos el contenedor Default en ambas apps para poder configurarlo de inmediato
    if (self.igContainers.count == 0) {
        NSString *pKey = @"com.burbn.instagram_Default";
        NSMutableDictionary *prof = [self ensureProfileForKey:pKey containerName:@"Default" path:@"" forceRotate:NO];
        [self.igContainers addObject:@{@"title": @"Default", @"profileKey": pKey, @"path": @"", @"profile": prof}];
    }
    if (self.redditContainers.count == 0) {
        NSString *pKey = @"com.reddit.Reddit_Default";
        NSMutableDictionary *prof = [self ensureProfileForKey:pKey containerName:@"Default" path:@"" forceRotate:NO];
        [self.redditContainers addObject:@{@"title": @"Default", @"profileKey": pKey, @"path": @"", @"profile": prof}];
    }
}

#pragma mark - TableView Nivel 1

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"CONTROL GENERAL";
        case 1: return @"APLICACIONES Y CONTENEDORES (CRANE)";
        case 2: return @"ESTADO DE RED Y SISTEMA DEL IPHONE";
        case 3: return @"MANTENIMIENTO Y SINCRONIZACIÓN";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 2;
        case 1: return 2;
        case 2: return 4;
        case 3: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL masterOn = [self.state[@"masterEnabled"] boolValue];

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = @"Habilitar IGFarmShield";
            cell.detailTextLabel.text = masterOn ? @"Protección activa por contenedor" : @"Desactivado globalmente";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = masterOn;
            [sw addTarget:self action:@selector(toggleMasterSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            cell.textLabel.text = @"Integración con Choicy";
            cell.detailTextLabel.text = self.choicyStatusText;
            cell.detailTextLabel.textColor = self.choicySafe ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            BOOL igOn = masterOn && [self.state[@"enableIG"] boolValue];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = @"📸 Instagram";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu contenedores • Escudo %@",
                                         (unsigned long)self.igContainers.count, igOn ? @"ACTIVO" : @"APAGADO"];
            cell.detailTextLabel.textColor = igOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
        } else {
            BOOL rdOn = masterOn && [self.state[@"enableReddit"] boolValue];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = @"🤖 Reddit";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu contenedores • Escudo %@",
                                         (unsigned long)self.redditContainers.count, rdOn ? @"ACTIVO" : @"APAGADO"];
            cell.detailTextLabel.textColor = rdOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
        }
        return cell;
    }

    if (indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Túnel Proxy / VPN (Shadowrocket)";
            cell.detailTextLabel.text = self.vpnActive ? [NSString stringWithFormat:@"Conectado • Interfaz %@", self.vpnInterfaceName] : @"Desconectado (Usando Wi-Fi directo)";
            cell.detailTextLabel.textColor = self.vpnActive ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"IP Saliente y Proveedor (ISP)";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@",
                                         self.state[@"last_ip"] ?: @"Detectando...",
                                         self.state[@"last_isp"] ?: @"Toca actualizar abajo"];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Zona Horaria Detectada en Red";
            cell.detailTextLabel.text = self.state[@"defaultTimeZone"] ?: self.realTimeZone;
        } else {
            cell.textLabel.text = @"Almacenamiento y Hardware Real";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@ • Bat: %d%%",
                                         self.realHardwareModel, self.realFreeDisk, self.realBatteryPct];
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.row == 0) {
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.textLabel.text = @"🔄 Detectar IP Saliente y Sincronizar Red";
    } else {
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.text = @"🧹 Limpiar Caché Temporal de Contenedores";
    }
    return cell;
}

- (void)toggleMasterSwitch:(UISwitch *)sender {
    self.state[@"masterEnabled"] = @(sender.isOn);
    [self saveState];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1) {
        IGFarmAppContainersController *subVC = [[IGFarmAppContainersController alloc] init];
        subVC.parentRoot = self;
        subVC.state = self.state;
        if (indexPath.row == 0) {
            subVC.appTitle = @"Instagram";
            subVC.bundleID = @"com.burbn.instagram";
            subVC.stateKey = @"enableIG";
            subVC.isIG = YES;
            subVC.appContainers = self.igContainers;
        } else {
            subVC.appTitle = @"Reddit";
            subVC.bundleID = @"com.reddit.Reddit";
            subVC.stateKey = @"enableReddit";
            subVC.isIG = NO;
            subVC.appContainers = self.redditContainers;
        }
        [self.navigationController pushViewController:subVC animated:YES];
        return;
    }

    if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            [self refreshRealPhoneTelemetry];
            [self syncCurrentNetworkSilently:NO];
        } else {
            [self purgeContainersCache];
        }
    }
}

- (void)syncCurrentNetworkSilently:(BOOL)silent {
    NSURL *url = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,countryCode,city,timezone,isp,query"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 6.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!silent) [self showAlert:@"Sin respuesta de red" msg:@"Verifica que Shadowrocket o el Wi-Fi tengan salida a internet."];
            });
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) return;

        NSString *ip = json[@"query"] ?: @"Desconocida";
        NSString *ispRaw = json[@"isp"] ?: @"ISP";
        NSString *cc = [json[@"countryCode"] lowercaseString] ?: @"us";
        NSString *tz = json[@"timezone"] ?: @"America/New_York";

        self.state[@"last_ip"] = ip;
        self.state[@"last_isp"] = [NSString stringWithFormat:@"%@ (%@)", ispRaw, [cc uppercaseString]];
        self.state[@"defaultTimeZone"] = tz;
        self.state[@"defaultLocale"] = [NSString stringWithFormat:@"en_%@", [cc uppercaseString]];
        [self saveState];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
            if (!silent) {
                [self showAlert:@"Red Detectada"
                            msg:[NSString stringWithFormat:@"IP Saliente: %@\nISP: %@ (%@)\nZona Horaria: %@",
                                 ip, ispRaw, [cc uppercaseString], tz]];
            }
        });
    }] resume];
}

- (void)purgeContainersCache {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger cleaned = 0;
    NSArray *all = [self.igContainers arrayByAddingObjectsFromArray:self.redditContainers];
    for (NSDictionary *item in all) {
        NSString *cPath = item[@"path"];
        if (!cPath || cPath.length == 0) continue;
        for (NSString *subDir in @[@"Library/Caches", @"tmp"]) {
            NSString *targetDir = [cPath stringByAppendingPathComponent:subDir];
            if ([fm fileExistsAtPath:targetDir]) {
                NSArray *files = [fm contentsOfDirectoryAtPath:targetDir error:nil];
                for (NSString *f in files) {
                    [fm removeItemAtPath:[targetDir stringByAppendingPathComponent:f] error:nil];
                    cleaned++;
                }
            }
        }
    }
    [self refreshRealPhoneTelemetry];
    [self.tableView reloadData];
    [self showAlert:@"Caché Limpiada"
                msg:[NSString stringWithFormat:@"Se eliminaron %lu archivos temporales sin cerrar sesiones.\n%@", (unsigned long)cleaned, self.realFreeDisk]];
}

- (void)showAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

// ============================================================================
// IMPLEMENTACIÓN NIVEL 2: LISTA DE CONTENEDORES DE LA APP (ESTILO CRANE)
// ============================================================================
@implementation IGFarmAppContainersController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.appTitle ?: @"Contenedores";
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.parentRoot scanAllRealContainersOnDisk];
    self.appContainers = self.isIG ? self.parentRoot.igContainers : self.parentRoot.redditContainers;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"ESTADO EN ESTA APLICACIÓN";
    if (section == 1) return [NSString stringWithFormat:@"CONTENEDORES DE %@ (%lu)", [self.appTitle uppercaseString], (unsigned long)self.appContainers.count];
    return @"GESTIÓN DE CONTENEDORES";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return self.appContainers.count;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL masterOn = [self.state[@"masterEnabled"] boolValue];
    BOOL appOn = [self.state[self.stateKey] boolValue];

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        cell.textLabel.text = [NSString stringWithFormat:@"Activar Escudo en %@", self.appTitle];
        cell.detailTextLabel.text = (masterOn && appOn) ? @"Inyectando huella aislada por contenedor" : @"Desactivado (Usando valores reales del iPhone)";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = appOn;
        sw.enabled = masterOn;
        [sw addTarget:self action:@selector(toggleAppSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        NSDictionary *item = self.appContainers[indexPath.row];
        NSMutableDictionary *prof = item[@"profile"];
        BOOL contOn = prof[@"enabled"] ? [prof[@"enabled"] boolValue] : YES;
        BOOL active = masterOn && appOn && contOn;

        cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        cell.textLabel.text = [NSString stringWithFormat:@"📦 %@", item[@"title"]];

        if (active) {
            NSString *netDesc = [prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]
                ? @"Wi-Fi Puro"
                : [NSString stringWithFormat:@"4G %@", prof[@"CarrierName"] ?: @"T-Mobile"];
            NSString *idfvShort = [prof[@"idfv"] length] >= 8 ? [prof[@"idfv"] substringToIndex:8] : prof[@"idfv"];
            cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 %@ • %@ • IDFV: %@...",
                                         netDesc, prof[@"timeZone"] ?: @"America/New_York", idfvShort];
        } else {
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.detailTextLabel.text = @"⚪ Escudo apagado en este contenedor";
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.textLabel.text = @"➕ Añadir / Pre-configurar Contenedor de Crane";
    return cell;
}

- (void)toggleAppSwitch:(UISwitch *)sender {
    self.state[self.stateKey] = @(sender.isOn);
    [self.parentRoot saveState];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1) {
        IGFarmContainerDetailController *detailVC = [[IGFarmContainerDetailController alloc] init];
        detailVC.containerItem = self.appContainers[indexPath.row];
        detailVC.isIG = self.isIG;
        detailVC.parentRoot = self.parentRoot;
        [self.navigationController pushViewController:detailVC animated:YES];
        return;
    }

    if (indexPath.section == 2) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Nuevo Contenedor de Crane"
                                                                    message:@"Escribe el nombre exacto del contenedor en Crane (ej: Cuenta1, Main, Backup). También se registran solos al abrir la app:"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"Nombre del contenedor en Crane";
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Crear Perfil" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *name = ac.textFields.firstObject.text;
            if (!name || name.length == 0) return;
            NSMutableDictionary *known = [self.parentRoot.state[@"knownContainers"] isKindOfClass:[NSDictionary class]]
                ? [self.parentRoot.state[@"knownContainers"] mutableCopy]
                : [NSMutableDictionary dictionary];
            NSString *k = [NSString stringWithFormat:@"%@_%@", self.bundleID, name];
            known[k] = @{@"bundleID": self.bundleID, @"craneName": name, @"path": @""};
            self.parentRoot.state[@"knownContainers"] = known;
            [self.parentRoot saveState];
            [self.parentRoot scanAllRealContainersOnDisk];
            self.appContainers = self.isIG ? self.parentRoot.igContainers : self.parentRoot.redditContainers;
            [self.tableView reloadData];
        }]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

@end

// ============================================================================
// IMPLEMENTACIÓN NIVEL 3: CONFIGURACIÓN Y DATOS ACTIVOS DEL CONTENEDOR
// ============================================================================
@implementation IGFarmContainerDetailController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *cTitle = self.containerItem[@"title"] ?: @"Default";
    self.title = [NSString stringWithFormat:@"📦 %@", cTitle];

    NSString *pKey = self.containerItem[@"profileKey"] ?: @"com.burbn.instagram_Default";
    NSString *cPath = self.containerItem[@"path"] ?: @"";
    if (self.parentRoot) {
        self.profile = [self.parentRoot ensureProfileForKey:pKey containerName:cTitle path:cPath forceRotate:NO];
    } else {
        self.profile = self.containerItem[@"profile"] ?: [NSMutableDictionary dictionary];
    }

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)saveContainerProfile {
    NSString *pKey = self.profile[@"profileKey"] ?: (self.containerItem[@"profileKey"] ?: @"com.burbn.instagram_Default");
    if (self.parentRoot) {
        NSMutableDictionary *allProfiles = [self.parentRoot.state[@"profilesByContainer"] isKindOfClass:[NSDictionary class]]
            ? [self.parentRoot.state[@"profilesByContainer"] mutableCopy]
            : [NSMutableDictionary dictionary];
        allProfiles[pKey] = self.profile;
        self.parentRoot.state[@"profilesByContainer"] = allProfiles;
        [self.parentRoot saveState];
    }
    NSString *cPath = self.containerItem[@"path"];
    if (cPath && cPath.length > 0) {
        NSString *profilePath = [cPath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        [self.profile writeToFile:profilePath atomically:YES];
    }
}

- (BOOL)isModOn:(NSString *)key {
    BOOL contOn = self.profile[@"enabled"] ? [self.profile[@"enabled"] boolValue] : YES;
    if (!contOn) return NO;
    return self.profile[key] ? [self.profile[key] boolValue] : YES;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"1. ESTADO DEL CONTENEDOR";
        case 1: return @"2. SELECCIÓN DE RED Y REGIÓN DE ESTA CUENTA";
        case 2: return @"3. DATOS ACTIVOS DEL CONTENEDOR (HUELLA ACTUAL)";
        case 3: return @"4. MÓDULOS DE PROTECCIÓN";
        case 4: return @"5. ACCIONES Y AUDITORÍA DE RED";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;
        case 1: return 3;
        case 2: return 6;
        case 3: return 5;
        case 4: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL contOn = self.profile[@"enabled"] ? [self.profile[@"enabled"] boolValue] : YES;

    // SECCIÓN 0: INTERRUPTOR DEL CONTENEDOR
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        cell.textLabel.text = @"Escudo Activo en este Contenedor";
        cell.detailTextLabel.text = contOn ? @"🟢 Protegiendo esta cuenta" : @"⚪ Apagado (Usa datos reales)";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = contOn;
        sw.tag = 200;
        [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    // SECCIÓN 1: SELECTORES DE RED Y REGIÓN (SE REFLEJAN ABAJO EN SECCIÓN 2)
    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"📡 Elegir Operadora / Modo de Red";
            if ([self.profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Seleccionado: Wi-Fi Residencial Sin SIM (%@)", [self.profile[@"CarrierISO"] ?: @"us" uppercaseString]];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Seleccionado: 4G LTE %@ (MCC %@ / MNC %@)",
                                             self.profile[@"CarrierName"] ?: @"T-Mobile",
                                             self.profile[@"CarrierMCC"] ?: @"310",
                                             self.profile[@"CarrierMNC"] ?: @"260"];
            }
            cell.detailTextLabel.textColor = [UIColor systemBlueColor];
        } else if (indexPath.row == 1) {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"🌎 Elegir Zona Horaria e Idioma";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Seleccionado: %@ • Idioma: %@",
                                         self.profile[@"timeZone"] ?: @"America/New_York",
                                         self.profile[@"localeID"] ?: @"en_US"];
            cell.detailTextLabel.textColor = [UIColor systemBlueColor];
        } else {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.text = @"⚡ Auto-Ajustar Red según mi Proxy Actual";
            cell.detailTextLabel.text = self.profile[@"lastSyncedIP"]
                ? [NSString stringWithFormat:@"Última IP sincronizada: %@", self.profile[@"lastSyncedIP"]]
                : @"Toca para detectar tu IP saliente y configurar operadora/hora";
        }
        return cell;
    }

    // SECCIÓN 2: DATOS ACTIVOS DEL CONTENEDOR (DOBLE LÍNEA LIMPIA Y PROPORCIONADA)
    if (indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        cell.detailTextLabel.numberOfLines = 2;

        double freeGB = [self.profile[@"freeBytes"] unsignedLongLongValue] / (1024.0*1024.0*1024.0);
        int batPct = (int)([self.profile[@"batteryLevel"] floatValue] * 100.0f);
        int volPct = (int)([self.profile[@"audioVolume"] floatValue] * 100.0f);
        NSUInteger upMin = [self.profile[@"uptimeOffset"] unsignedIntegerValue] / 60;

        if (indexPath.row == 0) {
            cell.textLabel.text = @"Red Móvil y Operadora Inyectada";
            if (![self isModOn:@"spoofNetwork"]) {
                cell.detailTextLabel.text = @"⚪ Desactivado (Usando SIM real del iPhone)";
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            } else if ([self.profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 Modo Wi-Fi Puro (SIM oculta • País: %@)", [self.profile[@"CarrierISO"] ?: @"us" uppercaseString]];
                cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 4G LTE %@ • MCC: %@ / MNC: %@ (%@)",
                                             self.profile[@"CarrierName"] ?: @"T-Mobile",
                                             self.profile[@"CarrierMCC"] ?: @"310",
                                             self.profile[@"CarrierMNC"] ?: @"260",
                                             [self.profile[@"CarrierISO"] ?: @"us" uppercaseString]];
                cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            }
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Zona Horaria y Región Inyectada";
            if (![self isModOn:@"spoofLocation"] || [self.profile[@"timeZone"] isEqualToString:@"REAL"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"⚪ Usando reloj real (%@)", self.parentRoot.realTimeZone ?: @"Local"];
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 %@ • Locale: %@",
                                             self.profile[@"timeZone"] ?: @"America/New_York",
                                             self.profile[@"localeID"] ?: @"en_US"];
                cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            }
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Red Local (IP LAN y Router Wi-Fi)";
            if (![self isModOn:@"spoofNetwork"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"⚪ IP Real: %@", self.parentRoot.realLocalIP ?: @"192.168.1.x"];
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 IP: %@ • %@ (%@)",
                                             self.profile[@"localIP"] ?: @"192.168.1.45",
                                             self.profile[@"ssid"] ?: @"HomeWiFi-5G",
                                             self.profile[@"bssid"] ?: @"a4:83:e7:11:22:33"];
                cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            }
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"Vendor ID (IDFV de esta Cuenta)";
            if (![self isModOn:@"spoofIDs"]) {
                cell.detailTextLabel.text = @"⚪ Desactivado (Usando IDFV nativo)";
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 %@", self.profile[@"idfv"] ?: @"Generando..."];
                cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            }
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"Device ID y Kernel BootUUID";
            if (![self isModOn:@"spoofIDs"]) {
                cell.detailTextLabel.text = @"⚪ Desactivado (Usando UUIDs reales)";
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            } else {
                NSString *devShort = [self.profile[@"shieldDeviceID"] length] >= 13 ? [self.profile[@"shieldDeviceID"] substringToIndex:13] : self.profile[@"shieldDeviceID"];
                NSString *bootShort = [self.profile[@"bootSessionUUID"] length] >= 13 ? [self.profile[@"bootSessionUUID"] substringToIndex:13] : self.profile[@"bootSessionUUID"];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 Dev: %@... • Boot: %@...", devShort, bootShort];
                cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            }
        } else if (indexPath.row == 5) {
            cell.textLabel.text = @"Hardware Simulado (Disco, Batería y Uptime)";
            if (![self isModOn:@"spoofHardware"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"⚪ Real: %@ • Bat: %d%%", self.parentRoot.realFreeDisk ?: @"64GB", self.parentRoot.realBatteryPct];
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 %.2f GB libres • Bat: %d%% • Vol: %d%% • +%lu min",
                                             freeGB, batPct, volPct, (unsigned long)upMin];
                cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            }
        }
        return cell;
    }

    // SECCIÓN 3: INTERRUPTORES DE MÓDULOS
    if (indexPath.section == 3) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSArray *titles = @[
            @"Camuflar IDs (IDFV / DeviceID / BootUUID)",
            @"Camuflar Red Local y Ocultar VPN",
            @"Camuflar Zona Horaria e Idioma",
            @"Camuflar Hardware (Disco y Batería)",
            @"Ocultar Jailbreak y Crane"
        ];
        NSArray *keys = @[@"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity"];
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.textLabel.text = titles[indexPath.row];
        UISwitch *sw = [[UISwitch alloc] init];
        NSString *k = keys[indexPath.row];
        sw.on = self.profile[k] ? [self.profile[k] boolValue] : YES;
        sw.enabled = contOn;
        sw.tag = 201 + indexPath.row;
        [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    // SECCIÓN 4 (AL FINAL): ACCIONES Y AUDITORÍA
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.row == 0) {
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.textLabel.text = @"🔄 Generar Nueva Huella Completa en esta Cuenta";
    } else {
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.text = @"🔍 Auditar IP de este Contenedor en VPS (Telegram)";
    }
    return cell;
}

- (void)toggleSwitch:(UISwitch *)sender {
    if (sender.tag == 200) {
        self.profile[@"enabled"] = @(sender.isOn);
    } else {
        NSArray *keys = @[@"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity"];
        NSString *k = keys[sender.tag - 201];
        self.profile[k] = @(sender.isOn);
    }
    [self saveContainerProfile];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            [self showCarrierSelector];
        } else if (indexPath.row == 1) {
            [self showTimeZoneSelector];
        } else {
            [self autoDetectNetworkAndApplyToContainerWithVPS:NO];
        }
        return;
    }

    if (indexPath.section == 4) {
        if (indexPath.row == 0) {
            NSString *pKey = self.containerItem[@"profileKey"] ?: @"com.burbn.instagram_Default";
            NSString *cTitle = self.containerItem[@"title"] ?: @"Default";
            NSString *cPath = self.containerItem[@"path"] ?: @"";
            self.profile = [self.parentRoot ensureProfileForKey:pKey containerName:cTitle path:cPath forceRotate:YES];
            [self.tableView reloadData];
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Huella Regenerada"
                                                                        message:@"Se actualizaron todos los identificadores (IDFV, Device ID, BootUUID, IP LAN, Router Wi-Fi, Espacio en Disco y Batería) de este contenedor."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        } else {
            [self autoDetectNetworkAndApplyToContainerWithVPS:YES];
        }
    }
}

- (void)autoDetectNetworkAndApplyToContainerWithVPS:(BOOL)sendToVPS {
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

        [self saveContainerProfile];

        if (!sendToVPS) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Red Sincronizada en el Contenedor"
                                                                            message:[NSString stringWithFormat:@"IP Detectada: %@\nISP: %@\n\nSe inyectó automáticamente:\n• Modo: %@ (%@)\n• Zona Horaria: %@\n• Región: %@",
                                                                                     ip, ispRaw, self.profile[@"CarrierMode"], self.profile[@"CarrierName"], tz, self.profile[@"localeID"]]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
            return;
        }

        BOOL choicyOK = [self.parentRoot auditChoicyConfiguration];
        NSString *plat = self.isIG ? @"INSTAGRAM" : @"REDDIT";
        NSString *contName = [self.containerItem[@"title"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"Default";
        NSString *ispEnc = [ispRaw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
        NSString *bssidEnc = [(self.profile[@"bssid"] ?: @"") stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";

        NSString *vpsUrlStr = [NSString stringWithFormat:@"%@?ip=%@&contenedor=%@&plataforma=%@&choicy=%d&bssid=%@&isp=%@&cc=%@",
                               VPS_AUDIT_URL, ip, contName, plat, choicyOK ? 1 : 0, bssidEnc, ispEnc, cc];

        [[session dataTaskWithURL:[NSURL URLWithString:vpsUrlStr] completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
            NSDictionary *vpsJson = vData ? [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil] : nil;
            if (![vpsJson isKindOfClass:[NSDictionary class]]) vpsJson = nil;
            NSString *msj = vpsJson[@"mensaje_iphone"] ?: [NSString stringWithFormat:@"IP: %@ (%@)\nEl VPS no respondió en el puerto 5001, pero el contenedor ya quedó configurado localmente.", ip, ispRaw];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Resultado de Auditoría" message:msj preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
        }] resume];
    }] resume];
}

- (void)showCarrierSelector {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Operadora / Red del Contenedor"
                                                                message:@"Selecciona qué red verá la app dentro de este contenedor (se reflejará en la sección 3):"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *presets = @[
        @{@"title": @"📱 T-Mobile US 4G LTE (310 / 260)", @"mode": @"CELLULAR", @"name": @"T-Mobile", @"mcc": @"310", @"mnc": @"260", @"iso": @"us"},
        @{@"title": @"📱 AT&T US 4G LTE (310 / 410)", @"mode": @"CELLULAR", @"name": @"AT&T", @"mcc": @"310", @"mnc": @"410", @"iso": @"us"},
        @{@"title": @"📱 Verizon US 4G LTE (311 / 480)", @"mode": @"CELLULAR", @"name": @"Verizon", @"mcc": @"311", @"mnc": @"480", @"iso": @"us"},
        @{@"title": @"🛜 Wi-Fi Residencial Puro (Sin SIM / Proxy Residencial)", @"mode": @"WIFI_ONLY", @"name": @"Wi-Fi", @"mcc": @"", @"mnc": @"", @"iso": @"us"},
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
            [self saveContainerProfile];
            [self.tableView reloadData];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showTimeZoneSelector {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Zona Horaria y Región"
                                                                message:@"Selecciona la ubicación horaria que verá la app en este contenedor:"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *zones = @[
        @{@"title": @"🇺🇸 USA Este - Miami / NY (America/New_York)", @"tz": @"America/New_York", @"loc": @"en_US"},
        @{@"title": @"🇺🇸 USA Centro - Texas / Chicago (America/Chicago)", @"tz": @"America/Chicago", @"loc": @"en_US"},
        @{@"title": @"🇺🇸 USA Montaña - Denver (America/Denver)", @"tz": @"America/Denver", @"loc": @"en_US"},
        @{@"title": @"🇺🇸 USA Oeste - Los Ángeles (America/Los_Angeles)", @"tz": @"America/Los_Angeles", @"loc": @"en_US"},
        @{@"title": @"🇬🇧 Reino Unido - Londres (Europe/London)", @"tz": @"Europe/London", @"loc": @"en_GB"},
        @{@"title": @"🇪🇸 España - Madrid (Europe/Madrid)", @"tz": @"Europe/Madrid", @"loc": @"es_ES"},
        @{@"title": @"⚪ Usar Reloj Real del iPhone", @"tz": @"REAL", @"loc": @"REAL"}
    ];

    for (NSDictionary *z in zones) {
        [ac addAction:[UIAlertAction actionWithTitle:z[@"title"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self.profile[@"timeZone"] = z[@"tz"];
            self.profile[@"localeID"] = z[@"loc"];
            [self saveContainerProfile];
            [self.tableView reloadData];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
