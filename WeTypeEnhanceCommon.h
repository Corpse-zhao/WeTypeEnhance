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
// v1.8.7：透明底的范围  bg = 只透底板（按键保留原样） / all = 整键盘透明（按键帽也摘掉）
#define kKeyTransScope         @"transScope"

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

// 把当前偏好复制到所有「键盘扩展读得到」的位置（键盘扩展容器 / Media /
// Application Support / App Group）。返回成功写入的完整路径数组。
// 面板跑在 Preferences 进程里，不受 app 沙盒限制，所以这一步能在键盘
// 直读 /var/mobile/Library/Preferences 被拦时提供保底通道。
NSArray  *WTE_SyncConfigToReadablePlaces(void);

#ifdef __cplusplus
}
#endif

#endif /* WETYPE_ENHANCE_COMMON_H */
