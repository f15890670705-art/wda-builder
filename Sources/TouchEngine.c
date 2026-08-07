/*
 * TouchEngine.c — HID 触摸注入引擎（iOS 14 兼容版）
 *
 * 依据 iOS 14 实测实现（ZXTouch / PTFakeTouch）修正：
 *  1. IOHIDEventCreateDigitizerEvent       15 参数（iOS 14 签名）
 *  2. IOHIDEventCreateDigitizerFingerEvent 13 参数（iOS 14 签名，坐标归一化 [0,1]）
 *  3. senderID 必须匹配设备真实 digitizer —— 启动后监听真实触摸自动提取，
 *     提取到之前注入事件会被系统静默丢弃（首次需手动摸一下屏幕）
 *  4. 父事件(hand) + 子事件(finger) 两级结构
 */
#include "TouchEngine.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>

static void *io_handle = NULL;
static void *hid_client = NULL;
static int   g_seq = 1000;
static char  g_diag[256] = {0};

static float g_screen_w = 375.0f;
static float g_screen_h = 812.0f;
static volatile uint64_t g_real_sender_id = 0;   /* 从真实触摸提取 */
static int g_require_real_sender = 1;

/* ---------- iOS 14 函数签名 ---------- */
/* IOHIDEventCreateDigitizerEvent(alloc, ts, transducerType, index, identifier,
 *   eventMask, buttonMask, x, y, z, tipPressure, barrelPressure, range, touch, options) */
typedef void* (*fn_CreateDigitizer)(void*, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, uint32_t, uint32_t, uint32_t);
/* IOHIDEventCreateDigitizerFingerEvent(alloc, ts, index, transducerType, eventMask,
 *   x, y, z, tipPressure, twist, range, touch, options) */
typedef void* (*fn_CreateFinger)(void*, uint64_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, uint32_t, uint32_t, uint32_t);
typedef void  (*fn_SetInteger)(void*, void*, int);
typedef void  (*fn_SetFloat)(void*, void*, double);
typedef uint64_t (*fn_GetSenderID)(void*);
typedef void  (*fn_AppendEvent)(void*, void*, int);

static fn_CreateDigitizer p_CreateDigitizer;
static fn_CreateFinger    p_CreateFinger;
static fn_SetInteger      p_SetInteger;
static fn_SetFloat        p_SetFloat;
static fn_GetSenderID     p_GetSenderID;
static fn_AppendEvent     p_AppendEvent;

/* 事件回调：从真实 digitizer 事件提取 senderID */
static void event_callback(void *target, void *refcon, void *sender, void *event) {
    if (g_real_sender_id) return;
    if (!p_GetSenderID || !event) return;
    uint64_t sid = p_GetSenderID(event);
    if (sid) g_real_sender_id = sid;
}

int TouchEngineInit(void) {
    if (hid_client) return 0;

    io_handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!io_handle) { snprintf(g_diag, sizeof(g_diag), "IOKit dlopen failed"); return -1; }

    void* (*cc)(void*) = dlsym(io_handle, "IOHIDEventSystemClientCreate");
    if (!cc) { snprintf(g_diag, sizeof(g_diag), "IOHIDEventSystemClientCreate not found"); return -2; }
    hid_client = cc((void*)kCFAllocatorDefault);
    if (!hid_client) { snprintf(g_diag, sizeof(g_diag), "HID client create failed"); return -3; }

    p_CreateDigitizer = (fn_CreateDigitizer)dlsym(io_handle, "IOHIDEventCreateDigitizerEvent");
    p_CreateFinger    = (fn_CreateFinger)dlsym(io_handle, "IOHIDEventCreateDigitizerFingerEvent");
    p_SetInteger      = (fn_SetInteger)dlsym(io_handle, "IOHIDEventSetIntegerValue");
    p_SetFloat        = (fn_SetFloat)dlsym(io_handle, "IOHIDEventSetFloatValue");
    p_GetSenderID     = (fn_GetSenderID)dlsym(io_handle, "IOHIDEventGetSenderID");
    p_AppendEvent     = (fn_AppendEvent)dlsym(io_handle, "IOHIDEventAppendEvent");

    if (!p_CreateDigitizer || !p_CreateFinger) {
        snprintf(g_diag, sizeof(g_diag), "HID symbols missing (digitizer=%p finger=%p)", (void*)p_CreateDigitizer, (void*)p_CreateFinger);
        return -4;
    }

    /* 注册事件回调，监听真实触摸提取 senderID */
    void* (*regcb)(void*, void*, void*, void*) = dlsym(io_handle, "IOHIDEventSystemClientRegisterEventCallback");
    if (regcb) regcb(hid_client, event_callback, NULL, NULL);

    snprintf(g_diag, sizeof(g_diag), "HID engine ready (tap once to grab senderID)");
    return 0;
}

