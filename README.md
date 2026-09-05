# Homelab Monitoring, Alerting & Tailscale CMDB Stack

An opinionated, high-performance, and ultra-lean monitoring, alerting, and CMDB stack built for mixed homelab fleets and Tailscale networks.

Powered by **Incus / LXD**, **VictoriaMetrics**, **Grafana**, **vmalert**, **Alertmanager**, and **Dynamic Tailscale Discovery**.

---

## Architecture Overview

<p align="center">
  <img src="docs/images/architecture.png" alt="Homelab Monitoring & Tailscale CMDB Architecture" width="850">
</p>

<details>
<summary><b>View Mermaid Architecture Code</b></summary>

```mermaid
architecture-beta
    group host(server)[Host Server (Linux / ARM / x86)]
    group storage(disk)[Host Storage: /opt/homelab-monitoring] in host
    service tsdb(database)[VictoriaMetrics TSDB] in storage
    service gdb(database)[Grafana DB] in storage

    group container(cloud)[Incus Container: monitoring] in host
    service vm(server)[VictoriaMetrics :8428] in container
    service vma(server)[vmalert :8880] in container
    service am(server)[Alertmanager :9093] in container
    service graf(server)[Grafana :3000] in container
    service sd(server)[Tailscale SD :8080] in container
    service ts(internet)[Tailscale Serve TLS] in container

    group fleet(cloud)[Tailscale Mesh Fleet]
    service linux(server)[Linux Nodes :9100] in fleet
    service mac(server)[macOS Nodes :9100] in fleet
    service win(server)[Windows 11 :9182] in fleet
    service nas(disk)[NAS RAID tag:nas] in fleet

    service tg(cloud)[Telegram Alerts Topic]

    vm:B --> T:tsdb
    graf:B --> T:gdb
    sd:L --> R:vm
    vm:T --> B:vma
    vma:R --> L:am
    am:R --> L:tg
    ts:L --> R:graf

    linux:T --> B:vm
    mac:T --> B:vm
    win:T --> B:vm
    nas:T --> B:vm
```

</details>

---

## Key Highlights

- **Cattle Container, Pet Data**: The container is completely disposable. All time-series data, Grafana users, Alertmanager state, and Tailscale machine keys reside directly on the host filesystem (`/opt/homelab-monitoring`) with zero uid/gid permission mismatch (`shift=true`).
- **VictoriaMetrics Core**: Replaces heavy Prometheus instances with single-binary VictoriaMetrics. Uses ~120MB RAM, starts in milliseconds, natively scrapes Prometheus targets, and is 100% PromQL compatible.
- **Dynamic Tailscale Discovery**: Automatically queries your tailnet and feeds active nodes to VictoriaMetrics over HTTP Service Discovery (`http_sd_configs`). Automatically detects offline infrastructure nodes for immediate downtime alerting while filtering out phones and auxiliary containers.
- **Automated Telegram Alerting**: Dispatches structured HTML alert cards with visual ASCII depletion bars, severity badges, and one-tap deep links directly to dedicated Telegram forum topics (via Alertmanager v0.34+ `message_thread_id`).
- **Browser-Trusted HTTPS via Tailscale Serve**: Automatically acquires and renews official Let's Encrypt certificates for `https://monitoring.<your-tailnet>.ts.net` with zero reverse-proxy boilerplate.
- **Cross-Platform Fleet CMDB**: Unifies Linux, macOS, and Windows 11 hardware, OS, and network telemetry into an executive asset inventory table.

---

## Service Discovery & Data Pipeline

<p align="center">
  <img src="docs/images/pipeline.png" alt="Tailscale Discovery & Alerting Lifecycle" width="850">
</p>

<details>
<summary><b>View Sequence Flowchart Code</b></summary>

