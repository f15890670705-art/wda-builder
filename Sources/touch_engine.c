/*
 * touch_engine.c — root HID 注入引擎（CFRunLoop + GCD）
 *
 * 全部跑在 main 的 CFRunLoop 上：HID client (IOKit) 和 socket listener (GCD)
 * 都由 runloop 驱动，否则 DispatchEvent 不会真发出去。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <spawn.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>

extern char **environ;

#define SOCK_PATH "/tmp/ailintouch.sock"
#define LOG_PATH  "/tmp/ailintouch_engine.log"
#define PID_PATH  "/tmp/ailintouch_engine.pid"
#define HTTP_PORT 8080
#define INSTALL_PATH  "/var/mobile/ailintouch_engine"
#define LAUNCHD_PLIST "/Library/LaunchDaemons/com.ailintouch.engine.plist"
#define LAUNCHD_LABEL "com.ailintouch.engine"
#define STOPPED_MARKER "/tmp/ailintouch.stopped"
#define ENGINE_VERSION "1.0.9"

static FILE *logfp;
static void dlog(const char *fmt, ...) {
    if (!logfp) return;
    va_list ap; va_start(ap, fmt); vfprintf(logfp, fmt, ap); va_end(ap);
    fprintf(logfp, "\n"); fflush(logfp);
}
#define LOG(fmt, ...) dlog(fmt, ##__VA_ARGS__)

static void *io_handle;
static void *hid_client;
static uint64_t g_sender_id = 0;
static uint64_t g_fallback_sender = 0;
static int g_seq = 1000;
static int g_listen_fd = -1;

typedef void* (*fn_CreateDigitizer)(void*, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, uint32_t, uint32_t, uint32_t);
typedef void* (*fn_CreateFinger)(void*, uint64_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, uint32_t, uint32_t, uint32_t);
typedef void* (*fn_CreateKeyboard)(void*, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t);
typedef uint64_t (*fn_GetSenderID)(void*);
typedef void  (*fn_SetSender)(void*, uint64_t);
typedef void  (*fn_SetInteger)(void*, void*, int);
typedef void  (*fn_AppendEvent)(void*, void*, int);
typedef void  (*fn_Dispatch)(void*, void*);
typedef void  (*fn_SetMatching)(void*, CFDictionaryRef);
typedef void  (*fn_RegCB)(void*, void*, void*, void*);
typedef void  (*fn_Schedule)(void*, CFRunLoopRef, CFStringRef);

static fn_CreateDigitizer p_CreateDigitizer;
static fn_CreateFinger    p_CreateFinger;
static fn_CreateKeyboard  p_CreateKeyboard;
static fn_GetSenderID     p_GetSenderID;
static fn_SetSender       p_SetSender;
static fn_SetInteger      p_SetInteger;
static fn_AppendEvent     p_AppendEvent;
static fn_Dispatch        p_Dispatch;
static fn_SetMatching     p_SetMatching;
static fn_RegCB           p_RegCB;
static fn_Schedule        p_Schedule;

static uint64_t boot_session_sender(void) {
    void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (!mg) return 0;
    void* (*ca)(CFStringRef) = dlsym(mg, "MGCopyAnswer");
    if (!ca) return 0;
    CFStringRef bs = ca(CFSTR("BootSessionID"));
    if (!bs) return 0;
    char buf[128] = {0};
    CFStringGetCString(bs, buf, sizeof(buf), kCFStringEncodingUTF8);
    CFRelease(bs);
    uint64_t h = 0xcbf29ce484222325ULL;
    for (char *p = buf; *p; p++) { h ^= (unsigned char)*p; h *= 0x100000001b3ULL; }
    h |= 0x0000000080000000ULL;
    return h;
}

static int hid_init(void) {
    io_handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!io_handle) { LOG("IOKit dlopen failed"); return -1; }
    void* (*cc)(void*) = dlsym(io_handle, "IOHIDEventSystemClientCreate");
    if (!cc) return -2;
    hid_client = cc((void*)kCFAllocatorDefault);
    if (!hid_client) return -3;

    p_CreateDigitizer = (fn_CreateDigitizer)dlsym(io_handle, "IOHIDEventCreateDigitizerEvent");
    p_CreateFinger    = (fn_CreateFinger)dlsym(io_handle, "IOHIDEventCreateDigitizerFingerEvent");
    p_CreateKeyboard  = (fn_CreateKeyboard)dlsym(io_handle, "IOHIDEventCreateKeyboardEvent");
    p_GetSenderID     = (fn_GetSenderID)dlsym(io_handle, "IOHIDEventGetSenderID");
    p_SetSender       = (fn_SetSender)dlsym(io_handle, "IOHIDEventSetSenderID");
    p_SetInteger      = (fn_SetInteger)dlsym(io_handle, "IOHIDEventSetIntegerValue");
    p_AppendEvent     = (fn_AppendEvent)dlsym(io_handle, "IOHIDEventAppendEvent");
    p_Dispatch        = (fn_Dispatch)dlsym(io_handle, "IOHIDEventSystemClientDispatchEvent");
    p_SetMatching     = (fn_SetMatching)dlsym(io_handle, "IOHIDEventSystemClientSetMatching");
    p_RegCB           = (fn_RegCB)dlsym(io_handle, "IOHIDEventSystemClientRegisterEventCallback");
    p_Schedule        = (fn_Schedule)dlsym(io_handle, "IOHIDEventSystemClientScheduleWithRunLoop");

    if (!p_CreateDigitizer || !p_CreateFinger || !p_Dispatch) {
        LOG("HID symbols missing"); return -4;
    }

    if (p_RegCB) p_RegCB(hid_client, NULL, NULL, NULL);
    if (p_SetMatching) {
        int t = 11;
        CFStringRef k = CFSTR("IOHIDEventType");
        CFNumberRef v = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &t);
        CFDictionaryRef d = CFDictionaryCreate(kCFAllocatorDefault, (const void**)&k, (const void**)&v, 1, NULL, NULL);
        p_SetMatching(hid_client, d);
        CFRelease(d); CFRelease(v);
    }

    /* ⭐ 必须 Schedule 到 main runloop，否则 DispatchEvent 不真发 */
    if (p_Schedule) {
        p_Schedule(hid_client, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        LOG("HID client scheduled on main runloop");
    } else {
        LOG("WARN: ScheduleWithRunLoop not found");
    }

    g_fallback_sender = boot_session_sender();
    if (!g_fallback_sender) g_fallback_sender = 0x8000000817319372ULL;
    LOG("fallback senderID=0x%llx", (unsigned long long)g_fallback_sender);
    LOG("HID engine ready");
    return 0;
}

