#!/usr/bin/env bash
# apps/mcp-benchmarker/scripts/official-matrix-11x-only.sh
#
# 1.1.x continuation script — run after the 1.0.x remainder matrix finishes.
# Executes ONLY the 1.1.x grid, token-efficiency legs deliberately omitted:
#   - arm=both is the default for all LME runs, so every LME run already
#     carries both arms' token data. The tokeneff legs are pure duplicates.
#   - The dense/exact byte ratio is a known format-arithmetic artifact
#     (Kinsta investigation, 2026-07-26); the metric is meaningless until
#     the scorer fix lands.
#
# Run count: 18
#   1.1.x LME   Swift R1-R3  :  3  (~37 min each)
#   1.1.x LME   Rust  R1-R3  :  3  (~37 min each)
#   1.1.x LoCoMo Swift R1-R3 :  3  (~ 7 min each)
#   1.1.x LoCoMo Rust  R1-R3 :  3  (~ 7 min each)
#   1.1.x LMEB  Swift R1-R3  :  3  (~ 4 min each)
#   1.1.x LMEB  Rust  R1-R3  :  3  (~ 4 min each)
#
# Estimated wall clock: ~4 hours
#   6 LME runs  x 37 min = 222 min
#   6 LoCoMo    x  7 min =  42 min
#   6 LMEB      x  4 min =  24 min
#
# NOTE: CLI flag differences between twins:
#   LME:    Swift uses --data-dir <dir> --variant s
#           Rust  uses --corpus <single-json-file>
#   LoCoMo: Swift uses --data-file <json>
#           Rust  uses --corpus <json>
#   LMEB:   both use --data-dir <ConvoMem-parent>
#   moot binary: Swift uses --mootx01-binary, Rust uses --binary
#
# Usage:
#   nohup bash /path/to/official-matrix-11x-only.sh 2>&1 | tee matrix-11x.log &

# No set -e — we handle errors per-run and never abort the matrix.
# Fatal pre-run checks use explicit || { ... exit 1; }.

SEED=20260725
VARIANT=s
LIMIT=50

# ── 1.0.x paths (for holes.log location only) ─────────────────────────────
DIR10X=/Users/bob/devlop/mootx01-ce-develop_1.0.x
RESULTS10X="$DIR10X/apps/mcp-benchmarker/results/20260726-official-quietrun"

# ── 1.1.x paths ──────────────────────────────────────────────────────────────
DIR11X=/Users/bob/devlop/mootx01-ce-develop_1.1.x
MOOT11X="$DIR11X/apps/mootx01/.build/release/mootx01"
SWIFT11X="$DIR11X/apps/mcp-benchmarker/.build/release/mcp-benchmarker"
RUST11X="$DIR11X/apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs"
RESULTS11X="$DIR11X/apps/mcp-benchmarker/results/20260726-official-quietrun"

# ── Fixture paths ─────────────────────────────────────────────────────────────
# LME: Swift needs the data directory; Rust needs the specific corpus JSON.
LME_DATA_DIR=/Users/bob/devlop/mootx01-ce-lme/apps/mcp-benchmarker/fixtures/longmemeval/data
LME_CORPUS_S="$LME_DATA_DIR/longmemeval_s_cleaned.json"

# LoCoMo: single JSON file used by both twins (different flag name per twin).
LOCOMO_JSON=/Users/bob/devlop/mootx01-ce-lme-locomo/apps/mcp-benchmarker/fixtures/locomo/locomo10.json

# LMEB: parent directory of evidence-type subdirectories.
# Only user_evidence is downloaded; --evidence-types restricts to that split.
LMEB_DATA_DIR=/Users/bob/devlop/mootx01-ce-lme-lmeb/apps/mcp-benchmarker/fixtures/lmeb/data/ConvoMem

# ── Setup ────────────────────────────────────────────────────────────────────
mkdir -p "$RESULTS10X" "$RESULTS11X" \
    || { echo "FATAL: could not create results dirs"; exit 1; }

# Holes log lives in 1.0.x results dir alongside the full-matrix holes log.
HOLES_LOG="$RESULTS10X/holes-11x.log"
touch "$HOLES_LOG" \
    || { echo "FATAL: could not create holes log at $HOLES_LOG"; exit 1; }

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

# ── Pre-flight: verify fixture files/dirs ────────────────────────────────────
[ -f "$LME_CORPUS_S" ]   || { echo "FATAL: LME corpus not found: $LME_CORPUS_S"; exit 1; }
[ -f "$LOCOMO_JSON" ]     || { echo "FATAL: LoCoMo corpus not found: $LOCOMO_JSON"; exit 1; }
[ -d "$LMEB_DATA_DIR" ]  || { echo "FATAL: LMEB data dir not found: $LMEB_DATA_DIR"; exit 1; }
[ -d "$LMEB_DATA_DIR/user_evidence" ] \
    || { echo "FATAL: LMEB user_evidence split not found under $LMEB_DATA_DIR"; exit 1; }

# ── Build 1.1.x binaries if absent ───────────────────────────────────────────
if [ ! -x "$MOOT11X" ]; then
    echo "[$(ts)] Building 1.1.x mootx01 (binary absent)..."
    (cd "$DIR11X/apps/mootx01" && swift build -c release) \
        || { echo "FATAL: 1.1.x mootx01 build failed"; exit 1; }
