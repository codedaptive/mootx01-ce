#!/usr/bin/env bash
# schema-gate.sh — refuse a measured run whose artifacts predate the harness's schema.
#
# SOFT GATE, and deliberately cheap. Every artifact carries its schema version
# in artifact.json. The harness declares the schema it expects in one constant.
# This compares the two across a whole store in one pass, before the run opens
# a benchmark window, and never launches the product binary to ask.
#
# Without it the mismatch still surfaces — the provenance manifest is validated
# when an artifact is opened, and a mismatch is a hard error — but it surfaces
# PER UNIT, mid-pass, after the quiet machine has already been spent. The scan
# costs seconds and moves that discovery before the window opens.
#
# What a mismatch means: artifacts of two schema lines do NOT sit side by side.
# The store key carries no schema version, so both lines land on the same key
# and the older set simply stops opening. Rebuild it or move it aside.
#
# Usage: schema-gate.sh <cache-dir> <expected-schema>
set -uo pipefail

CACHE_DIR="${1:?usage: schema-gate.sh <cache-dir> <expected-schema>}"
EXPECTED="${2:?usage: schema-gate.sh <cache-dir> <expected-schema>}"

[ -d "$CACHE_DIR" ] || { echo "[schema-gate] no store at $CACHE_DIR"; exit 1; }

mismatched=0
checked=0
found=""
while IFS= read -r manifest; do
  v=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('estate_schema_version',''))" "$manifest" 2>/dev/null)
  checked=$((checked + 1))
  [ "$v" = "$EXPECTED" ] && continue
  mismatched=$((mismatched + 1))
  case " $found " in *" $v "*) ;; *) found="$found $v";; esac
done < <(find "$CACHE_DIR" -name artifact.json -maxdepth 3 2>/dev/null)

if [ "$checked" -eq 0 ]; then
  echo "[schema-gate] no artifacts under $CACHE_DIR — nothing to check"
  exit 0
fi

if [ "$mismatched" -gt 0 ]; then
  echo "[schema-gate] REFUSING: $mismatched of $checked artifacts carry a schema other than $EXPECTED (found:$found)."
  echo "[schema-gate] They will not open against this harness. Rebuild the set or move it aside before measuring."
  exit 1
fi

echo "[schema-gate] PASS — $checked artifacts all at schema $EXPECTED"
