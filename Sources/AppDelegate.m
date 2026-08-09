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
#import "FloatingWindowManager.h"
#import <AVFoundation/AVFoundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <spawn.h>
#import <pthread.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <time.h>
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
@property (nonatomic, assign) BOOL engineReady;   /* ★ v1.8.6 引擎 HTTP 就绪标记（分阶段启动） */
@property (nonatomic, strong) NSString *cachedIP;
@property (nonatomic, strong) AVAudioPlayer *keepAlivePlayer;
@end

@implementation AppDelegate

/* ★ 场景配置工厂（AutoGo floatball 同架构）：返回主 App 自己的 SceneDelegate。
   Info.plist 的 UIApplicationSceneManifest 触发 scene 生命周期，
   HUD 进程会用自己 AppDelegate 覆盖成 HUDSceneDelegate（共享 bundle 各用各的） */
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                   options:(UISceneConnectionOptions *)options {

    UISceneConfiguration *cfg = [[UISceneConfiguration alloc]
        initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
    cfg.delegateClass = NSClassFromString(@"AilinTouchSceneDelegate");
    return cfg;
}

/* 崩溃日志：App 异常退出时把原因写到 /tmp/ailintouch.crash，
   引擎 /log 可读到（root 能读 /tmp），方便远程定位"悬浮球消失=App 被杀" */
static void write_crash_log(NSString *why) {
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], why];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ailintouch.crash"];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:@"/tmp/ailintouch.crash" contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ailintouch.crash"];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static void crash_handler(NSException *ex) {
    write_crash_log([NSString stringWithFormat:@"EXCEPTION %@ %@ %@",
                     ex.name, ex.reason, ex.userInfo]);
    write_crash_log([NSString stringWithFormat:@"STACK %@",
                     [[ex callStackSymbols] componentsJoinedByString:@" | "]]);
}

/* ★ v1.6.4: 信号级崩溃捕获（SIGABRT/SIGSEGV/SIGBUS）。
   v1.6.3 的 KVC 写私有 ivar 触发 UIKit 内部断言 abort = SIGABRT，
   NSSetUncaughtExceptionHandler 只捕 OC 异常，信号崩溃连 crash 文件都没写
   （用户只看到日志"剩一条引擎 start"）。信号 handler 里只做异步安全的事
   （open/write 是 async-signal-safe），写完后恢复默认 handler 让系统出崩溃报告。 */
