#!/bin/bash
# Sotto Clean Build & Global Update Script
set -e

echo "=== Sotto Clean Build & Update ==="

# 1. Clean old build folders and SPM caches
echo "[1/4] Cleaning SPM caches and old build files..."
swift package clean
rm -rf .build

# 2. Build Sotto in release mode
echo "[2/4] Compiling Sotto in release mode..."
swift build -c release

# 3. Stop any running Sotto instances to release the executable file lock
echo "[3/4] Terminating any active Sotto processes..."
pkill Sotto || true

# 4. Copy the built release binary to the global PATH
echo "[4/4] Updating Sotto binary in /usr/local/bin/sotto..."
if [ -w "/usr/local/bin" ]; then
    cp .build/release/Sotto /usr/local/bin/sotto
    chmod +x /usr/local/bin/sotto
else
    echo "Requesting privileges to install Sotto to /usr/local/bin..."
    sudo cp .build/release/Sotto /usr/local/bin/sotto
    sudo chmod +x /usr/local/bin/sotto
fi

echo "=== Sotto successfully updated! ==="
echo "Launch Sotto by running 'sotto' in your terminal."
