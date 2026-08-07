/*
 * TouchEngine.c — HID 触摸/键盘注入引擎（Ailin 方式）
 *
 * 核心思路（与 Ailin.ipa 的 goeval 引擎一致）：
 *   App 自身以 platform-application + no-sandbox + HID event-dispatch
 *   entitlement 安装（TrollStore），然后在自己的进程里直接调用
 *   IOHIDEventSystemClientCreate / DispatchEvent 派发 digitizer 事件，
 *   对系统而言与真实手指完全等价。不需要注入 SpringBoard，不需要 root。
 *
 * 所有私有函数通过 dlsym 动态解析，无需私有头文件，clang 直接编译。
 * iOS 14.6 可用（IOHIDEventSystemClient 自 iOS 11 起存在）。
 */
#include "TouchEngine.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>

#define SENDER_ID 0x8000000817319372ULL  /* 与已验证实现一致的 sender id */

static void *io_handle = NULL;
static void *hid_client = NULL;
static int   g_seq = 1000;
static char  g_diag[256] = {0};

/* ---------- 私有函数指针 ---------- */
typedef void* (*fn_CreateDigitizer)(void*, uint64_t, int, int, int, int, int, int, int, int, int,
    double, double, double, double, double, double, double, int, int, int, int, int, int, int, int,
    int, int, int, int, int, int, int, int, long, void*, long);
typedef void* (*fn_CreateFinger)(void*, uint64_t, int, int, int, int, int, double, double, double,
    double, double, double, double, double, double, double, double, double, double, double, double,
    double, double, double, double, double, uint32_t, uint32_t, uint32_t);
typedef void* (*fn_CreateKeyboard)(void*, uint64_t, uint64_t, int, int, int);
typedef void  (*fn_SetInteger)(void*, void*, int);
typedef void  (*fn_SetFloat)(void*, void*, double);
typedef void  (*fn_SetSender)(void*, uint64_t);
typedef void  (*fn_AppendEvent)(void*, void*, int);
typedef void  (*fn_Dispatch)(void*, void*);

static fn_CreateDigitizer p_CreateDigitizer;
static fn_CreateFinger    p_CreateFinger;
static fn_CreateKeyboard  p_CreateKeyboard;
static fn_SetInteger      p_SetInteger;
static fn_SetFloat        p_SetFloat;
static fn_SetSender       p_SetSender;
static fn_AppendEvent     p_AppendEvent;
static fn_Dispatch        p_Dispatch;

int TouchEngineInit(void) {
    if (hid_client) return 0;

    io_handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!io_handle) { snprintf(g_diag, sizeof(g_diag), "IOKit dlopen failed"); return -1; }

    void* (*cc)(void*) = dlsym(io_handle, "IOHIDEventSystemClientCreate");
    if (!cc) { snprintf(g_diag, sizeof(g_diag), "IOHIDEventSystemClientCreate not found"); return -2; }
    hid_client = cc((void*)kCFAllocatorDefault);
    if (!hid_client) { snprintf(g_diag, sizeof(g_diag), "HID client create failed"); return -3; }

    p_CreateDigitizer = (fn_CreateDigitizer)dlsym(io_handle, "IOHIDEventCreateDigitizerEvent");
    p_CreateFinger    = (fn_CreateFinger)dlsym(io_handle, "IOHIDEventCreateDigitizerFingerEventWithQuality");
    p_CreateKeyboard  = (fn_CreateKeyboard)dlsym(io_handle, "IOHIDEventCreateKeyboardEvent");
    p_SetInteger      = (fn_SetInteger)dlsym(io_handle, "IOHIDEventSetIntegerValue");
    p_SetFloat        = (fn_SetFloat)dlsym(io_handle, "IOHIDEventSetFloatValue");
    p_SetSender       = (fn_SetSender)dlsym(io_handle, "IOHIDEventSetSenderID");
    p_AppendEvent     = (fn_AppendEvent)dlsym(io_handle, "IOHIDEventAppendEvent");
    p_Dispatch        = (fn_Dispatch)dlsym(io_handle, "IOHIDEventSystemClientDispatchEvent");

    if (!p_CreateDigitizer || !p_CreateFinger || !p_Dispatch) {
        snprintf(g_diag, sizeof(g_diag), "HID symbols missing (dispatch=%p)", (void*)p_Dispatch);
        return -4;
    }
    snprintf(g_diag, sizeof(g_diag), "HID engine ready");
    return 0;
}

