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

int main(int argc, char *argv[]) {
    @autoreleasepool {
        hud_mark(@"booting");
        /* ★ v1.8.25 bootrun 模式（照懒人 RootCore main argv 检查）：
           AilinHUD 被拉起时传 bootrun → 纯 HTTP server，不调 UIApplicationMain
           （UIApplicationMain 裸进程会卡 scene，v1.8.0-1.8.2 实测）。
           ★ v1.8.26 修复：argc>=3 → argc>=2（主 App spawn 传 {路径, bootrun}
           argc=2，原判断导致 bootrun 分支不进 → 卡 booting 实测 hud_alive=booting）*/
        if (argc >= 2 && strcmp(argv[1], "bootrun") == 0) {
            hud_mark(@"bootrun-http-mode");
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
