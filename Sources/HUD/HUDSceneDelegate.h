//
// HUDSceneDelegate.h
//
// AilinHUD Scene 生命周期（iOS 13+ 必须走 scene，UIApplicationMain 需要
// UISceneConfigurations + SceneDelegate 才能拿到窗口，AutoGo floatball 同款架构）。
//
#import <UIKit/UIKit.h>

@interface HUDSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
