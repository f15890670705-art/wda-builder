/*
 * touch_engine.c — Ailin 方式 root 权限 HID 注入引擎（iOS 14 兼容）
 *
 * 由主 App 以 posix_spawn + persona(99)/uid 0 拉起，以 root 身份运行。
 * iOS 14 的 backboardd 只接受 root/平台进程派发的 HID 事件——这就是
 * 普通 App 进程注入无效、root 进程注入生效的根本原因（Ailin 引擎同款架构）。
 *
 * 要点：
 *  1. IOHIDEventCreateDigitizerEvent 15 参数（iOS 14 签名）
 *  2. IOHIDEventCreateDigitizerFingerEvent 13 参数，坐标归一化 [0,1]
 *  3. senderID 动态提取：监听真实触摸事件，IOHIDEventGetSenderID 拿设备的
 *     真实 digitizer ID（硬编码 ID 会被系统静默丢弃）——提取到之前注入无效，
 *     首次需手动触摸屏幕一次
 *
 * 协议：Unix socket /tmp/ailintouch.sock
 *   TAP x y           单击
 *   SWIPE x1 y1 x2 y2 ms   滑动
 *   DOWN x y          按下（多点）
 *   MOVE x y          移动
 *   UP x y            抬起
 *   STATUS            返回引擎状态
 * 响应：OK 或 ERR <msg>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <dlfcn.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>

#define SOCK_PATH "/tmp/ailintouch.sock"
#define LOG_PATH  "/var/mobile/ailintouch_engine.log"

static FILE *logfp;
static void dlog(const char *fmt, ...) {
    if (!logfp) return;
    va_list ap; va_start(ap, fmt); vfprintf(logfp, fmt, ap); va_end(ap);
    fprintf(logfp, "\n"); fflush(logfp);
}
#define LOG(fmt, ...) dlog(fmt, ##__VA_ARGS__)

/* ---------- IOKit 动态加载 ---------- */
static void *io_handle;
static void *hid_client;
static uint64_t g_sender_id = 0;
static uint64_t g_fallback_sender = 0;
static int g_seq = 1000;

/* 从 MobileGestalt 取 BootSessionID 并派生一个稳定的 fallback senderID */
static uint64_t boot_session_sender(void) {
    void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (!mg) { LOG("MobileGestalt dlopen failed"); return 0; }
    void* (*copyAnswer)(CFStringRef) = dlsym(mg, "MGCopyAnswer");
    if (!copyAnswer) { LOG("MGCopyAnswer not found"); return 0; }
    CFStringRef bs = copyAnswer(CFSTR("BootSessionID"));
    if (!bs) { LOG("BootSessionID nil"); return 0; }
    char buf[128] = {0};
    CFStringGetCString(bs, buf, sizeof(buf), kCFStringEncodingUTF8);
    CFRelease(bs);
    LOG("BootSessionID='%s'", buf);
    /* 派生 64 位 senderID：FNV-1a hash */
    uint64_t h = 0xcbf29ce484222325ULL;
    for (char *p = buf; *p; p++) { h ^= (unsigned char)*p; h *= 0x100000001b3ULL; }
    h |= 0x0000000080000000ULL;  /* 保持高位特征 */
    return h;
}

typedef void* (*fn_CreateDigitizer)(void*, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, uint32_t, uint32_t, uint32_t);
typedef void* (*fn_CreateFinger)(void*, uint64_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, uint32_t, uint32_t, uint32_t);
typedef uint64_t (*fn_GetSenderID)(void*);
typedef void  (*fn_SetSender)(void*, uint64_t);
typedef void  (*fn_SetInteger)(void*, void*, int);
typedef void  (*fn_AppendEvent)(void*, void*, int);
typedef void  (*fn_Dispatch)(void*, void*);

static fn_CreateDigitizer p_CreateDigitizer;
static fn_CreateFinger    p_CreateFinger;
static fn_GetSenderID     p_GetSenderID;
static fn_SetSender       p_SetSender;
static fn_SetInteger      p_SetInteger;
static fn_AppendEvent     p_AppendEvent;
static fn_Dispatch        p_Dispatch;