static void signal_crash_handler(int sig) {
    int fd = open("/tmp/ailintouch.crash", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        char buf[128];
        int n = snprintf(buf, sizeof(buf), "[%ld] SIGNAL %d\n", (long)time(NULL), sig);
        write(fd, buf, n);
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

/* ★ v1.5.7 照懒人反编译（RootService 0x10004dc5c）方案修复。
   懒人 applicationDidBecomeActive 实际只调 [self.window setHidden:NO] —— 关键
   是【不重建窗口、不重新注册 SBS】！v1.5.5/v1.5.6 的 rebuild 思路完全反了。
   原因：SBS 注册的 contextID 一旦稳定，SpringBoard 不会回收（懒人 BSServiceDomains
   + SBAppIsDaemon + LaunchAtBoot 让 App 永驻，window 永在，context 永活）。
   切后台 SpringBoard 不会销毁 SBS 托管，setHidden:NO 就能恢复显示。
   回前台只 setHidden:NO 即可，跟懒人完全一致。 */
- (void)applicationDidBecomeActive:(UIApplication *)application {
    /* ★ v1.8.9 每次前台都打点（含版本号）：不依赖 didFinish——旧进程被前台化
       不会重走启动流水，用户"启动了app日志也不显示"的根因排查。
       /tmp/ailintouch_app.log 是追加式，每次前台化都能看到时间戳。 */
    [self appTrace:[NSString stringWithFormat:@"foreground ver=%@",
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]]];

    /* ★ v1.8.22 回前台：球窗口绑回 scene（切后台时 detachBallFromScene 脱离的）*/
    [[FloatingWindowManager shared] attachBallToScene];

    [[FloatingWindowManager shared] setWindowVisible:YES];
    /* ★ v1.7.0 关键修复：回前台必须【重新注册 SBS】！
       用户铁证："第一次安装球全局 → App 任何方式进后台 → 永远变内部球"。
       机制：App 进后台时 WindowServer 回收窗口 contextID（cid 变化），
       SBS 注册的旧 cid 失效 → 托管丢失；回前台若不重新注册，球永远内部。
       懒人（daemon）cid 永不变所以注册一次够，我们前台 App cid 会变
       必须回前台重新注册（windowContextID 每次重新取新值）。 */
    [[FloatingWindowManager shared] registerToSpringBoardWithRetry];
}

/* ★ v1.6.9 修复：切后台【绝不隐藏窗口】！
   v1.5.7 加 setWindowVisible:NO 是【自杀行为】——
   SBS registerWindowWithContextID 注册后，SpringBoard 托管的是该 contextID
   对应的窗口画面；窗口 setHidden:YES = 画面消失 = 球从全局消失！
   用户现象铁证："切后台悬浮球全局显示一下就消失"（v1.5.4 前）、
   "有真实点击才全局显示几百ms"（点击→becomeActive→恢复显示→马上又
   inactive→隐藏→消失）——全是 setWindowVisible:NO 干的！
   懒人 didEnterBackground 虽也 setHidden:YES，但懒人是 daemon（永远后台
   运行、无前台态），该分支实际从不执行。我们是前台 App，切后台必然触发，
   绝不能隐藏窗口 —— SBS 托管要靠窗口画面持续存在，切后台只留心跳即可。 */
- (void)applicationDidEnterBackground:(UIApplication *)application {
    /* ★ v1.8.22 切后台让球窗口【脱离 scene】：不隐藏窗口没用（系统在 scene
       不激活时强制隐藏，用户实测：切后台球从全局变 App 内）。
       脱离 scene 后窗口不随 scene 隐藏，保留 contextID + SBS 托管 → 球继续全局。
       回前台 applicationDidBecomeActive 绑回 scene。
       ★ v1.8.40 打点：v1.8.39 实测本回调从未触发（daemon 化 App 不走标准
       前后台转换，ball-detach-scene 从未出现）——心跳兜底在 hbTimer 里。 */
    [self appTrace:@"did-enter-background"];
    [[FloatingWindowManager shared] detachBallFromScene];
}

/* ★ v1.8.40 打点：willResignActive 通常比 didEnterBackground 先触发，
   如果 daemon 化 App 触发这个，提前 detach 更及时 */
- (void)applicationWillResignActive:(UIApplication *)application {
    [self appTrace:@"will-resign-active"];
    [[FloatingWindowManager shared] detachBallFromScene];
}

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
    /* ★ v1.5.9 照 AutoGo 反汇编 _AGSpawnWithRootPreference (0x10001cd38) 铁证提权：
       ① posix_spawnattr_setflags(0x400) = POSIX_SPAWN_SETPERSONA —— v1.5.8 及之前
          setflags(POSIX_SPAWN_SETPGROUP|0x100) 缺这个 flag → persona 设置全部无效
          → 引擎 uid=99 非 root → launchd 装不上 → App 没真正 daemon 化！
       ② set_persona_np(attr, 99, 1) —— 照 AutoGo 原样
       ③ set_persona_uid_np(attr, 0) → root；set_persona_gid_np(attr, 0) → root group
       顺序也照 AutoGo：init → setflags → persona_np → uid → gid */
    posix_spawnattr_setflags(&attr, 0x400);
    posix_spawnattr_set_persona_np(&attr, 99, 1);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    pid_t pid = 0;
    char *argv[] = {(char *)[enginePath UTF8String], NULL};
    int rc = posix_spawn(&pid, [enginePath UTF8String], NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) { NSLog(@"[AilinTouch] spawn failed: %s", strerror(rc)); return -1; }
    NSLog(@"[AilinTouch] engine spawn pid=%d", pid);
    return pid;
}

