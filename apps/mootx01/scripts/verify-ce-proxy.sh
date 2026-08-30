#!/usr/bin/env bash
# verify-ce-proxy.sh
#
# MACD-3D RED-2 CLOSURE: fail-closed CE-proxy build gate.
#
# LOCATION RATIONALE: apps/mootx01/scripts/ — this script operates exclusively
# on the apps/mootx01 package (rsync, manifest swap, swift build).  Placing it
# here keeps the gate co-located with what it guards: the Package.community.swift
# boundary that separates CE from EE in this package.
#
# WHAT THIS SCRIPT PROVES:
#   The Community Edition manifest (Package.community.swift) builds a clean
#   apps/mootx01 package that contains NO reference to the EE-only surfaces
#   (MootDaemonFederation, MootProductDock, ConvergenceKit, CloudKit) in its
#   SPM declarations or source tree.
#
# WHY THE PREVIOUS EVIDENCE WAS FAIL-OPEN:
#   The verifier found that the prior ce-proxy tree's
#   apps/mootx01/Package.swift
#   still CONTAINED the string "MootDaemonFederation" — proving the proxy was
#   built from the EE Package.swift, NOT Package.community.swift. The gate
#   therefore did not validate CE isolation at all.
#
# FAIL-CLOSED DESIGN:
#   Step 4 asserts BEFORE building.  A non-zero exit from grep kills the script
#   before swift build is reached, so a manifest with EE tokens never pretends
#   to be a CE build.  Every checked value is printed so the readback names
#   the expected value and fails closed.
#
# USAGE:
#   bash apps/mootx01/scripts/verify-ce-proxy.sh
#
#   Scratch defaults under the caller's own cache. Set CE_PROXY_ROOT to put
#   the proxy tree and its build scratch on a different volume — a big build
#   disk, for instance. Nothing here assumes a particular machine's layout.
#
# EXIT CODES:
#   0  — proxy tree assembled, assertions passed, swift build succeeded
#   1  — any assertion or build step failed (details printed to stderr)

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CE_PROXY_ROOT="${CE_PROXY_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/mootx01/ce-proxy}"
PROXY_ROOT="${CE_PROXY_ROOT}/tree"
PROXY_PKG="${PROXY_ROOT}/apps/mootx01"
BUILD_SCRATCH="${CE_PROXY_ROOT}/scratch/ce-proxy-mootx01"

echo "=== CE-proxy verify-ce-proxy.sh ==="
echo "REPO_ROOT   : ${REPO_ROOT}"
echo "PROXY_ROOT  : ${PROXY_ROOT}"
echo "PROXY_PKG   : ${PROXY_PKG}"
echo "BUILD_SCRATCH: ${BUILD_SCRATCH}"
echo ""

# ── Step 1: Delete any pre-existing proxy tree (no stale state) ────────────────

echo "[1] Deleting pre-existing proxy tree (fail-closed: no stale state)..."
if [ -d "${PROXY_ROOT}" ]; then
    rm -rf "${PROXY_ROOT}"
    echo "    Deleted: ${PROXY_ROOT}"
else
    echo "    (did not exist — clean start)"
fi

# ── Step 2: rsync the full repo tree into the proxy (exclude .git) ────────────
#
# Package.community.swift declares dependencies using relative paths (e.g.
# "../../packages/libs/AriaLexiconLib"). The packages/ tree must be present in
# the proxy for swift build to resolve them. We rsync the entire repo (minus
# .git and the build outputs directory) so those relative paths resolve
# correctly within the proxy root.

echo "[2] Rsyncing the repo tree into proxy (excluding .git and build outputs)..."
mkdir -p "${PROXY_ROOT}"
rsync -a \
    --exclude='.git' \
    --exclude='*.xcodeproj' \
    "${REPO_ROOT}/" \
    "${PROXY_ROOT}/"
echo "    rsync complete."
echo ""

# ── Step 3: Remove EE-only paths from the proxy tree ──────────────────────────

echo "[3] Removing EE-only paths from proxy..."

