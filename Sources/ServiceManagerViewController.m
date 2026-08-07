//
// ServiceManagerViewController.m
//
// 服务管理页：顶部标题 + 三个卡片（服务状态 / 设备信息 / 服务控制）
//
#import "ServiceManagerViewController.h"
#import "UITheme.h"

#pragma mark - 小工具类

@interface ATChipBadge : UILabel
+ (instancetype)badgeWithText:(NSString *)t fg:(UIColor *)fg bg:(UIColor *)bg;
@end
@implementation ATChipBadge
+ (instancetype)badgeWithText:(NSString *)t fg:(UIColor *)fg bg:(UIColor *)bg {
    UILabel *l = [UILabel new];
    l.text = t;
    l.textColor = fg;
    l.backgroundColor = bg;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    l.layer.cornerRadius = 6;
    l.layer.masksToBounds = YES;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}
@end

@interface ATCardView : UIView
+ (instancetype)card;
@end
@implementation ATCardView
+ (instancetype)card {
    UIView *v = [UIView new];
    v.backgroundColor = ATCard();
    v.layer.cornerRadius = AT_CARD_RADIUS;
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = 0.04;
    v.layer.shadowRadius = 8;
    v.layer.shadowOffset = CGSizeMake(0, 2);
    v.translatesAutoresizingMaskIntoConstraints = NO;
    return v;
}
@end


#pragma mark - ServiceManagerViewController

@interface ServiceManagerViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *content;

@property (nonatomic, strong) ATCardView *cardStatus;
@property (nonatomic, strong) ATCardView *cardDevice;
@property (nonatomic, strong) ATCardView *cardControl;

@property (nonatomic, strong) UIView    *statusDot;
@property (nonatomic, strong) UILabel   *statusText;
@property (nonatomic, strong) UILabel   *versionText;
@property (nonatomic, strong) UILabel   *ipText;
@property (nonatomic, strong) UIButton  *refreshIpBtn;
@property (nonatomic, strong) UILabel   *portText;

@property (nonatomic, strong) UILabel   *devName;
@property (nonatomic, strong) UILabel   *devOS;
@property (nonatomic, strong) UILabel   *devModel;
@property (nonatomic, strong) UILabel   *devScreen;

@property (nonatomic, strong) UIButton  *startBtn;
@property (nonatomic, strong) UIButton  *stopBtn;
@property (nonatomic, strong) UIButton  *refreshBtn;
@property (nonatomic, strong) UIButton  *logBtn;
@property (nonatomic, strong) UIButton  *workBtn;
@end

@implementation ServiceManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ATBg();
    [self buildUI];
    [self refreshAll];
}

#pragma mark - 构建 UI

- (void)buildUI {
    /* scroll + content */
    self.scroll = [UIScrollView new];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.showsVerticalScrollIndicator = NO;
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    self.content = [UIView new];
    self.content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:self.content];

    /* 顶部 title */
    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"服务管理";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = ATText();
    title.textAlignment = NSTextAlignmentCenter;
    [self.content addSubview:title];

    /* 三张卡片 */
    self.cardStatus  = [ATCardView card];
    self.cardDevice  = [ATCardView card];
    self.cardControl = [ATCardView card];
    [self.content addSubview:self.cardStatus];
    [self.content addSubview:self.cardDevice];
    [self.content addSubview:self.cardControl];

    [self buildCardStatus];
    [self buildCardDevice];
    [self buildCardControl];

    /* constraints */
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        /* scroll */
        [self.scroll.topAnchor      constraintEqualToAnchor:g.topAnchor],
        [self.scroll.bottomAnchor   constraintEqualToAnchor:g.bottomAnchor],
        [self.scroll.leadingAnchor  constraintEqualToAnchor:g.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        /* content */
        [self.content.topAnchor      constraintEqualToAnchor:self.scroll.topAnchor],
        [self.content.bottomAnchor   constraintEqualToAnchor:self.scroll.bottomAnchor],
        [self.content.leadingAnchor  constraintEqualToAnchor:self.scroll.leadingAnchor],
        [self.content.trailingAnchor constraintEqualToAnchor:self.scroll.trailingAnchor],
        [self.content.widthAnchor    constraintEqualToAnchor:self.scroll.widthAnchor],

        /* title */
        [title.topAnchor      constraintEqualToAnchor:self.content.topAnchor constant:12],
        [title.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor],

        /* cards */
        [self.cardStatus.topAnchor      constraintEqualToAnchor:title.bottomAnchor constant:12],
        [self.cardStatus.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:AT_PAD],
        [self.cardStatus.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-AT_PAD],

        [self.cardDevice.topAnchor      constraintEqualToAnchor:self.cardStatus.bottomAnchor constant:12],
        [self.cardDevice.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:AT_PAD],
        [self.cardDevice.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-AT_PAD],

        [self.cardControl.topAnchor      constraintEqualToAnchor:self.cardDevice.bottomAnchor constant:12],
        [self.cardControl.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:AT_PAD],
        [self.cardControl.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-AT_PAD],
        [self.cardControl.bottomAnchor   constraintEqualToAnchor:self.content.bottomAnchor constant:-24],
    ]];
}

