// WTERootListController.m
// 微信输入法增强 —— 偏好设置面板
// 完整图形界面：开关 / 滑块 / 取色器 / 相册选图 / 预设 / 重置

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <signal.h>
#import "../WeTypeEnhanceCommon.h"

// ---- Preferences 私有框架自声明 ----
// iOS SDK 不含 Preferences.framework 的头文件与 .tbd，且 roothide theos 的
// vendor/include 里不一定有副本。这里只声明用到的部分，链接期用
// -Wl,-undefined,dynamic_lookup 交给运行时解析（符号由设置 App 提供）。

typedef NS_ENUM(NSInteger, PSCellType) {
    PSGroupCell       = 0,
    PSLinkCell        = 1,
    PSLinkListCell    = 2,
    PSListItemCell    = 3,
    PSTitleValueCell  = 4,
    PSSliderCell      = 5,
    PSSwitchCell      = 6,
    PSStaticTextCell  = 7,
    PSButtonCell      = 8,
    PSRadioGroupCell  = 9,
    PSControlGroupCell = 10,
};

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(PSCellType)cell
                                    edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setButtonAction:(SEL)action;
- (void)setTarget:(id)target;
@end

@interface PSTableCell : UITableViewCell
@property (nonatomic, strong) id specifier;
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier;
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier;
@end

@interface PSListController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, retain) NSArray *specifiers;
- (NSArray *)specifiers;
- (PSSpecifier *)specifierAtIndexPath:(NSIndexPath *)indexPath;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)spec;
@end

@interface WTEDiagViewController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, copy) NSString *reportText;
@property (nonatomic, copy) NSString *reportPath;
@end

@implementation WTEDiagViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"诊断报告";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UIBarButtonItem *copyItem = [[UIBarButtonItem alloc] initWithTitle:@"复制"
                                                                style:UIBarButtonItemStylePlain
                                                               target:self
                                                               action:@selector(copyReport:)];
    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                                                 style:UIBarButtonItemStyleDone
                                                                target:self
                                                                action:@selector(close:)];
    self.navigationItem.rightBarButtonItem = copyItem;
    self.navigationItem.leftBarButtonItem = closeItem;

    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _textView.text = self.reportText ?: @"";
    [self.view addSubview:_textView];
}

- (void)copyReport:(id)sender {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    if (@available(iOS 10.0, *)) {
        pb.string = self.reportText ?: @"";
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已复制"
                                                              message:@"诊断内容已复制到剪贴板，可直接粘贴发送"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)close:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// 在候选路径里找诊断文件（含键盘扩展容器、App Group 共享容器）
static NSArray *WTEP_DiagSearchPaths(void) {
    NSMutableArray *paths = [NSMutableArray array];
    [paths addObject:@"/var/mobile/Media/WeTypeEnhance/diag.txt"];
    [paths addObject:@"/var/mobile/Library/Application Support/WeTypeEnhance/diag.txt"];

    NSFileManager *fm = [NSFileManager defaultManager];

    // 插件容器（键盘扩展的数据容器就在这里）
    NSString *pk = @"/var/mobile/Containers/Data/PluginKitPlugin";
    for (NSString *sub in [fm contentsOfDirectoryAtPath:pk error:nil]) {
        NSString *base = [pk stringByAppendingPathComponent:sub];
        for (NSString *rel in @[@"Documents/WeTypeEnhance/diag.txt",
                                @"tmp/WeTypeEnhance/diag.txt",
                                @"Library/Application Support/WeTypeEnhance/diag.txt"]) {
            [paths addObject:[base stringByAppendingPathComponent:rel]];
        }
    }

    // App Group 共享容器
    NSString *shared = @"/var/mobile/Containers/Shared/AppGroup";
    for (NSString *sub in [fm contentsOfDirectoryAtPath:shared error:nil]) {
        NSString *base = [shared stringByAppendingPathComponent:sub];
        NSString *meta = [base stringByAppendingPathComponent:
                          @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *gid = m[@"MCMMetadataIdentifier"];
        if (![gid isKindOfClass:[NSString class]]) continue;
        if ([gid containsString:@"tencent"] || [gid containsString:@"wetype"] ||
            [gid containsString:@"xin"] || [gid containsString:@"wechat"]) {
            [paths addObject:[base stringByAppendingPathComponent:@"WeTypeEnhance/diag.txt"]];
        }
    }

    // 普通 App 容器（万一键盘跑在主 App 里）
    NSString *app = @"/var/mobile/Containers/Data/Application";
    for (NSString *sub in [fm contentsOfDirectoryAtPath:app error:nil]) {
        NSString *base = [app stringByAppendingPathComponent:sub];
        [paths addObject:[base stringByAppendingPathComponent:@"Documents/WeTypeEnhance/diag.txt"]];
        [paths addObject:[base stringByAppendingPathComponent:@"tmp/WeTypeEnhance/diag.txt"]];
    }
    return paths;
}

static NSString *WTEP_FindDiagPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in WTEP_DiagSearchPaths()) {
        if ([fm fileExistsAtPath:p]) {
            NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
            if ([attr fileSize] > 0) return p;
        }
    }
    return nil;
}

