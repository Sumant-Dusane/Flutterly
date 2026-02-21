#!/usr/bin/env bash
set -euo pipefail

# Usage: sudo bash enable-https.sh
#
# Run this once after setup.sh to enable proper HTTPS via Let's Encrypt.
# Requires sudo to:
#   1. Grant Caddy permission to bind to ports 80 and 443 (setcap)
#   2. Enable user linger so services survive logout
#
# The domain must be publicly reachable on ports 80 and 443 for
# Let's Encrypt to issue a certificate.

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "Error: run this script with sudo: sudo bash enable-https.sh" >&2
    exit 1
fi

if [ -z "${SUDO_USER:-}" ]; then
    echo "Error: SUDO_USER not set. Use sudo, not su." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_HOME=$(eval echo "~$SUDO_USER")
LOCAL_BIN="$USER_HOME/.local/bin"
CADDY_BIN="$LOCAL_BIN/caddy"
DOMAIN_FILE="$SCRIPT_DIR/config/.domain"

if [ ! -f "$DOMAIN_FILE" ]; then
    echo "Error: config/.domain not found. Run setup.sh first." >&2
    exit 1
fi

if [ ! -f "$CADDY_BIN" ]; then
    echo "Error: caddy not found at $CADDY_BIN. Run setup.sh first." >&2
    exit 1
fi

DOMAIN="$(cat "$DOMAIN_FILE")"
SUDO_UID=$(id -u "$SUDO_USER")

echo "User:   $SUDO_USER"
echo "Domain: $DOMAIN"
echo "Caddy:  $CADDY_BIN"
echo ""

# ---------------------------------------------------------------------------
# 1. Grant Caddy permission to bind to ports 80 and 443
# ---------------------------------------------------------------------------

echo "Setting capabilities on caddy..."
setcap cap_net_bind_service=+ep "$CADDY_BIN"
echo "Done."

# ---------------------------------------------------------------------------
# 2. Enable linger so user services survive logout
# ---------------------------------------------------------------------------

loginctl enable-linger "$SUDO_USER"
echo "Linger enabled for $SUDO_USER."

# ---------------------------------------------------------------------------
# 3. Rewrite Caddyfile with standard HTTPS (Let's Encrypt)
# ---------------------------------------------------------------------------

sed \
    -e "s|{{SCHEME}}://{{DOMAIN}}:{{PORT}}|${DOMAIN}|g" \
    -e "s|{{TLS_DIRECTIVE}}||g" \
    "$SCRIPT_DIR/Caddyfile.template" > "$SCRIPT_DIR/Caddyfile"

echo "Caddyfile updated for HTTPS."

# ---------------------------------------------------------------------------
# 4. Restart Caddy as the actual user
# ---------------------------------------------------------------------------

echo "Restarting caddy..."
sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$SUDO_UID" \
    systemctl --user daemon-reload
sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$SUDO_UID" \
    systemctl --user restart caddy

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "HTTPS enabled!"
echo ""
echo "  App URL: https://${DOMAIN}/"
echo ""
echo "Caddy will automatically obtain and renew a certificate from Let's Encrypt."
echo "First-time cert issuance may take ~30 seconds on the first visit."
