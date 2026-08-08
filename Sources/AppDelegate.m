//
// AppDelegate.m — AilinTouch（v8.0 UI 重写）
//
//  卡片式 UI：顶部标题 + 服务状态/设备信息/服务控制 三张卡片
//  底部 TabBar：控制面板 / 服务管理
//  引擎：spawn root touch_engine，HTTP :8080（常驻由 launchd 全权负责）
//
#import "AppDelegate.h"
#import "ATTabBarController.h"
#import "ControlPanelViewController.h"
#import "ServiceManagerViewController.h"
#import "FileViewerViewController.h"
#import "LogViewerViewController.h"
#import "DirListViewController.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <spawn.h>
#import <pthread.h>
#import <dlfcn.h>
#import <signal.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <stdlib.h>
#import <string.h>

#define SERVER_PORT       8080
#define ENGINE_SOCK       "/tmp/ailintouch.sock"
#define ENGINE_PID_PATH   @"/tmp/ailintouch_engine.pid"
#define ENGINE_LOG_PATH   @"/tmp/ailintouch_engine.log"
#define ENGINE_STOPPED    @"/tmp/ailintouch.stopped"

extern char **environ;
static AppDelegate *g_delegate;

#pragma mark - AppDelegate

@interface AppDelegate () <UINavigationControllerDelegate>
@property (nonatomic, strong) UINavigationController *nav;
@property (nonatomic, strong) ATTabBarController *tabBar;
@property (nonatomic, strong) ControlPanelViewController *controlVC;
@property (nonatomic, strong) ServiceManagerViewController *serviceVC;
@property (nonatomic, assign) pid_t enginePid;
@property (nonatomic, strong) NSString *cachedIP;
@end

@implementation AppDelegate

#pragma mark root spawn

extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, int, uid_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);

- (pid_t)spawnEngineAsRoot {
    NSString *bundlePath = [[NSBundle mainBundle] resourcePath];
    NSString *enginePath = [bundlePath stringByAppendingPathComponent:@"touch_engine"];

    if (![[NSFileManager defaultManager] isExecutableFileAtPath:enginePath]) {
        chmod([enginePath UTF8String], 0755);
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, 0);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | 0x100);

    pid_t pid = 0;
    char *argv[] = {(char *)[enginePath UTF8String], NULL};
    int rc = posix_spawn(&pid, [enginePath UTF8String], NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) { NSLog(@"[AilinTouch] spawn failed: %s", strerror(rc)); return -1; }
    NSLog(@"[AilinTouch] engine spawn pid=%d", pid);
    return pid;
}

#pragma mark Unix socket

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

#pragma mark 引擎通断

