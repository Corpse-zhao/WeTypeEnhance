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
    NSString *path = WTEP_PrefPath();
    NSMutableDictionary *dict = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    if (!dict) dict = [NSMutableDictionary dictionary];
    if (value == nil) {
        [dict removeObjectForKey:key];
    } else {
        dict[key] = value;
    }
    [dict writeToFile:path atomically:YES];
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
