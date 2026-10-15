#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>

#define STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define VPS_AUDIT_URL @"http://162.35.105.151:5001/iphone_audit"

@interface PSViewController : UIViewController
@end

@class IGFarmRootListController;

// ============================================================================
// NIVEL 1: PANEL CENTRAL (DE PRIMERO PARA QUE SETTINGS LO ABRA SIEMPRE)
// ============================================================================
@interface IGFarmRootListController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableDictionary *state;
@property (nonatomic, strong) NSMutableArray *containerNames;
@property (nonatomic, assign) BOOL vpnActive;
@property (nonatomic, strong) NSString *vpnInterfaceName;
@property (nonatomic, strong) NSString *residualSummary;
- (void)saveState;
- (void)scanAndSyncAllContainers;
- (void)calculateResidualTraces;
- (void)cleanResidualTracesBeforeRotation;
- (void)detectCurrentNetworkSilently:(BOOL)silent;
- (NSMutableDictionary *)ensureProfileForContainer:(NSString *)cName forceRotate:(BOOL)rotate;
- (void)saveProfile:(NSMutableDictionary *)profile forContainer:(NSString *)cName;
@end

// ============================================================================
// NIVEL 2: DENTRO DEL CONTENEDOR (SELECTORES IG/REDDIT + CONFIGURACIONES)
// ============================================================================
@interface IGFarmContainerDetailController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSString *containerName;
@property (nonatomic, strong) NSMutableDictionary *profile;
@property (nonatomic, weak) IGFarmRootListController *parentRoot;
@property (nonatomic, strong) UITableView *tableView;
- (void)saveCurrentProfile;
- (void)toggleSwitch:(UISwitch *)sender;
- (void)showCarrierSelector;
- (void)showTimeZoneSelector;
- (void)showModelSelector;
- (void)autoSyncNetworkAndAuditOnVPS:(BOOL)sendToVPS;
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
// IMPLEMENTACIÓN NIVEL 1: PANEL CENTRAL ESTILO CRANE / GHOST
// ============================================================================
@implementation IGFarmRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"IGFarmShield";

    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    self.state = loaded ? [loaded mutableCopy] : [NSMutableDictionary dictionary];
    if (!self.state[@"masterEnabled"]) self.state[@"masterEnabled"] = @YES;
    if (!self.state[@"containers"]) self.state[@"containers"] = [NSMutableDictionary dictionary];
    [self saveState];

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
    [self scanAndSyncAllContainers];
    [self calculateResidualTraces];
    [self.tableView reloadData];
}

- (void)saveState {
    [self.state writeToFile:STATE_PLIST atomically:YES];
}

