#!/usr/bin/env python3
"""probe_fixture_lanes.py — per-lane diagnosis of LME fixture questions.

Ingests the haystack for one or more questions from fixtures/lme_fixture_rg.json
against a fresh scratch mootx01 estate (plaintext, no-encrypt marker), waits on
the drain barrier, then queries with explain:true and moot_recall_precise.
Reports per-lane ranks of the answer drawers to surface where recall fails.

This is the maintained version of the scratchpad probe developed during the
11X-RECALL-GAP-01 root-cause investigation. The 5-question fixture encodes:
  3 failing on 1.1.x (at least 2 temporal-reasoning)
  2 passing on 1.1.x

Usage:
  python3 scripts/probe_fixture_lanes.py <question_id> [<question_id> ...]
  python3 scripts/probe_fixture_lanes.py --all
  python3 scripts/probe_fixture_lanes.py --all-failing
  python3 scripts/probe_fixture_lanes.py --all-passing

Options:
  --binary <path>   path to the mootx01 binary (auto-discovered if omitted)
  --no-precise      skip moot_recall_precise (faster, less detail)
  --limit N         ingest only the first N turns per question (for quick smoke runs)
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIXTURE_PATH = os.path.join(SCRIPT_DIR, "..", "fixtures", "lme_fixture_rg.json")


def discover_binary() -> str | None:
    """Return the path to the mootx01 binary, or None if not found."""
    # 1. Explicit env var.
    env_path = os.environ.get("MOOTX01_BINARY", "")
    if env_path:
        return env_path
    # 2. Known install location.
    installed = os.path.expanduser("~/.mootx01/bin/mootx01")
    if os.path.isfile(installed) and os.access(installed, os.X_OK):
        return installed
    # 3. Nearest 1.1.x debug build (relative to repo root).
    repo_root = os.path.join(SCRIPT_DIR, "..", "..", "..")
    candidates = [
        os.path.join(repo_root, "apps", "mootx01", ".build", "release", "mootx01"),
        os.path.join(repo_root, "apps", "mootx01", ".build", "debug", "mootx01"),
    ]
    for c in candidates:
        c = os.path.normpath(c)
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    # 4. PATH.
    try:
        result = subprocess.run(["which", "mootx01"], capture_output=True, text=True)
        path = result.stdout.strip()
        if path:
            return path
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# MCP stdio client (minimal JSON-RPC 2.0)
# ---------------------------------------------------------------------------

class MCPClient:
    """Minimal MCP JSON-RPC stdio client for probe use."""

    def __init__(self, binary: str, data_dir: str):
        self._id = 0
        env = dict(os.environ, MOOTX01_DATA_DIR=data_dir)
        self._proc = subprocess.Popen(
            [binary, "serve"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            text=True,
            bufsize=1,
        )

    def _next_id(self) -> int:
        self._id += 1
        return self._id

    def _send(self, method: str, params=None) -> dict:
        req_id = self._next_id()
        req: dict = {"jsonrpc": "2.0", "id": req_id, "method": method}
        if params is not None:
            req["params"] = params
        self._proc.stdin.write(json.dumps(req) + "\n")
        self._proc.stdin.flush()
        while True:
            line = self._proc.stdout.readline()
            if not line:
                raise RuntimeError("mootx01 server closed stdout unexpectedly")
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == req_id:
                return msg

    def initialize(self):
        self._send("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "probe_fixture_lanes", "version": "1.0"},
        })
        self._proc.stdin.write(
            json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"
        )
        self._proc.stdin.flush()

    def call_tool(self, name: str, arguments: dict) -> str:
        """Call a tool and return joined text content blocks."""
        resp = self._send("tools/call", {"name": name, "arguments": arguments})
        content = resp.get("result", {}).get("content", [])
        return "\n".join(b.get("text", "") for b in content if b.get("type") == "text")

    def terminate(self):
        try:
            self._proc.terminate()
            self._proc.wait(timeout=5)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Drain barrier
# ---------------------------------------------------------------------------

def wait_drain(client: MCPClient, label: str, timeout: int = 300):
    """Poll moot_drain_status until idle. Returns True on convergence."""
    start = time.time()
    no_lanes_count = 0
    while time.time() - start < timeout:
        out = client.call_tool("moot_drain_status", {})
        if "drains: none" in out:
            no_lanes_count += 1
            if no_lanes_count >= 4 and time.time() - start >= 2.0:
                print(f"  [{label}] drain: accepted no-lanes via grace window", file=sys.stderr)
                return True
        elif "draining" in out:
            no_lanes_count = 0
            print(f"  [{label}] drain: {out.strip()}", file=sys.stderr)
        elif "idle" in out:
            return True
        time.sleep(0.5)
    print(f"  [{label}] WARNING: drain did not converge in {timeout}s", file=sys.stderr)
    return False


# ---------------------------------------------------------------------------
# UUID extraction helpers
# ---------------------------------------------------------------------------

_UUID_RE = re.compile(r"([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})")


def extract_uuids(text: str) -> list[str]:
    return [m.lower() for m in _UUID_RE.findall(text)]


# ---------------------------------------------------------------------------
# Probe one question
# ---------------------------------------------------------------------------

def probe_question(qid: str, qdata: dict, binary: str, *, run_precise: bool = True, limit: int | None = None):
    """Ingest, drain, then search + recall_precise for one fixture question."""
    scratch = tempfile.mkdtemp(prefix="lme-probe-rg-")
    # Write no-encrypt marker so the estate is plaintext (no keychain contact).
    open(os.path.join(scratch, "no-encrypt"), "w").close()

    print(f"\n=== {qid} [{qdata['category']}] expect_fail_11x={qdata['expect_fail_11x']}")
    print(f"    question: {qdata['question'][:90]}")
    print(f"    answer:   {str(qdata['answer'])[:60]}")
    print(f"    answer_sids: {qdata['answer_sids']}")

    client = MCPClient(binary, scratch)
    try:
        client.initialize()

        # --- Ingest ---
        uuid_to_sid: dict[str, str] = {}
        answer_uuids: list[str] = []
        turns = qdata["turns"]
        if limit is not None:
            turns = turns[:limit]
        for t in turns:
            out = client.call_tool("moot_file_memory", {
                "content": f"{t['role']}: {t['content']}",
                "location": "benchmark/longmemeval",
            })
            m = re.search(r"filed memory ([0-9A-Fa-f-]{36})", out)
            if m:
                uid = m.group(1).lower()
                uuid_to_sid[uid] = t["sid"]
                if t["ans"]:
                    answer_uuids.append(uid)

        print(f"    ingested: {len(uuid_to_sid)} turns, {len(answer_uuids)} answer-turn UUIDs")

        # --- Drain ---
        wait_drain(client, qid)

        # --- moot_memory_search (fused, relevance, explain) ---
        out_search = client.call_tool("moot_memory_search", {
            "query": qdata["question"],
            "ordering": "byRelevanceDesc",
            "explain": True,
            "limit": 20,
        })
        uuids_search = extract_uuids(out_search)[:40]
        ans_ranks_search = [i + 1 for i, u in enumerate(uuids_search) if u in answer_uuids]
        top5_sids_search = [uuid_to_sid.get(u, "?") for u in uuids_search[:5]]
        disc_search = next((l for l in out_search.split("\n") if "discrimination" in l), "")
        prov_search = next((l for l in out_search.split("\n") if "recall_provenance" in l), "")
        print(f"[search+relevance] answer ranks: {ans_ranks_search or 'ABSENT'}")
        print(f"  top5 sids: {top5_sids_search}")
        if disc_search:
            print(f"  {disc_search.strip()}")
        if prov_search:
            print(f"  {prov_search.strip()}")

        # Explain block for the best-ranked answer turn (if any)
        if answer_uuids:
            blocks = out_search.split("\n\n")
            for uid in answer_uuids:
                for b in blocks:
                    if uid[:8].upper() in b.upper() or uid in b.lower():
                        print("  -- explain block for ANSWER drawer --")
                        print("  " + b[:500].replace("\n", "\n  "))
                        break
                else:
                    continue
                break

        # --- moot_recall_precise ---
        if run_precise:
            out_precise = client.call_tool("moot_recall_precise", {
                "query": qdata["question"],
                "limit": 20,
                "pool": 40,
            })
            uuids_precise = extract_uuids(out_precise)[:40]
            ans_ranks_precise = [i + 1 for i, u in enumerate(uuids_precise) if u in answer_uuids]
            top5_sids_precise = [uuid_to_sid.get(u, "?") for u in uuids_precise[:5]]
            print(f"[recall_precise   ] answer ranks: {ans_ranks_precise or 'ABSENT'}")
            print(f"  top5 sids: {top5_sids_precise}")

    finally:
        client.terminate()
        # Clean up scratch directory.
        import shutil
        try:
            shutil.rmtree(scratch)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    if not args or "--help" in args or "-h" in args:
        print(__doc__)
        sys.exit(0)

    # Load fixture.
    fixture_path = os.path.normpath(FIXTURE_PATH)
    if not os.path.isfile(fixture_path):
        print(f"ERROR: fixture not found at {fixture_path}", file=sys.stderr)
        sys.exit(1)
    with open(fixture_path) as f:
        fixture: dict = json.load(f)

    # Parse options.
    binary = None
    run_precise = True
    limit = None
    question_ids: list[str] = []

    i = 0
    while i < len(args):
        a = args[i]
        if a == "--binary" and i + 1 < len(args):
            binary = args[i + 1]
            i += 2
        elif a == "--no-precise":
            run_precise = False
            i += 1
        elif a == "--limit" and i + 1 < len(args):
            limit = int(args[i + 1])
            i += 2
        elif a == "--all":
            question_ids = list(fixture.keys())
            i += 1
        elif a == "--all-failing":
            question_ids = [qid for qid, v in fixture.items() if v.get("expect_fail_11x")]
            i += 1
        elif a == "--all-passing":
            question_ids = [qid for qid, v in fixture.items() if not v.get("expect_fail_11x")]
            i += 1
        elif not a.startswith("--"):
            question_ids.append(a)
            i += 1
        else:
            print(f"Unknown option: {a}", file=sys.stderr)
            sys.exit(1)

    if not question_ids:
        print("ERROR: no question IDs specified. Pass --all, --all-failing, or explicit IDs.", file=sys.stderr)
        print("Available IDs:", list(fixture.keys()), file=sys.stderr)
        sys.exit(1)

    # Discover binary if not specified.
    if binary is None:
        binary = discover_binary()
    if binary is None:
        print("ERROR: could not find mootx01 binary.", file=sys.stderr)
        print("Pass --binary <path> or set $MOOTX01_BINARY.", file=sys.stderr)
        sys.exit(1)
    print(f"binary: {binary}")
    print(f"fixture: {fixture_path}")
    print(f"questions: {question_ids}")
    if limit is not None:
        print(f"turn limit: {limit} per question")

    for qid in question_ids:
        if qid not in fixture:
            print(f"WARNING: {qid} not in fixture; skipping", file=sys.stderr)
            continue
        probe_question(qid, fixture[qid], binary, run_precise=run_precise, limit=limit)


if __name__ == "__main__":
    main()
