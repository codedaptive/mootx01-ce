#!/usr/bin/env python3
"""Settle a Rust-lane estate whose distillation debt is pending.

Repair tool for estates seeded by pre-fix Rust binaries (before the
serve gained the on_encoded distillation rider): their encode drained
under the old binary, so no encode work remains for the rider to ride
and the existing debt clears only via one explicit sweep. This script
opens the estate, sweeps, and waits for both gating lanes to read
idle. Usage: kick_rust_distill.py <estate-data-dir>
"""

import json
import os
import subprocess
import sys
import time

BINARY = os.environ.get(
    "MOOTX01_RUST_BINARY",
    os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..",
        "apps", "mootx01", "rust", "target", "release", "mootx01")))


def main():
    data_dir = os.path.abspath(sys.argv[1])
    p = subprocess.Popen([BINARY, "serve", "--db", data_dir], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True, bufsize=1)
    seq = [0]

    def send(method, params=None):
        seq[0] += 1
        req = {"jsonrpc": "2.0", "id": seq[0], "method": method}
        if params is not None:
            req["params"] = params
        p.stdin.write(json.dumps(req) + "\n")
        p.stdin.flush()
        while True:
            line = p.stdout.readline()
            if not line:
                sys.exit("serve closed stdout")
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == seq[0]:
                return msg

    def text(resp):
        return "".join(b.get("text", "")
                       for b in resp["result"]["content"])

    send("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                        "clientInfo": {"name": "kick-distill", "version": "1"}})
    p.stdin.write(json.dumps(
        {"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    p.stdin.flush()

    print(f"[{data_dir}] distill sweep starting", flush=True)
    out = send("tools/call", {"name": "moot_distill", "arguments": {}})
    print(text(out).splitlines()[0], flush=True)

    consecutive = 0
    deadline = time.time() + int(os.environ.get("KICK_TIMEOUT", "7200"))
    while time.time() < deadline:
        t = text(send("tools/call",
                      {"name": "moot_drain_status", "arguments": {}}))
        gating = [l for l in t.splitlines() if l.strip().startswith(
            ("corpus_encode:", "distillation:"))]
        if gating and all("idle" in l for l in gating):
            consecutive += 1
            if consecutive >= 3:
                print(f"[{data_dir}] SETTLED", flush=True)
                p.terminate()
                return
        else:
            consecutive = 0
        time.sleep(5)
    print(f"[{data_dir}] TIMEOUT waiting for idle", flush=True)
    p.terminate()
    sys.exit(1)


if __name__ == "__main__":
    main()
