// WeTypeEnhance Tweak.x
// 微信输入法增强 —— 功能对等移植自「原生输入法增强 KBTheme」，目标改为微信输入法
//
// 目标 Bundle:  com.tencent.wetype.keyboard / com.tencent.xin.keyboard / com.tencent.wetype
// 目标进程:     wxkb_plugin / wxkb_plugin.appex
//
// 设计要点（v1.1.0 起）：
//   输入法版本迭代后类名可能变化，因此不再写死 WB* 类，改为：
//     1) 运行时枚举所有类，按名字特征挑出「键盘/按键/候选/工具栏」候选类
//     2) 对这些类动态 hook -layoutSubviews / -didMoveToWindow
//     3) 处理时按类名特征 + 视图内容做通用判定，不依赖固定类名
//   同时输出诊断文件，便于类名变化时快速定位。
//
// 包名: com.colorblack.wetypeenhance

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "WeTypeEnhanceCommon.h"

#define WTE_LOG_ENABLE 1

// 前置声明：视图树重排分类（定义在后面）
@interface UIView (WTEEnhance)
- (void)_wte_relayoutTree;
@end

#pragma mark - ========== 工具函数 ==========

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
        if ([color getWhite:&w alpha:&wa]) { r = g = b = w; a = wa; }
        else { return @"#000000"; }
    }
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X",
            (int)round(r * 255), (int)round(g * 255), (int)round(b * 255), (int)round(a * 255)];
}

// ---------- 偏好通道（v1.7.0 多通道） ----------
// 键盘扩展跑在独立沙盒里（PluginKitPlugin 容器），直读 /var/mobile/Library/Preferences
// 有可能被沙盒拦掉。因此面板会把同一份配置复制到多个「键盘扩展读得到」的位置，
// 这里按「文件修改时间最新者优先」挑一份用 —— 比固定优先级更抗部分写入失败。
static NSString *WTEPref_HomePath(NSString *rel) {
    NSString *home = NSHomeDirectory();
    return home.length ? [home stringByAppendingPathComponent:rel] : nil;
}

static NSArray *WTE_PrefCandidates(void) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *p = nil;
    // 1) 本进程自己的容器（键盘扩展一定可读）
    if ((p = WTEPref_HomePath(@"Documents/WeTypeEnhance/config.plist"))) [a addObject:p];
    if ((p = WTEPref_HomePath(@"Library/Application Support/WeTypeEnhance/config.plist"))) [a addObject:p];
    if ((p = WTEPref_HomePath(@"Library/Preferences/com.colorblack.wetypeenhance.plist"))) [a addObject:p];
    // 2) 全局可写位置
    [a addObject:@"/var/mobile/Library/Application Support/WeTypeEnhance/config.plist"];
    [a addObject:@"/var/jb/var/mobile/Library/Application Support/WeTypeEnhance/config.plist"];
    [a addObject:@"/var/mobile/Media/WeTypeEnhance/config.plist"];
    // 3) 标准偏好域
    [a addObject:@"/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist"];
    [a addObject:@"/var/jb/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist"];
    // 4) 微信输入法相关 App Group 共享容器
    NSString *shared = @"/var/mobile/Containers/Shared/AppGroup";
    for (NSString *sub in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:shared error:nil]) {
        NSString *base = [shared stringByAppendingPathComponent:sub];
        NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:
            [base stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        NSString *gid = m[@"MCMMetadataIdentifier"];
        if (![gid isKindOfClass:[NSString class]]) continue;
        if ([gid containsString:@"tencent"] || [gid containsString:@"wetype"] ||
            [gid containsString:@"xin"] || [gid containsString:@"wechat"]) {
            [a addObject:[base stringByAppendingPathComponent:@"WeTypeEnhance/config.plist"]];
        }
    }
    return a;
}

static NSDictionary *gConfigDict     = nil;   // 当前生效的原始偏好快照
static NSString     *gConfigDictPath = nil;   // 快照来源（诊断用）

// 逐路径扫描，取「修改时间最新」的那份非空配置
static NSDictionary *WTE_ReadRawPrefs(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *best = nil;
    NSString *bestPath = nil;
    NSDate *bestDate = nil;

    for (NSString *path in WTE_PrefCandidates()) {
        if (![path isKindOfClass:[NSString class]] || path.length == 0) continue;
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        if (!attr) continue;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![d isKindOfClass:[NSDictionary class]] || d.count == 0) continue;
        NSDate *mod = attr[NSFileModificationDate] ?: [NSDate dateWithTimeIntervalSince1970:0];
        if (best && bestDate && [mod compare:bestDate] != NSOrderedDescending) continue;
        best = d; bestPath = path; bestDate = mod;
    }
    if (best) { gConfigDictPath = bestPath; return best; }

    // 最后兜底：cfprefsd。越狱环境下 cfprefsd 读偏好通常不受 app 沙盒限制，
    // 所以即使上面的直读全部失败，这条路仍可能拿到配置。
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
    NSDictionary *rep = [ud persistentDomainForName:kPrefDomain];
    if ([rep isKindOfClass:[NSDictionary class]] && rep.count) {
        gConfigDictPath = @"cfprefsd://com.colorblack.wetypeenhance";
        return rep;
    }
    gConfigDictPath = nil;
    return nil;
}

static NSString *WTE_PrefPath(void) {
    if (gConfigDictPath.length) return gConfigDictPath;
    return @"/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist";
}

id WTE_GetPref(NSString *key) {
    if (!key) return nil;
    if (!gConfigDict) gConfigDict = WTE_ReadRawPrefs();
    id v = gConfigDict[key];
    if (v) return v;
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
    return [ud objectForKey:key];
}

void WTE_SetPref(NSString *key, id value) {
    if (!key) return;
    // 所有可写候选路径都写一份，读哪份都能读到
    for (NSString *path in WTE_PrefCandidates()) {
        if (![path isKindOfClass:[NSString class]] || path.length == 0) continue;
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
    gConfigDict = nil;      // 使缓存失效，下次读取重新扫描
}

void WTE_NotifyChanged(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kPrefChangedNotify,
                                         NULL, NULL, YES);
}

