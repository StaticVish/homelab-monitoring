#!/usr/bin/env bash
# Teardown Homelab Monitoring Container (Incus / LXD)
# The container is destroyed, but all metrics, dashboards, configs,
# and Tailscale identity on the host filesystem remain completely safe.

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-monitoring}"
MONITORING_ROOT="${MONITORING_ROOT:-/opt/homelab-monitoring}"

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] teardown.sh requires root privileges."
    echo "Please run: sudo ./teardown.sh"
    exit 1
fi

if command -v incus &>/dev/null; then
    ENGINE="incus"
elif command -v lxc &>/dev/null || [ -x /snap/bin/lxc ]; then
    ENGINE="lxc"
else
    echo "[WARN] Neither incus nor lxc found on host."
    exit 0
fi

echo "==> Stopping and deleting container '${CONTAINER_NAME}' via ${ENGINE}..."
${ENGINE} stop "${CONTAINER_NAME}" --force 2>/dev/null || true
${ENGINE} delete "${CONTAINER_NAME}" 2>/dev/null || true

echo ""
echo "================================================================="
echo " Container '${CONTAINER_NAME}' has been cleanly destroyed."
echo " All persistent data remains safe at: ${MONITORING_ROOT}"
echo " To redeploy, simply run: sudo ./deploy.sh"
echo "================================================================="
