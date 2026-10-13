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
static BOOL gDiagDumpedTree = NO;
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

// —— 键盘视图树快照 ——
// 背景类问题光靠猜没用，这里把最外层键盘容器的前几层子树打出来：
// 类名 / frame / 底色 RGBA / 是否不透明 / layer 有没有内容 / 有没有自己的模糊效果。
// 谁在画底色一眼就看出来。
static void WTE_DumpTree(UIView *v, int depth, NSMutableString *out) {
    if (!v || depth > 3 || out.length > 5000) return;
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                      withString:@" " startingAtIndex:0];
    CGFloat r = 0, g = 0, b = 0, a = 0;
    CGColorRef cg = v.backgroundColor.CGColor;
    if (cg) {
        CGColorSpaceRef cs = CGColorGetColorSpace(cg);
        CGColorSpaceModel model = cs ? CGColorSpaceGetModel(cs) : kCGColorSpaceModelUnknown;
        const CGFloat *comp = CGColorGetComponents(cg);
        size_t n = CGColorGetNumberOfComponents(cg);
        if (comp) {
            if (model == kCGColorSpaceModelMonochrome && n >= 2) { r = g = b = comp[0]; a = comp[1]; }
            else if (n >= 4) { r = comp[0]; g = comp[1]; b = comp[2]; a = comp[3]; }
            else if (n >= 2) { r = g = b = comp[0]; a = comp[1]; }
        }
    }
    [out appendFormat:@"%@%@ f(%.0f,%.0f,%.0f,%.0f) bg(%.2f,%.2f,%.2f,%.2f) op=%d ct=%d al=%.2f\n",
     pad, NSStringFromClass([v class]),
     v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height,
     r, g, b, a, v.isOpaque ? 1 : 0,
     v.layer.contents ? 1 : 0, v.alpha];
    for (UIView *s in v.subviews) WTE_DumpTree(s, depth + 1, out);
}

// 诊断用小工具（实现在下面的「透明底清理」一节，这里先声明）
static void WTE_CollectViewLayers(UIView *v, NSMutableSet *set, int depth);
static int  WTE_CountDecorationSublayers(UIView *v, NSSet *viewLayers);
static NSString *WTE_DecorationLayerNames(UIView *v, NSSet *viewLayers, int maxN);

// 这里不用 UIColor 的私有方法，只走公开的 getRed/green/blue/alpha
static void WTE_DiagColorRGBA(UIColor *col, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    *r = *g = *b = *a = 0;
    if (!col) return;
    @try {
        CGFloat rr = 0, gg = 0, bb = 0, aa = 0;
        if ([col getRed:&rr green:&gg blue:&bb alpha:&aa]) { *r = rr; *g = gg; *b = bb; *a = aa; return; }
        CGFloat w = 0, al = 0;
        if ([col getWhite:&w alpha:&al]) { *r = *g = *b = w; *a = al; }
    } @catch (__unused NSException *e) {}
}

// 本类【自己】是否实现了某个方法（不沿继承链）—— 用来判断「是不是它自己画的」
static BOOL WTE_DiagImplements(Class c, const char *selName) {
    if (!c) return NO;
    SEL sel = sel_registerName(selName);
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { found = YES; break; }
    }
    if (list) free(list);
    return found;
}

// —— 祖先链快照 ——
// 背景类问题的另一半线索：底色可能压根不在键盘子树里，而在【祖先】或
// 【同层兄弟】上。这里从键盘容器一路往上打到窗口（含窗口），
// 并把每一层排在它前面的兄弟视图也列出来 —— 谁在画底色一眼可见。
//
// v1.8.5 追加：sl=装饰子层数 / f=CA滤镜 / bf=背景滤镜 / dR=自己实现了 drawRect:
// 这几个字段是关键 —— 视图树的 backgroundColor 和 layer.contents 都清干净了
// 却还能看见底色，那底色只可能藏在这四样里：
//   · layer.sublayers 里的【装饰层】（渐变层 / 形状层 / 边框层，完全不在 subviews 里）
//   · layer.filters / layer.backgroundFilters（CA 滤镜，毛玻璃「材质」就是这么来的）
//   · 视图自己 drawRect: 画进 backing store 的内容
static void WTE_DumpOneLine(UIView *v, const char *tag, NSMutableString *out) {
    if (!v) return;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    WTE_DiagColorRGBA(v.backgroundColor, &r, &g, &b, &a);

    int filters = 0, bgFilters = 0;
    @try {
        id f = [v.layer valueForKey:@"filters"];
        if ([f isKindOfClass:[NSArray class]] && [(NSArray *)f count] > 0) filters = (int)[(NSArray *)f count];
        id bf = [v.layer valueForKey:@"backgroundFilters"];
        if ([bf isKindOfClass:[NSArray class]] && [(NSArray *)bf count] > 0) bgFilters = (int)[(NSArray *)bf count];
    } @catch (__unused NSException *e) {}

    [out appendFormat:
     @"  %s %@ f(%.0f,%.0f,%.0f,%.0f) bg(%.2f,%.2f,%.2f,%.2f) op=%d ct=%d al=%.2f z=%lu "
     @"sl=%lu f=%d bf=%d dR=%d ivs=%@\n",
     tag, NSStringFromClass([v class]),
     v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height,
     r, g, b, a, v.isOpaque ? 1 : 0, v.layer.contents ? 1 : 0, v.alpha,
     (unsigned long)(v.superview ? [v.superview.subviews indexOfObject:v] : 0),
     (unsigned long)v.layer.sublayers.count, filters, bgFilters,
     WTE_DiagImplements([v class], "drawRect:") ? 1 : 0,
     (v.layer.delegate == v ? @"self" : @"other")];
}

static void WTE_DumpAncestors(UIView *kb, NSMutableString *out) {
    if (!kb || !out) return;
    [out appendString:@"\n===== 键盘祖先链 + 同层前置兄弟 =====\n"];
    UIView *p = kb.superview;
    UIView *child = kb;
    int hops = 0;
    while (p && hops < 12) {
        WTE_DumpOneLine(p, "ANC ", out);
        if ([p isKindOfClass:[UIWindow class]]) {
            UIWindow *w = (UIWindow *)p;
            [out appendFormat:@"  ^^ 这是窗口，祖先链到此为止；window.opaque=%d 窗口层子层=%lu\n",
             w.opaque ? 1 : 0, (unsigned long)w.layer.sublayers.count];
            break;
        }
        // 同层里排在「kb 这一支」前面（z 序更低）的兄弟
        for (UIView *sib in p.subviews) {
            if (sib == child) break;
            WTE_DumpOneLine(sib, "  ├─SIB", out);
        }
        child = p;
        p = p.superview;
        hops++;
    }
    if (!p || hops >= 12) [out appendString:@"  (祖先链没走到窗口)\n"];
}

// —— 底板普查：清完之后，整个窗口里还有谁「画得出东西」？——
// 这是这个 bug 的判决性证据：
//   · 有输出 → 照单抓人，下一版精准打掉
//   · 空     → 说明底色根本不在本进程的视图树里（只在宿主 App / 系统侧合成），
//              那就必须改用「注入宿主 App」的路线
static void WTE_DumpPaintCensus(UIView *kb, NSMutableString *out) {
    if (!kb || !out) return;
    UIWindow *w = kb.window;
    if (!w) { [out appendString:@"\n===== 底板普查：拿不到窗口，跳过 =====\n"]; return; }

    NSMutableSet *viewLayers = [NSMutableSet set];
    WTE_CollectViewLayers(w, viewLayers, 0);

    [out appendString:@"\n===== 清完之后「还能画出底色」的东西（底板普查）=====\n"];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
    int guard = 0, lines = 0;
    while (stack.count > 0 && guard < 5000) {
        guard++;
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIView *s in v.subviews) [stack addObject:s];

        NSMutableArray *why = [NSMutableArray array];
        CGFloat r = 0, g = 0, b = 0, a = 0;
        WTE_DiagColorRGBA(v.backgroundColor, &r, &g, &b, &a);
        if (a > 0.02) [why addObject:[NSString stringWithFormat:@"bg(%.2f,%.2f,%.2f,%.2f)", r, g, b, a]];
        if (v.layer.contents) [why addObject:@"contents"];
        int deco = WTE_CountDecorationSublayers(v, viewLayers);
        if (deco > 0) {
            [why addObject:[NSString stringWithFormat:@"装饰子层×%d[%@]", deco,
                            WTE_DecorationLayerNames(v, viewLayers, 3)]];
        }
        if ([v isKindOfClass:[UIVisualEffectView class]] && ((UIVisualEffectView *)v).effect) {
            [why addObject:@"毛玻璃"];
        }
        @try {
            id f = [v.layer valueForKey:@"filters"];
            if ([f isKindOfClass:[NSArray class]] && [(NSArray *)f count] > 0) [why addObject:@"filters"];
            id bf = [v.layer valueForKey:@"backgroundFilters"];
            if ([bf isKindOfClass:[NSArray class]] && [(NSArray *)bf count] > 0) [why addObject:@"backgroundFilters"];
        } @catch (__unused NSException *e) {}
        if (v.layer.borderWidth > 0.01) {
            [why addObject:[NSString stringWithFormat:@"border%.1f", v.layer.borderWidth]];
        }
        if (WTE_DiagImplements([v class], "drawRect:")) [why addObject:@"drawRect:"];
        if (v.alpha < 0.99) [why addObject:[NSString stringWithFormat:@"alpha%.2f", v.alpha]];

        if (why.count > 0 && lines < 140) {
            lines++;
            [out appendFormat:@"  %@ f(%.0f,%.0f,%.0f,%.0f) → %@%@\n",
             NSStringFromClass([v class]),
             v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height,
             [why componentsJoinedByString:@", "],
             (v == kb ? @"   ←【键盘容器本身】" : @"")];
        }
    }
    if (lines == 0) {
        [out appendString:@"  （空！本进程整个窗口里没有任何视图还能画底色\n"
                          "    ⇒ 底色来自【进程外 / 系统侧合成】，必须走「注入宿主 App」路线）\n"];
    }
}

