#!/usr/bin/env bash
set -euo pipefail

# RustBill 部署/更新脚本
# 从 GitHub Releases 下载并部署/更新 RustBill
# 用法:
#   curl -fsSL <URL> | bash              # 交互式部署
#   curl -fsSL <URL> | bash -s -- --update  # 仅更新模式
#   curl -fsSL <URL> | bash -s -- --yes     # 非交互模式（自动选最新版）

REPO="zyxisme/rustbill-releases"
API_BASE="https://api.github.com/repos/${REPO}"
DOWNLOAD_BASE="https://github.com/${REPO}/releases/download"

# ── 颜色 ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "  ${BLUE}[*]${NC} $*"; }
ok()      { echo -e "  ${GREEN}[✔]${NC} $*"; }
warn()    { echo -e "  ${YELLOW}[!]${NC} $*"; }
err()     { echo -e "  ${RED}[✘]${NC} $*"; }
section() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}"; }

# ── 解析命令行参数 ───────────────────────────────────────────────────────────
UPDATE_ONLY=false
NON_INTERACTIVE=false
FORCE_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update|-u)
            UPDATE_ONLY=true
            shift
            ;;
        --yes|-y)
            NON_INTERACTIVE=true
            shift
            ;;
        --version|-v)
            FORCE_VERSION="$2"
            shift 2
            ;;
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
        *)
            err "未知选项: $1"
            echo "使用 --help 查看可用选项"
            exit 1
            ;;
    esac
done

# ── 前置检查 ─────────────────────────────────────────────────────────────────
section "环境检查"

command -v curl  &>/dev/null || { err "需要 curl，请先安装"; exit 1; }
command -v tar   &>/dev/null || { err "需要 tar，请先安装";  exit 1; }
command -v jq    &>/dev/null || warn "jq 未安装，将使用基本模式（仍可正常使用）"

# ── 架构探测 ─────────────────────────────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)        RUSTBILL_ARCH="linux-x86_64" ;;
    aarch64|arm64) RUSTBILL_ARCH="linux-arm64" ;;
    *)
        err "不支持的架构: $ARCH"
        echo "  支持的架构: x86_64, aarch64"
        exit 1
        ;;
esac
ok "检测到架构: ${BOLD}${RUSTBILL_ARCH}${NC}"

OS=$(uname -s)
if [ "$OS" != "Linux" ]; then
    warn "当前系统为 ${OS}，RustBill 仅正式支持 Linux。继续部署风险自负。"
fi

# ── 获取版本信息 ─────────────────────────────────────────────────────────────
section "获取版本信息"

echo "  正在查询最新版本..."
RELEASES_JSON=$(curl -sf "${API_BASE}/releases?per_page=20" 2>/dev/null) || {
    err "无法访问 GitHub Releases，请检查网络连接"
    exit 1
}

# 提取最新版本号
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
else
    # 显示可用版本
    if command -v jq &>/dev/null; then
        echo ""
        echo -e "  ${BOLD}可用版本 (最近 10 个):${NC}"
        echo "$RELEASES_JSON" | jq -r '.[] | "    \(.tag_name)  |  \(.published_at // "unknown")" ' | head -10
        echo ""
    else
        echo ""
        echo -e "  ${BOLD}可选标签:${NC}"
        echo "$RELEASES_JSON" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -10 | while read -r tag; do
            echo "    - $tag"
        done
        echo ""
    fi

    if $NON_INTERACTIVE; then
        VERSION="$LATEST_VERSION"
        ok "自动选择最新版本: ${BOLD}${VERSION}${NC}"
    else
        echo -n "  输入版本号 (直接回车使用最新版 ${LATEST_VERSION}): "
        read -r VERSION

        if [ -z "$VERSION" ]; then
            VERSION="$LATEST_VERSION"
            ok "已选择最新版本: ${BOLD}${VERSION}${NC}"
        else
            VERSION="${VERSION#v}"
            VERSION="v${VERSION}"
            ok "已选择版本: ${BOLD}${VERSION}${NC}"
        fi
    fi
fi