- (void)buildCardStatus {
    /* 顶部 chip: 服务状态 */
    ATChipBadge *badge = [ATChipBadge badgeWithText:@"  服务状态  " fg:ATPurple() bg:ATPurpleBg()];
    [self.cardStatus addSubview:badge];

    /* 状态点 + 文字 */
    self.statusDot = [UIView new];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.backgroundColor = ATGreen();
    self.statusDot.layer.cornerRadius = 5;
    [self.cardStatus addSubview:self.statusDot];

    self.statusText = [UILabel new];
    self.statusText.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusText.text = @"服务已启动";
    self.statusText.textColor = ATGreen();
    self.statusText.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [self.cardStatus addSubview:self.statusText];

    /* 版本 */
    self.versionText = [UILabel new];
    self.versionText.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionText.textColor = ATSubText();
    self.versionText.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    [self.cardStatus addSubview:self.versionText];

    /* 分隔线 */
    UIView *line = [UIView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = ATDivider();
    [self.cardStatus addSubview:line];

    /* IP 行 */
    self.ipText = [UILabel new];
    self.ipText.translatesAutoresizingMaskIntoConstraints = NO;
    self.ipText.text = @"IP: -";
    self.ipText.textColor = ATText();
    self.ipText.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [self.cardStatus addSubview:self.ipText];

    self.refreshIpBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.refreshIpBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.refreshIpBtn setTitle:@"刷新 IP" forState:UIControlStateNormal];
    [self.refreshIpBtn setTitleColor:ATBlue() forState:UIControlStateNormal];
    self.refreshIpBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.refreshIpBtn.backgroundColor = [UIColor whiteColor];
    self.refreshIpBtn.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    self.refreshIpBtn.layer.cornerRadius = 16;
    self.refreshIpBtn.layer.borderColor = ATBlue().CGColor;
    self.refreshIpBtn.layer.borderWidth = 1.2;
    self.refreshIpBtn.layer.masksToBounds = YES;
    [self.refreshIpBtn addTarget:self action:@selector(didTapRefreshIP) forControlEvents:UIControlEventTouchUpInside];
    [self.cardStatus addSubview:self.refreshIpBtn];

    self.portText = [UILabel new];
    self.portText.translatesAutoresizingMaskIntoConstraints = NO;
    self.portText.textColor = ATSubText();
    self.portText.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    [self.cardStatus addSubview:self.portText];

    /* constraints */
    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor      constraintEqualToAnchor:self.cardStatus.topAnchor constant:16],
        [badge.leadingAnchor  constraintEqualToAnchor:self.cardStatus.leadingAnchor constant:16],
        [badge.heightAnchor   constraintEqualToConstant:26],

        [self.statusDot.widthAnchor  constraintEqualToConstant:10],
        [self.statusDot.heightAnchor constraintEqualToConstant:10],
        [self.statusDot.topAnchor      constraintEqualToAnchor:badge.bottomAnchor constant:14],
        [self.statusDot.leadingAnchor constraintEqualToAnchor:self.cardStatus.leadingAnchor constant:18],

        [self.statusText.leadingAnchor constraintEqualToAnchor:self.statusDot.trailingAnchor constant:8],
        [self.statusText.centerYAnchor constraintEqualToAnchor:self.statusDot.centerYAnchor],

        [self.versionText.topAnchor     constraintEqualToAnchor:self.statusDot.bottomAnchor constant:6],
        [self.versionText.leadingAnchor constraintEqualToAnchor:self.statusDot.leadingAnchor],

        [line.topAnchor      constraintEqualToAnchor:self.versionText.bottomAnchor constant:16],
        [line.leadingAnchor  constraintEqualToAnchor:self.cardStatus.leadingAnchor constant:16],
        [line.trailingAnchor constraintEqualToAnchor:self.cardStatus.trailingAnchor constant:-16],
        [line.heightAnchor   constraintEqualToConstant:1],

        [self.ipText.topAnchor     constraintEqualToAnchor:line.bottomAnchor constant:14],
        [self.ipText.leadingAnchor constraintEqualToAnchor:self.cardStatus.leadingAnchor constant:16],

        [self.refreshIpBtn.centerYAnchor constraintEqualToAnchor:self.ipText.centerYAnchor],
        [self.refreshIpBtn.trailingAnchor constraintEqualToAnchor:self.cardStatus.trailingAnchor constant:-16],

        [self.portText.topAnchor     constraintEqualToAnchor:self.ipText.bottomAnchor constant:8],
        [self.portText.leadingAnchor constraintEqualToAnchor:self.cardStatus.leadingAnchor constant:16],
        [self.portText.bottomAnchor  constraintEqualToAnchor:self.cardStatus.bottomAnchor constant:-16],
    ]];
}

