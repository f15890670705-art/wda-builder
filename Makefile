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
BUILD_DIR   = build
APP_DIR     = $(BUILD_DIR)/$(APP_NAME).app

SDK  = $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
ARCH = arm64
CC   = clang

CFLAGS = -arch $(ARCH) -isysroot $(SDK) -fobjc-arc -Wall \
         -Wno-deprecated-declarations \
         -ISources
LDFLAGS = -arch $(ARCH) -isysroot $(SDK) \
          -framework Foundation -framework UIKit \
          -framework CoreFoundation -framework CoreGraphics \
          -framework IOKit -framework QuartzCore

APP_SOURCES  = Sources/main.m Sources/AppDelegate.m \
               Sources/ATTabBarController.m \
               Sources/ControlPanelViewController.m \
               Sources/ServiceManagerViewController.m \
               Sources/FileViewerViewController.m \
               Sources/LogViewerViewController.m
ENGINE_SOURCE = Sources/touch_engine.c

all: build sign ipa

build:
	@mkdir -p $(APP_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(APP_SOURCES) -o $(APP_DIR)/$(APP_NAME)
	$(CC) $(CFLAGS) $(ENGINE_SOURCE) -o $(APP_DIR)/touch_engine
	@cp Resources/Info.plist $(APP_DIR)/Info.plist
	# 复制 AppIcon PNG（Info.plist 用 CFBundleIconFiles 引用 AppIcon60x60 / AppIcon76x76 名字）
	@cp -R Resources/AppIcon/*.png $(APP_DIR)/
	@echo "== build done (App + touch_engine + icons) =="

sign:
	@echo "== signing App =="
	ldid -SEntitlements.plist $(APP_DIR)/$(APP_NAME)
	@echo "== signing touch_engine =="
	ldid -SEntitlements.plist $(APP_DIR)/touch_engine
	@chmod 755 $(APP_DIR)/touch_engine
	@echo "== verify =="
	@ldid -e $(APP_DIR)/$(APP_NAME) | grep -q "event-dispatch" && echo "OK: App event-dispatch" || echo "WARN: App event-dispatch missing"
	@ldid -e $(APP_DIR)/touch_engine | grep -q "event-dispatch" && echo "OK: engine event-dispatch" || echo "WARN: engine event-dispatch missing"

ipa:
	@rm -rf $(BUILD_DIR)/Payload
	@mkdir -p $(BUILD_DIR)/Payload
	@cp -R $(APP_DIR) $(BUILD_DIR)/Payload/
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
