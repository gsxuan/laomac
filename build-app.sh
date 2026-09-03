#!/usr/bin/env bash
# 打包为 Laomac.app (免 Xcode, 仅用 SwiftPM + CommandLineTools)
set -e
cd "$(dirname "$0")"

APP_NAME="Laomac"
APP_DIR="dist/${APP_NAME}.app"

# 单一版本号源: 仓库根 VERSION 文件 (release.sh / CI 打包与 gh release tag 均以此为准),
# 可用环境变量 LAOMAC_VERSION 临时覆盖 (CI 从 git tag 推导时使用)
APP_VERSION="${LAOMAC_VERSION:-}"
if [ -z "$APP_VERSION" ] && [ -f VERSION ]; then
    APP_VERSION="$(tr -d '[:space:]' < VERSION)"
fi
APP_VERSION="${APP_VERSION:-1.0}"
APP_BUILD="${APP_BUILD:-$APP_VERSION}"
echo "==> 版本: ${APP_VERSION} (build ${APP_BUILD})"

# 旧版本在运行时 codesign 会报 Operation not permitted, 先退出
if pgrep -f "$(pwd)/$APP_DIR/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "==> 检测到 ${APP_NAME} 正在运行, 先退出..."
    pkill -f "$(pwd)/$APP_DIR/Contents/MacOS/$APP_NAME" || true
    sleep 2
fi

if [ "${LAOMAC_UNIVERSAL:-0}" = "1" ]; then
    # 发布包: arm64 + x86_64 两个切片分别交叉编译后 lipo 合并,
    # 仅靠 CommandLineTools 即可产出通用二进制 (无需 Xcode 的 XCBuild)
    echo "==> 编译通用二进制 (arm64 + x86_64)..."
    mkdir -p .build/universal
    SRCS="$(find Sources -name '*.swift' | sort)"
    for A in arm64 x86_64; do
        echo "    - ${A}"
        swiftc -O -target "${A}-apple-macosx13.0" $SRCS -o ".build/universal/${APP_NAME}-${A}"
    done
    lipo -create -output ".build/universal/${APP_NAME}" \
        .build/universal/${APP_NAME}-arm64 .build/universal/${APP_NAME}-x86_64
    BIN=".build/universal/${APP_NAME}"
else
    echo "==> 编译 release 版本 (本机架构)..."
    swift build -c release
    BIN=".build/release/${APP_NAME}"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/${APP_NAME}"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
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
    <string>${APP_VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
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
# 始终编成通用包: 它是独立的 setuid 二进制, 必须与宿主机架构匹配
echo "==> 编译 smctool (arm64 + x86_64)..."
cc -O2 -arch arm64 -arch x86_64 -DSMCTOOL_VERSION="\"${APP_VERSION}\"" \
    -o "$APP_DIR/Contents/Resources/smctool" smctool.c \
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
echo "    架构: $(lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME")  版本: $APP_VERSION"
echo "    启动: open $APP_DIR"