#!/bin/sh
set -e

# Ensure state directory exists
STATE_DIR="${OPENCLAW_STATE_DIR:-/data/openclaw}"
mkdir -p "$STATE_DIR"

# Bootstrap minimal config if none exists
CONFIG_FILE="$STATE_DIR/openclaw.json"
if [ ! -f "$CONFIG_FILE" ]; then
  BOOT_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
  cat > "$CONFIG_FILE" <<CONF
{"gateway":{"mode":"local","bind":"lan","auth":{"token":"$BOOT_TOKEN"},"controlUi":{"dangerouslyDisableDeviceAuth":true}},"update":{"checkOnStart":false}}
CONF
  echo "Created default config at $CONFIG_FILE (bootstrap token: $BOOT_TOKEN)"
fi

# Start SSH daemon first (always available for debugging)
mkdir -p /var/run/sshd /root/.ssh
chmod 700 /root/.ssh 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
/usr/sbin/sshd
echo "SSH daemon started."

# Start Docker daemon in background (best-effort, not critical for gateway)
dockerd --host=unix:///var/run/docker.sock --storage-driver=vfs --iptables=false &
DOCKERD_PID=$!

echo "Waiting for Docker daemon..."
DOCKER_WAIT=0
while ! docker info >/dev/null 2>&1; do
  sleep 1
  DOCKER_WAIT=$((DOCKER_WAIT + 1))
  if [ $DOCKER_WAIT -ge 30 ]; then
    echo "Warning: Docker daemon not ready after 30s, continuing without it."
    break
  fi
  # Check if dockerd process died
  if ! kill -0 $DOCKERD_PID 2>/dev/null; then
    echo "Warning: Docker daemon exited, continuing without it."
    break
  fi
done
if docker info >/dev/null 2>&1; then
  echo "Docker daemon ready."
fi

# Start openclaw gateway (foreground)
exec openclaw gateway run --bind lan --port 18789 --force