- (NSMutableDictionary *)ensureProfileForContainer:(NSString *)cName forceRotate:(BOOL)rotate {
    if (!cName || cName.length == 0) cName = @"Default";
    NSMutableDictionary *containersMap = [self.state[@"containers"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containers"] mutableCopy]
        : [NSMutableDictionary dictionary];

    NSMutableDictionary *profile = nil;
    if (containersMap[cName] && [containersMap[cName] isKindOfClass:[NSDictionary class]]) {
        profile = [containersMap[cName] mutableCopy];
    }

    if (!profile || !profile[@"idfv"] || rotate) {
        BOOL wasEnabled = (profile && profile[@"enabled"] != nil) ? [profile[@"enabled"] boolValue] : YES;
        BOOL wasIG = (profile && profile[@"enableIG"] != nil) ? [profile[@"enableIG"] boolValue] : YES;
        BOOL wasRD = (profile && profile[@"enableReddit"] != nil) ? [profile[@"enableReddit"] boolValue] : YES;
        NSDictionary *existingPaths = [profile[@"paths"] isKindOfClass:[NSDictionary class]] ? profile[@"paths"] : @{};

        uint64_t seed = fnv1aHashPrefs([NSString stringWithFormat:@"%@_%@", cName, [[NSUUID UUID] UUIDString]]);
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
        unsigned long long freeBytes = (18400ULL + (seed % 29000ULL)) * 1024ULL * 1024ULL;

        profile = [@{
            @"containerName": cName,
            @"enabled": @(wasEnabled),
            @"enableIG": @(wasIG),
            @"enableReddit": @(wasRD),
            @"spoofIDs": profile[@"spoofIDs"] ?: @YES,
            @"spoofNetwork": profile[@"spoofNetwork"] ?: @YES,
            @"spoofLocation": profile[@"spoofLocation"] ?: @YES,
            @"spoofHardware": profile[@"spoofHardware"] ?: @YES,
            @"spoofSecurity": profile[@"spoofSecurity"] ?: @YES,
            @"deviceModel": profile[@"deviceModel"] ?: model,
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
            @"timeZone": profile[@"timeZone"] ?: (self.state[@"defaultTimeZone"] ?: @"America/New_York"),
            @"localeID": profile[@"localeID"] ?: (self.state[@"defaultLocale"] ?: @"en_US"),
            @"CarrierMode": profile[@"CarrierMode"] ?: @"CELLULAR",
            @"CarrierName": profile[@"CarrierName"] ?: @"T-Mobile",
            @"CarrierMCC": profile[@"CarrierMCC"] ?: @"310",
            @"CarrierMNC": profile[@"CarrierMNC"] ?: @"260",
            @"CarrierISO": profile[@"CarrierISO"] ?: @"us",
            @"paths": existingPaths
        } mutableCopy];
    }

    [self saveProfile:profile forContainer:cName];
    return profile;
}

- (void)saveProfile:(NSMutableDictionary *)profile forContainer:(NSString *)cName {
    if (!cName || !profile) return;
    NSMutableDictionary *containersMap = [self.state[@"containers"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containers"] mutableCopy]
        : [NSMutableDictionary dictionary];
    containersMap[cName] = profile;
    self.state[@"containers"] = containersMap;
    [self saveState];

    NSDictionary *paths = profile[@"paths"];
    if ([paths isKindOfClass:[NSDictionary class]]) {
        for (NSString *bID in paths) {
            NSString *p = paths[bID];
            if ([p isKindOfClass:[NSString class]] && p.length > 0) {
                NSString *localPlist = [p stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
                [profile writeToFile:localPlist atomically:YES];
            }
        }
    }
}

- (void)scanAndSyncAllContainers {
    NSMutableSet *namesSet = [NSMutableSet setWithObject:@"Default"];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSDictionary *existingMap = self.state[@"containers"];
    if ([existingMap isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in existingMap) [namesSet addObject:k];
    }

    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:appsDir error:nil];
    for (NSString *uuid in uuids) {
        NSString *fullPath = [appsDir stringByAppendingPathComponent:uuid];
        NSString *metaPath = [fullPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        NSString *bundleID = meta[@"MCMMetadataIdentifier"] ?: @"";
        if (![bundleID isEqualToString:@"com.burbn.instagram"] && ![bundleID isEqualToString:@"com.reddit.Reddit"]) continue;

        NSString *cName = meta[@"com.opa334.crane.container.name"] ?: @"Default";
        [namesSet addObject:cName];

        NSMutableDictionary *prof = [self ensureProfileForContainer:cName forceRotate:NO];
        NSMutableDictionary *paths = [prof[@"paths"] isKindOfClass:[NSDictionary class]]
            ? [prof[@"paths"] mutableCopy]
            : [NSMutableDictionary dictionary];
        paths[bundleID] = fullPath;
        prof[@"paths"] = paths;
        [self saveProfile:prof forContainer:cName];
    }

    self.containerNames = [[[namesSet allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)] mutableCopy];
    if ([self.containerNames containsObject:@"Default"]) {
        [self.containerNames removeObject:@"Default"];
        [self.containerNames insertObject:@"Default" atIndex:0];
    }
    for (NSString *cName in self.containerNames) {
        [self ensureProfileForContainer:cName forceRotate:NO];
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
    NSDictionary *containersMap = self.state[@"containers"];

    if ([containersMap isKindOfClass:[NSDictionary class]]) {
        for (NSString *cName in containersMap) {
            NSDictionary *prof = containersMap[cName];
            NSDictionary *paths = prof[@"paths"];
            if (![paths isKindOfClass:[NSDictionary class]]) continue;
            for (NSString *bID in paths) {
                NSString *cPath = paths[bID];
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
    }

    double mb = (double)residualBytes / (1024.0 * 1024.0);
    self.residualSummary = [NSString stringWithFormat:@"%lu rastros temporales (%.2f MB) + Portapapeles", (unsigned long)residualFiles, mb];
}

- (void)cleanResidualTracesBeforeRotation {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger removedCount = 0;

    [UIPasteboard generalPasteboard].items = @[];
    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    NSDictionary *containersMap = self.state[@"containers"];
    if ([containersMap isKindOfClass:[NSDictionary class]]) {
        for (NSString *cName in containersMap) {
            NSDictionary *prof = containersMap[cName];
            NSDictionary *paths = prof[@"paths"];
            if (![paths isKindOfClass:[NSDictionary class]]) continue;
            for (NSString *bID in paths) {
                NSString *cPath = paths[bID];
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
    }

    [self calculateResidualTraces];
    [self.tableView reloadData];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Rastro Residual Eliminado"
                                                                message:[NSString stringWithFormat:@"Se limpiaron %lu archivos residuales (tmp, Caches, WebKit) y se vació el portapapeles compartido.\n\nYa puedes rotar de contenedor en Crane de forma segura.", (unsigned long)removedCount]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Listo" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - TableView Nivel 1 (Panel Central)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"PANEL CENTRAL IGFARMSHIELD";
    if (section == 1) return [NSString stringWithFormat:@"CONTENEDORES (%lu) — ACTIVA O TOCA PARA CONFIGURAR", (unsigned long)self.containerNames.count];
    return @"LIMPIEZA DE RASTRO ANTES DE ROTAR CONTENEDOR";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (section == 1) return self.containerNames.count + 1;
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
            cell.detailTextLabel.text = masterOn ? @"🟢 Escudo maestro activo" : @"⚪ Escudo maestro desactivado";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = masterOn;
            [sw addTarget:self action:@selector(toggleMasterSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"Estado de Red / Proxy Actual";
            NSString *vpnTxt = self.vpnActive ? [NSString stringWithFormat:@"🟢 VPN (%@)", self.vpnInterfaceName] : @"⚠️ Sin VPN";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • IP: %@ (%@)",
                                         vpnTxt,
                                         self.state[@"last_ip"] ?: @"Toca para verificar",
                                         self.state[@"last_isp"] ?: @"..."];
        }
        return cell;
    }

    if (indexPath.section == 1) {
        if (indexPath.row == self.containerNames.count) {
            UITableViewCell *addCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            addCell.textLabel.textColor = [UIColor systemBlueColor];
            addCell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            addCell.textLabel.text = @"➕ Añadir Contenedor de Crane";
            return addCell;
        }

        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        NSString *cName = self.containerNames[indexPath.row];
        NSMutableDictionary *prof = [self ensureProfileForContainer:cName forceRotate:NO];
        BOOL contOn = prof[@"enabled"] ? [prof[@"enabled"] boolValue] : YES;
        BOOL igOn = prof[@"enableIG"] ? [prof[@"enableIG"] boolValue] : YES;
        BOOL rdOn = prof[@"enableReddit"] ? [prof[@"enableReddit"] boolValue] : YES;

        cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        cell.textLabel.text = [NSString stringWithFormat:@"📦 %@", cName];

        if (masterOn && contOn) {
            NSString *appsTxt = [NSString stringWithFormat:@"IG:%@ RD:%@", igOn ? @"ON" : @"OFF", rdOn ? @"ON" : @"OFF"];
            NSString *netTxt = [prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"] ? @"Wi-Fi" : (prof[@"CarrierName"] ?: @"T-Mobile");
            cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 %@ • %@ • %@ › (Toca para configurar)",
                                         appsTxt, netTxt, prof[@"deviceModel"] ?: @"iPhone14,5"];
        } else {
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.detailTextLabel.text = @"⚪ Desactivado en este contenedor (Toca para entrar)";
        }

        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = contOn;
        sw.enabled = masterOn;
        sw.tag = indexPath.row;
        [sw addTarget:self action:@selector(toggleContainerSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.textLabel.textColor = [UIColor systemRedColor];
    cell.textLabel.text = @"🧹 Limpiar Rastro y Memoria Residual (Rotación Segura)";
    cell.detailTextLabel.text = self.residualSummary ?: @"Purga tmp, Caches, WebKit y Portapapeles antes de cambiar de cuenta";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)toggleMasterSwitch:(UISwitch *)sender {
    self.state[@"masterEnabled"] = @(sender.isOn);
    [self saveState];
    [self.tableView reloadData];
}

- (void)toggleContainerSwitch:(UISwitch *)sender {
    if (sender.tag < 0 || sender.tag >= self.containerNames.count) return;
    NSString *cName = self.containerNames[sender.tag];
    NSMutableDictionary *prof = [self ensureProfileForContainer:cName forceRotate:NO];
    prof[@"enabled"] = @(sender.isOn);
    [self saveProfile:prof forContainer:cName];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0 && indexPath.row == 1) {
        [self detectCurrentNetworkSilently:NO];
        return;
    }

    if (indexPath.section == 1) {
        if (indexPath.row == self.containerNames.count) {
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Añadir Contenedor de Crane"
                                                                        message:@"Escribe el nombre exacto del contenedor que creaste en Crane (también se detectan solos al abrir la app):"
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                tf.placeholder = @"Ej: Cuenta1, Backup, Main...";
            }];
            [ac addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
            [ac addAction:[UIAlertAction actionWithTitle:@"Guardar" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                NSString *name = ac.textFields.firstObject.text;
                if (!name || name.length == 0) return;
                [self ensureProfileForContainer:name forceRotate:NO];
                [self scanAndSyncAllContainers];
                [self.tableView reloadData];
            }]];
            [self presentViewController:ac animated:YES completion:nil];
            return;
        }

        NSString *cName = self.containerNames[indexPath.row];
        IGFarmContainerDetailController *detailVC = [[IGFarmContainerDetailController alloc] init];
        detailVC.containerName = cName;
        detailVC.parentRoot = self;
        detailVC.profile = [self ensureProfileForContainer:cName forceRotate:NO];
        [self.navigationController pushViewController:detailVC animated:YES];
        return;
    }

    if (indexPath.section == 2) {
        [self cleanResidualTracesBeforeRotation];
    }
}

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
        NSString *cc = [json[@"countryCode"] lowercaseString] ?: @"us";
        NSString *tz = json[@"timezone"] ?: @"America/New_York";

        self.state[@"last_ip"] = ip;
        self.state[@"last_isp"] = [NSString stringWithFormat:@"%@ (%@)", ispRaw, [cc uppercaseString]];
        self.state[@"defaultTimeZone"] = tz;
        self.state[@"defaultLocale"] = [NSString stringWithFormat:@"en_%@", [cc uppercaseString]];
        [self saveState];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self calculateResidualTraces];
            [self.tableView reloadData];
        });
    }] resume];
}

@end

// ============================================================================
// IMPLEMENTACIÓN NIVEL 2: DENTRO DEL CONTENEDOR (IG / REDDIT + TABS + DATOS)
// ============================================================================
@implementation IGFarmContainerDetailController

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.containerName) self.containerName = @"Default";
    self.title = [NSString stringWithFormat:@"📦 %@", self.containerName];

    if (self.parentRoot) {
        self.profile = [self.parentRoot ensureProfileForContainer:self.containerName forceRotate:NO];
    }

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)saveCurrentProfile {
    if (self.parentRoot && self.profile) {
        [self.parentRoot saveProfile:self.profile forContainer:self.containerName];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"1. APLICACIONES PROTEGIDAS EN ESTE CONTENEDOR";
        case 1: return @"2. CONFIGURACIÓN DE RED, REGIÓN Y MODELO";
        case 2: return @"3. MÓDULOS DE AISLAMIENTO ACTIVOS";
        case 3: return @"4. DATOS REALES INYECTADOS EN ESTE CONTENEDOR";
        case 4: return @"5. ROTACIÓN DE HUELLA Y AUDITORÍA";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 3;
        case 1: return 4;
        case 2: return 5;
        case 3: return 6;
        case 4: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL contOn = self.profile[@"enabled"] ? [self.profile[@"enabled"] boolValue] : YES;

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];

        if (indexPath.row == 0) {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = @"Estado General del Contenedor";
            cell.detailTextLabel.text = contOn ? @"🟢 Contenedor blindado" : @"⚪ Contenedor desactivado";
            sw.on = contOn;
            sw.tag = 100;
        } else if (indexPath.row == 1) {
            BOOL igOn = self.profile[@"enableIG"] ? [self.profile[@"enableIG"] boolValue] : YES;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"📸 Activar para Instagram";
            cell.detailTextLabel.text = (contOn && igOn) ? @"Inyectando huella aislada en Instagram" : @"Desactivado en Instagram";
            sw.on = igOn;
            sw.enabled = contOn;
            sw.tag = 101;
        } else {
            BOOL rdOn = self.profile[@"enableReddit"] ? [self.profile[@"enableReddit"] boolValue] : YES;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"🤖 Activar para Reddit";
            cell.detailTextLabel.text = (contOn && rdOn) ? @"Inyectando huella aislada en Reddit" : @"Desactivado en Reddit";
            sw.on = rdOn;
            sw.enabled = contOn;
            sw.tag = 102;
        }
        [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.detailTextLabel.textColor = [UIColor systemBlueColor];

        if (indexPath.row == 0) {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"📡 Operadora / Modo de Red";
            if ([self.profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Wi-Fi Puro Residencial (Sin SIM • %@)", [self.profile[@"CarrierISO"] ?: @"us" uppercaseString]];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"4G LTE %@ (MCC %@ / MNC %@)",
                                             self.profile[@"CarrierName"] ?: @"T-Mobile",
                                             self.profile[@"CarrierMCC"] ?: @"310",
                                             self.profile[@"CarrierMNC"] ?: @"260"];
            }
        } else if (indexPath.row == 1) {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"🌎 Zona Horaria e Idioma";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • Locale: %@",
                                         self.profile[@"timeZone"] ?: @"America/New_York",
                                         self.profile[@"localeID"] ?: @"en_US"];
        } else if (indexPath.row == 2) {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"📱 Modelo de iPhone en este Contenedor";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Identificador de Placa: %@", self.profile[@"deviceModel"] ?: @"iPhone14,5"];
        } else {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.text = @"⚡ Auto-Configurar según mi Proxy Actual";
            cell.detailTextLabel.text = self.profile[@"lastSyncedIP"]
                ? [NSString stringWithFormat:@"Sincronizado con IP: %@", self.profile[@"lastSyncedIP"]]
                : @"Detecta el ISP y país de tu proxy y ajusta este contenedor";
        }
        return cell;
    }

    if (indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSArray *titles = @[
            @"Camuflar IDs (IDFV / BootUUID / iCloud)",
            @"Camuflar Red Local y Ocultar VPN (utun)",
            @"Camuflar Zona Horaria e Idioma",
            @"Camuflar Hardware (Modelo / Disco / Batería)",
            @"Ocultar Jailbreak y Librerías de Crane"
        ];
        NSArray *keys = @[@"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity"];
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.textLabel.text = titles[indexPath.row];
        UISwitch *sw = [[UISwitch alloc] init];
        NSString *k = keys[indexPath.row];
        sw.on = self.profile[k] ? [self.profile[k] boolValue] : YES;
        sw.enabled = contOn;
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
            cell.textLabel.text = @"Vendor ID (IDFV Único del Contenedor)";
            cell.detailTextLabel.text = self.profile[@"idfv"] ?: @"N/A";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Kernel BootSession UUID (Aislado del Sistema)";
            cell.detailTextLabel.text = self.profile[@"bootSessionUUID"] ?: @"N/A";
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Hardware Inyectado (hw.machine / Disco / Batería)";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %.2f GB libres • Bat: %d%% • Vol: %d%%",
                                         self.profile[@"deviceModel"] ?: @"iPhone14,5", freeGB, batPct, volPct];
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"Operadora e Interfaz Celular (CoreTelephony)";
            if ([self.profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Modo Wi-Fi Puro (SIM oculta • ISO: %@)", [self.profile[@"CarrierISO"] ?: @"us" uppercaseString]];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"4G LTE %@ • MCC %@ / MNC %@ (%@)",
                                             self.profile[@"CarrierName"], self.profile[@"CarrierMCC"], self.profile[@"CarrierMNC"], [self.profile[@"CarrierISO"] uppercaseString]];
            }
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"Subred Local (en0) y Router Wi-Fi";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"LAN: %@ • SSID: %@ (%@)",
                                         self.profile[@"localIP"], self.profile[@"ssid"], self.profile[@"bssid"]];
        } else {
            cell.textLabel.text = @"Región Horaria y Desfase de Arranque (kern.boottime)";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@) • Uptime: +%lu min",
                                         self.profile[@"timeZone"], self.profile[@"localeID"], (unsigned long)upMin];
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.row == 0) {
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.textLabel.text = @"🔄 Regenerar Todos los IDs de este Contenedor";
    } else {
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.text = @"🔍 Auditar Contenedor + IP en VPS (Telegram)";
    }
    return cell;
}

