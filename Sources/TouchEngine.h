/*
 * TouchEngine.h — HID 触摸/键盘注入引擎接口
 */
#ifndef TOUCH_ENGINE_H
#define TOUCH_ENGINE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 初始化 HID 客户端。返回 0 成功，负值为错误码（用 TouchEngineDiag 看详情） */
int TouchEngineInit(void);

/* 设置屏幕尺寸（逻辑点），用于坐标归一化。App 启动时传入 UIScreen bounds */
void TouchEngineSetScreenSize(float w, float h);

/* 返回诊断信息字符串（初始化失败原因 / ready） */
const char* TouchEngineDiag(void);

/* 单击 */
int TouchTap(float x, float y);

/* 滑动（线性插值，durationMs 毫秒） */
int TouchSwipe(float x1, float y1, float x2, float y2, int durationMs);

/* 多点触控：按下 / 移动 / 抬起（可组合实现长按、捏合等） */
int TouchDown(float x, float y);
int TouchMove(float x, float y);
int TouchUp(float x, float y);

/* 键盘按键（usage = HID Usage ID） */
int TouchKey(uint16_t usage);

#ifdef __cplusplus
}
#endif

#endif