// 阳性对照文件（由 SpringBoard 进程写入）
static NSString *WTEP_FindSpringBoardMarker(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray array];
    [cands addObject:@"/var/mobile/Media/WeTypeEnhance/springboard.txt"];
    for (NSString *p in WTEP_DiagSearchPaths()) {
        [cands addObject:[[p stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:@"springboard.txt"]];
    }
    for (NSString *p in cands) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

// ═══ v1.9.2：收集宿主 App 的回执 ═══
// 为什么必须由「设置」面板来收：
//   · 真正的键盘显示位置在宿主 App 进程（微信等）里，透明底必须在那儿动手
//   · 宿主 App 被自己的沙盒关住，只能写自己容器里的 Documents/WeTypeEnhance/host.txt
//   · 键盘扩展进程【列不出】/var/mobile/Containers/Data/Application 目录（沙盒挡住），
//     所以 v1.9.0 的报告里「宿主回执」永远是空的 —— 取证通道本身走错路了
//   · 而「设置」进程能读 App 容器（配置同步就是这么写进键盘容器的），所以由它来收
static NSArray<NSString *> *WTEP_CollectHostReports(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *bases = @[@"/var/mobile/Containers/Data/Application",
                       @"/var/mobile/Containers/Data/PluginKitPlugin"];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-1800];   // 只看最近半小时
    for (NSString *base in bases) {
        NSArray *subs = [fm contentsOfDirectoryAtPath:base error:nil];
        if (!subs.count) {
            [out addObject:[NSString stringWithFormat:@"  (%@ 列不出来 —— 本进程读不了 App 容器)", base]];
            continue;
        }
        for (NSString *sub in subs) {
            NSString *f = [[[base stringByAppendingPathComponent:sub]
                            stringByAppendingPathComponent:@"Documents/WeTypeEnhance"]
                           stringByAppendingPathComponent:@"host.txt"];
            NSDictionary *attr = [fm attributesOfItemAtPath:f error:nil];
            if (!attr) continue;
            NSDate *mod = attr[NSFileModificationDate];
            if (mod && [mod compare:cutoff] == NSOrderedAscending) continue;
            NSString *txt = [NSString stringWithContentsOfFile:f
                                                      encoding:NSUTF8StringEncoding error:nil];
            if (!txt.length) continue;
            if (txt.length > 7000) txt = [txt substringFromIndex:txt.length - 7000];
            [out addObject:[NSString stringWithFormat:@"----- %@ -----\n%@", f, txt]];
            if (out.count >= 10) break;      // 别把弹窗撑爆
        }
        if (out.count >= 10) break;
    }
    return out;
}

#pragma mark - 主控制器

@interface WTERootListController : PSListController <UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) PSSpecifier *pendingSpec;
@end

// 自声明里没有 _specifiers ivar，用自定义存储承接
@interface WTERootListController ()
@property (nonatomic, strong) NSArray *wteSpecifiers;
@end

@implementation WTERootListController

- (NSArray *)specifiers {
    // 真正的 PSListController 内部大量路径直接读私有 ivar `_specifiers`，
    // 不经过 getter。这里通过 runtime 把构建好的列表写入该 ivar，
    // 保证内部数据源与我们的 getter 看到同一份数据。
    Ivar ivar = class_getInstanceVariable([PSListController class], "_specifiers");
    if (ivar) {
        id cur = object_getIvar(self, ivar);
        if (!cur) {
            cur = [[self buildSpecifiers] copy];
            object_setIvar(self, ivar, cur);
        }
        return cur;
    }
    // 兜底：ivar 不存在（理论上不会），退回自有存储
    if (!self.wteSpecifiers) {
        self.wteSpecifiers = [[self buildSpecifiers] copy];
    }
    return self.wteSpecifiers;
}

- (PSSpecifier *)group:(NSString *)name {
    return [PSSpecifier groupSpecifierWithName:name];
}

// v1.9.0：带说明文字的分组（footerText 会渲染在这一组所有行的下方）
- (PSSpecifier *)group:(NSString *)name footer:(NSString *)footer {
    PSSpecifier *s = [PSSpecifier groupSpecifierWithName:name];
    if (footer.length) {
        @try { [s setProperty:footer forKey:@"footerText"]; } @catch (__unused id e) {}
    }
    return s;
}

- (PSSpecifier *)switchRow:(NSString *)title key:(NSString *)key def:(BOOL)def {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:@selector(setPref:forSpecifier:)
                                                       get:@selector(getPrefForSpecifier:)
                                                    detail:nil
                                                      cell:PSSwitchCell
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:@(def) forKey:@"defaultValue"];
    return s;
}

- (PSSpecifier *)sliderRow:(NSString *)title key:(NSString *)key def:(double)def min:(double)mn max:(double)mx {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:@selector(setPref:forSpecifier:)
                                                       get:@selector(getPrefForSpecifier:)
                                                    detail:nil
                                                      cell:PSSliderCell
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:@(def) forKey:@"defaultValue"];
    [s setProperty:@(mn) forKey:@"min"];
    [s setProperty:@(mx) forKey:@"max"];
    return s;
}

- (PSSpecifier *)colorRow:(NSString *)title key:(NSString *)key def:(NSString *)def {
    // 用系统 PSTitleValueCell：get 返回当前 hex 显示在右侧，点击进取色器。
    // 注意：真实 Preferences 会调用 get/set 刷新 cell，任何一个为 nil 都会把整行禁用（灰掉），
    // 所以这里 get/set 必须都给。
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:@selector(setColorValue:forSpecifier:)
                                                       get:@selector(getColorValueForSpecifier:)
                                                    detail:nil
                                                      cell:PSTitleValueCell
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:def forKey:@"defaultHex"];
    [s setProperty:@YES forKey:@"isColorRow"];
    return s;
}

