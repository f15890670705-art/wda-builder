//
// AilinHUD main.m
//
// 独立悬浮球进程（懒人模式）：由 touch_engine（root daemon）spawn 拉起。
// ★★ 必须先在 main 里调 FBSystemShellInitialize(nil) 初始化 FrontBoard 服务，
//    裸 spawn 的进程才能连上系统场景服务（AutoGo agoverlayd / FrontBoardAppLauncher 同款）。
//
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import "HUDAppDelegate.h"

/* 诊断辅助：每一步写入 /tmp/ailintouch_hud.alive，引擎 /hud 端点远程读 */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

/* FrontBoard 初始化（私有 API，运行时 dlopen 解析避免链接报错）。
   FBSystemShellInitialize 在 FrontBoard.framework（不是 FrontBoardServices）*/
static void fb_init(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard", RTLD_NOW);
    if (!h) {
        hud_mark([NSString stringWithFormat:@"fb-dlopen-fail:%s", dlerror()]);
        return;
    }
    void (*FBSystemShellInitialize)(void *opaque) = dlsym(h, "FBSystemShellInitialize");
    if (FBSystemShellInitialize) {
        FBSystemShellInitialize(NULL);
        hud_mark(@"fb-inited");
    } else {
        hud_mark(@"fb-sym-missing");
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        hud_mark(@"booting");
        fb_init();
        int rc = UIApplicationMain(argc, argv, nil,
            NSStringFromClass([HUDAppDelegate class]));
        hud_mark([NSString stringWithFormat:@"exited-%d", rc]);
        return rc;
    }
}
