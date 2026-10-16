#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
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
#define CURRENT_SCHEMA_VERSION 21

@interface PSViewController : UIViewController
@end

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@end

static UIImage *badgeIcon(NSString *symbol, UIColor *color) {
    CGSize size = CGSizeMake(28, 28);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 28, 28) cornerRadius:6.5] fill];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
        UIImage *s = [[UIImage systemImageNamed:symbol withConfiguration:cfg] imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (s) [s drawInRect:CGRectMake((28 - s.size.width)/2, (28 - s.size.height)/2, s.size.width, s.size.height)];
    }];
}

static void haptic() {
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [g impactOccurred];
}

static uint64_t seed64(NSString *s) {
    uint64_t h = 14695981039346656037ULL;
    const char *b = [s UTF8String];
    if (b) { while (*b) { h ^= (uint8_t)(*b++); h *= 1099511628211ULL; } }
    uint64_t r = 0;
    arc4random_buf(&r, sizeof(r));
    return h ^ r;
}

static void killProc(NSString *name) {
    pid_t pid;
    const char *args[] = {"/var/jb/usr/bin/killall", "-9", [name UTF8String], NULL};
    posix_spawn(&pid, args[0], NULL, NULL, (char *const *)args, environ);
}

static NSString *appSandboxPath(NSString *bundleID) {
    Class cls = NSClassFromString(@"LSApplicationProxy");
    if (cls && [cls respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        LSApplicationProxy *p = [cls applicationProxyForIdentifier:bundleID];
        if ([p respondsToSelector:@selector(dataContainerURL)] && p.dataContainerURL.path.length > 0) {
            return p.dataContainerURL.path;
        }
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSDate *bestDate = nil;
    NSString *bestPath = nil;
    for (NSString *u in [fm contentsOfDirectoryAtPath:appsDir error:nil]) {
        NSString *p = [appsDir stringByAppendingPathComponent:u];
        NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        if ([m isKindOfClass:[NSDictionary class]] && [m[@"MCMMetadataIdentifier"] isEqualToString:bundleID]) {
            NSDate *d = [fm attributesOfItemAtPath:p error:nil][NSFileModificationDate] ?: [NSDate distantPast];
            if (!bestDate || [d compare:bestDate] == NSOrderedDescending) { bestDate = d; bestPath = p; }
        }
    }
    return bestPath;
}

static void parseCraneSubtree(id node, NSMutableDictionary *outMap) {
    if (!node || !outMap) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)node;
        for (NSString *ak in @[@"activeContainer", @"selectedContainer", @"currentContainer", @"activeContainerIdentifier", @"active"]) {
            if ([d[ak] isKindOfClass:[NSString class]] && [d[ak] length] > 0) outMap[@"__ACTIVE__"] = d[ak];
        }
        NSString *cID = nil, *cName = nil;
        for (NSString *ik in @[@"identifier", @"id", @"UUID", @"uuid", @"containerIdentifier"]) {
            if ([d[ik] isKindOfClass:[NSString class]] && [d[ik] length] > 0) { cID = d[ik]; break; }
        }
        for (NSString *nk in @[@"name", @"displayName", @"label", @"title", @"containerName"]) {
            if ([d[nk] isKindOfClass:[NSString class]] && [d[nk] length] > 0) { cName = d[nk]; break; }
        }
        if (cID && cName) outMap[[cID lowercaseString]] = @{@"id": cID, @"name": cName};

        for (id k in d) {
            NSString *ks = [k description];
            id v = d[k];
            if ([v isKindOfClass:[NSDictionary class]]) {
                NSDictionary *sub = (NSDictionary *)v;
                NSString *sName = nil;
                for (NSString *nk in @[@"name", @"displayName", @"label", @"title", @"containerName"]) {
                    if ([sub[nk] isKindOfClass:[NSString class]] && [sub[nk] length] > 0) { sName = sub[nk]; break; }
                }
                if (sName) {
                    NSString *sID = ks;
                    for (NSString *ik in @[@"identifier", @"id", @"UUID", @"uuid", @"containerIdentifier"]) {
                        if ([sub[ik] isKindOfClass:[NSString class]] && [sub[ik] length] > 0) { sID = sub[ik]; break; }
                    }
                    outMap[[sID lowercaseString]] = @{@"id": sID, @"name": sName};
                } else {
                    parseCraneSubtree(v, outMap);
                }
            } else if ([v isKindOfClass:[NSArray class]]) {
                parseCraneSubtree(v, outMap);
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) parseCraneSubtree(item, outMap);
    }
}

static void extractCraneForBundle(id node, NSString *bundleID, NSMutableDictionary *outMap) {
    if (![node isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *d = (NSDictionary *)node;
    for (id k in d) {
        NSString *ks = [k description];
        id v = d[k];
        if ([ks rangeOfString:bundleID options:NSCaseInsensitiveSearch].location != NSNotFound) {
            parseCraneSubtree(v, outMap);
        } else if ([v isKindOfClass:[NSDictionary class]]) {
            extractCraneForBundle(v, bundleID, outMap);
        }
    }
}

static void scanCacheDir(NSString *dir, uint64_t *bytes, NSUInteger *files, BOOL deleteFiles) {
    if (!dir || dir.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
    NSString *rel = nil;
    while ((rel = [en nextObject])) {
        NSDictionary *at = [en fileAttributes];
        if ([at[NSFileType] isEqualToString:NSFileTypeRegular]) {
            if (bytes) *bytes += [at[NSFileSize] unsignedLongLongValue];
            if (files) (*files)++;
        }
    }
    if (deleteFiles) {
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:item] error:nil];
        }
    }
}

static void fetchIPCascade(NSArray *urls, NSUInteger idx, void (^done)(NSDictionary *res)) {
    if (idx >= urls.count) { if (done) done(nil); return; }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.URLCache = nil;
    cfg.timeoutIntervalForRequest = 7.0;
    NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urls[idx]]];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
    [[s dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d || e) { fetchIPCascade(urls, idx + 1, done); return; }
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) { fetchIPCascade(urls, idx + 1, done); return; }
        NSString *ip = j[@"ip"] ?: j[@"query"];
        NSString *tz = [j[@"timezone"] isKindOfClass:[NSDictionary class]] ? j[@"timezone"][@"id"] : j[@"timezone"];
        NSString *cc = j[@"country_code"] ?: (j[@"countryCode"] ?: j[@"country"]);
        NSString *isp = [j[@"connection"] isKindOfClass:[NSDictionary class]] ? (j[@"connection"][@"isp"] ?: j[@"connection"][@"org"]) : (j[@"isp"] ?: j[@"org"]);
        if (ip.length > 0 && tz.length > 0) {
            if (done) done(@{@"ip": ip, @"isp": isp ?: @"ISP", @"cc": [cc ?: @"us" lowercaseString], @"city": j[@"city"] ?: @"", @"region": j[@"region"] ?: (j[@"regionName"] ?: @""), @"tz": tz});
        } else {
            fetchIPCascade(urls, idx + 1, done);
        }
    }] resume];
}

