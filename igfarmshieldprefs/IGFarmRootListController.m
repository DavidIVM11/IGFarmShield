#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <sys/types.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <string.h>
#import <time.h>
#import <spawn.h>

extern char **environ;

#define STATE_PLIST @"/var/jb/var/mobile/Library/Preferences/com.ivm.igfarmshield.state.plist"
#define MIRROR_STATE_DIR @"/var/jb/Library/Application Support/IGFarmShield"
#define MIRROR_STATE_PLIST @"/var/jb/Library/Application Support/IGFarmShield/state_mirror.plist"
#define CRANE_PREFS_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_PREFS_VAR @"/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define CRANE_MAIN_JB @"/var/jb/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define CRANE_MAIN_VAR @"/var/mobile/Library/Preferences/com.opa334.crane.plist"
#define VPS_AUDIT_URL @"http://162.35.105.151:5001/iphone_audit"
#define CURRENT_SCHEMA_VERSION 38

static NSArray<NSString *> *residualSubdirectoriesToTrack(void) {
    return @[
        @"tmp",
        @"Library/Caches",
        @"Library/SplashBoard/Snapshots",
        @"SystemData/com.apple.SafariViewService"
    ];
}

@class IGFarmRootListController;

// Dibuja el logo Ghost moderno en código nativo para el banner y los iconos del tweak
static UIImage *renderGhostLogoIcon(CGSize size, UIColor *bgColor) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        CGFloat w = size.width;
        CGFloat h = size.height;

        UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, w, h) cornerRadius:w * 0.22];
        [bgColor setFill];
        [bg fill];

        UIBezierPath *ghost = [UIBezierPath bezierPath];
        [ghost moveToPoint:CGPointMake(w * 0.24, h * 0.78)];
        [ghost addLineToPoint:CGPointMake(w * 0.24, h * 0.44)];
        [ghost addArcWithCenter:CGPointMake(w * 0.50, h * 0.44)
                         radius:w * 0.26
                     startAngle:M_PI
                       endAngle:0
                      clockwise:YES];
        [ghost addLineToPoint:CGPointMake(w * 0.76, h * 0.78)];
        [ghost addLineToPoint:CGPointMake(w * 0.67, h * 0.69)];
        [ghost addLineToPoint:CGPointMake(w * 0.58, h * 0.78)];
        [ghost addLineToPoint:CGPointMake(w * 0.50, h * 0.69)];
        [ghost addLineToPoint:CGPointMake(w * 0.42, h * 0.78)];
        [ghost addLineToPoint:CGPointMake(w * 0.33, h * 0.69)];
        [ghost closePath];

        [[UIColor whiteColor] setFill];
        [ghost fill];

        [bgColor setFill];
        UIBezierPath *leftEye = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(w * 0.35, h * 0.38, w * 0.10, h * 0.13)];
        UIBezierPath *rightEye = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(w * 0.55, h * 0.38, w * 0.10, h * 0.13)];
        [leftEye fill];
        [rightEye fill];
    }];
}

static UIImage *settingsBadgeIcon(NSString *symbolName, UIColor *bgColor) {
    static NSMutableDictionary *iconCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ iconCache = [NSMutableDictionary dictionary]; });

    NSString *cacheKey = [NSString stringWithFormat:@"%@_%@", symbolName, bgColor.description];
    if (iconCache[cacheKey]) return iconCache[cacheKey];

    if ([symbolName isEqualToString:@"ghost.custom"]) {
        UIImage *ghostImg = renderGhostLogoIcon(CGSizeMake(29, 29), bgColor);
        if (ghostImg) iconCache[cacheKey] = ghostImg;
        return ghostImg;
    }

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

static void triggerHaptic(void) {
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

static NSString *generateCellularCGNATAddress(NSString *salt) {
    uint64_t cSeed = randomSeedPrefs64(salt ?: @"cgnat");
    return [NSString stringWithFormat:@"100.%d.%d.%d",
            64 + (int)(cSeed % 60),
            1 + (int)((cSeed >> 8) % 250),
            2 + (int)((cSeed >> 16) % 250)];
}

static void assignSpoofedBootTimeToProfile(NSMutableDictionary *prof, BOOL recentReboot) {
    if (!prof) return;
    NSString *bootUUID = prof[@"bootSessionUUID"] ?: [[NSUUID UUID] UUIDString];
    prof[@"bootSessionUUID"] = bootUUID;

    uint64_t bSeed = randomSeedPrefs64(bootUUID);
    time_t nowEpoch = time(NULL);
    long long offsetSec = recentReboot
        ? (1800LL + (long long)(bSeed % 9000ULL))
        : (21600LL + (long long)(bSeed % 669600ULL));

    long long bootSec = (long long)nowEpoch - offsetSec;
    int bootUsec = (int)((bSeed >> 12) % 999999ULL);

    prof[@"spoofedBootEpoch"] = @(bootSec);
    prof[@"spoofedBootUsec"] = @(bootUsec);
    prof[@"lastBootUUIDForTime"] = bootUUID;
}

static NSString *formatBootUptimeSummary(NSDictionary *prof) {
    if (!prof) return @"N/A";
    long long bootSec = [prof[@"spoofedBootEpoch"] longLongValue];
    time_t nowEpoch = time(NULL);
    if (bootSec <= 0 || bootSec >= nowEpoch) {
        return @"Sincronizando al abrir la cuenta";
    }
    long long diff = (long long)nowEpoch - bootSec;
    long long days = diff / 86400LL;
    long long hours = (diff % 86400LL) / 3600LL;
    long long mins = (diff % 3600LL) / 60LL;

    NSDate *bootDate = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)bootSec];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *dateStr = [fmt stringFromDate:bootDate];

    if (days > 0) {
        return [NSString stringWithFormat:@"%lldd %lldh %lldm (%@)", days, hours, mins, dateStr];
    }
    return [NSString stringWithFormat:@"%lldh %lldm (%@)", hours, mins, dateStr];
}

static void killAppProcess(NSString *procName) {
    pid_t pid;
    const char *args[] = {"/var/jb/usr/bin/killall", "-9", [procName UTF8String], NULL};
    posix_spawn(&pid, args[0], NULL, NULL, (char *const *)args, environ);
}

static BOOL isTunnelInterfacePrefsName(NSString *ifName) {
    if (!ifName) return NO;
    NSString *low = [ifName lowercaseString];
    return ([low hasPrefix:@"utun"] ||
            [low hasPrefix:@"ppp"] ||
            [low hasPrefix:@"ipsec"] ||
            [low hasPrefix:@"tun"] ||
            [low hasPrefix:@"tap"] ||
            [low hasPrefix:@"wg"]);
}

static void writeContainerLocalPlistSafely(NSDictionary *prof) {
    if (!prof) return;
    NSString *cPath = prof[@"path"];
    if (![cPath isKindOfClass:[NSString class]] || cPath.length == 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:cPath]) return;

    NSString *libDir = [cPath stringByAppendingPathComponent:@"Library"];
    if (![fm fileExistsAtPath:libDir]) {
        [fm createDirectoryAtPath:libDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *localPlist = [libDir stringByAppendingPathComponent:@".igshield_container.plist"];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:localPlist];
    if ([existing isKindOfClass:[NSDictionary class]] && [existing isEqualToDictionary:prof]) {
        return;
    }
    [prof writeToFile:localPlist atomically:YES];
    chmod([localPlist fileSystemRepresentation], 0644);
}

static void parseCraneAppSubtree(id node, NSMutableDictionary *outContainers) {
    if (!node || !outContainers) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;

        for (NSString *ak in @[@"activeContainer", @"selectedContainer", @"currentContainer", @"activeContainerIdentifier", @"active", @"defaultContainer", @"selected"]) {
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
            outContainers[[cID lowercaseString]] = @{@"id": cID, @"name": cName};
        } else if (!cID && cName) {
            outContainers[[cName lowercaseString]] = @{@"id": cName, @"name": cName};
        }

        for (id k in dict) {
            NSString *kStr = [k description];
            id val = dict[k];
            if ([val isKindOfClass:[NSDictionary class]]) {
                NSDictionary *sub = (NSDictionary *)val;
                NSString *subName = nil;
                for (NSString *nk in @[@"name", @"displayName", @"label", @"title", @"containerName"]) {
                    if ([sub[nk] isKindOfClass:[NSString class]] && [sub[nk] length] > 0) {
                        subName = sub[nk];
                        break;
                    }
                }
                if (subName) {
                    NSString *subID = kStr;
                    for (NSString *ik in @[@"identifier", @"id", @"UUID", @"uuid", @"containerIdentifier", @"craneIdentifier"]) {
                        if ([sub[ik] isKindOfClass:[NSString class]] && [sub[ik] length] > 0) {
                            subID = sub[ik];
                            break;
                        }
                    }
                    outContainers[[subID lowercaseString]] = @{@"id": subID, @"name": subName};
                } else {
                    parseCraneAppSubtree(val, outContainers);
                }
            } else if ([val isKindOfClass:[NSArray class]]) {
                parseCraneAppSubtree(val, outContainers);
            } else if ([val isKindOfClass:[NSString class]]) {
                NSString *vStr = (NSString *)val;
                NSString *kLow = [kStr lowercaseString];
                BOOL isMetaKey = ([kLow containsString:@"active"] ||
                                  [kLow containsString:@"selected"] ||
                                  [kLow containsString:@"default"] ||
                                  [kLow containsString:@"bundle"] ||
                                  [kLow containsString:@"version"] ||
                                  [kLow containsString:@"identifier"] ||
                                  [kLow containsString:@"path"]);
                if (!isMetaKey && vStr.length > 0 && vStr.length < 50 && ![vStr containsString:@"/"] && ![vStr hasPrefix:@"com."]) {
                    outContainers[kLow] = @{@"id": kStr, @"name": vStr};
                }
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) {
            if ([item isKindOfClass:[NSString class]]) {
                NSString *s = (NSString *)item;
                if (s.length > 0 && s.length < 50 && ![s containsString:@"/"]) {
                    outContainers[[s lowercaseString]] = @{@"id": s, @"name": s};
                }
            } else {
                parseCraneAppSubtree(item, outContainers);
            }
        }
    }
}

static void extractCraneConfigForBundle(id node, NSString *bundleID, NSMutableDictionary *outContainers) {
    if (!node || !bundleID || !outContainers) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        for (NSString *bk in @[@"bundleIdentifier", @"appIdentifier", @"bundleID", @"MCMMetadataIdentifier"]) {
            if ([dict[bk] isKindOfClass:[NSString class]] && [dict[bk] caseInsensitiveCompare:bundleID] == NSOrderedSame) {
                parseCraneAppSubtree(dict, outContainers);
                return;
            }
        }
        for (id k in dict) {
            NSString *kStr = [k description];
            id val = dict[k];
            if ([kStr rangeOfString:bundleID options:NSCaseInsensitiveSearch].location != NSNotFound) {
                if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                    outContainers[@"__ACTIVE_ID__"] = val;
                } else {
                    parseCraneAppSubtree(val, outContainers);
                }
            } else if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                extractCraneConfigForBundle(val, bundleID, outContainers);
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) {
            extractCraneConfigForBundle(item, bundleID, outContainers);
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

static void accumulateDirectoryCacheUsage(NSString *dirPath, unsigned long long *outBytes, NSUInteger *outFiles) {
    if (!dirPath || dirPath.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dirPath isDirectory:&isDir] || !isDir) return;

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:dirPath];
    NSString *relPath = nil;
    while ((relPath = [enumerator nextObject])) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:relPath];
        struct stat st;
        if (lstat([fullPath fileSystemRepresentation], &st) == 0) {
            if (S_ISREG(st.st_mode)) {
                if (outBytes) *outBytes += (unsigned long long)st.st_size;
                if (outFiles) (*outFiles)++;
            }
        }
    }
}

