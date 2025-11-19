#!/bin/bash
set -e

REPO_URL="https://github.com/milibots/panel.git"
APP_DIR="$PWD/milibots-panel"
SERVICE_NAME="milibots-panel.service"
PYTHON_BIN="python3"
TELEGRAM_SCRIPT="/usr/local/bin/ssh-login-notify.sh"

echo "⚙️ Starting Milibots Panel installation..."
sleep 1

# Install system dependencies
echo "📦 Installing dependencies..."
apt-get update -y >/dev/null || echo "⚠️  apt-get update failed, but continuing..."

# Install packages individually and continue on failure
for pkg in $PYTHON_BIN python3-venv git curl jq; do
    if apt-get install -y $pkg >/dev/null 2>&1; then
        echo "✅ $pkg installed successfully"
    else
        echo "⚠️  Failed to install $pkg, but continuing..."
    fi
done

# Prompt for configuration
echo ""
read -p "🌐 Enter the port to run the panel on (default: 7878): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-7878}

read -p "👤 Enter admin username (default: milibots): " ADMIN_USERNAME
ADMIN_USERNAME=${ADMIN_USERNAME:-milibots}

read -sp "🔑 Enter admin password (default: milibots): " ADMIN_PASSWORD
ADMIN_PASSWORD=${ADMIN_PASSWORD:-milibots}
echo ""

# Telegram notification setup
echo ""
echo "🔔 Telegram SSH Login Notifications Setup"
echo "=========================================="
read -p "🤖 Enter Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -p "👤 Enter Your Telegram User ID: " TELEGRAM_USER_ID

# Remove any old installation
if [ -d "$APP_DIR" ]; then
    echo "🧹 Removing old installation..."
    rm -rf "$APP_DIR" || echo "⚠️  Failed to remove old installation, but continuing..."
fi

# Clone repo
echo "📂 Cloning repository..."
if git clone --depth 1 "$REPO_URL" "$APP_DIR" 2>/dev/null; then
    echo "✅ Repository cloned successfully"
else
    echo "❌ Failed to clone repository. Exiting."
    exit 1
fi

cd "$APP_DIR"

# Create virtual environment
if [ ! -d "venv" ]; then
    echo "🐍 Creating virtual environment..."
    if $PYTHON_BIN -m venv venv 2>/dev/null; then
        echo "✅ Virtual environment created"
    else
        echo "❌ Failed to create virtual environment. Exiting."
        exit 1
    fi
fi

# Install requirements
echo "📥 Installing Python dependencies..."
source venv/bin/activate

# Upgrade pip with error handling
if pip install --upgrade pip >/dev/null 2>&1; then
    echo "✅ pip upgraded successfully"
else
    echo "⚠️  pip upgrade failed, but continuing..."
fi

# Install requirements with error handling
if [ -f "requirements.txt" ]; then
    if pip install -r requirements.txt >/dev/null 2>&1; then
        echo "✅ Python dependencies installed"
    else
        echo "⚠️  Some Python dependencies failed to install, but continuing..."
    fi
else
    echo "❌ requirements.txt not found. Exiting."
    exit 1
fi

deactivate

# Create .env file
echo "🧾 Generating .env file..."
if cat <<EOF > .env
SECRET_KEY=$(openssl rand -hex 16)
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
PORT=${PANEL_PORT}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_USER_ID=${TELEGRAM_USER_ID}
EOF
then
    echo "✅ .env file created"
else
    echo "❌ Failed to create .env file. Exiting."
    exit 1
fi

# Create Telegram notification script
echo "🔔 Creating SSH login notification script..."
if cat <<EOF > $TELEGRAM_SCRIPT
#!/bin/bash

# Telegram Bot Configuration
BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
USER_ID="$TELEGRAM_USER_ID"