static BOOL  WTE_BoolPref(NSString *key, BOOL def) {
    id v = WTE_GetPref(key);
    return v ? [v boolValue] : def;
}
static double WTE_DoublePref(NSString *key, double def) {
    id v = WTE_GetPref(key);
    return v ? [v doubleValue] : def;
}
static NSString *WTE_StringPref(NSString *key, NSString *def) {
    id v = WTE_GetPref(key);
    return [v isKindOfClass:[NSString class]] ? v : def;
}

#pragma mark - ========== 诊断输出 ==========

#if WTE_LOG_ENABLE
static NSMutableString *gDiag;
static dispatch_queue_t gDiagQueue;
static BOOL gDiagFlushedClassScan = NO;
static NSMutableSet *gLayoutSeen;

#if WTE_LOG_ENABLE
static void WTE_Diag(NSString *fmt, ...);   // 前置声明（定义在下面）
#endif

static NSArray *WTE_DiagDirs(void) {
    NSMutableArray *dirs = [NSMutableArray array];
    // 1) 全局可写位置
    [dirs addObject:@"/var/mobile/Media/WeTypeEnhance"];
    [dirs addObject:@"/var/mobile/Library/Application Support/WeTypeEnhance"];
    // 2) 当前进程自己的容器（扩展容器一定可写）
    NSString *home = NSHomeDirectory();
    if (home.length) {
        [dirs addObject:[home stringByAppendingPathComponent:@"Documents/WeTypeEnhance"]];
        [dirs addObject:[home stringByAppendingPathComponent:@"tmp/WeTypeEnhance"]];
    }
    // 3) 微信输入法相关的 App Group 共享容器（导入导出组）
    NSString *shared = @"/var/mobile/Containers/Shared/AppGroup";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *subs = [fm contentsOfDirectoryAtPath:shared error:nil];
    for (NSString *sub in subs) {
        NSString *base = [shared stringByAppendingPathComponent:sub];
        NSString *meta = [base stringByAppendingPathComponent:
                          @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *gid = m[@"MCMMetadataIdentifier"];
        if (![gid isKindOfClass:[NSString class]]) continue;
        if ([gid containsString:@"tencent"] || [gid containsString:@"wetype"] ||
            [gid containsString:@"xin"] || [gid containsString:@"wechat"]) {
            [dirs addObject:base];
        }
    }
    return dirs;
}

static void WTE_DiagFlush(NSString *tag) {
    if (!gDiag) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *ok = [NSMutableArray array];
    for (NSString *dir in WTE_DiagDirs()) {
        NSString *target = [dir hasSuffix:@"AppGroup"] || [dir containsString:@"AppGroup/"]
                         ? [dir stringByAppendingPathComponent:@"WeTypeEnhance"]
                         : dir;
        NSError *e = nil;
        if (![fm fileExistsAtPath:target]) {
            [fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:&e];
        }
        if (![fm fileExistsAtPath:target]) continue;
        NSString *dest = [target stringByAppendingPathComponent:@"diag.txt"];
        // 两段式：先写正文，成功则记下该路径
        if ([gDiag writeToFile:dest atomically:YES encoding:NSUTF8StringEncoding error:&e]) {
            [ok addObject:dest];
        }
    }
    // 把成功写入的路径补进正文（下次 flush 生效），便于确认哪条通道可用
    if (ok.count) {
        [gDiag appendFormat:@"=== 已成功写入 %lu 处 ===\n", (unsigned long)ok.count];
        for (NSString *p in ok) [gDiag appendFormat:@"  wrote %@\n", p];
    }
    WTE_Diag(@"flush(%@) 成功 %lu 处", tag, (unsigned long)ok.count);
}

static void WTE_Diag(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (!gDiag) gDiag = [NSMutableString new];
    [gDiag appendFormat:@"%@\n", line];
    NSLog(@"[WeTypeEnhance] %@", line);
}
#else
#define WTE_Diag(...) do {} while (0)
static void WTE_DiagFlush(NSString *tag) {}
#endif

#pragma mark - ========== 全局配置快照 ==========

@interface WTEConfig : NSObject
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL bgEnabled;
@property (nonatomic, copy)   NSString *bgMode;
@property (nonatomic, strong) UIColor  *bgColor;
@property (nonatomic, assign) double    bgAlpha;
@property (nonatomic, strong) UIImage  *bgImage;
@property (nonatomic, assign) BOOL keyboardTransparent;

@property (nonatomic, assign) BOOL keyColorEnabled;
@property (nonatomic, strong) UIColor *keyLetterBg;
@property (nonatomic, strong) UIColor *keyDigitBg;
@property (nonatomic, strong) UIColor *keyFuncLeftBg;
@property (nonatomic, strong) UIColor *keyFuncRightBg;
@property (nonatomic, strong) UIColor *keySpaceBg;
@property (nonatomic, strong) UIColor *keyTextColor;
@property (nonatomic, strong) UIColor *keyHighlightColor;

@property (nonatomic, assign) BOOL skinEnabled;
@property (nonatomic, assign) BOOL letterGradientEnabled;
@property (nonatomic, strong) UIColor *letterGradientFrom;
@property (nonatomic, strong) UIColor *letterGradientTo;
@property (nonatomic, strong) NSDictionary *letterColorMap;

@property (nonatomic, copy)   NSString *keyShape;
@property (nonatomic, assign) BOOL keyCap3D;
@property (nonatomic, assign) double keyCornerRadius;

@property (nonatomic, assign) BOOL tbKeepNativeSize;
@property (nonatomic, assign) BOOL tbHorizontalScroll;
@property (nonatomic, assign) BOOL tbFillRow;
@property (nonatomic, assign) BOOL tbEditNoFill;

@property (nonatomic, assign) double kbOffset;
@end

@interface WTEConfig (Gradient)
+ (UIColor *)interpolateFrom:(UIColor *)a to:(UIColor *)b t:(double)t;
@end

@implementation WTEConfig

+ (instancetype)loadConfig {
    WTEConfig *c = [WTEConfig new];

    // —— 诊断模式 ——
    // 如果偏好完全读不到（空字典），强制套用一套高对比测试主题：
    //   键盘橙色背景 + 按键红色。
    // 键盘变红橙 → 注入/hook 全通，问题是「偏好读不到」（沙盒），换存储方案即可
    // 键盘没变化 → 注入或类扫描问题，需要 diag.txt
    NSDictionary *raw = gConfigDict ?: WTE_ReadRawPrefs();
    BOOL prefsReadable = raw.count > 0;
    if (!prefsReadable) {
        c.enabled = YES;
        c.bgEnabled = YES;
        c.bgMode = @"solid";
        c.bgColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.0 alpha:1.0];
        c.bgAlpha = 1.0;
        c.keyColorEnabled = YES;
        c.keyLetterBg = [UIColor colorWithRed:0.95 green:0.1 blue:0.1 alpha:1.0];
        c.keyDigitBg  = [UIColor colorWithRed:0.95 green:0.5 blue:0.1 alpha:1.0];
        c.keyFuncLeftBg = [UIColor darkGrayColor];
        c.keyFuncRightBg = [UIColor darkGrayColor];
        c.keySpaceBg = [UIColor colorWithRed:0.95 green:0.1 blue:0.1 alpha:1.0];
        c.keyTextColor = [UIColor whiteColor];
        c.keyShape = @"rounded";
        c.keyCornerRadius = 6.0;
        WTE_Diag(@"!!! 偏好不可读，进入强制测试主题模式（键盘应为橙底红键）");
        return c;
    }

    c.enabled = WTE_BoolPref(kKeyEnabled, YES);
    if (!c.enabled) return c;

    c.bgEnabled           = WTE_BoolPref(kKeyBgEnabled, NO);
    c.bgMode              = WTE_StringPref(kKeyBgMode, @"solid");
    c.bgColor             = WTE_ColorFromHex(WTE_StringPref(kKeyBgColor, @"#1C1C1E")) ?: [UIColor clearColor];
    c.bgAlpha             = WTE_DoublePref(kKeyBgAlpha, 1.0);
    c.keyboardTransparent = WTE_BoolPref(kKeyKeyboardTransparent, NO);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *useImg = nil;
    for (NSString *p in @[@"/var/mobile/Library/Application Support/WeTypeEnhance/bg.png",
                          @"/var/jb/var/mobile/Library/Application Support/WeTypeEnhance/bg.png"]) {
        if ([fm fileExistsAtPath:p]) { useImg = p; break; }
    }
    if (useImg) {
        c.bgImage = [UIImage imageWithContentsOfFile:useImg];
    } else {
        id data = WTE_GetPref(kKeyBgImageData);
        if ([data isKindOfClass:[NSData class]] && [(NSData *)data length] > 0) {
            c.bgImage = [UIImage imageWithData:data];
        }
    }

    c.keyColorEnabled   = WTE_BoolPref(kKeyKeyColorEnabled, NO);
    c.keyLetterBg       = WTE_ColorFromHex(WTE_StringPref(kKeyKeyLetterBg, @"#FFFFFF"));
    c.keyDigitBg        = WTE_ColorFromHex(WTE_StringPref(kKeyKeyDigitBg, @"#FFD166"));
    c.keyFuncLeftBg     = WTE_ColorFromHex(WTE_StringPref(kKeyKeyFuncLeftBg, @"#A8A8A8"));
    c.keyFuncRightBg    = WTE_ColorFromHex(WTE_StringPref(kKeyKeyFuncRightBg, @"#A8A8A8"));
    c.keySpaceBg        = WTE_ColorFromHex(WTE_StringPref(kKeyKeySpaceBg, @"#FFFFFF"));
    c.keyTextColor      = WTE_ColorFromHex(WTE_StringPref(kKeyKeyTextColor, @"#000000"));
    c.keyHighlightColor = WTE_ColorFromHex(WTE_StringPref(kKeyKeyHighlightColor, @"#D9D9D9"));

    c.skinEnabled           = WTE_BoolPref(kKeySkinEnabled, NO);
    c.letterGradientEnabled = WTE_BoolPref(kKeyLetterGradientEnabled, NO);
    c.letterGradientFrom    = WTE_ColorFromHex(WTE_StringPref(kKeyLetterGradientFrom, @"#5AC8FA"));
    c.letterGradientTo      = WTE_ColorFromHex(WTE_StringPref(kKeyLetterGradientTo, @"#AF52DE"));
    c.letterColorMap        = WTE_GetPref(kKeyLetterColorMap);

    c.keyShape        = WTE_StringPref(kKeyKeyShape, @"rounded");
    c.keyCap3D        = WTE_BoolPref(kKeyKeyCap3D, NO);
    c.keyCornerRadius = WTE_DoublePref(kKeyKeyCornerRadius, 5.0);

    c.tbKeepNativeSize   = WTE_BoolPref(kKeyTbKeepNativeSize, YES);
    c.tbHorizontalScroll = WTE_BoolPref(kKeyTbHorizontalScroll, NO);
    c.tbFillRow          = WTE_BoolPref(kKeyTbFillRow, NO);
    c.tbEditNoFill       = WTE_BoolPref(kKeyTbEditNoFill, YES);

    c.kbOffset = WTE_DoublePref(kKeyKbOffset, 0.0);

    return c;
}
@end

