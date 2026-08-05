#!/usr/bin/env bash
# check-harness-builds-clean.sh
#
# Forces a clean rebuild of the conformance harness on both ports,
# then runs Swift and Rust validate-vectors against each vector file.
# Catches the
# "stale release binary" class of bug where the harness compiles
# from cache against a pre-refactor substrate-lib snapshot.
#
# Run before every release tag, after any change that touches:
#   - the substrate package layout (Types/Kernel/ML/Lib moves)
#   - Cargo feature gating (simd-nightly, serde-support, etc.)
#   - the harness's own primitive registry
#
# Exit 0 = harness clean-builds + all conformant primitives PASS
# Exit 1 = build failure or any conformance FAIL

set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# This check deliberately builds from scratch, and `cargo clean` erases the
# WHOLE target directory. The repo otherwise shares one target directory per
# checkout, so inheriting it here would wipe every other workspace's artifacts.
# Pin the harness to its own target/ so the clean stays local — and so the
# `rust/target/release/...` lookups further down resolve.
export CARGO_TARGET_DIR="$HERE/rust/target"

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
echo "=== full conformant-primitive 4-way conformance ==="
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
echo "PASS — harness rebuilds clean + all conformant primitives conformance-gated"
