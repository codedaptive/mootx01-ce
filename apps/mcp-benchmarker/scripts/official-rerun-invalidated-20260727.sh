#!/usr/bin/env bash
# apps/mcp-benchmarker/scripts/official-rerun-invalidated-20260727.sh
#
# Invalidated-run replacement — 2026-07-27 (Bilby fix-fanout + fix-bench merge).
#
# The 20260726 official-rerun grid (40 runs) is partially invalidated:
#
#   1.1.x — ALL 18 drain + 2 impatient runs invalidated:
#     - fan-out not yet applied (CorpusContentEngine.drainContentQueueOnce was
#       single-threaded; stream/fix-fanout merged 2026-07-27).
#     - drain barrier used old heuristic (EncodeBarrier.swift searched for
#       ": draining" substring; parseDrainResponse shape parser applied via
#       cherry-pick of 4f2cb650 on 2026-07-27).
#     - Rust binary also used /Users/bob/.mootx01/bin/mootx01 (installed Jul 16)
#       instead of the develop-tree binary because the old benchmarker binary
#       did not support --mootx01-binary; rebuild restores correct targeting.
#
#   1.0.x — Rust runs only (4 of 20) invalidated:
#     - Rust binary used installed binary for the same --mootx01-binary reason.
#     - Swift drain barrier on 1.0.x ALSO used the old heuristic (fix-bench not
#       merged until 2026-07-27), but recall on drain runs was within normal
#       range and the old response format matched the heuristic reliably;
#       Swift drain re-run is deferred to the next full grid sweep.
#
# This replacement script re-runs only the invalidated cells:
#
#   1.1.x (8 runs, 1 run per cell):
#     1.1.x LME   Swift drain   r1  (~37 min)
#     1.1.x LoCoMo Swift drain  r1  (~ 7 min)
#     1.1.x LMEB  Swift drain   r1  (~ 4 min)
#     1.1.x LME   Rust  drain   r1  (~37 min)
#     1.1.x LoCoMo Rust  drain  r1  (~ 7 min)
#     1.1.x LMEB  Rust  drain   r1  (~ 4 min)
#     1.1.x LME   Swift impatient r1  (~37 min)  [+ hint-line grep]
#     1.1.x LME   Rust  impatient r1  (~37 min)  [+ hint-line grep]
#
#   1.0.x Rust only (4 runs, 1 run per cell):
#     1.0.x LME   Rust  drain   r1  (~37 min)
#     1.0.x LoCoMo Rust  drain  r1  (~ 7 min)
#     1.0.x LMEB  Rust  drain   r1  (~ 4 min)
#     1.0.x LME   Rust  impatient r1  (~37 min)  [+ hint-line grep]
#
# Run count: 12
# Estimated wall clock: ~255 min (~4h15m, sequential)
#   1.1.x Swift drain (LME+LoCoMo+LMEB): 37+7+4 = 48 min
#   1.1.x Rust drain  (LME+LoCoMo+LMEB): 37+7+4 = 48 min
#   1.1.x impatient   (Swift+Rust LME):  37+37  = 74 min
#   1.0.x Rust drain  (LME+LoCoMo+LMEB): 37+7+4 = 48 min
#   1.0.x Rust impatient (LME):           37    = 37 min
#   Total:                                        255 min
#
# Estate-cache: drain runs only (lme07 feature)
#   All drain cells use --estate-cache reuse --cache-dir <results>/estate-cache.
#   The cache key is (benchmark, variant, seed, barrier, mootx01_binary_fingerprint,
#   unit_id). Because all 1.1.x drain runs share the same MOOT binary and SEED:
#
#     Run 1 (Swift drain): COLD miss — estate ingest runs normally, snapshot saved.
#     Run 2 (Rust  drain): WARM hit  — estate restored from snapshot, ingest skipped.
#
#   Wall-clock for run 2 drops from ~37 min (LME) / ~7 min (LoCoMo) / ~4 min (LMEB)
#   to under a minute per question. The estate-cache is populated per question/session
#   so cache hits are measured and reported in the JSON as cacheHits / cacheMisses.
#
#   1.0.x drain runs: single Rust run per cell — always cold (save-only, no hit
#   within this script). Estate-cache flag still present so future reruns can warm.
#
#   Impatient cells: NO --estate-cache flag — estate-cache must be off for impatient
#   cells because they specifically test ingest throughput (the cache bypasses ingest
#   entirely and would produce misleading latency measurements).
#
# Hint-line check (impatient cells):
#   After each impatient run, the log is grepped for
#   "[longmemeval] encode-barrier: impatient" (Swift) or
#   "[lme] encode-barrier: impatient" (Rust).
#   A missing line appends a WARNING to the holes log — encode-barrier mode
#   is now logged at startup so a silent parse failure or flag rename will
#   surface immediately instead of producing a drain-like result silently.
#
# CLI notes (unified twin flags, validated in fix-bench integration pass):
#   LME:    Swift uses --data-dir <dir> --variant s --mootx01-binary <path>
#           Rust  uses --corpus <json-file> --mootx01-binary <path> --variant s
#   LoCoMo: Swift uses --data-file <json> --mootx01-binary <path>
#           Rust  uses --corpus  <json>   --mootx01-binary <path>
#   LMEB:   both  use --data-dir <ConvoMem-parent> --mootx01-binary <path>
#   encode-barrier: both twins accept --encode-barrier drain|impatient|none
#
# Results go to each line's results/20260727-invalidated-rerun/ directory.
#
# Usage:
#   bash -n /path/to/official-rerun-invalidated-20260727.sh   # syntax-check only
#   nohup bash /path/to/official-rerun-invalidated-20260727.sh 2>&1 | tee rerun-20260727-invalidated.log &