const char* TouchEngineDiag(void) { return g_diag; }

/*
 * phase 约定（与已验证实现一致）：
 *   1 = down（按下）  2 = move（移动）  3 = up（抬起）
 */
static void send_digitizer(float x, float y, int phase) {
    if (!hid_client) return;
    uint64_t ts = mach_absolute_time();

    void *d = p_CreateDigitizer(NULL, ts, 0x0B, 0, 0, 2, 0, 0, 0, 0, 0,
        -0.001, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        g_seq, NULL, 0);
    if (!d) return;

    if (p_SetInteger) p_SetInteger(d, (void*)CFSTR("Digitizer.isDisplayIntegrated"), 1);
    if (p_SetSender)  p_SetSender(d, SENDER_ID);

    void *f = p_CreateFinger(NULL, ts, g_seq, phase, 2, 0, 0,
        0, 0, 0, 0, (double)x, (double)y, 0,
        0.04, 0.04, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0, 0, 0, 0,
        (phase != 3) ? 1 : 0, (phase != 3) ? 1 : 0, 0);
    if (f) {
        if (p_AppendEvent) p_AppendEvent(d, f, 0);
        CFRelease(f);
    }

    p_Dispatch(hid_client, d);
    CFRelease(d);
    g_seq++;
}

int TouchTap(float x, float y) {
    if (!hid_client) return -1;
    send_digitizer(x, y, 1);  /* down */
    usleep(50 * 1000);
    send_digitizer(x, y, 3);  /* up   */
    return 0;
}

int TouchSwipe(float x1, float y1, float x2, float y2, int durationMs) {
    if (!hid_client) return -1;
    int steps = 20;
    if (durationMs < 50) durationMs = 50;
    int delayUs = (durationMs * 1000) / steps;

    send_digitizer(x1, y1, 1);  /* down */
    for (int i = 1; i <= steps; i++) {
        float t = (float)i / steps;
        float x = x1 + (x2 - x1) * t;
        float y = y1 + (y2 - y1) * t;
        send_digitizer(x, y, 2);  /* move */
        usleep(delayUs);
    }
    send_digitizer(x2, y2, 3);  /* up */
    return 0;
}

int TouchDown(float x, float y)  { if (!hid_client) return -1; send_digitizer(x, y, 1); return 0; }
int TouchMove(float x, float y)  { if (!hid_client) return -1; send_digitizer(x, y, 2); return 0; }
int TouchUp(float x, float y)    { if (!hid_client) return -1; send_digitizer(x, y, 3); return 0; }

/*
 * 键盘输入：IOHIDEventCreateKeyboardEvent 发送真实按键事件。
 * usage = HID Usage ID（如 0x04 = a, 0x28 = Enter, 0x2C = Space）
 */
int TouchKey(uint16_t usage) {
    if (!hid_client || !p_CreateKeyboard) return -1;
    uint64_t ts = mach_absolute_time();

    void *down = p_CreateKeyboard(NULL, ts, SENDER_ID, 1, 0, usage);
    if (down) { p_Dispatch(hid_client, down); CFRelease(down); }
    usleep(20 * 1000);
    void *up = p_CreateKeyboard(NULL, ts, SENDER_ID, 0, 0, usage);
    if (up) { p_Dispatch(hid_client, up); CFRelease(up); }
    return 0;
}
