#!/usr/bin/env bash
# 打包为 Laomac.app (免 Xcode, 仅用 SwiftPM + CommandLineTools)
set -e
cd "$(dirname "$0")"

APP_NAME="Laomac"
APP_DIR="dist/${APP_NAME}.app"

# 旧版本在运行时 codesign 会报 Operation not permitted, 先退出
if pgrep -f "$(pwd)/$APP_DIR/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "==> 检测到 ${APP_NAME} 正在运行, 先退出..."
    pkill -f "$(pwd)/$APP_DIR/Contents/MacOS/$APP_NAME" || true
    sleep 2
fi

echo "==> 编译 release 版本..."
swift build -c release

echo "==> 生成 ${APP_DIR} ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/${APP_NAME}" "$APP_DIR/Contents/MacOS/${APP_NAME}"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Laomac</string>
    <key>CFBundleDisplayName</key>
    <string>Laomac</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.laomac</string>
    <key>CFBundleExecutable</key>
    <string>Laomac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>鼠标手势功能需要监听全局右键拖动事件</string>
    <key>MAC_OPT_SCRIPT</key>
    <string>macos-optimize.sh</string>
</dict>
</plist>
PLIST

# 把优化脚本打包进 app, 供「完整优化脚本」功能调用 (优先仓库内副本, 兼容旧的上级目录布局)
if [ -f macos-optimize.sh ]; then
    cp macos-optimize.sh "$APP_DIR/Contents/Resources/macos-optimize.sh"
    chmod +x "$APP_DIR/Contents/Resources/macos-optimize.sh"
elif [ -f ../macos-optimize.sh ]; then
    cp ../macos-optimize.sh "$APP_DIR/Contents/Resources/macos-optimize.sh"
    chmod +x "$APP_DIR/Contents/Resources/macos-optimize.sh"
fi

# 打包应用图标
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
else
    echo "警告: AppIcon.icns 不存在, 先运行: swift make_icon.swift . && iconutil -c icns AppIcon.iconset -o AppIcon.icns"
fi

# 编译 SMC 读写工具 (充电限制等功能需要, 以 root 运行)
echo "==> 编译 smctool..."
cc -O2 -o "$APP_DIR/Contents/Resources/smctool" smctool.c \
    -framework IOKit -framework CoreFoundation
chmod +x "$APP_DIR/Contents/Resources/smctool"

# 稳定签名: 专用钥匙串 + 本地自签名证书, 签名要求 = identifier + 证书指纹,
# 不随重编译变化, 辅助功能等 TCC 授权一次授予、永久有效。
IDENTITY="Laomac Local Signer"
SIGN_DIR="$(pwd)/signing"
KC="$HOME/Library/Keychains/laomac-sign.keychain-db"
mkdir -p "$SIGN_DIR"

if [ ! -f "$SIGN_DIR/cert.pem" ] || [ ! -f "$SIGN_DIR/key.pem" ]; then
    echo "==> 生成本地签名证书 (一次性)..."
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$SIGN_DIR/key.pem" -out "$SIGN_DIR/cert.pem" \
        -days 3650 -nodes -subj "/CN=$IDENTITY" \
        -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=digitalSignature" >/dev/null 2>&1 || true
fi

SIGNED=0
if [ -f "$SIGN_DIR/cert.pem" ] && [ -f "$SIGN_DIR/key.pem" ]; then
    if [ ! -f "$KC" ]; then
        security create-keychain -p laomac "$KC" >/dev/null 2>&1 || true
        security set-keychain-settings -t 7200 "$KC" >/dev/null 2>&1 || true
    fi
    security unlock-keychain -p laomac "$KC" >/dev/null 2>&1 || true
    # 身份不存在时才导入, 避免重复导入触发钥匙串弹窗
    if ! security find-identity "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
        security import "$SIGN_DIR/cert.pem" -k "$KC" >/dev/null 2>&1 || true
        security import "$SIGN_DIR/key.pem" -k "$KC" -A -T /usr/bin/codesign >/dev/null 2>&1 || true
    fi
    rm -f "$APP_DIR/Contents/MacOS/"*.cstemp 2>/dev/null || true
    if codesign --force --keychain "$KC" -s "$IDENTITY" "$APP_DIR" 2>/dev/null; then
        SIGNED=1
        echo "==> 已用稳定身份签名: $IDENTITY (重编译后辅助功能授权不失效)"
    fi
fi
if [ "$SIGNED" = 0 ]; then
    codesign --force -s - "$APP_DIR"
    echo "警告: 稳定签名不可用, 使用 ad-hoc 签名 (重编译后辅助功能授权会失效)"
fi

# 最终校验: 未签名的包会导致 TCC 授权失效, 直接报错终止
if ! codesign --verify "$APP_DIR" 2>/dev/null; then
    echo "错误: 签名校验失败, 请确认应用未在运行后重试"
    exit 1
fi

echo "==> 完成: $(pwd)/$APP_DIR"
echo "    启动: open $APP_DIR"