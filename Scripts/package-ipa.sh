#!/bin/bash
# package-ipa.sh — 打包 AilinTouch.ipa（校验 ldid 签名后打包）
set -e

APP_NAME="AilinTouch"
BUILD_DIR="build"

echo "[1/3] 校验签名..."
ldid -e "$BUILD_DIR/$APP_NAME.app/$APP_NAME" > /tmp/ailintouch_ent.plist
if ! grep -q "event-dispatch" /tmp/ailintouch_ent.plist; then
  echo "ERROR: entitlements 中缺少 com.apple.private.hid.client.event-dispatch！请先 make sign"
  exit 1
fi
echo "OK: event-dispatch entitlement 已确认"

echo "[2/3] 组装 Payload..."
rm -rf "$BUILD_DIR/Payload"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$BUILD_DIR/$APP_NAME.app" "$BUILD_DIR/Payload/"

echo "[3/3] 打包 IPA..."
cd "$BUILD_DIR"
rm -f "$APP_NAME.ipa"
zip -r "$APP_NAME.ipa" Payload -x "*.DS_Store" > /dev/null
cd ..
echo "完成: $BUILD_DIR/$APP_NAME.ipa"
echo ""
echo "安装：原始 IPA 直接丢 TrollStore（禁止爱思/Sideloadly 重签！）"
