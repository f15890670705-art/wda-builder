//
// FloatingWindowManager.m
//
// 全局悬浮窗：懒人同款 SBSAccessibilityWindowHostingController 方案
//   1. 创建高 windowLevel 的 UIWindow（普通 App 只能盖自己界面）
//   2. 取 window 的 contextID（需等 WindowServer 分配，延迟+重试）
//   3. SBSAccessibilityWindowHostingController registerWindowWithContextID:atLevel:
//      → 把窗口注册进 SpringBoard → 悬浮在所有 App 之上
//   4. 发 HUD 通知确认注册
//   5. App 回前台/后台切换时重新注册，防止 SpringBoard 移除后丢失
//
#import "FloatingWindowManager.h"
#import "FloatingBall.h"
#import <objc/message.h>
#import <dlfcn.h>

/* SBSAccessibilityWindowHostingController 私有类声明（运行时 NSClassFromString） */
@interface SBSAccessibilityWindowHostingController : NSObject
- (void)registerWindowWithContextID:(unsigned int)contextID atLevel:(double)level;
- (void)unregisterWindowWithContextID:(unsigned int)contextID;
@end

/* ★ v1.6.1 照懒人/AutoGo 反汇编铁证：iOS13+ 悬浮球正确姿势 =
   UIRootWindowScenePresentationBinder 把窗口绑定到系统 root window scene
   （懒人 RootService 符号表有 UIRootWindowScenePresentationBinder + addScene: +
   setBinder:；AutoGo agoverlayd 也是 ovBindWindowSceneFromBinder）。
   只 SBS 注册不够：窗口 bind 在主 App scene 上，切后台 scene 挂起 → contextID
   变垃圾大数（设备日志 reg-ok-233044077→3077728→...每次不同）→ 球消失。
   binder 绑定后窗口显示在系统 root window 层，独立于 App 生命周期。 */
@interface UIRootWindowScenePresentationBinder : NSObject
+ (instancetype)new;   /* 私有类，运行时 NSClassFromString */
- (void)addScene:(id)scene;
@end

/* 穿透窗口：SBS 托管需要全屏窗口（context 稳定不消失），但全屏窗口默认会把
   整个屏幕的触摸都拦下来（hitTest 无子视图命中时返回 self，不是 nil！）。
   重写 hitTest：只有命中悬浮球才响应，命中窗口自身/透明背景 → 返回 nil → 穿透
   给下层主窗口（TabBar 等照常可点）。

   ★ v1.6.8 照懒人 MyCustomWindow 完整类结构反汇编铁证（class_ro_t@0x1000be708）：
   懒人 override 的是【类方法】不是实例方法！且返回值照原样：
     +_isSystemWindow              → YES
     +_shouldResizeWithScene       → YES
     +_isSettingFirstResponder     → YES
     +_isWindowServerHostingManaged → NO   （v1.6.4 错误地 override 实例方法且返回 YES！）
     +isInternalWindow             → NO
   用类方法 override（+ 号），UIKit 通过类对象查询这些私有接口。 */
@interface FloatingBallWindow : UIWindow
@end

@implementation FloatingBallWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) {
        return nil;   /* 窗口自身 / rootVC 全屏透明背景 → 穿透 */
    }
    return hit;       /* 悬浮球（ball 及其子视图）→ 正常响应 */
}

/* ★ v1.6.8 照懒人 MyCustomWindow：类方法 override（懒人是 + 号元类方法） */
+ (BOOL)_isSystemWindow { return YES; }
+ (BOOL)_shouldResizeWithScene { return YES; }
+ (BOOL)_isSettingFirstResponder { return YES; }
+ (BOOL)_isWindowServerHostingManaged { return NO; }
+ (BOOL)isInternalWindow { return NO; }
+ (BOOL)_ignoresHitTest { return NO; }
+ (BOOL)_isSecure { return NO; }
+ (BOOL)_shouldCreateContextAsSecure { return NO; }
@end

@interface FloatingWindowManager ()
@property (nonatomic, strong) id hostingController;
@property (nonatomic, strong) id rootBinder;        /* ★ v1.6.1 UIRootWindowScenePresentationBinder 实例 */
@property (nonatomic, assign) BOOL registered;
@property (nonatomic, strong) FloatingBall *ball;
@property (nonatomic, strong) NSTimer *hbTimer;      /* v1.8.20 30s 心跳：只上报 hb-alive */
@property (nonatomic, assign) unsigned int cachedCid;  /* 同一窗口 contextID 不变，拿到一次缓存复用 */
@property (nonatomic, strong) UIWindowScene *detachedScene; /* v1.8.22 切后台脱离的 scene（回前台绑回） */
@property (nonatomic, strong) id independentScene;   /* ★ v1.8.47 主 App 进程内创建的独立二进制 FBScene */
@end

@implementation FloatingWindowManager

+ (instancetype)shared {
    static FloatingWindowManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [FloatingWindowManager new]; });
    return inst;
}

/* App 状态上报到引擎日志（远程 curl /log 可查 App 生命周期/存活）。
   ★ v1.8.5 双通道：① 写本地文件 /tmp/ailintouch_app.log —— App 启动瞬间
   引擎可能还没 spawn/监听 8080，HTTP 会静默失败（用户铁证"app启动的时候
   引擎二进制还没有启动怎么可能有日志"！启动关键上报 root-scene-ok/
   ball-shown 全丢了）；落盘后引擎就绪 /log 端点合并读取。② 异步 HTTP。
   ★ v1.8.11 节流：同一条 msg 15 秒内只上报一次（用户铁证"手机发烫"——
   切后台系统强压 hidden 时 hidden-revive 每 0.5s 刷一次 = 每秒 2 次写文件
   +2 次 HTTP，直接发烫！节流后最多 15s 一次）。
   ★ v1.8.14 日志整理：去掉 HTTP 上报（引擎 /log 直接读文件，HTTP 造成
   同一事件出现两遍的重复日志）。只写文件，格式 [HH:mm:ss.SSS] [app] msg。 */
