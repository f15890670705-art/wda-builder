//
// FloatingWindowManager.h
// 管理全局悬浮窗：创建高 level UIWindow + SBSAccessibilityWindowHostingController 注册
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FloatingWindowManager : NSObject
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, strong) UIWindow *floatingWindow;

+ (instancetype)shared;
- (void)showFloatingBall;
- (void)hideFloatingBall;
@end

NS_ASSUME_NONNULL_END