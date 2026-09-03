#!/usr/bin/env bash
# Laomac 一行安装 / 卸载脚本 (无需 gh, 仅用 curl + 系统自带工具)
#
#   curl -fsSL https://raw.githubusercontent.com/gsxuan/laomac/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --version 1.1      # 装指定版本
#   curl -fsSL .../install.sh | bash -s -- --uninstall        # 卸载
#
# 做四件事: 下载 zip → 校验 sha256 → 放进 /Applications 并去 quarantine → 装 setuid SMC 组件
# 特权步骤优先用 sudo; 在 `curl | bash` (无 tty) 下自动改走系统图形授权弹窗。
set -euo pipefail

REPO="gsxuan/laomac"
APP_NAME="Laomac"
INSTALL_DIR="${LAOMAC_INSTALL_DIR:-/Applications}"
HELPER_PATH="/Library/PrivilegedHelperTools/com.local.laomac.smctool"
BUNDLE_ID="com.local.laomac"

VERSION=""
MODE="install"
WANT_HELPER=1
WANT_LAUNCH=1

while [ $# -gt 0 ]; do
    case "$1" in
        --version|-v) VERSION="${2:-}"; shift 2 ;;
        --uninstall|-u) MODE="uninstall"; shift ;;
        --no-helper) WANT_HELPER=0; shift ;;
        --no-launch) WANT_LAUNCH=0; shift ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "未知参数: $1"; exit 2 ;;
    esac
done

say()  { printf '==> %s\n' "$*"; }
warn() { printf '警告: %b\n' "$*" >&2; }
die()  { printf '错误: %b\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Laomac 只支持 macOS"

# ---------- 特权通道 (只判定一次) ----------
# root → 直接执行; sudo 可用 → 走 sudo; 否则 (如 curl | bash 无 tty) 累积命令到临时脚本,
# 最后用 osascript 一次性弹系统授权框执行, 避免每条命令弹一次密码
PRIV_MODE=""
GUI_SCRIPT=""
if [ "$(id -u)" = 0 ]; then
    PRIV_MODE="root"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    PRIV_MODE="sudo"
elif command -v osascript >/dev/null 2>&1; then
    PRIV_MODE="gui"
else
    PRIV_MODE="none"
fi

priv() {
    case "$PRIV_MODE" in
        root) bash -c "$1" ;;
        sudo) sudo bash -c "$1" ;;
        gui)
            [ -n "$GUI_SCRIPT" ] || { GUI_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/laomac-priv.XXXXXX")"; chmod 700 "$GUI_SCRIPT"; }
            printf '%s\n' "$1" >> "$GUI_SCRIPT" ;;
        *) warn "无管理员权限, 跳过: $1"; return 1 ;;
    esac
}

# 执行累积的特权命令 (图形授权只弹一次)
flush_priv() {
    [ "$PRIV_MODE" = "gui" ] || return 0
    [ -n "$GUI_SCRIPT" ] && [ -s "$GUI_SCRIPT" ] || return 0
    say "需要管理员权限, 请在弹出的系统对话框中输入密码"
    osascript -e "do shell script \"/bin/bash $GUI_SCRIPT\" with administrator privileges" >/dev/null \
        || die "管理员授权未通过, 安装未完成"
    rm -f "$GUI_SCRIPT"; GUI_SCRIPT=""
}

# 先以当前用户身份尝试, 真的写不动才提权 (避免装到自己可写目录也弹密码框)
try_priv() {
    bash -c "$1" 2>/dev/null && return 0
    [ "$PRIV_MODE" = "none" ] && { warn "权限不够且无法提权, 跳过: $1"; return 1; }
    say "普通权限失败, 提权重试: $1"
    priv "$1"
}

sha256() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
    else sha256sum "$1" | awk '{print $1}'; fi
}

Q="$(command -v curl)"
[ -n "$Q" ] || die "未找到 curl"

# ---------- 卸载模式 ----------
if [ "$MODE" = "uninstall" ]; then
    say "卸载 $APP_NAME"
    pkill -x "$APP_NAME" 2>/dev/null || true
    [ -d "$INSTALL_DIR/$APP_NAME.app" ] && try_priv "rm -rf '$INSTALL_DIR/$APP_NAME.app'"
    [ -f "$HELPER_PATH" ] && priv "rm -f '$HELPER_PATH'"
    flush_priv
    warn "用户配置 (defaults $BUNDLE_ID) 与手势设置已保留, 需要时手动执行: defaults delete $BUNDLE_ID"
    say "已卸载"
    exit 0