- (void)reportToEngine:(NSString *)msg {
    static NSMutableDictionary *lastSent = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lastSent = [NSMutableDictionary new]; });
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSNumber *last = lastSent[msg];
    if (last && (now - last.doubleValue) < 15.0) return;
    lastSent[msg] = @(now);

    @try {
        NSString *appLog = @"/tmp/ailintouch_app.log";
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:appLog];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:appLog
                                                    contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:appLog];
        }
        if (fh) {
            [fh seekToEndOfFile];
            NSDateFormatter *df = [NSDateFormatter new];
            df.dateFormat = @"HH:mm:ss.SSS";
            NSString *line = [NSString stringWithFormat:@"[%@] [app] %@\n",
                              [df stringFromDate:[NSDate date]], msg];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) { }
}

- (void)showFloatingBall {
    [self showFloatingBallInScene:[[[UIApplication sharedApplication] connectedScenes] anyObject]];
}

/* v1.5.2: iOS 13+ scene 模式下 UIWindow 必须绑定 windowScene 才能显示。
   AilinTouchSceneDelegate 调用时传当前 scene。
   v1.5.4: 窗口改回【全屏透明】+ 球子视图（懒人同款）。v1.2.7 的 56×56 小窗口
   context 不稳定——SBS 托管的 context 需要全屏窗口才稳定全局显示，
   切主界面"挺一会"就没了 = 小窗口 context 被回收。全屏窗口 + hitTest 穿透
   （FloatingBallWindow 已实现：命中自身/透明背景返回 nil）不影响点击。
   ★ v1.6.0 照懒人反汇编（scene:willConnect 0x10001d0d8）铁证：窗口必须用
   initWithWindowScene: 创建（iOS13+ 正确姿势，窗口真正 attach 到 scene 拿到
   有效 WindowServer contextID）。之前 initWithFrame:+手动赋值 windowScene
   → _contextId 拿不到有效值（设备日志 reg-ok-3837087202 每次不同的大数=垃圾）！
   懒人窗口：MyCustomWindow = [[MyCustomWindow alloc] initWithWindowScene:scene] */
