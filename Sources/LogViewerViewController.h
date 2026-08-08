//
// LogViewerViewController.h
// 通过引擎 HTTP /log 端点拉取日志（root 引擎读日志，App 走 HTTP 显示）
//
#import <UIKit/UIKit.h>

@interface LogViewerViewController : UIViewController
@property (nonatomic, copy) NSString *endpointURL;   // 默认 http://127.0.0.1:8080/log
@end