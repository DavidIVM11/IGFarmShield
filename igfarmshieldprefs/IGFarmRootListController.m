#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>

#define STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CHOICY_PLIST @"/var/jb/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define VPS_C2_URL @"http://162.35.105.151:5001/check_ip"

@interface IGFarmRootListController : UIViewController <UITableViewDelegate, UITableViewDataSource> {
    id _specifier;
    id _rootController;
    id _parentController;
}
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableDictionary *state;
@property (nonatomic, strong) NSMutableArray *containersList;
@property (nonatomic, assign) BOOL vpnActive;
@property (nonatomic, strong) NSString *vpnInterfaceName;
@property (nonatomic, strong) NSString *realLocalIP;
@property (nonatomic, strong) NSString *realHardwareModel;
@property (nonatomic, strong) NSString *realFreeDisk;
@end

@implementation IGFarmRootListController

- (void)setSpecifier:(id)specifier { _specifier = specifier; }
- (id)specifier { return _specifier; }
- (void)setRootController:(id)rc { _rootController = rc; }
- (id)rootController { return _rootController; }
- (void)setParentController:(id)pc { _parentController = pc; }
- (id)parentController { return _parentController; }
- (void)handleURL:(NSDictionary *)url {}
- (BOOL)canBeShownFromSuspendedState { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"IGFarmShield v3.0";
    self.state = [NSMutableDictionary dictionaryWithContentsOfFile:STATE_PLIST] ?: [NSMutableDictionary dictionary];

    if (!self.state[@"enableIG"]) self.state[@"enableIG"] = @YES;
    if (!self.state[@"enableReddit"]) self.state[@"enableReddit"] = @YES;
    [self saveState];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    [self refreshRealPhoneTelemetry];
    [self scanAllRealContainersOnDisk];
    [self auditProxyAndSyncCarrierSilently:YES];
}

- (void)saveState {
    [self.state writeToFile:STATE_PLIST atomically:YES];
}

