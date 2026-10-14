#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#define STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define CHOICY_PLIST @"/var/jb/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
#define CRANE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define VPS_C2_URL @"http://162.35.105.151:5001/check_ip"

@interface IGFarmRootListController : UIViewController <UITableViewDelegate, UITableViewDataSource> {
    id _specifier;
    id _rootController;
    id _parentController;
}
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableDictionary *state;
@end

@implementation IGFarmRootListController

// Métodos requeridos por PreferenceLoader en Settings.app
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
    self.title = @"IGFarmShield v2.0";
    self.state = [NSMutableDictionary dictionaryWithContentsOfFile:STATE_PLIST] ?: [NSMutableDictionary dictionary];

    if (!self.state[@"CarrierName"]) self.state[@"CarrierName"] = @"T-Mobile";
    if (!self.state[@"CarrierMCC"]) self.state[@"CarrierMCC"] = @"310";
    if (!self.state[@"CarrierMNC"]) self.state[@"CarrierMNC"] = @"260";
    if (!self.state[@"CarrierISO"]) self.state[@"CarrierISO"] = @"us";
    if (!self.state[@"CarrierMode"]) self.state[@"CarrierMode"] = @"CELLULAR";
    if (!self.state[@"enableIG"]) self.state[@"enableIG"] = @YES;
    if (!self.state[@"enableReddit"]) self.state[@"enableReddit"] = @YES;
    [self saveState];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)saveState {
    [self.state writeToFile:STATE_PLIST atomically:YES];
}

- (NSString *)checkChoicyStatus {
    NSDictionary *choicy = [NSDictionary dictionaryWithContentsOfFile:CHOICY_PLIST];
    if (!choicy) return @"⚠️ Configura Choicy (Allow: Crane + IGFarmShield)";
    return @"✅ Choicy Detectado";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"1. AUDITORÍA CHOICY Y PLATAFORMAS";
        case 1: return @"2. RED Y PROXY (MOBILE / RESIDENCIAL)";
        case 2: return @"3. HARDWARE BASE Y HUELLA POR CONTENEDOR";
        case 3: return @"4. ACCIONES TÁCTICAS (64GB & PROXY CENTER)";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 3;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Estado Choicy";
            cell.detailTextLabel.text = [self checkChoicyStatus];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Activar en Instagram";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [self.state[@"enableIG"] boolValue];
            sw.tag = 101;
            [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Activar en Reddit";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [self.state[@"enableReddit"] boolValue];
            sw.tag = 102;
            [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"IP / ISP Actual";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)", self.state[@"last_ip"] ?: @"Sin auditar", self.state[@"last_isp"] ?: @"T-Mobile FL"];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Modo Red / SIM";
            if ([self.state[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Wi-Fi Residencial (%@)", self.state[@"CarrierISO"] ?: @"us"];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"4G %@ (%@/%@)", self.state[@"CarrierName"], self.state[@"CarrierMCC"], self.state[@"CarrierMNC"]];
            }
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Estado Proxy Center";
            cell.detailTextLabel.text = self.state[@"c2_status"] ?: @"Pendiente";
        }
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Modelo Base";
            cell.detailTextLabel.text = @"iPhone10,4 (iPhone 8 Nativo)";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Escudos Activos";
            cell.detailTextLabel.text = @"Passcode + No-UTUN + No-DCDevice";
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Semilla de IDs";
            cell.detailTextLabel.text = self.state[@"resetToken"] ?: @"Original";
        }
    } else if (indexPath.section == 3) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.textColor = [UIColor systemBlueColor];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"🔍 Auditar Proxy + Auto-Configurar Red";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"🔄 Rotar Huella (IDs/MAC/Disco) en Contenedores";
        } else if (indexPath.row == 2) {
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.textLabel.text = @"🧹 Purgar Caché de IG/Reddit (Liberar 64GB)";
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
    if (indexPath.section != 3) return;

    if (indexPath.row == 0) {
        [self auditProxyAndSyncCarrier];
    } else if (indexPath.row == 1) {
        self.state[@"resetToken"] = [[[NSUUID UUID] UUIDString] substringToIndex:8];
        [self saveState];
        [self.tableView reloadData];
        [self showAlert:@"Huella Renovada" msg:@"Cada contenedor de Crane generará un nuevo BSSID, IP local, token de iCloud y GB libres al abrirse."];
    } else if (indexPath.row == 2) {
        [self purgeContainersCache];
    }
}

- (void)auditProxyAndSyncCarrier {
    NSURL *url = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,countryCode,city,isp,query"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 6.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"Error de Red" msg:@"No hubo respuesta a través de Shadowrocket. Verifica que el proxy esté encendido."];
            });
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *ip = json[@"query"] ?: @"Desconocida";
        NSString *isp = [json[@"isp"] uppercaseString] ?: @"";
        NSString *cc = [json[@"countryCode"] lowercaseString] ?: @"us";

        self.state[@"last_ip"] = ip;
        self.state[@"last_isp"] = json[@"isp"] ?: @"ISP";

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

        NSString *c2UrlStr = [NSString stringWithFormat:@"%@?ip=%@&cuenta=IPHONE_AUDIT", VPS_C2_URL, ip];
        [[session dataTaskWithURL:[NSURL URLWithString:c2UrlStr] completionHandler:^(NSData *c2Data, NSURLResponse *r2, NSError *e2) {
            if (c2Data && !e2) {
                NSDictionary *c2Json = [NSJSONSerialization JSONObjectWithData:c2Data options:0 error:nil];
                if ([c2Json[@"status"] isEqualToString:@"contaminada"]) {
                    self.state[@"c2_status"] = [NSString stringWithFormat:@"⚠️ Usada por %@", c2Json[@"cuenta_previa"]];
                } else {
                    self.state[@"c2_status"] = @"✅ IP Limpia en Sheets";
                }
            } else {
                self.state[@"c2_status"] = @"ℹ️ Sin conexión C2";
            }
            [self saveState];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                [self showAlert:@"Auditoría Completada"
                            msg:[NSString stringWithFormat:@"IP: %@\nISP: %@\nModo: %@ (%@)\nProxy Center: %@",
                                 ip, json[@"isp"], self.state[@"CarrierMode"], self.state[@"CarrierName"], self.state[@"c2_status"]]];
            });
        }] resume];
    }] resume];
}

- (void)purgeContainersCache {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *dirs = [fm contentsOfDirectoryAtPath:appsDir error:nil];
    NSUInteger cleaned = 0;

    for (NSString *uuid in dirs) {
        NSString *cachePath = [[appsDir stringByAppendingPathComponent:uuid] stringByAppendingPathComponent:@"Library/Caches"];
        if ([fm fileExistsAtPath:cachePath]) {
            NSArray *files = [fm contentsOfDirectoryAtPath:cachePath error:nil];
            for (NSString *f in files) {
                if ([f containsString:@"instagram"] || [f containsString:@"reddit"] || [f containsString:@"com.burbn"] || [f containsString:@"Snapshots"]) {
                    [fm removeItemAtPath:[cachePath stringByAppendingPathComponent:f] error:nil];
                    cleaned++;
                }
            }
        }
    }
    [self showAlert:@"Caché Purgada (64GB Safe)" msg:[NSString stringWithFormat:@"Se limpiaron %lu carpetas de caché sin cerrar tus sesiones.", (unsigned long)cleaned]];
}

- (void)showAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
