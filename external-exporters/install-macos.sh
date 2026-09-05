#!/usr/bin/env bash
# macOS node_exporter automated installer
# Supports Apple Silicon (arm64) and Intel (x86_64) via LaunchDaemon

set -euo pipefail

NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.8.2}"
INSTALL_DIR="/usr/local/bin"
PLIST_PATH="/Library/LaunchDaemons/io.prometheus.node-exporter.plist"

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (use: sudo ./install-macos.sh)"
    exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
    arm64)
        DARWIN_ARCH="arm64"
        ;;
    x86_64)
        DARWIN_ARCH="amd64"
        ;;
    *)
        echo "[ERROR] Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac

echo "[INFO] Detected macOS architecture: ${ARCH} (Darwin target: ${DARWIN_ARCH})"
TARBALL="node_exporter-${NODE_EXPORTER_VERSION}.darwin-${DARWIN_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${TARBALL}"

echo "[INFO] Downloading node_exporter v${NODE_EXPORTER_VERSION}..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

curl -sSL -o "${TMP_DIR}/${TARBALL}" "${DOWNLOAD_URL}"
tar -xzf "${TMP_DIR}/${TARBALL}" -C "${TMP_DIR}"

mkdir -p "${INSTALL_DIR}"
cp "${TMP_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.darwin-${DARWIN_ARCH}/node_exporter" "${INSTALL_DIR}/node_exporter"
chmod 755 "${INSTALL_DIR}/node_exporter"
chown root:wheel "${INSTALL_DIR}/node_exporter"

echo "[INFO] Installed binary to ${INSTALL_DIR}/node_exporter"

# Unload previous LaunchDaemon if running
if launchctl list | grep -q "io.prometheus.node-exporter"; then
    echo "[INFO] Unloading existing service..."
    launchctl unload -w "${PLIST_PATH}" 2>/dev/null || true
fi

echo "[INFO] Creating LaunchDaemon at ${PLIST_PATH}..."
cat <<EOF > "${PLIST_PATH}"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.prometheus.node-exporter</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/node_exporter</string>
        <string>--web.listen-address=:9100</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/node-exporter.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/node-exporter-err.log</string>
</dict>
</plist>
EOF

chmod 644 "${PLIST_PATH}"
chown root:wheel "${PLIST_PATH}"

echo "[INFO] Starting LaunchDaemon..."
launchctl load -w "${PLIST_PATH}"

echo "[SUCCESS] Node Exporter is active and listening on port 9100."
echo "[INFO] Verify metrics locally: curl -s http://localhost:9100/metrics | head -n 10"