- (void)refreshRealPhoneTelemetry {
    size_t size = 0;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    if (size > 0) {
        char *machine = malloc(size);
        sysctlbyname("hw.machine", machine, &size, NULL, 0);
        self.realHardwareModel = [NSString stringWithUTF8String:machine];
        free(machine);
    } else {
        self.realHardwareModel = @"iPhone10,4";
    }

    NSDictionary *fsAttr = [[NSFileManager defaultManager] attributesOfFileSystemForPath:@"/var/mobile" error:nil];
    unsigned long long freeBytes = [fsAttr[NSFileSystemFreeSize] unsignedLongLongValue];
    unsigned long long totalBytes = [fsAttr[NSFileSystemSize] unsignedLongLongValue];
    self.realFreeDisk = [NSString stringWithFormat:@"%.2f GB libres de %.0f GB",
                         (double)freeBytes / (1024.0*1024.0*1024.0),
                         (double)totalBytes / (1024.0*1024.0*1024.0)];

    self.vpnActive = NO;
    self.vpnInterfaceName = @"Ninguno";
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

                if ([ifName isEqualToString:@"en0"]) {
                    self.realLocalIP = ipStr;
                } else if ([ifName hasPrefix:@"utun"] || [ifName hasPrefix:@"ppp"] || [ifName hasPrefix:@"ipsec"]) {
                    if (![ipStr hasPrefix:@"127."] && ![ipStr hasPrefix:@"169.254."]) {
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

// Crea o lee el archivo .igshield_container.plist directamente dentro de la carpeta del contenedor
- (NSMutableDictionary *)ensureProfileForContainerPath:(NSString *)containerPath forceRotate:(BOOL)rotate {
    NSString *profilePath = [containerPath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
    NSMutableDictionary *profile = [NSMutableDictionary dictionaryWithContentsOfFile:profilePath];

    if (!profile || !profile[@"idfv"] || rotate) {
        NSUInteger seed = [containerPath hash] ^ (NSUInteger)([[NSDate date] timeIntervalSince1970] * 1000) ^ arc4random();
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
            @"CarrierMode": self.state[@"CarrierMode"] ?: @"CELLULAR",
            @"CarrierName": self.state[@"CarrierName"] ?: @"T-Mobile",
            @"CarrierMCC": self.state[@"CarrierMCC"] ?: @"310",
            @"CarrierMNC": self.state[@"CarrierMNC"] ?: @"260",
            @"CarrierISO": self.state[@"CarrierISO"] ?: @"us"
        } mutableCopy];

        [[NSFileManager defaultManager] createDirectoryAtPath:[containerPath stringByAppendingPathComponent:@"Library"]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [profile writeToFile:profilePath atomically:YES];
    }
    return profile;
}

// Escanea directamente el sistema de archivos en busca de contenedores de Instagram, Reddit y Crane
- (void)scanAllRealContainersOnDisk {
    self.containersList = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
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

        NSString *platformName = isIG ? @"📸 Instagram" : @"🤖 Reddit";
        NSString *craneName = meta[@"com.opa334.crane.container.name"] ?: @"Default";
        NSString *shortUUID = [uuid substringToIndex:MIN(8, uuid.length)];

        NSMutableDictionary *prof = [self ensureProfileForContainerPath:fullPath forceRotate:NO];
        [self.containersList addObject:@{
            @"title": [NSString stringWithFormat:@"%@ [%@] (%@)", platformName, craneName, shortUUID],
            @"path": fullPath,
            @"uuid": uuid,
            @"profile": prof
        }];

        // Verificar si hay subcontenedores adicionales dentro de ___Crane_Containers
        NSString *subCraneDir = [fullPath stringByAppendingPathComponent:@"___Crane_Containers"];
        if ([fm fileExistsAtPath:subCraneDir]) {
            NSArray *subUUIDs = [fm contentsOfDirectoryAtPath:subCraneDir error:nil];
            for (NSString *sub in subUUIDs) {
                NSString *subPath = [subCraneDir stringByAppendingPathComponent:sub];
                NSMutableDictionary *subProf = [self ensureProfileForContainerPath:subPath forceRotate:NO];
                [self.containersList addObject:@{
                    @"title": [NSString stringWithFormat:@"%@ [Crane: %@]", platformName, [sub substringToIndex:MIN(8, sub.length)]],
                    @"path": subPath,
                    @"uuid": sub,
                    @"profile": subProf
                }];
            }
        }
    }

    // Escanear también la ruta alternativa de contenedores de Crane en Application Support
    NSString *altCraneBase = @"/var/mobile/Library/Application Support/Crane/Containers";
    for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
        NSString *bPath = [altCraneBase stringByAppendingPathComponent:bID];
        if ([fm fileExistsAtPath:bPath]) {
            NSArray *cDirs = [fm contentsOfDirectoryAtPath:bPath error:nil];
            for (NSString *cName in cDirs) {
                NSString *cFullPath = [bPath stringByAppendingPathComponent:cName];
                NSMutableDictionary *cProf = [self ensureProfileForContainerPath:cFullPath forceRotate:NO];
                NSString *pName = [bID containsString:@"instagram"] ? @"📸 IG Crane" : @"🤖 Reddit Crane";
                [self.containersList addObject:@{
                    @"title": [NSString stringWithFormat:@"%@ [%@]", pName, cName],
                    @"path": cFullPath,
                    @"uuid": cName,
                    @"profile": cProf
                }];
            }
        }
    }
}

- (NSString *)checkChoicyStatus {
    NSDictionary *choicy = [NSDictionary dictionaryWithContentsOfFile:CHOICY_PLIST];
    if (!choicy) return @"⚠️ Sin configurar";
    return @"✅ Choicy Detectado";
}

#pragma mark - TableView DataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"1. TELEMETRÍA REAL DEL IPHONE (EN VIVO)";
        case 1: return @"2. ESTADO REAL DE RED, VPN Y PROXY";
        case 2: return [NSString stringWithFormat:@"3. CONTENEDORES DETECTADOS (%lu) - TOCA UN CONTENEDOR", (unsigned long)self.containersList.count];
        case 3: return @"4. AUDITORÍA DE RED Y LIMPIEZA (64GB)";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 5;
        case 1: return 4;
        case 2: return MAX(1, self.containersList.count);
        case 3: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Placa / Modelo Real";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (iPhone 8)", self.realHardwareModel];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Disco Real (64GB)";
            cell.detailTextLabel.text = self.realFreeDisk;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Estado Choicy";
            cell.detailTextLabel.text = [self checkChoicyStatus];
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"Activar en Instagram";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [self.state[@"enableIG"] boolValue];
            sw.tag = 101;
            [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"Activar en Reddit";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [self.state[@"enableReddit"] boolValue];
            sw.tag = 102;
            [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Túnel VPN (Shadowrocket)";
            if (self.vpnActive) {
                cell.detailTextLabel.textColor = [UIColor systemGreenColor];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"🟢 ACTIVO (%@)", self.vpnInterfaceName];
            } else {
                cell.detailTextLabel.textColor = [UIColor systemRedColor];
                cell.detailTextLabel.text = @"⚠️ APAGADO (Wi-Fi Directo)";
            }
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"IP / ISP Real Actual";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)",
                                         self.state[@"last_ip"] ?: @"Consultando...",
                                         self.state[@"last_isp"] ?: @"..."];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Operadora p/ Contenedores";
            if (!self.vpnActive) {
                cell.detailTextLabel.text = @"⚠️ Enciende el VPN primero";
            } else if ([self.state[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Wi-Fi Residencial (%@)", self.state[@"CarrierISO"] ?: @"us"];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"4G %@ (%@/%@)",
                                             self.state[@"CarrierName"] ?: @"T-Mobile",
                                             self.state[@"CarrierMCC"] ?: @"310",
                                             self.state[@"CarrierMNC"] ?: @"260"];
            }
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"IP Wi-Fi Real (en0)";
            cell.detailTextLabel.text = self.realLocalIP;
        }
    } else if (indexPath.section == 2) {
        if (self.containersList.count == 0) {
            cell.textLabel.text = @"No se detectaron contenedores de IG/Reddit";
            cell.detailTextLabel.text = @"Instala IG o Reddit";
        } else {
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            NSDictionary *item = self.containersList[indexPath.row];
            NSDictionary *prof = item[@"profile"];
            cell.textLabel.text = item[@"title"];
            NSString *shortIDFV = [prof[@"idfv"] substringToIndex:8];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"IDFV: %@... | %@", shortIDFV, prof[@"bssid"]];
        }
    } else if (indexPath.section == 3) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.textColor = [UIColor systemBlueColor];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"🔍 Auditar Red en Vivo y Sincronizar Contenedores";
        } else if (indexPath.row == 1) {
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.textLabel.text = @"🧹 Purgar Caché de Todos los Contenedores (64GB)";
        }
    }
    return cell;
}