- (void)buildCardDevice {
    ATChipBadge *badge = [ATChipBadge badgeWithText:@"  设备信息  " fg:ATGreen() bg:ATGreenBg()];
    [self.cardDevice addSubview:badge];

    self.devName   = [self buildRowLabel];
    self.devOS     = [self buildRowLabel];
    self.devModel  = [self buildRowLabel];
    self.devScreen = [self buildRowLabel];
    [self.cardDevice addSubview:self.devName];
    [self.cardDevice addSubview:self.devOS];
    [self.cardDevice addSubview:self.devModel];
    [self.cardDevice addSubview:self.devScreen];

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor      constraintEqualToAnchor:self.cardDevice.topAnchor constant:16],
        [badge.leadingAnchor  constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16],
        [badge.heightAnchor   constraintEqualToConstant:26],

        [self.devName.topAnchor     constraintEqualToAnchor:badge.bottomAnchor constant:14],
        [self.devName.leadingAnchor constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16],
        [self.devName.trailingAnchor constraintLessThanOrEqualToAnchor:self.cardDevice.trailingAnchor constant:-16],

        [self.devOS.topAnchor     constraintEqualToAnchor:self.devName.bottomAnchor constant:10],

        [self.devModel.topAnchor     constraintEqualToAnchor:self.devOS.bottomAnchor constant:10],

        [self.devScreen.topAnchor     constraintEqualToAnchor:self.devModel.bottomAnchor constant:10],
        [self.devScreen.bottomAnchor  constraintEqualToAnchor:self.cardDevice.bottomAnchor constant:-16],
    ]];

    [[self.devOS.leadingAnchor constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16] setActive:YES];
    [[self.devModel.leadingAnchor constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16] setActive:YES];
}

- (UILabel *)buildRowLabel {
    UILabel *l = [UILabel new];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    l.textColor = ATText();
    return l;
}