static void send_digitizer(float x, float y, int phase, int finger_index) {
    if (!hid_client) return;
    uint64_t sender = g_sender_id ? g_sender_id : g_fallback_sender;
    if (!sender) return;

    uint64_t ts = mach_absolute_time();
    float nx = x / 375.0f, ny = y / 812.0f;
    if (nx < 0) nx = 0; if (nx > 1) nx = 1;
    if (ny < 0) ny = 0; if (ny > 1) ny = 1;

    uint32_t evMask = 0, range = 0, touch = 0;
    switch (phase) {
        case 1: evMask = 0x3; range = 1; touch = 1; break;
        case 2: evMask = 0x4; range = 1; touch = 1; break;
        case 3: evMask = 0x2; range = 0; touch = 0; break;
    }

    void *d = p_CreateDigitizer(NULL, ts, 3, 99, 1, evMask, 0, nx, ny, 0, 0, 0, range, touch, 0);
    if (!d) return;
    if (p_SetInteger) {
        p_SetInteger(d, (void*)(uintptr_t)0xb0019, 1);
        p_SetInteger(d, (void*)(uintptr_t)0xb0007, 0x23);
    }
    /* ⭐ finger index 固定：down/up 必须同一 index，否则 up 会被当成另一根手指 */
    void *f = p_CreateFinger(NULL, ts, (uint32_t)finger_index, 2, evMask,
        nx, ny, 0, 0.04, 0, range, touch, 0);
    if (f) {
        if (p_AppendEvent) p_AppendEvent(d, f, 0);
        CFRelease(f);
    }
    if (p_SetSender) p_SetSender(d, sender);
    p_Dispatch(hid_client, d);
    CFRelease(d);
    g_seq++;
    LOG("dispatch x=%.0f y=%.0f phase=%d idx=%d", x, y, phase, finger_index);
}