- (void)toggleSwitch:(UISwitch *)sender {
    if (sender.tag == 101) self.state[@"enableIG"] = @(sender.isOn);
    if (sender.tag == 102) self.state[@"enableReddit"] = @(sender.isOn);
    [self saveState];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    // Al tocar un contenedor específico de la lista
    if (indexPath.section == 2 && self.containersList.count > 0) {
        NSDictionary *item = self.containersList[indexPath.row];
        NSDictionary *prof = item[@"profile"];
        double freeGB = [prof[@"freeBytes"] unsignedLongLongValue] / (1024.0*1024.0*1024.0);
        NSUInteger upMin = [prof[@"uptimeOffset"] unsignedIntegerValue] / 60;
        int batPct = (int)([prof[@"batteryLevel"] floatValue] * 100.0f);

        NSString *msg = [NSString stringWithFormat:
            @"🔑 Vendor ID (IDFV):\n%@\n\n"
            @"☁️ iCloud Token:\n%@\n\n"
            @"📡 Router BSSID: %@\n"
            @"📶 Wi-Fi SSID: %@\n"
            @"🌐 IP Local (en0): %@\n"
            @"💾 Espacio Libre Fijo: %.2f GB\n"
            @"🔋 Batería Simulada: %d%%\n"
            @"⏱ Desfase BootTime: +%lu min\n\n"
            @"📂 Ruta: %@",
            prof[@"idfv"], prof[@"cloudUUID"], prof[@"bssid"], prof[@"ssid"],
            prof[@"localIP"], freeGB, batPct, (unsigned long)upMin, item[@"uuid"]];

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:item[@"title"]
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];

        [ac addAction:[UIAlertAction actionWithTitle:@"🔄 Rotar Huella SOLO de este Contenedor"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *action) {
            [self ensureProfileForContainerPath:item[@"path"] forceRotate:YES];
            [self scanAllRealContainersOnDisk];
            [self.tableView reloadData];
            [self showAlert:@"Huella Renovada"
                        msg:[NSString stringWithFormat:@"Se generó un nuevo IDFV, BSSID, IP local y espacio en disco únicamente para:\n%@\n\nTus demás contenedores siguen intactos.", item[@"title"]]];
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"Cerrar" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            [self refreshRealPhoneTelemetry];
            [self scanAllRealContainersOnDisk];
            [self.tableView reloadData];
            [self auditProxyAndSyncCarrierSilently:NO];
        } else if (indexPath.row == 1) {
            [self purgeContainersCache];
        }
    }
}