static WTEConfig *gConfig = nil;
static dispatch_queue_t gPrefQueue;

static void WTE_ReloadConfig(void) {
    gConfigDict = WTE_ReadRawPrefs();   // 刷新原始快照（缓存失效）
    gConfig = [WTEConfig loadConfig];
}

static void WTE_PrefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    // 延迟 0.8s：面板发通知的同时 SpringBoard 的「偏好中继」也在写文件，
    // 等它写完再重读，避免拿到旧配置
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   gPrefQueue, ^{
        WTE_ReloadConfig();
        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    [w setNeedsLayout];
                    [w _wte_relayoutTree];
                }
            }
        });
    });
}

#pragma mark - ========== 按键类型判定（通用启发式，不依赖固定类名） ==========

typedef NS_ENUM(NSInteger, WTEKeyKind) {
    WTEKeyKindLetter = 0,
    WTEKeyKindDigit,
    WTEKeyKindFuncLeft,
    WTEKeyKindFuncRight,
    WTEKeyKindSpace,
    WTEKeyKindOther,
};

// 取视图上的文字（兼容 titleLabel / text / 首个 UILabel 子视图）
static NSString *WTE_TextOfView(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length) return t;
    }
    SEL s = NSSelectorFromString(@"titleLabel");
    if ([v respondsToSelector:s]) {
        id lbl = ((id (*)(id, SEL))objc_msgSend)(v, s);
        if ([lbl isKindOfClass:[UILabel class]] && [(UILabel *)lbl text].length) {
            return [(UILabel *)lbl text];
        }
    }
    s = NSSelectorFromString(@"text");
    if ([v respondsToSelector:s]) {
        id t = ((id (*)(id, SEL))objc_msgSend)(v, s);
        if ([t isKindOfClass:[NSString class]] && [(NSString *)t length]) return t;
    }
    // 兜底：扫一层子视图找 UILabel
    for (UIView *sub in v.subviews) {
        if ([sub isKindOfClass:[UILabel class]] && ((UILabel *)sub).text.length) {
            return ((UILabel *)sub).text;
        }
    }
    return nil;
}

