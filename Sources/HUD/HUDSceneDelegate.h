//
// HUDSceneDelegate.h
//
// AilinHUD Scene 生命周期（照懒人 RootCore 反汇编铁证 v1.8.0）：
// 窗口 + 二进制 FBScene + binder + SBS 注册。
//
#import <UIKit/UIKit.h>

@interface HUDSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) id fbScene;    /* v1.8.0 FBSceneManager 手动创建的二进制 scene */
@property (nonatomic, strong) id binder;     /* v1.8.0 UIRootWindowScenePresentationBinder */
@end
