# Monitoring Service

A robust monitoring stack for K3s home labs using Prometheus, Grafana, and Alertmanager.

## Features
- **Prometheus**: Metric collection and storage.
- **Grafana**: Visualization dashboards.
- **Alertmanager**: Alerting via Telegram.
- **External Node Monitoring**: Support for scraping metrics from non-K8s machines.
- **Kustomize-based**: Easy configuration management and overlaying.

## Prerequisites
- K3s installed and running (`sudo k3s kubectl` access).
- `kubectl` and `kustomize` (usually bundled with k3s or available separately).

## Configuration

### 1. Telegram Alerts
We use **SOPS** to manage secrets. The Telegram configuration is stored in an encrypted file: `k8s/overlays/prod/secrets/alertmanager-secret.enc.yaml`.

To edit the secrets (Telegram Token/Chat ID):
```bash
# Set your age key environment variable
export SOPS_AGE_KEY_FILE=$(pwd)/key.txt

# Decrypt and edit
sops k8s/overlays/prod/secrets/alertmanager-secret.enc.yaml
```

Do **NOT** commit the `key.txt` file to git. It is your private key.

The Helm Chart is configured to use the secret `alertmanager-telegram-config` which is created from this encrypted file.

### 2. External Nodes
To monitor external machines (e.g., a NAS or a Raspberry Pi), add their IPs to `k8s/overlays/prod/helm-chart.yaml` under `additionalScrapeConfigs`:

```yaml
        additionalScrapeConfigs:
          - job_name: 'external-nodes'
            static_configs:
              - targets: ['192.168.1.50:9100', '192.168.1.51:9100']
```

## Deployment

To deploy the stack to your K3s cluster:

To deploy the stack (including secrets):

```bash
chmod +x deploy.sh
./deploy.sh
```

This script will:
1. Decrypt the `alertmanager-secret.enc.yaml` using your `key.txt` and apply it to the cluster.
2. Build and apply the Kustomize overlays.

Check the status of the pods:
```bash
sudo k3s kubectl get pods -n monitoring
```

## Accessing Grafana

Port-forward to access the Grafana dashboard:
```bash
sudo k3s kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
```
Then visit [http://localhost:3000](http://localhost:3000).
**Default User**: `admin`
**Default Password**: `admin` (Change this in `values.yaml` or UI immediately!)

## Monitoring External Machines

To start the node-exporter on an external machine:

### Option 1: Docker Compose
Copy `external-exporters/docker-compose.yaml` to the target machine and run:
```bash
docker-compose up -d
```

### Option 2: Shell Script
Copy `external-exporters/install.sh` to the target machine and run:
```bash
chmod +x install.sh
./install.sh
```

Ensure the machine's IP is added to the Prometheus config as described above.
