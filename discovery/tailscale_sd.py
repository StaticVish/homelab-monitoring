#!/usr/bin/env python3
"""
Tailscale Service Discovery for Prometheus
Generates target definitions from 'tailscale status --json' or the Tailscale API,
and serves them over HTTP (Prometheus http_sd_configs) or writes to a file (file_sd_configs).
"""

import argparse
import http.server
import json
import os
import socketserver
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_EXPORTER_PORT = 9100
DEFAULT_WINDOWS_PORT = 9182
DEFAULT_HTTP_PORT = 8080


def fetch_from_cli():
    """Fetch status directly from local tailscale CLI."""
    try:
        raw = subprocess.check_output(["tailscale", "status", "--json"], text=True)
        return json.loads(raw)
    except Exception as exc:
        sys.stderr.write(f"[WARN] Local tailscale CLI failed: {exc}\n")
        return None


def fetch_from_api(api_key, tailnet):
    """Fetch devices from official Tailscale API."""
    url = f"https://api.tailscale.com/api/v2/tailnet/{tailnet}/devices"
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
            "User-Agent": "Prometheus-Tailscale-SD",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            # Transform API format to match status parser structure
            devices = data.get("devices", [])
            peers = {}
            for d in devices:
                key = d.get("nodeId", d.get("id"))
                peers[key] = {
                    "HostName": d.get("hostname", d.get("name")),
                    "DNSName": d.get("name", ""),
                    "TailscaleIPs": d.get("addresses", []),
                    "OS": d.get("os", "unknown"),
                    "Online": not d.get("clientConnectivity", {}).get("endpoints", []) == [] if "clientConnectivity" in d else True,
                    "Tags": d.get("tags", []),
                }
            return {"Peer": peers, "Self": {}}
    except Exception as exc:
        sys.stderr.write(f"[WARN] Tailscale API fetch failed: {exc}\n")
        return None


def build_prometheus_targets(status_data, exporter_port=DEFAULT_EXPORTER_PORT, windows_port=DEFAULT_WINDOWS_PORT, include_offline=True, include_mobile=False, tag_filter=None, exclude_tags=None):
    if not status_data:
        return []

    targets = []
    seen_ips = set()

    def add_node(node_info):
        ips = node_info.get("TailscaleIPs", [])
        if not ips:
            return

        # Use first IPv4 address
        ipv4 = next((ip for ip in ips if ":" not in ip), ips[0])
        if ipv4 in seen_ips:
            return
        seen_ips.add(ipv4)

        hostname = node_info.get("HostName", "unknown").lower()
        dns_name = node_info.get("DNSName", "").rstrip(".")
        raw_os = node_info.get("OS", "unknown").lower()
        os_name = "macos" if raw_os in ("darwin", "macos") else raw_os
        tags = node_info.get("Tags", []) or []

        # Filter out mobile platforms by default
        if not include_mobile and os_name in ("android", "ios"):
            return

        # Filter out excluded tags (e.g. tag:container)
        if exclude_tags and any(t in tags for t in exclude_tags):
            return

        # Tag filter check (whitelist)
        if tag_filter and not any(t in tags for t in tag_filter):
            return

        # Select target port: Windows uses windows_exporter (9182), Linux/macOS use node_exporter (9100)
        target_port = windows_port if os_name == "windows" else exporter_port

        targets.append({
            "targets": [f"{ipv4}:{target_port}"],
            "labels": {
                "instance": hostname,
                "dns_name": dns_name or hostname,
                "tailscale_ip": ipv4,
                "os": os_name,
                "tailscale_tags": ",".join(tags) if tags else "none",
                "job": "tailscale-nodes",
            },
        })

    # Include local host if running CLI mode
    self_node = status_data.get("Self")
    if self_node:
        add_node(self_node)

    # Process all peers
    for _, peer in status_data.get("Peer", {}).items():
        is_online = peer.get("Online", False)
        if not include_offline and not is_online:
            continue
        add_node(peer)

    # Sort deterministically by hostname
    targets.sort(key=lambda x: x["labels"]["instance"])
    return targets