# ── 探测已有安装 ─────────────────────────────────────────────────────────────
detect_existing_install() {
    # 按优先级查找: 1) RUSTBILL_HOME 环境变量 2) systemd service 3) 常见路径
    if [ -n "${RUSTBILL_HOME:-}" ] && [ -f "$RUSTBILL_HOME/rustbill-server" ]; then
        echo "$RUSTBILL_HOME"
        return
    fi

    # 从 systemd 服务提取路径
    if command -v systemctl &>/dev/null; then
        local svc_path
        svc_path=$(systemctl show rustbill-server -p ExecStart 2>/dev/null | grep -oP '^ExecStart=\{\ type=exec \;\ path=\K[^ ;]+' || true)
        if [ -z "$svc_path" ]; then
            svc_path=$(systemctl show rustbill-server -p ExecStart 2>/dev/null | grep -oP '^ExecStart=\K[^ ]+' | sed 's/{}//g' || true)
        fi
        if [ -n "$svc_path" ] && [ -f "$svc_path" ]; then
            dirname "$svc_path"
            return
        fi
    fi

    # 检查常见路径
    for dir in "/opt/rustbill" "$HOME/rustbill"; do
        if [ -f "$dir/rustbill-server" ]; then
            echo "$dir"
            return
        fi
    done
}

EXISTING_DIR=$(detect_existing_install || true)

if [ -n "$EXISTING_DIR" ]; then
    # 获取已安装版本
    INSTALLED_VERSION=""
    if [ -f "${EXISTING_DIR}/VERSION" ]; then
        INSTALLED_VERSION=$(cat "${EXISTING_DIR}/VERSION")
    elif [ -f "${EXISTING_DIR}/rustbill-server" ]; then
        INSTALLED_VERSION=$("${EXISTING_DIR}/rustbill-server" --version 2>/dev/null || echo "")
    fi

    section "检测到已有安装"

    echo -e "  安装目录: ${BOLD}${EXISTING_DIR}${NC}"
    if [ -n "$INSTALLED_VERSION" ]; then
        echo -e "  当前版本: ${BOLD}${INSTALLED_VERSION}${NC}"
    else
        echo -e "  当前版本: ${YELLOW}未知${NC}"
    fi
    echo -e "  目标版本: ${BOLD}${VERSION}${NC}"

    if [ "$INSTALLED_VERSION" = "$VERSION" ] && [ "$INSTALLED_VERSION" != "" ]; then
        echo ""
        warn "已安装版本与目标版本相同 (${VERSION})"
        echo -n "  是否强制重新安装? [y/N]: "
        if $NON_INTERACTIVE; then
            echo "N (非交互模式，跳过)"
            exit 0
        fi
        read -r force_reinstall
        if [ "${force_reinstall,,}" != "y" ] && [ "${force_reinstall,,}" != "yes" ]; then
            echo "  已取消。"
            exit 0
        fi
    fi

    if ! $UPDATE_ONLY; then
        echo ""
        echo -n "  是否更新已有安装? [Y/n]: "
        if ! $NON_INTERACTIVE; then
            read -r do_update
        else
            do_update="y"
            echo "Y (非交互模式)"
        fi
        if [ "${do_update,,}" = "n" ] || [ "${do_update,,}" = "no" ]; then
            # 走全新安装流程
            EXISTING_DIR=""
        fi
    fi

    INSTALL_DIR="$EXISTING_DIR"
else
    INSTALL_DIR=""
fi

