# RustBill

基于 Rust 的分布式云服务器财务管理系统，支持多供应商、多支付网关、多通知渠道插件化扩展。

## 快速开始

```bash
# 下载最新版本
wget https://github.com/zyxisme/rustbill-releases/releases/latest/download/rustbill-linux-x86_64.tar.gz

# 解压并启动
tar -xzf rustbill-linux-x86_64.tar.gz
cd rustbill
cp config.example.toml config.toml
# 编辑 config.toml，填入数据库地址和 JWT secret
./rustbill-server
```

浏览器打开 `http://localhost:50051/admin` 进入管理后台。

## 包含组件

| 组件 | 说明 |
|------|------|
| `rustbill-server` | gRPC 服务端，内嵌 Admin SPA |
| `rustbill-cli` | CLI 管理工具，含交互式 TUI |
| `plugins/` | 插件目录（provider / gateway / notifier） |
| `consumer-dist/` | 前台客户 SPA，独立部署 |

## 文档

完整文档见 [docs/](https://github.com/zyxisme/rustbill/tree/main/docs)（私有仓库）。

## 架构

```
用户浏览器 → gRPC-Web → rustbill-server → PostgreSQL
                              ├── Provider 插件 → 云厂商 / KVM / Incus
                              ├── Gateway 插件 → 支付网关
                              └── Notifier 插件 → 邮件 / Webhook
```

## 最低要求

- Linux x86_64 或 ARM64
- PostgreSQL 16+
- 系统服务单元配置见 `config.example.toml`