# No set -e — we handle errors per-run and never abort the matrix.
# Fatal pre-flight checks use explicit || { ... exit 1; }.

SEED=20260725
VARIANT=s
LIMIT=50

# ── 1.0.x paths ──────────────────────────────────────────────────────────────
DIR10X=/Users/bob/devlop/mootx01-ce-develop_1.0.x
MOOT10X="$DIR10X/apps/mootx01/.build/release/mootx01"
SWIFT10X="$DIR10X/apps/mcp-benchmarker/.build/release/mcp-benchmarker"
RUST10X="$DIR10X/apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs"
RESULTS10X="$DIR10X/apps/mcp-benchmarker/results/20260727-invalidated-rerun"
CACHE10X="$RESULTS10X/estate-cache"

# ── 1.1.x paths ──────────────────────────────────────────────────────────────
DIR11X=/Users/bob/devlop/mootx01-ce-develop_1.1.x
MOOT11X="$DIR11X/apps/mootx01/.build/release/mootx01"
SWIFT11X="$DIR11X/apps/mcp-benchmarker/.build/release/mcp-benchmarker"
RUST11X="$DIR11X/apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs"
RESULTS11X="$DIR11X/apps/mcp-benchmarker/results/20260727-invalidated-rerun"
CACHE11X="$RESULTS11X/estate-cache"

# ── Fixture paths ─────────────────────────────────────────────────────────────
LME_DATA_DIR=/Users/bob/devlop/mootx01-ce-lme/apps/mcp-benchmarker/fixtures/longmemeval/data
LME_CORPUS_S="$LME_DATA_DIR/longmemeval_s_cleaned.json"

LOCOMO_JSON=/Users/bob/devlop/mootx01-ce-lme-locomo/apps/mcp-benchmarker/fixtures/locomo/locomo10.json

LMEB_DATA_DIR=/Users/bob/devlop/mootx01-ce-lme-lmeb/apps/mcp-benchmarker/fixtures/lmeb/data/ConvoMem

# ── Setup ────────────────────────────────────────────────────────────────────
mkdir -p "$RESULTS10X" "$RESULTS11X" "$CACHE10X" "$CACHE11X" \
    || { echo "FATAL: could not create results/cache dirs"; exit 1; }

# Holes log lives alongside results in the 1.0.x results dir (canonical location).
HOLES_LOG="$RESULTS10X/holes.log"
touch "$HOLES_LOG" \
    || { echo "FATAL: could not create holes log at $HOLES_LOG"; exit 1; }

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

# ── Pre-flight: verify binaries exist and are executable ─────────────────────
for bin in "$MOOT10X" "$SWIFT10X" "$RUST10X" "$MOOT11X" "$SWIFT11X" "$RUST11X"; do
    [ -x "$bin" ] || { echo "FATAL: binary not found or not executable: $bin"; exit 1; }