- (BOOL)engineAlive {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(SERVER_PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    struct timeval tv = { .tv_sec = 0, .tv_usec = 200 * 1000 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    int ok = (connect(fd, (struct sockaddr*)&a, sizeof(a)) == 0);
    close(fd);
    return ok;
}

- (void)ensureEngine {
    if ([self engineAlive]) return;
    NSLog(@"[AilinTouch] engine down, spawning...");
    self.enginePid = [self spawnEngineAsRoot];
}

/* 启动服务：先判断是否已启动；未启动才拉起（launchd 由 root 引擎自己 ensure） */
- (void)startService {
    /* 清掉手动停止标记，允许引擎再次常驻 */
    unlink([ENGINE_STOPPED UTF8String]);
    if ([self engineAlive]) {
        NSLog(@"[AilinTouch] startService: already running");
        return;
    }
    NSLog(@"[AilinTouch] startService: starting...");
    self.enginePid = [self spawnEngineAsRoot];
    NSLog(@"[AilinTouch] startService done, alive=%d", [self engineAlive]);
}

/* 停止服务：root 引擎收到 SHUTDOWN 后自己 launchctl unload + 退出 */
- (void)stopEngine {
    NSString *r = [self forwardToEngine:@"SHUTDOWN\n"];
    NSLog(@"[AilinTouch] shutdown reply: %@", r);
    /* 兜底 kill（若引擎没回 SHUTDOWN） */
    FILE *pf = fopen([ENGINE_PID_PATH UTF8String], "r");
    if (pf) {
        int pid = 0;
        if (fscanf(pf, "%d", &pid) == 1 && pid > 0) {
            if (kill(pid, 0) == 0) {
                kill(pid, SIGKILL);
                NSLog(@"[AilinTouch] killed engine pid=%d", pid);
            }
        }
        fclose(pf);
    }
    usleep(300 * 1000);
}

#pragma mark IP

- (NSString *)currentWifiIP {
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) return nil;
    NSString *result = nil;
    for (struct ifaddrs *p = addrs; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        if (!(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
        NSString *name = [NSString stringWithUTF8String:p->ifa_name];
        if (![name hasPrefix:@"en"]) continue; /* en0 = wifi, en1 = 多网 */
        char buf[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &((struct sockaddr_in*)p->ifa_addr)->sin_addr, buf, sizeof(buf));
        NSString *ip = [NSString stringWithUTF8String:buf];
        if (![ip isEqualToString:@"0.0.0.0"] && ![ip hasPrefix:@"169.254."]) {
            result = ip;
            break;
        }
    }
    freeifaddrs(addrs);
    return result;
}

#pragma mark 设备信息

- (NSDictionary *)collectDeviceInfo {
    NSMutableDictionary *d = [NSMutableDictionary new];

    /* 设备名 */
    NSString *name = [[UIDevice currentDevice] name] ?: @"-";
    [d setObject:name forKey:@"name"];

    /* iOS 版本 */
    NSString *ver = [[UIDevice currentDevice] systemVersion] ?: @"-";
    [d setObject:ver forKey:@"os"];

    /* 机型 — sysctl hw.machine */
    size_t sz = 0;
    sysctlbyname("hw.machine", NULL, &sz, NULL, 0);
    char *m = malloc(sz + 1);
    if (m) {
        sysctlbyname("hw.machine", m, &sz, NULL, 0);
        m[sz] = 0;
        [d setObject:[NSString stringWithUTF8String:m] forKey:@"machine"];
        free(m);
    } else [d setObject:@"-" forKey:@"machine"];

    /* 屏幕 */
    CGSize sz1 = [UIScreen mainScreen].bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;
    [d setObject:[NSString stringWithFormat:@"%.0fx%.0f (@%.0fx)",
                   sz1.width, sz1.height, scale] forKey:@"screen"];

    return d;
}

#pragma mark UI 构建

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    g_delegate = self;

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor whiteColor];

    /* 两个 Tab 页 */
    self.controlVC  = [ControlPanelViewController new];
    self.serviceVC  = [ServiceManagerViewController new];

    self.tabBar = [[ATTabBarController alloc]
        initWithViewControllers:@[self.controlVC, self.serviceVC]
                        titles:@[@"控制面板", @"服务管理"]
                       symbols:@[@"house.fill", @"gearshape.fill"]];

    self.nav = [[UINavigationController alloc] initWithRootViewController:self.tabBar];
    self.nav.navigationBar.hidden = YES;     /* 自绘标题 */
    self.window.rootViewController = self.nav;
    [self.window makeKeyAndVisible];

    /* 全局悬浮球（懒人同款 SBS 注册；点击暂时 toast "123"） */
    __weak typeof(self) ws = self;
    FloatingWindowManager.shared.onTap = ^{
        [ws showToast:@"123"];
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [FloatingWindowManager.shared showFloatingBall];
    });

    /* 按钮回调 */
    __weak typeof(self) ws = self;
    self.serviceVC.onTapStart = ^{
        BOOL wasRunning = [ws engineAlive];
        [ws startService];
        [ws showToast:wasRunning ? @"服务已启动" : @"启动服务中"];
        [ws refreshStatus];
    };
    self.serviceVC.onTapStop = ^{
        [ws stopEngine];
        [ws showToast:@"服务已停止"];
        [ws refreshStatus];
    };
    self.serviceVC.onTapRefreshStatus = ^{
        [ws refreshStatus];
        [ws showToast:@"状态已刷新"];
    };
    self.serviceVC.onTapRefreshIP = ^{
        ws.cachedIP = [ws currentWifiIP] ?: @"无 WiFi";
        ws.serviceVC.localIP = ws.cachedIP;
        ws.controlVC.localIP = ws.cachedIP;
        [ws refreshStatus];
        [ws showToast:@"IP 已刷新"];
    };
    self.serviceVC.onTapLogDir = ^{
        /* 走 HTTP /log：root 引擎读日志后返回，App 不用 root */
        LogViewerViewController *vc = [LogViewerViewController new];
        vc.endpointURL = @"http://127.0.0.1:8080/log";
        [ws.nav pushViewController:vc animated:YES];
    };
    self.serviceVC.onTapWorkDir = ^{
        /* 走 HTTP /dir：root 引擎列目录返回，App 不用 root */
        DirListViewController *vc = [DirListViewController new];
        vc.endpointURL = @"http://127.0.0.1:8080/dir?path=/var/mobile/ailintouch";
        [ws.nav pushViewController:vc animated:YES];
    };

    /* 1. 拉起引擎（若上次手动停止过，尊重用户选择：不自动拉起） */
    if ([[NSFileManager defaultManager] fileExistsAtPath:ENGINE_STOPPED]) {
        NSLog(@"[AilinTouch] stopped marker present, engine stays down");
    } else {
        self.enginePid = [self spawnEngineAsRoot];
    }

    /* 2. 每秒刷新状态 */
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        [self refreshStatus];
    }];
    [self refreshStatus];

    return YES;
}

