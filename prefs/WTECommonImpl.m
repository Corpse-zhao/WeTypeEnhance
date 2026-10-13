// WTECommonImpl.m
// 工具函数实现 —— 仅编入偏好面板 bundle。
// 这些函数声明在 WeTypeEnhanceCommon.h（extern），但实现原本只在主 tweak dylib 里；
// 设置进程不加载 tweak dylib，导致 dlopen 报
// "symbol not found in flat namespace '_WTE_ColorFromHex'"。
// bundle 内自带一份实现，同时把实现从 Tweak.x 中的对应符号降级为静态，避免重名。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../WeTypeEnhanceCommon.h"

#pragma mark - 颜色转换

UIColor *WTE_ColorFromHex(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return nil;
    NSString *s = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"0x" withString:@""];
    if (s.length != 6 && s.length != 8) return nil;
    unsigned int value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:s];
    if (![scanner scanHexInt:&value]) return nil;
    if (s.length == 6) {
        return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0
                               green:((value >> 8)  & 0xFF) / 255.0
                                blue:( value        & 0xFF) / 255.0
                               alpha:1.0];
    }
    return [UIColor colorWithRed:((value >> 24) & 0xFF) / 255.0
                           green:((value >> 16) & 0xFF) / 255.0
                            blue:((value >> 8)  & 0xFF) / 255.0
                           alpha:( value        & 0xFF) / 255.0];
}

NSString *WTE_HexFromColor(UIColor *color) {
    if (!color) return @"#000000";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0, wa = 0;
        if ([color getWhite:&w alpha:&wa]) {
            r = g = b = w; a = wa;
        } else {
            return @"#000000";
        }
    }
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X",
            (int)round(r * 255), (int)round(g * 255), (int)round(b * 255), (int)round(a * 255)];
}

#pragma mark - 偏好读写（兼容 roothide / rootless 双路径）

static NSString *WTEP_PrefPath(void) {
    NSArray *candidates = @[
        @"/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in candidates) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return candidates.firstObject;
}

id WTE_GetPref(NSString *key) {
    if (!key) return nil;
    NSString *path = WTEP_PrefPath();
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    id v = dict[key];
    if (v) return v;
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
    return [ud objectForKey:key];
}

void WTE_SetPref(NSString *key, id value) {
    if (!key) return;
    // 所有候选路径都写一份，保证 tweak 无论从哪个路径读都能读到
    NSArray *paths = @[
        @"/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist",
    ];
    for (NSString *path in paths) {
        NSMutableDictionary *dict = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
        if (!dict) dict = [NSMutableDictionary dictionary];
        if (value == nil) [dict removeObjectForKey:key];
        else dict[key] = value;
        [dict writeToFile:path atomically:YES];
    }
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
    if (value == nil) [ud removeObjectForKey:key];
    else [ud setObject:value forKey:key];
    [ud synchronize];
}

void WTE_NotifyChanged(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kPrefChangedNotify,
                                         NULL, NULL, YES);
}

#pragma mark - 配置同步（键盘扩展沙盒保底通道）

// 扫描某类容器目录，挑出标识里含微信输入法关键字的那几个
static NSArray *WTEP_ContainersMatching(NSString *basePath, NSArray *keywords) {
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sub in [fm contentsOfDirectoryAtPath:basePath error:nil]) {
        NSString *base = [basePath stringByAppendingPathComponent:sub];
        NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:
            [base stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        NSString *ident = m[@"MCMMetadataIdentifier"];
        NSString *t = [[NSString stringWithFormat:@"%@ %@", ident ?: @"", sub] lowercaseString];
        for (NSString *kw in keywords) {
            if ([t containsString:kw]) { [out addObject:base]; break; }
        }
    }
    return out;
}

