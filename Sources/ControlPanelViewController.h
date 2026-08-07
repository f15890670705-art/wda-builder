//
// ControlPanelViewController.h
// 控制面板页（TabBar 左）—— 展示当前触摸命令格式 + IP，方便手动测
//
#import <UIKit/UIKit.h>

@interface ControlPanelViewController : UIViewController

/* 实时刷新的 IP */
@property (nonatomic, copy) NSString *localIP;
@property (nonatomic, assign) NSInteger httpPort;

@end
