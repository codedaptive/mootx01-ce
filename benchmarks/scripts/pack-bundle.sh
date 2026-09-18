#!/usr/bin/env bash
# pack-bundle.sh — assemble a self-contained benchmark bundle for M4 MacBook Airs
#
# Run from the repo root or anywhere:
#   BENCH_WORK_ROOT=/external/path bash benchmarks/scripts/pack-bundle.sh
#
# Produces a zip below BENCH_WORK_ROOT/bundles.
# Requires: `make binaries` and `make fetch` from benchmarks/.

set -euo pipefail

# Resolve immutable source and mutable work independently.
BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="$(cd "$BENCH/.." && pwd -P)"
: "${BENCH_WORK_ROOT:?BENCH_WORK_ROOT is required; invoke through make or set it explicitly}"
BENCH_WORK_ROOT="$(python3 "$BENCH/scripts/work-root.py" prepare --repo "$R" --work "$BENCH_WORK_ROOT")"
MOOT_BIN="$BENCH_WORK_ROOT/build/product-swift/release/mootx01"
BENCH_BIN="$BENCH_WORK_ROOT/build/harness-swift/release/mcp-benchmarker"
FIXTURES="$BENCH_WORK_ROOT/fixtures"

OUT_DIR="$BENCH_WORK_ROOT/bundles"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
case "$OUT_DIR/" in
  "$BENCH_WORK_ROOT/"*) ;;
  *) echo "REFUSING: --out-dir must remain under BENCH_WORK_ROOT ($BENCH_WORK_ROOT)" >&2; exit 2 ;;
esac

