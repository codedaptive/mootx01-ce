#!/usr/bin/env python3
"""Black-box benchmark of the shipped mootx01 MCP product boundary.

The runner starts the requested binary as a resident HTTP daemon against a
temporary, isolated estate. It never reads or writes the user's real estate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import signal
import socket
import statistics
import subprocess
import tempfile
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def percentile(values: list[int], p: float) -> int:
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1, int((p * len(ordered) + 0.999999999)) - 1))]


def summary(samples: list[int]) -> dict[str, object]:
    return {
        "samples": len(samples),
        "min_ns": min(samples),
        "mean_ns": round(statistics.fmean(samples)),
        "p50_ns": percentile(samples, 0.50),
        "p95_ns": percentile(samples, 0.95),
        "p99_ns": percentile(samples, 0.99),
        "max_ns": max(samples),
        "raw_samples_ns": samples,
    }


def wait_for_port(port: int, process: subprocess.Popen[str], timeout: float = 120.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"daemon exited early with status {process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError(f"daemon did not listen on port {port}")


def require_free_port(port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", port))


def call(port: int, request_id: int, tool: str, arguments: dict[str, object]) -> dict[str, object]:
    body = json.dumps({
        "jsonrpc": "2.0", "id": request_id, "method": "tools/call",
        "params": {"name": tool, "arguments": arguments},
    }, separators=(",", ":")).encode()
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/", data=body, method="POST",
        headers={"Content-Type": "application/json", "Connection": "close"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        payload = json.load(response)
    if "error" in payload:
        raise RuntimeError(f"{tool} JSON-RPC error: {payload['error']}")
    result = payload.get("result", {})
    if result.get("isError"):
        raise RuntimeError(f"{tool} tool error: {result}")
    return payload


def measured_calls(port: int, counter: list[int], tool: str, arguments_factory, count: int, warmup: int = 5) -> list[int]:
    for i in range(warmup):
        counter[0] += 1
        call(port, counter[0], tool, arguments_factory(-(i + 1)))
    samples: list[int] = []
    for i in range(count):
        counter[0] += 1
        start = time.perf_counter_ns()
        call(port, counter[0], tool, arguments_factory(i))
        samples.append(time.perf_counter_ns() - start)
    return samples


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--port", type=int, default=43873)
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error(f"binary does not exist: {binary}")
    require_free_port(args.port)

    write_count = 30 if args.quick else 120
    read_count = 20 if args.quick else 80
    started = datetime.now(timezone.utc)
    with tempfile.TemporaryDirectory(prefix="mootx01-product-bench-") as data_dir:
        env = os.environ.copy()
        env["MOOTX01_DATA_DIR"] = data_dir
        subprocess.run([str(binary), "db", "create", "benchmark"], env=env, check=True, capture_output=True, text=True)
        daemon_start = time.perf_counter_ns()
        daemon = subprocess.Popen(
            [str(binary), "serve", "--db", "benchmark", "--http", str(args.port)],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True,
        )
        try:
            wait_for_port(args.port, daemon)
            startup_ns = time.perf_counter_ns() - daemon_start
            counter = [0]
            measurements: dict[str, dict[str, object]] = {}
            measurements["estate_ping"] = summary(measured_calls(args.port, counter, "moot_estate_ping", lambda _: {}, read_count))
            measurements["file_memory_impatient"] = summary(measured_calls(
                args.port, counter, "moot_file_memory",
                lambda i: {
                    "content": f"Benchmark memory {i}: graph algorithms, deterministic retrieval, matrix scoring, and durable local evidence.",
                    "location": "benchmark/performance", "impatient": True,
                }, write_count, warmup=1,
            ))
            search_terms = ["graph algorithms", "deterministic retrieval", "matrix scoring", "durable evidence"]
            measurements["memory_search_relevance"] = summary(measured_calls(
                args.port, counter, "moot_memory_search",
                lambda i: {"query": search_terms[i % len(search_terms)], "limit": 10, "ordering": "byRelevanceDesc"},
                read_count,
            ))
            measurements["recall_precise"] = summary(measured_calls(
                args.port, counter, "moot_recall_precise",
                lambda i: {"query": f"Benchmark memory {i % write_count} graph algorithms", "limit": 10, "pool": 30},
                read_count,
            ))
            measurements["estate_status"] = summary(measured_calls(args.port, counter, "moot_estate_status", lambda _: {}, read_count))
        finally:
            daemon.send_signal(signal.SIGTERM)
            try:
                daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait(timeout=5)

    version = subprocess.run([str(binary), "--version"], capture_output=True, text=True, check=True).stdout.strip()
    git_sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    report = {
        "schema_version": "product-1",
        "date": started.date().isoformat(),
        "generated_at": started.isoformat().replace("+00:00", "Z"),
        "git_sha": git_sha,
        "binary": str(binary),
        "binary_version": version,
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "isolation": "temporary estate; resident loopback HTTP; deleted after run",
        "dataset": {"measured_writes": write_count, "warmup_writes": 1},
        "daemon_startup_ns": startup_ns,
        "platform": {
            "system": platform.system(), "release": platform.release(),
            "machine": platform.machine(), "processor": platform.processor(),
            "python": platform.python_version(),
        },
        "quick_mode": args.quick,
        "measurements": measurements,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
