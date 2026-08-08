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

/* 穿透窗口：SBS 托管需要全屏窗口（context 稳定不消失），但全屏窗口默认会把
   整个屏幕的触摸都拦下来（hitTest 无子视图命中时返回 self，不是 nil！）。
   重写 hitTest：只有命中悬浮球才响应，命中窗口自身/透明背景 → 返回 nil → 穿透
   给下层主窗口（TabBar 等照常可点）。 */
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
@end

@interface FloatingWindowManager ()
@property (nonatomic, strong) id hostingController;
@property (nonatomic, assign) BOOL registered;
@property (nonatomic, strong) FloatingBall *ball;
@property (nonatomic, strong) NSTimer *touchTimer;
@property (nonatomic, strong) NSTimer *hbTimer;      /* 心跳：定期重注册 + 上报 App 存活（诊断） */
@property (nonatomic, assign) unsigned int cachedCid;  /* 同一窗口 contextID 不变，拿到一次缓存复用 */
@end

@implementation FloatingWindowManager

+ (instancetype)shared {
    static FloatingWindowManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [FloatingWindowManager new]; });
    return inst;
}

/* App 状态上报到引擎日志（远程 curl /log 可查 App 生命周期/存活） */
- (void)reportToEngine:(NSString *)msg {
    NSString *enc = [msg stringByAddingPercentEncodingWithAllowedCharacters:
                        [NSCharacterSet alphanumericCharacterSet]];
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:8080/applog?msg=%@", enc];
    NSURLSessionDataTask *t = [[NSURLSession sharedSession]
        dataTaskWithURL:[NSURL URLWithString:url] completionHandler:nil];
    [t resume];
}

- (void)showFloatingBall {
    if (self.floatingWindow) return;

    /* 回退 v1.2.7：56×56 小窗口 + hidden=NO。
       v1.2.8 的 makeKeyAndVisible 抢走 key window 造成回归（点击了球也没了），
       回退到"至少点击能活"的形态。 */
    UIWindow *keyWindow = [UIApplication sharedApplication].windows.firstObject;
    if (!keyWindow) return;

    CGFloat size = 56;                          /* 球尺寸 */
    CGFloat x = 20;                             /* 初始靠左 */
    CGFloat y = keyWindow.bounds.size.height / 2 - size;
    CGRect ballFrame = CGRectMake(x, y, size, size);

    self.floatingWindow = [[FloatingBallWindow alloc] initWithFrame:ballFrame];
    self.floatingWindow.windowLevel = UIWindowLevelStatusBar + 100;
    self.floatingWindow.backgroundColor = [UIColor clearColor];
    self.floatingWindow.hidden = NO;

    /* 轻量 root VC 承载悬浮球（view 跟随窗口 56×56，球填满） */
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    self.floatingWindow.rootViewController = vc;

    FloatingBall *ball = [[FloatingBall alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    ball.onTap = self.onTap;
    [vc.view addSubview:ball];
    self.ball = ball;

    /* 立即注册（若 contextID 尚未分配会失败，走 retry 补齐） */
    [self registerToSpringBoardWithRetry];

    /* 触摸轮询：引擎(root)全局监听 HID 触摸，把坐标写 /tmp/ailintouch.touch，
       App 每 50ms 读一次，命中球区域触发 onTap（懒人同款机制，后台也能点） */
    self.touchTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        [self pollTouchFile];
    }];

    /* 心跳：每 5 秒只上报 App 存活（远程诊断）。
       ⚠️ 后台绝不注册/重建窗口！后台 App 的窗口拿不到 contextID，
       注册失败 → rebuild → 新窗口后台又拿不到 → 死循环（v1.1.9 实测）。
       已注册的托管窗口由 SpringBoard 自己管，回前台时再重注册。 */
    self.hbTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {
        [self reportToEngine:@"hb-alive"];
        /* 后台不碰窗口，保持现有托管状态 */
    }];
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
    [self unregisterFromSpringBoard];
    self.floatingWindow.hidden = YES;
    self.floatingWindow = nil;
    self.ball = nil;
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

/* 取 UIWindow 的 contextID（懒人 safeGetWindowContextID 同思路） */
- (unsigned int)windowContextID {
    if (!self.floatingWindow) return 0;
    /* iOS 13+ UIWindow 有 _contextId 私有 ivar */
    if (self.cachedCid != 0) return self.cachedCid;   /* 缓存复用：窗口没重建 contextID 不变 */
    id cid = [self.floatingWindow valueForKey:@"_contextId"];
    if (cid && [cid respondsToSelector:@selector(unsignedIntValue)]) {
        unsigned int v = [cid unsignedIntValue];
        if (v != 0) {
            self.cachedCid = v;
            return v;
        }
    }
    /* ⚠️ 不要 fallback 到 layer.contextId！那是 CA layer 的内部 ID（大数/内存地址），
       SBSAccessibilityWindowHostingController 需要的是 WindowServer 给 UIWindow 分配的
       contextID（_contextId，小数字）。用 layer 值注册"成功"但 SpringBoard 不认 →
       球不显示（v1.2.5 日志铁证：reg-ok 的 cid 一会 779798 一会 3 亿大数）。 */
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

    /* 复用同一个 controller 实例（懒人持有一个 controller 反复 register；
       每次 alloc 新实例注册同一 cid 的行为不可预期） */
    if (!self.hostingController) {
        self.hostingController = [[cls alloc] init];
    }
    if ([self.hostingController respondsToSelector:@selector(registerWindowWithContextID:atLevel:)]) {
        [self.hostingController registerWindowWithContextID:cid
                                                   atLevel:self.floatingWindow.windowLevel];
        self.registered = YES;
        NSLog(@"[Floating] registered contextID=%u level=%.0f", cid, self.floatingWindow.windowLevel);
        [self reportToEngine:[NSString stringWithFormat:@"reg-ok-%u", cid]];
    } else {
        [self reportToEngine:@"sbs-no-selector"];
    }

    /* HUD 注册通知（懒人同款） */
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.apple.hudservices.windowRegistered"), NULL, NULL, true);
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
    if (!self.floatingWindow) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        [self reportToEngine:@"rebuild-skipped-not-active"];
        return;
    }
    [self reportToEngine:@"rebuild"];
    self.cachedCid = 0;   /* 新窗口新 contextID，清缓存 */
    [self.touchTimer invalidate]; self.touchTimer = nil;
    [self.hbTimer invalidate]; self.hbTimer = nil;
    [self unregisterFromSpringBoard];
    self.floatingWindow.hidden = YES;
    self.floatingWindow = nil;
    self.ball = nil;
    self.registered = NO;
    [self showFloatingBall];
}

@end