static UILabel *WTE_LabelOfView(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) return (UILabel *)v;
    SEL s = NSSelectorFromString(@"titleLabel");
    if ([v respondsToSelector:s]) {
        id lbl = ((id (*)(id, SEL))objc_msgSend)(v, s);
        if ([lbl isKindOfClass:[UILabel class]]) return lbl;
    }
    for (UIView *sub in v.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) return (UILabel *)sub;
    }
    return nil;
}

// 类名特征分流：这是不是「按键」/「键盘容器」/「候选栏」/「工具栏」
static BOOL WTE_NameIsKey(NSString *cls) {
    if ([cls containsString:@"Keyboard"]) return NO;   // 排除容器
    if ([cls containsString:@"Key"])     return YES;
    if ([cls containsString:@"Button"] && [cls containsString:@"KB"]) return YES;
    return NO;
}
static BOOL WTE_NameIsKeyboard(NSString *cls) {
    if ([cls containsString:@"Keyboard"]) return YES;
    if ([cls containsString:@"InputView"]) return YES;
    if ([cls containsString:@"RootInput"]) return YES;
    if ([cls containsString:@"MainInput"]) return YES;
    return NO;
}
static BOOL WTE_NameIsCandidate(NSString *cls) {
    return [cls containsString:@"Candidate"];
}
static BOOL WTE_NameIsBar(NSString *cls) {
    if ([cls containsString:@"ToolBar"]) return YES;
    if ([cls containsString:@"TopBar"]) return YES;
    if ([cls containsString:@"Arrange"]) return YES;
    if ([cls containsString:@"Panel"]) return YES;
    return NO;
}

static WTEKeyKind WTE_KeyKindForView(UIView *v) {
    NSString *cls = NSStringFromClass([v class]);
    if ([cls containsString:@"Return"] || [cls containsString:@"Sec"] || [cls containsString:@"Backspace"]) {
        return WTEKeyKindFuncRight;
    }

    NSString *text = WTE_TextOfView(v);
    if (text.length == 0) return WTEKeyKindLetter;

    if ([text isEqualToString:@" "] || [text containsString:@"空格"]) return WTEKeyKindSpace;

    if (text.length <= 3 &&
        [text rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound) {
        return WTEKeyKindDigit;
    }
    NSArray *leftKeys = @[@"⇧", @"⇪", @"#+=", @"123", @"ABC", @"中", @"英", @"中英"];
    if ([leftKeys containsObject:text]) return WTEKeyKindFuncLeft;

    if ([text isEqualToString:@"⌫"] || [text isEqualToString:@"⌦"] ||
        [text containsString:@"换行"] || [text isEqualToString:@"return"] ||
        [text containsString:@"发送"] || [text containsString:@"完成"]) {
        return WTEKeyKindFuncRight;
    }
    return WTEKeyKindLetter;
}

static UIColor *WTE_ColorForKeyKind(WTEKeyKind kind, WTEConfig *c) {
    switch (kind) {
        case WTEKeyKindLetter:    return c.keyLetterBg;
        case WTEKeyKindDigit:     return c.keyDigitBg;
        case WTEKeyKindFuncLeft:  return c.keyFuncLeftBg;
        case WTEKeyKindFuncRight: return c.keyFuncRightBg;
        case WTEKeyKindSpace:     return c.keySpaceBg;
        default:                  return nil;
    }
}

static UIColor *WTE_GradientColorForLetter(unichar ch, WTEConfig *c) {
    if ([c.letterColorMap isKindOfClass:[NSDictionary class]]) {
        NSString *k = [[NSString stringWithFormat:@"%C", ch] lowercaseString];
        id hex = c.letterColorMap[k] ?: c.letterColorMap[[k uppercaseString]];
        if (hex) {
            UIColor *col = WTE_ColorFromHex(hex);
            if (col) return col;
        }
    }
    if (!c.letterGradientEnabled) return nil;
    double t = -1;
    if (ch >= 'a' && ch <= 'z') t = (double)(ch - 'a') / 25.0;
    else if (ch >= 'A' && ch <= 'Z') t = (double)(ch - 'A') / 25.0;
    else if (ch >= '0' && ch <= '9') t = (double)(ch - '0') / 9.0;
    if (t < 0) return nil;
    return [WTEConfig interpolateFrom:c.letterGradientFrom to:c.letterGradientTo t:t];
}

@implementation WTEConfig (Gradient)
+ (UIColor *)interpolateFrom:(UIColor *)a to:(UIColor *)b t:(double)t {
    if (!a) a = [UIColor clearColor];
    if (!b) b = [UIColor clearColor];
    CGFloat r1 = 0, g1 = 0, b1 = 0, a1 = 1;
    CGFloat r2 = 0, g2 = 0, b2 = 0, a2 = 1;
    [a getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    [b getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
    t = MAX(0.0, MIN(1.0, t));
    return [UIColor colorWithRed:r1 + (r2 - r1) * t
                           green:g1 + (g2 - g1) * t
                            blue:b1 + (b2 - b1) * t
                           alpha:a1 + (a2 - a1) * t];
}
@end

#pragma mark - ========== 视图树重排辅助 ==========

@implementation UIView (WTEEnhance)
- (void)_wte_relayoutTree {
    [self setNeedsLayout];
    for (UIView *sub in self.subviews) [sub _wte_relayoutTree];
}
@end

#pragma mark - ========== 核心：把配置应用到单个视图 ==========

static void WTE_ApplyKeyboardBg(UIView *self, WTEConfig *c) {
    BOOL transparent = c.keyboardTransparent || [c.bgMode isEqualToString:@"transparent"];
    BOOL imageBg     = c.bgEnabled && [c.bgMode isEqualToString:@"image"] && c.bgImage;
    BOOL solidBg     = c.bgEnabled && !transparent && !imageBg;

    // v1.7.0：不再往键盘视图里 insertSubview。
    // 之前是在 -layoutSubviews 内部插一个背景子视图，等于在布局途中改视图树，
    // UIKit 会异常/死循环 → 整个输入法崩溃。
    // 现在全部走图层：背景色用 backgroundColor，背景图用 layer.contents，零视图树改动。
    CALayer *layer = self.layer;

    if (imageBg) {
        layer.contents = (__bridge id)c.bgImage.CGImage;
        layer.contentsGravity = kCAGravityResizeAspectFill;
        layer.contentsScale = c.bgImage.scale > 0 ? c.bgImage.scale : [UIScreen mainScreen].scale;
        layer.masksToBounds = YES;
        ((UIView *)self).backgroundColor = [UIColor clearColor];
        self.opaque = NO;
    } else {
        if (layer.contents) layer.contents = nil;
        if (solidBg) {
            self.backgroundColor = [c.bgColor colorWithAlphaComponent:c.bgAlpha];
        } else if (transparent) {
            self.backgroundColor = [UIColor clearColor];
            self.opaque = NO;
            if ([self respondsToSelector:NSSelectorFromString(@"setBackgroundEffects:")]) {
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"setBackgroundEffects:"), nil);
                } @catch (__unused NSException *e) {}
            }
        }
    }

    // 键盘整体位移：只在目标值变化时才写 transform，
    // 否则每次布局都改 transform 会反复触发父视图重新布局（CPU 打满 + 抖动）
    CGFloat want = (CGFloat)c.kbOffset;
    CGFloat cur  = self.transform.ty;
    if (fabs(cur - want) > 0.5) {
        self.transform = want == 0.0 ? CGAffineTransformIdentity
                                     : CGAffineTransformMakeTranslation(0, want);
    }
}

