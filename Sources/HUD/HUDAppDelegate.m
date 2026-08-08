//
// HUDAppDelegate.m
//
// AilinHUD 进程入口（App 生命周期层）：iOS 13+ 走 Scene 生命周期，
// 窗口/悬浮球/SBS 注册全部在 HUDSceneDelegate 里做（AutoGo floatball 同款架构）。
// 独立于主 App，由引擎 spawn。停止服务时引擎通知本进程退出 → 球消失。
//
#import "HUDAppDelegate.h"

@implementation HUDAppDelegate

/* 提供 scene 配置（Info.plist UISceneConfigurations 指定了 HUDSceneDelegate） */
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                   options:(UISceneConnectionOptions *)options {

    UISceneConfiguration *cfg = [[UISceneConfiguration alloc]
        initWithName:@"Default Configuration"
        sessionRole:connectingSceneSession.role];
    cfg.delegateClass = NSClassFromString(@"HUDSceneDelegate");
    return cfg;
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    /* iOS 13+ 窗口创建交给 Scene，这里只确认进程活着 */
    [@"appdelegate\n" writeToFile:@"/tmp/ailintouch_hud.alive"
                      atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {}
- (void)applicationDidEnterBackground:(UIApplication *)application {}

@end