/* ★ v1.8.25 用户指示：先在 AilinHUD 搞 HTTP server 日志跑通，再管引擎。
   主 App 拉起 AilinHUD（bootrun 模式 = 纯 HTTP server 8081，不调
   UIApplicationMain 不卡）。路径：嵌套在主 bundle 的 AilinHUD.app/AilinHUD。 */
- (void)spawnHudBootrun {
    NSString *bundlePath = [[NSBundle mainBundle] resourcePath];
    NSString *hudPath = [bundlePath stringByAppendingPathComponent:@"AilinHUD.app/AilinHUD"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:hudPath]) {
        [self appTrace:@"hud-binary-missing"];
        return;
    }
    /* 先杀旧 HUD（防多开） */
    pid_t pk;
    char *pka[] = {"/usr/bin/pkill", "-f", "AilinHUD", NULL};
    if (posix_spawn(&pk, "/usr/bin/pkill", NULL, NULL, pka, environ) == 0) {
        int pst = 0;
        waitpid(pk, &pst, 0);
    }
    usleep(200 * 1000);
    pid_t pid = 0;
    char *argv[] = {(char *)[hudPath UTF8String], "bootrun", NULL};
    int rc = posix_spawn(&pid, [hudPath UTF8String], NULL, NULL, argv, environ);
    if (rc == 0) {
        [self appTrace:[NSString stringWithFormat:@"hud-spawned bootrun pid=%d", pid]];
    } else {
        [self appTrace:[NSString stringWithFormat:@"hud-spawn-fail-%s", strerror(rc)]];
    }
}

/* ★ v1.8.6 App 启动阶段日志：写 /tmp/ailintouch_app.log（引擎就绪后 /log
   合并读取）+ NSLog。启动瞬间引擎未就绪 HTTP 不可靠，必须落盘。
   用户铁证"app启动你直接就启动悬浮球跟引擎 也不分先后也不分时间"——
   启动必须分阶段、每阶段打点。 */
- (void)appTrace:(NSString *)msg {
    @try {
        NSString *path = @"/tmp/ailintouch_app.log";
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:path
                                                    contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh) {
            [fh seekToEndOfFile];
            NSDateFormatter *df = [NSDateFormatter new];
            df.dateFormat = @"HH:mm:ss.SSS";
            NSString *line = [NSString stringWithFormat:@"[%@] [app] %@\n",
                              [df stringFromDate:[NSDate date]], msg];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) { }
    NSLog(@"[AilinTouch] %@", msg);
}

/* ★ v1.8.6 阶段2：轮询引擎 HTTP 就绪（/diag 可连 = 引擎完全起来监听 8080）。
   球创建前必须先等引擎就绪 —— 分先后分时间，不许一股脑全启动。
   ★ v1.8.18 改读【就绪标记文件】/tmp/ailintouch_engine_ready（引擎 HID +
   socket + HTTP 全建立后才写）——不依赖引擎 HTTP（v1.8.17 实测引擎消失时
   8080 拒连，HTTP 轮询永远失败）。引擎真正完全建立 = 悬浮球创建时机。 */
- (void)pollEngineReady {
    static int tries = 0;
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/ailintouch_engine_ready"]) {
        [self appTrace:[NSString stringWithFormat:@"phase-2 engine-ready tries=%d", tries]];
        self.engineReady = YES;
        return;
    }
    if (tries++ < 60) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self pollEngineReady];
        });
    } else {
        [self appTrace:@"phase-2 engine-not-ready-giveup"];
    }
}

/* ★ v1.8.6 阶段4：等引擎就绪再建球（超时 9s 也建球，球创建不依赖引擎，
   只是日志通道需要引擎先就绪才能上报） */
