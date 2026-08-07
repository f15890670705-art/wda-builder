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
#include <dispatch/dispatch.h>
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

static void send_digitizer(float x, float y, int phase) {
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
    LOG("dispatch x=%.0f y=%.0f phase=%d", x, y, phase);
}

static void do_tap(float x, float y) { send_digitizer(x, y, 1); usleep(60*1000); send_digitizer(x, y, 3); }
static void do_swipe(float x1, float y1, float x2, float y2, int ms) {
    int steps = 20; if (ms < 50) ms = 50;
    int d = (ms*1000)/steps;
    send_digitizer(x1, y1, 1);
    for (int i = 1; i <= steps; i++) {
        float t = (float)i/steps;
        send_digitizer(x1+(x2-x1)*t, y1+(y2-y1)*t, 2);
        usleep(d);
    }
    send_digitizer(x2, y2, 3);
}

static void handle_client(int cfd) {
    char buf[256] = {0};
    ssize_t n = read(cfd, buf, sizeof(buf)-1);
    if (n <= 0) { close(cfd); return; }
    char cmd[16] = {0}; float a=0,b=0,c=0,d=0; int ms=300;
    sscanf(buf, "%15s %f %f %f %f %d", cmd, &a, &b, &c, &d, &ms);
    char reply[160];
    if (strcmp(cmd, "TAP") == 0 && n > 4) { do_tap(a,b); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "SWIPE") == 0) { do_swipe(a,b,c,d,ms); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "DOWN") == 0) { send_digitizer(a,b,1); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "MOVE") == 0) { send_digitizer(a,b,2); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "UP") == 0)   { send_digitizer(a,b,3); snprintf(reply, sizeof(reply), "OK\n"); }
    else if (strcmp(cmd, "STATUS") == 0) {
        uint64_t s = g_sender_id ? g_sender_id : g_fallback_sender;
        snprintf(reply, sizeof(reply), "engine=ready senderid=%llx fallback=%llx seq=%d\n",
            (unsigned long long)g_sender_id, (unsigned long long)s, g_seq);
    } else snprintf(reply, sizeof(reply), "ERR unknown\n");
    write(cfd, reply, strlen(reply));
    close(cfd);
}

int main(int argc, char *argv[]) {
    logfp = fopen(LOG_PATH, "w");
    LOG("touch_engine start uid=%d", getuid());

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

    /* HID client 已在 hid_init 里 Schedule 到 main runloop；启动 runloop 驱动它 */
    CFRunLoopRun();
    return 0;
}