#!/usr/bin/env python3
"""Fire every ARIA tool once against a cloned estate and record what came back.

    catalog_exercise.py --binary <mootx01> --estate <settled estate dir> \
        --calls catalog-calls.json --out <report dir> [--record]

The release-qualification station (harness Makefile `release-qualification`):
after the smokes and the one-unit proof, this is the pass that says nothing in
the catalog is broken. It clones the estate (never serves the source), opens a
stdio serve on the clone, asks `tools/list`, and then fires each entry of the
call table in order, capturing ids from earlier answers into placeholders for
later ones. Every call is recorded: tool, arguments, wall latency, isError,
the refusal code when there is one, and the SHA-256 and byte count of the
text (no content leaves the estate). A tool in the list but not in the table,
or in the table but not in the list, fails the pass. In pinned mode each entry
must match its `expect` (`ok`, or `refusal:<code>`); `--record` writes the
observed outcomes into the report without judging them, for building the
table against a new estate shape.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import select
import shutil
import subprocess
import sys
import time

PLACEHOLDER = re.compile(r"\$\{([A-Z0-9_]+)\}")


class Serve:
    def __init__(self, binary: str, estate: pathlib.Path, log: pathlib.Path, timeout: float):
        self.timeout = timeout
        self.p = subprocess.Popen([binary, "serve", "--db", str(estate)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=open(log, "w"), text=True, bufsize=1)
        self.n = 0
        self.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                    "clientInfo": {"name": "catalog_exercise", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.p.stdin.flush()

    def request(self, method: str, params: dict) -> dict:
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            # A serve that answers nothing must not hang the pass: wait on
            # the pipe with the remaining budget before reading a line.
            ready, _, _ = select.select([self.p.stdout], [], [], max(0.0, deadline - time.monotonic()))
            if not ready:
                break
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("serve closed")
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == self.n:
                return msg
        raise RuntimeError(f"{method} timed out after {self.timeout}s")

    def close(self) -> None:
        try:
            self.p.stdin.close()
            self.p.terminate()
            self.p.wait(timeout=15)
        except Exception:
            self.p.kill()


def clone(source: pathlib.Path, dest: pathlib.Path) -> pathlib.Path:
    """The estate's files, never its runtime pid marker; cp -c clones on APFS."""
    dest.mkdir(parents=True, exist_ok=True)
    for entry in source.iterdir():
        if entry.name == "estate.pid" or entry.name.startswith("harness-"):
            continue
        target = dest / entry.name
        if entry.is_dir():
            subprocess.run(["cp", "-c", "-R", str(entry), str(target)], check=False) \
                if sys.platform == "darwin" else shutil.copytree(entry, target)
        else:
            if subprocess.run(["cp", "-c", str(entry), str(target)], capture_output=True).returncode != 0:
                shutil.copy2(entry, target)
    return dest


def dig(value, path: str):
    """`data.results[0].id` into a JSON value; None when absent."""
    for part in path.split("."):
        m = re.fullmatch(r"([^\[]+)(?:\[(\d+)\])?", part)
        if not m:
            return None
        key, index = m.group(1), m.group(2)
        if isinstance(value, dict):
            value = value.get(key)
        else:
            return None
        if index is not None:
            if not isinstance(value, list) or len(value) <= int(index):
                return None
            value = value[int(index)]
    return value


def substitute(value, names: dict):
    if isinstance(value, str):
        def repl(m):
            if m.group(1) not in names:
                raise KeyError(m.group(1))
            return str(names[m.group(1)])
        whole = PLACEHOLDER.fullmatch(value)
        if whole:
            if whole.group(1) not in names:
                raise KeyError(whole.group(1))
            return names[whole.group(1)]
        return PLACEHOLDER.sub(repl, value)
    if isinstance(value, list):
        return [substitute(v, names) for v in value]
    if isinstance(value, dict):
        return {k: substitute(v, names) for k, v in value.items()}
    return value


def outcome_of(resp: dict) -> tuple[str, str, int, str]:
    """(outcome, text sha256, byte count, code). outcome is `ok`, `refusal:<code>`
    or `error:<jsonrpc code>`."""
    if "error" in resp:
        err = resp["error"]
        text = json.dumps(err, sort_keys=True)
        return f"error:{err.get('code')}", hashlib.sha256(text.encode()).hexdigest(), len(text.encode()), str(err.get("code"))
    result = resp.get("result") or {}
    text = "\n".join(b.get("text", "") for b in result.get("content", []) if b.get("type") == "text")
    digest = hashlib.sha256(text.encode()).hexdigest()
    if result.get("isError"):
        code = (((result.get("structuredContent") or {}).get("error") or {}).get("code")) or "unknown"
        return f"refusal:{code}", digest, len(text.encode()), code
    return "ok", digest, len(text.encode()), ""


