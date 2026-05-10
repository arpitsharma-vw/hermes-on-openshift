#!/usr/bin/env bash
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "git is required before installing Hermes." >&2
  exit 1
fi

echo "Installing Hermes Agent using the upstream macOS installer..."
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash

echo
echo "Installation finished. Reload your shell, then run:"
echo "  source ~/.zshrc"
echo "  hermes doctor"
echo "  hermes model"
echo "  hermes --tui"
