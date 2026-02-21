#!/usr/bin/env bash
set -euo pipefail

BASHRC="$HOME/.bashrc"

if [ ! -f "$BASHRC" ]; then
    echo "not-configured"
    exit 0
fi

if grep -q "AWS_BEARER_TOKEN_BEDROCK" "$BASHRC"; then
    echo "configured"
else
    echo "not-configured"
fi