/* 事件回调：从真实触摸提取 senderID */
static void event_callback(void *target, void *refcon, void *sender, void *event) {
    if (g_sender_id || !p_GetSenderID || !event) return;
    uint64_t sid = p_GetSenderID(event);
    if (sid) { g_sender_id = sid; LOG("captured real senderID=0x%llx", (unsigned long long)sid); }
}

static int hid_init(void) {
    io_handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!io_handle) { LOG("IOKit dlopen failed"); return -1; }

    void* (*cc)(void*) = dlsym(io_handle, "IOHIDEventSystemClientCreate");
    if (!cc) { LOG("IOHIDEventSystemClientCreate not found"); return -2; }
    hid_client = cc((void*)kCFAllocatorDefault);
    if (!hid_client) { LOG("HID client create failed"); return -3; }

    p_CreateDigitizer = (fn_CreateDigitizer)dlsym(io_handle, "IOHIDEventCreateDigitizerEvent");
    p_CreateFinger    = (fn_CreateFinger)dlsym(io_handle, "IOHIDEventCreateDigitizerFingerEvent");
    p_GetSenderID     = (fn_GetSenderID)dlsym(io_handle, "IOHIDEventGetSenderID");
    p_SetSender       = (fn_SetSender)dlsym(io_handle, "IOHIDEventSetSenderID");
    p_SetInteger      = (fn_SetInteger)dlsym(io_handle, "IOHIDEventSetIntegerValue");
    p_AppendEvent     = (fn_AppendEvent)dlsym(io_handle, "IOHIDEventAppendEvent");
    p_Dispatch        = (fn_Dispatch)dlsym(io_handle, "IOHIDEventSystemClientDispatchEvent");

    if (!p_CreateDigitizer || !p_CreateFinger || !p_Dispatch) {
        LOG("HID symbols missing (digit=%p finger=%p disp=%p)",
            (void*)p_CreateDigitizer, (void*)p_CreateFinger, (void*)p_Dispatch);
        return -4;
    }

    /* 注册回调监听真实触摸提取 senderID */
    void* (*regcb)(void*, void*, void*, void*) = dlsym(io_handle, "IOHIDEventSystemClientRegisterEventCallback");
    if (regcb) regcb(hid_client, event_callback, NULL, NULL);

    /* ⭐ 必须 SetMatching 声明监听的事件类型，否则客户端收不到任何事件。
       注意：字典 key 必须唯一！匹配 digitizer(11) 类型即可捕获真实触摸。 */
    void* (*setm)(void*, CFDictionaryRef) = dlsym(io_handle, "IOHIDEventSystemClientSetMatching");
    if (setm) {
        int digitizerType = 11;  /* kIOHIDEventTypeDigitizer */
        CFStringRef key = CFSTR("IOHIDEventType");
        CFNumberRef val = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &digitizerType);
        CFDictionaryRef dict = CFDictionaryCreate(kCFAllocatorDefault,
            (const void**)&key, (const void**)&val, 1, NULL, NULL);
        setm(hid_client, dict);
        CFRelease(dict);
        CFRelease(val);
        LOG("SetMatching digitizer(11) done");
    } else {
        LOG("WARN: SetMatching not found");
    }

    LOG("HID engine ready, waiting real touch to capture senderID");
    g_fallback_sender = boot_session_sender();
    LOG("fallback senderID=0x%llx", (unsigned long long)g_fallback_sender);
    return 0;
}