- (void)showFloatingBallInScene:(UIWindowScene *)windowScene {
    if (self.floatingWindow) return;

    CGFloat size = 56;                          /* 球尺寸 */
    CGFloat x = 20;                             /* 初始靠左 */

    /* ★ v1.6.0: initWithWindowScene:（懒人 scene:willConnect 同款）。
       窗口 frame 初始为 scene bounds（随后布局球），全屏透明。 */
    CGRect full = windowScene ? windowScene.coordinateSpace.bounds : [UIScreen mainScreen].bounds;
    CGFloat y = full.size.height / 2 - size;

    /* ★ v1.8.4 用户铁证"懒人是不是一直在获取前台的scene" + 懒人符号铁证：
       懒人 RootService/RootCore 都含 @_OBJC_CLASS_$_UIRootSceneWindow +
       UIRootWindowScenePresentationBinder + connectedScenes ——
       懒人悬浮球窗口【优先绑定系统 root window scene】（UIRootSceneWindow
       持有的 scene，永远存在、永远激活）→ 不随 App 的 main scene 挂起 →
       切后台球不消失！v1.8.3 绑 main scene 切后台被系统强制隐藏的根因。
       ★ v1.8.7 修复：v1.8.6 用 KVC valueForKey:@"_rootWindowScene" 抛异常
       （root-scene-ex-fallback-main，iOS15+ UIScreen 私有 API 变化）。
       改【多 key + NSInvocation】动态调用 getter（懒人 safeGetWindowContextID
       同款姿势），key 候选：_rootWindowScene / _rootSceneWindow / _rootScene /
       _windowScene；_rootSceneWindow 是 UIWindow → 取其 windowScene。 */
    UIWindowScene *bindScene = windowScene;
    NSArray *rootKeys = @[@"_rootWindowScene", @"_rootSceneWindow",
                          @"_rootScene", @"_windowScene"];
    for (NSString *k in rootKeys) {
        @try {
            id v = nil;
            SEL sel = NSSelectorFromString(k);
            if ([[UIScreen mainScreen] respondsToSelector:sel]) {
                NSMethodSignature *sig = [[UIScreen mainScreen] methodSignatureForSelector:sel];
                if (sig && sig.methodReturnLength >= 4 && sig.methodReturnType[0] == '@') {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:[UIScreen mainScreen]];
                    [inv setSelector:sel];
                    [inv invoke];
                    __unsafe_unretained id ret = nil;
                    [inv getReturnValue:&ret];
                    v = ret;
                }
            }
            if (v) {
                UIWindowScene *rs = nil;
                if ([v isKindOfClass:[UIWindow class]]) {
                    rs = ((UIWindow *)v).windowScene;
                } else if ([v isKindOfClass:[UIWindowScene class]]) {
                    rs = (UIWindowScene *)v;
                }
                if (rs) {
                    bindScene = rs;
                    [self reportToEngine:[NSString stringWithFormat:@"root-scene-ok-%@", k]];
                    break;
                }
            }
        } @catch (NSException *e) { }
    }
    if (bindScene == windowScene) {
        [self reportToEngine:@"root-scene-nil-fallback-main"];
    }

    /* ★ v1.8.13 恢复最简可靠路径：直接绑 scene（v1.8.3-11 已验证球显示）。
       v1.8.12 不绑 scene 两次实测（12:27/12:42）均 cid-zero-fallback ——
       确认我们环境（TrollStore + 前台 App）下 WindowServer 不给不绑 scene
       窗口分配 contextID，daemon 化无此能力，懒人靠的是别的机制（其窗口
       在 RootService daemon 进程中）。不再尝试，直接绑 scene 保证显示。 */
    self.floatingWindow = [[FloatingBallWindow alloc] initWithWindowScene:bindScene];
    if (!self.floatingWindow) {
        /* 兜底：scene 为 nil 时退回旧姿势 */
        self.floatingWindow = [[FloatingBallWindow alloc] initWithFrame:full];
        self.floatingWindow.windowScene = bindScene;
    }
    self.floatingWindow.windowLevel = 20000002;
    self.floatingWindow.backgroundColor = [UIColor clearColor];

    /* 轻量 root VC 承载悬浮球 */
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    self.floatingWindow.rootViewController = vc;

    FloatingBall *ball = [[FloatingBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
    ball.onTap = self.onTap;
    [vc.view addSubview:ball];
    self.ball = ball;

    /* ★ v1.5.6: makeKeyAndVisible（懒人同款）—— iOS13+ scene 模式多窗口共存，
       窗口必须 makeKeyAndVisible 才会被 WindowServer 分配 contextID + SBS 托管。
       v1.1.x 因 legacy 单窗口模式抢 key window 回退成 hidden=NO，
       scene 模式下没有这个顾虑（主窗口仍 visible 显示）。 */
    [self.floatingWindow makeKeyAndVisible];

    /* 立即注册（若 contextID 尚未分配会失败，走 retry 补齐） */
    [self registerToSpringBoardWithRetry];

    /* ★ v1.8.47 主 App 进程内创建独立二进制 FBScene（主 App 是合法 app 身份，
       FrontBoard 认可 → createScene 断言能过；HUD 独立进程 v1.8.42/45 断言
       失败 FBSceneManager.m:462 就是身份问题）。创建成功 + binder 绑系统
       root window 层 → 独立 scene 不随 app main scene 挂起 → 球切后台全局。 */
    [self createIndependentFBScene];

    /* ★ v1.8.20 删除触摸轮询（touchTimer 0.15s 读文件）——高频文件 I/O
       卡顿源之一，且用户早已指出该方案不行。球点击保留前台 tap 手势，
       后台点击留待引擎侧命中检测方案。 */

    /* ★ v1.8.20 心跳简化：30s 一次，只上报 hb-alive，【不再做 SBS 注册】。
       SBS 注册交给前台激活（scene 通知，v1.8.46）——cid 稳定后注册一次。
       ★ v1.8.46 删除心跳里的 detach 兜底：v1.8.40/41 实测 detach 丢 cid
       （脱离 scene 后 WindowServer 回收 context），且 daemon 化 App 的
       applicationDidBecomeActive 不触发 → detach 后回前台永远恢复不了。
       切后台不做任何操作，让 SBS 托管自己撑；回前台 scene 通知重新注册。 */
    self.hbTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *t) {
        [self reportToEngine:@"hb-alive"];
    }];

    /* ★ v1.8.13 删除 hiddenKeepTimer：v1.8.12 实测 reg-ok 的 contextID 每
       15 秒心跳都在变（2874493361→279838510→709162564→2901182776→92634869）
       —— 强烈怀疑 hiddenKeepTimer 反复 setHidden:NO 与系统强压互相拉扯，
       导致窗口反复 attach/detach → contextID 每轮重分配 → SBS 托管不稳。
       删掉它，依赖 applicationDidBecomeActive 重注册。
       （若切后台球消失，说明问题在 scene 激活状态，setHidden 强顶无效，
       保留它只会让 cid 一直抖。） */

    /* ★ v1.8.20 删除 sceneFollowTimer（3s 遍历 connectedScenes）——高频枚举
       卡顿源之一；root scene 拿不到（iOS15+），跟随前台 scene 效果有限。 */

    [self reportToEngine:@"ball-shown"];

    /* ★ v1.8.41 监听 scene 后台/失活通知 —— ★ v1.8.46 只打点不再 detach：
       v1.8.40/41 实测 detach 丢 cid 无效（脱离 scene 后 WindowServer 回收
       context），且 daemon 化 App 的 applicationDidBecomeActive 不触发导致
       detach 后回前台无法恢复（用户铁证"切一次后台球再也不显示"）。
       切后台不动窗口（SBS 托管自己撑），回前台 scene 激活通知重新注册。 */
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:UISceneDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(sceneDidGoBackground:)
        name:UISceneDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:UISceneWillDeactivateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(sceneDidGoBackground:)
        name:UISceneWillDeactivateNotification object:nil];

    /* ★ v1.8.46 回前台恢复（daemon 化 App 的 applicationDidBecomeActive 不触发，
       但 scene 激活通知会发）：attach 回 scene + 重新 SBS 注册。 */
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:UISceneWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(sceneWillComeForeground:)
        name:UISceneWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:UISceneDidActivateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(sceneWillComeForeground:)
        name:UISceneDidActivateNotification object:nil];
}

