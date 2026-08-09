//
// FloatingBall.m
//
#import "FloatingBall.h"

@implementation FloatingBall {
    UIImageView *_icon;
    UIPanGestureRecognizer *_pan;
    UITapGestureRecognizer *_tap;
    CGPoint _lastPos;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];

        /* 圆形底 */
        UIView *circle = [UIView new];
        circle.translatesAutoresizingMaskIntoConstraints = NO;
        circle.backgroundColor = [UIColor systemBlueColor];
        circle.layer.cornerRadius = self.bounds.size.width / 2;
        /* ★ v1.8.20 阴影改极淡 + 静态 shadowPath：①黑圈消失（用户反馈）；
           ②shadowPath 固定后阴影不再每帧重算，渲染开销大降（卡顿源之一） */
        circle.layer.shadowColor = [UIColor blackColor].CGColor;
        circle.layer.shadowOpacity = 0.06;
        circle.layer.shadowRadius = 1.5;
        circle.layer.shadowOffset = CGSizeMake(0, 1);
        circle.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:
            CGRectInset(self.bounds, 1, 1)].CGPath;
        circle.userInteractionEnabled = NO;
        [self addSubview:circle];

        /* ⚠️ 持续渲染保活：SpringBoard 托管的窗口 context 在【无渲染活动】时会被
           系统回收 → 悬浮球消失。★ v1.8.20 改用【透明度呼吸】（opacity 0.98↔1.0，
           视觉不可察觉）替代【阴影呼吸】——阴影呼吸 = 黑圈 + 阴影每帧重算 = 卡顿。
           透明度动画同样触发 CA 每帧渲染，保活效果不变。 */
        CABasicAnimation *breath = [CABasicAnimation animationWithKeyPath:@"opacity"];
        breath.fromValue = @(1.0);
        breath.toValue = @(0.96);
        breath.duration = 2.0;
        breath.autoreverses = YES;
        breath.repeatCount = INFINITY;
        [circle.layer addAnimation:breath forKey:@"breath"];

        /* 图标：AilinTouch 的 A */
        _icon = [UIImageView new];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        if (@available(iOS 13.0, *)) {
            _icon.image = [UIImage systemImageNamed:@"hand.tap.fill"
                                      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium]];
        }
        _icon.tintColor = [UIColor whiteColor];
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.userInteractionEnabled = NO;
        [self addSubview:_icon];

        [NSLayoutConstraint activateConstraints:@[
            [circle.topAnchor constraintEqualToAnchor:self.topAnchor],
            [circle.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [circle.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [circle.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

            [_icon.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_icon.widthAnchor constraintEqualToConstant:26],
            [_icon.heightAnchor constraintEqualToConstant:26],
        ]];

        /* 拖动 */
        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:_pan];

        /* 点击 */
        _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        _tap.numberOfTapsRequired = 1;
        [self addGestureRecognizer:_tap];
        [_tap requireGestureRecognizerToFail:_pan];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *win = self.window;
    if (g.state == UIGestureRecognizerStateBegan) {
        _lastPos = self.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.superview];
        CGPoint c = CGPointMake(_lastPos.x + t.x, _lastPos.y + t.y);

        /* 限制在屏幕内 */
        if (win) {
            CGFloat m = self.bounds.size.width / 2;
            c.x = MAX(m, MIN(c.x, win.bounds.size.width - m));
            c.y = MAX(m, MIN(c.y, win.bounds.size.height - m));
        }
        self.center = c;
    } else if (g.state == UIGestureRecognizerStateEnded) {
        /* 吸附到左右边缘（懒人同款） */
        if (win) {
            CGPoint c = self.center;
            CGFloat m = self.bounds.size.width / 2;
            BOOL left = c.x < win.bounds.size.width / 2;
            [UIView animateWithDuration:0.2 animations:^{
                self.center = CGPointMake(left ? m : win.bounds.size.width - m, c.y);
            }];
        }
    }
}

- (void)handleTap {
    /* 前台：ball 手势直接命中 → 清掉引擎监听写的文件，避免和轮询重复触发 */
    [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/ailintouch.touch" error:nil];
    if (self.onTap) self.onTap();
}

@end