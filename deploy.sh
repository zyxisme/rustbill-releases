#!/usr/bin/env bash
set -euo pipefail

# curl | bash 管道下 stdin 被脚本内容占用，重定向到终端确保 read 可交互
exec < /dev/tty 2>/dev/null || true

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                    RustBill 部署/更新脚本                                    ║
# ║                    交互式安装 · 一键升级 · 安全回滚                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# 用法:
#   curl -fsSL <URL> | bash                  # 交互式部署
#   curl -fsSL <URL> | bash -s -- --update   # 仅更新模式
#   curl -fsSL <URL> | bash -s -- --yes      # 非交互（CI/CD）
#   curl -fsSL <URL> | bash -s -- -y -v v1.0 # 非交互指定版本

REPO="zyxisme/rustbill-releases"
API_BASE="https://api.github.com/repos/${REPO}"
DOWNLOAD_BASE="https://github.com/${REPO}/releases/download"

# ── 颜色体系 (ANSI-C quoting: 变量存真正的 ESC 字符, echo/printf 均兼容) ─────
# 基础色
RED=$'\033[0;31m';    GREEN=$'\033[0;32m';  YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m';   CYAN=$'\033[0;36m';   MAGENTA=$'\033[0;35m'
WHITE=$'\033[1;37m';  GRAY=$'\033[0;90m';   DIM=$'\033[2m'
# 粗体
BOLD=$'\033[1m';      B_RED=$'\033[1;31m';  B_GREEN=$'\033[1;32m'
B_YELLOW=$'\033[1;33m'; B_BLUE=$'\033[1;34m'; B_CYAN=$'\033[1;36m'
B_MAGENTA=$'\033[1;35m'; B_WHITE=$'\033[1;37m'
# 背景
BG_GREEN=$'\033[42m'; BG_RED=$'\033[41m';   BG_BLUE=$'\033[44m'
BG_CYAN=$'\033[46m'
# 重置
NC=$'\033[0m'
CLEAR_LINE=$'\033[K'

# ── 终端尺寸 ──────────────────────────────────────────────────────────────────
get_term_width() {
    local w
    w=$(tput cols 2>/dev/null || echo 80)
    echo "${w:-80}"
}
TERM_WIDTH=$(get_term_width)
HALF_WIDTH=$(( (TERM_WIDTH - 4) / 2 ))
BOX_WIDTH=$(( TERM_WIDTH - 4 > 76 ? 76 : TERM_WIDTH - 4 ))

hr() {
    local char="${1:-─}"
    local color="${2:-${GRAY}}"
    printf "${color}"
    printf '%*s' "$BOX_WIDTH" '' | tr ' ' "$char"
    printf "${NC}\n"
}

center() {
    local text="$1"
    local color="${2:-}"
    local plain
    plain=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local len=${#plain}
    local pad=$(( (BOX_WIDTH - len) / 2 ))
    [[ $pad -lt 0 ]] && pad=0
    printf "  %${pad}s${color}%s${NC}\n" "" "$text"
}

box_top()    { echo -e "  ${GRAY}╭$(printf '%*s' "$BOX_WIDTH" '' | tr ' ' '─')╮${NC}"; }
box_bottom() { echo -e "  ${GRAY}╰$(printf '%*s' "$BOX_WIDTH" '' | tr ' ' '─')╯${NC}"; }
box_line()   { printf "  ${GRAY}│${NC} %-${BOX_WIDTH}s ${GRAY}│${NC}\n" "$1"; }
box_empty()  { box_line ""; }

# ── 图标函数 ──────────────────────────────────────────────────────────────────
icon_step()   { echo -ne "${B_BLUE}[$1/$TOTAL_STEPS]${NC}"; }
icon_ok()     { echo -ne "${B_GREEN}✔${NC}"; }
icon_err()    { echo -ne "${B_RED}✘${NC}"; }
icon_warn()   { echo -ne "${B_YELLOW}⚠${NC}"; }
icon_info()   { echo -ne "${B_BLUE}ℹ${NC}"; }
icon_star()   { echo -ne "${B_YELLOW}★${NC}"; }
icon_arrow()  { echo -ne "${GRAY}→${NC}"; }
icon_dot()    { echo -ne "${GRAY}•${NC}"; }

info()    { echo -e "  ${BLUE}ℹ${NC}  $*"; }
ok()      { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()     { echo -e "  ${RED}✘${NC}  $*"; }
success() { echo -e "  ${B_GREEN}✔ ${BOLD}$*${NC}"; }
step_header() {
    local current="$1" total="$2" title="$3"
    echo ""
    printf "  ${B_BLUE}[%s/%s]${NC} ${BOLD}%s${NC}\n" "$current" "$total" "$title"
    hr "─" "${GRAY}"
}

# ── 旋转动画 ──────────────────────────────────────────────────────────────────
SPINNER_PID=""
SPINNER_STOP=""

spinner_start() {
    local message="$1"
    local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    SPINNER_STOP="/tmp/rustbill-spinner-stop-$$"
    rm -f "$SPINNER_STOP"

    (
        local i=0
        while [ ! -f "$SPINNER_STOP" ]; do
            printf "\r  ${CYAN}%s${NC} %s" "${chars:$i:1}" "$message"
            i=$(( (i + 1) % ${#chars} ))
            sleep 0.08
        done
        printf "\r\033[K"
    ) &
    SPINNER_PID=$!
}

spinner_stop() {
    touch "$SPINNER_STOP" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    rm -f "$SPINNER_STOP"
    SPINNER_PID=""
}

spinner_ok() {
    spinner_stop
    ok "$1"
}

spinner_err() {
    spinner_stop
    err "$1"
}

# ── 进度条 ────────────────────────────────────────────────────────────────────
draw_progress() {
    local current="$1" total="$2" label="${3:-}"
    local pct=$(( current * 100 / total ))
    local bar_width=40
    local filled=$(( pct * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    printf "\r  ${GRAY}[${NC}"
    printf "${B_GREEN}%*s${NC}" "$filled" "" | tr ' ' '█'
    printf "${GRAY}%*s${NC}" "$empty" "" | tr ' ' '░'
    printf "${GRAY}]${NC} %3d%%" "$pct"
    [ -n "$label" ] && printf "  %s" "$label"
}

# ── 横幅 ──────────────────────────────────────────────────────────────────────
show_banner() {
    clear 2>/dev/null || true
    echo ""
    center "╔══════════════════════════════════════════════════════╗" "${CYAN}"
    center "║                                                      ║" "${CYAN}"
    center "║   ${B_WHITE}██████╗ ██╗   ██╗███████╗████████╗${CYAN}               ║"
    center "║   ${B_WHITE}██╔══██╗██║   ██║██╔════╝╚══██╔══╝${CYAN}               ║"
    center "║   ${B_WHITE}██████╔╝██║   ██║███████╗   ██║   ${CYAN}               ║"
    center "║   ${B_WHITE}██╔══██╗██║   ██║╚════██║   ██║   ${CYAN}               ║"
    center "║   ${B_WHITE}██║  ██║╚██████╔╝███████║   ██║   ${CYAN}               ║"
    center "║   ${B_WHITE}╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝   ${CYAN}               ║"
    center "║                                                      ║" "${CYAN}"
    center "║   ${B_BLUE}██████╗ ██╗██╗     ██╗     ${CYAN}                        ║"
    center "║   ${B_BLUE}██╔══██╗██║██║     ██║     ${CYAN}                        ║"
    center "║   ${B_BLUE}██████╔╝██║██║     ██║     ${CYAN}                        ║"
    center "║   ${B_BLUE}██╔══██╗██║██║     ██║     ${CYAN}                        ║"
    center "║   ${B_BLUE}██████╔╝██║███████╗███████╗${CYAN}                        ║"
    center "║   ${B_BLUE}╚═════╝ ╚═╝╚══════╝╚══════╝${CYAN}                        ║"
    center "║                                                      ║" "${CYAN}"
    center "╚══════════════════════════════════════════════════════╝" "${CYAN}"
    echo ""
    center "基于 Rust 的分布式云服务器财务管理系统" "${GRAY}"
    center "插件化架构 · 多供应商 · 多支付网关 · 多渠道通知" "${DIM}"
    echo ""
    hr "═" "${CYAN}"
    echo ""
}

# ── 确认提示 (带高亮默认值) ──────────────────────────────────────────────────
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local yn_hint

    if [ "$default" = "y" ]; then
        yn_hint="${BOLD}Y${NC}/${DIM}n${NC}"
    else
        yn_hint="${DIM}y${NC}/${BOLD}N${NC}"
    fi

    printf "  ${YELLOW}?${NC} %s [%b] " "$prompt" "$yn_hint"
}

# ── 数字菜单 ──────────────────────────────────────────────────────────────────
show_menu() {
    local title="$1"
    shift
    local -a items=("$@")

    printf "  ${BOLD}%s${NC}\n" "$title"
    echo ""
    local i=1
    for item in "${items[@]}"; do
        printf "    ${B_BLUE}%2d.${NC} %s\n" "$i" "$item"
        i=$((i + 1))
    done
    echo ""
}

# ── 解析命令行参数 ───────────────────────────────────────────────────────────
UPDATE_ONLY=false
NON_INTERACTIVE=false
FORCE_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update|-u) UPDATE_ONLY=true; shift ;;
        --yes|-y)    NON_INTERACTIVE=true; shift ;;
        --version|-v) FORCE_VERSION="$2"; shift 2 ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --update, -u     仅更新模式（跳过安装流程，直接升级已有实例）"
            echo "  --yes, -y        非交互模式（自动选择最新版本、跳过确认）"
            echo "  --version, -v N  指定版本号（如 v1.0.0）"
            echo "  --help, -h       显示此帮助"
            exit 0
            ;;
        *) err "未知选项: $1"; echo "使用 --help 查看可用选项"; exit 1 ;;
    esac
done

# ── 步骤规划 ──────────────────────────────────────────────────────────────────
TOTAL_STEPS=7

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  第 1 步：环境检查                                                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

show_banner

step_header 1 "$TOTAL_STEPS" "环境检查"

command -v curl &>/dev/null || { err "需要 curl，请先安装"; exit 1; }
command -v tar  &>/dev/null || { err "需要 tar，请先安装";  exit 1; }

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)        RUSTBILL_ARCH="linux-x86_64" ;;
    aarch64|arm64) RUSTBILL_ARCH="linux-arm64" ;;
    *) err "不支持的架构: $ARCH"; echo "  支持的架构: x86_64, aarch64"; exit 1 ;;
esac

OS=$(uname -s)

box_top
box_line "$(printf "%-10s  %s" "系统:" "$(uname -s) $(uname -r)")"
box_line "$(printf "%-10s  %s" "架构:" "${BOLD}${RUSTBILL_ARCH}${NC}")"
box_line "$(printf "%-10s  %s" "Shell:" "${BASH_VERSION%%(*}")"
command -v jq &>/dev/null && box_line "$(printf "%-10s  ${GREEN}已安装${NC}" "jq:")" || box_line "$(printf "%-10s  ${YELLOW}未安装 (基本模式)${NC}" "jq:")"
box_bottom

if [ "$OS" != "Linux" ]; then
    warn "当前系统为 ${OS}，RustBill 仅正式支持 Linux。继续部署风险自负。"
fi

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  第 2 步：获取版本信息                                                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

step_header 2 "$TOTAL_STEPS" "获取版本信息"

spinner_start "正在连接 GitHub Releases..."

RELEASES_JSON=$(curl -sf "${API_BASE}/releases?per_page=10" 2>/dev/null) || {
    spinner_err "无法访问 GitHub Releases，请检查网络连接"
    exit 1
}

spinner_stop

get_latest_version() {
    if command -v jq &>/dev/null; then
        echo "$RELEASES_JSON" | jq -r '.[0].tag_name'
    else
        echo "$RELEASES_JSON" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1
    fi
}

LATEST_VERSION=$(get_latest_version)

if [ -n "$FORCE_VERSION" ]; then
    VERSION="${FORCE_VERSION#v}"
    VERSION="v${VERSION}"
    ok "使用指定版本: ${BOLD}${VERSION}${NC}"
elif $NON_INTERACTIVE; then
    VERSION="$LATEST_VERSION"
    ok "自动选择最新版本: ${BOLD}${VERSION}${NC}"
else
    echo ""
    # 构建版本列表
    echo "" > /tmp/rustbill-versions-$$.txt
    if command -v jq &>/dev/null; then
        echo "$RELEASES_JSON" | jq -r '.[] | "\(.tag_name)|\(.published_at // "")|\(.name // .tag_name)"' > /tmp/rustbill-versions-$$.txt
    fi

    echo -e "  ${BOLD}可用版本${NC}"
    echo ""
    printf "  ${GRAY}%4s  %-12s  %-16s  %s${NC}\n" "  #" "版本" "发布日期" "标题"
    hr "─" "${DIM}"

    idx=1
    while IFS='|' read -r tag date name; do
        [ -z "$tag" ] && continue
        marker=""
        [ "$tag" = "$LATEST_VERSION" ] && marker=" ${B_GREEN}◀ latest${NC}"
        short_date="${date:0:10}"
        printf "  ${B_BLUE}%4d.${NC}  ${BOLD}%-12s${NC}  ${GRAY}%-16s${NC}  %s%s\n" \
            "$idx" "$tag" "${short_date:- }" "${name:$tag}" "$marker"
        idx=$((idx + 1))
    done < /tmp/rustbill-versions-$$.txt
    rm -f /tmp/rustbill-versions-$$.txt

    echo ""
    hr "─" "${DIM}"
    printf "  ${BOLD}选择版本${NC} [1-$((idx - 1)) / 回车=最新版 / q=退出]: "

    read -r choice
    if [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
        echo -e "\n  ${GRAY}已取消${NC}"
        exit 0
    fi
    if [ -z "$choice" ]; then
        VERSION="$LATEST_VERSION"
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        # Map menu number to tag
        selected=$(echo "$RELEASES_JSON" | jq -r ".[$((choice - 1))].tag_name" 2>/dev/null || true)
        if [ -n "$selected" ]; then
            VERSION="$selected"
        else
            warn "无效选择，使用最新版本"
            VERSION="$LATEST_VERSION"
        fi
    else
        VERSION="${choice#v}"
        VERSION="v${VERSION}"
    fi

    ok "已选择版本: ${BOLD}${VERSION}${NC}"

    # 显示所选版本的 release notes 摘要 (如果有)
    if command -v jq &>/dev/null; then
        rn=$(echo "$RELEASES_JSON" | jq -r ".[] | select(.tag_name == \"$VERSION\") | .body" 2>/dev/null | head -10 || true)
        if [ -n "$rn" ]; then
            echo ""
            echo -e "  ${BOLD}${GRAY}▸ Release Notes 摘要:${NC}"
            echo "$rn" | while IFS= read -r line; do
                [ -z "$line" ] && continue
                echo -e "    ${GRAY}${line:0:70}${NC}"
            done
            echo ""
        fi
    fi
fi

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  第 3 步：探测已有安装                                                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

step_header 3 "$TOTAL_STEPS" "探测已有安装"

detect_existing_install() {
    if [ -n "${RUSTBILL_HOME:-}" ] && [ -f "$RUSTBILL_HOME/rustbill-server" ]; then
        echo "$RUSTBILL_HOME"; return
    fi
    if command -v systemctl &>/dev/null; then
        local svc_path
        svc_path=$(systemctl show rustbill-server -p ExecStart 2>/dev/null | grep -oP '^ExecStart=\{\ type=exec \;\ path=\K[^ ;]+' || true)
        [ -z "$svc_path" ] && svc_path=$(systemctl show rustbill-server -p ExecStart 2>/dev/null | grep -oP '^ExecStart=\K[^ ]+' | sed 's/{}//g' || true)
        if [ -n "$svc_path" ] && [ -f "$svc_path" ]; then dirname "$svc_path"; return; fi
    fi
    for dir in "/opt/rustbill" "$HOME/rustbill"; do
        [ -f "$dir/rustbill-server" ] && echo "$dir" && return
    done
}

EXISTING_DIR=$(detect_existing_install || true)

if [ -n "$EXISTING_DIR" ]; then
    INSTALLED_VERSION=""
    if [ -f "${EXISTING_DIR}/VERSION" ]; then
        INSTALLED_VERSION=$(cat "${EXISTING_DIR}/VERSION")
    elif [ -f "${EXISTING_DIR}/rustbill-server" ]; then
        INSTALLED_VERSION=$("${EXISTING_DIR}/rustbill-server" --version 2>/dev/null || echo "")
    fi

    # 检查 systemd 状态
    SERVICE_STATUS="未安装"
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet rustbill-server 2>/dev/null; then
            SERVICE_STATUS="${GREEN}运行中${NC}"
        elif systemctl is-enabled --quiet rustbill-server 2>/dev/null; then
            SERVICE_STATUS="${YELLOW}已停止${NC}"
        fi
    fi

    box_top
    box_line "$(printf "%-14s  %s" "安装目录:" "${BOLD}${EXISTING_DIR}${NC}")"
    box_line "$(printf "%-14s  %s" "当前版本:" "${BOLD}${INSTALLED_VERSION:-未知}${NC}")"
    box_line "$(printf "%-14s  %s" "目标版本:" "${BOLD}${VERSION}${NC}")"
    box_line "$(printf "%-14s  %b" "Systemd:" "$SERVICE_STATUS")"
    box_bottom

    if [ "$INSTALLED_VERSION" = "$VERSION" ] && [ -n "$INSTALLED_VERSION" ]; then
        echo ""
        warn "已安装版本与目标版本相同 (${VERSION})"
        if $NON_INTERACTIVE; then
            echo "  非交互模式，跳过。"
            exit 0
        fi
        confirm "是否强制重新安装?" "n"
        read -r force
        [ "${force,,}" != "y" ] && [ "${force,,}" != "yes" ] && { echo "  已取消。"; exit 0; }
    fi

    if ! $UPDATE_ONLY; then
        echo ""
        confirm "更新已有安装?" "y"
        if ! $NON_INTERACTIVE; then
            read -r do_update
        else
            do_update="y"; echo "Y (非交互模式)"
        fi
        [ "${do_update,,}" = "n" ] || [ "${do_update,,}" = "no" ] && EXISTING_DIR=""
    fi

    INSTALL_DIR="$EXISTING_DIR"
else
    ok "未检测到已有安装，将进行全新部署"
    INSTALL_DIR=""
fi

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  第 4 步：选择安装目录                                                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

if [ -z "$INSTALL_DIR" ]; then
    step_header 4 "$TOTAL_STEPS" "选择安装目录"

    DEFAULT_DIR="$HOME/rustbill"
    if $NON_INTERACTIVE; then
        INSTALL_DIR="$DEFAULT_DIR"
        echo "  安装目录: ${BOLD}${INSTALL_DIR}${NC} (非交互模式)"
    else
        printf "  安装目录 [${BOLD}%s${NC}]: " "$DEFAULT_DIR"
        read -r input_dir
        INSTALL_DIR="${input_dir:-$DEFAULT_DIR}"
    fi

    if [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        warn "目录 ${INSTALL_DIR} 已存在且非空"
        if $NON_INTERACTIVE; then
            err "非交互模式下不支持覆盖已有目录"; exit 1
        fi
        confirm "是否覆盖?" "n"
        read -r confirm_dir
        [ "${confirm_dir,,}" != "y" ] && [ "${confirm_dir,,}" != "yes" ] && { echo "  已取消。"; exit 0; }
        rm -rf "$INSTALL_DIR"
    fi
    mkdir -p "$INSTALL_DIR"
fi

ok "安装目录: ${BOLD}${INSTALL_DIR}${NC}"

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  第 5 步：更新前准备 (仅更新模式)                                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

IS_UPDATING=false
BACKUP_DIR=""
SERVICE_WAS_RUNNING=false

if [ -f "${INSTALL_DIR}/rustbill-server" ]; then
    IS_UPDATING=true
    step_header 5 "$TOTAL_STEPS" "更新前准备"

    # 停止服务
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet rustbill-server 2>/dev/null; then
            SERVICE_WAS_RUNNING=true
            spinner_start "正在停止 rustbill-server 服务..."
            sudo systemctl stop rustbill-server || warn "无法停止服务（将继续更新）"
            spinner_ok "服务已优雅停止"
        fi
    fi

    # 备份
    BACKUP_DIR="${INSTALL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"

    spinner_start "正在创建备份..."
    mkdir -p "$BACKUP_DIR"

    count=0; total_backups=6
    [ -f "${INSTALL_DIR}/config.toml" ]       && cp "${INSTALL_DIR}/config.toml"       "${BACKUP_DIR}/" && count=$((count+1))
    [ -f "${INSTALL_DIR}/config.local.toml" ] && cp "${INSTALL_DIR}/config.local.toml" "${BACKUP_DIR}/" && count=$((count+1))
    [ -f "${INSTALL_DIR}/rustbill-server" ]   && cp "${INSTALL_DIR}/rustbill-server"   "${BACKUP_DIR}/" && count=$((count+1))
    [ -f "${INSTALL_DIR}/rustbill-cli" ]      && cp "${INSTALL_DIR}/rustbill-cli"      "${BACKUP_DIR}/" && count=$((count+1))
    [ -d "${INSTALL_DIR}/plugins" ]           && cp -r "${INSTALL_DIR}/plugins"        "${BACKUP_DIR}/" && count=$((count+1))
    [ -d "${INSTALL_DIR}/consumer-dist" ]     && cp -r "${INSTALL_DIR}/consumer-dist"  "${BACKUP_DIR}/" && count=$((count+1))

    # 生成回滚脚本
    cat > "${BACKUP_DIR}/rollback.sh" <<'RBEOF'
#!/usr/bin/env bash
set -euo pipefail
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║    RustBill 回滚程序                      ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""
BACKUP_DIR="$(dirname "$0")"
RBEOF
    cat >> "${BACKUP_DIR}/rollback.sh" <<RBEOF
INSTALL_DIR="${INSTALL_DIR}"
echo "  正在回滚 RustBill..."
[ -f "\$BACKUP_DIR/rustbill-server" ] && cp "\$BACKUP_DIR/rustbill-server" "\$INSTALL_DIR/"
[ -f "\$BACKUP_DIR/rustbill-cli" ]    && cp "\$BACKUP_DIR/rustbill-cli"    "\$INSTALL_DIR/"
if [ -d "\$BACKUP_DIR/plugins" ]; then
    rm -rf "\$INSTALL_DIR/plugins"
    cp -r "\$BACKUP_DIR/plugins" "\$INSTALL_DIR/plugins"
fi
echo "  ✔ 回滚完成。重启服务: sudo systemctl restart rustbill-server"
RBEOF
    chmod +x "${BACKUP_DIR}/rollback.sh"

    spinner_ok "备份完成 (${count} 项)"
    echo -e "  ${GRAY}▸${NC} 备份位置: ${GRAY}${BACKUP_DIR}${NC}"
    echo -e "  ${GRAY}▸${NC} 回滚命令: ${GRAY}${BACKUP_DIR}/rollback.sh${NC}"
else
    step_header 5 "$TOTAL_STEPS" "更新前准备"
    ok "全新安装，无需备份"
fi

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  第 6 步：下载 & 校验                                                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

step_header 6 "$TOTAL_STEPS" "下载 & 安全校验"

TARBALL="rustbill-${RUSTBILL_ARCH}.tar.gz"
DOWNLOAD_URL="${DOWNLOAD_BASE}/${VERSION}/${TARBALL}"

info "下载: ${GRAY}${DOWNLOAD_URL}${NC}"
echo ""

# 带原生进度条的下载
curl -fL --progress-bar -o "/tmp/${TARBALL}" "$DOWNLOAD_URL" || {
    err "下载失败。请确认版本 ${VERSION} 存在且包含 ${RUSTBILL_ARCH} 架构。"
    if $IS_UPDATING && [ -n "$BACKUP_DIR" ]; then
        warn "备份保存在 ${BACKUP_DIR}，可使用 rollback.sh 回滚"
    fi
    exit 1
}
echo ""

# 获取文件大小
FILE_SIZE=$(stat -c%s "/tmp/${TARBALL}" 2>/dev/null || stat -f%z "/tmp/${TARBALL}" 2>/dev/null || echo 0)
FILE_SIZE_MB=$(awk "BEGIN { printf \"%.1f\", $FILE_SIZE / 1048576 }")
ok "下载完成 (${FILE_SIZE_MB} MB)"

# SHA256 校验
if command -v sha256sum &>/dev/null && command -v jq &>/dev/null; then
    spinner_start "正在进行 SHA256 校验..."

    SHA256_URL="${API_BASE}/releases/tags/${VERSION}"
    RELEASE_BODY=$(curl -sf "$SHA256_URL" 2>/dev/null | jq -r '.body' 2>/dev/null) || true

    VERIFIED=false
    if [ -n "$RELEASE_BODY" ]; then
        EXPECTED_SHA=$(echo "$RELEASE_BODY" | grep -oP "[0-9a-f]{64}\s+${TARBALL}" | head -1 | awk '{print $1}' || true)
        if [ -n "$EXPECTED_SHA" ]; then
            ACTUAL_SHA=$(sha256sum "/tmp/${TARBALL}" | awk '{print $1}')
            if [ "$EXPECTED_SHA" = "$ACTUAL_SHA" ]; then
                VERIFIED=true
                spinner_ok "SHA256 校验通过"
                echo -e "  ${GRAY}▸ ${ACTUAL_SHA:0:16}...${NC}"
            else
                spinner_err "SHA256 校验失败!"
                echo -e "  ${RED}期望: ${EXPECTED_SHA}${NC}"
                echo -e "  ${RED}实际: ${ACTUAL_SHA}${NC}"
                rm -f "/tmp/${TARBALL}"
                exit 1
            fi
        fi
    fi

    if ! $VERIFIED; then
        spinner_stop
        warn "无法获取 checksum，跳过校验"
        echo -e "  ${GRAY}▸ 手动验证: sha256sum /tmp/${TARBALL}${NC}"
    fi
else
    warn "缺少 sha256sum 或 jq，跳过 SHA256 校验"
fi

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  第 7 步：安装/更新                                                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

if $IS_UPDATING; then
    step_header 7 "$TOTAL_STEPS" "执行更新"
else
    step_header 7 "$TOTAL_STEPS" "解压安装"
fi

spinner_start "正在解压..."

if $IS_UPDATING; then
    TMP_EXTRACT="/tmp/rustbill-extract-$$"
    mkdir -p "$TMP_EXTRACT"
    tar -xzf "/tmp/${TARBALL}" -C "$TMP_EXTRACT" --strip-components=1 || {
        spinner_err "解压失败"
        rm -rf "$TMP_EXTRACT"
        exit 1
    }

    # 暂存用户配置
    CONFIG_TMP="/tmp/rustbill-config-$$"
    mkdir -p "$CONFIG_TMP"
    [ -f "${INSTALL_DIR}/config.toml" ]       && cp "${INSTALL_DIR}/config.toml"       "$CONFIG_TMP/"
    [ -f "${INSTALL_DIR}/config.local.toml" ] && cp "${INSTALL_DIR}/config.local.toml" "$CONFIG_TMP/"

    # 替换二进制
    cp "$TMP_EXTRACT/rustbill-server" "${INSTALL_DIR}/rustbill-server"
    cp "$TMP_EXTRACT/rustbill-cli"    "${INSTALL_DIR}/rustbill-cli"

    # 替换插件
    if [ -d "${INSTALL_DIR}/plugins" ]; then
        rm -rf "${INSTALL_DIR}/plugins.old" 2>/dev/null || true
        mv "${INSTALL_DIR}/plugins" "${INSTALL_DIR}/plugins.old"
    fi
    cp -r "$TMP_EXTRACT/plugins" "${INSTALL_DIR}/plugins"

    # 替换客户前台
    if [ -d "${INSTALL_DIR}/consumer-dist" ]; then
        rm -rf "${INSTALL_DIR}/consumer-dist.old" 2>/dev/null || true
        mv "${INSTALL_DIR}/consumer-dist" "${INSTALL_DIR}/consumer-dist.old"
    fi
    if [ -d "$TMP_EXTRACT/consumer-dist" ]; then
        cp -r "$TMP_EXTRACT/consumer-dist" "${INSTALL_DIR}/consumer-dist"
    fi

    # 更新配置模板
    [ -f "$TMP_EXTRACT/config.example.toml" ] && cp "$TMP_EXTRACT/config.example.toml" "${INSTALL_DIR}/config.example.toml"

    # 恢复用户配置
    [ -f "$CONFIG_TMP/config.toml" ]       && mv "$CONFIG_TMP/config.toml"       "${INSTALL_DIR}/"
    [ -f "$CONFIG_TMP/config.local.toml" ] && mv "$CONFIG_TMP/config.local.toml" "${INSTALL_DIR}/"

    echo "$VERSION" > "${INSTALL_DIR}/VERSION"

    rm -rf "$TMP_EXTRACT" "$CONFIG_TMP"
    rm -f "/tmp/${TARBALL}"

    spinner_ok "更新完成"

    # 更新摘要面板
    echo ""
    box_top
    box_line "$(printf "%-22s  %s" "rustbill-server:" "${B_GREEN}${VERSION}${NC}")"
    box_line "$(printf "%-22s  %s" "rustbill-cli:" "${B_GREEN}${VERSION}${NC}")"
    box_line "$(printf "%-22s  %s" "plugins/:" "${GREEN}已更新${NC}")"
    box_line "$(printf "%-22s  %s" "consumer-dist/:" "${GREEN}已更新${NC}")"
    box_line "$(printf "%-22s  %s" "config.toml:" "${BOLD}已保留${NC}")"
    box_empty
    [ -d "${INSTALL_DIR}/plugins.old" ]       && box_line "$(printf "%-22s  %s" "plugins.old/:" "${YELLOW}旧版本备份${NC}")"
    [ -d "${INSTALL_DIR}/consumer-dist.old" ] && box_line "$(printf "%-22s  %s" "consumer-dist.old/:" "${YELLOW}旧版本备份${NC}")"
    box_bottom
else
    tar -xzf "/tmp/${TARBALL}" -C "$INSTALL_DIR" --strip-components=1
    rm -f "/tmp/${TARBALL}"
    echo "$VERSION" > "${INSTALL_DIR}/VERSION"

    spinner_ok "解压完成"

    echo ""
    box_top
    box_line "${BOLD}已安装组件:${NC}"
    box_empty
    box_line "  ├─ rustbill-server       服务端程序 (内嵌 Admin SPA)"
    box_line "  ├─ rustbill-cli          命令行管理工具 (含 TUI)"
    box_line "  ├─ plugins/              插件目录 (Rune 脚本 .rn 文件)"
    box_line "  ├─ consumer-dist/        客户前台 SPA (独立部署)"
    box_line "  └─ config.example.toml   配置模板"
    box_bottom
fi

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  交互式配置向导 (仅新安装)                                                    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

if ! $IS_UPDATING && ! $NON_INTERACTIVE; then
    echo ""
    step_header "~" "$TOTAL_STEPS" "交互式配置向导"

    echo ""
    echo -e "  ${BOLD}现在将一步步引导你完成配置，无需手动编辑文件。${NC}"
    echo -e "  ${GRAY}直接回车使用方括号中的默认值。${NC}"
    echo ""

    # ── 2.0 读取默认值 ────────────────────────────────────────────────────────
    cp "${INSTALL_DIR}/config.example.toml" "${INSTALL_DIR}/config.toml"

    # ── 2.1 数据库配置 ────────────────────────────────────────────────────────
    step_header "2.1" "$TOTAL_STEPS" "数据库配置"

    # 探测本地 PostgreSQL
    PG_LOCAL=false
    PG_VERSION=""
    IS_ROOT=false
    [ "$(id -u)" = "0" ] && IS_ROOT=true

    if command -v psql &>/dev/null; then
        PG_VERSION=$(psql --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "")
        [ -n "$PG_VERSION" ] && PG_LOCAL=true
    fi

    if $PG_LOCAL; then
        echo -e "  ${GREEN}✔${NC} 检测到本地 PostgreSQL ${PG_VERSION}"
    else
        echo -e "  ${GRAY}ℹ${NC}  未检测到本地 psql，将手动输入数据库连接信息"
        echo -e "  ${GRAY}▸${NC} 安装指南: https://www.postgresql.org/download/"
    fi
    echo ""

    printf "  ${BOLD}数据库名称${NC} [rustbill]: "
    read -r PG_DB; PG_DB="${PG_DB:-rustbill}"

    printf "  ${BOLD}数据库用户${NC} [rustbill]: "
    read -r PG_USER; PG_USER="${PG_USER:-rustbill}"

    # 自动生成密码
    PG_PASS=$(openssl rand -base64 16 2>/dev/null || cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 20)
    echo -e "  ${BOLD}数据库密码${NC}: ${GRAY}已自动生成${NC}"

    PG_HOST="localhost"
    PG_PORT="5432"
    PG_URL="postgres://${PG_USER}:${PG_PASS}@${PG_HOST}:${PG_PORT}/${PG_DB}"

    # ── 自动初始化数据库 ────────────────────────────────────────────────────
    echo ""
    spinner_start "正在初始化数据库..."

    DB_READY=false

    if $PG_LOCAL; then
        # 尝试 sudo -u postgres (root 或有 sudo 权限)
        PG_CMD=""
        if $IS_ROOT; then
            PG_CMD="su - postgres -c"
        elif command -v sudo &>/dev/null && sudo -n -u postgres true 2>/dev/null; then
            PG_CMD="sudo -u postgres"
        fi

        if [ -n "$PG_CMD" ]; then
            # 通过 postgres 系统用户免密码操作
            spinner_stop
            spinner_start "正在通过 postgres 用户创建角色和数据库..."

            $PG_CMD psql -c "SELECT 1" &>/dev/null 2>&1 || {
                # 尝试启动 PostgreSQL
                if $IS_ROOT; then
                    systemctl start postgresql &>/dev/null 2>&1 || service postgresql start &>/dev/null 2>&1 || true
                    sleep 2
                fi
            }

            set +e
            $PG_CMD psql &>/dev/null <<SQLEOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${PG_USER}') THEN
    CREATE ROLE "${PG_USER}" LOGIN PASSWORD '${PG_PASS}';
  ELSE
    ALTER ROLE "${PG_USER}" PASSWORD '${PG_PASS}';
  END IF;
END
\$\$;
SELECT 1 FROM pg_database WHERE datname = '${PG_DB}' \gset
\if :{?1}
  -- database exists
\else
  CREATE DATABASE "${PG_DB}" OWNER "${PG_USER}";
\endif
GRANT ALL PRIVILEGES ON DATABASE "${PG_DB}" TO "${PG_USER}";
\c "${PG_DB}"
GRANT ALL ON SCHEMA public TO "${PG_USER}";
SQLEOF
            PG_INIT_EXIT=$?
            set -e

            if [ $PG_INIT_EXIT -eq 0 ]; then
                # 测试连接
                if PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null 2>&1; then
                    spinner_ok "数据库 ${PG_DB} 和用户 ${PG_USER} 已就绪"
                    DB_READY=true
                fi
            fi
        fi

        # 回退：用 peer 认证直连
        if ! $DB_READY; then
            spinner_stop
            spinner_start "尝试 peer 认证..."
            if sudo -u "$PG_USER" psql -d "$PG_DB" -c "SELECT 1" &>/dev/null 2>&1; then
                spinner_ok "peer 认证连接成功"
                DB_READY=true
            elif sudo -u postgres psql -c "CREATE ROLE \"${PG_USER}\" LOGIN PASSWORD '${PG_PASS}'; CREATE DATABASE \"${PG_DB}\" OWNER \"${PG_USER}\"; GRANT ALL PRIVILEGES ON DATABASE \"${PG_DB}\" TO \"${PG_USER}\";" &>/dev/null 2>&1; then
                if PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null 2>&1; then
                    spinner_ok "数据库 ${PG_DB} 和用户 ${PG_USER} 已就绪"
                    DB_READY=true
                fi
            fi
        fi
    fi

    # 远程数据库：直接测试连接
    if ! $DB_READY && ! $PG_LOCAL; then
        spinner_stop
        printf "  ${BOLD}数据库主机${NC} [${PG_HOST}]: "
        read -r RH; PG_HOST="${RH:-$PG_HOST}"
        printf "  ${BOLD}数据库端口${NC} [${PG_PORT}]: "
        read -r RP; PG_PORT="${RP:-$PG_PORT}"
        PG_URL="postgres://${PG_USER}:${PG_PASS}@${PG_HOST}:${PG_PORT}/${PG_DB}"

        spinner_start "正在测试远程连接..."
        if PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null 2>&1; then
            spinner_ok "远程数据库连接成功"
            DB_READY=true
        else
            spinner_stop
            warn "无法连接远程数据库"
            echo -e "  请确保 pg_hba.conf 允许 ${PG_HOST} 的连接"
            echo -e "  连接串: ${GRAY}${PG_URL}${NC}"
            echo ""
            confirm "已手动准备好数据库，继续?" "n"
            read -r continue_anyway
            [ "${continue_anyway,,}" = "y" ] || [ "${continue_anyway,,}" = "yes" ] || exit 1
            DB_READY=true
        fi
    fi

    if ! $DB_READY; then
        spinner_err "数据库初始化失败"
        echo "  请手动创建用户和数据库后重试："
        echo "  sudo -u postgres psql -c \"CREATE ROLE ${PG_USER} LOGIN PASSWORD 'xxx';\""
        echo "  sudo -u postgres psql -c \"CREATE DATABASE ${PG_DB} OWNER ${PG_USER};\""
        exit 1
    fi

    # 写入 config.toml
    sed -i "s|url = \"postgres://localhost:5432/rustbill\"|url = \"${PG_URL}\"|" "${INSTALL_DIR}/config.toml"

    echo ""
    box_top
    box_line "$(printf "%-14s  ${GREEN}✔${NC}" "数据库配置:")"
    box_line "  ${GRAY}${PG_URL}${NC}"
    box_bottom

    # ── 2.2 JWT 密钥 ──────────────────────────────────────────────────────────
    step_header "2.2" "$TOTAL_STEPS" "安全配置"

    JWT_SECRET=$(openssl rand -base64 48 2>/dev/null || cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 64)
    sed -i "s|secret = \"\"|secret = \"${JWT_SECRET}\"|" "${INSTALL_DIR}/config.toml"
    ok "JWT 密钥已自动生成"
    echo -e "  ${GRAY}▸ ${JWT_SECRET:0:32}...${NC}"

    # ── 2.3 管理员账户 ────────────────────────────────────────────────────────
    echo ""
    printf "  ${BOLD}管理员用户名${NC} [admin]: "
    read -r ADMIN_USER; ADMIN_USER="${ADMIN_USER:-admin}"

    printf "  ${BOLD}管理员密码${NC}: "
    read -rs ADMIN_PASS
    echo ""
    if [ -z "$ADMIN_PASS" ]; then
        ADMIN_PASS=$(openssl rand -base64 12 2>/dev/null || cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
        echo -e "  ${YELLOW}⚠${NC}  未输入密码，已自动生成: ${BOLD}${ADMIN_PASS}${NC}"
        echo -e "  ${YELLOW}⚠${NC}  请务必记住此密码！"
        echo ""
    fi

    sed -i "s|admin_username = \"admin\"|admin_username = \"${ADMIN_USER}\"|" "${INSTALL_DIR}/config.toml"
    sed -i "s|admin_password = \"CHANGE_ME_TO_A_STRONG_PASSWORD\"|admin_password = \"${ADMIN_PASS}\"|" "${INSTALL_DIR}/config.toml"

    # 建议的安全路径
    ADMIN_PATH="/admin"
    echo ""
    echo -e "  ${BOLD}管理后台路径${NC} — 生产环境建议改为随机字符串防爆破"
    printf "  [${ADMIN_PATH}]: "
    read -r input_path
    if [ -n "$input_path" ]; then
        ADMIN_PATH="$input_path"
        sed -i "s|# admin_path = \"/admin\"|admin_path = \"${ADMIN_PATH}\"|" "${INSTALL_DIR}/config.toml"
    fi

    # ── 2.4 域名 (Caddy) ─────────────────────────────────────────────────────
    step_header "2.3" "$TOTAL_STEPS" "域名 & HTTPS"

    RUSTBILL_DOMAIN=""
    echo -e "  ${BOLD}配置域名后可通过 Caddy 自动获取 SSL 证书 (Let's Encrypt)。${NC}"
    echo -e "  ${GRAY}留空则跳过 Caddy 配置，仅本地运行。${NC}"
    echo ""
    printf "  ${BOLD}域名${NC} (如 rustbill.example.com) [跳过]: "
    read -r RUSTBILL_DOMAIN

    if [ -n "$RUSTBILL_DOMAIN" ]; then
        # 写入 config.toml 的 host 为 127.0.0.1 (由 Caddy 反代)
        sed -i "s|host = \"0.0.0.0\"|host = \"127.0.0.1\"|" "${INSTALL_DIR}/config.toml"

        ok "域名设置为: ${BOLD}${RUSTBILL_DOMAIN}${NC}"

        echo ""
        printf "  ${BOLD}通知邮箱${NC} (用于 Let's Encrypt 和系统通知) [admin@${RUSTBILL_DOMAIN#*.}]: "
        read -r NOTIFY_EMAIL
        NOTIFY_EMAIL="${NOTIFY_EMAIL:-admin@${RUSTBILL_DOMAIN#*.}}"

        sed -i "s|# notify_email = \"admin@example.com\"|notify_email = \"${NOTIFY_EMAIL}\"|" "${INSTALL_DIR}/config.toml"
    else
        warn "跳过域名配置"
    fi

    echo ""
    box_top
    box_line "${BOLD}配置摘要:${NC}"
    box_empty
    box_line "  数据库:    ${GRAY}${PG_URL}${NC}"
    box_line "  管理员:    ${BOLD}${ADMIN_USER}${NC}"
    box_line "  JWT 密钥:  ${GRAY}${JWT_SECRET:0:24}...${NC} (已自动生成)"
    [ -n "$RUSTBILL_DOMAIN" ] && box_line "  域名:      ${BOLD}${RUSTBILL_DOMAIN}${NC}"
    [ -n "$ADMIN_PATH" ] && [ "$ADMIN_PATH" != "/admin" ] && box_line "  管理路径:  ${BOLD}${ADMIN_PATH}${NC}"
    box_bottom

    # ═══════════════════════════════════════════════════════════════════════════
    # Caddy 安装 & 配置
    # ═══════════════════════════════════════════════════════════════════════════

    if [ -n "$RUSTBILL_DOMAIN" ]; then
        echo ""
        step_header "2.4" "$TOTAL_STEPS" "Caddy 反向代理"

        CADDY_INSTALLED=false
        if command -v caddy &>/dev/null; then
            CADDY_INSTALLED=true
            ok "Caddy 已安装: $(caddy version 2>/dev/null | head -1)"
        else
            warn "Caddy 未安装"
            echo ""
            echo -e "  Caddy 是推荐的反向代理，支持自动 HTTPS (HTTP/3 QUIC)。"
            confirm "是否自动安装 Caddy?" "y"
            read -r install_caddy
            if [ "${install_caddy,,}" = "y" ] || [ "${install_caddy,,}" = "yes" ]; then

                # 检测包管理器
                CADDY_INSTALL_CMD=""
                if command -v apt &>/dev/null; then
                    spinner_start "通过 apt 安装 Caddy..."
                    if sudo apt update -qq &>/dev/null && sudo apt install -y -qq caddy &>/dev/null; then
                        spinner_ok "Caddy 安装完成"
                        CADDY_INSTALLED=true
                    else
                        spinner_err "apt 安装失败"
                    fi
                fi

                if ! $CADDY_INSTALLED && command -v dnf &>/dev/null; then
                    spinner_start "通过 dnf 安装 Caddy..."
                    if sudo dnf install -y caddy &>/dev/null; then
                        spinner_ok "Caddy 安装完成"
                        CADDY_INSTALLED=true
                    else
                        spinner_err "dnf 安装失败"
                    fi
                fi

                if ! $CADDY_INSTALLED; then
                    warn "自动安装失败，请手动安装 Caddy: https://caddyserver.com/docs/install"
                fi
            fi
        fi

        if $CADDY_INSTALLED; then
            CADDYFILE="/etc/caddy/Caddyfile"
            if [ ! -w "/etc/caddy" ]; then
                # 尝试项目本地 Caddyfile
                CADDYFILE="${INSTALL_DIR}/Caddyfile"
                warn "无权限写入 /etc/caddy/，将生成到 ${CADDYFILE}"
            fi

            spinner_start "正在生成 Caddyfile..."
            cat > "/tmp/rustbill-caddyfile-$$" <<CADDYEOF
# RustBill — ${RUSTBILL_DOMAIN}
# HTTP/3 + TLS 自动管理 (Let's Encrypt)

${RUSTBILL_DOMAIN} {
    # gRPC-Web → gRPC bridge to tonic backend
    handle /rustbill.* {
        reverse_proxy h2c://127.0.0.1:50051 {
            transport http {
                versions h2c
            }
        }
    }

    # Admin SPA is embedded in the server
    handle {
        reverse_proxy 127.0.0.1:50051
    }

    # Security headers
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
    }

    # Logs (optional)
    log {
        output file /var/log/caddy/rustbill.log
    }
}
CADDYEOF

            if [ -w "$(dirname "$CADDYFILE")" ]; then
                cp "/tmp/rustbill-caddyfile-$$" "$CADDYFILE"
            else
                sudo cp "/tmp/rustbill-caddyfile-$$" "$CADDYFILE"
            fi
            rm -f "/tmp/rustbill-caddyfile-$$"
            spinner_ok "Caddyfile 已生成: ${CADDYFILE}"

            # 测试配置
            echo ""
            spinner_start "正在验证 Caddy 配置..."
            if sudo caddy validate --config "$CADDYFILE" &>/dev/null 2>&1; then
                spinner_ok "Caddy 配置验证通过"
            else
                spinner_err "Caddy 配置验证失败，请检查 Caddyfile"
            fi

            # 询问是否启动
            echo ""
            confirm "是否现在启动 Caddy?" "y"
            read -r start_caddy
            if [ "${start_caddy,,}" = "y" ] || [ "${start_caddy,,}" = "yes" ]; then
                spinner_start "正在启动 Caddy..."
                if sudo systemctl enable caddy &>/dev/null 2>&1 && sudo systemctl restart caddy &>/dev/null 2>&1; then
                    spinner_ok "Caddy 已启动 (开机自启)"
                else
                    sudo caddy start --config "$CADDYFILE" &>/dev/null 2>&1 && spinner_ok "Caddy 已启动" || spinner_err "Caddy 启动失败"
                fi
            else
                info "Caddy 未启动，稍后可手动启动: sudo systemctl start caddy"
            fi
        fi
    fi
fi

# ── systemd 服务 (仅新安装，非更新) ───────────────────────────────────────────

if ! $IS_UPDATING; then
    echo ""
    step_header "~" "$TOTAL_STEPS" "Systemd 服务"

    echo "  RustBill 可注册为 systemd 服务，实现开机自启和异常重启。"
    echo ""

    if $NON_INTERACTIVE; then
        install_service="y"
        echo "  自动安装 systemd 服务 (非交互模式)"
    else
        confirm "是否安装 systemd 服务?" "y"
        read -r install_service
    fi

    if [ "${install_service,,}" = "y" ] || [ "${install_service,,}" = "yes" ]; then
        SERVICE_FILE="/etc/systemd/system/rustbill-server.service"
        USERNAME=$(whoami)
        SERVICE_CONTENT="[Unit]
Description=RustBill Server
After=network.target postgresql.service
Wants=network.target

[Service]
Type=simple
User=${USERNAME}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/rustbill-server
Restart=on-failure
RestartSec=5
Environment=RUST_LOG=info
Environment=RUST_LOG_FORMAT=json
# 安全加固
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${INSTALL_DIR}
ReadOnlyPaths=/etc/ssl/certs

[Install]
WantedBy=multi-user.target"

        if [ -w "/etc/systemd/system" ]; then
            echo "$SERVICE_CONTENT" > "$SERVICE_FILE"
        else
            echo "$SERVICE_CONTENT" | sudo tee "$SERVICE_FILE" > /dev/null
        fi

        sudo systemctl daemon-reload
        ok "systemd 服务已安装"

        echo ""
        box_top
        box_line "${BOLD}常用管理命令:${NC}"
        box_empty
        box_line "  启动服务:     sudo systemctl start rustbill-server"
        box_line "  开机自启:     sudo systemctl enable rustbill-server"
        box_line "  查看状态:     sudo systemctl status rustbill-server"
        box_line "  实时日志:     sudo journalctl -u rustbill-server -f"
        box_bottom

        # 询问是否现在启动
        if ! $NON_INTERACTIVE; then
            echo ""
            confirm "是否现在启动 RustBill?" "y"
            read -r start_now
            if [ "${start_now,,}" = "y" ] || [ "${start_now,,}" = "yes" ]; then
                sudo systemctl start rustbill-server
                sleep 2
                if systemctl is-active --quiet rustbill-server 2>/dev/null; then
                    ok "RustBill 已启动"
                else
                    err "启动失败，请检查: sudo journalctl -u rustbill-server -n 30"
                fi
            fi
        fi
    else
        echo -e "  ${GRAY}▸ 手动启动:${NC} cd ${INSTALL_DIR} && ./rustbill-server"
    fi
fi

# ── 更新模式的 systemd 重启 ───────────────────────────────────────────────────

if $IS_UPDATING; then
    echo ""
    step_header "~" "$TOTAL_STEPS" "Systemd 服务"

    if $SERVICE_WAS_RUNNING; then
        spinner_start "正在重启 rustbill-server 服务..."
        sudo systemctl start rustbill-server || warn "启动失败，请检查日志"
        sleep 2
        if systemctl is-active --quiet rustbill-server 2>/dev/null; then
            spinner_ok "服务已成功重启"
        else
            spinner_err "服务启动异常"
            echo -e "  ${YELLOW}▸ 回滚命令: ${BACKUP_DIR}/rollback.sh${NC}"
            echo -e "  ${GRAY}▸ 查看日志: sudo journalctl -u rustbill-server -n 50${NC}"
        fi
    else
        ok "服务未在运行，跳过重启"
        echo ""
        echo -e "  ${GRAY}▸ 手动启动:${NC} cd ${INSTALL_DIR} && ./rustbill-server"
    fi
fi

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  完成                                                                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

echo ""
echo ""
hr "═" "${CYAN}"

if $IS_UPDATING; then
    center "╭────────────────────────────────────────╮" "${GREEN}"
    center "│     ✔  更 新 完 成                      │" "${B_GREEN}"
    center "╰────────────────────────────────────────╯" "${GREEN}"
    echo ""
    center "${INSTALLED_VERSION:-旧版本}  ${GRAY}━━▸${NC}  ${B_GREEN}${VERSION}${NC}"
else
    center "╭────────────────────────────────────────╮" "${GREEN}"
    center "│     ✔  部 署 完 成                      │" "${B_GREEN}"
    center "╰────────────────────────────────────────╯" "${GREEN}"
    echo ""
    center "版本: ${B_GREEN}${VERSION}${NC}"
fi

echo ""
center "安装目录: ${BOLD}${INSTALL_DIR}${NC}" "${GRAY}"
[ -n "$BACKUP_DIR" ] && center "备份目录: ${GRAY}${BACKUP_DIR}${NC}"

echo ""
echo ""

if $IS_UPDATING; then
    box_top
    box_line "${BOLD}更新后检查清单:${NC}"
    box_empty
    box_line "  ${DIM}1.${NC} 验证服务状态:  sudo systemctl status rustbill-server"
    box_line "  ${DIM}2.${NC} 测试管理后台:  http://localhost:50051/admin"
    box_line "  ${DIM}3.${NC} 确认正常后清理: rm -rf ${INSTALL_DIR}/{plugins,consumer-dist}.old"
    box_line "  ${DIM}4.${NC} 回滚 (如需):    ${BACKUP_DIR}/rollback.sh"
    box_bottom
else
    box_top
    box_line "${BOLD}部署完成，配置已就绪:${NC}"
    box_empty
    box_line "  配置文件:    ${INSTALL_DIR}/config.toml (已自动填写)"
    box_line "  启动服务:    sudo systemctl start rustbill-server"
    box_line "  数据库迁移:  首次启动自动执行"
    if [ -n "${RUSTBILL_DOMAIN:-}" ]; then
        box_empty
        box_line "  ${BOLD}访问地址:${NC}"
        box_line "  管理后台:    https://${RUSTBILL_DOMAIN}${ADMIN_PATH:-/admin}"
        box_line "  客户前台:    部署 consumer-dist/ 到 Web 服务器"
    else
        box_empty
        box_line "  管理后台:    http://localhost:50051${ADMIN_PATH:-/admin}"
    fi
    box_empty
    box_line "  CLI 管理:     ${INSTALL_DIR}/rustbill-cli --help"
    box_bottom
fi

echo ""
hr "═" "${CYAN}"
echo ""
center "感谢使用 RustBill  ${GRAY}✦${NC}" "${DIM}"
echo ""
