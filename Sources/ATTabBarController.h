//
// ATTabBarController.h
// 自定义底部 TabBar（控制面板 / 服务管理）
//
#import <UIKit/UIKit.h>

@interface ATTabBarController : UIViewController
- (instancetype)initWithViewControllers:(NSArray<UIViewController *> *)vcs
                                 titles:(NSArray<NSString *> *)titles
                                symbols:(NSArray<NSString *> *)symbols;
@end
