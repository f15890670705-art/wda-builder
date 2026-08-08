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
- (void)showFloatingBallInScene:(UIWindowScene *)windowScene;   /* v1.5.2 iOS13+ 绑 scene */
- (void)hideFloatingBall;
- (void)reRegisterIfNeeded;
- (void)rebuildFloatingWindow;   /* v1.5.5: 回前台重建窗口拿全新 contextID */
- (void)reportToEngine:(NSString *)msg;   /* App 状态上报到引擎日志（远程诊断） */
@end

NS_ASSUME_NONNULL_END