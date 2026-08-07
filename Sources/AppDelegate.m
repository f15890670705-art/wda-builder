#import "AppDelegate.h"
#import "TouchEngine.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <pthread.h>

#define SERVER_PORT 8080

@interface AppDelegate ()
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation AppDelegate

/* ---------- 简易 HTTP 处理 ---------- */

static void send_response(int fd, const char *body) {
    char buf[1024];
    int len = snprintf(buf, sizeof(buf),
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s", strlen(body), body);
    write(fd, buf, len);
    close(fd);
}

static void handle_request(int fd, const char *req) {
    char method[16] = {0}, path[256] = {0};
    sscanf(req, "%15s %255s", method, path);

    if (strncmp(path, "/tap", 4) == 0) {
        float x = 0, y = 0;
        sscanf(path, "/tap?x=%f&y=%f", &x, &y);
        int rc = TouchTap(x, y);
        char body[128];
        snprintf(body, sizeof(body), "{\"ok\":%d,\"x\":%.1f,\"y\":%.1f}", rc == 0, x, y);
        send_response(fd, body);
    }
    else if (strncmp(path, "/swipe", 6) == 0) {
        float x1=0,y1=0,x2=0,y2=0; int ms=300;
        sscanf(path, "/swipe?x1=%f&y1=%f&x2=%f&y2=%f&ms=%d", &x1,&y1,&x2,&y2,&ms);
        int rc = TouchSwipe(x1, y1, x2, y2, ms);
        send_response(fd, rc == 0 ? "{\"ok\":true}" : "{\"ok\":false}");
    }
    else if (strncmp(path, "/key", 4) == 0) {
        int usage = 0;
        sscanf(path, "/key?usage=%d", &usage);
        int rc = TouchKey((uint16_t)usage);
        send_response(fd, rc == 0 ? "{\"ok\":true}" : "{\"ok\":false}");
    }
    else if (strncmp(path, "/status", 7) == 0) {
        char body[256];
        snprintf(body, sizeof(body), "{\"engine\":\"%s\",\"port\":%d}", TouchEngineDiag(), SERVER_PORT);
        send_response(fd, body);
    }
    else {
        send_response(fd, "{\"ok\":false,\"error\":\"unknown endpoint\"}");
    }
}

static void *server_thread(void *arg) {
    int sfd = socket(AF_INET, SOCK_STREAM, 0);
    int on = 1;
    setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(SERVER_PORT);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(sfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { close(sfd); return NULL; }
    if (listen(sfd, 8) < 0) { close(sfd); return NULL; }

    for (;;) {
        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) continue;
        char req[2048] = {0};
        ssize_t n = read(cfd, req, sizeof(req) - 1);
        if (n > 0) handle_request(cfd, req);
        else close(cfd);
    }
    return NULL;
}

/* ---------- App 生命周期 ---------- */

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    /* 初始化 HID 引擎 */
    int rc = TouchEngineInit();

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[UIViewController alloc] init];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 80, 300, 60)];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.text = [NSString stringWithFormat:@"TouchEngine: %@ (rc=%d)\nHTTP: %@:%d",
        [NSString stringWithUTF8String:TouchEngineDiag()], rc,
        [[UIDevice currentDevice] name] ?: @"?", SERVER_PORT];
    [self.window.rootViewController.view addSubview:self.statusLabel];

    [self.window makeKeyAndVisible];

    /* 启动 HTTP 控制服务 */
    pthread_t tid;
    pthread_create(&tid, NULL, server_thread, NULL);
    pthread_detach(tid);

    return YES;
}

@end
