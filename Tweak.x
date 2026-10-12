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

static NSArray *WTE_PrefCandidates(void) {
    return @[
        @"/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist",
    ];
}

static NSString *WTE_PrefPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in WTE_PrefCandidates()) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return [WTE_PrefCandidates() firstObject];
}

id WTE_GetPref(NSString *key) {
    if (!key) return nil;
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:WTE_PrefPath()];
    id v = dict[key];
    if (v) return v;
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
    return [ud objectForKey:key];
}

void WTE_SetPref(NSString *key, id value) {
    if (!key) return;
    // 所有候选路径都写一份，读哪份都能读到
    for (NSString *path in WTE_PrefCandidates()) {
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
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:WTE_PrefPath()];
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
    gConfig = [WTEConfig loadConfig];
}

static void WTE_PrefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(gPrefQueue, ^{
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

#pragma mark - ========== 背景图铺满 ==========

@interface WTEBackgroundView : UIImageView
@end
@implementation WTEBackgroundView
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.image || !self.superview) return;
    CGSize bs = self.superview.bounds.size;
    CGSize is = self.image.size;
    if (bs.width <= 0 || bs.height <= 0 || is.width <= 0 || is.height <= 0) return;
    CGFloat scale = MAX(bs.width / is.width, bs.height / is.height);
    CGFloat w = is.width * scale, h = is.height * scale;
    self.frame = CGRectMake((bs.width - w) / 2.0, (bs.height - h) / 2.0, w, h);
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

static const void *kWTEKBGKey   = &kWTEKBGKey;    // 键盘背景层
static const void *kWTEStyledKey = &kWTEStyledKey; // 本轮是否已处理
static Class gKBRootClass = Nil;                  // 记录最外层的键盘容器类

static void WTE_ApplyKeyboardBg(UIView *self, WTEConfig *c) {
    UIView *bg = objc_getAssociatedObject(self, kWTEKBGKey);
    BOOL needBg = c.bgEnabled || c.keyboardTransparent ||
                  [c.bgMode isEqualToString:@"transparent"] || [c.bgMode isEqualToString:@"image"];
    if (!needBg) {
        if (bg) {
            [bg removeFromSuperview];
            objc_setAssociatedObject(self, kWTEKBGKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else {
        if (c.keyboardTransparent || [c.bgMode isEqualToString:@"transparent"]) {
            self.backgroundColor = [UIColor clearColor];
            self.opaque = NO;
            if ([self respondsToSelector:NSSelectorFromString(@"setBackgroundEffects:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"setBackgroundEffects:"), nil);
            }
        }
        if (!bg) {
            bg = [[UIView alloc] initWithFrame:self.bounds];
            bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            bg.userInteractionEnabled = NO;
            [self insertSubview:bg atIndex:0];
            objc_setAssociatedObject(self, kWTEKBGKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        bg.frame = self.bounds;
        for (UIView *sub in [bg.subviews copy]) {
            if ([sub isKindOfClass:[WTEBackgroundView class]]) [sub removeFromSuperview];
        }
        if ([c.bgMode isEqualToString:@"image"] && c.bgImage) {
            bg.backgroundColor = [UIColor clearColor];
            WTEBackgroundView *iv = [[WTEBackgroundView alloc] initWithImage:c.bgImage];
            iv.contentMode = UIViewContentModeScaleAspectFill;
            iv.clipsToBounds = YES;
            iv.userInteractionEnabled = NO;
            iv.frame = bg.bounds;
            [bg addSubview:iv];
        } else if ([c.bgMode isEqualToString:@"transparent"] || c.keyboardTransparent) {
            bg.backgroundColor = [UIColor clearColor];
        } else {
            bg.backgroundColor = [c.bgColor colorWithAlphaComponent:c.bgAlpha];
        }
    }

    // 键盘整体位移
    if (c.kbOffset != 0.0) {
        self.transform = CGAffineTransformMakeTranslation(0, c.kbOffset);
    } else if (self.transform.ty != 0 || self.transform.tx != 0) {
        self.transform = CGAffineTransformIdentity;
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

#pragma mark - ========== 动态 hook ==========

static NSMutableDictionary *gOrigLayout;   // Class -> NSValue(IMP)
static NSMutableDictionary *gOrigMove;     // Class -> NSValue(IMP)
static NSMutableArray *gHookedClasses;

static void WTE_LayoutReplacement(UIView *self, SEL _cmd) {
    // 防止同一对象在 orig 链中被重复处理
    if (!objc_getAssociatedObject(self, kWTEStyledKey)) {
        @try {
            objc_setAssociatedObject(self, kWTEStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            WTE_ApplyToView(self);
            objc_setAssociatedObject(self, kWTEStyledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } @catch (__unused NSException *e) {}
    }

    NSValue *v = gOrigLayout[NSStringFromClass([self class])];
    if (v) ((void (*)(id, SEL))v.pointerValue)(self, _cmd);
}

static void WTE_MoveReplacement(UIView *self, SEL _cmd) {
    NSValue *v = gOrigMove[NSStringFromClass([self class])];
    if (v) ((void (*)(id, SEL))v.pointerValue)(self, _cmd);

    @try {
        if (!objc_getAssociatedObject(self, kWTEStyledKey)) {
            objc_setAssociatedObject(self, kWTEStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            WTE_ApplyToView(self);
            objc_setAssociatedObject(self, kWTEStyledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } @catch (__unused NSException *e) {}

    // 记录布局期见到的类（诊断用）
#if WTE_LOG_ENABLE
    NSString *cls = NSStringFromClass([self class]);
    if (gLayoutSeen.count < 120 && ![gLayoutSeen containsObject:cls]) {
        [gLayoutSeen addObject:cls];
        NSString *txt = WTE_TextOfView(self);
        WTE_Diag(@"layered: %@ text=%@ frame=%@", cls, txt ?: @"-", NSStringFromCGRect(self.frame));
    }
#endif
}

static void WTE_HookClassForLayout(Class c) {
    if (!c) return;
    NSString *name = NSStringFromClass(c);
    if (!name.length) return;
    if (gHookedClasses && [gHookedClasses containsObject:name]) return;

    SEL layoutSel = @selector(layoutSubviews);
    Method m = class_getInstanceMethod(c, layoutSel);
    if (!m) return;

    IMP prev = NULL;
    MSHookMessageEx(c, layoutSel, (IMP)&WTE_LayoutReplacement, (IMP *)&prev);
    if (prev) gOrigLayout[name] = [NSValue valueWithPointer:prev];

    SEL moveSel = @selector(didMoveToWindow);
    Method m2 = class_getInstanceMethod(c, moveSel);
    if (m2) {
        IMP prev2 = NULL;
        MSHookMessageEx(c, moveSel, (IMP)&WTE_MoveReplacement, (IMP *)&prev2);
        if (prev2) gOrigMove[name] = [NSValue valueWithPointer:prev2];
    }

    if (!gHookedClasses) gHookedClasses = [NSMutableArray new];
    [gHookedClasses addObject:name];
}

// 类名是否符合 hook 目标特征
static BOOL WTE_NameLooksInteresting(NSString *n) {
    if (!n.length) return NO;
    if ([n hasPrefix:@"UI"] && ![n containsString:@"Keyboard"]) return NO;   // 少动系统 UI 类
    if ([n containsString:@"Keyboard"]) return YES;
    if ([n containsString:@"Key"]) return YES;
    if ([n containsString:@"Candidate"]) return YES;
    if ([n containsString:@"ToolBar"]) return YES;
    if ([n containsString:@"TopBar"]) return YES;
    if ([n containsString:@"Arrange"]) return YES;
    if ([n containsString:@"InputView"]) return YES;
    if ([n containsString:@"RootInput"]) return YES;
    if ([n containsString:@"MainInput"]) return YES;
    if ([n hasPrefix:@"WB"]) return YES;
    if ([n hasPrefix:@"Tx"]) return YES;
    return NO;
}

static int WTE_ScanAndHookClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return 0;
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    if (!classes) return 0;
    count = objc_getClassList(classes, count);

    NSMutableArray *candidates = [NSMutableArray array];
    NSMutableArray *allNames = [NSMutableArray array];

    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        NSString *n = NSStringFromClass(c);
        if (!n.length) continue;

        // 只关心 UIView 体系
        BOOL isView = NO;
        Class s = c;
        while (s) {
            if (s == [UIView class]) { isView = YES; break; }
            s = class_getSuperclass(s);
        }
        if (!isView) continue;

        if (WTE_NameLooksInteresting(n)) {
            [candidates addObject:n];
            [allNames addObject:n];
        }
    }
    free(classes);

    [allNames sortUsingSelector:@selector(compare:)];
    WTE_Diag(@"=== 候选类扫描：共 %d 个 UIView 类命中特征 ===", (int)allNames.count);
    for (NSString *n in allNames) WTE_Diag(@"  class %@", n);

    for (NSString *n in candidates) {
        WTE_HookClassForLayout(NSClassFromString(n));
    }
    return (int)candidates.count;
}

#pragma mark - ========== 初始化 ==========

__attribute__((constructor))
static void WTE_Init(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleID = [bundle bundleIdentifier] ?: @"";
    NSString *execName = [[NSProcessInfo processInfo] processName] ?: @"";

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
    gOrigMove = [NSMutableDictionary new];

    WTE_ReloadConfig();

    WTE_Diag(@"================ WeTypeEnhance v1.4.0 ================");
    WTE_Diag(@"pid=%d bundle=%@ exec=%@ home=%@", getpid(), bundleID, execName, NSHomeDirectory());
    WTE_Diag(@"--- 偏好可读性检查 ---");
    for (NSString *p in WTE_PrefCandidates()) {
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:p];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        WTE_Diag(@"  %@ exists=%d keys=%d", p, exists, (int)d.count);
    }
    WTE_Diag(@"--- 当前配置 ---");
    WTE_Diag(@"  enabled=%d bgEnabled=%d bgMode=%@ keyColorEnabled=%d skinEnabled=%d kbOffset=%.1f",
             gConfig.enabled, gConfig.bgEnabled, gConfig.bgMode,
             gConfig.keyColorEnabled, gConfig.skinEnabled, gConfig.kbOffset);
    WTE_Diag(@"  raw prefs = %@", [NSDictionary dictionaryWithContentsOfFile:WTE_PrefPath()]);
    WTE_Diag(@"--- App Group 容器 ---");
    for (NSString *d in WTE_DiagDirs()) WTE_Diag(@"  dir %@", d);

    // 立刻写一次：证明本进程确实注入了（不依赖类扫描成功）
    WTE_DiagFlush(@"init");

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    WTE_PrefsChangedCallback,
                                    (__bridge CFStringRef)kPrefChangedNotify,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // 类扫描 + 动态 hook（延迟到主线程，等 dyld 把输入法类都注册好）
    dispatch_async(dispatch_get_main_queue(), ^{
        int hooked = WTE_ScanAndHookClasses();
        WTE_Diag(@"=== 已 hook %d 个类 ===", hooked);
        WTE_DiagFlush(@"scan");
    });
}
