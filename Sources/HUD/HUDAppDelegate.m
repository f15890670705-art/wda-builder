//
// HUDAppDelegate.m
//
// AilinHUD 进程入口。
// ★★ 核心机制（照 AutoGo agoverlayd / FrontBoardAppLauncher 开源实现）：
//    不依赖 UIKit 自动分配 scene（裸 spawn 进程拿不到），而是用
//    FBSceneManager 手动创建 FrontBoard 场景 + UIRootWindowScenePresentationBinder
//    把 UIWindow 直接绑定到系统场景 → 全局悬浮 + 后台可点 + 卸载 App 球还在。
//
#import "HUDAppDelegate.h"
#import "HUDBall.h"
#import <dlfcn.h>

/* 诊断辅助：写 /tmp/ailintouch_hud.alive，引擎 /hud 端点远程读 */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@implementation HUDAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    hud_mark(@"appdelegate");

    /* 1. 解析 FrontBoardServices + UIKitCore 私有符号 */
    void *fbs = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    void *ui = dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW);
    if (!fbs || !ui) {
        hud_mark(@"dlopen-fail");
        return YES;
    }

    /* 2. 显示配置（主屏） */
    id (*FBDisplayManager_mainConfiguration)(Class, SEL) = (void *)dlsym(fbs, "objc_msgSend");
    Class fbDisplayMgr = NSClassFromString(@"FBDisplayManager");
    id displayConfig = ((id (*)(id, SEL))objc_msgSend)(fbDisplayMgr, sel_registerName("mainConfiguration"));

    /* 3. UIRootWindowScenePresentationBinder —— 把窗口绑定到系统场景的关键 */
    Class binderCls = NSClassFromString(@"UIRootWindowScenePresentationBinder");
    id binder = [[binderCls alloc] initWithPriority:0 displayConfiguration:displayConfig];
    if (!binder) {
        hud_mark(@"binder-nil");
        return YES;
    }

    /* 4. 场景定义（identity = bundle id，client = local） */
    Class defCls = NSClassFromString(@"FBSMutableSceneDefinition");
    id definition = [defCls definition];
    id identity = [NSClassFromString(@"FBSSceneIdentity") identityForIdentifier:@"com.ailintouch.hud"];
    id clientId = [NSClassFromString(@"FBSSceneClientIdentity") localIdentity];
    id spec = [NSClassFromString(@"UIApplicationSceneSpecification") specification];
    [definition setIdentity:identity];
    [definition setClientIdentity:clientId];
    [definition setSpecification:spec];

    /* 5. 场景参数（全屏 + foreground + 忽略遮挡） */
    id parameters = [NSClassFromString(@"FBSMutableSceneParameters") parametersForSpecification:spec];
    id settings = [NSClassFromString(@"UIMutableApplicationSceneSettings") new];
    [settings setDisplayConfiguration:displayConfig];
    [settings setFrame:[UIScreen mainScreen].bounds];
    [settings setForeground:YES];
    [settings setInterfaceOrientation:1];   /* portrait */
    [settings setDeviceOrientationEventsEnabled:YES];
    /* ignoreOcclusionReasons 加 SystemApp：不被系统元素遮挡 */
    id ignoreReasons = [settings valueForKey:@"ignoreOcclusionReasons"];
    if (ignoreReasons && [ignoreReasons respondsToSelector:@selector(addObject:)]) {
        [ignoreReasons addObject:@"SystemApp"];
    }
    [parameters setSettings:settings];

    id clientSettings = [NSClassFromString(@"UIMutableApplicationSceneClientSettings") new];
    [clientSettings setInterfaceOrientation:1];
    [clientSettings setStatusBarStyle:0];
    [parameters setClientSettings:clientSettings];

    /* 6. FBSceneManager 创建场景 */
    id scene = [[NSClassFromString(@"FBSceneManager") sharedInstance]
        createSceneWithDefinition:definition initialParameters:parameters];
    if (!scene) {
        hud_mark(@"scene-nil");
        return YES;
    }

    /* 7. 绑定到窗口展示 */
    [binder addScene:scene];
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
