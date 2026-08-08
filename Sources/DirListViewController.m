//
// DirListViewController.m
//
#import "DirListViewController.h"
#import "UITheme.h"

@interface DirListViewController ()
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIBarButtonItem *refreshBtn;
@end

@implementation DirListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ATBg();
    self.title = @"工作目录";

    self.refreshBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                     target:self
                                                                     action:@selector(reload)];
    self.navigationItem.rightBarButtonItem = self.refreshBtn;

    [self.navigationController setNavigationBarHidden:NO animated:NO];

    self.tv = [UITextView new];
    self.tv.translatesAutoresizingMaskIntoConstraints = NO;
    self.tv.editable = NO;
    self.tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.tv.textColor = ATText();
    self.tv.backgroundColor = ATCard();
    self.tv.layer.cornerRadius = 12;
    self.tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    [self.view addSubview:self.tv];

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.statusLabel.textColor = ATSubText();
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.statusLabel];

    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.tv.refreshControl = rc;

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:AT_PAD],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-AT_PAD],

        [self.tv.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:8],
        [self.tv.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
        [self.tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:AT_PAD],
        [self.tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-AT_PAD],
    ]];

    self.statusLabel.text = [NSString stringWithFormat:@"目录: %@", self.endpointURL ?: @""];
    [self reload];
}

- (void)reload {
    [self.tv.refreshControl endRefreshing];
    NSString *url = self.endpointURL ?: @"http://127.0.0.1:8080/dir?path=/var/mobile/ailintouch";
    NSURL *u = [NSURL URLWithString:url];
    if (!u) {
        self.tv.text = @"URL 错误";
        return;
    }
    NSURLRequest *req = [NSURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err) {
                self.tv.text = [NSString stringWithFormat:@"拉取失败\n\n%@\n\n可能原因:\n• 引擎未启动（请到「服务管理」点启动）", err.localizedDescription];
                return;
            }
            NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            if (s.length == 0) s = @"(空)";
            self.tv.text = s;
        });
    }];
    [task resume];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
}

@end