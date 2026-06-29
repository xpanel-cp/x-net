<div align="center">

# X-NET Panel

**VPN / Proxy Management Panel and SSH Tunnel — Powered by Sing-box Core with Multi-Node Architecture**

[![Sing-box](https://img.shields.io/badge/engine-sing--box-10b981)](https://sing-box.sagernet.org)
[![Backend](https://img.shields.io/badge/backend-Go-00ADD8)](https://go.dev)
[![Frontend](https://img.shields.io/badge/frontend-React%20%2B%20Vite-61dafb)](https://react.dev)
[![License](https://img.shields.io/badge/license-X--NET-yellow)](../LICENSE)

🌐 [فارسی](README.md) · **English** · [Русский](README.ru.md) · [中文](README.zh.md)

</div>

---

## Introduction

**X-NET** is a panel for creating and managing **VPN/Proxy** services and **SSH accounts**. Through it you create users (subscriptions), control the traffic and expiration of each one, and deliver subscription links.

- Traffic processing with the **Sing-box** core
- Ability to create **SSH accounts** with various protocols: SSH-over-WebSocket, Stunnel/TLS, SlowDNS, Dropbear, and BadVPN/UDPGW
- **Access isolation:** Each SSH account only has access to its own port/protocol
- **Multi-server management** from a single interface: one "panel" server and the rest as "nodes"

---

## Installation

### Prerequisites

- Linux server (Ubuntu / Debian recommended), `amd64` architecture
- `root` access

### Panel Installation

```bash
apt update
bash <(curl -fsSL https://raw.githubusercontent.com/xpanel-cp/x-net/main/install/xnet.sh)
```

The installer shows the 3 latest versions in a menu. To directly install a specific version:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpanel-cp/x-net/main/install/xnet.sh) v1.2.3
```

During the initial installation, the panel port and admin credentials are requested, a systemd service is created, the sing-box core and SSH subsystems are installed, and the port is opened in the firewall. On re-run (update), the `.env` file and database are preserved.

### Node (Agent) Installation

Run the same installation command on the node server and select the `agent` option when prompted for a role. Then in the panel, go to **Servers & Nodes → Register Node**; place the generated keys in `/opt/xnet/.env` on the node and restart the service:

```bash
nano /opt/xnet/.env
#   NODE_ROLE=agent
#   NODE_API_KEY=xnetnode_...
#   NODE_SECRET_KEY=...
systemctl restart xnet
```

### Service Management

```bash
systemctl status xnet      # Service status
journalctl -u xnet -f      # Live logs
systemctl restart xnet     # Restart service
```

> **Security:** The address `http://IP:PORT` is not encrypted. For production environments, place the panel behind a domain + HTTPS.

---

## Protocols

### Core Protocols (Sing-box)

`VLESS` · `VMess` · `Trojan` · `Shadowsocks` · `SOCKS` · `HTTP` · `TUIC` · `Hysteria2`

### Transports

`TCP` · `WebSocket` · `gRPC` · `HTTP/2` · `HTTPUpgrade` · `QUIC`

### Security / TLS

`Plain` · `TLS` · `Reality`

### SSH

`SSH-over-WebSocket` · `Stunnel/TLS` · `SlowDNS` · `Dropbear` · `BadVPN/UDPGW`

## Features

### Inbound Management
Create, edit, clone, enable/disable, and deploy across multiple nodes

### Subscription Management
Subscription link, QR Code, traffic limit, expiration date, concurrent device limit, renewal, and traffic reset

### SSH Accounts
Create system users, restrict traffic and concurrent login count

### Multi-Node
panel/agent roles, automatic synchronization, and **single active node (Follow-Me)** with node switching via the subscription link

### Security
JWT login, two-factor authentication (TOTP), access roles (Admin/Operator/Reseller), and HMAC signing between panel and node

### Domain & Certificate
Real DNS verification, TLS certificate issuance/renewal (Let's Encrypt)

### Routing & Network
Routing rules (GeoSite/GeoIP, AdBlock), DNS configuration, and TCP BBR congestion control

### Monitoring
Dashboard, traffic analysis, live logs, database backup/restore

### API
Bearer token, documentation and playground, and IP whitelist firewall

### Interface
Multi-language (Persian/English/Russian/Chinese), light and dark themes, automatic page updates

## License

This project is released under the **X-NET Software License (Version 1.0)** — a proprietary license. Full text in the [`LICENSE`](../LICENSE) file.

| Status | Description |
|---|---|
| ✅ Allowed | Use of the official compiled distribution for personal and commercial purposes, installation on any number of servers |
| 🔒 Proprietary | Source code — no right to access, modify, distribute, or reverse engineer |
| ❌ Prohibited | Removing/modifying copyright notices, distributing modified versions, using the X-NET name without written permission |
| ⚠️ No Warranty | Software is provided "as is"; compliance with applicable laws is the user's responsibility |

> **Copyright (c) 2026 X-NET. All Rights Reserved.**