- (PSSpecifier *)choiceRow:(NSString *)title key:(NSString *)key def:(NSString *)def
                    values:(NSArray *)values titles:(NSArray *)titles {
    // 用 PSTitleValueCell（和颜色行同一套，实测不会变成可编辑文本框）。
    // 注意不能用 PSButtonCell —— 这版 Preferences 会把它渲染成可输入的文本框。
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:@selector(setChoiceValue:forSpecifier:)
                                                       get:@selector(getChoiceValueForSpecifier:)
                                                    detail:nil
                                                      cell:PSTitleValueCell
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:def forKey:@"defaultValue"];
    [s setProperty:values forKey:@"validValues"];
    [s setProperty:titles forKey:@"validTitles"];
    [s setProperty:@YES forKey:@"isChoiceRow"];
    return s;
}

- (PSSpecifier *)buttonRow:(NSString *)title action:(SEL)action {
    // 同上：PSButtonCell 会被当文本框，改用 PSTitleValueCell + 自定义点击。
    // get/set 必须给（否则整行灰掉），get 返回空串让右侧留白。
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:@selector(setDisplay:forSpecifier:)
                                                       get:@selector(getDisplayForSpecifier:)
                                                    detail:nil
                                                      cell:PSTitleValueCell
                                                      edit:nil];
    [s setProperty:NSStringFromSelector(action) forKey:@"action"];
    [s setProperty:@YES forKey:@"isButtonRow"];
    return s;
}

- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    // 版本号从 bundle 读，避免写死后与实际包版本不一致
    NSString *ver = [[NSBundle bundleForClass:[self class]]
                     objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";

    // ★ 版本一致性检查：iOS 装 deb 不重启键盘扩展进程，
    //   面板是新版、键盘还是旧码 —— 这是「改了设置完全不生效」的头号原因。
    NSString *running = [self keyboardRunningVersion];
    NSString *head;
    if (running.length && ![running isEqualToString:ver]) {
        head = [NSString stringWithFormat:
            @"微信输入法增强 v%@\n\n⚠️ 键盘进程还在跑旧版 v%@\n装完新包必须注销一次，否则怎么调都不生效", ver, running];
    } else if (running.length) {
        head = [NSString stringWithFormat:
            @"微信输入法增强 v%@\n键盘进程 v%@ ✅ 版本一致", ver, running];
    } else {
        head = [NSString stringWithFormat:
            @"微信输入法增强 v%@\n功能对等移植自「原生输入法增强」\n（还没拿到键盘进程报告，弹出一次键盘后再看）", ver];
    }
    [specs addObject:[self group:head]];
    [specs addObject:[self buttonRow:@"重启键盘进程（不影响其它 App）" action:@selector(restartKeyboard:)]];
    [specs addObject:[self buttonRow:@"检查键盘运行版本" action:@selector(checkKeyboardVersion:)]];
    [specs addObject:[self buttonRow:@"注销 (Respring)" action:@selector(respringDevice:)]];
    [specs addObject:[self switchRow:@"启用" key:kKeyEnabled def:YES]];

    // ---- 1. 键盘背景（v1.8.0：只保留 纯色 / 透明底） ----
    [specs addObject:[self group:@"键盘背景"
        footer:@"【透明底】＝ 把键盘自己的底板清空，透出聊天背景（就像微信自带的表情面板那样）。\n"
               "【按键透明度】＝ 键帽的透明程度，只在「透明底」下生效：\n"
               "  · 1.0 ＝ 键帽完全不透明（打字最清楚）\n"
               "  · 0.3 ＝ 默认。键帽半透明，能看见聊天背景，字母依旧清晰 ←「透明但不影响打字」\n"
               "  · 0.0 ＝ 键帽一点不剩，只剩字母（最好看，但可能不好找按键）\n"
               "注意：要让它生效，「透明范围」必须是【整键盘透明】；\n"
               "或者你亲手拉过这个滑条（拉过就两个档都生效）。"]];
    [specs addObject:[self switchRow:@"开启背景" key:kKeyBgEnabled def:NO]];
    [specs addObject:[self choiceRow:@"背景模式" key:kKeyBgMode def:@"solid"
                              values:@[@"solid", @"transparent"]
                              titles:@[@"纯色", @"透明底"]]];
    // v1.8.9：默认「只透底板」。整键盘透明会把按键帽改半透明 —— 1.8.7/1.8.8 直接摘掉，
    // 用户实测「打字按不到字母」；1.8.9 起改成半透明帽，既透又看得见。
    [specs addObject:[self choiceRow:@"透明范围" key:kKeyTransScope def:@"bg"
                              values:@[@"bg", @"all"]
                              titles:@[@"只透底板（按键正常，推荐）", @"整键盘透明（按键按下面的滑条变透）"]]];
    // v1.9.0 引入滑条 / v1.9.2 修好它：默认 0.30，且改成「只降不升」的封顶语义。
    // 之前默认 1.0 → 整段被跳过 → 滑条怎么拉都没反应（用户报「键盘还是实心」的根因之一）。
    [specs addObject:[self sliderRow:@"按键透明度 (1=不透明 0=全透)"
                                key:kKeyKeyOpacity def:0.30 min:0.0 max:1.0]];
    [specs addObject:[self colorRow:@"背景颜色" key:kKeyBgColor def:@"#101826"]];
    [specs addObject:[self sliderRow:@"背景不透明度" key:kKeyBgAlpha def:1.0 min:0.0 max:1.0]];

    // ---- 2. 按键配色 ----
    [specs addObject:[self group:@"按键配色"]];
    [specs addObject:[self switchRow:@"开启按键配色" key:kKeyKeyColorEnabled def:NO]];
    [specs addObject:[self colorRow:@"字母键背景" key:kKeyKeyLetterBg def:@"#FFFFFF"]];
    [specs addObject:[self colorRow:@"数字键背景" key:kKeyKeyDigitBg def:@"#FFD166"]];
    [specs addObject:[self colorRow:@"左侧功能键背景" key:kKeyKeyFuncLeftBg def:@"#A8A8A8"]];
    [specs addObject:[self colorRow:@"右侧功能键背景" key:kKeyKeyFuncRightBg def:@"#A8A8A8"]];
    [specs addObject:[self colorRow:@"空格键背景" key:kKeyKeySpaceBg def:@"#FFFFFF"]];
    [specs addObject:[self colorRow:@"按键文字颜色" key:kKeyKeyTextColor def:@"#000000"]];
    [specs addObject:[self colorRow:@"按下高亮色" key:kKeyKeyHighlightColor def:@"#D9D9D9"]];

    // ---- 3. 皮肤与字母渐变 ----
    [specs addObject:[self group:@"皮肤与字母渐变"]];
    [specs addObject:[self switchRow:@"启用皮肤" key:kKeySkinEnabled def:NO]];
    [specs addObject:[self switchRow:@"字母渐变" key:kKeyLetterGradientEnabled def:NO]];
    [specs addObject:[self colorRow:@"渐变起始色" key:kKeyLetterGradientFrom def:@"#5AC8FA"]];
    [specs addObject:[self colorRow:@"渐变结束色" key:kKeyLetterGradientTo def:@"#AF52DE"]];

    // ---- 4. 按键形状 ----
    [specs addObject:[self group:@"按键形状"]];
    [specs addObject:[self choiceRow:@"形状" key:kKeyKeyShape def:@"rounded"
                              values:@[@"rounded", @"square", @"circle", @"bevel"]
                              titles:@[@"圆角", @"直角", @"圆形", @"斜面"]]];
    [specs addObject:[self switchRow:@"3D 键帽" key:kKeyKeyCap3D def:NO]];
    [specs addObject:[self sliderRow:@"圆角半径" key:kKeyKeyCornerRadius def:5.0 min:0.0 max:20.0]];

    // ---- 5. 工具栏布局 ----
    [specs addObject:[self group:@"工具栏布局"]];
    [specs addObject:[self switchRow:@"保持原生尺寸" key:kKeyTbKeepNativeSize def:YES]];
    [specs addObject:[self switchRow:@"横向滚动" key:kKeyTbHorizontalScroll def:NO]];
    [specs addObject:[self switchRow:@"填充整行" key:kKeyTbFillRow def:NO]];
    [specs addObject:[self switchRow:@"编辑态不填充" key:kKeyTbEditNoFill def:YES]];

    // ---- 6. 键盘位移 ----
    [specs addObject:[self group:@"键盘位移"]];
    [specs addObject:[self sliderRow:@"上下偏移 (-40 ~ 40)" key:kKeyKbOffset def:0.0 min:-40.0 max:40.0]];

    // ---- 7. 预设与重置 ----
    [specs addObject:[self group:@"预设方案"]];
    [specs addObject:[self buttonRow:@"classic 经典"   action:@selector(applyClassic:)]];
    [specs addObject:[self buttonRow:@"dark 暗黑"      action:@selector(applyDark:)]];
    [specs addObject:[self buttonRow:@"violet 紫罗兰"  action:@selector(applyViolet:)]];
    [specs addObject:[self buttonRow:@"ocean 海洋"     action:@selector(applyOcean:)]];
    [specs addObject:[self buttonRow:@"sunset 日落"    action:@selector(applySunset:)]];
    // ---- 8. 诊断 ----
    [specs addObject:[self group:@"诊断"]];
    [specs addObject:[self buttonRow:@"透明诊断（点一下看结论）" action:@selector(transVerdict:)]];
    [specs addObject:[self buttonRow:@"生成诊断报告" action:@selector(openDiagReport:)]];
    [specs addObject:[self buttonRow:@"同步配置到键盘" action:@selector(syncToKeyboard:)]];
    [specs addObject:[self group:@""]];
    [specs addObject:[self buttonRow:@"恢复默认设置"   action:@selector(resetAll:)]];

    return specs;
}

