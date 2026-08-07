//
// FileViewerViewController.m
//
#import "FileViewerViewController.h"
#import "UITheme.h"

@interface FileViewerViewController ()
@property (nonatomic, copy) NSString *folderPath;
@property (nonatomic, copy) NSString *folderTitle;
@property (nonatomic, assign) BOOL tailMode;
@property (nonatomic, strong) UITextView *tv;
@end

@implementation FileViewerViewController

- (instancetype)initWithTitle:(NSString *)t path:(NSString *)path showTail:(BOOL)tail {
    if ((self = [super init])) {
        self.folderTitle = t;
        self.folderPath = path;
        self.tailMode = tail;
        self.title = t;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ATBg();

    self.navigationItem.title = self.folderTitle;

    UITextView *tv = [UITextView new];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.textColor = ATText();
    tv.backgroundColor = ATCard();
    tv.layer.cornerRadius = 12;
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    [self.view addSubview:tv];
    self.tv = tv;

    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    tv.refreshControl = rc;
    tv.alwaysBounceVertical = YES;

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [tv.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],
        [tv.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:AT_PAD],
        [tv.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-AT_PAD],
    ]];

    [self reload];
}

- (void)reload {
    [self.tv.refreshControl endRefreshing];
    if (self.tailMode) {
        [self loadTail];
    } else {
        [self loadListing];
    }
}

- (NSString *)resolvePath:(NSString *)p {
    /* 如果是目录则列目录；如果是文件返回原路径 */
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir) {
        return p;
    }
    return p;
}

- (void)loadListing {
    NSString *p = self.folderPath;
    NSError *err = nil;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:&err];
    if (!items) {
        self.tv.text = [NSString stringWithFormat:@"读取失败: %@\n路径: %@\n\n提示: /var/mobile/ 在 App 中需 root 权限才能访问。\n"
                                                 "请在「服务管理」页启动服务后,通过 launchd 常驻 root 引擎来访问。", err.localizedDescription, p];
        return;
    }

    NSMutableString *out = [NSMutableString stringWithFormat:@"📁 %@\n\n", p];
    for (NSString *name in items) {
        NSString *full = [p stringByAppendingPathComponent:name];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:nil];
        unsigned long long size = [attr[NSFileSize] unsignedLongLongValue];
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm";
        NSString *mtime = [df stringFromDate:attr[NSFileModificationDate]];
        BOOL isDir = [attr[NSFileType] isEqualToString:NSFileTypeDirectory];
        if (isDir) {
            [out appendFormat:@"📁 %@\n", name];
        } else {
            [out appendFormat:@"📄 %-30s  %10llu B  %@\n",
                            [name UTF8String], size, mtime];
        }
    }
    self.tv.text = out;
}

- (void)loadTail {
    NSString *p = self.folderPath;
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) {
        self.tv.text = [NSString stringWithFormat:@"读取失败: %@", p];
        return;
    }
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];

    /* 截取尾部最多 200 行 */
    NSArray *lines = [s componentsSeparatedByString:@"\n"];
    NSInteger from = MAX(0, (NSInteger)lines.count - 200);
    NSString *tail = [[lines subarrayWithRange:NSMakeRange(from, lines.count - from)] componentsJoinedByString:@"\n"];
    self.tv.text = [NSString stringWithFormat:@"📄 %@\n\n%@", p, tail];
}

@end
