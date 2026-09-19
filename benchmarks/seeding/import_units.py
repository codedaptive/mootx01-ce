#!/usr/bin/env python3
"""Import the spike's unit seed files into fresh estates and prove the
subject wrapper rides through moot_json_import. Prints per-estate drawer
counts, a subject spot-check, and on-disk sizes.

Uses the same bounded MCP stdio pattern as the benchmark harness.
"""

import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

import artifact_layout as layout

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_ap = argparse.ArgumentParser()
_ap.add_argument("--set", default="out-lme-s",
                 help="output-set dir under this folder (e.g. out-locomo)")
_ap.add_argument("--limit", type=int, default=0,
                 help="import at most N unit files (0 = all)")
_ap.add_argument("--file", default="",
                 help="import this single seed file instead of units/ "
                      "(estate lands next to it, named after its stem)")
_ap.add_argument("--estates-dir", required=True,
                 help="external directory in which to build estates")
_ap.add_argument("--estate-name", default="",
                 help="estate directory name for a --file build (default: "
                      "the seed filename stem). The run-book layout names "
                      "Form-2 estates by dataset: WING_ROOT/<port>/<ds>/")
_args = _ap.parse_args()
SEEDING_ROOT = os.path.realpath(os.getcwd())
UNITS_DIR = os.path.join(SEEDING_ROOT, _args.set, "units")
ESTATES_DIR = os.path.realpath(_args.estates_dir)
def cow_copy(src, dst):
    """Copy-on-write file copy (standing order 2026-08-28): APFS clone
    via `cp -c`, falling back to a byte copy when cloning is impossible
    (cross-volume, non-APFS). The temp dir callers pass sits BESIDE the
    source (same volume) so the clone path is actually reachable."""
    import shutil, subprocess
    r = subprocess.run(["cp", "-c", src, dst], capture_output=True)
    if r.returncode != 0:
        shutil.copy2(src, dst)


BINARY = os.environ.get("MOOTX01_BINARY")
# Poll cadence of the two wait loops below, in milliseconds. The benchmark
# recipes set it low (with MOOTX01_BRAIN_TICK_MS on the daemon) because a
# one-record unit otherwise pays a fixed ~30 s of tick and poll latency;
# unset, the loops keep their original 2 s and 5 s cadences.
_POLL_MS = os.environ.get("MOOTX01_BENCH_POLL_MS", "")


def poll_seconds(default: float) -> float:
    """The wait-loop cadence: MOOTX01_BENCH_POLL_MS when set, else `default`."""
    try:
        return max(0.05, int(_POLL_MS) / 1000.0) if _POLL_MS else default
    except ValueError:
        return default
if not BINARY:
    _ap.error("MOOTX01_BINARY must name the product binary built under BENCH_WORK_ROOT")

# Minimum LocusKit schema version an estate must carry to be READY.
# Schema 20 adds fact_extractor_models and the extractor/projection columns
# on kg_facts; an estate at 19 is pre-facts and must be rebuilt via
# `mootx01 upgrade` — SQL surgery on a populated estate is prohibited.
_REQUIRED_SCHEMA_VERSION = 20
_SCHEMA_KIT_ID = "LocusKit"

# Benchmark estates run with these estate preferences OFF (ruling 2026-09-14):
# every preference ships ON in the product and there is no create-time
# override, so the harness creates the estate and flips them through the
# product CLI before the first import. fact_extraction stays ON by default
# because the fact-search validator lane scores extracted facts. The
# contradiction lane turns contradiction_sweep back ON per estate at measure
# time. A build may turn more keys off through MOOTX01_BENCH_PREFERENCES_OFF_EXTRA
# (comma-separated): the Rust artifact build turns fact_extraction off (ruling
# 2026-09-16) because the feature is experimental, the Rust extractor runs on
# the CPU, and one Swift artifact set is enough to judge the lane's value.
BENCHMARK_PREFERENCES_OFF = (
    "consolidation", "contradiction_sweep", "cross_encoder_routing",
    "maintenance", "adaptive_recall")


def benchmark_preferences_off():
    extra = tuple(k.strip() for k in os.environ.get("MOOTX01_BENCH_PREFERENCES_OFF_EXTRA", "").split(",") if k.strip())
    return BENCHMARK_PREFERENCES_OFF + extra


