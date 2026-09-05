#!/usr/bin/env python3
"""
Node Exporter Textfile Collector for AI CLI Tools (Antigravity & OpenCode).
Queries local CLI tool quotas and statistics and writes them directly
to a Prometheus textfile (.prom) for native scraping via Node Exporter on port 9100.

Eliminates the need for separate exporter containers and custom HTTP ports.
"""

import argparse
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from typing import List, Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger("ai_metrics_textfile_collector")

DEFAULT_OUTPUT_DIR = "/var/lib/node_exporter/textfile_collector"
DEFAULT_FILENAME = "ai_metrics.prom"


def strip_ansi(text: str) -> str:
    """Remove ANSI escape sequences from terminal output."""
    ansi_regex = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    return ansi_regex.sub('', text)


def find_executable(name: str, extra_paths: Optional[List[str]] = None) -> Optional[str]:
    """Find binary in PATH or common user locations."""
    path = shutil.which(name)
    if path:
        return path

    search_dirs = [
        os.path.expanduser("~/.local/bin"),
        os.path.expanduser("~/.opencode/bin"),
        "/usr/local/bin",
        "/usr/bin",
    ]
    if extra_paths:
        search_dirs.extend(extra_paths)

    for d in search_dirs:
        candidate = os.path.join(d, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate

    return None


def run_cmd(cmd: List[str], timeout: int = 15) -> Optional[str]:
    """Execute command safely without hanging."""
    env = os.environ.copy()
    env["CI"] = "1"
    env["NO_COLOR"] = "1"
    env["TERM"] = "dumb"

    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            env=env,
        )
        if proc.returncode == 0:
            return strip_ansi(proc.stdout)
        else:
            logger.debug(f"Command {' '.join(cmd)} failed with returncode {proc.returncode}: {proc.stderr.strip()}")
            return None
    except Exception as exc:
        logger.warning(f"Error running {' '.join(cmd)}: {exc}")
        return None


def scrape_agy(allowed_models: Optional[List[str]] = None) -> List[str]:
    """Scrape Antigravity (agy) quota."""
    lines = []
    agy_bin = find_executable("agy")
    if not agy_bin:
        return lines

    stdout = run_cmd([agy_bin, "-p", "/usage"], timeout=20)
    if not stdout:
        lines.append("agy_quota_scrape_success 0")
        return lines

    got_any = False
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue

        pct_match = re.search(r'(\d+)%', line)
        if not pct_match:
            continue
        pct = float(pct_match.group(1))

        model_family = "unknown"
        line_lower = line.lower()
        if "gemini" in line_lower:
            model_family = "gemini"
        elif "claude" in line_lower or "gpt" in line_lower:
            model_family = "claude_gpt"

        # Skip model families that are not in the allowed list
        if allowed_models and model_family not in allowed_models:
            continue

        window = "unknown"
        if "five hour" in line_lower or "5h" in line_lower:
            window = "5h"
        elif "weekly" in line_lower:
            window = "weekly"

        lines.append(f'agy_quota_remaining_percent{{model_family="{model_family}",window="{window}"}} {pct}')
        got_any = True

    if got_any:
        lines.insert(0, "agy_quota_scrape_success 1")
        lines.insert(1, f"agy_quota_last_scrape_timestamp_seconds {int(time.time())}")
    else:
        lines.append("agy_quota_scrape_success 0")

    return lines


def scrape_opencode() -> List[str]:
    """Scrape OpenCode quotas and local usage statistics."""
    lines = []
    opencode_bin = find_executable("opencode")

    # 1. Quota scraping via opencode-quota
    quota_bin = find_executable("opencode-quota")
    quota_stdout = None
    if quota_bin:
        quota_stdout = run_cmd([quota_bin, "show", "--json"], timeout=15)
        if not quota_stdout:
            quota_stdout = run_cmd([quota_bin, "status", "--json"], timeout=15)
    else:
        # Fallback to npx if available
        npx_bin = find_executable("npx")
        if npx_bin:
            quota_stdout = run_cmd([npx_bin, "-y", "@slkiser/opencode-quota@latest", "show", "--json"], timeout=20)

    if quota_stdout:
        try:
            # Extract JSON block if surrounded by logging
            json_match = re.search(r'\{.*\}', quota_stdout, re.DOTALL)
            if json_match:
                data = json.loads(json_match.group(0))
                got_any = False
                providers = data.get("providers", data)
                for prov_name, prov_data in providers.items():
                    if not isinstance(prov_data, dict) or prov_data.get("status") != "ok":
                        continue
                    for entry in prov_data.get("entries", []):
                        window = str(entry.get("window", "unknown")).lower()
                        pct = entry.get("percentRemaining")
                        reset_at = entry.get("resetAt")
                        if pct is not None:
                            try:
                                lines.append(
                                    f'opencode_quota_remaining_percent{{provider="{prov_name}",window="{window}"}} {float(pct)}'
                                )
                                got_any = True
                            except (ValueError, TypeError):
                                pass
                        if reset_at:
                            try:
                                lines.append(
                                    f'opencode_quota_reset_timestamp_seconds{{provider="{prov_name}",window="{window}"}} {int(reset_at)}'
                                )
                            except (ValueError, TypeError):
                                pass
                if got_any:
                    lines.insert(0, "opencode_quota_scrape_success 1")
                    lines.insert(1, f"opencode_quota_last_scrape_timestamp_seconds {int(time.time())}")
                else:
                    lines.append("opencode_quota_scrape_success 0")
        except Exception as exc:
            logger.debug(f"Failed to parse opencode-quota JSON: {exc}")
            lines.append("opencode_quota_scrape_success 0")

    # 2. OpenCode local stats (cost & token counts)
    if opencode_bin:
        stats_stdout = run_cmd([opencode_bin, "stats"], timeout=10)
        if stats_stdout:
            cost_m = re.search(r"Total Cost\s+\$([\d\.]+)", stats_stdout)
            if cost_m:
                lines.append(f"opencode_stats_total_cost_usd {float(cost_m.group(1))}")

            sess_m = re.search(r"Sessions\s+(\d+)", stats_stdout)
            if sess_m:
                lines.append(f"opencode_stats_sessions_total {int(sess_m.group(1))}")

            def parse_units(raw_str: str) -> float:
                raw_str = raw_str.strip().upper()
                mults = {"K": 1e3, "M": 1e6, "B": 1e9}
                for suffix, mult in mults.items():
                    if raw_str.endswith(suffix):
                        return float(raw_str[:-len(suffix)]) * mult
                return float(raw_str)

            for token_type, label in [
                ("Input", "input"),
                ("Output", "output"),
                ("Cache Read", "cache_read"),
                ("Cache Write", "cache_write"),
            ]:
                m = re.search(rf"{token_type}\s+([\d\.]+[KMB]?)", stats_stdout)
                if m:
                    try:
                        lines.append(f'opencode_stats_tokens_total{{type="{label}"}} {parse_units(m.group(1))}')
                    except Exception:
                        pass

    return lines


