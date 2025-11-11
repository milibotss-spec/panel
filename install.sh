#!/bin/bash
set -e

REPO_URL="https://github.com/milibotss-spec/panel.git"
APP_DIR="$PWD/milibots-panel"
SERVICE_NAME="milibots-panel.service"
PYTHON_BIN="python3"

echo "⚙️ Starting Milibots Panel installation..."
sleep 1

# Install required system packages
echo "📦 Installing dependencies..."
apt-get update -y >/dev/null
apt-get install -y $PYTHON_BIN python3-venv git curl >/dev/null

# Remove any existing folder
if [ -d "$APP_DIR" ]; then
    echo "🧹 Removing old installation..."
    rm -rf "$APP_DIR"
fi

# Clone without username prompt (using HTTPS public clone)
echo "📂 Cloning repository..."
git clone --depth 1 "$REPO_URL" "$APP_DIR"

cd "$APP_DIR"

# Create virtual environment if not exists
if [ ! -d "venv" ]; then
    echo "🐍 Creating virtual environment..."
    $PYTHON_BIN -m venv venv
fi

# Activate venv and install requirements
echo "📥 Installing Python dependencies..."
source venv/bin/activate
pip install --upgrade pip >/dev/null
pip install -r requirements.txt >/dev/null
deactivate

# Create systemd service if not exists
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

if [ ! -f "$SERVICE_PATH" ]; then
    echo "🧩 Creating systemd service: $SERVICE_NAME"
    cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=Milibots Panel Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/gunicorn -w 2 -b 0.0.0.0:7878 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF
fi

# Reload systemd and enable service
echo "🔄 Enabling and starting service..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

echo "✅ Installation complete!"
echo "🌐 Your panel should now be running at: http://<your-server-ip>:7878"
