//
// HUDAppDelegate.m
//
// AilinHUD 进程入口（v1.8.1 照懒人 RootCore 反汇编铁证重构）。
//
// ★★ v1.8.1 关键架构：
//   懒人 RootCore（com.nx.RootCore）= 独立 UIApplication 进程（@_UIApplicationMain
//   + FBSceneManager 二进制 scene + UIRootWindowScenePresentationBinder + SBS 注册）。
//   悬浮球 = 独立进程持二进制 FBScene → 不依赖主 App 生命周期 → 全局持久。
//
//   ★ legacy 模式（无 UIApplicationSceneManifest）：UIApplicationMain 不会等
//   scene 连接 → 不卡 booting（v1.5.0 共享主 bundle + SceneManifest 卡死的根因）。
//   窗口在 didFinish 手动创建 + FBSceneManager 手动建二进制 scene + binder 绑定
//   系统 root window 层 → 全局显示。
//
#import "HUDAppDelegate.h"
#import "HUDBall.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>   /* CAContext */

/* ★ v1.8.60 照开源 Letterpress TRHudMainWindow 完整 override（TrollStore 悬浮窗
   显示关键）：_isSystemWindow=YES 让系统当系统窗口；_isWindowServerHostingManaged=NO
   = 窗口不归 WindowServer 常规托管 → 不依赖 scene 也能拿 contextID（v1.8.59
   legacy 窗口 cid-zero 的解法）。+ 类方法 / - 实例方法照原样。 */
@interface HUDMainWindow : UIWindow
@end

@implementation HUDMainWindow
+ (BOOL)_isSecure { return YES; }
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
/* ★ v1.8.62 _ignoresHitTest 改 NO：v1.8.60 照 Letterpress 原样 YES（纯显示悬浮窗）
   导致窗口忽略所有触摸 → 球拖不动（HUDBall 的 pan 手势收不到事件）。
   我们要拖动 → 必须接收触摸。透明区域由 hitTest 返回 nil 穿透（照主 App
   FloatingBallWindow v1.6.8 同款）。 */
- (BOOL)_ignoresHitTest { return NO; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }

/* 穿透：命中窗口自身/rootVC 全屏透明背景 → nil（下层可点）；
   命中悬浮球（HUDBall 及子视图）→ 正常响应（拖动/点击）。 */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    return hit;
}
@end

/* UIWindow 私有（Letterpress UIWindow+Private.h 同款）。
   CAContext 是 QuartzCore 私有类（公开头无），用 id 动态调用 */
@interface UIWindow (HUDPrivate)
- (id)_boundContext;
- (unsigned int)_contextId;
@end

/* 诊断辅助：写 /tmp/ailintouch_hud.alive（引擎 /hud 可读）
   ★ v1.8.34 双写 /tmp/ailintouch_hud.log（引擎 /log?src=hud 可读，带时间戳） */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    @autoreleasepool {
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] [hud] %@\n",
                          [df stringFromDate:[NSDate date]], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ailintouch_hud.log"];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:@"/tmp/ailintouch_hud.log"
                                                    contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ailintouch_hud.log"];
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

@implementation HUDAppDelegate

/* ★ v1.8.36 手动建球（不依赖 UIApplicationMain/UIApplication 单例）：
   照 AutoGo floatball installFloatingBallWindow 的顺序 —— 在 UIApplicationMain
   之前先把球建好、SBS 注册，UIApplicationMain 卡不卡都无所谓。
   全部 @try 保护：任何一步崩/失败都不影响进程，逐步骤 hud_mark 记录。 */
static UIWindow *g_manualWindow = nil;

