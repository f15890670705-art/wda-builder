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

#pragma mark - 设备信息行（key + value）

@interface ATInfoRow : UIView
@property (nonatomic, strong) UILabel *keyLabel;
@property (nonatomic, strong) UILabel *valueLabel;
- (instancetype)initWithKey:(NSString *)key;
@end
@implementation ATInfoRow
- (instancetype)initWithKey:(NSString *)key {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _keyLabel = [UILabel new];
        _keyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _keyLabel.text = key;
        _keyLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        _keyLabel.textColor = ATSubText();
        _keyLabel.textAlignment = NSTextAlignmentLeft;
        [self addSubview:_keyLabel];

        _valueLabel = [UILabel new];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel.text = @"-";
        _valueLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _valueLabel.textColor = ATText();
        _valueLabel.textAlignment = NSTextAlignmentLeft;
        _valueLabel.adjustsFontSizeToFitWidth = YES;
        _valueLabel.minimumScaleFactor = 0.7;
        [self addSubview:_valueLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_keyLabel.topAnchor      constraintEqualToAnchor:self.topAnchor],
            [_keyLabel.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
            [_keyLabel.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
            [_keyLabel.widthAnchor    constraintEqualToConstant:84],

            [_valueLabel.topAnchor    constraintEqualToAnchor:self.topAnchor],
            [_valueLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_valueLabel.leadingAnchor  constraintEqualToAnchor:_keyLabel.trailingAnchor constant:8],
            [_valueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];
    }
    return self;
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

@property (nonatomic, strong) ATInfoRow *devName;
@property (nonatomic, strong) ATInfoRow *devOS;
@property (nonatomic, strong) ATInfoRow *devModel;
@property (nonatomic, strong) ATInfoRow *devScreen;

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
    UILabel *ipLabel = [UILabel new];
    ipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    ipLabel.text = @"本地 IP";
    ipLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    ipLabel.textColor = ATSubText();
    [self.cardStatus addSubview:ipLabel];

    self.ipText = [UILabel new];
    self.ipText.translatesAutoresizingMaskIntoConstraints = NO;
    self.ipText.text = @"-";
    self.ipText.textColor = ATText();
    self.ipText.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
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

        [ipLabel.topAnchor     constraintEqualToAnchor:line.bottomAnchor constant:14],
        [ipLabel.leadingAnchor constraintEqualToAnchor:self.cardStatus.leadingAnchor constant:16],
        [ipLabel.widthAnchor   constraintEqualToConstant:84],

        [self.ipText.topAnchor     constraintEqualToAnchor:ipLabel.topAnchor],
        [self.ipText.leadingAnchor constraintEqualToAnchor:ipLabel.trailingAnchor constant:8],
        [self.ipText.trailingAnchor constraintLessThanOrEqualToAnchor:self.refreshIpBtn.leadingAnchor constant:-8],

        [self.refreshIpBtn.centerYAnchor constraintEqualToAnchor:ipLabel.centerYAnchor],
        [self.refreshIpBtn.trailingAnchor constraintEqualToAnchor:self.cardStatus.trailingAnchor constant:-16],

        [self.portText.topAnchor     constraintEqualToAnchor:ipLabel.bottomAnchor constant:8],
        [self.portText.leadingAnchor constraintEqualToAnchor:self.cardStatus.leadingAnchor constant:16],
        [self.portText.bottomAnchor  constraintEqualToAnchor:self.cardStatus.bottomAnchor constant:-16],
    ]];
}

- (void)buildCardDevice {
    ATChipBadge *badge = [ATChipBadge badgeWithText:@"  设备信息  " fg:ATGreen() bg:ATGreenBg()];
    [self.cardDevice addSubview:badge];

    self.devName   = [[ATInfoRow alloc] initWithKey:@"设备名称"];
    self.devOS     = [[ATInfoRow alloc] initWithKey:@"系统版本"];
    self.devModel  = [[ATInfoRow alloc] initWithKey:@"设备型号"];
    self.devScreen = [[ATInfoRow alloc] initWithKey:@"屏幕尺寸"];
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
        [self.devName.trailingAnchor constraintEqualToAnchor:self.cardDevice.trailingAnchor constant:-16],
        [self.devName.heightAnchor  constraintEqualToConstant:24],

        [self.devOS.topAnchor     constraintEqualToAnchor:self.devName.bottomAnchor constant:10],
        [self.devOS.leadingAnchor constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16],
        [self.devOS.trailingAnchor constraintEqualToAnchor:self.cardDevice.trailingAnchor constant:-16],
        [self.devOS.heightAnchor  constraintEqualToConstant:24],

        [self.devModel.topAnchor     constraintEqualToAnchor:self.devOS.bottomAnchor constant:10],
        [self.devModel.leadingAnchor constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16],
        [self.devModel.trailingAnchor constraintEqualToAnchor:self.cardDevice.trailingAnchor constant:-16],
        [self.devModel.heightAnchor  constraintEqualToConstant:24],

        [self.devScreen.topAnchor     constraintEqualToAnchor:self.devModel.bottomAnchor constant:10],
        [self.devScreen.leadingAnchor constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16],
        [self.devScreen.trailingAnchor constraintEqualToAnchor:self.cardDevice.trailingAnchor constant:-16],
        [self.devScreen.heightAnchor  constraintEqualToConstant:24],
        [self.devScreen.bottomAnchor  constraintEqualToAnchor:self.cardDevice.bottomAnchor constant:-16],
    ]];
}

