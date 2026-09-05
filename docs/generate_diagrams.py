#!/usr/bin/env python3
"""
Generate professional architectural diagrams for the homelab-monitoring repository.
Requires: uv run --with diagrams python3 generate_diagrams.py
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.onprem.monitoring import Prometheus, Grafana
from diagrams.onprem.container import Lxc
from diagrams.onprem.compute import Server
from diagrams.generic.storage import Storage
from diagrams.generic.os import LinuxGeneral, Windows, Ubuntu
from diagrams.generic.network import VPN
from diagrams.saas.chat import Telegram

graph_attr = {
    "fontsize": "16",
    "bgcolor": "#ffffff",
    "pad": "0.5",
    "splines": "spline",
}

# 1. Full Stack Architecture Diagram
with Diagram(
    "Homelab Monitoring & Tailscale CMDB Architecture",
    filename="docs/images/architecture",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
):
    with Cluster("Host Server (Linux / ARM / x86)"):
        with Cluster("Persistent Host Storage (/opt/homelab-monitoring)\n[shift=true]"):
            tsdb_storage = Storage("VictoriaMetrics TSDB\n(/data/victoria-metrics)")
            graf_storage = Storage("Grafana SQLite\n(/data/grafana)")
            ts_state = Storage("Tailscale State\n(/data/tailscale)")

        with Cluster("Incus / LXD Container ('monitoring')"):
            container = Lxc("Incus Container\n(Ubuntu 24.04)")
            
            with Cluster("Core Observability"):
                vm = Prometheus("VictoriaMetrics\n(:8428)")
                vmalert = Prometheus("vmalert\n(:8880)")
                alertmanager = Prometheus("Alertmanager v0.34\n(:9093)")
                grafana = Grafana("Grafana UI\n(:3000)")

            with Cluster("Networking & Discovery"):
                ts_sd = Server("Tailscale Discovery\n(:8080/targets)")
                ts_serve = VPN("Tailscale Serve\n(HTTPS Let's Encrypt)")

    with Cluster("Tailscale Mesh Fleet (100.64.0.0/10)"):
        linux_nodes = Ubuntu("Linux Fleet & SBCs\n(node_exporter :9100)")
        mac_nodes = Server("macOS Workstations\n(node_exporter :9100)")
        win_nodes = Windows("Windows 11 PCs\n(windows_exporter :9182)")
        nas_nodes = Storage("NAS Software RAID\n[tag:nas] (:9100)")

    telegram = Telegram("Telegram Supergroup\n(Alerts Topic)")

    # Data & Storage Bindings
    vm >> Edge(label="idmapped bind", color="#438dd5", style="dashed") >> tsdb_storage
    grafana >> Edge(label="idmapped bind", color="#438dd5", style="dashed") >> graf_storage
    ts_serve >> Edge(label="persists identity", color="#438dd5", style="dashed") >> ts_state

    # Scrape & Discovery Flow
    ts_sd >> Edge(label="HTTP SD", color="#2ca02c") >> vm
    vm >> Edge(label="scrape :9100", color="#ff7f0e") >> linux_nodes
    vm >> Edge(label="scrape :9100", color="#ff7f0e") >> mac_nodes
    vm >> Edge(label="scrape :9182", color="#ff7f0e") >> win_nodes
    vm >> Edge(label="scrape RAID :9100", color="#ff7f0e") >> nas_nodes

    # Alerting Pipeline
    vm >> Edge(label="eval rules (15s)", color="#d62728") >> vmalert
    vmalert >> Edge(label="push firing", color="#d62728") >> alertmanager
    alertmanager >> Edge(label="HTML cards with deep links", color="#0088cc", style="bold") >> telegram

    # User HTTPS Access
    ts_serve >> Edge(label="HTTPS proxy (:443 -> :3000)", color="#2ca02c") >> grafana
    grafana >> Edge(label="PromQL", color="#ff7f0e") >> vm

print("Generated docs/images/architecture.png")

# 2. Dynamic Discovery & Alerting Pipeline Diagram
with Diagram(
    "Tailscale Discovery & Alerting Lifecycle",
    filename="docs/images/pipeline",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
):
    with Cluster("Tailscale Mesh Network"):
        ts_daemon = VPN("Tailscale Engine\n(State & Peers)")
        devices = [
            Ubuntu("Linux Servers"),
            Server("macOS Hosts"),
            Windows("Windows PCs"),
            Storage("NAS RAID"),
        ]

    with Cluster("Dynamic Discovery & Ingestion"):
        sd_script = Server("discovery/tailscale_sd.py\n(HTTP SD :8080/targets)")
        vm_scraper = Prometheus("VictoriaMetrics\n(15s Scraper & TSDB)")

    with Cluster("Alerting & Notification Engine"):
        evaluator = Prometheus("vmalert\n(15s Rule Evaluator)")
        router = Prometheus("Alertmanager v0.34\n(Topic Routing :9093)")

    telegram_channel = Telegram("Telegram Alerts Topic\n(Visual HTML Cards)")

    # Data Flow
    ts_daemon >> Edge(label="peers metadata", color="#2ca02c") >> sd_script
    sd_script >> Edge(label="JSON target pool", color="#2ca02c") >> vm_scraper
    vm_scraper >> Edge(label="scrapes :9100 / :9182", color="#ff7f0e", style="dashed") >> devices
    vm_scraper >> Edge(label="PromQL timeseries", color="#438dd5") >> evaluator
    evaluator >> Edge(label="firing alerts", color="#d62728") >> router
    router >> Edge(label="thread-routed alerts", color="#0088cc", style="bold") >> telegram_channel

print("Generated docs/images/pipeline.png")