```mermaid
sequenceDiagram
    autonumber
    participant TS as Tailscale Daemon
    participant SD as discovery/tailscale_sd.py (:8080)
    participant VM as VictoriaMetrics (:8428)
    participant VMA as vmalert (:8880)
    participant AM as Alertmanager (:9093)
    participant TG as Telegram (Alerts Topic)

    TS->>SD: Polls tailnet devices & metadata
    SD-->>SD: Filters mobile (iOS/Android) & tag:container
    SD->>VM: Serves target list over HTTP SD (/targets)
    VM->>TS: Scrapes port 9100 / 9182 across mesh
    VM->>VM: Ingests node_*, windows_*, and custom textfile metrics
    VM->>VMA: Evaluates rules every 15-30s
    opt Condition Fails (e.g. Node Down, Quota > 60%, RAID Degraded)
        VMA->>AM: Dispatches firing alert with category labels
        AM->>TG: Delivers formatted HTML card with dashboard deep-link
    end
```

</details>

---

## Included Dashboards

The stack auto-provisions 4 comprehensive dashboards located in `dashboards/`:

1. **`tailscale-cmdb.json` (Tailscale Homelab CMDB)**:
   - Centralized asset directory coalescing Linux/macOS `node_*` and Windows `windows_*` metrics.
   - Shows hostname, Tailscale IP, OS version, kernel, CPU cores, physical RAM, disk utilization, uptime, and scrape health in a unified searchable grid.
2. **`nas-raid-storage.json` (NAS & RAID Storage)**:
   - Built for software RAID arrays (e.g. `md0`, `md1` via `mdadm`).
   - Dynamically filters on nodes carrying `tag:nas`.
   - Real-time array integrity stat cards (`HEALTHY` vs `DEGRADED`), active/failed disk counters, rebuild/sync progress gauges, filesystem space breakdown (Used vs Free), and physical member drive read/write IOPS and latency.
3. **`agent-observability.json` (AI Gateway & Quota Observability)**:
   - Tracks LiteLLM proxy spend, model latency percentiles, and error rates.
   - Live quota tracking for Antigravity (`agy`) and OpenCode remaining quota percentages across `5h`, `Weekly`, and `Monthly` windows.
4. **`node-exporter-full.json` (Deep System Telemetry)**:
   - Deep OS and kernel metrics covering CPU frequency, thermal sensors, memory allocation, TCP connections, and disk saturation.

---

## Alerting Rules & Golden Signals

Pre-configured in `config/alerts/`:

| Rule Name | Group | Severity | Condition |
|---|---|---|---|
| `TailscaleNodeDown` | `fleet_availability` | 🔥 Critical | Node unreachable for > 3m (`up{job="tailscale-nodes"} == 0`) |
| `DiskWillFillIn24Hours` | `host_hardware` | ⚠️ Warning | Linear regression predicts root disk fills in < 24h (`predict_linear < 0`) |
| `HostMemoryExhaustion` | `host_hardware` | 🔥 Critical | Usable RAM drops below 5% for > 5m (`MemAvailable / MemTotal < 0.05`) |
| `SBCThermalOverheat` | `host_hardware` | ⚠️ Warning | Sensor exceeds 82°C for > 5m (protects ARM boards like ODROID/Rockchip) |
| `RAIDArrayDegraded` | `host_hardware` | 🔥 Critical | Software RAID array has dropped or failed drives (`node_md_degraded > 0`) |
| `RAIDDiskFailed` | `host_hardware` | 🔥 Critical | mdadm reports failed disk in array (`node_md_disks{state="failed"} > 0`) |
| `LiteLLMHighErrorRate` | `ai_gateway` | 🔥 Critical | > 10% of agent requests fail over 5m |
| `AgentLatencyDegraded` | `ai_gateway` | ⚠️ Warning | p90 agent response latency exceeds 25s |
| `AIMetricsCollectorStale`| `ai_gateway` | ⚠️ Warning | `ai_metrics.prom` textfile not updated for > 10m |
| `OpenCodeQuota60PercentUsed`| `opencode_quota` | ⚠️ Warning | Remaining quota between 30% and 40% (60% used) |
| `OpenCodeQuota70PercentUsed`| `opencode_quota` | ⚠️ Warning | Remaining quota between 20% and 30% (70% used) |
| `OpenCodeQuota80PercentUsed`| `opencode_quota` | ⚠️ Warning | Remaining quota between 10% and 20% (80% used) |
| `OpenCodeQuota90PercentUsed`| `opencode_quota` | 🔥 Critical | Remaining quota between 0% and 10% (90% used) |
| `OpenCodeQuotaExhausted`| `opencode_quota` | 🔥 Critical | Remaining quota completely exhausted (`remaining == 0`) |