- (void)waitEngineReadyThenShowBall:(UIWindowScene *)scene try:(int)tries {
    if (self.engineReady) {
        [self appTrace:@"phase-4 ball-create engine-ready"];
        [[FloatingWindowManager shared] showFloatingBallInScene:scene];
        return;
    }
    if (tries < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self waitEngineReadyThenShowBall:scene try:tries + 1];
        });
    } else {
        [self appTrace:@"phase-4 ball-create engine-timeout-giveup"];
        [[FloatingWindowManager shared] showFloatingBallInScene:scene];
    }
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

    /* ★ v1.8.6 启动分阶段（用户铁证"不分先后也不分时间一股脑全启动"）：
       阶段0 app-start → 阶段1 spawn 引擎 → 阶段2 轮询引擎 HTTP 就绪 →
       阶段3 scene 连接 → 阶段4 引擎就绪后才建球 → 阶段5 binder → 阶段6 SBS 注册。
       每阶段 appTrace 落盘 + 引擎日志带时间戳，跨进程时序一目了然。 */
    [self appTrace:@"phase-0 app-start"];

    /* 崩溃日志：注册 handler，App 被杀原因写到 /tmp 供引擎读取 */
    NSSetUncaughtExceptionHandler(&crash_handler);
    /* ★ v1.6.4: 信号级崩溃捕获（SIGABRT/SIGSEGV/SIGBUS 也写崩溃日志） */
    signal(SIGABRT, signal_crash_handler);
    signal(SIGSEGV, signal_crash_handler);
    signal(SIGBUS, signal_crash_handler);

    /* App 打开上报（无条件）：日志里必须有这条，否则说明 App 没起来/没跑新版本 */
    BOOL stopped = [[NSFileManager defaultManager] fileExistsAtPath:ENGINE_STOPPED];
    NSLog(@"[AilinTouch] app-open stopped=%d ver=%@", stopped,
          [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);

    /* 后台保活（懒人同款）：audio session + 循环静音 → App 退后台不挂起 */
    [self startBackgroundAudioKeepAlive];

    /* ★ iOS 13+ scene 生命周期（AutoGo floatball 同架构）：窗口由
       AilinTouchSceneDelegate 在 scene:willConnect 创建，这里监听它的通知接住 UI */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneReady:)
                                                 name:@"AilinTouchSceneReady"
                                               object:nil];

    /* 阶段1: 拉起引擎（若上次手动停止过，尊重用户选择：不自动拉起） */
    if ([[NSFileManager defaultManager] fileExistsAtPath:ENGINE_STOPPED]) {
        [self appTrace:@"phase-1 engine-stopped-marker, stay down"];
    } else {
        self.enginePid = [self spawnEngineAsRoot];
        [self appTrace:[NSString stringWithFormat:@"phase-1 engine-spawned pid=%d", self.enginePid]];
        /* 阶段2: 轮询引擎 HTTP 就绪（分先后：球创建必须等引擎先起来） */
        [self pollEngineReady];
    }

    /* ★ v1.8.25 用户指示：先跑通 AilinHUD 的 HTTP server 日志（8081），
       再管 touch 引擎。主 App 拉起 AilinHUD（bootrun 纯 HTTP 模式）。 */
    [self spawnHudBootrun];

    /* ★ v1.8.21 状态刷新改为【事件驱动】，删除 30s 定时轮询（用户建议：
       引擎关闭了就刷新一下，为什么非要自动刷新）。
       刷新时机：① 启动首次（下方立即刷新）；② 用户点启动/停止（onTapStart/
       onTapStop 回调内）；③ 用户点手动刷新（onTapRefreshStatus）；④ 进入
       服务管理页面（VC viewWillAppear）。无任何定时轮询。 */
    [self refreshStatus];

    return YES;
}

