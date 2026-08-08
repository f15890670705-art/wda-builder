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

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([HUDAppDelegate class]));
    }
}
