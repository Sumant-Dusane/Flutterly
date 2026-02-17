#!/usr/bin/env bash
set -euo pipefail

# Usage: sudo bash setup.sh <domain> <flutter-project-path>

# ---------------------------------------------------------------------------
# 1. Validate inputs
# ---------------------------------------------------------------------------

if [ $# -lt 2 ]; then
    echo "Usage: sudo bash setup.sh <domain> <flutter-project-path>" >&2
    exit 1
fi

DOMAIN="$1"
FLUTTER_PROJECT="$2"

if ! which flutter &>/dev/null; then
    echo "Error: flutter is not installed or not on PATH" >&2
    exit 1
fi

if [ ! -d "$FLUTTER_PROJECT" ]; then
    echo "Error: Flutter project directory '$FLUTTER_PROJECT' not found" >&2
    exit 1
fi

FLUTTER_PROJECT="$(realpath "$FLUTTER_PROJECT")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_BIN="$(which flutter)"

echo "Domain:          $DOMAIN"
echo "Flutter project: $FLUTTER_PROJECT"
echo "App directory:   $SCRIPT_DIR"

# ---------------------------------------------------------------------------
# 2. Install ttyd
# ---------------------------------------------------------------------------

if ! which ttyd &>/dev/null; then
    echo "Installing ttyd..."
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  TTYD_ARCH="x86_64" ;;
        aarch64) TTYD_ARCH="aarch64" ;;
        *)
            echo "Error: unsupported architecture: $ARCH" >&2
            exit 1
            ;;
    esac
    TTYD_VERSION="1.7.7"
    TTYD_URL="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}"
    curl -fsSL "$TTYD_URL" -o /usr/local/bin/ttyd
    chmod +x /usr/local/bin/ttyd
    echo "ttyd installed."
else
    echo "ttyd already installed, skipping."
fi

# ---------------------------------------------------------------------------
# 3. Install Caddy
# ---------------------------------------------------------------------------

if ! which caddy &>/dev/null; then
    echo "Installing Caddy..."
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
    echo "Caddy installed."
else
    echo "Caddy already installed, skipping."
fi

# ---------------------------------------------------------------------------
# 4. Install Node.js (if not present)
# ---------------------------------------------------------------------------

if ! which node &>/dev/null; then
    echo "Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y nodejs
    echo "Node.js installed."
else
    echo "Node.js already installed, skipping."
fi

# ---------------------------------------------------------------------------
# 5. Save config
# ---------------------------------------------------------------------------

mkdir -p "$SCRIPT_DIR/config"
echo "$FLUTTER_PROJECT" > "$SCRIPT_DIR/config/.flutter-project"
chmod 600 "$SCRIPT_DIR/config/.flutter-project"
echo "Config saved."

# ---------------------------------------------------------------------------
# 6. Write Caddyfile
# ---------------------------------------------------------------------------

sed \
    -e "s|{{DOMAIN}}|${DOMAIN}|g" \
    -e "s|{{APP_DIR}}|${SCRIPT_DIR}|g" \
    "$SCRIPT_DIR/Caddyfile.template" > /etc/caddy/Caddyfile

echo "Caddyfile written to /etc/caddy/Caddyfile"

# ---------------------------------------------------------------------------
# 7. Create systemd service: claude-ttyd
# ---------------------------------------------------------------------------

cat > /etc/systemd/system/claude-ttyd.service <<EOF
[Unit]
Description=ttyd web terminal for Claude Code
After=network.target

[Service]
ExecStart=/usr/local/bin/ttyd -p 7681 -W /bin/bash -l -c "cd ${FLUTTER_PROJECT} && exec bash"
Environment=TERM=xterm-256color
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "claude-ttyd service created."

# ---------------------------------------------------------------------------
# 8. Create systemd service: flutter-dev
# ---------------------------------------------------------------------------

cat > /etc/systemd/system/flutter-dev.service <<EOF
[Unit]
Description=Flutter web dev server
After=network.target

[Service]
ExecStart=${FLUTTER_BIN} run -d web-server --web-port=8080 --web-hostname=127.0.0.1
WorkingDirectory=${FLUTTER_PROJECT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "flutter-dev service created."

# ---------------------------------------------------------------------------
# 9. Create systemd service: flutterly-server
# ---------------------------------------------------------------------------

NODE_BIN="$(which node)"

cat > /etc/systemd/system/flutterly-server.service <<EOF
[Unit]
Description=Flutterly Node.js config server
After=network.target

[Service]
ExecStart=${NODE_BIN} ${SCRIPT_DIR}/server.js
WorkingDirectory=${SCRIPT_DIR}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "flutterly-server service created."

# ---------------------------------------------------------------------------
# 10. Start everything
# ---------------------------------------------------------------------------

echo "Enabling and starting services..."
systemctl daemon-reload
systemctl enable --now claude-ttyd flutter-dev flutterly-server
systemctl reload caddy

# ---------------------------------------------------------------------------
# 11. Print success
# ---------------------------------------------------------------------------

echo ""
echo "Setup complete!"
echo ""
echo "  App URL: https://${DOMAIN}/"
echo ""
echo "Services running:"
echo "  claude-ttyd      (web terminal on :7681)"
echo "  flutter-dev      (Flutter preview on :8080)"
echo "  flutterly-server (config API on :7600)"
echo "  caddy            (HTTPS reverse proxy)"
echo ""
echo "Visit https://${DOMAIN}/ and enter your AWS Bearer Token on first visit."
