#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Flutterly Setup
#
# Run on a fresh Ubuntu 22.04+ VM with a public IP and
# a domain name pointing to it (for automatic HTTPS).
#
# Usage: sudo bash setup.sh <domain> <password> <flutter-project-path> [--flutter-version=X.X.X]
# Example: sudo bash setup.sh myapp.example.com mysecretpass /home/user/myapp --flutter-version=3.24.0
#
# --flutter-version   Install Flutter at this version if not already on PATH.
#                     Required only when flutter is not pre-installed.
# ============================================================

DOMAIN="${1:?Usage: sudo bash setup.sh <domain> <password> <flutter-project-path>}"
PASSWORD="${2:?Usage: sudo bash setup.sh <domain> <password> <flutter-project-path>}"
FLUTTER_PROJECT="${3:?Usage: sudo bash setup.sh <domain> <password> <flutter-project-path>}"

FLUTTER_VERSION=""
for arg in "$@"; do
    if [[ "$arg" == --flutter-version=* ]]; then
        FLUTTER_VERSION="${arg#--flutter-version=}"
    fi
done
USERNAME="claude"
NTFY_TOPIC="flutterly-$(openssl rand -hex 4)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$FLUTTER_PROJECT" ]; then
    echo "Error: Flutter project directory '$FLUTTER_PROJECT' not found" >&2
    exit 1
fi
FLUTTER_PROJECT="$(realpath "$FLUTTER_PROJECT")"

echo "==> Installing system dependencies..."
apt-get update -qq
apt-get install -y curl git jq openssl xz-utils

# Install Node.js
if ! command -v node &>/dev/null; then
    echo "==> Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi

# Install Claude Code
if ! command -v claude &>/dev/null; then
    echo "==> Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
fi

# Install or validate Flutter
if ! command -v flutter &>/dev/null; then
    if [ -z "$FLUTTER_VERSION" ]; then
        echo "Error: flutter is not installed and --flutter-version was not specified." >&2
        echo "  Re-run with: sudo bash setup.sh ... --flutter-version=3.24.0" >&2
        exit 1
    fi
    echo "==> Installing Flutter ${FLUTTER_VERSION}..."
    FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
    curl -fsSL "$FLUTTER_URL" -o /tmp/flutter.tar.xz
    tar -xf /tmp/flutter.tar.xz -C /opt/
    rm /tmp/flutter.tar.xz
    export PATH="/opt/flutter/bin:$PATH"
    echo "==> Pre-downloading Flutter web artifacts..."
    /opt/flutter/bin/flutter precache --web
    echo "Flutter ${FLUTTER_VERSION} installed to /opt/flutter"
fi
FLUTTER_BIN="$(which flutter)"
NODE_BIN="$(which node)"

# Install ttyd
if ! command -v ttyd &>/dev/null; then
    echo "==> Installing ttyd..."
    TTYD_VERSION="1.7.7"
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  TTYD_ARCH="x86_64" ;;
        aarch64) TTYD_ARCH="aarch64" ;;
        *) echo "Error: unsupported architecture: $ARCH" >&2; exit 1 ;;
    esac
    curl -fsSL -o /usr/local/bin/ttyd \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}"
    chmod +x /usr/local/bin/ttyd
fi

# Install Caddy
if ! command -v caddy &>/dev/null; then
    echo "==> Installing Caddy..."
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y caddy
fi

# Generate password hash for Caddy basic auth
HASHED_PASSWORD=$(caddy hash-password --plaintext "$PASSWORD")

# ============================================================
# Save config
# ============================================================
mkdir -p "${SCRIPT_DIR}/config"
echo "$FLUTTER_PROJECT" > "${SCRIPT_DIR}/config/.flutter-project"
echo "$DOMAIN"          > "${SCRIPT_DIR}/config/.domain"
echo "$HASHED_PASSWORD" > "${SCRIPT_DIR}/config/.password_hash"
echo "$NTFY_TOPIC"      > "${SCRIPT_DIR}/config/.ntfy_topic"
chmod 600 \
    "${SCRIPT_DIR}/config/.flutter-project" \
    "${SCRIPT_DIR}/config/.domain" \
    "${SCRIPT_DIR}/config/.password_hash" \
    "${SCRIPT_DIR}/config/.ntfy_topic"