# ── 新安装：选择目录 ─────────────────────────────────────────────────────────
if [ -z "$INSTALL_DIR" ]; then
    section "选择安装目录"

    DEFAULT_DIR="$HOME/rustbill"
    if $NON_INTERACTIVE; then
        INSTALL_DIR="$DEFAULT_DIR"
        echo -n "  安装目录 [${DEFAULT_DIR}]: "
        echo "$INSTALL_DIR (非交互模式)"
    else
        echo -n "  安装目录 [${DEFAULT_DIR}]: "
        read -r INSTALL_DIR
        INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"
    fi

    if [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        warn "目录 ${INSTALL_DIR} 已存在且非空"
        if $NON_INTERACTIVE; then
            err "非交互模式下不支持覆盖已有目录，请手动处理"
            exit 1
        fi
        echo -n "  是否覆盖? [y/N]: "
        read -r confirm
        if [ "${confirm,,}" != "y" ] && [ "${confirm,,}" != "yes" ]; then
            echo "  已取消。"
            exit 0
        fi
        rm -rf "$INSTALL_DIR"
    fi
    mkdir -p "$INSTALL_DIR"
fi
ok "安装目录: ${BOLD}${INSTALL_DIR}${NC}"

# ── 更新前准备 ───────────────────────────────────────────────────────────────
IS_UPDATING=false
BACKUP_DIR=""

if [ -f "${INSTALL_DIR}/rustbill-server" ]; then
    IS_UPDATING=true
    section "更新前准备"

    # 停止系统服务
    SERVICE_WAS_RUNNING=false
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet rustbill-server 2>/dev/null; then
            SERVICE_WAS_RUNNING=true
            info "正在停止 rustbill-server 服务..."
            sudo systemctl stop rustbill-server || warn "无法停止服务（将继续更新）"
            ok "服务已停止"
        fi
    fi

    # 备份
    BACKUP_DIR="${INSTALL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    info "创建备份到 ${BACKUP_DIR}"

    # 备份配置文件
    if [ -f "${INSTALL_DIR}/config.toml" ]; then
        cp "${INSTALL_DIR}/config.toml" "${BACKUP_DIR}/config.toml"
    fi
    if [ -f "${INSTALL_DIR}/config.local.toml" ]; then
        cp "${INSTALL_DIR}/config.local.toml" "${BACKUP_DIR}/config.local.toml"
    fi

    # 备份旧的二进制和插件（方便回滚）
    if [ -f "${INSTALL_DIR}/rustbill-server" ]; then
        cp "${INSTALL_DIR}/rustbill-server" "${BACKUP_DIR}/rustbill-server"
    fi
    if [ -f "${INSTALL_DIR}/rustbill-cli" ]; then
        cp "${INSTALL_DIR}/rustbill-cli" "${BACKUP_DIR}/rustbill-cli"
    fi
    if [ -d "${INSTALL_DIR}/plugins" ]; then
        cp -r "${INSTALL_DIR}/plugins" "${BACKUP_DIR}/plugins"
    fi

    # 生成回滚脚本
    cat > "${BACKUP_DIR}/rollback.sh" <<ROLLBACK_SCRIPT
#!/usr/bin/env bash
set -euo pipefail
echo "回滚 RustBill 到更新前版本..."
if [ -f "${BACKUP_DIR}/rustbill-server" ]; then
    cp "${BACKUP_DIR}/rustbill-server" "${INSTALL_DIR}/rustbill-server"
fi
if [ -f "${BACKUP_DIR}/rustbill-cli" ]; then
    cp "${BACKUP_DIR}/rustbill-cli" "${INSTALL_DIR}/rustbill-cli"
fi
if [ -d "${BACKUP_DIR}/plugins" ]; then
    rm -rf "${INSTALL_DIR}/plugins"
    cp -r "${BACKUP_DIR}/plugins" "${INSTALL_DIR}/plugins"
fi
echo "回滚完成。如需重启服务: sudo systemctl restart rustbill-server"
ROLLBACK_SCRIPT
    chmod +x "${BACKUP_DIR}/rollback.sh"

    ok "备份完成"
    echo -e "  ${YELLOW}回滚脚本: ${BACKUP_DIR}/rollback.sh${NC}"
else
    SERVICE_WAS_RUNNING=false
fi

# ── 下载 ─────────────────────────────────────────────────────────────────────
section "下载发布包"

TARBALL="rustbill-${RUSTBILL_ARCH}.tar.gz"
DOWNLOAD_URL="${DOWNLOAD_BASE}/${VERSION}/${TARBALL}"

info "下载地址: ${DOWNLOAD_URL}"
echo ""

# 带进度条的下载
curl -fL --progress-bar -o "/tmp/${TARBALL}" "$DOWNLOAD_URL" || {
    err "下载失败。请确认版本 ${VERSION} 存在且包含 ${RUSTBILL_ARCH} 架构。"
    if $IS_UPDATING && [ -n "$BACKUP_DIR" ]; then
        warn "更新失败，备份保存在 ${BACKUP_DIR}，可使用 rollback.sh 回滚"
    fi
    exit 1
}
ok "下载完成: ${TARBALL}"

# ── 校验 SHA256 ──────────────────────────────────────────────────────────────
section "校验 SHA256"

SHA256_URL="${API_BASE}/releases/tags/${VERSION}"

if command -v jq &>/dev/null; then
    echo "  正在获取 checksum..."
    RELEASE_BODY=$(curl -sf "$SHA256_URL" 2>/dev/null | jq -r '.body' 2>/dev/null) || true

    if [ -n "$RELEASE_BODY" ]; then
        EXPECTED_SHA=$(echo "$RELEASE_BODY" | grep -oP "[0-9a-f]{64}\s+${TARBALL}" | head -1 | awk '{print $1}' || true)
        if [ -n "$EXPECTED_SHA" ]; then
            ACTUAL_SHA=$(sha256sum "/tmp/${TARBALL}" | awk '{print $1}')
            if [ "$EXPECTED_SHA" = "$ACTUAL_SHA" ]; then
                ok "SHA256 校验通过"
            else
                err "SHA256 校验失败!"
                echo "  期望: ${EXPECTED_SHA}"
                echo "  实际: ${ACTUAL_SHA}"
                rm -f "/tmp/${TARBALL}"
                exit 1
            fi
        else
            warn "未能从 release notes 中提取 ${TARBALL} 的 checksum，跳过校验"
            warn "请手动验证: sha256sum /tmp/${TARBALL}"
        fi
    else
        warn "无法获取 release 信息，跳过校验"
    fi
else
    warn "jq 未安装，跳过 SHA256 校验"
    warn "安装 jq 后重新运行可自动校验: apt install jq"
fi

# ── 解压安装 ─────────────────────────────────────────────────────────────────
if $IS_UPDATING; then
    section "更新安装"
else
    section "解压安装"
fi

info "正在解压到 ${INSTALL_DIR}..."

if $IS_UPDATING; then
    # 更新模式：覆盖二进制和插件，保留配置和前端
    # 先解压到临时目录
    TMP_EXTRACT="/tmp/rustbill-extract-$$"
    mkdir -p "$TMP_EXTRACT"
    tar -xzf "/tmp/${TARBALL}" -C "$TMP_EXTRACT" --strip-components=1 || {
        err "解压失败"
        rm -rf "$TMP_EXTRACT"
        exit 1
    }

    # 保存需要保留的用户文件
    CONFIG_BACKUP="/tmp/rustbill-config-backup-$$"
    mkdir -p "$CONFIG_BACKUP"
    [ -f "${INSTALL_DIR}/config.toml" ]       && cp "${INSTALL_DIR}/config.toml"       "$CONFIG_BACKUP/"
    [ -f "${INSTALL_DIR}/config.local.toml" ] && cp "${INSTALL_DIR}/config.local.toml" "$CONFIG_BACKUP/"

    # 替换二进制
    cp "$TMP_EXTRACT/rustbill-server" "${INSTALL_DIR}/rustbill-server"
    cp "$TMP_EXTRACT/rustbill-cli"    "${INSTALL_DIR}/rustbill-cli"

    # 替换插件目录（全量替换，保留旧插件备份）
    if [ -d "${INSTALL_DIR}/plugins" ]; then
        rm -rf "${INSTALL_DIR}/plugins.old"
        mv "${INSTALL_DIR}/plugins" "${INSTALL_DIR}/plugins.old"
    fi
    cp -r "$TMP_EXTRACT/plugins" "${INSTALL_DIR}/plugins"

    # 替换客户前台
    if [ -d "${INSTALL_DIR}/consumer-dist" ]; then
        rm -rf "${INSTALL_DIR}/consumer-dist.old"
        if [ -d "${INSTALL_DIR}/consumer-dist" ]; then
            mv "${INSTALL_DIR}/consumer-dist" "${INSTALL_DIR}/consumer-dist.old"
        fi
    fi
    if [ -d "$TMP_EXTRACT/consumer-dist" ]; then
        cp -r "$TMP_EXTRACT/consumer-dist" "${INSTALL_DIR}/consumer-dist"
    fi

    # 更新配置模板（不覆盖用户配置）
    if [ -f "$TMP_EXTRACT/config.example.toml" ]; then
        cp "$TMP_EXTRACT/config.example.toml" "${INSTALL_DIR}/config.example.toml"
    fi

    # 恢复用户配置
    [ -f "$CONFIG_BACKUP/config.toml" ]       && mv "$CONFIG_BACKUP/config.toml"       "${INSTALL_DIR}/"
    [ -f "$CONFIG_BACKUP/config.local.toml" ] && mv "$CONFIG_BACKUP/config.local.toml" "${INSTALL_DIR}/"

    # 写入版本文件
    echo "$VERSION" > "${INSTALL_DIR}/VERSION"

    # 清理
    rm -rf "$TMP_EXTRACT" "$CONFIG_BACKUP"
    rm -f "/tmp/${TARBALL}"

    ok "更新完成 (${VERSION})"

    # 显示更新内容
    echo ""
    echo -e "  ${BOLD}已更新的组件:${NC}"
    echo "    ├── rustbill-server       → ${VERSION}"
    echo "    ├── rustbill-cli          → ${VERSION}"
    echo "    ├── plugins/              → ${VERSION}"
    echo "    ├── consumer-dist/        → ${VERSION}"
    echo "    ├── config.example.toml   → ${VERSION}"
    echo "    └── config.toml           已保留"
    echo ""
    echo -e "  ${BOLD}旧文件保留:${NC}"
    if [ -d "${INSTALL_DIR}/plugins.old" ]; then
        echo "    ├── plugins.old/          旧插件（确认正常后可删除）"
    fi
    if [ -d "${INSTALL_DIR}/consumer-dist.old" ]; then
        echo "    └── consumer-dist.old/    旧前端（确认正常后可删除）"
    fi
else
    # 全新安装：直接解压
    tar -xzf "/tmp/${TARBALL}" -C "$INSTALL_DIR" --strip-components=1
    rm -f "/tmp/${TARBALL}"

    # 写入版本文件
    echo "$VERSION" > "${INSTALL_DIR}/VERSION"

    ok "解压完成"

    # 列出安装内容
    echo ""
    echo -e "  ${BOLD}已安装的文件:${NC}"
    echo "    ├── rustbill-server       服务端程序"
    echo "    ├── rustbill-cli          命令行管理工具"
    echo "    ├── plugins/              插件目录"
    echo "    ├── consumer-dist/        客户前台 SPA"
    echo "    └── config.example.toml   配置模板"
fi

# ── 配置初始化 (新安装) ──────────────────────────────────────────────────────
if ! $IS_UPDATING; then
    section "配置初始化"

    if [ ! -f "${INSTALL_DIR}/config.toml" ]; then
        cp "${INSTALL_DIR}/config.example.toml" "${INSTALL_DIR}/config.toml"
        ok "已从模板创建 config.toml"
    else
        ok "config.toml 已存在，跳过"
    fi

    echo ""
    echo -e "  ${YELLOW}⚠ 请务必编辑 config.toml 填入以下必填项:${NC}"
    echo "    - [db].url            PostgreSQL 连接串"
    echo "    - [jwt].secret        JWT 签名密钥 (随机字符串)"
    echo "    - [bootstrap].admin_password  初始管理员密码"
    echo ""

    if ! $NON_INTERACTIVE; then
        echo -n "  是否现在编辑配置? [y/N]: "
        read -r edit_now
        if [ "${edit_now,,}" = "y" ] || [ "${edit_now,,}" = "yes" ]; then
            EDITOR="${EDITOR:-${VISUAL:-}}"
            if [ -z "$EDITOR" ]; then
                for candidate in nano vim vi; do
                    if command -v "$candidate" &>/dev/null; then
                        EDITOR="$candidate"
                        break
                    fi
                done
            fi
            if [ -n "$EDITOR" ]; then
                "$EDITOR" "${INSTALL_DIR}/config.toml"
            else
                warn "未找到编辑器，请手动编辑 ${INSTALL_DIR}/config.toml"
            fi
        fi
    fi
fi

# ── systemd 服务 ─────────────────────────────────────────────────────────────
section "Systemd 服务"

if $IS_UPDATING; then
    # 更新模式下，如果之前有 systemd 服务则自动重启
    if $SERVICE_WAS_RUNNING; then
        info "正在重启 rustbill-server 服务..."
        sudo systemctl start rustbill-server || warn "服务启动失败，请检查日志: sudo journalctl -u rustbill-server"

        # 验证服务状态
        sleep 2
        if systemctl is-active --quiet rustbill-server 2>/dev/null; then
            ok "服务已成功重启"
        else
            err "服务启动异常，请检查日志: sudo journalctl -u rustbill-server -n 50"
            echo -e "  ${YELLOW}回滚命令: ${BACKUP_DIR}/rollback.sh${NC}"
        fi
    else
        info "服务未在运行，跳过重启"
        echo ""
        echo -e "  ${BOLD}启动命令:${NC}"
        echo "    cd ${INSTALL_DIR} && ./rustbill-server"
        echo "    # 或使用 systemd: sudo systemctl start rustbill-server"
    fi
else
    # 新安装：询问是否配置 systemd
    echo "  RustBill 可以注册为 systemd 服务，实现开机自启和自动重启。"
    if $NON_INTERACTIVE; then
        install_service="y"
        echo -n "  是否安装 systemd 服务? [y/N]: "
        echo "Y (非交互模式)"
    else
        echo -n "  是否安装 systemd 服务? [y/N]: "
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
            warn "已使用 sudo 写入 systemd 服务文件"
        fi

        sudo systemctl daemon-reload
        ok "systemd 服务已安装: rustbill-server"
        echo ""
        echo -e "  ${BOLD}管理命令:${NC}"
        echo "    sudo systemctl start rustbill-server    启动"
        echo "    sudo systemctl enable rustbill-server   开机自启"
        echo "    sudo systemctl status rustbill-server   查看状态"
        echo "    sudo journalctl -u rustbill-server -f   查看日志"
    else
        echo ""
        echo -e "  ${BOLD}手动启动命令:${NC}"
        echo "    cd ${INSTALL_DIR} && ./rustbill-server"
    fi
fi

# ── 完成 ─────────────────────────────────────────────────────────────────────
if $IS_UPDATING; then
    section "更新完成"

    echo -e "  ${GREEN}RustBill 已从 ${INSTALLED_VERSION:-旧版本} 更新到 ${VERSION}${NC}"
    echo -e "  ${BOLD}安装目录: ${INSTALL_DIR}${NC}"
    echo ""
    echo -e "  ${BOLD}版本文件:${NC} ${INSTALL_DIR}/VERSION"
    echo -e "  ${BOLD}备份目录:${NC} ${BACKUP_DIR}"
    echo -e "  ${BOLD}回滚脚本:${NC} ${BACKUP_DIR}/rollback.sh"
    echo ""
    echo -e "  ${YELLOW}提示:${NC} 数据库迁移由 rustbill-server 启动时自动执行。"
    echo "  更新后首次启动会自动应用新迁移（如有）。"
    echo ""
    echo -e "  ${YELLOW}清理旧文件（确认一切正常后）:${NC}"
    echo "    rm -rf ${INSTALL_DIR}/plugins.old"
    echo "    rm -rf ${INSTALL_DIR}/consumer-dist.old"
else
    section "部署完成"

    echo -e "  ${GREEN}RustBill ${VERSION} 已成功部署到:${NC}"
    echo -e "  ${BOLD}${INSTALL_DIR}${NC}"
    echo ""
    echo -e "  ${BOLD}快速开始:${NC}"
    echo "    1. 编辑配置: ${INSTALL_DIR}/config.toml"
    echo "    2. 启动服务: cd ${INSTALL_DIR} && ./rustbill-server"
    echo "    3. 管理后台: http://localhost:50051/admin"
    echo "    4. CLI 管理: ${INSTALL_DIR}/rustbill-cli --help"
    echo ""
    echo "  ${BOLD}数据库迁移${NC}由 rustbill-server 启动时自动执行。"
    echo ""
    echo -e "  ${CYAN}部署客户前台:${NC} 将 ${INSTALL_DIR}/consumer-dist/ 中的"
    echo "    静态文件部署到任意 Web 服务器 (Nginx/Caddy),"
    echo "    并配置反向代理指向 rustbill-server gRPC 端口。"
    echo "    详见: https://github.com/zyxisme/rustbill/tree/main/docs"
    echo ""
fi
