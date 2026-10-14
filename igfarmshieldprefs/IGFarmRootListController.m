#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>

#define STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CHOICY_PLIST @"/var/jb/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define VPS_AUDIT_URL @"http://162.35.105.151:5001/iphone_audit"

@class IGFarmRootListController;

@interface PSViewController : UIViewController {
    id _specifier;
    id _rootController;
    id _parentController;
}
- (void)setSpecifier:(id)specifier;
- (id)specifier;
- (void)setRootController:(id)rc;
- (id)rootController;
- (void)setParentController:(id)pc;
- (id)parentController;
- (void)handleURL:(NSDictionary *)url;
- (BOOL)canBeShownFromSuspendedState;
@end

@interface IGFarmContainerDetailController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSDictionary *containerItem;
@property (nonatomic, strong) NSMutableDictionary *profile;
@property (nonatomic, assign) BOOL isIG;
@property (nonatomic, weak) IGFarmRootListController *parentRoot;
@property (nonatomic, strong) UITableView *tableView;
@end

@interface IGFarmAppContainersController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSString *appTitle;
@property (nonatomic, strong) NSString *stateKey;
@property (nonatomic, assign) BOOL isIG;
@property (nonatomic, strong) NSMutableDictionary *state;
@property (nonatomic, strong) NSMutableArray *appContainers;
@property (nonatomic, weak) IGFarmRootListController *parentRoot;
@property (nonatomic, strong) UITableView *tableView;
@end

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
@property (nonatomic, strong) NSString *realBootUUID;
@property (nonatomic, strong) NSString *realTimeZone;
@property (nonatomic, assign) int realBatteryPct;
- (void)saveState;
- (void)scanAllRealContainersOnDisk;
- (BOOL)auditChoicyConfiguration;
- (NSMutableDictionary *)ensureProfileForContainerPath:(NSString *)containerPath forceRotate:(BOOL)rotate;
@end