#pragma mark 状态刷新

- (void)refreshStatus {
    BOOL alive = [self engineAlive];
    NSString *state = alive ? @"已启动" : @"已停止";
    NSString *appVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"-";
    NSString *ip = self.cachedIP ?: ([self currentWifiIP] ?: @"未连接");
    if (!self.cachedIP) self.cachedIP = ip;

    /* 从引擎 STATUS 里解出引擎版本（ver=xxx） */
    NSString *engStatus = alive ? [self forwardToEngine:@"STATUS\n"] : @"";
    NSString *engVer = @"-";
    if ([engStatus rangeOfString:@"ver="].location != NSNotFound) {
        NSString *part = [engStatus componentsSeparatedByString:@"ver="].lastObject;
        engVer = [part componentsSeparatedByString:@" "].firstObject ?: @"-";
    }

    NSDictionary *dev = [self collectDeviceInfo];

    self.serviceVC.serviceState  = state;
    self.serviceVC.serviceVersion = engVer;
    self.serviceVC.appVersion    = appVer;
    self.serviceVC.localIP       = ip;
    self.serviceVC.httpPort      = SERVER_PORT;
    self.serviceVC.deviceName    = dev[@"name"];
    self.serviceVC.deviceOS      = [NSString stringWithFormat:@"iOS %@", dev[@"os"]];
    self.serviceVC.deviceModel   = dev[@"machine"];
    self.serviceVC.screenSize    = dev[@"screen"];

    self.controlVC.localIP = ip;
    self.controlVC.httpPort = SERVER_PORT;
}

#pragma mark Toast

- (void)showToast:(NSString *)msg {
    UIWindow *w = self.window;
    if (!w) return;

    UILabel *toast = [UILabel new];
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.text = msg;
    toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.layer.cornerRadius = 18;
    toast.layer.masksToBounds = YES;
    toast.numberOfLines = 1;
    toast.alpha = 0;
    [w addSubview:toast];

    [NSLayoutConstraint activateConstraints:@[
        [toast.centerXAnchor constraintEqualToAnchor:w.centerXAnchor],
        [toast.bottomAnchor constraintEqualToAnchor:w.safeAreaLayoutGuide.bottomAnchor constant:-90],
        [toast.widthAnchor constraintGreaterThanOrEqualToConstant:120],
        [toast.heightAnchor constraintEqualToConstant:36],
    ]];
    [toast sizeToFit];

    [UIView animateWithDuration:0.22 animations:^{
        toast.alpha = 1.0;
    } completion:^(BOOL f) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                toast.alpha = 0;
            } completion:^(BOOL f2) {
                [toast removeFromSuperview];
            }];
        });
    }];
}

@end