/* AilinTouchSceneDelegate 建好窗口后回调：接住 VC 引用 + 绑定按钮回调 */
- (void)sceneReady:(NSNotification *)note {
    self.nav = note.userInfo[@"nav"];
    self.controlVC = note.userInfo[@"controlVC"];
    self.serviceVC = note.userInfo[@"serviceVC"];
    UIWindowScene *scene = note.userInfo[@"scene"];

    __weak typeof(self) ws = self;
    /* ★ v1.5.2: 悬浮球点击回调 → 引擎命令（球在 App 内，FloatingWindowManager 管理）。
       onTap 由引擎 HID 全局触摸监控驱动（引擎写 /tmp/ailintouch.touch，
       App 轮询命中球区域触发），后台也能点。 */
    [FloatingWindowManager shared].onTap = ^{
        /* 点击悬浮球 → 通知引擎（后续可扩展为展开菜单/执行命令） */
        [ws forwardToEngine:@"BALL_TAP\n"];
        NSLog(@"[AilinTouch] ball tapped -> engine");
    };

    /* ★ v1.8.3 球回主 App（v1.8.0-1.8.2 独立 AilinHUD 进程路线失败：
       裸进程 UIApplicationMain 卡 booting，懒人 RootCore bootrun 分支
       根本不调 UIApplicationMain 是铁证）。主 App 是正常安装注册的 App，
       scene 合法 → 窗口能拿 contextID + binder 绑系统 root window。
       ★ v1.8.6 阶段4：严格【等引擎就绪后再建球】——分先后分时间
       （用户铁证"不分先后一股脑全启动"）。先等 0.5s 让 scene 稳定
       （懒人 setupHUDWindow 后 dispatch_after(0.5s) 时序），再等引擎
       HTTP 就绪（waitEngineReadyThenShowBall 轮询），最后建球。 */
    [self appTrace:@"phase-3 scene-ready"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self waitEngineReadyThenShowBall:scene try:0];
    });

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
        /* 停止服务：引擎停止 → HUD 进程随之退出 → 悬浮球消失（懒人同款联动） */
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
    NSLog(@"[AilinTouch] scene ready, UI wired");
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
    /* v1.5.2: 窗口在 SceneDelegate 里，AppDelegate.window 是 nil —— 用 keyWindow */
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
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

#pragma mark 后台保活（懒人同款）

- (void)startBackgroundAudioKeepAlive {
    NSError *err = nil;
    /* 声明 playback 会话：App 退后台后系统仍允许播放音频，进程不挂起 */
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                           withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                                 error:&err];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];

    NSString *path = [[NSBundle mainBundle] pathForResource:@"silence" ofType:@"wav"];
    if (!path) {
        NSLog(@"[KeepAlive] silence.wav not in bundle");
        return;
    }
    self.keepAlivePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (!self.keepAlivePlayer) {
        NSLog(@"[KeepAlive] AVAudioPlayer init error: %@", err);
        return;
    }
    self.keepAlivePlayer.numberOfLoops = -1;   /* 无限循环 */
    /* ⚠️ 音量必须 = 1.0：silence.wav 本身是静音（全零 PCM），播放无声音；
       若 volume=0 系统会判定"没有实际播放"→ 不维持后台运行 → 进程挂起 → 悬浮球触摸穿透 */
    self.keepAlivePlayer.volume = 1.0;
    [self.keepAlivePlayer play];
    NSLog(@"[KeepAlive] background audio started (silence loop, vol=1.0)");

    /* 守护：AVAudioPlayer 可能被系统打断/停止（来电、其他 App 抢音频通道），
       一旦停了 App 退后台就挂起 → 悬浮球消失。★ v1.8.11 每 10 秒检查重新播放。 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self startKeepAliveWatchdog];
    });
}

- (void)startKeepAliveWatchdog {
    if (self.keepAlivePlayer && !self.keepAlivePlayer.isPlaying) {
        [self.keepAlivePlayer play];
        NSLog(@"[KeepAlive] player stopped, re-play");
    }
    /* ★ v1.8.20 降频 10s→30s：检查播放状态不需要太频繁（卡顿源之一） */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self startKeepAliveWatchdog];
    });
}

@end
