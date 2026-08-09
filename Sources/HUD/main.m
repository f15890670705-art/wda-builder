//
// AilinHUD main.m
//
// 独立悬浮球进程（v1.8.1 照懒人 RootCore 重构）。
// legacy 模式（无 SceneManifest）→ UIApplicationMain 不等 scene → 不卡 booting。
// 窗口 + FBScene 二进制 scene + binder 全在 HUDAppDelegate didFinish 做。
//
#import <UIKit/UIKit.h>
#import "HUDAppDelegate.h"

/* 诊断辅助：写 /tmp/ailintouch_hud.alive，引擎 /hud 端点远程读 */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        hud_mark(@"booting");
        /* ★ v1.8.1 照懒人 RootCore main（0x1000a65c4）：
           argv[1]=="bootrun"（引擎 spawn 时传）→ 引擎模式。legacy 模式下
           UIApplicationMain 不等 scene 连接（无 SceneManifest），正常启动。 */
        if (argc >= 3 && strcmp(argv[1], "bootrun") == 0) {
            hud_mark(@"bootrun-mode");
        }
        int rc = UIApplicationMain(argc, argv, nil,
            NSStringFromClass([HUDAppDelegate class]));
        hud_mark([NSString stringWithFormat:@"exited-%d", rc]);
        return rc;
    }
}