static void do_tap(float x, float y) { send_digitizer(x, y, 1, 1); usleep(60*1000); send_digitizer(x, y, 3, 1); }
static void do_swipe(float x1, float y1, float x2, float y2, int ms) {
    int steps = 20; if (ms < 50) ms = 50;
    int d = (ms*1000)/steps;
    send_digitizer(x1, y1, 1, 1);
    for (int i = 1; i <= steps; i++) {
        float t = (float)i/steps;
        send_digitizer(x1+(x2-x1)*t, y1+(y2-y1)*t, 2, 1);
        usleep(d);
    }
    send_digitizer(x2, y2, 3, 1);
}

/* ---------- 按键注入（home / 锁屏 / 音量，懒人精灵同款 IOHIDEventCreateKeyboardEvent） ---------- */
static void send_key(uint32_t page, uint32_t usage, int down) {
    if (!hid_client || !p_CreateKeyboard) { LOG("key: client/keyboard sym missing"); return; }
    uint64_t sender = g_sender_id ? g_sender_id : g_fallback_sender;
    if (!sender) return;
    uint64_t ts = mach_absolute_time();
    void *k = p_CreateKeyboard(NULL, ts, page, usage, down, 0);
    if (!k) { LOG("key: create failed page=0x%x usage=0x%x", page, usage); return; }
    /* ⭐ iOS 逆向社区验证：按键事件必须 SetIntegerValue(field=4, 1)，否则 backboardd 不认 */
    if (p_SetInteger) p_SetInteger(k, (void*)(uintptr_t)4, 1);
    if (p_SetSender) p_SetSender(k, sender);
    p_Dispatch(hid_client, k);
    CFRelease(k);
    LOG("key page=0x%x usage=0x%x %s", page, usage, down ? "down" : "up");
}

/* 单击 = down + up，间隔 40ms */
static void do_key_press(uint32_t page, uint32_t usage) {
    send_key(page, usage, 1);
    usleep(40 * 1000);
    send_key(page, usage, 0);
}

/* 常用按键快捷映射（WDA 标准表：0x0C=Consumer；0x40=Home/Menu、0x30=Power、0xE9/0xEA=音量） */
static int do_named_key(const char *name) {
    if (strcmp(name, "home") == 0)       { do_key_press(0x0C, 0x40);   return 1; }  /* Consumer Home/Menu */
    if (strcmp(name, "home2") == 0)      { do_key_press(0x0C, 0x0223); return 1; }  /* Consumer AC Home */
    if (strcmp(name, "lock") == 0)       { do_key_press(0x0C, 0x30);   return 1; }  /* Consumer Power / 锁屏 */
    if (strcmp(name, "volup") == 0)      { do_key_press(0x0C, 0xE9);   return 1; }  /* Volume Increment */
    if (strcmp(name, "voldown") == 0)    { do_key_press(0x0C, 0xEA);   return 1; }  /* Volume Decrement */
    if (strcmp(name, "mute") == 0)       { do_key_press(0x0C, 0xE2);   return 1; }
    return 0;
}

