// WeTypeEnhance Tweak.x
// 微信输入法增强 —— 功能对等移植自「原生输入法增强 KBTheme」，目标改为微信输入法
//
// 目标 Bundle:  com.tencent.wetype.keyboard / com.tencent.xin.keyboard / com.tencent.wetype
// 目标进程:     wxkb_plugin / wxkb_plugin.appex
// 可 hook 类:   WBKeyboardView WBKeyView WBReturnKeyView WBSecKeyboardKeyView
//               WBRuleKeyView WBCandidateView WBArrangeView WBTopBar
//               WBToolBarButton WBButton WBRootInputView WBMainInputView WBT26Panel
//
// 包名: com.colorblack.wetypeenhance

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "WeTypeEnhanceCommon.h"

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
        if ([color getWhite:&w alpha:&wa]) {
            r = g = b = w; a = wa;
        } else {
            return @"#000000";
        }
    }
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X",
            (int)round(r * 255), (int)round(g * 255), (int)round(b * 255), (int)round(a * 255)];
}

// 兼容 rootless / roothide / 纯越狱 三种路径
static NSString *WTE_PrefPath(void) {
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
    NSString *path = WTE_PrefPath();
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    id v = dict[key];
    if (v) return v;
    // 回退到 NSUserDefaults（部分越狱环境 plist 缓存行为不同）
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
    return [ud objectForKey:key];
}

void WTE_SetPref(NSString *key, id value) {
    if (!key) return;
    NSString *path = WTE_PrefPath();
    NSMutableDictionary *dict = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    if (!dict) dict = [NSMutableDictionary dictionary];
    if (value == nil) {
        [dict removeObjectForKey:key];
    } else {
        dict[key] = value;
    }
    [dict writeToFile:path atomically:YES];
    // 同步一份到 NSUserDefaults，保证面板与 tweak 读到一致
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

#pragma mark - ========== 全局配置快照 ==========

// 每次读到偏好变更就重建，避免在 layout 热路径里反复读磁盘
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

// 颜色插值（分类声明放在使用之前）
@interface WTEConfig (Gradient)
+ (UIColor *)interpolateFrom:(UIColor *)a to:(UIColor *)b t:(double)t;
@end

@implementation WTEConfig

+ (instancetype)load {
    WTEConfig *c = [WTEConfig new];

    c.enabled = WTE_BoolPref(kKeyEnabled, YES);
    if (!c.enabled) return c;

    // 1. 键盘背景
    c.bgEnabled           = WTE_BoolPref(kKeyBgEnabled, NO);
    c.bgMode              = WTE_StringPref(kKeyBgMode, @"solid");
    c.bgColor             = WTE_ColorFromHex(WTE_StringPref(kKeyBgColor, @"#1C1C1E")) ?: [UIColor clearColor];
    c.bgAlpha             = WTE_DoublePref(kKeyBgAlpha, 1.0);
    c.keyboardTransparent = WTE_BoolPref(kKeyKeyboardTransparent, NO);

    // 背景图片：优先读沙盒文件，其次读内联 base64/NSData
    NSString *imgPath = @"/var/mobile/Library/Application Support/WeTypeEnhance/bg.png";
    NSString *imgPathJB = @"/var/jb/var/mobile/Library/Application Support/WeTypeEnhance/bg.png";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *useImg = nil;
    if ([fm fileExistsAtPath:imgPath]) useImg = imgPath;
    else if ([fm fileExistsAtPath:imgPathJB]) useImg = imgPathJB;
    if (useImg) {
        c.bgImage = [UIImage imageWithContentsOfFile:useImg];
    } else {
        id data = WTE_GetPref(kKeyBgImageData);
        if ([data isKindOfClass:[NSData class]] && [(NSData *)data length] > 0) {
            c.bgImage = [UIImage imageWithData:data];
        }
    }

    // 2. 按键配色
    c.keyColorEnabled   = WTE_BoolPref(kKeyKeyColorEnabled, NO);
    c.keyLetterBg       = WTE_ColorFromHex(WTE_StringPref(kKeyKeyLetterBg, @"#FFFFFF"));
    c.keyDigitBg        = WTE_ColorFromHex(WTE_StringPref(kKeyKeyDigitBg, @"#FFD166"));
    c.keyFuncLeftBg     = WTE_ColorFromHex(WTE_StringPref(kKeyKeyFuncLeftBg, @"#A8A8A8"));
    c.keyFuncRightBg    = WTE_ColorFromHex(WTE_StringPref(kKeyKeyFuncRightBg, @"#A8A8A8"));
    c.keySpaceBg        = WTE_ColorFromHex(WTE_StringPref(kKeyKeySpaceBg, @"#FFFFFF"));
    c.keyTextColor      = WTE_ColorFromHex(WTE_StringPref(kKeyKeyTextColor, @"#000000"));
    c.keyHighlightColor = WTE_ColorFromHex(WTE_StringPref(kKeyKeyHighlightColor, @"#D9D9D9"));

    // 3. 皮肤与字母渐变
    c.skinEnabled           = WTE_BoolPref(kKeySkinEnabled, NO);
    c.letterGradientEnabled = WTE_BoolPref(kKeyLetterGradientEnabled, NO);
    c.letterGradientFrom    = WTE_ColorFromHex(WTE_StringPref(kKeyLetterGradientFrom, @"#5AC8FA"));
    c.letterGradientTo      = WTE_ColorFromHex(WTE_StringPref(kKeyLetterGradientTo, @"#AF52DE"));
    c.letterColorMap        = WTE_GetPref(kKeyLetterColorMap);

    // 4. 按键形状
    c.keyShape        = WTE_StringPref(kKeyKeyShape, @"rounded");
    c.keyCap3D        = WTE_BoolPref(kKeyKeyCap3D, NO);
    c.keyCornerRadius = WTE_DoublePref(kKeyKeyCornerRadius, 5.0);

    // 5. 工具栏布局
    c.tbKeepNativeSize   = WTE_BoolPref(kKeyTbKeepNativeSize, YES);
    c.tbHorizontalScroll = WTE_BoolPref(kKeyTbHorizontalScroll, NO);
    c.tbFillRow          = WTE_BoolPref(kKeyTbFillRow, NO);
    c.tbEditNoFill       = WTE_BoolPref(kKeyTbEditNoFill, YES);

    // 6. 键盘位移
    c.kbOffset = WTE_DoublePref(kKeyKbOffset, 0.0);

    return c;
}
@end

static WTEConfig *gConfig = nil;
static dispatch_queue_t gPrefQueue;

static void WTE_ReloadConfig(void) {
    gConfig = [WTEConfig load];
}

static void WTE_PrefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(gPrefQueue, ^{
        WTE_ReloadConfig();
        // 配置变化后，让微信输入法整条视图树重新走一遍 layout
        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    [w setNeedsLayout];
                }
            }
        });
    });
}

