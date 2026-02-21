#!/usr/bin/env bash
set -euo pipefail

# Usage: bash setup.sh <domain> <flutter-project-path>
# No root/sudo required — installs binaries to ~/.local/bin and services to ~/.config/systemd/user/

# ---------------------------------------------------------------------------
# 1. Validate inputs
# ---------------------------------------------------------------------------

if [ $# -lt 2 ]; then
    echo "Usage: bash setup.sh <domain> <flutter-project-path>" >&2
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

if ! which node &>/dev/null; then
    echo "Error: Node.js is not installed or not on PATH" >&2
    echo "  Install via nvm: https://github.com/nvm-sh/nvm" >&2
    exit 1
fi

FLUTTER_PROJECT="$(realpath "$FLUTTER_PROJECT")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_BIN="$(which flutter)"
NODE_BIN="$(which node)"
LOCAL_BIN="$HOME/.local/bin"

echo "Domain:          $DOMAIN"
echo "Flutter project: $FLUTTER_PROJECT"
echo "App directory:   $SCRIPT_DIR"

mkdir -p "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$PATH"

# ---------------------------------------------------------------------------
# 2. Install ttyd
# ---------------------------------------------------------------------------

if ! which ttyd &>/dev/null; then
    echo "Installing ttyd to $LOCAL_BIN..."
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
    curl -fsSL "$TTYD_URL" -o "$LOCAL_BIN/ttyd"
    chmod +x "$LOCAL_BIN/ttyd"
    echo "ttyd installed."
else
    echo "ttyd already installed, skipping."
fi

# ---------------------------------------------------------------------------
# 3. Install Caddy
# ---------------------------------------------------------------------------

if ! which caddy &>/dev/null; then
    echo "Installing Caddy to $LOCAL_BIN..."
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  CADDY_ARCH="amd64" ;;
        aarch64) CADDY_ARCH="arm64" ;;
        *)
            echo "Error: unsupported architecture: $ARCH" >&2
            exit 1
            ;;
    esac
    CADDY_VERSION="2.9.1"
    CADDY_URL="https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${CADDY_ARCH}.tar.gz"
    CADDY_TMP="$(mktemp -d)"
    curl -fsSL "$CADDY_URL" -o "$CADDY_TMP/caddy.tar.gz"
    tar -xzf "$CADDY_TMP/caddy.tar.gz" -C "$CADDY_TMP"
    mv "$CADDY_TMP/caddy" "$LOCAL_BIN/caddy"
    chmod +x "$LOCAL_BIN/caddy"
    rm -rf "$CADDY_TMP"
    echo "Caddy installed."
else
    echo "Caddy already installed, skipping."
fi

# ---------------------------------------------------------------------------
# 4. Save config
# ---------------------------------------------------------------------------

mkdir -p "$SCRIPT_DIR/config"
echo "$FLUTTER_PROJECT" > "$SCRIPT_DIR/config/.flutter-project"
chmod 600 "$SCRIPT_DIR/config/.flutter-project"
echo "Config saved."

# ---------------------------------------------------------------------------
# 5. Write Caddyfile
# ---------------------------------------------------------------------------

sed \
    -e "s|{{DOMAIN}}|${DOMAIN}|g" \
    -e "s|{{APP_DIR}}|${SCRIPT_DIR}|g" \
    "$SCRIPT_DIR/Caddyfile.template" > "$SCRIPT_DIR/Caddyfile"

echo "Caddyfile written to $SCRIPT_DIR/Caddyfile"

# ---------------------------------------------------------------------------
# 6. Create user systemd services
# ---------------------------------------------------------------------------

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

cat > "$SYSTEMD_USER_DIR/claude-ttyd.service" <<EOF
[Unit]
Description=ttyd web terminal for Claude Code
After=network.target

[Service]
ExecStart=${LOCAL_BIN}/ttyd -p 7681 -W /bin/bash -l -c "cd ${FLUTTER_PROJECT} && exec bash"
Environment=TERM=xterm-256color
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

echo "claude-ttyd service created."

cat > "$SYSTEMD_USER_DIR/flutter-dev.service" <<EOF
[Unit]
Description=Flutter web dev server
After=network.target

[Service]
ExecStart=${FLUTTER_BIN} run -d web-server --web-port=8080 --web-hostname=127.0.0.1
WorkingDirectory=${FLUTTER_PROJECT}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

echo "flutter-dev service created."

cat > "$SYSTEMD_USER_DIR/flutterly-server.service" <<EOF
[Unit]
Description=Flutterly Node.js config server
After=network.target

[Service]
ExecStart=${NODE_BIN} ${SCRIPT_DIR}/server.js
WorkingDirectory=${SCRIPT_DIR}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

echo "flutterly-server service created."

cat > "$SYSTEMD_USER_DIR/caddy.service" <<EOF
[Unit]
Description=Caddy web server
After=network.target

[Service]
ExecStart=${LOCAL_BIN}/caddy run --config ${SCRIPT_DIR}/Caddyfile --adapter caddyfile
ExecReload=${LOCAL_BIN}/caddy reload --config ${SCRIPT_DIR}/Caddyfile --adapter caddyfile
WorkingDirectory=${SCRIPT_DIR}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

echo "caddy service created."

# ---------------------------------------------------------------------------
# 7. Enable linger (services persist after logout)
# ---------------------------------------------------------------------------

if loginctl enable-linger "$USER" 2>/dev/null; then
    echo "Linger enabled — services will survive logout."
else
    echo "Warning: could not enable linger. Services may stop when you log out."
    echo "  To fix: ask an admin to run: sudo loginctl enable-linger $USER"
fi

# ---------------------------------------------------------------------------
# 8. Start everything
# ---------------------------------------------------------------------------

echo "Enabling and starting services..."
systemctl --user daemon-reload
systemctl --user enable --now claude-ttyd flutter-dev flutterly-server caddy

# ---------------------------------------------------------------------------
# 9. Print success
# ---------------------------------------------------------------------------

echo ""
echo "Setup complete!"
echo ""
echo "  App URL: http://${DOMAIN}:7800/"
echo ""
echo "Services running (user-level systemd):"
echo "  claude-ttyd      (web terminal on :7681)"
echo "  flutter-dev      (Flutter preview on :8080)"
echo "  flutterly-server (config API on :7600)"
echo "  caddy            (HTTP reverse proxy on :7800)"
echo ""
echo "Visit http://${DOMAIN}:7800/ and enter your AWS Bearer Token on first visit."