fi

# ---------- 下载 ----------
BASE="https://github.com/$REPO/releases"
if [ -n "$VERSION" ]; then
    ASSET="$APP_NAME-$VERSION.zip"
    URL="$BASE/download/v$VERSION/$ASSET"
else
    ASSET="$APP_NAME-latest.zip"
    URL="$BASE/latest/download/$ASSET"
fi
WORK="$(mktemp -d -t laomac-dl)"
trap 'rm -rf "$WORK" "${GUI_SCRIPT:-}"' EXIT

say "下载 $URL"
"$Q" -fsSL --retry 3 -o "$WORK/$ASSET" "$URL" || die "下载失败 (版本不存在或网络异常): $URL"
"$Q" -fsSL -o "$WORK/sha256.txt" "$BASE/latest/download/$APP_NAME-latest.sha256" 2>/dev/null \
    || "$Q" -fsSL -o "$WORK/sha256.txt" "${URL%.zip}.sha256" 2>/dev/null || warn "拿不到校验和, 跳过完整性验证"

if [ -s "$WORK/sha256.txt" ]; then
    EXPECT="$(awk -v f="$ASSET" '$2 == f {print $1}' "$WORK/sha256.txt")"
    [ -n "$EXPECT" ] || EXPECT="$(awk 'NR==1 {print $1}' "$WORK/sha256.txt")"
    GOT="$(sha256 "$WORK/$ASSET")"
    if [ -n "$EXPECT" ]; then
        [ "$EXPECT" = "$GOT" ] || die "sha256 校验失败\n    期望 $EXPECT\n    实际 $GOT\n    请立即停止使用并核对下载源"
        say "sha256 校验通过"
    fi
fi

say "解压"
ditto -x -k "$WORK/$ASSET" "$WORK/unpacked"
[ -d "$WORK/unpacked/$APP_NAME.app" ] || die "包内未找到 $APP_NAME.app"

# ---------- 安装 ----------
try_priv "mkdir -p '$INSTALL_DIR'"
if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    say "替换旧版本: $INSTALL_DIR/$APP_NAME.app"
    pkill -x "$APP_NAME" 2>/dev/null || true
    try_priv "rm -rf '$INSTALL_DIR/$APP_NAME.app'"
fi
flush_priv
# rm 在前保证幂等: 上一次 cp 失败留下半个目录时, cp -R 会嵌进去变成 Laomac.app/Laomac.app
try_priv "rm -rf '$INSTALL_DIR/$APP_NAME.app' && cp -R '$WORK/unpacked/$APP_NAME.app' '$INSTALL_DIR/'"
# 用 root 拷进以后归属会被改回当前用户, 以便后续升级无需再提权
try_priv "chown -R $(id -u):$(id -g) '$INSTALL_DIR/$APP_NAME.app'" || true

# 自签名/未公证 → 去掉隔离标记, 免得首次打开被 Gatekeeper 拦
try_priv "xattr -dr com.apple.quarantine '$INSTALL_DIR/$APP_NAME.app'" || true

if [ "$WANT_HELPER" = 1 ]; then
    # 预装 setuid SMC 组件, 让风扇/温度功能不必等首次授权
    say "安装 SMC 特权组件 (风扇/温度读写需要)"
    priv "mkdir -p /Library/PrivilegedHelperTools \
          && cp '$INSTALL_DIR/$APP_NAME.app/Contents/Resources/smctool' '$HELPER_PATH' \
          && chown root:wheel '$HELPER_PATH' && chmod 4755 '$HELPER_PATH'" \
        || warn "SMC 组件预装失败, 首次启动 app 时会再弹一次授权"
fi
flush_priv

# ---------- 校验与启动 ----------
codesign --verify --deep "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null \
    && say "签名校验通过" || warn "签名校验未通过 (ad-hoc 签名属正常现象, 不影响使用)"
say "架构: $(lipo -archs "$INSTALL_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || echo 未知)"

if [ "$WANT_LAUNCH" = 1 ]; then
    say "启动 $APP_NAME"
    open "$INSTALL_DIR/$APP_NAME.app" || warn "自动启动失败, 请到「应用程序」里手动打开"
else
    say "已安装: $INSTALL_DIR/$APP_NAME.app"
fi

cat <<'TIP'

首次打开若提示"无法验证开发者": 在访达里右键 Laomac → 打开 → 再点"打开"。
风扇/温度功能需要管理员授权一次 (安装 setuid 组件), 之后永久免密码。
TIP