fi
if [ ! -x "$SWIFT11X" ]; then
    echo "[$(ts)] Building 1.1.x Swift benchmarker (binary absent)..."
    (cd "$DIR11X/apps/mcp-benchmarker" && swift build -c release) \
        || { echo "FATAL: 1.1.x Swift benchmarker build failed"; exit 1; }
fi
if [ ! -x "$RUST11X" ]; then
    echo "[$(ts)] Building 1.1.x Rust benchmarker (binary absent)..."
    (cd "$DIR11X/apps/mcp-benchmarker/rust" && cargo build --release) \
        || { echo "FATAL: 1.1.x Rust benchmarker build failed"; exit 1; }
fi

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

# ============================================================================
# 1.1.x — FULL GRID (tokeneff legs omitted — see file header)
# ============================================================================
echo "[$(ts)] ============================================================"
echo "[$(ts)] 1.1.x FULL GRID — 18 runs (no tokeneff)"
echo "[$(ts)] ============================================================"
echo ""

# ── 1.1.x LME Swift R1-R3 ────────────────────────────────────────────────────
for RN in 1 2 3; do
    run_leg "1.1.x-lme-swift-r${RN}" \
        "$RESULTS11X/lme-swift-run${RN}.log" \
        "$RESULTS11X/lme-report-${VARIANT}-seed${SEED}.json" \
        "$RESULTS11X/lme-11x-swift-r${RN}.json" \
        "$SWIFT11X" longmemeval \
            --data-dir "$LME_DATA_DIR" \
            --variant "$VARIANT" \
            --mootx01-binary "$MOOT11X" \
            --limit "$LIMIT" --seed "$SEED" \
            --out "$RESULTS11X"
done

# ── 1.1.x LME Rust R1-R3 ─────────────────────────────────────────────────────
for RN in 1 2 3; do
    run_leg "1.1.x-lme-rust-r${RN}" \
        "$RESULTS11X/lme-rust-run${RN}.log" \
        "$RESULTS11X/lme-report-${VARIANT}-seed${SEED}.json" \
        "$RESULTS11X/lme-11x-rust-r${RN}.json" \
        "$RUST11X" longmemeval \
            --corpus "$LME_CORPUS_S" \
            --binary "$MOOT11X" \
            --variant "$VARIANT" \
            --limit "$LIMIT" --seed "$SEED" \
            --out "$RESULTS11X"
done

# ── 1.1.x LoCoMo Swift R1-R3 ─────────────────────────────────────────────────
for RN in 1 2 3; do
    run_leg "1.1.x-locomo-swift-r${RN}" \
        "$RESULTS11X/locomo-swift-run${RN}.log" \
        "$RESULTS11X/locomo-report-seed${SEED}.json" \
        "$RESULTS11X/locomo-11x-swift-r${RN}.json" \
        "$SWIFT11X" locomo \
            --data-file "$LOCOMO_JSON" \
            --mootx01-binary "$MOOT11X" \
            --limit "$LIMIT" --seed "$SEED" \
            --out "$RESULTS11X"
done

# ── 1.1.x LoCoMo Rust R1-R3 ──────────────────────────────────────────────────
# Rust twin uses --corpus instead of --data-file, and --binary instead of --mootx01-binary.
for RN in 1 2 3; do
    run_leg "1.1.x-locomo-rust-r${RN}" \
        "$RESULTS11X/locomo-rust-run${RN}.log" \
        "$RESULTS11X/locomo-report-seed${SEED}.json" \
        "$RESULTS11X/locomo-11x-rust-r${RN}.json" \
        "$RUST11X" locomo \
            --corpus "$LOCOMO_JSON" \
            --binary "$MOOT11X" \
            --limit "$LIMIT" --seed "$SEED" \
            --out "$RESULTS11X"
done

# ── 1.1.x LMEB Swift R1-R3 ───────────────────────────────────────────────────
for RN in 1 2 3; do
    run_leg "1.1.x-lmeb-swift-r${RN}" \
        "$RESULTS11X/lmeb-swift-run${RN}.log" \
        "$RESULTS11X/lmeb-report-seed${SEED}.json" \
        "$RESULTS11X/lmeb-11x-swift-r${RN}.json" \
        "$SWIFT11X" lmeb \
            --data-dir "$LMEB_DATA_DIR" \
            --evidence-types user_evidence \
            --mootx01-binary "$MOOT11X" \
            --limit "$LIMIT" --seed "$SEED" \
            --out "$RESULTS11X"
done

# ── 1.1.x LMEB Rust R1-R3 ────────────────────────────────────────────────────
for RN in 1 2 3; do
    run_leg "1.1.x-lmeb-rust-r${RN}" \
        "$RESULTS11X/lmeb-rust-run${RN}.log" \
        "$RESULTS11X/lmeb-report-seed${SEED}.json" \
        "$RESULTS11X/lmeb-11x-rust-r${RN}.json" \
        "$RUST11X" lmeb \
            --data-dir "$LMEB_DATA_DIR" \
            --evidence-types user_evidence \
            --binary "$MOOT11X" \
            --limit "$LIMIT" --seed "$SEED" \
            --out "$RESULTS11X"
done

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo "[$(ts)] ============================================================"
echo "[$(ts)] 1.1.x GRID COMPLETE"
HOLE_COUNT=$(wc -l < "$HOLES_LOG" 2>/dev/null || echo "?")
echo "[$(ts)] Holes: ${HOLE_COUNT} (see $HOLES_LOG)"
echo "[$(ts)] 1.1.x results: $RESULTS11X"
echo "[$(ts)] ============================================================"
