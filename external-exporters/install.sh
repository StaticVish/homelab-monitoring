#!/bin/bash
set -e

echo "Starting Node Exporter on port 9100..."

# Check if docker is installed
if ! command -v docker &> /dev/null
then
    echo "Docker could not be found. Please install docker first."
    exit 1
fi

docker run -d \
  --name=node_exporter \
  --net="host" \
  --pid="host" \
  -v "/:/host:ro,rslave" \
  quay.io/prometheus/node-exporter:latest \
  --path.rootfs=/host

echo "Node Exporter is running."
echo "You can check metrics at http://localhost:9100/metrics"