static void handle_client(int cfd) {
    char buf[512] = {0};
    ssize_t n = read(cfd, buf, sizeof(buf)-1);
    if (n <= 0) { close(cfd); return; }

    char reply[256];
    /* HTTP 请求：GET /tap?x=..&y=.. HTTP/1.1 */
    if (strncmp(buf, "GET ", 4) == 0) {
        char path[256] = {0};
        sscanf(buf, "GET %255s", path);
        float a=0,b=0,c=0,d=0; int ms=300;
        if (strncmp(path, "/tap", 4) == 0) {
            sscanf(path, "/tap?x=%f&y=%f", &a, &b);
            do_tap(a,b);
            snprintf(reply, sizeof(reply), "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{\"ok\":true}");
        } else if (strncmp(path, "/swipe", 6) == 0) {
            sscanf(path, "/swipe?x1=%f&y1=%f&x2=%f&y2=%f&ms=%d", &a,&b,&c,&d,&ms);
            do_swipe(a,b,c,d,ms);
            snprintf(reply, sizeof(reply), "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{\"ok\":true}");
        } else if (strncmp(path, "/status", 7) == 0) {
            uint64_t s = g_sender_id ? g_sender_id : g_fallback_sender;
            snprintf(reply, sizeof(reply),
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 200\r\nConnection: close\r\n\r\n"
                "{\"engine\":\"root ready\",\"senderid\":\"%llx\",\"fallback\":\"%llx\",\"seq\":%d}",
                (unsigned long long)g_sender_id, (unsigned long long)s, g_seq);
        } else if (strncmp(path, "/diag", 5) == 0) {
            /* 诊断：返回 LOG 状态、文件 stat、errno */
            char dbuf[1024];
            struct stat st;
            int exists = (stat(LOG_PATH, &st) == 0);
            snprintf(dbuf, sizeof(dbuf),
                "{\"engine_ver\":\"%s\",\"log_path\":\"%s\",\"log_exists\":%s,\"log_size\":%lld,\"log_open_ok\":%s,\"errno_at_open\":%d}",
                ENGINE_VERSION, LOG_PATH,
                exists ? "true" : "false",
                exists ? (long long)st.st_size : -1,
                logfp ? "true" : "false",
                logfp ? 0 : errno);
            size_t dl = strlen(dbuf);
            snprintf(reply, sizeof(reply),
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                dl, dbuf);
        } else if (strncmp(path, "/log", 4) == 0) {
            /* 返回引擎日志尾部 80 行，方便远程排查 */
            char lbuf[8192] = {0};
            size_t ln = 0;
            FILE *lf = fopen(LOG_PATH, "r");
            if (lf) {
                ln = fread(lbuf, 1, sizeof(lbuf) - 1, lf);
                fclose(lf);
            }
            /* 取尾部 */
            char *tail = lbuf + ln;
            int lines = 0;
            while (tail > lbuf && lines < 80) {
                tail--;
                if (*tail == '\n') lines++;
            }
            if (*tail == '\n') tail++;
            size_t tl = strlen(tail);
            snprintf(reply, sizeof(reply),
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                tl, tail);
        } else if (strncmp(path, "/key", 4) == 0) {
            /* /key?name=home 或 /key?page=0xC&usage=0x40 */
            char name[32] = {0};
            unsigned int page = 0, usage = 0;
            if (sscanf(path, "/key?name=%31[a-zA-Z0-9]", name) == 1) {
                if (do_named_key(name)) {
                    snprintf(reply, sizeof(reply), "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{\"ok\":true}");
                } else {
                    snprintf(reply, sizeof(reply), "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 21\r\nConnection: close\r\n\r\n{\"ok\":false}");
                }
            } else if (sscanf(path, "/key?page=%x&usage=%x", &page, &usage) == 2) {
                do_key_press((uint32_t)page, (uint32_t)usage);
                snprintf(reply, sizeof(reply), "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{\"ok\":true}");
            } else {
                snprintf(reply, sizeof(reply), "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 21\r\nConnection: close\r\n\r\n{\"ok\":false}");
            }
        } else {
            snprintf(reply, sizeof(reply), "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 21\r\nConnection: close\r\n\r\n{\"ok\":false}");
        }
        write(cfd, reply, strlen(reply));
        close(cfd);
        return;
    }

    /* 文本命令：TAP x y\n */
    char cmd[16] = {0}; float a=0,b=0,c=0,d=0; int ms=300;
    sscanf(buf, "%15s %f %f %f %f %d", cmd, &a, &b, &c, &d, &ms);
    if (strcmp(cmd, "TAP") == 0 && n > 4) { do_tap(a,b); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "SWIPE") == 0) { do_swipe(a,b,c,d,ms); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "DOWN") == 0) { send_digitizer(a,b,1,1); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "MOVE") == 0) { send_digitizer(a,b,2,1); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "UP") == 0)   { send_digitizer(a,b,3,1); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "HOME") == 0) { do_named_key("home"); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "LOCK") == 0) { do_named_key("lock"); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "VOLUP") == 0)   { do_named_key("volup"); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "VOLDOWN") == 0) { do_named_key("voldown"); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "KEY") == 0 && n > 4) {
        char kname[32] = {0};
        sscanf(buf + 4, "%31s", kname);
        if (do_named_key(kname)) snprintf(reply, sizeof(reply), "OK\n");
        else snprintf(reply, sizeof(reply), "ERR unknown-key\n");
    }
    else if (strcmp(cmd, "STATUS") == 0) {
        uint64_t s = g_sender_id ? g_sender_id : g_fallback_sender;
        snprintf(reply, sizeof(reply), "engine=%s ver=%s senderid=%llx fallback=%llx seq=%d\n",
            "ready", ENGINE_VERSION,
            (unsigned long long)g_sender_id, (unsigned long long)s, g_seq);
    }
    else if (strcmp(cmd, "SHUTDOWN") == 0) {
        /* 停止服务：删除 launchd 配置 + 异步 unload/remove（绝不 waitpid 阻塞——
           否则引擎卡在 GCD 主队列，exit 不执行，8080 一直通）+
           写 stopped 标记，即使 launchd 竞态拉起也会立即退出 */
        snprintf(reply, sizeof(reply), "OK bye\n");
        write(cfd, reply, strlen(reply));
        close(cfd);

        unlink(LAUNCHD_PLIST);                 /* 删配置，防重新 load */
        FILE *mk = fopen(STOPPED_MARKER, "w"); /* 写停止标记 */
        if (mk) { fputs("stopped\n", mk); fclose(mk); }

        /* 异步 unload（不 waitpid），引擎立即退出 */
        pid_t sp1;
        char *la[] = {"/bin/launchctl", "unload", LAUNCHD_PLIST, NULL};
        posix_spawn(&sp1, "/bin/launchctl", NULL, NULL, la, environ);
        /* 双保险：按 label remove（iOS 标准停止 daemon 方式） */
        pid_t sp2;
        char *rm[] = {"/bin/launchctl", "remove", LAUNCHD_LABEL, NULL};
        posix_spawn(&sp2, "/bin/launchctl", NULL, NULL, rm, environ);

        unlink(PID_PATH);
        unlink(SOCK_PATH);
        LOG("SHUTDOWN requested, bye");
        exit(0);
    }
    else snprintf(reply, sizeof(reply), "ERR unknown\n");
    write(cfd, reply, strlen(reply));
    close(cfd);
}