// —— 收集宿主 App 的回执（v1.8.8）——
// 宿主 App 被沙盒关在自己容器里，写不了 /var/mobile/Media（v1.8.7 报告已证实），
// 只能各写自己容器里的 host.txt。键盘扩展这边去 Application 容器里把它们捞出来 ——
// 这是验证「过滤规则到底有没有把宿主 App 也注入到」的唯一通道：
//   · 捞到了 → 注入成功，问题在「清得不够」（那就看它清掉了哪些视图）
//   · 捞不到 → 过滤规则没铺开，得换注入写法（跟 v1.8.8 的清理逻辑无关）
static void WTE_DumpHostReports(NSMutableString *out) {
    if (!out) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *bases = @[@"/var/mobile/Containers/Data/Application",
                       @"/var/mobile/Containers/Data/PluginKitPlugin"];
    int files = 0;
    for (NSString *base in bases) {
        NSArray *subs = [fm contentsOfDirectoryAtPath:base error:nil];
        if (!subs.count) {
            [out appendFormat:@"  宿主回执：%@ 列不出来（沙盒挡住）\n", base];
            continue;
        }
        for (NSString *sub in subs) {
            if (files >= 8) break;
            NSString *f = [[base stringByAppendingPathComponent:sub]
                           stringByAppendingPathComponent:@"Documents/WeTypeEnhance/host.txt"];
            if (![fm fileExistsAtPath:f]) continue;
            NSString *txt = [NSString stringWithContentsOfFile:f
                                                      encoding:NSUTF8StringEncoding error:nil];
            if (!txt.length) continue;
            files++;
            if (txt.length > 3000) txt = [txt substringFromIndex:txt.length - 3000];
            [out appendFormat:@"\n----- 宿主回执 #%d %@ -----\n%@\n", files, f, txt];
        }
    }
    if (files == 0) {
        [out appendString:@"  （一处都没捞到 ⇒ 宿主 App 侧没被注入，或沙盒挡住了；\n"
                         "    若地址列不出来 = 沙盒挡住，得改用别的取证方式）\n"];
    }
}

// —— v1.9.0：把本进程【所有窗口】都列出来 ——
// 之前的普查只看 kb.window。万一输入法自己开了第二个窗口垫底色，我们永远扫不到。
static void WTE_DumpAllWindows(NSMutableString *out) {
    if (!out) return;
    NSArray *wins = nil;
    @try {
        Class appCls = NSClassFromString(@"UIApplication");
        if (!appCls) return;
        id app = ((id (*)(id, SEL))objc_msgSend)(appCls, NSSelectorFromString(@"sharedApplication"));
        wins = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"windows"));
    } @catch (__unused NSException *e) { return; }
    if (![wins isKindOfClass:[NSArray class]]) return;

    [out appendFormat:@"\n===== 本进程共 %lu 个窗口 =====\n", (unsigned long)wins.count];
    for (id o in wins) {
        if (![o isKindOfClass:[UIWindow class]]) continue;
        UIWindow *w = (UIWindow *)o;
        CGFloat r = 0, g = 0, b = 0, a = 0;
        WTE_DiagColorRGBA(w.backgroundColor, &r, &g, &b, &a);
        [out appendFormat:@"  %@ f(%.0f,%.0f,%.0f,%.0f) bg(%.2f,%.2f,%.2f,%.2f) "
                          @"hidden=%d alpha=%.2f op=%d 子视图=%lu 层子层=%lu\n",
         NSStringFromClass([w class]),
         w.frame.origin.x, w.frame.origin.y, w.frame.size.width, w.frame.size.height,
         r, g, b, a, w.hidden ? 1 : 0, w.alpha, w.isOpaque ? 1 : 0,
         (unsigned long)w.subviews.count, (unsigned long)w.layer.sublayers.count];
    }
}

// —— v1.9.0：透明自检（判决性实验）——
// 光看视图树猜不出谁在画底色，那就直接【渲染成位图、数不透明像素】：
//   ① 整个窗口原样渲染           → 键盘本来就画着按键，占比高是正常的
//   ② 把键盘容器藏掉再渲染一次    → 剩下的就是「键盘内容之外」的底色
//      · ≈0%  ⇒ 本进程窗口除了键盘内容什么都没画 ⇒ 底色 100% 在宿主 App 进程
//      · >0%  ⇒ 本进程窗口里还有别的东西在画底色 ⇒ 看窗口列表 + 普查去抓它
// （hidden 的改动在同一个 RunLoop 里恢复，不会真的闪一帧）
static double WTE_RenderOpaqueRatio(UIView *v) {
    if (!v) return -1;
    CGSize size = v.bounds.size;
    if (size.width < 8 || size.height < 8) return -1;
    NSInteger W = 32, H = 20;
    unsigned char *buf = (unsigned char *)malloc((size_t)(W * H * 4));
    if (!buf) return -1;
    memset(buf, 0, (size_t)(W * H * 4));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) { free(buf); return -1; }
    CGContextScaleCTM(c, (CGFloat)W / size.width, (CGFloat)H / size.height);
    @try {
        [v drawViewHierarchyInRect:CGRectMake(0, 0, size.width, size.height)
                afterScreenUpdates:NO];
    } @catch (__unused NSException *e) { CGContextRelease(c); free(buf); return -1; }
    CGContextRelease(c);
    long opaque = 0, total = W * H;
    for (long i = 0; i < total; i++) if (buf[i * 4 + 3] > 24) opaque++;
    free(buf);
    return (double)opaque / (double)total;
}

static void WTE_TransparentSelfTest(UIView *kb, NSMutableString *out) {
    if (!kb || !kb.window || !out) return;
    double rAll = WTE_RenderOpaqueRatio(kb.window);
    BOOL wasHidden = kb.hidden;
    kb.hidden = YES;
    double rBg = WTE_RenderOpaqueRatio(kb.window);
    kb.hidden = wasHidden;

    [out appendString:@"\n===== 透明自检（把窗口渲染成位图数不透明像素）=====\n"];
    if (rAll < 0 || rBg < 0) { [out appendString:@"  （渲染失败，本机不支持采样）\n"]; return; }
    [out appendFormat:@"  ① 整个窗口原样渲染       不透明占比 %5.1f%%（按键本来就不透明，正常）\n", rAll * 100];
    [out appendFormat:@"  ② 藏掉键盘容器后再渲染    不透明占比 %5.1f%%\n", rBg * 100];
    if (rBg < 0.02) {
        [out appendString:@"  ⇒ 判决：本进程窗口除了键盘内容【什么都没画】\n"
                          "    剩下的底色 100% 来自宿主 App 进程 —— 看上面的「宿主回执」确认注入有没有铺开\n"];
    } else {
        [out appendString:@"  ⇒ 判决：本进程窗口里【还有别的东西在画底色】！\n"
                          "    拿上面的「窗口列表」和「底板普查」对，找出那个大面积的层\n"];
    }
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
@property (nonatomic, assign) BOOL keyboardTransparent;
@property (nonatomic, copy)   NSString *transScope;   // bg / all
@property (nonatomic, assign) double    keyOpacity;   // v1.9.0 按键透明度（透明底模式专用）

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
    if (![c.bgMode isEqualToString:@"transparent"]) c.bgMode = @"solid";  // 只保留 纯色 / 透明底
    c.bgColor             = WTE_ColorFromHex(WTE_StringPref(kKeyBgColor, @"#1C1C1E")) ?: [UIColor clearColor];
    c.bgAlpha             = WTE_DoublePref(kKeyBgAlpha, 1.0);
    // 「整键盘透明」并入背景模式：mode=transparent 即透明底
    c.keyboardTransparent = [c.bgMode isEqualToString:@"transparent"];
    // v1.8.7 透明范围：bg = 只透底板（按键保留白帽） / all = 整键盘透明（按键帽也摘掉）
    // v1.8.9 默认改回 bg：整键盘透明会把按键帽摘掉/改透，用户实测「打字按不到字母」。
    // 想要更透的效果自己去面板切「整键盘透明」（按键会变半透明，仍可见）。
    c.transScope = WTE_StringPref(kKeyTransScope, @"bg");
    if (![c.transScope isEqualToString:@"bg"] && ![c.transScope isEqualToString:@"all"])
        c.transScope = @"bg";

    // v1.9.0 按键透明度：1.0 = 不透明（默认，打字最清楚），0 = 完全透明。
    // 只在透明底模式下生效，越界值一律夹回 [0,1]。
    c.keyOpacity = WTE_DoublePref(kKeyKeyOpacity, 1.0);
    if (!(c.keyOpacity >= 0.0)) c.keyOpacity = 0.0;
    if (c.keyOpacity > 1.0)     c.keyOpacity = 1.0;

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
#if WTE_LOG_ENABLE
    gDiagDumpedTree = NO;               // 配置变了，允许下一轮再拍一张视图树快照
#endif
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

// 只在颜色真的变了才写。冗余写 backgroundColor 会触发重绘/重排，
// 在 -layoutSubviews 里反复写就是「卡死」的温床。
static void WTE_SetBackground(UIView *v, UIColor *col) {
    if (!v || !col) return;
    UIColor *cur = v.backgroundColor;
    if (cur == col) return;
    CGColorRef a = cur.CGColor, b = col.CGColor;
    if (a && b && CGColorEqualToColor(a, b)) return;
    v.backgroundColor = col;
}

static void WTE_SetClearBackground(UIView *v) {
    if (!v) return;
    UIColor *bg = v.backgroundColor;
    if (!bg) return;
    CGColorRef cg = bg.CGColor;
    if (cg && CGColorGetAlpha(cg) <= 0.001) return;   // 已经透明，别碰
    v.backgroundColor = [UIColor clearColor];
}

// 把「中间层」自己画的背景彻底抹掉：底色 / 背景图 / layer 内容 / 毛玻璃。
// 微信输入法键盘的可见底色往往不是 backgroundColor，而是一张纹理图
// （layer.contents 或 UIImageView.image）或毛玻璃层 —— 只清颜色是没用的。
// ⚠️ 绝不能在「按键 / 工具栏内部」调用：那里面有字母、图标，
//    清掉 layer.contents 会把 UILabel 的文字一起抹掉。
//
// 关于 setBackgroundEffects:：它没有 getter，读不到当前值，
// 而它本身会触发重新布局（写多了就是卡死）。所以用「配置令牌」标记，
// 同一个配置下每个视图只调一次。配置一变（面板改设置）自动重新武装。
static const void *kWTEgBgEffectsKey = &kWTEgBgEffectsKey;

static void WTE_ClearLayerPaint(UIView *v) {
    if (!v) return;
    WTE_SetClearBackground(v);
    if (v.isOpaque) v.opaque = NO;

    if ([v isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)v;
        if (iv.image) iv.image = nil;
    } else if (![v isKindOfClass:[UILabel class]]) {
        // UILabel 的 layer.contents 就是它渲染出的文字，必须跳过
        if (v.layer.contents) v.layer.contents = nil;
    }

    if ([v isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *ev = (UIVisualEffectView *)v;
        if (ev.effect) ev.effect = nil;
    }

    NSUInteger token = (NSUInteger)(uintptr_t)gConfig;
    NSNumber *prev = objc_getAssociatedObject(v, kWTEgBgEffectsKey);
    if (!prev || prev.unsignedIntegerValue != token) {
        objc_setAssociatedObject(v, kWTEgBgEffectsKey, @(token),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SEL sfx = NSSelectorFromString(@"setBackgroundEffects:");
        if ([v respondsToSelector:sfx]) {
            ((void (*)(id, SEL, id))objc_msgSend)(v, sfx, nil);
        }
    }
}

// —— 透明底：把「键盘容器背后的所有底色」全部清掉 ——
//
// 背景到底画在哪，只有两个可能，两个都要处理：
//   A. 画在我们的【祖先】上（UIInputSetHostView / UIInputSetContainerView /
//      毛玻璃层 / 键盘窗口本身）—— 祖先永远在子视图下面，一清就透出去。
//   B. 画在同一层里【排在我们前面（z 序更低 = 更靠后）的兄弟视图】上。
//      v1.8.3 之前只清了祖先、没管兄弟，所以可能是 B 的情况一直没修好。
//
// ⚠️ 关键认识：键盘扩展运行在【自己独立的进程和窗口】里，
//    这棵树里的东西全都是键盘自己的 —— 可以放心一路清到窗口，
//    绝不可能把宿主 App（微信）的界面搞透明。
//
// ⚠️ 但「清背景」和「清内容」必须分开：字母、图标、候选词一旦被清掉，
//    键盘就废了。所以这里用两条保守规则：
//      · 祖先 → 只清它【自己那一层】的底色/纹理（绝不下探，不碰后代内容）
//      · 兄弟 → 只有「整棵子树没有任何文字/图片」才敢清；
//              例外：面积 ≥ 键盘 85% 宽 × 50% 高的图片 = 皮肤纹理图，
//              那是背景不是图标，也要清。

// 子树里有没有「真正的内容」（文字 / 图片）？没有 = 纯背景层，可以放心清。
static BOOL WTE_SubtreeHasContent(UIView *v, int depth) {
    if (!v || depth > 8) return YES;   // 太深就保守当它有内容，宁可漏清不可误清
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UILabel class]]) return YES;
        if ([s isKindOfClass:[UIImageView class]] && ((UIImageView *)s).image) return YES;
        if (WTE_SubtreeHasContent(s, depth + 1)) return YES;
    }
    return NO;
}