def run(a) -> int:
    calls = json.loads(pathlib.Path(a.calls).read_text())
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    # The manifest names the estate and the serve checks that name against
    # the directory, so the clone keeps the source directory's name.
    source = pathlib.Path(a.estate)
    estate = clone(source, out / "estate" / source.name)
    scratch = out / "scratch"
    scratch.mkdir(exist_ok=True)
    names = {"SCRATCH": str(scratch), "ESTATE": str(estate)}
    serve = Serve(a.binary, estate, out / "serve.stderr.log", a.timeout)
    rows, failures = [], []
    try:
        listed = {t["name"] for t in serve.request("tools/list", {})["result"]["tools"]}
        tabled = [c["tool"] for c in calls]
        for missing in sorted(listed - set(tabled)):
            failures.append(f"tool in tools/list but not in the call table: {missing}")
        for extra in sorted(set(tabled) - listed):
            failures.append(f"tool in the call table but not in tools/list: {extra}")
        for entry in calls:
            tool = entry["tool"]
            expect = entry.get("expect", "ok")
            if isinstance(expect, dict):
                # A per-port expectation records a known divergence between
                # the ports; the note beside it says which is the contract.
                expect = expect.get(a.port, "ok")
            row = {"tool": tool, "id": entry.get("id", tool), "expect": expect}
            try:
                arguments = substitute(entry.get("arguments", {}), names)
            except KeyError as exc:
                row.update(outcome="skipped", reason=f"unresolved placeholder {exc}")
                rows.append(row)
                if not a.record:
                    failures.append(f"{row['id']}: unresolved placeholder {exc}")
                continue
            row["arguments"] = arguments
            t0 = time.monotonic()
            try:
                resp = serve.request("tools/call", {"name": tool, "arguments": arguments})
            except RuntimeError as exc:
                # A serve that dies under a call is the finding of the pass;
                # record it, reopen the serve on the same clone (its state is on
                # disk) and keep firing so one crash does not hide the next.
                row.update(outcome=f"crash:{exc}", ms=int((time.monotonic() - t0) * 1000))
                rows.append(row)
                failures.append(f"{row['id']}: serve crashed ({exc}); see serve.stderr.log")
                serve.close()
                serve = Serve(a.binary, estate, out / f"serve.stderr.{len(rows)}.log", a.timeout)
                continue
            outcome, digest, nbytes, code = outcome_of(resp)
            data = ((resp.get("result") or {}).get("structuredContent") or {}).get("data") or {}
            row.update(outcome=outcome, ms=int((time.monotonic() - t0) * 1000), sha256=digest, bytes=nbytes)
            if a.record:
                # Building the table needs to see what came back; the pinned
                # pass records digests only.
                text = "\n".join(b.get("text", "") for b in (resp.get("result") or {}).get("content", []) if b.get("type") == "text")
                row["text_head"] = (text or json.dumps(resp.get("error")))[:200]
                row["data_keys"] = sorted(data.keys()) if isinstance(data, dict) else []
            captured = {}
            for name, path in (entry.get("capture") or {}).items():
                value = dig(data, path)
                if value is not None:
                    names[name] = value
                    captured[name] = value
            if captured:
                row["captured"] = captured
            rows.append(row)
            if not a.record and outcome != row["expect"]:
                failures.append(f"{row['id']}: expected {row['expect']}, got {outcome}")
    finally:
        serve.close()
    report = {"binary": a.binary, "binary_sha256": hashlib.sha256(pathlib.Path(a.binary).read_bytes()).hexdigest(),
              "source_estate": str(a.estate), "mode": "record" if a.record else "pinned",
              "tools_listed": len(listed) if "listed" in dir() else 0, "calls": rows, "failures": failures}
    (out / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    counts = {}
    for r in rows:
        counts[r["outcome"].split(":")[0]] = counts.get(r["outcome"].split(":")[0], 0) + 1
    print(f"[catalog] {len(rows)} calls: {counts}; {len(failures)} failure(s); report {out / 'report.json'}")
    for f in failures:
        print(f"[catalog] FAIL {f}")
    if a.record:
        return 0
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", required=True)
    ap.add_argument("--estate", required=True)
    ap.add_argument("--calls", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=float, default=300.0)
    ap.add_argument("--port", default="swift", choices=("swift", "rust"),
                    help="which port's expectation applies where the table records one per port")
    ap.add_argument("--record", action="store_true", help="record outcomes without judging them")
    return run(ap.parse_args(argv[1:]))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
