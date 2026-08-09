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
#import "HUDAppDelegate.h"

extern char **environ;   /* v1.8.47 posix_spawn launchctl 用 */

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
        /* ★ v1.8.52 bootrun 改回裸进程手动建球（不调 UIApplicationMain）：
           v1.8.51 实测铁证：scene-based UIApplicationMain 行为不稳定（v1.8.44
           能进 appdelegate，v1.8.51 卡在 ui-main-start 连 appdelegate 都不触发
           —— HUD 日志 18:22:27.069 后无任何输出），且主 App v1.8.50 实测
           createScene 在主 App（有 scene session）里 EXC_BREAKPOINT trap。
           → 裸进程（无 UIApplicationMain、无 scene session 关联）反而最干净：
           v1.8.42 裸进程已走到 fb-create-sel-ok（FBSceneManager 可用），当时
           缺 identity/spec/params 才失败；现在三件套齐全 + 主线程调用，
           createScene 应能成功（无 app scene 约束不会 trap）。
           流程：manualInstallBall（裸窗 + createScene + binder + SBS）→
           CFRunLoopRun 驱动渲染。 */
        if (argc >= 2 && strcmp(argv[1], "bootrun") == 0) {
            hud_mark(@"ui-main-start");
            /* 后台线程尝试 launchd（TrollStore 下会失败，无害） */
            pthread_t lt;
            pthread_create(&lt, NULL, hud_launchd_thread, NULL);
            /* 手动建球：窗口 + FBScene createScene（主线程）+ binder + SBS 注册 */
            [HUDAppDelegate manualInstallBall];
            hud_mark(@"runloop-start");
            CFRunLoopRun();
            hud_mark(@"runloop-exited");
            return 0;
        }
        int rc = UIApplicationMain(argc, argv, nil,
            NSStringFromClass([HUDAppDelegate class]));
        hud_mark([NSString stringWithFormat:@"exited-%d", rc]);
        return rc;
    }
}
