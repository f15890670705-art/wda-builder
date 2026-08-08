//
// FloatingBall.h
// 全局悬浮球（懒人同款 SBSAccessibilityWindowHostingController 方案）
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FloatingBall : UIView
@property (nonatomic, copy) void (^onTap)(void);
@end

NS_ASSUME_NONNULL_END