/* ★ v1.8.46 scene 进入后台/失活 → 只打点，不 detach（v1.8.40/41 实测 detach
   丢 cid 无效；切后台 SBS 托管自然失效由系统决定，回前台 scene 通知恢复） */
- (void)sceneDidGoBackground:(NSNotification *)note {
    [self reportToEngine:@"scene-bg"];
}

/* ★ v1.8.46 scene 回前台/激活 → attach 回 scene + 重新 SBS 注册（恢复球） */
- (void)sceneWillComeForeground:(NSNotification *)note {
    [self reportToEngine:@"scene-fg-recover"];
    [self attachBallToScene];
    [self registerToSpringBoardWithRetry];
}

- (void)hideFloatingBall {
    if (!self.floatingWindow) return;
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:UISceneDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:UISceneWillDeactivateNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:UISceneWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:UISceneDidActivateNotification object:nil];
    [self.hbTimer invalidate];
    self.hbTimer = nil;
    [self unregisterFromSpringBoard];
    self.floatingWindow.hidden = YES;
    self.floatingWindow = nil;
    self.ball = nil;
    self.detachedScene = nil;
}

/* ★ v1.8.22 切后台：球窗口【脱离 scene】（windowScene=nil）。
   用户实测铁证：App 完全重启创建全局球，前台一直全局；一切后台就变 App 内
   —— 因为窗口绑 scene，scene 不激活 → 系统强制隐藏窗口 → SBS 托管失效。
   脱离 scene 后窗口不随 scene 隐藏，保留已分配的 contextID + SBS 托管
   → 球继续全局显示。回前台 attachBallToScene 绑回。 */
- (void)detachBallFromScene {
    if (!self.floatingWindow) return;
    if (self.floatingWindow.windowScene) {
        self.detachedScene = self.floatingWindow.windowScene;
        self.floatingWindow.windowScene = nil;
        [self reportToEngine:@"ball-detach-scene"];
    }
}

- (void)attachBallToScene {
    if (!self.floatingWindow) return;
    if (self.detachedScene && !self.floatingWindow.windowScene) {
        self.floatingWindow.windowScene = self.detachedScene;
        self.detachedScene = nil;
        [self reportToEngine:@"ball-attach-scene"];
    }
}

/* ★ v1.6.1: UIRootWindowScenePresentationBinder 绑定（懒人/AutoGo 反汇编铁证）。
   创建 binder 实例，把窗口的 scene addScene: 进去 → 窗口显示在系统 root window
   层。这是 iOS13+ 悬浮球"全局 + 持久"的核心机制，纯 SBS 注册做不到。
   ⚠️ v1.6.2 修正：addScene: 需要的是【FBScene】（UIWindowScene 内部持有的
   FrontBoard scene），直接传 UIWindowScene 会抛异常（设备日志 binder-exception）。
   从 windowScene 取私有 _fbScene（或 _scene）再传。 */
- (void)bindToRootWindowScene:(UIWindowScene *)windowScene {
    @try {
        Class binderCls = NSClassFromString(@"UIRootWindowScenePresentationBinder");
        if (!binderCls) {
            [self reportToEngine:@"binder-class-missing"];
            return;
        }
        if (!self.rootBinder) {
            self.rootBinder = [[binderCls alloc] init];
            [self reportToEngine:@"binder-created"];
        }
        /* addScene: 参数 = FBScene（windowScene 的私有 _fbScene / _scene ivar）。
           ★ v1.8.7 修复：v1.8.6 用 valueForKey 拿 _fbScene 抛异常被吞 → nil →
           fallback 传 windowScene → addScene 抛 binder-exception！
           改用 NSInvocation 动态调用（懒人 safeGetWindowContextID 同款姿势）。 */
        id fbScene = nil;
        for (NSString *k in @[@"_fbScene", @"_scene"]) {
            @try {
                SEL sel = NSSelectorFromString(k);
                if (![windowScene respondsToSelector:sel]) continue;
                NSMethodSignature *sig = [windowScene methodSignatureForSelector:sel];
                if (!sig || sig.methodReturnLength < 4 || sig.methodReturnType[0] != '@') continue;
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:windowScene];
                [inv setSelector:sel];
                [inv invoke];
                __unsafe_unretained id ret = nil;
                [inv getReturnValue:&ret];
                if (ret) { fbScene = ret; [self reportToEngine:[NSString stringWithFormat:@"fbscene-got-%@", k]]; break; }
            } @catch (NSException *e) { }
        }
        if (!fbScene) {
            /* ★ v1.8.10 修复：v1.8.6/1.8.7 fbScene 拿不到时 fallback 传
               windowScene → addScene: 类型不符抛 binder-exception！
               iOS15+ UIWindowScene 的 _fbScene 私有 ivar 可能改名/移除。
               拿不到就跳过 binder（不 fallback 错类型），日志明确。 */
            [self reportToEngine:@"binder-no-fbscene-skip"];
            return;
        }
        if ([self.rootBinder respondsToSelector:@selector(addScene:)]) {
            [self.rootBinder addScene:fbScene];
            [self reportToEngine:@"binder-addscene-ok"];
        } else {
            [self reportToEngine:@"binder-no-addscene"];
        }
    } @catch (NSException *e) {
        [self reportToEngine:@"binder-exception"];
    }
}

/* ★ v1.8.47 主 App 进程内创建独立二进制 FBScene + binder 绑系统 root window。
   v1.8.42/45 在 HUD 独立进程（非 launchd daemon）createScene 断言失败
   （FBSceneManager.m:462），主 App 是正常安装注册的 app（合法 FrontBoard
   身份）→ createScene 应能成功。成功 → binder addScene 绑系统层 → 独立
   scene 不随 app main scene 生命周期 → 球切后台全局（懒人 RootCore 机制）。 */
