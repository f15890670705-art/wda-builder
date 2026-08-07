//
// FileViewerViewController.h
// 日志/工作目录查看器
//
#import <UIKit/UIKit.h>

@interface FileViewerViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)t path:(NSString *)path showTail:(BOOL)tail;
@end