/* 杀旧实例：新引擎启动时清掉残留的旧引擎（重装/重开 App 后孤儿进程清理） */
static void kill_old_instance(void) {
    FILE *pf = fopen(PID_PATH, "r");
    if (pf) {
        int oldpid = 0;
        if (fscanf(pf, "%d", &oldpid) == 1 && oldpid > 0 && oldpid != getpid()) {
            if (kill(oldpid, 0) == 0) {  /* 进程仍存活 */
                kill(oldpid, SIGKILL);
                usleep(200 * 1000);
                LOG("killed old engine pid=%d", oldpid);
            }
        }
        fclose(pf);
    }
    FILE *wf = fopen(PID_PATH, "w");
    if (wf) { fprintf(wf, "%d", getpid()); fclose(wf); }
}

/* 复制自身到固定路径 */
static int copy_self(const char *dst) {
    char self[1024] = {0};
    uint32_t sz = sizeof(self);
    _NSGetExecutablePath(self, &sz);
    if (strcmp(self, dst) == 0) return 0;

    FILE *in = fopen(self, "rb");
    if (!in) { LOG("open self failed: %s", self); return -1; }
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); LOG("open dst failed: %s", dst); return -1; }
    char buf[8192]; size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, n, out);
    fclose(in); fclose(out);
    chmod(dst, 0755);
    LOG("copied self -> %s", dst);
    return 0;
}

/* 安装 launchd 守护进程（开机自启 + KeepAlive 崩溃重启） */
static int ensure_launchd(void) {
    if (copy_self(INSTALL_PATH) != 0) return -1;

    FILE *pf = fopen(LAUNCHD_PLIST, "w");
    if (!pf) { LOG("cannot write %s", LAUNCHD_PLIST); return -1; }
    fprintf(pf,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\">\n<dict>\n"
        "\t<key>Label</key>\n\t<string>%s</string>\n"
        "\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>%s</string>\n\t</array>\n"
        "\t<key>RunAtLoad</key>\n\t<true/>\n"
        "\t<key>KeepAlive</key>\n\t<true/>\n"
        "\t<key>UserName</key>\n\t<string>root</string>\n"
        "</dict>\n</plist>\n", LAUNCHD_LABEL, INSTALL_PATH);
    fclose(pf);
    LOG("wrote %s", LAUNCHD_PLIST);

    /* iOS 14 用 launchctl load -w */
    pid_t pid;
    char *argv[] = {"launchctl", "load", "-w", LAUNCHD_PLIST, NULL};
    int rc = posix_spawn(&pid, "/bin/launchctl", NULL, NULL, argv, environ);
    if (rc != 0) { LOG("launchctl spawn failed: %s", strerror(rc)); return -1; }
    int st = 0;
    waitpid(pid, &st, 0);
    int erc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    LOG("launchctl load rc=%d", erc);
    return 0;
}

