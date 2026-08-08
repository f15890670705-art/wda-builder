//
// AilinTouchSceneDelegate.h
//
// 主 App Scene 生命周期（照 AutoGo floatball 架构：主 App 和 HUD 共享
// 同一 Info.plist 的 UIApplicationSceneManifest，各进程用 configurationFor
// ConnectingSceneSession 动态指定自己的 SceneDelegate）。
// 主 App 的窗口在 scene:willConnectToSession:options: 里创建。
//
#import <UIKit/UIKit.h>

@interface AilinTouchSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