NSArray *WTE_SyncConfigToReadablePlaces(void) {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 源数据：标准偏好域（面板刚写进去的那份）
    NSDictionary *src = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist"];
    if (![src isKindOfClass:[NSDictionary class]] || src.count == 0) {
        NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
        src = [ud persistentDomainForName:kPrefDomain];
    }
    if (![src isKindOfClass:[NSDictionary class]] || src.count == 0) return @[];

    NSMutableArray *targets = [NSMutableArray array];
    [targets addObject:@"/var/mobile/Library/Application Support/WeTypeEnhance/config.plist"];
    [targets addObject:@"/var/jb/var/mobile/Library/Application Support/WeTypeEnhance/config.plist"];
    [targets addObject:@"/var/mobile/Media/WeTypeEnhance/config.plist"];

    NSArray *kws = @[@"wetype", @"tencent", @"wxkb", @"xin.keyboard", @"wechat"];

    // ① 键盘扩展容器 —— 这是最关键的通道：键盘进程读自己的容器永远不受沙盒限制
    for (NSString *base in WTEP_ContainersMatching(@"/var/mobile/Containers/Data/PluginKitPlugin", kws)) {
        [targets addObject:[base stringByAppendingPathComponent:@"Documents/WeTypeEnhance/config.plist"]];
        [targets addObject:[base stringByAppendingPathComponent:@"Documents/wte_config.plist"]];
        [targets addObject:[base stringByAppendingPathComponent:@"Library/Application Support/WeTypeEnhance/config.plist"]];
        [targets addObject:[base stringByAppendingPathComponent:@"Library/Preferences/com.colorblack.wetypeenhance.plist"]];
        [targets addObject:[base stringByAppendingPathComponent:@"tmp/WeTypeEnhance/config.plist"]];
    }
    // ② 主 App 容器
    for (NSString *base in WTEP_ContainersMatching(@"/var/mobile/Containers/Data/Application", kws)) {
        [targets addObject:[base stringByAppendingPathComponent:@"Documents/WeTypeEnhance/config.plist"]];
        [targets addObject:[base stringByAppendingPathComponent:@"Library/Application Support/WeTypeEnhance/config.plist"]];
        [targets addObject:[base stringByAppendingPathComponent:@"Library/Preferences/com.colorblack.wetypeenhance.plist"]];
    }
    // ③ App Group 共享容器
    for (NSString *base in WTEP_ContainersMatching(@"/var/mobile/Containers/Shared/AppGroup", kws)) {
        [targets addObject:[base stringByAppendingPathComponent:@"WeTypeEnhance/config.plist"]];
    }

    NSMutableArray *ok = [NSMutableArray array];
    for (NSString *dest in targets) {
        NSString *dir = [dest stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        if (![fm fileExistsAtPath:dir]) continue;
        if ([src writeToFile:dest atomically:YES]) [ok addObject:dest];
    }

    // ---- 背景图也要一起送进容器（键盘沙盒读不到全局路径） ----
    NSString *bgSrc = nil;
    for (NSString *cand in @[@"/var/mobile/Library/Application Support/WeTypeEnhance/bg.png",
                             @"/var/jb/var/mobile/Library/Application Support/WeTypeEnhance/bg.png"]) {
        if ([fm fileExistsAtPath:cand]) { bgSrc = cand; break; }
    }
    if (bgSrc) {
        NSData *bg = [NSData dataWithContentsOfFile:bgSrc];
        if (bg.length) {
            for (NSString *base in WTEP_ContainersMatching(@"/var/mobile/Containers/Data/PluginKitPlugin", kws)) {
                for (NSString *rel in @[@"Documents/WeTypeEnhance/bg.png",
                                        @"tmp/WeTypeEnhance/bg.png"]) {
                    NSString *dest = [base stringByAppendingPathComponent:rel];
                    NSString *dir = [dest stringByDeletingLastPathComponent];
                    if (![fm fileExistsAtPath:dir]) {
                        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                    }
                    if (![fm fileExistsAtPath:dir]) continue;
                    if ([bg writeToFile:dest atomically:YES]) [ok addObject:dest];
                }
            }
        }
    }
    return ok;
}
