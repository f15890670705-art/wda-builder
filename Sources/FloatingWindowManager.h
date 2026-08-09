//
// FloatingWindowManager.h
// 管理全局悬浮窗：创建高 level UIWindow + SBSAccessibilityWindowHostingController 注册
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FloatingWindowManager : NSObject
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, strong) UIWindow *floatingWindow;
/* ★ v1.8.61 主 App 内部球开关（默认 NO）：全局球由 AilinHUD 独立进程
   （TRHudMain plugin 模式 + SBS 注册）负责，主 App 只显示控制面板 UI。
   置 YES 可恢复主 App 球（兜底用）。 */
@property (nonatomic, assign) BOOL ballEnabled;

+ (instancetype)shared;
- (void)showFloatingBall;
- (void)showFloatingBallInScene:(UIWindowScene *)windowScene;   /* v1.5.2 iOS13+ 绑 scene */
- (void)hideFloatingBall;
- (void)reRegisterIfNeeded;
- (void)registerToSpringBoardWithRetry;   /* v1.7.0: 重新取 cid + 重注册（回前台/心跳用） */
- (void)setWindowVisible:(BOOL)visible;   /* v1.5.7 照懒人 setHidden:BOOL 切换可见性 */
- (void)rebuildFloatingWindow;   /* v1.5.5: 回前台重建窗口拿全新 contextID */
- (void)reportToEngine:(NSString *)msg;   /* App 状态上报到引擎日志（远程诊断） */
- (void)detachBallFromScene;   /* v1.8.22 切后台窗口脱离 scene（球不随 scene 隐藏） */
- (void)attachBallToScene;     /* v1.8.22 回前台窗口绑回 scene */
@end

NS_ASSUME_NONNULL_END