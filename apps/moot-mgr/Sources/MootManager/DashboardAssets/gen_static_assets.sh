#!/usr/bin/env bash
#
# gen_static_assets.sh — regenerate StaticAssets.swift from the editable
# DashboardAssets/ source files (index.html, app.css, app.js, semantic-zoom.mjs).
#
# The dashboard's HTML/CSS/JS live as readable, diffable source files in this
# directory, but the resident host serves them as in-binary string constants
# (StaticAssets.swift) so the host is a single self-contained binary with no
# filesystem static-root (and therefore no path-traversal surface). This script
# is the one-way sync: edit the asset files, run this, commit both.
#
# Usage:
#   gen_static_assets.sh              — writes to the default source-tree path
#   gen_static_assets.sh <out_path>   — writes to <out_path> instead (used by
#                                       the CI lint gate to write to a temp file
#                                       for comparison without touching the live
#                                       StaticAssets.swift)
#
# It embeds each asset in a Swift extended-delimiter raw string ( #"""..."""# )
# so no character in the assets needs escaping. If an asset ever contains the
# closing delimiter sequence, this script aborts (raise the delimiter then).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# Optional output-path override for CI lint gate temp-dir comparisons.
out="${1:-$here/../StaticAssets.swift}"

# Fast exit: skip regeneration when the output is already newer than every
# asset source. Keeps incremental builds fast when DashboardAssets/ is unchanged.
if [ -f "$out" ] && \
   [ "$out" -nt "$here/index.html" ] && \
   [ "$out" -nt "$here/app.css" ] && \
   [ "$out" -nt "$here/app.js" ] && \
   [ "$out" -nt "$here/semantic-zoom.mjs" ] && \
   [ "$out" -nt "$here/three.min.js" ] && \
   [ "$out" -nt "$here/OrbitControls.js" ]; then
  echo "StaticAssets.swift is up to date, skipping regeneration"
  exit 0
fi

for f in index.html app.css app.js semantic-zoom.mjs three.min.js OrbitControls.js; do
  if grep -qF '"""##' "$here/$f"; then
    echo "ERROR: $f contains the raw-string close delimiter; raise the delimiter." >&2
    exit 1
  fi
done

# Two-pound delimiter (##"""..."""##) so that \#( in Three.js is treated
# as literal text, not Swift string interpolation (which is \##( at this level).
emit_asset() {
  local var="$1" file="$2"
  printf '    static let %s = ##"""\n' "$var"
  cat "$here/$file"
  printf '\n"""##\n\n'
}

{
  cat <<'HEADER'
// StaticAssets.swift
//
// GENERATED — do not hand-edit. Regenerate with:
//   apps/moot-mgr/Sources/MootManager/DashboardAssets/gen_static_assets.sh
//
// The moot-mgr read-plane dashboard's HTML/CSS/JS, embedded as in-binary
// constants. The resident host serves these from the loopback HTTP listener
// (HTTPReadAPI) so the host ships as one self-contained binary with NO
// filesystem static-root. Because lookups go through a fixed allow-list
// (`asset(for:)`) rather than mapping a request path onto a directory, there is
// no path-traversal surface (§Security). The editable source
// of truth is DashboardAssets/{index.html,app.css,app.js,semantic-zoom.mjs}.

import Foundation

// MARK: - StaticAssets

/// The embedded dashboard assets and the content-type allow-list used by the
/// loopback HTTP read-API to serve the read-plane web UI.
enum StaticAssets {

    // MARK: Embedded asset bodies (generated)

HEADER

  emit_asset indexHTML index.html
  emit_asset appCSS app.css
  emit_asset appJS app.js
  emit_asset semanticZoomJS semantic-zoom.mjs
  emit_asset threeJS three.min.js
  emit_asset orbitControlsJS OrbitControls.js

  cat <<'FOOTER'
    // MARK: Lookup

    /// One served asset: its body text and its HTTP `Content-Type`.
    struct Asset: Sendable {
        let body: String
        let contentType: String
    }

    /// Resolve a request path to an embedded asset, or `nil` for anything not on
    /// the allow-list. The list is fixed (no directory mapping), so an arbitrary
    /// path cannot escape it. Everything else returns `nil` and the caller answers 404.
    static func asset(for path: String) -> Asset? {
        let bare = path.split(separator: "?").first.map(String.init) ?? path
        switch bare {
        case "/", "/index.html":
            return Asset(body: indexHTML, contentType: "text/html; charset=utf-8")
        case "/app.css":
            return Asset(body: appCSS, contentType: "text/css; charset=utf-8")
        case "/app.js":
            return Asset(body: appJS, contentType: "text/javascript; charset=utf-8")
        case "/semantic-zoom.mjs":
            return Asset(body: semanticZoomJS, contentType: "text/javascript; charset=utf-8")
        case "/three.min.js":
            return Asset(body: threeJS, contentType: "text/javascript; charset=utf-8")
        case "/OrbitControls.js":
            return Asset(body: orbitControlsJS, contentType: "text/javascript; charset=utf-8")
        default:
            return nil
        }
    }
}
FOOTER
} > "$out"

echo "wrote $out"