# Make scripts executable
chmod +x "${SCRIPT_DIR}/scripts/"*.sh

# ============================================================
# Systemd service: ttyd (Claude Code web terminal)
# ============================================================
cat > /etc/systemd/system/claude-ttyd.service << EOF
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

# ============================================================
# Systemd service: Flutter dev server
# ============================================================
cat > /etc/systemd/system/flutter-dev.service << EOF
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

# ============================================================
# Systemd service: Node.js config/API server
# ============================================================
cat > /etc/systemd/system/flutterly-server.service << EOF
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

# ============================================================
# Caddyfile (automatic HTTPS via Let's Encrypt)
# ============================================================
cat > /etc/caddy/Caddyfile << EOF
${DOMAIN} {
    basicauth * {
        ${USERNAME} ${HASHED_PASSWORD}
    }

    # Node.js server (split-view UI + Bedrock config endpoints)
    handle / {
        reverse_proxy localhost:7600
    }

    handle /check-bedrock {
        reverse_proxy localhost:7600
    }

    handle /configure-bedrock {
        reverse_proxy localhost:7600
    }

    # ttyd web terminal (WebSocket)
    handle /terminal/* {
        uri strip_prefix /terminal
        reverse_proxy localhost:7681 {
            header_up Connection {>Connection}
            header_up Upgrade {>Upgrade}
        }
    }

    # Flutter web preview
    handle /preview/* {
        uri strip_prefix /preview
        reverse_proxy localhost:8080 {
            header_up Host "localhost:8080"
        }
    }
}
EOF

# ============================================================
# Convenience aliases
# ============================================================
FLUTTER_PATH_LINE=""
if [ -d "/opt/flutter/bin" ]; then
    FLUTTER_PATH_LINE='export PATH="/opt/flutter/bin:$PATH"'
fi

cat > /etc/profile.d/flutterly.sh << EOF
export FLUTTERLY_ROOT="${SCRIPT_DIR}"
${FLUTTER_PATH_LINE}
alias flutterly-logs='journalctl -u claude-ttyd -u flutter-dev -u flutterly-server -f'
alias flutterly-restart='systemctl restart claude-ttyd flutter-dev flutterly-server caddy'
alias flutterly-status='systemctl status claude-ttyd flutter-dev flutterly-server caddy'
EOF

# Enable and start services
systemctl daemon-reload
systemctl enable --now claude-ttyd flutter-dev flutterly-server
systemctl enable --now caddy

echo ""
echo "============================================================"
echo "  Flutterly setup complete!"
echo "============================================================"
echo ""
echo "  URL:      https://${DOMAIN}/"
echo "  Username: ${USERNAME}"
echo "  Password: (the one you provided)"
echo ""
echo "  ntfy topic:  ${NTFY_TOPIC}"
echo "  Subscribe:   https://ntfy.sh/${NTFY_TOPIC}"
echo ""
echo "  Services running:"
echo "    claude-ttyd      (web terminal on :7681)"
echo "    flutter-dev      (Flutter preview on :8080)"
echo "    flutterly-server (config API on :7600)"
echo "    caddy            (HTTPS reverse proxy on :443)"
echo ""
echo "  NEXT STEPS:"
echo ""
echo "  1. Open https://${DOMAIN}/ in your browser"
echo "  2. Log in with username '${USERNAME}' and your password"
echo "  3. Enter your AWS Bearer Token when prompted"
echo "  4. Type 'claude' in the terminal to start Claude Code"
echo ""
echo "  Reload your shell for aliases:"
echo "    source /etc/profile.d/flutterly.sh"
echo ""
echo "============================================================"