// ============================================================================
// NIVEL 3: CONFIGURACIÓN INDIVIDUAL DE UN CONTENEDOR (CRANE ID + SHIELD ID)
// ============================================================================
@implementation IGFarmContainerDetailController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.containerItem[@"title"];
    self.profile = self.containerItem[@"profile"];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)saveContainerProfile {
    NSString *profilePath = [self.containerItem[@"path"] stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
    [self.profile writeToFile:profilePath atomically:YES];
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
        case 0: return @"1. ESTADO DE ESTE CONTENEDOR";
        case 1: return @"2. MÓDULOS DE SEGURIDAD (INDEPENDIENTES)";
        case 2: return @"3. AUDITORÍA VPS + TELEGRAM Y RED DEL CONTENEDOR";
        case 3: return @"4. ID DE CRANE + NUEVOS IDs DE IGFARMSHIELD";
        case 4: return @"5. ACCIONES DE ESTE CONTENEDOR";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;
        case 1: return 5;
        case 2: return 3;
        case 3: return 9;
        case 4: return 1;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;

    BOOL contOn = self.profile[@"enabled"] ? [self.profile[@"enabled"] boolValue] : YES;

    if (indexPath.section == 0) {
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        cell.textLabel.text = @"Activar Escudo en este Contenedor";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = contOn;
        sw.tag = 200;
        [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if (indexPath.section == 1) {
        NSArray *titles = @[
            @"Spoof IDs (IDFV / BootUUID / iCloud)",
            @"Spoof Red Local y Ocultar VPN",
            @"Spoof Zona Horaria e Idioma",
            @"Spoof Hardware (Disco / Batería / Audio)",
            @"Escudos (Passcode / HideCrane / No-Push)"
        ];
        NSArray *keys = @[@"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity"];
        cell.textLabel.text = titles[indexPath.row];
        UISwitch *sw = [[UISwitch alloc] init];
        NSString *k = keys[indexPath.row];
        sw.on = self.profile[k] ? [self.profile[k] boolValue] : YES;
        sw.enabled = contOn;
        sw.tag = 201 + indexPath.row;
        [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if (indexPath.section == 2) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"🔍 Auditar Contenedor + IP en Proxy Center (TG)";
            cell.detailTextLabel.text = self.profile[@"lastAuditVerdict"] ?: @"Verificar";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"📡 Operadora / Modo de Red";
            if (![self isModOn:@"spoofNetwork"]) {
                cell.detailTextLabel.text = @"⚪ Sistema Real";
            } else if ([self.profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"🛜 Wi-Fi Puro (%@)", [self.profile[@"CarrierISO"] ?: @"us" uppercaseString]];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"📱 4G %@ (%@/%@)",
                                             self.profile[@"CarrierName"] ?: @"T-Mobile",
                                             self.profile[@"CarrierMCC"] ?: @"310",
                                             self.profile[@"CarrierMNC"] ?: @"260"];
            }
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"🌎 Zona Horaria y Región";
            if (![self isModOn:@"spoofLocation"] || [self.profile[@"timeZone"] isEqualToString:@"REAL"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"⚪ Real (%@)", self.parentRoot.realTimeZone];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)",
                                             self.profile[@"timeZone"] ?: @"America/New_York",
                                             self.profile[@"localeID"] ?: @"en_US"];
            }
        }
    } else if (indexPath.section == 3) {
        double freeGB = [self.profile[@"freeBytes"] unsignedLongLongValue] / (1024.0*1024.0*1024.0);
        int batPct = (int)([self.profile[@"batteryLevel"] floatValue] * 100.0f);
        int volPct = (int)([self.profile[@"audioVolume"] floatValue] * 100.0f);
        NSUInteger upMin = [self.profile[@"uptimeOffset"] unsignedIntegerValue] / 60;
        NSString *craneID = self.profile[@"craneContainerID"] ?: self.containerItem[@"uuid"];
        NSString *shieldDevID = self.profile[@"shieldDeviceID"] ?: self.profile[@"cloudUUID"];

        if (indexPath.row == 0) {
            cell.textLabel.text = @"🆔 ID Contenedor (Crane)";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"📦 %@", [craneID substringToIndex:MIN(14, craneID.length)]];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"🛡️ Nuevo Device ID (Shield)";
            cell.detailTextLabel.text = [self isModOn:@"spoofIDs"] ? [NSString stringWithFormat:@"🟢 %@", [shieldDevID substringToIndex:MIN(13, shieldDevID.length)]] : @"⚪ Desactivado";
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"🔑 Nuevo Vendor ID (IDFV)";
            cell.detailTextLabel.text = [self isModOn:@"spoofIDs"] ? [NSString stringWithFormat:@"🟢 %@", [self.profile[@"idfv"] substringToIndex:13]] : @"⚪ IDFV Base de Crane";
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"🔄 BootSession UUID";
            cell.detailTextLabel.text = [self isModOn:@"spoofIDs"] ? [NSString stringWithFormat:@"🟢 %@", [self.profile[@"bootSessionUUID"] substringToIndex:13]] : @"⚪ Real";
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"📡 Router Wi-Fi (BSSID)";
            cell.detailTextLabel.text = [self isModOn:@"spoofNetwork"] ? [NSString stringWithFormat:@"🟢 %@ (%@)", self.profile[@"bssid"], self.profile[@"ssid"]] : @"⚪ Router Real";
        } else if (indexPath.row == 5) {
            cell.textLabel.text = @"💻 IP Local (en0)";
            cell.detailTextLabel.text = [self isModOn:@"spoofNetwork"] ? [NSString stringWithFormat:@"🟢 %@", self.profile[@"localIP"]] : [NSString stringWithFormat:@"⚪ Real (%@)", self.parentRoot.realLocalIP];
        } else if (indexPath.row == 6) {
            cell.textLabel.text = @"💾 Espacio Libre (64GB)";
            cell.detailTextLabel.text = [self isModOn:@"spoofHardware"] ? [NSString stringWithFormat:@"🟢 %.2f GB libres", freeGB] : [NSString stringWithFormat:@"⚪ Real (%@)", self.parentRoot.realFreeDisk];
        } else if (indexPath.row == 7) {
            cell.textLabel.text = @"🔋 Batería / Audio";
            cell.detailTextLabel.text = [self isModOn:@"spoofHardware"] ? [NSString stringWithFormat:@"🟢 Bat: %d%% | Vol: %d%%", batPct, volPct] : [NSString stringWithFormat:@"⚪ Bat Real: %d%%", self.parentRoot.realBatteryPct];
        } else if (indexPath.row == 8) {
            cell.textLabel.text = @"⏱️ Desfase Uptime/Boot";
            cell.detailTextLabel.text = [self isModOn:@"spoofHardware"] ? [NSString stringWithFormat:@"🟢 +%lu min", (unsigned long)upMin] : @"⚪ Uptime Real";
        }
    } else if (indexPath.section == 4) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.text = @"🔄 Regenerar Huella (IDFV/ShieldID/MAC/IP) en esta Cuenta";
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

    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            [self auditAndSyncWithProxyCenterVPS];
        } else if (indexPath.row == 1) {
            [self showCarrierSelector];
        } else if (indexPath.row == 2) {
            [self showTimeZoneSelector];
        }
    } else if (indexPath.section == 4 && indexPath.row == 0) {
        self.profile = [self.parentRoot ensureProfileForContainerPath:self.containerItem[@"path"] forceRotate:YES];
        [self.parentRoot scanAllRealContainersOnDisk];
        [self.tableView reloadData];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Huella Regenerada"
                                                                    message:@"Se generaron nuevos identificadores (Shield Device ID, IDFV, BootUUID, BSSID e IP local) manteniendo intacto el contenedor de Crane."
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

// Conecta con ip-api + tu VPS (162.35.105.151:5001/iphone_audit), sincroniza Operadora/Wi-Fi y envía alerta a Telegram
- (void)auditAndSyncWithProxyCenterVPS {
    NSURL *ipUrl = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,countryCode,city,timezone,isp,query"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 6.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:ipUrl completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Error de Red" message:@"No se pudo detectar la IP saliente de Shadowrocket." preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
            return;
        }

        NSDictionary *ipJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *ip = ipJson[@"query"] ?: @"";
        NSString *ispRaw = ipJson[@"isp"] ?: @"ISP";
        NSString *cc = [ipJson[@"countryCode"] lowercaseString] ?: @"us";
        NSString *tz = ipJson[@"timezone"] ?: @"America/New_York";

        self.profile[@"lastSyncedIP"] = ip;
        self.profile[@"timeZone"] = tz;
        self.profile[@"localeID"] = [NSString stringWithFormat:@"en_%@", [cc uppercaseString]];

        // Ahora consultamos al Proxy Center en tu VPS para verificar Google Sheets y enviar alerta a Telegram
        BOOL choicyOK = [self.parentRoot auditChoicyConfiguration];
        NSString *plat = self.isIG ? @"INSTAGRAM" : @"REDDIT";
        NSString *contName = [self.containerItem[@"title"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"Container";
        NSString *ispEnc = [ispRaw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
        NSString *bssidEnc = [self.profile[@"bssid"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";

        NSString *vpsUrlStr = [NSString stringWithFormat:@"%@?ip=%@&contenedor=%@&plataforma=%@&choicy=%d&bssid=%@&isp=%@&cc=%@",
                               VPS_AUDIT_URL, ip, contName, plat, choicyOK ? 1 : 0, bssidEnc, ispEnc, cc];
        NSURL *vpsUrl = [NSURL URLWithString:vpsUrlStr];

        [[session dataTaskWithURL:vpsUrl completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
            NSDictionary *vpsJson = vData ? [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil] : nil;
            NSDictionary *carrierProf = vpsJson[@"carrier_profile"];

            if (carrierProf) {
                self.profile[@"CarrierMode"] = carrierProf[@"modo"] ?: @"CELLULAR";
                self.profile[@"CarrierName"] = carrierProf[@"name"] ?: @"T-Mobile";
                self.profile[@"CarrierMCC"] = carrierProf[@"mcc"] ?: @"310";
                self.profile[@"CarrierMNC"] = carrierProf[@"mnc"] ?: @"260";
                self.profile[@"CarrierISO"] = carrierProf[@"iso"] ?: cc;
            }

            NSString *icono = vpsJson[@"icono"] ?: @"🟢";
            NSString *status = vpsJson[@"status"] ?: @"LOCAL";
            NSString *msjIphone = vpsJson[@"mensaje_iphone"] ?: [NSString stringWithFormat:@"IP: %@ (%@)\nSincronizado localmente (VPS sin respuesta en puerto 5001).", ip, ispRaw];

            self.profile[@"lastAuditVerdict"] = [NSString stringWithFormat:@"%@ %@", icono, status];
            [self saveContainerProfile];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ Auditoría: %@", icono, status]
                                                                            message:[NSString stringWithFormat:@"%@\n\nISP: %@\nModo Inyectado: %@ (%@)\nZona Horaria: %@\n\n(Notificación enviada a Telegram Topic 157)",
                                                                                     msjIphone, ispRaw, self.profile[@"CarrierMode"], self.profile[@"CarrierName"], tz]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"Aceptar" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
        }] resume];
    }] resume];
}

- (void)showCarrierSelector {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Seleccionar Operadora / Red"
                                                                message:@"Elige qué tipo de conexión verá la app en este contenedor:"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *presets = @[
        @{@"title": @"📱 T-Mobile US 4G (310 / 260)", @"mode": @"CELLULAR", @"name": @"T-Mobile", @"mcc": @"310", @"mnc": @"260", @"iso": @"us"},
        @{@"title": @"📱 AT&T US 4G (310 / 410)", @"mode": @"CELLULAR", @"name": @"AT&T", @"mcc": @"310", @"mnc": @"410", @"iso": @"us"},
        @{@"title": @"📱 Verizon US 4G (311 / 480)", @"mode": @"CELLULAR", @"name": @"Verizon", @"mcc": @"311", @"mnc": @"480", @"iso": @"us"},
        @{@"title": @"🛜 Proxy Residencial / Wi-Fi Puro (Sin SIM)", @"mode": @"WIFI_ONLY", @"name": @"Wi-Fi", @"mcc": @"", @"mnc": @"", @"iso": @"us"},
        @{@"title": @"🇬🇧 Vodafone UK 4G (234 / 15)", @"mode": @"CELLULAR", @"name": @"Vodafone UK", @"mcc": @"234", @"mnc": @"15", @"iso": @"gb"},
        @{@"title": @"🇪🇸 Movistar ES 4G (214 / 07)", @"mode": @"CELLULAR", @"name": @"Movistar", @"mcc": @"214", @"mnc": @"07", @"iso": @"es"}
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
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Zona Horaria y Región del Contenedor"
                                                                message:@"Elige la zona horaria según el proxy que uses en esta cuenta:"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *zones = @[
        @{@"title": @"🇺🇸 USA Este - Miami / NY (America/New_York)", @"tz": @"America/New_York", @"loc": @"en_US"},
        @{@"title": @"🇺🇸 USA Centro - Texas / Chicago (America/Chicago)", @"tz": @"America/Chicago", @"loc": @"en_US"},
        @{@"title": @"🇺🇸 USA Montaña - Denver (America/Denver)", @"tz": @"America/Denver", @"loc": @"en_US"},
        @{@"title": @"🇺🇸 USA Oeste - Los Ángeles (America/Los_Angeles)", @"tz": @"America/Los_Angeles", @"loc": @"en_US"},
        @{@"title": @"🇬🇧 Reino Unido - Londres (Europe/London)", @"tz": @"Europe/London", @"loc": @"en_GB"},
        @{@"title": @"🇪🇸 España - Madrid (Europe/Madrid)", @"tz": @"Europe/Madrid", @"loc": @"es_ES"},
        @{@"title": @"⚪ Usar Reloj e Idioma Real del iPhone", @"tz": @"REAL", @"loc": @"REAL"}
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

// ============================================================================
// NIVEL 2: SUB-CONTROLADOR POR APP (INSTAGRAM / REDDIT)
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
    [self.parentRoot scanAllRealContainersOnDisk];
    self.appContainers = self.isIG ? self.parentRoot.igContainers : self.parentRoot.redditContainers;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"INTERRUPTOR DE LA APLICACIÓN";
    return [NSString stringWithFormat:@"CONTENEDORES (%lu) - TOCA UNO PARA CONFIGURARLO", (unsigned long)self.appContainers.count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return MAX(1, self.appContainers.count);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    BOOL masterOn = [self.state[@"masterEnabled"] boolValue];
    BOOL appOn = [self.state[self.stateKey] boolValue];

    if (indexPath.section == 0) {
        cell.textLabel.text = [NSString stringWithFormat:@"Habilitar en %@", self.appTitle];
        cell.detailTextLabel.text = (masterOn && appOn) ? @"🟢 Activo" : @"⚪ Apagado (Datos Reales del Sistema)";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = appOn;
        sw.enabled = masterOn;
        [sw addTarget:self action:@selector(toggleAppSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (self.appContainers.count == 0) {
        cell.textLabel.text = @"No se detectaron contenedores aún";
        cell.detailTextLabel.text = @"Abre la app una vez con el tweak activo o crea contenedores en Crane";
        return cell;
    }

    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    NSDictionary *item = self.appContainers[indexPath.row];
    NSMutableDictionary *prof = item[@"profile"];
    BOOL containerOn = prof[@"enabled"] ? [prof[@"enabled"] boolValue] : YES;
    BOOL effectivelyActive = masterOn && appOn && containerOn;

    cell.textLabel.text = item[@"title"];
    if (effectivelyActive) {
        cell.detailTextLabel.textColor = [UIColor systemGreenColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"🛡️ %@ | %@ | IDFV: %@... | Shield: %@...",
                                     prof[@"CarrierName"] ?: @"T-Mobile",
                                     prof[@"localIP"],
                                     [prof[@"idfv"] substringToIndex:6],
                                     [(prof[@"shieldDeviceID"] ?: prof[@"cloudUUID"]) substringToIndex:6]];
    } else {
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"⚪ Usando Sistema Real (%@)", self.parentRoot.realLocalIP];
    }

    return cell;
}

- (void)toggleAppSwitch:(UISwitch *)sender {
    self.state[self.stateKey] = @(sender.isOn);
    [self.parentRoot saveState];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || self.appContainers.count == 0) return;

    IGFarmContainerDetailController *detailVC = [[IGFarmContainerDetailController alloc] init];
    detailVC.containerItem = self.appContainers[indexPath.row];
    detailVC.isIG = self.isIG;
    detailVC.parentRoot = self.parentRoot;
    [self.navigationController pushViewController:detailVC animated:YES];
}

@end

// ============================================================================
// NIVEL 1: MENÚ RAÍZ + AUDITOR DE CHOICY Y CONEXIÓN VPS
// ============================================================================
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
    self.title = @"IGFarmShield";
    self.state = [NSMutableDictionary dictionaryWithContentsOfFile:STATE_PLIST] ?: [NSMutableDictionary dictionary];

    if (!self.state[@"masterEnabled"]) self.state[@"masterEnabled"] = @YES;
    if (!self.state[@"enableIG"]) self.state[@"enableIG"] = @YES;
    if (!self.state[@"enableReddit"]) self.state[@"enableReddit"] = @YES;
    [self saveState];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    [self auditChoicyConfiguration];
    [self refreshRealPhoneTelemetry];
    [self scanAllRealContainersOnDisk];
    [self auditProxyAndSyncCarrierSilently:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
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
        self.choicyStatusText = @"⚠️ Choicy no configurado aún";
        return NO;
    }
    NSDictionary *appSettings = choicy[@"appSettings"];
    NSDictionary *igCfg = appSettings[@"com.burbn.instagram"];
    NSDictionary *rdCfg = appSettings[@"com.reddit.Reddit"];

    BOOL igHasCustom = (igCfg != nil);
    BOOL rdHasCustom = (rdCfg != nil);

    if (igHasCustom || rdHasCustom) {
        self.choicySafe = YES;
        self.choicyStatusText = @"🟢 Blindado (Whitelist Activa)";
        return YES;
    }
    self.choicySafe = NO;
    self.choicyStatusText = @"🟡 Configura Allowlist en Choicy";
    return NO;
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

    size_t uuidSize = 0;
    sysctlbyname("kern.bootsessionuuid", NULL, &uuidSize, NULL, 0);
    if (uuidSize > 0) {
        char *bUuid = malloc(uuidSize);
        sysctlbyname("kern.bootsessionuuid", bUuid, &uuidSize, NULL, 0);
        self.realBootUUID = [NSString stringWithUTF8String:bUuid];
        free(bUuid);
    } else {
        self.realBootUUID = @"Nativo";
    }

    self.realTimeZone = [[NSTimeZone localTimeZone] name] ?: @"Local";

    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    float rawBat = [UIDevice currentDevice].batteryLevel;
    self.realBatteryPct = (rawBat > 0) ? (int)(rawBat * 100.0f) : 50;

    NSDictionary *fsAttr = [[NSFileManager defaultManager] attributesOfFileSystemForPath:@"/var/mobile" error:nil];
    unsigned long long freeBytes = [fsAttr[NSFileSystemFreeSize] unsignedLongLongValue];
    unsigned long long totalBytes = [fsAttr[NSFileSystemSize] unsignedLongLongValue];
    self.realFreeDisk = [NSString stringWithFormat:@"%.2f GB de %.0f GB",
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

- (NSMutableDictionary *)ensureProfileForContainerPath:(NSString *)containerPath forceRotate:(BOOL)rotate {
    NSString *profilePath = [containerPath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
    NSMutableDictionary *profile = [NSMutableDictionary dictionaryWithContentsOfFile:profilePath];

    if (!profile || !profile[@"idfv"] || rotate) {
        BOOL wasEnabled = profile[@"enabled"] ? [profile[@"enabled"] boolValue] : YES;
        NSString *existingCraneID = profile[@"craneContainerID"] ?: [containerPath lastPathComponent];
        NSUInteger seed = [containerPath hash] ^ (NSUInteger)([[NSDate date] timeIntervalSince1970] * 1000) ^ arc4random();
        NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59"];
        NSString *oui = ouis[seed % ouis.count];
        uint8_t b3 = (seed >> 8) & 0xFF;
        uint8_t b4 = (seed >> 16) & 0xFF;
        uint8_t b5 = (seed >> 24) & 0xFF;
        NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x", oui, b3, b4, b5];
        NSString *ssid = [NSString stringWithFormat:@"HomeWiFi-%02X-5G", (unsigned int)(seed & 0xFF)];
        int lastOctet = 20 + (seed % 210);
        NSString *localIP = [NSString stringWithFormat:@"192.168.1.%d", lastOctet];

        unsigned long long baseFreeMB = 16500ULL + (seed % 28300ULL);
        unsigned long long freeBytes = baseFreeMB * 1024ULL * 1024ULL + (seed % 1048576ULL);
        NSUInteger uptimeOffset = 900 + (seed % 54000);
        float batteryLvl = 0.35f + ((seed % 58) / 100.0f);
        float brightnessLvl = 0.40f + (((seed >> 4) % 48) / 100.0f);
        float audioVol = 0.25f + (((seed >> 6) % 65) / 100.0f);

        profile = [@{
            @"enabled": @(wasEnabled),
            @"spoofIDs": profile[@"spoofIDs"] ?: @YES,
            @"spoofNetwork": profile[@"spoofNetwork"] ?: @YES,
            @"spoofLocation": profile[@"spoofLocation"] ?: @YES,
            @"spoofHardware": profile[@"spoofHardware"] ?: @YES,
            @"spoofSecurity": profile[@"spoofSecurity"] ?: @YES,
            @"craneContainerID": existingCraneID,
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
            @"pasteboardCount": @(10 + (seed % 90)),
            @"timeZone": profile[@"timeZone"] ?: (self.state[@"defaultTimeZone"] ?: @"America/New_York"),
            @"localeID": profile[@"localeID"] ?: (self.state[@"defaultLocale"] ?: @"en_US"),
            @"CarrierMode": profile[@"CarrierMode"] ?: (self.state[@"CarrierMode"] ?: @"CELLULAR"),
            @"CarrierName": profile[@"CarrierName"] ?: (self.state[@"CarrierName"] ?: @"T-Mobile"),
            @"CarrierMCC": profile[@"CarrierMCC"] ?: (self.state[@"CarrierMCC"] ?: @"310"),
            @"CarrierMNC": profile[@"CarrierMNC"] ?: (self.state[@"CarrierMNC"] ?: @"260"),
            @"CarrierISO": profile[@"CarrierISO"] ?: (self.state[@"CarrierISO"] ?: @"us")
        } mutableCopy];

        [[NSFileManager defaultManager] createDirectoryAtPath:[containerPath stringByAppendingPathComponent:@"Library"]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [profile writeToFile:profilePath atomically:YES];
    }
    return profile;
}

- (void)scanAllRealContainersOnDisk {
    self.igContainers = [NSMutableArray array];
    self.redditContainers = [NSMutableArray array];
    NSMutableSet *seenPaths = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Leer contenedores auto-registrados por Tweak.x en STATE_PLIST
    NSDictionary * freshState = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    NSDictionary *known = freshState[@"knownContainers"];
    for (NSString *cPath in known) {
        if (![fm fileExistsAtPath:cPath]) continue;
        NSDictionary *info = known[cPath];
        NSString *bID = info[@"bundleID"] ?: @"";
        NSString *cName = info[@"craneName"] ?: [cPath lastPathComponent];
        BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
        BOOL isReddit = [bID isEqualToString:@"com.reddit.Reddit"];
        if (!isIG && !isReddit) continue;

        NSMutableDictionary *prof = [self ensureProfileForContainerPath:cPath forceRotate:NO];
        NSMutableArray *targetList = isIG ? self.igContainers : self.redditContainers;
        [targetList addObject:@{
            @"title": [NSString stringWithFormat:@"[%@]", cName],
            @"path": cPath,
            @"uuid": cName,
            @"profile": prof
        }];
        [seenPaths addObject:cPath];
    }

    // 2. Escanear rutas directas en disco
    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:appsDir error:nil];

    for (NSString *uuid in uuids) {
        NSString *fullPath = [appsDir stringByAppendingPathComponent:uuid];
        if ([seenPaths containsObject:fullPath]) continue;

        NSString *metaPath = [fullPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        NSString *bundleID = meta[@"MCMMetadataIdentifier"] ?: @"";

        BOOL isIG = [bundleID isEqualToString:@"com.burbn.instagram"];
        BOOL isReddit = [bundleID isEqualToString:@"com.reddit.Reddit"];
        if (!isIG && !isReddit) continue;

        NSMutableArray *targetList = isIG ? self.igContainers : self.redditContainers;
        NSString *craneName = meta[@"com.opa334.crane.container.name"] ?: @"Default";
        NSString *shortUUID = [uuid substringToIndex:MIN(6, uuid.length)];

        NSMutableDictionary *prof = [self ensureProfileForContainerPath:fullPath forceRotate:NO];
        [targetList addObject:@{
            @"title": [NSString stringWithFormat:@"[%@] (%@)", craneName, shortUUID],
            @"path": fullPath,
            @"uuid": uuid,
            @"profile": prof
        }];
        [seenPaths addObject:fullPath];
    }
}

#pragma mark - TableView DataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"1. INTERRUPTOR GENERAL Y ESTADO DE CHOICY";
        case 1: return @"2. APLICACIONES Y CONTENEDORES (CRANE)";
        case 2: return @"3. TELEMETRÍA REAL DEL SISTEMA Y RED ACTUAL";
        case 3: return @"4. AUDITORÍA PROXY CENTER (TG) Y LIMPIEZA 64GB";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 3;
        case 1: return 2;
        case 2: return 5;
        case 3: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;

    BOOL masterOn = [self.state[@"masterEnabled"] boolValue];

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = @"Habilitar IGFarmShield";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = masterOn;
            [sw addTarget:self action:@selector(toggleMasterSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Modo General";
            cell.detailTextLabel.textColor = masterOn ? [UIColor systemGreenColor] : [UIColor systemRedColor];
            cell.detailTextLabel.text = masterOn ? @"🟢 Activo (Independiente por Cuenta)" : @"⚪ Apagado";
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"🛡️ Estado de Choicy";
            cell.detailTextLabel.textColor = self.choicySafe ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
            cell.detailTextLabel.text = self.choicyStatusText;
        }
    } else if (indexPath.section == 1) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"📸 Instagram";
            BOOL igOn = masterOn && [self.state[@"enableIG"] boolValue];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu contenedores (%@)",
                                         (unsigned long)self.igContainers.count, igOn ? @"ON" : @"OFF"];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"🤖 Reddit";
            BOOL rdOn = masterOn && [self.state[@"enableReddit"] boolValue];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu contenedores (%@)",
                                         (unsigned long)self.redditContainers.count, rdOn ? @"ON" : @"OFF"];
        }
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Túnel VPN (Shadowrocket)";
            cell.detailTextLabel.textColor = self.vpnActive ? [UIColor systemGreenColor] : [UIColor systemRedColor];
            cell.detailTextLabel.text = self.vpnActive ? [NSString stringWithFormat:@"🟢 ACTIVO (%@)", self.vpnInterfaceName] : @"⚠️ APAGADO (Wi-Fi Directo)";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"IP / ISP Saliente Actual";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)",
                                         self.state[@"last_ip"] ?: @"Consultando...",
                                         self.state[@"last_isp"] ?: @"..."];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Zona Horaria Detectada";
            cell.detailTextLabel.text = self.state[@"defaultTimeZone"] ?: self.realTimeZone;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"Placa / Batería / IP Real";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ | %d%% | %@", self.realHardwareModel, self.realBatteryPct, self.realLocalIP];
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"Disco Real (64GB)";
            cell.detailTextLabel.text = self.realFreeDisk;
        }
    } else if (indexPath.section == 3) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        if (indexPath.row == 0) {
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"🔍 Auditar Red en Proxy Center + Enviar a Telegram";
        } else if (indexPath.row == 1) {
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.textLabel.text = @"🧹 Purgar Caché y Temporales (30-40 Cuentas / 64GB)";
        }
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
            subVC.stateKey = @"enableIG";
            subVC.isIG = YES;
            subVC.appContainers = self.igContainers;
        } else {
            subVC.appTitle = @"Reddit";
            subVC.stateKey = @"enableReddit";
            subVC.isIG = NO;
            subVC.appContainers = self.redditContainers;
        }
        [self.navigationController pushViewController:subVC animated:YES];
        return;
    }

    if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            [self auditChoicyConfiguration];
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
    NSURL *url = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,countryCode,city,timezone,isp,query"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 6.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) {
            self.state[@"last_ip"] = @"Sin conexión";
            self.state[@"last_isp"] = @"Offline";
            [self saveState];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                if (!silent) [self showAlert:@"Error de Red" msg:@"No hay salida a internet en el iPhone."];
            });
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *ip = json[@"query"] ?: @"Desconocida";
        NSString *ispRaw = json[@"isp"] ?: @"ISP";
        NSString *cc = [json[@"countryCode"] lowercaseString] ?: @"us";
        NSString *tz = json[@"timezone"] ?: @"America/New_York";

        self.state[@"last_ip"] = ip;
        self.state[@"last_isp"] = [NSString stringWithFormat:@"%@ (%@)", ispRaw, [cc uppercaseString]];
        self.state[@"defaultTimeZone"] = tz;
        self.state[@"defaultLocale"] = [NSString stringWithFormat:@"en_%@", [cc uppercaseString]];
        [self saveState];

        if (silent) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
            });
            return;
        }

        // Si el usuario tocó el botón de Auditar, consultamos también a tu VPS (162.35.105.151:5001)
        BOOL choicyOK = [self auditChoicyConfiguration];
        NSString *plat = ([self.state[@"enableIG"] boolValue]) ? @"INSTAGRAM" : @"REDDIT";
        NSString *ispEnc = [ispRaw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
        NSString *vpsUrlStr = [NSString stringWithFormat:@"%@?ip=%@&contenedor=Global_Check&plataforma=%@&choicy=%d&bssid=Global&isp=%@&cc=%@",
                               VPS_AUDIT_URL, ip, plat, choicyOK ? 1 : 0, ispEnc, cc];

        [[session dataTaskWithURL:[NSURL URLWithString:vpsUrlStr] completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
            NSDictionary *vpsJson = vData ? [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil] : nil;
            NSString *veredictoVPS = vpsJson[@"mensaje_iphone"] ?: @"VPS no respondió en puerto 5001 (Verifica el Firewall de Windows en tu VPS).";

            dispatch_async(dispatch_get_main_queue(), ^{
                [self refreshRealPhoneTelemetry];
                [self.tableView reloadData];
                NSString *vpnState = self.vpnActive ? @"🟢 VPN Shadowrocket Activo" : @"⚠️ VPN APAGADO (Wi-Fi Directo)";
                [self showAlert:@"Auditoría Proxy Center + Telegram"
                            msg:[NSString stringWithFormat:@"%@\n🛡️ Choicy: %@\n\n📍 IP Saliente: %@\n📡 ISP: %@ (%@)\n🌎 Zona Horaria: %@\n\n📊 Veredicto Proxy Center:\n%@",
                                 vpnState, self.choicyStatusText, ip, ispRaw, [cc uppercaseString], tz, veredictoVPS]];
            });
        }] resume];
    }] resume];
}

- (void)purgeContainersCache {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger cleaned = 0;
    NSArray *all = [self.igContainers arrayByAddingObjectsFromArray:self.redditContainers];
    for (NSDictionary *item in all) {
        for (NSString *subDir in @[@"Library/Caches", @"tmp"]) {
            NSString *targetDir = [item[@"path"] stringByAppendingPathComponent:subDir];
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
    [self showAlert:@"Caché y Temporales Purgados (64GB Safe)"
                msg:[NSString stringWithFormat:@"Se eliminaron %lu archivos basura de Library/Caches y tmp/ sin tocar las sesiones iniciadas.\nEspacio libre real: %@", (unsigned long)cleaned, self.realFreeDisk]];
}

- (void)showAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