@interface IGFarmRootListController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableDictionary *state;
@property (nonatomic, strong) NSMutableArray *igList;
@property (nonatomic, strong) NSMutableArray *rdList;
@property (nonatomic, assign) BOOL vpnActive;
@property (nonatomic, strong) NSString *vpnName;
@property (nonatomic, strong) NSString *cacheSummary;
- (void)saveState;
- (void)syncContainersFromCrane;
- (void)updateCacheMetrics:(BOOL)cleanNow showPopup:(BOOL)popup;
- (NSMutableDictionary *)ensureProfile:(NSString *)bundleID uuid:(NSString *)uuid name:(NSString *)name path:(NSString *)path rotate:(BOOL)rot;
- (void)saveProfile:(NSMutableDictionary *)p forUUID:(NSString *)u;
- (void)setContainer:(NSString *)u enabled:(BOOL)en bundle:(NSString *)bID;
@end

@interface IGFarmAppContainersController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSString *bundleID;
@property (nonatomic, strong) NSString *appTitle;
@property (nonatomic, strong) NSString *appKey;
@property (nonatomic, strong) NSMutableArray *containers;
@property (nonatomic, weak) IGFarmRootListController *root;
@property (nonatomic, strong) UITableView *tableView;
@end

@interface IGFarmContainerDetailController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSString *bundleID;
@property (nonatomic, strong) NSString *uuid;
@property (nonatomic, strong) NSMutableDictionary *profile;
@property (nonatomic, weak) IGFarmRootListController *root;
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation IGFarmRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"IGFarmShield v21";
    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    self.state = loaded ? [loaded mutableCopy] : [NSMutableDictionary dictionary];
    // Por defecto manual: solo se activan cuando el usuario lo decide
    if (!self.state[@"masterEnabled"]) self.state[@"masterEnabled"] = @NO;
    if (!self.state[@"exclusiveMode"]) self.state[@"exclusiveMode"] = @YES;
    if (!self.state[@"enableIG"]) self.state[@"enableIG"] = @NO;
    if (!self.state[@"enableReddit"]) self.state[@"enableReddit"] = @NO;
    if (![self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]) self.state[@"containersByUUID"] = [NSMutableDictionary dictionary];
    if (![self.state[@"hiddenIDs"] isKindOfClass:[NSArray class]]) self.state[@"hiddenIDs"] = @[];
    [self saveState];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60.0;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    if (loaded) self.state = [loaded mutableCopy];
    [self syncContainersFromCrane];
    [self updateCacheMetrics:NO showPopup:NO];
    [self.tableView reloadData];
}

