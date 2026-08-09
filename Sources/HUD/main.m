//
// AilinHUD main.m
//
// 独立进程（照懒人 RootCore 架构）。
// ★ v1.8.33 用户指示：不要 8081 HTTP server——touch 引擎(8080)直接读 HUD
//   写的日志文件即可。bootrun 模式 = 只做三件事：
//   ① 写状态日志 /tmp/ailintouch_hud.log（+ alive 标记），引擎 /log?src=hud 读
//   ② 后台线程尝试 launchd 系统 daemon 化（launch_msg，不阻塞）
//   ③ 主线程保活
//   后续加悬浮球/界面时在 bootrun 分支扩展（或走 UIApplicationMain）。
//
#import <UIKit/UIKit.h>
#import <pthread.h>
#import <spawn.h>
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <signal.h>
#import <dlfcn.h>
#import "HUDAppDelegate.h"

extern char **environ;   /* v1.8.47 posix_spawn launchctl 用 */

/* ★ v1.8.60 照开源 Letterpress TRHudMain 私有 API（dlsym 动态解析，避免
   构建机链接私有 framework 失败）。这些是 iOS 悬浮窗的终极启动姿势：
   GSInitialize + BKSDisplayServicesStart + UIApplicationInitialize +
   UIApplicationInstantiateSingleton + __completeAndRunAsPlugin + CFRunLoopRun
   —— 完全不经过 UIApplicationMain 的 scene 生命周期（v1.8.44-59 卡
   ui-main-start / legacy cid-zero 的根因），以 plugin 身份运行。 */
typedef void (*fn_void)(void);
typedef void (*fn_void_id)(id);

static fn_void s_GSInitialize;
static fn_void s_BKSDisplayServicesStart;
static fn_void s_UIApplicationInitialize;
static fn_void_id s_UIApplicationInstantiateSingleton;

static BOOL hud_load_privates(void) {
    void *h = NULL;
    h = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
               RTLD_NOW | RTLD_GLOBAL);
    if (h) s_GSInitialize = (fn_void)dlsym(h, "GSInitialize");

    h = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
               RTLD_NOW | RTLD_GLOBAL);
    if (h) s_BKSDisplayServicesStart = (fn_void)dlsym(h, "BKSDisplayServicesStart");

    h = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit",
               RTLD_NOW | RTLD_GLOBAL);
    if (h) {
        s_UIApplicationInitialize = (fn_void)dlsym(h, "UIApplicationInitialize");
        s_UIApplicationInstantiateSingleton = (fn_void_id)dlsym(h, "UIApplicationInstantiateSingleton");
    }
    /* UIApplicationInitialize 实际在 UIKit 里；个别 iOS 版本放 BackBoardServices */
    if (!s_UIApplicationInitialize) {
        h = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
                   RTLD_NOW | RTLD_GLOBAL);
        if (h) s_UIApplicationInitialize = (fn_void)dlsym(h, "UIApplicationInitialize");
    }
    hud_mark([NSString stringWithFormat:@"priv-gs=%d bks=%d uiappinit=%d uiappsing=%d",
              s_GSInitialize != NULL, s_BKSDisplayServicesStart != NULL,
              s_UIApplicationInitialize != NULL, s_UIApplicationInstantiateSingleton != NULL]);
    return s_GSInitialize && s_BKSDisplayServicesStart &&
           s_UIApplicationInitialize && s_UIApplicationInstantiateSingleton;
}

/* UIApplication 私有方法（Letterpress UIApplication+Private.h 同款） */
@interface UIApplication (HUDPrivate)
- (void)_accessibilityInit;
- (void)__completeAndRunAsPlugin;
@end

/* ★ v1.8.60 TRHudMain plugin 模式启动（照 Letterpress TRHudApp.mm TRHudMain 完整序列）。
   不调 UIApplicationMain！GSInitialize + BKSDisplayServicesStart（拿 BackBoard 显示
   身份）→ UIApplicationInitialize + UIApplicationInstantiateSingleton（手动实例化
   UIApplication）→ setDelegate → _accessibilityInit → __completeAndRunAsPlugin
   （以 plugin 身份运行，绕开 iOS 13+ scene 生命周期）→ CFRunLoopRun。
   didFinish 里窗口 initWithFrame 不绑 scene + _isWindowServerHostingManaged=NO
   + _contextId + SBS 注册 = 全局悬浮球（Letterpress TrollStore 实测正路）。 */
