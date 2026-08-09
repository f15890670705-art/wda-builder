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
#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <spawn.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>

extern char **environ;

#define SOCK_PATH "/tmp/ailintouch.sock"
#define DATA_ROOT "/var/mobile/ailintouch"
#define LOG_PATH  DATA_ROOT "/logs/ailintouch_engine.log"
#define LOG_PATH_TMP "/tmp/ailintouch_engine.log"
#define PID_PATH  "/tmp/ailintouch_engine.pid"
#define HTTP_PORT 8080
#define INSTALL_PATH  "/var/mobile/ailintouch_engine"
#define LAUNCHD_PLIST "/Library/LaunchDaemons/com.ailintouch.engine.plist"
#define LAUNCHD_LABEL "com.ailintouch.engine"
#define STOPPED_MARKER "/tmp/ailintouch.stopped"
#define ENGINE_VERSION "1.8.14"

static FILE *logfp;
static void dlog(const char *fmt, ...) {
    if (!logfp) return;
    /* ★ v1.8.14 统一时间戳格式 [HH:mm:ss.SSS]（毫秒，和 App 日志一致），
       跨进程日志才能按时间归并排序。 */
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tmv;
    localtime_r(&tv.tv_sec, &tmv);
    char ts[40];
    snprintf(ts, sizeof(ts), "[%02d:%02d:%02d.%03d]",
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000));
    fprintf(logfp, "%s ", ts);
    va_list ap; va_start(ap, fmt); vfprintf(logfp, fmt, ap); va_end(ap);
    fprintf(logfp, "\n"); fflush(logfp);
}
#define LOG(fmt, ...) dlog(fmt, ##__VA_ARGS__)

/* ---------- v1.8.14 日志归并 ----------
   /log 端点把 app log 与引擎日志【按时间戳归并排序】输出（各自按时间有序，
   两路归并 O(n)），统一 [HH:mm:ss.SSS] 格式，解决时间倒挂/分块拼接。 */
#define LOG_MAX_LINES 1024
#define LOG_MAX_LEN   256
static char log_app_lines[LOG_MAX_LINES][LOG_MAX_LEN];
static char log_eng_lines[LOG_MAX_LINES][LOG_MAX_LEN];

/* 解析行首 [HH:MM:SS.mmm]（兼容旧的 [HH:MM:SS]）→ 自当日 0 点的毫秒数 */
static long long log_ts_ms(const char *line) {
    if (!line || line[0] != '[') return 0;
    int h = 0, m = 0, s = 0, ms = 0;
    if (sscanf(line + 1, "%d:%d:%d", &h, &m, &s) != 3) return 0;
    const char *cl = strchr(line, ']');
    if (cl) {
        for (const char *q = line + 1; q < cl; q++) {
            if (*q == '.') { sscanf(q + 1, "%3d", &ms); break; }
        }
    }
    return ((long long)h * 3600 + (long long)m * 60 + s) * 1000 + ms;
}

/* 读文件到行数组，返回行数 */
static int log_read_lines(const char *path, char lines[][LOG_MAX_LEN], int max) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char *buf = malloc(65536);
    if (!buf) { fclose(f); return 0; }
    size_t n = fread(buf, 1, 65535, f);
    fclose(f);
    buf[n] = 0;
    int cnt = 0;
    char *p = buf;
    while (*p && cnt < max) {
        char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        if (len > 0 && len < LOG_MAX_LEN - 1) {
            memcpy(lines[cnt], p, len);
            lines[cnt][len] = 0;
            cnt++;
        }
        if (!nl) break;
        p = nl + 1;
    }
    free(buf);
    return cnt;
}

/* 创建数据区目录结构（launchd 实例 = root 无 sandbox 可建；App spawn 实例 sandbox 内失败则日志落 /tmp） */
static void ensure_data_dirs(void) {
    const char *dirs[] = {
        DATA_ROOT "/logs",
        DATA_ROOT "/scripts",
        DATA_ROOT "/libs",
        DATA_ROOT "/config",
        DATA_ROOT "/cache",
        DATA_ROOT "/work",
    };
    for (size_t i = 0; i < sizeof(dirs)/sizeof(dirs[0]); i++) {
        mkdir(dirs[i], 0755);
    }
}