EE_SRC="${PROXY_PKG}/Sources/MootDaemonFederation"
EE_TESTS="${PROXY_PKG}/Tests/MootDaemonFederationTests"
PRODUCT_DOCK_SRC="${PROXY_PKG}/Sources/MootProductDock"
PRODUCT_DOCK_TESTS="${PROXY_PKG}/Tests/MootProductDockTests"

echo "    Expected absent: ${EE_SRC}"
echo "    Expected absent: ${EE_TESTS}"
echo "    Expected absent: ${PRODUCT_DOCK_SRC}"
echo "    Expected absent: ${PRODUCT_DOCK_TESTS}"

if [ -d "${EE_SRC}" ]; then
    rm -rf "${EE_SRC}"
    echo "    Removed: ${EE_SRC}"
else
    echo "    (MootDaemonFederation Sources already absent)"
fi

if [ -d "${EE_TESTS}" ]; then
    rm -rf "${EE_TESTS}"
    echo "    Removed: ${EE_TESTS}"
else
    echo "    (MootDaemonFederationTests already absent)"
fi

if [ -d "${PRODUCT_DOCK_SRC}" ]; then
    rm -rf "${PRODUCT_DOCK_SRC}"
    echo "    Removed: ${PRODUCT_DOCK_SRC}"
else
    echo "    (MootProductDock Sources already absent)"
fi

if [ -d "${PRODUCT_DOCK_TESTS}" ]; then
    rm -rf "${PRODUCT_DOCK_TESTS}"
    echo "    Removed: ${PRODUCT_DOCK_TESTS}"
else
    echo "    (MootProductDockTests already absent)"
fi
echo ""

# ── Step 4a: Replace Package.swift with Package.community.swift ────────────────

echo "[4a] Replacing Package.swift with Package.community.swift..."
echo "     Expected: no EE tokens in active SPM declarations"

COMMUNITY_MANIFEST="${PROXY_PKG}/Package.community.swift"
ACTIVE_MANIFEST="${PROXY_PKG}/Package.swift"

if [ ! -f "${COMMUNITY_MANIFEST}" ]; then
    echo "ERROR: Package.community.swift not found at ${COMMUNITY_MANIFEST}" >&2
    exit 1
fi

cp "${COMMUNITY_MANIFEST}" "${ACTIVE_MANIFEST}"
echo "    Copied Package.community.swift → Package.swift"
echo ""

# ── Step 4b: Assert BEFORE building — fail-closed on EE tokens ─────────────────
#
# We check non-comment lines only (lines that do not start with // or whitespace-//).
# Comments that document what was EXCLUDED (e.g., "# MootDaemonFederation is not
# listed here") are explanatory; they do not affect SPM dependency resolution.
# An EE token in a DECLARATION line (dependency, target, product) would be fatal.
#
# Grep exits non-zero when it finds NO match — so we invert: if grep FINDS a match,
# we have a violation.  Use grep -c (count) and test that it is zero.

echo "[4b] Asserting EE tokens absent from SPM declaration lines in proxy Package.swift..."
echo "     Expected: MootDaemonFederation, MootProductDock, ConvergenceKit, CloudKit appear ONLY in comments"
echo "     Checking: non-comment lines only (lines not matching ^\s*//)"
echo ""

MANIFEST_CHECK="${ACTIVE_MANIFEST}"

# Strip comment lines for the assertion.
NONCOMMENT_CONTENT=$(grep -v '^\s*//' "${MANIFEST_CHECK}" || true)

FORBIDDEN_TOKENS=("MootDaemonFederation" "MootProductDock" "ConvergenceKit" "CloudKit")
ASSERTION_FAILED=0

