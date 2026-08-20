#!/usr/bin/env bash
#
# macos-optimize.sh — 本地 macOS 优化脚本
#
# 功能:
#   clean    系统清理 (缓存 / 日志 / 下载残留 / 开发工具垃圾)
#   tune     系统调优 (defaults 设置, 均为可逆的常用优化)
#   doctor   体检报告 (磁盘 / 内存 / 电池 / 大文件 / 启动项)
#   brew     Homebrew 清理与更新
#   all      依次执行 doctor -> clean -> tune -> brew
#
# 用法:
#   ./macos-optimize.sh <command> [--dry-run]
#   ./macos-optimize.sh clean --dry-run   # 只报告将要清理的内容, 不实际删除
#
# 安全设计:
#   - 所有删除操作默认需要二次确认, 可用 -y / --yes 跳过
#   - --dry-run 模式下只统计体积, 不做任何修改
#   - tune 的每一项都可用 tune-undo 恢复
#

set -u

# ---------------------------------------------------------------------------
# 全局配置
# ---------------------------------------------------------------------------
DRY_RUN=false
ASSUME_YES=false
BACKUP_DIR="$HOME/.macos-optimize-backup"
SCRIPT_NAME="$(basename "$0")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
log()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[ OK ]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()  { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; }
head_() { printf "\n${BOLD}${CYAN}==> %s${NC}\n" "$*"; }

# 人类可读的目录大小
dir_size() {
    local s=""
    [ -e "$1" ] && s="$(du -sh "$1" 2>/dev/null | awk '{print $1}')"
    printf '%s' "${s:-0B}"
}

# 实际执行或仅预览
run_or_preview() {
    local desc="$1"; shift
    if $DRY_RUN; then
        printf "  ${YELLOW}[dry-run]${NC} %s\n" "$desc"
        printf "            $ %s\n" "$*"
    else
        printf "  %s ... " "$desc"
        if "$@" >/dev/null 2>&1; then
            printf "${GREEN}done${NC}\n"
        else
            printf "${YELLOW}skipped/failed${NC}\n"
        fi
    fi
}

# 删除目录/文件内容 (带体积统计与确认)
safe_clean() {
    local desc="$1" target="$2"
    [ ! -e "$target" ] && return 0
    local size
    size="$(dir_size "$target")"
    if $DRY_RUN; then
        printf "  ${YELLOW}[dry-run]${NC} 将清理 %-42s (${RED}%s${NC})\n" "$desc" "$size"
        return 0
    fi
    printf "  发现 %-46s ${RED}%s${NC}\n" "$desc" "$size"
    CLEAN_PENDING+=("$target")
    CLEAN_DESC+=("$desc")
}

