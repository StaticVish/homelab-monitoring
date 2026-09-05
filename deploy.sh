#!/usr/bin/env bash
# Deploy Homelab Monitoring Stack (Incus / LXD + VictoriaMetrics + Grafana + Tailscale HTTPS)
# All time-series data, dashboards, configs, and Tailscale identity reside on host storage

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-monitoring}"
MONITORING_ROOT="${MONITORING_ROOT:-/opt/homelab-monitoring}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-monitoring}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="/snap/bin:$PATH"

# 1. Verify Root Privileges
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] deploy.sh requires root privileges to manage host storage, devices, and containers."
    echo "Please run: sudo ./deploy.sh"
    exit 1
fi

# 2. Detect or Auto-Install Container Engine (Incus preferred for Debian/Ubuntu APT, LXD fallback)
if command -v incus &>/dev/null; then
    ENGINE="incus"
    UBUNTU_IMAGE="images:ubuntu/24.04"
    INIT_CMD="incus admin init --auto"
elif command -v lxc &>/dev/null || [ -x /snap/bin/lxc ]; then
    ENGINE="lxc"
    UBUNTU_IMAGE="ubuntu:24.04"
    INIT_CMD="lxd init --auto"
else
    echo "==> [0/5] No container engine found. Installing native Incus via APT..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq incus
    ENGINE="incus"
    UBUNTU_IMAGE="images:ubuntu/24.04"
    INIT_CMD="incus admin init --auto"
fi

echo "================================================================="
echo " Deploying Homelab Monitoring Stack via ${ENGINE^^}"
echo " Container Name:     ${CONTAINER_NAME}"
echo " Image Source:       ${UBUNTU_IMAGE}"
echo " Tailscale Hostname: ${TAILSCALE_HOSTNAME}"
echo " Host Storage Path:  ${MONITORING_ROOT}"
echo "================================================================="

# Ensure container engine daemon is initialized
echo "==> Verifying ${ENGINE^^} daemon initialization..."
if [ "${ENGINE}" = "incus" ]; then
    if ! incus profile show default &>/dev/null || [ "$(incus storage list --format csv 2>/dev/null | wc -l)" -eq 0 ]; then
        echo "[INFO] Running initial incus admin init --auto..."
        incus admin init --auto
    fi
else
    if ! lxd waitready --timeout=15 2>/dev/null; then
        systemctl start snap.lxd.daemon 2>/dev/null || true
    fi
    if ! lxc profile show default &>/dev/null || [ "$(lxc storage list --format csv 2>/dev/null | wc -l)" -eq 0 ]; then
        echo "[INFO] Running initial lxd init --auto..."
        lxd init --auto
    fi
fi

# Ensure UFW allows bridge traffic if active on host
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    BRIDGE_NAME="incusbr0"
    [ "${ENGINE}" = "lxc" ] && BRIDGE_NAME="lxdbr0"
    echo "[INFO] UFW is active. Ensuring bridge DHCP/DNS and routing rules for ${BRIDGE_NAME}..."
    ufw allow in on "${BRIDGE_NAME}" >/dev/null 2>&1 || true
    ufw route allow in on "${BRIDGE_NAME}" >/dev/null 2>&1 || true
    ufw route allow out on "${BRIDGE_NAME}" >/dev/null 2>&1 || true
fi

# 3. Prepare Host Storage Directories
echo "==> [1/5] Preparing persistent host storage at ${MONITORING_ROOT}..."
mkdir -p "${MONITORING_ROOT}/config/alerts"
mkdir -p "${MONITORING_ROOT}/config/grafana/provisioning/datasources"
mkdir -p "${MONITORING_ROOT}/config/grafana/provisioning/dashboards"
mkdir -p "${MONITORING_ROOT}/dashboards"
mkdir -p "${MONITORING_ROOT}/data/victoria-metrics"
mkdir -p "${MONITORING_ROOT}/data/grafana"
mkdir -p "${MONITORING_ROOT}/data/alertmanager"
mkdir -p "${MONITORING_ROOT}/data/tailscale"
mkdir -p "${MONITORING_ROOT}/discovery"
mkdir -p "${MONITORING_ROOT}/lxd/systemd"

