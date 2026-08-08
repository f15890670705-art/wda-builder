//
// AilinTouchSceneDelegate.m
//
// 主 App Scene 生命周期（照 AutoGo floatball 架构）：
// 窗口 + TabBar + Nav 在 scene:willConnectToSession:options: 里创建，
// 然后通过 AilinTouchSceneReady 通知把引用交给 AppDelegate。
//
#import "AilinTouchSceneDelegate.h"
#import "ATTabBarController.h"
#import "ControlPanelViewController.h"
#import "ServiceManagerViewController.h"
#import "FloatingWindowManager.h"

@implementation AilinTouchSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)connectionOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.windowScene = (UIWindowScene *)scene;
    self.window.backgroundColor = [UIColor whiteColor];

    ControlPanelViewController *controlVC  = [ControlPanelViewController new];
    ServiceManagerViewController *serviceVC = [ServiceManagerViewController new];

    ATTabBarController *tabBar = [[ATTabBarController alloc]
        initWithViewControllers:@[controlVC, serviceVC]
                        titles:@[@"控制面板", @"服务管理"]
                       symbols:@[@"house.fill", @"gearshape.fill"]];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:tabBar];
    nav.navigationBar.hidden = YES;     /* 自绘标题 */
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    /* ★ v1.5.2: 悬浮球回到 App 内（照懒人方案——懒人 RootService 没有独立 HUD
       进程，球就在主 App 进程里画 + SBS 注册全局显示。App daemon 化后 launchd
       常驻，iOS 不杀 → "卸载 App 球还在"）。
       之前 v1.3.x-1.5.x 走独立 HUD 进程是错误方向：裸进程拿不到 FrontBoard scene
       一直卡 booting。现在用 v1.1.x 验证过能显示的 FloatingWindowManager，
       iOS 13+ 必须绑定当前 windowScene。 */
    [[FloatingWindowManager shared] showFloatingBallInScene:(UIWindowScene *)scene];

    /* 通知 AppDelegate 接住 VC 引用（按钮回调 + 状态刷新用） */
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"AilinTouchSceneReady"
                      object:nil
                    userInfo:@{
                        @"nav": nav,
                        @"controlVC": controlVC,
                        @"serviceVC": serviceVC,
                    }];
}

@end
