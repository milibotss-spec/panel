from flask import Flask, render_template, request, redirect, url_for, session, flash, Response, jsonify
import os
import subprocess
import shlex
import time
from dotenv import load_dotenv
from flask_socketio import SocketIO
import json

load_dotenv()

app = Flask(__name__)
app.secret_key = os.getenv('SECRET_KEY', 'a_default_secret_key_please_change_me')
socketio = SocketIO(app, cors_allowed_origins="*")

ADMIN_USERNAME = os.getenv('ADMIN_USERNAME')
ADMIN_PASSWORD = os.getenv('ADMIN_PASSWORD')

# Store service states for real-time updates
service_states = {}

def run_cmd(cmd, timeout=10):
    """Run shell command safely with timeout, returning (success, stdout, stderr)."""
    try:
        result = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout)
        return (result.returncode == 0), result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        return False, "", "Command timed out"
    except Exception as e:
        return False, "", f"Command error: {e}"

def get_service_status(service_name):
    """Get detailed status of a service."""
    ok, output, err = run_cmd(f"systemctl is-active {shlex.quote(service_name)}")
    active_status = output.strip() if ok else "unknown"
    
    ok, output, err = run_cmd(f"systemctl is-enabled {shlex.quote(service_name)}")
    enabled_status = output.strip() if ok else "unknown"
    
    return active_status, enabled_status

def update_all_service_states():
    """Update all service states and emit via WebSocket."""
    services, error = get_running_services()
    if not error:
        for service in services:
            service_name = service['unit']
            active_status, enabled_status = get_service_status(service_name)
            service_states[service_name] = {
                'active': service['active'],
                'enabled': enabled_status,
                'description': service['description']
            }
        
        # Emit update to all connected clients
        socketio.emit('service_states_update', service_states)

def run_systemctl_command(action, service_name):
    """Perform start/stop/restart/status/enable/disable/delete actions on a systemd service safely."""
    valid_actions = ['start', 'stop', 'restart', 'status', 'enable', 'disable', 'delete']
    if action not in valid_actions:
        return False, f"Invalid action: {action}"

    service_path = shlex.quote(service_name)

    try:
        # Delete service (remove unit file and disable)
        if action == 'delete':
            # Stop service first
            run_cmd(f"sudo systemctl stop {service_path}")
            # Disable service
            run_cmd(f"sudo systemctl disable {service_path}")
            # Remove service file (assuming standard location)
            ok, _, _ = run_cmd(f"sudo rm -f /etc/systemd/system/{service_path}")
            if ok:
                run_cmd("sudo systemctl daemon-reload")
                return True, f"Service '{service_name}' deleted successfully."
            return False, f"Failed to delete service '{service_name}'"

        # Enable/disable service
        if action in ['enable', 'disable']:
            ok, out, err = run_cmd(f"sudo systemctl {action} {service_path}")
            if ok:
                run_cmd("sudo systemctl daemon-reload")
                return True, out or f"Service '{service_name}' {action}d successfully."
            return False, err or out

        # Restart = stop + start manually (safer)
        if action == 'restart':
            ok1, _, err1 = run_cmd(f"sudo systemctl stop {service_path}")
            time.sleep(2)

            # Force kill if still alive
            ok2, pid_out, _ = run_cmd(f"systemctl show -p MainPID {service_path} | cut -d= -f2")
            if pid_out.strip() and pid_out.strip() != "0":
                run_cmd(f"sudo kill -9 {pid_out.strip()}")

            # Special cleanup for bot.service
            if service_name == 'bot.service':
                run_cmd("sudo tmux kill-session -t bot 2>/dev/null")
                run_cmd("sudo rm -f /root/NIVa/bot/NIVA.session /root/NIVa/bot/NIVA.session-journal")

            ok3, _, err3 = run_cmd(f"sudo systemctl start {service_path}")
            if ok1 and ok3:
                return True, f"Service '{service_name}' restarted successfully."
            return False, f"Restart failed: {err1 or err3}"

        # Normal start/stop/status
        ok, out, err = run_cmd(f"sudo systemctl {action} {service_path}")
        if not ok:
            # Try force kill if stop failed
            if action == 'stop':
                ok_pid, pid_out, _ = run_cmd(f"systemctl show -p MainPID {service_path} | cut -d= -f2")
                if ok_pid and pid_out.strip() and pid_out.strip() != "0":
                    run_cmd(f"sudo kill -9 {pid_out.strip()}")
            return ok, err or out

        return True, out or f"Service '{service_name}' {action}ed successfully."

    except Exception as e:
        return False, f"Unexpected error: {str(e)}"

