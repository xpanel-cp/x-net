<div align="center">
# X-NET Panel
**VPN / Proxy and SSH Tunneling Management Panel — Powered by Sing-box Core and Multi-Node Architecture**
[![Sing-box](https://img.shields.io/badge/engine-sing--box-10b981)](https://sing-box.sagernet.org)
[![Backend](https://img.shields.io/badge/backend-Go-00ADD8)](https://go.dev)
[![Frontend](https://img.shields.io/badge/frontend-React%20%2B%20Vite-61dafb)](https://react.dev)
[![License](https://img.shields.io/badge/license-X--NET-yellow)](../LICENSE)
</div>

## Language Versions
[English](README.md) | [فارسی](README.fa.md) | [Русский](README.ru.md) | [中文](README.zh.md)

---
## Introduction
The **X-NET** project is a panel for creating and managing **VPN/Proxy** services and **SSH accounts**. Through it, you can create users (subscriptions), control their traffic and expiration, and deliver subscription links.

- Traffic processing with **Sing-box** core
- Ability to create **SSH accounts** with various protocols: SSH-over-WebSocket, Stunnel/TLS, SlowDNS, Dropbear, and BadVPN/UDPGW
- **Access Isolation:** Each SSH account has access only to its own port/protocol
- Manage **multiple servers** from a single interface: one "panel" server and the rest "nodes"

## Installation
### Prerequisites
- Linux server (Ubuntu / Debian recommended), `amd64` architecture
- `root` access

### Panel Installation
```bash
apt update
bash <(curl -fsSL https://raw.githubusercontent.com/xpanel-cp/x-net/main/install/xnet.sh)
```

The installer shows the last 3 versions in a menu; for direct installation of a specific version:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpanel-cp/x-net/main/install/xnet.sh) v1.2.3
```

During initial installation, the panel port and admin credentials are requested, a systemd service is created, sing-box core and SSH subsystems are installed, and the port is opened in the firewall. On subsequent runs (updates), the `.env` file and database are preserved.

### Node (Agent) Installation
Run the same installation command on the node server and select `agent` for the role. Then, in the panel, go to **Servers and Nodes → Register Node**; place the generated keys in the node's `/opt/xnet/.env` and restart the service:
```bash
nano /opt/xnet/.env
# NODE_ROLE=agent
# NODE_API_KEY=xnetnode_...
# NODE_SECRET_KEY=...
systemctl restart xnet
```

### Service Management
```bash
systemctl status xnet # Service status
journalctl -u xnet -f # Live logs
systemctl restart xnet # Restart
```

> **Security:** The address `http://IP:PORT` is not encrypted; for production, place the panel behind a domain + HTTPS.

## Protocols
### Core Protocols (Sing-box)
`VLESS` · `VMess` · `Trojan` · `Shadowsocks` · `SOCKS` · `HTTP` · `TUIC` · `Hysteria2` · `WireGuard` · `Mixed` · `TUN` · `ShadowTLS` · `NaiveProxy`

### Transports
`TCP` · `WebSocket` · `gRPC` · `HTTP/2` · `HTTPUpgrade` · `QUIC`

### Security / TLS
`Plain` · `TLS` · `Reality`

### SSH
`SSH-over-WebSocket` · `Stunnel/TLS` · `SlowDNS` · `Dropbear` · `BadVPN/UDPGW`

## Features
### Inbound Management
Create, edit, clone, enable/disable, and deploy on multiple nodes

### Subscription Management
Subscription links, QR Code, volume cap, expiration date, concurrent device limit, renewal, and traffic reset

### SSH Accounts
Create system users, limit traffic and concurrent logins

### Multi-Node
Panel/agent roles, automatic synchronization, and **Single Active Node (Follow-Me)** with node switching via subscription link

### Security
JWT login, Two-Factor Authentication (TOTP), access roles (admin/operator/representative), and HMAC signing between panel and nodes

### Domain and Certificates
Real DNS checks, TLS certificate issuance/renewal (Let's Encrypt)

### Routing and Network
Routing rules (GeoSite/GeoIP, AdBlock), DNS configuration, and TCP BBR congestion control

### Monitoring
Dashboard, traffic analytics, live logs, database backup/restore

### API
Bearer token, documentation and playground, IP whitelist firewall

### User Interface
Multilingual (Persian/English/Russian/Chinese), light and dark themes, automatic page updates

## License
This project is released under the **X-NET Software License (Version 1.0)** — a custom license. Full text in the [`LICENSE`](../LICENSE) file.

| Status | Description |
|---|---|
| ✅ Allowed | Use of official compiled distribution for personal and commercial purposes, installation on any number of servers |
| 🔒 Proprietary | Source code — no right to access, modify, distribute, or reverse engineer |
| ❌ Prohibited | Remove/change copyright, distribute modified versions, use X-NET name without written permission |
| ⚠️ No Warranty | Software provided "as is"; user is responsible for legal compliance |

> **Copyright (c) 2026 X-NET. All Rights Reserved.**
