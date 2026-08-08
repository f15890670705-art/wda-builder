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
        /* ★ v1.5.1: 设置 UIKit 启动环境（对照 AutoGo floatball 的
           _AGFloatballPrepareFromProcessArguments 思路——独立 spawn 进程
           没有 LaunchServices 注入的 HOME，UIKit 早期访问用户域会卡死）。
           CFFIXED_USER_HOME 决定 NSHomeDirectory() 返回值，
           缺它 UIApplicationMain 在连接 backboard 前就阻塞（alive=booting 卡死）。 */
        if (getenv("CFFIXED_USER_HOME") == NULL) {
            setenv("CFFIXED_USER_HOME", "/var/mobile", 1);
            setenv("HOME", "/var/mobile", 1);
        }

        hud_mark(@"booting");
        int rc = UIApplicationMain(argc, argv, nil,
            NSStringFromClass([HUDAppDelegate class]));
        hud_mark([NSString stringWithFormat:@"exited-%d", rc]);
        return rc;
    }
}

