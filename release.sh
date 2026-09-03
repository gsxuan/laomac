#!/usr/bin/env bash
# 发布 Laomac 到 GitHub Releases (通用二进制 + dmg/zip + 校验和)
#
# 用法:
#   ./release.sh                # 用 VERSION 文件里的版本号发布
#   ./release.sh v1.2           # 指定 tag (同时写回 VERSION 文件)
#   ./release.sh v1.2 -n        # dry-run: 只打包不上传不建 tag
#   ./release.sh v1.2 -y        # 跳过交互确认 (CI 用)
#   ./release.sh v1.2 --force   # release 已存在时覆盖其资产
#
# CI 里同样调用本脚本: 已存在的 tag 不会被重复创建; release 已存在时默认不覆盖,
# 以本地先发的稳定签名包为准, 避开与 GitHub Actions 之互相抢写。
set -euo pipefail
cd "$(dirname "$0")"

REPO="gsxuan/laomac"
APP_NAME="Laomac"
DIST="dist"

TAG=""
DRY=0
YES=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRY=1 ;;
        -y|--yes) YES=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        v[0-9]*) TAG="$arg" ;;
        *) echo "未知参数: $arg"; exit 2 ;;
    esac
done

VER_FILE="VERSION"
FILE_VER="$(tr -d '[:space:]' < "$VER_FILE" 2>/dev/null || echo "")"
if [ -z "$TAG" ]; then
    [ -n "$FILE_VER" ] || { echo "错误: 未指定 tag 且 $VER_FILE 为空"; exit 1; }
    TAG="v$FILE_VER"
fi
VER="${TAG#v}"
[ "$VER" = "$FILE_VER" ] || echo "$VER" > "$VER_FILE"

echo "==> 发布 $TAG (版本 $VER)"
if [ "$DRY" = 0 ]; then
    command -v gh >/dev/null || { echo "错误: 需要 gh (brew install gh) 并 gh auth login"; exit 1; }
    # CI 里用 workflow 自带的 GH_TOKEN, 不会有 gh auth login 状态
    if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
        gh auth status >/dev/null 2>&1 || { echo "错误: gh 未登录"; exit 1; }
    fi
    DIRTY="$(git status --porcelain)"
    if [ -n "$DIRTY" ]; then
        echo "警告: 工作区有未提交改动, 发布的二进制可能包含未提交代码:"
        echo "$DIRTY" | sed 's/^/    /'
    fi
fi

if [ "$DRY" = 0 ] && [ "$YES" = 0 ] && [ -z "${CI:-}" ]; then
    printf "确认发布 %s 到 %s? [y/N] " "$TAG" "$REPO"
    read -r ans || ans="n"
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; exit 1; }
fi

# ---------- 1. 通用编译 + 打包 ----------
echo "==> 通用编译 (arm64 + x86_64)"
LAOMAC_UNIVERSAL=1 LAOMAC_VERSION="$VER" ./build-app.sh

APP_DIR="$DIST/$APP_NAME.app"
BIN="$APP_DIR/Contents/MacOS/$APP_NAME"
ARCHS="$(lipo -archs "$BIN")"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) echo "错误: 产物不是通用二进制 (当前: $ARCHS)"; exit 1 ;;
esac
echo "==> 架构确认: $ARCHS"

# ---------- 2. dmg (带 Applications 快捷方式, 拖拽即安装) ----------
DMG="$DIST/$APP_NAME-$VER.dmg"
STAGE="$DIST/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# ---------- 3. zip (brew / install.sh 用); latest 别名供固定 URL 使用 ----------
ZIP="$DIST/$APP_NAME-$VER.zip"
LATEST_ZIP="$DIST/$APP_NAME-latest.zip"
LATEST_DMG="$DIST/$APP_NAME-latest.dmg"
rm -f "$ZIP" "$LATEST_ZIP" "$LATEST_DMG"
ditto -c -k --keepParent "$APP_DIR" "$ZIP"
cp "$ZIP" "$LATEST_ZIP"
cp "$DMG" "$LATEST_DMG"

# ---------- 4. 校验和 (install.sh 会验证; 每行只有文件名, 便于 awk 取用) ----------
SHA="$DIST/$APP_NAME-$VER.sha256"
( cd "$DIST" && shasum -a 256 "$APP_NAME-$VER.zip" "$APP_NAME-$VER.dmg" > "$APP_NAME-$VER.sha256" )
cp "$SHA" "$DIST/$APP_NAME-latest.sha256"
cat "$SHA" | sed 's/^/    /'

if [ "$DRY" = 1 ]; then
    echo "==> dry-run 完成, 产物:"
    ls -lh "$DMG" "$ZIP" "$LATEST_ZIP" "$SHA" | awk '{print "    " $5 "\t" $9}'
    exit 0
fi

# ---------- 5. tag ----------
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "==> tag $TAG 已存在, 复用"
elif [ -n "${CI:-}" ]; then
    # CI 不建 tag (runner 上无提交身份也无推送权限), 由本地 git push --tags 触发
    echo "错误: CI 环境下 tag $TAG 不存在, 请先在本地打 tag 后推送"
    exit 1
else
    git add "$VER_FILE"
    if [ -n "$(git diff --cached --name-only)" ]; then
        git commit -m "release: $TAG" >/dev/null
    fi
    git tag -a "$TAG" -m "$APP_NAME $VER"
    git push origin "$TAG"
    echo "==> 已推送 tag $TAG"
fi

# ---------- 6. release notes ----------
NOTES="$DIST/release-notes.md"
PREV="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || echo "")"
{
    echo "### 安装"
    echo ""
    echo "\`\`\`bash"
    echo "curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash"
    echo "\`\`\`"
    echo ""
    echo "或下载 \`$APP_NAME-$VER.dmg\` 拖入「应用程序」。"
    echo "本版本为本地自签名, 未经 Apple 公证, 首次打开若被 Gatekeeper 拦截:"
    echo "在访达里 **右键 Laomac → 打开**, 或执行 \`xattr -dr com.apple.quarantine /Applications/$APP_NAME.app\`。"
    if [ -n "$PREV" ]; then
        echo ""
        echo "### 自 $PREV 以来的改动"
        git log --pretty=format:'- %s (%h)' "$PREV..$TAG"
    fi
} > "$NOTES"

# ---------- 7. 上传 ----------
ASSETS=("$DMG" "$ZIP" "$LATEST_ZIP" "$LATEST_DMG" "$SHA" "$DIST/$APP_NAME-latest.sha256")
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    if [ "$FORCE" = 1 ]; then
        echo "==> release 已存在, --force 指定, 覆盖资产"
        gh release upload "$TAG" "${ASSETS[@]}" -R "$REPO" --clobber
        gh release edit "$TAG" -R "$REPO" --notes-file "$NOTES"
    else
        # 本地与 CI 都能发版, 谁先到算谁; 后到的一方在此空退, 不会把稳定签名包换成 ad-hoc 包
        echo "==> release $TAG 已存在, 不覆盖资产 (需覆盖请加 --force)"
        echo "    https://github.com/$REPO/releases/tag/$TAG"
        exit 0
    fi
else
    gh release create "$TAG" "${ASSETS[@]}" -R "$REPO" \
        --title "$APP_NAME $VER" --notes-file "$NOTES"
fi

echo "==> 完成: https://github.com/$REPO/releases/tag/$TAG"
gh release view "$TAG" -R "$REPO" | sed 's/^/    /'
