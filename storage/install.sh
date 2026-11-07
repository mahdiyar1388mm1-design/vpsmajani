#!/usr/bin/env bash
# One-shot installer for the persistent storage VPS of the RDP chain.
#
#   sudo bash install.sh
#
# What it does:
#   * installs Python (if missing) and Tailscale
#   * creates /mnt/vpsmajani (or reuses an existing volume mount)
#   * installs the snapshot server as a systemd service on port 8787
#   * prints the Tailscale address to paste into GitHub Actions variables
#
# It asks for two things interactively: a Tailscale auth key and the shared
# token that the Windows sessions use to authenticate.

set -euo pipefail

SNAP_DIR="${SNAP_DIR:-/mnt/vpsmajani}"
SNAP_KEEP="${SNAP_KEEP:-3}"
PORT="${PORT:-8787}"
SERVICE=/etc/systemd/system/vpsmajani-sync.service
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The server lives in .github/scripts when run from a repo checkout,
# and next to this script when the two files are copied over on their own.
if [ -f "$SCRIPT_DIR/sync_server.py" ]; then
    SERVER_SRC="$SCRIPT_DIR/sync_server.py"
elif [ -f "$SCRIPT_DIR/../.github/scripts/sync_server.py" ]; then
    SERVER_SRC="$SCRIPT_DIR/../.github/scripts/sync_server.py"
else
    echo "sync_server.py not found next to install.sh" >&2
    exit 1
fi

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run me with sudo"

# ---------------------------------------------------------------- dependencies
say "installing dependencies"
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates python3 >/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl ca-certificates python3 >/dev/null
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl ca-certificates python3 >/dev/null
else
    command -v python3 >/dev/null 2>&1 || die "install python3 and curl first"
fi
python3 --version

# ------------------------------------------------------------------- tailscale
if ! command -v tailscale >/dev/null 2>&1; then
    say "installing Tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
fi

if ! tailscale status >/dev/null 2>&1; then
    if [ -z "${TS_AUTHKEY:-}" ]; then
        read -r -p "Tailscale auth key (tskey-auth-...): " TS_AUTHKEY
    fi
    say "joining the tailnet"
    tailscale up --authkey="$TS_AUTHKEY" --hostname="vpsmajani-storage"
fi

TS_IP="$(tailscale ip -4 | head -1)"
[ -n "$TS_IP" ] || die "no Tailscale IPv4 address yet, run 'tailscale status'"

# ---------------------------------------------------------------- storage dir
if ! mountpoint -q "$SNAP_DIR" 2>/dev/null; then
    say "$SNAP_DIR is not a mount point; using it as a plain folder on this disk"
    say "  (attach a volume and mount it here to make the data independent of this VPS)"
fi
mkdir -p "$SNAP_DIR"

# --------------------------------------------------------------------- token
TOKEN_FILE=/etc/vpsmajani-sync.token
if [ -f "$TOKEN_FILE" ]; then
    SYNC_TOKEN="$(cat "$TOKEN_FILE")"
    say "reusing the existing token from $TOKEN_FILE"
else
    if [ -z "${SYNC_TOKEN:-}" ]; then
        SYNC_TOKEN="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)"
    fi
    printf '%s' "$SYNC_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
fi

# ------------------------------------------------------------------- install
install -m 0755 "$SERVER_SRC" /usr/local/bin/vpsmajani-sync.py
install -d -m 0700 /etc/vpsmajani-sync

cat > /etc/vpsmajani-sync/env <<EOF
# vpsmajani snapshot server configuration
SNAP_DIR=$SNAP_DIR
SNAP_KEEP=$SNAP_KEEP
SYNC_TOKEN=$SYNC_TOKEN
BIND_ADDR=0.0.0.0
BIND_PORT=$PORT
EOF
chmod 600 /etc/vpsmajani-sync/env

cat > "$SERVICE" <<EOF
[Unit]
Description=vpsmajani snapshot server (persistent desktop for the RDP chain)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/vpsmajani-sync/env
ExecStart=/usr/bin/env python3 /usr/local/bin/vpsmajani-sync.py
Restart=always
RestartSec=5
User=root
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

# Only the tailnet may talk to the port.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow in on tailscale0 to any port "$PORT" proto tcp >/dev/null || true
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -i tailscale0 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -i tailscale0 -p tcp --dport "$PORT" -j ACCEPT || true
fi

systemctl daemon-reload
systemctl enable --now vpsmajani-sync.service
sleep 2

say "checking the service"
curl -fsS -H "Authorization: Bearer $SYNC_TOKEN" "http://127.0.0.1:$PORT/health" || {
    journalctl -u vpsmajani-sync.service -n 30 --no-pager
    die "the service did not answer on port $PORT"
}
echo

cat <<EOF

$(printf '\033[1;32mDone.\033[0m') The storage volume is live.

  Tailscale IP      : $TS_IP
  Port              : $PORT
  Data folder       : $SNAP_DIR  (keeps the last $SNAP_KEEP snapshots)
  Shared token      : $SYNC_TOKEN

Add these to the GitHub repository (Settings -> Secrets and variables -> Actions):

  Variable  STORAGE_URL   http://$TS_IP:$PORT
  Variable  SYNC_MODE     http
  Secret    SYNC_TOKEN    $SYNC_TOKEN

Check it any time:

  systemctl status vpsmajani-sync
  curl -H "Authorization: Bearer $SYNC_TOKEN" http://$TS_IP:$PORT/stats

Total size of the saved snapshots:

  du -sh $SNAP_DIR
EOF
