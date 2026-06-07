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
// no path-traversal surface (blast-radius note §Security). The editable source
// of truth is DashboardAssets/{index.html,app.css,app.js}.

import Foundation

// MARK: - StaticAssets

/// The embedded dashboard assets and the content-type allow-list used by the
/// loopback HTTP read-API to serve the read-plane web UI.
enum StaticAssets {

    // MARK: Embedded asset bodies (generated)

    static let indexHTML = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>moot-mgr · Read Console</title>
<!--
  moot-mgr read-plane dashboard (P4). Vanilla HTML/CSS/JS — NO frameworks, NO
  CDN dependencies (loopback-only). Served by the resident host's HTTPReadAPI
  from 127.0.0.1 only. Read-only: every panel binds to a GET /api/* endpoint;
  there are no control forms here (privileged writes travel the native/gated
  channel — GUI SPEC §2.1).

  Fonts: the design system names Bebas Neue / Outfit / JetBrains Mono, but a
  loopback dashboard cannot fetch from a font CDN, so we declare those families
  with their system fallbacks (Impact / system-ui / ui-monospace) and ship no
  web-font payload. The fallbacks carry the same role semantics (display vs UI
  vs mono).
-->
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Crect width='100' height='100' fill='%2306070e'/%3E%3Cg fill='none' stroke='%23ff8c00' stroke-width='6' stroke-linejoin='round'%3E%3Cpath d='M30 14 L40 30 L50 16 L60 30 L70 14'/%3E%3Cpath d='M86 30 L70 40 L84 50 L70 60 L86 70'/%3E%3Cpath d='M70 86 L60 70 L50 84 L40 70 L30 86'/%3E%3Cpath d='M14 70 L30 60 L16 50 L30 40 L14 30'/%3E%3C/g%3E%3Ccircle cx='50' cy='50' r='9' fill='%23ff8c00'/%3E%3C/svg%3E">
<link rel="stylesheet" href="/app.css">
</head>
<body>
<div class="app">

  <!-- TOP BAR (GUI SPEC §2.3 — read-plane subset) -->
  <header class="topbar">
    <div class="brand">
      <svg class="chip" viewBox="0 0 100 100" aria-hidden="true">
        <g fill="none" stroke="#ff8c00" stroke-width="6" stroke-linejoin="round">
          <path d="M30 14 L40 30 L50 16 L60 30 L70 14"/>
          <path d="M86 30 L70 40 L84 50 L70 60 L86 70"/>
          <path d="M70 86 L60 70 L50 84 L40 70 L30 86"/>
          <path d="M14 70 L30 60 L16 50 L30 40 L14 30"/>
        </g>
        <circle class="core" cx="50" cy="50" r="9" fill="#ff8c00"/>
      </svg>
      <div class="wordmark"><b>moot-mgr</b><span>READ CONSOLE</span></div>
    </div>
    <div class="sep"></div>
    <div class="meta-strip">
      <span class="pill" id="statusPill"><span class="dot"></span><span id="statusText">CONNECTING</span></span>
      <span class="tag">monitoring <b id="monIndicator">—</b></span>
      <span class="tag">uptime <b id="uptimeTag">—</b></span>
    </div>
    <div class="right">
      <span class="tag" id="lastUpdated">—</span>
    </div>
  </header>

  <!-- LEFT NAV (GUI SPEC §2.2 — read views; admin/native views excluded) -->
  <nav class="sidenav" id="nav" aria-label="Views">
    <button class="navitem on" data-view="overview">Overview</button>
    <button class="navitem" data-view="estates">Estates</button>
    <button class="navitem" data-view="pipeline">Pipeline</button>
    <button class="navitem" data-view="activity">Activity</button>
    <button class="navitem" data-view="topology">Topology</button>
    <button class="navitem" data-view="configuration">Configuration</button>
  </nav>

  <!-- MAIN -->
  <main class="main" id="main">

    <!-- OVERVIEW -->
    <section class="view on" data-view="overview">
      <h1 class="title">Overview</h1>
      <p class="sub">Whole-server health and fleet aggregate — estate-agnostic.</p>
      <div class="cards" id="overviewCards"></div>
      <div class="panel">
        <h2 class="phead">Pending server probes</h2>
        <p class="note">
          Process RSS/CPU, RPC rate, kernel backend + fallback rate, protocol
          version, and the per-connection panel are not in the Phase-1 stats
          store. They render as <em>n/a — pending</em> until those substrate
          probes land (HTTP API §5).
        </p>
        <div class="naprow" id="overviewPending"></div>
      </div>
    </section>

    <!-- ESTATES -->
    <section class="view" data-view="estates">
      <h1 class="title">Estates</h1>
      <p class="sub">Per-estate event rollups. Kind/backend/queue/rung metrics are pending substrate work.</p>
      <div id="estatesList" class="estates"></div>
    </section>

    <!-- PIPELINE -->
    <section class="view" data-view="pipeline">
      <h1 class="title">Pipeline</h1>
      <p class="sub">Recent intake flow, derived from events. Queue/backpressure metrics are pending the per-estate queue subtree (HTTP API §5).</p>
      <div class="strip" id="pipelineStrip"></div>
      <div class="panel">
        <h2 class="phead">Recent flow (last events)</h2>
        <div id="pipelineFlow" class="flow"></div>
      </div>
      <div class="panel">
        <h2 class="phead">Backpressure metrics</h2>
        <div class="naprow" id="pipelinePending"></div>
      </div>
    </section>

    <!-- ACTIVITY -->
    <section class="view" data-view="activity">
      <h1 class="title">Activity</h1>
      <p class="sub">Recorded events from the stats store. Metadata only — never memory content. Live tail via SSE.</p>
      <div class="actbar">
        <button class="btn" id="ssePauseBtn">Pause live tail</button>
        <span class="tag">live tail <b id="sseState">off</b></span>
        <input class="filter" id="activityFilter" type="text" placeholder="filter by estate / kind / dropbox…" aria-label="Filter activity">
      </div>
      <table class="dtable" id="activityTable">
        <thead><tr><th>Timestamp</th><th>Kind</th><th>Noun</th><th>Estate</th><th>Dropbox</th></tr></thead>
        <tbody id="activityBody"></tbody>
      </table>
    </section>

    <!-- TOPOLOGY (P5) — Sigma-style node-link renderer over /api/graph.
         The renderer is fed by GET /api/graph. moot-mgr is a pure observer, so
         per-node/per-edge STRUCTURE is not reachable here; when the snapshot
         reports structurePending the canvas shows an honest pending overlay and
         the panel surfaces the VizGraph analytic signals that ARE available
         (community count, centrality/anomaly/NMF/decay completion) — never
         fabricated nodes (PoC spec §4.1 content boundary). -->
    <section class="view" data-view="topology">
      <div class="topo-bar">
        <h1 class="title">Topology</h1>
        <div class="topo-controls">
          <label class="topo-label" for="topoEstate">estate</label>
          <select class="topo-select" id="topoEstate" aria-label="Estate filter"></select>
          <button class="btn" id="topoReset">Reset layout</button>
          <span class="tag">structure <b id="topoStructure">—</b></span>
        </div>
      </div>
      <div class="topo-stage" id="topoStage">
        <!-- Sigma.js canvas mounts here (full remaining height). -->
        <div class="topo-canvas" id="topoCanvas"></div>
        <!-- Honest pending overlay, shown when /api/graph has no structure. -->
        <div class="topo-pending" id="topoPending" hidden>
          <div class="stubmark">◊</div>
          <h2>Structure pending</h2>
          <p id="topoPendingText"></p>
        </div>
        <!-- Activity feed overlay (3 lines, auto-fade) — PoC spec §6.4. -->
        <div class="topo-feed" id="topoFeed" aria-live="polite"></div>
        <!-- Legend: VizGraph analytic signals available from the observer host. -->
        <div class="topo-legend" id="topoLegend"></div>
      </div>
    </section>

    <!-- CONFIGURATION -->
    <section class="view" data-view="configuration">
      <h1 class="title">Configuration</h1>
      <p class="sub">Effective monitoring configuration (read-only — edit from the native menu).</p>
      <div class="cards" id="configCards"></div>
      <div class="panel">
        <h2 class="phead">Pending configuration fields</h2>
        <div class="naprow" id="configPending"></div>
      </div>
    </section>

  </main>
</div>
<!-- Vendored, self-contained Sigma-style renderer (no CDN). Loaded before
     app.js so the Topology driver can `new Sigma(...)`. -->
<script src="/sigma.js"></script>
<script src="/app.js"></script>
</body>
</html>

"""#

    static let appCSS = #"""
/*
  moot-mgr read-plane dashboard styles (P4).

  MOOTx01 design tokens from GUI SPEC §1.1/§1.2. Color is never the sole signal
  (§8): every status carries a label and/or shape alongside its hue. Accents
  (orange/blue) are reserved for large numerals, icons, fills, and bold labels —
  never small body text on dark — to keep WCAG AA contrast (§8).

  No web fonts: the design system names Bebas Neue / Outfit / JetBrains Mono;
  on a loopback dashboard we cannot fetch them, so each family degrades to its
  system fallback (Impact / system-ui / ui-monospace).
*/
:root{
  --bg:#06070e; --bg2:#090b14; --bg3:#0d1020; --surface2:#12162a; --surface3:#181d34;
  --text:#f0eeea; --hi:#c8c4bc; --muted:#8a8aaa; --faint:#56566e;
  --accent:#ff8c00; --accent2:#3ab4ff;
  --border:rgba(255,255,255,.07); --border2:rgba(255,255,255,.13);
  --ba:rgba(255,140,0,.25); --ba2:rgba(58,180,255,.25);
  --adim:rgba(255,140,0,.10); --adim2:rgba(58,180,255,.08);
  --ok:#3ab4ff; --warn:#ffb74d; --err:#ff5d6c;
  --font-d:"Bebas Neue",Impact,sans-serif;
  --font-u:"Outfit",system-ui,-apple-system,sans-serif;
  --font-m:"JetBrains Mono",ui-monospace,Menlo,monospace;
  --r:10px; --rsm:7px;
}
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{
  font-family:var(--font-u); background:var(--bg); color:var(--text);
  font-size:14px; line-height:1.45; letter-spacing:.1px; -webkit-font-smoothing:antialiased;
  overflow:hidden;
}
/* atmosphere — orange-top / blue-bottom glows + faint scanline (§1.4), kept low so data stays legible */
body::before{
  content:""; position:fixed; inset:0; z-index:0; pointer-events:none;
  background:
    radial-gradient(680px 460px at 80% -10%, var(--adim), transparent 68%),
    radial-gradient(620px 620px at -6% 112%, var(--adim2), transparent 70%),
    repeating-linear-gradient(0deg,transparent,transparent 3px,rgba(0,0,0,.032) 3px,rgba(0,0,0,.032) 4px),
    linear-gradient(180deg,#080a14 0%,#06070e 100%);
}
.app{position:relative; z-index:1; display:grid; grid-template-columns:212px 1fr; grid-template-rows:auto 1fr; height:100vh}

/* TOP BAR */
.topbar{
  grid-column:1 / -1; display:flex; align-items:center; gap:18px; padding:0 20px; height:60px;
  border-bottom:1px solid var(--border);
  background:linear-gradient(180deg,rgba(22,24,31,.9),rgba(16,18,24,.78));
}
.brand{display:flex; align-items:center; gap:11px}
.chip{width:28px;height:28px;flex:none;filter:drop-shadow(0 0 6px rgba(255,140,0,.45))}
.chip .core{transform-origin:center; animation:corepulse 2.6s ease-in-out infinite}
@keyframes corepulse{0%,100%{opacity:1}50%{opacity:.62}}
.wordmark{display:flex; flex-direction:column; line-height:1}
.wordmark b{font-family:var(--font-d); font-weight:600; font-size:19px; letter-spacing:.6px}
.wordmark span{font-size:9.5px; color:var(--muted); letter-spacing:2.2px; text-transform:uppercase; margin-top:3px}
.sep{width:1px; height:28px; background:var(--border)}
.meta-strip{display:flex; align-items:center; gap:14px; flex-wrap:wrap}
.right{margin-left:auto; display:flex; align-items:center; gap:10px}
.pill{
  display:inline-flex; align-items:center; gap:7px; padding:5px 11px; border-radius:999px;
  font-size:11px; font-weight:600; letter-spacing:.4px; border:1px solid var(--border2);
  background:var(--surface2); color:var(--hi);
}
.pill.running{color:var(--ok); border-color:var(--ba2); background:rgba(58,180,255,.10)}
.pill.stopped{color:var(--err); border-color:rgba(255,93,108,.3); background:rgba(255,93,108,.10)}
.dot{width:7px;height:7px;border-radius:50%;background:currentColor;position:relative}
.pill.running .dot::after{content:"";position:absolute;inset:-4px;border-radius:50%;border:1px solid var(--ok);animation:ping 1.8s ease-out infinite}
@keyframes ping{0%{transform:scale(.6);opacity:.9}100%{transform:scale(2.4);opacity:0}}
.tag{font-family:var(--font-m); font-size:11px; color:var(--muted)}
.tag b{color:var(--hi); font-weight:500}

/* SIDE NAV */
.sidenav{
  display:flex; flex-direction:column; gap:2px; padding:14px 10px; border-right:1px solid var(--border);
  background:linear-gradient(180deg,var(--bg2),var(--bg));
}
.navitem{
  text-align:left; background:transparent; border:1px solid transparent; color:var(--muted);
  font-family:var(--font-u); font-size:13px; font-weight:500; padding:9px 12px; border-radius:var(--rsm);
  cursor:pointer; transition:background .14s, color .14s;
}
.navitem:hover{background:var(--surface2); color:var(--text)}
.navitem.on{background:var(--adim); border-color:var(--ba); color:var(--text)}
.navitem:focus-visible{outline:2px solid var(--ba2); outline-offset:1px}

/* MAIN */
.main{overflow:auto; padding:26px 30px 40px}
.view{display:none; animation:fade .25s ease}
.view.on{display:block}
@keyframes fade{from{opacity:0; transform:translateY(4px)}to{opacity:1; transform:none}}
@media (prefers-reduced-motion:reduce){
  .view,.chip .core,.pill.running .dot::after{animation:none}
}
.title{font-family:var(--font-d); font-size:27px; font-weight:600; letter-spacing:.5px}
.sub{color:var(--muted); font-size:12.5px; margin:4px 0 20px; max-width:760px}

/* metric cards */
.cards{display:grid; grid-template-columns:repeat(auto-fill,minmax(180px,1fr)); gap:14px; margin-bottom:22px}
.card{
  background:linear-gradient(180deg,var(--bg3),var(--bg2)); border:1px solid var(--border);
  border-radius:var(--r); padding:16px 18px;
}
.card .clabel{font-size:10.5px; text-transform:uppercase; letter-spacing:1.4px; color:var(--muted)}
.card .cval{font-family:var(--font-d); font-size:34px; line-height:1.05; margin-top:6px; color:var(--text)}
.card .cval.blue{color:var(--accent2)}
.card .cval.orange{color:var(--accent)}
.card .cunit{font-family:var(--font-m); font-size:12px; color:var(--muted); margin-left:6px}

/* panels */
.panel{
  background:linear-gradient(180deg,var(--bg3),var(--bg2)); border:1px solid var(--border);
  border-radius:var(--r); padding:18px 20px; margin-bottom:18px;
}
.phead{font-size:12px; font-weight:700; text-transform:uppercase; letter-spacing:1.2px; color:var(--hi); margin-bottom:10px}
.note{color:var(--muted); font-size:12.5px; max-width:720px; margin-bottom:12px}
.note em{color:var(--warn); font-style:normal}

/* n/a pending chips */
.naprow{display:flex; flex-wrap:wrap; gap:8px}
.nachip{
  display:inline-flex; align-items:center; gap:7px; font-family:var(--font-m); font-size:11px;
  padding:5px 10px; border-radius:999px; border:1px dashed var(--border2); color:var(--muted);
  background:var(--surface2);
}
.nachip::before{content:"n/a"; color:var(--warn); font-weight:700; font-size:9px; letter-spacing:.5px}

/* estates */
.estates{display:grid; grid-template-columns:repeat(auto-fill,minmax(260px,1fr)); gap:14px}
.estate{
  background:linear-gradient(180deg,var(--bg3),var(--bg2)); border:1px solid var(--border);
  border-radius:var(--r); padding:16px 18px;
}
.estate .ename{font-family:var(--font-m); font-size:14px; font-weight:500; color:var(--text); word-break:break-all}
.estate .erow{display:flex; justify-content:space-between; margin-top:10px; font-size:12px; color:var(--muted)}
.estate .erow b{font-family:var(--font-m); color:var(--hi); font-weight:500}

/* pipeline */
.strip{display:flex; align-items:center; gap:6px; margin-bottom:18px; flex-wrap:wrap}
.stage{
  flex:1; min-width:110px; text-align:center; background:var(--surface2); border:1px solid var(--border);
  border-radius:var(--rsm); padding:12px 8px;
}
.stage .sname{font-size:10px; text-transform:uppercase; letter-spacing:1px; color:var(--muted)}
.stage .sval{font-family:var(--font-d); font-size:22px; margin-top:4px; color:var(--accent2)}
.stage.pending .sval{color:var(--muted); font-size:13px; font-family:var(--font-m)}
.arrow{color:var(--faint); font-size:18px}
.flow{display:flex; flex-direction:column; gap:6px; font-family:var(--font-m); font-size:12px}
.flow .frow{display:flex; gap:10px; color:var(--hi)}
.flow .frow .k{font-weight:700}
.k.capture{color:var(--accent)}
.k.think{color:var(--accent2)}

/* activity */
.actbar{display:flex; align-items:center; gap:14px; margin-bottom:14px; flex-wrap:wrap}
.btn{
  background:var(--surface3); border:1px solid var(--border2); color:var(--text); font-family:var(--font-u);
  font-size:12px; font-weight:500; padding:7px 14px; border-radius:var(--rsm); cursor:pointer;
}
.btn:hover{background:var(--surface2)}
.btn:focus-visible{outline:2px solid var(--ba2); outline-offset:1px}
.filter{
  flex:1; min-width:200px; background:var(--bg2); border:1px solid var(--border2); color:var(--text);
  font-family:var(--font-m); font-size:12px; padding:7px 12px; border-radius:var(--rsm);
}
.filter:focus-visible{outline:2px solid var(--ba2); outline-offset:0}
.dtable{width:100%; border-collapse:collapse; font-size:12px}
.dtable th{
  text-align:left; font-size:10px; text-transform:uppercase; letter-spacing:1.1px; color:var(--muted);
  padding:8px 10px; border-bottom:1px solid var(--border2); position:sticky; top:-26px; background:var(--bg);
}
.dtable td{padding:8px 10px; border-bottom:1px solid var(--border); font-family:var(--font-m); color:var(--hi)}
.dtable tr:hover td{background:var(--surface2)}
.kind-capture{color:var(--accent)}
.kind-think{color:var(--accent2)}

/* topology (P5) — Sigma-style canvas + controls + overlays */
.topo-bar{display:flex; align-items:center; justify-content:space-between; gap:16px; flex-wrap:wrap; margin-bottom:14px}
.topo-controls{display:flex; align-items:center; gap:12px; flex-wrap:wrap}
.topo-label{font-size:10px; text-transform:uppercase; letter-spacing:1.1px; color:var(--muted)}
.topo-select{
  background:var(--bg2); border:1px solid var(--border2); color:var(--text);
  font-family:var(--font-m); font-size:12px; padding:6px 10px; border-radius:var(--rsm);
}
.topo-select:focus-visible{outline:2px solid var(--ba2); outline-offset:0}
.topo-stage{
  position:relative; width:100%; height:calc(100vh - 200px); min-height:380px;
  border:1px solid var(--border); border-radius:var(--r); overflow:hidden;
  background:radial-gradient(900px 600px at 50% 40%, rgba(58,180,255,.04), transparent 70%), var(--bg2);
}
.topo-canvas{position:absolute; inset:0}
.topo-canvas canvas{cursor:grab}
.topo-canvas canvas:active{cursor:grabbing}
/* honest pending overlay (centered) */
.topo-pending{
  position:absolute; inset:0; display:flex; flex-direction:column; align-items:center;
  justify-content:center; text-align:center; color:var(--muted); pointer-events:none; padding:24px;
}
.stubmark{font-size:60px; color:var(--faint); margin-bottom:14px}
.topo-pending h2{font-family:var(--font-d); font-size:24px; color:var(--hi); letter-spacing:1px}
.topo-pending p{max-width:560px; font-size:12.5px; margin-top:8px; line-height:1.6}
/* activity feed (bottom-left, 3 lines, auto-fade) — PoC spec §6.4 */
.topo-feed{
  position:absolute; left:14px; bottom:14px; display:flex; flex-direction:column; gap:4px;
  font-family:var(--font-m); font-size:11px; pointer-events:none; max-width:70%;
}
.topo-feed .fline{
  display:flex; align-items:center; gap:8px; color:var(--hi); background:rgba(6,7,14,.55);
  padding:3px 9px; border-radius:999px; border:1px solid var(--border);
  animation:feedfade 8s ease forwards;
}
.topo-feed .fdot{width:7px; height:7px; border-radius:50%; flex:none}
.topo-feed .fdot.capture{background:var(--accent)}
.topo-feed .fdot.think{background:var(--accent2)}
@keyframes feedfade{0%{opacity:0}8%{opacity:1}80%{opacity:1}100%{opacity:0}}
@media (prefers-reduced-motion:reduce){ .topo-feed .fline{animation:none} }
/* legend (bottom-right): the VizGraph analytic signals available from the host */
.topo-legend{
  position:absolute; right:14px; bottom:14px; display:flex; flex-direction:column; gap:6px;
  background:rgba(6,7,14,.62); border:1px solid var(--border); border-radius:var(--rsm);
  padding:10px 12px; font-family:var(--font-m); font-size:10.5px; color:var(--muted); max-width:260px;
}
.topo-legend .lhead{font-weight:700; color:var(--hi); letter-spacing:.6px; text-transform:uppercase; font-size:9.5px}
.topo-legend .lrow{display:flex; justify-content:space-between; gap:12px}
.topo-legend .lrow b{color:var(--hi); font-weight:500}
.topo-legend .lswatches{display:flex; gap:4px; flex-wrap:wrap; margin-top:2px}
.topo-legend .lsw{width:11px; height:11px; border-radius:3px}

/* loading / empty */
.empty{color:var(--muted); font-size:13px; font-style:italic; padding:18px 0}

"""#

    static let appJS = #"""
/*
  moot-mgr read-plane dashboard logic (P4).

  Vanilla JS — no frameworks, no CDN. All data comes from the resident host's
  loopback GET /api/* endpoints. This script issues ONLY reads (GET + the SSE
  GET /api/events?stream=1); it never POSTs to the control surface — the
  dashboard is read-only (GUI SPEC §2.1).

  Fields the Phase-1 API does not yet serve (HTTP API §5) are rendered as
  "n/a — pending" chips rather than faked. The pending field lists below are the
  single source of truth for that and mirror the API doc's §5.
*/
(function () {
  "use strict";

  // ----- pending-field catalogs (HTTP API §5; render as n/a, never faked) -----
  const PENDING = {
    overview: ["rpc_rate", "rss_mb", "cpu_pct", "kernel_backend",
               "kernel_fallback_rate", "proto_version", "connections"],
    pipeline: ["depth", "throughput", "fill_rate", "drain_rate",
               "head_of_line_age_s", "p50_ms", "p95_ms", "idle_nonempty",
               "gate_admit_rate", "gate_reject_rate"],
    config:   ["transport", "read_strategy", "timeouts", "capabilities",
               "namespacing", "monitoring_layers", "depth_default"],
  };

  // ----- tiny DOM helpers -----
  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));
  function el(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

  async function getJSON(path) {
    const res = await fetch(path, { headers: { "Accept": "application/json" } });
    if (!res.ok) throw new Error(path + " → " + res.status);
    return res.json();
  }

  // Formatters. Uptime via a plain seconds→h:m:s split (no locale text needed).
  function fmtUptime(secs) {
    secs = Math.max(0, secs | 0);
    const h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60), s = secs % 60;
    return h + "h " + String(m).padStart(2, "0") + "m " + String(s).padStart(2, "0") + "s";
  }
  function fmtBytes(b) {
    if (b < 1024) return b + " B";
    const u = ["KB", "MB", "GB"]; let v = b / 1024, i = 0;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return v.toFixed(1) + " " + u[i];
  }

  function metricCard(label, value, unit, tone) {
    const c = el("div", "card");
    c.appendChild(el("div", "clabel", label));
    const v = el("div", "cval" + (tone ? " " + tone : ""));
    v.appendChild(document.createTextNode(String(value)));
    if (unit) v.appendChild(el("span", "cunit", unit));
    c.appendChild(v);
    return c;
  }
  function naChips(container, names) {
    clear(container);
    names.forEach((n) => container.appendChild(el("span", "nachip", n)));
  }

  // ----- views -----
  async function renderOverview() {
    const cards = $("#overviewCards");
    try {
      const s = await getJSON("/api/server");
      clear(cards);
      cards.appendChild(metricCard("Monitoring", s.monitoringEnabled ? "ON" : "OFF", null,
                                   s.monitoringEnabled ? "blue" : null));
      cards.appendChild(metricCard("Uptime", fmtUptime(s.uptimeSeconds)));
      cards.appendChild(metricCard("Estates", s.estateCount, null, "orange"));
      cards.appendChild(metricCard("Events", s.totalEvents, null, "blue"));
      cards.appendChild(metricCard("Metrics", s.totalMetrics));
      cards.appendChild(metricCard("Store size", fmtBytes(s.storeSizeBytes)));
      setStatus(true, s);
    } catch (e) {
      clear(cards);
      cards.appendChild(el("div", "empty", "server unreachable — " + e.message));
      setStatus(false);
    }
    naChips($("#overviewPending"), PENDING.overview);
  }

  async function renderEstates() {
    const list = $("#estatesList");
    clear(list);
    try {
      const p = await getJSON("/api/estates");
      if (!p.estates.length) { list.appendChild(el("div", "empty", "no estates observed yet")); return; }
      p.estates.forEach((e) => {
        const card = el("div", "estate");
        card.appendChild(el("div", "ename", e.id));
        const r1 = el("div", "erow");
        r1.appendChild(el("span", null, "events")); r1.appendChild(el("b", null, String(e.eventCount)));
        card.appendChild(r1);
        const r2 = el("div", "erow");
        r2.appendChild(el("span", null, "last event"));
        r2.appendChild(el("b", null, e.lastEventTs || "—"));
        card.appendChild(r2);
        list.appendChild(card);
      });
    } catch (e) {
      list.appendChild(el("div", "empty", "estates unreachable — " + e.message));
    }
  }

  async function renderPipeline() {
    // The queue subtree is not in the Phase-1 API, so the strip stages are
    // marked pending; the "recent flow" panel is derived from /api/events.
    const strip = $("#pipelineStrip");
    clear(strip);
    const stages = ["intake", "write-gate", "queue depth", "drain", "enrichment"];
    stages.forEach((name, i) => {
      const st = el("div", "stage pending");
      st.appendChild(el("div", "sname", name));
      st.appendChild(el("div", "sval", "pending"));
      strip.appendChild(st);
      if (i < stages.length - 1) strip.appendChild(el("span", "arrow", "→"));
    });
    const flow = $("#pipelineFlow");
    clear(flow);
    try {
      const p = await getJSON("/api/events");
      const recent = p.events.slice(0, 12);
      if (!recent.length) { flow.appendChild(el("div", "empty", "no recent flow")); }
      recent.forEach((ev) => {
        const row = el("div", "frow");
        row.appendChild(el("span", null, ev.ts));
        const k = el("span", "k " + (ev.kind === "capture" ? "capture" : ev.kind === "think" ? "think" : ""), ev.kind);
        row.appendChild(k);
        row.appendChild(el("span", null, "estate=" + ev.estate));
        row.appendChild(el("span", null, "via " + ev.dropbox));
        flow.appendChild(row);
      });
    } catch (e) {
      flow.appendChild(el("div", "empty", "events unreachable — " + e.message));
    }
    naChips($("#pipelinePending"), PENDING.pipeline);
  }

  // ----- Activity + SSE live tail -----
  let sse = null, ssePaused = false, activityRows = [];
  const ACTIVITY_CAP = 500; // keep the table bounded; newest-first

  function activityMatches(ev, q) {
    if (!q) return true;
    q = q.toLowerCase();
    return (ev.estate || "").toLowerCase().includes(q)
        || (ev.kind || "").toLowerCase().includes(q)
        || (ev.dropbox || "").toLowerCase().includes(q);
  }
  function paintActivity() {
    const body = $("#activityBody");
    const q = $("#activityFilter").value.trim();
    clear(body);
    const shown = activityRows.filter((ev) => activityMatches(ev, q));
    if (!shown.length) {
      const tr = el("tr"); const td = el("td"); td.colSpan = 5;
      td.appendChild(el("span", "empty", q ? "no rows match the filter" : "no events recorded"));
      tr.appendChild(td); body.appendChild(tr); return;
    }
    shown.forEach((ev) => {
      const tr = el("tr");
      tr.appendChild(el("td", null, ev.ts));
      tr.appendChild(el("td", "kind-" + ev.kind, ev.kind));
      tr.appendChild(el("td", null, String(ev.nounType)));
      tr.appendChild(el("td", null, ev.estate));
      tr.appendChild(el("td", null, ev.dropbox));
      body.appendChild(tr);
    });
  }
  function pushEvent(ev) {
    activityRows.unshift(ev);
    if (activityRows.length > ACTIVITY_CAP) activityRows.length = ACTIVITY_CAP;
  }
  async function renderActivity() {
    try {
      const p = await getJSON("/api/events");
      activityRows = p.events.slice(0, ACTIVITY_CAP); // newest-first from the API
    } catch (e) {
      activityRows = [];
    }
    paintActivity();
    startSSE();
  }
  function startSSE() {
    if (ssePaused || sse) return;
    sse = new EventSource("/api/events?stream=1");
    $("#sseState").textContent = "on";
    sse.onmessage = (m) => {
      try { pushEvent(JSON.parse(m.data)); paintActivity(); } catch (_) { /* ignore malformed frame */ }
    };
    sse.onerror = () => { $("#sseState").textContent = "reconnecting"; };
  }
  function stopSSE() {
    if (sse) { sse.close(); sse = null; }
    $("#sseState").textContent = "off";
  }

  async function renderConfiguration() {
    const cards = $("#configCards");
    clear(cards);
    try {
      const c = await getJSON("/api/config");
      cards.appendChild(metricCard("Monitoring", c.monitoringEnabled ? "ON" : "OFF", null,
                                   c.monitoringEnabled ? "blue" : null));
      cards.appendChild(metricCard("Retention", c.retentionSeconds, "s"));
      const cut = el("div", "card");
      cut.appendChild(el("div", "clabel", "Last retention cutoff"));
      const v = el("div", "cval"); v.style.fontSize = "16px"; v.style.fontFamily = "var(--font-m)";
      v.textContent = c.retentionCutoff;
      cut.appendChild(v);
      cards.appendChild(cut);
    } catch (e) {
      cards.appendChild(el("div", "empty", "config unreachable — " + e.message));
    }
    naChips($("#configPending"), PENDING.config);
  }

  // ----- top-bar status -----
  function setStatus(running, server) {
    const pill = $("#statusPill"), txt = $("#statusText");
    pill.classList.toggle("running", running);
    pill.classList.toggle("stopped", !running);
    txt.textContent = running ? "RUNNING" : "STOPPED";
    $("#monIndicator").textContent = server ? (server.monitoringEnabled ? "ON" : "OFF") : "—";
    $("#uptimeTag").textContent = server ? fmtUptime(server.uptimeSeconds) : "—";
    const now = new Date();
    $("#lastUpdated").textContent = "updated " +
      String(now.getHours()).padStart(2, "0") + ":" +
      String(now.getMinutes()).padStart(2, "0") + ":" +
      String(now.getSeconds()).padStart(2, "0");
  }

  // ----- Topology (P5): /api/graph + the vendored Sigma renderer -----
  //
  // moot-mgr is a pure observer, so /api/graph reports structurePending=true
  // (no per-node/per-edge structure reachable from the host). When structure is
  // pending we mount NO nodes and show the honest pending overlay; the legend
  // still surfaces the VizGraph analytic signals the host CAN read. If a future
  // build serves real nodes/edges, the same driver renders them — no change.
  let topoSigma = null, topoGraphSSE = null, topoFeedTimer = null;
  const TOPO_NOUN_SIZE = { 0: 4, 3: 3, 4: 2.6, 5: 2, 6: 3.2, 7: 1.6 }; // PoC §1.1

  function topoTeardown() {
    if (topoSigma) { topoSigma.kill(); topoSigma = null; }
    if (topoGraphSSE) { topoGraphSSE.close(); topoGraphSSE = null; }
  }

  // Map a node's centrality (0..1) to a radius: base + scaled, capped 3x (PoC §3.2).
  function topoRadius(nounType, centrality) {
    const base = TOPO_NOUN_SIZE[nounType] != null ? TOPO_NOUN_SIZE[nounType] : 2.5;
    return Math.min(base * 3, base + (centrality || 0) * base * 2);
  }

  async function renderTopology() {
    topoTeardown();
    const estate = $("#topoEstate").value || "";
    let g;
    try {
      g = await getJSON("/api/graph" + (estate ? "?estate=" + encodeURIComponent(estate) : ""));
    } catch (e) {
      $("#topoStructure").textContent = "unreachable";
      return;
    }

    // Estate selector options (first load only — keep the user's choice after).
    const sel = $("#topoEstate");
    const estatesSeen = Array.from(new Set((g.analytics || []).map((a) => a.estate))).sort();
    if (sel.options.length === 0) {
      sel.appendChild(new Option("all", ""));
      estatesSeen.forEach((id) => sel.appendChild(new Option(id, id)));
    }

    $("#topoStructure").textContent = g.structurePending ? "pending" : "live";

    // Build the Sigma graph from whatever structure is present.
    const graph = new Sigma.Graph();
    (g.nodes || []).forEach((n) => {
      graph.addNode(n.id, {
        size: topoRadius(n.nounType, n.centrality),
        color: topoCommunityColor(g, n.communityId),
        anomaly: !!n.anomaly,
      });
    });
    (g.edges || []).forEach((e) => {
      graph.addEdge(e.source, e.target, {
        weight: e.weight, decayedWeight: e.decayedWeight, edgeType: e.edgeType,
      });
    });
    topoSigma = new Sigma(graph, $("#topoCanvas"), { gravity: 0.04, scalingRatio: 2 });

    // Pending overlay: shown when there is no structure to draw.
    const pending = $("#topoPending");
    const hasStructure = graph.order() > 0;
    pending.hidden = hasStructure;
    if (!hasStructure) {
      $("#topoPendingText").textContent =
        "The resident observer host cannot reach the estate graph, so nodes and "
        + "edges are not drawn (never fabricated). " + (g.pending || []).join("  ·  ");
    }

    topoRenderLegend(g);
    // The graph_event SSE channel drives capture/think animations on nodes.
    topoStartSSE();
  }

  function topoCommunityColor(g, communityId) {
    const c = (g.communities || []).find((x) => x.id === communityId);
    return c ? c.color : "rgba(232,234,240,0.7)";
  }

  function topoRenderLegend(g) {
    const box = $("#topoLegend");
    clear(box);
    box.appendChild(el("div", "lhead", "VizGraph signals"));
    if (!(g.analytics || []).length) {
      box.appendChild(el("div", "lrow", "no signals — monitoring off / none yet"));
    } else {
      // Latest value per signal (collapsed across estates for the compact legend).
      const bySignal = {};
      g.analytics.forEach((a) => { bySignal[a.signal] = a.value; });
      Object.keys(bySignal).sort().forEach((sig) => {
        const row = el("div", "lrow");
        row.appendChild(el("span", null, sig));
        row.appendChild(el("b", null, String(Math.round(bySignal[sig] * 100) / 100)));
        box.appendChild(row);
      });
    }
    if ((g.communities || []).length) {
      const sw = el("div", "lswatches");
      g.communities.slice(0, 12).forEach((c) => {
        const dot = el("div", "lsw"); dot.style.background = c.color; sw.appendChild(dot);
      });
      box.appendChild(sw);
    }
  }

  // Activity feed + node animation over the graph_event SSE channel (PoC §2.3).
  function topoStartSSE() {
    if (topoGraphSSE) return;
    topoGraphSSE = new EventSource("/api/events?stream=1");
    topoGraphSSE.onmessage = (m) => {
      let ev; try { ev = JSON.parse(m.data); } catch (_) { return; }
      topoFeedLine(ev);
      // Drive the node pulse/glow if the node is present in the graph.
      if (topoSigma && ev.nounType != null) {
        // EventPayload has no row_id field on this read surface, so the pulse
        // targets matching nodes by capture/think channel only when structure
        // is present; with structure pending this is a no-op (no nodes mounted).
        topoSigma.graph.forEachNode((nd) => {
          if (ev.kind === "capture") {
            nd.pulseOrange = true; setTimeout(() => { nd.pulseOrange = false; }, 2000);
          } else if (ev.kind === "think") {
            nd.glowBlue = true; setTimeout(() => { nd.glowBlue = false; }, 10000);
          }
        });
      }
    };
    topoGraphSSE.onerror = () => { /* browser auto-reconnects */ };
  }

  // Append one auto-fading feed line (orange dot = capture, blue = think).
  function topoFeedLine(ev) {
    const feed = $("#topoFeed");
    const line = el("div", "fline");
    line.appendChild(el("span", "fdot " + (ev.kind === "capture" ? "capture" : "think")));
    line.appendChild(el("span", null, ev.kind + "  ·  noun " + ev.nounType + "  ·  " + ev.estate));
    feed.appendChild(line);
    while (feed.childElementCount > 3) feed.removeChild(feed.firstChild);
    clearTimeout(topoFeedTimer);
    topoFeedTimer = setTimeout(() => { clear(feed); }, 8500);
  }

  // ----- view router -----
  const RENDER = {
    overview: renderOverview,
    estates: renderEstates,
    pipeline: renderPipeline,
    activity: renderActivity,
    topology: renderTopology,
    configuration: renderConfiguration,
  };
  function show(view) {
    $$(".navitem").forEach((b) => b.classList.toggle("on", b.dataset.view === view));
    $$(".view").forEach((s) => s.classList.toggle("on", s.dataset.view === view));
    // The SSE tail only runs while Activity is visible.
    if (view !== "activity") stopSSE();
    // The Topology renderer + its graph_event SSE run only while it is visible.
    if (view !== "topology") topoTeardown();
    (RENDER[view] || function () {})();
  }

  // ----- wiring -----
  document.addEventListener("DOMContentLoaded", function () {
    $$(".navitem").forEach((b) => b.addEventListener("click", () => show(b.dataset.view)));
    $("#activityFilter").addEventListener("input", paintActivity);
    $("#ssePauseBtn").addEventListener("click", function () {
      ssePaused = !ssePaused;
      this.textContent = ssePaused ? "Resume live tail" : "Pause live tail";
      if (ssePaused) stopSSE(); else startSSE();
    });
    // Topology controls: estate filter reloads the snapshot; reset re-seeds layout.
    $("#topoEstate").addEventListener("change", renderTopology);
    $("#topoReset").addEventListener("click", function () {
      if (topoSigma) topoSigma.resetLayout();
    });
    show("overview");
    // Refresh the Overview header status on a slow cadence so the top bar stays
    // current without hammering the store.
    setInterval(function () {
      const active = $(".view.on");
      if (active && active.dataset.view === "overview") renderOverview();
    }, 5000);
  });
})();

