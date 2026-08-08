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

@interface FloatingWindowManager ()
@property (nonatomic, strong) id hostingController;
@property (nonatomic, assign) BOOL registered;
@property (nonatomic, strong) FloatingBall *ball;
@property (nonatomic, strong) NSTimer *touchTimer;
@property (nonatomic, strong) NSTimer *hbTimer;      /* 心跳：定期重注册 + 上报 App 存活（诊断） */
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

    UIWindow *keyWindow = [UIApplication sharedApplication].windows.firstObject;
    if (!keyWindow) return;

    /* ⚠️ 窗口必须全屏：SBSAccessibilityWindowHostingController 托管的是窗口的
       CA context，SpringBoard 对非全屏窗口 context 托管不稳定（显示一帧即被移除）。
       悬浮球只是全屏透明窗口里的子视图，懒人 overlay window 也是全屏的。 */
    CGFloat size = 56;                          /* 球尺寸 */
    CGFloat x = 20;                             /* 初始靠左 */
    CGFloat y = keyWindow.bounds.size.height / 2 - size;
    CGRect screen = keyWindow.bounds;

    self.floatingWindow = [[UIWindow alloc] initWithFrame:screen];
    self.floatingWindow.windowLevel = UIWindowLevelStatusBar + 100;   /* 高过普通 App 窗口 */
    self.floatingWindow.backgroundColor = [UIColor clearColor];
    /* 注意：不能设 userInteractionEnabled=NO（会连子视图 ball 一起禁掉）。
       透明区域没有子视图 → hitTest 返回 nil → 触摸天然穿透到下层窗口，
       只有命中 ball 的区域才被球拦截。 */
    self.floatingWindow.hidden = NO;

    /* 轻量 root VC 承载悬浮球（view 全屏透明，球是子视图） */
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    self.floatingWindow.rootViewController = vc;

    FloatingBall *ball = [[FloatingBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
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

    /* 心跳：每 3 秒上报 App 存活到引擎日志（远程诊断）；
       后台时强制重注册（SpringBoard 可能移除托管窗口，registered 标志不可靠） */
    self.hbTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t) {
        [self reportToEngine:@"hb-alive"];
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            [self reRegisterForce];
        }
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

    /* 球的屏幕坐标：窗口全屏，ball.frame 相对 vc.view（= 屏幕坐标） */
    CGRect ballFrame = self.ball.frame;
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

/* App 回前台/活跃时调用：确保悬浮球仍注册在 SpringBoard（防止被移除） */
- (void)reRegisterIfNeeded {
    if (!self.floatingWindow) return;
    [self reRegisterForce];
}

/* 强制重注册：先 unregister 再 register（SpringBoard 可能静默移除托管窗口，
   registered 标志此时仍是 YES，必须无条件重注册） */
- (void)reRegisterForce {
    if (!self.floatingWindow) return;
    [self unregisterFromSpringBoard];
    [self registerToSpringBoard];
    [self reportToEngine:@"re-register"];
}

/* 取 UIWindow 的 contextID（懒人 safeGetWindowContextID 同思路） */
- (unsigned int)windowContextID {
    if (!self.floatingWindow) return 0;
    /* iOS 13+ UIWindow 有 _contextId 私有 ivar */
    id cid = [self.floatingWindow valueForKey:@"_contextId"];
    if (cid && [cid respondsToSelector:@selector(unsignedIntValue)]) {
        unsigned int v = [cid unsignedIntValue];
        if (v != 0) return v;
    }
    /* fallback：通过 layer 拿 context id */
    id layerCid = [self.floatingWindow.layer valueForKey:@"contextId"];
    if (layerCid && [layerCid respondsToSelector:@selector(unsignedIntValue)]) {
        unsigned int v = [layerCid unsignedIntValue];
        if (v != 0) return v;
    }
    return 0;
}

/* 带重试的注册：contextID 需要等 WindowServer 分配，首帧可能为 0，
   每 0.3s 重试一次，最多 10 次（3 秒内一定能拿到） */
- (void)registerToSpringBoardWithRetry {
    unsigned int cid = [self windowContextID];
    if (cid == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!self.floatingWindow) return;
            [self registerToSpringBoardWithRetry];
        });
        return;
    }
    [self registerToSpringBoard];
}

- (void)registerToSpringBoard {
    /* 去掉 if (self.registered) return —— SpringBoard 可能已移除托管但标志没重置，
       心跳/回前台必须能无条件重注册 */
    unsigned int cid = [self windowContextID];
    if (cid == 0) {
        [self reportToEngine:@"cid-zero"];
        return;
    }

    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!cls) {
        NSLog(@"[Floating] SBSAccessibilityWindowHostingController not found");
        [self reportToEngine:@"sbs-class-missing"];
        return;
    }

    self.hostingController = [[cls alloc] init];
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

@end