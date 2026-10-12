// WTERootListController.m
// 微信输入法增强 —— 偏好设置面板
// 完整图形界面：开关 / 滑块 / 取色器 / 相册选图 / 预设 / 重置

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import "../WeTypeEnhanceCommon.h"

#pragma mark - 自定义取色单元格

@interface WTEColorCell : PSTableCell
@property (nonatomic, strong) UIView *swatch;
@end

@implementation WTEColorCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        _swatch = [[UIView alloc] initWithFrame:CGRectZero];
        _swatch.translatesAutoresizingMaskIntoConstraints = NO;
        _swatch.layer.cornerRadius = 6.0;
        _swatch.layer.borderWidth = 0.5;
        _swatch.layer.borderColor = [[UIColor separatorColor] CGColor];
        [self.contentView addSubview:_swatch];
        [NSLayoutConstraint activateConstraints:@[
            [_swatch.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_swatch.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
            [_swatch.widthAnchor constraintEqualToConstant:29],
            [_swatch.heightAnchor constraintEqualToConstant:29],
        ]];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    NSString *hex = [self.specifier propertyForKey:@"hexValue"];
    if (!hex) {
        id v = WTE_GetPref([specifier propertyForKey:@"key"]);
        hex = [v isKindOfClass:[NSString class]] ? v : [specifier propertyForKey:@"defaultHex"];
    }
    UIColor *c = WTE_ColorFromHex(hex) ?: [UIColor grayColor];
    self.swatch.backgroundColor = c;
    self.detailTextLabel.text = hex;
}

@end

#pragma mark - 主控制器

@interface WTERootListController : PSListController <UIColorPickerViewControllerDelegate, PHPickerViewControllerDelegate>
@property (nonatomic, strong) PSSpecifier *pendingSpec;
@end

@implementation WTERootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self buildSpecifiers];
    }
    return _specifiers;
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
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:nil
                                                       get:nil
                                                    detail:nil
                                                      cell:NSClassFromString(@"WTEColorCell")
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:def forKey:@"defaultHex"];
    [s setProperty:def forKey:@"hexValue"];
    return s;
}

- (PSSpecifier *)choiceRow:(NSString *)title key:(NSString *)key def:(NSString *)def
                    values:(NSArray *)values titles:(NSArray *)titles {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:@selector(setPref:forSpecifier:)
                                                       get:@selector(getPrefForSpecifier:)
                                                    detail:nil
                                                      cell:PSLinkListCell
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:def forKey:@"defaultValue"];
    [s setProperty:values forKey:@"validValues"];
    [s setProperty:titles forKey:@"validTitles"];
    [s setProperty:@(0) forKey:@"default"];
    return s;
}

- (PSSpecifier *)buttonRow:(NSString *)title action:(SEL)action {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:nil
                                                       get:nil
                                                    detail:nil
                                                      cell:PSButtonCell
                                                      edit:nil];
    [s setProperty:NSStringFromSelector(action) forKey:@"action"];
    [s setButtonAction:action];
    return s;
}

- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    [specs addObject:[self group:@"微信输入法增强 v1.0.0\n功能对等移植自「原生输入法增强」"]];
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

#pragma mark - 取色器

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([spec.cellClass isEqual:NSClassFromString(@"WTEColorCell")]) {
        self.pendingSpec = spec;
        UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
        picker.delegate = self;
        picker.supportsAlpha = YES;
        NSString *cur = [spec propertyForKey:@"hexValue"]
                        ?: WTE_StringPref([spec propertyForKey:@"key"], [spec propertyForKey:@"defaultHex"]);
        UIColor *c = WTE_ColorFromHex(cur);
        if (c) picker.selectedColor = c;
        [self presentViewController:picker animated:YES completion:nil];
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
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