+ (void)manualInstallBall {
    hud_mark(@"manual-install-start");
    @try {
        /* 1. 窗口（v1.8.44 兜底：有 scene 就绑 scene（拿有效 cid），无 scene 裸窗） */
        UIWindowScene *ws = nil;
        @try {
            ws = (UIWindowScene *)[[[UIApplication sharedApplication] connectedScenes] anyObject];
        } @catch (NSException *e) { ws = nil; }
        if (ws) {
            g_manualWindow = [[UIWindow alloc] initWithWindowScene:ws];
            hud_mark(@"manual-window-scene-bound");
        } else {
            g_manualWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            hud_mark(@"manual-window-no-scene");
        }
        g_manualWindow.backgroundColor = [UIColor clearColor];
        g_manualWindow.windowLevel = 20000002.0;
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        g_manualWindow.rootViewController = vc;

        /* 2. 悬浮球 */
        CGFloat size = 56;
        CGFloat x = 20;
        CGFloat y = [UIScreen mainScreen].bounds.size.height / 2 - size;
        HUDBall *ball = [[HUDBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
        [vc.view addSubview:ball];

        /* 3. 显示（可能因无 UIApplication 抛异常，catch 后球窗口仍可能已有 contextID） */
        @try {
            [g_manualWindow makeKeyAndVisible];
            hud_mark(@"window-shown");
        } @catch (NSException *e) {
            hud_mark([NSString stringWithFormat:@"window-visible-ex-%@", e.name]);
            /* 无 UIApplication 时 makeKeyAndVisible 可能崩，改 hidden=NO */
            @try { g_manualWindow.hidden = NO; } @catch (NSException *e2) {}
        }
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"manual-window-ex-%@", e.name]);
    }

    /* 4. FBScene 二进制 scene + binder（v1.8.1 逻辑，转类方法调用） */
    [HUDAppDelegate manualCreateFrontBoardScene];

    /* 5. SBS 注册（拿窗口 _contextId） */
    [HUDAppDelegate manualRegisterToSpringBoard];
    hud_mark(@"manual-install-done");
}

/* 类方法版 createFrontBoardScene（照实例方法，窗口用 g_manualWindow）
   ★ v1.8.39 每步独立 try-catch + 标记，精确定位 fb-bind-ex 在哪一步 */