done

# ── Pre-flight: verify fixture files/dirs ────────────────────────────────────
[ -f "$LME_CORPUS_S" ]   || { echo "FATAL: LME corpus not found: $LME_CORPUS_S"; exit 1; }
[ -f "$LOCOMO_JSON" ]     || { echo "FATAL: LoCoMo corpus not found: $LOCOMO_JSON"; exit 1; }
[ -d "$LMEB_DATA_DIR" ]  || { echo "FATAL: LMEB data dir not found: $LMEB_DATA_DIR"; exit 1; }
[ -d "$LMEB_DATA_DIR/user_evidence" ] \
    || { echo "FATAL: LMEB user_evidence split not found under $LMEB_DATA_DIR"; exit 1; }

echo "[$(ts)] Pre-flight checks passed."
echo "[$(ts)] Holes log: $HOLES_LOG"
echo ""

# ── Helper: execute one benchmark leg ────────────────────────────────────────
# run_leg <run_id> <log_path> <expected_json> <renamed_json> <binary> [args...]
#
# On success (exit 0): renames <expected_json> to <renamed_json>.
# On failure (exit !=0): appends "HOLE: <run_id>" to holes log and continues.
run_leg() {
    local run_id log_path expected_json renamed_json rc
    run_id="$1"; shift
    log_path="$1"; shift
    expected_json="$1"; shift
    renamed_json="$1"; shift

    echo "[$(ts)] START  $run_id"

    "$@" 2>&1 | tee "$log_path"
    rc=${PIPESTATUS[0]}

    if [ "$rc" -ne 0 ]; then
        echo "HOLE: $run_id (exit $rc)" | tee -a "$HOLES_LOG"
        echo "[$(ts)] HOLE   $run_id exit=$rc — continuing matrix"
    else
        mv "$expected_json" "$renamed_json" \
            || { echo "HOLE: $run_id (mv failed)" | tee -a "$HOLES_LOG"; \
                 echo "[$(ts)] HOLE   $run_id: mv $expected_json → $renamed_json failed"; }
        echo "[$(ts)] DONE   $run_id → $(basename "$renamed_json")"
    fi
}

# ── Helper: hint-line check for impatient cells ───────────────────────────────
# check_impatient_hint <runner_prefix> <log_path>
#
# Greps the log for the encode-barrier: impatient startup line added in the
# fix-fanout merge pass. A missing line means the flag was not parsed correctly
# or the runner silently fell back to a different mode — log a WARNING to the
# holes log so the cell is flagged for investigation before reporting.
check_impatient_hint() {
    local prefix="$1"
    local log_path="$2"
    if ! grep -q "\[$prefix\] encode-barrier: impatient" "$log_path" 2>/dev/null; then
        echo "WARNING: [$prefix] encode-barrier: impatient not found in $log_path — mode may have been silently overridden" \
            | tee -a "$HOLES_LOG"
        echo "[$(ts)] WARNING impatient hint line absent — check $log_path"
    fi
}

# ============================================================================
# 1.1.x — DRAIN GRID (single-run validation per cell)
# ============================================================================
echo "[$(ts)] ============================================================"
echo "[$(ts)] 1.1.x DRAIN GRID — 6 runs (LME+LoCoMo+LMEB × Swift+Rust)"
echo "[$(ts)] ============================================================"
echo ""

# ── 1.1.x LME Swift drain r1 (cold — miss+save) ──────────────────────────────
run_leg "1.1.x-lme-swift-r1" \
    "$RESULTS11X/lme-swift-run1.log" \
    "$RESULTS11X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS11X/lme-11x-swift-r1.json" \
    "$SWIFT11X" longmemeval \
        --data-dir "$LME_DATA_DIR" \
        --variant "$VARIANT" \
        --mootx01-binary "$MOOT11X" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier drain \
        --estate-cache reuse --cache-dir "$CACHE11X" \
        --out "$RESULTS11X"

# ── 1.1.x LoCoMo Swift drain r1 (cold — miss+save) ───────────────────────────
run_leg "1.1.x-locomo-swift-r1" \
    "$RESULTS11X/locomo-swift-run1.log" \
    "$RESULTS11X/locomo-report-seed${SEED}.json" \
    "$RESULTS11X/locomo-11x-swift-r1.json" \
    "$SWIFT11X" locomo \
        --data-file "$LOCOMO_JSON" \
        --mootx01-binary "$MOOT11X" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier drain \
        --estate-cache reuse --cache-dir "$CACHE11X" \
        --out "$RESULTS11X"

