//
// HUDSceneDelegate.m
//
// AilinHUD Scene 生命周期实现（照懒人 RootCore 真实 Info.plist + 符号铁证 v1.8.44）。
// 懒人 RootCore（com.nx.RootCore）：完整 UIApplicationSceneManifest + SceneDelegate
// + @_OBJC_CLASS_$_UIWindowScene + UIRootSceneWindow + UIRootWindowScenePresentationBinder
// + FBSceneManager + SBSAccessibilityWindowHostingController。
// ★ v1.8.44 关键修正（照懒人铁证）：窗口必须 initWithWindowScene: 绑 UIKit scene ——
//   v1.8.0-1.8.37 的"不绑 scene 裸窗口 + 二进制 FBScene"路线实测球不渲染/不全局
//   （registered-cid 但球不显示）。scene-based 下窗口有 scene → 有效 contextID →
//   SBS 注册全局。FBScene/binder 保留作为补路。
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

    if (![scene isKindOfClass:[UIWindowScene class]]) {
        hud_mark(@"scene-not-windowscene");
        return;
    }
    UIWindowScene *windowScene = (UIWindowScene *)scene;

    /* ★ v1.8.44 照懒人 MyCustomWindow = initWithWindowScene:（scene:willConnect
       反汇编 0x10001d0d8 铁证）：窗口绑 scene 才能拿到有效 WindowServer
       contextID + 内容渲染。v1.8.36 的 initWithFrame 裸窗口（无 scene）实测
       registered-cid 但球不渲染 = cid 是垃圾大数。 */
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.backgroundColor = [UIColor clearColor];
    self.window.windowLevel = 20000002.0;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    self.window.rootViewController = vc;

    /* 悬浮球（位置靠右，与主 App 球区分，便于验证双进程） */
    CGFloat size = 56;
    CGFloat x = windowScene.coordinateSpace.bounds.size.width - 20 - size;
    CGFloat y = windowScene.coordinateSpace.bounds.size.height / 2 - size;
    HUDBall *ball = [[HUDBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
    [vc.view addSubview:ball];

    [self.window makeKeyAndVisible];
    hud_mark(@"window-shown");

    /* ★ v1.8.0 二进制 FBScene：FBSceneManager 手动创建 + binder 绑系统 root window。
       懒人 RootCore 符号铁证。createSceneWithDefinition:initialParameters:
       v1.8.44 保留（补路）：scene-based 主路走通时它无害，失败时不影响窗口。 */
    [self createFrontBoardScene];

    /* SBS 注册 → 全局悬浮（cid 可能延迟分配，内部重试） */
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

        /* 3. identity —— ★ v1.8.42 铁证不再设置！
           v1.8.39 实测 FBSMutableSceneIdentity init 全抛异常，设置失败后 def
           不干净 → createSceneWithDefinition 卡死。agoverlayd 符号里没有任何
           identity selector = 它根本不设 identity，def 用 new 的干净对象。 */

        /* 4. FBSMutableSceneParameters */
        Class paramsCls = NSClassFromString(@"FBSMutableSceneParameters");
        id params = paramsCls ? ((id(*)(id, SEL))objc_msgSend)(paramsCls, NSSelectorFromString(@"new")) : nil;
        if (!params) { hud_mark(@"fb-params-fail"); return; }

        /* 5. createSceneWithDefinition:initialParameters:（★ v1.8.42 后台线程 +
           3s 超时，不阻塞主线程 —— v1.8.39 实测 createScene 可能同步卡死） */
        __block id fbSceneBlock = nil;
        __block BOOL createDone = NO;
        SEL createSel = NSSelectorFromString(@"createSceneWithDefinition:initialParameters:");
        if (![manager respondsToSelector:createSel]) { hud_mark(@"fb-create-no-sel"); return; }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @try {
                fbSceneBlock = ((id(*)(id, SEL, id, id))objc_msgSend)(manager, createSel, def, params);
            } @catch (NSException *e) {
                hud_mark([NSString stringWithFormat:@"fb-create-ex-%@", e.name]);
            }
            createDone = YES;
        });
        for (int i = 0; i < 30 && !createDone; i++) usleep(100 * 1000);
        id fbScene = fbSceneBlock;
        hud_mark(createDone ? (fbScene ? @"fb-scene-created" : @"fb-create-returned-nil")
                            : @"fb-create-timeout-3s");
        if (!fbScene) return;
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

static int g_register_attempts = 0;   /* SBS 注册重试计数 */

- (void)registerToSpringBoard {
    unsigned int cid = [self windowContextID];
    if (cid == 0) {
        /* 首帧可能拿不到，0.3s 后重试（最多 10 次） */
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
