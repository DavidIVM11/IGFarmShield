#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
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
#define CURRENT_SCHEMA_VERSION 18

@interface PSViewController : UIViewController
@end

@class IGFarmRootListController;

static UIImage *settingsBadgeIcon(NSString *symbolName, UIColor *bgColor) {
    static NSMutableDictionary *iconCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ iconCache = [NSMutableDictionary dictionary]; });

    NSString *cacheKey = [NSString stringWithFormat:@"%@_%@", symbolName, bgColor.description];
    if (iconCache[cacheKey]) return iconCache[cacheKey];

    CGSize size = CGSizeMake(29, 29);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 29, 29) cornerRadius:6.5];
        [bgColor setFill];
        [path fill];

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.5 weight:UIImageSymbolWeightSemibold];
        UIImage *sym = [[UIImage systemImageNamed:symbolName withConfiguration:cfg] imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (sym) {
            CGRect r = CGRectMake((29.0 - sym.size.width) / 2.0, (29.0 - sym.size.height) / 2.0, sym.size.width, sym.size.height);
            [sym drawInRect:r];
        }
    }];

    if (img) iconCache[cacheKey] = img;
    return img;
}

static void triggerHaptic() {
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [gen prepare];
    [gen impactOccurred];
}

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
            if ([dict[ak] isKindOfClass:[NSString class]] && [dict[ak] length] > 0) {
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
                        NSString *subID = kStr;
                        for (NSString *ik in @[@"identifier", @"id", @"UUID", @"uuid", @"containerIdentifier"]) {
                            if ([sub[ik] isKindOfClass:[NSString class]] && [sub[ik] length] > 0) {
                                subID = sub[ik];
                                break;
                            }
                        }
                        outContainers[subID] = sub[nk];
                    }
                }
            } else if ([val isKindOfClass:[NSString class]]) {
                NSString *vStr = (NSString *)val;
                if (kStr.length >= 8 && [kStr containsString:@"-"] && vStr.length > 0 && vStr.length < 50 && ![vStr containsString:@"/"]) {
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

static void classifyIPAndApplyToProfile(NSMutableDictionary *prof, NSString *ip, NSString *ispRaw, NSString *cc, NSString *city, NSString *region, NSString *tz, BOOL isMobileFlag) {
    if (!prof) return;
    NSString *ispUp = [ispRaw ?: @"" uppercaseString];
    NSString *ccLow = [cc ?: @"us" lowercaseString];

    prof[@"locationAnchored"] = @YES;
    prof[@"lastSyncedIP"] = ip ?: @"";
    prof[@"ispName"] = ispRaw ?: @"ISP";
    prof[@"cityCountry"] = [NSString stringWithFormat:@"%@, %@ (%@)", city ?: @"", region ?: @"", [ccLow uppercaseString]];
    prof[@"timeZone"] = tz ?: @"America/New_York";
    prof[@"localeID"] = [NSString stringWithFormat:@"en_%@", [ccLow uppercaseString]];

    BOOL isMobileCarrier = isMobileFlag ||
                           [ispUp containsString:@"T-MOBILE"] ||
                           [ispUp containsString:@"AT&T"] ||
                           [ispUp containsString:@"VERIZON"] ||
                           [ispUp containsString:@"METRO"] ||
                           [ispUp containsString:@"MINT"] ||
                           [ispUp containsString:@"CRICKET"] ||
                           [ispUp containsString:@"VISIBLE"] ||
                           [ispUp containsString:@"VODAFONE"] ||
                           [ispUp containsString:@"MOVISTAR"] ||
                           [ispUp containsString:@"ORANGE"] ||
                           [ispUp containsString:@"O2"] ||
                           [ispUp containsString:@"THREE"] ||
                           [ispUp containsString:@"CELL"] ||
                           [ispUp containsString:@"MOBILE"] ||
                           [ispUp containsString:@"WIRELESS"];

    if ([ispUp containsString:@"T-MOBILE"] || [ispUp containsString:@"METRO"] || [ispUp containsString:@"MINT"]) {
        prof[@"CarrierMode"] = @"CELLULAR"; prof[@"CarrierName"] = @"T-Mobile";
        prof[@"CarrierMCC"] = @"310"; prof[@"CarrierMNC"] = @"260"; prof[@"CarrierISO"] = ccLow;
    } else if ([ispUp containsString:@"AT&T"] || [ispUp containsString:@"CRICKET"]) {
        prof[@"CarrierMode"] = @"CELLULAR"; prof[@"CarrierName"] = @"AT&T";
        prof[@"CarrierMCC"] = @"310"; prof[@"CarrierMNC"] = @"410"; prof[@"CarrierISO"] = ccLow;
    } else if ([ispUp containsString:@"VERIZON"] || [ispUp containsString:@"VISIBLE"]) {
        prof[@"CarrierMode"] = @"CELLULAR"; prof[@"CarrierName"] = @"Verizon";
        prof[@"CarrierMCC"] = @"311"; prof[@"CarrierMNC"] = @"480"; prof[@"CarrierISO"] = ccLow;
    } else if (isMobileCarrier) {
        prof[@"CarrierMode"] = @"CELLULAR"; prof[@"CarrierName"] = ispRaw ?: @"LTE";
        prof[@"CarrierMCC"] = @"310"; prof[@"CarrierMNC"] = @"260"; prof[@"CarrierISO"] = ccLow;
    } else {
        prof[@"CarrierMode"] = @"WIFI_ONLY"; prof[@"CarrierName"] = ispRaw ?: @"Wi-Fi";
        prof[@"CarrierMCC"] = @""; prof[@"CarrierMNC"] = @""; prof[@"CarrierISO"] = ccLow;
    }
}

static void fetchLiveIPFromEndpoints(NSArray<NSString *> *urls, NSUInteger index, void (^completion)(NSDictionary *parsed, NSError *error)) {
    if (index >= urls.count) {
        if (completion) completion(nil, [NSError errorWithDomain:@"IGFarmShield" code:-1 userInfo:nil]);
        return;
    }

    NSURL *url = [NSURL URLWithString:urls[index]];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.URLCache = nil;
    cfg.HTTPCookieStorage = nil;
    cfg.timeoutIntervalForRequest = 8.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) {
            fetchLiveIPFromEndpoints(urls, index + 1, completion);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) {
            fetchLiveIPFromEndpoints(urls, index + 1, completion);
            return;
        }

        NSString *ip = nil;
        NSString *isp = nil;
        NSString *cc = nil;
        NSString *city = nil;
        NSString *region = nil;
        NSString *tz = nil;
        BOOL isMobile = NO;

        if (json[@"ip"] && [json[@"success"] boolValue]) {
            ip = json[@"ip"];
            NSDictionary *conn = [json[@"connection"] isKindOfClass:[NSDictionary class]] ? json[@"connection"] : @{};
            NSDictionary *tzD = [json[@"timezone"] isKindOfClass:[NSDictionary class]] ? json[@"timezone"] : @{};
            isp = conn[@"isp"] ?: (conn[@"org"] ?: @"ISP");
            cc = json[@"country_code"];
            city = json[@"city"];
            region = json[@"region"];
            tz = tzD[@"id"];
        } else if (json[@"ip"] && json[@"country_code"] && !json[@"error"]) {
            ip = json[@"ip"];
            isp = json[@"org"] ?: @"ISP";
            cc = json[@"country_code"];
            city = json[@"city"];
            region = json[@"region"];
            tz = json[@"timezone"];
        } else if (json[@"ip"] && json[@"country"] && json[@"timezone"]) {
            ip = json[@"ip"];
            isp = json[@"org"] ?: @"ISP";
            cc = json[@"country"];
            city = json[@"city"];
            region = json[@"region"];
            tz = json[@"timezone"];
        } else if ([json[@"status"] isEqualToString:@"success"] && json[@"query"]) {
            ip = json[@"query"];
            isp = json[@"isp"] ?: @"ISP";
            cc = json[@"countryCode"];
            city = json[@"city"];
            region = json[@"regionName"];
            tz = json[@"timezone"];
            isMobile = [json[@"mobile"] boolValue];
        }

        if (ip && ip.length > 0 && tz && tz.length > 0) {
            if (completion) {
                completion(@{
                    @"ip": ip,
                    @"isp": isp ?: @"ISP",
                    @"cc": [cc ?: @"us" lowercaseString],
                    @"city": city ?: @"",
                    @"region": region ?: @"",
                    @"tz": tz ?: @"America/New_York",
                    @"mobile": @(isMobile)
                }, nil);
            }
        } else {
            fetchLiveIPFromEndpoints(urls, index + 1, completion);
        }
    }] resume];
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
- (UIView *)buildHeaderBannerView;
- (void)auditChoicyStatus;
- (void)scanAndSyncAllContainers;
- (void)calculateResidualTraces;
- (void)cleanResidualTracesAndKillApps:(BOOL)showPopup;
- (void)toggleRootSwitch:(UISwitch *)sender;
- (NSString *)enforceExclusiveModeWhenToggledOn;
- (void)deduplicateActiveIfMultiple;
- (NSMutableDictionary *)profileForUUID:(NSString *)uuid;
- (NSMutableDictionary *)ensureProfileForBundle:(NSString *)bundleID uuid:(NSString *)uuid craneID:(NSString *)craneID defaultName:(NSString *)dName path:(NSString *)path allowEnableDefault:(BOOL)allowEnable forceRotate:(BOOL)rotate;
- (void)saveProfile:(NSMutableDictionary *)profile forUUID:(NSString *)uuid;
- (void)setContainer:(NSString *)targetUUID enabled:(BOOL)enabled inBundle:(NSString *)bundleID;
- (void)hideAndPurgeContainerProfile:(NSDictionary *)prof;
@end

