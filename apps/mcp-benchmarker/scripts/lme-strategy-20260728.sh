#!/bin/bash
# lme-strategy-20260728.sh — LME drain cells under the DOCUMENTED client
# protocol (--exact-strategy auto: byRelevanceDesc + precise escalation on low
# discrimination), plus one legacy `search` cell per line for the delta.
set -u
TS() { date "+[%Y-%m-%dT%H:%M:%S]"; }
R10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mcp-benchmarker/results/20260728-lme-strategy
R11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mcp-benchmarker/results/20260728-lme-strategy
DATA=/Users/bob/devlop/mootx01-ce-lme/apps/mcp-benchmarker/fixtures/longmemeval/data
CORPUS="$DATA/longmemeval_s_cleaned.json"
SB10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mcp-benchmarker/.build/release/mcp-benchmarker
RB10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs
SB11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mcp-benchmarker/.build/release/mcp-benchmarker
RB11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs
M10=/Users/bob/devlop/mootx01-ce-develop_1.0.x/apps/mootx01/.build/release/mootx01
M11=/Users/bob/devlop/mootx01-ce-develop_1.1.x/apps/mootx01/.build/release/mootx01
HOLES="$R10/holes.log"; mkdir -p "$R10" "$R11"
run_leg() { local id="$1" log="$2"; shift 2
  mkdir -p "$(dirname "$log")"
  # the runner does not create its --out dir; create every leg's dir here
  local prev="" a
  for a in "$@"; do [ "$prev" = "--out" ] && mkdir -p "$a"; prev="$a"; done
  echo "$(TS) START  $id"
  if "$@" > "$log" 2>&1; then echo "$(TS) DONE   $id"
  else local rc=$?; echo "$(TS) HOLE   $id (exit $rc)"; echo "HOLE: $id" >> "$HOLES"; fi }
# auto (documented protocol) — the headline cells
run_leg 1.0.x-swift-auto "$R10/swift-auto.log" "$SB10" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M10" --limit 50 --seed 20260725 --encode-barrier drain --exact-strategy auto --out "$R10/1.0.x-swift-auto"
run_leg 1.0.x-rust-auto  "$R10/rust-auto.log"  "$RB10" longmemeval --corpus "$CORPUS" --variant s --mootx01-binary "$M10" --limit 50 --seed 20260725 --encode-barrier drain --exact-strategy auto --out "$R10/1.0.x-rust-auto"
run_leg 1.1.x-swift-auto "$R11/swift-auto.log" "$SB11" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M11" --limit 50 --seed 20260725 --encode-barrier drain --exact-strategy auto --out "$R11/1.1.x-swift-auto"
run_leg 1.1.x-rust-auto  "$R11/rust-auto.log"  "$RB11" longmemeval --corpus "$CORPUS" --variant s --mootx01-binary "$M11" --limit 50 --seed 20260725 --encode-barrier drain --exact-strategy auto --out "$R11/1.1.x-rust-auto"
# legacy search — strategy delta reference (one per line)
run_leg 1.0.x-swift-search "$R10/swift-search.log" "$SB10" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M10" --limit 50 --seed 20260725 --encode-barrier drain --exact-strategy search --out "$R10/1.0.x-swift-search"
run_leg 1.1.x-swift-search "$R11/swift-search.log" "$SB11" longmemeval --data-dir "$DATA" --variant s --mootx01-binary "$M11" --limit 50 --seed 20260725 --encode-barrier drain --exact-strategy search --out "$R11/1.1.x-swift-search"
echo "$(TS) ALL LEGS COMPLETE"