static void WTE_ApplyKeyAppearance(UIView *self, WTEConfig *c) {
    WTEKeyKind kind = WTE_KeyKindForView(self);

    // 形状
    if ([c.keyShape isEqualToString:@"circle"]) {
        self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) / 2.0;
        self.layer.masksToBounds = YES;
    } else if ([c.keyShape isEqualToString:@"square"]) {
        self.layer.cornerRadius = 0;
        self.layer.masksToBounds = YES;
    } else if ([c.keyShape isEqualToString:@"bevel"]) {
        self.layer.cornerRadius = c.keyCornerRadius;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.35] CGColor];
    } else {
        self.layer.cornerRadius = c.keyCornerRadius;
        self.layer.masksToBounds = YES;
    }

    if (c.keyCap3D) {
        self.layer.shadowColor   = [[UIColor blackColor] CGColor];
        self.layer.shadowOffset  = CGSizeMake(0, 1.5);
        self.layer.shadowOpacity = 0.30;
        self.layer.shadowRadius  = 1.0;
        self.layer.masksToBounds = NO;
        self.layer.shadowPath    = [[UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                             cornerRadius:self.layer.cornerRadius] CGPath];
    } else {
        self.layer.shadowOpacity = 0.0;
    }

    // 底色
    if (c.keyColorEnabled) {
        UIColor *col = WTE_ColorForKeyKind(kind, c);
        if (col) {
            self.backgroundColor = col;
            // 有些按键底色画在子视图上，一并处理一层
            for (UIView *sub in self.subviews) {
                if (![sub isKindOfClass:[UILabel class]] && sub.subviews.count == 0 &&
                    sub.bounds.size.height >= self.bounds.size.height * 0.8 &&
                    sub.bounds.size.width  >= self.bounds.size.width  * 0.8) {
                    sub.backgroundColor = col;
                }
            }
        }
    }

    UILabel *lbl = WTE_LabelOfView(self);

    // 文字颜色
    if (c.keyColorEnabled && c.keyTextColor && lbl) {
        lbl.textColor = c.keyTextColor;
    }

    // 字母渐变
    if ((c.letterGradientEnabled || [c.letterColorMap count] > 0) && lbl) {
        NSString *txt = lbl.text;
        if (txt.length >= 1) {
            UIColor *gc = WTE_GradientColorForLetter([txt characterAtIndex:0], c);
            if (gc) lbl.textColor = gc;
        }
    }

    // 按下高亮色
    if (c.keyColorEnabled && c.keyHighlightColor) {
        SEL s = NSSelectorFromString(@"setHighlightedBackgroundColor:");
        if ([self respondsToSelector:s]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, s, c.keyHighlightColor);
        }
    }
}

static void WTE_ApplyBarOrCandidate(UIView *self, WTEConfig *c) {
    if (c.keyboardTransparent || [c.bgMode isEqualToString:@"transparent"]) {
        self.backgroundColor = [UIColor clearColor];
    }
    if (c.keyColorEnabled && c.keyTextColor) {
        if ([self isKindOfClass:[UILabel class]]) ((UILabel *)self).textColor = c.keyTextColor;
        else {
            UILabel *l = WTE_LabelOfView(self);
            if (l) l.textColor = c.keyTextColor;
        }
    }
}

// 统一入口：按类名特征分派
static void WTE_ApplyToView(UIView *self) {
    WTEConfig *c = gConfig;
    if (!c || !c.enabled) return;

    NSString *cls = NSStringFromClass([self class]);
    if (cls.length == 0) return;

    if (WTE_NameIsKeyboard(cls)) {
        WTE_ApplyKeyboardBg(self, c);
    } else if (WTE_NameIsCandidate(cls) || WTE_NameIsBar(cls)) {
        WTE_ApplyBarOrCandidate(self, c);
    } else if (WTE_NameIsKey(cls)) {
        WTE_ApplyKeyAppearance(self, c);
    }
}

#pragma mark - ========== 动态 hook（白名单 + 崩溃防护） ==========
//
// 历史教训（v1.6.0 崩溃复盘）：
//   1) 早期用 objc_getClassList 全量扫描 + 关键字匹配（Key / Keyboard / InputView），
//      把 UIKeyboardLayoutStar、UIInputView 等【系统键盘类】也 hook 了 ——
//      微信输入法宿主的是系统键盘视图树，改它们 = 直接崩，被 iOS 回退到苹果原生键盘。
//   2) WTE_HookClassForLayout 没有「本类是否自己实现该方法」的守卫：
//      class_getInstanceMethod 会沿继承链拿到父类的 IMP，若父类已被 hook，
//      存下来的 prev 就是我们自己的 replacement → 调用时无限自递归。
//   3) 在 -layoutSubviews 里 insertSubview 插背景视图 → 布局期改视图树 → UIKit 异常。
// 对应修法：
//   · 白名单固定类名，只碰微信输入法自己的 WB* 视图类，绝不碰系统类
//   · 加「本类自己实现 layoutSubviews」守卫
//   · orig 沿继承链查找（子类未被 hook 时也能正确回调父类原始实现）
//   · 不再插任何子视图，背景改成直接设置 backgroundColor / layer.contents
//   · 全局重入锁 gWTEBusy + @try/@catch 兜底

