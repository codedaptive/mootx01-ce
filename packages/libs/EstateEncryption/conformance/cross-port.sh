#!/usr/bin/env bash
# cross-port.sh — proves the Swift and Rust ports produce equivalent output.
#
# Usage: conformance/cross-port.sh <source.sqlite> [<source.sqlite> ...]
#
# For each source database it converts with BOTH ports, then checks:
#
#   1. each port's output opens with the key in the OTHER port
#   2. the content digest of both outputs equals the source's
#   3. the four gated row counts agree across source and both outputs
#
# It does NOT compare bytes. SQLCipher writes a random 16-byte salt at the head
# of page 1 and a random IV per page, so two correct conversions of one source
# are never byte-equal. A byte comparison here would fail on correct output,
# which is why the check is content-based.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
BENCHMARKS_DIR="$REPO/benchmarks"
RUST_SOURCE_DIR="$REPO/packages/libs/EstateEncryption/rust"
REQUESTED_WORK_ROOT="${BENCH_WORK_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/mootx01/benchmarks/$(basename "$REPO")}"
BENCH_WORK_ROOT="$(python3 "$BENCHMARKS_DIR/scripts/work-root.py" prepare \
  --repo "$REPO" --work "$REQUESTED_WORK_ROOT")" || exit 2
SWIFT_BIN="$BENCH_WORK_ROOT/build/harness-swift/release/mcp-benchmarker"
export CARGO_TARGET_DIR="$BENCH_WORK_ROOT/build/estate-encryption-conformance-rust"

# A fixed key: these databases live for the length of this script.
KEY="4d6f6f7478303120636f6e666f726d616e63652d6b65792d33322d6279746573"

[[ $# -ge 1 ]] || { echo "usage: $0 <source.sqlite> [...]"; exit 2; }

make -C "$BENCHMARKS_DIR" swift-harness BENCH_WORK_ROOT="$BENCH_WORK_ROOT"
[[ -x "$SWIFT_BIN" ]] || { echo "harness build did not produce $SWIFT_BIN"; exit 2; }

mkdir -p "$BENCH_WORK_ROOT/tmp"
work="$(mktemp -d "$BENCH_WORK_ROOT/tmp/estate-encryption-cross-port.XXXXXX")"
trap 'rm -rf "$work"' EXIT
rust_build_dir="$work/estate-encryption-rust"
mkdir -p "$rust_build_dir"
cp "$RUST_SOURCE_DIR/Cargo.toml" "$rust_build_dir/Cargo.toml"
cp -R "$RUST_SOURCE_DIR/src" "$rust_build_dir/src"
cp -R "$RUST_SOURCE_DIR/examples" "$rust_build_dir/examples"
failures=0

digest() { cargo run --manifest-path "$rust_build_dir/Cargo.toml" --offline -q --example digest -- "$@" 2>/dev/null | tail -1; }

for source in "$@"; do
  name="$(basename "$source" .sqlite)"
  echo "── $name"

  cp "$source" "$work/$name-swift-src.sqlite"
  cp "$source" "$work/$name-rust-src.sqlite"

  "$SWIFT_BIN" convert --source "$work/$name-swift-src.sqlite" \
                       --dest "$work/$name-swift.enc" --key-hex "$KEY" > /dev/null
  cargo run --manifest-path "$rust_build_dir/Cargo.toml" --offline -q --example convert -- \
       "$work/$name-rust-src.sqlite" "$work/$name-rust.enc" "$KEY" > /dev/null

  src_d="$(digest "$source")"
  sw_d="$(digest "$work/$name-swift.enc" "$KEY")"
  ru_d="$(digest "$work/$name-rust.enc" "$KEY")"

  # Each port reads the other's output.
  sw_reads_rust="$("$SWIFT_BIN" convert --verify --source "$work/$name-rust.enc" --key-hex "$KEY")"
  sw_reads_swift="$("$SWIFT_BIN" convert --verify --source "$work/$name-swift.enc" --key-hex "$KEY")"

  ok=1
  [[ "$sw_d" == "$src_d" ]] || { echo "   FAIL swift output digest != source"; ok=0; }
  [[ "$ru_d" == "$src_d" ]] || { echo "   FAIL rust output digest != source"; ok=0; }
  [[ "$sw_reads_rust" == "$sw_reads_swift" ]] || { echo "   FAIL cross-open counts differ"; ok=0; }

  if [[ $ok -eq 1 ]]; then
    echo "   PASS  $src_d"
    echo "         cross-open: $sw_reads_rust"
  else
    failures=$((failures + 1))
  fi
done

echo ""
if [[ $failures -eq 0 ]]; then
  echo "cross-port conformance: PASS ($# database(s))"
else
  echo "cross-port conformance: FAIL ($failures of $# database(s))"
  exit 1
fi
