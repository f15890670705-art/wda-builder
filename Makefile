# AilinTouch — Ailin 方式的 TrollStore 触摸注入 IPA
#
#   make build  → clang 编译（iphoneos SDK）
#   make sign   → ldid 注入 Entitlements.plist 签名
#   make ipa    → 打包 .ipa
#   make all    → 三步全做
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

SOURCES = Sources/main.m Sources/AppDelegate.m Sources/TouchEngine.c

all: build sign ipa

build:
	@mkdir -p $(APP_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(SOURCES) -o $(APP_DIR)/$(APP_NAME)
	@cp Resources/Info.plist $(APP_DIR)/Info.plist
	@echo "== build done =="

sign:
	@echo "== signing with Entitlements.plist =="
	ldid -SEntitlements.plist $(APP_DIR)/$(APP_NAME)
	ldid -e $(APP_DIR)/$(APP_NAME) | grep -q "event-dispatch" && echo "OK: event-dispatch entitlement present" || echo "WARN: event-dispatch missing!"

ipa:
	@rm -rf $(BUILD_DIR)/Payload
	@mkdir -p $(BUILD_DIR)/Payload
	@cp -R $(APP_DIR) $(BUILD_DIR)/Payload/
	@cd $(BUILD_DIR) && zip -r $(APP_NAME).ipa Payload -x "*.DS_Store"
	@echo "== ipa: $(BUILD_DIR)/$(APP_NAME).ipa =="

clean:
	@rm -rf $(BUILD_DIR)
	@echo "cleaned"