+ (void)manualCreateFrontBoardScene {
    /* ★ v1.8.37 dlopen 加载 FrontBoardServices/FrontBoard（私有 framework，
       不编译链接——SDK 无 PrivateFrameworks 路径，运行时加载即可） */
    @try {
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard", RTLD_NOW);
    } @catch (NSException *e) {
        hud_mark(@"fb-dlopen-ex");
    }

    /* 1. FBSceneManager */
    Class mgrCls = nil;
    id manager = nil;
    @try {
        mgrCls = NSClassFromString(@"FBSceneManager");
        if (!mgrCls) { hud_mark(@"fb-mgr-missing"); return; }
        hud_mark(@"fb-mgr-ok");
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if ([mgrCls respondsToSelector:sharedSel]) {
            manager = ((id(*)(id, SEL))objc_msgSend)(mgrCls, sharedSel);
        }
        if (!manager) manager = ((id(*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"new"));
        if (!manager) { hud_mark(@"fb-mgr-fail"); return; }
        hud_mark(@"fb-manager-ok");
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"fb-mgr-ex-%@", e.name]);
        return;
    }

    /* 2. FBSMutableSceneDefinition */
    id def = nil;
    @try {
        Class defCls = NSClassFromString(@"FBSMutableSceneDefinition");
        if (!defCls) { hud_mark(@"fb-def-missing"); return; }
        hud_mark(@"fb-def-class-ok");
        def = ((id(*)(id, SEL))objc_msgSend)(defCls, NSSelectorFromString(@"new"));
        if (!def) { hud_mark(@"fb-def-new-fail"); return; }
        hud_mark(@"fb-def-created");
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"fb-def-ex-%@", e.name]);
        return;
    }

    /* 3. identity —— ★ v1.8.51 照懒人 RootCore 反汇编铁证：identityForIdentifier:
       （v1.8.48 的 identityWithIdentifier: 是错方法名，主 App v1.8.49 实测
       fb-ident-ok-FBSSceneIdentity 确认正确类和方法）。 */
    @try {
        Class sceneIdentCls = NSClassFromString(@"FBSSceneIdentity");
        if (sceneIdentCls) {
            SEL sel = NSSelectorFromString(@"identityForIdentifier:");
            if ([sceneIdentCls respondsToSelector:sel]) {
                NSString *ident = [[NSBundle mainBundle] bundleIdentifier];
                id identity = ((id(*)(id, SEL, id))objc_msgSend)(sceneIdentCls, sel, ident);
                if (identity) {
                    SEL setSel = NSSelectorFromString(@"setIdentity:");
                    if ([def respondsToSelector:setSel]) {
                        ((void(*)(id, SEL, id))objc_msgSend)(def, setSel, identity);
                        hud_mark(@"fb-ident-set-ok-sceneident");
                    } else {
                        [def setValue:identity forKey:@"identity"];
                        hud_mark(@"fb-ident-set-kvc");
                    }
                } else {
                    hud_mark(@"fb-ident-nil-sceneident");
                }
            } else {
                hud_mark(@"fb-ident-no-sel-sceneident");
            }
        } else {
            hud_mark(@"fb-ident-class-missing-sceneident");
        }
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"fb-ident-ex-%@", e.name]);
    }

    /* 4. specification —— ★ v1.8.51 照反汇编铁证（主 App v1.8.49 实测
       FBSSceneSpecification +specification 存在且 setSpecification 成功） */
    id spec = nil;
    @try {
        Class specCls = NSClassFromString(@"FBSSceneSpecification");
        if (specCls) {
            SEL sel = NSSelectorFromString(@"specification");
            if ([specCls respondsToSelector:sel]) {
                spec = ((id(*)(id, SEL))objc_msgSend)(specCls, sel);
                hud_mark(spec ? @"fb-spec-ok" : @"fb-spec-nil");
            }
        }
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"fb-spec-ex-%@", e.name]);
    }
    if (!spec) {
        Class sc = NSClassFromString(@"FBSMutableSceneSpecification");
        if (sc) { spec = ((id(*)(id, SEL))objc_msgSend)(sc, NSSelectorFromString(@"new")); hud_mark(@"fb-spec-new"); }
    }
    if (spec) {
        @try {
            SEL setSel = NSSelectorFromString(@"setSpecification:");
            if ([def respondsToSelector:setSel]) {
                ((void(*)(id, SEL, id))objc_msgSend)(def, setSel, spec);
                hud_mark(@"fb-spec-set-ok");
            } else {
                [def setValue:spec forKey:@"specification"];
                hud_mark(@"fb-spec-set-kvc");
            }
        } @catch (NSException *e) {
            hud_mark([NSString stringWithFormat:@"fb-spec-set-ex-%@", e.name]);
        }
    }

    /* 5. parameters —— ★ v1.8.51 照反汇编：+parametersForSpecification:spec
       （不是 new！主 App v1.8.49 实测 fb-params-from-spec 成功） */
    id params = nil;
    @try {
        Class paramsCls = NSClassFromString(@"FBSMutableSceneParameters");
        if (!paramsCls) { hud_mark(@"fb-params-missing"); return; }
        hud_mark(@"fb-params-class-ok");
        SEL sel = NSSelectorFromString(@"parametersForSpecification:");
        if ([paramsCls respondsToSelector:sel]) {
            params = ((id(*)(id, SEL, id))objc_msgSend)(paramsCls, sel, spec);
            hud_mark(params ? @"fb-params-from-spec" : @"fb-params-from-spec-nil");
        }
        if (!params) {
            params = ((id(*)(id, SEL))objc_msgSend)(paramsCls, NSSelectorFromString(@"new"));
            hud_mark(@"fb-params-new-fallback");
        }
        if (!params) { hud_mark(@"fb-params-fail"); return; }
        /* 照反汇编配置 params */
        for (NSString *s in @[@"setForeground:", @"setInterfaceOrientation:", @"setLevel:"]) {
            SEL ps = NSSelectorFromString(s);
            if ([params respondsToSelector:ps]) {
                ((void(*)(id, SEL, int))objc_msgSend)(params, ps, 1);
            }
        }
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"fb-params-ex-%@", e.name]);
        return;
    }

    /* 6. createSceneWithDefinition:initialParameters: —— ★ v1.8.51 主线程同步调用！
       v1.8.50 实测铁证（主 App crash report 181635.ips + fb-create-ex main thread）：
       createScene 必须在主线程（v1.8.42 后台线程触发断言）。HUD 是独立进程
       （无 app scene session，主 App trap 的问题在 HUD 不存在）→ createScene
       创建第一个 scene → FrontBoard 接受。 */
    id fbScene = nil;
    @try {
        SEL createSel = NSSelectorFromString(@"createSceneWithDefinition:initialParameters:");
        if (![manager respondsToSelector:createSel]) { hud_mark(@"fb-create-no-sel"); return; }
        hud_mark(@"fb-create-sel-ok");
        fbScene = ((id(*)(id, SEL, id, id))objc_msgSend)(manager, createSel, def, params);
        hud_mark(fbScene ? @"fb-scene-created" : @"fb-create-returned-nil");
        if (!fbScene) return;
        /* 存全局防释放 */
        objc_setAssociatedObject([HUDAppDelegate class], "ovFBScene", fbScene, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"fb-create-out-ex-%@", e.name]);
        return;
    }

    /* 6. binder addScene */
    @try {
        Class binderCls = NSClassFromString(@"UIRootWindowScenePresentationBinder");
        if (!binderCls) { hud_mark(@"binder-missing"); return; }
        hud_mark(@"binder-class-ok");
        id binder = ((id(*)(id, SEL))objc_msgSend)(binderCls, NSSelectorFromString(@"new"));
        if (!binder) { hud_mark(@"binder-new-fail"); return; }
        hud_mark(@"binder-created");
        SEL addSel = NSSelectorFromString(@"addScene:");
        if ([binder respondsToSelector:addSel]) {
            ((void(*)(id, SEL, id))objc_msgSend)(binder, addSel, fbScene);
            hud_mark(@"fb-scene-bound");
            objc_setAssociatedObject([HUDAppDelegate class], "ovFBBinder", binder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            hud_mark(@"binder-no-addscene");
        }
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"binder-ex-%@", e.name]);
    }
}