void TouchEngineSetScreenSize(float w, float h) {
    if (w > 0) g_screen_w = w;
    if (h > 0) g_screen_h = h;
}

const char* TouchEngineDiag(void) {
    /* 动态追加 senderID 状态 */
    if (g_real_sender_id)
        snprintf(g_diag, sizeof(g_diag), "HID ready, senderID=%llx", (unsigned long long)g_real_sender_id);
    else if (hid_client)
        snprintf(g_diag, sizeof(g_diag), "HID ready, waiting senderID (touch screen once)");
    return g_diag;
}

/* phase: 1=down 2=move 3=up */
static void send_digitizer(float x, float y, int phase) {
    if (!hid_client) return;
    if (g_require_real_sender && !g_real_sender_id) return;  /* 未提取到真实 senderID，直接丢弃 */

    uint64_t ts = mach_absolute_time();
    float nx = x / g_screen_w;   /* 归一化 [0,1] */
    float ny = y / g_screen_h;
    if (nx < 0) nx = 0; if (nx > 1) nx = 1;
    if (ny < 0) ny = 0; if (ny > 1) ny = 1;

    /* 事件掩码 / range / touch（iOS 14 约定） */
    uint32_t evMask = 0, range = 0, touch = 0;
    switch (phase) {
        case 1: evMask = 0x3; range = 1; touch = 1; break;  /* down: TOUCH|POSITION */
        case 2: evMask = 0x4; range = 1; touch = 1; break;  /* move: POSITION */
        case 3: evMask = 0x2; range = 0; touch = 0; break;  /* up:   TOUCH */
    }

    /* 父事件：hand（transducerType=3, index=99, identifier=1） */
    void *d = p_CreateDigitizer(NULL, ts, 3, 99, 1, evMask, 0,
        nx, ny, 0, 0, 0, range, touch, 0);
    if (!d) return;

    /* IsDisplayIntegrated = true（ZXTouch 实测值） */
    if (p_SetInteger) p_SetInteger(d, (void*)(uintptr_t)0xb0019, 1);
    if (p_SetInteger) p_SetInteger(d, (void*)(uintptr_t)0xb0007, 0x23);

    /* 子事件：finger（transducerType=2, index=g_seq 递增） */
    void *f = p_CreateFinger(NULL, ts, (uint32_t)(g_seq % 10) + 1, 2, evMask,
        nx, ny, 0, 0.04, 0, range, touch, 0);
    if (f) {
        if (p_AppendEvent) p_AppendEvent(d, f, 0);
        CFRelease(f);
    }

    /* 派发（使用真实 senderID） */
    void (*dp)(void*, void*) = dlsym(io_handle, "IOHIDEventSystemClientDispatchEvent");
    void (*ss)(void*, uint64_t) = dlsym(io_handle, "IOHIDEventSetSenderID");
    if (dp && ss && g_real_sender_id) {
        ss(d, g_real_sender_id);
        dp(hid_client, d);
    }
    CFRelease(d);
    g_seq++;
}

int TouchTap(float x, float y) {
    if (!hid_client || !g_real_sender_id) return -2;
    send_digitizer(x, y, 1);
    usleep(60 * 1000);
    send_digitizer(x, y, 3);
    return 0;
}

int TouchSwipe(float x1, float y1, float x2, float y2, int durationMs) {
    if (!hid_client || !g_real_sender_id) return -2;
    int steps = 20;
    if (durationMs < 50) durationMs = 50;
    int delayUs = (durationMs * 1000) / steps;

    send_digitizer(x1, y1, 1);
    for (int i = 1; i <= steps; i++) {
        float t = (float)i / steps;
        send_digitizer(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, 2);
        usleep(delayUs);
    }
    send_digitizer(x2, y2, 3);
    return 0;
}

int TouchDown(float x, float y)  { if (!hid_client || !g_real_sender_id) return -2; send_digitizer(x, y, 1); return 0; }
int TouchMove(float x, float y)  { if (!hid_client || !g_real_sender_id) return -2; send_digitizer(x, y, 2); return 0; }
int TouchUp(float x, float y)    { if (!hid_client || !g_real_sender_id) return -2; send_digitizer(x, y, 3); return 0; }

int TouchKey(uint16_t usage) {
    return -1;  /* 键盘事件 iOS 14 暂未实现，先用触摸 */
}
