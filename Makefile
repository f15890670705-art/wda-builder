# AilinTouch — Ailin 方式 TrollStore 触摸注入 IPA（root 引擎架构）
#
#   make build  → clang 编译两个二进制（App + touch_engine）
#   make sign   → ldid 分别注入 Entitlements.plist 签名
#   make ipa    → 打包 .ipa
#   make all    → 三步全做
#
# 架构：主 App（HTTP :8080）→ Unix socket → touch_engine（root 进程，HID 注入）
#
# 环境：macOS + Xcode（iphoneos SDK）+ ldid（brew install ldid）
# 无 Mac？用 .github/workflows/build-ipa.yml 在 GitHub Actions 免费云构建

APP_NAME    = AilinTouch
HUD_NAME    = AilinHUD
HUD_BUNDLE  = AilinHUD.app
BUILD_DIR   = build
APP_DIR     = $(BUILD_DIR)/$(APP_NAME).app
HUD_DIR     = $(BUILD_DIR)/$(HUD_BUNDLE)

SDK  = $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
ARCH = arm64
CC   = clang

CFLAGS = -arch $(ARCH) -isysroot $(SDK) -fobjc-arc -Wall \
         -Wno-deprecated-declarations \
         -ISources
LDFLAGS = -arch $(ARCH) -isysroot $(SDK) \
          -framework Foundation -framework UIKit \
          -framework CoreFoundation -framework CoreGraphics \
          -framework IOKit -framework QuartzCore \
          -framework AVFoundation -framework AudioToolbox \
          -F $(SDK)/System/Library/PrivateFrameworks \
          -framework FrontBoardServices -framework FrontBoard

APP_SOURCES  = Sources/main.m Sources/AppDelegate.m \
               Sources/AilinTouchSceneDelegate.m \
               Sources/ATTabBarController.m \
               Sources/ControlPanelViewController.m \
               Sources/ServiceManagerViewController.m \
               Sources/FileViewerViewController.m \
               Sources/LogViewerViewController.m \
               Sources/DirListViewController.m \
               Sources/FloatingBall.m Sources/FloatingWindowManager.m
HUD_SOURCES  = Sources/HUD/main.m Sources/HUD/HUDAppDelegate.m \
               Sources/HUD/HUDBall.m
ENGINE_SOURCE = Sources/touch_engine.c

all: build sign ipa

