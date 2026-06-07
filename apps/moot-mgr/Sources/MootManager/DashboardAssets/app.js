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