---

## Secrets Management & Git Safety

This repository eliminates the need for complex external secret managers or encryption tools by adopting a **Host-Bound Secrets Pattern**:

```mermaid
flowchart LR
    subgraph GitRepository["Public Git Repository"]
        ExConfig["config/alertmanager.example.yml<br/>(Tracked - Safe Placeholders)"]
        GitIgnore[".gitignore<br/>(Guards: alertmanager.yml, *.key, .env)"]
    end

    subgraph HostFilesystem["Host Storage (/opt/homelab-monitoring/)"]
        RealConfig["config/alertmanager.yml<br/>(Real Telegram Bot Token, Chat ID & Topic)"]
    end

    subgraph ContainerMount["Incus Container: 'monitoring'"]
        Mount["Mounted via idmapped shift=true<br/>(/mnt/monitoring/config/alertmanager.yml)"]
    end

    GitIgnore -. Blocks Commit to GitHub .-> RealConfig
    RealConfig ==> ContainerMount
```

### How Secrets are Protected:
1. **Zero Secret Footprint in Git**:
   The repository only tracks `config/alertmanager.example.yml` with generic placeholders (`YOUR_TELEGRAM_BOT_TOKEN`, `chat_id: 123456789`).
2. **Guarded by `.gitignore`**:
   The real production file (`config/alertmanager.yml`) is explicitly blocked by `.gitignore` and can never be accidentally staged or committed to git.
3. **Persists across Re-deploys**:
   Because the configuration resides on the host storage at `/opt/homelab-monitoring/config/`, destroying or upgrading the container with `teardown.sh` and `deploy.sh` preserves your credentials automatically without manual intervention.

---

## Quickstart & Deployment

### 1. Prerequisites
- Linux host running Ubuntu 22.04/24.04 or Debian 12 (x86_64 or ARM64).
- Incus or LXD installed (`deploy.sh` auto-installs Incus if missing).
- Tailscale account with MagicDNS enabled.

### 2. Deploy
```bash
git clone https://github.com/StaticVish/homelab-monitoring.git
cd homelab-monitoring

# Provide an optional Tailscale Auth Key for zero-touch joining:
# export TAILSCALE_AUTHKEY="tskey-auth-..."

sudo ./deploy.sh
```

The script will:
1. Initialize persistent host storage at `/opt/homelab-monitoring/`.
2. Configure UFW bridge routing for `incusbr0`.
3. Launch an Ubuntu 24.04 container named `monitoring` with idmapped shifting (`shift=true`).
4. Install VictoriaMetrics, vmalert, Alertmanager v0.34.0, Grafana, and Tailscale SD.
5. Authenticate to Tailscale and activate **Tailscale HTTPS Serve**.
6. Provide a valid HTTPS MagicDNS URL: `https://monitoring.<your-tailnet>.ts.net`.

### 3. Teardown & Rebuild
Because the container is treated as cattle and all state is kept on the host:
```bash
# Safely destroy the container (zero data loss):
sudo ./teardown.sh

# Re-deploy in seconds:
sudo ./deploy.sh
```

---

## Installing Exporters across the Fleet

### Multi-OS Ansible Playbook
Automatically maps Linux, macOS, and Windows architecture:
```bash
cd external-exporters/ansible
ansible-playbook --become-user root --ask-pass --ask-become-pass -i inventory playbook.yaml
```

### Standalone Platform Installers
- **Linux** (Systemd): `sudo ./external-exporters/install-linux.sh`
- **macOS** (LaunchDaemon + Application Firewall whitelist): `sudo ./external-exporters/install-macos.sh`
- **Windows 11** (MSI + Windows Firewall rule for `100.64.0.0/10`):
  ```powershell
  Set-ExecutionPolicy Bypass -Scope Process -Force
  .\external-exporters\install-windows.ps1
  ```

---

## License

Open-source software licensed under the [MIT License](LICENSE).