// 连子树一起清（只在「确认无内容」或「确认是皮肤大图」时才用）
static void WTE_ClearLayerPaintDeep(UIView *v) {
    if (!v) return;
    WTE_ClearLayerPaint(v);
    for (UIView *s in [v.subviews copy]) WTE_ClearLayerPaintDeep(s);
}

// 大面积图片 = 皮肤/纹理背景（小面积图片 = 图标，不动）
static BOOL WTE_LooksLikeSkinImage(UIView *v, CGSize kb) {
    if (![v isKindOfClass:[UIImageView class]]) return NO;
    if (!((UIImageView *)v).image) return NO;
    if (kb.width <= 1.0 || kb.height <= 1.0) return NO;
    CGSize s = v.bounds.size;
    return (s.width >= kb.width * 0.85 && s.height >= kb.height * 0.5);
}

// ═══════════ v1.8.5：最后两个藏身处 ═══════════
//
// v1.8.4 的诊断报告把范围逼死了：视图树里所有 backgroundColor 全是 0、
// 所有 layer.contents 全是 0、祖先链也全清干净了 —— 但底色还在。
//
// 那么底色只可能藏在「不看视图树就看不见」的地方，一共三样：
//   ① layer.sublayers 里的【装饰层】：渐变层 / 形状层 / 边框层。
//      它们根本不出现在 subviews 里，只清 backgroundColor 一万次也扫不到。
//   ② layer.filters / layer.backgroundFilters：CoreAnimation 滤镜。
//      「毛玻璃 / 玻璃材质」背景就是这么实现的 —— 它不是一个视图，
//      而是让图层对【身后内容】做一次高斯模糊。
//      ⚠️ 注意它和 UIVisualEffectView 是两码事：前者是图层滤镜，
//         后者是一个真实视图（我们早就清过了）。这就是之前一直漏掉的那一个。
//   ③ 视图自己用 drawRect: 画进 backing store 的内容。
//
// 判断「哪些子层是装饰层」有个精确又安全的办法：
//   把整棵窗口树里【所有视图的 layer】收集成一个集合，
//   那么某个 layer 的 sublayers 中不在这个集合里的，就一定不是任何视图的层
//   → 纯装饰层，删掉它不会带走任何视图的内容。

static void WTE_CollectViewLayers(UIView *v, NSMutableSet *set, int depth) {
    if (!v || !set || depth > 40) return;
    if (v.layer) [set addObject:[NSValue valueWithPointer:(__bridge const void *)(v.layer)]];
    for (UIView *s in v.subviews) WTE_CollectViewLayers(s, set, depth + 1);
}

static int WTE_CountDecorationSublayers(UIView *v, NSSet *viewLayers) {
    if (!v || !viewLayers) return 0;
    int n = 0;
    for (CALayer *sl in v.layer.sublayers) {
        NSValue *pv = [NSValue valueWithPointer:(__bridge const void *)(sl)];
        if (![viewLayers containsObject:pv]) n++;
    }
    return n;
}

// 装饰层的类名（诊断用：CATextLayer / CAGradientLayer / CALayer …）
static NSString *WTE_DecorationLayerNames(UIView *v, NSSet *viewLayers, int maxN) {
    if (!v || !viewLayers) return @"";
    NSMutableArray *a = [NSMutableArray array];
    for (CALayer *sl in v.layer.sublayers) {
        NSValue *pv = [NSValue valueWithPointer:(__bridge const void *)(sl)];
        if ([viewLayers containsObject:pv]) continue;
        [a addObject:NSStringFromClass([sl class])];
        if ((int)a.count >= maxN) break;
    }
    return [a componentsJoinedByString:@"/"];
}

// 抹掉一个图层身上的滤镜（毛玻璃材质就是这么来的）。
// filters / backgroundFilters 在 iOS 的 CALayer 上不是公开属性，所以走 KVC + @try。
static void WTE_ClearLayerFilters(UIView *v) {
    if (!v) return;
    @try {
        id f = [v.layer valueForKey:@"filters"];
        if ([f isKindOfClass:[NSArray class]] && [(NSArray *)f count] > 0) {
            [v.layer setValue:nil forKey:@"filters"];
        }
    } @catch (__unused NSException *e) {}
    @try {
        id bf = [v.layer valueForKey:@"backgroundFilters"];
        if ([bf isKindOfClass:[NSArray class]] && [(NSArray *)bf count] > 0) {
            [v.layer setValue:nil forKey:@"backgroundFilters"];
        }
    } @catch (__unused NSException *e) {}
}

// 删掉一个视图图层上的【装饰子层】（不是任何视图的层）。
// 只在「祖先」和「没有内容的纯背景层」上用，绝不碰键盘内容。
static void WTE_StripDecorationSublayers(UIView *v, NSSet *viewLayers) {
    if (!v || !viewLayers) return;
    NSArray *subs = [v.layer.sublayers copy];
    for (CALayer *sl in subs) {
        NSValue *pv = [NSValue valueWithPointer:(__bridge const void *)(sl)];
        if ([viewLayers containsObject:pv]) continue;   // 是某个视图的层，绝不能动
        NSString *cls = NSStringFromClass([sl class]);
        @try {
            [sl removeFromSuperlayer];
            WTE_Diag(@"    [strip] %@ 上的装饰层 %@ 已移除",
                     NSStringFromClass([v class]), cls);
        } @catch (__unused NSException *e) {}
    }
}

// ═══════════ v1.8.6：键盘容器自己身上的装饰层（★ 真凶） ═══════════
//
// v1.8.5 的「底板普查」给出了判决性证据：清完所有东西之后，整个窗口里
// 唯一「满屏尺寸 + 还能画东西」的就是这一行 ——
//
//     WBRootInputView f(0,0,430,251) → 装饰子层×1   ←【键盘容器本身】
//
// 这就是微信输入法的渐变底色：它既不是视图、也不是 backgroundColor，
// 而是挂在【键盘容器图层】上的一个装饰性 CALayer。
//
// 为什么之前所有修法都打不中它 —— CALayer 的绘制顺序是：
//     backgroundColor  →  contents  →  sublayers  →  border
// 装饰子层画在 backgroundColor 【之上】：
//   · 纯色模式盖不住它（只能叠色 → 看起来像"渐变"，其实是我们的颜色 + 它的渐变）
//   · 透明底也清不掉它（我们一直清的只是 backgroundColor）
// 这也解释了用户那句「纯色模式是渐变，还挺好看」和 bg alpha=0.39 时的效果。