- (void)saveState {
    [self.state writeToFile:STATE_PLIST atomically:YES];
}

- (void)saveProfile:(NSMutableDictionary *)p forUUID:(NSString *)u {
    if (!u || !p) return;
    p[@"containerUUID"] = u;
    p[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
    NSMutableDictionary *byU = [self.state[@"containersByUUID"] mutableCopy] ?: [NSMutableDictionary dictionary];
    byU[u] = p;
    self.state[@"containersByUUID"] = byU;
    [self saveState];
    NSString *path = p[@"path"];
    if (path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [p writeToFile:[path stringByAppendingPathComponent:@"Library/.igshield_container.plist"] atomically:YES];
    }
}

// Todo contenedor nuevo nace DESACTIVADO (@NO) y con todos sus switches en @NO para control 100% manual
- (NSMutableDictionary *)ensureProfile:(NSString *)bundleID uuid:(NSString *)uuid name:(NSString *)name path:(NSString *)path rotate:(BOOL)rot {
    NSMutableDictionary *byU = [self.state[@"containersByUUID"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *prof = [byU[uuid] isKindOfClass:[NSDictionary class]] ? [byU[uuid] mutableCopy] : nil;

    if (!prof) {
        for (NSString *k in [byU allKeys]) {
            NSDictionary *c = byU[k];
            if ([c isKindOfClass:[NSDictionary class]] && [c[@"bundleID"] isEqualToString:bundleID] &&
                ([k caseInsensitiveCompare:uuid] == NSOrderedSame || [c[@"containerName"] caseInsensitiveCompare:name] == NSOrderedSame)) {
                prof = [c mutableCopy];
                if (![k isEqualToString:uuid]) [byU removeObjectForKey:k];
                break;
            }
        }
    }

    NSString *cleanName = name.length > 0 ? name : @"Default";
    NSString *idfv = ([uuid containsString:@"-"] && uuid.length >= 32 && !rot) ? [uuid uppercaseString] : (prof[@"idfv"] && !rot ? prof[@"idfv"] : [[NSUUID UUID] UUIDString]);

    if (!prof || !prof[@"idfv"] || rot) {
        uint64_t s = seed64(uuid);
        NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59"];
        NSArray *ssids = @[@"HomeWiFi", @"ATT-Fiber", @"Xfinity-WiFi", @"SpectrumSetup", @"NETGEAR"];
        NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x", ouis[s % ouis.count], (unsigned)((s>>8)&0xFF), (unsigned)((s>>16)&0xFF), (unsigned)((s>>24)&0xFF)];
        NSString *ssid = [NSString stringWithFormat:@"%@-%02X-5G", ssids[(s>>3) % ssids.count], (unsigned)(s & 0xFF)];
        unsigned long long freeB = ((15000ULL + (s % 28000ULL)) * 1024ULL * 1024ULL);

        prof = [@{
            @"schemaVersion": @(CURRENT_SCHEMA_VERSION),
            @"containerUUID": uuid,
            @"craneIdentifier": uuid,
            @"containerName": cleanName,
            @"bundleID": bundleID,
            @"path": path ?: @"",
            @"enabled": prof[@"enabled"] ?: @NO,
            @"spoofIDs": prof[@"spoofIDs"] ?: @NO,
            @"spoofNetwork": prof[@"spoofNetwork"] ?: @NO,
            @"spoofLocation": prof[@"spoofLocation"] ?: @NO,
            @"spoofHardware": prof[@"spoofHardware"] ?: @NO,
            @"spoofSecurity": prof[@"spoofSecurity"] ?: @NO,
            @"idfv": idfv,
            @"bootSessionUUID": [[NSUUID UUID] UUIDString],
            @"bssid": bssid,
            @"ssid": ssid,
            @"localIP": [NSString stringWithFormat:@"192.168.1.%d", 15 + (int)(s % 210)],
            @"freeBytes": @(freeB),
            @"batteryLevel": @(0.35f + ((s % 55) / 100.0f)),
            @"brightness": @(0.30f + (((s >> 4) % 55) / 100.0f)),
            @"audioVolume": @(0.25f + (((s >> 6) % 60) / 100.0f)),
            @"pasteboardCount": @(3 + (s % 40)),
            @"lastSyncedIP": prof[@"lastSyncedIP"] ?: @"Sin sincronizar",
            @"ispName": prof[@"ispName"] ?: @"Pendiente",
            @"cityCountry": prof[@"cityCountry"] ?: @"Sin sincronizar",
            @"timeZone": prof[@"timeZone"] ?: @"America/New_York",
            @"localeID": prof[@"localeID"] ?: @"en_US",
            @"CarrierMode": prof[@"CarrierMode"] ?: @"WIFI_ONLY",
            @"CarrierName": prof[@"CarrierName"] ?: @"Wi-Fi",
            @"CarrierMCC": @"310",
            @"CarrierMNC": @"260",
            @"CarrierISO": @"us"
        } mutableCopy];
    } else {
        prof[@"containerName"] = cleanName;
        if (path.length > 0) prof[@"path"] = path;
    }

    [self saveProfile:prof forUUID:uuid];
    return prof;
}

// Lee estrictamente de Crane + contenedor principal de LSApplicationProxy (Cero contenedores huérfanos)
- (void)syncContainersFromCrane {
    self.igList = [NSMutableArray array];
    self.rdList = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSMutableSet *hidden = [NSMutableSet set];
    for (NSString *h in (self.state[@"hiddenIDs"] ?: @[])) [hidden addObject:[h lowercaseString]];

    NSMutableArray *sources = [NSMutableArray array];
    for (NSString *dom in @[@"com.opa334.crane", @"com.opa334.craneprefs"]) {
        CFPreferencesAppSynchronize((__bridge CFStringRef)dom);
        for (NSString *u in @[@"mobile", @"root"]) {
            CFDictionaryRef cf = CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)dom, (__bridge CFStringRef)u, kCFPreferencesAnyHost);
            if (cf) { NSDictionary *d = CFBridgingRelease(cf); if (d.count) [sources addObject:d]; }
        }
    }
    for (NSString *p in @[CRANE_PREFS_JB, CRANE_PREFS_VAR, CRANE_MAIN_JB, CRANE_MAIN_VAR]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d.count) [sources addObject:d];
    }
    for (NSString *dir in @[@"/var/mobile/Library/Application Support/Crane", @"/var/jb/var/mobile/Library/Application Support/Crane"]) {
        for (NSString *f in [fm subpathsOfDirectoryAtPath:dir error:nil]) {
            if ([f hasSuffix:@".plist"]) {
                NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
                if (d.count) [sources addObject:d];
            }
        }
    }

    NSMutableDictionary *igMap = [NSMutableDictionary dictionary];
    NSMutableDictionary *rdMap = [NSMutableDictionary dictionary];
    for (NSDictionary *src in sources) {
        extractCraneForBundle(src, @"com.burbn.instagram", igMap);
        extractCraneForBundle(src, @"com.reddit.Reddit", rdMap);
    }

    NSString *igAct = igMap[@"__ACTIVE__"];
    NSString *rdAct = rdMap[@"__ACTIVE__"];
    [igMap removeObjectForKey:@"__ACTIVE__"];
    [rdMap removeObjectForKey:@"__ACTIVE__"];

    NSMutableSet *validKeys = [NSMutableSet set];

    for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
        BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
        NSMutableDictionary *cMap = isIG ? igMap : rdMap;
        NSMutableArray *list = isIG ? self.igList : self.rdList;
        NSMutableSet *seen = [NSMutableSet set];

        NSString *mainPath = appSandboxPath(bID) ?: @"";
        NSDictionary *defEntry = cMap[@"default"];
        NSString *defName = [defEntry isKindOfClass:[NSDictionary class]] ? (defEntry[@"name"] ?: @"Default") : @"Default";

        NSMutableDictionary *defProf = [self ensureProfile:bID uuid:@"Default" name:defName path:mainPath rotate:NO];
        [list addObject:defProf];
        [seen addObject:@"default"];
        [validKeys addObject:@"Default"];

        for (NSString *lowKey in cMap) {
            if ([seen containsObject:lowKey] || [hidden containsObject:lowKey]) continue;
            NSDictionary *entry = cMap[lowKey];
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSString *cID = entry[@"id"] ?: lowKey;
            NSString *cName = entry[@"name"] ?: cID;
            if ([cName caseInsensitiveCompare:@"Default"] == NSOrderedSame || [hidden containsObject:[cID lowercaseString]]) continue;

            NSString *subPath = @"";
            if (mainPath.length > 0) {
                NSString *cand = [[mainPath stringByAppendingPathComponent:@"___Crane_Containers"] stringByAppendingPathComponent:cID];
                if ([fm fileExistsAtPath:cand]) subPath = cand;
            }
            if (subPath.length == 0) {
                NSString *cand2 = [NSString stringWithFormat:@"/var/mobile/Library/Application Support/Crane/Containers/%@/%@", bID, cID];
                if ([fm fileExistsAtPath:cand2]) subPath = cand2;
            }

            NSMutableDictionary *p = [self ensureProfile:bID uuid:cID name:cName path:subPath rotate:NO];
            [list addObject:p];
            [seen addObject:lowKey];
            [seen addObject:[cID lowercaseString]];
            [validKeys addObject:cID];
        }
    }

    NSMutableDictionary *byU = [self.state[@"containersByUUID"] mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *k in [byU allKeys]) {
        if (![validKeys containsObject:k]) [byU removeObjectForKey:k];
    }
    self.state[@"containersByUUID"] = byU;

    NSMutableDictionary *actMap = [self.state[@"activeInCrane"] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (igAct) actMap[@"com.burbn.instagram"] = igAct;
    if (rdAct) actMap[@"com.reddit.Reddit"] = rdAct;
    self.state[@"activeInCrane"] = actMap;
    [self saveState];
}

