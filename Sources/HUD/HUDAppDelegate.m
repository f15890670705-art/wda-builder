//
// HUDAppDelegate.m
//
// AilinHUD 进程入口（照 AutoGo floatball 验证过的架构）。
//
// ★★ 为什么这样能拿到 scene（floatball 原理解析）：
//   HUD 二进制放在主 App bundle 根目录（不是独立 .app），共享主 App 的
//   Info.plist —— mainBundle = AilinTouch.app，bundle id = 已安装的
//   com.ailintouch.iphone。UIKit 以"已安装 App"身份请求 scene 连接，
//   FrontBoard 认识这个 bundle → 分配 scene → scene:willConnect 正常触发。
//   而我们之前 HUD 是独立 bundle（com.ailintouch.hud），FrontBoard 不认识
//   → 永不分配 scene → 卡死（v1.3.7-1.4.2 一路的根因）。
//
//   AppDelegate 实现 configurationForConnectingSceneSession:options:
//   动态返回 UISceneConfiguration（delegateClass = HUDSceneDelegate），
//   覆盖 Info.plist 里指向主 App SceneDelegate 的默认配置（floatball 同款）。
//
#import "HUDAppDelegate.h"

/* 诊断辅助：写 /tmp/ailintouch_hud.alive，引擎 /hud 端点远程读 */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@implementation HUDAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    hud_mark(@"appdelegate");
    return YES;
}

/* ★ 关键：动态返回 HUD 自己的 scene 配置（floatball 同款）
   Info.plist 的 UISceneConfigurations 指向主 App 的 AilinTouchSceneDelegate，
   这里覆盖成 HUDSceneDelegate —— 同一 bundle 两个进程各用各的 delegate */
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                   options:(UISceneConnectionOptions *)options {

    UISceneConfiguration *cfg = [[UISceneConfiguration alloc]
        initWithName:@"HUD Configuration" sessionRole:connectingSceneSession.role];
    cfg.delegateClass = NSClassFromString(@"HUDSceneDelegate");
    hud_mark(@"scene-config-returned");
    return cfg;
}

- (void)applicationWillResignActive:(UIApplication *)application {}
- (void)applicationDidEnterBackground:(UIApplication *)application {}

@end
