//
// AilinHUD main.m
//
// 独立悬浮球进程（懒人模式）：由 touch_engine（root daemon）spawn 拉起，
// 不受主 App 生命周期影响 —— 卸载主 App 后 HUD 依然常驻。
// HUD 自己是唯一 UI 进程，直接 makeKeyAndVisible（无主窗口冲突），
// 用 TrollSpeed 验证过的 SBS 注册姿势全局显示悬浮球。
//
#import <UIKit/UIKit.h>
#import "HUDAppDelegate.h"

/* 诊断辅助：每一步写入 /tmp/ailintouch_hud.alive，引擎 /hud 端点远程读。
   区分 HUD 卡在哪一步：booting → main 进了；appdelegate → didFinish 跑了；
   registered-cid=xxx → SBS 注册成功。 */
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