- (void)createIndependentFBScene {
    @try {
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard", RTLD_NOW);
    } @catch (NSException *e) { }

    @try {
        Class mgrCls = NSClassFromString(@"FBSceneManager");
        if (!mgrCls) { [self reportToEngine:@"fb-mgr-missing"]; return; }
        id manager = nil;
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if ([mgrCls respondsToSelector:sharedSel]) {
            manager = ((id(*)(id, SEL))objc_msgSend)(mgrCls, sharedSel);
        }
        if (!manager) manager = ((id(*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"new"));
        if (!manager) { [self reportToEngine:@"fb-manager-fail"]; return; }

        Class defCls = NSClassFromString(@"FBSMutableSceneDefinition");
        if (!defCls) { [self reportToEngine:@"fb-def-missing"]; return; }
        id def = ((id(*)(id, SEL))objc_msgSend)(defCls, NSSelectorFromString(@"new"));

        /* ★★ v1.8.49 照懒人 RootCore 反汇编铁证完整重写（0x100080ad4~0x100080d40）：
           [FBSSceneIdentity identityForIdentifier:[[NSBundle mainBundle] bundleIdentifier]]
           → [def setIdentity:] → [def setClientIdentity:localIdentity] →
           [某类 specification] → [def setSpecification:] →
           [FBSMutableSceneParameters parametersForSpecification:spec]（不是 new!）→
           params 配置 → [[FBSceneManager sharedInstance] createSceneWithDefinition:def
           initialParameters:params]。462 断言= def 缺 identity/specification（我们一直
           缺后面这个）。每个调用打标，失败看日志定位。 */

        /* 2. identity：+identityForIdentifier:（懒人用的方法名，v1.8.48 的
           identityWithIdentifier: 是错的方法名） */
        id identity = nil;
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        for (NSString *clsName in @[@"FBSSceneIdentity", @"FBSMutableSceneIdentity"]) {
            Class identCls = NSClassFromString(clsName);
            if (!identCls) { [self reportToEngine:[NSString stringWithFormat:@"fb-ident-cls-missing-%@", clsName]]; continue; }
            @try {
                SEL sel = NSSelectorFromString(@"identityForIdentifier:");
                if ([identCls respondsToSelector:sel]) {
                    identity = ((id(*)(id, SEL, id))objc_msgSend)(identCls, sel, bundleId);
                    [self reportToEngine:identity ? [NSString stringWithFormat:@"fb-ident-ok-%@", clsName]
                                                  : [NSString stringWithFormat:@"fb-ident-nil-%@", clsName]];
                } else {
                    [self reportToEngine:[NSString stringWithFormat:@"fb-ident-nosel-%@", clsName]];
                }
            } @catch (NSException *e) {
                [self reportToEngine:[NSString stringWithFormat:@"fb-ident-ex-%@-%@", clsName, e.name]];
            }
            if (identity) break;
        }
        if (identity) {
            @try {
                SEL setSel = NSSelectorFromString(@"setIdentity:");
                if ([def respondsToSelector:setSel]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(def, setSel, identity);
                    [self reportToEngine:@"fb-ident-set-ok"];
                } else {
                    [def setValue:identity forKey:@"identity"];
                    [self reportToEngine:@"fb-ident-set-kvc"];
                }
            } @catch (NSException *e) {
                [self reportToEngine:[NSString stringWithFormat:@"fb-ident-set-ex-%@", e.name]];
            }
        } else {
            [self reportToEngine:@"fb-ident-all-fail"];
        }

        /* 3. clientIdentity：+localIdentity（懒人 0x100080b84 铁证） */
        @try {
            for (NSString *clsName in @[@"FBSSceneIdentity", @"FBSMutableSceneIdentity", @"FBSProcessIdentity"]) {
                Class c = NSClassFromString(clsName);
                if (!c) continue;
                SEL sel = NSSelectorFromString(@"localIdentity");
                if ([c respondsToSelector:sel]) {
                    id li = ((id(*)(id, SEL))objc_msgSend)(c, sel);
                    if (li && [def respondsToSelector:NSSelectorFromString(@"setClientIdentity:")]) {
                        ((void(*)(id, SEL, id))objc_msgSend)(def, NSSelectorFromString(@"setClientIdentity:"), li);
                        [self reportToEngine:[NSString stringWithFormat:@"fb-clientid-ok-%@", clsName]];
                    } else {
                        [self reportToEngine:[NSString stringWithFormat:@"fb-clientid-nil-%@", clsName]];
                    }
                    break;
                } else {
                    [self reportToEngine:[NSString stringWithFormat:@"fb-clientid-nosel-%@", clsName]];
                }
            }
        } @catch (NSException *e) {
            [self reportToEngine:[NSString stringWithFormat:@"fb-clientid-ex-%@", e.name]];
        }

        /* 4. specification：懒人 0x100080bac ~ 0x100080bc8（类方法 +specification 或 new） */
        id spec = nil;
        @try {
            for (NSString *clsName in @[@"FBSMutableSceneSpecification", @"FBSMutableSceneDefinition", @"FBSSceneSpecification"]) {
                Class c = NSClassFromString(clsName);
                if (!c) continue;
                SEL sel = NSSelectorFromString(@"specification");
                if ([c respondsToSelector:sel]) {
                    spec = ((id(*)(id, SEL))objc_msgSend)(c, sel);
                    [self reportToEngine:spec ? [NSString stringWithFormat:@"fb-spec-ok-%@", clsName]
                                              : [NSString stringWithFormat:@"fb-spec-nil-%@", clsName]];
                    break;
                } else {
                    [self reportToEngine:[NSString stringWithFormat:@"fb-spec-nosel-%@", clsName]];
                }
            }
        } @catch (NSException *e) {
            [self reportToEngine:[NSString stringWithFormat:@"fb-spec-ex-%@", e.name]];
        }
        if (!spec) {
            Class sc = NSClassFromString(@"FBSMutableSceneSpecification");
            if (sc) { spec = ((id(*)(id, SEL))objc_msgSend)(sc, NSSelectorFromString(@"new")); [self reportToEngine:@"fb-spec-new"]; }
        }
        if (spec) {
            @try {
                SEL setSel = NSSelectorFromString(@"setSpecification:");
                if ([def respondsToSelector:setSel]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(def, setSel, spec);
                    [self reportToEngine:@"fb-spec-set-ok"];
                } else {
                    [def setValue:spec forKey:@"specification"];
                    [self reportToEngine:@"fb-spec-set-kvc"];
                }
            } @catch (NSException *e) {
                [self reportToEngine:[NSString stringWithFormat:@"fb-spec-set-ex-%@", e.name]];
            }
        }

        /* 5. parameters：+parametersForSpecification:spec（懒人 0x100080bf8 铁证，
           不是 new！参数类型由 specification 决定） */
        Class paramsCls = NSClassFromString(@"FBSMutableSceneParameters");
        id params = nil;
        if (paramsCls) {
            @try {
                SEL sel = NSSelectorFromString(@"parametersForSpecification:");
                if ([paramsCls respondsToSelector:sel]) {
                    params = ((id(*)(id, SEL, id))objc_msgSend)(paramsCls, sel, spec);
                    [self reportToEngine:params ? @"fb-params-from-spec" : @"fb-params-from-spec-nil"];
                } else {
                    [self reportToEngine:@"fb-params-nosel-fromspec"];
                }
            } @catch (NSException *e) {
                [self reportToEngine:[NSString stringWithFormat:@"fb-params-ex-%@", e.name]];
            }
        }
        if (!params && paramsCls) {
            params = ((id(*)(id, SEL))objc_msgSend)(paramsCls, NSSelectorFromString(@"new"));
            [self reportToEngine:@"fb-params-new-fallback"];
        }
        if (!params) { [self reportToEngine:@"fb-params-fail"]; return; }

        /* 6. params 配置（懒人 0x100080c18~0x100080d1c：setForeground:1、
           setInterfaceOrientation:1、setLevel:1、setSettings:、setClientSettings:） */
        @try {
            for (NSString *s in @[@"setForeground:", @"setInterfaceOrientation:"]) {
                SEL sel = NSSelectorFromString(s);
                if ([params respondsToSelector:sel]) {
                    ((void(*)(id, SEL, int))objc_msgSend)(params, sel, 1);
                }
            }
        } @catch (NSException *e) { }

        SEL createSel = NSSelectorFromString(@"createSceneWithDefinition:initialParameters:");
        if (![manager respondsToSelector:createSel]) { [self reportToEngine:@"fb-create-no-sel"]; return; }
        [self reportToEngine:@"fb-create-start"];

        /* 后台线程 + 3s 超时（v1.8.42 修复版，不阻塞主线程） */
        __block id fbSceneBlock = nil;
        __block BOOL createDone = NO;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @try {
                fbSceneBlock = ((id(*)(id, SEL, id, id))objc_msgSend)(manager, createSel, def, params);
            } @catch (NSException *e) {
                /* ★ v1.8.48 打 reason：拿 FBSceneManager.m:462 断言的完整消息 */
                NSString *reason = [e.reason substringToIndex:MIN((NSUInteger)200, e.reason.length)];
                [self reportToEngine:[NSString stringWithFormat:@"fb-create-ex-%@-%@", e.name, reason]];
            }
            createDone = YES;
        });
        for (int i = 0; i < 30 && !createDone; i++) usleep(100 * 1000);
        id fbScene = fbSceneBlock;
        [self reportToEngine:createDone ? (fbScene ? @"fb-scene-created" : @"fb-create-nil")
                                       : @"fb-create-timeout-3s"];
        if (!fbScene) return;
        self.independentScene = fbScene;

        /* binder 绑系统 root window 层（懒人 UIRootWindowScenePresentationBinder） */
        @try {
            Class binderCls = NSClassFromString(@"UIRootWindowScenePresentationBinder");
            if (!binderCls) { [self reportToEngine:@"binder-missing"]; return; }
            if (!self.rootBinder) {
                self.rootBinder = ((id(*)(id, SEL))objc_msgSend)(binderCls, NSSelectorFromString(@"new"));
                [self reportToEngine:@"binder-created"];
            }
            SEL addSel = NSSelectorFromString(@"addScene:");
            if ([self.rootBinder respondsToSelector:addSel]) {
                ((void(*)(id, SEL, id))objc_msgSend)(self.rootBinder, addSel, fbScene);
                [self reportToEngine:@"binder-addscene-ok"];
            } else {
                [self reportToEngine:@"binder-no-addscene"];
            }
        } @catch (NSException *e) {
            [self reportToEngine:@"binder-ex"];
        }

        /* 1s 后看 UIKit 是否为新 FBScene 建立了 UIWindowScene → 球窗口改绑它 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self tryBindWindowToNewScene];
        });
    } @catch (NSException *e) {
        [self reportToEngine:@"fb-outer-ex"];
    }
}

/* 遍历 connectedScenes 找新出现的 UIWindowScene（非当前 main scene）→ 球窗口改绑它。
   若 UIKit 为独立 FBScene 建立了 UIWindowScene，绑上后窗口脱离 app main scene
   生命周期 → SBS 托管持续 → 切后台球全局。 */
- (void)tryBindWindowToNewScene {
    if (!self.floatingWindow) return;
    UIWindowScene *current = self.floatingWindow.windowScene;
    NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
    for (UIScene *s in scenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s == (id)current) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        self.floatingWindow.windowScene = ws;
        [self reportToEngine:@"ball-rebound-newscene"];
        [self registerToSpringBoardWithRetry];
        return;
    }
    [self reportToEngine:@"no-new-scene"];
}