- (void)buildCardControl {
    ATChipBadge *badge = [ATChipBadge badgeWithText:@"  服务控制  " fg:ATPurple() bg:ATPurpleBg()];
    [self.cardControl addSubview:badge];

    /* 启动 / 停止：UIStackView 等分两半 */
    self.startBtn = [self buildBigButton:@"启动服务" bg:ATGreenBg() fg:ATGreen()];
    self.stopBtn  = [self buildBigButton:@"停止服务" bg:ATRedBg() fg:ATRed()];
    [self.startBtn addTarget:self action:@selector(didTapStart) forControlEvents:UIControlEventTouchUpInside];
    [self.stopBtn  addTarget:self action:@selector(didTapStop)  forControlEvents:UIControlEventTouchUpInside];

    UIStackView *startStopRow = [UIStackView new];
    startStopRow.translatesAutoresizingMaskIntoConstraints = NO;
    startStopRow.axis = UILayoutConstraintAxisHorizontal;
    startStopRow.distribution = UIStackViewDistributionFillEqually;
    startStopRow.alignment = UIStackViewAlignmentFill;
    startStopRow.spacing = 12;
    [startStopRow addArrangedSubview:self.startBtn];
    [startStopRow addArrangedSubview:self.stopBtn];
    [self.cardControl addSubview:startStopRow];

    /* 刷新状态：单独居中 */
    UIStackView *refreshWrap = [UIStackView new];
    refreshWrap.translatesAutoresizingMaskIntoConstraints = NO;
    refreshWrap.axis = UILayoutConstraintAxisHorizontal;
    refreshWrap.distribution = UIStackViewDistributionFillEqually;
    refreshWrap.alignment = UIStackViewAlignmentFill;
    refreshWrap.spacing = 12;
    [refreshWrap addArrangedSubview:[UIView new]];   /* 左侧占位 */
    self.refreshBtn = [self buildBigButton:@"刷新状态" bg:ATBlueBg() fg:ATBlue()];
    [self.refreshBtn addTarget:self action:@selector(didTapRefresh) forControlEvents:UIControlEventTouchUpInside];
    [refreshWrap addArrangedSubview:self.refreshBtn];
    [refreshWrap addArrangedSubview:[UIView new]];   /* 右侧占位 */
    [self.cardControl addSubview:refreshWrap];

    /* 文件浏览器小标题 */
    UILabel *filesTitle = [UILabel new];
    filesTitle.translatesAutoresizingMaskIntoConstraints = NO;
    filesTitle.text = @"文件浏览器";
    filesTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    filesTitle.textColor = ATText();
    [self.cardControl addSubview:filesTitle];

    /* 日志 / 工作 目录：等分两半 */
    self.logBtn  = [self buildBigButton:@"📁  日志目录" bg:ATGreen() fg:[UIColor whiteColor]];
    self.workBtn = [self buildBigButton:@"📁  工作目录" bg:ATBrown() fg:[UIColor whiteColor]];
    [self.logBtn  addTarget:self action:@selector(didTapLog)  forControlEvents:UIControlEventTouchUpInside];
    [self.workBtn addTarget:self action:@selector(didTapWork) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *fileRow = [UIStackView new];
    fileRow.translatesAutoresizingMaskIntoConstraints = NO;
    fileRow.axis = UILayoutConstraintAxisHorizontal;
    fileRow.distribution = UIStackViewDistributionFillEqually;
    fileRow.alignment = UIStackViewAlignmentFill;
    fileRow.spacing = 12;
    [fileRow addArrangedSubview:self.logBtn];
    [fileRow addArrangedSubview:self.workBtn];
    [self.cardControl addSubview:fileRow];

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor      constraintEqualToAnchor:self.cardControl.topAnchor constant:16],
        [badge.leadingAnchor  constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [badge.heightAnchor   constraintEqualToConstant:26],

        /* 启动/停止 — 等分 */
        [startStopRow.topAnchor      constraintEqualToAnchor:badge.bottomAnchor constant:14],
        [startStopRow.leadingAnchor  constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [startStopRow.trailingAnchor constraintEqualToAnchor:self.cardControl.trailingAnchor constant:-16],
        [startStopRow.heightAnchor   constraintEqualToConstant:48],

        /* 刷新状态 — 居中 */
        [refreshWrap.topAnchor      constraintEqualToAnchor:startStopRow.bottomAnchor constant:12],
        [refreshWrap.leadingAnchor  constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [refreshWrap.trailingAnchor constraintEqualToAnchor:self.cardControl.trailingAnchor constant:-16],
        [refreshWrap.heightAnchor   constraintEqualToConstant:48],

        /* 文件浏览器小标题 */
        [filesTitle.topAnchor     constraintEqualToAnchor:refreshWrap.bottomAnchor constant:18],
        [filesTitle.leadingAnchor constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [filesTitle.trailingAnchor constraintLessThanOrEqualToAnchor:self.cardControl.trailingAnchor constant:-16],

        /* 文件浏览两按钮 — 等分 */
        [fileRow.topAnchor      constraintEqualToAnchor:filesTitle.bottomAnchor constant:10],
        [fileRow.leadingAnchor  constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [fileRow.trailingAnchor constraintEqualToAnchor:self.cardControl.trailingAnchor constant:-16],
        [fileRow.heightAnchor   constraintEqualToConstant:48],
        [fileRow.bottomAnchor   constraintEqualToAnchor:self.cardControl.bottomAnchor constant:-16],
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
    self.ipText.text = self.localIP ?: @"-";

    NSString *port = self.httpPort > 0 ? [NSString stringWithFormat:@"HTTP 服务端口: %ld", (long)self.httpPort] : @"HTTP 服务端口: -";
    self.portText.text = port;

    self.devName.valueLabel.text   = self.deviceName  ?: @"-";
    self.devOS.valueLabel.text     = self.deviceOS    ?: @"-";
    self.devModel.valueLabel.text  = self.deviceModel ?: @"-";
    self.devScreen.valueLabel.text = self.screenSize  ?: @"-";
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
