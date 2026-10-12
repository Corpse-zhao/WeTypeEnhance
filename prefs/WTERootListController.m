// WTERootListController.m
// 微信输入法增强 —— 偏好设置面板
// 完整图形界面：开关 / 滑块 / 取色器 / 相册选图 / 预设 / 重置

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <PhotosUI/PhotosUI.h>
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

#pragma mark - 主控制器

@interface WTERootListController : PSListController <UIColorPickerViewControllerDelegate, PHPickerViewControllerDelegate>
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
    // 点击循环切换：PSButtonCell + get 返回当前中文标题。
    // 不用 PSLinkListCell（无 detail 控制器时点击无响应）。
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:@selector(setChoiceValue:forSpecifier:)
                                                       get:@selector(getChoiceValueForSpecifier:)
                                                    detail:nil
                                                      cell:PSButtonCell
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:def forKey:@"defaultValue"];
    [s setProperty:values forKey:@"validValues"];
    [s setProperty:titles forKey:@"validTitles"];
    [s setProperty:@YES forKey:@"isChoiceRow"];
    [s setButtonAction:@selector(cycleChoice:)];
    return s;
}

- (PSSpecifier *)buttonRow:(NSString *)title action:(SEL)action {
    // 按钮行也要给 get/set，否则整行灰掉
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:@selector(setDisplay:forSpecifier:)
                                                       get:@selector(getDisplayForSpecifier:)
                                                    detail:nil
                                                      cell:PSButtonCell
                                                      edit:nil];
    [s setProperty:NSStringFromSelector(action) forKey:@"action"];
    [s setButtonAction:action];
    return s;
}

- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    // 版本号从 bundle 读，避免写死后与实际包版本不一致
    NSString *ver = [[NSBundle bundleForClass:[self class]]
                     objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    [specs addObject:[self group:[NSString stringWithFormat:
        @"微信输入法增强 v%@\n功能对等移植自「原生输入法增强」", ver]]];
    [specs addObject:[self switchRow:@"启用" key:kKeyEnabled def:YES]];

    // ---- 1. 键盘背景 ----
    [specs addObject:[self group:@"键盘背景"]];
    [specs addObject:[self switchRow:@"开启背景" key:kKeyBgEnabled def:NO]];
    [specs addObject:[self choiceRow:@"背景模式" key:kKeyBgMode def:@"solid"
                              values:@[@"solid", @"image", @"transparent"]
                              titles:@[@"纯色", @"图片", @"整键盘透明"]]];
    [specs addObject:[self colorRow:@"背景颜色" key:kKeyBgColor def:@"#101826"]];
    [specs addObject:[self sliderRow:@"背景不透明度" key:kKeyBgAlpha def:1.0 min:0.0 max:1.0]];
    [specs addObject:[self buttonRow:@"从相册选择背景图" action:@selector(pickBackgroundImage:)]];
    [specs addObject:[self switchRow:@"整键盘透明" key:kKeyKeyboardTransparent def:NO]];

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
    [specs addObject:[self buttonRow:@"生成诊断报告" action:@selector(openDiagReport:)]];
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
    WTE_NotifyChanged();
    [self reloadSpecifiers];
}

// 按钮行的占位读写（Preferences 要求 get/set 可调用，否则整行灰掉）
- (id)getDisplayForSpecifier:(PSSpecifier *)spec {
    return [spec propertyForKey:@"title"] ?: @"";
}
- (void)setDisplay:(id)value forSpecifier:(PSSpecifier *)spec {
    // no-op
}

// 面板入口：查看诊断报告
- (void)openDiagReport:(PSSpecifier *)spec {
    NSString *path = WTEP_FindDiagPath();
    if (!path) {
        // 列出已检查的位置，便于判断到底是「没注入」还是「写不进去」
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
            @"未找到诊断报告，共检查 %lu 个位置：\n\n%@\n\n可能原因：\n1) 插件没注入进键盘进程\n2) 键盘进程沙盒禁止写文件\n\n请先确认：去微信调出键盘打几个字，键盘有没有变成「橙色背景 + 红色按键」？\n· 变红 → 注入和 hook 正常，只是读写文件被沙盒拦了\n· 没变 → 注入没成功",
            (unsigned long)checked.count, list];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"还没有诊断报告"
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


- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)vc {
    if (!self.pendingSpec) return;
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

#pragma mark - 相册选图

- (void)pickBackgroundImage:(PSSpecifier *)spec {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter imagesFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    NSItemProvider *itemProvider = results.firstObject.itemProvider;
    if (![itemProvider canLoadObjectOfClass:[UIImage class]]) return;

    __weak typeof(self) weakSelf = self;
    [itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        if (![object isKindOfClass:[UIImage class]]) return;
        UIImage *image = (UIImage *)object;
        // 裁切成键盘比例，控制文件体积
        UIImage *cropped = [weakSelf cropToKeyboardAspect:image];
        NSData *png = UIImagePNGRepresentation(cropped);
        if (!png) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray *paths = @[
                @"/var/mobile/Library/Application Support/WeTypeEnhance",
                @"/var/jb/var/mobile/Library/Application Support/WeTypeEnhance",
            ];
            NSFileManager *fm = [NSFileManager defaultManager];
            for (NSString *dir in paths) {
                NSError *e = nil;
                if (![fm fileExistsAtPath:dir]) {
                    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&e];
                }
                if ([fm fileExistsAtPath:dir]) {
                    NSString *dest = [dir stringByAppendingPathComponent:@"bg.png"];
                    [png writeToFile:dest atomically:YES];
                }
            }
            WTE_SetPref(kKeyBgMode, @"image");
            WTE_SetPref(kKeyBgEnabled, @YES);
            WTE_NotifyChanged();
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf reloadSpecifiers];
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已设置"
                                                                          message:@"背景图已保存并生效"
                                                                   preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:a animated:YES completion:nil];
            });
        });
    }];
}

- (UIImage *)cropToKeyboardAspect:(UIImage *)image {
    CGSize sz = image.size;
    if (sz.width <= 0 || sz.height <= 0) return image;
    // 键盘约 2.6 : 1（宽:高）
    CGFloat targetRatio = 2.6;
    CGFloat curRatio = sz.width / sz.height;
    CGRect rect;
    if (curRatio > targetRatio) {
        CGFloat w = sz.height * targetRatio;
        rect = CGRectMake((sz.width - w) / 2.0, 0, w, sz.height);
    } else {
        CGFloat h = sz.width / targetRatio;
        rect = CGRectMake(0, (sz.height - h) / 2.0, sz.width, h);
    }
    CGFloat scale = image.scale;
    CGRect px = CGRectMake(rect.origin.x * scale, rect.origin.y * scale,
                           rect.size.width * scale, rect.size.height * scale);
    CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, px);
    if (!cg) return image;
    UIImage *out = [UIImage imageWithCGImage:cg scale:scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    return out;
}

#pragma mark - 预设

- (void)applyPreset:(NSDictionary *)preset {
    for (NSString *k in preset) {
        WTE_SetPref(k, preset[k]);
    }
    WTE_SetPref(kKeyEnabled, @YES);
    WTE_SetPref(kKeyBgEnabled, @YES);
    WTE_SetPref(kKeyKeyColorEnabled, @YES);
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