/* 类方法版 SBS 注册（窗口用 g_manualWindow） */
+ (void)manualRegisterToSpringBoard {
    unsigned int cid = 0;
    @try {
        id win = g_manualWindow;
        if (!win) { hud_mark(@"sbs-no-window"); return; }
        SEL sel = NSSelectorFromString(@"_contextId");
        if ([win respondsToSelector:sel]) {
            NSMethodSignature *sig = [win methodSignatureForSelector:sel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:win];
                [inv setSelector:sel];
                [inv invoke];
                if (sig.methodReturnType[0] == '@') {
                    __unsafe_unretained id ret = nil;
                    [inv getReturnValue:&ret];
                    if (ret && [ret isKindOfClass:[NSNumber class]]) cid = [ret unsignedIntValue];
                } else if (sig.methodReturnLength == 4) {
                    unsigned int v = 0;
                    [inv getReturnValue:&v];
                    cid = v;
                }
            }
        }
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"cid-ex-%@", e.name]);
    }
    if (cid == 0) { hud_mark(@"sbs-cid-zero"); return; }
    hud_mark([NSString stringWithFormat:@"sbs-cid-%u", cid]);

    @try {
        Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
        if (!cls) { hud_mark(@"sbs-class-missing"); return; }
        id ctrl = ((id(*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"new"));
        SEL regSel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
        if ([ctrl respondsToSelector:regSel]) {
            NSMethodSignature *sig = [ctrl methodSignatureForSelector:regSel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:ctrl];
                [inv setSelector:regSel];
                [inv setArgument:&cid atIndex:2];
                double level = (double)20000002.0;
                [inv setArgument:&level atIndex:3];
                [inv invoke];
                hud_mark([NSString stringWithFormat:@"registered-cid=%u", cid]);
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                    CFSTR("com.apple.hudservices.windowRegistered"), NULL, NULL, true);
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                    CFSTR("com.apple.springboard.hudwindow.registered"), NULL, NULL, true);
            }
        }
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"sbs-ex-%@", e.name]);
    }
}


- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    hud_mark(@"appdelegate");

    /* ★ v1.8.57 照开源 Letterpress（TrollStore 悬浮窗 TRHud，GitHub
       OwnGoalStudio/Letterpress）完整复刻：legacy 模式（无 SceneManifest）+
       窗口 initWithFrame: 不绑 scene + SBSAccessibilityWindowHostingController
       registerWindowWithContextID:atLevel: = 全局悬浮球。
       scene-based 是错的（v1.8.44 实测 willConnect 不触发/不稳定；窗口绑 scene
       切后台挂起；不绑 scene 在 scene-based app 里 cid-zero）。
       legacy 模式无 scene 生命周期 → 窗口直接 WindowServer 拿 cid → SBS 注册
       → SpringBoard 托管 → 切后台全局。不再 createScene（裸进程 v1.8.52 卡死）。 */
    @try {
        /* 窗口：HUDMainWindow（_isSystemWindow/_isWindowServerHostingManaged=NO，
           Letterpress TRHudMainWindow 同款）+ initWithFrame 不绑 scene */
        self.window = [[HUDMainWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        self.window.backgroundColor = [UIColor clearColor];
        self.window.windowLevel = 10000001.0;   /* Letterpress 同款 level */
        self.window.clipsToBounds = YES;

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        self.window.rootViewController = vc;

        /* 悬浮球（靠右，与主 App 球区分） */
        CGFloat size = 56;
        CGFloat x = [UIScreen mainScreen].bounds.size.width - 20 - size;
        CGFloat y = [UIScreen mainScreen].bounds.size.height / 2 - size;
        HUDBall *ball = [[HUDBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
        [vc.view addSubview:ball];

        [self.window makeKeyAndVisible];
        hud_mark(@"window-shown");

        /* Letterpress 同款：_boundContext setSecure（拿 context 前先设安全） */
        @try {
            if ([self.window respondsToSelector:@selector(_boundContext)]) {
                id boundCtx = [self.window _boundContext];
                if (boundCtx && [boundCtx respondsToSelector:@selector(setSecure:)]) {
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(boundCtx,
                        NSSelectorFromString(@"setSecure:"), YES);
                    hud_mark(@"bound-ctx-secure");
                }
            }
        } @catch (NSException *e) {
            hud_mark([NSString stringWithFormat:@"boundctx-ex-%@", e.name]);
        }

        /* SBS 注册（照 Letterpress：_contextId + registerWindowWithContextID:atLevel:） */
        [self registerToSpringBoard];
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"hud-window-ex-%@", e.name]);
    }

    /* 兜底：2s 后没注册成功就再注册一次（cid 可能延迟分配） */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            if (self.window) {
                [self registerToSpringBoard];
                hud_mark(@"re-register-2s");
            }
        } @catch (NSException *e) { }
    });

    return YES;
}

/* ★ v1.8.1 照懒人 RootCore：FBSceneManager 手动创建二进制 scene +
   UIRootWindowScenePresentationBinder 绑定到系统 root window 层。
   全部私有 API objc_msgSend 动态调用，包 @try 防崩。 */
