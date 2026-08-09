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
@property (nonatomic, strong) NSTimer *touchTimer;
@property (nonatomic, strong) NSTimer *hbTimer;      /* 心跳：定期重注册 + 上报 App 存活（诊断） */
@property (nonatomic, strong) NSTimer *hiddenKeepTimer; /* v1.8.4 0.5s 强制窗口可见 */
@property (nonatomic, strong) NSTimer *sceneFollowTimer; /* v1.8.4 1s 跟随前台 scene */
@property (nonatomic, assign) unsigned int cachedCid;  /* 同一窗口 contextID 不变，拿到一次缓存复用 */
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
   +2 次 HTTP，直接发烫！节流后最多 15s 一次）。 */
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
            NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                              [df stringFromDate:[NSDate date]], msg];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) { }

    NSString *enc = [msg stringByAddingPercentEncodingWithAllowedCharacters:
                        [NSCharacterSet alphanumericCharacterSet]];
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:8080/applog?msg=%@", enc];
    NSURLSessionDataTask *t = [[NSURLSession sharedSession]
        dataTaskWithURL:[NSURL URLWithString:url] completionHandler:nil];
    [t resume];
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

    /* ★ v1.8.12 核心改动：先试【不绑 scene】窗口（懒人 setupHUDWindow 姿势：
       initWithFrame + level 20000002 + makeKeyAndVisible + SBS 注册）。
       懒人是 daemon（SBAppIsDaemon），WindowServer 给 daemon 的不绑 scene
       窗口也分配 contextID，且【不受 scene 生命周期控制】→ 切后台不隐藏！
       这就是懒人"切后台球还在"的机制。
       v1.6.6/v1.7.2 不绑 scene 失败（cid=0）= 当时 daemon 化未生效
       （SpringBoard 未重读 SBAppIsDaemon，必须重启手机——用户铁证"每次
       重启手机他才真的重启"）。现在 daemon 化已生效，重试不绑 scene。
       若仍拿不到 cid（daemon 化无效），自动 fallback 绑 scene（v1.8.3-11
       已验证的可靠路径，球能显示只是切后台消失）。 */
    BOOL noSceneMode = YES;
    self.floatingWindow = [[FloatingBallWindow alloc] initWithFrame:full];
    self.floatingWindow.windowLevel = 20000002;
    self.floatingWindow.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    self.floatingWindow.rootViewController = vc;
    FloatingBall *ball = [[FloatingBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
    ball.onTap = self.onTap;
    [vc.view addSubview:ball];
    self.ball = ball;
    [self.floatingWindow makeKeyAndVisible];
    if ([self windowContextID] == 0) {
        /* daemon 化未生效 / 不绑 scene 拿不到 cid → fallback 绑 scene */
        [self reportToEngine:@"nosccene-cid-zero-fallback-scene"];
        self.floatingWindow = nil;
        self.floatingWindow = [[FloatingBallWindow alloc] initWithWindowScene:bindScene];
        self.floatingWindow.windowLevel = 20000002;
        self.floatingWindow.backgroundColor = [UIColor clearColor];
        UIViewController *vc2 = [UIViewController new];
        vc2.view.backgroundColor = [UIColor clearColor];
        self.floatingWindow.rootViewController = vc2;
        FloatingBall *ball2 = [[FloatingBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
        ball2.onTap = self.onTap;
        [vc2.view addSubview:ball2];
        self.ball = ball2;
        [self.floatingWindow makeKeyAndVisible];
        noSceneMode = NO;
    } else {
        [self reportToEngine:@"nosccene-cid-ok-daemon-mode"];
    }

    /* ★ v1.7.3 恢复 binder 绑定（用户"二进制 scene"铁证）：
       懒人 RootService 含 UIRootWindowScenePresentationBinder +
       FBSceneManager + createSceneWithDefinition 符号 —— 窗口的二进制
       FBScene（windowScene._fbScene）addScene 到 binder → 窗口绑定到
       系统 root window scene → 全局显示且不随 App scene 挂起。
       ★ v1.8.12 只在绑 scene 路径用 binder（不绑 scene 的窗口无 scene 可绑） */
    if (!noSceneMode && bindScene) {
        [self bindToRootWindowScene:bindScene];
    }

    /* 立即注册（若 contextID 尚未分配会失败，走 retry 补齐） */
    [self registerToSpringBoardWithRetry];

    /* 触摸轮询：引擎(root)全局监听 HID 触摸，把坐标写 /tmp/ailintouch.touch，
       App 每 50ms 读一次，命中球区域触发 onTap（懒人同款机制，后台也能点） */
    self.touchTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) {
        [self pollTouchFile];
    }];

    /* ★ v1.5.6: 心跳每 5 秒【幂等重注册】，绝不 rebuild！
       v1.5.5 心跳每 5 秒 rebuild → 窗口每 5 秒销毁重建 → 球闪烁 + 刚注册成功
       就被打断（用户实测"几秒闪一下"）。
       SBS register 是幂等的（重复注册同一 contextID 无副作用），心跳持续
       register 保持托管即可；rebuild 只在 applicationDidBecomeActive 回前台时
       做一次（拿全新 contextID，v1.5.5 保留）。 */
    /* ★ v1.7.0 心跳恢复注册：每 5 秒幂等 re-register。
       v1.6.7 学懒人"只注册一次"去掉了注册 —— 但懒人 daemon 的 cid 永不变，
       我们前台 App 进后台 WindowServer 会回收/更换 contextID（用户铁证：
       第一次装球全局 → App 进后台 → 永远内部）。windowContextID 每次重新取
       新值，心跳注册会自动用新 cid（cid 没变则重复注册同一 cid 幂等无害）。 */
    self.hbTimer = [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *t) {
        [self reportToEngine:@"hb-alive"];
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
        [self registerToSpringBoardWithRetry];
    }];

    /* ★ v1.8.4 双保险（用户铁证：切后台球立即消失 = v1.8.3 绑 main scene
       被系统强制 hidden）：
       ① hiddenKeepTimer(0.5s)：窗口被系统改 hidden=YES 立即 setHidden:NO 复活。
          NSRunLoopCommonModes 保证后台模式也触发（NSTimer 默认 default mode
          在后台 runloop 可能不回调）。懒人 daemon 窗口永活，我们前台 App
          必须主动维持。 */
    self.hiddenKeepTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        if (self.floatingWindow && self.floatingWindow.hidden) {
            self.floatingWindow.hidden = NO;
            [self reportToEngine:@"hidden-revive"];
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.hiddenKeepTimer forMode:NSRunLoopCommonModes];

    /* ② sceneFollowTimer(1s)：跟随当前前台 scene（用户直觉"懒人一直在获取
       前台的scene"）。若 root scene 绑定失败（bindScene=main scene），
       动态把球窗口切到前台激活的 scene；切后台后自己进程无 active scene
       则不动作（保留 root scene 方案为主，此为兜底）。 */
    self.sceneFollowTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t) {
        if (!self.floatingWindow) return;
        UIWindowScene *active = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                active = (UIWindowScene *)s;
                break;
            }
        }
        if (active && self.floatingWindow.windowScene != active) {
            self.floatingWindow.windowScene = active;
            [self reportToEngine:@"scene-follow"];
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.sceneFollowTimer forMode:NSRunLoopCommonModes];

    [self reportToEngine:@"ball-shown"];
}