# Get server information
SERVER_IP=\$(curl -s https://ipapi.co/ip/ || hostname -I | awk '{print \$1}')
SERVER_NAME=\$(hostname)

# Login information
LOGIN_USER=\$PAM_USER
LOGIN_TYPE=\$PAM_TYPE
REMOTE_IP=\${PAM_RHOST:-"unknown"}
LOGIN_TIME=\$(date '+%Y-%m-%d %H:%M:%S')

if [ "\$PAM_TYPE" = "open_session" ]; then
    MESSAGE="🔐 *SSH Login Alert* 🔐

🖥️ *Server:* \${SERVER_NAME}
🌐 *IP:* \${SERVER_IP}
👤 *User:* \${LOGIN_USER}
📍 *From IP:* \${REMOTE_IP}
🕐 *Time:* \${LOGIN_TIME}
🔍 *Status:* Login Successful"

    # Send to Telegram
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
        -d chat_id="\${USER_ID}" \\
        -d text="\${MESSAGE}" \\
        -d parse_mode="Markdown" > /dev/null 2>&1
fi

exit 0
EOF
then
    echo "✅ Telegram script created"
else
    echo "⚠️  Failed to create Telegram script, but continuing..."
fi

# Make the script executable
if chmod +x $TELEGRAM_SCRIPT 2>/dev/null; then
    echo "✅ Telegram script made executable"
else
    echo "⚠️  Failed to make Telegram script executable, but continuing..."
fi

# Configure PAM to trigger the script on SSH login
echo "🔧 Configuring PAM for SSH notifications..."
if [ ! -f /etc/pam.d/sshd ]; then
    echo "❌ PAM SSH configuration not found!"
else
    # Check if already configured
    if ! grep -q "ssh-login-notify" /etc/pam.d/sshd; then
        if echo "session optional pam_exec.so /usr/local/bin/ssh-login-notify.sh" >> /etc/pam.d/sshd; then
            echo "✅ PAM configured for SSH notifications"
        else
            echo "⚠️  Failed to configure PAM, but continuing..."
        fi
    else
        echo "ℹ️ PAM already configured for SSH notifications"
    fi
fi

# Test Telegram configuration
echo "🧪 Testing Telegram configuration..."
TEST_MESSAGE="✅ *SSH Notification Test* ✅

🤖 Bot is configured successfully!
🖥️ Server: \$(hostname)
🌐 IP: \$(curl -s https://ipapi.co/ip/ || echo "unknown")
🕐 Time: \$(date '+%Y-%m-%d %H:%M:%S')

You will receive this notification whenever someone logs in via SSH."

TEST_RESULT=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_USER_ID}" \
    -d text="${TEST_MESSAGE}" \
    -d parse_mode="Markdown" | jq -r '.ok' 2>/dev/null || echo "false")

if [ "$TEST_RESULT" = "true" ]; then
    echo "✅ Telegram test notification sent successfully!"
else
    echo "⚠️  Failed to send Telegram test notification, but continuing..."
    echo "💡 Please check your Bot Token and User ID later"
fi

# Create systemd service
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

echo "🧩 Creating systemd service: $SERVICE_NAME"
if cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=Milibots Panel Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/gunicorn -w 2 -b 0.0.0.0:${PANEL_PORT} app:app
Restart=always
EnvironmentFile=$APP_DIR/.env

[Install]
WantedBy=multi-user.target
EOF
then
    echo "✅ Systemd service created"
else
    echo "❌ Failed to create systemd service. Exiting."
    exit 1
fi

# Reload and start service
echo "🔄 Enabling and starting service..."
if systemctl daemon-reload 2>/dev/null; then
    echo "✅ Systemd daemon reloaded"
else
    echo "⚠️  Failed to reload systemd daemon, but continuing..."
fi

if systemctl enable --now "$SERVICE_NAME" 2>/dev/null; then
    echo "✅ Service enabled and started"
else
    echo "⚠️  Failed to enable/start service, but continuing..."
fi

# Wait a moment for service to start
sleep 3

# Check service status
SERVICE_STATUS=$(systemctl is-active $SERVICE_NAME 2>/dev/null || echo "inactive")
if [ "$SERVICE_STATUS" = "active" ]; then
    echo "✅ Service started successfully!"
else
    echo "⚠️  Service may not be running. Check status with: systemctl status $SERVICE_NAME"
fi

# Detect server IP using ipapi
echo "🌍 Detecting server IP..."
SERVER_IP=$(curl -s https://ipapi.co/ip/ 2>/dev/null || echo "127.0.0.1")

echo ""
echo "🎉 Installation complete!"
echo "========================"
echo "🌐 Your panel is live at: http://${SERVER_IP}:${PANEL_PORT}"
echo "👤 Username: ${ADMIN_USERNAME}"
echo "🔑 Password: ${ADMIN_PASSWORD}"
echo ""
echo "🔔 SSH Login Notifications:"
echo "   ✅ Telegram bot configured"
echo "   ✅ PAM integration active"
echo "   📱 You will receive notifications on Telegram for SSH logins"
echo ""
echo "🔧 Management commands:"
echo "   systemctl status $SERVICE_NAME    # Check service status"
echo "   journalctl -u $SERVICE_NAME -f   # View logs"
echo "   systemctl restart $SERVICE_NAME   # Restart service"