@interface IGFarmAppContainersController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSString *bundleID;
@property (nonatomic, strong) NSString *appTitle;
@property (nonatomic, strong) NSString *appStateKey;
@property (nonatomic, strong) NSMutableArray *containers;
@property (nonatomic, weak) IGFarmRootListController *parentRoot;
@property (nonatomic, strong) UITableView *tableView;
- (void)refreshFromCrane:(UIRefreshControl *)rc;
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
- (void)refreshPurePhoneTelemetryValuesOnly;
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
    if (![self.state[@"hiddenContainerIDs"] isKindOfClass:[NSArray class]]) {
        self.state[@"hiddenContainerIDs"] = @[];
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
    self.tableView.tableHeaderView = [self buildHeaderBannerView];
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    if (loaded) self.state = [loaded mutableCopy];
    [self auditChoicyStatus];
    [self scanAndSyncAllContainers];
    [self calculateResidualTraces];
    self.tableView.tableHeaderView = [self buildHeaderBannerView];
    [self.tableView reloadData];
}

- (UIView *)buildHeaderBannerView {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 108)];
    header.backgroundColor = [UIColor clearColor];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 12, self.view.bounds.size.width - 32, 86)];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 14.0;
    card.clipsToBounds = YES;

    UIImageView *shieldView = [[UIImageView alloc] initWithFrame:CGRectMake(16, 18, 50, 50)];
    shieldView.backgroundColor = [UIColor systemBlueColor];
    shieldView.layer.cornerRadius = 12.0;
    shieldView.contentMode = UIViewContentModeCenter;
    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightBold];
    shieldView.image = [[UIImage systemImageNamed:@"checkmark.shield.fill" withConfiguration:symCfg] imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    [card addSubview:shieldView];

    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(78, 16, card.bounds.size.width - 90, 22)];
    titleLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    titleLbl.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    titleLbl.text = @"IGFarmShield";
    [card addSubview:titleLbl];

    UILabel *subLbl = [[UILabel alloc] initWithFrame:CGRectMake(78, 38, card.bounds.size.width - 90, 16)];
    subLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    subLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    subLbl.textColor = [UIColor secondaryLabelColor];
    subLbl.text = @"Sincronización directa con Crane • Zero-Leak";
    [card addSubview:subLbl];

    BOOL masterOn = [self.state[@"masterEnabled"] boolValue];
    UILabel *pill = [[UILabel alloc] initWithFrame:CGRectMake(78, 57, 225, 18)];
    pill.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    pill.textColor = masterOn ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    pill.text = masterOn
        ? [NSString stringWithFormat:@"● ESCUDO ACTIVO • TÚNEL: %@", self.vpnActive ? [self.vpnInterfaceName uppercaseString] : @"DIRECTO"]
        : @"○ ESCUDO GLOBAL EN PAUSA";
    [card addSubview:pill];

    [header addSubview:card];
    return header;
}

- (void)saveState {
    [self.state writeToFile:STATE_PLIST atomically:YES];
}

- (void)hideAndPurgeContainerProfile:(NSDictionary *)prof {
    if (!prof) return;
    NSString *uuid = prof[@"containerUUID"];
    NSString *craneID = prof[@"craneIdentifier"];

    NSMutableArray *hidden = [self.state[@"hiddenContainerIDs"] isKindOfClass:[NSArray class]]
        ? [self.state[@"hiddenContainerIDs"] mutableCopy]
        : [NSMutableArray array];
    if (uuid.length > 0 && ![hidden containsObject:[uuid lowercaseString]]) {
        [hidden addObject:[uuid lowercaseString]];
    }
    if (craneID.length > 0 && ![hidden containsObject:[craneID lowercaseString]]) {
        [hidden addObject:[craneID lowercaseString]];
    }
    self.state[@"hiddenContainerIDs"] = hidden;

    NSMutableDictionary *byUUID = [self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containersByUUID"] mutableCopy]
        : [NSMutableDictionary dictionary];
    if (uuid) [byUUID removeObjectForKey:uuid];
    if (craneID) [byUUID removeObjectForKey:craneID];
    self.state[@"containersByUUID"] = byUUID;
    [self saveState];
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
        self.choicySummary = @"Whitelist activa en Instagram y Reddit";
    } else if (igOK || rdOK) {
        self.choicySummary = [NSString stringWithFormat:@"Parcial • IG: %@ | Reddit: %@", igOK ? @"OK" : @"Pendiente", rdOK ? @"OK" : @"Pendiente"];
    } else {
        self.choicySummary = @"Escudo interno activo • Toca para ver detalles";
    }

    self.choicyDetailReport = [NSString stringWithFormat:
        @"• Choicy en Instagram: %@\n"
        @"• Choicy en Reddit: %@\n"
        @"• Importante en Crane para Reddit: Desactiva 'Separate System Accounts' en Crane.\n"
        @"• Tip: Si algún contenedor viejo queda en caché, deslízalo hacia la izquierda para eliminarlo.",
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
    if ([p isKindOfClass:[NSString class]] && p.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:p]) {
        NSString *localPlist = [p stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        [profile writeToFile:localPlist atomically:YES];
    }
}

- (void)deduplicateActiveIfMultiple {
    NSDictionary *activeMap = self.state[@"activeInCrane"];
    for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
        BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
        NSMutableArray *list = isIG ? self.igContainersList : self.redditContainersList;

        NSMutableArray *enabledList = [NSMutableArray array];
        for (NSMutableDictionary *p in list) {
            if ([p[@"enabled"] boolValue]) [enabledList addObject:p];
        }
        if (enabledList.count <= 1) continue;

        NSString *preferredID = activeMap[bID];
        NSString *chosenUUID = nil;
        for (NSMutableDictionary *p in enabledList) {
            if (preferredID &&
                ([p[@"containerUUID"] caseInsensitiveCompare:preferredID] == NSOrderedSame ||
                 [p[@"craneIdentifier"] caseInsensitiveCompare:preferredID] == NSOrderedSame ||
                 [p[@"containerName"] caseInsensitiveCompare:preferredID] == NSOrderedSame)) {
                chosenUUID = p[@"containerUUID"];
                break;
            }
        }
        if (!chosenUUID) {
            chosenUUID = enabledList.firstObject[@"containerUUID"];
        }

        for (NSMutableDictionary *p in list) {
            NSString *u = p[@"containerUUID"];
            BOOL keepOn = [u isEqualToString:chosenUUID];
            p[@"enabled"] = @(keepOn);
            [self saveProfile:p forUUID:u];
        }
    }
}