static void open_log(void) {
    ensure_data_dirs();
    logfp = fopen(LOG_PATH, "a");
    if (!logfp) {
        /* sandbox 实例（App spawn）写不了 /var/mobile，降级 /tmp */
        logfp = fopen(LOG_PATH_TMP, "a");
        if (!logfp) {
            fprintf(stderr, "[AilinTouch] FATAL: cannot open log (%s / %s): %s\n",
                    LOG_PATH, LOG_PATH_TMP, strerror(errno));
        }
    }
}

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
typedef int   (*fn_GetType)(void*);
typedef long long (*fn_GetInteger)(void*, int);
typedef double (*fn_GetFloat)(void*, int);

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
static fn_GetType         p_GetType;
static fn_GetInteger      p_GetInteger;
static fn_GetFloat        p_GetFloat;

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

/* ---------- 全局触摸监听（懒人 isTouchFromEventInfo 同款） ----------
   root 引擎注册 IOHIDEventSystemClientRegisterEventCallback，监听所有真实触摸，
   把坐标写到 /tmp/ailintouch.touch，App 悬浮球读它判断是否命中球区域。
   这样悬浮球不依赖窗口收触摸（后台窗口触摸 iOS 不路由给后台 App），
   而是引擎在系统层旁听，命中就触发 App 动作 —— 懒人就是这么做的。 */

/* 触摸回调：libIOMobileFramebuffer/IOHID 回调签名
   (void *target, void *refcon, void *sender, IOHIDEventRef event) */
static void touch_evt_cb(void *target, void *refcon, void *sender, void *event) {
    if (!event || !p_GetType) return;
    int t = p_GetType(event);
    if (t != 11) return;                    /* kIOHIDEventTypeDigitizer = 11 */
    if (!p_GetInteger || !p_GetFloat) return;

    /* 阶段：1=began 2=moved 3=ended */
    long long phase = p_GetInteger(event, 0x10007);   /* kIOHIDEventFieldDigitizerPhase */
    if (phase != 1) return;                  /* 只关心手指按下 */

    /* 排除引擎自己注入的事件（senderID 匹配时跳过），只旁听真实手指 */
    if (p_GetSenderID) {
        uint64_t sid = p_GetSenderID(event);
        if (sid && (sid == g_sender_id || sid == g_fallback_sender)) return;
    }

    /* 坐标（points，屏幕物理坐标） */
    double x = p_GetFloat(event, 0x10005);   /* kIOHIDEventFieldDigitizerX */
    double y = p_GetFloat(event, 0x10006);   /* kIOHIDEventFieldDigitizerY */
    if (x < 0 || y < 0) return;

    /* 写共享文件：App 悬浮球轮询读取 */
    FILE *tf = fopen("/tmp/ailintouch.touch", "w");
    if (tf) {
        fprintf(tf, "%.1f %.1f\n", x, y);
        fclose(tf);
    }
}