class MCPClient:
    def __init__(self, data_dir):
        self._id = 0
        # Benchmark estates contain exactly the imported corpus: charter
        # hint drawers are outside every benchmark spec and occupy
        # candidate-pool slots in recall (2026-08-24 ruling).
        # A transient catalog record (--db <dir>) is non-federating by the
        # product default (federate flipped to false in the catalog core,
        # 2026-09-05): no Ed25519 keypair, no login-keychain entry, no
        # manifest public key — the 53k-entry pollution (2026-08-28) is
        # prevented by record kind, not by an environment variable.
        env = dict(os.environ)
        # The estate directory is a transient catalog record (--db <dir>):
        # plaintext by rule, identity in memory, never a catalog entry.
        self._proc = subprocess.Popen(
            [BINARY, "serve", "--db", data_dir], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, env=env, text=True, bufsize=1)

    def _send(self, method, params=None):
        self._id += 1
        req = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            req["params"] = params
        self._proc.stdin.write(json.dumps(req) + "\n")
        self._proc.stdin.flush()
        while True:
            line = self._proc.stdout.readline()
            if not line:
                raise RuntimeError("server closed stdout")
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == self._id:
                return msg

    def initialize(self):
        self._send("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "import_units", "version": "1.0"}})
        self._proc.stdin.write(json.dumps(
            {"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self._proc.stdin.flush()

    def call(self, name, arguments):
        resp = self._send("tools/call", {"name": name, "arguments": arguments})
        content = resp.get("result", {}).get("content", [])
        return "\n".join(b.get("text", "") for b in content
                         if b.get("type") == "text")

    def call_checked(self, name, arguments):
        """The tool's text and whether the surface marked the call an error
        (a v2 refusal answers with isError and one message line)."""
        resp = self._send("tools/call", {"name": name, "arguments": arguments})
        result = resp.get("result", {})
        text = "\n".join(b.get("text", "") for b in result.get("content", [])
                         if b.get("type") == "text")
        return text, bool(result.get("isError")) or "error" in resp

    def call_structured(self, name, arguments):
        """The tool's structuredContent.data object (v2 surface); {} when absent.
        The human text of a v2 tool is a one-line summary, so lane-level state
        is read from here, never parsed out of the text."""
        resp = self._send("tools/call", {"name": name, "arguments": arguments})
        structured = resp.get("result", {}).get("structuredContent") or {}
        return structured.get("data") or {}

    def terminate(self):
        try:
            self._proc.terminate()
            self._proc.wait(timeout=5)
        except Exception:
            pass


def set_benchmark_preferences(data_dir):
    """Create the estate through a short serve, then flip every
    BENCHMARK_PREFERENCES_OFF key off through the product CLI, then read them
    back and fail loud on any key that does not read `off`. Runs before the
    import serve starts: the ruled order is create, flip, import."""
    # Materialise the estate first: `mootx01 serve --db <dir>` creates estate.sqlite on
    # first open in both ports, so the preference writes below land on a real estate
    # (the Rust CLI refuses to write preferences into an empty directory).
    probe = MCPClient(data_dir)
    try:
        probe.initialize()
    finally:
        probe.terminate()
    keys = benchmark_preferences_off()
    for key in keys:
        subprocess.run([BINARY, "preference", "set", key, "off", "--db", data_dir],
                       check=True, capture_output=True, text=True)
    listing = subprocess.run([BINARY, "preference", "list", "--db", data_dir],
                             check=True, capture_output=True, text=True).stdout
    values = dict(line.split(None, 1) for line in listing.splitlines() if line.strip())
    wrong = [k for k in keys if values.get(k, "").strip() != "off"]
    if wrong:
        raise RuntimeError(f"preferences not off after set: {wrong}; list output:\n{listing}")
    return values


def _encoded_chunk_count(data_dir):
    """Encoded-chunk evidence read straight from the estate file (read-only):
    the v2 drain rows carry state and pending only, so the evidence gate that
    used to parse `encoded_chunks: N` out of the lane text reads the
    corpus_index_state row count instead."""
    path = os.path.join(data_dir, "estate.sqlite")
    if not os.path.exists(path):
        return 0
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        try:
            return con.execute("SELECT COUNT(*) FROM corpus_index_state").fetchone()[0]
        finally:
            con.close()
    except sqlite3.Error:
        return 0


def wait_drain(client, label, timeout=600, data_dir=None):
    """Idle when corpus_encode and distillation report idle AND at least
    one chunk has been encoded. The encoded_chunks>0 requirement is the
    evidence gate against the false-idle window right after import, when
    the lanes report idle because the encode worker has not yet picked up
    the queue — gating on evidence instead of a flat warm-up sleep keeps
    small units at a seconds-scale floor. The dreaming and
    subject_backfill lanes legitimately keep working — they are not part
    of the import barrier."""
    start = time.time()
    consecutive = 0
    while time.time() - start < timeout:
        drains = client.call_structured("moot_drain_status", {}).get("drains") or []
        # v2 reports lanes as structured rows: name, state, pending, detail.
        # The import barrier gates on corpus_encode (and distillation when
        # present); row-debt lanes (span_encode, subject_backfill,
        # fact_extraction) are paid by dreaming and are not part of it.
        gating = [d for d in drains if d.get("name") in ("corpus_encode", "distillation")]
        encoded = _encoded_chunk_count(data_dir) if data_dir else 0
        if gating and encoded > 0 and all(d.get("state") == "idle" and int(d.get("pending") or 0) == 0 for d in gating):
            consecutive += 1
            if consecutive >= 3:
                return True
        else:
            consecutive = 0
        time.sleep(poll_seconds(2.0))
    print(f"  [{label}] WARNING: drain not idle after {timeout}s")
    return False


def estate_state(estate_dir, expected_records):
    """Classify an estate directory for the idempotent build contract:

      absent      no estate database, OR migrations table present but no
                  LocusKit row AND zero drawers (fresh-install abort —
                  self-healing; import path re-creates the estate)
      schema-old  LocusKit migrations row present AND below
                  _REQUIRED_SCHEMA_VERSION — must be rebuilt via
                  `mootx01 upgrade`; SQL surgery is prohibited
      resume      rows complete, encode coverage short — resume encoding
      span-short  rows and BM25 encode complete; active-encoder span
                  coverage short (see layout.SPAN_COVERED_SQL) — start the
                  resident HTTP serve to drain
      verified    rows, encode, AND span coverage complete — nothing to do
      interrupted rows short of the seed (strict-append import cannot
                  resume a partial import; delete and re-import), OR
                  migrations table present with no LocusKit row AND drawers
                  present (structurally inconsistent; delete and re-import)

    Counts are read from a checkpointed COPY (db + wal) so a crashed
    serve's un-checkpointed WAL is included and the original is never
    touched. Returns (state, drawers, indexed).
    """
    db = os.path.join(estate_dir, "estate.sqlite")
    if not os.path.exists(db):
        db = os.path.join(estate_dir, "databases", "default", "estate.sqlite")
    if not os.path.exists(db):
        return ("absent", 0, 0)
    # Clone dir beside the source (same volume) so cp -c can clonefile.
    tmpd = tempfile.mkdtemp(prefix=".tmp-verify-", dir=os.path.dirname(db))
    try:
        # db + wal ONLY — never the -shm. A crash-recovered estate's stale
        # shm carries a wal-index that can mask every unfolded WAL frame,
        # making a fully-imported estate read as zero rows ("absent") and
        # mis-branching the idempotent contract (observed 2026-08-29:
        # post-panic twins re-imported instead of resuming). Without an
        # shm, SQLite rebuilds the wal-index from the WAL file itself and
        # the counts include every frame.
        for ext in ("", "-wal"):
            if os.path.exists(db + ext):
                cow_copy(db + ext, os.path.join(tmpd, "c.db" + ext))
        con = sqlite3.connect(os.path.join(tmpd, "c.db"))
        con.execute("PRAGMA wal_checkpoint")
        # Schema version check: an estate at an old schema version is neither
        # resumable nor verified. `mootx01 upgrade` is the only migration
        # vehicle; SQL surgery on a populated estate is prohibited.
        row_absent = False
        schema_ver = None
        try:
            schema_ver = con.execute(
                "SELECT version FROM _storagekit_migrations "
                "WHERE kit_id = ?", (_SCHEMA_KIT_ID,)).fetchone()
        except sqlite3.OperationalError:
            # _storagekit_migrations does not exist.  applyMigrations creates
            # this table as its very first SQL statement, so its absence means
            # the database was never initialised — drawers was not created
            # either.  Probe sqlite_master to confirm: if drawers is absent too,
            # the estate is a clean never-initialised file and must be classified
            # absent so the import path re-creates it.  If drawers somehow
            # exists without a migrations table the estate is structurally
            # inconsistent; let the drawers-count path below resolve it.
            tbl = con.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='drawers'").fetchone()
            if tbl is None:
                con.close()
                return ("absent", 0, 0)
            row_absent = True
        if row_absent or schema_ver is None:
            # The LocusKit migrations row is absent (table missing or table
            # present with no row).  Count drawers to choose the right state.
            drawers_now = con.execute(
                "SELECT COUNT(*) FROM drawers").fetchone()[0]
            con.close()
            if drawers_now == 0:
                # No drawers and no schema stamp: a fresh-install abort.
                # Classify as 'absent' so the import path re-creates the
                # estate — self-healing, no operator action required.
                return ("absent", 0, 0)
            # Drawers present but no schema stamp: structurally inconsistent.
            # An estate cannot accumulate drawer rows without applyMigrations
            # completing (which stamps the version row).  'absent' would
            # trigger a strict-append re-import against existing rows (unsafe).
            # 'schema-old' would tell the operator to run 'mootx01 upgrade',
            # which requires a valid starting version and cannot fix this.
            # 'interrupted' triggers a delete-and-reimport cycle — the only
            # clean resolution.
            return ("interrupted", drawers_now, 0)
        if schema_ver[0] < _REQUIRED_SCHEMA_VERSION:
            con.close()
            return ("schema-old", schema_ver[0], 0)
        drawers = con.execute("SELECT COUNT(*) FROM drawers").fetchone()[0]
        indexed = con.execute(
            "SELECT COUNT(*) FROM corpus_index_state").fetchone()[0]
        # Span coverage: an estate whose resident span encoder did not finish
        # has full rows and full BM25 encode but short span coverage.
        # Without this check it reads as "verified" and the driver skips the
        # resident span phase while the smoke gate fails the estate strict —
        # no path converges it.
        # layout.SPAN_COVERED_SQL requires kind=2 and the current serving
        # generation so this check agrees exactly with wait_span_drain()'s
        # polling loop.
        n_eligible = con.execute(
            "SELECT COUNT(*) FROM drawers "
            "WHERE tombstonedAt IS NULL AND content != ''").fetchone()[0]
        n_covered = con.execute(layout.SPAN_COVERED_SQL).fetchone()[0]
        con.close()
    except sqlite3.Error:
        # An unreadable database is neither resumable nor verified.
        return ("interrupted", -1, -1)
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)
    if drawers == 0:
        return ("absent", drawers, indexed)
    if drawers < expected_records:
        return ("interrupted", drawers, indexed)
    if indexed < drawers:
        return ("resume", drawers, indexed)
    if n_covered < n_eligible:
        return ("span-short", drawers, indexed)
    return ("verified", drawers, indexed)


# OWNED_GUARDIAN: parent-death-aware process-group guardian. Spawned as a
# new session leader wrapping the serve child, it forwards SIGTERM to the
# whole group, then escalates to SIGKILL. On parent death (getppid change)
# it executes the same sequence so the serve never orphans on driver exit.
_OWNED_GUARDIAN = r"""import os,signal,subprocess,sys,time
owner=int(sys.argv[1]); child=subprocess.Popen(sys.argv[2:])
def stop_group(*_):
 signal.signal(signal.SIGTERM,signal.SIG_IGN); signal.signal(signal.SIGINT,signal.SIG_IGN)
 deadline=time.monotonic()+1
 try: os.killpg(os.getpgrp(),signal.SIGTERM)
 except ProcessLookupError: pass
 try: child.wait(timeout=1)
 except subprocess.TimeoutExpired: pass
 time.sleep(max(0,deadline-time.monotonic()))
 os.killpg(os.getpgrp(),signal.SIGKILL)
signal.signal(signal.SIGTERM,stop_group); signal.signal(signal.SIGINT,stop_group)
while child.poll() is None:
 if os.getppid()!=owner: stop_group()
 time.sleep(.1)
while os.getppid()==owner: time.sleep(.1)
stop_group()
"""


def _spawn_owned(command, **kwargs):
    """Spawn command in a new process group with a parent-death guardian."""
    return subprocess.Popen(
        [sys.executable, "-c", _OWNED_GUARDIAN, str(os.getpid()), *command],
        start_new_session=True, **kwargs)


def _stop_owned(process, timeout=10):
    """Terminate an owned process group: SIGTERM, wait, then SIGKILL.

    A group that is already gone (ProcessLookupError) or that the kernel
    will not let us signal as a group (PermissionError: a member has
    already been reaped or re-parented by the time the group is signalled;
    measured on a Rust unit serve whose drains had settled, 2026-09-19) is
    not an error: the guardian itself is still ours, so it is signalled
    directly and the stop is bounded either way. Stopping an owned process
    must never abort the build."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except (ProcessLookupError, PermissionError):
            try:
                process.send_signal(sig)
            except (ProcessLookupError, PermissionError):
                pass
        try:
            process.wait(timeout=timeout if sig == signal.SIGTERM else 5)
            return
        except subprocess.TimeoutExpired:
            continue


def _sha256_file(path):
    """Return the sha256 hex digest of the file at path."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _native_catalog_path():
    """Return the path to the live mootx01 estate catalog, or None."""
    # macOS: ~/Library/Application Support/com.mootx01.app/catalog.json
    # Linux: $XDG_DATA_HOME/mootx01/catalog.json
    xdg_env = os.environ.get("XDG_DATA_HOME")
    if xdg_env:
        return os.path.join(xdg_env, "mootx01", "catalog.json")
    home = os.path.expanduser("~")
    darwin_path = os.path.join(
        home, "Library", "Application Support", "com.mootx01.app", "catalog.json")
    if os.path.exists(darwin_path):
        return darwin_path
    linux_path = os.path.join(home, ".local", "share", "mootx01", "catalog.json")
    if os.path.exists(linux_path):
        return linux_path
    return None


def _assert_encoder_model_slot(binary):
    """Assert the arctic-embed-s-w60 encoder model is staged in the share slot
    beside the binary. The resolver checks vocab.txt sha256 at load time; a
    missing or wrong-platform directory causes the serve to run lexical-only
    and write no span rows. Failing here is cheaper than 985 seconds of
    span 0/272 with no diagnostic output (Adams gate, 2026-09-09).

    Exits RED naming the missing slot if vocab.txt is absent or its sha256
    does not match the pinned constant for arctic-embed-s-w60.
    """
    exe_dir = os.path.dirname(os.path.realpath(binary))
    model_slot = os.path.normpath(
        os.path.join(exe_dir, "..", "share", "mootx01", "models", "arctic-embed-s-w60"))
    vocab = os.path.join(model_slot, "vocab.txt")
    # sha256(vocab.txt) for arctic-embed-s-w60 at HF revision e596f507…
    # Identical across Apple and Linux manifests (same source vocab file).
    # Defined in EncoderModelSeed.tokenizerHash.
    expected = "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"
    if not os.path.exists(vocab):
        sys.exit(
            f"RED: encoder model slot empty — span encode will not run.\n"
            f"  Expected vocab.txt at: {vocab}\n"
            f"  Stage the model: make moot-binary (Swift) or "
            f"make rust-moot-binary (Rust)")
    actual = _sha256_file(vocab)
    if actual != expected:
        sys.exit(
            f"RED: vocab.txt sha256 mismatch for arctic-embed-s-w60 "
            f"at {model_slot}.\n"
            f"  Expected: {expected}\n"
            f"  Got:      {actual}\n"
            f"  Wrong-platform layout? Re-stage: "
            f"make stage-encoder-model-swift or make stage-encoder-model-rust")


# Span wait stall window: RED when active-encoder coverage has not advanced
# for this long. It bounds a dead encoder, never the size of the estate.
SPAN_STALL_SECONDS = 600


def wait_span_drain(scratch, label, poll_interval=None):
    """Start a resident HTTP serve and poll SQLite until the active encoder
    covers every eligible drawer.

    The span encoder is resident-only: it does not run during a stdio import
    session. This phase starts the binary as an HTTP serve with XDG_DATA_HOME
    redirected to a scratch directory (preventing catalog registration), polls
    the estate database until active-encoder span coverage equals eligible
    drawers, then terminates the process group.

    Process lifecycle: spawned through _OWNED_GUARDIAN (new session, parent-
    death aware). Shutdown: SIGTERM the group, wait, SIGKILL if needed.
    stdout and stderr go to resident.stderr.log in the scratch dir.

    Drain wait: there is no budget on the work itself; the encoder pays
    every eligible drawer at its own rate (the Rust encoder is several
    times slower than the Swift one and the two ports build concurrently).
    The wait is RED only when coverage has not advanced for
    SPAN_STALL_SECONDS — the encoder never loaded, or the serve stopped
    paying — so a short estate is never left for the next pass and a
    slow estate is never failed for being large.
    """
    if poll_interval is None:
        poll_interval = poll_seconds(5.0)
    _assert_encoder_model_slot(BINARY)

    db = os.path.join(scratch, "estate.sqlite")
    if not os.path.exists(db):
        db = os.path.join(scratch, "databases", "default", "estate.sqlite")
    if not os.path.exists(db):
        sys.exit(f"[{label}] RED: no estate.sqlite for span drain")

    # Read the eligible-drawer count before spawning (the progress line
    # reports covered/eligible from the first poll).
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        n_eligible = con.execute(
            "SELECT COUNT(*) FROM drawers "
            "WHERE tombstonedAt IS NULL AND content != ''").fetchone()[0]
        con.close()
    except sqlite3.Error as exc:
        sys.exit(f"[{label}] RED: cannot read estate before span drain: {exc}")

    # Catalog integrity: record sha256 before the resident phase. Any change
    # means the transient estate registered in the product catalog.
    catalog_path = _native_catalog_path()
    catalog_before = None
    if catalog_path and os.path.isfile(catalog_path) and not os.path.islink(catalog_path):
        catalog_before = _sha256_file(catalog_path)

    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]

    # XDG redirect: isolate model/catalog writes from the live user catalog.
    xdg = os.path.join(scratch, ".span-xdg")
    os.makedirs(xdg, exist_ok=True)
    env = dict(os.environ)
    env["XDG_DATA_HOME"] = xdg
    env.pop("MOOTX01_FROZEN", None)
    env.pop("MOOTX01_HTTP_PORT", None)

    # Log resident stdout and stderr so serve-side errors (model load failure,
    # port conflict) are inspectable after the drain exits.
    log_path = os.path.join(scratch, "resident.stderr.log")
    log_file = open(log_path, "w", encoding="utf-8")

    proc = _spawn_owned(
        [BINARY, "serve", "--db", scratch, "--http", str(port)],
        stdin=subprocess.DEVNULL,
        stdout=log_file,
        stderr=log_file,
        env=env)

    covered = 0
    last_covered = 0
    last_progress_at = time.time()
    try:
        while time.time() - last_progress_at < SPAN_STALL_SECONDS:
            if proc.poll() is not None:
                log_file.flush()
                sys.exit(
                    f"[{label}] RED: span serve exited {proc.returncode}; "
                    f"inspect {log_path}")
            try:
                con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
                n_eligible = con.execute(
                    "SELECT COUNT(*) FROM drawers "
                    "WHERE tombstonedAt IS NULL AND content != ''").fetchone()[0]
                # layout.SPAN_COVERED_SQL: same predicate used by estate_state() —
                # kind=2 selects span vectors; generation matches the active
                # serving generation. Shared module constant so the two
                # check-points cannot drift.
                covered = con.execute(layout.SPAN_COVERED_SQL).fetchone()[0]
                con.close()
            except sqlite3.Error:
                time.sleep(poll_interval)
                continue
            if covered > last_covered:
                last_covered = covered
                last_progress_at = time.time()
            if covered >= n_eligible:
                print(f"  [{label}] span {covered}/{n_eligible} ...", flush=True)
                print(f"  [{label}] span coverage complete ({covered}/{n_eligible})",
                      flush=True)
                break
            print(f"  [{label}] span {covered}/{n_eligible} ...", flush=True)
            time.sleep(poll_interval)
        else:
            sys.exit(
                f"[{label}] RED: span coverage stalled for {SPAN_STALL_SECONDS}s "
                f"({covered}/{n_eligible}); inspect {log_path}")
    finally:
        log_file.close()
        _stop_owned(proc)

    # Catalog integrity: any change means the transient estate registered in
    # the product catalog despite the XDG redirect.
    if catalog_before is not None and catalog_path and os.path.isfile(catalog_path):
        catalog_after = _sha256_file(catalog_path)
        if catalog_after != catalog_before:
            sys.exit(
                f"[{label}] RED: resident phase changed the live estate catalog "
                f"(before={catalog_before[:12]}... after={catalog_after[:12]}...); "
                "the transient estate may have registered in the product catalog")


def du_mb(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            if f.startswith("seed-part"):
                continue
            total += os.path.getsize(os.path.join(root, f))
    return total / (1024 * 1024)


def main():
    global ESTATES_DIR
    if _args.file:
        unit_files = [os.path.abspath(_args.file)]
        ESTATES_DIR = os.path.join(
            os.path.dirname(unit_files[0]), "estates")
    else:
        unit_files = sorted(glob.glob(os.path.join(UNITS_DIR, "*.json")))
        if not unit_files:
            sys.exit(f"no unit files in {UNITS_DIR} — run the seeder first")
        if _args.limit:
            unit_files = unit_files[:_args.limit]
    if _args.estates_dir:
        ESTATES_DIR = os.path.abspath(_args.estates_dir)
    os.makedirs(ESTATES_DIR, exist_ok=True)
    total_mb = 0.0
    failed_estates = []
    for uf in unit_files:
        import_failed = False
        qid = os.path.splitext(os.path.basename(uf))[0]
        if _args.estate_name and _args.file:
            qid = _args.estate_name
        seed = json.load(open(uf))
        expect = len(seed["records"])
        probe = seed["records"][0]          # first record: known subject
        scratch = os.path.join(ESTATES_DIR, qid)
        os.makedirs(scratch, exist_ok=True)

        # Idempotent build contract (run book §5): the same command
        # converges an estate from any starting state. Absent imports;
        # rows-complete-but-encode-short resumes; converged verifies and
        # moves on. A row count short of the seed is an interrupted
        # import — strict-append cannot resume one — so it fails loud
        # and names the deletion instead of guessing.
        state, n0_rows, n0_idx = estate_state(scratch, expect)
        if state == "verified":
            print(f"{qid}: already converged ({n0_rows} rows, "
                  f"{n0_idx} indexed) — verified, nothing to do")
            continue
        if state == "schema-old":
            # n0_rows holds the found LocusKit schema version as an integer.
            sys.exit(
                f"{qid}: estate at {scratch} carries LocusKit schema "
                f"{n0_rows} but schema {_REQUIRED_SCHEMA_VERSION} is required. "
                "Run `mootx01 upgrade` to migrate the estate, then rerun the build. "
                "SQL surgery on a populated estate is prohibited.")
        if state == "interrupted":
            if n0_rows < 0:
                sys.exit(f"{qid}: estate at {scratch} is unreadable or "
                         "corrupt — delete the estate directory and rerun "
                         "the build.")
            elif n0_rows < expect:
                sys.exit(f"{qid}: estate at {scratch} has {n0_rows} of "
                         f"{expect} expected rows — strict-append cannot "
                         "resume a partial import. Delete the estate "
                         "directory and rerun the build.")
            else:
                sys.exit(f"{qid}: estate at {scratch} has {n0_rows} rows "
                         "but no schema version stamp — structurally "
                         "inconsistent. Delete the estate directory and "
                         "rerun the build.")
        resume = state == "resume"
        span_short = state == "span-short"
        if resume:
            print(f"{qid}: resuming encode ({n0_idx}/{n0_rows} indexed)")
        if span_short:
            print(f"{qid}: rows and encode complete — resuming the "
                  "resident span-drain phase")

        # Windowed import: one moot_json_import carries at most ~125k rows.
        # Split oversized seed files into parts, keeping facts with the part
        # holding their record and tunnels with the part holding both ends.
        # Part files are only consumed by a fresh import — resume and
        # span-short builds skip the split.
        WINDOW = 120_000
        import_paths = [uf]
        if expect > WINDOW and not resume and not span_short:
            recs = seed["records"]
            id_part = {}
            parts = []
            for i in range(0, len(recs), WINDOW):
                part_recs = recs[i:i + WINDOW]
                for r in part_recs:
                    id_part[r["id"]] = len(parts)
                parts.append({"format_version": 1,
                              "name": f"{seed['name']}-part{len(parts)}",
                              "records": part_recs})
            dropped = 0
            for f in seed.get("facts", []):
                p = id_part.get(f["record_id"])
                if p is None:
                    dropped += 1
                    continue
                parts[p].setdefault("facts", []).append(f)
            for t in seed.get("tunnels", []):
                pa, pb = id_part.get(t["from"]), id_part.get(t["to"])
                if pa is not None and pa == pb:
                    parts[pa].setdefault("tunnels", []).append(t)
                else:
                    dropped += 1
            if dropped:
                print(f"  [{qid}] WARNING: {dropped} cross-part "
                      "facts/tunnels dropped by windowing")
            import_paths = []
            for i, part in enumerate(parts):
                pth = os.path.join(scratch, f"seed-part{i}.json")
                with open(pth, "w") as fh:
                    json.dump(part, fh, ensure_ascii=False)
                import_paths.append(pth)

        t0 = time.time()
        if not resume and not span_short:
            prefs = set_benchmark_preferences(scratch)
            print(f"{qid}: preferences " + " ".join(f"{k}={v}" for k, v in prefs.items()))
        client = MCPClient(scratch)
        try:
            client.initialize()
            out = "resume" if (resume or span_short) else ""
            if not resume and not span_short:
                # Join part outputs with a newline: a part's output does
                # not end in one, so bare += fuses part N's trailing
                # id_map JSON line with part N+1's first line and the
                # merge below dies on "Extra data" (observed 2026-08-29,
                # rust complete part-1 at char 10,793,827).
                outs = []
                for pth in import_paths:
                    text, refused = client.call_checked(
                        "moot_json_import", {"path": pth, "return_id_map": True})
                    outs.append(text)
                    if refused:
                        # A refused import leaves nothing to drain: skip every
                        # wait below and let the row count fail the estate.
                        import_failed = True
                        print(f"  [{qid}] import REFUSED: {text[:200]}", flush=True)
                        break
                out = "\n".join(outs)
                # Persist the raw import output — it carries the id_map
                # (seed record id -> drawer UUID) the scorers need.
                with open(os.path.join(scratch, "import-output.txt"),
                          "w") as fh:
                    fh.write(out)
                # Distill the merged id-map.json the artifact-recall measure
                # lane requires (its loader hard-errors without it). Each
                # import part returns its own {"id_map": {...}} block; the
                # merge is safe because seed record ids are unique across
                # parts. Emitted at build time so measure never needs the
                # recover_idmap.py backfill for new estates.
                # Every v2 result also carries its whole serialized envelope
                # as a trailing text block (ARIA_MCP_SPEC 5.4.0), so a line
                # can hold the map at the top level (the opted-in id_map
                # block) or under data (the envelope); either is the same
                # map, and a line with neither is not an id map.
                id_map = {}
                for line in out.splitlines():
                    line = line.strip()
                    if line.startswith("{") and '"id_map"' in line:
                        parsed = json.loads(line)
                        found = parsed.get("id_map")
                        if found is None:
                            found = (parsed.get("data") or {}).get("id_map")
                        if isinstance(found, dict):
                            id_map.update(found)
                with open(os.path.join(scratch, "id-map.json"), "w") as fh:
                    json.dump(id_map, fh)
            drain_timeout = int(os.environ.get("IMPORT_DRAIN_TIMEOUT", "2400"))
            if import_failed:
                resume = span_short = False
            if resume:
                # Resume = drive the encode backfill to full coverage. A
                # reopened estate has NO persisted encode backlog (the
                # 2026-08-28 twin stall: waiting on drain alone left every
                # twin at one 10k pass's worth of coverage). moot_reindex
                # sweeps the whole missing set and backfills it to full
                # coverage on a background worker (auto-continuing 10k
                # passes internally); the driver's job is one call, then
                # poll moot_rebuild_status until the backfill span closes.
                print(f"  [{qid}] {client.call('moot_reindex', {})}",
                      flush=True)
            if not span_short and not import_failed:
                # Both fresh imports and resumes converge through the SAME
                # background backfill (moot_json_import defers its encode
                # tail to a detached task; moot_reindex is that task for
                # resumes) — the rebuild span is open from the moment the
                # import/reindex call returns, so poll it closed before the
                # drain gate. Without this the driver raced the retrain
                # tail: the encode queue reads idle while the basis
                # retrains, and a driver that exits then kills the serve
                # mid-retrain.
                start = time.time()
                while time.time() - start < drain_timeout:
                    # v2 reports the rebuild state in structured content; the
                    # text is a one-line summary that never says idle.
                    if client.call_structured("moot_rebuild_status", {}).get("state") == "idle":
                        break
                    # The rebuild of a one-record unit is done long before a
                    # 10 s sleep returns; this poll was 20 of the 24 s a unit
                    # cost (profiled 2026-09-19).
                    time.sleep(poll_seconds(10.0))
                else:
                    print(f"  [{qid}] WARNING: reindex backfill timed out "
                          f"after {drain_timeout}s — proceeding to the drain "
                          "gate; the post-run verifier reports the estate "
                          "INCOMPLETE if coverage is short")
            # A span-short build has full encode coverage and does no encode
            # work in this serve session, so the drain gate's
            # encoded_chunks>0 evidence requirement can never be met —
            # skip straight to the span drain below.
            if not span_short and not import_failed:
                wait_drain(client, qid, timeout=drain_timeout, data_dir=scratch)
            # Prove the subject rode through: search for the persona name.
            listing = ""
            hit = client.call("moot_memory_search",
                              {"query": probe["subject"], "limit": 5})
        finally:
            client.terminate()
        # Resident span-drain phase: the active encoder runs only in a resident
        # HTTP serve — not during stdio import. Start an HTTP serve on the
        # estate with XDG_DATA_HOME redirected locally (so the transient estate
        # never registers in the product catalog), poll until the active encoder
        # covers every eligible drawer (layout.SPAN_COVERED_SQL), then terminate.
        if not import_failed:
            wait_span_drain(scratch, qid)
        secs = time.time() - t0
        mb = du_mb(scratch)
        total_mb += mb
        # Authoritative success test: drawer rows in the estate. Skip-charters
        # imports carry exactly the record count; require at least that.
        # The Swift binary lays the estate at the data-dir root; the Rust
        # binary at databases/default/ — resolve whichever exists.
        db = os.path.join(scratch, "estate.sqlite")
        if not os.path.exists(db):
            db = os.path.join(scratch, "databases", "default", "estate.sqlite")
        tmpd = tempfile.mkdtemp(prefix=".tmp-verify-", dir=os.path.dirname(db))
        cow_copy(db, os.path.join(tmpd, "c.db"))
        # The WAL can vanish between the existence check and the copy: the
        # serve that just stopped checkpoints on its last close and SQLite
        # deletes the file. A vanished WAL is already in the main file.
        wal = db + "-wal"
        if os.path.exists(wal):
            try:
                cow_copy(wal, os.path.join(tmpd, "c.db-wal"))
            except FileNotFoundError:
                pass
        con = sqlite3.connect(os.path.join(tmpd, "c.db"))
        con.execute("PRAGMA wal_checkpoint")
        n_rows = con.execute("SELECT COUNT(*) FROM drawers").fetchone()[0]
        # Encode coverage is part of DONE: an estate whose serve died
        # mid-encode has full drawer rows but a nearly empty index, and a
        # drawer-count check alone reads that as converged (the twin-fleet
        # miss of 2026-08-28). Converged = every drawer indexed.
        n_indexed = con.execute(
            "SELECT COUNT(*) FROM corpus_index_state").fetchone()[0]
        # Span coverage uses layout.SPAN_COVERED_SQL (requires kind=2 and the
        # current serving generation) so this report agrees exactly with
        # wait_span_drain()'s polling predicate and cannot drift from it.
        n_eligible = con.execute(
            "SELECT COUNT(*) FROM drawers "
            "WHERE tombstonedAt IS NULL AND content != ''").fetchone()[0]
        n_covered = con.execute(layout.SPAN_COVERED_SQL).fetchone()[0]
        con.close()
        shutil.rmtree(tmpd, ignore_errors=True)
        ok = n_rows >= expect
        if not ok:
            failed_estates.append(qid)
        encode_ok = n_indexed >= n_rows
        span_ok = n_covered >= n_eligible
        imported = (f"confirmed ({n_rows} rows)" if ok
                    else f"FAILED rows={n_rows}/{expect}: {out[:160]}")
        subject_ok = probe["subject"] in listing or probe["subject"] in hit
        print(f"{qid}: {expect} records, import {imported}, "
              f"encode {'COMPLETE' if encode_ok else f'INCOMPLETE {n_indexed}/{n_rows}'}, "
              f"span {'COMPLETE' if span_ok else f'INCOMPLETE {n_covered}/{n_eligible}'}, "
              f"{secs:.0f}s, {mb:.1f} MB, subject ride-through: "
              f"{'YES' if subject_ok else 'NO'}")
        if not subject_ok:
            print("  listing head:", listing[:300].replace("\n", " | "))
    print(f"\ntotal for {len(unit_files)} estates: {total_mb:.1f} MB "
          f"(mean {total_mb/len(unit_files):.1f} MB/estate)")
    if failed_estates:
        sys.exit(f"import FAILED for {len(failed_estates)} estate(s): "
                 f"{' '.join(failed_estates)}")


if __name__ == "__main__":
    main()