- (void)createFrontBoardScene {
    @try {
        Class mgrCls = NSClassFromString(@"FBSceneManager");
        if (!mgrCls) { hud_mark(@"fb-mgr-missing"); return; }
        id manager = nil;
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if ([mgrCls respondsToSelector:sharedSel]) {
            manager = ((id(*)(id, SEL))objc_msgSend)(mgrCls, sharedSel);
        }
        if (!manager) manager = ((id(*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"new"));
        if (!manager) { hud_mark(@"fb-mgr-fail"); return; }

        Class defCls = NSClassFromString(@"FBSMutableSceneDefinition");
        if (!defCls) { hud_mark(@"fb-def-missing"); return; }
        id def = ((id(*)(id, SEL))objc_msgSend)(defCls, NSSelectorFromString(@"new"));

        Class identCls = NSClassFromString(@"FBSMutableSceneIdentity");
        if (identCls) {
            SEL initSel = NSSelectorFromString(@"initWithBundleIdentifier:");
            id identity = ((id(*)(id, SEL, id))objc_msgSend)(
                ((id(*)(id, SEL))objc_msgSend)(identCls, NSSelectorFromString(@"alloc")),
                initSel, [[NSBundle mainBundle] bundleIdentifier]);
            if (identity) {
                ((void(*)(id, SEL, id))objc_msgSend)(def, NSSelectorFromString(@"setIdentity:"), identity);
            }
        }

        Class paramsCls = NSClassFromString(@"FBSMutableSceneParameters");
        id params = paramsCls ? ((id(*)(id, SEL))objc_msgSend)(paramsCls, NSSelectorFromString(@"new")) : nil;
        if (!params) { hud_mark(@"fb-params-fail"); return; }

        SEL createSel = NSSelectorFromString(@"createSceneWithDefinition:initialParameters:");
        if (![manager respondsToSelector:createSel]) { hud_mark(@"fb-create-no-sel"); return; }
        id fbScene = ((id(*)(id, SEL, id, id))objc_msgSend)(manager, createSel, def, params);
        if (!fbScene) { hud_mark(@"fb-create-fail"); return; }
        hud_mark(@"fb-scene-created");

        Class binderCls = NSClassFromString(@"UIRootWindowScenePresentationBinder");
        if (!binderCls) { hud_mark(@"binder-missing"); return; }
        id binder = ((id(*)(id, SEL))objc_msgSend)(binderCls, NSSelectorFromString(@"new"));
        SEL addSel = NSSelectorFromString(@"addScene:");
        if ([binder respondsToSelector:addSel]) {
            ((void(*)(id, SEL, id))objc_msgSend)(binder, addSel, fbScene);
            hud_mark(@"fb-scene-bound");
        } else {
            hud_mark(@"binder-no-addscene");
        }
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"fb-bind-ex-%@", e.name]);
    }
}

- (unsigned int)windowContextID {
    SEL sel = NSSelectorFromString(@"_contextId");
    if (![self.window respondsToSelector:sel]) return 0;
    NSMethodSignature *sig = [self.window methodSignatureForSelector:sel];
    if (!sig) return 0;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:self.window];
    [inv setSelector:sel];
    [inv invoke];
    if (sig.methodReturnType[0] == '@') {
        __unsafe_unretained id ret = nil;
        [inv getReturnValue:&ret];
        if (ret && [ret isKindOfClass:[NSNumber class]]) {
            return [ret unsignedIntValue];
        }
        return 0;
    }
    if (sig.methodReturnLength == 4) {
        unsigned int v = 0;
        [inv getReturnValue:&v];
        return v;
    }
    return 0;
}

static int g_register_attempts = 0;

- (void)registerToSpringBoard {
    unsigned int cid = [self windowContextID];
    if (cid == 0) {
        if (g_register_attempts++ < 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self registerToSpringBoard];
            });
        }
        return;
    }
    g_register_attempts = 0;
    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!cls) {
        hud_mark(@"sbs-class-missing");
        return;
    }
    id ctrl = ((id(*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"new"));
    SEL regSel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if ([ctrl respondsToSelector:regSel]) {
        NSMethodSignature *sig = [ctrl methodSignatureForSelector:regSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:ctrl];
            [inv setSelector:regSel];
            [inv setArgument:&cid atIndex:2];
            double level = (double)self.window.windowLevel;
            [inv setArgument:&level atIndex:3];
            [inv invoke];
            NSLog(@"[AilinHUD] registered cid=%u", cid);
            hud_mark([NSString stringWithFormat:@"registered-cid=%u", cid]);
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.apple.hudservices.windowRegistered"), NULL, NULL, true);
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.apple.springboard.hudwindow.registered"), NULL, NULL, true);
        }
    }
}

- (void)applicationWillResignActive:(UIApplication *)application {}
- (void)applicationDidEnterBackground:(UIApplication *)application {}

@end
