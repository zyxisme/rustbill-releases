#!/usr/bin/env bash
set -euo pipefail

# RustBill 交互式部署脚本
# 从 GitHub Releases (zyxisme/rustbill-releases) 下载并部署

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

# ── 选择版本 ─────────────────────────────────────────────────────────────────
section "获取版本信息"

echo "  正在查询最新版本..."
RELEASES_JSON=$(curl -sf "${API_BASE}/releases?per_page=10" 2>/dev/null) || {
    err "无法访问 GitHub Releases，请检查网络连接"
    exit 1
}

# 使用 jq 美化输出（若已安装），否则用纯文本
if command -v jq &>/dev/null; then
    echo ""
    echo -e "  ${BOLD}可用版本:${NC}"
    echo "$RELEASES_JSON" | jq -r '.[] | "    \(.tag_name)  |  \(.published_at // "unknown")  |  \(.name // .tag_name)"' | head -10
    echo ""

    echo -n "  输入版本号 (直接回车使用最新版): "
    read -r VERSION

    if [ -z "$VERSION" ]; then
        VERSION=$(echo "$RELEASES_JSON" | jq -r '.[0].tag_name')
        ok "已选择最新版本: ${BOLD}${VERSION}${NC}"
    else
        # 去掉可能的 v 前缀再统一加回
        VERSION="${VERSION#v}"
        VERSION="v${VERSION}"
        ok "已选择版本: ${BOLD}${VERSION}${NC}"
    fi
else
    # 无 jq 时的简化输出
    echo ""
    echo -e "  ${BOLD}可选标签 (最近 10 个):${NC}"
    echo "$RELEASES_JSON" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -10 | while read -r tag; do
        echo "    - $tag"
    done
    echo ""

    echo -n "  输入版本号 (直接回车使用最新版): "
    read -r VERSION

    if [ -z "$VERSION" ]; then
        VERSION=$(echo "$RELEASES_JSON" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1)
        ok "已选择最新版本: ${BOLD}${VERSION}${NC}"
    else
        VERSION="${VERSION#v}"
        VERSION="v${VERSION}"
        ok "已选择版本: ${BOLD}${VERSION}${NC}"
    fi
fi

# ── 选择安装目录 ─────────────────────────────────────────────────────────────
section "选择安装目录"

DEFAULT_DIR="$HOME/rustbill"
echo -n "  安装目录 [${DEFAULT_DIR}]: "
read -r INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"

if [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    warn "目录 ${INSTALL_DIR} 已存在且非空"
    echo -n "  是否覆盖? [y/N]: "
    read -r confirm
    if [ "${confirm,,}" != "y" ] && [ "${confirm,,}" != "yes" ]; then
        echo "  已取消。"
        exit 0
    fi
    rm -rf "$INSTALL_DIR"
fi
mkdir -p "$INSTALL_DIR"
ok "安装目录: ${BOLD}${INSTALL_DIR}${NC}"

# ── 下载 ─────────────────────────────────────────────────────────────────────
section "下载发布包"

TARBALL="rustbill-${RUSTBILL_ARCH}.tar.gz"
DOWNLOAD_URL="${DOWNLOAD_BASE}/${VERSION}/${TARBALL}"

info "下载地址: ${DOWNLOAD_URL}"
echo ""

# 带进度条的下载
curl -fL --progress-bar -o "/tmp/${TARBALL}" "$DOWNLOAD_URL" || {
    err "下载失败。请确认版本 ${VERSION} 存在且包含 ${RUSTBILL_ARCH} 架构。"
    exit 1
}
ok "下载完成: ${TARBALL}"

# ── 校验 SHA256 (从 release notes 中提取) ────────────────────────────────────
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

# ── 解压 ─────────────────────────────────────────────────────────────────────
section "解压安装"

info "正在解压到 ${INSTALL_DIR}..."
tar -xzf "/tmp/${TARBALL}" -C "$INSTALL_DIR" --strip-components=1
rm -f "/tmp/${TARBALL}"

ok "解压完成"

# 列出安装内容
echo ""
echo -e "  ${BOLD}已安装的文件:${NC}"
echo "    ├── rustbill-server       服务端程序"
echo "    ├── rustbill-cli          命令行管理工具"
echo "    ├── plugins/              插件目录"
echo "    ├── consumer-dist/        客户前台 SPA"
echo "    └── config.example.toml   配置模板"

# ── 配置初始化 ───────────────────────────────────────────────────────────────
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
echo -n "  是否现在编辑配置? [y/N]: "
read -r edit_now
if [ "${edit_now,,}" = "y" ] || [ "${edit_now,,}" = "yes" ]; then
    # 尝试找到可用的编辑器
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

# ── systemd 服务 (可选) ──────────────────────────────────────────────────────
section "Systemd 服务 (可选)"

echo "  RustBill 可以注册为 systemd 服务，实现开机自启和自动重启。"
echo -n "  是否安装 systemd 服务? [y/N]: "
read -r install_service

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

# ── 完成 ─────────────────────────────────────────────────────────────────────
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