static NSMutableDictionary *gOrigLayout;    // 类名 -> NSValue(原始 IMP)
static NSMutableArray      *gHookedClasses;
static BOOL gWTEBusy = NO;

// —— 目标类白名单 ——
// 全部来自键盘进程实际诊断报告（diag.txt 里扫出来的真实类名）
static NSArray<NSString *> *WTE_TargetClassNames(void) {
    return @[
        // 键盘容器
        @"WBKeyboardView", @"WBKeyboardRootView", @"WBRootInputView", @"WBMainInputView",
        // 按键
        @"WBKeyView", @"WBKeyViewButton", @"WBKeyButton",
        @"WBNewlineKeyView", @"WBReturnKeyView", @"WBSecKeyboardKeyView",
        @"WBRuleKeyView", @"WBSpaceKeyView",
        // 候选栏 / 工具栏
        @"WBCandidateView", @"WBCandidateBarView",
        @"WBTopBar", @"WBArrangeView", @"WBCustomToolBarView",
        @"WBToolBarButton", @"WBFunctionToolBar", @"WBPlusEntranceView",
    ];
}

// 类【自己】是否实现了该方法（不沿继承链找）—— 防自递归的关键守卫
static BOOL WTE_ClassImplements(Class c, SEL sel) {
    if (!c) return NO;
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { found = YES; break; }
    }
    if (list) free(list);
    return found;
}

// 沿继承链找被 hook 时保存的原始 IMP
// （子类没被 hook 时会走到父类的原始实现，避免「orig 为 nil → 布局被跳过」）
static IMP WTE_OrigLayoutIMP(Class cls) {
    Class k = cls;
    while (k) {
        NSString *n = NSStringFromClass(k);
        if (n.length) {
            NSValue *v = gOrigLayout[n];
            if (v) return (IMP)v.pointerValue;
        }
        k = class_getSuperclass(k);
    }
    return NULL;
}

static void WTE_ApplySubtree(UIView *root, int depth);   // 前置声明

static void WTE_LayoutReplacement(UIView *self, SEL _cmd) {
    // 1) 先跑原始布局（保证 bounds 已是最终值）
    IMP orig = WTE_OrigLayoutIMP([self class]);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);

    // 2) 再做美化。任何异常都不允许外泄，否则整个输入法崩掉
    if (gWTEBusy) return;
    WTEConfig *c = gConfig;
    if (!c || !c.enabled) return;

    gWTEBusy = YES;
    @try {
        NSString *cls = NSStringFromClass([self class]);
        if (WTE_NameIsKeyboard(cls)) {
            WTE_ApplyToView(self);        // 键盘背景（只设颜色 / layer，不插子视图）
            WTE_ApplySubtree(self, 0);    // 子树的按键、候选栏、工具栏
        } else {
            WTE_ApplyToView(self);
        }
    } @catch (__unused NSException *e) {}
    gWTEBusy = NO;

#if WTE_LOG_ENABLE
    NSString *cls2 = NSStringFromClass([self class]);
    if (gLayoutSeen && gLayoutSeen.count < 80 && ![gLayoutSeen containsObject:cls2]) {
        [gLayoutSeen addObject:cls2];
        WTE_Diag(@"live: %@ text=%@ frame=%@", cls2,
                 WTE_TextOfView(self) ?: @"-", NSStringFromCGRect(self.frame));
    }
#endif
}

// 递归给子树里的键盘元素上色
static void WTE_ApplySubtree(UIView *root, int depth) {
    if (!root || depth > 8) return;
    for (UIView *sub in [root.subviews copy]) {
        @try {
            NSString *cls = NSStringFromClass([sub class]);
            if (WTE_NameIsKeyboard(cls) || WTE_NameIsKey(cls) ||
                WTE_NameIsCandidate(cls) || WTE_NameIsBar(cls)) {
                WTE_ApplyToView(sub);
            }
        } @catch (__unused NSException *e) {}
        WTE_ApplySubtree(sub, depth + 1);
    }
}

static void WTE_HookClass(Class c) {
    if (!c) return;
    NSString *name = NSStringFromClass(c);
    if (!name.length) return;
    if (!gHookedClasses) gHookedClasses = [NSMutableArray new];
    if ([gHookedClasses containsObject:name]) return;
    [gHookedClasses addObject:name];

    SEL sel = @selector(layoutSubviews);
    if (!WTE_ClassImplements(c, sel)) {
        // 自己不实现 → 它的实例会走到父类被 hook 的实现，不需要（也不能）重复 hook
        return;
    }
    IMP prev = NULL;
    MSHookMessageEx(c, sel, (IMP)&WTE_LayoutReplacement, &prev);
    if (prev) gOrigLayout[name] = [NSValue valueWithPointer:prev];
}

