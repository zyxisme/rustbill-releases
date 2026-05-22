#!/usr/bin/env bash
set -euo pipefail

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

# ── 颜色体系 ──────────────────────────────────────────────────────────────────
# 基础色
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   MAGENTA='\033[0;35m'
WHITE='\033[1;37m';  GRAY='\033[0;90m';   DIM='\033[2m'
# 粗体
BOLD='\033[1m';      B_RED='\033[1;31m';  B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'; B_BLUE='\033[1;34m'; B_CYAN='\033[1;36m'
B_MAGENTA='\033[1;35m'; B_WHITE='\033[1;37m'
# 背景
BG_GREEN='\033[42m'; BG_RED='\033[41m';   BG_BLUE='\033[44m'
BG_CYAN='\033[46m';   BG_DARK='\033[48;5;236m'
# 重置
NC='\033[0m'

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
    printf "  ${B_BLUE}[%d/%d]${NC} ${BOLD}%s${NC}\n" "$current" "$total" "$title"
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

    local idx=1
    while IFS='|' read -r tag date name; do
        [ -z "$tag" ] && continue
        local marker=""
        [ "$tag" = "$LATEST_VERSION" ] && marker=" ${B_GREEN}◀ latest${NC}"
        local short_date="${date:0:10}"
        printf "  ${B_BLUE}%4d.${NC}  ${BOLD}%-12s${NC}  ${GRAY}%-16s${NC}  %s%s\n" \
            "$idx" "$tag" "${short_date:- }" "${name:$tag}" "$marker"
        idx=$((idx + 1))
    done < /tmp/rustbill-versions-$$.txt
    rm -f /tmp/rustbill-versions-$$.txt

    echo ""
    hr "─" "${DIM}"
    printf "  ${BOLD}选择版本${NC} [1-${idx_minus_one}$((idx - 1)) / 回车=最新版 / q=退出]: "

    read -r choice
    if [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
        echo -e "\n  ${GRAY}已取消${NC}"
        exit 0
    fi
    if [ -z "$choice" ]; then
        VERSION="$LATEST_VERSION"
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        # Map menu number to tag
        local selected
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
        local rn
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

    local count=0; local total_backups=6
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
    box_line "  ├─ plugins/              插件目录 (Provider/Gateway/Notifier)"
    box_line "  ├─ consumer-dist/        客户前台 SPA (独立部署)"
    box_line "  └─ config.example.toml   配置模板"
    box_bottom
fi

# ── 配置初始化 (仅新安装) ─────────────────────────────────────────────────────

if ! $IS_UPDATING; then
    echo ""
    step_header "~" "$TOTAL_STEPS" "配置初始化"

    if [ ! -f "${INSTALL_DIR}/config.toml" ]; then
        cp "${INSTALL_DIR}/config.example.toml" "${INSTALL_DIR}/config.toml"
        ok "已从模板创建 config.toml"
    else
        ok "config.toml 已存在，跳过"
    fi

    echo ""
    echo -e "  ${B_YELLOW}▸ 请务必编辑 config.toml 填入以下必填项:${NC}"
    echo -e "    ${DIM}1.${NC} ${BOLD}[db].url${NC}            PostgreSQL 连接串"
    echo -e "    ${DIM}2.${NC} ${BOLD}[jwt].secret${NC}        JWT 签名密钥"
    echo -e "    ${DIM}3.${NC} ${BOLD}[bootstrap].admin_password${NC}  初始管理员密码"
    echo ""

    if ! $NON_INTERACTIVE; then
        confirm "是否现在编辑配置?" "n"
        read -r edit_now
        if [ "${edit_now,,}" = "y" ] || [ "${edit_now,,}" = "yes" ]; then
            EDITOR="${EDITOR:-${VISUAL:-}}"
            if [ -z "$EDITOR" ]; then
                for candidate in nano vim vi; do
                    command -v "$candidate" &>/dev/null && { EDITOR="$candidate"; break; }
                done
            fi
            if [ -n "$EDITOR" ]; then
                "$EDITOR" "${INSTALL_DIR}/config.toml"
            else
                warn "未找到编辑器，请手动编辑"
            fi
        fi
    fi
fi

# ── systemd 服务 ──────────────────────────────────────────────────────────────

echo ""
step_header "~" "$TOTAL_STEPS" "Systemd 服务"

if $IS_UPDATING; then
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
else
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
    else
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
    box_line "${BOLD}快速开始:${NC}"
    box_empty
    box_line "  ${DIM}1.${NC} 编辑配置:     ${INSTALL_DIR}/config.toml"
    box_line "  ${DIM}2.${NC} 启动服务:     cd ${INSTALL_DIR} && ./rustbill-server"
    box_line "  ${DIM}3.${NC} 管理后台:     http://localhost:50051/admin"
    box_line "  ${DIM}4.${NC} CLI 管理:     ${INSTALL_DIR}/rustbill-cli --help"
    box_empty
    box_line "${GRAY}数据库迁移由 rustbill-server 启动时自动执行。${NC}"
    box_bottom
fi

echo ""
hr "═" "${CYAN}"
echo ""
center "感谢使用 RustBill  ${GRAY}✦${NC}" "${DIM}"
echo ""