def get_running_services():
    """Return a list of all .service units with details."""
    ok, output, err = run_cmd("systemctl list-units --type=service --all --no-pager --no-legend")
    if not ok:
        return [], f"Failed to fetch service list: {err}"

    services = []
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 5:
            unit = parts[0]
            if not unit.endswith(".service"):
                continue
            services.append({
                'unit': unit,
                'load': parts[1],
                'active': parts[2],
                'sub': parts[3],
                'description': ' '.join(parts[4:])
            })
    return services, None

def stream_service_logs(service_name):
    """Stream live logs for a service using SSE."""
    command = f"sudo journalctl -u {shlex.quote(service_name)} -f -n 50"
    try:
        process = subprocess.Popen(shlex.split(command), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)

        def generate():
            try:
                for line in iter(process.stdout.readline, ''):
                    yield f"data: {line.strip()}\n\n"
            except Exception as e:
                yield f"data: ERROR: {str(e)}\n\n"
            finally:
                process.terminate()

        return generate(), None

    except FileNotFoundError:
        return None, "Error: 'journalctl' not found."
    except Exception as e:
        return None, f"Error streaming logs: {e}"

# WebSocket event handlers
@socketio.on('connect')
def handle_connect():
    """Handle client connection."""
    print(f"Client connected: {request.sid}")
    # Send current service states to newly connected client
    socketio.emit('service_states_update', service_states)

@socketio.on('disconnect')
def handle_disconnect():
    """Handle client disconnection."""
    print(f"Client disconnected: {request.sid}")

@app.route('/')
def index():
    if session.get('logged_in'):
        return redirect(url_for('admin_dashboard'))
    return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    """Simple admin login."""
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')

        if username == ADMIN_USERNAME and password == ADMIN_PASSWORD:
            session['logged_in'] = True
            flash('✅ Logged in successfully!', 'success')
            return redirect(url_for('admin_dashboard'))
        flash('❌ Invalid credentials', 'danger')
    return render_template('login.html')

@app.route('/logout')
def logout():
    """Logout the admin."""
    session.pop('logged_in', None)
    flash('👋 You have been logged out.', 'info')
    return redirect(url_for('login'))

@app.route('/admin')
def admin_dashboard():
    """Dashboard showing all services."""
    if not session.get('logged_in'):
        flash('⚠️ Please log in to access the admin dashboard.', 'warning')
        return redirect(url_for('login'))

    services, error = get_running_services()
    if error:
        flash(error, 'danger')
        services = []
    
    # Update service states for real-time functionality
    update_all_service_states()
    
    return render_template('admin.html', services=services)

@app.route('/admin/service/<service_name>', methods=['POST'])
def admin_service_action(service_name):
    """Perform start/stop/restart/status/enable/disable/delete for a given service."""
    if not session.get('logged_in'):
        return jsonify({'success': False, 'message': 'Please log in first.'}), 401

    action = request.form.get('action')
    if not action:
        return jsonify({'success': False, 'message': 'No action specified.'}), 400

    success, message = run_systemctl_command(action, service_name)
    
    # Update service states after action
    update_all_service_states()
    
    if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
        return jsonify({'success': success, 'message': message})
    else:
        flash(message, 'success' if success else 'danger')
        return redirect(url_for('admin_dashboard'))

@app.route('/admin/service/<service_name>/status')
def admin_service_status(service_name):
    """Get current status of a service."""
    if not session.get('logged_in'):
        return jsonify({'error': 'Unauthorized'}), 401
    
    active_status, enabled_status = get_service_status(service_name)
    return jsonify({
        'service': service_name,
        'active': active_status,
        'enabled': enabled_status
    })

@app.route('/admin/logs/<service_name>')
def admin_service_logs(service_name):
    """Stream live logs for the given service."""
    if not session.get('logged_in'):
        flash('⚠️ Please log in to view logs.', 'warning')
        return redirect(url_for('login'))

    generator, error = stream_service_logs(service_name)
    if error:
        flash(error, 'danger')
        return redirect(url_for('admin_dashboard'))

    return Response(generator, mimetype='text/event-stream')

if __name__ == '__main__':
    print("✅ Flask Admin Service Panel running on http://0.0.0.0:7878")
    socketio.run(app, debug=True, host='0.0.0.0', port=7878, allow_unsafe_werkzeug=True)