#pragma mark - 偏好读写

- (id)getPrefForSpecifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    id v = WTE_GetPref(key);
    if (v) return v;
    return [spec propertyForKey:@"defaultValue"];
}

- (void)setPref:(id)value forSpecifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    WTE_SetPref(key, value);
    // v1.9.2：滑条拖动时每个像素都会回调一次。之前每次都「全量同步到所有容器 + 整表刷新」，
    // 结果滑条会被 reloadSpecifiers 顶回旧位置，既拉不动又卡。这里改成松手后再同步。
    BOOL isSlider = ([spec propertyForKey:@"min"] != nil || [spec propertyForKey:@"max"] != nil);
    if (isSlider) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(wteFinishSliderChange)
                                                   object:nil];
        [self performSelector:@selector(wteFinishSliderChange) withObject:nil afterDelay:0.25];
        return;
    }
    WTE_SyncConfigToReadablePlaces();   // 同步到键盘扩展容器（沙盒保底通道）
    WTE_NotifyChanged();
    [self reloadSpecifiers];
}

// 滑条松手（0.25s 没有新手势）之后，再全量同步一次
- (void)wteFinishSliderChange {
    WTE_SyncConfigToReadablePlaces();
    WTE_NotifyChanged();
    [self reloadSpecifiers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

// 重建 specifier 缓存后再交给父类刷新
- (void)reloadSpecifiers {
    self.wteSpecifiers = nil;
    Ivar ivar = class_getInstanceVariable([PSListController class], "_specifiers");
    if (ivar) object_setIvar(self, ivar, nil);
    [super reloadSpecifiers];
}

#pragma mark - 取色器

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([[spec propertyForKey:@"isColorRow"] boolValue]) {
        self.pendingSpec = spec;
        UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
        picker.delegate = self;
        picker.supportsAlpha = YES;
        NSString *cur = [self prefStringForKey:[spec propertyForKey:@"key"]
                                    fallback:[spec propertyForKey:@"defaultHex"]];
        UIColor *c = WTE_ColorFromHex(cur);
        if (c) picker.selectedColor = c;
        [self presentViewController:picker animated:YES completion:nil];
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    if ([[spec propertyForKey:@"isChoiceRow"] boolValue]) {
        [self cycleChoice:spec];
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    if ([[spec propertyForKey:@"isButtonRow"] boolValue]) {
        // 按钮行：自己派发动作（PSButtonCell 在这版 Preferences 会变成文本框，故手动接管）
        NSString *selName = [spec propertyForKey:@"action"];
        if (selName.length) {
            SEL a = NSSelectorFromString(selName);
            if ([self respondsToSelector:a]) {
                // suppress performSelector-leaks warning
                ((void (*)(id, SEL, id))objc_msgSend)(self, a, spec);
            }
        }
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (NSString *)prefStringForKey:(NSString *)key fallback:(NSString *)fallback {
    id v = WTE_GetPref(key);
    return [v isKindOfClass:[NSString class]] ? v : fallback;
}

#pragma mark - 颜色行 / 选择行 / 按钮行的 get,set

// 颜色行：get 返回当前 hex（显示在 PSTitleValueCell 右侧）
- (id)getColorValueForSpecifier:(PSSpecifier *)spec {
    return [self prefStringForKey:[spec propertyForKey:@"key"]
                         fallback:[spec propertyForKey:@"defaultHex"]];
}
- (void)setColorValue:(NSString *)hex forSpecifier:(PSSpecifier *)spec {
    WTE_SetPref([spec propertyForKey:@"key"], hex);
    WTE_SyncConfigToReadablePlaces();
    WTE_NotifyChanged();
}

// 选择行：get 返回当前值对应的中文标题
- (id)getChoiceValueForSpecifier:(PSSpecifier *)spec {
    NSString *cur = [self prefStringForKey:[spec propertyForKey:@"key"]
                                 fallback:[spec propertyForKey:@"defaultValue"]];
    NSArray *values = [spec propertyForKey:@"validValues"];
    NSArray *titles = [spec propertyForKey:@"validTitles"];
    NSUInteger idx = [values indexOfObject:cur];
    if (idx == NSNotFound || idx >= titles.count) idx = 0;
    return titles.count ? titles[idx] : cur;
}
- (void)setChoiceValue:(id)value forSpecifier:(PSSpecifier *)spec {
    WTE_SetPref([spec propertyForKey:@"key"], value);
    WTE_SyncConfigToReadablePlaces();
    WTE_NotifyChanged();
}

// 点击循环切换到下一个取值
- (void)cycleChoice:(PSSpecifier *)spec {
    NSString *cur = [self prefStringForKey:[spec propertyForKey:@"key"]
                                 fallback:[spec propertyForKey:@"defaultValue"]];
    NSArray *values = [spec propertyForKey:@"validValues"];
    NSUInteger idx = [values indexOfObject:cur];
    if (idx == NSNotFound) idx = 0;
    NSString *next = values[(idx + 1) % values.count];
    WTE_SetPref([spec propertyForKey:@"key"], next);
    WTE_SyncConfigToReadablePlaces();
    WTE_NotifyChanged();
    [self reloadSpecifiers];
}

// 按钮行的占位读写（Preferences 要求 get/set 可调用，否则整行灰掉）
- (id)getDisplayForSpecifier:(PSSpecifier *)spec {
    return @"";   // PSTitleValueCell 右侧留白，标题已经写在左边
}
- (void)setDisplay:(id)value forSpecifier:(PSSpecifier *)spec {
    // no-op
}

#pragma mark - 只重启键盘进程（不动其它 App）

// 枚举进程表，把微信输入法的键盘扩展进程（wxkb_plugin）杀掉。
// 面板和键盘扩展都以 mobile 身份运行，同 uid 之间 kill 是允许的。
// 杀掉之后系统会在下次弹出键盘时自动用新 dylib 重新拉起 —— 不用注销、不动别的 App。
// ⚠️ 只匹配 wxkb 前缀，绝不碰主 App（否则会把微信一起干掉）。
static int WTE_KillKeyboardWebProcesses(NSMutableArray *report) {
    int killed = 0;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return 0;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return 0;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) { free(procs); return 0; }

    int n = (int)(size / sizeof(struct kinfo_proc));
    pid_t me = getpid();
    for (int i = 0; i < n; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 0 || pid == me) continue;
        char nm[32] = {0};
        strncpy(nm, procs[i].kp_proc.p_comm, sizeof(nm) - 1);
        if (nm[0] == 0) continue;
        NSString *pn = [NSString stringWithUTF8String:nm];
        if (![pn.lowercaseString containsString:@"wxkb"]) continue;
        if (kill(pid, SIGKILL) == 0) {
            killed++;
            if (report) [report addObject:[NSString stringWithFormat:@"%@ (pid %d)", pn, pid]];
        }
    }
    free(procs);
    return killed;
}

- (void)restartKeyboard:(PSSpecifier *)spec {
    NSMutableArray *killedList = [NSMutableArray array];
    int n = WTE_KillKeyboardWebProcesses(killedList);
    NSString *mine = [self myVersion];

    NSString *msg;
    if (n > 0) {
        NSMutableString *d = [NSMutableString string];
        for (NSString *s in killedList) [d appendFormat:@"  %@\n", s];
        msg = [NSString stringWithFormat:
               @"已重启 %d 个键盘进程：\n%@\n"
                "下一次弹出键盘时系统会用 v%@ 重新加载。\n\n"
                "其它 App 完全没受影响，不需要注销。",
               n, d, mine];
    } else {
        msg = @"当前没有正在运行的键盘进程（或者杀不掉）。\n\n"
               "这其实也是好消息 —— 下次弹出键盘自然就是新版。\n"
               "如果还是不生效，点「检查键盘运行版本」看看键盘跑的到底是哪个版本。";
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"重启键盘进程"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 版本一致性 / 注销

// 从诊断报告的 banner 行解析出键盘进程实际运行的版本号
- (NSString *)keyboardRunningVersion {
    NSString *path = WTEP_FindDiagPath();
    if (!path) return nil;
    NSString *s = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
    if (s.length == 0) return nil;
    NSRange r = [s rangeOfString:@"WeTypeEnhance v"];
    if (r.location == NSNotFound || r.location + r.length >= s.length) return nil;
    NSMutableString *v = [NSMutableString string];
    for (NSUInteger i = r.location + r.length; i < s.length; i++) {
        unichar ch = [s characterAtIndex:i];
        if ((ch >= '0' && ch <= '9') || ch == '.') [v appendFormat:@"%C", ch];
        else break;
    }
    return v.length ? v : nil;
}

- (NSString *)myVersion {
    return [[NSBundle bundleForClass:[self class]]
            objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
}

- (void)checkKeyboardVersion:(PSSpecifier *)spec {
    NSString *mine = [self myVersion];
    NSString *running = [self keyboardRunningVersion];
    NSString *msg;
    if (!running) {
        msg = @"没拿到键盘进程的诊断报告。\n\n"
               "先弹一次微信输入法键盘，再回来点这个按钮。";
    } else if ([running isEqualToString:mine]) {
        msg = [NSString stringWithFormat:
               @"键盘进程正在运行 v%@\n面板也是 v%@\n\n✅ 版本一致，设置可以直接生效。", running, mine];
    } else {
        msg = [NSString stringWithFormat:
               @"⚠️ 键盘进程还在跑旧版 v%@\n面板已经是 v%@\n\n"
                "iOS 装 deb 只换磁盘文件，【不会】重启正在运行的键盘扩展进程。\n"
                "所以面板是新的、键盘还是旧代码 —— 怎么调都不会生效。\n\n"
                "→ 点下面的「注销 (Respring)」按钮，注销完再测。",
               running, mine];
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"键盘运行版本"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)respringDevice:(PSSpecifier *)spec {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"注销"
                                                              message:@"将重启 SpringBoard（屏幕会黑几秒），确定吗？"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive
                                        handler:^(__unused UIAlertAction *act) {
        // 老牌做法：给 SpringBoard 发「重启渲染树」的 Darwin 通知（roothide 上通常仍有效）
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("SBRestartRenderTree"), NULL, NULL, TRUE);
        // 兜底：1 秒后再发一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFSTR("SBRestartRenderTree"), NULL, NULL, TRUE);
        });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// 手动把配置刷一遍到所有可读位置（键盘扩展容器 / Media / App Group）
// 用于「改了设置但键盘没反应」时手工重推一次，并直接看到写成功了几处。
- (void)syncToKeyboard:(PSSpecifier *)spec {
    NSArray *ok = WTE_SyncConfigToReadablePlaces();
    NSMutableString *detail = [NSMutableString string];
    NSUInteger shown = 0;
    for (NSString *p in ok) {
        if (shown >= 12) { [detail appendString:@"  …\n"]; break; }
        [detail appendFormat:@"%@\n", p];
        shown++;
    }
    NSString *msg;
    if (ok.count == 0) {
        msg = @"没有写入任何位置。\n\n"
               "说明 Preferences 进程也无法访问键盘扩展容器 / Media。\n"
               "此时只能依赖 cfprefsd 通道 —— 请点「生成诊断报告」，"
               "报告里的「最终采用的来源」如果是 cfprefsd:// 就说明偏好其实是读得到的。";
    } else {
        msg = [NSString stringWithFormat:
               @"已写入 %lu 处：\n\n%@\n"
                "键盘会在下次弹出时读取（或注销一次让插件重新加载）。",
               (unsigned long)ok.count, detail];
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"同步配置"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// 面板入口：查看诊断报告
- (void)openDiagReport:(PSSpecifier *)spec {
    NSString *path = WTEP_FindDiagPath();
    if (!path) {
        // 没有键盘进程报告时，退而求其次看阳性对照（SpringBoard 注入标记）
        NSString *sb = WTEP_FindSpringBoardMarker();
        if (sb) {
            NSString *sbText = [NSString stringWithContentsOfFile:sb encoding:NSUTF8StringEncoding error:nil] ?: @"";
            NSString *head = [NSString stringWithFormat:
                @"【阳性对照】\n注入机制本身是通的（SpringBoard 已成功注入并写入文件）：\n%@\n\n"
                 "但键盘进程没有生成报告 → 说明插件没被加载进微信输入法键盘进程。\n"
                 "可能原因：过滤规则里的 Bundle ID / 进程名与你这个输入法版本不一致。\n\n"
                 "────── 原始内容 ──────\n", sb];
            WTEDiagViewController *vc = [WTEDiagViewController new];
            vc.reportText = [head stringByAppendingString:sbText];
            vc.reportPath = sb;
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationPageSheet;
            [self presentViewController:nav animated:YES completion:nil];
            return;
        }

        // 连对照都没有 → 注入机制或写文件通道有问题
        NSArray *checked = WTEP_DiagSearchPaths();
        NSMutableString *list = [NSMutableString string];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSUInteger shown = 0;
        for (NSString *p in checked) {
            if (shown >= 8) { [list appendString:@"  …\n"]; break; }
            NSString *dir = [p stringByDeletingLastPathComponent];
            BOOL dirExists = [fm fileExistsAtPath:dir];
            [list appendFormat:@"%@ %@\n", dirExists ? @"[目录在]" : @"[无目录]", p];
            shown++;
        }
        NSString *msg = [NSString stringWithFormat:
            @"连阳性对照（SpringBoard 标记）都没有。\n\n"
             "这说明插件的文件写入通道或注入机制本身没生效，和微信输入法无关。\n"
             "（注意：修改设置后需要注销/重启一次）\n\n"
             "已检查 %lu 个位置：\n%@",
            (unsigned long)checked.count, list];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"还没有任何报告"
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil] ?: @"";
    WTEDiagViewController *vc = [WTEDiagViewController new];
    vc.reportText = content;
    vc.reportPath = path;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}


// ═══ v1.9.1：一句话结论 ═══
// 用户不用导出/发文件，点一下就能看到「透明到底卡在哪一步」的结论。
// 只挑关键行（透明自检的判决 / 宿主回执 / 当前配置 / 清了什么），弹窗直接看。
- (void)transVerdict:(PSSpecifier *)spec {
    NSString *path = WTEP_FindDiagPath();
    // v1.9.2：键盘进程报告还没有时，也不要直接放弃 ——
    // 宿主 App 的回执是本进程（设置）直接读容器拿的，不依赖键盘进程。
    NSString *content = path
        ? ([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"")
        : @"";
    NSArray *l1 = @[@"占比", @"判决", @"⇒"];                       // 透明自检
    NSArray *l2 = @[@"注入成功", @"[host", @"宿主回执"];             // 宿主侧
    NSArray *l3 = @[@"当前配置", @"透明:", @"装饰层：摘掉", @"藏掉", @"[allwin]",
                    @"已成功写入", @"最终采用的来源"];

    NSMutableArray *all = [NSMutableArray array];
    for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length == 0) continue;
        [all addObject:t];
    }
    NSMutableArray *p1 = [NSMutableArray array], *p2 = [NSMutableArray array], *p3 = [NSMutableArray array];
    for (NSString *t in all) {
        BOOL hit = NO;
        for (NSString *k in l1) if ([t containsString:k]) { [p1 addObject:t]; hit = YES; break; }
        if (hit) continue;
        for (NSString *k in l2) if ([t containsString:k]) { [p2 addObject:t]; hit = YES; break; }
        if (hit) continue;
        for (NSString *k in l3) if ([t containsString:k]) { [p3 addObject:t]; break; }
    }
    // 每类只留最后几条（= 最近一次运行）
    NSArray *s1 = p1.count > 8 ? [p1 subarrayWithRange:NSMakeRange(p1.count - 8, 8)] : p1;
    NSArray *s2 = p2.count > 6 ? [p2 subarrayWithRange:NSMakeRange(p2.count - 6, 6)] : p2;
    NSArray *s3 = p3.count > 5 ? [p3 subarrayWithRange:NSMakeRange(p3.count - 5, 5)] : p3;

    NSMutableString *msg = [NSMutableString string];
    [msg appendString:@"── 透明自检（关键）──\n"];
    [msg appendString:s1.count ? [s1 componentsJoinedByString:@"\n"] : @"（没有：键盘进程可能没跑新版）\n"];
    [msg appendString:@"\n── 键盘进程里看到的宿主侧 ──\n"];
    [msg appendString:s2.count ? [s2 componentsJoinedByString:@"\n"] : @"（没有）\n"];

    // v1.9.2：真正的宿主回执由本进程（设置）去 App 容器里收 ——
    // 键盘扩展被沙盒挡住，永远收不到这几份。
    NSArray *hosts = WTEP_CollectHostReports();
    [msg appendString:@"\n── 宿主 App 回执（本进程直接读容器）──\n"];
    if (hosts.count) {
        NSMutableArray *trimmed = [NSMutableArray array];
        for (NSString *h in hosts) {
            [trimmed addObject:h.length > 2600 ? [h substringToIndex:2600] : h];
        }
        [msg appendString:[trimmed componentsJoinedByString:@"\n"]];
    } else {
        [msg appendString:@"（一条都没有 ⇒ 宿主 App 侧没被注入，或最近半小时内没弹过键盘）\n"];
    }

    [msg appendString:@"\n── 清理动作 ──\n"];
    [msg appendString:s3.count ? [s3 componentsJoinedByString:@"\n"] : @"（没有）\n"];

    NSString *verdict = @"";
    for (NSString *t in s1) {
        if ([t containsString:@"占比"] && [t containsString:@"②"]) verdict = t;
    }
    NSString *title = verdict.length ? @"透明结论（见正文②）" : @"透明诊断";

    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"复制全文" style:UIAlertActionStyleDefault
                                       handler:^(__unused UIAlertAction *act) {
        [UIPasteboard generalPasteboard].string = msg;
        __strong typeof(weakSelf) s = weakSelf;
        if (s) [s dismissViewControllerAnimated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)vc {    if (!self.pendingSpec) return;
    NSString *hex = WTE_HexFromColor(vc.selectedColor);
    [self.pendingSpec setProperty:hex forKey:@"hexValue"];
    WTE_SetPref([self.pendingSpec propertyForKey:@"key"], hex);
    WTE_NotifyChanged();
    [self reloadSpecifiers];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc {
    if (!self.pendingSpec) return;
    NSString *hex = WTE_HexFromColor(vc.selectedColor);
    WTE_SetPref([self.pendingSpec propertyForKey:@"key"], hex);
    WTE_NotifyChanged();
    self.pendingSpec = nil;
    [self reloadSpecifiers];
}

#pragma mark - 预设

- (void)applyPreset:(NSDictionary *)preset {
    for (NSString *k in preset) {
        WTE_SetPref(k, preset[k]);
    }
    WTE_SetPref(kKeyEnabled, @YES);
    WTE_SetPref(kKeyBgEnabled, @YES);
    WTE_SetPref(kKeyKeyColorEnabled, @YES);
    WTE_SyncConfigToReadablePlaces();
    WTE_NotifyChanged();
    [self reloadSpecifiers];
}

- (void)applyClassic:(PSSpecifier *)s {
    [self applyPreset:@{
        kKeyBgMode: @"solid", kKeyBgColor: @"#D8CFC4", kKeyBgAlpha: @1.0,
        kKeyKeyLetterBg: @"#FFFFFF", kKeyKeyDigitBg: @"#C9BFB2",
        kKeyKeyFuncLeftBg: @"#B7A99A", kKeyKeyFuncRightBg: @"#B7A99A",
        kKeyKeySpaceBg: @"#FFFFFF", kKeyKeyTextColor: @"#5B534A",
        kKeyKeyShape: @"rounded", kKeyKeyCornerRadius: @5.0,
        kKeyLetterGradientEnabled: @NO,
    }];
}
- (void)applyDark:(PSSpecifier *)s {
    [self applyPreset:@{
        kKeyBgMode: @"solid", kKeyBgColor: @"#1C1C1E", kKeyBgAlpha: @1.0,
        kKeyKeyLetterBg: @"#2B2B2E", kKeyKeyDigitBg: @"#1F1F22",
        kKeyKeyFuncLeftBg: @"#3A3A3C", kKeyKeyFuncRightBg: @"#3A3A3C",
        kKeyKeySpaceBg: @"#2B2B2E", kKeyKeyTextColor: @"#FFFFFF",
        kKeyKeyShape: @"rounded", kKeyKeyCornerRadius: @5.0,
        kKeyLetterGradientEnabled: @NO,
    }];
}
- (void)applyViolet:(PSSpecifier *)s {
    [self applyPreset:@{
        kKeyBgMode: @"solid", kKeyBgColor: @"#0E1524", kKeyBgAlpha: @1.0,
        kKeyKeyLetterBg: @"#7C3AED", kKeyKeyDigitBg: @"#A855F7",
        kKeyKeyFuncLeftBg: @"#5B21B6", kKeyKeyFuncRightBg: @"#5B21B6",
        kKeyKeySpaceBg: @"#7C3AED", kKeyKeyTextColor: @"#FFFFFF",
        kKeyKeyShape: @"rounded", kKeyKeyCornerRadius: @8.0,
        kKeyLetterGradientEnabled: @YES,
        kKeyLetterGradientFrom: @"#A855F7", kKeyLetterGradientTo: @"#22D3EE",
    }];
}
- (void)applyOcean:(PSSpecifier *)s {
    [self applyPreset:@{
        kKeyBgMode: @"solid", kKeyBgColor: @"#0E1524", kKeyBgAlpha: @1.0,
        kKeyKeyLetterBg: @"#22D3EE", kKeyKeyDigitBg: @"#0EA5E9",
        kKeyKeyFuncLeftBg: @"#155E75", kKeyKeyFuncRightBg: @"#155E75",
        kKeyKeySpaceBg: @"#22D3EE", kKeyKeyTextColor: @"#04212E",
        kKeyKeyShape: @"circle", kKeyKeyCornerRadius: @10.0,
        kKeyLetterGradientEnabled: @YES,
        kKeyLetterGradientFrom: @"#22D3EE", kKeyLetterGradientTo: @"#A855F7",
    }];
}
- (void)applySunset:(PSSpecifier *)s {
    [self applyPreset:@{
        kKeyBgMode: @"solid", kKeyBgColor: @"#2B1B17", kKeyBgAlpha: @1.0,
        kKeyKeyLetterBg: @"#FF7A45", kKeyKeyDigitBg: @"#FFD166",
        kKeyKeyFuncLeftBg: @"#B4462B", kKeyKeyFuncRightBg: @"#B4462B",
        kKeyKeySpaceBg: @"#FF7A45", kKeyKeyTextColor: @"#2B1B17",
        kKeyKeyShape: @"bevel", kKeyKeyCornerRadius: @6.0,
        kKeyLetterGradientEnabled: @YES,
        kKeyLetterGradientFrom: @"#FFD166", kKeyLetterGradientTo: @"#EF476F",
    }];
}

#pragma mark - 重置

- (void)resetAll:(PSSpecifier *)s {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"恢复默认"
                                                              message:@"将清除所有自定义设置，确定吗？"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        NSString *path = @"/var/mobile/Library/Preferences/com.colorblack.wetypeenhance.plist";
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:path error:nil];
        [fm removeItemAtPath:[@"/var/jb" stringByAppendingString:path] error:nil];
        NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
        for (NSString *k in [ud dictionaryRepresentation].allKeys) [ud removeObjectForKey:k];
        [ud synchronize];
        WTE_NotifyChanged();
        [weakSelf reloadSpecifiers];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