# 4. Synchronize Configs and Dashboards
echo "==> [2/5] Syncing configs, dashboards, and discovery scripts..."
cp -r "${REPO_DIR}/config/"* "${MONITORING_ROOT}/config/"
cp -r "${REPO_DIR}/dashboards/"* "${MONITORING_ROOT}/dashboards/"
cp -r "${REPO_DIR}/discovery/"* "${MONITORING_ROOT}/discovery/"
cp -r "${REPO_DIR}/lxd/"* "${MONITORING_ROOT}/lxd/"

if [ ! -f "${MONITORING_ROOT}/config/alertmanager.yml" ]; then
    cp "${REPO_DIR}/config/alertmanager.example.yml" "${MONITORING_ROOT}/config/alertmanager.yml"
fi

# 5. Launch or Start Container
echo "==> [3/5] Setting up container '${CONTAINER_NAME}' with ${ENGINE}..."
if ! ${ENGINE} info "${CONTAINER_NAME}" &>/dev/null; then
    echo "[INFO] Launching fresh container '${CONTAINER_NAME}' from ${UBUNTU_IMAGE}..."
    ${ENGINE} launch "${UBUNTU_IMAGE}" "${CONTAINER_NAME}"
else
    echo "[INFO] Container '${CONTAINER_NAME}' already exists."
    if [ "$(${ENGINE} info "${CONTAINER_NAME}" | awk '/^Status:/ {print $2}')" != "RUNNING" ]; then
        echo "[INFO] Starting container '${CONTAINER_NAME}'..."
        ${ENGINE} start "${CONTAINER_NAME}"
    fi
fi

# Configure Container Capabilities for Tailscale and idmapping
echo "==> [4/5] Configuring devices (idmapped storage, /dev/net/tun)..."
${ENGINE} config set "${CONTAINER_NAME}" security.nesting=true

# Add TUN device for Tailscale
if ! ${ENGINE} config device show "${CONTAINER_NAME}" | grep -q "tun:"; then
    ${ENGINE} config device add "${CONTAINER_NAME}" tun unix-char path=/dev/net/tun
fi

# Attach host storage device with idmapped shifting
if ! ${ENGINE} config device show "${CONTAINER_NAME}" | grep -q "homelab-storage:"; then
    ${ENGINE} config device add "${CONTAINER_NAME}" homelab-storage disk \
        source="${MONITORING_ROOT}" \
        path=/mnt/monitoring \
        shift=true
fi

# Expose local ports to host as fallback
for port in 3000 8428 9093; do
    devname="proxy-${port}"
    if ! ${ENGINE} config device show "${CONTAINER_NAME}" | grep -q "${devname}:"; then
        ${ENGINE} config device add "${CONTAINER_NAME}" "${devname}" proxy \
            listen="tcp:0.0.0.0:${port}" connect="tcp:127.0.0.1:${port}" bind=host || true
    fi
done

# Wait for container network to settle
sleep 4

# 6. Execute Provisioning inside Container
echo "==> [5/5] Executing in-container provisioning..."
${ENGINE} exec "${CONTAINER_NAME}" \
    --env TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY}" \
    --env TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME}" \
    -- /mnt/monitoring/lxd/setup-container.sh

# 7. Print Final Status & Access Information
echo ""
echo "================================================================="
echo " [SUCCESS] Monitoring Stack Deployed Successfully via ${ENGINE^^}!"
echo "================================================================="

# Extract Tailscale details from container
TS_IP="$(${ENGINE} exec "${CONTAINER_NAME}" -- tailscale ip -4 2>/dev/null || echo 'Not Connected')"
TS_FQDN="$(${ENGINE} exec "${CONTAINER_NAME}" -- tailscale status --json 2>/dev/null | grep -o '"DNSName": "[^"]*' | head -n 1 | cut -d'"' -f4 | sed 's/\.$//' || echo '')"

if [ -n "${TS_FQDN}" ]; then
    echo " Secure HTTPS Dashboard:  https://${TS_FQDN} (Tailscale Auto-Cert)"
fi
echo " Tailscale Node IP:       ${TS_IP}"
echo " Local Fallback (Host):   http://localhost:3000 (admin / admin)"
echo " VictoriaMetrics Web:     http://localhost:8428"
echo " Host Persistent Data:    ${MONITORING_ROOT}/data"
echo "================================================================="
