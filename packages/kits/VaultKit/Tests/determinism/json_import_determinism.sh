#!/bin/bash
# json_import_determinism.sh — MXE-JI-1 Part 6 verification script.
#
# Benchmark-agnostic; runnable by Adams in post-flight and by Skippy
# post-merge against the built products of both ports. Proves, by
# execution rather than prose:
#   (a) a malformed seed file performs zero writes and the lane errors,
#   (b) a lineage collision is a hard error,
#   (c) the same seed imported twice into fresh estates produces
#       byte-identical drawer/fact/tunnel inventories (per port),
#   (d) the same seed through Swift and Rust produces identical
#       inventories (byte-compared here, across ports).
#
# (a)-(c) are enforced by the JsonImportDeterminism harness suites (Swift)
# and json_import_determinism tests (Rust); a regression fails those runs
# and this script exits nonzero. (d) is the diff below.
#
# STUB GUARD: an unimplemented path MUST exit nonzero. `swift test
# --filter` and `cargo test <filter>` exit 0 when a filter matches zero
# tests, so this script independently verifies each harness actually ran
# and wrote a non-empty inventory; a missing/empty inventory is a FAILURE.
set -euo pipefail

VAULTKIT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULTKIT_DIR"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "[1/3] Swift determinism harness (swift test --filter JsonImportDeterminism)"
JI_INVENTORY_OUT="$OUT/swift_inventory.txt" swift test --filter JsonImportDeterminism
if ! [ -s "$OUT/swift_inventory.txt" ]; then
    echo "FAIL: the Swift harness did not write an inventory — the harness did not run (stub-exits-0 guard)" >&2
    exit 1
fi

echo "[2/3] Rust determinism harness (cargo test json_import_determinism)"
(cd rust && JI_INVENTORY_OUT="$OUT/rust_inventory.txt" cargo test --offline --lib json_import_determinism)
if ! [ -s "$OUT/rust_inventory.txt" ]; then
    echo "FAIL: the Rust harness did not write an inventory — the harness did not run (stub-exits-0 guard)" >&2
    exit 1
fi

echo "[3/3] Cross-port inventory comparison (byte-for-byte)"
if ! diff -u "$OUT/swift_inventory.txt" "$OUT/rust_inventory.txt"; then
    echo "FAIL: Swift and Rust inventories differ for the same seed file" >&2
    exit 1
fi

LINES="$(wc -l < "$OUT/swift_inventory.txt" | tr -d ' ')"
if [ "$LINES" -ne 8 ]; then
    echo "FAIL: inventory carries $LINES lines; the determinism seed builds exactly 8 (4 drawers + 2 facts + 2 tunnels)" >&2
    exit 1
fi

echo "DETERMINISTIC: malformed→zero-writes, collision→hard-error, double-run and cross-port inventories byte-identical ($LINES rows)"