static void purgeDirectoryCacheContents(NSString *dirPath, unsigned long long *freedBytes, NSUInteger *freedFiles) {
    if (!dirPath || dirPath.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dirPath isDirectory:&isDir] || !isDir) return;

    accumulateDirectoryCacheUsage(dirPath, freedBytes, freedFiles);
    NSArray *topItems = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    for (NSString *item in topItems) {
        NSString *full = [dirPath stringByAppendingPathComponent:item];
        [fm removeItemAtPath:full error:nil];
    }
}

static NSArray<NSString *> *collectAllPhysicalContainerPaths(NSArray *igList, NSArray *rdList, NSArray *hiddenIDs) {
    NSMutableSet<NSString *> *uniquePaths = [NSMutableSet set];
    NSMutableSet<NSString *> *hiddenSet = [NSMutableSet set];
    for (NSString *h in hiddenIDs ?: @[]) {
        if ([h isKindOfClass:[NSString class]]) [hiddenSet addObject:[h lowercaseString]];
    }

    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSArray *list in @[igList ?: @[], rdList ?: @[]]) {
        for (NSDictionary *prof in list) {
            NSString *cPath = prof[@"path"];
            if ([cPath isKindOfClass:[NSString class]] && cPath.length > 0 && [fm fileExistsAtPath:cPath]) {
                [uniquePaths addObject:cPath];
            }
        }
    }

    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:appsDir error:nil];
    for (NSString *folderUUID in uuids) {
        if ([hiddenSet containsObject:[folderUUID lowercaseString]]) continue;
        NSString *fullPath = [appsDir stringByAppendingPathComponent:folderUUID];
        NSString *metaPath = [fullPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        if (![meta isKindOfClass:[NSDictionary class]]) continue;
        NSString *mcmID = meta[@"MCMMetadataIdentifier"] ?: @"";
        if ([mcmID caseInsensitiveCompare:@"com.burbn.instagram"] == NSOrderedSame ||
            [mcmID caseInsensitiveCompare:@"com.reddit.Reddit"] == NSOrderedSame) {
            [uniquePaths addObject:fullPath];
        }
    }

    return [uniquePaths allObjects];
}

static void inspectPasteboardUsage(NSUInteger *outItemCount, unsigned long long *outBytes) {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSArray *items = pb.items;
    NSUInteger count = items.count;
    unsigned long long bytes = 0;

    for (NSDictionary<NSString *, id> *dict in items) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        for (NSString *typeKey in dict) {
            id val = dict[typeKey];
            if ([val isKindOfClass:[NSData class]]) {
                bytes += [(NSData *)val length];
            } else if ([val isKindOfClass:[NSString class]]) {
                bytes += [(NSString *)val lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            } else if ([val isKindOfClass:[NSURL class]]) {
                bytes += [[(NSURL *)val absoluteString] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            } else if ([val isKindOfClass:[UIImage class]]) {
                UIImage *img = (UIImage *)val;
                if (img.CGImage) {
                    bytes += (unsigned long long)(CGImageGetHeight(img.CGImage) * CGImageGetBytesPerRow(img.CGImage));
                } else {
                    NSData *imgData = UIImagePNGRepresentation(img);
                    bytes += imgData.length;
                }
            }
        }
    }

    if (bytes == 0 && (pb.hasStrings || pb.hasURLs || pb.hasImages)) {
        if (pb.string.length > 0) {
            if (count == 0) count = 1;
            bytes += [pb.string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        }
        if (pb.image && pb.image.CGImage) {
            if (count == 0) count = 1;
            bytes += (unsigned long long)(CGImageGetHeight(pb.image.CGImage) * CGImageGetBytesPerRow(pb.image.CGImage));
        }
    }

    if (outItemCount) *outItemCount = count;
    if (outBytes) *outBytes = bytes;
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
                           [ispUp containsString:@"TELCEL"] ||
                           [ispUp containsString:@"ROGERS"] ||
                           [ispUp containsString:@"BELL"] ||
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
    cfg.timeoutIntervalForRequest = 12.0;
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
        } else if (json[@"ipAddress"] && json[@"countryCode"]) {
            ip = json[@"ipAddress"];
            isp = json[@"asnOrganization"] ?: @"ISP";
            cc = json[@"countryCode"];
            city = json[@"cityName"];
            region = json[@"regionName"];
            NSArray *tzArr = [json[@"timeZones"] isKindOfClass:[NSArray class]] ? json[@"timeZones"] : nil;
            tz = (tzArr && tzArr.count > 0) ? tzArr.firstObject : @"America/New_York";
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

@interface IGFarmRootListController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, weak) id rootController;
@property (nonatomic, weak) id parentController;
@property (nonatomic, strong) id specifier;
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
@property (nonatomic, assign) BOOL stealthCurrentlyActive;
@property (nonatomic, strong) NSString *stealthSummary;
@property (nonatomic, strong) NSString *stealthDetailReport;
@property (nonatomic, strong) NSString *residualSummary;
- (void)saveState;
- (void)syncAllContainerLocalPlists;
- (UIView *)buildHeaderBannerView;
- (void)auditStealthEngineStatus;
- (void)scanAndSyncAllContainers;
- (void)calculateResidualTraces;
- (void)cleanResidualTracesAndKillApps:(BOOL)showPopup;
- (void)toggleRootSwitch:(UISwitch *)sender;
- (NSString *)enforceExclusiveModeWhenToggledOn;
- (void)deduplicateActiveIfMultiple;
- (NSMutableDictionary *)profileForUUID:(NSString *)uuid;
- (NSMutableDictionary *)ensureProfileForBundle:(NSString *)bundleID uuid:(NSString *)uuid craneID:(NSString *)craneID defaultName:(NSString *)dName path:(NSString *)path allowEnableDefault:(BOOL)allowEnable saveNow:(BOOL)saveNow;
- (void)saveProfile:(NSMutableDictionary *)profile forUUID:(NSString *)uuid saveNow:(BOOL)saveNow;
- (void)setContainer:(NSString *)targetUUID enabled:(BOOL)enabled inBundle:(NSString *)bundleID;
- (void)purgeGhostContainerFromTweak:(NSDictionary *)prof;
@end

@interface IGFarmAppContainersController : UIViewController <UITableViewDelegate, UITableViewDataSource>
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

@interface IGFarmContainerDetailController : UIViewController <UITableViewDelegate, UITableViewDataSource>
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
- (void)rotateBootUUIDWithPopup;
- (void)syncWithLiveIPAndAuditVPS:(BOOL)sendToVPS;
@end

@implementation IGFarmRootListController

- (instancetype)initForContentSize:(CGSize)contentSize { return [self init]; }
- (void)viewWillBecomeVisible:(void *)source {}
- (void)setRootController:(id)rootController { _rootController = rootController; }
- (void)setParentController:(id)parentController { _parentController = parentController; }
- (void)setSpecifier:(id)specifier { _specifier = specifier; }
- (void)handleURL:(NSDictionary *)dictionary {}
- (BOOL)canBeShownFromSuspendedState { return YES; }
- (void)willResignActive {}
- (void)willBecomeActive {}
- (void)suspend {}
- (void)didLock {}
- (void)willUnlock {}
- (void)didUnlock {}
- (void)didWake {}
- (void)showController:(id)controller {}
- (void)showController:(id)controller animate:(BOOL)animate {}
- (void)statusBarWillAnimateByHeight:(double)height {}
- (void)setPreferenceValue:(id)value specifier:(id)specifier {}
- (id)readPreferenceValue:(id)specifier { return nil; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"IGFarmShield";

    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:STATE_PLIST];
    if (!loaded) {
        loaded = [NSDictionary dictionaryWithContentsOfFile:MIRROR_STATE_PLIST];
    }
    self.state = loaded ? [loaded mutableCopy] : [NSMutableDictionary dictionary];

    if (!self.state[@"schemaVersion"]) {
        self.state[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
        self.state[@"masterEnabled"] = @NO;
        self.state[@"exclusiveMode"] = @NO;
        self.state[@"enableIG"] = @NO;
        self.state[@"enableReddit"] = @NO;
    }

    if (!self.state[@"masterEnabled"]) self.state[@"masterEnabled"] = @NO;
    if (!self.state[@"exclusiveMode"]) self.state[@"exclusiveMode"] = @NO;
    if (!self.state[@"enableIG"]) self.state[@"enableIG"] = @NO;
    if (!self.state[@"enableReddit"]) self.state[@"enableReddit"] = @NO;
    if (![self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]) {
        self.state[@"containersByUUID"] = [NSMutableDictionary dictionary];
    }
    if (![self.state[@"hiddenContainerIDs"] isKindOfClass:[NSArray class]]) {
        self.state[@"hiddenContainerIDs"] = @[];
    }

    self.igContainersList = [NSMutableArray array];
    self.redditContainersList = [NSMutableArray array];
    [self saveState];

    self.residualSummary = @"Calculando caché temporal y portapapeles...";

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
    if (!loaded) {
        loaded = [NSDictionary dictionaryWithContentsOfFile:MIRROR_STATE_PLIST];
    }
    if (loaded) self.state = [loaded mutableCopy];
    [self calculateResidualTraces];
    [self scanAndSyncAllContainers];
    [self auditStealthEngineStatus];
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

    BOOL masterOn = [self.state[@"masterEnabled"] boolValue];
    BOOL ksAlert = (masterOn && self.stealthCurrentlyActive && !self.vpnActive);

    UIColor *logoColor = ksAlert
        ? [UIColor systemRedColor]
        : ((masterOn && self.stealthCurrentlyActive)
            ? [UIColor colorWithRed:0.12 green:0.16 blue:0.36 alpha:1.0]
            : [UIColor systemGrayColor]);

    UIImageView *ghostView = [[UIImageView alloc] initWithFrame:CGRectMake(16, 18, 50, 50)];
    ghostView.image = renderGhostLogoIcon(CGSizeMake(50, 50), logoColor);
    ghostView.layer.cornerRadius = 12.0;
    ghostView.clipsToBounds = YES;
    [card addSubview:ghostView];

    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(78, 16, card.bounds.size.width - 90, 22)];
    titleLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    titleLbl.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    titleLbl.text = @"IGFarmShield";
    [card addSubview:titleLbl];

    UILabel *subLbl = [[UILabel alloc] initWithFrame:CGRectMake(78, 38, card.bounds.size.width - 90, 16)];
    subLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    subLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    subLbl.textColor = [UIColor secondaryLabelColor];
    subLbl.text = @"Modo Invisible • Aislamiento de Cuentas y Red";
    [card addSubview:subLbl];

    UILabel *pill = [[UILabel alloc] initWithFrame:CGRectMake(78, 57, 260, 18)];
    pill.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    if (ksAlert) {
        pill.textColor = [UIColor systemRedColor];
        pill.text = @"⛔ SIN TÚNEL (ENCIENDE SHADOWROCKET)";
    } else if (masterOn && self.stealthCurrentlyActive) {
        pill.textColor = [UIColor systemGreenColor];
        pill.text = [NSString stringWithFormat:@"● PROTECCIÓN ACTIVA • TÚNEL: %@", [self.vpnInterfaceName uppercaseString]];
    } else {
        pill.textColor = [UIColor secondaryLabelColor];
        pill.text = @"○ PROTECCIÓN EN PAUSA";
    }
    [card addSubview:pill];

    [header addSubview:card];
    return header;
}

- (void)saveState {
    self.state[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
    [self.state writeToFile:STATE_PLIST atomically:YES];
    chmod([STATE_PLIST fileSystemRepresentation], 0644);

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:MIRROR_STATE_DIR]) {
        [fm createDirectoryAtPath:MIRROR_STATE_DIR withIntermediateDirectories:YES attributes:nil error:nil];
        chmod([MIRROR_STATE_DIR fileSystemRepresentation], 0755);
    }
    [self.state writeToFile:MIRROR_STATE_PLIST atomically:YES];
    chmod([MIRROR_STATE_PLIST fileSystemRepresentation], 0644);
}

