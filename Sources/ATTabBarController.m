//
// ATTabBarController.m
// 自定义底部 TabBar（控制面板 / 服务管理）
//
#import "ATTabBarController.h"
#import "UITheme.h"

@interface ATTabBarController ()
@property (nonatomic, strong) NSArray<UIViewController *> *viewControllers;
@property (nonatomic, strong) NSArray<NSString *> *titles;
@property (nonatomic, strong) NSMutableArray<UIButton *> *tabButtons;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, strong) UIView *tabBar;
@end

@implementation ATTabBarController

- (instancetype)initWithViewControllers:(NSArray *)vcs titles:(NSArray *)titles {
    if ((self = [super init])) {
        _viewControllers = vcs;
        _titles = titles;
        _selectedIndex = 0;
        _tabButtons = [NSMutableArray array];
    }
    return self;
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

    /* 按钮 */
    NSInteger n = self.viewControllers.count;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.alignment = UIStackViewAlignmentFill;
    [self.tabBar addSubview:stack];

    for (NSInteger i = 0; i < n; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:self.titles[i] forState:UIControlStateNormal];
        [b.titleLabel setFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]];
        b.titleLabel.numberOfLines = 2;
        b.titleLabel.textAlignment = NSTextAlignmentCenter;
        b.tintColor = ATSubText();
        b.tag = i;
        [b addTarget:self action:@selector(switchTab:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:b];
        [self.tabButtons addObject:b];

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
        UIButton *b = self.tabButtons[j];
        [b setTitleColor:(sel ? ATBlue() : ATSubText()) forState:UIControlStateNormal];
    }
}

- (void)switchTab:(UIButton *)sender {
    [self setSelectedIndex:sender.tag animated:YES];
}

@end