- (NSString *)enforceExclusiveModeWhenToggledOn {
    NSDictionary *activeMap = self.state[@"activeInCrane"];
    NSMutableArray *keptNames = [NSMutableArray array];

    for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
        BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
        NSMutableArray *list = isIG ? self.igContainersList : self.redditContainersList;
        if (list.count == 0) continue;

        NSString *preferredID = activeMap[bID];
        NSString *chosenUUID = nil;

        for (NSMutableDictionary *p in list) {
            if ([p[@"enabled"] boolValue] && preferredID &&
                ([p[@"containerUUID"] caseInsensitiveCompare:preferredID] == NSOrderedSame ||
                 [p[@"craneIdentifier"] caseInsensitiveCompare:preferredID] == NSOrderedSame ||
                 [p[@"containerName"] caseInsensitiveCompare:preferredID] == NSOrderedSame)) {
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
            [keptNames addObject:[NSString stringWithFormat:@"%@: Ninguno (En pausa manual)", isIG ? @"IG" : @"Reddit"]];
            continue;
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

- (NSMutableDictionary *)ensureProfileForBundle:(NSString *)bundleID uuid:(NSString *)uuid craneID:(NSString *)craneID defaultName:(NSString *)dName path:(NSString *)path allowEnableDefault:(BOOL)allowEnable forceRotate:(BOOL)rotate {
    if (!bundleID) bundleID = @"com.burbn.instagram";
    if (!uuid || uuid.length == 0) uuid = craneID ?: @"Default";
    if (!craneID || craneID.length == 0) craneID = uuid;

    NSMutableDictionary *byUUID = [self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containersByUUID"] mutableCopy]
        : [NSMutableDictionary dictionary];

    NSMutableDictionary *profile = nil;
    if ([byUUID[uuid] isKindOfClass:[NSDictionary class]] && byUUID[uuid][@"idfv"]) {
        profile = [byUUID[uuid] mutableCopy];
    }
    if (!profile) {
        for (NSString *existingKey in [byUUID allKeys]) {
            if ([existingKey caseInsensitiveCompare:uuid] == NSOrderedSame ||
                [existingKey caseInsensitiveCompare:craneID] == NSOrderedSame) {
                NSDictionary *cand = byUUID[existingKey];
                if ([cand isKindOfClass:[NSDictionary class]] && [cand[@"bundleID"] isEqualToString:bundleID] && cand[@"idfv"]) {
                    profile = [cand mutableCopy];
                    if (![existingKey isEqualToString:uuid]) {
                        [byUUID removeObjectForKey:existingKey];
                        self.state[@"containersByUUID"] = byUUID;
                    }
                    break;
                }
            }
        }
    }
    if (!profile && path.length > 0) {
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Library/.igshield_container.plist"]];
        if ([disk isKindOfClass:[NSDictionary class]] && disk[@"idfv"]) {
            profile = [disk mutableCopy];
        }
    }

    NSString *cleanCraneName = (dName && dName.length > 0) ? dName : @"Default";
    NSString *shieldIDFV = ([craneID containsString:@"-"] && craneID.length >= 32 && !rotate)
        ? [craneID uppercaseString]
        : (profile[@"idfv"] && !rotate ? profile[@"idfv"] : [[NSUUID UUID] UUIDString]);

    if (!profile || !profile[@"idfv"] || rotate) {
        BOOL wasEnabled = (profile && profile[@"enabled"] != nil) ? [profile[@"enabled"] boolValue] : allowEnable;

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
        unsigned long long freeBytes = ((14200ULL + (seed % 32000ULL)) * 1024ULL * 1024ULL) + ((seed >> 12) % 1048576ULL);

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
            @"locationAnchored": profile[@"locationAnchored"] ?: @NO,
            @"deviceModel": @"iPhone10,4",
            @"craneOriginalIDFV": craneID,
            @"idfv": shieldIDFV,
            @"shieldDeviceID": [[NSUUID UUID] UUIDString],
            @"bootSessionUUID": [[NSUUID UUID] UUIDString],
            @"cloudUUID": [[NSUUID UUID] UUIDString],
            @"bssid": bssid,
            @"ssid": ssid,
            @"localIP": localIP,
            @"freeBytes": @(freeBytes),
            @"batteryLevel": @(0.28f + ((seed % 64) / 100.0f)),
            @"brightness": @(0.25f + (((seed >> 4) % 65) / 100.0f)),
            @"audioVolume": @(0.18f + (((seed >> 6) % 72) / 100.0f)),
            @"pasteboardCount": @(4 + (seed % 95)),
            @"lastSyncedIP": profile[@"lastSyncedIP"] ?: @"Sin sincronizar",
            @"ispName": profile[@"ispName"] ?: @"Pendiente",
            @"cityCountry": profile[@"cityCountry"] ?: @"Sincroniza dentro del contenedor",
            @"timeZone": profile[@"timeZone"] ?: @"America/New_York",
            @"localeID": profile[@"localeID"] ?: @"en_US",
            @"CarrierMode": profile[@"CarrierMode"] ?: @"CELLULAR",
            @"CarrierName": profile[@"CarrierName"] ?: @"T-Mobile",
            @"CarrierMCC": profile[@"CarrierMCC"] ?: @"310",
            @"CarrierMNC": profile[@"CarrierMNC"] ?: @"260",
            @"CarrierISO": profile[@"CarrierISO"] ?: @"us"
        } mutableCopy];
    } else {
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

// Escaneo híbrido completo: lee contenedores en disco + contenedores recién creados en Crane
- (void)scanAndSyncAllContainers {
    self.igContainersList = [NSMutableArray array];
    self.redditContainersList = [NSMutableArray array];
    NSMutableSet *seenUUIDs = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL exclusive = [self.state[@"exclusiveMode"] boolValue];

    NSMutableSet *hiddenSet = [NSMutableSet set];
    if ([self.state[@"hiddenContainerIDs"] isKindOfClass:[NSArray class]]) {
        for (NSString *h in self.state[@"hiddenContainerIDs"]) {
            [hiddenSet addObject:[h lowercaseString]];
        }
    }

    // 1. Leer todas las fuentes de configuración de Crane
    NSMutableArray *craneSources = [NSMutableArray array];
    for (NSString *domain in @[@"com.opa334.crane", @"com.opa334.craneprefs"]) {
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
        for (NSString *user in @[@"mobile", @"root"]) {
            CFDictionaryRef cfDict = CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)domain, (__bridge CFStringRef)user, kCFPreferencesAnyHost);
            if (cfDict) {
                NSDictionary *d = CFBridgingRelease(cfDict);
                if ([d count] > 0) [craneSources addObject:d];
            }
        }
        NSDictionary *ud = [[[NSUserDefaults alloc] initWithSuiteName:domain] dictionaryRepresentation];
        if ([ud count] > 0) [craneSources addObject:ud];
    }
    for (NSString *pPath in @[CRANE_PREFS_JB, CRANE_PREFS_VAR, CRANE_MAIN_JB, CRANE_MAIN_VAR]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:pPath];
        if ([d count] > 0) [craneSources addObject:d];
    }

    NSArray *prefDirs = @[
        @"/var/mobile/Library/Preferences",
        @"/var/jb/var/mobile/Library/Preferences",
        @"/var/mobile/Library/Application Support/Crane",
        @"/var/jb/var/mobile/Library/Application Support/Crane",
        @"/var/mobile/Library/Crane",
        @"/var/jb/var/mobile/Library/Crane"
    ];
    for (NSString *pDir in prefDirs) {
        if (![fm fileExistsAtPath:pDir]) continue;
        NSArray *files = [fm subpathsOfDirectoryAtPath:pDir error:nil];
        for (NSString *f in files) {
            if (([[f lowercaseString] containsString:@"crane"] || [pDir containsString:@"Crane"]) && [f hasSuffix:@".plist"]) {
                NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[pDir stringByAppendingPathComponent:f]];
                if ([d isKindOfClass:[NSDictionary class]] && [d count] > 0) {
                    [craneSources addObject:d];
                }
            }
        }
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

    // Si Crane tiene registrado un contenedor de nuevo en su plist vivo, quitarlo de la lista de ocultos
    for (NSString *cID in [igCraneMap allKeys]) [hiddenSet removeObject:[cID lowercaseString]];
    for (NSString *cID in [rdCraneMap allKeys]) [hiddenSet removeObject:[cID lowercaseString]];

    // 2. Escanear todas las carpetas en /var/mobile/Containers/Data/Application
    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:appsDir error:nil];

    for (NSString *folderUUID in uuids) {
        if ([hiddenSet containsObject:[folderUUID lowercaseString]]) continue;

        NSString *fullPath = [appsDir stringByAppendingPathComponent:folderUUID];
        NSString *metaPath = [fullPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        if (![meta isKindOfClass:[NSDictionary class]]) continue;

        BOOL isIG = nodeMentionsString(meta, @"com.burbn.instagram");
        BOOL isRD = nodeMentionsString(meta, @"com.reddit.Reddit");
        if (!isIG && !isRD) continue;

        NSString *bundleID = isIG ? @"com.burbn.instagram" : @"com.reddit.Reddit";
        NSMutableDictionary *craneMap = isIG ? igCraneMap : rdCraneMap;
        NSMutableArray *targetList = isIG ? self.igContainersList : self.redditContainersList;

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
                    if ([kl containsString:@"name"] || [kl containsString:@"label"] || [kl containsString:@"title"]) {
                        detectedName = val;
                    } else if (([kl containsString:@"id"] || [kl containsString:@"crane"] || [kl containsString:@"container"] || [kl containsString:@"uuid"]) && ![val isEqualToString:bundleID]) {
                        craneID = val;
                    }
                }
            }
        }

        if ([hiddenSet containsObject:[craneID lowercaseString]]) continue;

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

        BOOL hasActiveAlready = NO;
        for (NSDictionary *p in targetList) {
            if ([p[@"enabled"] boolValue]) { hasActiveAlready = YES; break; }
        }
        BOOL allowOn = (!exclusive || !hasActiveAlready);

        NSMutableDictionary *prof = [self ensureProfileForBundle:bundleID
                                                            uuid:folderUUID
                                                         craneID:craneID
                                                     defaultName:detectedName
                                                            path:fullPath
                                              allowEnableDefault:allowOn
                                                     forceRotate:NO];
        [seenUUIDs addObject:[folderUUID lowercaseString]];
        [seenUUIDs addObject:[craneID lowercaseString]];
        [targetList addObject:prof];

        // Escanear subcarpetas ___Crane_Containers si existen dentro de la carpeta
        NSString *subCraneDir = [fullPath stringByAppendingPathComponent:@"___Crane_Containers"];
        if ([fm fileExistsAtPath:subCraneDir]) {
            NSArray *subUUIDs = [fm contentsOfDirectoryAtPath:subCraneDir error:nil];
            for (NSString *subID in subUUIDs) {
                if ([seenUUIDs containsObject:[subID lowercaseString]] || [hiddenSet containsObject:[subID lowercaseString]]) continue;
                NSString *subPath = [subCraneDir stringByAppendingPathComponent:subID];
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:subPath isDirectory:&isDir] || !isDir) continue;

                NSString *subName = craneMap[subID];
                if (!subName) {
                    for (NSDictionary *src in craneSources) {
                        subName = findCraneNameByID(src, subID);
                        if (subName) break;
                    }
                }
                if (!subName || subName.length == 0) subName = subID;

                BOOL subHasActive = NO;
                for (NSDictionary *p in targetList) {
                    if ([p[@"enabled"] boolValue]) { subHasActive = YES; break; }
                }
                BOOL subAllowOn = (!exclusive || !subHasActive);

                NSMutableDictionary *subProf = [self ensureProfileForBundle:bundleID
                                                                       uuid:subID
                                                                    craneID:subID
                                                                defaultName:subName
                                                                       path:subPath
                                                         allowEnableDefault:subAllowOn
                                                                forceRotate:NO];
                [seenUUIDs addObject:[subID lowercaseString]];
                [targetList addObject:subProf];
            }
        }
    }

    // 3. Añadir los contenedores creados en Crane (Add) que están en craneMap aunque aún no hayas abierto la app en ellos
    for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
        BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
        NSMutableDictionary *craneMap = isIG ? igCraneMap : rdCraneMap;
        NSMutableArray *targetList = isIG ? self.igContainersList : self.redditContainersList;

        for (NSString *cID in craneMap) {
            if ([seenUUIDs containsObject:[cID lowercaseString]] || [hiddenSet containsObject:[cID lowercaseString]]) continue;
            NSString *cName = craneMap[cID];
            if (![cName isKindOfClass:[NSString class]] || cName.length == 0) continue;

            // Evitar duplicar Default si ya está en la lista
            BOOL defaultExists = NO;
            for (NSDictionary *p in targetList) {
                if ([p[@"containerName"] caseInsensitiveCompare:@"Default"] == NSOrderedSame) {
                    defaultExists = YES; break;
                }
            }
            if (defaultExists && [cName caseInsensitiveCompare:@"Default"] == NSOrderedSame) continue;

            BOOL hasActiveAlready = NO;
            for (NSDictionary *p in targetList) {
                if ([p[@"enabled"] boolValue]) { hasActiveAlready = YES; break; }
            }
            BOOL allowOn = (!exclusive || !hasActiveAlready);

            NSMutableDictionary *prof = [self ensureProfileForBundle:bID
                                                                uuid:cID
                                                             craneID:cID
                                                         defaultName:cName
                                                                path:@""
                                                  allowEnableDefault:allowOn
                                                         forceRotate:NO];
            [seenUUIDs addObject:[cID lowercaseString]];
            [targetList addObject:prof];
        }
    }

    // Ordenar dejando Default arriba
    NSComparator sortBlock = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *na = a[@"containerName"] ?: @"";
        NSString *nb = b[@"containerName"] ?: @"";
        if ([na caseInsensitiveCompare:@"Default"] == NSOrderedSame) return NSOrderedAscending;
        if ([nb caseInsensitiveCompare:@"Default"] == NSOrderedSame) return NSOrderedDescending;
        return [na localizedCaseInsensitiveCompare:nb];
    };
    [self.igContainersList sortUsingComparator:sortBlock];
    [self.redditContainersList sortUsingComparator:sortBlock];

    // 4. Purgar de state.plist los contenedores que ya no estén ni en disco ni en Crane
    NSMutableDictionary *byUUID = [self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containersByUUID"] mutableCopy]
        : [NSMutableDictionary dictionary];
    for (NSString *savedKey in [byUUID allKeys]) {
        if (![seenUUIDs containsObject:[savedKey lowercaseString]]) {
            [byUUID removeObjectForKey:savedKey];
        }
    }
    self.state[@"containersByUUID"] = byUUID;

    NSMutableDictionary *activeMap = [self.state[@"activeInCrane"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"activeInCrane"] mutableCopy]
        : [NSMutableDictionary dictionary];
    if (igActiveCraneID) activeMap[@"com.burbn.instagram"] = igActiveCraneID;
    if (rdActiveCraneID) activeMap[@"com.reddit.Reddit"] = rdActiveCraneID;
    self.state[@"activeInCrane"] = activeMap;

    if (exclusive) {
        [self deduplicateActiveIfMultiple];
    }

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
    self.residualSummary = [NSString stringWithFormat:@"%lu archivos residuales (%.2f MB) + Portapapeles", (unsigned long)residualFiles, mb];
}