def get_targets(args):
    status = None
    api_key = args.api_key or os.environ.get("TAILSCALE_API_KEY")
    tailnet = args.tailnet or os.environ.get("TAILSCALE_TAILNET")

    if api_key and tailnet:
        status = fetch_from_api(api_key, tailnet)

    if not status:
        status = fetch_from_cli()

    tags = [t.strip() for t in args.tags.split(",")] if args.tags else None
    exclude_tags = [t.strip() for t in args.exclude_tags.split(",") if t.strip()] if args.exclude_tags else []
    include_offline = not args.exclude_offline
    return build_prometheus_targets(
        status,
        exporter_port=args.exporter_port,
        windows_port=args.windows_port,
        include_offline=include_offline,
        include_mobile=args.include_mobile,
        tag_filter=tags,
        exclude_tags=exclude_tags,
    )


class TargetHTTPHandler(http.server.BaseHTTPRequestHandler):
    def __init__(self, *handler_args, cli_args=None, **kwargs):
        self.cli_args = cli_args
        super().__init__(*handler_args, **kwargs)

    def do_GET(self):
        if self.path in ("/", "/targets", "/metrics-targets"):
            targets = get_targets(self.cli_args)
            body = json.dumps(targets, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *msg_args):
        # Concise logging
        sys.stderr.write(f"[HTTP] {self.address_string()} - {format % msg_args}\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Prometheus Service Discovery for Tailscale")
    parser.add_argument("--serve", action="store_true", help="Run HTTP SD server for Prometheus http_sd_configs")
    parser.add_argument("--port", type=int, default=DEFAULT_HTTP_PORT, help=f"HTTP server port (default: {DEFAULT_HTTP_PORT})")
    parser.add_argument("--exporter-port", type=int, default=DEFAULT_EXPORTER_PORT, help=f"Target node-exporter port for Linux/macOS (default: {DEFAULT_EXPORTER_PORT})")
    parser.add_argument("--windows-port", type=int, default=DEFAULT_WINDOWS_PORT, help=f"Target windows_exporter port for Windows (default: {DEFAULT_WINDOWS_PORT})")
    parser.add_argument("--output", "-o", type=str, help="Output file path for Prometheus file_sd_configs")
    parser.add_argument("--exclude-offline", action="store_true", help="Exclude offline Tailscale peers (default: include all peers for node-down alerting)")
    parser.add_argument("--include-offline", action="store_true", default=True, help="Include offline Tailscale peers (default: true)")
    parser.add_argument("--include-mobile", action="store_true", help="Include mobile phones/tablets (android/ios)")
    parser.add_argument("--tags", type=str, help="Comma-separated list of Tailscale tags to filter by")
    parser.add_argument("--exclude-tags", type=str, default="tag:container", help="Comma-separated list of Tailscale tags to omit (default: tag:container)")
    parser.add_argument("--api-key", type=str, help="Tailscale API key (or TAILSCALE_API_KEY env)")
    parser.add_argument("--tailnet", type=str, help="Tailnet name (or TAILSCALE_TAILNET env)")
    return parser.parse_args()


class ThreadedHTTPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    args = parse_args()

    if args.serve:
        handler = lambda *h_args, **h_kwargs: TargetHTTPHandler(*h_args, cli_args=args, **h_kwargs)
        with ThreadedHTTPServer(("", args.port), handler) as httpd:
            sys.stdout.write(f"Tailscale Prometheus SD server listening on http://0.0.0.0:{args.port}/targets\n")
            try:
                httpd.serve_forever()
            except KeyboardInterrupt:
                sys.stdout.write("\nShutting down server.\n")
    else:
        targets = get_targets(args)
        rendered = json.dumps(targets, indent=2)
        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(rendered + "\n")
            sys.stdout.write(f"Wrote {len(targets)} targets to {args.output}\n")
        else:
            print(rendered)


if __name__ == "__main__":
    main()
