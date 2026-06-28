<div align="center">

# X-NET Panel

**VPN / 代理管理面板与 SSH 隧道 — 基于 Sing-box 核心，支持多节点架构**

[![Sing-box](https://img.shields.io/badge/engine-sing--box-10b981)](https://sing-box.sagernet.org)
[![Backend](https://img.shields.io/badge/backend-Go-00ADD8)](https://go.dev)
[![Frontend](https://img.shields.io/badge/frontend-React%20%2B%20Vite-61dafb)](https://react.dev)
[![License](https://img.shields.io/badge/license-X--NET-yellow)](../LICENSE)

🌐 [فارسی](README.md) · [English](README.en.md) · [Русский](README.ru.md) · **中文**

</div>

---

## 简介

**X-NET** 是一个用于创建和管理 **VPN/代理** 服务及 **SSH 账户** 的面板。通过它您可以创建用户（订阅），控制每位用户的流量和到期时间，并分发订阅链接。

- 使用 **Sing-box** 核心处理流量
- 支持通过多种协议创建 **SSH 账户**：SSH-over-WebSocket、Stunnel/TLS、SlowDNS、Dropbear 和 BadVPN/UDPGW
- **访问隔离：** 每个 SSH 账户只能访问其自身的端口/协议
- 通过单一界面管理**多台服务器**：一台"面板"服务器，其余均为"节点"

---

## 安装

### 前提条件

- Linux 服务器（推荐 Ubuntu / Debian），`amd64` 架构
- `root` 权限

### 安装面板

```bash
apt update
bash <(curl -fsSL https://raw.githubusercontent.com/xpanel-cp/x-net/main/install/xnet.sh)
```

安装程序会在菜单中显示最新的 3 个版本。如需直接安装特定版本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpanel-cp/x-net/main/install/xnet.sh) v1.2.3
```

首次安装时，系统会询问面板端口和管理员信息，创建 systemd 服务，安装 sing-box 核心和 SSH 子系统，并在防火墙中开放端口。再次运行（更新）时，`.env` 文件和数据库将被完整保留。

### 安装节点（Agent）

在节点服务器上运行相同的安装命令，在询问角色时选择 `agent`。然后在面板中进入**服务器与节点 → 注册节点**；将生成的密钥填入节点的 `/opt/xnet/.env` 文件并重启服务：

```bash
nano /opt/xnet/.env
#   NODE_ROLE=agent
#   NODE_API_KEY=xnetnode_...
#   NODE_SECRET_KEY=...
systemctl restart xnet
```

### 服务管理

```bash
systemctl status xnet      # 查看服务状态
journalctl -u xnet -f      # 实时日志
systemctl restart xnet     # 重启服务
```

> **安全提示：** 地址 `http://IP:PORT` 未经加密。在生产环境中，请将面板部署在域名 + HTTPS 之后。

---

## 协议

### 核心协议（Sing-box）

`VLESS` · `VMess` · `Trojan` · `Shadowsocks` · `SOCKS` · `HTTP` · `TUIC` · `Hysteria2`

### 传输层

`TCP` · `WebSocket` · `gRPC` · `HTTP/2` · `HTTPUpgrade` · `QUIC`

### 安全性 / TLS

`Plain` · `TLS` · `Reality`

### SSH

`SSH-over-WebSocket` · `Stunnel/TLS` · `SlowDNS` · `Dropbear` · `BadVPN/UDPGW`

---

## 功能特性

### 入站管理
创建、编辑、克隆、启用/禁用，并支持部署到多个节点

### 订阅管理
订阅链接、二维码、流量限额、到期日期、同时在线设备数限制、续费与流量重置

### SSH 账户
创建系统用户，限制流量及同时登录数量

### 多节点
panel/agent 角色、自动同步，以及**单一活跃节点（Follow-Me）**功能，支持从订阅链接切换节点

### 安全性
JWT 登录、双因素认证（TOTP）、访问角色（管理员/操作员/代理商），以及面板与节点之间的 HMAC 签名验证

### 域名与证书
真实 DNS 验证，TLS 证书签发/续签（Let's Encrypt）

### 路由与网络
路由规则（GeoSite/GeoIP、广告拦截）、DNS 配置与 TCP BBR 拥塞控制

### 监控
仪表板、流量分析、实时日志、数据库备份与恢复

### API
Bearer 令牌、API 文档与测试平台，以及 IP 白名单防火墙

### 用户界面
多语言支持（波斯语/英语/俄语/中文）、明暗主题切换、页面自动更新

---

## 许可证

本项目在 **X-NET Software License（版本 1.0）** 下发布——这是一份专有许可证。完整文本见 [`LICENSE`](../LICENSE) 文件。

| 状态 | 说明 |
|---|---|
| ✅ 允许 | 将官方编译版本用于个人和商业目的，可在任意数量的服务器上安装 |
| 🔒 专有 | 源代码——无权访问、修改、分发或进行逆向工程 |
| ❌ 禁止 | 删除/修改版权声明、分发修改版本、未经书面许可使用 X-NET 名称 |
| ⚠️ 无保证 | 软件按"现状"提供；遵守适用法律法规是用户自身的责任 |

> **Copyright (c) 2026 X-NET. All Rights Reserved.**
