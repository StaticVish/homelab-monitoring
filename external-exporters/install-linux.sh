#!/usr/bin/env bash
# Linux native node_exporter automated installer (systemd)
# Multi-arch: x86_64, aarch64 (arm64), armv7l, armv6l, 386

set -euo pipefail

NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.8.2}"
INSTALL_DIR="/usr/local/bin"

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (use: sudo ./install-linux.sh)"
    exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)
        BIN_ARCH="amd64"
        ;;
    aarch64|arm64)
        BIN_ARCH="arm64"
        ;;
    armv7l)
        BIN_ARCH="armv7"
        ;;
    armv6l)
        BIN_ARCH="armv6"
        ;;
    i386|i686)
        BIN_ARCH="386"
        ;;
    *)
        echo "[ERROR] Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac

echo "[INFO] Detected Linux architecture: ${ARCH} (target: ${BIN_ARCH})"
TARBALL="node_exporter-${NODE_EXPORTER_VERSION}.linux-${BIN_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${TARBALL}"

# 1. Create dedicated system user
if ! id "node_exporter" &>/dev/null; then
    echo "[INFO] Creating node_exporter system user..."
    useradd --no-create-home --shell /bin/false --system node_exporter
fi

# 2. Download and extract
echo "[INFO] Downloading node_exporter v${NODE_EXPORTER_VERSION}..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

curl -sSL -o "${TMP_DIR}/${TARBALL}" "${DOWNLOAD_URL}"
tar -xzf "${TMP_DIR}/${TARBALL}" -C "${TMP_DIR}"

mkdir -p "${INSTALL_DIR}"
cp "${TMP_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${BIN_ARCH}/node_exporter" "${INSTALL_DIR}/node_exporter"
chown node_exporter:node_exporter "${INSTALL_DIR}/node_exporter"
chmod 755 "${INSTALL_DIR}/node_exporter"

# 3. Create Systemd Unit
echo "[INFO] Creating systemd service..."
cat <<EOF > /etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=${INSTALL_DIR}/node_exporter --web.listen-address=:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 4. Enable and start
systemctl daemon-reload
systemctl enable --now node_exporter

echo "[SUCCESS] node_exporter is running on port 9100!"
echo "[INFO] Verify metrics: curl -s http://localhost:9100/metrics | head -n 10"
