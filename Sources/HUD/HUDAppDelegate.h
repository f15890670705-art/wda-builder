//
// HUDAppDelegate.h
//
#import <UIKit/UIKit.h>

@interface HUDAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;

/* ★ v1.8.36 手动建球（不依赖 UIApplicationMain）：UIApplicationMain 前先建窗口+球+FBScene+binder+SBS */
+ (void)manualInstallBall;
@end