// 一个子层是不是「某个视图的层」？UIKit 会把视图图层的 delegate 设成视图自己。
// 装饰层的 delegate 一般是 nil，或者是别人 —— 用它就能把两类层精确分开。
static BOOL WTE_IsViewBackedLayer(CALayer *l) {
    if (!l) return NO;
    @try {
        id d = l.delegate;
        if ([d isKindOfClass:[UIView class]] && ((UIView *)d).layer == l) return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

// 只在这种【结构性容器】上清装饰层。
// 按键 / 候选词单元格 / 文字 / 图标一律不碰 —— 那些是人要看的"皮"。
static BOOL WTE_IsStructuralContainerClass(NSString *cls) {
    static NSArray *names = nil;
    if (!names) {
        names = @[@"WBRootInputView", @"WBMainInputView", @"WBKeyboardView",
                  @"WBT26Panel", @"WBTopBar", @"WBArrangeView",
                  @"WBCustomToolBarView", @"WBFunctionToolBar",
                  @"WBCandidateView", @"WBPlusEntranceView", @"WBTopBarTipsView"];
    }
    for (NSString *n in names) {
        if ([cls isEqualToString:n]) return YES;
    }
    return NO;
}

// 把键盘容器子树里的装饰子层摘掉。
//   scope = @"bg"  → 只摘【结构性容器】上的（按键帽保留，透明底板）
//   scope = @"all" → 整棵键盘子树都摘，【但按键除外】（见下）
// 返回摘掉的数量，方便诊断。
static int WTE_StripContainerDecorations(UIView *root, int depth, BOOL allViews) {
    if (!root || depth > 8) return 0;
    int n = 0;
    @try {
        NSString *cls = NSStringFromClass([root class]);
        // ★ v1.8.9：按键【绝不摘】装饰层 ★
        //   v1.8.7/1.8.8 在「整键盘透明」时把按键帽的装饰层也摘了，
        //   结果按键变得几乎看不见 → 用户「打字很容易按不到字母」。
        //   按键帽的半透明改由 WTE_ApplyKeyAppearance 用 layer.opacity 实现：
        //   帽子还在（形状/位置/可点击区域都不变），只是变透明。
        BOOL isKey = WTE_NameIsKey(cls);
        BOOL target = isKey ? NO : (allViews || WTE_IsStructuralContainerClass(cls));
        if (target) {
            for (CALayer *sl in [root.layer.sublayers copy]) {
                if (WTE_IsViewBackedLayer(sl)) continue;   // 视图自己的层，绝不能动
                @try {
                    WTE_Diag(@"    [strip] %@ 上的装饰层 %@ bounds=%@ opacity=%.2f hidden=%d",
                             cls, NSStringFromClass([sl class]),
                             NSStringFromCGRect(sl.bounds), sl.opacity, sl.hidden ? 1 : 0);
                    sl.hidden = YES;
                    [sl removeFromSuperlayer];
                    n++;
                } @catch (__unused NSException *e) {}
            }
        }
        for (UIView *s in [root.subviews copy]) n += WTE_StripContainerDecorations(s, depth + 1, allViews);
    } @catch (__unused NSException *e) {}
    return n;
}

// 窗口级兜底清扫：把整棵窗口树里「大面积 + 无内容」的纯背景层全清掉，
// 但【绝不进键盘容器 kb 的子树】—— 那里面是字母、图标、候选词。
static void WTE_ClearWindowBackgrounds(UIView *kb) {
    if (!kb) return;
    UIWindow *w = kb.window;
    if (!w) return;
    CGFloat kbArea = kb.bounds.size.width * kb.bounds.size.height;
    if (kbArea <= 1.0) return;

    NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
    int guard = 0;
    while (stack.count > 0 && guard < 3000) {
        guard++;
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIView *s in [v.subviews copy]) {
            if (s == kb) continue;                       // 键盘本体 → 整支跳过
            CGFloat area = s.bounds.size.width * s.bounds.size.height;
            BOOL big = (area >= kbArea * 0.35);
            if (WTE_LooksLikeSkinImage(s, kb.bounds.size)) {
                WTE_ClearLayerPaintDeep(s);
                WTE_ClearLayerFilters(s);
            } else if (big && !WTE_SubtreeHasContent(s, 0)) {
                WTE_ClearLayerPaintDeep(s);
                WTE_ClearLayerFilters(s);
            } else {
                [stack addObject:s];                     // 有内容 → 只往下找，不动它
            }
        }
    }
}

// ═══════════ v1.8.9：最后一类「清不掉」的底 —— 用 drawRect: 画出来的纯背景叶子 ═══════════
//
// backgroundColor / layer.contents / 装饰层 / 滤镜全都不是它 —— 它是把底色直接画进
// backing store 的。对这种视图，清是清不掉的：UIKit 下一次 display 会重画回来
// （这正是「清完普查为空、屏幕上却还有底色」的最可能解释）。
//
// 唯一可靠的办法是【整个藏掉】。安全边界画得很死：
//   · 只藏【叶子】（没有子视图）→ 不可能连带藏掉别人的内容
//   · 只藏面积 ≥ 键盘 60% 的        → 键帽、图标、候选词都远小于这个
//   · 只藏「真的画了东西」的         → 底色 / contents / 装饰层 至少占一样
//   · UILabel / UIImageView 一律跳过 → 文字和图标绝不动
// 按键有文字或图标，永远命中不了 —— 不会出现「按不到字母」。
static const void *kWTEHideLeafKey = &kWTEHideLeafKey;

static void WTE_HidePureBackdropLeaves(UIView *kb) {
    if (!kb) return;
    UIWindow *w = kb.window;
    if (!w) return;
    CGFloat kbArea = kb.bounds.size.width * kb.bounds.size.height;
    if (kbArea <= 1.0) return;
    NSUInteger token = (NSUInteger)(uintptr_t)gConfig;

    NSMutableSet *viewLayers = [NSMutableSet set];
    WTE_CollectViewLayers(w, viewLayers, 0);

    NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
    int guard = 0, hid = 0;
    while (stack.count > 0 && guard < 3000) {
        guard++;
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIView *s in [v.subviews copy]) [stack addObject:s];

        if (v == kb) continue;
        if (v.subviews.count > 0) continue;                     // 不是叶子
        if ([v isKindOfClass:[UILabel class]]) continue;
        if ([v isKindOfClass:[UIImageView class]]) continue;
        CGFloat area = v.bounds.size.width * v.bounds.size.height;
        if (area < kbArea * 0.60) continue;                     // 不够大，不是底板

        BOOL paints = NO;
        CGColorRef cg = v.backgroundColor.CGColor;
        if (cg && CGColorGetAlpha(cg) > 0.02) paints = YES;
        if (v.layer.contents) paints = YES;
        if (WTE_CountDecorationSublayers(v, viewLayers) > 0) paints = YES;
        if (!paints) continue;                                  // 什么都不画，别动它

        NSNumber *prev = objc_getAssociatedObject(v, kWTEHideLeafKey);
        if (prev && prev.unsignedIntegerValue == token) continue;
        objc_setAssociatedObject(v, kWTEHideLeafKey, @(token), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!v.hidden) {
            v.hidden = YES;
            hid++;
            WTE_Diag(@"[hide] 纯背景叶子 %@ f(%.0f,%.0f,%.0f,%.0f)",
                     NSStringFromClass([v class]),
                     v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height);
        }
    }
    if (hid) WTE_Diag(@"=== 藏掉 %d 个纯背景叶子（drawRect: 类底色只能藏不能清）===", hid);
}

// ═══════════ v1.9.0：本进程【所有窗口】逐个清一遍 ═══════════
//
// 之前的普查和清理都只盯 kb.window。万一输入法自己开了第二个窗口垫底色，
// 我们永远扫不到它 —— 底板普查当然是空的，屏幕上却还是有底色。
// 键盘扩展进程里的每个窗口都属于键盘本身，清了不会伤到别人。
static void WTE_ClearAllExtensionWindows(UIView *kb) {
    if (!kb) return;
    NSArray *wins = nil;
    @try {
        Class appCls = NSClassFromString(@"UIApplication");
        if (!appCls) return;
        id app = ((id (*)(id, SEL))objc_msgSend)(appCls, NSSelectorFromString(@"sharedApplication"));
        wins = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"windows"));
    } @catch (__unused NSException *e) { return; }
    if (![wins isKindOfClass:[NSArray class]]) return;

    NSMutableSet *viewLayers = [NSMutableSet set];
    for (id o in wins) {
        if ([o isKindOfClass:[UIWindow class]]) WTE_CollectViewLayers((UIWindow *)o, viewLayers, 0);
    }

    int touched = 0;
    for (id o in wins) {
        if (![o isKindOfClass:[UIWindow class]]) continue;
        UIWindow *w = (UIWindow *)o;
        if (w == kb.window) continue;                    // kb.window 祖先链里已经清过
        WTE_ClearLayerPaint(w);
        WTE_ClearLayerFilters(w);
        WTE_StripDecorationSublayers(w, viewLayers);
        if (w.opaque) w.opaque = NO;
        touched++;
        WTE_Diag(@"[allwin] 额外窗口#%d %@ f(%0.f,%0.f,%0.f,%0.f) 子视图=%lu 已清",
                 touched, NSStringFromClass([w class]), w.frame.origin.x, w.frame.origin.y,
                 w.frame.size.width, w.frame.size.height, (unsigned long)w.subviews.count);

        CGFloat area = w.bounds.size.width * w.bounds.size.height;
        if (area <= 1.0) continue;
        for (UIView *s in [w.subviews copy]) {
            CGFloat sa = s.bounds.size.width * s.bounds.size.height;
            if (sa >= area * 0.35 && !WTE_SubtreeHasContent(s, 0)) {
                WTE_ClearLayerPaintDeep(s);
                WTE_ClearLayerFilters(s);
                WTE_StripDecorationSublayers(s, viewLayers);
            }
        }
    }
}

// ═══════════ v1.9.1：把两趟重活挪出布局热路径 ═══════════
//
// 【卡顿根因】v1.9.0 把 WTE_HidePureBackdropLeaves（窗口树遍历 ≤3000 节点）
// 和 WTE_ClearAllExtensionWindows（所有窗口 + 收集全部视图层）直接写在
// WTE_ApplyKeyboardBg 里。而这个函数会被 -layoutSubviews hook 在
// 「尺寸变了」时调用 —— 键盘滑入滑出 / 切换字母↔数字 / 候选栏伸缩，
// 每帧尺寸都在变 → 每帧走两趟全树 → 打字明显发涩。
//
// v1.9.1：**布局里一次重活都不做**。改成丢到主队列、延迟 0.35s、并且
// 1.2 秒内只允许跑一次。代价是「藏叶子」比之前晚 0.35s，肉眼无感。
static NSTimeInterval gWTELastHeavySweep = 0;

static void WTE_RunHeavySweep(UIView *kb) {
    if (!kb) return;
    WTEConfig *c = gConfig;
    if (!c) return;
    if (!(c.keyboardTransparent || [c.bgMode isEqualToString:@"transparent"])) return;
    // 布局后 0.35s 再动手：这时候 UIKit 已经把这一轮的底色铺完了
    WTE_HidePureBackdropLeaves(kb);
    WTE_ClearAllExtensionWindows(kb);
}

static void WTE_ScheduleHeavySweep(UIView *kb) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - gWTELastHeavySweep < 1.2) return;      // 节流：1.2 秒最多一趟
    gWTELastHeavySweep = now;
    __weak UIView *weakKB = kb;
    for (NSNumber *d in @[@0.35, @1.20]) {           // 两个时间点足够覆盖键盘建树过程
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WTE_RunHeavySweep(weakKB);
        });
    }
}

// ★★ v1.8.6 主枪口：键盘容器【自己图层】上的装饰子层 ★★
//
// 底板普查（v1.8.5 加的那个）给出的判决性证据：
//   WBRootInputView f(0,0,430,251) → 装饰子层×1   ←【键盘容器本身】
// 清完所有东西后，整个窗口里唯一「满屏尺寸 + 还能画东西」的就它一个。
//
// 这就是微信输入法的渐变底色：既不是视图、也不是 backgroundColor，
// 而是挂在键盘容器图层上的一个装饰性 CALayer（CAGradientLayer 之类）。
//
// 为什么之前所有修法都打不中它 —— CALayer 绘制顺序：
//     backgroundColor  →  contents  →  sublayers  →  border
// 装饰子层画在 backgroundColor 【之上】：
//   · 纯色模式盖不住它（只能叠色 → 看起来像"渐变"）
//   · 透明底也清不掉它（我们一直清的只是 backgroundColor）
//
// 两种模式都摘：
//   · 透明底 → 它走了，键盘才真的透
//   · 纯色   → 我们的颜色才是真·纯色，而不是被它的渐变叠出来的"假渐变"
// 这同时也是一次自证实验：如果摘完纯色模式还是渐变，说明渐变不在容器上。
static const void *kWTEStripOnceKey = &kWTEStripOnceKey;

