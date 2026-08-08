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
@end

@implementation FloatingWindowManager

+ (instancetype)shared {
    static FloatingWindowManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [FloatingWindowManager new]; });
    return inst;
}

- (void)showFloatingBall {
    if (self.floatingWindow) return;

    UIWindow *keyWindow = [UIApplication sharedApplication].windows.firstObject;
    if (!keyWindow) return;

    /* 悬浮球尺寸 */
    CGFloat size = 56;
    CGFloat x = 20;                          /* 初始靠左 */
    CGFloat y = keyWindow.bounds.size.height / 2 - size;

    self.floatingWindow = [[UIWindow alloc] initWithFrame:CGRectMake(x, y, size, size)];
    self.floatingWindow.windowLevel = UIWindowLevelStatusBar + 100;   /* 高过普通 App 窗口 */
    self.floatingWindow.backgroundColor = [UIColor clearColor];
    self.floatingWindow.hidden = NO;

    /* 轻量 root VC 只承载悬浮球 */
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

    /* 球的屏幕坐标 = floatingWindow.origin + ball.origin（window 非全屏，就是球的位置） */
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
    [self unregisterFromSpringBoard];
    self.floatingWindow.hidden = YES;
    self.floatingWindow = nil;
    self.ball = nil;
}

/* App 回前台/活跃时调用：确保悬浮球仍注册在 SpringBoard（防止被移除） */
- (void)reRegisterIfNeeded {
    if (!self.floatingWindow) return;
    if (self.registered) return;
    [self registerToSpringBoardWithRetry];
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
    if (self.registered) return;
    unsigned int cid = [self windowContextID];
    if (cid == 0) return;

    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!cls) {
        NSLog(@"[Floating] SBSAccessibilityWindowHostingController not found");
        return;
    }

    self.hostingController = [[cls alloc] init];
    if ([self.hostingController respondsToSelector:@selector(registerWindowWithContextID:atLevel:)]) {
        [self.hostingController registerWindowWithContextID:cid
                                                   atLevel:self.floatingWindow.windowLevel];
        self.registered = YES;
        NSLog(@"[Floating] registered contextID=%u level=%.0f", cid, self.floatingWindow.windowLevel);
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