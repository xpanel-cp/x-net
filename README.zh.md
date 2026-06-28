<div align="center">
# X-NET Panel
**VPN / Proxy 和 SSH 隧道管理面板 — 基于 Sing-box 内核和多节点架构**
[![Sing-box](https://img.shields.io/badge/engine-sing--box-10b981)](https://sing-box.sagernet.org)
[![Backend](https://img.shields.io/badge/backend-Go-00ADD8)](https://go.dev)
[![Frontend](https://img.shields.io/badge/frontend-React%20%2B%20Vite-61dafb)](https://react.dev)
[![License](https://img.shields.io/badge/license-X--NET-yellow)](../LICENSE)
</div>

## 语言版本
[English](README.md) | [فارسی](README.fa.md) | [Русский](README.ru.md) | [中文](README.zh.md)

---
## 介绍
**X-NET** 项目是一个用于创建和管理 **VPN/Proxy** 服务以及 **SSH 账户** 的面板。通过它，您可以创建用户（订阅），控制每个用户的流量和到期时间，并提供订阅链接。

- 使用 **Sing-box** 内核处理流量
- 支持创建具有多种协议的 **SSH 账户**：SSH-over-WebSocket、Stunnel/TLS、SlowDNS、Dropbear 和 BadVPN/UDPGW
- **访问隔离：** 每个 SSH 账户仅能访问自己的端口/协议
- 从单一界面管理 **多个服务器**：一个“面板”服务器，其余为“节点”

## 安装
### 先决条件
- Linux 服务器（推荐 Ubuntu / Debian），`amd64` 架构
- `root` 权限

### 安装面板
```bash
apt update
bash <(curl -fsSL https://raw.githubusercontent.com/xpanel-cp/x-net/main/install/xnet.sh)
```

安装程序会在菜单中显示最近 3 个版本；直接安装特定版本：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpanel-cp/x-net/main/install/xnet.sh) v1.2.3
```

首次安装时会询问面板端口和管理员信息，创建 systemd 服务，安装 sing-box 内核和 SSH 子系统，并在防火墙中打开端口。后续运行（更新）时，`.env` 文件和数据库将被保留。

### 安装节点 (Agent)
在节点服务器上运行相同的安装命令，并在角色选择时输入 `agent`。然后在面板中进入 **服务器和节点 → Register Node**；将生成的密钥放入节点的 `/opt/xnet/.env` 并重启服务：
```bash
nano /opt/xnet/.env
# NODE_ROLE=agent
# NODE_API_KEY=xnetnode_...
# NODE_SECRET_KEY=...
systemctl restart xnet
```

### 服务管理
```bash
systemctl status xnet # 服务状态
journalctl -u xnet -f # 实时日志
systemctl restart xnet # 重启
```

> **安全：** 地址 `http://IP:PORT` 未加密；在生产环境中，请将面板置于域名 + HTTPS 之后。

## 协议
### 核心协议 (Sing-box)
`VLESS` · `VMess` · `Trojan` · `Shadowsocks` · `SOCKS` · `HTTP` · `TUIC` · `Hysteria2` · `WireGuard` · `Mixed` · `TUN` · `ShadowTLS` · `NaiveProxy`

### 传输方式 (Transports)
`TCP` · `WebSocket` · `gRPC` · `HTTP/2` · `HTTPUpgrade` · `QUIC`

### 安全 / TLS
`Plain` · `TLS` · `Reality`

### SSH
`SSH-over-WebSocket` · `Stunnel/TLS` · `SlowDNS` · `Dropbear` · `BadVPN/UDPGW`

## 功能
### Inbound 管理
创建、编辑、克隆、启用/禁用并部署到多个节点

### 订阅管理
订阅链接、QR 码、流量上限、到期日期、并发设备限制、续费和流量重置

### SSH 账户
创建系统用户，限制流量和并发登录数

### 多节点
Panel/agent 角色、自动同步，以及 **单活跃节点 (Follow-Me)** 通过订阅链接切换节点

### 安全
JWT 登录、双因素认证 (TOTP)、访问角色（管理员/操作员/代表）以及面板与节点之间的 HMAC 签名

### 域名和证书
真实 DNS 检查、TLS 证书颁发/续期 (Let's Encrypt)

### 路由和网络
路由规则 (GeoSite/GeoIP、AdBlock)、DNS 配置和 TCP BBR 拥塞控制

### 监控
仪表盘、流量分析、实时日志、数据库备份/恢复

### API
Bearer 令牌、文档和 playground、IP 白名单防火墙

### 用户界面
多语言（波斯语/英语/俄语/中文）、浅色和深色主题、页面自动更新

## 许可证
本项目基于 **X-NET Software License (Version 1.0)** — 自定义许可证发布。完整文本见 [`LICENSE`](../LICENSE) 文件。

| 状态 | 说明 |
|---|---|
| ✅ 允许 | 使用官方编译发行版用于个人和商业目的，可安装在任意数量服务器上 |
| 🔒 专有 | 源代码 — 禁止访问、修改、分发或逆向工程 |
| ❌ 禁止 | 删除/更改版权、发布修改版本、未经书面许可使用 X-NET 名称 |
| ⚠️ 无担保 | 软件“按原样”提供；用户负责遵守法律法规 |

> **Copyright (c) 2026 X-NET. All Rights Reserved.**