static int hid_init(void) {
    io_handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!io_handle) { LOG("IOKit dlopen failed"); return -1; }
    void* (*cc)(void*) = dlsym(io_handle, "IOHIDEventSystemClientCreate");
    if (!cc) return -2;

    /* ★ v1.6.6 恢复 touch monitor（点击模块）：v1.6.5 实验版禁用了它导致
       球点击功能失效，用户要求恢复。窗口不绑 scene 的修复保留。 */
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
    p_GetType         = (fn_GetType)dlsym(io_handle, "IOHIDEventGetType");
    p_GetInteger      = (fn_GetInteger)dlsym(io_handle, "IOHIDEventGetIntegerValue");
    p_GetFloat        = (fn_GetFloat)dlsym(io_handle, "IOHIDEventGetFloatValue");

    if (!p_CreateDigitizer || !p_CreateFinger || !p_Dispatch) {
        LOG("HID symbols missing"); return -4;
    }

    if (p_RegCB) {
        /* 注册真实回调：监听所有 digitizer 触摸（引擎 root + event-monitor entitlement） */
        p_RegCB(hid_client, (void*)touch_evt_cb, NULL, NULL);
        LOG("touch monitor registered (floating ball hit-test)");
    }
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

    char reply[131072];   /* ★ v1.8.14 /log 归并输出（app+引擎 400 行，128K）*/
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
            char body[128];
            int bl = snprintf(body, sizeof(body),
                "{\"engine\":\"root ready\",\"senderid\":\"%llx\",\"fallback\":\"%llx\",\"seq\":%d}",
                (unsigned long long)g_sender_id, (unsigned long long)s, g_seq);
            snprintf(reply, sizeof(reply),
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
                bl, body);
        } else if (strncmp(path, "/diag", 5) == 0) {
            /* 诊断：返回 LOG 状态、文件 stat、errno、stopped marker */
            char dbuf[1024];
            struct stat st;
            int exists = (stat(LOG_PATH, &st) == 0);
            int stopped = (access(STOPPED_MARKER, F_OK) == 0);
            snprintf(dbuf, sizeof(dbuf),
                "{\"engine_ver\":\"%s\",\"log_path\":\"%s\",\"log_exists\":%s,\"log_size\":%lld,\"log_open_ok\":%s,\"errno_at_open\":%d,\"stopped_marker\":%s}",
                ENGINE_VERSION, LOG_PATH,
                exists ? "true" : "false",
                exists ? (long long)st.st_size : -1,
                logfp ? "true" : "false",
                logfp ? 0 : errno,
                stopped ? "true" : "false");
            size_t dl = strlen(dbuf);
            snprintf(reply, sizeof(reply),
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                dl, dbuf);
        } else if (strncmp(path, "/applog", 7) == 0) {
            /* App 端状态上报：GET /applog?msg=xxx → 写入引擎日志，远程可查 App 生命周期 */
            const char *msg = strstr(path, "msg=");
            if (msg) {
                msg += 4;
                /* URL 解码到临时缓冲（简单 %xx） */
                char dec[512] = {0};
                size_t di = 0;
                for (; *msg && di < sizeof(dec)-1; msg++) {
                    if (*msg == '%' && msg[1] && msg[2]) {
                        int v = 0;
                        if (sscanf(msg+1, "%2x", &v) == 1) { dec[di++] = (char)v; msg += 2; }
                        else dec[di++] = *msg;
                    } else dec[di++] = *msg;
                }
                LOG("[app] %s", dec);
                snprintf(reply, sizeof(reply), "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{\"ok\":true}");
            } else {
                snprintf(reply, sizeof(reply), "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 21\r\nConnection: close\r\n\r\n{\"ok\":false}");
            }
        } else if (strncmp(path, "/log", 4) == 0) {
            /* ★ v1.8.14 日志整理：app log 与引擎日志【按时间戳归并排序】输出，
               统一 [HH:mm:ss.SSS] 格式，解决 v1.8.13 及之前的时间倒挂
               （app 流水在前、引擎日志在后，12:42 后面跟着 12:50）。 */
            int anc = log_read_lines("/tmp/ailintouch_app.log", log_app_lines, LOG_MAX_LINES);
            int enc = log_read_lines(LOG_PATH, log_eng_lines, LOG_MAX_LINES);
            if (enc == 0) enc = log_read_lines(LOG_PATH_TMP, log_eng_lines, LOG_MAX_LINES);
            /* 两路归并（各自按时间有序） */
            char *out = malloc(131072);
            if (!out) {
                snprintf(reply, sizeof(reply), "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\n\n");
                break;
            }
            size_t ol = 0;
            int i = 0, j = 0;
            while ((i < anc || j < enc) && ol < 131072 - LOG_MAX_LEN) {
                const char *pick = NULL;
                if (i < anc && j < enc) {
                    pick = (log_ts_ms(log_app_lines[i]) <= log_ts_ms(log_eng_lines[j]))
                               ? log_app_lines[i++] : log_eng_lines[j++];
                } else if (i < anc) {
                    pick = log_app_lines[i++];
                } else {
                    pick = log_eng_lines[j++];
                }
                size_t pl = strlen(pick);
                memcpy(out + ol, pick, pl); ol += pl;
                out[ol++] = '\n';
            }
            out[ol] = 0;
            /* 取尾部 400 行 */
            char *tail = out + ol;
            int lines = 0;
            while (tail > out && lines < 400) {
                tail--;
                if (*tail == '\n') lines++;
            }
            if (*tail == '\n') tail++;
            size_t tl = strlen(tail);
            snprintf(reply, sizeof(reply),
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                tl, tail);
            free(out);
        } else if (strncmp(path, "/hud", 4) == 0) {
            /* 远程诊断：HUD 存活标记 + 崩溃 stderr（HUD 是独立进程，这里读它的文件） */
            char hbuf[4096] = {0};
            size_t hn = 0;
            FILE *hf = fopen("/tmp/ailintouch_hud.alive", "r");
            if (hf) {
                hn = fread(hbuf, 1, sizeof(hbuf) - 1, hf);
                fclose(hf);
            }
            char ebu[4096] = {0};
            size_t en = 0;
            FILE *ef = fopen("/tmp/ailintouch_hud.err", "r");
            if (ef) {
                en = fread(ebu, 1, sizeof(ebu) - 1, ef);
                fclose(ef);
            }
            char haux[8192] = {0};
            snprintf(haux, sizeof(haux),
                "hud_alive=%s\nhud_err=%s\n",
                hn > 0 ? hbuf : "(missing)",
                en > 0 ? ebu : "(none)");
            size_t hl = strlen(haux);
            snprintf(reply, sizeof(reply),
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                hl, haux);
        } else if (strncmp(path, "/dir", 4) == 0) {
            /* /dir?path=/var/mobile/ailintouch  列出目录（root 引擎读，App 免 root） */
            char dirp[512] = {0};
            if (sscanf(path, "/dir?path=%511[^\r\n]", dirp) != 1 || dirp[0] != '/') {
                snprintf(reply, sizeof(reply), "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: close\r\n\r\nbad path\n");
            } else {
                DIR *d = opendir(dirp);
                if (!d) {
                    char emsg[256];
                    snprintf(emsg, sizeof(emsg), "error: cannot open %s (%s)\n", dirp, strerror(errno));
                    size_t el = strlen(emsg);
                    snprintf(reply, sizeof(reply),
                        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                        el, emsg);
                } else {
                    /* 收集到字符串：名字+类型+大小，按行 */
                    char dbuf[4096] = {0};
                    size_t off = 0;
                    struct dirent *e;
                    while ((e = readdir(d)) != NULL && off < sizeof(dbuf) - 200) {
                        if (e->d_name[0] == '.') continue;   /* 跳过隐藏 */
                        char full[600];
                        snprintf(full, sizeof(full), "%s/%s", dirp, e->d_name);
                        struct stat st;
                        if (stat(full, &st) == 0) {
                            if (S_ISDIR(st.st_mode))
                                off += snprintf(dbuf + off, sizeof(dbuf) - off, "[D] %s/\n", e->d_name);
                            else
                                off += snprintf(dbuf + off, sizeof(dbuf) - off, "[F] %s  %lld\n", e->d_name, (long long)st.st_size);
                        } else {
                            off += snprintf(dbuf + off, sizeof(dbuf) - off, "[?] %s\n", e->d_name);
                        }
                    }
                    closedir(d);
                    size_t dl = strlen(dbuf);
                    snprintf(reply, sizeof(reply),
                        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                        dl, dbuf);
                }
            }
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

/* ---------- 独立悬浮球进程 AilinHUD（懒人模式核心） ----------
   悬浮球由独立的 AilinHUD 进程画（root 拉起，SBS 注册全局显示）。
   ★★ 照 AutoGo floatball 架构：HUD 二进制直接放在主 App bundle 根目录，
   **共享主 App 的 Info.plist**（bundle id = 已安装的 com.ailintouch.iphone）
   → UIKit 以"已安装 App"身份请求 scene → FrontBoard 认识 → 分配 scene。
   spawn 路径就是主 App bundle 里的 AilinHUD（不做独立 .app、不复制 ——
   独立 bundle FrontBoard 不认，scene 永不分配，v1.3.7-1.4.2 一路的根因）。 */

extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, int, uid_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);