- (void)syncAllContainerLocalPlists {
    BOOL masterOn = [self.state[@"masterEnabled"] boolValue];
    BOOL igOn = [self.state[@"enableIG"] boolValue];
    BOOL rdOn = [self.state[@"enableReddit"] boolValue];

    NSMutableDictionary *byUUID = [self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containersByUUID"] mutableCopy]
        : [NSMutableDictionary dictionary];

    NSArray *groups = @[
        @[@(igOn), self.igContainersList ?: @[]],
        @[@(rdOn), self.redditContainersList ?: @[]]
    ];

    for (NSArray *grp in groups) {
        BOOL appOn = [grp[0] boolValue];
        NSMutableArray *list = grp[1];
        if (![list isKindOfClass:[NSMutableArray class]]) continue;
        for (NSUInteger i = 0; i < list.count; i++) {
            NSMutableDictionary *prof = [list[i] isKindOfClass:[NSMutableDictionary class]]
                ? list[i]
                : [list[i] mutableCopy];
            if (!prof) continue;

            NSString *u = prof[@"containerUUID"];
            if (u.length > 0 && [byUUID[u] isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *merged = [byUUID[u] mutableCopy];
                for (NSString *k in prof) {
                    merged[k] = prof[k];
                }
                prof = merged;
            }

            BOOL contOn = [prof[@"enabled"] boolValue];
            prof[@"masterEnabled"] = @(masterOn);
            prof[@"appEnabled"] = @(appOn);
            prof[@"effectiveShieldActive"] = @(masterOn && appOn && contOn);
            prof[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
            list[i] = prof;
            if (u.length > 0) {
                byUUID[u] = prof;
            }
            writeContainerLocalPlistSafely(prof);
        }
    }

    self.state[@"containersByUUID"] = byUUID;
    [self saveState];
}

- (void)purgeGhostContainerFromTweak:(NSDictionary *)prof {
    if (!prof) return;
    NSString *uuid = prof[@"containerUUID"] ?: @"";
    NSString *craneID = prof[@"craneIdentifier"] ?: @"";
    NSString *cName = prof[@"containerName"] ?: @"";
    NSString *cPath = prof[@"path"] ?: @"";
    NSString *bundleID = prof[@"bundleID"] ?: @"";

    killAppProcess([bundleID isEqualToString:@"com.burbn.instagram"] ? @"Instagram" : @"Reddit");

    NSFileManager *fm = [NSFileManager defaultManager];
    if (cPath.length > 0 && [fm fileExistsAtPath:cPath]) {
        NSString *localPlist = [cPath stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        [fm removeItemAtPath:localPlist error:nil];
        for (NSString *sub in residualSubdirectoriesToTrack()) {
            purgeDirectoryCacheContents([cPath stringByAppendingPathComponent:sub], NULL, NULL);
        }
    }

    NSMutableArray *hidden = [self.state[@"hiddenContainerIDs"] isKindOfClass:[NSArray class]]
        ? [self.state[@"hiddenContainerIDs"] mutableCopy]
        : [NSMutableArray array];
    if (uuid.length > 0 && ![hidden containsObject:[uuid lowercaseString]]) [hidden addObject:[uuid lowercaseString]];
    if (craneID.length > 0 && ![hidden containsObject:[craneID lowercaseString]]) [hidden addObject:[craneID lowercaseString]];
    if (cName.length > 0 && [cName caseInsensitiveCompare:@"Default"] != NSOrderedSame && ![hidden containsObject:[cName lowercaseString]]) {
        [hidden addObject:[cName lowercaseString]];
    }
    self.state[@"hiddenContainerIDs"] = hidden;

    NSMutableDictionary *byUUID = [self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containersByUUID"] mutableCopy]
        : [NSMutableDictionary dictionary];
    if (uuid.length > 0) [byUUID removeObjectForKey:uuid];
    if (craneID.length > 0) [byUUID removeObjectForKey:craneID];
    self.state[@"containersByUUID"] = byUUID;
    [self saveState];
}

- (void)auditStealthEngineStatus {
    BOOL masterOn = [self.state[@"masterEnabled"] boolValue];
    BOOL igOn = [self.state[@"enableIG"] boolValue];
    BOOL rdOn = [self.state[@"enableReddit"] boolValue];

    NSUInteger activeStealthCount = 0;
    if (masterOn && igOn) {
        for (NSDictionary *p in self.igContainersList) {
            BOOL contEnabled = [p[@"enabled"] boolValue];
            BOOL secEnabled = (p[@"spoofSecurity"] == nil) ? YES : [p[@"spoofSecurity"] boolValue];
            if (contEnabled && secEnabled) activeStealthCount++;
        }
    }
    if (masterOn && rdOn) {
        for (NSDictionary *p in self.redditContainersList) {
            BOOL contEnabled = [p[@"enabled"] boolValue];
            BOOL secEnabled = (p[@"spoofSecurity"] == nil) ? YES : [p[@"spoofSecurity"] boolValue];
            if (contEnabled && secEnabled) activeStealthCount++;
        }
    }

    self.stealthCurrentlyActive = (activeStealthCount > 0);

    if (self.stealthCurrentlyActive) {
        self.stealthSummary = [NSString stringWithFormat:@"🟢 Activo en %lu cuenta(s) — Ocultando Jailbreak y Crane", (unsigned long)activeStealthCount];
    } else {
        self.stealthSummary = @"⚪ En pausa — Activa una cuenta para ocultar el Jailbreak";
    }

    self.stealthDetailReport =
        @"¿Qué hace el Modo Invisible?\n\n"
        @"• Oculta el Jailbreak y Crane: Impide que Instagram y Reddit detecten archivos del sistema, librerías inyectadas o contenedores.\n\n"
        @"• Protege tu conexión (Kill-Switch): Si Shadowrocket se desconecta, bloquea el internet de la app al instante para no filtrar tu IP real.\n\n"
        @"• Aísla cada cuenta: Hace que cada contenedor tenga sus propios identificadores, hora, operadora 4G y nivel de batería.";
}

- (NSMutableDictionary *)profileForUUID:(NSString *)uuid {
    if (!uuid) return nil;
    NSDictionary *byUUID = self.state[@"containersByUUID"];
    if ([byUUID isKindOfClass:[NSDictionary class]] && [byUUID[uuid] isKindOfClass:[NSDictionary class]]) {
        return [byUUID[uuid] mutableCopy];
    }
    return nil;
}

- (void)saveProfile:(NSMutableDictionary *)profile forUUID:(NSString *)uuid saveNow:(BOOL)saveNow {
    if (!uuid || uuid.length == 0 || !profile) return;
    profile[@"containerUUID"] = uuid;
    profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);

    BOOL masterOn = [self.state[@"masterEnabled"] boolValue];
    NSString *bID = profile[@"bundleID"] ?: @"com.burbn.instagram";
    BOOL appOn = [bID isEqualToString:@"com.burbn.instagram"]
        ? [self.state[@"enableIG"] boolValue]
        : [self.state[@"enableReddit"] boolValue];
    BOOL contOn = [profile[@"enabled"] boolValue];
    profile[@"masterEnabled"] = @(masterOn);
    profile[@"appEnabled"] = @(appOn);
    profile[@"effectiveShieldActive"] = @(masterOn && appOn && contOn);

    for (NSMutableArray *list in @[self.igContainersList ?: @[], self.redditContainersList ?: @[]]) {
        if (![list isKindOfClass:[NSMutableArray class]]) continue;
        for (NSUInteger i = 0; i < list.count; i++) {
            NSDictionary *item = list[i];
            if ([item[@"containerUUID"] isEqualToString:uuid]) {
                list[i] = profile;
                break;
            }
        }
    }

    NSMutableDictionary *byUUID = [self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containersByUUID"] mutableCopy]
        : [NSMutableDictionary dictionary];
    byUUID[uuid] = profile;
    self.state[@"containersByUUID"] = byUUID;

    if (saveNow) {
        [self saveState];
    }

    NSString *p = profile[@"path"];
    if ([p isKindOfClass:[NSString class]] && p.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:p]) {
        NSString *localPlist = [p stringByAppendingPathComponent:@"Library/.igshield_container.plist"];
        if (saveNow || ![[NSFileManager defaultManager] fileExistsAtPath:localPlist]) {
            writeContainerLocalPlistSafely(profile);
        }
    }
}

- (void)deduplicateActiveIfMultiple {
    NSDictionary *activeMap = [self.state[@"activeInCrane"] isKindOfClass:[NSDictionary class]] ? self.state[@"activeInCrane"] : @{};
    for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
        BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
        NSMutableArray *list = isIG ? self.igContainersList : self.redditContainersList;
        if (![list isKindOfClass:[NSMutableArray class]] || list.count <= 1) continue;

        NSArray *snapshot = [list copy];
        NSMutableArray *enabledList = [NSMutableArray array];
        for (NSDictionary *p in snapshot) {
            if ([p[@"enabled"] boolValue]) [enabledList addObject:p];
        }
        if (enabledList.count <= 1) continue;

        NSString *preferredID = [activeMap[bID] isKindOfClass:[NSString class]] ? activeMap[bID] : nil;
        NSString *chosenUUID = nil;
        for (NSDictionary *p in enabledList) {
            if (preferredID.length > 0 &&
                (([p[@"containerUUID"] isKindOfClass:[NSString class]] && [p[@"containerUUID"] caseInsensitiveCompare:preferredID] == NSOrderedSame) ||
                 ([p[@"craneIdentifier"] isKindOfClass:[NSString class]] && [p[@"craneIdentifier"] caseInsensitiveCompare:preferredID] == NSOrderedSame) ||
                 ([p[@"containerName"] isKindOfClass:[NSString class]] && [p[@"containerName"] caseInsensitiveCompare:preferredID] == NSOrderedSame))) {
                chosenUUID = p[@"containerUUID"];
                break;
            }
        }
        if (!chosenUUID) {
            chosenUUID = enabledList.firstObject[@"containerUUID"];
        }

        for (NSDictionary *item in snapshot) {
            NSMutableDictionary *p = [item isKindOfClass:[NSMutableDictionary class]] ? (NSMutableDictionary *)item : [item mutableCopy];
            NSString *u = p[@"containerUUID"];
            if (!u) continue;
            BOOL keepOn = [u isEqualToString:chosenUUID];
            p[@"enabled"] = @(keepOn);
            [self saveProfile:p forUUID:u saveNow:NO];
        }
    }
}

- (NSString *)enforceExclusiveModeWhenToggledOn {
    NSDictionary *activeMap = [self.state[@"activeInCrane"] isKindOfClass:[NSDictionary class]] ? self.state[@"activeInCrane"] : @{};
    NSMutableArray *keptNames = [NSMutableArray array];

    for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
        BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
        NSMutableArray *list = isIG ? self.igContainersList : self.redditContainersList;
        if (![list isKindOfClass:[NSMutableArray class]] || list.count == 0) continue;

        NSArray *snapshot = [list copy];
        NSString *preferredID = [activeMap[bID] isKindOfClass:[NSString class]] ? activeMap[bID] : nil;
        NSString *chosenUUID = nil;

        for (NSDictionary *p in snapshot) {
            if ([p[@"enabled"] boolValue] && preferredID.length > 0 &&
                (([p[@"containerUUID"] isKindOfClass:[NSString class]] && [p[@"containerUUID"] caseInsensitiveCompare:preferredID] == NSOrderedSame) ||
                 ([p[@"craneIdentifier"] isKindOfClass:[NSString class]] && [p[@"craneIdentifier"] caseInsensitiveCompare:preferredID] == NSOrderedSame) ||
                 ([p[@"containerName"] isKindOfClass:[NSString class]] && [p[@"containerName"] caseInsensitiveCompare:preferredID] == NSOrderedSame))) {
                chosenUUID = p[@"containerUUID"];
                break;
            }
        }
        if (!chosenUUID) {
            for (NSDictionary *p in snapshot) {
                if ([p[@"enabled"] boolValue]) {
                    chosenUUID = p[@"containerUUID"];
                    break;
                }
            }
        }
        if (!chosenUUID) {
            [keptNames addObject:[NSString stringWithFormat:@"%@: Ninguno (En pausa)", isIG ? @"IG" : @"Reddit"]];
            continue;
        }

        for (NSDictionary *item in snapshot) {
            NSMutableDictionary *p = [item isKindOfClass:[NSMutableDictionary class]] ? (NSMutableDictionary *)item : [item mutableCopy];
            NSString *u = p[@"containerUUID"];
            if (!u) continue;
            BOOL keepOn = [u isEqualToString:chosenUUID];
            p[@"enabled"] = @(keepOn);
            [self saveProfile:p forUUID:u saveNow:NO];
            if (keepOn) {
                [keptNames addObject:[NSString stringWithFormat:@"%@: %@", isIG ? @"IG" : @"Reddit", p[@"containerName"] ?: @"Default"]];
            }
        }
    }

    [self syncAllContainerLocalPlists];
    return (keptNames.count > 0) ? [keptNames componentsJoinedByString:@"\n• "] : @"Ninguno";
}

- (void)setContainer:(NSString *)targetUUID enabled:(BOOL)enabled inBundle:(NSString *)bundleID {
    if (!targetUUID || !bundleID) return;
    BOOL exclusive = [self.state[@"exclusiveMode"] boolValue];
    NSMutableArray *list = [bundleID isEqualToString:@"com.burbn.instagram"] ? self.igContainersList : self.redditContainersList;
    NSArray *snapshot = [list copy];

    for (NSDictionary *item in snapshot) {
        NSMutableDictionary *p = [item isKindOfClass:[NSMutableDictionary class]] ? (NSMutableDictionary *)item : [item mutableCopy];
        NSString *u = p[@"containerUUID"];
        if (!u) continue;
        if ([u isEqualToString:targetUUID]) {
            p[@"enabled"] = @(enabled);
            [self saveProfile:p forUUID:u saveNow:NO];
        } else if (enabled && exclusive && [p[@"enabled"] boolValue]) {
            p[@"enabled"] = @NO;
            [self saveProfile:p forUUID:u saveNow:NO];
        }
    }

    [self syncAllContainerLocalPlists];
    [self auditStealthEngineStatus];
    killAppProcess([bundleID isEqualToString:@"com.burbn.instagram"] ? @"Instagram" : @"Reddit");
}

- (NSMutableDictionary *)ensureProfileForBundle:(NSString *)bundleID uuid:(NSString *)uuid craneID:(NSString *)craneID defaultName:(NSString *)dName path:(NSString *)path allowEnableDefault:(BOOL)allowEnable saveNow:(BOOL)saveNow {
    if (!bundleID) bundleID = @"com.burbn.instagram";
    if (!uuid || uuid.length == 0) uuid = craneID ?: @"Default";
    if (!craneID || craneID.length == 0) craneID = uuid;

    NSMutableDictionary *byUUID = [self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containersByUUID"] mutableCopy]
        : [NSMutableDictionary dictionary];

    NSMutableDictionary *profile = nil;
    NSString *preservedPath = (path && path.length > 0) ? path : nil;

    if ([byUUID[uuid] isKindOfClass:[NSDictionary class]] && byUUID[uuid][@"bootSessionUUID"]) {
        profile = [byUUID[uuid] mutableCopy];
        if (!preservedPath && [profile[@"path"] isKindOfClass:[NSString class]] && [profile[@"path"] length] > 0) {
            preservedPath = profile[@"path"];
        }
    }
    if (!profile) {
        for (NSString *existingKey in [byUUID allKeys]) {
            NSDictionary *cand = byUUID[existingKey];
            if (![cand isKindOfClass:[NSDictionary class]] || ![cand[@"bundleID"] isEqualToString:bundleID] || !cand[@"bootSessionUUID"]) continue;
            NSString *candCraneID = cand[@"craneIdentifier"] ?: @"";
            NSString *candIDFV = cand[@"idfv"] ?: @"";
            NSString *candName = cand[@"containerName"] ?: @"";
            NSString *candPath = cand[@"path"] ?: @"";
            if ([existingKey caseInsensitiveCompare:uuid] == NSOrderedSame ||
                (![craneID isEqualToString:@"Default"] && ([existingKey caseInsensitiveCompare:craneID] == NSOrderedSame ||
                                                           [candCraneID caseInsensitiveCompare:craneID] == NSOrderedSame ||
                                                           [candIDFV caseInsensitiveCompare:craneID] == NSOrderedSame)) ||
                (path.length > 0 && [candPath isEqualToString:path]) ||
                (dName.length > 0 && ![dName isEqualToString:@"Default"] && [candName caseInsensitiveCompare:dName] == NSOrderedSame)) {
                profile = [cand mutableCopy];
                if (!preservedPath && candPath.length > 0) preservedPath = candPath;
                if (![existingKey isEqualToString:uuid]) {
                    [byUUID removeObjectForKey:existingKey];
                    self.state[@"containersByUUID"] = byUUID;
                }
                break;
            }
        }
    }

    NSDictionary *disk = nil;
    if (preservedPath.length > 0) {
        disk = [NSDictionary dictionaryWithContentsOfFile:[preservedPath stringByAppendingPathComponent:@"Library/.igshield_container.plist"]];
        if (!profile && [disk isKindOfClass:[NSDictionary class]] && disk[@"bootSessionUUID"]) {
            profile = [disk mutableCopy];
        }
    }

    if (profile && [disk isKindOfClass:[NSDictionary class]]) {
        for (NSString *runtimeKey in @[@"cellularLocalIP", @"spoofedBootEpoch", @"spoofedBootUsec", @"lastBootUUIDForTime", @"idfv", @"craneOriginalIDFV"]) {
            if ((!profile[runtimeKey] || ([profile[runtimeKey] isKindOfClass:[NSString class]] && [profile[runtimeKey] length] == 0)) && disk[runtimeKey]) {
                profile[runtimeKey] = disk[runtimeKey];
            }
        }
    }

    NSString *cleanCraneName = (dName && dName.length > 0) ? dName : @"Default";
    BOOL hasValidCraneUUID = ([craneID containsString:@"-"] && craneID.length >= 32);
    NSString *diskCapturedIDFV = ([disk isKindOfClass:[NSDictionary class]] && [disk[@"craneOriginalIDFV"] isKindOfClass:[NSString class]] && [disk[@"craneOriginalIDFV"] length] >= 32)
        ? [disk[@"craneOriginalIDFV"] uppercaseString]
        : nil;
    NSString *profileSavedIDFV = ([profile[@"idfv"] isKindOfClass:[NSString class]] && [profile[@"idfv"] length] >= 32)
        ? [profile[@"idfv"] uppercaseString]
        : nil;
    NSString *nativeCraneIDFV = diskCapturedIDFV
        ?: (hasValidCraneUUID ? [craneID uppercaseString] : (profileSavedIDFV ?: @""));

    BOOL isNewProfile = (!profile || !profile[@"bootSessionUUID"]);

    if (isNewProfile) {
        BOOL wasEnabled = (profile && profile[@"enabled"] != nil) ? [profile[@"enabled"] boolValue] : YES;

        uint64_t seed = randomSeedPrefs64(uuid);
        NSArray *ouis = @[@"a4:83:e7", @"28:80:88", @"00:1d:7e", @"c0:56:27", @"ec:1a:59", @"f0:9f:c2", @"04:d6:aa"];
        NSArray *ssidPrefixes = @[@"HomeWiFi", @"ATT-Fiber", @"Xfinity-WiFi", @"SpectrumSetup", @"NETGEAR", @"TP-Link"];

        NSString *oui = ouis[seed % ouis.count];
        NSString *ssidPref = ssidPrefixes[(seed >> 3) % ssidPrefixes.count];
        NSString *bssid = [NSString stringWithFormat:@"%@:%02x:%02x:%02x",
                           oui, (unsigned int)((seed >> 8) & 0xFF), (unsigned int)((seed >> 16) & 0xFF), (unsigned int)((seed >> 24) & 0xFF)];
        NSString *ssid = [NSString stringWithFormat:@"%@-%02X-5G", ssidPref, (unsigned int)(seed & 0xFF)];
        NSString *localIP = [NSString stringWithFormat:@"192.168.1.%d", 12 + (int)(seed % 230)];
        NSString *newBootUUID = [[NSUUID UUID] UUIDString];
        NSString *cellIP = generateCellularCGNATAddress(newBootUUID);
        unsigned long long freeBytes = ((14200ULL + (seed % 32000ULL)) * 1024ULL * 1024ULL) + ((seed >> 12) % 1048576ULL);

        profile = [@{
            @"schemaVersion": @(CURRENT_SCHEMA_VERSION),
            @"containerUUID": uuid,
            @"craneIdentifier": craneID,
            @"containerName": cleanCraneName,
            @"bundleID": bundleID,
            @"path": preservedPath ?: @"",
            @"enabled": @(wasEnabled),
            @"masterEnabled": self.state[@"masterEnabled"] ?: @NO,
            @"appEnabled": @NO,
            @"effectiveShieldActive": @NO,
            @"spoofIDs": profile[@"spoofIDs"] ?: @YES,
            @"spoofNetwork": profile[@"spoofNetwork"] ?: @YES,
            @"spoofLocation": profile[@"spoofLocation"] ?: @YES,
            @"spoofHardware": profile[@"spoofHardware"] ?: @YES,
            @"spoofSecurity": profile[@"spoofSecurity"] ?: @YES,
            @"locationAnchored": profile[@"locationAnchored"] ?: @NO,
            @"deviceModel": @"iPhone10,4",
            @"craneOriginalIDFV": nativeCraneIDFV,
            @"idfv": nativeCraneIDFV,
            @"bootSessionUUID": newBootUUID,
            @"bssid": bssid,
            @"ssid": ssid,
            @"localIP": localIP,
            @"cellularLocalIP": cellIP,
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
        assignSpoofedBootTimeToProfile(profile, NO);
    } else {
        [profile removeObjectForKey:@"uptimeOffset"];
        [profile removeObjectForKey:@"customRotatedIDFV"];
        if (nativeCraneIDFV.length >= 32) {
            profile[@"idfv"] = nativeCraneIDFV;
            profile[@"craneOriginalIDFV"] = nativeCraneIDFV;
        }
        profile[@"schemaVersion"] = @(CURRENT_SCHEMA_VERSION);
        profile[@"containerUUID"] = uuid;
        profile[@"craneIdentifier"] = craneID;
        profile[@"containerName"] = cleanCraneName;
        profile[@"bundleID"] = bundleID;
        if (preservedPath.length > 0) profile[@"path"] = preservedPath;
    }

    NSString *lanIP = profile[@"localIP"] ?: @"192.168.1.45";
    if (![lanIP hasPrefix:@"192.168.1."]) {
        uint64_t fixSeed = randomSeedPrefs64(uuid);
        lanIP = [NSString stringWithFormat:@"192.168.1.%d", 15 + (int)(fixSeed % 220)];
        profile[@"localIP"] = lanIP;
    }

    NSString *cellIP = profile[@"cellularLocalIP"];
    if (![cellIP isKindOfClass:[NSString class]] || ![cellIP hasPrefix:@"100."]) {
        profile[@"cellularLocalIP"] = generateCellularCGNATAddress(profile[@"bootSessionUUID"] ?: uuid);
    }

    long long savedBootSec = [profile[@"spoofedBootEpoch"] longLongValue];
    NSString *savedBootRef = profile[@"lastBootUUIDForTime"] ?: @"";
    time_t nowEpoch = time(NULL);
    if (savedBootSec <= 0 || savedBootSec >= (nowEpoch - 600) || (nowEpoch - savedBootSec) > (30 * 86400) ||
        ![savedBootRef isEqualToString:(profile[@"bootSessionUUID"] ?: @"")]) {
        assignSpoofedBootTimeToProfile(profile, NO);
    }

    [self saveProfile:profile forUUID:uuid saveNow:(saveNow || isNewProfile)];
    return profile;
}

- (void)scanAndSyncAllContainers {
    self.igContainersList = [NSMutableArray array];
    self.redditContainersList = [NSMutableArray array];
    NSMutableSet *seenIGKeys = [NSMutableSet set];
    NSMutableSet *seenRDKeys = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL exclusive = [self.state[@"exclusiveMode"] boolValue];

    NSMutableSet *hiddenSet = [NSMutableSet set];
    if ([self.state[@"hiddenContainerIDs"] isKindOfClass:[NSArray class]]) {
        for (NSString *h in self.state[@"hiddenContainerIDs"]) {
            [hiddenSet addObject:[h lowercaseString]];
        }
    }

    NSMutableArray *craneSources = [NSMutableArray array];
    for (NSString *pPath in @[CRANE_PREFS_JB, CRANE_MAIN_JB, CRANE_PREFS_VAR, CRANE_MAIN_VAR]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:pPath];
        if ([d isKindOfClass:[NSDictionary class]] && [d count] > 0) [craneSources addObject:d];
    }

    NSArray *craneDirs = @[
        @"/var/jb/var/mobile/Library/Application Support/Crane",
        @"/var/mobile/Library/Application Support/Crane",
        @"/var/jb/var/mobile/Library/Crane",
        @"/var/mobile/Library/Crane"
    ];
    for (NSString *cDir in craneDirs) {
        if (![fm fileExistsAtPath:cDir]) continue;
        NSArray *files = [fm subpathsOfDirectoryAtPath:cDir error:nil];
        for (NSString *f in files) {
            if ([f hasSuffix:@".plist"]) {
                NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[cDir stringByAppendingPathComponent:f]];
                if ([d isKindOfClass:[NSDictionary class]] && [d count] > 0) {
                    [craneSources addObject:d];
                }
            }
        }
    }

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

    NSMutableDictionary *igCraneMap = [NSMutableDictionary dictionary];
    NSMutableDictionary *rdCraneMap = [NSMutableDictionary dictionary];

    for (NSDictionary *src in craneSources) {
        extractCraneConfigForBundle(src, @"com.burbn.instagram", igCraneMap);
        extractCraneConfigForBundle(src, @"com.reddit.Reddit", rdCraneMap);
    }

    NSString *igActiveCraneID = igCraneMap[@"__ACTIVE_ID__"];
    NSString *rdActiveCraneID = rdCraneMap[@"__ACTIVE_ID__"];
    [igCraneMap removeObjectForKey:@"__ACTIVE_ID__"];
    [rdCraneMap removeObjectForKey:@"__ACTIVE_ID__"];

    BOOL igHasCraneConfigured = (igCraneMap.count > 0 || (igActiveCraneID && igActiveCraneID.length > 0));
    BOOL rdHasCraneConfigured = (rdCraneMap.count > 0 || (rdActiveCraneID && rdActiveCraneID.length > 0));

    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:appsDir error:nil];

    for (NSString *folderUUID in uuids) {
        if ([hiddenSet containsObject:[folderUUID lowercaseString]]) continue;

        NSString *fullPath = [appsDir stringByAppendingPathComponent:folderUUID];
        NSString *metaPath = [fullPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        if (![meta isKindOfClass:[NSDictionary class]]) continue;

        NSString *mcmID = meta[@"MCMMetadataIdentifier"] ?: @"";
        BOOL isIG = ([mcmID caseInsensitiveCompare:@"com.burbn.instagram"] == NSOrderedSame);
        BOOL isRD = ([mcmID caseInsensitiveCompare:@"com.reddit.Reddit"] == NSOrderedSame);
        if (!isIG && !isRD) continue;

        NSString *bundleID = isIG ? @"com.burbn.instagram" : @"com.reddit.Reddit";
        NSMutableDictionary *craneMap = isIG ? igCraneMap : rdCraneMap;
        NSMutableArray *targetList = isIG ? self.igContainersList : self.redditContainersList;
        NSMutableSet *seenKeys = isIG ? seenIGKeys : seenRDKeys;

        NSString *craneID = nil;
        NSString *detectedName = nil;
        NSString *mcmUUID = [meta[@"MCMMetadataUUID"] isKindOfClass:[NSString class]] ? meta[@"MCMMetadataUUID"] : nil;

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

        NSDictionary *localSaved = [NSDictionary dictionaryWithContentsOfFile:[fullPath stringByAppendingPathComponent:@"Library/.igshield_container.plist"]];
        NSString *savedIDFV = nil;
        if ([localSaved isKindOfClass:[NSDictionary class]]) {
            NSString *savedCID = localSaved[@"craneIdentifier"];
            if (!craneID && [savedCID isKindOfClass:[NSString class]] && savedCID.length > 0 && [savedCID caseInsensitiveCompare:@"Default"] != NSOrderedSame) {
                craneID = savedCID;
            }
            NSString *savedName = localSaved[@"containerName"];
            if (!detectedName && [savedName isKindOfClass:[NSString class]] && savedName.length > 0 && [savedName caseInsensitiveCompare:@"Default"] != NSOrderedSame) {
                detectedName = savedName;
            }
            if ([localSaved[@"idfv"] isKindOfClass:[NSString class]] && [localSaved[@"idfv"] length] >= 32) {
                savedIDFV = localSaved[@"idfv"];
            }
        }

        BOOL folderHasCraneMeta = (craneID != nil || detectedName != nil || savedIDFV != nil || ([userInfo isKindOfClass:[NSDictionary class]] && [userInfo count] > 0));
        BOOL appUsesCrane = isIG ? (igHasCraneConfigured || folderHasCraneMeta) : (rdHasCraneConfigured || folderHasCraneMeta);
        if (!appUsesCrane) continue;

        NSDictionary *cEntry = nil;
        if (craneID.length > 0) cEntry = craneMap[[craneID lowercaseString]];
        if (!cEntry && savedIDFV.length > 0) cEntry = craneMap[[savedIDFV lowercaseString]];
        if (!cEntry && mcmUUID.length > 0) cEntry = craneMap[[mcmUUID lowercaseString]];
        if (!cEntry) cEntry = craneMap[[folderUUID lowercaseString]];
        if (!cEntry && detectedName.length > 0) cEntry = craneMap[[detectedName lowercaseString]];

        if ([cEntry isKindOfClass:[NSDictionary class]]) {
            if ([cEntry[@"name"] length] > 0) detectedName = cEntry[@"name"];
            if ([cEntry[@"id"] length] > 0) craneID = cEntry[@"id"];
        }

        if (!detectedName) {
            for (NSDictionary *src in craneSources) {
                if (craneID.length > 0) detectedName = findCraneNameByID(src, craneID);
                if (detectedName) break;
                if (savedIDFV.length > 0) detectedName = findCraneNameByID(src, savedIDFV);
                if (detectedName) break;
                if (mcmUUID.length > 0) detectedName = findCraneNameByID(src, mcmUUID);
                if (detectedName) break;
                detectedName = findCraneNameByID(src, folderUUID);
                if (detectedName) break;
            }
        }

        if (!craneID || craneID.length == 0) {
            if ((!userInfo || [userInfo count] == 0) && ![seenKeys containsObject:@"default"]) {
                craneID = @"Default";
            } else if (savedIDFV.length > 0) {
                craneID = savedIDFV;
            } else if (mcmUUID.length > 0) {
                craneID = mcmUUID;
            } else {
                craneID = folderUUID;
            }
        }

        if ([hiddenSet containsObject:[craneID lowercaseString]]) continue;

        if (!detectedName || detectedName.length == 0) {
            if ([craneID caseInsensitiveCompare:@"default"] == NSOrderedSame) {
                detectedName = @"Default";
            } else {
                detectedName = craneID;
            }
        }

        if ([hiddenSet containsObject:[detectedName lowercaseString]]) continue;
        if ([seenKeys containsObject:[folderUUID lowercaseString]] ||
            [seenKeys containsObject:[craneID lowercaseString]]) {
            continue;
        }

        NSMutableDictionary *prof = [self ensureProfileForBundle:bundleID
                                                            uuid:folderUUID
                                                         craneID:craneID
                                                     defaultName:detectedName
                                                            path:fullPath
                                              allowEnableDefault:YES
                                                         saveNow:NO];
        [seenKeys addObject:[folderUUID lowercaseString]];
        [seenKeys addObject:[craneID lowercaseString]];
        if (mcmUUID.length > 0) [seenKeys addObject:[mcmUUID lowercaseString]];
        if (detectedName.length > 0) [seenKeys addObject:[detectedName lowercaseString]];
        [targetList addObject:prof];
    }

    for (NSString *bID in @[@"com.burbn.instagram", @"com.reddit.Reddit"]) {
        BOOL isIG = [bID isEqualToString:@"com.burbn.instagram"];
        BOOL appUsesCrane = isIG ? igHasCraneConfigured : rdHasCraneConfigured;
        if (!appUsesCrane) continue;

        NSMutableDictionary *craneMap = isIG ? igCraneMap : rdCraneMap;
        NSMutableArray *targetList = isIG ? self.igContainersList : self.redditContainersList;
        NSMutableSet *seenKeys = isIG ? seenIGKeys : seenRDKeys;

        for (NSString *cKey in craneMap) {
            NSDictionary *cEntry = craneMap[cKey];
            NSString *cID = [cEntry isKindOfClass:[NSDictionary class]] ? (cEntry[@"id"] ?: cKey) : cKey;
            NSString *cName = [cEntry isKindOfClass:[NSDictionary class]] ? (cEntry[@"name"] ?: cID) : [cEntry description];
            if (!cName || cName.length == 0) continue;

            if ([seenKeys containsObject:[cID lowercaseString]] ||
                [seenKeys containsObject:[cName lowercaseString]] ||
                [hiddenSet containsObject:[cID lowercaseString]] ||
                [hiddenSet containsObject:[cName lowercaseString]]) {
                continue;
            }

            NSMutableDictionary *prof = [self ensureProfileForBundle:bID
                                                                uuid:cID
                                                             craneID:cID
                                                         defaultName:cName
                                                                path:@""
                                                  allowEnableDefault:YES
                                                             saveNow:NO];
            [seenKeys addObject:[cID lowercaseString]];
            [seenKeys addObject:[cName lowercaseString]];
            [targetList addObject:prof];
        }
    }

    NSComparator sortBlock = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *na = a[@"containerName"] ?: @"";
        NSString *nb = b[@"containerName"] ?: @"";
        if ([na caseInsensitiveCompare:@"Default"] == NSOrderedSame) return NSOrderedAscending;
        if ([nb caseInsensitiveCompare:@"Default"] == NSOrderedSame) return NSOrderedDescending;
        return [na localizedCaseInsensitiveCompare:nb];
    };
    [self.igContainersList sortUsingComparator:sortBlock];
    [self.redditContainersList sortUsingComparator:sortBlock];

    NSMutableSet *activeProfileKeys = [NSMutableSet set];
    for (NSDictionary *p in self.igContainersList) { if (p[@"containerUUID"]) [activeProfileKeys addObject:p[@"containerUUID"]]; }
    for (NSDictionary *p in self.redditContainersList) { if (p[@"containerUUID"]) [activeProfileKeys addObject:p[@"containerUUID"]]; }

    NSMutableDictionary *byUUID = [self.state[@"containersByUUID"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"containersByUUID"] mutableCopy]
        : [NSMutableDictionary dictionary];
    for (NSString *savedKey in [byUUID allKeys]) {
        if (![activeProfileKeys containsObject:savedKey]) {
            [byUUID removeObjectForKey:savedKey];
        }
    }
    self.state[@"containersByUUID"] = byUUID;

    NSMutableDictionary *activeMap = [self.state[@"activeInCrane"] isKindOfClass:[NSDictionary class]]
        ? [self.state[@"activeInCrane"] mutableCopy]
        : [NSMutableDictionary dictionary];
    if (igActiveCraneID && igActiveCraneID.length > 0) activeMap[@"com.burbn.instagram"] = igActiveCraneID;
    if (rdActiveCraneID && rdActiveCraneID.length > 0) activeMap[@"com.reddit.Reddit"] = rdActiveCraneID;
    self.state[@"activeInCrane"] = activeMap;

    if (exclusive) {
        [self deduplicateActiveIfMultiple];
    }

    [self syncAllContainerLocalPlists];
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
    if (getifaddrs(&interfaces) == 0 && interfaces != NULL) {
        struct ifaddrs *temp = interfaces;
        while (temp != NULL) {
            if (temp->ifa_name && temp->ifa_addr && (temp->ifa_flags & IFF_UP)) {
                NSString *ifName = [NSString stringWithUTF8String:temp->ifa_name];
                if (temp->ifa_addr->sa_family == AF_INET) {
                    struct sockaddr_in sin;
                    memcpy(&sin, temp->ifa_addr, sizeof(sin));
                    if (sin.sin_addr.s_addr != 0) {
                        char addrBuf[INET_ADDRSTRLEN] = {0};
                        inet_ntop(AF_INET, &sin.sin_addr, addrBuf, INET_ADDRSTRLEN);
                        NSString *ipStr = [NSString stringWithUTF8String:addrBuf];
                        if ([ifName isEqualToString:@"en0"] && ipStr.length > 0) {
                            self.realLocalIP = ipStr;
                        } else if (isTunnelInterfacePrefsName(ifName)) {
                            self.vpnActive = YES;
                            self.vpnInterfaceName = ifName;
                        }
                    }
                }
            }
            temp = temp->ifa_next;
        }
        freeifaddrs(interfaces);
    }

    NSUInteger pbItems = 0;
    unsigned long long pbBytes = 0;
    inspectPasteboardUsage(&pbItems, &pbBytes);

    NSArray *hiddenIDs = [self.state[@"hiddenContainerIDs"] isKindOfClass:[NSArray class]] ? self.state[@"hiddenContainerIDs"] : @[];
    NSArray<NSString *> *pathsToScan = collectAllPhysicalContainerPaths(self.igContainersList, self.redditContainersList, hiddenIDs);

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        unsigned long long residualBytes = 0;
        NSUInteger residualFiles = 0;
        NSArray<NSString *> *trackedSubs = residualSubdirectoriesToTrack();

        for (NSString *cPath in pathsToScan) {
            for (NSString *sub in trackedSubs) {
                accumulateDirectoryCacheUsage([cPath stringByAppendingPathComponent:sub], &residualBytes, &residualFiles);
            }
        }

        double mb = (double)residualBytes / (1024.0 * 1024.0);
        double pbKB = (double)pbBytes / 1024.0;
        NSString *pbText = (pbItems > 0)
            ? [NSString stringWithFormat:@"Portapapeles: %lu ítem(s) (%.1f KB)", (unsigned long)pbItems, pbKB]
            : @"Portapapeles: Vacío (0 KB)";

        NSString *summary = [NSString stringWithFormat:@"Caché temporal en %lu cuenta(s): %lu archivos (%.2f MB)\n%@",
                             (unsigned long)pathsToScan.count, (unsigned long)residualFiles, mb, pbText];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.residualSummary = summary;
            if (strongSelf.tableView) {
                [strongSelf.tableView reloadData];
            }
        });
    });
}

