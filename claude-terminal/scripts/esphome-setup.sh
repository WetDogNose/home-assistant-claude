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

# Delegate to persist-install when it is available: it runs the pip install AND
# records the package in /data/persistent-packages.json, which is what makes the
# install survive a container restart. Doing our own pip install first and then
# "registering" afterwards is what the earlier version tried -- with a
# subcommand (`--add-pip`) that persist-install does not accept, so the
# registration silently failed and ESPHome vanished on the next restart.
if command -v persist-install >/dev/null 2>&1; then
    echo "Installing ESPHome CLI (persisted across restarts)..."
    persist-install pip esphome
else
    echo "Installing ESPHome CLI..."
    pip3 install --break-system-packages --no-cache-dir esphome
    echo "Note: persist-install is unavailable, so ESPHome will not survive a restart."
fi

echo "ESPHome installation complete:"
esphome version
