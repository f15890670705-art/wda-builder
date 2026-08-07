# AilinTouch — Ailin 方式的 TrollStore 触摸注入

用 **Ailin.ipa 验证过的方案**实现的 iOS 模拟点击工具：单 App + 系统级 HID 事件注入，TrollStore 安装，HTTP 远程控制，可点击任意前台第三方 App。

## 与旧方案（已归档）的关键差异

| | 旧方案（springboard_hid / touchd） | **本方案（Ailin 方式）** |
|---|---|---|
| 事件注入者 | dylib 注入 SpringBoard / 连 backboardd 服务 | **App 自身进程**（IOHIDEventSystemClient） |
| 权限 key | `iohideventsystem.client.dispatch` 等 | **`com.apple.private.hid.client.event-dispatch`**（Ailin 实际使用） |
| 复杂度 | 需要注入、需要 root、需要 persona | 单二进制，无注入无 root |
| 架构 | Route B/C（多进程） | **单进程**（App + HTTP + TouchEngine） |

## 架构

```
控制端(Node/浏览器) ──HTTP :8080──▶ AilinTouch.app
                                      │
                               TouchEngine.c
                        IOHIDEventSystemClientCreate
                        IOHIDEventCreateDigitizerEvent
                        IOHIDEventSystemClientDispatchEvent
                                      │
                                  系统 HID 队列 → 前台 App 收到"真实手指"事件
```

## 文件结构

| 路径 | 作用 |
|---|---|
| `Entitlements.plist` | ⭐ Ailin 验证过的权限：`event-dispatch`（决定性）+ platform-application + no-sandbox |
| `Sources/TouchEngine.c/.h` | HID 注入引擎：tap / swipe / 多点 / 键盘，dlsym 动态加载无需私有头文件 |
| `Sources/AppDelegate.m` | 裸 socket HTTP 服务（:8080）+ 启动初始化 |
| `Resources/Info.plist` | HideAtLaunch + SBAppIsDaemon + LaunchAtBoot 后台常驻（Ailin 同款） |
| `Makefile` | build / sign / ipa 三段 |
| `.github/workflows/build-ipa.yml` | 无 Mac 时 GitHub Actions 免费云构建 |
| `client/tap.mjs` | Node 控制端 |

## 构建

有 Mac（Xcode + ldid）：
```bash
brew install ldid
make all          # build + sign + ipa → build/AilinTouch.ipa
```

无 Mac：把本目录推到 GitHub 仓库 → Actions → 运行 `Build AilinTouch IPA` → 下载 artifact。

## 安装

1. **原始 IPA 直接丢 TrollStore 安装**——禁止爱思/Sideloadly 重签（会抹掉全部私有 entitlements）
2. 打开 App，界面显示 `TouchEngine: HID engine ready` 和 HTTP 端口

## 使用（设备与控制端同局域网）

```bash
node client/tap.mjs <设备IP> status              # 查引擎状态
node client/tap.mjs <设备IP> tap 180 400         # 点击 (180,400)
node client/tap.mjs <设备IP> swipe 100 200 300 400 500   # 滑动
node client/tap.mjs <设备IP> key 40              # 键盘 Enter
```

HTTP 直连也行：`curl "http://<设备IP>:8080/tap?x=180&y=400"`

## 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| `/status` 返回 `rc=-4 HID symbols missing` | entitlements 没生效 | 确认是 TrollStore 装的原始 IPA，`make sign` 时确认 `event-dispatch` 在 |
| 点击无反应但返回 ok | 权限 key 与系统版本不匹配 | 已同时放入 iOS14 备用 key；仍不行把 `/status` 结果发我 |
| 换包名后装不上 | Info.plist 与 entitlements 的 bundle id 不一致 | 两处同步改 `com.ailintouch.iphone` |

## 合规提示

本工具适用于**你自己持有设备的自动化测试/研究**。请勿用于批量操控他人设备或绕过平台风控的黑灰产用途。