build:
	@mkdir -p $(APP_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(APP_SOURCES) -o $(APP_DIR)/$(APP_NAME)
	$(CC) $(CFLAGS) $(ENGINE_SOURCE) -o $(APP_DIR)/touch_engine
	# ★ v1.8.1 AilinHUD 独立 .app（照懒人 RootCore 终极铁证重构）：
	#   懒人 RootCore（com.nx.RootCore）= 独立 UIApplication 进程（@_UIApplicationMain
	#   + FBSceneManager 二进制 scene + UIRootWindowScenePresentationBinder）。
	#   独立 bundle id + 【无 SceneManifest = legacy 模式】→ UIApplicationMain
	#   不等 scene 连接 → 不卡 booting（v1.5.0 共享主 bundle+SceneManifest 卡死的根因）。
	#   didFinish 手动建窗口 + FBSceneManager 二进制 scene + binder 绑系统 root window。
	@mkdir -p $(HUD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(HUD_SOURCES) -o $(HUD_DIR)/$(HUD_NAME)
	@cp Resources/HUD/Info.plist $(HUD_DIR)/Info.plist
	@printf 'APPL????' > $(HUD_DIR)/PkgInfo
	@cp Resources/Info.plist $(APP_DIR)/Info.plist
	@cp Resources/AppIcon/*.png $(APP_DIR)/
	@cp Resources/silence.wav $(APP_DIR)/
	@echo "== build done (App + touch_engine + AilinHUD.app) =="

sign:
	@echo "== signing App =="
	ldid -SEntitlements.plist $(APP_DIR)/$(APP_NAME)
	@echo "== signing touch_engine =="
	ldid -SEntitlements.plist $(APP_DIR)/touch_engine
	@echo "== signing AilinHUD =="
	ldid -SEntitlements.plist $(HUD_DIR)/$(HUD_NAME)
	@chmod 755 $(APP_DIR)/touch_engine
	@chmod 755 $(HUD_DIR)/$(HUD_NAME)
	@echo "== verify =="
	@ldid -e $(APP_DIR)/$(APP_NAME) | grep -q "event-dispatch" && echo "OK: App event-dispatch" || echo "WARN: App event-dispatch missing"
	@ldid -e $(APP_DIR)/touch_engine | grep -q "event-dispatch" && echo "OK: engine event-dispatch" || echo "WARN: engine event-dispatch missing"
	@ldid -e $(HUD_DIR)/$(HUD_NAME) | grep -q "accessibility-window-hosting" && echo "OK: HUD accessibility-window-hosting" || echo "WARN: HUD accessibility-window-hosting missing"

ipa:
	@rm -rf $(BUILD_DIR)/Payload
	@mkdir -p $(BUILD_DIR)/Payload
	@cp -R $(APP_DIR) $(BUILD_DIR)/Payload/
	# ★ v1.8.2 修复：AilinHUD.app 必须【嵌套】进主 App bundle（Payload/AilinTouch.app/AilinHUD.app）
	#   —— TrollStore 只安装 Payload 下的主 App，平级 Payload/AilinHUD.app 根本不会装进设备
	#   （v1.8.1 实测 hud_alive=(missing) 根因：引擎找 AilinTouch.app/AilinHUD.app/AilinHUD 不存在）。
	#   嵌套后随主 App 一起安装，引擎 _NSGetExecutablePath 截断主 bundle 路径后天然对上。
	@cp -R $(HUD_DIR) $(BUILD_DIR)/Payload/$(APP_NAME).app/AilinHUD.app
	# PkgInfo —— iOS 安装器要求存在 (8 字节 "APPL????")
	@printf 'APPL????' > $(APP_DIR)/PkgInfo
	@cp $(APP_DIR)/PkgInfo $(BUILD_DIR)/Payload/$(APP_NAME).app/PkgInfo
	# 注入 SDK 字段（覆盖模板里的占位，plutil 不会写数组空写 plist 的语法糖有问题）
	@plutil -insert CFBundleSupportedPlatforms -json '["iPhoneOS"]' $(APP_DIR)/Info.plist 2>/dev/null || \
	  plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' $(APP_DIR)/Info.plist
	@plutil -insert UILaunchScreen -json '{}' $(APP_DIR)/Info.plist 2>/dev/null || \
	  plutil -replace UILaunchScreen -json '{}' $(APP_DIR)/Info.plist
	@cd $(BUILD_DIR) && zip -r $(APP_NAME).ipa Payload -x "*.DS_Store"
	@echo "== ipa: $(BUILD_DIR)/$(APP_NAME).ipa =="

clean:
	@rm -rf $(BUILD_DIR)
	@echo "cleaned"

# 自动递增版本号（patch +1：1.0.0 → 1.0.1 → 1.0.2）并 commit。改完代码后跑一次 make bump 再 push。
bump:
	@VERSION=$$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist) && \
	MAJOR=$$(echo $$VERSION | cut -d. -f1) && \
	MINOR=$$(echo $$VERSION | cut -d. -f2) && \
	PATCH=$$(echo $$VERSION | cut -d. -f3) && \
	NEW=$$MAJOR.$$MINOR.$$((PATCH + 1)) && \
	plutil -replace CFBundleShortVersionString -string "$$NEW" Resources/Info.plist && \
	plutil -replace CFBundleVersion -string "$$NEW" Resources/Info.plist && \
	git add Resources/Info.plist && \
	git commit -m "release: v$$NEW" && \
	echo "✅ bumped to v$$NEW"