// 白名单安装；若白名单一个都没命中（输入法版本变化），
// 才退回「窄范围扫描」—— 只认 WB 前缀且名字含键盘语义的 UIView 类。
static int WTE_InstallHooks(void) {
    int hooked = 0;
    for (NSString *n in WTE_TargetClassNames()) {
        Class c = NSClassFromString(n);
        if (!c) { WTE_Diag(@"  [miss] %@ 不存在", n); continue; }
        if (![c isSubclassOfClass:[UIView class]]) { WTE_Diag(@"  [skip] %@ 非 UIView", n); continue; }
        WTE_HookClass(c);
        hooked++;
        WTE_Diag(@"  [ok]   %@  ownLayoutSubviews=%d", n,
                 WTE_ClassImplements(c, @selector(layoutSubviews)));
    }

    if (hooked == 0) {
        WTE_Diag(@"!!! 白名单全部未命中，退回窄范围扫描（只认 WB 前缀 + 键盘语义）");
        int count = objc_getClassList(NULL, 0);
        if (count > 0) {
            Class *classes = (Class *)malloc(sizeof(Class) * count);
            if (classes) {
                count = objc_getClassList(classes, count);
                for (int i = 0; i < count; i++) {
                    Class c = classes[i];
                    NSString *n = NSStringFromClass(c);
                    if (!n.length || ![n hasPrefix:@"WB"]) continue;
                    if ([n hasPrefix:@"WBBookVideo"]) continue;   // 书城/视频无关业务
                    BOOL isView = NO;
                    Class s = c;
                    while (s) { if (s == [UIView class]) { isView = YES; break; } s = class_getSuperclass(s); }
                    if (!isView) continue;
                    // 仍然只认键盘语义，避免误碰业务类
                    if (!([n containsString:@"Key"] || [n containsString:@"Keyboard"] ||
                          [n containsString:@"Candidate"] || [n containsString:@"ToolBar"] ||
                          [n containsString:@"TopBar"] || [n containsString:@"InputView"])) continue;
                    WTE_HookClass(c);
                    hooked++;
                    WTE_Diag(@"  [fallback] %@", n);
                }
                free(classes);
            }
        }
    }
    return hooked;
}

#pragma mark - ========== SpringBoard 偏好中继 ==========
//
// 1.7.0 实测定论：键盘扩展沙盒里所有偏好通道全部不可读
//   （连 /var/mobile/Library/Preferences 都读不到，cfprefsd 也会把外部 suite
//     重定向到扩展自己的容器，所以 NSUserDefaults 兜底也拿不到）。
// 而 tweak 自己【能写】进键盘容器（diag.txt 写成功了）—— 问题只在「谁把配置送进来」。
// 面板（Preferences 进程）不一定写得进别的 App 的容器，但 SpringBoard 没有沙盒限制：
//   读全局偏好 ✅  +  写任意 App 容器 ✅
// 所以让 SpringBoard 当中继：读全局偏好 → 铺到微信输入法所有相关容器。
// 装完插件注销一次，配置就已经在键盘容器里了，键盘第一次弹出就能读到。

static NSString *WTE_RelayPushConfig(void) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];

        NSDictionary *src = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist"];
        if (![src isKindOfClass:[NSDictionary class]] || src.count == 0) {
            src = [NSDictionary dictionaryWithContentsOfFile:
                @"/var/jb/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist"];
        }
        if (![src isKindOfClass:[NSDictionary class]] || src.count == 0) {
            return @"全局偏好文件不存在或为空（还没在面板里设置过）→ 未铺配置。\n"
                    "去面板里改任意一项设置再注销，或点「同步配置到键盘」。";
        }

        NSMutableArray *bases = [NSMutableArray array];
        for (NSString *root in @[@"/var/mobile/Containers/Data/PluginKitPlugin",
                                 @"/var/mobile/Containers/Data/Application",
                                 @"/var/mobile/Containers/Shared/AppGroup"]) {
            for (NSString *sub in [fm contentsOfDirectoryAtPath:root error:nil]) {
                NSString *base = [root stringByAppendingPathComponent:sub];
                NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:
                    [base stringByAppendingPathComponent:
                     @".com.apple.mobile_container_manager.metadata.plist"]];
                NSString *ident = m[@"MCMMetadataIdentifier"];
                if (![ident isKindOfClass:[NSString class]]) continue;
                NSString *low = [ident lowercaseString];
                if (![low containsString:@"wetype"] && ![low containsString:@"tencent"] &&
                    ![low containsString:@"wxkb"] && ![low containsString:@"xin.keyboard"] &&
                    ![low containsString:@"wechat"]) continue;
                [bases addObject:base];
            }
        }
        if (bases.count == 0) return @"没找到任何微信输入法相关容器";

        int ok = 0;
        for (NSString *base in bases) {
            for (NSString *rel in @[@"Documents/WeTypeEnhance/config.plist",
                                    @"Library/Preferences/com.colorblack.wetypeenhance.plist"]) {
                NSString *dest = [base stringByAppendingPathComponent:rel];
                NSString *d = [dest stringByDeletingLastPathComponent];
                if (![fm fileExistsAtPath:d]) {
                    [fm createDirectoryAtPath:d withIntermediateDirectories:YES
                                      attributes:nil error:nil];
                }
                if ([src writeToFile:dest atomically:YES]) ok++;
            }
        }
        NSString *sum = [NSString stringWithFormat:
            @"已把配置铺到 %d 处 / %lu 个容器", ok, (unsigned long)bases.count];
        NSLog(@"[WeTypeEnhance][relay] %@", sum);
        return sum;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"中继异常: %@", e];
    }
}

static void WTE_RelayNotifyCallback(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    WTE_RelayPushConfig();
}

#pragma mark - ========== 初始化 ==========

