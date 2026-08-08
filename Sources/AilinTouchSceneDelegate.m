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

    /* ★ v1.7.2 照懒人时序：悬浮球窗口【不在 scene:willConnect 创建】！
       懒人 = didFinish → dispatch_after(1s) → initializeWithHUD →
       setupHUDWindow（不绑 scene 的高 level 窗口）→ dispatch_after(0.5s) →
       registerHUDWindow。窗口在 App 完全启动、scene 稳定后才创建——
       不绑 scene 的窗口此时才能被 WindowServer 接受（v1.6.6 在 scene 刚
       连接时创建 → cid=0 球消失的根因）。
       这里只发通知，由 AppDelegate didFinish 延迟 1 秒创建悬浮球。 */
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
