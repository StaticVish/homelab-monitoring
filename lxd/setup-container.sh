#!/usr/bin/env bash
# Internal container setup script
# Provisions VictoriaMetrics, Grafana, Alertmanager, Tailscale (with HTTPS Serve), and Tailscale SD

set -euo pipefail

VM_VERSION="v1.102.0"
AM_VERSION="0.34.0"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-monitoring}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

echo "================================================================="
echo " Starting In-Container Provisioning"
echo " Target Tailscale Hostname: ${TAILSCALE_HOSTNAME}"
echo "================================================================="

# 1. System Dependencies
echo "==> [1/7] Installing system dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg apt-transport-https python3 iptables

# Detect architecture
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)
        PKG_ARCH="amd64"
        ;;
    aarch64|arm64)
        PKG_ARCH="arm64"
        ;;
    *)
        echo "[ERROR] Unsupported container architecture: ${ARCH}"
        exit 1
        ;;
esac
echo "==> Architecture: ${ARCH} (target: ${PKG_ARCH})"

# 2. Install Tailscale & Persist State to Host
echo "==> [2/7] Configuring Tailscale with host-persistent state..."
if ! command -v tailscale &>/dev/null; then
    echo "[INFO] Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# Ensure Tailscale state persists on host storage
mkdir -p /mnt/monitoring/data/tailscale
if [ ! -L /var/lib/tailscale ]; then
    systemctl stop tailscaled 2>/dev/null || true
    rm -rf /var/lib/tailscale
    ln -s /mnt/monitoring/data/tailscale /var/lib/tailscale
fi

systemctl daemon-reload
systemctl enable --now tailscaled

# Wait for tailscaled socket
sleep 2

# Authenticate Tailscale
echo "==> [3/7] Connecting to Tailnet..."
if ! tailscale status &>/dev/null; then
    if [ -n "${TAILSCALE_AUTHKEY}" ]; then
        echo "[INFO] Logging in with provided Tailscale Auth Key..."
        tailscale up --authkey="${TAILSCALE_AUTHKEY}" --hostname="${TAILSCALE_HOSTNAME}" --accept-routes --reset
    else
        echo "================================================================="
        echo " [ACTION REQUIRED] Please authenticate this node on Tailscale:"
        echo "================================================================="
        tailscale up --hostname="${TAILSCALE_HOSTNAME}" --accept-routes --reset || true
    fi
else
    echo "[INFO] Tailscale node is already authenticated and active."
fi

# 3. Install VictoriaMetrics
echo "==> [4/7] Installing VictoriaMetrics (${VM_VERSION})..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

curl -sSL -o "${TMP_DIR}/victoria-metrics.tar.gz" \
    "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/victoria-metrics-linux-${PKG_ARCH}-${VM_VERSION}.tar.gz"
tar -xzf "${TMP_DIR}/victoria-metrics.tar.gz" -C "${TMP_DIR}"
cp "${TMP_DIR}/victoria-metrics-prod" "/usr/local/bin/victoria-metrics"
chmod 755 "/usr/local/bin/victoria-metrics"

# Install vmalert from vmutils
echo "==> Installing vmalert (${VM_VERSION})..."
curl -sSL -o "${TMP_DIR}/vmutils.tar.gz" \
    "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/vmutils-linux-${PKG_ARCH}-${VM_VERSION}.tar.gz"
tar -xzf "${TMP_DIR}/vmutils.tar.gz" -C "${TMP_DIR}" vmalert-prod
cp "${TMP_DIR}/vmalert-prod" "/usr/local/bin/vmalert"
chmod 755 "/usr/local/bin/vmalert"

# 4. Install Alertmanager
echo "==> [5/8] Installing Alertmanager (${AM_VERSION})..."
curl -sSL -o "${TMP_DIR}/alertmanager.tar.gz" \
    "https://github.com/prometheus/alertmanager/releases/download/v${AM_VERSION}/alertmanager-${AM_VERSION}.linux-${PKG_ARCH}.tar.gz"
tar -xzf "${TMP_DIR}/alertmanager.tar.gz" -C "${TMP_DIR}"
cp "${TMP_DIR}/alertmanager-${AM_VERSION}.linux-${PKG_ARCH}/alertmanager" "/usr/local/bin/alertmanager"
chmod 755 "/usr/local/bin/alertmanager"

# 5. Install Node Exporter for self-monitoring
NODE_EXPORTER_VERSION="1.8.2"
echo "==> [6/8] Installing Node Exporter for container self-monitoring (${NODE_EXPORTER_VERSION})..."
curl -sSL -o "${TMP_DIR}/node_exporter.tar.gz" \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${PKG_ARCH}.tar.gz"
tar -xzf "${TMP_DIR}/node_exporter.tar.gz" -C "${TMP_DIR}"
cp "${TMP_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${PKG_ARCH}/node_exporter" "/usr/local/bin/node_exporter"
chmod 755 "/usr/local/bin/node_exporter"

# 6. Install Tailscale Discovery Script
echo "==> [7/8] Installing Tailscale Discovery Engine..."
if [ -f "/mnt/monitoring/discovery/tailscale_sd.py" ]; then
    cp "/mnt/monitoring/discovery/tailscale_sd.py" "/usr/local/bin/tailscale_sd.py"
    chmod 755 "/usr/local/bin/tailscale_sd.py"
fi

# 7. Install Grafana from official repository
echo "==> [8/8] Installing Grafana..."
mkdir -p /etc/apt/keyrings/
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg --yes
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update -qq
apt-get install -y -qq grafana

# Configure Grafana paths to use host storage
cat <<EOF > /etc/grafana/grafana.ini
[paths]
data = /mnt/monitoring/data/grafana
provisioning = /mnt/monitoring/config/grafana/provisioning

[server]
http_port = 3000
root_url = %(protocol)s://%(domain)s:%(http_port)s/

[security]
admin_user = admin
admin_password = admin

[analytics]
check_for_updates = false
EOF

mkdir -p /mnt/monitoring/data/grafana
chown -R grafana:grafana /mnt/monitoring/data/grafana 2>/dev/null || true

# Copy systemd units and launch services
if [ -d "/mnt/monitoring/lxd/systemd" ]; then
    cp /mnt/monitoring/lxd/systemd/*.service /etc/systemd/system/
fi

systemctl daemon-reload
systemctl enable --now victoria-metrics
systemctl enable --now alertmanager
systemctl enable --now vmalert
systemctl enable --now node-exporter
systemctl enable --now grafana-server
systemctl enable --now tailscale-sd || true

# 7. Configure Tailscale HTTPS Serve for Grafana
if tailscale status &>/dev/null; then
    echo "==> Enabling Tailscale HTTPS Serve for Grafana..."
    # Configures Tailscale to terminate TLS on port 443 and proxy to Grafana on 3000
    tailscale serve --bg http://127.0.0.1:3000 || true
    TS_IP="$(tailscale ip -4 2>/dev/null || echo 'unknown')"
    TS_FQDN="$(tailscale status --json | grep -o '"DNSName": "[^"]*' | head -n 1 | cut -d'"' -f4 | sed 's/\.$//' || true)"
    echo ""
    echo "================================================================="
    echo " [TAILSCALE HTTPS READY]"
    echo " MagicDNS URL: https://${TS_FQDN:-${TS_HOSTNAME}}"
    echo " Tailscale IP: ${TS_IP}"
    echo "================================================================="
fi