- (void)cleanResidualTracesAndKillApps:(BOOL)showPopup {
    triggerHaptic();
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
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Rastro Residual Eliminado"
                                                                    message:[NSString stringWithFormat:@"• Instagram y Reddit cerrados.\n• %lu archivos residuales eliminados.\n• Portapapeles vaciado antes de rotar.", (unsigned long)removedCount]
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Listo" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"CONTROL PRINCIPAL";
    if (section == 1) return @"CONTENEDORES POR APLICACIÓN (CRANE)";
    if (section == 2) return @"DIAGNÓSTICO LOCAL DE SEGURIDAD";
    return @"ROTACIÓN SEGURA DE CUENTAS";
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
            cell.imageView.image = settingsBadgeIcon(@"shield.fill", [UIColor systemBlueColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            cell.textLabel.text = @"Escudo Maestro IGFarmShield";
            cell.detailTextLabel.text = masterOn ? @"Protección activa por contenedor" : @"Desactivado globalmente";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = masterOn;
            sw.tag = 10;
            [sw addTarget:self action:@selector(toggleRootSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            BOOL excl = [self.state[@"exclusiveMode"] boolValue];
            cell.imageView.image = settingsBadgeIcon(@"lock.fill", [UIColor systemIndigoColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold];
            cell.textLabel.text = @"Modo Exclusivo Automático";
            cell.detailTextLabel.text = excl ? @"Al activar un contenedor se apagan los demás automáticamente" : @"Permite múltiples contenedores activos";
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
            cell.imageView.image = settingsBadgeIcon(@"camera.fill", [UIColor systemPinkColor]);
            NSUInteger onCount = 0;
            NSString *activeName = @"Ninguno";
            for (NSDictionary *p in self.igContainersList) {
                if ([p[@"enabled"] boolValue]) {
                    onCount++;
                    activeName = p[@"containerName"] ?: @"Default";
                }
            }
            cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            cell.textLabel.text = [NSString stringWithFormat:@"Instagram (%lu)", (unsigned long)self.igContainersList.count];
            cell.detailTextLabel.textColor = (onCount > 0) ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            cell.detailTextLabel.text = (onCount == 1)
                ? [NSString stringWithFormat:@"Protegido: %@", activeName]
                : (onCount == 0 ? @"Todos en pausa manual" : [NSString stringWithFormat:@"%lu contenedores protegidos", (unsigned long)onCount]);
        } else {
            cell.imageView.image = settingsBadgeIcon(@"bubble.left.and.bubble.right.fill", [UIColor systemOrangeColor]);
            NSUInteger onCount = 0;
            NSString *activeName = @"Ninguno";
            for (NSDictionary *p in self.redditContainersList) {
                if ([p[@"enabled"] boolValue]) {
                    onCount++;
                    activeName = p[@"containerName"] ?: @"Default";
                }
            }
            cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            cell.textLabel.text = [NSString stringWithFormat:@"Reddit (%lu)", (unsigned long)self.redditContainersList.count];
            cell.detailTextLabel.textColor = (onCount > 0) ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            cell.detailTextLabel.text = (onCount == 1)
                ? [NSString stringWithFormat:@"Protegido: %@", activeName]
                : (onCount == 0 ? @"Todos en pausa manual" : [NSString stringWithFormat:@"%lu contenedores protegidos", (unsigned long)onCount]);
        }
        return cell;
    }

    if (indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;

        if (indexPath.row == 0) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.imageView.image = settingsBadgeIcon(@"network", self.vpnActive ? [UIColor systemGreenColor] : [UIColor systemGrayColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            cell.textLabel.text = @"Interfaz de Túnel Local (Shadowrocket)";
            cell.detailTextLabel.text = self.vpnActive
                ? [NSString stringWithFormat:@"Túnel %@ activo • Sincronización HTTPS aislada por contenedor", self.vpnInterfaceName]
                : @"Sin túnel VPN activo (La IP se verifica dentro de cada contenedor)";
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.imageView.image = settingsBadgeIcon(@"checkmark.shield.fill", self.choicyAllSafe ? [UIColor systemGreenColor] : [UIColor systemOrangeColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            cell.textLabel.text = @"Auditoría de Choicy y Anti-Leak";
            cell.detailTextLabel.textColor = self.choicyAllSafe ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
            cell.detailTextLabel.text = self.choicySummary;
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.imageView.image = settingsBadgeIcon(@"trash.fill", [UIColor systemRedColor]);
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    cell.textLabel.textColor = [UIColor systemRedColor];
    cell.textLabel.text = @"Cerrar Apps y Limpiar Rastro Residual";
    cell.detailTextLabel.text = self.residualSummary;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)toggleRootSwitch:(UISwitch *)sender {
    triggerHaptic();
    if (sender.tag == 10) {
        self.state[@"masterEnabled"] = @(sender.isOn);
        [self saveState];
        killAppProcess(@"Instagram");
        killAppProcess(@"Reddit");
        self.tableView.tableHeaderView = [self buildHeaderBannerView];
        [self.tableView reloadData];
    } else if (sender.tag == 11) {
        self.state[@"exclusiveMode"] = @(sender.isOn);
        [self saveState];
        if (sender.isOn) {
            NSString *keptSummary = [self enforceExclusiveModeWhenToggledOn];
            killAppProcess(@"Instagram");
            killAppProcess(@"Reddit");
            [self.tableView reloadData];
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔒 Modo Exclusivo Aplicado"
                                                                        message:[NSString stringWithFormat:@"Estado actual por aplicación:\n• %@", keptSummary ?: @"Default"]
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
        triggerHaptic();
        IGFarmAppContainersController *appVC = [[IGFarmAppContainersController alloc] init];
        appVC.parentRoot = self;
        if (indexPath.row == 0) {
            appVC.bundleID = @"com.burbn.instagram";
            appVC.appTitle = @"Instagram";
            appVC.appStateKey = @"enableIG";
            appVC.containers = self.igContainersList;
        } else {
            appVC.bundleID = @"com.reddit.Reddit";
            appVC.appTitle = @"Reddit";
            appVC.appStateKey = @"enableReddit";
            appVC.containers = self.redditContainersList;
        }
        [self.navigationController pushViewController:appVC animated:YES];
        return;
    }

    if (indexPath.section == 2 && indexPath.row == 1) {
        triggerHaptic();
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🛡️ Estado de Aislamiento"
                                                                    message:self.choicyDetailReport
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    if (indexPath.section == 3) {
        [self cleanResidualTracesAndKillApps:YES];
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
    self.tableView.estimatedRowHeight = 68.0;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(refreshFromCrane:) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = rc;

    [self.view addSubview:self.tableView];
}

- (void)refreshFromCrane:(UIRefreshControl *)rc {
    triggerHaptic();
    // Al deslizar hacia abajo para refrescar, limpia la lista de ocultos para re-escanear todo desde Crane
    self.parentRoot.state[@"hiddenContainerIDs"] = @[];
    [self.parentRoot saveState];
    [self.parentRoot scanAndSyncAllContainers];
    self.containers = [self.bundleID isEqualToString:@"com.burbn.instagram"]
        ? self.parentRoot.igContainersList
        : self.parentRoot.redditContainersList;
    [self.tableView reloadData];
    [rc endRefreshing];
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
    if (section == 0) return @"CONTROL DE LA APLICACIÓN";
    return [NSString stringWithFormat:@"CONTENEDORES EN CRANE (%lu) — DESLIZA PARA REFRESCAR O BORRAR", (unsigned long)self.containers.count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return MAX(1, self.containers.count);
}

// Permite deslizar hacia la izquierda cualquier contenedor viejo para eliminarlo del tweak
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1 || self.containers.count == 0) return NO;
    NSDictionary *prof = self.containers[indexPath.row];
    return ([prof[@"containerName"] caseInsensitiveCompare:@"Default"] != NSOrderedSame);
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.section == 1 && indexPath.row < self.containers.count) {
        triggerHaptic();
        NSDictionary *prof = self.containers[indexPath.row];
        [self.parentRoot hideAndPurgeContainerProfile:prof];
        [self.containers removeObjectAtIndex:indexPath.row];
        [self.tableView reloadData];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL masterOn = [self.parentRoot.state[@"masterEnabled"] boolValue];
    BOOL appOn = [self.parentRoot.state[self.appStateKey] boolValue];

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.imageView.image = settingsBadgeIcon(@"power", [UIColor systemGreenColor]);
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        cell.textLabel.text = [NSString stringWithFormat:@"Proteger %@", self.appTitle];
        cell.detailTextLabel.text = (masterOn && appOn) ? @"Activo para los contenedores seleccionados" : @"En pausa para esta aplicación";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = appOn;
        sw.enabled = masterOn;
        [sw addTarget:self action:@selector(toggleAppMaster:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (self.containers.count == 0) {
        UITableViewCell *empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        empty.textLabel.text = @"No hay contenedores registrados";
        empty.detailTextLabel.text = @"Crea o abre un contenedor en Crane para sincronizarlo";
        return empty;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;

    NSMutableDictionary *prof = self.containers[indexPath.row];
    NSString *uuid = prof[@"containerUUID"] ?: @"Default";
    NSString *craneID = prof[@"craneIdentifier"] ?: uuid;
    NSString *cName = prof[@"containerName"] ?: @"Default";
    BOOL contOn = prof[@"enabled"] ? [prof[@"enabled"] boolValue] : NO;

    NSDictionary *activeMap = self.parentRoot.state[@"activeInCrane"];
    NSString *activeID = activeMap[self.bundleID];
    BOOL isCurrentInCrane = (activeID &&
                             ([activeID caseInsensitiveCompare:uuid] == NSOrderedSame ||
                              [activeID caseInsensitiveCompare:craneID] == NSOrderedSame ||
                              [activeID caseInsensitiveCompare:cName] == NSOrderedSame));

    cell.imageView.image = settingsBadgeIcon(isCurrentInCrane ? @"checkmark.circle.fill" : @"shippingbox.fill",
                                             (masterOn && appOn && contOn) ? [UIColor systemBlueColor] : [UIColor systemGrayColor]);
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    cell.textLabel.text = isCurrentInCrane
        ? [NSString stringWithFormat:@"%@ (Activo en Crane)", cName]
        : cName;

    NSString *shortIDFV = [prof[@"idfv"] length] >= 8 ? [prof[@"idfv"] substringToIndex:8] : prof[@"idfv"];
    BOOL isCell = [prof[@"CarrierMode"] isEqualToString:@"CELLULAR"];
    NSString *netDesc = isCell
        ? [NSString stringWithFormat:@"4G %@", prof[@"CarrierName"] ?: @"LTE"]
        : [NSString stringWithFormat:@"Wi-Fi (%@)", prof[@"localIP"] ?: @"LAN"];
    int batPct = (int)([prof[@"batteryLevel"] floatValue] * 100.0f);

    if (masterOn && appOn && contOn) {
        cell.detailTextLabel.textColor = [UIColor systemGreenColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"● PROTEGIDO • %@ • IDFV: %@...\nIP Contenedor: %@ • Bat: %d%%",
                                     netDesc, shortIDFV, prof[@"lastSyncedIP"] ?: @"Sin sincronizar", batPct];
    } else {
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"○ EN PAUSA (Datos nativos) • IDFV: %@...", shortIDFV];
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
    triggerHaptic();
    self.parentRoot.state[self.appStateKey] = @(sender.isOn);
    [self.parentRoot saveState];
    killAppProcess([self.bundleID isEqualToString:@"com.burbn.instagram"] ? @"Instagram" : @"Reddit");
    [self.tableView reloadData];
}

- (void)toggleContainerRowSwitch:(UISwitch *)sender {
    triggerHaptic();
    if (sender.tag < 0 || sender.tag >= self.containers.count) return;
    NSMutableDictionary *targetProf = self.containers[sender.tag];
    NSString *targetUUID = targetProf[@"containerUUID"];
    NSString *cName = targetProf[@"containerName"] ?: @"Contenedor";
    BOOL excl = [self.parentRoot.state[@"exclusiveMode"] boolValue];

    [self.parentRoot setContainer:targetUUID enabled:sender.isOn inBundle:self.bundleID];
    [self.tableView reloadData];

    if (sender.isOn && excl && self.containers.count > 1) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔒 Contenedor Exclusivo Activo"
                                                                    message:[NSString stringWithFormat:@"Se activó \"%@\" y se pusieron en pausa los demás contenedores de %@.", cName, self.appTitle]
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || self.containers.count == 0) return;

    triggerHaptic();
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
    BOOL contOn = self.profile[@"enabled"] ? [self.profile[@"enabled"] boolValue] : NO;
    if (!contOn) return NO;
    return (self.profile[key] == nil) ? YES : [self.profile[key] boolValue];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"1. CONTROL Y RED EXCLUSIVA DE ESTE CONTENEDOR";
        case 1: return @"2. PROTOCOLOS DE SPOOFING INDEPENDIENTES";
        case 2: return @"3. FINGERPRINT AISLADO (TOCA UNA FILA PARA COPIAR)";
        case 3: return @"4. SENSORES PUROS DEL TELÉFONO Y ROTACIÓN";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 3;
        case 1: return 5;
        case 2: return 6;
        case 3: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL contOn = self.profile[@"enabled"] ? [self.profile[@"enabled"] boolValue] : NO;

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;

        if (indexPath.row == 0) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.imageView.image = settingsBadgeIcon(@"shield.lefthalf.filled", contOn ? [UIColor systemGreenColor] : [UIColor systemGrayColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            cell.textLabel.text = @"Escudo en este Contenedor";
            cell.detailTextLabel.text = contOn ? @"Activo • Datos aislados de otros contenedores" : @"En pausa (Usando datos reales del iPhone)";
            cell.detailTextLabel.textColor = contOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = contOn;
            sw.tag = 100;
            [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.imageView.image = settingsBadgeIcon(@"antenna.radiowaves.left.and.right", [UIColor systemBlueColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.text = @"Sincronizar IP y Antena en este Contenedor";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Cascada HTTPS vía Shadowrocket • IP guardada: %@",
                                         self.profile[@"lastSyncedIP"] ?: @"Sin sincronizar"];
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.imageView.image = settingsBadgeIcon(@"paperplane.fill", [UIColor systemIndigoColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            cell.textLabel.textColor = [UIColor systemIndigoColor];
            cell.textLabel.text = @"Auditar IP en Proxy Center (Telegram)";
            cell.detailTextLabel.text = @"Verifica en tu VPS si la IP de esta cuenta está limpia";
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;

        NSArray *icons = @[@"key.fill", @"wifi.slash", @"globe.americas.fill", @"battery.100", @"lock.shield.fill"];
        NSArray *colors = @[
            [UIColor systemPurpleColor],
            [UIColor systemBlueColor],
            [UIColor systemTealColor],
            [UIColor systemGreenColor],
            [UIColor systemOrangeColor]
        ];
        NSArray *titles = @[
            @"Identificadores del Sistema",
            @"Coherencia Automática 4G / Wi-Fi",
            @"Ubicación de Red (Hora e Idioma)",
            @"Datos Puros del Teléfono",
            @"Ocultación de Jailbreak"
        ];
        NSArray *subtitles = @[
            @"Sincroniza IDFV con Crane y aísla BootSessionUUID",
            @"Si usas Mobile Proxy oculta el Wi-Fi físico y reporta Datos Móviles 4G LTE",
            @"Ancla el huso horario e idioma de esta cuenta al país de su IP",
            @"Aísla porcentaje de batería, volumen, brillo y espacio libre en disco",
            @"Oculta /var/jb y palera1n solo ante la app sin interferir con Crane"
        ];
        NSArray *keys = @[@"spoofIDs", @"spoofNetwork", @"spoofLocation", @"spoofHardware", @"spoofSecurity"];

        cell.imageView.image = settingsBadgeIcon(icons[indexPath.row], colors[indexPath.row]);
        cell.textLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
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
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];

        double freeGB = [self.profile[@"freeBytes"] unsignedLongLongValue] / (1024.0*1024.0*1024.0);
        int batPct = (int)([self.profile[@"batteryLevel"] floatValue] * 100.0f);
        int volPct = (int)([self.profile[@"audioVolume"] floatValue] * 100.0f);
        int briPct = (int)([self.profile[@"brightness"] floatValue] * 100.0f);
        NSString *craneID = self.profile[@"craneIdentifier"] ?: self.containerUUID;

        switch (indexPath.row) {
            case 0: {
                cell.textLabel.text = @"📦 Identidad del Contenedor (Crane)";
                cell.detailTextLabel.textColor = contOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Nombre:       %@\nContainer ID: %@",
                                             self.profile[@"containerName"] ?: @"Default", craneID];
                break;
            }
            case 1: {
                BOOL on = [self isModOn:@"spoofIDs"];
                cell.textLabel.text = @"🔑 Identificadores del Sistema";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? [NSString stringWithFormat:@"● AISLADO:\nIDFV:     %@\nBootUUID: %@",
                       self.profile[@"idfv"], self.profile[@"bootSessionUUID"]]
                    : @"○ NATIVO (Exponiendo UUIDs reales del sistema)";
                break;
            }
            case 2: {
                BOOL on = [self isModOn:@"spoofNetwork"];
                BOOL isCell = [self.profile[@"CarrierMode"] isEqualToString:@"CELLULAR"];
                cell.textLabel.text = @"📡 Conexión Que Ve la Aplicación";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                if (!on) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"○ NATIVO (Exponiendo tu Wi-Fi real %@)", self.parentRoot.realLocalIP ?: @"LAN"];
                } else if (isCell) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"● DATOS MÓVILES 4G LTE (Wi-Fi Físico Oculto):\nOperadora: %@ (MCC %@ / MNC %@)",
                                                 self.profile[@"CarrierName"] ?: @"T-Mobile",
                                                 self.profile[@"CarrierMCC"] ?: @"310",
                                                 self.profile[@"CarrierMNC"] ?: @"260"];
                } else {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"● WI-FI RESIDENCIAL:\nIP Local:    %@\nRouter Wi-Fi: %@ (%@)",
                                                 self.profile[@"localIP"], self.profile[@"ssid"], self.profile[@"bssid"]];
                }
                break;
            }
            case 3: {
                BOOL on = [self isModOn:@"spoofLocation"];
                cell.textLabel.text = @"🌎 Ubicación de Red y Zona Horaria";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? [NSString stringWithFormat:@"● AISLADO POR CONTENEDOR:\nIP / ISP:      %@ (%@)\nUbicación:     %@\nZona / Idioma: %@ (%@)",
                       self.profile[@"lastSyncedIP"] ?: @"Sin sincronizar", self.profile[@"ispName"] ?: @"ISP",
                       self.profile[@"cityCountry"] ?: @"Sincroniza arriba", self.profile[@"timeZone"], self.profile[@"localeID"]]
                    : [NSString stringWithFormat:@"○ NATIVO (Hora local %@)", [[NSTimeZone localTimeZone] name]];
                break;
            }
            case 4: {
                BOOL on = [self isModOn:@"spoofHardware"];
                cell.textLabel.text = @"🔋 Datos Puros del Teléfono (iPhone 8)";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? [NSString stringWithFormat:@"● AISLADO (iPhone10,4 • Build Nativo):\nBatería: %d%% • Volumen: %d%% • Brillo: %d%%\nDisco Libre: %.2f GB de 64 GB",
                       batPct, volPct, briPct, freeGB]
                    : [NSString stringWithFormat:@"○ NATIVO (Bat %d%% • Vol %d%% • %@)",
                       self.parentRoot.realBatteryPct, self.parentRoot.realVolumePct, self.parentRoot.realFreeDisk ?: @"64GB"];
                break;
            }
            case 5: {
                BOOL on = [self isModOn:@"spoofSecurity"];
                cell.textLabel.text = @"🛡️ Blindaje Anti-Jailbreak";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? @"● ACTIVO: /var/jb y DYLD ocultos ante la app • Crane libre"
                    : @"○ DESACTIVADO (Rutas de Jailbreak visibles)";
                break;
            }
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    if (indexPath.row == 0) {
        cell.imageView.image = settingsBadgeIcon(@"bolt.batteryblock.fill", [UIColor systemBlueColor]);
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        cell.textLabel.text = @"Actualizar Datos Puros del Teléfono";
        cell.detailTextLabel.text = @"Varía batería, volumen, brillo y espacio libre sin tocar el IDFV";
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        cell.imageView.image = settingsBadgeIcon(@"arrow.triangle.2.circlepath", [UIColor systemRedColor]);
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        cell.textLabel.text = @"Regenerar Huella Completa del Contenedor";
        cell.detailTextLabel.text = @"Genera un nuevo BootUUID, red local y parámetros físicos desde cero";
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    return cell;
}

- (void)toggleSwitch:(UISwitch *)sender {
    triggerHaptic();
    if (sender.tag == 100) {
        [self.parentRoot setContainer:self.containerUUID enabled:sender.isOn inBundle:self.bundleID];
        self.profile[@"enabled"] = @(sender.isOn);
        [self.tableView reloadData];

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:sender.isOn ? @"🟢 Contenedor Protegido" : @"⚪ Contenedor en Pausa"
                                                                    message:sender.isOn ? @"Escudo activado para este contenedor." : @"Escudo en pausa. Este contenedor permanecerá desactivado hasta que lo vuelvas a encender."
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

        NSString *popupTitle = @"";
        NSString *popupMsg = @"";

        if (idx == 0) {
            popupTitle = sender.isOn ? @"🔑 Identificadores Aplicados" : @"⚪ Identificadores Desactivados";
            popupMsg = sender.isOn
                ? [NSString stringWithFormat:@"• IDFV: %@\n• BootUUID: %@", self.profile[@"idfv"], self.profile[@"bootSessionUUID"]]
                : @"Usando UUIDs nativos del sistema.";
        } else if (idx == 1) {
            BOOL isCell = [self.profile[@"CarrierMode"] isEqualToString:@"CELLULAR"];
            popupTitle = sender.isOn ? (isCell ? @"📱 Datos Móviles 4G Activos" : @"🛜 Wi-Fi Residencial Activo") : @"⚪ Spoof de Red Desactivado";
            popupMsg = sender.isOn
                ? (isCell
                   ? [NSString stringWithFormat:@"Operadora inyectada: %@ (%@/%@) • Wi-Fi físico oculto.", self.profile[@"CarrierName"], self.profile[@"CarrierMCC"], self.profile[@"CarrierMNC"]]
                   : [NSString stringWithFormat:@"Wi-Fi inyectado: %@ (%@)", self.profile[@"ssid"], self.profile[@"bssid"]])
                : @"Mostrando conexión física real del teléfono.";
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
                popupMsg = [NSString stringWithFormat:@"• Batería: %d%%\n• Volumen: %d%%\n• Brillo: %d%%\n• Espacio Libre: %.2f GB", batPct, volPct, briPct, freeGB];
            } else {
                popupTitle = @"⚪ Datos de Hardware Desactivados";
                popupMsg = @"Reportando batería, volumen y disco reales.";
            }
        } else if (idx == 4) {
            popupTitle = sender.isOn ? @"🛡️ Escudo Anti-Jailbreak Aplicado" : @"⚪ Escudo Anti-Jailbreak Desactivado";
            popupMsg = sender.isOn
                ? @"Rutas /var/jb y DYLD ocultas ante la app sin bloquear a Crane."
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

- (void)refreshPurePhoneTelemetryValuesOnly {
    uint64_t seed = randomSeedPrefs64(self.containerUUID);
    unsigned long long freeBytes = ((14200ULL + (seed % 32000ULL)) * 1024ULL * 1024ULL) + ((seed >> 12) % 1048576ULL);

    self.profile[@"batteryLevel"] = @(0.26f + ((seed % 66) / 100.0f));
    self.profile[@"audioVolume"] = @(0.15f + (((seed >> 6) % 75) / 100.0f));
    self.profile[@"brightness"] = @(0.22f + (((seed >> 4) % 68) / 100.0f));
    self.profile[@"freeBytes"] = @(freeBytes);
    self.profile[@"pasteboardCount"] = @(4 + (seed % 95));
}

- (void)refreshPurePhoneTelemetryWithPopup {
    triggerHaptic();
    [self refreshPurePhoneTelemetryValuesOnly];
    [self saveCurrentProfile];
    [self.tableView reloadData];

    double freeGB = [self.profile[@"freeBytes"] unsignedLongLongValue] / (1024.0*1024.0*1024.0);
    int batPct = (int)([self.profile[@"batteryLevel"] floatValue] * 100.0f);
    int volPct = (int)([self.profile[@"audioVolume"] floatValue] * 100.0f);
    int briPct = (int)([self.profile[@"brightness"] floatValue] * 100.0f);

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔋 Datos Puros del Teléfono Renovados"
                                                                message:[NSString stringWithFormat:@"Sensores actualizados en \"%@\":\n\n• Batería Simulada: %d%%\n• Volumen de Audio: %d%%\n• Brillo de Pantalla: %d%%\n• Espacio Libre: %.2f GB",
                                                                         self.profile[@"containerName"], batPct, volPct, briPct, freeGB]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Perfecto" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    triggerHaptic();

    if (indexPath.section == 0) {
        if (indexPath.row == 1) [self syncWithLiveIPAndAuditVPS:NO];
        else if (indexPath.row == 2) [self syncWithLiveIPAndAuditVPS:YES];
        return;
    }

    if (indexPath.section == 2) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (cell.detailTextLabel.text.length > 0) {
            [UIPasteboard generalPasteboard].string = cell.detailTextLabel.text;
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"📋 Copiado al Portapapeles"
                                                                        message:cell.detailTextLabel.text
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        }
        return;
    }

    if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            [self refreshPurePhoneTelemetryWithPopup];
        } else {
            BOOL curOn = [self.profile[@"enabled"] boolValue];
            self.profile = [self.parentRoot ensureProfileForBundle:self.bundleID
                                                              uuid:self.containerUUID
                                                           craneID:self.profile[@"craneIdentifier"]
                                                       defaultName:self.profile[@"containerName"]
                                                              path:self.profile[@"path"]
                                                allowEnableDefault:curOn
                                                       forceRotate:YES];
            killAppProcess([self.bundleID isEqualToString:@"com.burbn.instagram"] ? @"Instagram" : @"Reddit");
            [self.tableView reloadData];
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔄 Huella Regenerada"
                                                                        message:[NSString stringWithFormat:@"Nuevos datos asignados exclusivamente a \"%@\":\n\n• BootUUID: %@\n• LAN: %@",
                                                                                 self.profile[@"containerName"], self.profile[@"bootSessionUUID"], self.profile[@"localIP"]]
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        }
    }
}

- (void)syncWithLiveIPAndAuditVPS:(BOOL)sendToVPS {
    NSArray *endpoints = @[
        @"https://ipwho.is/",
        @"https://ipapi.co/json/",
        @"https://ipinfo.io/json",
        @"http://ip-api.com/json/?fields=status,country,countryCode,regionName,city,timezone,isp,mobile,query"
    ];

    fetchLiveIPFromEndpoints(endpoints, 0, ^(NSDictionary *parsed, NSError *error) {
        if (!parsed || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Error de Conexión"
                                                                            message:@"Ninguno de los 4 servidores de IP respondió a través del proxy actual. Verifica que el proxy en Shadowrocket tenga salida a internet."
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
            return;
        }

        NSString *ip = parsed[@"ip"];
        NSString *ispRaw = parsed[@"isp"];
        NSString *cc = parsed[@"cc"];
        NSString *city = parsed[@"city"];
        NSString *region = parsed[@"region"];
        NSString *tz = parsed[@"tz"];
        BOOL isMobileISP = [parsed[@"mobile"] boolValue];

        classifyIPAndApplyToProfile(self.profile, ip, ispRaw, cc, city, region, tz, isMobileISP);
        [self saveCurrentProfile];

        if (!sendToVPS) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                BOOL isCell = [self.profile[@"CarrierMode"] isEqualToString:@"CELLULAR"];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"✅ IP Sincronizada con Shadowrocket"
                                                                            message:[NSString stringWithFormat:@"• Contenedor Exclusivo: %@\n• IP Asignada: %@\n• Antena/ISP: %@\n• Modo Automático: %@\n• Ubicación: %@, %@ (%@)\n• Zona Horaria: %@",
                                                                                     self.profile[@"containerName"], ip, ispRaw, isCell ? @"📱 Datos Móviles 4G LTE" : @"🛜 Wi-Fi Residencial", city, region, [cc uppercaseString], tz]
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

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 8.0;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

        [[session dataTaskWithURL:[NSURL URLWithString:vpsUrlStr] completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
            NSDictionary *vpsJson = vData ? [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil] : nil;
            NSString *msj = ([vpsJson isKindOfClass:[NSDictionary class]] && vpsJson[@"mensaje_iphone"])
                ? vpsJson[@"mensaje_iphone"]
                : [NSString stringWithFormat:@"IP: %@ (%@)\nSincronizado exclusivamente en este contenedor.", ip, ispRaw];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Auditoría Proxy Center" message:msj preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
        }] resume];
    });
}

@end
