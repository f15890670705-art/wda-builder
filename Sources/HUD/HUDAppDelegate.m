//
// HUDAppDelegate.m
//
// AilinHUD 进程入口。
// ★★ 核心机制（照 AutoGo agoverlayd / FrontBoardAppLauncher 开源实现）：
//    不依赖 UIKit 自动分配 scene（裸 spawn 进程拿不到），而是用
//    FBSceneManager 手动创建 FrontBoard 场景 + UIRootWindowScenePresentationBinder
//    把 UIWindow 直接绑定到系统场景 → 全局悬浮 + 后台可点 + 卸载 App 球还在。
//    所有私有 API 用 objc_msgSend 动态调用（编译期无声明，避免报错）。
//
#import "HUDAppDelegate.h"
#import "HUDBall.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

/* 诊断辅助：写 /tmp/ailintouch_hud.alive，引擎 /hud 端点远程读 */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@implementation HUDAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    hud_mark(@"appdelegate");

    /* 1. 加载私有框架 */
    void *fbs = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    void *ui  = dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW);
    if (!fbs || !ui) {
        hud_mark(@"dlopen-fail");
        return YES;
    }

    /* 2. 显示配置（主屏） */
    Class fbDisplayMgr = NSClassFromString(@"FBDisplayManager");
    id displayConfig = ((id (*)(id, SEL))objc_msgSend)(fbDisplayMgr, sel_registerName("mainConfiguration"));
    if (!displayConfig) {
        hud_mark(@"display-config-nil");
        return YES;
    }

    /* 3. UIRootWindowScenePresentationBinder —— 把窗口绑定到系统场景的关键 */
    Class binderCls = NSClassFromString(@"UIRootWindowScenePresentationBinder");
    id binder = ((id (*)(id, SEL, int, id))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(binderCls, sel_registerName("alloc")),
        sel_registerName("initWithPriority:displayConfiguration:"), 0, displayConfig);
    if (!binder) {
        hud_mark(@"binder-nil");
        return YES;
    }

    /* 4. 场景定义（identity = bundle id，client = local） */
    Class defCls = NSClassFromString(@"FBSMutableSceneDefinition");
    id definition = ((id (*)(id, SEL))objc_msgSend)(defCls, sel_registerName("definition"));
    Class identityCls = NSClassFromString(@"FBSSceneIdentity");
    id identity = ((id (*)(id, SEL, id))objc_msgSend)(identityCls,
        sel_registerName("identityForIdentifier:"), @"com.ailintouch.hud");
    Class clientIdCls = NSClassFromString(@"FBSSceneClientIdentity");
    id clientId = ((id (*)(id, SEL))objc_msgSend)(clientIdCls, sel_registerName("localIdentity"));
    Class specCls = NSClassFromString(@"UIApplicationSceneSpecification");
    id spec = ((id (*)(id, SEL))objc_msgSend)(specCls, sel_registerName("specification"));
    ((void (*)(id, SEL, id))objc_msgSend)(definition, sel_registerName("setIdentity:"), identity);
    ((void (*)(id, SEL, id))objc_msgSend)(definition, sel_registerName("setClientIdentity:"), clientId);
    ((void (*)(id, SEL, id))objc_msgSend)(definition, sel_registerName("setSpecification:"), spec);

    /* 5. 场景参数（全屏 + foreground + 忽略遮挡） */
    Class paramsCls = NSClassFromString(@"FBSMutableSceneParameters");
    id parameters = ((id (*)(id, SEL, id))objc_msgSend)(paramsCls,
        sel_registerName("parametersForSpecification:"), spec);
    Class settingsCls = NSClassFromString(@"UIMutableApplicationSceneSettings");
    id settings = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(settingsCls, sel_registerName("alloc")),
        sel_registerName("init"));
    ((void (*)(id, SEL, id))objc_msgSend)(settings, sel_registerName("setDisplayConfiguration:"), displayConfig);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, sel_registerName("setForeground:"), YES);
    ((void (*)(id, SEL, int))objc_msgSend)(settings, sel_registerName("setInterfaceOrientation:"), 1);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, sel_registerName("setDeviceOrientationEventsEnabled:"), YES);
    /* ignoreOcclusionReasons 加 SystemApp：不被系统元素遮挡 */
    id ignoreReasons = ((id (*)(id, SEL))objc_msgSend)(settings, sel_registerName("ignoreOcclusionReasons"));
    if (ignoreReasons && [ignoreReasons respondsToSelector:@selector(addObject:)]) {
        [ignoreReasons addObject:@"SystemApp"];
    }
    ((void (*)(id, SEL, id))objc_msgSend)(parameters, sel_registerName("setSettings:"), settings);

    Class clientSettingsCls = NSClassFromString(@"UIMutableApplicationSceneClientSettings");
    id clientSettings = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(clientSettingsCls, sel_registerName("alloc")),
        sel_registerName("init"));
    ((void (*)(id, SEL, int))objc_msgSend)(clientSettings, sel_registerName("setInterfaceOrientation:"), 1);
    ((void (*)(id, SEL, int))objc_msgSend)(clientSettings, sel_registerName("setStatusBarStyle:"), 0);
    ((void (*)(id, SEL, id))objc_msgSend)(parameters, sel_registerName("setClientSettings:"), clientSettings);

    /* 6. FBSceneManager 创建场景 */
    Class sceneMgrCls = NSClassFromString(@"FBSceneManager");
    id sceneMgr = ((id (*)(id, SEL))objc_msgSend)(sceneMgrCls, sel_registerName("sharedInstance"));
    id scene = ((id (*)(id, SEL, id, id))objc_msgSend)(sceneMgr,
        sel_registerName("createSceneWithDefinition:initialParameters:"), definition, parameters);
    if (!scene) {
        hud_mark(@"scene-nil");
        return YES;
    }

    /* 7. 绑定到窗口展示 */
    ((void (*)(id, SEL, id))objc_msgSend)(binder, sel_registerName("addScene:"), scene);
    hud_mark(@"scene-bound");

    /* 8. 全屏透明窗口 */
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor clearColor];
    self.window.windowLevel = 10000.0;   /* FrontBoardAppLauncher 同款 high level */

    /* ⭐ AutoGo agoverlayd 同款私有属性（后台可点关键） */
    @try {
        [self.window setValue:@YES forKey:@"_usesWindowServerHitTesting"];
        [self.window setValue:@YES forKey:@"_canShowWhileLocked"];
        [self.window setValue:@YES forKey:@"ignoreOcclusionReasons"];
    } @catch (NSException *e) {
        NSLog(@"[AilinHUD] private window props set failed: %@", e);
    }

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

    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {}
- (void)applicationDidEnterBackground:(UIApplication *)application {}

@end