static void WTE_StripContainerDecorationsOnce(UIView *kb) {
    if (!kb) return;
    NSUInteger token = (NSUInteger)(uintptr_t)gConfig;
    NSMutableSet *seen = objc_getAssociatedObject(kb, kWTEStripOnceKey);
    if (seen && [seen containsObject:@(token)]) return;   // 本配置已摘过

    int n = WTE_StripContainerDecorations(kb, 0,
             [gConfig.transScope isEqualToString:@"all"]);
    WTE_Diag(@"=== 键盘装饰层：摘掉 %d 个（范围=%@）===", n, gConfig.transScope ?: @"all");

    if (!seen) seen = [NSMutableSet new];
    [seen addObject:@(token)];
    objc_setAssociatedObject(kb, kWTEStripOnceKey, seen, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 输入法可能在布局过程中又把装饰层加回来 —— 在【非布局时机】补摘几次。
    // （必须在 dispatch_after 里做：如果在 layoutSubviews 里反复摘层，会形成回环 → 卡死）
    __weak UIView *weakKB = kb;
    for (NSNumber *d in @[@0.30, @0.90, @1.80]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *k = weakKB;
            if (!k || !gConfig) return;
            int n2 = WTE_StripContainerDecorations(k, 0,
                     [gConfig.transScope isEqualToString:@"all"]);
            if (n2 > 0) WTE_Diag(@"=== 补摘装饰层 %d 个（输入法又加回来了）===", n2);
        });
    }
}

static const void *kWTEAncestorKey = &kWTEAncestorKey;

static void WTE_ClearKeyboardAncestors(UIView *kb) {
    if (!kb) return;
    NSUInteger token = (NSUInteger)(uintptr_t)gConfig;
    NSMutableSet *seen = objc_getAssociatedObject(kb, kWTEAncestorKey);
    if (seen && [seen containsObject:@(token)]) return;   // 本配置已处理过，绝不重复扫

    CGSize kbSize = kb.bounds.size;

    // 先把整棵窗口树里「所有视图的 layer」收成一个集合。
    // 有了它才能精确区分「装饰层」和「某个视图的层」——
    // 删装饰层安全，删视图层会把子视图一起搞没。
    NSMutableSet *viewLayers = [NSMutableSet set];
    if (kb.window) WTE_CollectViewLayers(kb.window, viewLayers, 0);

    UIView *p = kb.superview;
    UIView *child = kb;
    int hops = 0;

    while (p && hops < 10) {
        // A. 祖先自己那一层：直接清（不下探，绝不碰后代里的文字/图标）
        WTE_ClearLayerPaint(p);
        // A2. ★ v1.8.5 新枪口：祖先身上的 CA 滤镜（毛玻璃「材质」就是它画的）
        //     它不是一个视图，只清 backgroundColor / contents 永远扫不到。
        WTE_ClearLayerFilters(p);
        // A3. ★ v1.8.5 新枪口：祖先图层上的【装饰子层】（渐变层 / 形状层 / 边框层）
        //     它们也不在 subviews 里，视图树快照根本打印不出来。
        WTE_StripDecorationSublayers(p, viewLayers);

        // B. 同层里排在「我们这一支」前面的兄弟 —— 它们也是在我们后面画的
        for (UIView *sib in [p.subviews copy]) {
            if (sib == child) break;          // 走到我们这一支就停
            if (WTE_LooksLikeSkinImage(sib, kbSize)) {
                WTE_ClearLayerPaintDeep(sib);
                WTE_ClearLayerFilters(sib);
                continue;
            }
            if (WTE_SubtreeHasContent(sib, 0)) continue;   // 有文字/图标 → 不动
            WTE_ClearLayerPaintDeep(sib);
            WTE_ClearLayerFilters(sib);
        }

        if ([p isKindOfClass:[UIWindow class]]) {
            UIWindow *w = (UIWindow *)p;
            if (w.opaque) w.opaque = NO;
            WTE_SetClearBackground(w);
            WTE_ClearLayerFilters(w);
            WTE_StripDecorationSublayers(w, viewLayers);
            break;
        }
        child = p;
        p = p.superview;
        hops++;
    }

    // 万一 superview 链没走到窗口（键盘扩展里偶尔会有），用 kb.window 兜一下
    UIWindow *win = kb.window;
    if (win) {
        if (win.opaque) win.opaque = NO;
        WTE_SetClearBackground(win);
        WTE_ClearLayerFilters(win);
    }

    // 键盘容器自己身上的滤镜也一并清掉（有些皮肤把材质挂在最外层）
    WTE_ClearLayerFilters(kb);

    // C. 兜底大扫除：整个键盘窗口里「大面积 + 没内容」的层一律清掉。
    //    有些皮肤的底图并不挂在键盘容器的祖先链上，而是挂在窗口根视图下面的
    //    另一支上 —— 只扫祖先链永远找不到它。
    //    加「面积 ≥ 键盘 35%」这道闸，是为了避开窄条形的工具栏之类。
    //    （真正有文字/图标的视图会被 WTE_SubtreeHasContent 挡掉。）
    WTE_ClearWindowBackgrounds(kb);

    if (!seen) seen = [NSMutableSet new];
    [seen addObject:@(token)];
    objc_setAssociatedObject(kb, kWTEAncestorKey, seen, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ═══ v1.8.5：UIInputView 的「系统键盘背景」═══
//
// 键盘扩展的 UIInputView 默认样式是 UIInputViewStyleKeyboard，iOS 会给它装上
// 一套 backgroundEffects（就是那个毛玻璃「材质」背景）。这套背景【不是一个视图】，
// 所以视图树快照里永远看不到它 —— 这正好解释了
// 「backgroundColor 全 0、contents 全 0、祖先链全清干净，人却还能看见底色」。
//
// 而且光调一次 setBackgroundEffects:nil 不够：输入法可能在我们之后又把它设回去。
// 所以这里 (a) 把 setter 钩住，透明底模式下任何设置一律吃掉；
//          (b) 顺手把 inputViewStyle 从 Keyboard(1) 改成 Default(0)。
//
// UIInputViewStyle: 0 = Default（透明背景）  1 = Keyboard（系统键盘背景）
static BOOL WTE_ForceInputViewTransparent(UIView *kb, NSString **report) {
    if (!kb) return NO;
    UIView *p = kb.superview;
    int hops = 0;
    while (p && hops < 10) {
        if ([NSStringFromClass([p class]) isEqualToString:@"UIInputView"]) break;
        p = p.superview;
        hops++;
    }
    if (!p) { if (report) *report = @"没找到 UIInputView 祖先"; return NO; }

    // 先读一下当前 style，作为证据记进诊断报告
    long style = -1;
    SEL getS = NSSelectorFromString(@"inputViewStyle");
    if ([p respondsToSelector:getS]) {
        @try { style = ((long (*)(id, SEL))objc_msgSend)(p, getS); }
        @catch (__unused NSException *e) {}
    }

    SEL setS = NSSelectorFromString(@"setInputViewStyle:");
    if ([p respondsToSelector:setS] && style != 0) {
        @try {
            ((void (*)(id, SEL, long))objc_msgSend)(p, setS, 0);   // → Default（透明）
            if (report) *report = [NSString stringWithFormat:
                @"UIInputView style %ld → 0（Default/透明）", style];
            return YES;
        } @catch (__unused NSException *e) {}
    }

    if (report) *report = [NSString stringWithFormat:
        @"UIInputView style=%ld（本来就是透明，或设置不被支持）", style];
    return NO;
}

static void WTE_ApplyKeyboardBg(UIView *self, WTEConfig *c) {
    BOOL transparent = (c.keyboardTransparent || [c.bgMode isEqualToString:@"transparent"]);
    BOOL solidBg     = (c.bgEnabled && !transparent);

    // v1.8.0：图片模式已移除，只保留「纯色 / 透明底」。
    // 背景一律走 backgroundColor（+ 清中间层），零视图树改动、零 Layer 内容切换。
    CALayer *layer = self.layer;
    if (layer.contents) layer.contents = nil;   // 清掉旧版本可能残留的背景图

#if WTE_LOG_ENABLE
    // ★ v1.8.9 诊断：动手【前】先拍一张原始状态的快照（只拍一次）★
    //   之前所有的快照都是「清完之后」拍的 —— 万一某个视图是用 drawRect: 画底，
    //   我们清完 contents 它就会重画，普查看到的就是「干净的」假象。
    //   有了这张原始快照，就能对比出「谁本来画着东西、清完又画回来了」。
    static BOOL sPristineDumped = NO;
    if (!sPristineDumped) {
        sPristineDumped = YES;
        NSMutableString *d = [NSMutableString stringWithString:
            @"\n===== 【原始状态】动手之前的键盘视图树（只拍这一次）=====\n"];
        WTE_DumpTree(self, 0, d);
        WTE_DumpPaintCensus(self, d);
        WTE_Diag(@"%@", d);
        WTE_DiagFlush(@"pristine");
    }
#endif

    // ★★ v1.8.6 主枪口：摘掉键盘容器图层上的装饰子层（微信输入法的渐变底就在这里）★★
    // 它画在 backgroundColor【之上】，纯色盖不住、透明清不掉 —— 之前所有修法都打不中它。
    // 两种模式都摘：透明底才能真正透出去；纯色才是真·纯色（不再是被它叠出来的假渐变）。
    WTE_StripContainerDecorationsOnce(self);

    if (solidBg) {
        WTE_SetBackground(self, [c.bgColor colorWithAlphaComponent:c.bgAlpha]);
    } else if (transparent) {
        WTE_SetClearBackground(self);
        if (self.opaque) self.opaque = NO;
        if ([self respondsToSelector:NSSelectorFromString(@"setBackgroundEffects:")]) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"setBackgroundEffects:"), nil);
            } @catch (__unused NSException *e) {}
        }
        // ★ 透明底的关键：键盘主题背景往往不是画在我们容器上，
        //   而是画在容器的【祖先】上（UIInputView / 系统宿主视图 / 毛玻璃层）。
        //   证据：纯色模式能盖住它（说明它在下层），透明底一清空就露出来了。
        //   所以必须顺着祖先链往上清，否则永远透不出去。
        WTE_ClearKeyboardAncestors(self);

        // ★ v1.8.9/v1.9.0 的「藏叶子 / 全窗口清理」是两趟全树遍历 ——
        //   ⚠️ v1.9.0 把它们直接写在布局路径里，键盘一滑动、尺寸一变就会被调用，
        //      每帧走几千个节点 → 用户实测「打字不顺畅」。v1.9.1 改成
        //      **挪出布局 + 时间节流**，布局里一次都不做重活。
        WTE_ScheduleHeavySweep(self);

        // ★ v1.8.5：UIInputView 的系统键盘背景（backgroundEffects / inputViewStyle）
        //   这一项不是视图，视图树快照看不到，是「全清了还有底色」的头号嫌疑。
