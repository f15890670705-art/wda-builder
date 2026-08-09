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

/* 提交 launchd job（root 常驻 KeepAlive）—— 系统 daemon 身份。
   ★ v1.8.46 修复：launch_msg 必须带 "command"="submit"（LAUNCHD_OP_SUBMIT）！
   v1.8.44/45 实测 hud.log 里 launchd-submit-ok/fail 从未出现 = launch_msg 缺
   command 字段直接卡死（launchd 等一个不存在的响应）。补上后才能真正把
   HUD 注册成 launchd daemon —— 这是懒人 RootCore 能 createScene 成功的核心
   （FBSceneManager.m:462 断言拒绝非 daemon 独立进程建 scene）。 */
static void hud_ensure_launchd(void) {
    hud_copy_self(HUD_INSTALL_PATH);
    launch_data_t msg = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
    if (!msg) return;
    launch_data_dict_insert(msg, launch_data_new_string("submit"), "command");
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
        /* ★ v1.8.44 照懒人 RootCore 铁证重写 bootrun：不再 CFRunLoopRun 裸跑。
           v1.8.36/1.8.37 的 legacy 裸跑（无 UIApplicationMain + 无 SceneManifest）
           实测 registered-cid 但球不渲染 —— 因为进程没有 UIKit scene 基础设施，
           UIWindow 没有 scene 可绑 → 拿不到有效 WindowServer contextID。
           懒人 RootCore = 完整 scene-based（Info.plist 有 UIApplicationSceneManifest
           + SceneDelegate），UIApplicationMain 后 UIKit 建 scene → scene:willConnect
           （HUDSceneDelegate）里窗口 initWithWindowScene: 绑 scene → 渲染 + SBS 注册。
           bootrun 参数保留（引擎/主 App 拉起时传），行为 = 正常 UIApplicationMain。 */
        if (argc >= 2 && strcmp(argv[1], "bootrun") == 0) {
            hud_mark(@"ui-main-start");
            /* 后台线程尝试 launchd（TrollStore 下会失败，无害） */
            pthread_t lt;
            pthread_create(&lt, NULL, hud_launchd_thread, NULL);
            /* ★ scene-based UIApplicationMain：SceneManifest + HUDSceneDelegate，
               窗口在 willConnect 里绑 scene 创建（照懒人 RootCore） */
            int rc = UIApplicationMain(argc, argv, nil,
                NSStringFromClass([HUDAppDelegate class]));
            hud_mark([NSString stringWithFormat:@"exited-%d", rc]);
            return rc;
        }
        int rc = UIApplicationMain(argc, argv, nil,
            NSStringFromClass([HUDAppDelegate class]));
        hud_mark([NSString stringWithFormat:@"exited-%d", rc]);
        return rc;
    }
}
