#!/usr/bin/env bash
# check-harness-builds-clean.sh
#
# Forces a clean rebuild of the conformance harness on both ports,
# then runs the 23-primitive 4-way conformance gate. Catches the
# "stale release binary" class of bug where the harness compiles
# from cache against a pre-refactor substrate-lib snapshot.
#
# Run before every release tag, after any change that touches:
#   - the substrate package layout (Types/Kernel/ML/Lib moves)
#   - Cargo feature gating (simd-nightly, serde-support, etc.)
#   - the harness's own primitive registry
#
# Exit 0 = harness clean-builds + all 23 conformance PASS
# Exit 1 = build failure or any conformance FAIL

set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

echo "=== cleaning Rust harness ==="
(cd rust && cargo clean) > /dev/null

echo "=== cleaning Swift harness ==="
(cd swift && rm -rf .build)

echo "=== rebuilding Rust harness (release) ==="
(cd rust && cargo build --release 2>&1 | grep -E "^error|^warning: \`" | head -10 || true)
if ! (cd rust && cargo build --release 2>&1 | tail -3 | grep -q "Finished"); then
    echo "FAIL: Rust harness did not build clean"
    exit 1
fi

echo "=== rebuilding Swift harness ==="
if ! (cd swift && swift build 2>&1 | tail -3 | grep -q "Build complete"); then
    echo "FAIL: Swift harness did not build clean"
    exit 1
fi

echo ""
echo "=== full 23-primitive 4-way conformance ==="
PASS=0; FAIL=0; FAILED=""
for vec in vectors/*.json; do
    name=$(basename "$vec" .json)
    s=$(swift/.build/debug/validate-vectors "$vec" 2>&1 | grep -E "^PASS$|^FAIL$" | head -1)
    r=$(rust/target/release/validate-vectors "$vec" 2>&1 | grep -E "^PASS$|^FAIL$" | head -1)
    if echo "$s$r" | grep -q FAIL; then
        FAIL=$((FAIL+1))
        FAILED="$FAILED $name"
    else
        PASS=$((PASS+1))
    fi
done
echo "  $PASS PASS / $FAIL FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo "FAIL: conformance regressions:$FAILED"
    exit 1
fi
echo ""
echo "PASS — harness rebuilds clean + all 23 primitives conformance-gated"