- (void)cleanResidualTracesAndKillApps:(BOOL)showPopup {
    triggerHaptic();
    killAppProcess(@"Instagram");
    killAppProcess(@"Reddit");

    unsigned long long freedBytes = 0;
    NSUInteger removedCount = 0;

    NSUInteger pbItemsBefore = 0;
    unsigned long long pbBytesBefore = 0;
    inspectPasteboardUsage(&pbItemsBefore, &pbBytesBefore);

    [UIPasteboard generalPasteboard].items = @[];
    [UIPasteboard generalPasteboard].string = @"";
    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    NSArray *hiddenIDs = [self.state[@"hiddenContainerIDs"] isKindOfClass:[NSArray class]] ? self.state[@"hiddenContainerIDs"] : @[];
    NSArray<NSString *> *pathsToClean = collectAllPhysicalContainerPaths(self.igContainersList, self.redditContainersList, hiddenIDs);
    NSArray<NSString *> *trackedSubs = residualSubdirectoriesToTrack();

    for (NSString *cPath in pathsToClean) {
        for (NSString *sub in trackedSubs) {
            purgeDirectoryCacheContents([cPath stringByAppendingPathComponent:sub], &freedBytes, &removedCount);
        }
    }

    double freedMB = (double)freedBytes / (1024.0 * 1024.0);
    double pbFreedKB = (double)pbBytesBefore / 1024.0;
    [self calculateResidualTraces];
    [self.tableView reloadData];

    if (showPopup) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🧹 Limpieza Completada"
                                                                    message:[NSString stringWithFormat:@"• Instagram y Reddit cerrados.\n• %lu archivos temporales eliminados (%.2f MB liberados).\n• Portapapeles vaciado (%lu ítem(s), %.1f KB).\n• Tus sesiones iniciadas se mantuvieron intactas.",
                                                                             (unsigned long)removedCount, freedMB, (unsigned long)pbItemsBefore, pbFreedKB]
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Listo" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"CONTROL GENERAL";
    if (section == 1) return @"CUENTAS Y CONTENEDORES (CRANE)";
    if (section == 2) return @"RED Y SEGURIDAD";
    return @"MANTENIMIENTO";
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
            cell.imageView.image = settingsBadgeIcon(@"ghost.custom", masterOn ? [UIColor colorWithRed:0.12 green:0.16 blue:0.36 alpha:1.0] : [UIColor systemGrayColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            cell.textLabel.text = @"Protección General";
            cell.detailTextLabel.text = masterOn ? @"Activa el aislamiento y el Modo Invisible en tus contenedores." : @"Desactivado. Las aplicaciones usan los datos reales del teléfono.";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = masterOn;
            sw.tag = 10;
            [sw addTarget:self action:@selector(toggleRootSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            BOOL excl = [self.state[@"exclusiveMode"] boolValue];
            cell.imageView.image = settingsBadgeIcon(@"lock.fill", excl ? [UIColor systemIndigoColor] : [UIColor systemGrayColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold];
            cell.textLabel.text = @"Modo Exclusivo";
            cell.detailTextLabel.text = excl ? @"Mantiene un solo contenedor activo a la vez y pausa los demás." : @"Apagado (Permite tener todos tus contenedores protegidos a la vez).";
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
            BOOL igOn = [self.state[@"enableIG"] boolValue];
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
            cell.detailTextLabel.textColor = (masterOn && igOn && onCount > 0) ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            cell.detailTextLabel.text = (self.igContainersList.count == 0)
                ? @"Sin contenedores detectados en Crane"
                : ((!masterOn || !igOn || onCount == 0)
                    ? @"En pausa"
                    : (onCount == 1 ? [NSString stringWithFormat:@"Protegido: %@", activeName] : [NSString stringWithFormat:@"%lu cuentas protegidas", (unsigned long)onCount]));
        } else {
            BOOL rdOn = [self.state[@"enableReddit"] boolValue];
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
            cell.detailTextLabel.textColor = (masterOn && rdOn && onCount > 0) ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            cell.detailTextLabel.text = (self.redditContainersList.count == 0)
                ? @"Sin contenedores detectados en Crane"
                : ((!masterOn || !rdOn || onCount == 0)
                    ? @"En pausa"
                    : (onCount == 1 ? [NSString stringWithFormat:@"Protegido: %@", activeName] : [NSString stringWithFormat:@"%lu cuentas protegidas", (unsigned long)onCount]));
        }
        return cell;
    }

    if (indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;

        if (indexPath.row == 0) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            BOOL ksBlocking = (masterOn && self.stealthCurrentlyActive && !self.vpnActive);
            cell.imageView.image = settingsBadgeIcon(@"network", self.vpnActive ? [UIColor systemGreenColor] : (ksBlocking ? [UIColor systemRedColor] : [UIColor systemGrayColor]));
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            cell.textLabel.text = @"Túnel Proxy y Kill-Switch";
            cell.detailTextLabel.textColor = ksBlocking ? [UIColor systemRedColor] : [UIColor secondaryLabelColor];
            cell.detailTextLabel.text = self.vpnActive
                ? [NSString stringWithFormat:@"Conectado (%@) • Tráfico protegido y sin fugas de IP", self.vpnInterfaceName]
                : (ksBlocking
                    ? @"⛔ Proxy desconectado — Bloqueando el acceso a internet en tus cuentas"
                    : @"Sin proxy conectado en este momento");
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.imageView.image = settingsBadgeIcon(@"ghost.custom", self.stealthCurrentlyActive ? [UIColor colorWithRed:0.12 green:0.16 blue:0.36 alpha:1.0] : [UIColor systemGrayColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            cell.textLabel.text = @"Modo Invisible";
            cell.detailTextLabel.textColor = self.stealthCurrentlyActive ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            cell.detailTextLabel.text = self.stealthSummary;
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.imageView.image = settingsBadgeIcon(@"trash.fill", [UIColor systemRedColor]);
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    cell.textLabel.textColor = [UIColor systemRedColor];
    cell.textLabel.text = @"Limpiar Caché y Portapapeles";
    cell.detailTextLabel.text = self.residualSummary;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)toggleRootSwitch:(UISwitch *)sender {
    triggerHaptic();
    BOOL isOn = sender.isOn;
    NSInteger tag = sender.tag;

    if (tag == 10) {
        self.state[@"masterEnabled"] = @(isOn);
        [self syncAllContainerLocalPlists];
        [self auditStealthEngineStatus];
        killAppProcess(@"Instagram");
        killAppProcess(@"Reddit");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.tableView.tableHeaderView = [self buildHeaderBannerView];
            [self.tableView reloadData];
        });
    } else if (tag == 11) {
        self.state[@"exclusiveMode"] = @(isOn);
        if (isOn) {
            NSString *keptSummary = [self enforceExclusiveModeWhenToggledOn];
            [self auditStealthEngineStatus];
            killAppProcess(@"Instagram");
            killAppProcess(@"Reddit");
            dispatch_async(dispatch_get_main_queue(), ^{
                self.tableView.tableHeaderView = [self buildHeaderBannerView];
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔒 Modo Exclusivo Activado"
                                                                            message:[NSString stringWithFormat:@"Contenedor activo actual:\n• %@", keptSummary ?: @"Ninguno"]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"Entendido" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
        } else {
            [self syncAllContainerLocalPlists];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
            });
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
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"👻 Modo Invisible"
                                                                    message:self.stealthDetailReport
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Entendido" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    if (indexPath.section == 3) {
        triggerHaptic();
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"¿Limpiar Caché y Portapapeles?"
                                                                         message:@"Se cerrarán Instagram y Reddit, se vaciará el portapapeles y se borrarán los archivos temporales sin cerrar tus sesiones."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Limpiar Ahora" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [self cleanResidualTracesAndKillApps:YES];
        }]];
        [self presentViewController:confirm animated:YES completion:nil];
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
    [self.parentRoot calculateResidualTraces];
    [self.parentRoot scanAndSyncAllContainers];
    [self.parentRoot auditStealthEngineStatus];
    self.containers = [self.bundleID isEqualToString:@"com.burbn.instagram"]
        ? self.parentRoot.igContainersList
        : self.parentRoot.redditContainersList;
    [self.tableView reloadData];
    [rc endRefreshing];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.parentRoot calculateResidualTraces];
    [self.parentRoot scanAndSyncAllContainers];
    [self.parentRoot auditStealthEngineStatus];
    self.containers = [self.bundleID isEqualToString:@"com.burbn.instagram"]
        ? self.parentRoot.igContainersList
        : self.parentRoot.redditContainersList;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"PROTECCIÓN DE LA APLICACIÓN";
    return [NSString stringWithFormat:@"CONTENEDORES (%lu) — DESLIZA PARA ELIMINAR", (unsigned long)self.containers.count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return MAX(1, self.containers.count);
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1 || self.containers.count == 0) return NO;
    NSDictionary *prof = self.containers[indexPath.row];
    return ([prof[@"containerName"] caseInsensitiveCompare:@"Default"] != NSOrderedSame);
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return @"Eliminar";
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.section == 1 && indexPath.row < self.containers.count) {
        triggerHaptic();
        NSDictionary *prof = self.containers[indexPath.row];
        NSString *cName = prof[@"containerName"] ?: @"Contenedor";
        [self.parentRoot purgeGhostContainerFromTweak:prof];
        [self.containers removeObjectAtIndex:indexPath.row];
        [self.parentRoot auditStealthEngineStatus];
        [self.tableView reloadData];

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🧹 Contenedor Eliminado"
                                                                    message:[NSString stringWithFormat:@"Se borraron los datos temporales y el perfil de \"%@\".", cName]
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL masterOn = [self.parentRoot.state[@"masterEnabled"] boolValue];
    BOOL appOn = [self.parentRoot.state[self.appStateKey] boolValue];

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.imageView.image = settingsBadgeIcon(@"power", (masterOn && appOn) ? [UIColor systemGreenColor] : [UIColor systemGrayColor]);
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        cell.textLabel.text = [NSString stringWithFormat:@"Proteger %@", self.appTitle];
        cell.detailTextLabel.text = (masterOn && appOn) ? @"Activo en las cuentas encendidas abajo." : @"En pausa para esta aplicación.";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = appOn;
        sw.enabled = masterOn;
        [sw addTarget:self action:@selector(toggleAppMaster:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (self.containers.count == 0) {
        UITableViewCell *empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        empty.textLabel.text = @"Sin contenedores de Crane";
        empty.detailTextLabel.text = @"Crea un contenedor en Crane para administrarlo aquí";
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
        ? [NSString stringWithFormat:@"%@ (Seleccionado en Crane)", cName]
        : cName;

    NSString *rawIDFV = [prof[@"idfv"] isKindOfClass:[NSString class]] ? prof[@"idfv"] : @"";
    NSString *shortIDFV = (rawIDFV.length >= 8) ? [rawIDFV substringToIndex:8] : @"Nuevo";
    BOOL isCell = ![prof[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"];
    NSString *netDesc = isCell
        ? [NSString stringWithFormat:@"4G: %@", prof[@"CarrierName"] ?: @"Móvil"]
        : @"Wi-Fi";
    int batPct = (int)([prof[@"batteryLevel"] floatValue] * 100.0f);

    if (masterOn && appOn && contOn) {
        BOOL ksNoTunnel = (!self.parentRoot.vpnActive && (prof[@"spoofNetwork"] == nil || [prof[@"spoofNetwork"] boolValue]));
        cell.detailTextLabel.textColor = ksNoTunnel ? [UIColor systemRedColor] : [UIColor systemGreenColor];
        cell.detailTextLabel.text = ksNoTunnel
            ? [NSString stringWithFormat:@"⛔ SIN TÚNEL (Bloqueado) • %@\nIP: %@ • ID: %@...",
               netDesc, prof[@"lastSyncedIP"] ?: @"Sin sincronizar", shortIDFV]
            : [NSString stringWithFormat:@"● PROTEGIDO • %@ • ID: %@...\nIP: %@ • Batería: %d%%",
               netDesc, shortIDFV, prof[@"lastSyncedIP"] ?: @"Sin sincronizar", batPct];
    } else {
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"○ EN PAUSA • ID: %@...", shortIDFV];
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
    [self.parentRoot syncAllContainerLocalPlists];
    [self.parentRoot auditStealthEngineStatus];
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
    self.containers = [self.bundleID isEqualToString:@"com.burbn.instagram"]
        ? self.parentRoot.igContainersList
        : self.parentRoot.redditContainersList;
    [self.tableView reloadData];

    if (sender.isOn && excl && self.containers.count > 1) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔒 Modo Exclusivo"
                                                                    message:[NSString stringWithFormat:@"Se activó \"%@\" y se pusieron en pausa las demás cuentas de %@.", cName, self.appTitle]
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
        [self.parentRoot saveProfile:self.profile forUUID:self.containerUUID saveNow:YES];
        [self.parentRoot syncAllContainerLocalPlists];
        [self.parentRoot auditStealthEngineStatus];
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
        case 0: return @"1. CONTROL Y RED";
        case 1: return @"2. FUNCIONES DE PROTECCIÓN";
        case 2: return @"3. DATOS DE LA CUENTA (TOCA PARA COPIAR)";
        case 3: return @"4. ACCIONES RÁPIDAS";
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
            cell.imageView.image = settingsBadgeIcon(@"ghost.custom", contOn ? [UIColor colorWithRed:0.12 green:0.16 blue:0.36 alpha:1.0] : [UIColor systemGrayColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            cell.textLabel.text = @"Proteger esta Cuenta";
            cell.detailTextLabel.text = contOn ? @"Activo • Usando datos aislados y Modo Invisible." : @"En pausa • Usando los datos reales del teléfono.";
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
            cell.textLabel.text = @"Sincronizar con el Proxy Actual";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Ajusta operadora, hora e idioma según tu IP • Actual: %@",
                                         self.profile[@"lastSyncedIP"] ?: @"Sin sincronizar"];
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.imageView.image = settingsBadgeIcon(@"paperplane.fill", [UIColor systemIndigoColor]);
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            cell.textLabel.textColor = [UIColor systemIndigoColor];
            cell.textLabel.text = @"Auditar IP en Proxy Center";
            cell.detailTextLabel.text = @"Verifica la IP actual y envía el reporte a tu bot de Telegram";
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;

        NSArray *icons = @[@"key.fill", @"network", @"globe.americas.fill", @"battery.100", @"ghost.custom"];
        NSArray *colors = @[
            [UIColor systemPurpleColor],
            [UIColor systemBlueColor],
            [UIColor systemTealColor],
            [UIColor systemGreenColor],
            [UIColor colorWithRed:0.12 green:0.16 blue:0.36 alpha:1.0]
        ];
        NSArray *titles = @[
            @"Identidad del Dispositivo",
            @"Protección de Red y Kill-Switch",
            @"Hora e Idioma Automáticos",
            @"Batería y Sensores",
            @"Modo Invisible"
        ];
        NSArray *subtitles = @[
            @"Asigna un identificador único y tiempo de encendido propio a esta cuenta.",
            @"Simula conexión móvil 4G o Wi-Fi y corta el internet si se desconecta el proxy.",
            @"Adapta la zona horaria y el idioma de la app al país de tu proxy.",
            @"Simula niveles independientes de batería, volumen, brillo y memoria libre.",
            @"Oculta el Jailbreak, Crane y este tweak para que la app vea un iPhone normal."
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
        NSString *displayIDFV = ([self.profile[@"idfv"] isKindOfClass:[NSString class]] && [self.profile[@"idfv"] length] >= 32)
            ? self.profile[@"idfv"]
            : @"Se asignará al abrir la app";

        switch (indexPath.row) {
            case 0: {
                cell.textLabel.text = @"📦 Contenedor";
                cell.detailTextLabel.textColor = contOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Nombre: %@\nID:     %@",
                                             self.profile[@"containerName"] ?: @"Default", craneID];
                break;
            }
            case 1: {
                BOOL on = [self isModOn:@"spoofIDs"];
                cell.textLabel.text = @"🔑 Identificadores";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? [NSString stringWithFormat:@"IDFV:      %@\nBootUUID:  %@\nEncendido: %@",
                       displayIDFV, self.profile[@"bootSessionUUID"], formatBootUptimeSummary(self.profile)]
                    : @"○ En pausa (Usando los datos reales del teléfono)";
                break;
            }
            case 2: {
                BOOL on = [self isModOn:@"spoofNetwork"];
                BOOL isCell = ![self.profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"];
                cell.textLabel.text = @"📡 Red y Kill-Switch";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                if (!on) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"○ En pausa (IP local real: %@)", self.parentRoot.realLocalIP ?: @"LAN"];
                } else if (isCell) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"Modo:       Datos Móviles 4G (%@)\nIP Interna: %@ • Kill-Switch activo",
                                                 self.profile[@"CarrierName"] ?: @"T-Mobile",
                                                 self.profile[@"cellularLocalIP"] ?: @"100.72.14.88"];
                } else {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"Modo:     Wi-Fi (%@)\nIP Local: %@ • Kill-Switch activo",
                                                 self.profile[@"ssid"],
                                                 self.profile[@"localIP"] ?: @"192.168.1.45"];
                }
                break;
            }
            case 3: {
                BOOL on = [self isModOn:@"spoofLocation"];
                cell.textLabel.text = @"🌎 Ubicación y Hora";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? [NSString stringWithFormat:@"IP / ISP:      %@ (%@)\nUbicación:     %@\nHora / Idioma: %@ (%@)",
                       self.profile[@"lastSyncedIP"] ?: @"Sin sincronizar", self.profile[@"ispName"] ?: @"ISP",
                       self.profile[@"cityCountry"] ?: @"N/A", self.profile[@"timeZone"], self.profile[@"localeID"]]
                    : [NSString stringWithFormat:@"○ En pausa (Hora real: %@)", [[NSTimeZone localTimeZone] name]];
                break;
            }
            case 4: {
                BOOL on = [self isModOn:@"spoofHardware"];
                cell.textLabel.text = @"🔋 Batería y Sensores";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? [NSString stringWithFormat:@"Batería: %d%% • Volumen: %d%%\nBrillo:  %d%% • Espacio libre: %.2f GB",
                       batPct, volPct, briPct, freeGB]
                    : [NSString stringWithFormat:@"○ En pausa (Batería real: %d%%)", self.parentRoot.realBatteryPct];
                break;
            }
            case 5: {
                BOOL on = [self isModOn:@"spoofSecurity"];
                cell.textLabel.text = @"👻 Modo Invisible";
                cell.detailTextLabel.textColor = on ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
                cell.detailTextLabel.text = on
                    ? @"● Activo: Jailbreak, Crane y tweak ocultos ante la app."
                    : @"○ En pausa en esta cuenta.";
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
        cell.textLabel.text = @"Variar Batería y Sensores";
        cell.detailTextLabel.text = @"Cambia los niveles de batería, volumen, brillo y memoria sin alterar la identidad";
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        cell.imageView.image = settingsBadgeIcon(@"arrow.clockwise.circle.fill", [UIColor systemOrangeColor]);
        cell.textLabel.textColor = [UIColor systemOrangeColor];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        cell.textLabel.text = @"Simular Reinicio del Teléfono";
        cell.detailTextLabel.text = @"Genera un nuevo ciclo de encendido e IP interna manteniendo el mismo dispositivo";
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

        NSString *displayIDFV = ([self.profile[@"idfv"] isKindOfClass:[NSString class]] && [self.profile[@"idfv"] length] >= 32)
            ? self.profile[@"idfv"]
            : @"Se asignará al abrir la app";

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:sender.isOn ? @"🟢 Cuenta Protegida" : @"⚪ Cuenta en Pausa"
                                                                    message:sender.isOn
                                                                        ? [NSString stringWithFormat:@"Protección activada para \"%@\".\n• IDFV: %@\n• Encendido: %@", self.profile[@"containerName"], displayIDFV, formatBootUptimeSummary(self.profile)]
                                                                        : @"Esta cuenta está en pausa y usará los datos normales del teléfono."
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
        NSString *displayIDFV = ([self.profile[@"idfv"] isKindOfClass:[NSString class]] && [self.profile[@"idfv"] length] >= 32)
            ? self.profile[@"idfv"]
            : @"Se asignará al abrir la app";

        if (idx == 0) {
            popupTitle = sender.isOn ? @"🔑 Identidad Aislada" : @"⚪ Identidad en Pausa";
            popupMsg = sender.isOn
                ? [NSString stringWithFormat:@"• IDFV: %@\n• BootUUID: %@\n• Encendido: %@", displayIDFV, self.profile[@"bootSessionUUID"], formatBootUptimeSummary(self.profile)]
                : @"Mostrando los identificadores reales del teléfono.";
        } else if (idx == 1) {
            BOOL isCell = ![self.profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"];
            popupTitle = sender.isOn ? @"📡 Protección de Red Activa" : @"⚪ Protección de Red en Pausa";
            popupMsg = sender.isOn
                ? (isCell
                   ? [NSString stringWithFormat:@"Modo móvil 4G (%@) • IP interna: %@ • Kill-Switch activo", self.profile[@"CarrierName"], self.profile[@"cellularLocalIP"]]
                   : [NSString stringWithFormat:@"Modo Wi-Fi (%@) • IP local: %@ • Kill-Switch activo", self.profile[@"ssid"], self.profile[@"localIP"]])
                : @"Mostrando la conexión física real del teléfono.";
        } else if (idx == 2) {
            popupTitle = sender.isOn ? @"🌎 Hora e Idioma Activos" : @"⚪ Hora e Idioma en Pausa";
            popupMsg = sender.isOn
                ? [NSString stringWithFormat:@"• Ubicación: %@\n• Zona Horaria: %@\n• Idioma: %@", self.profile[@"cityCountry"], self.profile[@"timeZone"], self.profile[@"localeID"]]
                : @"Usando la hora y el idioma reales del iPhone.";
        } else if (idx == 3) {
            double freeGB = [self.profile[@"freeBytes"] unsignedLongLongValue] / (1024.0*1024.0*1024.0);
            int batPct = (int)([self.profile[@"batteryLevel"] floatValue] * 100.0f);
            int volPct = (int)([self.profile[@"audioVolume"] floatValue] * 100.0f);
            int briPct = (int)([self.profile[@"brightness"] floatValue] * 100.0f);
            popupTitle = sender.isOn ? @"🔋 Batería y Sensores Activos" : @"⚪ Sensores en Pausa";
            popupMsg = sender.isOn
                ? [NSString stringWithFormat:@"• Batería: %d%%\n• Volumen: %d%%\n• Brillo: %d%%\n• Espacio libre: %.2f GB", batPct, volPct, briPct, freeGB]
                : @"Mostrando el nivel de batería y memoria reales.";
        } else if (idx == 4) {
            popupTitle = sender.isOn ? @"👻 Modo Invisible Activado" : @"⚪ Modo Invisible en Pausa";
            popupMsg = sender.isOn
                ? @"Ocultando el Jailbreak, Crane y el tweak ante la aplicación."
                : @"Modo Invisible desactivado en esta cuenta.";
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

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔋 Sensores Actualizados"
                                                                message:[NSString stringWithFormat:@"Nuevos valores para \"%@\":\n\n• Batería: %d%%\n• Volumen: %d%%\n• Brillo: %d%%\n• Espacio libre: %.2f GB",
                                                                         self.profile[@"containerName"], batPct, volPct, briPct, freeGB]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Listo" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)rotateBootUUIDWithPopup {
    triggerHaptic();
    NSString *newBootUUID = [[NSUUID UUID] UUIDString];
    self.profile[@"bootSessionUUID"] = newBootUUID;
    assignSpoofedBootTimeToProfile(self.profile, YES);
    self.profile[@"cellularLocalIP"] = generateCellularCGNATAddress(newBootUUID);
    [self saveCurrentProfile];
    [self.tableView reloadData];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"🔄 Reinicio Simulado"
                                                                message:[NSString stringWithFormat:@"Se renovó el ciclo de encendido en \"%@\" (manteniendo el mismo IDFV):\n\n• Nuevo BootUUID:\n%@\n\n• Nueva IP interna 4G:\n%@\n\n• Tiempo encendido:\n%@",
                                                                         self.profile[@"containerName"],
                                                                         self.profile[@"bootSessionUUID"],
                                                                         self.profile[@"cellularLocalIP"],
                                                                         formatBootUptimeSummary(self.profile)]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
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
            [self rotateBootUUIDWithPopup];
        }
    }
}

- (void)syncWithLiveIPAndAuditVPS:(BOOL)sendToVPS {
    NSArray *endpoints = @[
        @"https://ipwho.is/",
        @"https://ipinfo.io/json",
        @"https://ipapi.co/json/",
        @"https://freeipapi.com/api/json",
        @"http://ip-api.com/json/?fields=status,country,countryCode,regionName,city,timezone,isp,mobile,query"
    ];

    fetchLiveIPFromEndpoints(endpoints, 0, ^(NSDictionary *parsed, NSError *error) {
        if (!parsed || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Sin Conexión"
                                                                            message:@"No se pudo detectar la IP pública. Verifica que Shadowrocket esté encendido y conectado."
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
                BOOL isCell = ![self.profile[@"CarrierMode"] isEqualToString:@"WIFI_ONLY"];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"✅ Red Sincronizada"
                                                                            message:[NSString stringWithFormat:@"• Cuenta: %@\n• IP Pública: %@\n• Operadora/ISP: %@\n• Modo: %@\n• Ubicación: %@, %@ (%@)\n• Hora: %@",
                                                                                     self.profile[@"containerName"],
                                                                                     ip,
                                                                                     ispRaw,
                                                                                     isCell ? @"📱 Datos Móviles 4G" : @"🛜 Wi-Fi",
                                                                                     city,
                                                                                     region,
                                                                                     [cc uppercaseString],
                                                                                     tz]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
            return;
        }

        NSString *plat = [self.bundleID isEqualToString:@"com.burbn.instagram"] ? @"INSTAGRAM" : @"REDDIT";
        NSString *cName = self.profile[@"containerName"] ?: @"Default";
        NSString *contEnc = [cName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"Default";
        NSString *ispEnc = [(ispRaw ?: @"") stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";

        int shieldActiveFlag = [self isModOn:@"spoofSecurity"] ? 1 : 0;
        NSString *baseAuditURL = ([self.parentRoot.state[@"vpsAuditURL"] isKindOfClass:[NSString class]] && [self.parentRoot.state[@"vpsAuditURL"] length] > 0)
            ? self.parentRoot.state[@"vpsAuditURL"]
            : VPS_AUDIT_URL;
        NSString *vpsUrlStr = [NSString stringWithFormat:@"%@?ip=%@&contenedor=%@&plataforma=%@&shield=%d&bssid=%@&isp=%@&cc=%@",
                               baseAuditURL, ip, contEnc, plat, shieldActiveFlag, self.profile[@"bssid"] ?: @"", ispEnc, cc];

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 12.0;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

        [[session dataTaskWithURL:[NSURL URLWithString:vpsUrlStr] completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
            NSHTTPURLResponse *httpResp = [vResp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)vResp : nil;
            BOOL httpOK = (!vErr && httpResp && httpResp.statusCode >= 200 && httpResp.statusCode < 300);
            NSDictionary *vpsJson = (httpOK && vData) ? [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil] : nil;

            NSString *msj = nil;
            if ([vpsJson isKindOfClass:[NSDictionary class]] && [vpsJson[@"mensaje_iphone"] isKindOfClass:[NSString class]]) {
                msj = vpsJson[@"mensaje_iphone"];
            } else if (httpOK) {
                msj = [NSString stringWithFormat:@"✅ Auditoría enviada a Proxy Center.\n• IP: %@ (%@)\n• Cuenta: %@", ip, ispRaw, cName];
            } else {
                msj = [NSString stringWithFormat:@"⚠️ El VPS no respondió en el puerto 5001, pero la IP %@ (%@) quedó guardada en \"%@\".", ip, ispRaw, cName];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Proxy Center" message:msj preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
        }] resume];
    });
}

@end
