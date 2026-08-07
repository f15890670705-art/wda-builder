//
// ServiceManagerViewController.h
// 服务管理页（截图主页）
//
#import <UIKit/UIKit.h>

@interface ServiceManagerViewController : UIViewController

/* 提供给外部 UI 刷新的数据 source */
@property (nonatomic, copy) NSString *serviceState;    // @"已启动" / @"已停止"
@property (nonatomic, copy) NSString *serviceVersion;  // 引擎版本
@property (nonatomic, copy) NSString *appVersion;      // App 版本（显示在标题）
@property (nonatomic, copy) NSString *localIP;
@property (nonatomic, assign) NSInteger httpPort;
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic, copy) NSString *deviceOS;
@property (nonatomic, copy) NSString *deviceModel;
@property (nonatomic, copy) NSString *screenSize;

/* 按钮回调 */
@property (nonatomic, copy) void (^onTapStart)(void);
@property (nonatomic, copy) void (^onTapStop)(void);
@property (nonatomic, copy) void (^onTapRefreshStatus)(void);
@property (nonatomic, copy) void (^onTapRefreshIP)(void);
@property (nonatomic, copy) void (^onTapLogDir)(void);
@property (nonatomic, copy) void (^onTapWorkDir)(void);

@end
