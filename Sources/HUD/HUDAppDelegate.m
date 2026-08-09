//
// HUDAppDelegate.m
//
// AilinHUD 进程入口（v1.8.1 照懒人 RootCore 反汇编铁证重构）。
//
// ★★ v1.8.1 关键架构：
//   懒人 RootCore（com.nx.RootCore）= 独立 UIApplication 进程（@_UIApplicationMain
//   + FBSceneManager 二进制 scene + UIRootWindowScenePresentationBinder + SBS 注册）。
//   悬浮球 = 独立进程持二进制 FBScene → 不依赖主 App 生命周期 → 全局持久。
//
//   ★ legacy 模式（无 UIApplicationSceneManifest）：UIApplicationMain 不会等
//   scene 连接 → 不卡 booting（v1.5.0 共享主 bundle + SceneManifest 卡死的根因）。
//   窗口在 didFinish 手动创建 + FBSceneManager 手动建二进制 scene + binder 绑定
//   系统 root window 层 → 全局显示。
//
#import "HUDAppDelegate.h"
#import "HUDBall.h"
#import <objc/message.h>

/* 诊断辅助：写 /tmp/ailintouch_hud.alive（引擎 /hud 可读）
   ★ v1.8.34 双写 /tmp/ailintouch_hud.log（引擎 /log?src=hud 可读，带时间戳） */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    @autoreleasepool {
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] [hud] %@\n",
                          [df stringFromDate:[NSDate date]], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ailintouch_hud.log"];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:@"/tmp/ailintouch_hud.log"
                                                    contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ailintouch_hud.log"];
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

@implementation HUDAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    hud_mark(@"appdelegate");

    /* ★ v1.8.1 legacy 模式：窗口手动创建（不依赖 scene:willConnect） */
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor clearColor];
    self.window.windowLevel = 20000002.0;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    self.window.rootViewController = vc;

    /* 悬浮球 */
    CGFloat size = 56;
    CGFloat x = 20;
    CGFloat y = [UIScreen mainScreen].bounds.size.height / 2 - size;
    HUDBall *ball = [[HUDBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
    [vc.view addSubview:ball];

    [self.window makeKeyAndVisible];
    hud_mark(@"window-shown");

    /* ★ v1.8.1 二进制 FBScene（懒人 RootCore 同款）：
       FBSceneManager 手动创建 scene + UIRootWindowScenePresentationBinder 绑定 */
    [self createFrontBoardScene];

    /* SBS 注册 → 全局悬浮 */
    [self registerToSpringBoard];

    return YES;
}

/* ★ v1.8.1 照懒人 RootCore：FBSceneManager 手动创建二进制 scene +
   UIRootWindowScenePresentationBinder 绑定到系统 root window 层。
   全部私有 API objc_msgSend 动态调用，包 @try 防崩。 */
- (void)createFrontBoardScene {
    @try {
        Class mgrCls = NSClassFromString(@"FBSceneManager");
        if (!mgrCls) { hud_mark(@"fb-mgr-missing"); return; }
        id manager = nil;
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if ([mgrCls respondsToSelector:sharedSel]) {
            manager = ((id(*)(id, SEL))objc_msgSend)(mgrCls, sharedSel);
        }
        if (!manager) manager = ((id(*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"new"));
        if (!manager) { hud_mark(@"fb-mgr-fail"); return; }

        Class defCls = NSClassFromString(@"FBSMutableSceneDefinition");
        if (!defCls) { hud_mark(@"fb-def-missing"); return; }
        id def = ((id(*)(id, SEL))objc_msgSend)(defCls, NSSelectorFromString(@"new"));

        Class identCls = NSClassFromString(@"FBSMutableSceneIdentity");
        if (identCls) {
            SEL initSel = NSSelectorFromString(@"initWithBundleIdentifier:");
            id identity = ((id(*)(id, SEL, id))objc_msgSend)(
                ((id(*)(id, SEL))objc_msgSend)(identCls, NSSelectorFromString(@"alloc")),
                initSel, [[NSBundle mainBundle] bundleIdentifier]);
            if (identity) {
                ((void(*)(id, SEL, id))objc_msgSend)(def, NSSelectorFromString(@"setIdentity:"), identity);
            }
        }

        Class paramsCls = NSClassFromString(@"FBSMutableSceneParameters");
        id params = paramsCls ? ((id(*)(id, SEL))objc_msgSend)(paramsCls, NSSelectorFromString(@"new")) : nil;
        if (!params) { hud_mark(@"fb-params-fail"); return; }

        SEL createSel = NSSelectorFromString(@"createSceneWithDefinition:initialParameters:");
        if (![manager respondsToSelector:createSel]) { hud_mark(@"fb-create-no-sel"); return; }
        id fbScene = ((id(*)(id, SEL, id, id))objc_msgSend)(manager, createSel, def, params);
        if (!fbScene) { hud_mark(@"fb-create-fail"); return; }
        hud_mark(@"fb-scene-created");

        Class binderCls = NSClassFromString(@"UIRootWindowScenePresentationBinder");
        if (!binderCls) { hud_mark(@"binder-missing"); return; }
        id binder = ((id(*)(id, SEL))objc_msgSend)(binderCls, NSSelectorFromString(@"new"));
        SEL addSel = NSSelectorFromString(@"addScene:");
        if ([binder respondsToSelector:addSel]) {
            ((void(*)(id, SEL, id))objc_msgSend)(binder, addSel, fbScene);
            hud_mark(@"fb-scene-bound");
        } else {
            hud_mark(@"binder-no-addscene");
        }
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"fb-bind-ex-%@", e.name]);
    }
}

- (unsigned int)windowContextID {
    SEL sel = NSSelectorFromString(@"_contextId");
    if (![self.window respondsToSelector:sel]) return 0;
    NSMethodSignature *sig = [self.window methodSignatureForSelector:sel];
    if (!sig) return 0;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:self.window];
    [inv setSelector:sel];
    [inv invoke];
    if (sig.methodReturnType[0] == '@') {
        __unsafe_unretained id ret = nil;
        [inv getReturnValue:&ret];
        if (ret && [ret isKindOfClass:[NSNumber class]]) {
            return [ret unsignedIntValue];
        }
        return 0;
    }
    if (sig.methodReturnLength == 4) {
        unsigned int v = 0;
        [inv getReturnValue:&v];
        return v;
    }
    return 0;
}

static int g_register_attempts = 0;

- (void)registerToSpringBoard {
    unsigned int cid = [self windowContextID];
    if (cid == 0) {
        if (g_register_attempts++ < 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self registerToSpringBoard];
            });
        }
        return;
    }
    g_register_attempts = 0;
    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!cls) {
        hud_mark(@"sbs-class-missing");
        return;
    }
    id ctrl = ((id(*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"new"));
    SEL regSel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if ([ctrl respondsToSelector:regSel]) {
        NSMethodSignature *sig = [ctrl methodSignatureForSelector:regSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:ctrl];
            [inv setSelector:regSel];
            [inv setArgument:&cid atIndex:2];
            double level = (double)self.window.windowLevel;
            [inv setArgument:&level atIndex:3];
            [inv invoke];
            NSLog(@"[AilinHUD] registered cid=%u", cid);
            hud_mark([NSString stringWithFormat:@"registered-cid=%u", cid]);
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.apple.hudservices.windowRegistered"), NULL, NULL, true);
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.apple.springboard.hudwindow.registered"), NULL, NULL, true);
        }
    }
}

- (void)applicationWillResignActive:(UIApplication *)application {}
- (void)applicationDidEnterBackground:(UIApplication *)application {}

@end