#if WTE_LOG_ENABLE
        static BOOL sLoggedInputView = NO;
        NSString *rpt = nil;
        BOOL changed = WTE_ForceInputViewTransparent(self, &rpt);
        if (changed || !sLoggedInputView) {
            sLoggedInputView = YES;
            WTE_Diag(@"[inputView] %@", rpt ?: @"-");
        }
#else
        WTE_ForceInputViewTransparent(self, NULL);
#endif
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

    // ★ v1.9.0：「按键透明度」滑动条 ★（只在透明底模式起作用）
    //   1.0 = 不透明（默认 → 打字完全不受影响，也就是用户要的「透明但不影响打字」）
    //   0.0 = 完全透明（只剩字母，透过按键能直接看到聊天背景）
    //   与「透明范围」独立：就算选「只透底板」，把滑条拉低也能让按键透。
    //   用户自己开了「按键配色」的话，以用户的配色为准。
    if (!c.keyColorEnabled && c.keyOpacity < 0.995
        && (c.keyboardTransparent || [c.bgMode isEqualToString:@"transparent"])) {
        WTE_SetBackground(self, [UIColor colorWithWhite:1.0 alpha:c.keyOpacity]);
        for (CALayer *sl in [self.layer.sublayers copy]) {
            if (WTE_IsViewBackedLayer(sl)) continue;              // 视图自己的层不动
            if (fabs(sl.opacity - c.keyOpacity) > 0.01) sl.opacity = (float)c.keyOpacity;
        }
    }

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

    // 按键底色
    if (c.keyColorEnabled) {
        UIColor *col = WTE_ColorForKeyKind(kind, c);
        if (col) {
            WTE_SetBackground(self, col);
            // 有些按键底色画在子视图上，一并处理一层
            for (UIView *sub in self.subviews) {
                if (![sub isKindOfClass:[UILabel class]] && sub.subviews.count == 0 &&
                    sub.bounds.size.height >= self.bounds.size.height * 0.8 &&
                    sub.bounds.size.width  >= self.bounds.size.width  * 0.8) {
                    WTE_SetBackground(sub, col);
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
        WTE_SetClearBackground(self);
    }
    if (c.keyColorEnabled && c.keyTextColor) {
        if ([self isKindOfClass:[UILabel class]]) ((UILabel *)self).textColor = c.keyTextColor;
        else {
            UILabel *l = WTE_LabelOfView(self);
            if (l) l.textColor = c.keyTextColor;
        }
    }
}

// 是否已有「键盘容器」祖先 —— 背景只画在最外层，嵌套容器互相叠图层会花。
// ⚠️ 只认我们自己的容器类名，不能用「名字里带 Keyboard/InputView」这种模糊判断：
//    键盘扩展的祖先链里有 UIInputView / UIKeyboardHostView 这类【系统类】，
//    模糊判断会把所有候选容器全判成「非最外层」→ 谁都不画背景（1.8.0 的隐藏 bug）。
static BOOL WTE_HasKeyboardAncestor(UIView *v) {
    static NSArray *kbNames = nil;
    if (!kbNames) {
        kbNames = @[@"WBKeyboardView", @"WBKeyboardRootView",
                    @"WBRootInputView", @"WBMainInputView"];
    }
    UIView *p = v.superview;
    while (p) {
        NSString *n = NSStringFromClass([p class]);
        for (NSString *k in kbNames) {
            if ([n isEqualToString:k]) return YES;
        }
        p = p.superview;
    }
    return NO;
}

#pragma mark —— 幂等令牌：卡死防护的核心 ——
//
// v1.7.1/1.7.2 卡死根因：在 -layoutSubviews 里改 backgroundColor / 清 effect，
// 会让视图重新布局 → 又进我们的 hook → 又改 → **布局反馈死循环**，CPU 打满。
// 修法：给每个视图记一个「上次应用时的令牌」，令牌 = 配置对象指针 + 当前尺寸。
//   · 配置没变 && 尺寸没变  → 直接跳过，一次都不碰视图 → 循环自然断开
//   · 面板改配置 → WTE_ReloadConfig 造出新的 WTEConfig 对象 → 指针变 → 令牌变 → 重新应用
static const void *kWTELastApplyKey = &kWTELastApplyKey;
static const void *kWTEClearedKey   = &kWTEClearedKey;
static const void *kWTESubtreeCfgKey = &kWTESubtreeCfgKey;

static NSUInteger WTE_ApplyToken(UIView *v, WTEConfig *c) {
    NSUInteger h = (NSUInteger)(uintptr_t)c;
    h = h * 31u + (NSUInteger)(v.bounds.size.width + 0.5);
    h = h * 31u + (NSUInteger)(v.bounds.size.height + 0.5);
    return h;
}

// 统一入口：按类名特征分派。返回 YES 表示本次真的做了改动。
static BOOL WTE_ApplyToView(UIView *self) {
    WTEConfig *c = gConfig;
    if (!c || !c.enabled) return NO;

    NSString *cls = NSStringFromClass([self class]);
    if (cls.length == 0) return NO;

    // 幂等闸门：配置与尺寸都没变就不再碰这个视图
    NSUInteger token = WTE_ApplyToken(self, c);
    NSNumber *prev = objc_getAssociatedObject(self, kWTELastApplyKey);
    if (prev && prev.unsignedIntegerValue == token) return NO;
    objc_setAssociatedObject(self, kWTELastApplyKey, @(token),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (WTE_NameIsKeyboard(cls)) {
        if (!WTE_HasKeyboardAncestor(self)) WTE_ApplyKeyboardBg(self, c);
    } else if (WTE_NameIsCandidate(cls) || WTE_NameIsBar(cls)) {
        WTE_ApplyBarOrCandidate(self, c);
    } else if (WTE_NameIsKey(cls)) {
        WTE_ApplyKeyAppearance(self, c);
    }
    return YES;
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

// 类名 → 种类缓存（0=无关 1=键盘容器 2=候选/工具栏 3=按键）
// -layoutSubviews 是热路径（键盘动画时 60fps × 几十个视图），
// 每次都跑一串 containsString 太亏，这里按类名缓存一次。
static NSMutableDictionary<NSString *, NSNumber *> *gKindCache;
static int WTE_KindOfClass(NSString *cls) {
    if (cls.length == 0) return 0;
    NSNumber *n = gKindCache[cls];
    if (n) return n.intValue;
    int k = 0;
    if (WTE_NameIsKeyboard(cls))                            k = 1;
    else if (WTE_NameIsCandidate(cls) || WTE_NameIsBar(cls)) k = 2;
    else if (WTE_NameIsKey(cls))                             k = 3;
    if (!gKindCache) gKindCache = [NSMutableDictionary new];
    gKindCache[cls] = @(k);
    return k;
}

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
        int kind = WTE_KindOfClass(cls);
        if (kind == 1) {
            // 只在最外层键盘容器上做整树遍历（嵌套的 3 个容器只走一次，省 2/3 开销）
            if (!WTE_HasKeyboardAncestor(self)) {
                // 整树遍历是「配置级」动作：只有配置真的换了才走一遍。
                // 键盘滑入滑出时 bounds 每帧都在变，但颜色没变，没必要每帧遍历 150 个视图。
                NSUInteger cfg = (NSUInteger)(uintptr_t)c;
                NSNumber *last = objc_getAssociatedObject(self, kWTESubtreeCfgKey);
                if (!last || last.unsignedIntegerValue != cfg) {
                    objc_setAssociatedObject(self, kWTESubtreeCfgKey, @(cfg),
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    WTE_ApplyToView(self);
                    WTE_ApplySubtree(self, 0);
#if WTE_LOG_ENABLE
                    // 配置变了 → 拍一张视图树快照（最多 3 张，避免诊断文件膨胀）
                    // ⚠️ 必须延后到布局结束再拍：直接在 -layoutSubviews 里拍，
                    //    所有 frame 都是 0,0,0,0（布局还没写进去），等于白拍。
                    if (!gDiagDumpedTree) {
                        gDiagDumpedTree = YES;
                        __weak UIView *weakSelf = self;
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                      (int64_t)(0.8 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            UIView *kb = weakSelf;
                            if (!kb) return;
                            @try {
                                NSMutableString *dump = [NSMutableString stringWithString:
                                    @"\n===== 键盘视图树快照（前 3 层）=====\n"];
                                WTE_DumpTree(kb, 0, dump);
                                WTE_DumpAncestors(kb, dump);
                                WTE_DumpPaintCensus(kb, dump);
                                [dump appendString:
                                    @"\n===== 宿主 App 回执（宿主侧清理有没有铺开）=====\n"];
                                WTE_DumpHostReports(dump);
                                WTE_DumpAllWindows(dump);
                                WTE_TransparentSelfTest(kb, dump);
                                WTE_Diag(@"%@", dump);
                                WTE_DiagFlush(@"tree");
                            } @catch (__unused NSException *e) {}
                        });
                    }
#endif
                } else {
                    WTE_ApplyToView(self);   // 配置没变、只是尺寸变了：只更新容器自己
                }
            }
        } else if (kind != 0) {
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

// 递归给子树里的键盘元素上色 / 让中间层让位。
// protectedZone = YES 表示已经进到「按键 / 工具栏内部」，
// 那里面的图标和文字绝不能清，只继续找更深处的按键。
static void WTE_ApplySubtreeEx(UIView *root, int depth, BOOL protectedZone) {
    if (!root || depth > 6) return;
    WTEConfig *c = gConfig;
    if (!c) return;
    BOOL clearMiddle = (!protectedZone) &&
                       (c.bgEnabled || c.keyboardTransparent ||
                        [c.bgMode isEqualToString:@"transparent"]);
    NSUInteger clearToken = (NSUInteger)(uintptr_t)c;   // 配置一变就重新清一次

    for (UIView *sub in [root.subviews copy]) {
        @try {
            NSString *cls = NSStringFromClass([sub class]);
            BOOL isKey = WTE_NameIsKey(cls);
            BOOL isBar = WTE_NameIsCandidate(cls) || WTE_NameIsBar(cls);
            if (isKey || isBar) {
                WTE_ApplyToView(sub);
                WTE_ApplySubtreeEx(sub, depth + 1, YES);   // 进入保护区
            } else {
                // ★ 关键修复（v1.8.1）：
                // 嵌套的键盘容器（WBKeyboardView 套在 WBRootInputView 里）也走这一支 ——
                // 它们【不该自己画背景】，否则内层的不透明底色会把最外层刚画的背景整个盖住。
                // 之前这里对嵌套容器调了 WTE_ApplyToView，而那个函数见到「有键盘祖先」就跳过，
                // 结果内层底色原样保留 → 背景永远看不见。
                if (clearMiddle) {
                    NSNumber *pv = objc_getAssociatedObject(sub, kWTEClearedKey);
                    if (!pv || pv.unsignedIntegerValue != clearToken) {
                        objc_setAssociatedObject(sub, kWTEClearedKey, @(clearToken),
                                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        WTE_ClearLayerPaint(sub);
                    }
                }
                WTE_ApplySubtreeEx(sub, depth + 1, protectedZone);
            }
        } @catch (__unused NSException *e) {}
    }
}
static void WTE_ApplySubtree(UIView *root, int depth) {
    WTE_ApplySubtreeEx(root, depth, NO);
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

// ═══ v1.8.5：系统侧 hook —— UIInputView 的「键盘背景」═══
// setBackgroundEffects: 是 UIInputView 决定自己「毛玻璃材质背景」的私有入口。
// 透明底模式下直接把 setter 吃掉，任何一方（输入法 / UIKit）想设回去都无效。
static void (*gOrigSetBackgroundEffects)(id, SEL, id) = NULL;

static void WTE_SetBackgroundEffectsReplacement(id self, SEL _cmd, id effects) {
    BOOL transparent = (gConfig && (gConfig.keyboardTransparent ||
                                    [gConfig.bgMode isEqualToString:@"transparent"]));
    if (transparent) effects = nil;
    if (gOrigSetBackgroundEffects) gOrigSetBackgroundEffects(self, _cmd, effects);
}

static int WTE_InstallSystemHooks(void) {
    int n = 0;
    Class iv = NSClassFromString(@"UIInputView");
    SEL s = NSSelectorFromString(@"setBackgroundEffects:");
    if (iv && [iv instancesRespondToSelector:s]) {
        MSHookMessageEx(iv, s, (IMP)&WTE_SetBackgroundEffectsReplacement,
                        (IMP *)&gOrigSetBackgroundEffects);
        n++;
        WTE_Diag(@"  [sys] UIInputView -setBackgroundEffects: 已接管（透明底时强制 nil）");
    } else {
        WTE_Diag(@"  [sys] UIInputView 没有 setBackgroundEffects:，跳过");
    }
    return n;
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

#pragma mark - ========== 宿主 App 侧：清掉键盘在宿主机里的那层底 ==========
//
// ★ v1.8.8：这一节是整个「真·透明」的正面战场 ★
//
// v1.8.7 的诊断把结论钉死了：
//   · 键盘扩展【自己进程的整棵窗口树】已经清到一个能画底色的视图都没有（底板普查为空），
//     祖先链最外层是 _UIHostedWindow；
//   · 可屏幕上键盘区域依然是一整片系统灰。
//   ⇒ 那片灰根本不在扩展进程里。
//
// 第三方键盘真正的「显示位置」在【宿主 App 进程】：
//     UIRemoteKeyboardWindow → UIInputSetContainerView → UIInputSetHostView
// 扩展的内容是通过远程视图合成进这一支的。iOS 在这几级容器上垫的那层键盘底板，
// 扩展进程无论怎么清都碰不到 —— 这就是「透明底一直不生效」的最终根因。
//
// v1.8.8 的做法：让插件也注入宿主 App（过滤规则里列了一批常用 App），
// 键盘一弹出来就在【宿主进程】里把键盘窗口那一支清干净。
//
// 三条纪律：
//   · 【v1.9.1 修订】只 hook **UIInputSetHostView 这个系统类自己实现的方法**
//     （layoutSubviews / didMoveToWindow），而且钩子里只碰它自己那一层。
//     绝不 hook App 的视图、也绝不 hook 我们的键盘视图 —— 不会形成布局反馈死循环。
//     （v1.8.8 时因为怕死循环而完全不加钩子，结果清扫全靠固定时间点，容易漏。）
//   · 只在【键盘窗口】那一支里动手（树里找不到 UIInputSetHostView 的窗口一律跳过），
//     绝不扫 App 自己的界面 —— 不可能把用户的 App 搞透明。
//   · 一旦看到原生键盘的自绘部件（Keyplane / KeyView / KeyboardDock）
//     就整体跳过 —— 密码框等场景 iOS 会强制切回原生键盘，绝不能把原生键盘也弄透明。
static NSArray<NSString *> *WTE_HostBackdropClasses(void) {
    static NSArray *a = nil;
    if (!a) a = @[@"UIRemoteKeyboardWindow", @"UIInputSetContainerView",
                  @"UIInputSetHostView", @"UIKeyboardHostView",
                  @"_UIKeyboardHostView"];
    return a;
}

// —— 宿主侧「回执」——
// 宿主 App 被沙盒关在自己容器里，写不了 /var/mobile/Media（v1.8.7 的报告已证实
// 连键盘扩展都写不进去）。所以每个宿主 App 各写自己容器里的一份 host.txt；
// 键盘扩展那边会去 Application 容器里把这些回执捞出来塞进 diag.txt，
// 这就是验证「过滤规则到底有没有把宿主 App 也注入到」的唯一通道。
static void WTE_HostAppendReport(NSString *text) {
    if (!text.length) return;
    @try {
        NSString *home = NSHomeDirectory();
        if (!home.length) return;
        NSString *dir = [home stringByAppendingPathComponent:@"Documents/WeTypeEnhance"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSString *f = [dir stringByAppendingPathComponent:@"host.txt"];
        NSString *old = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil] ?: @"";
        if (old.length > 150000) old = @"";     // 防膨胀
        [([old stringByAppendingFormat:@"%@\n", text])
            writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (__unused NSException *e) {}
}

// 宿主进程里，键盘窗口这一支是不是「原生键盘自绘」？
// 苹果原生键盘的按键平面就在进程内，一旦看到 Keyplane / KeyView 就说明是原生键盘，
// 绝不能动它的底板，否则连原生键盘都会变透明。
// 第三方键盘在宿主进程里只有一个远程视图外壳，不会有这些部件。
static BOOL WTE_HostTreeLooksLikeSystemKeyboard(UIView *root) {
    if (!root) return NO;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard < 1500) {
        guard++;
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIView *s in v.subviews) [stack addObject:s];
        NSString *n = NSStringFromClass([v class]);
        if ([n containsString:@"Keyplane"] || [n containsString:@"KeyView"] ||
            [n containsString:@"KeyboardDock"] || [n containsString:@"KeyCap"] ||
            [n hasPrefix:@"UIKBKey"]) return YES;
    }
    return NO;
}

// 在窗口树里找「输入集宿主视图」—— 有它就说明这个窗口是键盘窗口。
static UIView *WTE_HostFindInputSetHost(UIView *root, int depth) {
    if (!root || depth > 12) return nil;
    NSString *n = NSStringFromClass([root class]);
    if ([n isEqualToString:@"UIInputSetHostView"] ||
        [n isEqualToString:@"UIKeyboardHostView"] ||
        [n isEqualToString:@"_UIKeyboardHostView"]) return root;
    for (UIView *s in root.subviews) {
        UIView *r = WTE_HostFindInputSetHost(s, depth + 1);
        if (r) return r;
    }
    return nil;
}

static NSArray<UIWindow *> *WTE_HostAllWindows(void) {
    @try {
        Class appCls = NSClassFromString(@"UIApplication");
        if (!appCls) return @[];
        id app = ((id (*)(id, SEL))objc_msgSend)(appCls, NSSelectorFromString(@"sharedApplication"));
        if (!app) return @[];
        NSArray *wins = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"windows"));
        if (![wins isKindOfClass:[NSArray class]]) return @[];
        NSMutableArray *out = [NSMutableArray array];
        for (id w in wins) {
            if ([w isKindOfClass:[UIWindow class]]) [out addObject:w];
        }
        return out;
    } @catch (__unused NSException *e) { return @[]; }
}

// 清一棵【键盘窗口】子树里所有能画出底色的东西。
// 这棵树整个都属于键盘，可以放心清；唯一要避开的是文字 / 图标（人手要看的）。
// 返回清掉的视图数。
static int WTE_HostSweepTree(UIView *root, NSMutableString *log, int *logged) {
    if (!root) return 0;
    NSMutableSet *viewLayers = [NSMutableSet set];
    WTE_CollectViewLayers(root, viewLayers, 0);

    CGSize rs = root.bounds.size;
    CGFloat rootArea = rs.width * rs.height;

    int cleared = 0;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard < 4000) {
        guard++;
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIView *s in [v.subviews copy]) [stack addObject:s];

        // 文字和图标绝不动（那是键盘的内容）
        if ([v isKindOfClass:[UILabel class]]) continue;
        if ([v isKindOfClass:[UIImageView class]]) continue;

        NSString *cls = NSStringFromClass([v class]);
        BOOL isBackdrop = NO;
        for (NSString *n in WTE_HostBackdropClasses()) {
            if ([cls isEqualToString:n]) { isBackdrop = YES; break; }
        }

        CGFloat area = v.bounds.size.width * v.bounds.size.height;
        BOOL big = (rootArea > 1.0 && area >= rootArea * 0.20);
        BOOL effect = ([v isKindOfClass:[UIVisualEffectView class]] &&
                       ((UIVisualEffectView *)v).effect != nil);
        BOOL needClear = isBackdrop || effect || (big && !WTE_SubtreeHasContent(v, 0));
        if (!needClear) continue;

        WTE_ClearLayerPaint(v);
        WTE_ClearLayerFilters(v);
        WTE_StripDecorationSublayers(v, viewLayers);
        if (v.opaque) v.opaque = NO;
        cleared++;
        if (log && logged && *logged < 40) {
            (*logged)++;
            [log appendFormat:@"  [host-clear] %@ f(%.0f,%.0f,%.0f,%.0f) 容器=%d 毛玻璃=%d\n",
             cls, v.frame.origin.x, v.frame.origin.y,
             v.frame.size.width, v.frame.size.height,
             isBackdrop ? 1 : 0, effect ? 1 : 0];
        }
    }
    return cleared;
}

// 一次宿主侧清扫：遍历所有窗口，只动「键盘窗口」那一支。
// writeLog = YES 时把结果写进本 App 容器里的 host.txt（回执）。
static void WTE_HostClearKeyboardBackdrop(BOOL writeLog) {
    @try {
        NSArray<UIWindow *> *wins = WTE_HostAllWindows();
        if (!wins.count) return;

        NSMutableString *log = [NSMutableString string];
        int logged = 0, touched = 0, total = 0;

        for (UIWindow *w in wins) {
            // 判据一：窗口树里能找到「输入集宿主视图」—— 最精确
            BOOL isKbWin = (WTE_HostFindInputSetHost(w, 0) != nil);
            // 判据二（兜底）：窗口类名本身就是键盘窗口。
            // 万一某个 iOS 版本把 UIInputSetHostView 换了名字，判据一会失效，
            // 但这两个类名是键盘窗口的固定标识，而且这种窗口里只有键盘那一支。
            if (!isKbWin) {
                NSString *wn = NSStringFromClass([w class]);
                if ([wn containsString:@"RemoteKeyboard"] || [wn containsString:@"KeyboardWindow"])
                    isKbWin = YES;
            }
            if (!isKbWin) continue;                            // 不是键盘窗口 → 跳过
            if (WTE_HostTreeLooksLikeSystemKeyboard(w)) {       // 原生键盘 → 一根手指都不碰
                if (writeLog) [log appendFormat:@"  [skip] %@：识别为原生键盘\n",
                                                NSStringFromClass([w class])];
                continue;
            }
            touched++;
            total += WTE_HostSweepTree(w, log, &logged);
        }

        if (writeLog && touched > 0) {
            NSMutableString *head = [NSMutableString stringWithFormat:
                @"[host] bundle=%@ pid=%d 键盘窗口=%d 清掉视图=%d time=%@\n",
                [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
                getpid(), touched, total, [NSDate date]];
            [head appendString:log];
            WTE_HostAppendReport(head);
        }
    } @catch (__unused NSException *e) {}
}

// 键盘动画期间 UIKeyboardWillChangeFrame 会狂发（每帧一条）。
// 不做节流的话，每一次都要遍历整个宿主 App 的窗口树 —— 微信会被拖卡。
// 这里 0.35 秒内只放行一批。（本函数总在主线程被调用，无需加锁）
static NSTimeInterval gHostLastSweepAt = 0;

static void WTE_HostScheduleSweeps(void) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - gHostLastSweepAt < 0.35) return;
    gHostLastSweepAt = now;
    // 键盘弹出是个动画过程：窗口和子视图是逐步建好的；第三方键盘扩展冷启动
    // 可能超过 1 秒。多打几个时间点，最后一个压到 2.8 秒。
    for (NSNumber *d in @[@0.05, @0.25, @0.50, @0.90, @1.40, @2.00, @2.80]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WTE_HostClearKeyboardBackdrop(d.doubleValue >= 0.50 && d.doubleValue <= 2.00);
        });
    }
}

// ═══ v1.9.1：宿主侧「落地钩子」═══
//
// 通知驱动的清扫有个天然缺陷：时间点全押在固定时刻（0.05~2.8s）。
// 只要 UIKit 在 2.8s 之后才补一次底板，就漏了 —— 而「偶尔漏」是最难查的。
// 这里给 UIInputSetHostView 挂两个**极窄**的钩子（只在它自己这个类上）：
//   · -layoutSubviews   → 它一被重新布局，就把自己那一层重新清一次（极轻，只碰它自己）
//   · -didMoveToWindow  → 进/出窗口时补几次延迟清理
// 与「不 hook 布局」的纪律不冲突：这里 hook 的是**系统键盘容器类自己**，
// 不是 App 的视图，也不 hook 我们的键盘视图 —— 不会形成布局反馈死循环。
// ⚠️ 刻意【不】接管 setBackgroundColor:：那等于改掉 UIKit 的行为，
//    连原生键盘都可能受影响，风险不值得。
static BOOL WTE_FastLooksSystemKeyboard(UIView *root) {
    // 浅层扫描（≤3 层、≤60 个节点）：原生键盘的按键平面就在很浅的位置，
    // 这个判据够用而且便宜到可以放进 layoutSubviews。
    if (!root) return NO;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard < 60) {
        guard++;
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        NSString *n = NSStringFromClass([v class]);
        if ([n containsString:@"Keyplane"] || [n containsString:@"KeyView"] ||
            [n containsString:@"KeyboardDock"] || [n hasPrefix:@"UIKBKey"]) return YES;
        int depth = (int)[stack count];   // 粗估：用队列长度近似控制层数
        if (depth > 60) continue;
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    return NO;
}

static void (*gOrigISHLayout)(id, SEL) = NULL;
static void (*gOrigISHDidMove)(id, SEL) = NULL;

// 极轻：只碰 UIInputSetHostView 自己那一层
static void WTE_ISH_ClearSelfLayer(UIView *v) {
    if (!v) return;
    @try {
        CGColorRef cg = v.backgroundColor.CGColor;
        if (!cg || CGColorGetAlpha(cg) > 0.001) v.backgroundColor = [UIColor clearColor];
        if (v.opaque) v.opaque = NO;
        @try {
            id bf = [v.layer valueForKey:@"backgroundFilters"];
            if ([bf isKindOfClass:[NSArray class]] && [(NSArray *)bf count] > 0)
                [v.layer setValue:nil forKey:@"backgroundFilters"];
        } @catch (__unused NSException *e) {}
        @try {
            id f = [v.layer valueForKey:@"filters"];
            if ([f isKindOfClass:[NSArray class]] && [(NSArray *)f count] > 0)
                [v.layer setValue:nil forKey:@"filters"];
        } @catch (__unused NSException *e) {}
    } @catch (__unused NSException *e) {}
}

static void WTE_ISHLayoutReplacement(id self, SEL _cmd) {
    if (gOrigISHLayout) gOrigISHLayout(self, _cmd);
    UIView *v = (UIView *)self;
    if (v.hidden || v.alpha < 0.05) return;
    @try {
        if (WTE_FastLooksSystemKeyboard(v)) return;    // 原生键盘 → 一根手指都不碰
        WTE_ISH_ClearSelfLayer(v);
    } @catch (__unused NSException *e) {}
}

static void WTE_ISHDidMoveReplacement(id self, SEL _cmd) {
    if (gOrigISHDidMove) gOrigISHDidMove(self, _cmd);
    UIView *v = (UIView *)self;
    if (!v.window) return;
    @try {
        if (WTE_FastLooksSystemKeyboard(v)) return;
    } @catch (__unused NSException *e) {}
    __weak UIView *weakV = v;
    for (NSNumber *d in @[@0.02, @0.20, @0.60, @1.30]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *x = weakV;
            if (!x) return;
            @try {
                if (WTE_FastLooksSystemKeyboard(x)) return;
                WTE_ISH_ClearSelfLayer(x);
            } @catch (__unused NSException *e) {}
        });
    }
}

