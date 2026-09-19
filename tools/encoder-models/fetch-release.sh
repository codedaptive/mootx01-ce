#!/usr/bin/env bash
# fetch-release.sh — download and verify a pinned model release asset.
#
# Usage:
#   tools/encoder-models/fetch-release.sh apple <dest-dir> [model-id]
#   tools/encoder-models/fetch-release.sh linux <dest-dir> [model-id]
#
# model-id selects the release: arctic-embed-s-w60 (default; the recall
# encoder) or nuextract-tiny-v1.5 (the fact extractor). Each model pins its
# release tag, its two platform tarballs with their sha256, and the manifest
# and verifier that check every extracted file. Downloads the asset for the
# pinned tag, verifies the tarball sha256, extracts, then verifies every file
# against the platform manifest through manifest_tools.py. Idempotent: if
# <dest-dir> already contains a fully-verified layout the script exits 0
# without re-downloading.
#
# CI and developer fetches both use this script. A fetch or verify failure
# exits non-zero so the caller fails the job.
#
# Requires: curl or wget, sha256sum or shasum, tar, python3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Pinned release coordinates ─────────────────────────────────────────────

# Which repository holds the model releases. Resolved from the checkout's own
# origin rather than written down, because the two editions publish the same
# tags on their own repositories and a hard-coded owner/repo would send one
# edition's build at the other's releases. GITHUB_REPOSITORY is set by Actions;
# the git remote covers a developer fetch; MOOTX01_REPO overrides both.
resolve_repo() {
    if [ -n "${MOOTX01_REPO:-}" ]; then printf '%s' "${MOOTX01_REPO}"; return; fi
    if [ -n "${GITHUB_REPOSITORY:-}" ]; then printf '%s' "${GITHUB_REPOSITORY}"; return; fi
    local url
    if ! url="$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null)"; then
        echo "fetch-release: cannot resolve the release repository — set MOOTX01_REPO" >&2
        exit 1
    fi
    # Both remote forms: git@host:owner/repo.git and https://host/owner/repo.git.
    # An https origin may carry credentials as user:token@host, so the userinfo
    # is dropped before anything else looks for the host separator — REPO is
    # echoed and handed to the downloader, and a token that survived the parse
    # would travel with it.
    url="${url%.git}"
    url="${url%/}"
    url="${url#*://}"         # scheme, if any
    url="${url##*@}"          # userinfo, and the scp form's user
    url="${url#*[:/]}"        # the host, however it is separated from the path
    printf '%s' "${url}"
}