#pragma mark - ========== 按键外观辅助 ==========

// 判断按键类型 —— 微信输入法键盘按键的文字/类名规律
typedef NS_ENUM(NSInteger, WTEKeyKind) {
    WTEKeyKindLetter = 0,   // 字母键
    WTEKeyKindDigit,        // 数字键
    WTEKeyKindFuncLeft,     // 左侧功能键（shift / 123 等）
    WTEKeyKindFuncRight,    // 右侧功能键（退格 / 回车 等）
    WTEKeyKindSpace,        // 空格
    WTEKeyKindOther,
};

static WTEKeyKind WTE_KeyKindForView(UIView *v) {
    NSString *cls = NSStringFromClass([v class]);
    if ([cls containsString:@"Return"])  return WTEKeyKindFuncRight;
    if ([cls containsString:@"Sec"])     return WTEKeyKindFuncRight;
    if ([cls containsString:@"Rule"])    return WTEKeyKindOther;

    // 拿按键文字判断
    NSString *text = nil;
    if ([v respondsToSelector:NSSelectorFromString(@"titleLabel")]) {
        UILabel *lbl = [v performSelector:NSSelectorFromString(@"titleLabel")];
        if ([lbl isKindOfClass:[UILabel class]]) text = lbl.text;
    }
    if (!text) {
        SEL s = NSSelectorFromString(@"text");
        if ([v respondsToSelector:s]) {
            id t = [v performSelector:s];
            if ([t isKindOfClass:[NSString class]]) text = t;
        }
    }
    if (text.length == 0) return WTEKeyKindLetter;

    if ([text isEqualToString:@" "]) return WTEKeyKindSpace;
    if ([text rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound
        && text.length <= 3) {
        return WTEKeyKindDigit;
    }
    if ([text isEqualToString:@"⇧"] || [text isEqualToString:@"⇪"] ||
        [text isEqualToString:@"#+="] || [text isEqualToString:@"123"] ||
        [text isEqualToString:@"ABC"] || [text isEqualToString:@"中"]) {
        return WTEKeyKindFuncLeft;
    }
    if ([text isEqualToString:@"⌫"] || [text isEqualToString:@"⌦"] ||
        [text isEqualToString:@"换行"] || [text isEqualToString:@"return"] ||
        [text length] == 0) {
        return WTEKeyKindFuncRight;
    }
    return WTEKeyKindLetter;
}

static UIColor *WTE_ColorForKeyKind(WTEKeyKind kind, WTEConfig *c) {
    switch (kind) {
        case WTEKeyKindLetter:     return c.keyLetterBg;
        case WTEKeyKindDigit:      return c.keyDigitBg;
        case WTEKeyKindFuncLeft:   return c.keyFuncLeftBg;
        case WTEKeyKindFuncRight:  return c.keyFuncRightBg;
        case WTEKeyKindSpace:      return c.keySpaceBg;
        default:                   return nil;
    }
}

// 字母渐变取色：按字母在键盘中的顺序映射到 from→to
static UIColor *WTE_GradientColorForLetter(unichar ch, WTEConfig *c) {
    // 先查自定义映射表
    if ([c.letterColorMap isKindOfClass:[NSDictionary class]]) {
        NSString *k = [[NSString stringWithFormat:@"%C", ch] lowercaseString];
        id hex = c.letterColorMap[k] ?: c.letterColorMap[[k uppercaseString]];
        if (hex) {
            UIColor *col = WTE_ColorFromHex(hex);
            if (col) return col;
        }
    }
    if (!c.letterGradientEnabled) return nil;
    if (ch >= 'a' && ch <= 'z') {
        double t = (double)(ch - 'a') / 25.0;
        return [WTEConfig interpolateFrom:c.letterGradientFrom to:c.letterGradientTo t:t];
    }
    if (ch >= 'A' && ch <= 'Z') {
        double t = (double)(ch - 'A') / 25.0;
        return [WTEConfig interpolateFrom:c.letterGradientFrom to:c.letterGradientTo t:t];
    }
    if (ch >= '0' && ch <= '9') {
        double t = (double)(ch - '0') / 9.0;
        return [WTEConfig interpolateFrom:c.letterGradientFrom to:c.letterGradientTo t:t];
    }
    return nil;
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

#pragma mark - ========== 背景图铺满绘制 ==========

@interface WTEBackgroundView : UIImageView
@end
@implementation WTEBackgroundView
- (void)layoutSubviews {
    [super layoutSubviews];
    // 保持比例铺满，不拉伸变形（等价原插件的 cropToKeyboardAspect）
    if (!self.image) return;
    CGSize bs = self.bounds.size;
    CGSize is = self.image.size;
    if (bs.width <= 0 || bs.height <= 0 || is.width <= 0 || is.height <= 0) return;
    CGFloat scale = MAX(bs.width / is.width, bs.height / is.height);
    CGFloat w = is.width * scale, h = is.height * scale;
    self.frame = CGRectMake(self.superview.bounds.origin.x + (bs.width - w) / 2.0,
                            self.superview.bounds.origin.y + (bs.height - h) / 2.0,
                            w, h);
}
@end

#pragma mark - ========== Hook: WBKeyboardView（键盘整体） ==========

static void (*orig_WBKeyboardView_layoutSubviews)(UIView *, SEL);

static void WTE_WBKeyboardView_layoutSubviews(UIView *self, SEL _cmd) {
    orig_WBKeyboardView_layoutSubviews(self, _cmd);

    WTEConfig *c = gConfig;
    if (!c || !c.enabled) return;

    static const void *kBgTagKey = &kBgTagKey;
    UIView *bg = objc_getAssociatedObject(self, kBgTagKey);

    BOOL needBg = c.bgEnabled || c.keyboardTransparent ||
                  [c.bgMode isEqualToString:@"image"] || [c.bgMode isEqualToString:@"transparent"];
    if (!needBg) {
        if (bg) { [bg removeFromSuperview]; objc_setAssociatedObject(self, kBgTagKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        return;
    }

    // 整键盘透明：把键盘自身背景抹掉
    if (c.keyboardTransparent || [c.bgMode isEqualToString:@"transparent"]) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        if ([self respondsToSelector:NSSelectorFromString(@"setBackgroundEffects:")]) {
            [self performSelector:NSSelectorFromString(@"setBackgroundEffects:") withObject:nil];
        }
    }

    if (!bg) {
        bg = [[UIView alloc] initWithFrame:self.bounds];
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        bg.userInteractionEnabled = NO;
        [self insertSubview:bg atIndex:0];
        objc_setAssociatedObject(self, kBgTagKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    bg.frame = self.bounds;

    // 清掉旧的背景图子视图
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

    // 键盘整体位移
    if (c.kbOffset != 0.0) {
        self.transform = CGAffineTransformMakeTranslation(0, c.kbOffset);
    } else {
        self.transform = CGAffineTransformIdentity;
    }
}

#pragma mark - ========== Hook: WBKeyView（单个按键） ==========

static void (*orig_WBKeyView_layoutSubviews)(UIView *, SEL);

static void WTE_WBKeyView_layoutSubviews(UIView *self, SEL _cmd) {
    orig_WBKeyView_layoutSubviews(self, _cmd);

    WTEConfig *c = gConfig;
    if (!c || !c.enabled) return;

    WTEKeyKind kind = WTE_KeyKindForView(self);

    // 按键形状：圆角 / 3D 键帽
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
    } else { // rounded
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

    // 按键配色
    if (c.keyColorEnabled) {
        UIColor *col = WTE_ColorForKeyKind(kind, c);
        if (col) self.backgroundColor = col;
    }

    // 文字颜色
    if (c.keyColorEnabled && c.keyTextColor) {
        UILabel *lbl = nil;
        if ([self respondsToSelector:NSSelectorFromString(@"titleLabel")]) {
            lbl = [self performSelector:NSSelectorFromString(@"titleLabel")];
        }
        if ([lbl isKindOfClass:[UILabel class]]) lbl.textColor = c.keyTextColor;
        // 有些版本的 WBKeyView 直接是 UILabel 子类 / 内嵌
        if ([self isKindOfClass:[UILabel class]]) ((UILabel *)self).textColor = c.keyTextColor;
    }

    // 字母渐变
    if (c.letterGradientEnabled || [c.letterColorMap count] > 0) {
        UILabel *lbl = nil;
        if ([self respondsToSelector:NSSelectorFromString(@"titleLabel")]) {
            lbl = [self performSelector:NSSelectorFromString(@"titleLabel")];
        }
        NSString *txt = ([lbl isKindOfClass:[UILabel class]]) ? lbl.text : nil;
        if (txt.length >= 1) {
            UIColor *gc = WTE_GradientColorForLetter([txt characterAtIndex:0], c);
            if (gc) {
                if ([lbl isKindOfClass:[UILabel class]]) lbl.textColor = gc;
                else if ([self isKindOfClass:[UILabel class]]) ((UILabel *)self).textColor = gc;
            }
        }
    }

    // 高亮色（按下态）
    if (c.keyColorEnabled && c.keyHighlightColor) {
        SEL s = NSSelectorFromString(@"setHighlightedBackgroundColor:");
        if ([self respondsToSelector:s]) {
            [self performSelector:s withObject:c.keyHighlightColor];
        }
    }
}

#pragma mark - ========== Hook: WBCandidateView / 候选栏 ==========

static void (*orig_WBCandidateView_layoutSubviews)(UIView *, SEL);

static void WTE_WBCandidateView_layoutSubviews(UIView *self, SEL _cmd) {
    orig_WBCandidateView_layoutSubviews(self, _cmd);
    WTEConfig *c = gConfig;
    if (!c || !c.enabled) return;

    if (c.keyboardTransparent || [c.bgMode isEqualToString:@"transparent"]) {
        self.backgroundColor = [UIColor clearColor];
    }
    if (c.keyColorEnabled && c.keyTextColor) {
        if ([self isKindOfClass:[UILabel class]]) ((UILabel *)self).textColor = c.keyTextColor;
        else if ([self respondsToSelector:NSSelectorFromString(@"titleLabel")]) {
            UILabel *l = [self performSelector:NSSelectorFromString(@"titleLabel")];
            if ([l isKindOfClass:[UILabel class]]) l.textColor = c.keyTextColor;
        }
    }
}

#pragma mark - ========== Hook: WBTopBar / WBArrangeView / 工具栏布局 ==========

static void (*orig_WBTopBar_layoutSubviews)(UIView *, SEL);

static void WTE_WBTopBar_layoutSubviews(UIView *self, SEL _cmd) {
    WTEConfig *c = gConfig;
    if (c && c.enabled) {
        // 工具栏自动填充整行
        if (c.tbFillRow) {
            self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        }
        // 编辑态不填充
        if (c.tbEditNoFill) {
            UIResponder *r = [self nextResponder];
            if ([r isKindOfClass:[UIView class]]) {
                NSString *rc = NSStringFromClass([r class]);
                if ([rc containsString:@"Edit"]) {
                    // 编辑态保持原尺寸
                }
            }
        }
        if (c.keyboardTransparent || [c.bgMode isEqualToString:@"transparent"]) {
            self.backgroundColor = [UIColor clearColor];
        }
    }
    orig_WBTopBar_layoutSubviews(self, _cmd);
}

static void (*orig_WBArrangeView_layoutSubviews)(UIView *, SEL);

static void WTE_WBArrangeView_layoutSubviews(UIView *self, SEL _cmd) {
    orig_WBArrangeView_layoutSubviews(self, _cmd);
    WTEConfig *c = gConfig;
    if (!c || !c.enabled) return;

    if (c.tbKeepNativeSize) {
        // 保持原生尺寸，不参与拉伸
        self.autoresizingMask = UIViewAutoresizingNone;
    }
    if (c.tbHorizontalScroll) {
        for (UIView *sub in self.subviews) {
            sub.autoresizingMask = UIViewAutoresizingNone;
        }
    }
    if (c.keyboardTransparent || [c.bgMode isEqualToString:@"transparent"]) {
        self.backgroundColor = [UIColor clearColor];
    }
}

#pragma mark - ========== 构造期 hook ==========

static void (*orig_WBKeyView_didMoveToWindow)(UIView *, SEL);

static void WTE_WBKeyView_didMoveToWindow(UIView *self, SEL _cmd) {
    orig_WBKeyView_didMoveToWindow(self, _cmd);
    // 进入窗口后再刷一次，规避时序问题
    [self setNeedsLayout];
}

#pragma mark - ========== 初始化 ==========

__attribute__((constructor))
static void WTE_Init(void) {
    gPrefQueue = dispatch_queue_create("com.colorblack.wetypeenhance.prefs", DISPATCH_QUEUE_SERIAL);

    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleID = [bundle bundleIdentifier];
    NSString *execName = [[NSProcessInfo processInfo] processName];

    NSLog(@"[WeTypeEnhance] loaded pid=%d bundle=%@ exec=%@", getpid(), bundleID, execName);

    WTE_ReloadConfig();

    // 偏好变更监听
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    WTE_PrefsChangedCallback,
                                    (__bridge CFStringRef)kPrefChangedNotify,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // ---- hook 各输入法类（存在才 hook，避免跨版本崩溃） ----
    Class kbd = objc_getClass("WBKeyboardView");
    if (kbd) MSHookMessageEx(kbd, @selector(layoutSubviews),
                             (IMP)&WTE_WBKeyboardView_layoutSubviews,
                             (IMP *)&orig_WBKeyboardView_layoutSubviews);

    Class key = objc_getClass("WBKeyView");
    if (key) {
        MSHookMessageEx(key, @selector(layoutSubviews),
                        (IMP)&WTE_WBKeyView_layoutSubviews,
                        (IMP *)&orig_WBKeyView_layoutSubviews);
        MSHookMessageEx(key, @selector(didMoveToWindow),
                        (IMP)&WTE_WBKeyView_didMoveToWindow,
                        (IMP *)&orig_WBKeyView_didMoveToWindow);
    }

    Class cand = objc_getClass("WBCandidateView");
    if (cand) MSHookMessageEx(cand, @selector(layoutSubviews),
                              (IMP)&WTE_WBCandidateView_layoutSubviews,
                              (IMP *)&orig_WBCandidateView_layoutSubviews);

    Class topbar = objc_getClass("WBTopBar");
    if (topbar) MSHookMessageEx(topbar, @selector(layoutSubviews),
                                (IMP)&WTE_WBTopBar_layoutSubviews,
                                (IMP *)&orig_WBTopBar_layoutSubviews);

    Class arrange = objc_getClass("WBArrangeView");
    if (arrange) MSHookMessageEx(arrange, @selector(layoutSubviews),
                                 (IMP)&WTE_WBArrangeView_layoutSubviews,
                                 (IMP *)&orig_WBArrangeView_layoutSubviews);

    NSLog(@"[WeTypeEnhance] hooks installed pid=%d bundle=%@", getpid(), bundleID);
}