/* App 回前台/活跃时调用：确保悬浮球仍注册在 SpringBoard。
   ⚠️ 只 register，不 unregister —— SBS register 是幂等的（重复注册同一
   contextID 无副作用）；先 unregister 再 register 有竞态：unregister 后窗口
   已从 SpringBoard 移除，若 register 因 cid 暂为 0 失败，球就永久消失。 */
- (void)reRegisterIfNeeded {
    if (!self.floatingWindow) return;
    [self registerToSpringBoardWithRetry];
    [self reportToEngine:@"re-register"];
}

/* ★ v1.5.7 照懒人反编译（RootService 0x10004dc5c）方案：回前台/切后台只切
   setHidden:BOOL，不重建窗口、不重新注册。懒人 BSServiceDomains + daemon 化
   让 SBS context 永活，setHidden:NO 就能恢复显示。v1.5.5/v1.5.6 重建窗口
   反而把稳定的 context 搞丢了。 */
- (void)setWindowVisible:(BOOL)visible {
    if (!self.floatingWindow) return;
    if (self.floatingWindow.hidden == !visible) {
        /* 状态没变，不动（避免无谓的刷新） */
        [self reportToEngine:visible ? @"vis-already-yes" : @"vis-already-no"];
        return;
    }
    self.floatingWindow.hidden = !visible;
    [self reportToEngine:visible ? @"vis-on" : @"vis-off"];
    /* ⚠️ 关键：不重建、不 unregister、不 reRegister。SBS context 留着，
       跟懒人完全一致。 */
}