# Whatever the source, REPO reaches a download URL and a command line, so it is
# held to the shape GitHub gives a repository: one owner, one name, and the
# characters GitHub allows in them. A parse that kept a host, a port or a
# credential fails here rather than travelling.
require_repo_slug() {
    case "$1" in
        *[!A-Za-z0-9._/-]*) ;;   # a character outside an owner/repo slug
        */*/*)              ;;   # more than one separator
        /* | */)            ;;   # empty owner or empty name
        */*)                return 0 ;;
        *)                  ;;   # no separator at all
    esac
    # The rejected value is not echoed: the case this guards is an origin
    # carrying a credential, and naming it here would put it in the log the
    # guard exists to keep it out of.
    echo "fetch-release: the release repository did not resolve to owner/repo — set MOOTX01_REPO" >&2
    exit 1
}
REPO="$(resolve_repo)"
require_repo_slug "${REPO}"

# Pinned tarball sha256 values are sourced from each release's SHA256SUMS asset.
# select_model <model-id> fills RELEASE_TAG, APPLE_ASSET, APPLE_SHA256,
# LINUX_ASSET, LINUX_SHA256, MANIFEST_PREFIX and VERIFY_MODE for the model.
select_model() {
    MODEL_ID="$1"
    case "${MODEL_ID}" in
        arctic-embed-s-w60)
            RELEASE_TAG="models-arctic-embed-s-w60"
            APPLE_ASSET="arctic-embed-s-w60-apple.tar.gz"
            # ADR-029: the Apple asset is the Core AI ArcticEmbedS.aimodel plus vocab.txt.
            APPLE_SHA256="dad804e6e4326b77d7fed9424c9ac21c7505b6fa710197d4024277b48ab3ffb8"
            LINUX_ASSET="arctic-embed-s-w60-linux.tar.gz"
            LINUX_SHA256="5f71131f1452c15da4f94481b7b1e3fbf7d9ad9b67289e39a3e8b964f100533c"
            MANIFEST_PREFIX="encoder-models"
            VERIFY_MODE="encoder"
            ;;
        ms-marco-minilm-l6-cross-v1)
            # The retrieval-time cross encoder (CROSSENCODER_SPEC): Core AI
            # MsMarcoMinilmL6CrossV1.aimodel plus vocab.txt on Apple, the HF
            # triple plus vocab.txt on Linux.
            RELEASE_TAG="models-ms-marco-minilm-l6-cross-v1"
            APPLE_ASSET="ms-marco-minilm-l6-cross-v1-apple.tar.gz"
            APPLE_SHA256="a4dfbc3ae0a13b1ec9f95940b9e0bb54931ae3d9942cfe8426179b09ce52cdf9"
            LINUX_ASSET="ms-marco-minilm-l6-cross-v1-linux.tar.gz"
            LINUX_SHA256="4e651c91e9a6c60ab811c4b21ca43d566ab70340e5d1bee9bb52613677ab586f"
            MANIFEST_PREFIX="cross-encoder-models"
            VERIFY_MODE="cross-encoder"
            ;;
        nuextract-tiny-v1.5)
            RELEASE_TAG="models-nuextract-tiny-v1.5"
            APPLE_ASSET="nuextract-tiny-v1.5-apple.tar.gz"
            APPLE_SHA256="14ff343271c1c565832b76f2c881bfc59ab6dd8ecf36264e660cf7ed7c3bbc87"
            LINUX_ASSET="nuextract-tiny-v1.5-linux.tar.gz"
            LINUX_SHA256="249523f61aa36a3fbef9ce9fcb38b30f88b4a16b9728cbb3bb990a2c48892030"
            MANIFEST_PREFIX="nuextract-models"
            VERIFY_MODE="nuextract"
            ;;
        *)
            die "unknown model-id '${MODEL_ID}'; use arctic-embed-s-w60, ms-marco-minilm-l6-cross-v1 or nuextract-tiny-v1.5"
            ;;
    esac
}

# verify_layout <root> runs the manifest verifier for the selected model. The
# encoder verifier re-derives the registry identity (Arctic geometry), the
# NuExtract verifier checks the fact-extractor manifest's digests and hashes.
verify_layout() {
    local root="$1"
    case "${VERIFY_MODE}" in
        encoder)
            "${PYTHON_BIN}" "${SCRIPT_DIR}/manifest_tools.py" verify \
                --manifest "${MANIFEST_FILE}" \
                --root "${root}" \
                --platform "${PLATFORM}" \
                --model-id "${MODEL_ID}" \
                --hf-repo "Snowflake/snowflake-arctic-embed-s" \
                --revision "e596f507467533e48a2e17c007f0e1dacc837b33" \
                --dim 384 \
                --pooling cls \
                --query-prefix "Represent this sentence for searching relevant passages: " \
                --doc-prefix "" \
                --window-words 60 \
                --overlap-divisor 2 \
                --max-spans 32 \
                --max-sequence 512
            ;;
        cross-encoder)
            "${PYTHON_BIN}" "${SCRIPT_DIR}/manifest_tools.py" verify-cross \
                --manifest "${MANIFEST_FILE}" \
                --root "${root}" \
                --platform "${PLATFORM}" \
                --model-id "${MODEL_ID}" \
                --hf-repo "cross-encoder/ms-marco-MiniLM-L-6-v2" \
                --revision "233902d25c440f23af6f7d6e94d2946bac0bee0a" \
                --max-sequence 512 \
                --pool 50 \
                --head 30 \
                --spans 3 \
                --rrf-k 60
            ;;
        nuextract)
            "${PYTHON_BIN}" "${SCRIPT_DIR}/manifest_tools.py" verify-nuextract \
                --manifest "${MANIFEST_FILE}" \
                --root "${root}" \
                --platform "${PLATFORM}"
            ;;
    esac
}

# ── Helpers ───────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: fetch-release.sh <apple|linux> <dest-dir> [model-id]

Downloads the pinned release asset of model-id (arctic-embed-s-w60 by default,
or nuextract-tiny-v1.5) for the given platform, verifies its tarball sha256,
extracts, and verifies every file through manifest_tools.py. Idempotent: an
already-verified dest-dir is left intact.

Options (via environment):
  MOOTX01_REPO  GitHub owner/repo (default: this checkout's own origin)
  GH_TOKEN      GitHub token for authenticated downloads (optional)
  PYTHON_BIN    Python interpreter (default: python3)
  FETCH_NOCACHE Set to 1 to force re-download even if dest-dir is verified
EOF
}

die() { echo "fetch-release: $*" >&2; exit 1; }

sha256_file() {
    # Prefer sha256sum (Linux/GNU) then shasum -a 256 (macOS).
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "no SHA-256 tool found; install sha256sum or shasum"
    fi
}

download_asset() {
    # download_asset <repo> <tag> <asset-name> <dest-file>
    # Uses gh CLI when available (handles private-repo auth transparently).
    # Falls back to curl/wget with GH_TOKEN when gh is not on PATH.
    local repo="$1" tag="$2" asset="$3" dest="$4"
    if command -v gh >/dev/null 2>&1; then
        gh release download "${tag}" -R "${repo}" -p "${asset}" -O "${dest}"
    elif command -v curl >/dev/null 2>&1; then
        local url="https://github.com/${repo}/releases/download/${tag}/${asset}"
        if [ -n "${GH_TOKEN:-}" ]; then
            curl -fsSL -H "Authorization: token ${GH_TOKEN}" "${url}" -o "${dest}"
        else
            curl -fsSL "${url}" -o "${dest}"
        fi
    elif command -v wget >/dev/null 2>&1; then
        local url="https://github.com/${repo}/releases/download/${tag}/${asset}"
        if [ -n "${GH_TOKEN:-}" ]; then
            wget -qO "${dest}" --header="Authorization: token ${GH_TOKEN}" "${url}"
        else
            wget -qO "${dest}" "${url}"
        fi
    else
        die "gh, curl, and wget are all absent — cannot download asset"
    fi
}

# validate_archive_members rejects absolute paths and '..' components (zip-slip
# prevention), matching the containment semantics of the Shell and Swift
# installer paths.
validate_archive_members() {
    local archive="$1"
    local bad=""
    while IFS= read -r member; do
        case "${member}" in
            /*) bad="${member}"; break ;;
        esac
        local IFS_save="$IFS"
        IFS='/'
        # shellcheck disable=SC2086
        set -- ${member}
        IFS="$IFS_save"
        for part; do
            if [ "${part}" = ".." ]; then
                bad="${member}"; break 2
            fi
        done
    done < <(tar -tzf "${archive}")
    if [ -n "${bad}" ]; then
        die "archive rejected: unsafe member '${bad}' (zip-slip prevention)"
    fi
}

# ── Arguments ─────────────────────────────────────────────────────────────────

if [ $# -lt 2 ]; then
    usage >&2
    exit 1
fi

PLATFORM="$1"
DEST_DIR="$2"
select_model "${3:-arctic-embed-s-w60}"

case "${PLATFORM}" in
    apple) ASSET="${APPLE_ASSET}"; EXPECTED_SHA256="${APPLE_SHA256}" ;;
    linux) ASSET="${LINUX_ASSET}"; EXPECTED_SHA256="${LINUX_SHA256}" ;;
    *) die "unknown platform '${PLATFORM}'; use apple or linux" ;;
esac

MANIFEST_FILE="${SCRIPT_DIR}/${MANIFEST_PREFIX}-${PLATFORM}.json"
[ -f "${MANIFEST_FILE}" ] || die "manifest not found: ${MANIFEST_FILE}"

PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "${PYTHON_BIN}" >/dev/null 2>&1 || die "python not found: ${PYTHON_BIN}"

# ── Idempotency check ─────────────────────────────────────────────────────────
# If the dest-dir already exists and manifest_tools.py confirms it, skip the
# download. Suppressed when FETCH_NOCACHE=1 is set.

if [ "${FETCH_NOCACHE:-0}" != "1" ] && [ -d "${DEST_DIR}" ]; then
    echo "fetch-release: dest-dir exists, running idempotency check..."
    if verify_layout "${DEST_DIR}" 2>/dev/null; then
        echo "fetch-release: ${DEST_DIR} already verified — nothing to do"
        exit 0
    fi
    echo "fetch-release: dest-dir present but not verified; re-fetching"
fi

# ── Download ──────────────────────────────────────────────────────────────────

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

echo "fetch-release: downloading ${ASSET} from ${REPO} tag ${RELEASE_TAG}..."
download_asset "${REPO}" "${RELEASE_TAG}" "${ASSET}" "${TMPDIR}/${ASSET}"

# ── Tarball sha256 verification ───────────────────────────────────────────────

echo "fetch-release: verifying tarball sha256..."
ACTUAL_SHA256="$(sha256_file "${TMPDIR}/${ASSET}")"
if [ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]; then
    die "tarball sha256 mismatch for ${ASSET}
  expected: ${EXPECTED_SHA256}
  actual:   ${ACTUAL_SHA256}"
fi
echo "fetch-release: tarball sha256 OK"

# ── Archive containment check ─────────────────────────────────────────────────

echo "fetch-release: checking archive members..."
validate_archive_members "${TMPDIR}/${ASSET}"

# ── Extraction ────────────────────────────────────────────────────────────────

echo "fetch-release: extracting to ${TMPDIR}/extract..."
mkdir -p "${TMPDIR}/extract"
tar -xzf "${TMPDIR}/${ASSET}" -C "${TMPDIR}/extract"

# ── Install to dest-dir ───────────────────────────────────────────────────────

# The model directory in the tarball is named by MODEL_ID. Replace any
# partially-extracted dest-dir atomically: extract to a sibling, then rename.
PARENT_DIR="$(dirname "${DEST_DIR}")"
mkdir -p "${PARENT_DIR}"

if [ -d "${TMPDIR}/extract/${MODEL_ID}" ]; then
    EXTRACTED_ROOT="${TMPDIR}/extract/${MODEL_ID}"
else
    # Fallback: tarball members are flat (no subdirectory wrapper).
    EXTRACTED_ROOT="${TMPDIR}/extract"
fi

STAGING="${TMPDIR}/staging-${MODEL_ID}"
cp -r "${EXTRACTED_ROOT}" "${STAGING}"

# Replace dest-dir atomically when possible.
if [ -d "${DEST_DIR}" ]; then
    OLD="${TMPDIR}/old-model"
    mv "${DEST_DIR}" "${OLD}"
fi
mv "${STAGING}" "${DEST_DIR}"

# ── Manifest verification ─────────────────────────────────────────────────────

echo "fetch-release: verifying files against ${PLATFORM} manifest..."
verify_layout "${DEST_DIR}"

echo "fetch-release: ${PLATFORM} model verified at ${DEST_DIR}"
