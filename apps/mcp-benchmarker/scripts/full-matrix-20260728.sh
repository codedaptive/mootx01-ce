#!/bin/bash
# full-matrix-20260728.sh — the definitive full performance matrix on the
# all-fixes binaries. 16 cells, sequential:
#   LME auto  × {1.0.x,1.1.x} × {swift,rust}   (documented protocol, drain)
#   LME impatient × {1.0.x,1.1.x} × {swift,rust} (inline-encode proof cells)
#   LoCoMo × {1.0.x,1.1.x} × {swift,rust}
#   LMEB   × {1.0.x,1.1.x} × {swift,rust}
# Seed 20260725, 50q. Per-leg out dirs (created here — the runner does not
# mkdir its own --out). No parallelism; shared /tmp scratch namespace.
set -u
TS() { date "+[%Y-%m-%dT%H:%M:%S]"; }
R10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mcp-benchmarker/results/20260728-full-matrix
R11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mcp-benchmarker/results/20260728-full-matrix
DATA=/Users/bob/devlop/mootx01-ce-lme/apps/mcp-benchmarker/fixtures/longmemeval/data
CORPUS="$DATA/longmemeval_s_cleaned.json"
LOCOMO_JSON=/Users/bob/devlop/mootx01-ce-lme-locomo/apps/mcp-benchmarker/fixtures/locomo/locomo10.json
LMEBD=/Users/bob/devlop/mootx01-ce-lme-lmeb/apps/mcp-benchmarker/fixtures/lmeb/data/ConvoMem
SB10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mcp-benchmarker/.build/release/mcp-benchmarker
RB10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs
SB11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mcp-benchmarker/.build/release/mcp-benchmarker
RB11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs
M10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mootx01/.build/release/mootx01
M11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mootx01/.build/release/mootx01
HOLES="$R10/holes.log"; mkdir -p "$R10" "$R11"
run_leg() { local id="$1" log="$2"; shift 2
  mkdir -p "$(dirname "$log")"
  local prev="" a
  for a in "$@"; do [ "$prev" = "--out" ] && mkdir -p "$a"; prev="$a"; done
  echo "$(TS) START  $id"
  if "$@" > "$log" 2>&1; then echo "$(TS) DONE   $id"
  else local rc=$?; echo "$(TS) HOLE   $id (exit $rc)"; echo "HOLE: $id" >> "$HOLES"; fi }
# ---- LME auto (headline) ----
run_leg lme-10x-swift-auto "$R10/lme-swift-auto.log" "$SB10" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M10" --limit 50 --seed 20260725 --encode-barrier drain --exact-strategy auto --out "$R10/lme-10x-swift-auto"
run_leg lme-10x-rust-auto  "$R10/lme-rust-auto.log"  "$RB10" longmemeval --corpus "$CORPUS" --variant s --mootx01-binary "$M10" --limit 50 --seed 20260725 --encode-barrier drain --exact-strategy auto --out "$R10/lme-10x-rust-auto"
run_leg lme-11x-swift-auto "$R11/lme-swift-auto.log" "$SB11" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M11" --limit 50 --seed 20260725 --encode-barrier drain --exact-strategy auto --out "$R11/lme-11x-swift-auto"
run_leg lme-11x-rust-auto  "$R11/lme-rust-auto.log"  "$RB11" longmemeval --corpus "$CORPUS" --variant s --mootx01-binary "$M11" --limit 50 --seed 20260725 --encode-barrier drain --exact-strategy auto --out "$R11/lme-11x-rust-auto"
# ---- LME impatient (inline-encode proof, fixed engines both lines) ----
run_leg lme-10x-swift-imp "$R10/lme-swift-imp.log" "$SB10" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M10" --limit 50 --seed 20260725 --encode-barrier impatient --exact-strategy auto --out "$R10/lme-10x-swift-imp"
run_leg lme-10x-rust-imp  "$R10/lme-rust-imp.log"  "$RB10" longmemeval --corpus "$CORPUS" --variant s --mootx01-binary "$M10" --limit 50 --seed 20260725 --encode-barrier impatient --exact-strategy auto --out "$R10/lme-10x-rust-imp"
run_leg lme-11x-swift-imp "$R11/lme-swift-imp.log" "$SB11" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M11" --limit 50 --seed 20260725 --encode-barrier impatient --exact-strategy auto --out "$R11/lme-11x-swift-imp"
run_leg lme-11x-rust-imp  "$R11/lme-rust-imp.log"  "$RB11" longmemeval --corpus "$CORPUS" --variant s --mootx01-binary "$M11" --limit 50 --seed 20260725 --encode-barrier impatient --exact-strategy auto --out "$R11/lme-11x-rust-imp"
# ---- LoCoMo ----
run_leg locomo-10x-swift "$R10/locomo-swift.log" "$SB10" locomo --data-file "$LOCOMO_JSON" --mootx01-binary "$M10" --limit 50 --seed 20260725 --encode-barrier drain --out "$R10/locomo-10x-swift"
run_leg locomo-10x-rust  "$R10/locomo-rust.log"  "$RB10" locomo --data-file "$LOCOMO_JSON" --mootx01-binary "$M10" --limit 50 --seed 20260725 --encode-barrier drain --out "$R10/locomo-10x-rust"
run_leg locomo-11x-swift "$R11/locomo-swift.log" "$SB11" locomo --data-file "$LOCOMO_JSON" --mootx01-binary "$M11" --limit 50 --seed 20260725 --encode-barrier drain --out "$R11/locomo-11x-swift"
run_leg locomo-11x-rust  "$R11/locomo-rust.log"  "$RB11" locomo --data-file "$LOCOMO_JSON" --mootx01-binary "$M11" --limit 50 --seed 20260725 --encode-barrier drain --out "$R11/locomo-11x-rust"
# ---- LMEB ----
run_leg lmeb-10x-swift "$R10/lmeb-swift.log" "$SB10" lmeb --data-dir "$LMEBD" --mootx01-binary "$M10" --limit 50 --seed 20260725 --encode-barrier drain --out "$R10/lmeb-10x-swift"
run_leg lmeb-10x-rust  "$R10/lmeb-rust.log"  "$RB10" lmeb --data-dir "$LMEBD" --mootx01-binary "$M10" --limit 50 --seed 20260725 --encode-barrier drain --out "$R10/lmeb-10x-rust"
run_leg lmeb-11x-swift "$R11/lmeb-swift.log" "$SB11" lmeb --data-dir "$LMEBD" --mootx01-binary "$M11" --limit 50 --seed 20260725 --encode-barrier drain --out "$R11/lmeb-11x-swift"
run_leg lmeb-11x-rust  "$R11/lmeb-rust.log"  "$RB11" lmeb --data-dir "$LMEBD" --mootx01-binary "$M11" --limit 50 --seed 20260725 --encode-barrier drain --out "$R11/lmeb-11x-rust"
echo "$(TS) ALL LEGS COMPLETE"