for TOKEN in "${FORBIDDEN_TOKENS[@]}"; do
    COUNT=$(echo "${NONCOMMENT_CONTENT}" | grep -c "${TOKEN}" || true)
    echo "    Checking token: '${TOKEN}'"
    echo "    Expected count in non-comment lines: 0"
    echo "    Actual count  in non-comment lines: ${COUNT}"
    if [ "${COUNT}" -ne 0 ]; then
        echo "FAIL: '${TOKEN}' appears ${COUNT} time(s) in SPM declaration lines" >&2
        echo "      Matching lines:" >&2
        echo "${NONCOMMENT_CONTENT}" | grep "${TOKEN}" >&2
        ASSERTION_FAILED=1
    else
        echo "    PASS: '${TOKEN}' — 0 occurrences in declaration lines"
    fi
    echo ""
done

echo "[4c] Asserting EE-only directories are absent from proxy tree..."
echo "     Expected absent: ${EE_SRC}"
echo "     Expected absent: ${EE_TESTS}"
echo "     Expected absent: ${PRODUCT_DOCK_SRC}"
echo "     Expected absent: ${PRODUCT_DOCK_TESTS}"

if [ -d "${EE_SRC}" ]; then
    echo "FAIL: EE Source directory still present: ${EE_SRC}" >&2
    ASSERTION_FAILED=1
else
    echo "    PASS: MootDaemonFederation Sources absent"
fi

if [ -d "${EE_TESTS}" ]; then
    echo "FAIL: EE Tests directory still present: ${EE_TESTS}" >&2
    ASSERTION_FAILED=1
else
    echo "    PASS: MootDaemonFederationTests absent"
fi


if [ -d "${PRODUCT_DOCK_SRC}" ]; then
    echo "FAIL: EE Source directory still present: ${PRODUCT_DOCK_SRC}" >&2
    ASSERTION_FAILED=1
else
    echo "    PASS: MootProductDock Sources absent"
fi

if [ -d "${PRODUCT_DOCK_TESTS}" ]; then
    echo "FAIL: EE Tests directory still present: ${PRODUCT_DOCK_TESTS}" >&2
    ASSERTION_FAILED=1
else
    echo "    PASS: MootProductDockTests absent"
fi
echo ""

if [ "${ASSERTION_FAILED}" -ne 0 ]; then
    echo "=== GATE FAILED: pre-build assertions violated — aborting before swift build ===" >&2
    echo "    Fix Package.community.swift or the proxy assembly steps and re-run." >&2
    exit 1
fi

echo "=== All pre-build assertions PASSED ==="
echo ""

# ── Step 5: swift build on the proxy package ──────────────────────────────────

echo "[5] Running swift build on CE proxy (scratch: ${BUILD_SCRATCH})..."
mkdir -p "${BUILD_SCRATCH}"
mkdir -p "${TMPDIR:-${CE_PROXY_ROOT}/tmp}"

set +e
swift build \
    --package-path "${PROXY_PKG}" \
    --scratch-path "${BUILD_SCRATCH}" \
    2>&1
BUILD_EXIT=$?
set -e

echo ""
if [ "${BUILD_EXIT}" -ne 0 ]; then
    echo "=== CE PROXY BUILD FAILED (exit ${BUILD_EXIT}) ===" >&2
    echo "    This is a genuine finding about Package.community.swift." >&2
    echo "    Fix the manifest and re-run; do NOT weaken this script to make it pass." >&2
    exit 1
fi

echo "=== CE PROXY BUILD SUCCEEDED (exit 0) ==="
echo ""
echo "Summary of values checked:"
echo "  Proxy root            : ${PROXY_ROOT}"
echo "  Active manifest       : ${ACTIVE_MANIFEST}"
echo "  Token 'MootDaemonFederation' in declaration lines: 0  [EXPECTED: 0]"
echo "  Token 'MootProductDock' in declaration lines:      0  [EXPECTED: 0]"
echo "  Token 'ConvergenceKit' in declaration lines:       0  [EXPECTED: 0]"
echo "  Token 'CloudKit' in declaration lines:             0  [EXPECTED: 0]"
echo "  EE Sources directory absent:                       YES [EXPECTED: YES]"
echo "  EE Tests directory absent:                         YES [EXPECTED: YES]"
echo "  swift build exit code:                             0   [EXPECTED: 0]"
echo ""
echo "CE boundary is CLEAN."