- (void)setContainer:(NSString *)targetUUID enabled:(BOOL)enabled bundle:(NSString *)bundleID {
    BOOL excl = [self.state[@"exclusiveMode"] boolValue];
    NSMutableArray *list = [bundleID isEqualToString:@"com.burbn.instagram"] ? self.igList : self.rdList;
    for (NSMutableDictionary *p in list) {
        NSString *u = p[@"containerUUID"];
        if ([u isEqualToString:targetUUID]) {
            p[@"enabled"] = @(enabled);
            [self saveProfile:p forUUID:u];
        } else if (enabled && excl) {
            p[@"enabled"] = @NO;
            [self saveProfile:p forUUID:u];
        }
    }
    killProc([bundleID isEqualToString:@"com.burbn.instagram"] ? @"Instagram" : @"Reddit");
}

- (void)updateCacheMetrics:(BOOL)cleanNow showPopup:(BOOL)popup {
    if (cleanNow) {
        haptic();
        killProc(@"Instagram");
        killProc(@"Reddit");
        [UIPasteboard generalPasteboard].items = @[];
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
    }

    self.vpnActive = NO;
    self.vpnName = @"Inactivo";
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) == 0) {
        for (struct ifaddrs *cur = ifap; cur; cur = cur->ifa_next) {
            if (cur->ifa_addr && cur->ifa_addr->sa_family == AF_INET && (cur->ifa_flags & IFF_UP)) {
                NSString *n = [NSString stringWithUTF8String:cur->ifa_name];
                if ([n hasPrefix:@"utun"] || [n hasPrefix:@"ppp"] || [n hasPrefix:@"ipsec"]) {
                    self.vpnActive = YES; self.vpnName = n;
                }
            }
        }
        freeifaddrs(ifap);
    }

    uint64_t totalBytes = 0;
    NSUInteger totalFiles = 0;
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
        NSMutableSet *roots = [NSMutableSet set];
        NSString *mainP = appSandboxPath(bID);
        if (mainP.length > 0) {
            [roots addObject:mainP];
            NSString *subC = [mainP stringByAppendingPathComponent:@"___Crane_Containers"];
            for (NSString *s in [fm contentsOfDirectoryAtPath:subC error:nil]) {
                [roots addObject:[subC stringByAppendingPathComponent:s]];
            }
        }
        NSString *craneAppDir = [@"/var/mobile/Library/Application Support/Crane/Containers" stringByAppendingPathComponent:bID];
        for (NSString *s in [fm contentsOfDirectoryAtPath:craneAppDir error:nil]) {
            [roots addObject:[craneAppDir stringByAppendingPathComponent:s]];
        }

        for (NSString *rPath in roots) {
            for (NSString *sub in @[@"tmp", @"Library/Caches", @"Library/WebKit/WebsiteData", @"Library/Saved Application State"]) {
                scanCacheDir([rPath stringByAppendingPathComponent:sub], &totalBytes, &totalFiles, cleanNow);
            }
        }
    }

    double mb = (double)totalBytes / (1024.0 * 1024.0);
    if (cleanNow) {
        self.cacheSummary = @"0 archivos en caché (0.00 MB) + Portapapeles limpio";
        [self.tableView reloadData];
        if (popup) {
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🧹 Caché Eliminada"
                                                                        message:[NSString stringWithFormat:@"• Apps cerradas.\n• %lu archivos borrados (%.2f MB liberados).\n• Portapapeles limpio.", (unsigned long)totalFiles, mb]
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        }
    } else {
        self.cacheSummary = [NSString stringWithFormat:@"%lu archivos en caché (%.2f MB) + Portapapeles", (unsigned long)totalFiles, mb];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"1. CONTROL MANUAL DEL ESCUDO";
    if (section == 1) return @"2. CONTENEDORES DE CRANE";
    return @"3. LIMPIEZA REAL DE CACHÉ Y FANTASMAS";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;

    if (indexPath.section == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            BOOL on = [self.state[@"masterEnabled"] boolValue];
            cell.imageView.image = badgeIcon(@"shield.fill", on ? [UIColor systemGreenColor] : [UIColor systemGrayColor]);
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = @"Habilitar IGFarmShield (Manual)";
            cell.detailTextLabel.text = on ? [NSString stringWithFormat:@"🟢 Activo • Túnel: %@", self.vpnActive ? self.vpnName : @"Directo"] : @"⚪ Desactivado (Todo en modo nativo)";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = on; sw.tag = 10;
            [sw addTarget:self action:@selector(toggleRoot:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            BOOL excl = [self.state[@"exclusiveMode"] boolValue];
            cell.imageView.image = badgeIcon(@"lock.fill", [UIColor systemIndigoColor]);
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15.5];
            cell.textLabel.text = @"Modo Exclusivo (1 Contenedor a la vez)";
            cell.detailTextLabel.text = excl ? @"Al encender un contenedor se apagan los demás" : @"Permite varios contenedores activos";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = excl; sw.tag = 11;
            [sw addTarget:self action:@selector(toggleRoot:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
        return cell;
    }

    if (indexPath.section == 1) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        BOOL isIG = (indexPath.row == 0);
        NSArray *list = isIG ? self.igList : self.rdList;
        NSUInteger onCount = 0;
        for (NSDictionary *p in list) if ([p[@"enabled"] boolValue]) onCount++;
        cell.imageView.image = badgeIcon(isIG ? @"camera.fill" : @"bubble.left.and.bubble.right.fill", isIG ? [UIColor systemPinkColor] : [UIColor systemOrangeColor]);
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ (%lu Contenedores)", isIG ? @"Instagram" : @"Reddit", (unsigned long)list.count];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu activos manualmente", (unsigned long)onCount];
        return cell;
    }

    if (indexPath.row == 0) {
        cell.imageView.image = badgeIcon(@"trash.fill", [UIColor systemRedColor]);
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.text = @"🧹 Cerrar Apps y Limpiar Caché Real";
        cell.detailTextLabel.text = self.cacheSummary;
    } else {
        cell.imageView.image = badgeIcon(@"arrow.clockwise.circle.fill", [UIColor systemBlueColor]);
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.text = @"🔄 Re-sincronizar con Crane (Purgar Fantasmas)";
        cell.detailTextLabel.text = @"Borra registros huérfanos y recarga solo los contenedores actuales de Crane";
    }
    return cell;
}

- (void)toggleRoot:(UISwitch *)sw {
    haptic();
    if (sw.tag == 10) self.state[@"masterEnabled"] = @(sw.isOn);
    else if (sw.tag == 11) self.state[@"exclusiveMode"] = @(sw.isOn);
    [self saveState];
    killProc(@"Instagram");
    killProc(@"Reddit");
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        haptic();
        IGFarmAppContainersController *vc = [[IGFarmAppContainersController alloc] init];
        vc.root = self;
        if (indexPath.row == 0) {
            vc.bundleID = @"com.burbn.instagram"; vc.appTitle = @"Instagram"; vc.appKey = @"enableIG"; vc.containers = self.igList;
        } else {
            vc.bundleID = @"com.reddit.Reddit"; vc.appTitle = @"Reddit"; vc.appKey = @"enableReddit"; vc.containers = self.rdList;
        }
        [self.navigationController pushViewController:vc animated:YES];
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            [self updateCacheMetrics:YES showPopup:YES];
        } else {
            haptic();
            self.state[@"containersByUUID"] = [NSMutableDictionary dictionary];
            self.state[@"hiddenIDs"] = @[];
            [self saveState];
            [self syncContainersFromCrane];
            [self.tableView reloadData];
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"✅ Sincronizado con Crane"
                                                                        message:@"Se eliminaron todos los registros antiguos y se cargaron únicamente los contenedores actuales de Crane."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        }
    }
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
    self.tableView.estimatedRowHeight = 64.0;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.root syncContainersFromCrane];
    self.containers = [self.bundleID isEqualToString:@"com.burbn.instagram"] ? self.root.igList : self.root.rdList;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"INTERRUPTOR MANUAL DE LA APP" : @"CONTENEDORES (DESLIZA IZQ. PARA OCULTAR)";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : self.containers.count;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 && indexPath.row > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style == UITableViewCellEditingStyleDelete) {
        NSDictionary *p = self.containers[indexPath.row];
        NSMutableArray *hid = [self.root.state[@"hiddenIDs"] mutableCopy] ?: [NSMutableArray array];
        [hid addObject:[p[@"containerUUID"] lowercaseString]];
        self.root.state[@"hiddenIDs"] = hid;
        [self.root saveState];
        [self.containers removeObjectAtIndex:indexPath.row];
        [self.tableView reloadData];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;

    BOOL masterOn = [self.root.state[@"masterEnabled"] boolValue];
    BOOL appOn = [self.root.state[self.appKey] boolValue];

    if (indexPath.section == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        cell.textLabel.text = [NSString stringWithFormat:@"Habilitar en %@", self.appTitle];
        cell.detailTextLabel.text = (masterOn && appOn) ? @"🟢 Activo" : @"⚪ En pausa (Nativo)";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = appOn; sw.enabled = masterOn;
        [sw addTarget:self action:@selector(toggleApp:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    NSMutableDictionary *p = self.containers[indexPath.row];
    BOOL cOn = [p[@"enabled"] boolValue];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
    cell.textLabel.text = p[@"containerName"] ?: @"Default";
    cell.detailTextLabel.text = (masterOn && appOn && cOn)
        ? [NSString stringWithFormat:@"🟢 ACTIVO • IP: %@ • %@", p[@"lastSyncedIP"], p[@"timeZone"]]
        : [NSString stringWithFormat:@"⚪ EN PAUSA (Manual) • ID: %@", p[@"containerUUID"]];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = cOn; sw.enabled = (masterOn && appOn); sw.tag = indexPath.row;
    [sw addTarget:self action:@selector(toggleCont:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (void)toggleApp:(UISwitch *)sw {
    haptic();
    self.root.state[self.appKey] = @(sw.isOn);
    [self.root saveState];
    killProc([self.bundleID isEqualToString:@"com.burbn.instagram"] ? @"Instagram" : @"Reddit");
    [self.tableView reloadData];
}

- (void)toggleCont:(UISwitch *)sw {
    haptic();
    NSDictionary *p = self.containers[sw.tag];
    [self.root setContainer:p[@"containerUUID"] enabled:sw.isOn bundle:self.bundleID];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        IGFarmContainerDetailController *vc = [[IGFarmContainerDetailController alloc] init];
        vc.bundleID = self.bundleID;
        vc.profile = self.containers[indexPath.row];
        vc.uuid = vc.profile[@"containerUUID"];
        vc.root = self.root;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

@end

@implementation IGFarmContainerDetailController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.profile[@"containerName"] ?: @"Contenedor";
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 62.0;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"1. INTERRUPTOR Y RED DEL CONTENEDOR";
    if (section == 1) return @"2. MÓDULOS MANUALES (ENCENDER SOLO LO NECESARIO)";
    return @"3. DATOS DEL CONTENEDOR";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 3;
    if (section == 1) return 5;
    return 4;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    BOOL cOn = [self.profile[@"enabled"] boolValue];

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.textLabel.text = @"Habilitar este Contenedor";
            cell.detailTextLabel.text = cOn ? @"🟢 Activo" : @"⚪ Apagado (Modo nativo puro)";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = cOn; sw.tag = 100;
            [sw addTarget:self action:@selector(toggleMod:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"⚡ Sincronizar con IP Actual (Shadowrocket)";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"IP actual guardada: %@ (%@)", self.profile[@"lastSyncedIP"], self.profile[@"timeZone"]];
        } else {
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.textLabel.text = @"🔄 Regenerar Datos del Contenedor";
            cell.detailTextLabel.text = @"Genera nuevos valores de red local y sensores";
        }
        return cell;
    }

    if (indexPath.section == 1) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSArray *titles = @[
            @"1. Bloquear Cartel de iCloud / Apple ID",
            @"2. Sincronizar Zona Horaria con la IP",
            @"3. Red Local Aislada (Wi-Fi / Operadora)",
            @"4. Sensores Físicos (Batería, Brillo, Audio)",
            @"5. Ocultar Rutas /var/jb (Modo Seguro sin Hooks C)"
        ];
        NSArray *keys = @[@"spoofIDs", @"spoofLocation", @"spoofNetwork", @"spoofHardware", @"spoofSecurity"];
        NSString *k = keys[indexPath.row];
        BOOL mOn = [self.profile[k] boolValue];

        cell.textLabel.font = [UIFont boldSystemFontOfSize:14.5];
        cell.textLabel.text = titles[indexPath.row];
        cell.detailTextLabel.text = mOn ? @"🟢 Habilitado manualmente" : @"⚪ Desactivado (Nativo)";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = mOn; sw.enabled = cOn; sw.tag = 200 + indexPath.row;
        [sw addTarget:self action:@selector(toggleMod:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    if (indexPath.row == 0) {
        cell.textLabel.text = @"📦 Contenedor en Crane";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Nombre: %@\nID:     %@", self.profile[@"containerName"], self.uuid];
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"🌎 Red e IP Sincronizada";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"IP:   %@\nISP:  %@\nZona: %@", self.profile[@"lastSyncedIP"], self.profile[@"ispName"], self.profile[@"timeZone"]];
    } else if (indexPath.row == 2) {
        cell.textLabel.text = @"📡 Wi-Fi Local Asignado";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"LAN:  %@\nSSID: %@ (%@)", self.profile[@"localIP"], self.profile[@"ssid"], self.profile[@"bssid"]];
    } else {
        int bat = (int)([self.profile[@"batteryLevel"] floatValue] * 100);
        int vol = (int)([self.profile[@"audioVolume"] floatValue] * 100);
        cell.textLabel.text = @"🔋 Sensores Asignados";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Batería: %d%% • Volumen: %d%%", bat, vol];
    }
    return cell;
}

- (void)toggleMod:(UISwitch *)sw {
    haptic();
    if (sw.tag == 100) {
        [self.root setContainer:self.uuid enabled:sw.isOn bundle:self.bundleID];
        self.profile[@"enabled"] = @(sw.isOn);
    } else {
        NSArray *keys = @[@"spoofIDs", @"spoofLocation", @"spoofNetwork", @"spoofHardware", @"spoofSecurity"];
        self.profile[keys[sw.tag - 200]] = @(sw.isOn);
        [self.root saveProfile:self.profile forUUID:self.uuid];
        killProc([self.bundleID isEqualToString:@"com.burbn.instagram"] ? @"Instagram" : @"Reddit");
    }
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;

    if (indexPath.row == 1) {
        haptic();
        NSArray *urls = @[@"https://ipwho.is/", @"https://ipapi.co/json/", @"https://ipinfo.io/json"];
        fetchIPCascade(urls, 0, ^(NSDictionary *res) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!res) {
                    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Error de Red" message:@"No hubo respuesta de los servidores HTTPS." preferredStyle:UIAlertControllerStyleAlert];
                    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:ac animated:YES completion:nil];
                    return;
                }
                classifyIPAndApplyToProfile(self.profile, res[@"ip"], res[@"isp"], res[@"cc"], res[@"city"], res[@"region"], res[@"tz"], NO);
                [self.root saveProfile:self.profile forUUID:self.uuid];
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"✅ IP Sincronizada"
                                                                            message:[NSString stringWithFormat:@"IP: %@\nISP: %@\nZona: %@", res[@"ip"], res[@"isp"], res[@"tz"]]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
        });
    } else if (indexPath.row == 2) {
        haptic();
        self.profile = [self.root ensureProfile:self.bundleID uuid:self.uuid name:self.profile[@"containerName"] path:self.profile[@"path"] rotate:YES];
        [self.tableView reloadData];
    }
}

@end
