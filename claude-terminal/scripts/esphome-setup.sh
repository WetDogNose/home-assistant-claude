#!/bin/bash

# esphome-setup — Install and persist ESPHome CLI toolchain
# Usage: esphome-setup

set -euo pipefail

echo "Checking ESPHome CLI installation..."

if command -v esphome >/dev/null 2>&1; then
    echo "ESPHome is already installed:"
    esphome version
    exit 0
fi

echo "Installing ESPHome CLI..."

if command -v uv >/dev/null 2>&1; then
    uv pip install --system --break-system-packages esphome
else
    pip3 install --break-system-packages esphome
fi

# Register with persist-install if available so it survives restarts
if command -v persist-install >/dev/null 2>&1; then
    echo "Persisting esphome in /data/persistent-packages.json..."
    persist-install --add-pip esphome || true
fi

echo "ESPHome installation complete:"
esphome version
EOF
