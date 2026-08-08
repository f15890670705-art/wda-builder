//
// HUDSceneDelegate.m
//
// AilinHUD Scene 生命周期实现（照 AutoGo floatball 验证过的架构）。
// 窗口 + 悬浮球 + SBS 注册全部在 scene:willConnectToSession:options: 里做。
//
#import "HUDSceneDelegate.h"
#import "HUDBall.h"

/* SBSAccessibilityWindowHostingController 私有类声明（运行时解析） */
@interface SBSAccessibilityWindowHostingController : NSObject
- (void)registerWindowWithContextID:(unsigned int)contextID atLevel:(double)level;
@end

/* 诊断辅助：写 /tmp/ailintouch_hud.alive，引擎 /hud 端点远程读 */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@implementation HUDSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)connectionOptions {

    hud_mark(@"scene-willconnect");

    /* 全屏透明窗口（TrollSpeed 姿势：全屏 + 极高 level + makeKeyAndVisible） */
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.windowScene = (UIWindowScene *)scene;
    self.window.backgroundColor = [UIColor clearColor];
    self.window.windowLevel = 10000010.0;

    /* ⭐ AutoGo agoverlayd 同款私有属性（后台可点关键） */
    @try {
        [self.window setValue:@YES forKey:@"_usesWindowServerHitTesting"];
        [self.window setValue:@YES forKey:@"_canShowWhileLocked"];
        [self.window setValue:@YES forKey:@"ignoreOcclusionReasons"];
    } @catch (NSException *e) {
        NSLog(@"[AilinHUD] private window props set failed: %@", e);
    }

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    self.window.rootViewController = vc;

    /* 悬浮球 */
    CGFloat size = 56;
    CGFloat x = 20;
    CGFloat y = [UIScreen mainScreen].bounds.size.height / 2 - size;
    HUDBall *ball = [[HUDBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
    [vc.view addSubview:ball];

    [self.window makeKeyAndVisible];
    hud_mark(@"window-shown");

    /* SBS 注册 → 全局悬浮 */
    [self registerToSpringBoard];
}

- (unsigned int)windowContextID {
    id cid = [self.window valueForKey:@"_contextId"];
    if (cid && [cid respondsToSelector:@selector(unsignedIntValue)]) {
        unsigned int v = [cid unsignedIntValue];
        if (v != 0) return v;
    }
    return 0;
}

- (void)registerToSpringBoard {
    unsigned int cid = [self windowContextID];
    if (cid == 0) {
        /* 首帧可能拿不到，0.3s 后重试 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self registerToSpringBoard];
        });
        return;
    }
    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!cls) {
        hud_mark(@"sbs-class-missing");
        return;
    }
    id ctrl = [[cls alloc] init];
    if ([ctrl respondsToSelector:@selector(registerWindowWithContextID:atLevel:)]) {
        [ctrl registerWindowWithContextID:cid atLevel:self.window.windowLevel];
        NSLog(@"[AilinHUD] registered cid=%u", cid);
        hud_mark([NSString stringWithFormat:@"registered-cid=%u", cid]);
    }
}

@end