static int hud_main_as_plugin(HUDAppDelegate *delegate) {
    hud_mark(@"plugin-main-start");
    if (!hud_load_privates()) {
        hud_mark(@"plugin-priv-load-fail");
        return 1;
    }
    if (s_GSInitialize) s_GSInitialize();
    hud_mark(@"gs-init-ok");
    if (s_BKSDisplayServicesStart) s_BKSDisplayServicesStart();
    hud_mark(@"bks-display-ok");
    if (s_UIApplicationInitialize) s_UIApplicationInitialize();
    hud_mark(@"uiapp-init-ok");
    if (s_UIApplicationInstantiateSingleton) s_UIApplicationInstantiateSingleton([UIApplication class]);
    hud_mark(@"uiapp-singleton-ok");

    UIApplication *app = [UIApplication sharedApplication];
    [app setDelegate:delegate];
    [app _accessibilityInit];
    hud_mark(@"delegate-set");
    [app __completeAndRunAsPlugin];
    hud_mark(@"plugin-run");
    CFRunLoopRun();
    hud_mark(@"runloop-exited");
    return 0;
}

/* 诊断辅助：写 /tmp/ailintouch_hud.alive（引擎 /hud 可读）+ /tmp/ailintouch_hud.log
   （引擎 /log?src=hud 可读，带 [HH:mm:ss.SSS] 时间戳）。全部依赖文件，无网络。 */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    @autoreleasepool {
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] [hud] %@\n",
                          [df stringFromDate:[NSDate date]], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ailintouch_hud.log"];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:@"/tmp/ailintouch_hud.log"
                                                    contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ailintouch_hud.log"];
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

/* ---------- launch_msg 声明（提交 launchd job 系统 daemon 化，照懒人 mqlaunchd） ----------
   不 exec 外部二进制（arm64e launchctl exec 失败，v1.8.15 实测），直接连 launchd socket。 */
typedef struct _launch_data *launch_data_t;
extern launch_data_t launch_msg(launch_data_t);
extern launch_data_t launch_data_alloc(int);
extern launch_data_t launch_data_free(launch_data_t);
extern void launch_data_dict_insert(launch_data_t, launch_data_t, const char *);
extern launch_data_t launch_data_new_string(const char *);
extern launch_data_t launch_data_new_bool(int);
#define LAUNCH_DATA_DICTIONARY 3

#define HUD_INSTALL_PATH "/var/mobile/ailintouch_hud"
#define HUD_LAUNCHD_LABEL "com.ailintouch.hud"

/* 复制自身到固定路径（launchd job 的 program 路径） */
static void hud_copy_self(const char *dst) {
    char self[1024] = {0};
    uint32_t sz = sizeof(self);
    _NSGetExecutablePath(self, &sz);
    if (strcmp(self, dst) == 0) return;
    FILE *in = fopen(self, "rb");
    if (!in) return;
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); return; }
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, n, out);
    fclose(out);
    fclose(in);
    chmod(dst, 0755);
}

/* 提交 launchd job（root 常驻）—— 系统 daemon 身份。
   ★ v1.8.47 改用 posix_spawn /bin/launchctl submit：
   v1.8.46 实测 launch_msg（即使补 command=submit）依然卡死（iOS 14.6 老接口
   对非 launchd 域进程不响应，launchd-submit-ok/fail 从未出现）→ HUD 没成
   daemon → createScene 断言失败（FBSceneManager.m:462）。
   launchctl submit -l label -p prog 不写 plist 文件（/Library 只读绕开），
   root 直接向 launchd 注册 job。 */
static void hud_ensure_launchd(void) {
    hud_copy_self(HUD_INSTALL_PATH);
    pid_t pid = 0;
    char *argv[] = {"/bin/launchctl", "submit", "-l",
                    (char *)HUD_LAUNCHD_LABEL, "-p",
                    (char *)HUD_INSTALL_PATH, NULL};
    int rc = posix_spawn(&pid, "/bin/launchctl", NULL, NULL, argv, environ);
    if (rc == 0) {
        int st = 0;
        waitpid(pid, &st, 0);
        hud_mark(st == 0 ? @"launchctl-submit-ok" : @"launchctl-submit-nonzero");
    } else {
        hud_mark([NSString stringWithFormat:@"launchctl-spawn-fail-%d", rc]);
    }
}

/* ★ v1.8.33 后台 launchd 提交线程（launch_msg 同步阻塞，放后台不阻塞主流程） */
static void *hud_launchd_thread(void *arg) {
    (void)arg;
    sleep(1);
    hud_ensure_launchd();
    hud_mark(@"launchd-submit-done");
    return NULL;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        hud_mark(@"booting");
        /* ★ v1.8.60 全部走 TRHudMain plugin 模式（不再 UIApplicationMain）：
           v1.8.44-59 反复卡 ui-main-start（spawn 独立进程 + UIApplicationMain
           = iOS 13+ 等 scene 连接卡死）。Letterpress TRHudMain 铁证：
           手动 UIApplicationInitialize + __completeAndRunAsPlugin + CFRunLoopRun
           —— plugin 身份运行，窗口不绑 scene 也能 WindowServer 接受（配合
           _isWindowServerHostingManaged=NO）+ SBS 注册全局。 */
        HUDAppDelegate *delegate = [HUDAppDelegate new];
        return hud_main_as_plugin(delegate);
    }
}
