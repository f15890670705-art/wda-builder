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
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <signal.h>
#import "HUDAppDelegate.h"

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

/* 提交 launchd job（root 常驻 KeepAlive）—— 系统 daemon 身份 */
static void hud_ensure_launchd(void) {
    hud_copy_self(HUD_INSTALL_PATH);
    launch_data_t msg = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
    if (!msg) return;
    launch_data_dict_insert(msg, launch_data_new_string(HUD_LAUNCHD_LABEL), "label");
    launch_data_dict_insert(msg, launch_data_new_string(HUD_INSTALL_PATH), "program");
    launch_data_dict_insert(msg, launch_data_new_bool(1), "run_at_load");
    launch_data_dict_insert(msg, launch_data_new_bool(1), "keep_alive");
    launch_data_t resp = launch_msg(msg);
    if (resp) { launch_data_free(resp); hud_mark(@"launchd-submit-ok"); }
    else hud_mark(@"launchd-submit-fail");
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
        /* ★ v1.8.33 bootrun 模式（引擎/App spawn 时传）：只写日志 + 提交
           launchd + 保活。无 8081 HTTP（用户指示：引擎直接读日志文件）。
           launchd 副本（ppid==1，系统身份）直接保活 = 系统 daemon 化成功。 */
        if (argc >= 2 && strcmp(argv[1], "bootrun") == 0) {
            int is_launchd = (getppid() == 1);
            if (is_launchd) {
                hud_mark(@"launchd-instance-run");
            } else {
                hud_mark(@"manual-instance");
                pthread_t lt;
                pthread_create(&lt, NULL, hud_launchd_thread, NULL);
            }
            /* 主线程保活 */
            for (;;) { sleep(60); }
        }
        int rc = UIApplicationMain(argc, argv, nil,
            NSStringFromClass([HUDAppDelegate class]));
        hud_mark([NSString stringWithFormat:@"exited-%d", rc]);
        return rc;
    }
}
