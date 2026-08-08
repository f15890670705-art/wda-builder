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
