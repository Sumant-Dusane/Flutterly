#!/usr/bin/env bash
set -euo pipefail

TOKEN="${1:-}"

if [ -z "$TOKEN" ]; then
    echo "Error: bearer token argument is required" >&2
    exit 1
fi

ZSHRC="$HOME/.zshrc"

touch "$ZSHRC"

# Remove any existing Bedrock-related lines
sed -i '/CLAUDE_CODE_USE_BEDROCK/d' "$ZSHRC"
sed -i '/AWS_REGION/d' "$ZSHRC"
sed -i '/AWS_BEARER_TOKEN_BEDROCK/d' "$ZSHRC"

# Append new config
cat >> "$ZSHRC" <<EOF
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=us-east-1
export AWS_BEARER_TOKEN_BEDROCK=${TOKEN}
EOF

systemctl restart claude-ttyd

exit 0
