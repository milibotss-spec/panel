#!/bin/bash
set -e

SERVICE_NAME="milibots-panel.service"
APP_DIR="$PWD/milibots-panel"

echo "⚠️  Uninstalling Milibots Panel..."

# Stop and disable the service
if systemctl list-units --full -all | grep -Fq "$SERVICE_NAME"; then
    echo "🛑 Stopping service..."
    systemctl stop "$SERVICE_NAME" || true
    echo "❌ Disabling service..."
    systemctl disable "$SERVICE_NAME" || true
    echo "🗑️ Removing service file..."
    rm -f "/etc/systemd/system/$SERVICE_NAME"
    systemctl daemon-reload
else
    echo "ℹ️ No systemd service found for $SERVICE_NAME"
fi

# Remove application directory
if [ -d "$APP_DIR" ]; then
    echo "🧹 Removing application directory..."
    rm -rf "$APP_DIR"
else
    echo "ℹ️ No application directory found at $APP_DIR"
fi

echo ""
echo "✅ Milibots Panel has been completely removed!"