/* 取 UIWindow 的 contextID。
   ★ v1.6.0 照懒人反汇编 safeGetWindowContextID (0x10004d330) 铁证重写：
   懒人用 NSInvocation 动态调用窗口的 _contextId / contextId 方法（不是简单
   KVC！），拿到后做 isKindOfClass:NSNumber 类型校验，再 unsignedIntValue。
   v1.5.9 用 valueForKey 拿到的值每次不同（设备日志 reg-ok-3837087202 → ...）
   = KVC 在这个 iOS 版本上拿不到有效 contextID。
   正确姿势：respondsToSelector + NSMethodSignature + NSInvocation 直接调方法。
   注意：WindowServer contextID 可能是大数（iOS15+），不做"小数字"上限过滤，
   只要求类型是 NSNumber 且非 0。 */
- (unsigned int)windowContextID {
    if (!self.floatingWindow) return 0;
    /* ★ v1.8.20 缓存优先：同一窗口 contextID 不变（v1.7.0 已加 cachedCid），
       拿到一次就复用，不再每次 NSInvocation 动态调用（高频取 cid 也是
       卡顿源之一）。窗口重建时 cachedCid 已清 0。 */
    if (self.cachedCid != 0) return self.cachedCid;
    /* 依次尝试多个方法名（懒人同款）：_contextId → contextId */
    NSArray *sels = @[@"_contextId", @"contextId"];
    for (NSString *selName in sels) {
        SEL sel = NSSelectorFromString(selName);
        if (![self.floatingWindow respondsToSelector:sel]) {
            [self reportToEngine:[NSString stringWithFormat:@"cid-no-sel-%@", selName]];
            continue;
        }
        /* NSInvocation 动态调用（懒人 safeGetWindowContextID 同款：
           methodSignatureForSelector + setTarget + setSelector + invoke + getReturnValue） */
        NSMethodSignature *sig = [self.floatingWindow methodSignatureForSelector:sel];
        if (!sig) continue;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:self.floatingWindow];
        [inv setSelector:sel];
        [inv invoke];
        if (sig.methodReturnLength == 0) continue;
        /* 返回值可能是 NSNumber 对象（对象类型）或直接 unsigned int（标量） */
        if (sig.methodReturnType[0] == '@') {
            /* 对象返回：isKindOfClass:NSNumber 校验（懒人 0x10006c38c 同款） */
            __unsafe_unretained id ret = nil;
            [inv getReturnValue:&ret];
            if (ret && [ret isKindOfClass:[NSNumber class]]) {
                unsigned int v = [ret unsignedIntValue];
                if (v != 0) { self.cachedCid = v; return v; }
            }
            [self reportToEngine:[NSString stringWithFormat:@"cid-not-number-%@", selName]];
        } else if (sig.methodReturnLength == 4) {
            /* 标量 unsigned int 返回 */
            unsigned int v = 0;
            [inv getReturnValue:&v];
            if (v != 0) { self.cachedCid = v; return v; }
            [self reportToEngine:[NSString stringWithFormat:@"cid-zero-%@", selName]];
        } else {
            [self reportToEngine:[NSString stringWithFormat:@"cid-badtype-%@-%s", selName, sig.methodReturnType]];
        }
    }
    return 0;
}

