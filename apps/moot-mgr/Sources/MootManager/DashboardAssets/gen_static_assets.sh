#!/usr/bin/env bash
#
# gen_static_assets.sh — regenerate StaticAssets.swift from the editable
# DashboardAssets/ source files (index.html, app.css, app.js).
#
# The dashboard's HTML/CSS/JS live as readable, diffable source files in this
# directory, but the resident host serves them as in-binary string constants
# (StaticAssets.swift) so the host is a single self-contained binary with no
# filesystem static-root (and therefore no path-traversal surface). This script
# is the one-way sync: edit the asset files, run this, commit both.
#
# It embeds each asset in a Swift extended-delimiter raw string ( #"""..."""# )
# so no character in the assets needs escaping. If an asset ever contains the
# closing delimiter sequence, this script aborts (raise the delimiter then).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../StaticAssets.swift"

for f in index.html app.css app.js sigma.js; do
  if grep -qF '"""#' "$here/$f"; then
    echo "ERROR: $f contains the raw-string close delimiter; raise the delimiter." >&2
    exit 1
  fi
done

emit_asset() {
  local var="$1" file="$2"
  printf '    static let %s = #"""\n' "$var"
  cat "$here/$file"
  printf '\n"""#\n\n'
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
// of truth is DashboardAssets/{index.html,app.css,app.js}.

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
  emit_asset sigmaJS sigma.js

  cat <<'FOOTER'
    // MARK: Lookup

    /// One served asset: its body text and its HTTP `Content-Type`.
    struct Asset: Sendable {
        let body: String
        let contentType: String
    }

    /// Resolve a request path to an embedded asset, or `nil` for anything not on
    /// the allow-list. The list is fixed (no directory mapping), so an arbitrary
    /// path cannot escape it — `/`, `/index.html`, `/app.css`, `/app.js`,
    /// `/sigma.js` only. Everything else returns `nil` and the caller answers 404.
    static func asset(for path: String) -> Asset? {
        switch path {
        case "/", "/index.html":
            return Asset(body: indexHTML, contentType: "text/html; charset=utf-8")
        case "/app.css":
            return Asset(body: appCSS, contentType: "text/css; charset=utf-8")
        case "/app.js":
            return Asset(body: appJS, contentType: "text/javascript; charset=utf-8")
        case "/sigma.js":
            // The vendored, self-contained Topology renderer (no CDN). See
            // DashboardAssets/sigma.js for why it is vendored rather than the
            // upstream graphology+Sigma bundle.
            return Asset(body: sigmaJS, contentType: "text/javascript; charset=utf-8")
        default:
            return nil
        }
    }
}
FOOTER
} > "$out"

echo "wrote $out"