int main(int argc, char *argv[]) {
    logfp = fopen(LOG_PATH, "a");  /* append，保留历史日志 */
    if (!logfp) {
        /* fopen 失败（iOS 沙箱/权限），双写 stderr 兜底 + 立刻返回错误给 syscall */
        fprintf(stderr, "[AilinTouch] FATAL: fopen LOG_PATH=%s failed: %s (errno=%d)\n",
                LOG_PATH, strerror(errno), errno);
    }
    LOG("touch_engine v%s start uid=%d ppid=%d errno_at_log_open=%d",
        ENGINE_VERSION, getuid(), getppid(), logfp ? 0 : errno);

    /* 用户手动停止后留下的标记：被 launchd 竞态拉起也立即退出，不提供 HTTP */
    if (access(STOPPED_MARKER, F_OK) == 0) {
        LOG("stopped marker present, exiting");
        return 0;
    }

    int is_launchd = (getppid() == 1);  /* launchd 拉起时父进程是 launchd */

    if (!is_launchd) {
        /* 由 App spawn 的手动实例：
           1) 先 launchctl unload —— 停掉 launchd job，KeepAlive 不再用旧文件副本重启
           2) 再杀旧实例（含 launchd 常驻的旧引擎，否则 8080 一直被旧代码占着）
           3) 覆盖安装 launchd 配置（copy_self 把新二进制拷到 INSTALL_PATH）
           4) 退出交给 launchd 拉起新版本 */
        pid_t sp;
        char *u[] = {"/bin/launchctl", "unload", LAUNCHD_PLIST, NULL};
        if (posix_spawn(&sp, "/bin/launchctl", NULL, NULL, u, environ) == 0) {
            int st = 0;
            waitpid(sp, &st, 0);
            LOG("launchctl unload rc=%d", WIFEXITED(st) ? WEXITSTATUS(st) : -1);
        }
        usleep(200 * 1000);   /* 等 unload 生效，KeepAlive 不再拉旧副本 */
        kill_old_instance();
        usleep(200 * 1000);
        int rc = ensure_launchd();
        if (rc == 0) {
            LOG("handoff to launchd, exiting");
            return 0;
        }
        LOG("launchd install failed, run as manual instance");
    }

    kill_old_instance();  /* 清旧实例（launchd 拉起时清理残留） */

    if (hid_init() != 0) { LOG("hid_init failed"); return 1; }

    unlink(SOCK_PATH);
    g_listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, SOCK_PATH);
    bind(g_listen_fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(g_listen_fd, 8);
    chmod(SOCK_PATH, 0777);

    /* GCD dispatch source 监听 socket，集成到 main queue（驱动 runloop） */
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
        (dispatch_fd_t)g_listen_fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        int cfd = accept(g_listen_fd, NULL, NULL);
        if (cfd >= 0) handle_client(cfd);
    });
    dispatch_resume(src);
    LOG("listening on %s (GCD main queue)", SOCK_PATH);

    /* TCP HTTP 监听 8080 —— root 进程常驻，App 后台/被杀也不影响 */
    int tcp_fd = socket(AF_INET, SOCK_STREAM, 0);
    int on = 1;
    setsockopt(tcp_fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in taddr = {0};
    taddr.sin_family = AF_INET;
    taddr.sin_port = htons(HTTP_PORT);
    taddr.sin_addr.s_addr = INADDR_ANY;
    bind(tcp_fd, (struct sockaddr*)&taddr, sizeof(taddr));
    listen(tcp_fd, 8);

    dispatch_source_t tcp_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
        (dispatch_fd_t)tcp_fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(tcp_src, ^{
        int cfd = accept(tcp_fd, NULL, NULL);
        if (cfd >= 0) handle_client(cfd);
    });
    dispatch_resume(tcp_src);
    LOG("HTTP listening on :%d (root)", HTTP_PORT);

    /* HID client 已在 hid_init 里 Schedule 到 main runloop；启动 runloop 驱动它 */
    CFRunLoopRun();
    return 0;
}