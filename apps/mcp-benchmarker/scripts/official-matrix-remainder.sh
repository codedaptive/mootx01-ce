#!/usr/bin/env bash
# apps/mcp-benchmarker/scripts/official-matrix-remainder.sh
#
# Official quiet-machine benchmark matrix — remainder run.
# Executes the full remaining grid sequentially, with no parallelism.
# A failing run is logged to holes.log and the matrix CONTINUES.
# The script never aborts on a benchmarker error.
#
# Run count: 36
#   1.0.x remainder : 16 runs
#     LME Rust R2-R3         :  2  (~37 min each)
#     LoCoMo Swift R1-R3     :  3  (~ 7 min each)
#     LoCoMo Rust  R1-R3     :  3  (~ 7 min each)
#     LMEB   Swift R1-R3     :  3  (~ 4 min each)
#     LMEB   Rust  R1-R3     :  3  (~ 4 min each)
#     Token-eff Swift (LME)  :  1  (~37 min)
#     Token-eff Rust  (LME)  :  1  (~37 min)
#   1.1.x full grid : 20 runs
#     LME   Swift R1-R3      :  3  (~37 min each)
#     LME   Rust  R1-R3      :  3  (~37 min each)
#     LoCoMo Swift R1-R3     :  3  (~ 7 min each)
#     LoCoMo Rust  R1-R3     :  3  (~ 7 min each)
#     LMEB   Swift R1-R3     :  3  (~ 4 min each)
#     LMEB   Rust  R1-R3     :  3  (~ 4 min each)
#     Token-eff Swift (LME)  :  1  (~37 min)
#     Token-eff Rust  (LME)  :  1  (~37 min)
#
# Estimated wall clock: ~9.5 hours
#   LME/tokeneff runs: 14 x 37 min = 518 min
#   LoCoMo runs:       12 x  7 min =  84 min
#   LMEB runs:         12 x  4 min =  48 min
#   Total:                         = 650 min (~10.8 hours)
#
# NOTE: "token-efficiency" runs are LME runs with --arm both (the default).
# No separate token-efficiency subcommand exists in either twin. These runs
# provide dedicated token-efficiency artifact files for the comparison doc.
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
#   nohup bash /path/to/official-matrix-remainder.sh 2>&1 | tee matrix-run.log &

# No set -e — we handle errors per-run and never abort the matrix.
# Fatal pre-run checks use explicit || { ... exit 1; }.

SEED=20260725
VARIANT=s
LIMIT=50

# ── 1.0.x paths ──────────────────────────────────────────────────────────────
DIR10X=/Users/bob/devlop/mootx01-ce-develop_1.0.x
MOOT10X="$DIR10X/apps/mootx01/.build/release/mootx01"
SWIFT10X="$DIR10X/apps/mcp-benchmarker/.build/release/mcp-benchmarker"
RUST10X="$DIR10X/apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs"
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

HOLES_LOG="$RESULTS10X/holes.log"
touch "$HOLES_LOG" \
    || { echo "FATAL: could not create holes.log at $HOLES_LOG"; exit 1; }

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

# ── Pre-flight: verify 1.0.x binaries exist ──────────────────────────────────
for bin in "$MOOT10X" "$SWIFT10X" "$RUST10X"; do
    [ -x "$bin" ] || { echo "FATAL: 1.0.x binary not found or not executable: $bin"; exit 1; }
