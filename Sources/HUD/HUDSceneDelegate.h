//
// HUDSceneDelegate.h
//
// AilinHUD Scene 生命周期（照 AutoGo floatball 验证过的架构）：
// 窗口 + 悬浮球 + SBS 注册在 scene:willConnectToSession:options: 里做。
//
#import <UIKit/UIKit.h>

@interface HUDSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