/* v1.8.3: 独立 HUD 进程路线废弃（裸进程 UIApplicationMain 卡 booting），
   本函数保留供参考但不再调用 */
__attribute__((unused))
static void ensure_hud(void) {
    /* 引擎路径（App spawn 时在 App bundle 内）→ 主 App bundle 目录 */
    char self[1024] = {0};
    uint32_t sz = sizeof(self);
    _NSGetExecutablePath(self, &sz);
    char *slash = strrchr(self, '/');
    if (!slash) { LOG("hud: bad self path %s", self); return; }

    /* ★ v1.8.1: AilinHUD 独立 .app（AilinHUD.app/AilinHUD）——
       独立 bundle id + 无 SceneManifest（legacy 模式）→ UIApplicationMain
       不等 scene 连接 → 不卡 booting。AilinHUD.app 打包在 IPA 的
       Payload/AilinHUD.app，运行时拷贝到主 App bundle 目录下
       （AilinTouch.app/AilinHUD.app/AilinHUD）。 */
    char hud_bin[1024];
    snprintf(hud_bin, sizeof(hud_bin), "%.*s/AilinHUD.app/AilinHUD", (int)(slash - self), self);

    /* 若独立 .app 不存在，兜底试 bundle 根目录（旧布局） */
    if (access(hud_bin, X_OK) != 0) {
        char fallback[1024];
        snprintf(fallback, sizeof(fallback), "%.*s/AilinHUD", (int)(slash - self), self);
        if (access(fallback, X_OK) == 0) {
            snprintf(hud_bin, sizeof(hud_bin), "%s", fallback);
        } else {
            LOG("AilinHUD binary missing: %s", hud_bin);
            return;
        }
    }

    /* 先杀旧 HUD（防多开）—— iOS 上 system() 不可用，用 posix_spawn pkill */
    pid_t pk;
    char *pka[] = {"/usr/bin/pkill", "-f", "AilinHUD", NULL};
    if (posix_spawn(&pk, "/usr/bin/pkill", NULL, NULL, pka, environ) == 0) {
        int pst = 0;
        waitpid(pk, &pst, 0);
    }
    usleep(200 * 1000);

    pid_t pid;
    /* ★ v1.8.1 照懒人 RootCore main（0x1000a65c4）：传 "bootrun" 参数 →
       不走 UIApplicationMain 的 scene 等待路径（双保险，legacy 模式 + bootrun） */
    char *argv[] = {(char*)hud_bin, "bootrun", NULL};
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, 0);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | 0x100);
    /* stderr 重定向到 /tmp/ailintouch_hud.err —— HUD 崩溃/启动错误直接落盘，
       引擎 /hud 端点可读（HUD 是独立进程，崩因只能这样拿） */
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 1, "/tmp/ailintouch_hud.err",
                                     O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_addopen(&fa, 2, "/tmp/ailintouch_hud.err",
                                     O_WRONLY | O_CREAT | O_APPEND, 0644);
    int rc = posix_spawn(&pid, hud_bin, &fa, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    if (rc == 0) {
        LOG("AilinHUD spawned pid=%d (%s)", pid, hud_bin);
    } else {
        LOG("AilinHUD spawn failed: %s", strerror(rc));
    }
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
    open_log();  /* 数据区日志，sandbox 实例降级 /tmp */
    LOG("touch_engine v%s start uid=%d ppid=%d", ENGINE_VERSION, getuid(), getppid());

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

    /* ★ v1.8.3 悬浮球回主 App 进程（懒人 RootService 同款架构）：
       懒人 RootCore main 反汇编铁证 —— bootrun 分支【根本不调 UIApplicationMain】！
       posix_spawn 裸进程 + UIApplicationMain 永远卡 booting（v1.8.0-1.8.2 实测
       hud_alive=booting），因为 FrontBoard 不认裸进程身份，scene 服务连不上。
       懒人悬浮球 = RootService（主 App，正常安装注册、scene 合法）didFinish →
       initializeWithHUD → setupHUDWindow 绘制。主 App 内球由 AppDelegate
       sceneReady: 调 FloatingWindowManager showFloatingBallInScene: 创建。
       这里不再 spawn AilinHUD（v1.8.0-1.8.2 的独立进程路线是死路，且会双球/僵尸）。 */
    LOG("hud-in-app mode (v1.8.5), ball in main app, no separate HUD process");

    /* HID client 已在 hid_init 里 Schedule 到 main runloop；启动 runloop 驱动它 */
    CFRunLoopRun();
    return 0;
}