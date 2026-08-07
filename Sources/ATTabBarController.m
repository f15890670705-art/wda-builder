//
// ATTabBarController.m
// 自定义底部 TabBar（控制面板 / 服务管理）—— 用 SF Symbols 图标
//
#import "ATTabBarController.h"
#import "UITheme.h"

@interface ATTabBarController ()
@property (nonatomic, strong) NSArray<UIViewController *> *viewControllers;
@property (nonatomic, strong) NSArray<NSString *> *titles;
@property (nonatomic, strong) NSArray<NSString *> *symbolNames;
@property (nonatomic, strong) NSMutableArray<UIButton *> *tabButtons;
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
        _tabButtons = [NSMutableArray array];
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

    /* 按钮 */
    NSInteger n = self.viewControllers.count;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 0;
    [self.tabBar addSubview:stack];

    for (NSInteger i = 0; i < n; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:self.titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        b.titleLabel.numberOfLines = 1;
        b.titleLabel.textAlignment = NSTextAlignmentCenter;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        b.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        UIImage *img = [self symbolImage:self.symbolNames[i] size:24 color:nil];
        [b setImage:img forState:UIControlStateNormal];
        b.tintColor = ATSubText();
        b.tag = i;
        [b addTarget:self action:@selector(switchTab:) forControlEvents:UIControlEventTouchUpInside];
        /* 上下排版：image 在上、title 在下 */
        CGSize imSize = img.size;
        CGFloat titleW = [b.titleLabel intrinsicContentSize].width;
        if (titleW < 50) titleW = 50;
        CGFloat spacing = 4;
        b.imageEdgeInsets = UIEdgeInsetsMake(-(titleW/2 + spacing/2), titleW/2 - imSize.width/2, 0, 0);
        b.titleEdgeInsets = UIEdgeInsetsMake(imSize.height + spacing, -imSize.width, 0, 0);
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

        [stack.topAnchor      constraintEqualToAnchor:self.tabBar.topAnchor constant:8],
        [stack.leadingAnchor  constraintEqualToAnchor:self.tabBar.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.tabBar.trailingAnchor],
        [stack.bottomAnchor   constraintEqualToAnchor:self.tabBar.bottomAnchor constant:-2],
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
        UIColor *c = sel ? ATBlue() : ATSubText();
        [b setTitleColor:c forState:UIControlStateNormal];
        b.tintColor = c;
        UIImage *img = [self symbolImage:self.symbolNames[j] size:24 color:c];
        [b setImage:img forState:UIControlStateNormal];
    }
}

- (void)switchTab:(UIButton *)sender {
    [self setSelectedIndex:sender.tag animated:YES];
}

@end