def scrape_litellm(port: int = 4000) -> List[str]:
    """Scrape local LiteLLM proxy /metrics/ endpoint if active."""
    url = f"http://127.0.0.1:{port}/metrics/"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "NodeExporter-TextfileCollector"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            content = resp.read().decode("utf-8")
            # Return non-empty metric lines
            return [line for line in content.splitlines() if line.strip()]
    except Exception as exc:
        logger.debug(f"LiteLLM not available on port {port}: {exc}")
        return []


def generate_metrics(allowed_models: Optional[List[str]] = None) -> str:
    """Collect all AI metrics and format as Prometheus text exposition."""
    lines = [
        "# HELP agy_quota_scrape_success Whether last agy scrape succeeded (1) or failed (0)",
        "# TYPE agy_quota_scrape_success gauge",
        "# HELP agy_quota_last_scrape_timestamp_seconds Timestamp of last successful agy scrape",
        "# TYPE agy_quota_last_scrape_timestamp_seconds gauge",
        "# HELP agy_quota_remaining_percent Antigravity (agy) remaining quota percentage",
        "# TYPE agy_quota_remaining_percent gauge",
        "# HELP opencode_quota_scrape_success Whether last opencode quota scrape succeeded (1) or failed (0)",
        "# TYPE opencode_quota_scrape_success gauge",
        "# HELP opencode_quota_last_scrape_timestamp_seconds Timestamp of last successful opencode quota scrape",
        "# TYPE opencode_quota_last_scrape_timestamp_seconds gauge",
        "# HELP opencode_quota_remaining_percent OpenCode provider remaining quota percentage",
        "# TYPE opencode_quota_remaining_percent gauge",
        "# HELP opencode_stats_total_cost_usd OpenCode locally recorded total spend in USD",
        "# TYPE opencode_stats_total_cost_usd gauge",
        "# HELP opencode_stats_tokens_total OpenCode locally recorded token consumption",
        "# TYPE opencode_stats_tokens_total counter",
        "# HELP opencode_stats_sessions_total OpenCode total sessions run",
        "# TYPE opencode_stats_sessions_total counter",
    ]

    lines.extend(scrape_agy(allowed_models=allowed_models))
    lines.extend(scrape_opencode())
    lines.extend(scrape_litellm())
    lines.append("")  # Ensure trailing newline
    return "\n".join(lines)


def atomic_write(filepath: str, content: str):
    """Write content to file atomically using a temporary file in the same directory."""
    dirname = os.path.dirname(filepath)
    os.makedirs(dirname, exist_ok=True)

    tmp_path = f"{filepath}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(content)

    # Atomic rename in POSIX
    os.replace(tmp_path, filepath)
    logger.info(f"Wrote metrics atomically to {filepath}")


def parse_args():
    parser = argparse.ArgumentParser(description="AI CLI Textfile Collector for Node Exporter")
    parser.add_argument(
        "--output", "-o",
        type=str,
        default=os.path.join(DEFAULT_OUTPUT_DIR, DEFAULT_FILENAME),
        help=f"Target .prom file path (default: {DEFAULT_OUTPUT_DIR}/{DEFAULT_FILENAME})"
    )
    parser.add_argument(
        "--agy-models",
        type=str,
        default=os.environ.get("AGY_MODELS", "gemini"),
        help="Comma-separated list of Antigravity model families to track (default: gemini)"
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Print metrics to stdout instead of writing to file"
    )
    return parser.parse_args()


def main():
    args = parse_args()
    allowed_models = [m.strip().lower() for m in args.agy_models.split(",") if m.strip()] if args.agy_models else None
    metrics = generate_metrics(allowed_models=allowed_models)

    if args.stdout:
        sys.stdout.write(metrics)
    else:
        atomic_write(args.output, metrics)


if __name__ == "__main__":
    main()
