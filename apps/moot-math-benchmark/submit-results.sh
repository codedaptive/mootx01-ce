#!/usr/bin/env bash
#
# submit-results.sh — run moot-math-benchmark and bundle the output into a
# single submission-ready bundle.
#
# The bundle is a directory with:
#   - all six JSON files (Rust + Swift × stress + topk + ml-bench)
#   - a SUBMISSION.md the maintainers read
#   - a system-report.txt with /proc/cpuinfo, uname -a, etc.
#
# Run from the repo root or from this directory. The bundle is named
# results/<date>-<hardware-tag>/ and the contents are git-add-ready.
#
# Usage:
#   apps/moot-math-benchmark/submit-results.sh                  # full sweep
#   apps/moot-math-benchmark/submit-results.sh --quick          # smoke run
#   apps/moot-math-benchmark/submit-results.sh --tag MY-RIG     # override hw tag
#
# This script handles only the Rust + Swift ports that ship with the
# project. To include Go or Python results, run those binaries
# separately and drop their JSON into the same bundle directory
# before opening the PR.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

QUICK=""
TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --quick) QUICK="--quick"; shift ;;
        --tag)   TAG="$2"; shift 2 ;;
        *) echo "unknown arg: $1"; exit 2 ;;
    esac
done

# ---- hardware tag ----------------------------------------------------
detect_tag() {
    local os arch cpu
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    if [ "$os" = "darwin" ]; then
        cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null | \
               sed -E 's/Apple //; s/[[:space:]]+/-/g' | tr '[:upper:]' '[:lower:]')"
        echo "apple-${cpu}"
    elif [ -r /proc/cpuinfo ]; then
        cpu="$(grep -m1 'model name' /proc/cpuinfo | sed -E 's/.*: //; s/[[:space:]]+/-/g' | \
               tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
        echo "${cpu}"
    else
        echo "${os}-${arch}"
    fi
}

if [ -z "$TAG" ]; then
    TAG="$(detect_tag)"
fi
DATE="$(date -u +%Y-%m-%d)"
BUNDLE="results/${DATE}-${TAG}"

mkdir -p "$BUNDLE"

# ---- run all four benches -------------------------------------------
echo "==> moot-math-benchmark bundle: $BUNDLE"
echo "==> $(date)"
echo ""

run_bin() {
    local label="$1" cmd="$2" out="$3"
    echo "==> $label  → $out"
    # Quote $out so paths with spaces survive eval; check PIPESTATUS so
    # `tail` doesn't swallow non-zero exits from the bench binary.
    eval "$cmd $QUICK --out \"$out\"" 2>&1 | tail -3
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
        echo "    OK"
    else
        echo "    FAILED — bundle will be incomplete"
    fi
    echo ""
}

(
    cd rust
    run_bin "rust topk-bench   " "cargo run --release --quiet --bin topk-bench --"   "../$BUNDLE/hamming_topk-rust.json"
    run_bin "rust stress-test  " "cargo run --release --quiet --bin stress-test --"  "../$BUNDLE/"
    run_bin "rust ml-bench     " "cargo run --release --quiet --bin ml-bench --"     "../$BUNDLE/substrate_ml-rust.json"
)

(
    cd swift
    swift build -c release 2>&1 | tail -1
    run_bin "swift topk-bench  " ".build/release/topk-bench"  "../$BUNDLE/hamming_topk-swift.json"
    run_bin "swift stress-test " ".build/release/stress-test" "../$BUNDLE/"
    run_bin "swift ml-bench    " ".build/release/ml-bench"    "../$BUNDLE/substrate_ml-swift.json"
)

# ---- system report ---------------------------------------------------
echo "==> system report"
{
    echo "moot-math-benchmark submission — system report"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Bundle:    $BUNDLE"
    echo ""
    echo "=== uname -a ==="
    uname -a
    echo ""
    echo "=== git HEAD ==="
    (cd ../.. && git rev-parse HEAD 2>/dev/null || echo "n/a")
    (cd ../.. && git status --short 2>/dev/null | head -10)
    echo ""
    echo "=== Swift toolchain ==="
    swift --version 2>&1 | head -3
    echo ""
    echo "=== Rust toolchain ==="
    rustc --version 2>&1
    echo ""
    if [ -r /proc/cpuinfo ]; then
        echo "=== /proc/cpuinfo (first block) ==="
        awk '/^$/ {exit} {print}' /proc/cpuinfo
        echo ""
        echo "=== /proc/meminfo (first 5 lines) ==="
        head -5 /proc/meminfo
    elif [ "$(uname -s)" = "Darwin" ]; then
        echo "=== sysctl machdep.cpu ==="
        sysctl machdep.cpu 2>&1 | head -20
        echo ""
        echo "=== sysctl hw.memsize / hw.ncpu ==="
        sysctl hw.memsize hw.ncpu hw.physicalcpu hw.logicalcpu 2>&1
    fi
} > "$BUNDLE/system-report.txt"
echo "    wrote $BUNDLE/system-report.txt"
echo ""

# ---- submission template --------------------------------------------
cat > "$BUNDLE/SUBMISSION.md" << SUBMD_EOF
# moot-math-benchmark submission — ${TAG} — ${DATE}

Hardware tag: \`${TAG}\`
Bundle path:  \`apps/moot-math-benchmark/${BUNDLE}/\`
Bench mode:   $( [ -n "$QUICK" ] && echo "quick (smoke)" || echo "full sweep" )

## Hardware

<!-- Fill in. Maintainers will use this to interpret the numbers. -->

- **CPU model:**
- **Core count (P / E):**
- **RAM:**
- **OS + version:**
- **Notable:** (laptop on battery? thermal-throttled? cloud VM?)

## Files in this bundle

$(ls "$BUNDLE" | sed 's/^/- /')

## How to re-run

\`\`\`sh
apps/moot-math-benchmark/submit-results.sh --tag ${TAG}$( [ -n "$QUICK" ] && echo " --quick" )
\`\`\`

## Notes

<!-- Anything maintainers should know: anomalies, hardware peculiarities,
     whether you had other processes running, etc. -->
SUBMD_EOF
echo "    wrote $BUNDLE/SUBMISSION.md"
echo ""

# ---- summary ---------------------------------------------------------
echo "==> bundle complete"
echo ""
ls -lh "$BUNDLE"
echo ""
echo "Next steps:"
echo "  1. Open $BUNDLE/SUBMISSION.md and fill in the hardware fields."
echo "  2. (Optional) Run Go or Python ports and add their JSON to the bundle."
echo "  3. git add apps/moot-math-benchmark/$BUNDLE"
echo "  4. git commit -m 'bench: ${TAG} ${DATE}'"
echo "  5. Open a PR."