"""#

    static let sigmaJS = #"""
/*
  sigma.js — vendored, self-contained node-link renderer for the moot-mgr
  Topology view (P5).

  WHY THIS IS VENDORED AND SELF-CONTAINED (read before swapping it):
  The PoC spec (NODELINK_VIZ_POC_SPEC.md §5) names "Sigma.js v3 + ForceAtlas2".
  The genuine library is an ES-module bundle that depends on graphology and
  graphology-layout-forceatlas2 — multiple hundreds of KB across several
  packages. The moot-mgr dashboard is served from a loopback-only host with a
  HARD no-CDN / zero-external-dependency rule (CLAUDE.md), and no copy of those
  packages exists in the repo to embed. So rather than fetch from a CDN (banned)
  or fabricate a dependency, this file is a small, self-contained renderer that
  exposes the SAME public graph API surface the topology driver uses
  (new Sigma(...), graph.addNode / addEdge / setNodeAttribute, .refresh(),
  .kill()) and runs a continuous ForceAtlas2-style force layout in the page —
  matching the PoC reference (mootx01-topology-poc.html), which is itself a
  hand-written canvas force layout, not the upstream library.

  It renders to a 2D canvas (no WebGL program authoring needed in the PoC) and
  honours the three visual signals the spec requires:
    - community coloring (node attribute `color`, from community id),
    - centrality-scaled node size (attribute `size`),
    - anomaly highlight (attribute `anomaly` → white outer ring, reduced alpha).
  Plus the two activity channels: `pulseOrange` (capture) and `glowBlue`
  (think), set/cleared by the driver on SSE events.

  Layout: a Barnes-Hut-free O(n^2) repulsion + edge attraction + gravity loop,
  adequate for the PoC tier (< ~2K nodes). The upgrade path to the real Sigma.js
  WebGL renderer + a quadtree layout is documented in the PoC spec §5.4.

  NO frameworks. NO CDN. Exposes a single global: `Sigma`.
*/
(function (global) {
  "use strict";

  // A minimal graph container with the subset of the graphology API the driver
  // uses. Nodes/edges are plain objects keyed by id.
  function Graph() {
    this._nodes = new Map();
    this._edges = [];
  }
  Graph.prototype.addNode = function (id, attrs) {
    if (this._nodes.has(id)) return id;
    // Seed a position in a small random disc so the force loop has somewhere to
    // start; the layout spreads them out from there.
    const a = Math.random() * Math.PI * 2, r = Math.random() * 40 + 10;
    const n = Object.assign({
      id: id, x: Math.cos(a) * r, y: Math.sin(a) * r, vx: 0, vy: 0,
      size: 3, color: "rgba(232,234,240,0.7)", anomaly: false,
      pulseOrange: false, glowBlue: false,
    }, attrs || {});
    this._nodes.set(id, n);
    return id;
  };
  Graph.prototype.hasNode = function (id) { return this._nodes.has(id); };
  Graph.prototype.addEdge = function (source, target, attrs) {
    if (!this._nodes.has(source) || !this._nodes.has(target)) return;
    this._edges.push(Object.assign({ source: source, target: target,
      weight: 1, decayedWeight: 1, edgeType: "tunnel" }, attrs || {}));
  };
  Graph.prototype.setNodeAttribute = function (id, key, value) {
    const n = this._nodes.get(id);
    if (n) n[key] = value;
  };
  Graph.prototype.getNodeAttribute = function (id, key) {
    const n = this._nodes.get(id);
    return n ? n[key] : undefined;
  };
  Graph.prototype.order = function () { return this._nodes.size; };
  Graph.prototype.clear = function () { this._nodes.clear(); this._edges = []; };
  Graph.prototype.forEachNode = function (fn) { this._nodes.forEach(fn); };

  // The renderer. Owns the canvas, the camera (pan/zoom), the force loop, and
  // the draw loop. Constructed with (graph, container, options).
  function Sigma(graph, container, options) {
    this.graph = graph;
    this.container = container;
    this.opts = Object.assign({ gravity: 0.04, scalingRatio: 2, repulsion: 1400 }, options || {});
    this._running = true;
    this._cam = { x: 0, y: 0, zoom: 1 };
    this._buildCanvas();
    this._bindInteractions();
    this._loop = this._loop.bind(this);
    requestAnimationFrame(this._loop);
  }

  Sigma.prototype._buildCanvas = function () {
    const c = document.createElement("canvas");
    c.style.display = "block";
    this.canvas = c;
    this.ctx = c.getContext("2d");
    this.container.appendChild(c);
    this._resize();
    this._onResize = this._resize.bind(this);
    window.addEventListener("resize", this._onResize);
  };

  Sigma.prototype._resize = function () {
    const dpr = window.devicePixelRatio || 1;
    const rect = this.container.getBoundingClientRect();
    this.W = Math.max(1, rect.width);
    this.H = Math.max(1, rect.height);
    this.canvas.width = this.W * dpr;
    this.canvas.height = this.H * dpr;
    this.canvas.style.width = this.W + "px";
    this.canvas.style.height = this.H + "px";
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  };

  Sigma.prototype._bindInteractions = function () {
    let dragging = false, lastX = 0, lastY = 0;
    this.canvas.addEventListener("mousedown", (e) => { dragging = true; lastX = e.clientX; lastY = e.clientY; });
    window.addEventListener("mouseup", () => { dragging = false; });
    window.addEventListener("mousemove", (e) => {
      if (!dragging) return;
      this._cam.x += (e.clientX - lastX); this._cam.y += (e.clientY - lastY);
      lastX = e.clientX; lastY = e.clientY;
    });
    this.canvas.addEventListener("wheel", (e) => {
      e.preventDefault();
      const f = e.deltaY < 0 ? 1.1 : 1 / 1.1;
      this._cam.zoom = Math.max(0.15, Math.min(6, this._cam.zoom * f));
    }, { passive: false });
  };

  // One ForceAtlas2-flavoured integration step: pairwise repulsion, edge
  // attraction (rest length modulated by decayed weight), and centre gravity.
  Sigma.prototype._step = function () {
    const nodes = Array.from(this.graph._nodes.values());
    const n = nodes.length;
    if (!n) return;
    const rep = this.opts.repulsion, grav = this.opts.gravity, k = this.opts.scalingRatio;
    for (let i = 0; i < n; i++) {
      const a = nodes[i];
      for (let j = i + 1; j < n; j++) {
        const b = nodes[j];
        let dx = a.x - b.x, dy = a.y - b.y;
        let d2 = dx * dx + dy * dy; if (d2 < 0.01) { d2 = 0.01; dx = Math.random(); dy = Math.random(); }
        const f = (rep * k) / d2;
        const d = Math.sqrt(d2);
        const fx = (dx / d) * f, fy = (dy / d) * f;
        a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
      }
      // Gravity toward origin keeps the cloud from drifting away.
      a.vx -= a.x * grav; a.vy -= a.y * grav;
    }
    for (const e of this.graph._edges) {
      const s = this.graph._nodes.get(e.source), t = this.graph._nodes.get(e.target);
      if (!s || !t) continue;
      const dx = t.x - s.x, dy = t.y - s.y;
      const d = Math.sqrt(dx * dx + dy * dy) || 0.01;
      // Higher decayed weight → stronger pull (shorter rest length).
      const pull = 0.0009 * d * (0.3 + (e.decayedWeight || 1));
      const fx = (dx / d) * pull, fy = (dy / d) * pull;
      s.vx += fx; s.vy += fy; t.vx -= fx; t.vy -= fy;
    }
    for (const a of nodes) {
      a.vx *= 0.85; a.vy *= 0.85;           // damping → gentle breathing, not snapping
      a.x += Math.max(-12, Math.min(12, a.vx));
      a.y += Math.max(-12, Math.min(12, a.vy));
    }
  };

  Sigma.prototype._toScreen = function (x, y) {
    return [x * this._cam.zoom + this.W / 2 + this._cam.x,
            y * this._cam.zoom + this.H / 2 + this._cam.y];
  };

  Sigma.prototype._draw = function () {
    const ctx = this.ctx;
    ctx.clearRect(0, 0, this.W, this.H);
    // Edges first.
    for (const e of this.graph._edges) {
      const s = this.graph._nodes.get(e.source), t = this.graph._nodes.get(e.target);
      if (!s || !t) continue;
      const [sx, sy] = this._toScreen(s.x, s.y), [tx, ty] = this._toScreen(t.x, t.y);
      const alpha = 0.08 + 0.32 * (e.decayedWeight || 1);
      ctx.strokeStyle = "rgba(138,138,170," + alpha.toFixed(3) + ")";
      ctx.lineWidth = e.edgeType === "tunnel" ? 1.1 : 0.7;
      if (e.edgeType === "kgFact" || e.edgeType === "association") ctx.setLineDash([3, 3]);
      else ctx.setLineDash([]);
      ctx.beginPath(); ctx.moveTo(sx, sy); ctx.lineTo(tx, ty); ctx.stroke();
    }
    ctx.setLineDash([]);
    // Nodes.
    this.graph._nodes.forEach((nd) => {
      const [x, y] = this._toScreen(nd.x, nd.y);
      const r = Math.max(1.2, (nd.size || 3) * this._cam.zoom);
      // think glow: soft blue halo behind the node.
      if (nd.glowBlue) {
        const g = ctx.createRadialGradient(x, y, 0, x, y, r * 6);
        g.addColorStop(0, "rgba(58,180,255,0.5)"); g.addColorStop(1, "rgba(58,180,255,0)");
        ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y, r * 6, 0, Math.PI * 2); ctx.fill();
      }
      // body, dimmed if anomalous.
      ctx.globalAlpha = nd.anomaly ? 0.55 : 1;
      ctx.fillStyle = nd.color || "rgba(232,234,240,0.7)";
      ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill();
      ctx.globalAlpha = 1;
      // anomaly: white outer ring (PoC spec §3.6).
      if (nd.anomaly) {
        ctx.strokeStyle = "rgba(240,238,234,0.85)"; ctx.lineWidth = 1.2;
        ctx.beginPath(); ctx.arc(x, y, r + 2.5, 0, Math.PI * 2); ctx.stroke();
      }
      // capture pulse: expanding orange ring.
      if (nd.pulseOrange) {
        ctx.strokeStyle = "rgba(255,140,0,0.8)"; ctx.lineWidth = 1.6;
        ctx.beginPath(); ctx.arc(x, y, r + 6, 0, Math.PI * 2); ctx.stroke();
      }
    });
  };

  Sigma.prototype._loop = function () {
    if (!this._running) return;
    this._step();
    this._draw();
    requestAnimationFrame(this._loop);
  };

  /// Re-seed all node positions in a fresh random disc (the "Reset layout" control).
  Sigma.prototype.resetLayout = function () {
    this.graph._nodes.forEach((n) => {
      const a = Math.random() * Math.PI * 2, r = Math.random() * 40 + 10;
      n.x = Math.cos(a) * r; n.y = Math.sin(a) * r; n.vx = 0; n.vy = 0;
    });
    this._cam = { x: 0, y: 0, zoom: 1 };
  };

  /// No-op refresh hook (the draw loop is continuous); kept for API parity with
  /// upstream Sigma so the driver can call it after bulk graph mutations.
  Sigma.prototype.refresh = function () { /* continuous render loop redraws each frame */ };

  /// Stop the loops and detach listeners (called when the view is hidden/torn down).
  Sigma.prototype.kill = function () {
    this._running = false;
    window.removeEventListener("resize", this._onResize);
    if (this.canvas && this.canvas.parentNode) this.canvas.parentNode.removeChild(this.canvas);
  };

  // Public surface: `Sigma` constructor with a `.Graph` factory hung off it,
  // mirroring the "new Sigma(new Graph(), container)" usage in the driver.
  Sigma.Graph = Graph;
  global.Sigma = Sigma;
})(typeof window !== "undefined" ? window : this);

"""#

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
