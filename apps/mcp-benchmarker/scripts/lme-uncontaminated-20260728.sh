#!/bin/bash
# lme-uncontaminated-20260728.sh — LME cells only, post consolidate-order fix.
# Every prior LME exact-arm number (both lines, both grids) was contaminated by
# moot_consolidate running BEFORE the exact query (arm=both default). This
# script re-measures the 8 LME cells with the fixed ordering. LoCoMo/LMEB cells
# from 20260727-invalidated-rerun remain valid (those runners never consolidate).
# Sequential; continue-on-error into holes log; fresh cache namespace so no
# pre-fix snapshot reuse ambiguity (binary fingerprint changed anyway).
set -u
TS() { date "+[%Y-%m-%dT%H:%M:%S]"; }
R10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mcp-benchmarker/results/20260728-lme-uncontaminated
R11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mcp-benchmarker/results/20260728-lme-uncontaminated
mkdir -p "$R10" "$R11"
for leg in 1.0.x-lme-swift-drain 1.0.x-lme-rust-drain 1.0.x-lme-swift-impatient 1.0.x-lme-rust-impatient; do mkdir -p "$R10/$leg"; done
for leg in 1.1.x-lme-swift-drain 1.1.x-lme-rust-drain 1.1.x-lme-swift-impatient 1.1.x-lme-rust-impatient; do mkdir -p "$R11/$leg"; done
HOLES="$R10/holes.log"
DATA=/Users/bob/devlop/mootx01-ce-lme/apps/mcp-benchmarker/fixtures/longmemeval/data
CORPUS="$DATA/longmemeval_s_cleaned.json"
SB10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mcp-benchmarker/.build/release/mcp-benchmarker
RB10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs
SB11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mcp-benchmarker/.build/release/mcp-benchmarker
RB11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs
M10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mootx01/.build/release/mootx01
M11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mootx01/.build/release/mootx01
for f in "$SB10" "$RB10" "$SB11" "$RB11" "$M10" "$M11" "$CORPUS"; do
  [ -e "$f" ] || { echo "$(TS) ABORT missing: $f"; exit 1; }
done
echo "$(TS) Pre-flight passed. 8 LME runs, seed 20260725, 50q, fixed ordering."

run_leg() { # id log json cmd...
  local id="$1" log="$2"; shift 2
  echo "$(TS) START  $id"
  if "$@" > "$log" 2>&1; then
    echo "$(TS) DONE   $id"
  else
    echo "$(TS) HOLE   $id (exit $?)"; echo "HOLE: $id" >> "$HOLES"
  fi
}

# 1.0.x drain (uncontaminated baseline re-measure)
run_leg 1.0.x-lme-swift-drain "$R10/lme-swift-drain.log" \
  "$SB10" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M10" \
  --limit 50 --seed 20260725 --encode-barrier drain --out "$R10/1.0.x-lme-swift-drain"
run_leg 1.0.x-lme-rust-drain "$R10/lme-rust-drain.log" \
  "$RB10" longmemeval --corpus "$CORPUS" --variant s --mootx01-binary "$M10" \
  --limit 50 --seed 20260725 --encode-barrier drain --out "$R10/1.0.x-lme-rust-drain"
# 1.1.x drain (the real cross-line recall comparison)
run_leg 1.1.x-lme-swift-drain "$R11/lme-swift-drain.log" \
  "$SB11" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M11" \
  --limit 50 --seed 20260725 --encode-barrier drain --out "$R11/1.1.x-lme-swift-drain"
run_leg 1.1.x-lme-rust-drain "$R11/lme-rust-drain.log" \
  "$RB11" longmemeval --corpus "$CORPUS" --variant s --mootx01-binary "$M11" \
  --limit 50 --seed 20260725 --encode-barrier drain --out "$R11/1.1.x-lme-rust-drain"
# impatient proof cells (basis fix, uncontaminated)
run_leg 1.0.x-lme-swift-impatient "$R10/lme-swift-impatient.log" \
  "$SB10" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M10" \
  --limit 50 --seed 20260725 --encode-barrier impatient --out "$R10/1.0.x-lme-swift-impatient"
run_leg 1.0.x-lme-rust-impatient "$R10/lme-rust-impatient.log" \
  "$RB10" longmemeval --corpus "$CORPUS" --variant s --mootx01-binary "$M10" \
  --limit 50 --seed 20260725 --encode-barrier impatient --out "$R10/1.0.x-lme-rust-impatient"
run_leg 1.1.x-lme-swift-impatient "$R11/lme-swift-impatient.log" \
  "$SB11" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M11" \
  --limit 50 --seed 20260725 --encode-barrier impatient --out "$R11/1.1.x-lme-swift-impatient"
run_leg 1.1.x-lme-rust-impatient "$R11/lme-rust-impatient.log" \
  "$RB11" longmemeval --corpus "$CORPUS" --variant s --mootx01-binary "$M11" \
  --limit 50 --seed 20260725 --encode-barrier impatient --out "$R11/1.1.x-lme-rust-impatient"
echo "$(TS) ALL LEGS COMPLETE"