done

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
# Runs: <binary> [args...], tees stdout+stderr to <log_path>.
# On success (exit 0): renames <expected_json> to <renamed_json>.
# On failure (exit !=0): appends "HOLE: <run_id>" to holes.log and continues.
run_leg() {
    local run_id log_path expected_json renamed_json rc
    run_id="$1"; shift
    log_path="$1"; shift
    expected_json="$1"; shift
    renamed_json="$1"; shift
    # remaining args: binary + its flags

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
# 1.0.x — REMAINDER
# ============================================================================
echo "[$(ts)] ============================================================"
echo "[$(ts)] 1.0.x REMAINDER (16 runs)"
echo "[$(ts)] ============================================================"
echo ""

# ── Rename Rust R1 report if it was not renamed before stall ─────────────────
# The bi9hlvf6o run completed and wrote lme-report-s-seed20260725.json.
# If lme-10x-rust-r1.json does not yet exist, rename it now.
if [ -f "$RESULTS10X/lme-report-s-seed${SEED}.json" ] && \
   [ ! -f "$RESULTS10X/lme-10x-rust-r1.json" ]; then
    mv "$RESULTS10X/lme-report-s-seed${SEED}.json" \
       "$RESULTS10X/lme-10x-rust-r1.json"
    echo "[$(ts)] Pre-rename: lme-report-s-seed${SEED}.json → lme-10x-rust-r1.json (from stalled session)"
fi

# ── 1.0.x LME Rust R2 ────────────────────────────────────────────────────────
run_leg "1.0.x-lme-rust-r2" \
    "$RESULTS10X/lme-rust-run2.log" \
    "$RESULTS10X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS10X/lme-10x-rust-r2.json" \
    "$RUST10X" longmemeval \
        --corpus "$LME_CORPUS_S" \
        --binary "$MOOT10X" \
        --variant "$VARIANT" \
        --limit "$LIMIT" --seed "$SEED" \
        --out "$RESULTS10X"

# ── 1.0.x LME Rust R3 ────────────────────────────────────────────────────────
run_leg "1.0.x-lme-rust-r3" \
    "$RESULTS10X/lme-rust-run3.log" \
    "$RESULTS10X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS10X/lme-10x-rust-r3.json" \
    "$RUST10X" longmemeval \
        --corpus "$LME_CORPUS_S" \
        --binary "$MOOT10X" \
        --variant "$VARIANT" \
        --limit "$LIMIT" --seed "$SEED" \
        --out "$RESULTS10X"

# ── 1.0.x LoCoMo Swift R1-R3 ─────────────────────────────────────────────────
for RN in 1 2 3; do
    run_leg "1.0.x-locomo-swift-r${RN}" \
        "$RESULTS10X/locomo-swift-run${RN}.log" \
        "$RESULTS10X/locomo-report-seed${SEED}.json" \
        "$RESULTS10X/locomo-10x-swift-r${RN}.json" \
        "$SWIFT10X" locomo \
            --data-file "$LOCOMO_JSON" \
            --mootx01-binary "$MOOT10X" \
            --limit "$LIMIT" --seed "$SEED" \
            --out "$RESULTS10X"
done

# ── 1.0.x LoCoMo Rust R1-R3 ──────────────────────────────────────────────────
# Rust twin uses --corpus instead of --data-file, and --binary instead of --mootx01-binary.
for RN in 1 2 3; do
    run_leg "1.0.x-locomo-rust-r${RN}" \
        "$RESULTS10X/locomo-rust-run${RN}.log" \
        "$RESULTS10X/locomo-report-seed${SEED}.json" \
        "$RESULTS10X/locomo-10x-rust-r${RN}.json" \
        "$RUST10X" locomo \
            --corpus "$LOCOMO_JSON" \
            --binary "$MOOT10X" \
            --limit "$LIMIT" --seed "$SEED" \
            --out "$RESULTS10X"
done

# ── 1.0.x LMEB Swift R1-R3 ───────────────────────────────────────────────────
for RN in 1 2 3; do
    run_leg "1.0.x-lmeb-swift-r${RN}" \
        "$RESULTS10X/lmeb-swift-run${RN}.log" \
        "$RESULTS10X/lmeb-report-seed${SEED}.json" \
        "$RESULTS10X/lmeb-10x-swift-r${RN}.json" \
        "$SWIFT10X" lmeb \
            --data-dir "$LMEB_DATA_DIR" \
            --evidence-types user_evidence \
            --mootx01-binary "$MOOT10X" \
            --limit "$LIMIT" --seed "$SEED" \
            --out "$RESULTS10X"
done

# ── 1.0.x LMEB Rust R1-R3 ────────────────────────────────────────────────────
for RN in 1 2 3; do
    run_leg "1.0.x-lmeb-rust-r${RN}" \
        "$RESULTS10X/lmeb-rust-run${RN}.log" \
        "$RESULTS10X/lmeb-report-seed${SEED}.json" \
        "$RESULTS10X/lmeb-10x-rust-r${RN}.json" \
        "$RUST10X" lmeb \
            --data-dir "$LMEB_DATA_DIR" \
            --evidence-types user_evidence \
            --binary "$MOOT10X" \
            --limit "$LIMIT" --seed "$SEED" \
            --out "$RESULTS10X"
done

# ── 1.0.x Token-efficiency Swift (LME, arm=both default) ─────────────────────
# arm=both is the default for both twins — each LME run already includes
# token-efficiency metrics. This dedicated run provides a clean artifact
# for the token-efficiency section of the comparison doc.
run_leg "1.0.x-tokeneff-swift" \
    "$RESULTS10X/lme-swift-tokeneff.log" \
    "$RESULTS10X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS10X/lme-10x-swift-tokeneff.json" \
    "$SWIFT10X" longmemeval \
        --data-dir "$LME_DATA_DIR" \
        --variant "$VARIANT" \
        --mootx01-binary "$MOOT10X" \
        --limit "$LIMIT" --seed "$SEED" \
        --out "$RESULTS10X"

# ── 1.0.x Token-efficiency Rust (LME, arm=both default) ──────────────────────
run_leg "1.0.x-tokeneff-rust" \
    "$RESULTS10X/lme-rust-tokeneff.log" \
    "$RESULTS10X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS10X/lme-10x-rust-tokeneff.json" \
    "$RUST10X" longmemeval \
        --corpus "$LME_CORPUS_S" \
        --binary "$MOOT10X" \
        --variant "$VARIANT" \
        --limit "$LIMIT" --seed "$SEED" \
        --out "$RESULTS10X"

echo ""
echo "[$(ts)] 1.0.x remainder complete."
echo ""

# ============================================================================
# 1.1.x — FULL GRID
# ============================================================================
echo "[$(ts)] ============================================================"
echo "[$(ts)] 1.1.x FULL GRID (20 runs)"
echo "[$(ts)] ============================================================"
echo ""
# 1.1.x benchmarker uses impatient=true (inline encoding barrier).
# All flag shapes and fixture paths are identical to 1.0.x;
# only the binary paths and results dir differ.

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

# ── 1.1.x Token-efficiency Swift (LME, arm=both default) ─────────────────────
run_leg "1.1.x-tokeneff-swift" \
    "$RESULTS11X/lme-swift-tokeneff.log" \
    "$RESULTS11X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS11X/lme-11x-swift-tokeneff.json" \
    "$SWIFT11X" longmemeval \
        --data-dir "$LME_DATA_DIR" \
        --variant "$VARIANT" \
        --mootx01-binary "$MOOT11X" \
        --limit "$LIMIT" --seed "$SEED" \
        --out "$RESULTS11X"

# ── 1.1.x Token-efficiency Rust (LME, arm=both default) ──────────────────────
run_leg "1.1.x-tokeneff-rust" \
    "$RESULTS11X/lme-rust-tokeneff.log" \
    "$RESULTS11X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS11X/lme-11x-rust-tokeneff.json" \
    "$RUST11X" longmemeval \
        --corpus "$LME_CORPUS_S" \
        --binary "$MOOT11X" \
        --variant "$VARIANT" \
        --limit "$LIMIT" --seed "$SEED" \
        --out "$RESULTS11X"

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo "[$(ts)] ============================================================"
echo "[$(ts)] MATRIX COMPLETE"
HOLE_COUNT=$(wc -l < "$HOLES_LOG" 2>/dev/null || echo "?")
echo "[$(ts)] Holes: ${HOLE_COUNT} (see $HOLES_LOG)"
echo "[$(ts)] 1.0.x results: $RESULTS10X"
echo "[$(ts)] 1.1.x results: $RESULTS11X"
echo "[$(ts)] ============================================================"
