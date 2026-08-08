//
// DirListViewController.h
// 通过引擎 HTTP /dir 端点列目录（root 引擎读，App 走 HTTP 显示，无需 root）
//
#import <UIKit/UIKit.h>

@interface DirListViewController : UIViewController
@property (nonatomic, copy) NSString *endpointURL;   // 默认 http://127.0.0.1:8080/dir?path=/var/mobile/ailintouch
@end