- (void)auditProxyAndSyncCarrierSilently:(BOOL)silent {
    NSURL *url = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,countryCode,city,isp,query"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 5.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) {
            self.state[@"last_ip"] = @"Sin conexión";
            self.state[@"last_isp"] = @"Offline";
            [self saveState];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                if (!silent) [self showAlert:@"Error de Red" msg:@"No hay salida a internet."];
            });
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *ip = json[@"query"] ?: @"Desconocida";
        NSString *ispRaw = json[@"isp"] ?: @"ISP";
        NSString *isp = [ispRaw uppercaseString];
        NSString *cc = [json[@"countryCode"] lowercaseString] ?: @"us";

        self.state[@"last_ip"] = ip;
        self.state[@"last_isp"] = [NSString stringWithFormat:@"%@ (%@)", ispRaw, [cc uppercaseString]];

        if ([isp containsString:@"T-MOBILE"] || [isp containsString:@"METRO"] || [isp containsString:@"MINT"]) {
            self.state[@"CarrierMode"] = @"CELLULAR";
            self.state[@"CarrierName"] = @"T-Mobile";
            self.state[@"CarrierMCC"] = @"310";
            self.state[@"CarrierMNC"] = @"260";
            self.state[@"CarrierISO"] = @"us";
        } else if ([isp containsString:@"AT&T"] || [isp containsString:@"CRICKET"]) {
            self.state[@"CarrierMode"] = @"CELLULAR";
            self.state[@"CarrierName"] = @"AT&T";
            self.state[@"CarrierMCC"] = @"310";
            self.state[@"CarrierMNC"] = @"410";
            self.state[@"CarrierISO"] = @"us";
        } else if ([isp containsString:@"VERIZON"] || [isp containsString:@"VISIBLE"]) {
            self.state[@"CarrierMode"] = @"CELLULAR";
            self.state[@"CarrierName"] = @"Verizon";
            self.state[@"CarrierMCC"] = @"311";
            self.state[@"CarrierMNC"] = @"480";
            self.state[@"CarrierISO"] = @"us";
        } else {
            self.state[@"CarrierMode"] = @"WIFI_ONLY";
            self.state[@"CarrierName"] = @"Wi-Fi";
            self.state[@"CarrierMCC"] = @"";
            self.state[@"CarrierMNC"] = @"";
            self.state[@"CarrierISO"] = cc;
        }

        [self saveState];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshRealPhoneTelemetry];
            [self scanAllRealContainersOnDisk];
            [self.tableView reloadData];
            if (!silent) {
                NSString *vpnState = self.vpnActive ? @"🟢 VPN Shadowrocket Activo" : @"⚠️ ¡ALERTA! VPN APAGADO (Saliendo con tu IP doméstica)";
                [self showAlert:@"Auditoría en Vivo"
                            msg:[NSString stringWithFormat:@"%@\n\nIP Saliente: %@\nISP Real: %@\nPaís: %@\nContenedores Sincronizados: %lu",
                                 vpnState, ip, ispRaw, [cc uppercaseString], (unsigned long)self.containersList.count]];
            }
        });
    }] resume];
}

- (void)purgeContainersCache {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger cleaned = 0;
    for (NSDictionary *item in self.containersList) {
        NSString *cachePath = [item[@"path"] stringByAppendingPathComponent:@"Library/Caches"];
        if ([fm fileExistsAtPath:cachePath]) {
            NSArray *files = [fm contentsOfDirectoryAtPath:cachePath error:nil];
            for (NSString *f in files) {
                [fm removeItemAtPath:[cachePath stringByAppendingPathComponent:f] error:nil];
                cleaned++;
            }
        }
    }
    [self refreshRealPhoneTelemetry];
    [self.tableView reloadData];
    [self showAlert:@"Caché Purgada (64GB Safe)"
                msg:[NSString stringWithFormat:@"Se eliminaron %lu archivos temporales en tus contenedores sin tocar las sesiones.\nEspacio libre actual: %@", (unsigned long)cleaned, self.realFreeDisk]];
}

- (void)showAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