- (void)pollTouchFile {
    if (!self.floatingWindow || !self.ball) return;
    NSString *path = @"/tmp/ailintouch.touch";
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!content || content.length == 0) return;
    /* 读完即删，防止重复触发 */
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    float x = 0, y = 0;
    if (sscanf(content.UTF8String, "%f %f", &x, &y) != 2) return;

    /* 球的屏幕坐标 = 窗口 origin + ball.origin（窗口 56×56 = 球的位置） */
    CGPoint ballOrigin = CGPointMake(self.floatingWindow.frame.origin.x + self.ball.frame.origin.x,
                                     self.floatingWindow.frame.origin.y + self.ball.frame.origin.y);
    CGRect ballFrame = CGRectMake(ballOrigin.x, ballOrigin.y,
                                  self.ball.bounds.size.width, self.ball.bounds.size.height);
    if (CGRectContainsPoint(ballFrame, CGPointMake(x, y))) {
        if (self.onTap) self.onTap();
    }
}

- (void)hideFloatingBall {
    if (!self.floatingWindow) return;
    [self.touchTimer invalidate];
    self.touchTimer = nil;
    [self.hbTimer invalidate];
    self.hbTimer = nil;
    [self.hiddenKeepTimer invalidate];
    self.hiddenKeepTimer = nil;
    [self.sceneFollowTimer invalidate];
    self.sceneFollowTimer = nil;
    [self unregisterFromSpringBoard];
    self.floatingWindow.hidden = YES;
    self.floatingWindow = nil;
    self.ball = nil;
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
    [self.touchTimer invalidate]; self.touchTimer = nil;
    [self.hbTimer invalidate]; self.hbTimer = nil;
    [self unregisterFromSpringBoard];
    self.floatingWindow.hidden = YES;
    self.floatingWindow = nil;
    self.ball = nil;
    self.registered = NO;
    [self showFloatingBallInScene:scene];
}

@end