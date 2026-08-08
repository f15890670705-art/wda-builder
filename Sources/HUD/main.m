//
// AilinHUD main.m
//
// 独立悬浮球进程（懒人模式）：由 touch_engine（root daemon）spawn 拉起。
// ⚠️ 不调 FBSystemShellInitialize —— 那是系统 shell(SpringBoard 类)专用，
//    裸 spawn 进程调用会因缺 frontboard.system-service domain 崩溃
//    (v1.4.1 实测 FBServiceFacilityServer 断言)。
//    窗口直接用 FBSceneManager 手动创建场景绑定（AppDelegate 里做）。
//
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import "HUDAppDelegate.h"

/* 诊断辅助：每一步写入 /tmp/ailintouch_hud.alive，引擎 /hud 端点远程读 */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        hud_mark(@"booting");
        int rc = UIApplicationMain(argc, argv, nil,
            NSStringFromClass([HUDAppDelegate class]));
        hud_mark([NSString stringWithFormat:@"exited-%d", rc]);
        return rc;
    }
}

