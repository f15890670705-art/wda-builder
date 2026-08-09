//
// AilinHUD main.m
//
// 独立进程（照懒人 RootCore 架构）。
// ★ v1.8.25 用户指示：先在 AilinHUD 里搞 HTTP server 实现日志，跑通后再管
//   touch 引擎。bootrun 模式 = 纯 HTTP server（不调 UIApplicationMain，
//   不会卡 booting），监听 8081 提供 /log（读 App 日志文件）+ /hud。
//   HTTP 跑通验证 AilinHUD 独立进程能起来，之后再加界面/悬浮球。
//
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <pthread.h>
#import "HUDAppDelegate.h"

/* 诊断辅助：写 /tmp/ailintouch_hud.alive，远程 /hud 端点可读 */
static void hud_mark(NSString *msg) {
    [msg writeToFile:@"/tmp/ailintouch_hud.alive"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

/* ---------- 简单 HTTP server（bootrun 模式）----------
   监听 8081（8080 是 touch 引擎的），提供：
   GET /log  → 读 /tmp/ailintouch_app.log（App 日志）+ 引擎日志
   GET /hud  → HUD 存活标记
   纯 C 线程，不依赖 UIApplicationMain。 */
#define HUD_HTTP_PORT 8081

static void hud_http_serve(int cfd) {
    char buf[512] = {0};
    read(cfd, buf, sizeof(buf) - 1);
    char body[70000] = {0};
    size_t bl = 0;
    if (strncmp(buf, "GET /log", 8) == 0) {
        /* App 日志在前 + 引擎日志在后（照 v1.8.14 归并思路，简化版） */
        FILE *af = fopen("/tmp/ailintouch_app.log", "r");
        if (af) { bl = fread(body, 1, sizeof(body) - 1, af); fclose(af); }
        if (bl > 0 && body[bl-1] != '\n') body[bl++] = '\n';
        FILE *ef = fopen("/tmp/ailintouch_engine.log", "r");
        if (ef) {
            size_t el = fread(body + bl, 1, sizeof(body) - 1 - bl, ef);
            bl += el;
            fclose(ef);
        }
        body[bl] = 0;
    } else if (strncmp(buf, "GET /hud", 8) == 0) {
        char alive[512] = {0};
        FILE *hf = fopen("/tmp/ailintouch_hud.alive", "r");
        if (hf) { size_t n = fread(alive, 1, sizeof(alive)-1, hf); alive[n] = 0; fclose(hf); }
        snprintf(body, sizeof(body), "hud_alive=%s\n", alive[0] ? alive : "(missing)");
        bl = strlen(body);
    } else {
        snprintf(body, sizeof(body), "AilinHUD HTTP ok (bootrun)\n");
        bl = strlen(body);
    }
    char resp[72000];
    int rl = snprintf(resp, sizeof(resp),
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
        bl, body);
    write(cfd, resp, rl);
    close(cfd);
}

static void *hud_http_thread(void *arg) {
    (void)arg;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NULL;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(HUD_HTTP_PORT);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        hud_mark([NSString stringWithFormat:@"http-bind-fail-%d", errno]);
        return NULL;
    }
    listen(fd, 8);
    hud_mark(@"http-up-8081");
    for (;;) {
        int cfd = accept(fd, NULL, NULL);
        if (cfd < 0) continue;
        hud_http_serve(cfd);
    }
    return NULL;
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

/* 验证 8081 已被接管（launchd 副本在服务） */
static int hud_verify_takeover(void) {
    for (int i = 0; i < 10; i++) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in sa = {0};
        sa.sin_family = AF_INET;
        sa.sin_port = htons(HUD_HTTP_PORT);
        sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(s, (struct sockaddr*)&sa, sizeof(sa)) == 0) {
            close(s);
            return 1;
        }
        close(s);
        usleep(300 * 1000);
    }
    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        hud_mark(@"booting");
        /* ★ v1.8.27 系统 daemon 化（照懒人 mqlaunchd 拉起 RootCore）：
           launchd 副本（ppid=1，系统身份）直接跑 HTTP；手动实例提交
           launchd job + 验证 8081 接管后退出（双保险：没接管就手动跑）。
           ★ 关键：无 kill_old_instance —— v1.8.23 引擎竞态崩溃的根源是
           互杀 + launchd 副本循环，AilinHUD 去掉它，两条干净路径。
           系统身份是下一步副本用 UIApplicationMain 画球（不卡 booting）的前提。 */
        if (argc >= 2 && strcmp(argv[1], "bootrun") == 0) {
            int is_launchd = (getppid() == 1);
            if (is_launchd) {
                hud_mark(@"launchd-instance-run");
            } else {
                hud_mark(@"manual-instance");
                hud_ensure_launchd();
                if (hud_verify_takeover()) {
                    hud_mark(@"launchd-takeover-exit");
                    return 0;
                }
                hud_mark(@"manual-http-fallback");
            }
            pthread_t th;
            pthread_create(&th, NULL, hud_http_thread, NULL);
            /* 主线程保活（HTTP server 在子线程跑） */
            for (;;) { sleep(60); }
        }
        int rc = UIApplicationMain(argc, argv, nil,
            NSStringFromClass([HUDAppDelegate class]));
        hud_mark([NSString stringWithFormat:@"exited-%d", rc]);
        return rc;
    }
}
