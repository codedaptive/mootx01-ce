#!/usr/bin/env bash
# apps/mcp-benchmarker/scripts/official-rerun-20260726.sh
#
# Official post-fix-integration re-run — 2026-07-26 (Bilby integration pass).
# Proves the three fix streams (fix-basis, fix-mcp, fix-bench) hold across
# both lines and both twins under clean conditions.
#
# Run count: 40
#   Drain grid — 2 lines × 2 twins × 3 benchmarks × 3 runs = 36 runs
#     1.0.x LME   Swift R1-R3 :  3  (~37 min each)
#     1.0.x LME   Rust  R1-R3 :  3  (~37 min each)
#     1.0.x LoCoMo Swift R1-R3 :  3  (~ 7 min each)
#     1.0.x LoCoMo Rust  R1-R3 :  3  (~ 7 min each)
#     1.0.x LMEB  Swift R1-R3 :  3  (~ 4 min each)
#     1.0.x LMEB  Rust  R1-R3 :  3  (~ 4 min each)
#     1.1.x LME   Swift R1-R3 :  3  (~37 min each)
#     1.1.x LME   Rust  R1-R3 :  3  (~37 min each)
#     1.1.x LoCoMo Swift R1-R3 :  3  (~ 7 min each)
#     1.1.x LoCoMo Rust  R1-R3 :  3  (~ 7 min each)
#     1.1.x LMEB  Swift R1-R3 :  3  (~ 4 min each)
#     1.1.x LMEB  Rust  R1-R3 :  3  (~ 4 min each)
#
#   Basis-fix proof cells — impatient barrier, LME only = 4 runs
#     1.0.x LME   Swift impatient-r1 :  1  (~37 min)
#     1.0.x LME   Rust  impatient-r1 :  1  (~37 min)
#     1.1.x LME   Swift impatient-r1 :  1  (~37 min)
#     1.1.x LME   Rust  impatient-r1 :  1  (~37 min)
#
# Estimated wall clock: ~12 hours
#   LME drain:     12 runs x 37 min = 444 min
#   LME impatient:  4 runs x 37 min = 148 min
#   LoCoMo drain:  12 runs x  7 min =  84 min
#   LMEB drain:    12 runs x  4 min =  48 min
#   Total:                          = 724 min (~12 hours)
#
# CLI notes (unified twin flags validated in Phase 3 integration pass):
#   LME:    Swift uses --data-dir <dir> --variant s --mootx01-binary <path>
#           Rust  uses --corpus <json-file> --mootx01-binary <path> --variant s
#   LoCoMo: Swift uses --data-file <json> --mootx01-binary <path>
#           Rust  uses --corpus  <json>   --mootx01-binary <path>
#   LMEB:   both use --data-dir <ConvoMem-parent> --mootx01-binary <path>
#   encode-barrier: both twins accept --encode-barrier drain|impatient|none
#
# Results go to each line's results/20260726-official-rerun/ directory.
#
# Usage:
#   bash -n /path/to/official-rerun-20260726.sh   # syntax-check only
#   nohup bash /path/to/official-rerun-20260726.sh 2>&1 | tee rerun-20260726.log &

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
RESULTS10X="$DIR10X/apps/mcp-benchmarker/results/20260726-official-rerun"

# ── 1.1.x paths ──────────────────────────────────────────────────────────────
DIR11X=/Users/bob/devlop/mootx01-ce-develop_1.1.x
MOOT11X="$DIR11X/apps/mootx01/.build/release/mootx01"
SWIFT11X="$DIR11X/apps/mcp-benchmarker/.build/release/mcp-benchmarker"
RUST11X="$DIR11X/apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs"
RESULTS11X="$DIR11X/apps/mcp-benchmarker/results/20260726-official-rerun"

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

# ============================================================================
# 1.0.x — DRAIN GRID
# ============================================================================
echo "[$(ts)] ============================================================"
echo "[$(ts)] 1.0.x DRAIN GRID — 18 runs"
echo "[$(ts)] ============================================================"
echo ""

# ── 1.0.x LME Swift R1-R3 ────────────────────────────────────────────────────
for RN in 1 2 3; do
    run_leg "1.0.x-lme-swift-r${RN}" \
        "$RESULTS10X/lme-swift-run${RN}.log" \
        "$RESULTS10X/lme-report-${VARIANT}-seed${SEED}.json" \
        "$RESULTS10X/lme-10x-swift-r${RN}.json" \
        "$SWIFT10X" longmemeval \
            --data-dir "$LME_DATA_DIR" \
            --variant "$VARIANT" \
            --mootx01-binary "$MOOT10X" \
            --limit "$LIMIT" --seed "$SEED" \
            --encode-barrier drain \
            --out "$RESULTS10X"