- (void)toggleSwitch:(UISwitch *)sender {
    if (sender.tag == 100) {
        self.profile[@"enabled"] = @(sender.isOn);
    } else if (sender.tag == 101) {
        self.profile[@"enableIG"] = @(sender.isOn);
    } else if (sender.tag == 102) {
        self.profile[@"enableReddit"] = @(sender.isOn);
    } else if (sender.tag >= 200) {
        NSArray *keys = @[@"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity"];
        self.profile[keys[sender.tag - 200]] = @(sender.isOn);
    }
    [self saveCurrentProfile];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1) {
        if (indexPath.row == 0) [self showCarrierSelector];
        else if (indexPath.row == 1) [self showTimeZoneSelector];
        else if (indexPath.row == 2) [self showModelSelector];
        else [self autoSyncNetworkAndAuditOnVPS:NO];
        return;
    }

    if (indexPath.section == 4) {
        if (indexPath.row == 0) {
            self.profile = [self.parentRoot ensureProfileForContainer:self.containerName forceRotate:YES];
            [self.tableView reloadData];
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Huella Regenerada"
                                                                        message:@"Se generaron nuevos IDFV, BootSession UUID, Modelo, IP LAN, Router Wi-Fi y métricas de hardware para este contenedor."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        } else {
            [self autoSyncNetworkAndAuditOnVPS:YES];
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
        @{@"title": @"🛜 Wi-Fi Residencial Puro (Sin SIM)", @"mode": @"WIFI_ONLY", @"name": @"Wi-Fi", @"mcc": @"", @"mnc": @"", @"iso": @"us"},
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

- (void)showModelSelector {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Modelo de iPhone Simulado"
                                                                message:@"Selecciona qué placa reportará hw.machine y uname() en este contenedor:"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *models = @[
        @{@"title": @"📱 iPhone 14 Pro (iPhone15,2)", @"val": @"iPhone15,2"},
        @{@"title": @"📱 iPhone 13 Pro (iPhone14,2)", @"val": @"iPhone14,2"},
        @{@"title": @"📱 iPhone 13 (iPhone14,5)", @"val": @"iPhone14,5"},
        @{@"title": @"📱 iPhone 12 (iPhone13,2)", @"val": @"iPhone13,2"},
        @{@"title": @"📱 iPhone 11 (iPhone12,1)", @"val": @"iPhone12,1"},
        @{@"title": @"⚪ iPhone 8 Real (iPhone10,4)", @"val": @"iPhone10,4"}
    ];
    for (NSDictionary *m in models) {
        [ac addAction:[UIAlertAction actionWithTitle:m[@"title"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self.profile[@"deviceModel"] = m[@"val"];
            [self saveCurrentProfile];
            [self.tableView reloadData];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

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
        } else {
            self.profile[@"CarrierMode"] = @"WIFI_ONLY"; self.profile[@"CarrierName"] = @"Wi-Fi";
            self.profile[@"CarrierMCC"] = @""; self.profile[@"CarrierMNC"] = @""; self.profile[@"CarrierISO"] = cc;
        }

        [self saveCurrentProfile];

        if (!sendToVPS) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Contenedor Sincronizado"
                                                                            message:[NSString stringWithFormat:@"IP Detectada: %@ (%@)\n\nDatos aplicados al contenedor:\n• Red: %@ (%@)\n• Zona Horaria: %@\n• Locale: %@",
                                                                                     ip, ispRaw, self.profile[@"CarrierMode"], self.profile[@"CarrierName"], tz, self.profile[@"localeID"]]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
            return;
        }

        NSString *contEnc = [self.containerName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"Default";
        NSString *ispEnc = [ispRaw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
        NSString *vpsUrlStr = [NSString stringWithFormat:@"%@?ip=%@&contenedor=%@&plataforma=BOTH&choicy=1&bssid=%@&isp=%@&cc=%@",
                               VPS_AUDIT_URL, ip, contEnc, self.profile[@"bssid"] ?: @"", ispEnc, cc];

        [[session dataTaskWithURL:[NSURL URLWithString:vpsUrlStr] completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
            NSDictionary *vpsJson = vData ? [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil] : nil;
            NSString *msj = ([vpsJson isKindOfClass:[NSDictionary class]] && vpsJson[@"mensaje_iphone"])
                ? vpsJson[@"mensaje_iphone"]
                : [NSString stringWithFormat:@"IP: %@ (%@)\nSincronizado localmente en el contenedor.", ip, ispRaw];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Auditoría de Contenedor" message:msj preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
        }] resume];
    }] resume];
}

@end
