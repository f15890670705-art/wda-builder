//
// ATTabBarController.m
// 自定义底部 TabBar（控制面板 / 服务管理）—— 子视图堆叠图标+文字
//
#import "ATTabBarController.h"
#import "UITheme.h"

@interface ATTabBarController ()
@property (nonatomic, strong) NSArray<UIViewController *> *viewControllers;
@property (nonatomic, strong) NSArray<NSString *> *titles;
@property (nonatomic, strong) NSArray<NSString *> *symbolNames;
@property (nonatomic, strong) NSMutableArray<UIView *> *tabItemViews;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *tabIcons;
@property (nonatomic, strong) NSMutableArray<UILabel *> *tabLabels;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, strong) UIView *tabBar;
@end

@implementation ATTabBarController

- (instancetype)initWithViewControllers:(NSArray *)vcs titles:(NSArray *)titles symbols:(NSArray *)symbols {
    if ((self = [super init])) {
        _viewControllers = vcs;
        _titles = titles;
        _symbolNames = symbols;
        _selectedIndex = 0;
        _tabItemViews = [NSMutableArray array];
        _tabIcons = [NSMutableArray array];
        _tabLabels = [NSMutableArray array];
    }
    return self;
}

- (UIImage *)symbolImage:(NSString *)name size:(CGFloat)size color:(UIColor *)color {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
        if (img && color) {
            img = [img imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
        }
        return img;
    }
    return nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ATBg();

    /* container 区域 */
    UIView *container = [UIView new];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.backgroundColor = ATBg();
    [self.view addSubview:container];

    /* 底部 TabBar */
    self.tabBar = [UIView new];
    self.tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabBar.backgroundColor = [UIColor whiteColor];
    [self.view addSubview:self.tabBar];

    /* 顶部一根细线 */
    UIView *line = [UIView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = ATDivider();
    [self.tabBar addSubview:line];

    /* 每个 Tab 自己占一个 UIStackView 轴上的格子 */
    NSInteger n = self.viewControllers.count;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 0;
    [self.tabBar addSubview:stack];

    for (NSInteger i = 0; i < n; i++) {
        /* 容器 view 包整块，点击触发 switch */
        UIControl *containerView = [UIControl new];
        containerView.translatesAutoresizingMaskIntoConstraints = NO;
        containerView.tag = i;
        [containerView addTarget:self action:@selector(switchTab:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:containerView];
        [self.tabItemViews addObject:containerView];

        /* 内部分上图标下文字 */
        UIStackView *col = [UIStackView new];
        col.translatesAutoresizingMaskIntoConstraints = NO;
        col.axis = UILayoutConstraintAxisVertical;
        col.alignment = UIStackViewAlignmentCenter;
        col.distribution = UIStackViewDistributionFill;
        col.spacing = 4;
        col.userInteractionEnabled = NO;     /* 不吃 hitTest，让 UIControl 接收 */
        [containerView addSubview:col];

        UIImageView *icon = [UIImageView new];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.image = [self symbolImage:self.symbolNames[i] size:24 color:ATSubText()];
        icon.userInteractionEnabled = NO;     /* 不吃 hitTest，让 UIControl 接收 */
        [icon.widthAnchor constraintEqualToConstant:28].active = YES;
        [icon.heightAnchor constraintEqualToConstant:28].active = YES;
        [self.tabIcons addObject:icon];
        [col addArrangedSubview:icon];

        UILabel *label = [UILabel new];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = self.titles[i];
        label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        label.textAlignment = NSTextAlignmentCenter;
        label.userInteractionEnabled = NO;     /* 同上 */
        [self.tabLabels addObject:label];
        [col addArrangedSubview:label];

        [NSLayoutConstraint activateConstraints:@[
            [col.centerXAnchor constraintEqualToAnchor:containerView.centerXAnchor],
            [col.topAnchor     constraintEqualToAnchor:containerView.topAnchor constant:8],
            [col.bottomAnchor  constraintEqualToAnchor:containerView.bottomAnchor constant:-4],
            [col.leadingAnchor  constraintGreaterThanOrEqualToAnchor:containerView.leadingAnchor constant:4],
            [col.trailingAnchor constraintLessThanOrEqualToAnchor:containerView.trailingAnchor constant:-4],
        ]];

        /* 把 VC 的 view 加到 container */
        UIViewController *vc = self.viewControllers[i];
        vc.view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:vc.view];
        [self addChildViewController:vc];
        [vc didMoveToParentViewController:self];
        [NSLayoutConstraint activateConstraints:@[
            [vc.view.topAnchor      constraintEqualToAnchor:container.topAnchor],
            [vc.view.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor],
            [vc.view.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor],
            [vc.view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        ]];
    }

    /* constraints */
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor      constraintEqualToAnchor:self.view.topAnchor],
        [container.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [container.bottomAnchor   constraintEqualToAnchor:self.tabBar.topAnchor],

        [self.tabBar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tabBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tabBar.bottomAnchor   constraintEqualToAnchor:g.bottomAnchor],
        [self.tabBar.heightAnchor   constraintGreaterThanOrEqualToConstant:64],

        [line.topAnchor      constraintEqualToAnchor:self.tabBar.topAnchor],
        [line.leadingAnchor  constraintEqualToAnchor:self.tabBar.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:self.tabBar.trailingAnchor],
        [line.heightAnchor   constraintEqualToConstant:0.5],

        [stack.topAnchor      constraintEqualToAnchor:self.tabBar.topAnchor],
        [stack.leadingAnchor  constraintEqualToAnchor:self.tabBar.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.tabBar.trailingAnchor],
        [stack.bottomAnchor   constraintEqualToAnchor:self.tabBar.bottomAnchor],
    ]];

    [self setSelectedIndex:0 animated:NO];
}

- (void)setSelectedIndex:(NSInteger)i animated:(BOOL)animated {
    _selectedIndex = i;
    for (NSInteger j = 0; j < self.viewControllers.count; j++) {
        BOOL sel = (j == i);
        UIViewController *vc = self.viewControllers[j];
        vc.view.alpha = sel ? 1.0 : 0.0;
        vc.view.userInteractionEnabled = sel;
        UIColor *c = sel ? ATBlue() : ATSubText();
        UIImageView *icon = self.tabIcons[j];
        UILabel *label = self.tabLabels[j];
        icon.image = [self symbolImage:self.symbolNames[j] size:24 color:c];
        label.textColor = c;
    }
}

- (void)switchTab:(UIControl *)sender {
    [self setSelectedIndex:sender.tag animated:YES];
}

@end