done

# ── 1.0.x LME Rust R1-R3 ─────────────────────────────────────────────────────
for RN in 1 2 3; do
    run_leg "1.0.x-lme-rust-r${RN}" \
        "$RESULTS10X/lme-rust-run${RN}.log" \
        "$RESULTS10X/lme-report-${VARIANT}-seed${SEED}.json" \
        "$RESULTS10X/lme-10x-rust-r${RN}.json" \
        "$RUST10X" longmemeval \
            --corpus "$LME_CORPUS_S" \
            --mootx01-binary "$MOOT10X" \
            --variant "$VARIANT" \
            --limit "$LIMIT" --seed "$SEED" \
            --encode-barrier drain \
            --out "$RESULTS10X"
done

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
            --encode-barrier drain \
            --out "$RESULTS10X"
done

# ── 1.0.x LoCoMo Rust R1-R3 ──────────────────────────────────────────────────
for RN in 1 2 3; do
    run_leg "1.0.x-locomo-rust-r${RN}" \
        "$RESULTS10X/locomo-rust-run${RN}.log" \
        "$RESULTS10X/locomo-report-seed${SEED}.json" \
        "$RESULTS10X/locomo-10x-rust-r${RN}.json" \
        "$RUST10X" locomo \
            --corpus "$LOCOMO_JSON" \
            --mootx01-binary "$MOOT10X" \
            --limit "$LIMIT" --seed "$SEED" \
            --encode-barrier drain \
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
            --encode-barrier drain \
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
            --mootx01-binary "$MOOT10X" \
            --limit "$LIMIT" --seed "$SEED" \
            --encode-barrier drain \
            --out "$RESULTS10X"
done

# ============================================================================
# 1.1.x — DRAIN GRID
# ============================================================================
echo ""
echo "[$(ts)] ============================================================"
echo "[$(ts)] 1.1.x DRAIN GRID — 18 runs"
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
            --encode-barrier drain \
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
            --mootx01-binary "$MOOT11X" \
            --variant "$VARIANT" \
            --limit "$LIMIT" --seed "$SEED" \
            --encode-barrier drain \
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
            --encode-barrier drain \
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
            --mootx01-binary "$MOOT11X" \
            --limit "$LIMIT" --seed "$SEED" \
            --encode-barrier drain \
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
            --encode-barrier drain \
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
            --mootx01-binary "$MOOT11X" \
            --limit "$LIMIT" --seed "$SEED" \
            --encode-barrier drain \
            --out "$RESULTS11X"
done

# ============================================================================
# BASIS-FIX PROOF CELLS — impatient barrier, LME only, 1 run per line/twin
#
# With the old degenerate-basis bug, impatient recall collapsed to near-zero
# because the basis was trained on only the FIRST document. With the fix
# (three-state ingest: first-ingest train → 2× growth retrain → fold-in),
# the impatient barrier now produces comparable recall to drain for the
# first few questions. These 4 cells prove the fix holds on both lines.
# ============================================================================
echo ""
echo "[$(ts)] ============================================================"
echo "[$(ts)] BASIS-FIX PROOF CELLS — impatient barrier, 4 runs"
echo "[$(ts)] ============================================================"
echo ""

# ── 1.0.x LME Swift impatient ────────────────────────────────────────────────
run_leg "1.0.x-lme-swift-impatient-r1" \
    "$RESULTS10X/lme-swift-impatient-run1.log" \
    "$RESULTS10X/lme-report-${VARIANT}-seed${SEED}.json" \
    "$RESULTS10X/lme-10x-swift-impatient-r1.json" \
    "$SWIFT10X" longmemeval \
        --data-dir "$LME_DATA_DIR" \
        --variant "$VARIANT" \
        --mootx01-binary "$MOOT10X" \
        --limit "$LIMIT" --seed "$SEED" \
        --encode-barrier impatient \
        --out "$RESULTS10X"

# ── 1.0.x LME Rust impatient ─────────────────────────────────────────────────
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

# ── 1.1.x LME Swift impatient ────────────────────────────────────────────────
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

# ── 1.1.x LME Rust impatient ─────────────────────────────────────────────────
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

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo "[$(ts)] ============================================================"
echo "[$(ts)] RERUN COMPLETE"
HOLE_COUNT=$(wc -l < "$HOLES_LOG" 2>/dev/null || echo "?")
echo "[$(ts)] Holes: ${HOLE_COUNT} (see $HOLES_LOG)"
echo "[$(ts)] 1.0.x results: $RESULTS10X"
echo "[$(ts)] 1.1.x results: $RESULTS11X"
echo "[$(ts)] ============================================================"
