#!/usr/bin/env bash
# ============================================================
#  X-Net — sing-box diagnostics collector
#  Run on a node/panel server:  sudo bash singbox-diag.sh
#  Copy ALL output and send it back for analysis.
# ============================================================
echo "==================== XNET SING-BOX DIAG ===================="
echo "date: $(date -u 2>/dev/null) (UTC)"
echo "host: $(hostname 2>/dev/null)  arch: $(uname -m 2>/dev/null)"
echo

echo "----- 1) sing-box binary + version -----"
which sing-box 2>/dev/null || echo "sing-box: NOT FOUND in PATH"
sing-box version 2>&1 | head -n 5 || true
echo

echo "----- 2) sing-box service status -----"
systemctl status sing-box --no-pager 2>&1 | head -n 20 || true
echo
echo "is-active : $(systemctl is-active sing-box 2>/dev/null)"
echo "is-enabled: $(systemctl is-enabled sing-box 2>/dev/null)"
echo

echo "----- 3) sing-box recent logs -----"
journalctl -u sing-box -n 60 --no-pager 2>&1 | tail -n 60 || true
echo

echo "----- 4) systemd unit file -----"
for u in /etc/systemd/system/sing-box.service /lib/systemd/system/sing-box.service /usr/lib/systemd/system/sing-box.service; do
  if [ -f "$u" ]; then echo "## $u"; cat "$u"; echo; fi
done

echo "----- 5) config presence + validation -----"
ls -l /etc/sing-box/ 2>&1 || true
echo "-- sing-box check -c /etc/sing-box/config.json --"
sing-box check -c /etc/sing-box/config.json 2>&1 | head -n 30 || true
echo "-- first 40 lines of config.json --"
head -n 40 /etc/sing-box/config.json 2>/dev/null || echo "config.json not found"
echo

echo "----- 6) xnet panel service + env -----"
echo "xnet is-active: $(systemctl is-active xnet 2>/dev/null)"
systemctl status xnet --no-pager 2>&1 | head -n 12 || true
echo "-- relevant .env keys --"
grep -E '^(PORT|NODE_ROLE|NODE_CLIENT_SCHEME|NODE_API_KEY|NODE_SECRET_KEY|SINGBOX_BINARY_PATH|SINGBOX_CONFIG_PATH)=' /opt/xnet/.env 2>/dev/null \
  | sed -E 's/(NODE_SECRET_KEY=).*/\1<hidden>/' || echo "/opt/xnet/.env not found"
echo

echo "----- 7) listening sockets -----"
ss -ltnp 2>/dev/null | grep -E 'sing-box|xnet-server' || echo "(no sing-box/xnet listeners found)"
echo
echo "----- 8) xnet recent logs (sing-box related) -----"
journalctl -u xnet -n 40 --no-pager 2>&1 | grep -iE 'sing-?box|config|reload|inbound' | tail -n 30 || true
echo "==================== END DIAG ===================="