/* 带次数上限的重试：contextID 需要等 WindowServer 分配，首帧可能为 0。
   ⚠️ 后台窗口永远拿不到 contextID（iOS 不给后台 App 窗口分配），
   所以超限后【不 rebuild】（rebuild 在后台会无限循环，v1.1.9 实测），
   只静默放弃，等 App 回前台时 applicationDidBecomeActive 再触发注册。 */
- (void)registerToSpringBoardWithRetry {
    [self registerToSpringBoardAttempt:0];
}

- (void)registerToSpringBoardAttempt:(int)attempt {
    if (!self.floatingWindow) return;
    unsigned int cid = [self windowContextID];
    if (cid == 0) {
        if (attempt >= 10) {
            /* 前台窗口 3 秒都拿不到 contextID（正常不会发生）；
               放弃本轮，回前台时重新触发。不 rebuild —— 那是死循环根源 */
            [self reportToEngine:@"cid-giveup-wait-foreground"];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!self.floatingWindow) return;
            [self registerToSpringBoardAttempt:attempt + 1];
        });
        return;
    }
    [self registerToSpringBoard];
}

- (void)registerToSpringBoard {
    unsigned int cid = [self windowContextID];
    if (cid == 0) {
        /* 静默返回：不递归（避免无限循环），由 retry 路径处理 */
        [self reportToEngine:@"cid-zero"];
        return;
    }

    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!cls) {
        NSLog(@"[Floating] SBSAccessibilityWindowHostingController not found");
        [self reportToEngine:@"sbs-class-missing"];
        return;
    }

    /* ★ v1.6.8 照懒人 tryRegisterWithAccessibilityController (0x10004d978) 完整反汇编：
       懒人【每次 alloc 新 controller】+ 【NSInvocation 动态调用】！
       关键：懒人用 methodSignatureForSelector: 取【运行时真实签名】再
       setArgument:atIndex: 传参 —— 参数类型完全按真实签名（cid 可能 4 字节、
       atLevel 可能是 double/float），不会像直接调用那样编译期签名猜错错位。
       v1.6.2-1.6.7 直接 [controller registerWindowWithContextID:atLevel:] 用的
       是 @interface 里猜的 (double) 签名 —— 若真实是 float 就参数错位注册无效！
       照懒人改 NSInvocation 动态调用。 */
    self.hostingController = [[cls alloc] init];
    @try {
        SEL sel = @selector(registerWindowWithContextID:atLevel:);
        if ([self.hostingController respondsToSelector:sel]) {
            NSMethodSignature *sig = [self.hostingController methodSignatureForSelector:sel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:self.hostingController];
                [inv setSelector:sel];
                [inv setArgument:&cid atIndex:2];
                double level = (double)self.floatingWindow.windowLevel;
                [inv setArgument:&level atIndex:3];
                [inv invoke];
                self.registered = YES;
                NSLog(@"[Floating] registered contextID=%u level=%.0f", cid, self.floatingWindow.windowLevel);
                [self reportToEngine:[NSString stringWithFormat:@"reg-ok-%u", cid]];
            } else {
                [self reportToEngine:@"sbs-no-signature"];
            }
        } else {
            [self reportToEngine:@"sbs-no-selector"];
        }

        /* ★ v1.6.2 照懒人 registerWindowWithFallback (0x10004db20) 反汇编：
           懒人注册后发【两个】Darwin 通知：hudservices.windowRegistered +
           springboard.hudwindow.registered（之前只发了第一个！）
           SpringBoard 监听这些通知确认悬浮窗注册。 */
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.apple.hudservices.windowRegistered"), NULL, NULL, true);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.apple.springboard.hudwindow.registered"), NULL, NULL, true);
        [self reportToEngine:@"hud-notify-sent"];
    } @catch (NSException *e) {
        NSLog(@"[Floating] SBS register exception: %@", e);
        [self reportToEngine:@"sbs-reg-exception"];
    }
}

- (void)unregisterFromSpringBoard {
    if (!self.hostingController) return;
    unsigned int cid = [self windowContextID];
    if ([self.hostingController respondsToSelector:@selector(unregisterWindowWithContextID:)]) {
        [self.hostingController unregisterWindowWithContextID:cid];
    }
    self.hostingController = nil;
    self.registered = NO;
}

/* 重建悬浮窗口（仅前台）：resume 后窗口对象还在但 CA context 已被系统回收，
   前台重建拿全新 contextID 即可恢复。⚠️ 只在 App Active 状态调用（不后台循环）。 */
- (void)rebuildFloatingWindow {
    /* v1.5.5: floatingWindow 可能被系统释放为 nil（后台回收），也要重建 */
    if (!self.floatingWindow) {
        [self showFloatingBallInScene:[[[UIApplication sharedApplication] connectedScenes] anyObject]];
        return;
    }
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        [self reportToEngine:@"rebuild-skipped-not-active"];
        return;
    }
    [self reportToEngine:@"rebuild"];
    UIWindowScene *scene = (UIWindowScene *)[[[UIApplication sharedApplication] connectedScenes] anyObject];
    self.cachedCid = 0;   /* 新窗口新 contextID，清缓存 */
    [self.hbTimer invalidate]; self.hbTimer = nil;
    [self unregisterFromSpringBoard];
    self.floatingWindow.hidden = YES;
    self.floatingWindow = nil;
    self.ball = nil;
    self.registered = NO;
    [self showFloatingBallInScene:scene];
}

@end