#import "AppDelegate.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <netinet/in.h>
#import <spawn.h>
#import <pthread.h>
#import <dlfcn.h>
#import <signal.h>

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

/* ---------- HTTP（已移到 root touch_engine :8080，App 不再监听避免冲突） ---------- */

static void *http_thread(void *arg) {
    (void)arg;
    return NULL;  /* HTTP 由 root 引擎提供 */
}

/* ---------- watchdog：检查引擎 8080，不通则重新安装拉起（launchd 负责常驻） ---------- */
- (BOOL)engineAlive {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(8080);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int ok = (connect(fd, (struct sockaddr*)&a, sizeof(a)) == 0);
    close(fd);
    return ok;
}

- (void)startWatchdog {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        while (YES) {
            if (![self engineAlive]) {
                NSLog(@"[AilinTouch] engine 8080 down, reinstall+spawn...");
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.enginePid = [self spawnEngineAsRoot];
                });
            }
            usleep(5 * 1000 * 1000);  /* 每 5 秒检查 */
        }
    });
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

    /* 3. watchdog（引擎崩溃自动拉起）+ 每秒刷新状态 */
    [self startWatchdog];
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        [self refreshStatus];
    }];
    [self refreshStatus];

    return YES;
}

@end