DATE=$(date +%Y%m%d)
BUNDLE_NAME="mootx01-bench-${DATE}"
BUNDLE="$OUT_DIR/$BUNDLE_NAME"
ZIP="$OUT_DIR/${BUNDLE_NAME}.zip"
HEAD=$(git -C "$R" rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo "=== mootx01 benchmark bundle packer ==="
echo "Repo HEAD:  $HEAD"
echo "Bundle:     $BUNDLE"
echo "Output zip: $ZIP"
echo ""

# ── Pre-flight ────────────────────────────────────────────────────────────────
err=0
require_exec() { [[ -x "$1" ]] || { echo "MISSING/not-executable: $1"; err=1; }; }
require_file() { [[ -f "$1" ]] || { echo "MISSING: $1"; err=1; }; }
require_dir()  { [[ -d "$1" ]] || { echo "MISSING dir: $1"; err=1; }; }

require_exec "$MOOT_BIN"
require_exec "$BENCH_BIN"
require_file "$FIXTURES/longmemeval/data/longmemeval_m_cleaned.json"
require_file "$FIXTURES/longmemeval/data/longmemeval_oracle.json"
require_dir  "$FIXTURES/membench/MemData/FirstAgent"
require_file "$FIXTURES/locomo/data/locomo10.json"

[[ -d "$FIXTURES/membench/MemData/ThirdAgent" ]] || \
  echo "WARNING: ThirdAgent fixture missing — membench-third leg will be skipped on Airs."

[[ $err -ne 0 ]] && { echo "Fix errors above before bundling."; exit 1; }

MINOS=$(otool -l "$MOOT_BIN" 2>/dev/null | awk '/minos/{print $2; exit}')
echo "mootx01 minos: $MINOS  (Airs must be on macOS 26+)"
echo ""

# ── Assemble ──────────────────────────────────────────────────────────────────
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/bin"
mkdir -p "$BUNDLE/fixtures/longmemeval/data"
mkdir -p "$BUNDLE/fixtures/locomo/data"
mkdir -p "$BUNDLE/results"
mkdir -p "$BUNDLE/estate-cache"

# ── Drift-gate receipt ────────────────────────────────────────────────────────
#
# The harness refuses to run with the estate cache ENABLED unless the cache dir
# carries a drift-gate receipt proving CorpusKit's counts-store invariants were
# checked against the source the binary was built from (see benchmarks/Makefile,
# target drift-gate).
#
# Today's bundle legs pass no --estate-cache flag, which defaults to "off", so
# the gate is exempt and nothing here is load-bearing. That is luck, not design:
# the first leg that adds --estate-cache reuse would refuse on every machine,
# because a bundle ships no kit tree to gate against.
#
# So the receipt is packed WITH the bundle. It is evidence that travels: the
# gate ran here, against the source this binary was built from, and the bundle
# carries the proof to wherever it is unpacked. A bundle whose source never
# passed the gate cannot produce one.
GATE_RECEIPT="$BENCH_WORK_ROOT/estate-cache/.drift-gate-stamp"
if [[ -f "$GATE_RECEIPT" ]]; then
  cp "$GATE_RECEIPT" "$BUNDLE/estate-cache/.drift-gate-stamp"
  echo "Packed drift-gate receipt: $(sed -n 1p "$GATE_RECEIPT") (kit $(sed -n 2p "$GATE_RECEIPT" | cut -c1-12))"
else
  echo "REFUSING to pack: no drift-gate receipt at $GATE_RECEIPT." >&2
  echo "Run 'make drift-gate' in benchmarks/ before packing a bundle — a bundle" >&2
  echo "without one cannot enable the estate cache on the target machine." >&2
  exit 1
fi

echo "Copying binaries..."
cp "$MOOT_BIN"  "$BUNDLE/bin/mootx01"
cp "$BENCH_BIN" "$BUNDLE/bin/mcp-benchmarker"
chmod +x "$BUNDLE/bin/"*

# SwiftPM resource bundles. A target that declares resources loads them from a
# `<Package>_<Target>.bundle` sitting NEXT TO the executable, so an executable
# copied on its own dies the first time it touches one. mootx01 traps with
# "unable to find bundle named LatticeLib_LatticeLib" on its first `serve` —
# after --version answers normally, which is why a bundle can look fine and
# still be unable to run a single leg.
#
# Copied by glob rather than by name: a target that gains resources later must
# not silently reintroduce this.
echo "Copying resource bundles..."
moot_bundles=$(dirname "$MOOT_BIN")
bench_bundles=$(dirname "$BENCH_BIN")
shopt -s nullglob
for b in "$moot_bundles"/*.bundle "$bench_bundles"/*.bundle; do
  ditto "$b" "$BUNDLE/bin/$(basename "$b")"
done
shopt -u nullglob
copied=$(find "$BUNDLE/bin" -maxdepth 1 -name '*.bundle' | wc -l | tr -d ' ')
echo "  $copied resource bundle(s) copied"
[[ "$copied" -eq 0 ]] && { echo "ERROR: no resource bundles found next to the binaries — the bundle would trap on first serve."; exit 1; }

echo "Copying fixtures..."
cp "$FIXTURES/longmemeval/data/longmemeval_m_cleaned.json" "$BUNDLE/fixtures/longmemeval/data/"
cp "$FIXTURES/longmemeval/data/longmemeval_oracle.json"    "$BUNDLE/fixtures/longmemeval/data/"
ditto "$FIXTURES/membench/MemData" "$BUNDLE/fixtures/membench/MemData"
cp "$FIXTURES/locomo/data/locomo10.json" "$BUNDLE/fixtures/locomo/data/"

# ── run.sh ────────────────────────────────────────────────────────────────────
echo "Writing run.sh..."
cat > "$BUNDLE/run.sh" << 'RUNEOF'
#!/usr/bin/env bash
# run.sh — benchmark runner for the mootx01-bench bundle
#
# Usage:
#   ./run.sh --all
#   ./run.sh membench-first lme-m lme-oracle locomo-connected gauntlet
#
# The script backgrounds itself automatically.
# Results land in ./results/<leg>/
# When done: ./collect.sh packages everything into a zip.

set -uo pipefail

BUNDLE="$(cd "$(dirname "$0")" && pwd)"
LOGFILE="$BUNDLE/run-$(hostname -s).log"

# Self-background: relaunch with nohup if not already running in the background
if [[ -z "${_MBR_BG:-}" ]]; then
  _MBR_BG=1 nohup "$0" "$@" >> "$LOGFILE" 2>&1 &
  BG_PID=$!
  echo ""
  echo "Benchmark running in background (PID $BG_PID)"
  echo "Log:  $LOGFILE"
  echo "Follow progress: tail -f $LOGFILE"
  echo "When done, run: ./collect.sh"
  echo ""
  exit 0
fi

MOOT="$BUNDLE/bin/mootx01"
BENCH="$BUNDLE/bin/mcp-benchmarker"
FIXTURES="$BUNDLE/fixtures"
RESULTS="$BUNDLE/results"
SEED=20260725
SEED_PATH=batch

# ── Pre-flight ────────────────────────────────────────────────────────────────
ok=1
[[ -x "$MOOT"  ]] || { echo "MISSING: $MOOT";  ok=0; }
[[ -x "$BENCH" ]] || { echo "MISSING: $BENCH"; ok=0; }
OS_VER=$(sw_vers -productVersion 2>/dev/null || echo "0")
OS_MAJOR=$(echo "$OS_VER" | cut -d. -f1)
[[ "$OS_MAJOR" -ge 26 ]] || { echo "macOS 26+ required (this: $OS_VER)"; ok=0; }
[[ $ok -eq 1 ]] || { echo "Aborting."; exit 1; }

echo "=== mootx01 benchmark runner ==="
echo "Host:    $(hostname -s)"
echo "macOS:   $OS_VER"
echo "Date:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Binary:  $("$MOOT" --version 2>/dev/null || echo unknown)"
echo ""

# ── Apple Intelligence pre-flight ─────────────────────────────────────────────
# mootx01 uses Apple miniLLM (on-device FoundationModels) to generate one-line
# subjects for every memory record. On machines without Apple Intelligence
# configured, the rider is disabled and subjects fall back to deterministic
# rule-based generation. Separately, on unconfigured machines mootx01 has been
# observed to hang on its first tool call -- this check surfaces that before a
# leg wastes hours on a run that will time out.
#
# Outcome codes: 0=AI available+working  1=AI unavailable but mootx01 runs
#                2=mootx01 hung (no response within 45s)
_preflight_apple_intelligence() {
  local SCRATCH SEED SLOG PY RC
  SCRATCH=$(mktemp -d)
  SEED=$(mktemp /tmp/mbs_XXXXXX.json)
  SLOG=$(mktemp /tmp/mbs_err_XXXXXX.log)
  PY=$(mktemp /tmp/mbs_XXXXXX.py)

  # Minimal valid v1 seed (format_version is integer, not string)
  printf '{"format_version":1,"name":"preflight","records":[%s,%s],"facts":[],"tunnels":[]}\n' \
    '{"id":"pa1","content":"Benchmark preflight record one.","room":"preflight","subject":"Benchmark preflight record one.","event_time":"2026-01-01T00:00:00Z"}' \
    '{"id":"pa2","content":"Benchmark preflight record two.","room":"preflight","subject":"Benchmark preflight record two.","event_time":"2026-01-02T00:00:00Z"}' \
    > "$SEED"

  cat > "$PY" << 'SCRIPTEOF'
import subprocess, json, sys, threading, select
moot,scratch,seed_path,slog = sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
proc = subprocess.Popen(
    ["env","MOOTX01_VAULT=1",moot,"serve","--db",scratch],
    stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
lines=[]
def drain():
    for l in proc.stderr: lines.append(l.decode().rstrip())
threading.Thread(target=drain,daemon=True).start()
def send(m): proc.stdin.write((json.dumps(m)+"\n").encode()); proc.stdin.flush()
try:
    send({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"pf","version":"1"}}})
    if not select.select([proc.stdout],[],[],20)[0]: proc.kill(); raise TimeoutError
    proc.stdout.readline()
    send({"jsonrpc":"2.0","method":"notifications/initialized","params":{}})
    send({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"moot_json_import","arguments":{"path":seed_path}}})
    if not select.select([proc.stdout],[],[],30)[0]: proc.kill(); raise TimeoutError
    proc.stdout.readline()
    proc.stdin.close(); proc.wait(timeout=5)
    with open(slog,"w") as f: f.write("\n".join(lines))
    sys.exit(0 if any("subject rider enabled" in l for l in lines) else 1)
except TimeoutError:
    try: proc.kill()
    except: pass
    with open(slog,"w") as f: f.write("\n".join(lines))
    sys.exit(2)
except Exception:
    try: proc.kill()
    except: pass
    sys.exit(2)
SCRIPTEOF

  /usr/bin/python3 "$PY" "$MOOT" "$SCRATCH" "$SEED" "$SLOG" 2>/dev/null
  RC=$?
  rm -rf "$SCRATCH" "$SEED" "$PY" "$SLOG"
  return $RC
}

echo "Checking Apple Intelligence (up to 45s)..."
_preflight_apple_intelligence
_PF_RC=$?

# When running in background (nohup self-relaunch), /dev/tty is unavailable
# so prompts are skipped and the safe default is applied automatically.
_INTERACTIVE=1
[[ -n "${_MBR_BG:-}" ]] && _INTERACTIVE=0
[[ ! -e /dev/tty   ]] && _INTERACTIVE=0

case $_PF_RC in
  0)
    echo "  OK -- Apple Intelligence available, subject rider active."
    ;;
  1)
    echo "  WARNING -- mootx01 responded but Apple Intelligence is not set up."
    echo "  Subjects will use deterministic rule-based generation only."
    echo "  (Enable: System Settings -> Apple Intelligence & Siri)"
    if [[ $_INTERACTIVE -eq 1 ]]; then
      echo ""
      echo -n "  Continue without Apple Intelligence rider? [Y/n] "
      read -r _ANS </dev/tty
      [[ -z "$_ANS" || "$_ANS" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    else
      echo "  Running unattended -- continuing with rider disabled."
    fi
    export MOOTX01_SUBJECT_RIDER=0
    ;;
  2)
    echo "  WARNING -- mootx01 did not respond to a tool call within 45 seconds."
    echo "  This may indicate Apple Intelligence is not configured."
    echo "  Continuing with MOOTX01_SUBJECT_RIDER=0; each leg will attempt to"
    echo "  run and will fail with its timeout if mootx01 still does not respond."
    if [[ $_INTERACTIVE -eq 1 ]]; then
      echo ""
      echo "  To abort instead, enable Apple Intelligence in"
      echo "  System Settings -> Apple Intelligence & Siri, then re-run."
      echo -n "  Continue anyway? [Y/n] "
      read -r _ANS </dev/tty
      [[ -z "$_ANS" || "$_ANS" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    else
      echo "  Running unattended -- continuing regardless."
    fi
    export MOOTX01_SUBJECT_RIDER=0
    ;;
esac
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────
run_leg() {
  local name="$1"; shift
  local out="$RESULTS/$name"
  mkdir -p "$out"
  echo ""
  echo "── [$name] start $(date -u +%H:%M:%SZ) ──"
  local t=$SECONDS
  caffeinate -dis "$@" > "$out/stdout.log" 2> "$out/stderr.log"
  local rc=$?; local elapsed=$(( SECONDS - t ))
  echo "$rc" > "$out/exit_code"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$out/finished_at"
  [[ $rc -eq 0 ]] && echo "── [$name] OK ${elapsed}s" \
                   || echo "── [$name] FAILED exit=$rc ${elapsed}s — see $out/stderr.log"
}

skip_leg() {
  local name="$1" reason="$2"
  echo "── [$name] SKIPPED — $reason"
  mkdir -p "$RESULTS/$name"
  echo "skipped: $reason" > "$RESULTS/$name/skipped"
}

# ── Legs ──────────────────────────────────────────────────────────────────────
do_membench_first() {
  [[ -d "$FIXTURES/membench/MemData/FirstAgent" ]] \
    || { skip_leg membench-first "FirstAgent fixture missing"; return; }
  run_leg membench-first \
    "$BENCH" membench \
      --mootx01-binary "$MOOT" \
      --data-dir "$FIXTURES/membench/MemData" \
      --agent FirstAgent \
      --seed $SEED --seed-path $SEED_PATH \
      --estate-mode unencrypted \
      --out "$RESULTS/membench-first"
}

do_membench_third() {
  # ThirdAgent uses a different schema (multiple-choice QA, flat message objects,
  # no sessions) and is not yet supported by this benchmarker version.
  skip_leg membench-third "ThirdAgent schema not yet supported (multiple-choice format)"
  return
  [[ -d "$FIXTURES/membench/MemData/ThirdAgent" ]] \
    || { skip_leg membench-third "ThirdAgent fixture missing"; return; }
  run_leg membench-third \
    "$BENCH" membench \
      --mootx01-binary "$MOOT" \
      --data-dir "$FIXTURES/membench/MemData" \
      --agent ThirdAgent \
      --seed $SEED --seed-path $SEED_PATH \
      --estate-mode unencrypted \
      --out "$RESULTS/membench-third"
}

do_lme_m() {
  [[ -f "$FIXTURES/longmemeval/data/longmemeval_m_cleaned.json" ]] \
    || { skip_leg lme-m "fixture missing"; return; }
  run_leg lme-m \
    "$BENCH" longmemeval \
      --mootx01-binary "$MOOT" \
      --data-dir "$FIXTURES/longmemeval/data" \
      --variant m \
      --seed $SEED --seed-path $SEED_PATH \
      --estate-mode unencrypted \
      --dump-judge-inputs "$RESULTS/lme-m/judge-inputs.jsonl" \
      --out "$RESULTS/lme-m"
}

do_lme_oracle() {
  [[ -f "$FIXTURES/longmemeval/data/longmemeval_oracle.json" ]] \
    || { skip_leg lme-oracle "fixture missing"; return; }
  run_leg lme-oracle \
    "$BENCH" longmemeval \
      --mootx01-binary "$MOOT" \
      --data-dir "$FIXTURES/longmemeval/data" \
      --variant oracle \
      --seed $SEED --seed-path $SEED_PATH \
      --estate-mode unencrypted \
      --dump-judge-inputs "$RESULTS/lme-oracle/judge-inputs.jsonl" \
      --out "$RESULTS/lme-oracle"
}

do_locomo_connected() {
  [[ -f "$FIXTURES/locomo/data/locomo10.json" ]] \
    || { skip_leg locomo-connected "fixture missing"; return; }
  run_leg locomo-connected \
    "$BENCH" locomo \
      --mootx01-binary "$MOOT" \
      --data-file "$FIXTURES/locomo/data/locomo10.json" \
      --strategy connected \
      --seed $SEED --seed-path $SEED_PATH \
      --estate-mode unencrypted \
      --out "$RESULTS/locomo-connected"
}

do_gauntlet() {
  local corpus="$RESULTS/gauntlet-corpus"
  echo "── [gauntlet-corpus] generating..."
  "$BENCH" gauntlet-corpus \
    --seed $SEED \
    --out "$corpus" \
    > "$RESULTS/gauntlet-corpus.log" 2>&1
  [[ -n "$(ls -A "$corpus" 2>/dev/null)" ]] \
    || { skip_leg gauntlet "corpus generation failed"; return; }

  # Dynamic config — points at the bundle binary, ephemeral estate
  local tmp="/tmp/gauntlet-bench-$$"
  local cfg="$RESULTS/gauntlet-mootx01-config.json"
  cat > "$cfg" << CFGEOF
{
  "source": {
    "name": "mootx01-bundle",
    "transport": { "stdio": { "command": "MOOTX01_SUBJECT_RIDER=0 ${MOOT} serve --db ${tmp}-src" } },
    "verbMap": { "write": "moot_file_memory", "query": "moot_memory_search",
                 "constantArgs": {}, "resultFormat": { "kind": "mootText" } },
    "role": "source"
  },
  "target": {
    "name": "mootx01-bundle-target-placeholder",
    "transport": { "stdio": { "command": "MOOTX01_SUBJECT_RIDER=0 ${MOOT} serve --db ${tmp}-tgt" } },
    "verbMap": { "write": "moot_file_memory", "query": "moot_memory_search",
                 "constantArgs": {}, "resultFormat": { "kind": "mootText" } },
    "role": "target"
  }
}
CFGEOF

  run_leg gauntlet \
    "$BENCH" gauntlet \
      --config "$cfg" \
      --corpus "$corpus" \
      --run-label "gauntlet-moot-v3-seed${SEED}" \
      --seed-path $SEED_PATH \
      --out "$RESULTS/gauntlet"
  rm -rf "${tmp}-src" 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────────
ALL_LEGS=(membench-first membench-third lme-m lme-oracle locomo-connected gauntlet)
LEGS_RAN=""

run_named() {
  local leg="$1"
  [[ " $LEGS_RAN " == *" $leg "* ]] && return
  LEGS_RAN="$LEGS_RAN $leg"
  case "$leg" in
    membench-first)   do_membench_first ;;
    membench-third)   do_membench_third ;;
    lme-m)            do_lme_m ;;
    lme-oracle)       do_lme_oracle ;;
    locomo-connected) do_locomo_connected ;;
    gauntlet)         do_gauntlet ;;
    *) echo "Unknown leg: $leg. Available: ${ALL_LEGS[*]}"; exit 1 ;;
  esac
}

if [[ $# -eq 0 ]]; then
  echo "Usage: ./run.sh [--all | leg1 leg2 ...]"
  echo "Legs:  ${ALL_LEGS[*]}"
  exit 0
fi

[[ "$1" == "--all" ]] && for leg in "${ALL_LEGS[@]}"; do run_named "$leg"; done \
                      || for leg in "$@"; do run_named "$leg"; done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== summary ==="
for d in "$RESULTS"/*/; do
  leg="$(basename "$d")"
  if   [[ -f "$d/skipped"   ]]; then echo "  SKIPPED  $leg"
  elif [[ -f "$d/exit_code" ]]; then
    rc=$(cat "$d/exit_code")
    [[ "$rc" == "0" ]] && echo "  OK       $leg" || echo "  FAILED   $leg  (exit $rc)"
  fi
done
echo ""
echo "Run ./collect.sh to package results for retrieval."
RUNEOF
chmod +x "$BUNDLE/run.sh"

# ── collect.sh ────────────────────────────────────────────────────────────────
cat > "$BUNDLE/collect.sh" << 'COLEOF'
#!/usr/bin/env bash
BUNDLE="$(cd "$(dirname "$0")" && pwd)"
HOST=$(hostname -s)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$BUNDLE/${HOST}-${STAMP}.zip"
cd "$BUNDLE"
zip -r "$OUT" results/
echo ""
echo "Results zip: $OUT"
COLEOF
chmod +x "$BUNDLE/collect.sh"

# ── README ────────────────────────────────────────────────────────────────────
THIRD_STATUS=$([[ -d "$FIXTURES/membench/MemData/ThirdAgent" ]] && echo "included" || echo "NOT INCLUDED")
cat > "$BUNDLE/README.txt" << READMEEOF
mootx01 Benchmark Bundle — $(date +%Y-%m-%d)  HEAD: $HEAD
=======================================================

REQUIREMENTS
  macOS 26+  (binary minos 26.0)
  Apple Silicon arm64

QUICK START (SSH)
  1. Copy zip to Air and unzip
  2. ssh into Air
  3. cd mootx01-bench-${DATE}
  4. ./run.sh --all
     (backgrounds itself; follow with: tail -f run-<hostname>.log)
  5. ./collect.sh when done
  6. Copy the results zip back

SUGGESTED SPLIT (two Airs)
  Air 1:  ./run.sh membench-first lme-m gauntlet
  Air 2:  ./run.sh membench-third lme-oracle locomo-connected

LEGS
  membench-first    MemBench FirstAgent  (~45 min)
  membench-third    MemBench ThirdAgent  (~45 min)
  lme-m             LongMemEval m        (~37 min)
  lme-oracle        LongMemEval oracle   (~12 min)
  locomo-connected  LoCoMo connected     (~7 min)
  gauntlet          Gauntlet moot-only   (~10 min)

JUDGE BATCH (on main machine after collecting results)
  mcp-benchmarker judge-batch \
    --inputs <Air-results>/lme-m/judge-inputs.jsonl \
    --judge-cmd '<your-judge-command>' \
    --out .

FIXTURES
  longmemeval m:    included (2.5 GB)
  longmemeval oracle: included (15 MB)
  locomo:           included (2.7 MB)
  membench FirstAgent: included
  membench ThirdAgent: ${THIRD_STATUS}

VERSION
  mootx01:    $("$MOOT_BIN" --version 2>/dev/null || echo unknown)
  HEAD:       $HEAD
  Built:      $(date +%Y-%m-%d)
READMEEOF

# ── Sizes + zip ───────────────────────────────────────────────────────────────
echo ""
echo "Bundle contents:"
du -sh "$BUNDLE/bin/"* "$BUNDLE/fixtures/"*
echo ""; echo "Total:"; du -sh "$BUNDLE"
echo ""
echo "Zipping..."
rm -f "$ZIP"
ditto -c -k --sequesterRsrc "$BUNDLE" "$ZIP"
echo ""
echo "=== DONE ==="
echo "  $ZIP"
echo "  $(du -sh "$ZIP" | cut -f1)"
