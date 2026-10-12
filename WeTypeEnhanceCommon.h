// WeTypeEnhanceCommon.h
// 微信输入法增强 —— 主程序与偏好面板共用的常量与工具函数
// 包名: com.colorblack.wetypeenhance

#ifndef WETYPE_ENHANCE_COMMON_H
#define WETYPE_ENHANCE_COMMON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ---- 偏好域名 ----
#define kPrefDomain        @"com.colorblack.wetypeenhance"
#define kPrefPath          @"/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist"
#define kPrefChangedNotify @"com.colorblack.wetypeenhance.prefschanged"

// ---- 资源目录 ----
#define kSkinDir @"/var/mobile/Library/Application Support/WeTypeEnhance/skins"

#pragma mark - 偏好键（与原 KBTheme 一一对应）

// 1. 总开关 / 键盘背景
#define kKeyEnabled            @"enabled"
#define kKeyBgEnabled          @"bgEnabled"
#define kKeyBgMode             @"bgMode"          // solid / image / transparent
#define kKeyBgColor            @"bgColor"
#define kKeyBgAlpha            @"bgAlpha"
#define kKeyBgImageData        @"bgImageData"
#define kKeyKeyboardTransparent @"keyboardTransparent"

// 2. 按键配色
#define kKeyKeyColorEnabled    @"keyColorEnabled"
#define kKeyKeyLetterBg        @"keyLetterBg"
#define kKeyKeyDigitBg         @"keyDigitBg"
#define kKeyKeyFuncLeftBg      @"keyFuncLeftBg"
#define kKeyKeyFuncRightBg     @"keyFuncRightBg"
#define kKeyKeySpaceBg         @"keySpaceBg"
#define kKeyKeyTextColor       @"keyTextColor"
#define kKeyKeyHighlightColor  @"keyHighlightColor"

// 3. 皮肤与字母渐变
#define kKeySkinEnabled          @"skinEnabled"
#define kKeyLetterGradientEnabled @"letterGradientEnabled"
#define kKeyLetterGradientFrom   @"letterGradientFrom"
#define kKeyLetterGradientTo     @"letterGradientTo"
#define kKeyLetterColorMap       @"letterColorMap"

// 4. 按键形状
#define kKeyKeyShape         @"keyShape"          // square / rounded / circle / bevel
#define kKeyKeyCap3D         @"keyCap3D"
#define kKeyKeyCornerRadius  @"keyCornerRadius"

// 5. 工具栏布局
#define kKeyTbKeepNativeSize @"tbKeepNativeSize"
#define kKeyTbHorizontalScroll @"tbHorizontalScroll"
#define kKeyTbFillRow        @"tbFillRow"
#define kKeyTbEditNoFill     @"tbEditNoFill"

// 6. 键盘位移
#define kKeyKbOffset @"kbOffset"

// 7. 预设
#define kKeyKBThemePreset @"KBThemePreset"

#pragma mark - 工具函数声明（实现在 Tweak.x，面板通过 extern 调用）

#ifdef __cplusplus
extern "C" {
#endif

UIColor  *WTE_ColorFromHex(NSString *hex);
NSString *WTE_HexFromColor(UIColor *color);
id        WTE_GetPref(NSString *key);
void      WTE_SetPref(NSString *key, id value);
void      WTE_NotifyChanged(void);

#ifdef __cplusplus
}
#endif

#endif /* WETYPE_ENHANCE_COMMON_H */
