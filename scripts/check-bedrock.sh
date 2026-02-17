#!/usr/bin/env bash
set -euo pipefail

ZSHRC="$HOME/.zshrc"

if [ ! -f "$ZSHRC" ]; then
    echo "not-configured"
    exit 0
fi

if grep -q "AWS_BEARER_TOKEN_BEDROCK" "$ZSHRC"; then
    echo "configured"
else
    echo "not-configured"
fi
