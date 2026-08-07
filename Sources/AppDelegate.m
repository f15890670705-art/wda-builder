#import "AppDelegate.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <netinet/in.h>
#import <spawn.h>
#import <pthread.h>
#import <dlfcn.h>

#define SERVER_PORT 8080
#define ENGINE_SOCK "/tmp/ailintouch.sock"

extern char **environ;

static AppDelegate *g_delegate;

@interface AppDelegate ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) pid_t enginePid;
@end

@implementation AppDelegate

/* ---------- root spawn（Ailin 同款：persona 99 + uid 0） ---------- */
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, int, uid_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_groups_np(const posix_spawnattr_t *, int, gid_t *);

- (pid_t)spawnEngineAsRoot {
    NSString *bundlePath = [[NSBundle mainBundle] resourcePath];
    NSString *enginePath = [bundlePath stringByAppendingPathComponent:@"touch_engine"];

    if (![[NSFileManager defaultManager] isExecutableFileAtPath:enginePath]) {
        chmod([enginePath UTF8String], 0755);
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, 0);          /* persona 99 (root) */
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | 0x100 /*POSIX_SPAWN_SET_PERSONA*/);

    pid_t pid = 0;
    char *argv[] = {(char *)[enginePath UTF8String], NULL};
    int rc = posix_spawn(&pid, [enginePath UTF8String], NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) {
        NSLog(@"[AilinTouch] spawn engine failed: %s (%d)", strerror(rc), rc);
        return -1;
    }
    NSLog(@"[AilinTouch] engine spawned pid=%d", pid);
    return pid;
}

/* ---------- 命令转发到引擎 socket ---------- */
- (NSString *)forwardToEngine:(NSString *)cmd {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return @"ERR socket";

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, ENGINE_SOCK);
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return @"ERR engine-not-running";
    }

    write(fd, [cmd UTF8String], [cmd length]);
    char buf[256] = {0};
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return @"ERR no-response";
    return [NSString stringWithUTF8String:buf];
}

/* ---------- HTTP ---------- */
static void send_response(int fd, const char *body) {
    char buf[1024];
    int len = snprintf(buf, sizeof(buf),
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n%s", strlen(body), body);
    write(fd, buf, len);
    close(fd);
}

static void handle_request(int fd, const char *req) {
    char method[16] = {0}, path[512] = {0};
    sscanf(req, "%15s %511s", method, path);

    char body[256] = {0};
    if (strncmp(path, "/tap", 4) == 0) {
        float x = 0, y = 0;
        sscanf(path, "/tap?x=%f&y=%f", &x, &y);
        NSString *r = [g_delegate forwardToEngine:[NSString stringWithFormat:@"TAP %.1f %.1f\n", x, y]];
        snprintf(body, sizeof(body), "{\"ok\":%d,\"engine\":\"%s\"}", [r hasPrefix:@"OK"], [r UTF8String]);
    }
    else if (strncmp(path, "/swipe", 6) == 0) {
        float x1=0,y1=0,x2=0,y2=0; int ms=300;
        sscanf(path, "/swipe?x1=%f&y1=%f&x2=%f&y2=%f&ms=%d", &x1,&y1,&x2,&y2,&ms);
        NSString *r = [g_delegate forwardToEngine:[NSString stringWithFormat:@"SWIPE %.1f %.1f %.1f %.1f %d\n", x1,y1,x2,y2,ms]];
        snprintf(body, sizeof(body), "{\"ok\":%d}", [r hasPrefix:@"OK"]);
    }
    else if (strncmp(path, "/status", 7) == 0) {
        NSString *r = [g_delegate forwardToEngine:@"STATUS\n"];
        snprintf(body, sizeof(body), "{\"engine\":\"%s\"}", [r UTF8String]);
    }
    else {
        snprintf(body, sizeof(body), "{\"ok\":false,\"error\":\"unknown\"}");
    }
    send_response(fd, body);
}

static void *http_thread(void *arg) {
    int sfd = socket(AF_INET, SOCK_STREAM, 0);
    int on = 1;
    setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in addr = {0};
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
- (void)refreshStatus {
    NSString *engineStatus = [self forwardToEngine:@"STATUS\n"];
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    self.statusLabel.text = [NSString stringWithFormat:
        @"AilinTouch v%@\n\n"
        @"engine pid: %d\n"
        @"HTTP: :%d\n"
        @"%@\n"
        @"\n命令: tap?x=..&y=..",
        ver, self.enginePid, SERVER_PORT, [engineStatus stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    g_delegate = self;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor whiteColor];
    self.window.rootViewController = [[UIViewController alloc] init];
    self.window.rootViewController.view.backgroundColor = [UIColor whiteColor];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 100, 340, 400)];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textColor = [UIColor blackColor];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:18];
    [self.window.rootViewController.view addSubview:self.statusLabel];
    [self.window makeKeyAndVisible];

    /* 1. 以 root 拉起引擎 */
    self.enginePid = [self spawnEngineAsRoot];

    /* 2. HTTP 服务 */
    pthread_t tid;
    pthread_create(&tid, NULL, http_thread, NULL);
    pthread_detach(tid);

    /* 3. 每秒刷新状态 */
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        [self refreshStatus];
    }];
    [self refreshStatus];

    return YES;
}

@end