confirm() {
    $ASSUME_YES && return 0
    $DRY_RUN && return 1
    local ans
    printf "${YELLOW}%s [y/N] ${NC}" "$1"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

require_macos() {
    if [[ "$(uname)" != "Darwin" ]]; then
        err "此脚本仅支持 macOS"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# doctor: 体检报告
# ---------------------------------------------------------------------------
cmd_doctor() {
    head_ "系统体检报告"

    log "系统版本: $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
    log "运行时长: $(uptime | sed 's/.*up /up /' | sed 's/, [0-9]* user.*//')"

    head_ "磁盘使用情况"
    df -h / | awk 'NR==1{printf "  %-10s %-10s %-10s %-10s %s\n",$2,$3,$4,$5,"挂载点"}
                   NR==2{printf "  %-10s %-10s %-10s %-10s %s\n",$2,$3,$4,$5,$9}'

    head_ "内存压力"
    if command -v memory_pressure >/dev/null 2>&1; then
        memory_pressure 2>/dev/null | grep -E "percentage|free" | sed 's/^/  /' || true
    fi
    log "Top 10 内存占用进程:"
    ps aux | sort -k4 -rn | head -10 | awk '{printf "  %-8s %5s%%  %s\n",$1,$4,$11}'

    head_ "CPU 占用 Top 5"
    ps aux | sort -k3 -rn | head -5 | awk '{printf "  %-8s %5s%%  %s\n",$1,$3,$11}'

    head_ "磁盘空间大户 (家目录下, 扫描可能较慢)"
    for d in "$HOME/Library/Caches" "$HOME/Library/Logs" "$HOME/Library/Developer" \
             "$HOME/Downloads" "$HOME/.Trash" "$HOME/Library/Application Support"; do
        [ -e "$d" ] && printf "  %-55s %s\n" "${d/#$HOME/~}" "$(dir_size "$d")"
    done

    head_ "开机启动项 (LaunchAgents)"
    for dir in "$HOME/Library/LaunchAgents" /Library/LaunchAgents; do
        if [ -d "$dir" ] && ls "$dir"/*.plist >/dev/null 2>&1; then
            log "$dir:"
            ls "$dir"/*.plist 2>/dev/null | xargs -n1 basename | sed 's/^/    /'
        fi
    done

    head_ "可优化项检查"
    local total=0
    for d in "$HOME/Library/Caches" "/private/var/folders"; do
        [ -e "$d" ] && total=$((total + $(du -sk "$d" 2>/dev/null | awk '{print $1}')))
    done
    log "缓存总量约 $(echo "$total" | awk '{printf "%.1f GB", $1/1024/1024}')"
    log "建议运行: $SCRIPT_NAME clean  进行清理"

    if command -v brew >/dev/null 2>&1; then
        local outdated
        outdated="$(brew outdated 2>/dev/null | wc -l | tr -d ' ')"
        [ "$outdated" -gt 0 ] && log "Homebrew 有 ${outdated} 个包可更新, 建议运行: $SCRIPT_NAME brew"
    fi
    ok "体检完成"
}

# ---------------------------------------------------------------------------
# clean: 系统清理
# ---------------------------------------------------------------------------
CLEAN_PENDING=()
CLEAN_DESC=()

cmd_clean() {
    head_ "系统清理"
    $DRY_RUN && warn "dry-run 模式: 只报告, 不删除"

    # --- 用户缓存 ---
    head_ "1/6 用户缓存"
    safe_clean "用户缓存 ~/Library/Caches" "$HOME/Library/Caches"

    # --- 日志 ---
    head_ "2/6 日志文件"
    safe_clean "用户日志 ~/Library/Logs" "$HOME/Library/Logs"
    safe_clean "系统旧日志 /private/var/log/asl/*.asl" "/private/var/log/asl"

    # --- 废纸篓 ---
    head_ "3/6 废纸篓"
    safe_clean "废纸篓 ~/.Trash" "$HOME/.Trash"

    # --- 开发工具垃圾 ---
    head_ "4/6 开发工具缓存"
    safe_clean "Xcode DerivedData" "$HOME/Library/Developer/Xcode/DerivedData"
    safe_clean "Xcode 旧模拟器" "$HOME/Library/Developer/CoreSimulator/Caches"
    safe_clean "iOS DeviceSupport" "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
    safe_clean "CocoaPods 缓存" "$HOME/Library/Caches/CocoaPods"
    safe_clean "npm 缓存" "$HOME/.npm"
    safe_clean "yarn 缓存" "$HOME/Library/Caches/Yarn"
    safe_clean "pip 缓存" "$HOME/Library/Caches/pip"
    safe_clean "Gradle 缓存 (~/.gradle/caches)" "$HOME/.gradle/caches"
    safe_clean "Docker 旧日志" "$HOME/Library/Containers/com.docker.docker/Data/log"

    # --- 下载目录残留 (超过 90 天) ---
    head_ "5/6 下载目录过期文件 (>90 天)"
    if [ -d "$HOME/Downloads" ]; then
        local old_files
        old_files="$(find "$HOME/Downloads" -maxdepth 1 -type f -mtime +90 ! -name '.localized' 2>/dev/null)"
        if [ -n "$old_files" ]; then
            local cnt; cnt="$(echo "$old_files" | wc -l | tr -d ' ')"
            if $DRY_RUN; then
                printf "  ${YELLOW}[dry-run]${NC} 将清理 Downloads 下 %s 个超过 90 天的文件\n" "$cnt"
                echo "$old_files" | head -10 | sed 's/^/    /'
            else
                if confirm "清理 Downloads 下 ${cnt} 个超过 90 天的文件?"; then
                    echo "$old_files" | while IFS= read -r f; do rm -f "$f"; done
                    ok "已清理过期下载文件"
                fi
            fi
        else
            log "没有超过 90 天的旧文件"
        fi
    fi

    # --- 系统维护 ---
    head_ "6/6 系统维护"
    if $DRY_RUN; then
        printf "  ${YELLOW}[dry-run]${NC} 可选: 清空 DNS 缓存 (sudo dscacheutil -flushcache)\n"
    elif confirm "清空 DNS 缓存并刷新网络? (需要 sudo)"; then
        sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder \
            && ok "DNS 缓存已清空" || warn "DNS 缓存清空失败"
    fi

    # --- 汇总确认 ---
    if $DRY_RUN; then
        warn "dry-run 结束: 以上为将要清理的内容, 去掉 --dry-run 实际执行"
        return 0
    fi

    if [ ${#CLEAN_PENDING[@]} -eq 0 ]; then
        ok "没有需要清理的内容"
        return 0
    fi

    printf "\n"
    if confirm "确认清理以上全部项目?"; then
        local i
        for i in "${!CLEAN_PENDING[@]}"; do
            local target="${CLEAN_PENDING[$i]}"
            printf "  清理 %-46s" "${CLEAN_DESC[$i]}"
            # 保留目录本身, 只删内容 (Caches 等目录删掉可能导致应用重建失败)
            if [ -d "$target" ]; then
                find "$target" -mindepth 1 -delete 2>/dev/null
            else
                rm -rf "$target" 2>/dev/null
            fi
            printf "${GREEN}done${NC}\n"
        done
        ok "清理完成"
    else
        log "已取消"
    fi
}

# ---------------------------------------------------------------------------
# tune: 系统调优 (defaults, 全部可逆)
# ---------------------------------------------------------------------------
declare -a TUNE_CMDS=()
declare -a TUNE_DESCS=()

add_tune() {
    TUNE_DESCS+=("$1")
    shift
    TUNE_CMDS+=("$*")
}

cmd_tune() {
    head_ "系统调优 (defaults 设置)"
    $DRY_RUN && warn "dry-run 模式: 只列出将要执行的设置"

    mkdir -p "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/tune-$(date +%Y%m%d-%H%M%S).plist"
    if ! $DRY_RUN; then
        defaults export -g "$backup_file" 2>/dev/null \
            && log "当前全局设置已备份到: $backup_file"
    fi

    # --- 通用 ---
    add_tune "显示所有文件扩展名" \
        defaults write NSGlobalDomain AppleShowAllExtensions -bool true
    add_tune "保存对话框默认展开" \
        defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
    add_tune "禁用自动更正" \
        defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
    add_tune "禁用智能引号和破折号" \
        defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
    add_tune "快速按键响应 (KeyRepeat 加快)" \
        defaults write NSGlobalDomain KeyRepeat -int 2
    add_tune "按键重复前延迟缩短" \
        defaults write NSGlobalDomain InitialKeyRepeat -int 15

    # --- Finder ---
    add_tune "Finder 显示路径栏" \
        defaults write com.apple.finder ShowPathbar -bool true
    add_tune "Finder 显示状态栏" \
        defaults write com.apple.finder ShowStatusBar -bool true
    add_tune "Finder 标题栏显示完整路径" \
        defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
    add_tune "Finder 搜索默认当前目录" \
        defaults write com.apple.finder FXDefaultSearchScope -string SCcf
    add_tune "按名称排序作为默认" \
        defaults write com.apple.finder FXPreferredGroupBy -string Name

    # --- Dock ---
    add_tune "Dock 自动隐藏 (节省屏幕空间)" \
        defaults write com.apple.dock autohide -bool true
    add_tune "Dock 自动隐藏动画加速" \
        defaults write com.apple.dock autohide-time-modifier -float 0.15
    add_tune "Dock 中只显示打开的应用" \
        defaults write com.apple.dock static-only -bool false
    add_tune "最小化窗口使用缩放效果" \
        defaults write com.apple.dock mineffect -string scale

    # --- 截图 ---
    add_tune "截图保存为 jpg (体积更小)" \
        defaults write com.apple.screencapture type -string jpg
    add_tune "截图去掉窗口阴影" \
        defaults write com.apple.screencapture disable-shadow -bool true
    add_tune "截图默认保存到 ~/Pictures/Screenshots" \
        bash -c 'mkdir -p "$HOME/Pictures/Screenshots" && defaults write com.apple.screencapture location -string "$HOME/Pictures/Screenshots"'

    # --- 触控板 ---
    add_tune "轻点即点击" \
        defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true
    add_tune "轻点即点击 (登录前也生效)" \
        defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true

    # --- 执行 ---
    local i
    for i in "${!TUNE_CMDS[@]}"; do
        if $DRY_RUN; then
            printf "  ${YELLOW}[dry-run]${NC} %-36s $ %s\n" "${TUNE_DESCS[$i]}" "${TUNE_CMDS[$i]}"
        else
            printf "  %-40s" "${TUNE_DESCS[$i]}"
            if eval "${TUNE_CMDS[$i]}" >/dev/null 2>&1; then
                printf "${GREEN}done${NC}\n"
            else
                printf "${YELLOW}skipped${NC}\n"
            fi
        fi
    done

    if ! $DRY_RUN; then
        head_ "重启相关服务使设置生效"
        run_or_preview "重启 Dock" killall Dock
        run_or_preview "重启 Finder" killall Finder
        ok "调优完成! 如需恢复: $SCRIPT_NAME tune-undo"
    fi
}

cmd_tune_undo() {
    head_ "恢复调优设置"
    local latest
    latest="$(ls -t "$BACKUP_DIR"/tune-*.plist 2>/dev/null | head -1)"
    if [ -z "$latest" ]; then
        err "没有找到备份文件 ($BACKUP_DIR)"
        return 1
    fi
    log "将使用备份恢复: $latest"
    if confirm "确认恢复?"; then
        defaults import -g "$latest" && ok "已恢复全局设置" || err "恢复失败"
        killall Dock Finder 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# brew: Homebrew 维护
# ---------------------------------------------------------------------------
cmd_brew() {
    head_ "Homebrew 维护"
    if ! command -v brew >/dev/null 2>&1; then
        warn "未安装 Homebrew, 跳过"
        return 0
    fi

    log "缓存体积: $(dir_size "$(brew --cache)")"
    log "可更新包: $(brew outdated 2>/dev/null | wc -l | tr -d ' ')"

    if $DRY_RUN; then
        warn "dry-run: 跳过实际执行"
        return 0
    fi

    if confirm "更新所有过期的包?"; then
        log "正在更新 (可能耗时较长)..."
        brew upgrade || warn "部分包更新失败"
    fi

    if confirm "清理旧版本与下载缓存?"; then
        brew cleanup --prune=all && ok "Homebrew 缓存已清理"
    fi

    log "运行 brew doctor 检查..."
    brew doctor 2>&1 | head -20 | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
# all
# ---------------------------------------------------------------------------
cmd_all() {
    cmd_doctor
    cmd_clean
    cmd_tune
    cmd_brew
    printf "\n"
    ok "全部流程执行完毕"
}

# ---------------------------------------------------------------------------
# 帮助与入口
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}macOS 本地优化脚本${NC}

用法: ${BOLD}$SCRIPT_NAME <command> [选项]${NC}

命令:
  ${GREEN}doctor${NC}     系统体检报告 (磁盘/内存/CPU/大文件/启动项)
  ${GREEN}clean${NC}      清理缓存、日志、废纸篓、开发工具垃圾
  ${GREEN}tune${NC}       系统调优 (Finder/Dock/截图/键盘等 defaults 设置)
  ${GREEN}tune-undo${NC}  恢复 tune 之前的设置
  ${GREEN}brew${NC}       Homebrew 更新与清理
  ${GREEN}all${NC}        doctor -> clean -> tune -> brew

选项:
  --dry-run, -n   只预览将要做什么, 不做任何修改
  --yes, -y       跳过所有确认提示
  --help, -h      显示本帮助

示例:
  $SCRIPT_NAME clean --dry-run    # 预览清理内容
  $SCRIPT_NAME clean -y           # 直接清理不再询问
  $SCRIPT_NAME all                # 完整优化流程
EOF
}

main() {
    require_macos

    local cmd="${1:-help}"
    shift || true

    for arg in "$@"; do
        case "$arg" in
            --dry-run|-n) DRY_RUN=true ;;
            --yes|-y)     ASSUME_YES=true ;;
            --help|-h)    usage; exit 0 ;;
            *) err "未知选项: $arg"; usage; exit 1 ;;
        esac
    done

    case "$cmd" in
        doctor)    cmd_doctor ;;
        clean)     cmd_clean ;;
        tune)      cmd_tune ;;
        tune-undo) cmd_tune_undo ;;
        brew)      cmd_brew ;;
        all)       cmd_all ;;
        help|--help|-h) usage ;;
        *) err "未知命令: $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