// 只 hook 到「UIInputSetHostView 自己实现的方法」上。
// ⚠️ 这一点极其重要：MSHookMessageEx 打在父类的实现上会波及**全 App 的所有视图**，
//    所以先用 WTE_ClassImplements 确认它自己实现了，否则宁可不装。
static int WTE_InstallHostInputSetHook(void) {
    Class cls = NSClassFromString(@"UIInputSetHostView");
    if (!cls) return 0;
    int n = 0;
    SEL s1 = @selector(layoutSubviews);
    if (WTE_ClassImplements(cls, s1)) {
        MSHookMessageEx(cls, s1, (IMP)&WTE_ISHLayoutReplacement, (IMP *)&gOrigISHLayout);
        n++;
    }
    SEL s2 = @selector(didMoveToWindow);
    if (WTE_ClassImplements(cls, s2)) {
        MSHookMessageEx(cls, s2, (IMP)&WTE_ISHDidMoveReplacement, (IMP *)&gOrigISHDidMove);
        n++;
    }
    return n;
}

static void WTE_InstallHostKeyboardSweep(void) {
    @try {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        NSOperationQueue *q = [NSOperationQueue mainQueue];
        for (NSString *name in @[UIKeyboardWillShowNotification, UIKeyboardDidShowNotification,
                                 UIKeyboardWillChangeFrameNotification]) {
            [nc addObserverForName:name object:nil queue:q
                        usingBlock:^(__unused NSNotification *note) {
                WTE_HostScheduleSweeps();
            }];
        }
        int hooked = WTE_InstallHostInputSetHook();
        // 回执：证明本进程确实被注入了，并记下进程里有没有键盘容器类。
        // 拿不到任何回执 ⇒ 过滤规则没把宿主 App 注入到，问题在下发层不在代码。
        WTE_HostAppendReport([NSString stringWithFormat:
            @"[host] 注入成功 bundle=%@ exec=%@ pid=%d 有键盘容器类=%d 布局钩子=%d time=%@\n",
            [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
            [[NSProcessInfo processInfo] processName] ?: @"?",
            getpid(),
            (NSClassFromString(@"UIInputSetHostView") ? 1 : 0),
            hooked,
            [NSDate date]]);
        NSLog(@"[WeTypeEnhance][host] 宿主侧键盘背景清理已就绪 (%@) 钩子=%d",
              [[NSBundle mainBundle] bundleIdentifier], hooked);
    } @catch (__unused NSException *e) {}
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

        // v1.8.8：SpringBoard 也可能是「宿主」—— 启动器/搜索页是 SpringBoard 进程画的，
        // 键盘就弹在 SpringBoard 进程里。系统垫的键盘灰底同样要清。
        WTE_InstallHostKeyboardSweep();
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
    if (!isWeType) {
        // —— 宿主 App 侧通道（v1.8.5 起，v1.8.8 全面铺开）——
        // 不是微信输入法自己的进程，但如果是 App（有 UIApplication），
        // 就在这里挂「键盘弹出 → 清掉键盘窗口背景」的清扫。
        // 这一步只碰【键盘窗口】那一支，绝不装键盘视图 hook，绝不 hook 布局。
        WTE_InstallHostKeyboardSweep();
        return;
    }

    gPrefQueue = dispatch_queue_create("com.colorblack.wetypeenhance.prefs", DISPATCH_QUEUE_SERIAL);
#if WTE_LOG_ENABLE
    gDiagQueue = dispatch_queue_create("com.colorblack.wetypeenhance.diag", DISPATCH_QUEUE_SERIAL);
    gLayoutSeen = [NSMutableSet new];
#endif
    gOrigLayout = [NSMutableDictionary new];

    WTE_ReloadConfig();

    WTE_Diag(@"================ WeTypeEnhance v1.9.1 ================");
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
        int sysHooked = WTE_InstallSystemHooks();
        WTE_Diag(@"=== 白名单命中并 hook %d 个类（另有 %d 个系统 hook）===", hooked, sysHooked);
        WTE_DiagFlush(@"hooks");
    });
}