# ── 1.1.x LMEB Swift drain r1 (cold — miss+save) ─────────────────────────────
run_leg "1.1.x-lmeb-swift-r1" \
    "$RESULTS11X/lmeb-swift-run1.log" \
    "$RESULTS11X/lmeb-report-seed${SEED}.json" \
    "$RESULTS11X/lmeb-11x-swift-r1.json" \
    "$SWIFT11X" lmeb \
        --data-dir "$LMEB_DATA_DIR" \
        --evidence-types user_evidence \
        --mootx01-binary "$MOOT11X" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier drain \
        --estate-cache reuse --cache-dir "$CACHE11X" \
        --out "$RESULTS11X"

# ── 1.1.x LME Rust drain r1 (warm — cache hit from Swift r1) ─────────────────
run_leg "1.1.x-lme-rust-r1" \
    "$RESULTS11X/lme-rust-run1.log" \
    "$RESULTS11X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS11X/lme-11x-rust-r1.json" \
    "$RUST11X" longmemeval \
        --corpus "$LME_CORPUS_S" \
        --mootx01-binary "$MOOT11X" \
        --variant "$VARIANT" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier drain \
        --estate-cache reuse --cache-dir "$CACHE11X" \
        --out "$RESULTS11X"

# ── 1.1.x LoCoMo Rust drain r1 (warm — cache hit from Swift r1) ──────────────
run_leg "1.1.x-locomo-rust-r1" \
    "$RESULTS11X/locomo-rust-run1.log" \
    "$RESULTS11X/locomo-report-seed${SEED}.json" \
    "$RESULTS11X/locomo-11x-rust-r1.json" \
    "$RUST11X" locomo \
        --corpus "$LOCOMO_JSON" \
        --mootx01-binary "$MOOT11X" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier drain \
        --estate-cache reuse --cache-dir "$CACHE11X" \
        --out "$RESULTS11X"

# ── 1.1.x LMEB Rust drain r1 (warm — cache hit from Swift r1) ────────────────
run_leg "1.1.x-lmeb-rust-r1" \
    "$RESULTS11X/lmeb-rust-run1.log" \
    "$RESULTS11X/lmeb-report-seed${SEED}.json" \
    "$RESULTS11X/lmeb-11x-rust-r1.json" \
    "$RUST11X" lmeb \
        --data-dir "$LMEB_DATA_DIR" \
        --evidence-types user_evidence \
        --mootx01-binary "$MOOT11X" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier drain \
        --estate-cache reuse --cache-dir "$CACHE11X" \
        --out "$RESULTS11X"

# ============================================================================
# 1.1.x — IMPATIENT PROOF CELLS (LME only, 1 run per twin)
# ============================================================================
echo ""
echo "[$(ts)] ============================================================"
echo "[$(ts)] 1.1.x IMPATIENT PROOF CELLS — 2 runs + hint-line check"
echo "[$(ts)] ============================================================"
echo ""

# ── 1.1.x LME Swift impatient r1 ─────────────────────────────────────────────
run_leg "1.1.x-lme-swift-impatient-r1" \
    "$RESULTS11X/lme-swift-impatient-run1.log" \
    "$RESULTS11X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS11X/lme-11x-swift-impatient-r1.json" \
    "$SWIFT11X" longmemeval \
        --data-dir "$LME_DATA_DIR" \
        --variant "$VARIANT" \
        --mootx01-binary "$MOOT11X" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier impatient \
        --out "$RESULTS11X"

# Hint-line check: verify the encode-barrier mode was logged at startup.
# A missing line means --encode-barrier impatient was not parsed or was silently
# overridden — the 20260726 run had no way to detect this; now we catch it here.
check_impatient_hint "longmemeval" "$RESULTS11X/lme-swift-impatient-run1.log"