__attribute__((constructor))
static void WTE_Init(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleID = [bundle bundleIdentifier] ?: @"";
    NSString *execName = [[NSProcessInfo processInfo] processName] ?: @"";

    // —— 阳性对照：SpringBoard ——
    // 在 SpringBoard 里只写一个标记文件就退出，用来验证「注入机制 + 文件写入通道」
    // 是否正常。若这个文件都没有，说明注入层/写文件通道有问题，与微信输入法无关。
    if ([bundleID isEqualToString:@"com.apple.springboard"]) {
        NSString *dir = @"/var/mobile/Media/WeTypeEnhance";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];

        NSMutableString *msg = [NSMutableString stringWithFormat:
            @"SpringBoard 注入成功（阳性对照）\npid=%d\nhome=%@\ntime=%@\n",
            getpid(), NSHomeDirectory(), [NSDate date]];

        // —— 枚举系统里微信输入法 App 与其扩展的真实标识 ——
        // 这是把「过滤规则匹配不上」变成「拿到真实 Bundle ID / 进程名」的关键。
        @try {
            Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
            id ws = ((id (*)(id, SEL))objc_msgSend)(wsClass, NSSelectorFromString(@"defaultWorkspace"));
            NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, NSSelectorFromString(@"installedApplications"));
            [msg appendFormat:@"\n===== 系统内 tencent/wetype 相关应用 %lu 个 =====\n", (unsigned long)apps.count];
            for (id app in apps) {
                @try {
                    NSString *bid = nil;
                    @try { bid = [app valueForKey:@"applicationIdentifier"]; } @catch (__unused NSException *e) {}
                    if (![bid isKindOfClass:[NSString class]]) continue;
                    NSString *low = [bid lowercaseString];
                    if (![low containsString:@"tencent"] && ![low containsString:@"wetype"]) continue;

                    NSBundle *b = nil;
                    @try {
                        NSURL *url = [app valueForKey:@"bundleURL"];
                        if ([url isKindOfClass:[NSURL class]]) b = [NSBundle bundleWithURL:url];
                    } @catch (__unused NSException *e) {}
                    [msg appendFormat:@"\nAPP  %@\n", bid];
                    if (b) {
                        [msg appendFormat:@"  版本=%@ 显示名=%@\n",
                            b.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
                            b.infoDictionary[@"CFBundleDisplayName"] ?: @"?"];
                        [msg appendFormat:@"  路径=%@\n", b.bundlePath];
                    }
                    NSArray *plugins = nil;
                    @try { plugins = [app valueForKey:@"plugInKitPlugins"]; } @catch (__unused NSException *e) {}
                    [msg appendFormat:@"  扩展数=%lu\n", (unsigned long)plugins.count];
                    for (id plugin in plugins) {
                        [msg appendFormat:@"  [扩展] %@\n", plugin];   // description 通常带全部键
                        NSURL *purl = nil;
                        for (NSString *k in @[@"pluginBundleURL", @"bundleURL", @"URL"]) {
                            @try {
                                id v = [plugin valueForKey:k];
                                if ([v isKindOfClass:[NSURL class]]) { purl = v; break; }
                            } @catch (__unused NSException *e) {}
                        }
                        if (purl) {
                            NSBundle *pb = [NSBundle bundleWithURL:purl];
                            [msg appendFormat:@"    BundleID=%@ Exec=%@\n",
                                pb.infoDictionary[@"CFBundleIdentifier"] ?: @"?",
                                pb.infoDictionary[@"CFBundleExecutable"] ?: @"?"];
                        }
                    }
                } @catch (NSException *e) {
                    [msg appendFormat:@"  遍历异常: %@\n", e];
                }
            }
        } @catch (NSException *e) {
            [msg appendFormat:@"Workspace 枚举失败: %@\n", e];
        }

        // —— 偏好中继：全局偏好 → 微信输入法所有相关容器 ——
        // SpringBoard 无沙盒限制，是「面板写不进键盘容器」时的保底通道。
        [msg appendFormat:@"\n===== 偏好中继 =====\n%@\n", WTE_RelayPushConfig() ?: @"(无返回)"];

        // 之后每次面板改设置都会发 Darwin 通知，SpringBoard 收到就重新铺一遍
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        WTE_RelayNotifyCallback,
                                        (__bridge CFStringRef)kPrefChangedNotify,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        BOOL ok1 = [msg writeToFile:[dir stringByAppendingPathComponent:@"springboard.txt"]
                         atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *ownDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/WeTypeEnhance"];
        [[NSFileManager defaultManager] createDirectoryAtPath:ownDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        BOOL ok2 = [msg writeToFile:[ownDir stringByAppendingPathComponent:@"springboard.txt"]
                         atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[WeTypeEnhance] SpringBoard 对照写入 Media=%d container=%d", ok1, ok2);
        return;
    }

    // —— 进程白名单 ——
    // 过滤 plist 已放宽到「注入所有进程」，这里做严格门禁：
    // 只有看起来是微信输入法（或进程里已注册 WB* 类）才继续，其它进程直接返回。
    NSString *lower = [[NSString stringWithFormat:@"%@ %@", bundleID, execName] lowercaseString];
    BOOL isWeType = NO;
    for (NSString *kw in @[@"wetype", @"wxkb", @"xin.keyboard", @"wechatkb", @"wetype.keyboard"]) {
        if ([lower containsString:kw]) { isWeType = YES; break; }
    }
    if (!isWeType) {
        // 兜底：进程里已存在 WB 开头的类（微信输入法的类名前缀）
        for (NSString *cn in @[@"WBKeyboardView", @"WBKeyView", @"WBRootInputView", @"WBMainInputView"]) {
            if (NSClassFromString(cn)) { isWeType = YES; break; }
        }
    }
    if (!isWeType) return;

    gPrefQueue = dispatch_queue_create("com.colorblack.wetypeenhance.prefs", DISPATCH_QUEUE_SERIAL);
#if WTE_LOG_ENABLE
    gDiagQueue = dispatch_queue_create("com.colorblack.wetypeenhance.diag", DISPATCH_QUEUE_SERIAL);
    gLayoutSeen = [NSMutableSet new];
#endif
    gOrigLayout = [NSMutableDictionary new];

    WTE_ReloadConfig();

    WTE_Diag(@"================ WeTypeEnhance v1.7.1 ================");
    WTE_Diag(@"pid=%d bundle=%@ exec=%@ home=%@", getpid(), bundleID, execName, NSHomeDirectory());
    WTE_Diag(@"--- 偏好通道逐个探测 ---");
    for (NSString *p in WTE_PrefCandidates()) {
        if (![p isKindOfClass:[NSString class]]) continue;
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        WTE_Diag(@"  [%@] %@ keys=%d mtime=%@",
                 attr ? @"可读" : @"不可读", p, (int)d.count,
                 attr[NSFileModificationDate] ?: @"-");
    }
    WTE_Diag(@"--- 最终采用的来源 ---");
    WTE_Diag(@"  source = %@", gConfigDictPath ?: @"(无，说明所有通道都读不到)");
    WTE_Diag(@"--- 当前配置 ---");
    WTE_Diag(@"  enabled=%d bgEnabled=%d bgMode=%@ keyColorEnabled=%d skinEnabled=%d kbOffset=%.1f",
             gConfig.enabled, gConfig.bgEnabled, gConfig.bgMode,
             gConfig.keyColorEnabled, gConfig.skinEnabled, gConfig.kbOffset);

    // 立刻写一次：证明本进程确实注入了（不依赖 hook 成功）
    WTE_DiagFlush(@"init");

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    WTE_PrefsChangedCallback,
                                    (__bridge CFStringRef)kPrefChangedNotify,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // 白名单 hook（延迟到主线程，等 dyld 把输入法类都注册好）
    dispatch_async(dispatch_get_main_queue(), ^{
        int hooked = WTE_InstallHooks();
        WTE_Diag(@"=== 白名单命中并 hook %d 个类 ===", hooked);
        WTE_DiagFlush(@"hooks");
    });
}
