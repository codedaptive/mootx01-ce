// static_assets.rs — Rust twin of the Swift moot-mgr StaticAssets.swift.
//
// The moot-mgr read-plane dashboard's HTML/CSS/JS, served by the resident host
// from the loopback HTTP listener so the host ships as one self-contained binary
// with NO filesystem static-root.
//
// ── Language-neutral content (NOT transcribed) ────────────────────────────────
// The dashboard assets are vanilla HTML/CSS/JS — language-neutral content the
// host SERVES, not Rust the host RUNS. Rather than copy ~4000 generated lines
// into a Rust string (which would immediately drift from the Swift source of
// truth), the Rust host embeds the SAME editable source files the Swift
// `StaticAssets.swift` is generated from, via `include_str!`:
//   apps/moot-mgr/Sources/MootManager/DashboardAssets/{index.html,app.css,app.js}
// Both ports therefore serve byte-identical assets from one source of truth.
// Only the SERVING is ported; the asset bytes are shared content.
//
// Because lookups go through a FIXED allow-list (`asset_for`) rather than mapping
// a request path onto a directory, there is no path-traversal surface: an
// arbitrary path returns `None` and the caller answers 404.

/// One served asset: its body text and its HTTP `Content-Type`. Mirrors Swift
/// `StaticAssets.Asset`.
pub struct Asset {
    pub body: String,
    pub content_type: &'static str,
}

/// The dashboard index page. Embedded from the shared editable source of truth
/// (the same file the Swift `StaticAssets.indexHTML` constant is generated from).
const INDEX_HTML: &str =
    include_str!("../../Sources/MootManager/DashboardAssets/index.html");
/// The dashboard stylesheet (shared source of truth).
const APP_CSS: &str = include_str!("../../Sources/MootManager/DashboardAssets/app.css");
/// The dashboard logic (shared source of truth).
const APP_JS: &str = include_str!("../../Sources/MootManager/DashboardAssets/app.js");
/// Three.js r170 — vendored WebGL rendering library (MIT, mrdoob/three.js).
const THREE_JS: &str = include_str!("../../Sources/MootManager/DashboardAssets/three.min.js");
/// OrbitControls addon from Three.js — pan/zoom/orbit camera interaction.
const ORBIT_CONTROLS_JS: &str =
    include_str!("../../Sources/MootManager/DashboardAssets/OrbitControls.js");

/// Resolve a request path to an embedded asset, or `None` for anything not on the
/// fixed allow-list. Mirrors Swift `StaticAssets.asset(for:)`.
///
/// The allow-list is fixed — there is no directory mapping, so an arbitrary path
/// cannot traverse the filesystem. Query suffixes (e.g. "/app.css?v=25") are
/// stripped before matching so the dashboard's cache-busting query strings resolve.
pub fn asset_for(path: &str) -> Option<Asset> {
    let path = path.split('?').next().unwrap_or(path);
    match path {
        "/" | "/index.html" => Some(Asset {
            body: INDEX_HTML.to_string(),
            content_type: "text/html; charset=utf-8",
        }),
        "/app.css" => Some(Asset {
            body: APP_CSS.to_string(),
            content_type: "text/css; charset=utf-8",
        }),
        "/app.js" => Some(Asset {
            body: APP_JS.to_string(),
            content_type: "text/javascript; charset=utf-8",
        }),
        "/three.min.js" => Some(Asset {
            body: THREE_JS.to_string(),
            content_type: "text/javascript; charset=utf-8",
        }),
        "/OrbitControls.js" => Some(Asset {
            body: ORBIT_CONTROLS_JS.to_string(),
            content_type: "text/javascript; charset=utf-8",
        }),
        _ => None,
    }
}
