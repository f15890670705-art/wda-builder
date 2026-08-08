//
// HUDSceneDelegate.m
//
// AilinHUD Scene 生命周期实现（照懒人 RootCore 反汇编铁证 v1.8.0）。
// 懒人 RootCore（com.nx.RootCore）符号铁证：@_UIApplicationMain +
// @_OBJC_CLASS_$_FBSceneManager + FBSMutableSceneDefinition +
// createSceneWithDefinition:initialParameters: + UIRootWindowScenePresentationBinder。
// 悬浮球 = 窗口不绑 UIKit scene + 【手动创建二进制 FBScene】+
// binder addScene 绑到系统 root window 层 → 全局显示、不随 App scene 挂起。
//
#import "HUDSceneDelegate.h"
#import "HUDBall.h"
#import <objc/message.h>

/* 诊断辅助：写 /tmp/ailintouch_hud.alive，引擎 /hud 端点远程读 */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@implementation HUDSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)connectionOptions {

    hud_mark(@"scene-willconnect");

    /* ★ v1.8.0 照懒人 MyCustomWindow：窗口 initWithFrame 全屏，不绑 UIKit scene。
       懒人 RootCore 的悬浮球窗口独立于 UIKit scene，由二进制 FBScene + binder
       挂到系统 root window 层显示。 */
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

    /* ★ v1.8.0 二进制 FBScene：FBSceneManager 手动创建 + binder 绑系统 root window。
       懒人 RootCore 符号铁证。createSceneWithDefinition:initialParameters: */
    [self createFrontBoardScene];

    /* SBS 注册 → 全局悬浮 */
    [self registerToSpringBoard];
}

/* ★ v1.8.0 照懒人 RootCore：FBSceneManager 手动创建二进制 scene +
   UIRootWindowScenePresentationBinder 绑定到系统 root window 层。
   全部私有 API 动态调用（objc_msgSend），包 @try 防崩。 */
- (void)createFrontBoardScene {
    @try {
        /* 1. FBSceneManager（单例） */
        Class mgrCls = NSClassFromString(@"FBSceneManager");
        if (!mgrCls) { hud_mark(@"fb-mgr-missing"); return; }
        id manager = nil;
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if ([mgrCls respondsToSelector:sharedSel]) {
            manager = ((id(*)(id, SEL))objc_msgSend)(mgrCls, sharedSel);
        }
        if (!manager) manager = ((id(*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"new"));
        if (!manager) { hud_mark(@"fb-mgr-fail"); return; }

        /* 2. FBSMutableSceneDefinition */
        Class defCls = NSClassFromString(@"FBSMutableSceneDefinition");
        if (!defCls) { hud_mark(@"fb-def-missing"); return; }
        id def = ((id(*)(id, SEL))objc_msgSend)(defCls, NSSelectorFromString(@"new"));

        /* 3. identity：FBSMutableSceneIdentity initWithBundleIdentifier: */
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

        /* 4. FBSMutableSceneParameters */
        Class paramsCls = NSClassFromString(@"FBSMutableSceneParameters");
        id params = paramsCls ? ((id(*)(id, SEL))objc_msgSend)(paramsCls, NSSelectorFromString(@"new")) : nil;
        if (!params) { hud_mark(@"fb-params-fail"); return; }

        /* 5. createSceneWithDefinition:initialParameters: */
        SEL createSel = NSSelectorFromString(@"createSceneWithDefinition:initialParameters:");
        if (![manager respondsToSelector:createSel]) { hud_mark(@"fb-create-no-sel"); return; }
        id fbScene = ((id(*)(id, SEL, id, id))objc_msgSend)(manager, createSel, def, params);
        if (!fbScene) { hud_mark(@"fb-create-fail"); return; }
        self.fbScene = fbScene;
        hud_mark(@"fb-scene-created");

        /* 6. UIRootWindowScenePresentationBinder addScene: */
        Class binderCls = NSClassFromString(@"UIRootWindowScenePresentationBinder");
        if (!binderCls) { hud_mark(@"binder-missing"); return; }
        self.binder = ((id(*)(id, SEL))objc_msgSend)(binderCls, NSSelectorFromString(@"new"));
        SEL addSel = NSSelectorFromString(@"addScene:");
        if ([self.binder respondsToSelector:addSel]) {
            ((void(*)(id, SEL, id))objc_msgSend)(self.binder, addSel, fbScene);
            hud_mark(@"fb-scene-bound");
        } else {
            hud_mark(@"binder-no-addscene");
        }
    } @catch (NSException *e) {
        hud_mark([NSString stringWithFormat:@"fb-bind-ex-%@", e.name]);
    }
}

- (unsigned int)windowContextID {
    /* v1.8.0 照懒人 safeGetWindowContextID：NSInvocation 动态调 _contextId */
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

- (void)registerToSpringBoard {
    unsigned int cid = [self windowContextID];
    if (cid == 0) {
        /* 首帧可能拿不到，0.3s 后重试（最多 10 次） */
        static int attempts = 0;
        if (attempts++ < 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self registerToSpringBoard];
            });
        }
        return;
    }
    attempts = 0;
    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!cls) {
        hud_mark(@"sbs-class-missing");
        return;
    }
    /* v1.8.0 照懒人 tryRegisterWithAccessibilityController：每次新实例 +
       NSInvocation 动态调用（参数类型按真实签名） */
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
            /* 双 Darwin 通知（懒人 registerWindowWithFallback 同款） */
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.apple.hudservices.windowRegistered"), NULL, NULL, true);
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.apple.springboard.hudwindow.registered"), NULL, NULL, true);
        }
    }
}

@end