# ── 1.1.x LME Rust impatient r1 ──────────────────────────────────────────────
run_leg "1.1.x-lme-rust-impatient-r1" \
    "$RESULTS11X/lme-rust-impatient-run1.log" \
    "$RESULTS11X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS11X/lme-11x-rust-impatient-r1.json" \
    "$RUST11X" longmemeval \
        --corpus "$LME_CORPUS_S" \
        --mootx01-binary "$MOOT11X" \
        --variant "$VARIANT" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier impatient \
        --out "$RESULTS11X"

# Hint-line check: Rust runner logs to stderr (merged via 2>&1 in run_leg).
check_impatient_hint "lme" "$RESULTS11X/lme-rust-impatient-run1.log"

# ============================================================================
# 1.0.x — RUST DRAIN GRID (single-run validation; Rust binary fix only)
# ============================================================================
echo ""
echo "[$(ts)] ============================================================"
echo "[$(ts)] 1.0.x RUST DRAIN GRID — 3 runs (Rust twin only)"
echo "[$(ts)] ============================================================"
echo ""

# ── 1.0.x LME Rust drain r1 (cold — miss+save) ───────────────────────────────
run_leg "1.0.x-lme-rust-r1" \
    "$RESULTS10X/lme-rust-run1.log" \
    "$RESULTS10X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS10X/lme-10x-rust-r1.json" \
    "$RUST10X" longmemeval \
        --corpus "$LME_CORPUS_S" \
        --mootx01-binary "$MOOT10X" \
        --variant "$VARIANT" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier drain \
        --estate-cache reuse --cache-dir "$CACHE10X" \
        --out "$RESULTS10X"

# ── 1.0.x LoCoMo Rust drain r1 (cold — miss+save) ────────────────────────────
run_leg "1.0.x-locomo-rust-r1" \
    "$RESULTS10X/locomo-rust-run1.log" \
    "$RESULTS10X/locomo-report-seed${SEED}.json" \
    "$RESULTS10X/locomo-10x-rust-r1.json" \
    "$RUST10X" locomo \
        --corpus "$LOCOMO_JSON" \
        --mootx01-binary "$MOOT10X" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier drain \
        --estate-cache reuse --cache-dir "$CACHE10X" \
        --out "$RESULTS10X"

# ── 1.0.x LMEB Rust drain r1 (cold — miss+save) ──────────────────────────────
run_leg "1.0.x-lmeb-rust-r1" \
    "$RESULTS10X/lmeb-rust-run1.log" \
    "$RESULTS10X/lmeb-report-seed${SEED}.json" \
    "$RESULTS10X/lmeb-10x-rust-r1.json" \
    "$RUST10X" lmeb \
        --data-dir "$LMEB_DATA_DIR" \
        --evidence-types user_evidence \
        --mootx01-binary "$MOOT10X" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier drain \
        --estate-cache reuse --cache-dir "$CACHE10X" \
        --out "$RESULTS10X"

# ============================================================================
# 1.0.x — IMPATIENT PROOF CELL (Rust twin only, LME only)
# ============================================================================
echo ""
echo "[$(ts)] ============================================================"
echo "[$(ts)] 1.0.x RUST IMPATIENT PROOF CELL — 1 run + hint-line check"
echo "[$(ts)] ============================================================"
echo ""

# ── 1.0.x LME Rust impatient r1 ──────────────────────────────────────────────
run_leg "1.0.x-lme-rust-impatient-r1" \
    "$RESULTS10X/lme-rust-impatient-run1.log" \
    "$RESULTS10X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS10X/lme-10x-rust-impatient-r1.json" \
    "$RUST10X" longmemeval \
        --corpus "$LME_CORPUS_S" \
        --mootx01-binary "$MOOT10X" \
        --variant "$VARIANT" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier impatient \
        --out "$RESULTS10X"

# Hint-line check: Rust runner logs to stderr (merged via 2>&1 in run_leg).
check_impatient_hint "lme" "$RESULTS10X/lme-rust-impatient-run1.log"

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo "[$(ts)] ============================================================"
echo "[$(ts)] INVALIDATED RERUN COMPLETE"
HOLE_COUNT=$(wc -l < "$HOLES_LOG" 2>/dev/null || echo "?")
echo "[$(ts)] Holes/warnings: ${HOLE_COUNT} (see $HOLES_LOG)"
echo "[$(ts)] 1.0.x results: $RESULTS10X"
echo "[$(ts)] 1.1.x results: $RESULTS11X"
echo "[$(ts)] ============================================================"