- (void)buildCardControl {
    ATChipBadge *badge = [ATChipBadge badgeWithText:@"  服务控制  " fg:ATPurple() bg:ATPurpleBg()];
    [self.cardControl addSubview:badge];

    /* 启动 / 停止 */
    self.startBtn = [self buildBigButton:@"启动服务" bg:ATGreenBg() fg:ATGreen()];
    self.stopBtn  = [self buildBigButton:@"停止服务" bg:ATRedBg() fg:ATRed()];
    [self.startBtn addTarget:self action:@selector(didTapStart) forControlEvents:UIControlEventTouchUpInside];
    [self.stopBtn  addTarget:self action:@selector(didTapStop)  forControlEvents:UIControlEventTouchUpInside];
    [self.cardControl addSubview:self.startBtn];
    [self.cardControl addSubview:self.stopBtn];

    /* 刷新状态 (单独居中靠左) */
    self.refreshBtn = [self buildBigButton:@"刷新状态" bg:ATBlueBg() fg:ATBlue()];
    [self.refreshBtn addTarget:self action:@selector(didTapRefresh) forControlEvents:UIControlEventTouchUpInside];
    [self.cardControl addSubview:self.refreshBtn];

    /* 文件浏览器小标题 */
    UILabel *filesTitle = [UILabel new];
    filesTitle.translatesAutoresizingMaskIntoConstraints = NO;
    filesTitle.text = @"文件浏览器";
    filesTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    filesTitle.textColor = ATText();
    [self.cardControl addSubview:filesTitle];

    /* 日志 / 工作 目录 */
    self.logBtn  = [self buildBigButton:@"📁  日志目录" bg:ATGreen() fg:[UIColor whiteColor]];
    self.workBtn = [self buildBigButton:@"📁  工作目录" bg:ATBrown() fg:[UIColor whiteColor]];
    [self.logBtn  addTarget:self action:@selector(didTapLog)  forControlEvents:UIControlEventTouchUpInside];
    [self.workBtn addTarget:self action:@selector(didTapWork) forControlEvents:UIControlEventTouchUpInside];
    [self.cardControl addSubview:self.logBtn];
    [self.cardControl addSubview:self.workBtn];

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor      constraintEqualToAnchor:self.cardControl.topAnchor constant:16],
        [badge.leadingAnchor  constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [badge.heightAnchor   constraintEqualToConstant:26],

        /* 启动/停止 */
        [self.startBtn.topAnchor     constraintEqualToAnchor:badge.bottomAnchor constant:14],
        [self.startBtn.leadingAnchor constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [self.stopBtn.topAnchor     constraintEqualToAnchor:self.startBtn.topAnchor],
        [self.stopBtn.trailingAnchor constraintEqualToAnchor:self.cardControl.trailingAnchor constant:-16],
        [self.startBtn.trailingAnchor constraintEqualToAnchor:self.stopBtn.leadingAnchor constant:-12],
        [self.startBtn.heightAnchor  constraintEqualToConstant:48],
        [self.stopBtn.heightAnchor   constraintEqualToConstant:48],

        /* 刷新状态：单独左侧，宽度减半 */
        [self.refreshBtn.topAnchor     constraintEqualToAnchor:self.startBtn.bottomAnchor constant:12],
        [self.refreshBtn.leadingAnchor constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [self.refreshBtn.widthAnchor   constraintEqualToAnchor:self.cardControl.widthAnchor multiplier:0.5 constant:-22],
        [self.refreshBtn.heightAnchor  constraintEqualToConstant:48],

        /* 文件浏览器小标题 */
        [filesTitle.topAnchor     constraintEqualToAnchor:self.refreshBtn.bottomAnchor constant:18],
        [filesTitle.leadingAnchor constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [filesTitle.trailingAnchor constraintLessThanOrEqualToAnchor:self.cardControl.trailingAnchor constant:-16],

        /* 日志 / 工作 */
        [self.logBtn.topAnchor     constraintEqualToAnchor:filesTitle.bottomAnchor constant:10],
        [self.logBtn.leadingAnchor constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [self.logBtn.trailingAnchor constraintEqualToAnchor:self.cardControl.centerXAnchor constant:-6],
        [self.logBtn.heightAnchor  constraintEqualToConstant:48],

        [self.workBtn.topAnchor     constraintEqualToAnchor:self.logBtn.topAnchor],
        [self.workBtn.leadingAnchor constraintEqualToAnchor:self.cardControl.centerXAnchor constant:6],
        [self.workBtn.trailingAnchor constraintEqualToAnchor:self.cardControl.trailingAnchor constant:-16],
        [self.workBtn.heightAnchor  constraintEqualToConstant:48],

        [self.workBtn.bottomAnchor constraintEqualToAnchor:self.cardControl.bottomAnchor constant:-16],
    ]];
}

- (UIButton *)buildBigButton:(NSString *)title bg:(UIColor *)bg fg:(UIColor *)fg {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    [b setTitleColor:[fg colorWithAlphaComponent:0.5] forState:UIControlStateHighlighted];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = AT_BUTTON_RADIUS;
    b.layer.masksToBounds = YES;
    return b;
}

#pragma mark - 数据刷新

- (void)refreshAll {
    BOOL running = [self.serviceState isEqualToString:@"已启动"];
    self.statusText.text = running ? @"服务已启动" : @"服务已停止";
    self.statusText.textColor = running ? ATGreen() : ATRed();
    self.statusDot.backgroundColor = running ? ATGreen() : ATRed();

    self.versionText.text = [NSString stringWithFormat:@"版本: %@", self.serviceVersion ?: @"-"];
    self.ipText.text = [NSString stringWithFormat:@"IP: %@", self.localIP ?: @"-"];

    NSString *port = self.httpPort > 0 ? [NSString stringWithFormat:@"HTTP 服务端口: %ld", (long)self.httpPort] : @"HTTP 服务端口: -";
    self.portText.text = port;

    self.devName.text   = [NSString stringWithFormat:@"设备名称:   %@", self.deviceName  ?: @"-"];
    self.devOS.text     = [NSString stringWithFormat:@"系统版本:   %@", self.deviceOS    ?: @"-"];
    self.devModel.text  = [NSString stringWithFormat:@"设备型号:   %@", self.deviceModel ?: @"-"];
    self.devScreen.text = [NSString stringWithFormat:@"屏幕尺寸:   %@", self.screenSize  ?: @"-"];
}

- (void)setServiceState:(NSString *)s { _serviceState = [s copy]; [self refreshAll]; }

#pragma mark - 按钮回调

- (void)didTapStart       { if (self.onTapStart)         self.onTapStart(); }
- (void)didTapStop        { if (self.onTapStop)          self.onTapStop(); }
- (void)didTapRefresh     { if (self.onTapRefreshStatus) self.onTapRefreshStatus(); }
- (void)didTapRefreshIP   { if (self.onTapRefreshIP)     self.onTapRefreshIP(); }
- (void)didTapLog         { if (self.onTapLogDir)        self.onTapLogDir(); }
- (void)didTapWork        { if (self.onTapWorkDir)       self.onTapWorkDir(); }

@end
