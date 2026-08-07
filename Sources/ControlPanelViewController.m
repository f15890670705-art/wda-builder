//
// ControlPanelViewController.m
//
#import "ControlPanelViewController.h"
#import "UITheme.h"

@interface ControlPanelViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusBadge;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *ipLabel;
@end

@implementation ControlPanelViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ATBg();

    self.scroll = [UIScrollView new];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scroll];

    self.content = [UIView new];
    self.content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:self.content];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor constraintEqualToAnchor:g.topAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [self.content.topAnchor constraintEqualToAnchor:self.scroll.topAnchor],
        [self.content.bottomAnchor constraintEqualToAnchor:self.scroll.bottomAnchor],
        [self.content.leadingAnchor constraintEqualToAnchor:self.scroll.leadingAnchor],
        [self.content.trailingAnchor constraintEqualToAnchor:self.scroll.trailingAnchor],
        [self.content.widthAnchor constraintEqualToAnchor:self.scroll.widthAnchor],
    ]];

    /* 顶部标题 */
    self.titleLabel = [UILabel new];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"控制面板";
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = ATText();
    [self.content addSubview:self.titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.content.topAnchor constant:12],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.content.leadingAnchor],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor],
    ]];

    /* 状态 / 说明卡 */
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = ATCard();
    card.layer.cornerRadius = AT_CARD_RADIUS;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.04;
    card.layer.shadowRadius = 8;
    card.layer.shadowOffset = CGSizeMake(0, 2);
    [self.content addSubview:card];

    UILabel *badge = [UILabel new];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.text = @"  远程控制  ";
    badge.textColor = ATPurple();
    badge.backgroundColor = ATPurpleBg();
    badge.textAlignment = NSTextAlignmentCenter;
    badge.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    badge.layer.cornerRadius = 6;
    badge.layer.masksToBounds = YES;
    [card addSubview:badge];

    self.statusBadge = [UILabel new];
    self.statusBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusBadge.text = @"● 服务已启动";
    self.statusBadge.textColor = ATGreen();
    self.statusBadge.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [card addSubview:self.statusBadge];

    self.descLabel = [UILabel new];
    self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.descLabel.numberOfLines = 0;
    self.descLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    self.descLabel.textColor = ATSubText();
    self.descLabel.text = @"本设备已在 8080 端口对外提供 HTTP 控制接口。\n"
                          @"从同 WiFi 的电脑 / 手机用浏览器访问下方 IP，"
                          @"即可触发触摸与滑动。\n\n"
                          @"示例命令:\n"
                          @"  GET /tap?x=200&y=400         单击\n"
                          @"  GET /swipe?x1=100&y1=500&x2=300&y2=500&ms=300   滑动\n";
    [card addSubview:self.descLabel];

    self.ipLabel = [UILabel new];
    self.ipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.ipLabel.numberOfLines = 0;
    self.ipLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.ipLabel.textColor = ATText();
    [card addSubview:self.ipLabel];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:12],
        [card.leadingAnchor constraintEqualToAnchor:self.content.leadingAnchor constant:AT_PAD],
        [card.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-AT_PAD],
        [card.bottomAnchor constraintEqualToAnchor:self.content.bottomAnchor constant:-24],

        [badge.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [badge.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [badge.heightAnchor constraintEqualToConstant:26],

        [self.statusBadge.topAnchor constraintEqualToAnchor:badge.bottomAnchor constant:12],
        [self.statusBadge.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],

        [self.descLabel.topAnchor constraintEqualToAnchor:self.statusBadge.bottomAnchor constant:14],
        [self.descLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.descLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.ipLabel.topAnchor constraintEqualToAnchor:self.descLabel.bottomAnchor constant:14],
        [self.ipLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.ipLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.ipLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
}

- (void)setLocalIP:(NSString *)ip {
    _localIP = [ip copy];
    if (self.httpPort > 0) {
        self.ipLabel.text = [NSString stringWithFormat:@"访问地址:\n  http://%@:%ld/\n  http://%@:%ld/status\n  http://%@:%ld/tap?x=200&y=400",
                             ip, (long)self.httpPort,
                             ip, (long)self.httpPort,
                             ip, (long)self.httpPort];
    } else {
        self.ipLabel.text = [NSString stringWithFormat:@"访问地址: http://%@:待启动", ip];
    }
}

@end