/* phase: 1=down 2=move 3=up */
static void send_digitizer(float x, float y, int phase) {
    if (!hid_client) return;
    /* senderID 优先级：真实提取 > boot session fallback。无条件注入。 */
    uint64_t sender = g_sender_id ? g_sender_id : g_fallback_sender;
    if (!sender) { LOG("no senderID available, drop"); return; }

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

    /* 父事件 hand */
    void *d = p_CreateDigitizer(NULL, ts, 3, 99, 1, evMask, 0, nx, ny, 0, 0, 0, range, touch, 0);
    if (!d) return;
    if (p_SetInteger) {
        p_SetInteger(d, (void*)(uintptr_t)0xb0019, 1);
        p_SetInteger(d, (void*)(uintptr_t)0xb0007, 0x23);
    }

    /* 子事件 finger */
    void *f = p_CreateFinger(NULL, ts, (uint32_t)(g_seq % 10) + 1, 2, evMask,
        nx, ny, 0, 0.04, 0, range, touch, 0);
    if (f) {
        if (p_AppendEvent) p_AppendEvent(d, f, 0);
        CFRelease(f);
    }

    if (p_SetSender) p_SetSender(d, sender);
    p_Dispatch(hid_client, d);
    CFRelease(d);
    g_seq++;
}

static void do_tap(float x, float y) {
    send_digitizer(x, y, 1);
    usleep(60 * 1000);
    send_digitizer(x, y, 3);
}
static void do_swipe(float x1, float y1, float x2, float y2, int ms) {
    int steps = 20; if (ms < 50) ms = 50;
    int delayUs = (ms * 1000) / steps;
    send_digitizer(x1, y1, 1);
    for (int i = 1; i <= steps; i++) {
        float t = (float)i / steps;
        send_digitizer(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, 2);
        usleep(delayUs);
    }
    send_digitizer(x2, y2, 3);
}

/* ---------- socket 服务 ---------- */
static void handle_cmd(int fd, const char *line) {
    char cmd[16] = {0};
    float a=0,b=0,c=0,d=0; int ms=300;
    int n = sscanf(line, "%15s %f %f %f %f %d", cmd, &a, &b, &c, &d, &ms);

    if (strcmp(cmd, "TAP") == 0 && n >= 3) {
        do_tap(a, b);
        write(fd, "OK\n", 3);
    } else if (strcmp(cmd, "SWIPE") == 0 && n >= 5) {
        do_swipe(a, b, c, d, ms);
        write(fd, "OK\n", 3);
    } else if (strcmp(cmd, "DOWN") == 0 && n >= 3) {
        send_digitizer(a, b, 1); write(fd, "OK\n", 3);
    } else if (strcmp(cmd, "MOVE") == 0 && n >= 3) {
        send_digitizer(a, b, 2); write(fd, "OK\n", 3);
    } else if (strcmp(cmd, "UP") == 0 && n >= 3) {
        send_digitizer(a, b, 3); write(fd, "OK\n", 3);
    } else if (strcmp(cmd, "STATUS") == 0) {
        char buf[160];
        uint64_t sender = g_sender_id ? g_sender_id : g_fallback_sender;
        snprintf(buf, sizeof(buf), "engine=ready senderid=%llx fallback=%llx seq=%d\n",
            (unsigned long long)g_sender_id, (unsigned long long)sender, g_seq);
        write(fd, buf, strlen(buf));
    } else {
        write(fd, "ERR unknown\n", 12);
    }
}

static void *socket_thread(void *arg) {
    unlink(SOCK_PATH);
    int sfd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, SOCK_PATH);
    if (bind(sfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { LOG("bind fail"); return NULL; }
    if (listen(sfd, 8) < 0) { LOG("listen fail"); return NULL; }
    chmod(SOCK_PATH, 0777);
    LOG("listening on %s (uid=%d)", SOCK_PATH, getuid());

    for (;;) {
        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) continue;
        char buf[256] = {0};
        ssize_t n = read(cfd, buf, sizeof(buf) - 1);
        if (n > 0) handle_cmd(cfd, buf);
        close(cfd);
    }
    return NULL;
}

int main(int argc, char *argv[]) {
    logfp = fopen(LOG_PATH, "w");
    LOG("touch_engine start uid=%d gid=%d", getuid(), getgid());

    if (getuid() != 0) LOG("WARNING: not running as root!");

    int rc = hid_init();
    LOG("hid_init rc=%d", rc);

    pthread_t tid;
    pthread_create(&tid, NULL, socket_thread, NULL);
    pthread_detach(tid);

    /* 保活 */
    for (;;) sleep(3600);
    return 0;
}
