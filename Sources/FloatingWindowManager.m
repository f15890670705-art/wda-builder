//
// FloatingWindowManager.m
//
// 全局悬浮窗：懒人同款 SBSAccessibilityWindowHostingController 方案
//   1. 创建高 windowLevel 的 UIWindow（普通 App 只能盖自己界面）
//   2. 取 window 的 contextID
//   3. SBSAccessibilityWindowHostingController registerWindowWithContextID:atLevel:
//      → 把窗口注册进 SpringBoard → 悬浮在所有 App 之上
//   4. 发 HUD 通知确认注册
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

    [self registerToSpringBoard];
}

- (void)hideFloatingBall {
    if (!self.floatingWindow) return;
    [self unregisterFromSpringBoard];
    self.floatingWindow.hidden = YES;
    self.floatingWindow = nil;
}

/* 取 UIWindow 的 contextID（懒人 safeGetWindowContextID 同思路） */
- (unsigned int)windowContextID {
    if (!self.floatingWindow) return 0;
    /* iOS 13+ UIWindow 有 _contextId 私有 ivar */
    id cid = [self.floatingWindow valueForKey:@"_contextId"];
    if (cid && [cid respondsToSelector:@selector(unsignedIntValue)]) {
        return [cid unsignedIntValue];
    }
    /* fallback：通过 layer 拿 context id */
    id layerCid = [self.floatingWindow.layer valueForKey:@"contextId"];
    if (layerCid && [layerCid respondsToSelector:@selector(unsignedIntValue)]) {
        return [layerCid unsignedIntValue];
    }
    return 0;
}

- (void)registerToSpringBoard {
    unsigned int cid = [self windowContextID];
    if (cid == 0) {
        NSLog(@"[Floating] cannot get window contextID");
        return;
    }

    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!cls) {
        NSLog(@"[Floating] SBSAccessibilityWindowHostingController not found");
        return;
    }

    self.hostingController = [[cls alloc] init];
    if ([self.hostingController respondsToSelector:@selector(registerWindowWithContextID:atLevel:)]) {
        [self.hostingController registerWindowWithContextID:cid
                                                   atLevel:self.floatingWindow.windowLevel];
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
}

@end