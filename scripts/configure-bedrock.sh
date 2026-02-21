#!/usr/bin/env bash
set -euo pipefail

TOKEN="${1:-}"

if [ -z "$TOKEN" ]; then
    echo "Error: bearer token argument is required" >&2
    exit 1
fi

BASHRC="$HOME/.bashrc"

touch "$BASHRC"

# Remove any existing Bedrock-related lines
sed -i '/CLAUDE_CODE_USE_BEDROCK/d' "$BASHRC"
sed -i '/AWS_REGION/d' "$BASHRC"
sed -i '/AWS_BEARER_TOKEN_BEDROCK/d' "$BASHRC"

# Append new config
cat >> "$BASHRC" <<EOF
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=us-east-1
export AWS_BEARER_TOKEN_BEDROCK=${TOKEN}
EOF

systemctl restart claude-ttyd

exit 0
