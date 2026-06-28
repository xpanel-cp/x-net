#!/bin/bash
# xnet-install-sshd.sh — Sets up multi-sshd instances for protocol isolation
# This script is idempotent and safe to re-run.
#
# Usage:
#   bash xnet-install-sshd.sh [admin_username]
#
# If admin_username is not provided, the script will prompt for it.
# The admin user is added to ssh-tcp-users so they retain SSH access
# after AllowGroups is enabled on the main sshd.

set -euo pipefail

# --- Determine admin SSH user to preserve access ---
ADMIN_SSH_USER="${1:-}"
if [ -z "$ADMIN_SSH_USER" ]; then
    read -r -p "Enter the SSH admin username to preserve access (default: root): " ADMIN_SSH_USER
    ADMIN_SSH_USER="${ADMIN_SSH_USER:-root}"
fi

# Create protocol groups (groupadd -f is idempotent — does nothing if group exists)
for grp in ssh-tcp-users ssh-ws-users ssh-tls-users ssh-slowdns-users ssh-dropbear-users; do
    groupadd -f "$grp"
done

# Add admin user to ssh-tcp-users BEFORE enabling AllowGroups on sshd_main.
# This prevents locking out the admin from the server.
usermod -aG ssh-tcp-users "$ADMIN_SSH_USER"
echo "[xnet] Admin user '$ADMIN_SSH_USER' added to ssh-tcp-users group"

# --- sshd_main (port 22) — ONLY ssh-tcp-users allowed ---
# Remove any existing AllowGroups line and set it to ONLY ssh-tcp-users.
# This prevents tunnel-only users (ws/tls/dns) from getting shell access.
sed -i '/^AllowGroups/d' /etc/ssh/sshd_config
echo "AllowGroups ssh-tcp-users" >> /etc/ssh/sshd_config
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

# --- sshd_ws (port 2222, localhost only) ---
cat > /etc/ssh/sshd_config_ws <<EOF
Port 2222
ListenAddress 127.0.0.1
AllowGroups ssh-ws-users ssh-tls-users
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
AllowTcpForwarding yes
PermitTunnel yes
GatewayPorts clientspecified
ForceCommand /bin/cat
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# --- sshd_tls (port 2223, localhost only) ---
cat > /etc/ssh/sshd_config_tls <<EOF
Port 2223
ListenAddress 127.0.0.1
AllowGroups ssh-tls-users
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
AllowTcpForwarding yes
PermitTunnel yes
GatewayPorts clientspecified
ForceCommand /bin/cat
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# --- sshd_dns (port 2224, localhost only) ---
cat > /etc/ssh/sshd_config_dns <<EOF
Port 2224
ListenAddress 127.0.0.1
AllowGroups ssh-slowdns-users
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
AllowTcpForwarding yes
PermitTunnel yes
GatewayPorts clientspecified
ForceCommand /bin/cat
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# --- systemd units for secondary sshd instances ---
for svc in ws tls dns; do
    cat > /etc/systemd/system/sshd-${svc}.service <<EOF
[Unit]
Description=OpenSSH SSH daemon (${svc} protocol)
After=network.target

[Service]
ExecStart=/usr/sbin/sshd -D -f /etc/ssh/sshd_config_${svc}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now sshd-${svc}.service
done

# --- Dropbear (port 444) ---
if [ -f /etc/pam.d/dropbear ]; then
    if ! grep -q "ssh-dropbear-users" /etc/pam.d/dropbear; then
        sed -i '1a auth required pam_succeed_if.so user ingroup ssh-dropbear-users' \
            /etc/pam.d/dropbear
    fi
fi

echo "[xnet] Multi-SSHD protocol isolation configured successfully."
