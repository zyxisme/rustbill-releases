<p align="center">
  <img src="logo.svg" width="80" alt="RustBill">
</p>

<h1 align="center">RustBill</h1>

<p align="center">基于 Rust 的分布式云服务器财务管理系统 — 插件化架构，支持多供应商、多支付网关、多渠道通知。</p>

<p align="center">
  <a href="https://github.com/zyxisme/rustbill-releases/releases"><img src="https://img.shields.io/github/v/release/zyxisme/rustbill-releases?label=latest&color=green" alt="Release"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-linux%20x86__64%20%7C%20arm64-blue" alt="Platform">
</p>

---

## 一键部署

```bash
# 交互式（推荐 — 支持版本选择菜单、配置引导）
bash <(curl -fsSL https://raw.githubusercontent.com/zyxisme/rustbill-releases/main/deploy.sh)
```

交互式脚本，逐步引导完成部署：

1. **架构检测** — 自动识别 x86_64 / ARM64
2. **版本选择** — 编号菜单 + Release Notes 预览
3. **下载 & SHA256 校验** — 安全完整性验证
4. **交互式配置向导**:
   - **数据库** — 自动探测本地 PostgreSQL，测试连接，自动创建用户和数据库
   - **JWT 密钥** — 自动生成强随机密钥
   - **管理员账户** — 交互输入或自动生成强密码
   - **域名 & HTTPS** — 一键配置 Caddy 反向代理 + Let's Encrypt 自动证书
   - **Caddy 安装** — 自动检测/安装/配置/启动 Caddy
5. **systemd 服务** — 可选开机自启，安装后可直接启动验证

**命令行选项：**

```bash
bash <(curl -fsSL ...) -- -y           # 非交互模式（CI/CD，自动选最新版）
bash <(curl -fsSL ...) -- -u           # 仅更新已有实例
bash <(curl -fsSL ...) -- -y -v v1.0   # 非交互指定版本
```

> 需要 bash 4+、curl、tar。PostgreSQL 16+ 需单独安装。

## 手动下载

从 [Releases](https://github.com/zyxisme/rustbill-releases/releases) 页面下载对应架构的 `tar.gz`：

```bash
# linux-x86_64
wget https://github.com/zyxisme/rustbill-releases/releases/latest/download/rustbill-linux-x86_64.tar.gz

# linux-arm64
wget https://github.com/zyxisme/rustbill-releases/releases/latest/download/rustbill-linux-arm64.tar.gz

# 解压启动
tar -xzf rustbill-linux-*.tar.gz
cd rustbill
cp config.example.toml config.toml
# 编辑 config.toml: db.url / jwt.secret / bootstrap.admin_password
./rustbill-server
```

浏览器打开 `http://localhost:50051/admin` 进入管理后台。

## 包含组件

| 组件 | 说明 |
|------|------|
| `rustbill-server` | gRPC 服务端，内嵌 Admin SPA |
| `rustbill-cli` | CLI 管理工具，含交互式 TUI (8 标签页) |
| `plugins/` | 插件目录 — provider / gateway / notifier |
| `consumer-dist/` | 客户前台 SPA，独立部署 |
| `config.example.toml` | 配置模板 |

## 架构

```
用户浏览器 → gRPC-Web → rustbill-server → PostgreSQL
                              ├── Provider 插件 → 云厂商 / KVM / Incus
                              ├── Gateway 插件 → 支付网关
                              └── Notifier 插件 → 邮件 / Webhook
```

## 内置插件

| 类型 | 插件 | 说明 |
|------|------|------|
| Provider | KVM | KVM/QEMU 第一方供应商 |
| Provider | Incus | Incus 虚拟化容器 |
| Provider | RustBill | 上游 RustBill 代理分销 |
| Gateway | BankTransfer | 银行转账支付 |
| Gateway | Yipay | 易支付聚合支付 (支付宝/微信/QQ) |
| Notifier | Email | SMTP 邮件通知 |
| Notifier | Webhook | 自定义 HTTP 回调 |

## 最低要求

- Linux x86_64 或 ARM64
- PostgreSQL 16+
- 内存 512 MB+ (推荐 2 GB+)

## 文档

完整文档见 [私有仓库 docs/](https://github.com/zyxisme/rustbill/tree/main/docs)。

## 从源码构建

本项目为自动构建的发布版。如需从源码构建，请访问 [zyxisme/rustbill](https://github.com/zyxisme/rustbill)（私有仓库）。
