import * as THREE from 'three';
import { OrbitControls } from '/OrbitControls.js';

/*
  moot-mgr read-plane dashboard logic.

  Vanilla JS + Three.js r170 (vendored, MIT) for the topology WebGL renderer.
  All data comes from the resident host's loopback GET /api/* endpoints. This
  script issues ONLY reads (GET + the SSE GET /api/events?stream=1); it never
  POSTs to the control surface — the dashboard is read-only (GUI SPEC §2.1).

  Fields the API does not yet serve are rendered as "n/a" rather than "pending"
  chips — they are honest absent values, not planned future probes.
*/
(function () {
  "use strict";

  // ----- noun type labels (SubstrateTypes.NounType ordinals) -----
  // Index = nounType integer from EventPayload / GraphNodePayload.
  const NOUN_LABELS = [
    "Drawer",        // 0
    "Tunnel",        // 1
    "KG Fact",       // 2
    "Diary Entry",   // 3
    "Proposal",      // 4
    "Association",   // 5
    "Learned Ref",   // 6
    "Ambient Sample" // 7
  ];

  function nounLabel(n) {
    return (n >= 0 && n < NOUN_LABELS.length) ? NOUN_LABELS[n] : "noun " + n;
  }

  // ----- estate name map -----
  // Built from admin.hosted[] on each estates fetch. Maps UUID → human name.
  // Used throughout to replace raw UUIDs with readable estate names.
  let estateNameMap = new Map();

  function buildEstateNameMap(hosted) {
    estateNameMap = new Map();
    if (!hosted) return;
    hosted.forEach(function (e) {
      if (e.estateUUID && e.estateName) estateNameMap.set(e.estateUUID, e.estateName);
    });
  }

  // Returns the estate name if known, otherwise the first 8 chars of the UUID + "…".
  function estateDisplayName(uuid) {
    if (estateNameMap.has(uuid)) return estateNameMap.get(uuid);
    return uuid && uuid.length > 8 ? uuid.slice(0, 8) + "…" : (uuid || "—");
  }

  // ----- last server payload (shared between views for derived state) -----
  let lastServerData = null;

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

  // Formatters
  function fmtUptime(secs) {
    secs = Math.max(0, secs | 0);
    const h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60), s = secs % 60;
    // Drop seconds when runtime is ≥1h — "3h 00m" fits a card; "3h 00m 18s" wraps.
    if (h > 0) return h + "h " + String(m).padStart(2, "0") + "m";
    return m + "m " + String(s).padStart(2, "0") + "s";
  }
  function fmtBytes(b) {
    if (b < 1024) return b + " B";
    const u = ["KB", "MB", "GB"]; let v = b / 1024, i = 0;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return v.toFixed(1) + " " + u[i];
  }
  function fmtRelative(isoTs) {
    const ms = Date.parse(isoTs);
    if (isNaN(ms)) return "—";
    const ageSec = Math.round((Date.now() - ms) / 1000);
    if (ageSec < 5) return "just now";
    if (ageSec < 60) return ageSec + "s ago";
    if (ageSec < 3600) return Math.round(ageSec / 60) + "m ago";
    return Math.round(ageSec / 3600) + "h ago";
  }

  // Metric card (in-place update friendly: caller creates once, updates .cval text)
  function metricCard(label, value, unit, tone) {
    const c = el("div", "card");
    c.appendChild(el("div", "clabel", label));
    const v = el("div", "cval" + (tone ? " " + tone : ""));
    v.appendChild(document.createTextNode(String(value)));
    if (unit) v.appendChild(el("span", "cunit", unit));
    c.appendChild(v);
    return c;
  }

  // ----- panel helper -----
  function panelHead(container, title, hint) {
    const row = el("div", "phead-row");
    row.appendChild(el("h2", "phead", title));
    if (hint) row.appendChild(el("span", "phint", hint));
    container.appendChild(row);
    return row;
  }

  // ----- "What are these codes?" explainer -----
  // Plain-language (8th-grade) explanation of FDC classification codes,
  // shown from the lattice table and the topology content picker. The key
  // point users trip on: the code is derived from the WORDS in the text,
  // not from the topic, so the code's label can differ from what the item
  // is "about" — that is expected, not a filing error.
  function codesExplainerButton() {
    const b = el("button", "btn btn-what", "What are these codes?");
    b.setAttribute("type", "button");
    b.addEventListener("click", showCodesExplainer);
    return b;
  }

  function showCodesExplainer() {
    if ($("#codesExplainer")) return;   // already open
    const wrap = el("div", "mx-modal-backdrop");
    wrap.id = "codesExplainer";
    const box = el("div", "mx-modal");
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-modal", "true");
    box.setAttribute("aria-labelledby", "codesExplainerTitle");

    const h = el("h2", "mx-modal-title", "What are these codes?");
    h.id = "codesExplainerTitle";
    box.appendChild(h);

    [
      "Every memory that comes in gets a code — like the call number on a " +
      "library book. Nearby numbers mean similar subjects, so related " +
      "memories end up on the same shelf and can be found together.",

      "The computer picks the code by looking at the actual words in the " +
      "text and matching them against a fixed, public list of about a " +
      "thousand subjects. The same words always land on the same code — on " +
      "every computer, with no guessing.",

      "Because the code comes from the words — not from what the item is " +
      "“really about” — the label next to a code can look " +
      "different from your topic. A note about your bakery’s budget " +
      "might file under “Accounting + Bookkeeping,” because budget " +
      "words dominate the text. That’s normal: the code is just the " +
      "shelf where similar-sounding memories sit, and it still groups " +
      "related things together.",

      "Want to dig into one memory? On the Topology view, right-click any " +
      "dot. That copies a ready-made question to your clipboard — paste it " +
      "into your AI assistant, and it will pull up that memory and its " +
      "closest neighbors and explain what they’re likely about.",
    ].forEach(function (t) { box.appendChild(el("p", "mx-modal-p", t)); });

    const close = el("button", "btn mx-modal-close", "Got it");
    close.setAttribute("type", "button");
    function dismiss() {
      document.removeEventListener("keydown", onKey);
      wrap.remove();
      if (opener && opener.focus) opener.focus();
    }
    function onKey(e) { if (e.key === "Escape") dismiss(); }
    const opener = document.activeElement;
    close.addEventListener("click", dismiss);
    wrap.addEventListener("click", function (e) { if (e.target === wrap) dismiss(); });
    document.addEventListener("keydown", onKey);
    box.appendChild(close);
    wrap.appendChild(box);
    document.body.appendChild(wrap);
    close.focus();
  }

  // ----- top-bar status -----
  function setStatus(running, server) {
    const pill = $("#statusPill"), txt = $("#statusText");
    pill.classList.toggle("running", running);
    pill.classList.toggle("stopped", !running);
    txt.textContent = running ? "RUNNING" : "STOPPED";
    if (server) {
      $("#monIndicator").textContent = server.monitoringEnabled ? "ON" : "OFF";
      $("#uptimeTag").textContent = fmtUptime(server.uptimeSeconds);
      $("#estateCountTag").textContent = String(server.estateCount);
    } else {
      $("#monIndicator").textContent = "—";
      $("#uptimeTag").textContent = "—";
      $("#estateCountTag").textContent = "—";
    }
    const now = new Date();
    $("#lastUpdated").textContent = "updated " +
      String(now.getHours()).padStart(2, "0") + ":" +
      String(now.getMinutes()).padStart(2, "0") + ":" +
      String(now.getSeconds()).padStart(2, "0");
  }

  // =========================================================================
  // OVERVIEW (concept-faithful rebuild)
  // =========================================================================

  // In-place card update: update existing cards' .cval text, or rebuild if count changed.
  function renderOverviewCards(s) {
    const container = $("#ovCards");
    if (!container) return;

    // Card definitions: [label, valueFn, unit, tone]
    const defs = [
      ["Uptime",      () => fmtUptime(s.uptimeSeconds),               null,    null],
      ["Connections", () => s.connections != null ? String(s.connections) : "—", null, "blue"],
      ["Events",      () => s.totalEvents.toLocaleString(),            null,    "orange"],
      ["RPC/s",       () => s.rpcRate != null ? s.rpcRate.toFixed(2) : "—",    null, null],
      ["CPU %",       () => s.cpuPct != null ? s.cpuPct.toFixed(1) : "—",      null, null],
      ["RSS",         () => s.rssMb != null ? s.rssMb.toFixed(1) : "—",        s.rssMb != null ? "MB" : null, null],
    ];

    // In-place update when card count hasn't changed — avoids flicker.
    const existing = $$("#ovCards .card");
    if (existing.length === defs.length) {
      existing.forEach(function (card, i) {
        const valEl = card.querySelector(".cval");
        if (valEl) {
          // Replace text node only; preserve cunit span if present.
          const nodes = Array.from(valEl.childNodes);
          const textNode = nodes.find((n) => n.nodeType === Node.TEXT_NODE);
          const unitSpan = valEl.querySelector(".cunit");
          const newVal = String(defs[i][1]());
          if (textNode) { textNode.textContent = newVal; }
          else { valEl.insertBefore(document.createTextNode(newVal), valEl.firstChild); }
          if (defs[i][2] && !unitSpan) valEl.appendChild(el("span", "cunit", defs[i][2]));
          else if (unitSpan) unitSpan.textContent = defs[i][2] || "";
        }
      });
      return;
    }

    // Rebuild on count change (first load or card set changed).
    clear(container);
    defs.forEach(function (d) {
      container.appendChild(metricCard(d[0], d[1](), d[2], d[3]));
    });
  }

  // Cache key for the last vol-bars render — skip rebuild when data is unchanged
  // so the CSS transition animation doesn't restart on every 5s poll cycle.
  let lastVolBarsKey = "";

  // Time-series volume bars — total event count on Y, time on X.
  // Receives the already-fetched events array from renderOverview; no extra fetch needed.
  function renderVolBars(events) {
    const bars = $("#ovVolBars");
    const axis = $("#ovVolAxis");
    if (!bars) return;

    // Guard: skip rebuild if event data hasn't changed since last render.
    const key = (events ? events.length : 0) + "|" + (events && events.length ? events[events.length - 1].ts : "");
    if (key === lastVolBarsKey) return;
    lastVolBarsKey = key;

    clear(bars);
    if (axis) clear(axis);

    if (!events || !events.length) {
      bars.appendChild(el("div", "empty", "no event data for time-series"));
      return;
    }

    // Parse ISO timestamps, drop invalid, sort ascending.
    const parsed = events
      .map(function (ev) { return Date.parse(ev.ts); })
      .filter(function (t) { return !isNaN(t); })
      .sort(function (a, b) { return a - b; });

    if (!parsed.length) {
      bars.appendChild(el("div", "empty", "no timestamped events"));
      return;
    }

    const tMin = parsed[0];
    const tMax = parsed[parsed.length - 1];
    const rangeMs = Math.max(1, tMax - tMin);

    // Aim for ~16 bars; minimum bucket = 1 minute.
    const NUM_BARS = 16;
    let bucketMs = Math.ceil(rangeMs / NUM_BARS);
    if (bucketMs < 60000) bucketMs = 60000;
    const numBuckets = Math.min(24, Math.ceil(rangeMs / bucketMs) + 1);
    const buckets = new Array(numBuckets).fill(0);

    events.forEach(function (ev) {
      const t = Date.parse(ev.ts);
      if (isNaN(t)) return;
      const idx = Math.min(Math.floor((t - tMin) / bucketMs), numBuckets - 1);
      buckets[idx]++;
    });

    const maxCount = Math.max(1, Math.max.apply(null, buckets));

    buckets.forEach(function (count) {
      const bar = el("div", "bar");
      bar.style.height = "3px"; // CSS transition animates to final height
      bar.title = count + " events";
      bars.appendChild(bar);
      setTimeout(function () {
        bar.style.height = Math.max(4, Math.round((count / maxCount) * 100)) + "%";
      }, 60);
    });

    if (axis) {
      function fmtAxisTime(ms) {
        const d = new Date(ms);
        return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
      }
      axis.appendChild(el("span", null, fmtAxisTime(tMin)));
      axis.appendChild(el("span", null, fmtAxisTime(tMax)));
    }
  }

  // Ranked horizontal bar list (concept "Top tools" — top observers by total calls).
  function renderTopObs(s) {
    const container = $("#ovTopObsList");
    if (!container) return;
    clear(container);

    if (!s || !s.byDropbox || !s.byDropbox.length) {
      container.appendChild(el("div", "empty", "no observer activity yet"));
      return;
    }
    const sorted = s.byDropbox.slice()
      .sort((a, b) => (b.metricCount + b.eventCount) - (a.metricCount + a.eventCount))
      .slice(0, 5);
    const maxTotal = Math.max(1, sorted[0].metricCount + sorted[0].eventCount);

    sorted.forEach(function (d) {
      const total = d.metricCount + d.eventCount;
      const item = el("div", "item");
      item.appendChild(el("span", "name", d.name));
      const meter = el("div", "meter");
      const fill = document.createElement("i");
      fill.style.width = Math.round((total / maxTotal) * 100) + "%";
      meter.appendChild(fill);
      item.appendChild(meter);
      item.appendChild(el("span", "n", total.toLocaleString()));
      container.appendChild(item);
    });
  }

  // Capabilities panel (concept .cap style — LED + .nm label + .ds descriptor right-aligned).
  function renderOverviewCaps(s) {
    const container = $("#ovCapList");
    if (!container) return;
    clear(container);

    const rows = [
      { label: "Monitoring",  desc: s ? (s.monitoringEnabled ? "ON" : "OFF") : "—", on: !!(s && s.monitoringEnabled) },
      { label: "Stats store", desc: s ? fmtBytes(s.storeSizeBytes) : "—",           on: !!(s && s.storeSizeBytes > 0) },
      { label: "Kernel",      desc: (s && s.kernelBackend) || "—",                   on: !!(s && s.kernelBackend) },
    ];
    const caps = s && s.capabilities ? s.capabilities : [];
    caps.forEach(function (name) { rows.push({ label: name, desc: "active", on: true }); });

    rows.forEach(function (r) {
      const div = el("div", "cap");
      div.appendChild(el("span", "led " + (r.on ? "on" : "off")));
      div.appendChild(el("span", "nm", r.label));
      div.appendChild(el("span", "ds", r.desc));
      container.appendChild(div);
    });
    if (!caps.length) {
      const note = el("div", "cap");
      note.style.opacity = "0.5";
      note.appendChild(el("span", "led off"));
      note.appendChild(el("span", "nm", "NeuronKit capabilities"));
      note.appendChild(el("span", "ds", "not reported"));
      container.appendChild(note);
    }
  }

  // Health check list (concept .health li — circular .check icon + .txt label + .sub detail).
  function renderOverviewHealth(s, c) {
    const ul = $("#ovHealthList");
    if (!ul) return;
    clear(ul);
    const running = !!s && $("#statusPill").classList.contains("running");

    // WAL frame count: 0 is ideal (fully checkpointed). Warn above 500 frames.
    const walFrames = s && s.storeWalFrameCount != null ? s.storeWalFrameCount : null;
    const walOk     = walFrames === null || walFrames < 500;

    // Cache hit ratio: nil → n/a; <0.80 → warn (cache pressure).
    const cacheRatio  = s && s.storeCacheHitRatio != null ? s.storeCacheHitRatio : null;
    const cacheOk     = cacheRatio === null || cacheRatio >= 0.80;
    const cachePct    = cacheRatio !== null ? (cacheRatio * 100).toFixed(1) + "%" : "—";

    // Freelist ratio: free pages / total pages. >10 % suggests fragmentation.
    const pageCount   = s && s.storePageCount != null ? s.storePageCount : null;
    const freePages   = s && s.storeFreelistPageCount != null ? s.storeFreelistPageCount : null;
    const fragRatio   = (pageCount && pageCount > 0 && freePages !== null)
                          ? freePages / pageCount : null;
    const fragOk      = fragRatio === null || fragRatio < 0.10;
    const fragDetail  = fragRatio !== null
                          ? freePages + " free / " + pageCount + " pages"
                          : (pageCount !== null ? pageCount + " pages" : "—");

    const checks = [
      [running ? "✓" : "!", running ? "ok" : "warn", "Server running",  running ? "RUNNING" : "STOPPED"],
      [s && s.monitoringEnabled ? "✓" : "!", s && s.monitoringEnabled ? "ok" : "warn",
       "Monitoring", s ? (s.monitoringEnabled ? "ON" : "OFF") : "—"],
      [s ? "✓" : "—", s ? "ok" : "warn", "Stats store",
       s ? fmtBytes(s.storeSizeBytes) + (s.storeRowCount != null ? " · " + s.storeRowCount + " rows" : "") : "—"],
      [c ? "✓" : "—", "ok", "Retention", c ? c.retentionSeconds + "s" : "—"],
      [walFrames !== null ? (walOk ? "✓" : "!") : "—", walOk ? "ok" : "warn",
       "WAL frames", walFrames !== null ? walFrames + (walOk ? "" : " (high)") : "—"],
      [cacheRatio !== null ? (cacheOk ? "✓" : "!") : "—", cacheOk ? "ok" : "warn",
       "Cache hit", cachePct],
      [fragRatio !== null ? (fragOk ? "✓" : "!") : "—", fragOk ? "ok" : "warn",
       "Fragmentation", fragDetail],
    ];
    checks.forEach(function (r) {
      const li = el("li");
      const check = el("span", "check " + r[1], r[0]);
      check.setAttribute("aria-hidden", "true");
      li.appendChild(check);
      const textDiv = el("div");
      textDiv.appendChild(el("div", "txt", r[2]));
      textDiv.appendChild(el("div", "sub", r[3]));
      li.appendChild(textDiv);
      ul.appendChild(li);
    });
  }

  // Live feed (concept .feed .ev — time · method orange · session · latency).
  async function renderMiniFeeed(events) {
    const feed = $("#ovMiniFeeed");
    if (!feed) return;
    clear(feed);
    if (!events || !events.length) {
      feed.appendChild(el("div", "empty", "no recent events"));
      return;
    }
    events.slice(0, 10).forEach(function (ev) {
      const div = el("div", "ev");
      const tsDate = ev.ts ? new Date(ev.ts) : null;
      const timeStr = tsDate ?
        String(tsDate.getHours()).padStart(2, "0") + ":" +
        String(tsDate.getMinutes()).padStart(2, "0") + ":" +
        String(tsDate.getSeconds()).padStart(2, "0") : "—";
      div.appendChild(el("span", "t", timeStr));
      div.appendChild(el("span", "m", ev.kind + " · " + nounLabel(ev.nounType)));
      div.appendChild(el("span", "d", estateDisplayName(ev.estate)));
      div.appendChild(el("span", "lat", "—"));
      feed.appendChild(div);
    });
  }

  // Busiest-estates bar chart (Row 4). Sorts by eventCount descending, shows
  // top 5. Degrades gracefully when the estates list is absent or empty.
  function renderBusiestEstates(estates) {
    const container = $("#ovBusiestList");
    if (!container) return;
    clear(container);

    if (!estates || !estates.length) {
      container.appendChild(el("div", "empty", "no estate activity yet"));
      return;
    }
    // Top 5 by event count. Ties broken by most recent last-event timestamp.
    const sorted = estates.slice()
      .sort((a, b) => (b.eventCount || 0) - (a.eventCount || 0))
      .slice(0, 5);
    const maxCount = Math.max(1, sorted[0].eventCount || 0);

    sorted.forEach(function (e) {
      const count = e.eventCount || 0;
      const row = el("div", "bar-row");
      row.appendChild(el("span", "bar-name", estateDisplayName(e.id)));
      const track = el("div", "bar-track");
      const fill = el("div", "bar-fill");
      fill.style.width = Math.round((count / maxCount) * 100) + "%";
      track.appendChild(fill);
      row.appendChild(track);
      row.appendChild(el("span", "bar-count", count.toLocaleString()));
      container.appendChild(row);
    });
  }

  async function renderOverview() {
    let s = null, c = null, events = [], estates = [];
    try {
      s = await getJSON("/api/server");
      lastServerData = s;
      setStatus(true, s);
    } catch (e) {
      setStatus(false, null);
      const cards = $("#ovCards");
      if (cards) { clear(cards); cards.appendChild(el("div", "empty", "server unreachable — " + e.message)); }
    }
    try { c = await getJSON("/api/config"); } catch (_) { /* health panel degrades */ }
    try {
      const ep = await getJSON("/api/events");
      events = ep.events || [];
    } catch (_) { /* mini-feed degrades */ }
    try {
      // Fetch estates for busiest-estates ranking. Degrades gracefully when
      // the endpoint is unavailable — the panel shows "no estate activity yet".
      const ep = await getJSON("/api/estates");
      buildEstateNameMap((ep.admin && ep.admin.hosted) ? ep.admin.hosted : []);
      estates = ep.estates || [];
    } catch (_) { /* busiest-estates panel degrades silently */ }

    if (s) {
      renderOverviewCards(s);
      renderVolBars(events);
      renderTopObs(s);
      renderOverviewCaps(s);
    }
    renderOverviewHealth(s, c);
    await renderMiniFeeed(events);
    renderBusiestEstates(estates);
  }

  // =========================================================================
  // RESOURCES (estate content surfaces)
  // =========================================================================

  async function renderResources() {
    const body = $("#resourcesBody");
    if (!body) return;
    clear(body);
    try {
      const p = await getJSON("/api/estates");
      buildEstateNameMap((p.admin && p.admin.hosted) ? p.admin.hosted : []);
      const estates = p.estates || [];
      if (!estates.length) {
        const tr = el("tr"); const td = el("td"); td.colSpan = 7;
        td.appendChild(el("span", "empty", "no estates observed"));
        tr.appendChild(td); body.appendChild(tr); return;
      }
      estates.forEach(function (e) {
        const tr = el("tr");
        tr.appendChild(el("td", null, estateDisplayName(e.id)));
        // contentCounts is nil when admin plane is absent or estate not provisioned locally.
        const cc = e.contentCounts;
        function tdCount(n) {
          const td = document.createElement("td");
          td.className = ""; td.style.fontFamily = "var(--font-m)"; td.style.fontSize = "12px";
          if (n == null) { td.textContent = "—"; td.className = "td-na"; }
          else td.textContent = n.toLocaleString();
          return td;
        }
        tr.appendChild(tdCount(cc ? cc.wingCount : null));
        tr.appendChild(tdCount(cc ? cc.drawerCount : null));
        tr.appendChild(tdCount(cc ? cc.kgFactCount : null));
        tr.appendChild(tdCount(cc ? cc.diaryEntryCount : null));
        tr.appendChild(tdCount(cc ? cc.proposalCount : null));
        tr.appendChild(el("td", null, e.eventCount.toLocaleString()));
        body.appendChild(tr);
      });
      if (!estates.some((e) => e.contentCounts)) {
        const note = document.createElement("tr");
        const td = document.createElement("td"); td.colSpan = 7;
        td.style.padding = "8px 10px";
        td.style.fontSize = "11px"; td.style.color = "var(--muted)";
        td.style.fontStyle = "italic";
        td.textContent = "Content counts require the admin plane — shown as — for observer-only mode.";
        note.appendChild(td); body.appendChild(note);
      }
    } catch (e) {
      const tr = el("tr"); const td = el("td"); td.colSpan = 7;
      td.appendChild(el("span", "empty", "estates unreachable — " + e.message));
      tr.appendChild(td); body.appendChild(tr);
    }
  }

  // =========================================================================
  // CONNECTS (observer dropbox connections)
  // =========================================================================

  async function renderConnects() {
    const body = $("#connectsBody");
    if (!body) return;
    clear(body);
    try {
      const s = await getJSON("/api/server");
      lastServerData = s;
      const dropboxes = s.byDropbox || [];
      if (!dropboxes.length) {
        const tr = el("tr"); const td = el("td"); td.colSpan = 6;
        td.appendChild(el("span", "empty", "no observer dropboxes observed yet"));
        tr.appendChild(td); body.appendChild(tr); return;
      }
      dropboxes.forEach(function (d) {
        const tr = el("tr");
        tr.appendChild(el("td", null, d.name));
        // Transport is always "local" — ObserverSink is process-internal.
        const tdT = el("td"); tdT.style.fontFamily = "var(--font-m)"; tdT.style.fontSize = "11px";
        tdT.style.color = "var(--muted)"; tdT.textContent = "local";
        tr.appendChild(tdT);
        tr.appendChild(el("td", null, d.metricCount.toLocaleString()));
        tr.appendChild(el("td", null, d.eventCount.toLocaleString()));
        const total = d.metricCount + d.eventCount;
        tr.appendChild(el("td", null, total.toLocaleString()));
        const lastTd = el("td", null, d.lastSeenISO ? fmtRelative(d.lastSeenISO) : "—");
        lastTd.title = d.lastSeenISO || "";
        tr.appendChild(lastTd);
        body.appendChild(tr);
      });
    } catch (e) {
      const tr = el("tr"); const td = el("td"); td.colSpan = 6;
      td.appendChild(el("span", "empty", "server unreachable — " + e.message));
      tr.appendChild(td); body.appendChild(tr);
    }
  }

  // =========================================================================
  // ESTATES
  // =========================================================================

  async function renderEstates() {
    const list = $("#estatesList");
    clear(list);
    try {
      const p = await getJSON("/api/estates");
      const adminHosted = (p.admin && p.admin.hosted) ? p.admin.hosted : [];
      buildEstateNameMap(adminHosted);
      const eventEstates = p.estates || [];

      if (adminHosted.length === 0 && eventEstates.length === 0) {
        const fr = el("div", "first-run");
        const frIcon = el("span", "fr-icon", "◊");
        frIcon.setAttribute("aria-hidden", "true");
        fr.appendChild(frIcon);
        fr.appendChild(el("h2", null, "No estates provisioned yet"));
        fr.appendChild(el("p", null, "Add your first estate from the menu-bar ↑"));
        list.appendChild(fr);
        return;
      }

      const evMap = Object.create(null);
      eventEstates.forEach((e) => { evMap[e.id] = e; });

      if (adminHosted.length > 0) {
        adminHosted.forEach((entry) => {
          const card = el("div", "estate");
          card.appendChild(el("div", "ename", entry.estateName || entry.estateUUID));

          const badges = el("div", "badge-row");
          const kindCls = entry.kind === "GLK" ? "glk"
            : entry.kind === "CorpusOnly" ? "corpusonly" : "locusonly";
          badges.appendChild(el("span", "badge badge-kind " + kindCls, entry.kind));
          const bEl = el("span", "badge badge-backend" + (entry.backend === "InMemory" ? " inmemory" : ""));
          bEl.textContent = (entry.backend === "InMemory" ? "⚠ " : "") + entry.backend;
          badges.appendChild(bEl);
          const mountCls = entry.mountState === "mounted" ? "mounted"
            : entry.mountState === "quiesced" ? "quiesced"
            : entry.mountState === "draining" ? "draining" : "";
          const mEl = el("span", "badge badge-mount " + mountCls);
          mEl.appendChild(el("span", "mount-dot"));
          mEl.appendChild(document.createTextNode(entry.mountState || "unknown"));
          badges.appendChild(mEl);
          card.appendChild(badges);
          card.appendChild(el("hr", "estate-divider"));

          const ev = evMap[entry.estateUUID];
          const r1 = el("div", "erow");
          r1.appendChild(el("span", null, "Events"));
          r1.appendChild(el("b", null, ev ? String(ev.eventCount) : "0"));
          card.appendChild(r1);
          const r2 = el("div", "erow");
          r2.appendChild(el("span", null, "Last"));
          r2.appendChild(el("b", null, (ev && ev.lastEventTs) ? ev.lastEventTs : "—"));
          card.appendChild(r2);

          const actions = el("div", "estate-actions");
          const btnQ = el("button", "btn btn-ghost", "Quiesce");
          btnQ.disabled = true; btnQ.title = "manage from the native menu-bar";
          const btnD = el("button", "btn btn-ghost", "Drain");
          btnD.disabled = true; btnD.title = "manage from the native menu-bar";
          actions.appendChild(btnQ); actions.appendChild(btnD);
          card.appendChild(actions);
          list.appendChild(card);
        });
      } else if (eventEstates.length > 0) {
        list.appendChild(el("div", "estates-section-label",
          "No admin-hosted estates. Add one from the native menu-bar."));
      }

      const adminUUIDs = new Set(adminHosted.map((e) => e.estateUUID));
      const external = eventEstates.filter((e) => !adminUUIDs.has(e.id));
      if (external.length > 0) {
        list.appendChild(el("div", "estates-section-label", "EXTERNAL REPORTERS"));
        external.forEach((e) => {
          const card = el("div", "estate");
          card.appendChild(el("div", "ename", estateDisplayName(e.id)));
          const r1 = el("div", "erow");
          r1.appendChild(el("span", null, "events")); r1.appendChild(el("b", null, String(e.eventCount)));
          card.appendChild(r1);
          const r2 = el("div", "erow");
          r2.appendChild(el("span", null, "last event"));
          r2.appendChild(el("b", null, e.lastEventTs || "—"));
          card.appendChild(r2);
          list.appendChild(card);
        });
      }
    } catch (e) {
      list.appendChild(el("div", "empty", "estates unreachable — " + e.message));
    }
  }

  // =========================================================================
  // PIPELINE
  // =========================================================================

  function updateStageValue(dataStageKey, val) {
    const st = $("[data-stage='" + dataStageKey + "']", $("#pipelineStrip"));
    if (!st) return;
    const valEl = st.querySelector(".sval");
    if (valEl) {
      valEl.textContent = (val === null || val === undefined) ? "—" : String(val);
      st.classList.remove("pending");
    }
  }

  // Render backpressure as pill cards — one card per stat.
  function renderBackpressurePills(selector, q) {
    const container = $(selector);
    if (!container) return;
    clear(container);
    if (!q) {
      container.appendChild(el("div", "empty", "no queue data for this estate"));
      return;
    }
    const stats = [
      ["depth",        q.depth != null ? q.depth.toFixed(0) : null],
      ["p50 ms",       q.latencyP50Ms != null ? q.latencyP50Ms.toFixed(1) : null],
      ["p95 ms",       q.latencyP95Ms != null ? q.latencyP95Ms.toFixed(1) : null],
      ["hol age s",    q.headOfLineAgeS != null ? q.headOfLineAgeS.toFixed(1) : null],
      ["idle ∅empty",  q.idleNonempty != null ? (q.idleNonempty ? "yes" : "no") : null],
      ["gate admits",  q.gateAdmitCount != null ? q.gateAdmitCount.toFixed(0) : null],
      ["gate rejects", q.gateRejectCount != null ? q.gateRejectCount.toFixed(0) : null],
    ];
    stats.forEach(function (s) {
      const card = el("div", "bpcard");
      card.appendChild(el("div", "bpl", s[0]));
      const vEl = el("div", "bpv" + (s[1] == null ? " na" : ""), s[1] != null ? s[1] : "—");
      card.appendChild(vEl);
      container.appendChild(card);
    });
  }

  async function renderPipeline() {
    const strip = $("#pipelineStrip");
    clear(strip);
    const stageDefs = [
      { name: "intake",      dataStage: null },
      { name: "write-gate",  dataStage: "gateAdmit" },
      { name: "queue depth", dataStage: "queueDepth" },
      { name: "drain",       dataStage: null },
      { name: "enrichment",  dataStage: null },
    ];
    stageDefs.forEach(({ name, dataStage }, i) => {
      const st = el("div", "stage pending");
      if (dataStage) st.setAttribute("data-stage", dataStage);
      st.appendChild(el("div", "sname", name));
      st.appendChild(el("div", "sval", "—"));
      strip.appendChild(st);
      if (i < stageDefs.length - 1) strip.appendChild(el("span", "arrow", "→"));
    });

    let eq = null;
    try {
      const ep = await getJSON("/api/estates");
      buildEstateNameMap((ep.admin && ep.admin.hosted) ? ep.admin.hosted : []);
      const sel = $("#pipelineEstate");
      const prevVal = sel.value;
      const allIds = new Set();
      ((ep.admin && ep.admin.hosted) ? ep.admin.hosted : []).forEach((e) => allIds.add(e.estateUUID));
      (ep.estates || []).forEach((e) => allIds.add(e.id));
      const ids = Array.from(allIds).sort();
      const existingIds = Array.from(sel.options).slice(1).map((o) => o.value);
      if (ids.join(",") !== existingIds.join(",")) {
        clear(sel);
        sel.appendChild(new Option("all", ""));
        ids.forEach((id) => {
          const label = estateDisplayName(id);
          sel.appendChild(new Option(label === id ? id : label + " (" + id.slice(0,8) + "…)", id));
        });
      }
      if (prevVal && Array.from(sel.options).some((o) => o.value === prevVal)) sel.value = prevVal;
      const estateFilter = sel.value;
      if (estateFilter && ep.estates) {
        eq = ep.estates.find((e) => e.id === estateFilter) || null;
      } else if (ep.estates && ep.estates.length > 0) {
        eq = ep.estates.find((e) => e.queue) || ep.estates[0] || null;
      }
    } catch (_) { /* estate selector degrades gracefully */ }

    if (eq && eq.queue) {
      const q = eq.queue;
      updateStageValue("queueDepth", q.depth != null ? q.depth.toFixed(0) : "—");
      updateStageValue("gateAdmit", q.gateAdmitCount != null ? q.gateAdmitCount.toFixed(0) : "—");
      renderBackpressurePills("#pipelineBackpressure", q);
    } else {
      renderBackpressurePills("#pipelineBackpressure", null);
    }

    const flow = $("#pipelineFlow");
    clear(flow);
    const estateFilter = $("#pipelineEstate").value;
    try {
      const p = await getJSON("/api/events");
      const recent = p.events.slice(0, 12);
      let rowsShown = 0;
      recent.forEach((ev) => {
        if (estateFilter && ev.estate !== estateFilter) return;
        rowsShown++;
        const row = el("div", "frow");
        row.appendChild(el("span", null, ev.ts));
        const k = el("span", "k " + (ev.kind === "capture" ? "capture" : ev.kind === "think" ? "think" : ""), ev.kind);
        row.appendChild(k);
        row.appendChild(el("span", null, "estate=" + estateDisplayName(ev.estate)));
        row.appendChild(el("span", null, "via " + ev.dropbox));
        flow.appendChild(row);
      });
      if (!rowsShown) flow.appendChild(el("div", "empty", "no recent flow"));
      const cutoffMs = Date.now() - 60000;
      const recentCount = p.events.filter((ev) => {
        const ms = Date.parse(ev.ts);
        return !isNaN(ms) && ms >= cutoffMs;
      }).length;
      const rateChip = el("div", "flow-rate" + (recentCount > 10 ? " flow-rate-active" : ""));
      rateChip.textContent = recentCount + " events/min";
      flow.appendChild(rateChip);
    } catch (e) {
      flow.appendChild(el("div", "empty", "events unreachable — " + e.message));
    }
  }

  // =========================================================================
  // ACTIVITY + SSE live tail
  // =========================================================================

  let sse = null, ssePaused = false, activityRows = [];
  const ACTIVITY_CAP = 500;
  let kindFilter = null;
  let expandedIdx = null;

  function activityMatches(ev, q) {
    if (kindFilter && ev.kind !== kindFilter) return false;
    if (!q) return true;
    q = q.toLowerCase();
    // Match against the human-readable name too, not just the raw UUID.
    const estateName = estateDisplayName(ev.estate).toLowerCase();
    return (ev.estate || "").toLowerCase().includes(q)
        || estateName.includes(q)
        || (ev.kind || "").toLowerCase().includes(q)
        || (ev.dropbox || "").toLowerCase().includes(q)
        || nounLabel(ev.nounType).toLowerCase().includes(q);
  }

  function handleRowClick(body, ev, idx) {
    if (expandedIdx === idx) {
      const next = this.nextSibling;
      if (next && next.classList && next.classList.contains("row-expand")) body.removeChild(next);
      this.setAttribute("aria-expanded", "false");
      expandedIdx = null;
      return;
    }
    if (expandedIdx !== null) {
      const prevTr = body.querySelector("tr[data-idx='" + expandedIdx + "']");
      if (prevTr) {
        prevTr.setAttribute("aria-expanded", "false");
        const prevNext = prevTr.nextSibling;
        if (prevNext && prevNext.classList && prevNext.classList.contains("row-expand")) {
          body.removeChild(prevNext);
        }
      }
    }
    expandedIdx = idx;
    this.setAttribute("aria-expanded", "true");
    const detailTr = el("tr", "row-expand");
    detailTr.setAttribute("aria-hidden", "true");
    const detailTd = el("td");
    detailTd.colSpan = 5;

    // Concept .insp-inner: 2-column — Event (left) + Context (right)
    const inner = el("div", "insp-inner");

    const leftDiv = el("div");
    leftDiv.appendChild(el("span", "sec-lab", "Event"));
    const grid1 = el("div", "expand-grid");
    [["timestamp", ev.ts],
     ["kind", ev.kind],
     ["noun", nounLabel(ev.nounType) + " (" + ev.nounType + ")"],
     ["dropbox", ev.dropbox]].forEach(function (pair) {
      grid1.appendChild(el("span", "exp-key", pair[0]));
      grid1.appendChild(el("span", "exp-val", pair[1]));
    });
    leftDiv.appendChild(grid1);
    inner.appendChild(leftDiv);

    const rightDiv = el("div");
    rightDiv.appendChild(el("span", "sec-lab", "Context"));
    const grid2 = el("div", "expand-grid");
    [["estate (name)", estateDisplayName(ev.estate)],
     ["estate (uuid)", ev.estate]].forEach(function (pair) {
      grid2.appendChild(el("span", "exp-key", pair[0]));
      grid2.appendChild(el("span", "exp-val", pair[1]));
    });
    rightDiv.appendChild(grid2);
    inner.appendChild(rightDiv);

    detailTd.appendChild(inner);
    detailTr.appendChild(detailTd);
    body.insertBefore(detailTr, this.nextSibling);
  }

  function paintActivity() {
    const body = $("#activityBody");
    const q = $("#activityFilter").value.trim();
    clear(body);
    expandedIdx = null;
    const shown = activityRows.filter((ev) => activityMatches(ev, q));
    if (!shown.length) {
      const tr = el("tr"); const td = el("td"); td.colSpan = 5;
      td.appendChild(el("span", "empty", (q || kindFilter) ? "no rows match the filter" : "no events recorded"));
      tr.appendChild(td); body.appendChild(tr); return;
    }
    shown.forEach((ev, i) => {
      const tr = el("tr");
      tr.dataset.idx = String(i);
      tr.tabIndex = 0;
      tr.setAttribute("role", "button");
      tr.setAttribute("aria-expanded", "false");

      // Time: HH:MM:SS (ISO timestamp formatted, not raw string)
      const tsDate = ev.ts ? new Date(ev.ts) : null;
      const timeStr = tsDate ?
        String(tsDate.getHours()).padStart(2, "0") + ":" +
        String(tsDate.getMinutes()).padStart(2, "0") + ":" +
        String(tsDate.getSeconds()).padStart(2, "0") : (ev.ts || "—");
      tr.appendChild(el("td", null, timeStr));

      // Method: concept .lex chip — kind · noun label
      const methodTd = el("td");
      const chip = el("span", "lex " + (ev.kind || ""), ev.kind + " · " + nounLabel(ev.nounType));
      chip.setAttribute("aria-label", ev.kind + " " + nounLabel(ev.nounType));
      methodTd.appendChild(chip);
      tr.appendChild(methodTd);

      // Session: estate display name (UUID→name via estateNameMap)
      tr.appendChild(el("td", null, estateDisplayName(ev.estate)));

      // Dropbox
      tr.appendChild(el("td", null, ev.dropbox));

      // Status: concept .stat.ok chip with LED dot (always ok — no error concept in observer events)
      const statusTd = el("td");
      const stat = el("span", "stat ok");
      const ledDot = el("span", "led on"); ledDot.setAttribute("aria-hidden", "true");
      stat.appendChild(ledDot);
      stat.appendChild(document.createTextNode(" ok"));
      statusTd.appendChild(stat);
      tr.appendChild(statusTd);

      function activateRow() {
        if (!this.dataset.idx) return;
        handleRowClick.call(this, body, ev, parseInt(this.dataset.idx, 10));
      }
      tr.addEventListener("click", activateRow);
      tr.addEventListener("keydown", function (e) {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); activateRow.call(this); }
      });
      body.appendChild(tr);
    });
  }

  function pushEvent(ev) {
    activityRows.unshift(ev);
    if (activityRows.length > ACTIVITY_CAP) activityRows.length = ACTIVITY_CAP;
  }

  async function renderActivity() {
    try {
      // Refresh the estate name map before rendering activity so names are fresh.
      try {
        const ep = await getJSON("/api/estates");
        buildEstateNameMap((ep.admin && ep.admin.hosted) ? ep.admin.hosted : []);
      } catch (_) { /* name map degrades — UUIDs shown */ }
      const p = await getJSON("/api/events");
      activityRows = p.events.slice(0, ACTIVITY_CAP);
    } catch (_) {
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
      try { pushEvent(JSON.parse(m.data)); paintActivity(); } catch (_) { }
    };
    sse.onerror = () => { $("#sseState").textContent = "reconnecting"; };
  }
  function stopSSE() {
    if (sse) { sse.close(); sse = null; }
    $("#sseState").textContent = "off";
  }

  // =========================================================================
  // LEXICON — ARIA grammar explorer
  // =========================================================================

  async function renderLexicon() {
    const container = $("#lexiconContent");
    if (!container) return;
    clear(container);

    let lex = null;
    try { lex = await getJSON("/api/lexicon"); } catch (e) {
      container.appendChild(el("div", "empty", "lexicon unreachable — " + e.message));
      return;
    }

    // Summary stat cards
    const totalPairs = Object.values(lex.acceptance)
      .reduce(function (s, vs) { return s + vs.length; }, 0);
    const cardRow = el("div", "cards");
    [
      ["Nouns",      String(lex.nouns.length),      null, null],
      ["Verbs",      String(lex.verbs.length),      null, null],
      ["Adjectives", String(lex.adjectives.length), null, null],
      ["Valid pairs", String(totalPairs),            null, "orange"],
    ].forEach(function (d) { cardRow.appendChild(metricCard(d[0], d[1], d[2], d[3])); });
    container.appendChild(cardRow);

    // Two-column layout: acceptance matrix (2fr left) + verbs + adjectives (1fr right)
    const cols = el("div", "panels-3col");

    // Left: acceptance matrix
    const matrixPanel = el("div", "panel panel-2col");
    panelHead(matrixPanel, "Acceptance Matrix", "verb × noun");

    const tbl = el("table", "dtable");
    tbl.style.marginTop = "10px";
    const thead = el("thead");
    const hrow = el("tr");
    ["Noun", "Valid Verbs", "Count"].forEach(function (h) { hrow.appendChild(el("th", null, h)); });
    thead.appendChild(hrow);
    tbl.appendChild(thead);

    const tbody = el("tbody");
    lex.nouns.forEach(function (noun) {
      const verbs = (lex.acceptance[noun] || []).slice().sort();
      const tr = el("tr");

      const nounTd = el("td");
      nounTd.style.fontFamily = "var(--font-m)";
      nounTd.style.fontWeight = "600";
      nounTd.style.color = "var(--hi)";
      nounTd.textContent = noun;
      tr.appendChild(nounTd);

      const verbTd = el("td");
      verbTd.style.paddingTop = "8px";
      verbTd.style.paddingBottom = "8px";
      verbTd.style.lineHeight = "2";
      verbs.forEach(function (verb) {
        const chip = el("span", "lex", verb);
        chip.style.marginRight = "5px";
        verbTd.appendChild(chip);
      });
      tr.appendChild(verbTd);

      const cntTd = el("td");
      cntTd.style.fontFamily = "var(--font-m)";
      cntTd.style.color = "var(--muted)";
      cntTd.textContent = String(verbs.length);
      tr.appendChild(cntTd);

      tbody.appendChild(tr);
    });
    tbl.appendChild(tbody);
    matrixPanel.appendChild(tbl);
    cols.appendChild(matrixPanel);

    // Right: verbs panel + adjectives panel stacked
    const rightCol = el("div", "lex-right-col");

    const verbPanel = el("div", "panel");
    panelHead(verbPanel, "Verbs", String(lex.verbs.length));
    const verbCaps = el("div", "caps");
    verbCaps.style.marginTop = "10px";
    lex.verbs.slice().sort().forEach(function (verb) {
      const cap = el("div", "cap");
      cap.appendChild(el("span", "led on"));
      cap.appendChild(el("span", "nm", verb));
      verbCaps.appendChild(cap);
    });
    verbPanel.appendChild(verbCaps);
    rightCol.appendChild(verbPanel);

    const adjPanel = el("div", "panel");
    panelHead(adjPanel, "Adjectives", String(lex.adjectives.length));
    const adjCaps = el("div", "caps");
    adjCaps.style.marginTop = "10px";
    lex.adjectives.slice().sort().forEach(function (adj) {
      const cap = el("div", "cap");
      cap.appendChild(el("span", "led on"));
      cap.appendChild(el("span", "nm", adj));
      adjCaps.appendChild(cap);
    });
    adjPanel.appendChild(adjCaps);
    rightCol.appendChild(adjPanel);

    cols.appendChild(rightCol);
    container.appendChild(cols);
  }

  // =========================================================================
  // LATTICE — LatticeLib / FDC knowledge framework
  // =========================================================================

  async function renderLattice() {
    const container = $("#latticeContent");
    if (!container) return;
    clear(container);

    // Fetch static metadata (version, FDC status) and live address snapshot in
    // parallel. The address snapshot is only available when ARIA_MCP is running.
    let lex = null, snap = null;
    try { lex = await getJSON("/api/lexicon"); } catch (e) {
      container.appendChild(el("div", "empty", "lattice data unreachable — " + e.message));
      return;
    }
    try { snap = await getJSON("/api/lattice"); } catch (_) { snap = null; }

    const addrs = (snap && snap.addresses) ? snap.addresses : [];
    const pending = !snap || snap.pending;

    // Row 1: summary stat cards
    const cardRow = el("div", "cards");
    cardRow.appendChild(metricCard("LatticeLib", lex.latticeVersion || "—", null, null));
    cardRow.appendChild(metricCard("FDC", lex.fdcAvailable ? "active" : "inactive", null, lex.fdcAvailable ? "blue" : null));
    cardRow.appendChild(metricCard("Data bundle", lex.fdcDataVersion || "—", null, null));
    cardRow.appendChild(metricCard("Active addresses", pending ? "—" : String(addrs.length), null, addrs.length > 0 ? "blue" : null));
    container.appendChild(cardRow);

    // Row 2: Framework status (LED caps)
    const statusPanel = el("div", "panel");
    panelHead(statusPanel, "Knowledge Framework Status", null);
    const caps = el("div", "caps");
    caps.style.marginTop = "10px";
    [
      { label: "LatticeLib",                        desc: lex.latticeVersion || "—",                            on: true },
      { label: "FDC (Frame Decimal Classification)", desc: lex.fdcAvailable ? "available" : "unavailable",      on: !!lex.fdcAvailable },
      { label: "FDC data bundle",                    desc: lex.fdcDataVersion || "—",                           on: !!lex.fdcDataVersion },
      { label: "Lattice index (ARIA_MCP)",           desc: pending ? "requires ARIA_MCP" : addrs.length + " active addresses", on: !pending },
    ].forEach(function (r) {
      const cap = el("div", "cap");
      cap.appendChild(el("span", "led " + (r.on ? "on" : "off")));
      cap.appendChild(el("span", "nm", r.label));
      cap.appendChild(el("span", "ds", r.desc));
      caps.appendChild(cap);
    });
    statusPanel.appendChild(caps);
    container.appendChild(statusPanel);

    // Row 3: Active lattice addresses table
    const addrPanel = el("div", "panel");
    const addrHead = panelHead(addrPanel, "Active Lattice Addresses", pending ? "requires ARIA_MCP" : addrs.length + " addresses · sorted by item count");
    addrHead.appendChild(codesExplainerButton());
    if (pending) {
      const note = el("div", "empty");
      note.style.marginTop = "12px";
      note.textContent = "Lattice address data requires ARIA_MCP (127.0.0.1:4242). Start the estate daemon to populate.";
      addrPanel.appendChild(note);
    } else if (addrs.length === 0) {
      const note = el("div", "empty");
      note.style.marginTop = "12px";
      note.textContent = "No anchored drawers yet — lattice addresses appear as content is captured with classification codes.";
      addrPanel.appendChild(note);
    } else {
      const tbl = el("table", "dtable");
      tbl.style.marginTop = "12px";
      const thead = el("thead");
      const hrow = el("tr");
      ["Code", "Classification", "Items"].forEach(function (h) {
        const th = el("th"); th.textContent = h; hrow.appendChild(th);
      });
      thead.appendChild(hrow);
      tbl.appendChild(thead);

      const tbody = el("tbody");
      addrs.forEach(function (a) {
        const tr = el("tr");

        // Code column: monospace orange chip
        const tdCode = el("td");
        const codeSpan = el("span", "cfg-val");
        codeSpan.style.fontFamily = "var(--font-m)";
        codeSpan.style.fontSize = "12px";
        codeSpan.textContent = a.code;
        tdCode.appendChild(codeSpan);
        tr.appendChild(tdCode);

        // Label column: human-readable heading or em-dash when not in frame
        const tdLabel = el("td");
        tdLabel.style.color = a.label ? "var(--fg)" : "var(--hi)";
        tdLabel.textContent = a.label || "—";
        tr.appendChild(tdLabel);

        // Count column: right-aligned
        const tdCount = el("td");
        tdCount.style.textAlign = "right";
        tdCount.style.fontFamily = "var(--font-m)";
        tdCount.style.fontVariantNumeric = "tabular-nums";
        tdCount.textContent = String(a.count);
        tr.appendChild(tdCount);

        tbody.appendChild(tr);
      });
      tbl.appendChild(tbody);
      addrPanel.appendChild(tbl);
    }
    container.appendChild(addrPanel);
  }

  // =========================================================================
  // CONFIGURATION
  // =========================================================================

  async function renderConfiguration() {
    // Fetch both config and server payloads.
    let c = null, s = null, lex = null;
    try { c = await getJSON("/api/config"); } catch (_) { }
    try { s = lastServerData || await getJSON("/api/server"); } catch (_) { }
    try { lex = await getJSON("/api/lexicon"); } catch (_) { }

    // Monitoring panel.
    const cards = $("#configCards");
    if (cards) {
      clear(cards);
      if (c) {
        cards.appendChild(metricCard("Monitoring", c.monitoringEnabled ? "ON" : "OFF", null,
                                     c.monitoringEnabled ? "blue" : null));
        cards.appendChild(metricCard("Retention", c.retentionSeconds, "s"));
        const cut = el("div", "card");
        cut.appendChild(el("div", "clabel", "Last retention cutoff"));
        const v = el("div", "cval"); v.style.fontSize = "14px"; v.style.fontFamily = "var(--font-m)";
        v.textContent = c.retentionCutoff;
        cut.appendChild(v);
        cards.appendChild(cut);
      } else {
        cards.appendChild(el("div", "empty", "config unreachable"));
      }
    }

    // Transport & Protocol panel (two-column left).
    const tGrid = $("#configTransportGrid");
    if (tGrid) {
      clear(tGrid);
      function kvRow(key, val, live) {
        tGrid.appendChild(el("span", "cfg-key", key));
        const cell = el("span", "cfg-val");
        if (live != null) {
          cell.appendChild(el("span", "cfg-val-chip", String(live)));
        } else {
          cell.appendChild(el("span", "cfg-val-na", "n/a"));
        }
        tGrid.appendChild(cell);
      }
      kvRow("Transport", null, "loopback HTTP/1.1");
      kvRow("Protocol version", null, s && s.protoVersion != null ? s.protoVersion : null);
      kvRow("Active connections", null, s && s.connections != null ? s.connections : null);
      kvRow("Read strategy", null, null);   // requires ARIA_MCP config endpoint
      kvRow("Handshake timeout", null, null);
    }

    // Estate & Naming panel (two-column right).
    const eGrid = $("#configEstateGrid");
    if (eGrid) {
      clear(eGrid);
      function evRow(key, val) {
        eGrid.appendChild(el("span", "cfg-key", key));
        const cell = el("span", "cfg-val");
        cell.appendChild(el("span", val != null ? "cfg-val-chip" : "cfg-val-na", val != null ? String(val) : "n/a"));
        eGrid.appendChild(cell);
      }
      evRow("Tool namespacing", null);
      evRow("Auto-bootstrap", null);
      evRow("Monitoring layers", null);
      evRow("Depth-dial default", null);
      // LatticeLib / FDC metadata from /api/lexicon.
      if (lex) {
        evRow("LatticeLib version", lex.latticeVersion);
        evRow("FDC available", lex.fdcAvailable ? "yes" : "no");
        evRow("FDC data version", lex.fdcDataVersion);
      }
    }

    // ARIA Grammar collapsible section.
    const lexDiv = $("#configLexicon");
    if (lexDiv && lex) {
      clear(lexDiv);
      const addRow = function (key, val) {
        lexDiv.appendChild(el("span", "cfg-key", key));
        const cell = el("span", "cfg-val");
        cell.appendChild(el("span", "cfg-val-chip", String(val)));
        lexDiv.appendChild(cell);
      };
      addRow("Nouns", lex.nouns.join(", "));
      addRow("Verbs", lex.verbs.join(", "));
      addRow("Adjectives", lex.adjectives.join(", "));
      addRow("Noun count", lex.nouns.length);
      addRow("Verb count", lex.verbs.length);
    }

    // Capabilities grid.
    const capsGrid = $("#configCapsGrid");
    if (capsGrid) {
      clear(capsGrid);
      const caps = s && s.capabilities && s.capabilities.length ? s.capabilities : [];
      if (!caps.length) {
        capsGrid.appendChild(el("div", "empty", "no NeuronKit capabilities reported"));
      } else {
        caps.forEach(function (name) {
          const item = el("div", "cap-item");
          item.appendChild(el("span", "cap-led on"));
          item.appendChild(document.createTextNode(name));
          capsGrid.appendChild(item);
        });
      }
    }
  }

  // =========================================================================
  // TOPOLOGY (P5) — Canvas2D neural-brain renderer
  //
  // Neurons (drawers, diary entries, proposals, learned refs) are placed in
  // a two-hemisphere brain oval with Gaussian cluster scatter. Community
  // lobes are rendered as feathered radial-gradient blobs. SSE events fire
  // real pulse animations on matching noun-type nodes.
  //
  // When /api/graph returns structurePending the canvas stays empty and the
  // honest pending overlay explains why — the estate always holds real
  // records (7 seeded at provisioning), so the dashboard renders real
  // structure or an honest "pending" state, never invented data.
  //
  // Content-safety invariant: only metadata (counts, enums, ISO-8601
  // timestamps, identifiers, classification codes from the pinned public
  // frame) crosses the wire — never rung/memory content.
  //
  // VIZ_V2 layers on top of the base renderer:
  //   L2 — recency brightness (lastActiveTs), centrality halos (> 0.55),
  //        weight-scaled edge alpha.
  //   L3 — FDC community labels drawn at lobe centroids (proxy-enriched
  //        communities []{id, label, size}).
  //   L4 — optional strata view (#topoDimToggle): perspective projection with
  //        age-derived depth, painter sort, depth fog, slow camera sway.
  //   L5 — radar-loop playback (#topoPlayBtn): event-indexed playhead over
  //        /api/events with an alive(t) birth filter and playhead-keyed
  //        recency. Live view is the default; SSE stays connected throughout.
  // =========================================================================

  let topoFeedTimer = null;

  // Three.js WebGL renderer state — replaces Canvas2D brain renderer.
  let brainScene = null, brainCamera = null, brainGLRenderer = null;
  let brainControls = null;          // OrbitControls instance
  let brainPointsMesh = null;        // THREE.Points for all nodes
  let brainEdgesMesh = null;         // THREE.LineSegments for all edges
  let brainLabelEls = [];            // HTML overlay label elements
  let brainLabelContainer = null;    // div holding the HTML labels
  let brainNodes = [], brainEdges = [], brainNodeMap = Object.create(null);
  let brainAnimId = null, brainT = 0;
  let brainW = 0, brainH = 0;
  // Pixel-to-world coordinate transform: centers layout at origin and
  // scales so the longest axis spans [-1, 1].
  let brainWorldScale = 1, brainWorldCX = 0, brainWorldCY = 0;
  let brainResizeObs = null;
  let brainContainer = null;         // DOM container for the renderer
  // Selection state — set by selectBrainNode(); drives neighbor highlighting.
  let brainSelectedNode = null;
  let brainHop1 = Object.create(null);
  let brainHop2 = Object.create(null);
  let brainAdjacency = Object.create(null);
  // L4 strata (3D depth) — toggled by #topoDimToggle.
  let brain3D = false;
  // L3 lobe labels — community rank → FDC label string.
  let brainLobeLabels = Object.create(null);
  // V2-P2a meaning channel — community rank → confidence label text
  // ("Label · 82%" or "Mixed · top: …"), set alongside brainLobeLabels by
  // buildRealBrainNodes. Read by updateBrainLabels (canvas overlay) and
  // renderCommPicker (picker rows) in place of the bare label when present.
  let brainLobeConfidence = Object.create(null);
  let topoCommFilter = null;
  let topoCommRows = [];
  let brainLobeKey = Object.create(null);
  let topoRealData = null;
  let topoCommKeyById = Object.create(null);
  let topoCommPaletteByKey = Object.create(null);
  let brainCommPools = Object.create(null);
  let brainNowMs = 0;
  // Raycaster for click-to-select.
  let brainRaycaster = null;
  let brainPointer = new THREE.Vector2();
  // L5 radar-loop playback state. active = a playback session holds the playhead
  // (playing or paused mid-loop); playing = the step timer is running.
  let topoPlay = { active: false, playing: false, idx: 0, timer: null, playheadMs: 0 };
  let topoPlayEvents = [];  // /api/events parsed + sorted ascending by ts
  // Ripple ring buffer: up to 20 active ripples overlapping like singing in
  // a round — each at a different phase of its expand+fade lifecycle.
  let brainRipples = [];         // [{nodeId, age, x, y, z, rgb}]
  let brainRippleMesh = null;    // THREE.Points for ripple rings
  var RIPPLE_MAX = 20;           // max concurrent ripples
  var RIPPLE_DURATION = 2.0;     // seconds per ripple lifecycle
  // Constellation trail buffer: glowing lines between consecutive same-
  // community events, each fading independently over ~2s.
  let brainTrails = [];          // [{x1,y1,z1, x2,y2,z2, age, rgb}]
  let brainTrailMesh = null;     // THREE.LineSegments for trails
  var TRAIL_MAX = 20;
  var TRAIL_DURATION = 2.5;      // seconds per trail fade
  let brainLastPulseNode = null; // last pulsed node for trail linking

  // Twelve fallback community colors — used only when a community carries no
  // FDC code (fragments bucket, unlabeled lobes, code-less snapshots).
  const BRAIN_COMM_COLORS = [
    [255, 140,   0], [58, 180, 255], [180, 120, 255], [  0, 210, 140],
    [255,  80, 120], [255, 200,  60], [100, 200, 255], [255, 140,  80],
    [140, 200, 255], [200, 160, 255], [ 80, 220, 160], [255, 120, 160],
  ];

  // Deterministic community color from the FDC code's leading digits.
  // Encoding rule XYZ: hundreds digit X → hue family (10 hues around the
  // wheel), tens digit Y → shade (saturation), ones digit Z → brightness
  // (lightness). Sibling codes therefore share a hue family but stay
  // tellable apart, and the same code renders the same color on every
  // host and every refresh. Returns [r,g,b] or null for a non-numeric /
  // absent code (callers fall back to BRAIN_COMM_COLORS).
  // The lightness floor (35%) keeps every code visible on the dark canvas.
  function fdcColor(code) {
    var m = /^(\d)(\d)(\d)/.exec(String(code || ""));
    if (!m) return null;
    var hue = (+m[1]) * 36;          // X: 000s→0° … 900s→324°
    var sat = 85 - (+m[2]) * 5;      // Y: 85% … 40%
    var lit = 62 - (+m[3]) * 3;      // Z: 62% … 35%
    return hslToRgb(hue, sat, lit);
  }

  // HSL → [r,g,b] 0-255. h in degrees, s/l in percent.
  function hslToRgb(h, s, l) {
    s /= 100; l /= 100;
    var c = (1 - Math.abs(2 * l - 1)) * s;
    var hp = (((h % 360) + 360) % 360) / 60;
    var x = c * (1 - Math.abs((hp % 2) - 1));
    var r1 = 0, g1 = 0, b1 = 0;
    if      (hp < 1) { r1 = c; g1 = x; }
    else if (hp < 2) { r1 = x; g1 = c; }
    else if (hp < 3) { g1 = c; b1 = x; }
    else if (hp < 4) { g1 = x; b1 = c; }
    else if (hp < 5) { r1 = x; b1 = c; }
    else             { r1 = c; b1 = x; }
    var mm = l - c / 2;
    return [Math.round((r1 + mm) * 255), Math.round((g1 + mm) * 255), Math.round((b1 + mm) * 255)];
  }

  // Desaturate an [r,g,b] toward its OWN grayscale luma by `amount`
  // (0 = untouched, 1 = fully gray at the same luma). Used to scale a
  // lobe's aura/label color down as its dominant code's purity falls.
  // Deliberately NOT a hue blend with the lobe's other codes — mixing
  // complementary hues collapses to dead gray, which reads as "no code"
  // rather than "mixed codes". Fading the dominant hue toward its own
  // gray keeps it identifiable while honestly signalling low confidence.
  function desaturateToward(rgb, amount) {
    var a = Math.max(0, Math.min(1, amount));
    var lum = rgb[0] * 0.299 + rgb[1] * 0.587 + rgb[2] * 0.114;
    return [
      Math.round(rgb[0] + (lum - rgb[0]) * a),
      Math.round(rgb[1] + (lum - rgb[1]) * a),
      Math.round(rgb[2] + (lum - rgb[2]) * a),
    ];
  }

  // Per-lobe FDC code purity (V2-P2a meaning channel): tallies each
  // member's own `.code` (attached in renderTopology's compact-format
  // unpack via codeIndex/codes — see that call site) and reports the
  // dominant code's share among CODED members only. Members with no code
  // are excluded from the denominator so an uncoded fragment sitting in an
  // otherwise tightly-coded lobe doesn't dilute the stated confidence.
  // `top` is the top 3 codes by share, for the "Mixed · top: …" breakdown.
  // `dominant` is null when the lobe has zero coded members — callers fall
  // back to the community-level `code` (the pre-V2-P2a behavior), which
  // is also exactly what happens for payloads that lack codes/codeIndex.
  function lobeCodeStats(members) {
    var counts = Object.create(null);
    var totalCoded = 0;
    members.forEach(function (n) {
      if (!n.code) return;
      counts[n.code] = (counts[n.code] || 0) + 1;
      totalCoded++;
    });
    var codes = Object.keys(counts);
    if (!codes.length) return { dominant: null, purity: 0, totalCoded: 0, top: [] };
    codes.sort(function (a, b) { return counts[b] - counts[a]; });
    var top = codes.slice(0, 3).map(function (code) {
      return { code: code, share: counts[code] / totalCoded };
    });
    return { dominant: codes[0], purity: counts[codes[0]] / totalCoded, totalCoded: totalCoded, top: top };
  }

  // Confidence label text for a lobe's code purity. A clear majority
  // (purity >= 60%) states the label with its share ("Label · 82%");
  // anything more mixed lists the top 3 codes by share of coded members
  // instead of letting the dominant code speak for members it doesn't
  // represent ("Mixed · top: label1 25% · label2 16% · label3 7%").
  // `codeLabelMap` resolves a raw code to its community/frame label
  // (falls back to the raw code itself when no community carries a label
  // for it). `fallbackLabel` is the community's own label, returned
  // verbatim for the zero-coded-members case — there's no honest
  // percentage to state, so none is shown (matches current behavior).
  function confidenceLabelText(stats, codeLabelMap, fallbackLabel) {
    if (!stats || !stats.dominant) return fallbackLabel || null;
    function labelFor(code) { return codeLabelMap[code] || code; }
    if (stats.purity >= 0.60) {
      return labelFor(stats.dominant) + " · " + Math.round(stats.purity * 100) + "%";
    }
    var parts = stats.top.map(function (t) {
      return labelFor(t.code) + " " + Math.round(t.share * 100) + "%";
    });
    return "Mixed · top: " + parts.join(" · ");
  }

  // Per-lobe resolved color ([r,g,b] by lobe rank) — set by buildRealBrainNodes,
  // read by brainCommCSS so legend swatches, hulls, and nodes stay in sync.
  let brainLobeRGB = Object.create(null);
  // Community FDC code by content key (label) — set by buildRealBrainNodes,
  // read by the right-click query builder. Keyed by label, not Louvain id,
  // for the same reason as the picker: ids renumber every governor cycle.
  let brainCodeByKey = Object.create(null);

  // Node visual style by noun type — matches the substrate NounType enum:
  //   0=Drawer (gray matter), 1=Tunnel, 2=KGFact, 3=DiaryEntry (blue activation),
  //   4=Proposal (orange potential), 5=Association (faint), 6=LearnedRef (synapse),
  //   7=AmbientSample (near-invisible background noise)
  function nounStyle(t) {
    const S = [
      { r: 2.5, rgb: [232, 234, 240], a: 0.75 }, // 0 Drawer
      { r: 2.0, rgb: [200, 200, 200], a: 0.50 }, // 1 Tunnel
      { r: 1.8, rgb: [255, 180,  80], a: 0.60 }, // 2 KGFact
      { r: 2.0, rgb: [ 58, 180, 255], a: 0.90 }, // 3 DiaryEntry
      { r: 1.8, rgb: [255, 140,   0], a: 0.50 }, // 4 Proposal
      { r: 1.4, rgb: [232, 234, 240], a: 0.25 }, // 5 Association
      { r: 2.2, rgb: [ 58, 180, 255], a: 0.60 }, // 6 LearnedRef
      { r: 1.2, rgb: [232, 234, 240], a: 0.15 }, // 7 AmbientSample
    ];
    return S[t] || S[0];
  }

  // Gaussian scatter helper — box-muller approximation via triple uniform sum.
  function brainGauss() { return (Math.random() + Math.random() + Math.random() - 1.5) * 1.2; }

  // Place numComm community centers in a two-hemisphere oval.
  // Each hemisphere holds half the communities, arranged in lobe arcs.
  // Place community centers in an organic ring around the canvas center.
  // Random phase offset prevents community 0 (the largest lobe) from always landing
  // at angle=0 (right side), which would create a persistent rightward bias.
  function brainCenters(numComm, W, H) {
    var centers = [];
    var minDim = Math.min(W, H);
    var phase = Math.random() * Math.PI * 2;   // random start so no fixed heavy-side bias
    for (var c = 0; c < numComm; c++) {
      var angle = phase + (c / numComm) * Math.PI * 2 + (Math.random() - 0.5) * 0.4;
      var radius = (0.26 + Math.random() * 0.16) * minDim;
      centers.push({
        x: W / 2 + Math.cos(angle) * radius * (0.75 + Math.random() * 0.35),
        y: H / 2 + Math.sin(angle) * radius * (0.65 + Math.random() * 0.35),
      });
    }
    return centers;
  }

  // Map real /api/graph nodes into brain-hemisphere layout using community IDs.
  //
  // Lobe membership is derived from the nodes' own Louvain communityId values,
  // ranked by member count; the proxy's communities[] descriptor array
  // ({id, label, size}, size-desc) supplies the FDC label drawn over each
  // lobe (brainLobeLabels). The live tunnel graph is sparse — many 1–2 node
  // fragments — so only communities with ≥ MIN_LOBE_SIZE members earn a
  // distinct lobe center; the long tail scatters as a periphery field with
  // each fragment's members kept adjacent (binary-star pairs), reading
  // honestly as "structured cores over an unclustered fringe" rather than a
  // thousand fake lobes on a ring.
  // Stable palette lookup: a content key keeps its first-assigned hue across
  // filter toggles and snapshot refreshes.
  function paletteFor(key, fallbackIdx) {
    if (topoCommPaletteByKey[key] === undefined) topoCommPaletteByKey[key] = fallbackIdx;
    return topoCommPaletteByKey[key];
  }

  // `isSubset` = re-layout for a content-filter selection: picker rows and
  // the stable palette are NOT rebuilt from a subset (they describe the full
  // estate); everything else — lobes, centers, spreads — derives from the
  // subset so the selection fills the canvas.
  function buildRealBrainNodes(rawNodes, communities, W, H, isSubset) {
    var MAX_LOBES = 14;     // distinct lobe centers the canvas can hold legibly
    var MIN_LOBE_SIZE = 4;  // fragments below this scatter to the periphery

    var byId = Object.create(null);
    rawNodes.forEach(function (n) {
      var k = (n.communityId === undefined || n.communityId === null) ? 0 : n.communityId;
      (byId[k] = byId[k] || []).push(n);
    });
    var ranked = Object.keys(byId).sort(function (a, b) {
      return byId[b].length - byId[a].length;
    });

    var lobeIds = ranked.filter(function (cid, i) {
      return i < MAX_LOBES && byId[cid].length >= MIN_LOBE_SIZE;
    });
    var centers = brainCenters(Math.max(1, lobeIds.length), W, H);
    var nodes = [];

    function pushNode(n, x, y, cIdx, isLobe, commKey, rgb) {
      // Parse wire timestamps once at build. createdMs is the birth instant for
      // the L5 alive(t) filter; deadMs (tombstonedTs) hides the entity in live
      // view and ends its playback lifespan.
      // lastActiveTs was removed from the wire format (FIX 2 payload trim) so
      // lastMs is always null for topology nodes; the renderer falls through to
      // createdMs for recency brightness.
      // Date.parse(null/undefined) is NaN, and NaN || null collapses to null.
      var lastMs = Date.parse(n.lastActiveTs) || null;
      var createdMs = Date.parse(n.createdTs) || null;
      var deadMs = Date.parse(n.tombstonedTs) || null;
      var node = {
        id: n.id,
        x: Math.max(20, Math.min(W - 20, x)),
        y: Math.max(20, Math.min(H - 20, y)),
        // Anchor: the layout home position the physics springs pull toward.
        ax: 0, ay: 0, vx: 0, vy: 0,
        community: cIdx,
        // Periphery fragments share palette indexes with lobes; hulls are
        // drawn only over lobe members so scattered fragments never produce
        // a phantom canvas-wide hull (see drawCommHulls).
        lobe: !!isLobe,
        // Content key for the picker filter — the community's FDC label or
        // a bucket. Stable across snapshots, unlike Louvain ids.
        commKey: commKey || null,
        // V2-P2a meaning channel: this node's own FDC code (string) when
        // the wire carried codes/codeIndex, else null — a mixed lobe must
        // visibly show which members carry which code, not just the
        // lobe's dominant one. Absent-payload wire nodes have `n.code`
        // undefined, which collapses to null here (graceful degrade).
        code: n.code || null,
        // Node fill color, fallback chain: this node's OWN code (fdcColor)
        // → the caller's resolved community/lobe color (`rgb` — the lobe
        // path is purity-scaled by buildRealBrainNodes, see brainLobeRGB)
        // → the static per-community palette as the final code-less
        // fallback. A mixed lobe therefore shows each node's real color
        // even though the lobe aura/label reads as desaturated "mixed".
        rgb: fdcColor(n.code) || rgb || BRAIN_COMM_COLORS[cIdx % BRAIN_COMM_COLORS.length],
        // nounType removed from wire format (FIX 2 payload trim); all drawers
        // are type 0 — the rendering path is unchanged (defaults to 0).
        nounType: n.nounType || 0,
        centrality: n.centrality || 0,
        breathPhase: Math.random() * Math.PI * 2,
        pulseOrange: 0,   // capture pulse magnitude 0..1 — decays over ~1s
        pulseBlue: 0,     // think pulse magnitude 0..1 — same decay, visible ring
        glowBlue: 0,      // think ambient glow magnitude 0..1 — decays over ~10s
        anomaly: !!n.anomaly,
        lastMs: lastMs,
        createdMs: createdMs,
        deadMs: deadMs,
      };
      node.ax = node.x; node.ay = node.y;
      nodes.push(node);
    }

    // L3: record the FDC label + digit-derived color for each community that
    // earned a lobe. brainLobeLabels/brainLobeRGB/brainLobeConfidence keys
    // are the lobe rank (the node `community` index used on the lobe path);
    // labels are the proxy's enriched strings. Null/empty labels are
    // skipped — updateBrainLabels draws nothing for them.
    brainLobeLabels = Object.create(null);
    brainLobeRGB = Object.create(null);
    brainLobeConfidence = Object.create(null);
    brainCodeByKey = Object.create(null);
    function commMeta(cid) {
      var meta = (communities || []).find(function (c) { return String(c.id) === String(cid); });
      if (meta && meta.label && meta.code) brainCodeByKey[meta.label] = meta.code;
      return meta;
    }
    lobeIds.forEach(function (cid, rank) {
      var meta = commMeta(cid);
      if (meta && meta.label) brainLobeLabels[rank] = meta.label;
    });

    // Code → label reverse lookup for confidenceLabelText: multiple
    // communities can carry the same FDC code, so first one wins —
    // communities[] arrives size-desc from the proxy, a stable order.
    // Falls back to the raw code string when no community carries a
    // label for it (confidenceLabelText handles that fallback itself).
    var codeLabelMap = Object.create(null);
    (communities || []).forEach(function (c) {
      if (c && c.code && c.label && codeLabelMap[c.code] === undefined) codeLabelMap[c.code] = c.label;
    });

    // Content keys for the picker: the community's FDC label when present;
    // unlabeled lobes bucket under '(unlabeled)'; sub-lobe fragments bucket
    // under 'fragments'. Labels are the stable identity across snapshots
    // (Louvain ids renumber every governor cycle).
    function contentKey(cid, members) {
      var meta = commMeta(cid);
      if (meta && meta.label) return meta.label;
      return members.length >= MIN_LOBE_SIZE ? "(unlabeled)" : "fragments";
    }

    // Picker rows: one per labeled lobe (size desc), then the two buckets.
    brainLobeKey = Object.create(null);
    var rowByKey = Object.create(null);
    function addRow(key, size, cIdx, isBucket, rgb, confidence) {
      if (!rowByKey[key]) {
        rowByKey[key] = {
          key: key, size: 0, cIdx: cIdx, bucket: !!isBucket, rgb: rgb || null,
          // V2-P2a confidence label ("Label · 82%" / "Mixed · top: …");
          // only lobes compute this (see lobeCodeStats) — periphery/bucket
          // rows pass undefined and fall back to the bare key in the picker.
          confidence: confidence || null,
        };
      }
      rowByKey[key].size += size;
    }

    // Lobe communities: members gathered around a shared center. Color is
    // digit-derived from the community's FDC code; the static palette (keyed
    // by stable content key) covers code-less communities.
    lobeIds.forEach(function (cid, rank) {
      var members = byId[cid];
      var key = contentKey(cid, members);
      brainLobeKey[rank] = key;
      var cIdx = paletteFor(key, rank % BRAIN_COMM_COLORS.length);
      var meta = commMeta(cid);
      // V2-P2a meaning channel: the lobe aura/label color is the DOMINANT
      // per-node code's color, desaturated toward gray as purity falls —
      // not a hue blend of every code present (see desaturateToward). A
      // lobe with zero coded members (stats.dominant === null) keeps the
      // pre-V2-P2a behavior: the community's own `code`, or the palette.
      var stats = lobeCodeStats(members);
      var baseRgb = fdcColor(meta && meta.code) || BRAIN_COMM_COLORS[cIdx % BRAIN_COMM_COLORS.length];
      var rgb = stats.dominant ? desaturateToward(fdcColor(stats.dominant), 1 - stats.purity) : baseRgb;
      brainLobeRGB[rank] = rgb;
      brainLobeConfidence[rank] = confidenceLabelText(stats, codeLabelMap, meta && meta.label);
      if (!isSubset) addRow(key, members.length, cIdx, key === "(unlabeled)", rgb, brainLobeConfidence[rank]);
      // sqrt scaling keeps scatter proportional to canvas even for huge
      // communities (6k+ nodes); linear scaling scatters far outside the
      // canvas, clamping all nodes to edges and collapsing via physics.
      var spread = Math.min(Math.max(28, Math.sqrt(members.length) * 3.5),
                            Math.min(W, H) * 0.16);
      var center = centers[rank];
      members.forEach(function (n) {
        var angle = Math.random() * Math.PI * 2;
        var dist = Math.abs(brainGauss()) * spread;
        pushNode(n, center.x + Math.cos(angle) * dist,
                    center.y + Math.sin(angle) * dist, rank, true, key, rgb);
      });
    });

    // Periphery fragments: each fragment gets one random anchor across the
    // canvas with its members placed tightly around it, so a tunnel-linked
    // pair stays a visible pair. Fragments with an FDC code get its
    // digit-derived color; the rest cycle the fallback palette.
    var lobeSet = Object.create(null);
    lobeIds.forEach(function (cid) { lobeSet[cid] = true; });
    ranked.forEach(function (cid, rank) {
      if (lobeSet[cid]) return;
      var members = byId[cid];
      var key = contentKey(cid, members);
      var meta = commMeta(cid);
      var cIdx = paletteFor(key, rank % BRAIN_COMM_COLORS.length);
      var rgb = fdcColor(meta && meta.code) || BRAIN_COMM_COLORS[cIdx % BRAIN_COMM_COLORS.length];
      if (!isSubset) addRow(key, members.length, -1, true, rgb);
      var ax = 20 + Math.random() * (W - 40);
      var ay = 20 + Math.random() * (H - 40);
      members.forEach(function (n, mi) {
        var angle = (mi / members.length) * Math.PI * 2 + Math.random() * 0.8;
        var dist = members.length > 1 ? 6 + Math.random() * 8 : 0;
        pushNode(n, ax + Math.cos(angle) * dist, ay + Math.sin(angle) * dist, cIdx, false, key, rgb);
      });
    });

    // Labeled rows by size descending; buckets always trail. A subset
    // re-layout keeps the FULL estate's rows (the picker must keep showing
    // everything available to re-check).
    if (!isSubset) {
      topoCommRows = Object.values(rowByKey).sort(function (a, b) {
        if (a.bucket !== b.bucket) return a.bucket ? 1 : -1;
        return b.size - a.size;
      });
    }
    return nodes;
  }

  // L2 community-aware force micro-sim. Anchor springs hold the lobe /
  // periphery layout; edge springs pull tunnel-linked nodes toward a short
  // rest length so connected memory visibly drifts together and settles;
  // damping keeps the motion organic rather than oscillating. O(N + E) per
  // frame — no pairwise repulsion (the anchor scatter already provides
  // separation at this density).
  //
  // For large graphs (>2k nodes) edge springs are scaled down so anchors
  // dominate — without this, inter-community edges collapse all communities
  // into a single blob since K_EDGE > K_ANCHOR and there is no repulsion.
  function brainPhysicsStep(dt) {
    var K_ANCHOR = 2.4;   // spring toward layout anchor (s^-2)
    var K_EDGE = 2.2;     // spring along edges (s^-2), scaled by weight
    var REST = 26;        // edge rest length, px
    var DAMP = 0.90;      // per-frame velocity retention at 60fps
    // Scale edge springs inversely with node count so large graphs keep
    // their community structure instead of collapsing into a hairball.
    var edgeScale = Math.min(1, 800 / Math.max(1, brainNodes.length));
    var kEdge = K_EDGE * edgeScale;
    var i, e, s, t;
    for (i = 0; i < brainEdges.length; i++) {
      e = brainEdges[i];
      s = brainNodeMap[e.src]; t = brainNodeMap[e.tgt];
      if (!s || !t) continue;
      var dx = t.x - s.x, dy = t.y - s.y;
      var d = Math.sqrt(dx * dx + dy * dy) || 0.01;
      var f = kEdge * (d - REST) / d * (e.w || 0.5) * dt;
      s.vx += dx * f; s.vy += dy * f;
      t.vx -= dx * f; t.vy -= dy * f;
    }
    var damp = Math.pow(DAMP, dt * 60);
    for (i = 0; i < brainNodes.length; i++) {
      var n = brainNodes[i];
      n.vx += (n.ax - n.x) * K_ANCHOR * dt;
      n.vy += (n.ay - n.y) * K_ANCHOR * dt;
      n.vx *= damp; n.vy *= damp;
      n.x += n.vx * dt * 60;
      n.y += n.vy * dt * 60;
    }
  }

  // Point shader: each node is a screen-space circle with per-point size,
  // color, and alpha. The fragment shader draws a soft-edged disc and applies
  // per-point alpha for breathing, recency, selection dimming, and depth fog.
  // Point vertex shader: size is in world-space units; the projection
  // converts to screen pixels via the viewport height (resolution.y)
  // so points remain a consistent angular size as you orbit.
  var POINT_VS = [
    'uniform float uPixelRatio;',
    'uniform float uViewportH;',
    'attribute float size;',
    'attribute float alpha;',
    'varying vec3 vColor;',
    'varying float vAlpha;',
    'void main() {',
    '  vColor = color;',
    '  vAlpha = alpha;',
    '  vec4 mv = modelViewMatrix * vec4(position, 1.0);',
    '  gl_PointSize = size * uViewportH * uPixelRatio / -mv.z;',
    '  gl_Position = projectionMatrix * mv;',
    '}',
  ].join('\n');
  var POINT_FS = [
    'varying vec3 vColor;',
    'varying float vAlpha;',
    'void main() {',
    '  float d = length(gl_PointCoord - vec2(0.5));',
    '  if (d > 0.5) discard;',
    '  float edge = 1.0 - smoothstep(0.38, 0.5, d);',
    '  gl_FragColor = vec4(vColor, vAlpha * edge);',
    '}',
  ].join('\n');

  // Ripple ring shader: hollow expanding circle that fades as it grows.
  // The `alpha` attribute carries (1 - age/duration) so the ring fades
  // out over its lifecycle. The `size` attribute grows with age.
  var RIPPLE_FS = [
    'varying vec3 vColor;',
    'varying float vAlpha;',
    'void main() {',
    '  float d = length(gl_PointCoord - vec2(0.5));',
    '  if (d > 0.5) discard;',
    // Hollow ring: only the outer band is visible.
    '  float ring = smoothstep(0.32, 0.40, d) * (1.0 - smoothstep(0.44, 0.50, d));',
    '  if (ring < 0.01) discard;',
    '  gl_FragColor = vec4(vColor, vAlpha * ring);',
    '}',
  ].join('\n');

  function startBrainAnimation(container, W, H) {
    stopBrainAnimation();
    brainW = W;
    brainH = H;
    brainContainer = container;

    // Scene — dark background.
    brainScene = new THREE.Scene();

    // Normalized world-space: the layout runs in pixel coordinates (0..W,
    // 0..H) for physics, but the GPU geometry is centered at origin and
    // scaled so the longest canvas axis maps to [-1, 1]. This keeps orbit,
    // perspective, and point sizing well-behaved regardless of canvas size.
    brainWorldScale = 2 / Math.max(W, H);  // px → world multiplier
    brainWorldCX = W / 2;                   // pixel center X
    brainWorldCY = H / 2;                   // pixel center Y

    // Camera — looking down the -Z axis at origin; distance 2.4 shows
    // the full [-1,1] scene with some margin in a 50° FOV.
    var aspect = W / H;
    brainCamera = new THREE.PerspectiveCamera(50, aspect, 0.01, 100);
    // Camera further back to encompass the deeper z-range (-1.4).
    brainCamera.position.set(0, 0, 3.2);
    brainCamera.lookAt(0, 0, -0.4);

    // WebGL renderer
    brainGLRenderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    brainGLRenderer.setSize(W, H);
    brainGLRenderer.setPixelRatio(window.devicePixelRatio);
    brainGLRenderer.setClearColor(0x06070e, 1);
    var glCanvas = brainGLRenderer.domElement;
    glCanvas.style.position = 'absolute';
    glCanvas.style.top = '0';
    glCanvas.style.left = '0';
    container.appendChild(glCanvas);

    // OrbitControls — scroll-wheel zoom, drag to orbit, right-drag to pan.
    brainControls = new OrbitControls(brainCamera, glCanvas);
    // Orbit target at the midpoint of the z-range so rotation reveals depth.
    brainControls.target.set(0, 0, -0.4);
    brainControls.enableDamping = true;
    brainControls.dampingFactor = 0.12;
    brainControls.minDistance = 0.5;
    brainControls.maxDistance = 8;
    brainControls.zoomSpeed = 1.2;
    brainControls.update();

    // Pre-build node lookup + community pools.
    brainNodeMap = Object.create(null);
    brainCommPools = Object.create(null);
    brainNodes.forEach(function (n) {
      brainNodeMap[n.id] = n;
      (brainCommPools[n.community] = brainCommPools[n.community] || []).push(n);
    });

    // Pre-build undirected adjacency map for hop-1/hop-2 lookups.
    brainAdjacency = Object.create(null);
    brainEdges.forEach(function (e) {
      (brainAdjacency[e.src] = brainAdjacency[e.src] || []).push(e.tgt);
      (brainAdjacency[e.tgt] = brainAdjacency[e.tgt] || []).push(e.src);
    });

    brainRaycaster = new THREE.Raycaster();
    // Threshold in world-space units — ~8px at default zoom.
    brainRaycaster.params.Points.threshold = 8 * brainWorldScale;

    // Build Three.js geometry for nodes and edges.
    buildBrainPoints();
    buildBrainLines();
    buildRippleMesh();
    buildTrailMesh();
    brainRipples = [];
    brainTrails = [];
    brainLastPulseNode = null;

    // HTML overlay for community labels.
    brainLabelContainer = document.createElement('div');
    brainLabelContainer.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;overflow:hidden;';
    container.appendChild(brainLabelContainer);

    // Click: raycaster hit → select node.
    glCanvas.addEventListener('click', function (e) {
      var rect = glCanvas.getBoundingClientRect();
      brainPointer.x = ((e.clientX - rect.left) / rect.width) * 2 - 1;
      brainPointer.y = -((e.clientY - rect.top) / rect.height) * 2 + 1;
      brainRaycaster.setFromCamera(brainPointer, brainCamera);
      var hits = brainPointsMesh ? brainRaycaster.intersectObject(brainPointsMesh) : [];
      if (hits.length > 0) {
        var idx = hits[0].index;
        var node = brainNodes[idx];
        if (node && !brainHidden(node)) {
          if (node === brainSelectedNode) {
            selectBrainNode(null);
          } else {
            selectBrainNode(node);
          }
        }
      } else {
        selectBrainNode(null);
      }
    });

    // Right-click: raycaster hit → copy a paste-ready AI query about the node.
    // The dashboard holds only metadata (drawer id, domain label, FDC code,
    // neighbor ids) — the query is executed by the user's own AI session,
    // which has the MOOTx01 tools and authorization to read content. Nothing
    // crosses this surface that isn't already on the wire. A miss falls
    // through to the browser's own context menu.
    glCanvas.addEventListener('contextmenu', function (e) {
      var rect = glCanvas.getBoundingClientRect();
      brainPointer.x = ((e.clientX - rect.left) / rect.width) * 2 - 1;
      brainPointer.y = -((e.clientY - rect.top) / rect.height) * 2 + 1;
      brainRaycaster.setFromCamera(brainPointer, brainCamera);
      var hits = brainPointsMesh ? brainRaycaster.intersectObject(brainPointsMesh) : [];
      if (!hits.length) return;
      var node = brainNodes[hits[0].index];
      if (!node || brainHidden(node)) return;
      e.preventDefault();
      selectBrainNode(node);   // highlight what the query refers to
      var query = buildNodeQuery(node);
      copyText(query, function (ok) {
        if (ok) {
          topoToast("Query copied — paste it into your AI to explore this memory");
        } else {
          // Safari: contextmenu events carry no user activation, so BOTH
          // clipboard paths are refused. Show the query pre-selected with a
          // Copy button — that click is an activation and always works.
          showQueryFallback(query);
        }
      });
    });

    // Escape clears selection.
    document.addEventListener('keydown', function brainKey(e) {
      if (e.key === 'Escape' && brainSelectedNode) selectBrainNode(null);
    });

    // ResizeObserver: scale node positions + renderer when container resizes.
    if (typeof ResizeObserver !== 'undefined') {
      brainResizeObs = new ResizeObserver(function (entries) {
        if (!brainGLRenderer) return;
        var entry = entries[0];
        var newW = entry.contentRect.width;
        var newH = entry.contentRect.height;
        if (newW < 10 || newH < 10) return;
        var sx = newW / brainW, sy = newH / brainH;
        brainNodes.forEach(function (n) {
          n.x *= sx; n.y *= sy;
          n.ax *= sx; n.ay *= sy;
        });
        brainW = newW; brainH = newH;
        brainWorldScale = 2 / Math.max(newW, newH);
        brainWorldCX = newW / 2;
        brainWorldCY = newH / 2;
        brainCamera.aspect = newW / newH;
        brainCamera.updateProjectionMatrix();
        brainGLRenderer.setSize(newW, newH);
        // Update shader uniform for point sizing.
        if (brainPointsMesh) {
          brainPointsMesh.material.uniforms.uViewportH.value = newH;
        }
      });
      brainResizeObs.observe(container);
    }

    brainT = 0;
    var prev = 0;
    function frame(ts) {
      var dt = prev ? Math.min(0.05, (ts - prev) / 1000) : 0.016;
      prev = ts;
      brainT += dt;
      tickBrainDecay(dt);
      brainPhysicsStep(dt);
      brainControls.update();
      updateBrainFrame();
      updateRipplesAndTrails(dt);
      brainGLRenderer.render(brainScene, brainCamera);
      brainAnimId = requestAnimationFrame(frame);
    }
    brainAnimId = requestAnimationFrame(frame);
  }

  // Build THREE.Points mesh from brainNodes.
  function buildBrainPoints() {
    if (brainPointsMesh) { brainScene.remove(brainPointsMesh); brainPointsMesh.geometry.dispose(); }
    var N = brainNodes.length;
    var positions = new Float32Array(N * 3);
    var colors = new Float32Array(N * 3);
    var sizes = new Float32Array(N);
    var alphas = new Float32Array(N);
    // Z depth: in 3D mode, z3 ∈ [0,1] maps to [0, -0.6] in world-space
    // (keystones at z=0, periphery sinks ~60% of the visible range).
    // Z depth: 1.4 world units gives the z-axis real visual weight when
    // orbiting — keystones at z=0, periphery sinks to z=-1.4.
    var zDepth = brain3D ? 1.4 : 0;
    var ws = brainWorldScale, cx = brainWorldCX, cy = brainWorldCY;
    for (var i = 0; i < N; i++) {
      var n = brainNodes[i];
      // Pixel → world: center at origin, scale to [-1,1], flip Y.
      positions[i * 3]     = (n.x - cx) * ws;
      positions[i * 3 + 1] = (cy - n.y) * ws;   // Y-flip
      positions[i * 3 + 2] = -(n.z3 || 0) * zDepth;
      var style = nounStyle(n.nounType);
      var rgb = n.rgb || style.rgb;
      // Desaturate colors: mix 40% toward gray so the palette reads as
      // tinted rather than neon. The gray target is the luminance of the
      // original color, preserving relative brightness.
      var lum = (rgb[0] * 0.299 + rgb[1] * 0.587 + rgb[2] * 0.114) / 255;
      var sat = 0.6;  // 0 = full gray, 1 = full color
      colors[i * 3]     = lum + (rgb[0] / 255 - lum) * sat;
      colors[i * 3 + 1] = lum + (rgb[1] / 255 - lum) * sat;
      colors[i * 3 + 2] = lum + (rgb[2] / 255 - lum) * sat;
      // Smaller dots: ~3px base at default zoom.
      sizes[i] = (style.r * (1 + n.centrality * 1.2)) * 0.005;
      alphas[i] = style.a;
    }
    var geom = new THREE.BufferGeometry();
    geom.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geom.setAttribute('color', new THREE.BufferAttribute(colors, 3));
    geom.setAttribute('size', new THREE.BufferAttribute(sizes, 1));
    geom.setAttribute('alpha', new THREE.BufferAttribute(alphas, 1));
    var mat = new THREE.ShaderMaterial({
      uniforms: {
        uPixelRatio: { value: window.devicePixelRatio || 1 },
        uViewportH:  { value: brainH },
      },
      vertexShader: POINT_VS,
      fragmentShader: POINT_FS,
      vertexColors: true,
      transparent: true,
      depthWrite: false,
    });
    brainPointsMesh = new THREE.Points(geom, mat);
    brainScene.add(brainPointsMesh);
  }

  // Build THREE.LineSegments mesh from brainEdges.
  function buildBrainLines() {
    if (brainEdgesMesh) { brainScene.remove(brainEdgesMesh); brainEdgesMesh.geometry.dispose(); }
    var E = brainEdges.length;
    var positions = new Float32Array(E * 6);
    var colors = new Float32Array(E * 6);
    var zDepth = brain3D ? 1.4 : 0;
    var ws = brainWorldScale, cx = brainWorldCX, cy = brainWorldCY;
    for (var i = 0; i < E; i++) {
      var e = brainEdges[i];
      var s = brainNodeMap[e.src], t = brainNodeMap[e.tgt];
      if (!s || !t) continue;
      positions[i * 6]     = (s.x - cx) * ws;
      positions[i * 6 + 1] = (cy - s.y) * ws;
      positions[i * 6 + 2] = -(s.z3 || 0) * zDepth;
      positions[i * 6 + 3] = (t.x - cx) * ws;
      positions[i * 6 + 4] = (cy - t.y) * ws;
      positions[i * 6 + 5] = -(t.z3 || 0) * zDepth;
      var col = e.type === 'tunnel' ? [0.86, 0.88, 0.94]
              : e.type === 'lattice' ? [1.0, 0.71, 0.24]
              : [0.23, 0.71, 1.0];
      // Dim edges by the degree of their highest-degree endpoint so hub
      // nodes don't accumulate hundreds of near-white edges into a comet.
      var sDeg = (brainAdjacency[e.src] || []).length;
      var tDeg = (brainAdjacency[e.tgt] || []).length;
      var maxDeg = Math.max(sDeg, tDeg, 1);
      var degDim = Math.min(1, 8 / Math.sqrt(maxDeg));
      colors[i * 6]     = col[0] * degDim; colors[i * 6 + 1] = col[1] * degDim; colors[i * 6 + 2] = col[2] * degDim;
      colors[i * 6 + 3] = col[0] * degDim; colors[i * 6 + 4] = col[1] * degDim; colors[i * 6 + 5] = col[2] * degDim;
    }
    var geom = new THREE.BufferGeometry();
    geom.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geom.setAttribute('color', new THREE.BufferAttribute(colors, 3));
    // Base opacity scales inversely with edge count. The per-vertex color
    // channel carries per-edge dimming (hub-degree scaling, selection state)
    // so this base just sets the floor.
    var edgeOpacity = Math.min(0.15, 30 / Math.max(1, E));
    var mat = new THREE.LineBasicMaterial({ vertexColors: true, transparent: true, opacity: edgeOpacity, depthWrite: false });
    brainEdgesMesh = new THREE.LineSegments(geom, mat);
    brainScene.add(brainEdgesMesh);
  }

  // Build the ripple ring mesh — fixed-size buffer for RIPPLE_MAX concurrent
  // ripple rings. Each ripple is a single point rendered as a hollow expanding
  // disc via the RIPPLE_FS shader.
  function buildRippleMesh() {
    if (brainRippleMesh) { brainScene.remove(brainRippleMesh); brainRippleMesh.geometry.dispose(); }
    var N = RIPPLE_MAX;
    var pos = new Float32Array(N * 3);
    var col = new Float32Array(N * 3);
    var siz = new Float32Array(N);
    var alp = new Float32Array(N);
    var geom = new THREE.BufferGeometry();
    geom.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    geom.setAttribute('color', new THREE.BufferAttribute(col, 3));
    geom.setAttribute('size', new THREE.BufferAttribute(siz, 1));
    geom.setAttribute('alpha', new THREE.BufferAttribute(alp, 1));
    var mat = new THREE.ShaderMaterial({
      uniforms: {
        uPixelRatio: { value: window.devicePixelRatio || 1 },
        uViewportH:  { value: brainH },
      },
      vertexShader: POINT_VS,
      fragmentShader: RIPPLE_FS,
      vertexColors: true,
      transparent: true,
      depthWrite: false,
    });
    brainRippleMesh = new THREE.Points(geom, mat);
    brainScene.add(brainRippleMesh);
  }

  // Build the constellation trail mesh — TRAIL_MAX line segments that glow
  // between consecutive same-community events then fade.
  function buildTrailMesh() {
    if (brainTrailMesh) { brainScene.remove(brainTrailMesh); brainTrailMesh.geometry.dispose(); }
    var N = TRAIL_MAX;
    var pos = new Float32Array(N * 6);
    var col = new Float32Array(N * 6);
    var geom = new THREE.BufferGeometry();
    geom.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    geom.setAttribute('color', new THREE.BufferAttribute(col, 3));
    var mat = new THREE.LineBasicMaterial({
      vertexColors: true, transparent: true, opacity: 0.7, depthWrite: false,
    });
    brainTrailMesh = new THREE.LineSegments(geom, mat);
    brainScene.add(brainTrailMesh);
  }

  // Per-frame ripple + trail animation update. Called from updateBrainFrame.
  function updateRipplesAndTrails(dt) {
    var ws = brainWorldScale, cx = brainWorldCX, cy = brainWorldCY;
    var zDepth = brain3D ? 1.4 : 0;

    // --- Ripples ---
    if (brainRippleMesh) {
      var rPos = brainRippleMesh.geometry.attributes.position.array;
      var rCol = brainRippleMesh.geometry.attributes.color.array;
      var rSiz = brainRippleMesh.geometry.attributes.size.array;
      var rAlp = brainRippleMesh.geometry.attributes.alpha.array;
      // Age all active ripples; remove expired ones.
      for (var i = brainRipples.length - 1; i >= 0; i--) {
        brainRipples[i].age += dt;
        if (brainRipples[i].age >= RIPPLE_DURATION) brainRipples.splice(i, 1);
      }
      for (var i = 0; i < RIPPLE_MAX; i++) {
        var r = brainRipples[i];
        if (!r) {
          rSiz[i] = 0; rAlp[i] = 0;
          continue;
        }
        var t = r.age / RIPPLE_DURATION;  // 0→1 over lifecycle
        // Position tracks the node (which drifts under physics).
        var node = brainNodeMap[r.nodeId];
        if (node) {
          rPos[i * 3]     = (node.x - cx) * ws;
          rPos[i * 3 + 1] = (cy - node.y) * ws;
          rPos[i * 3 + 2] = -(node.z3 || 0) * zDepth;
        }
        // Ring expands from 0.02 to 0.12 world units; alpha fades out.
        rSiz[i] = 0.02 + t * 0.10;
        rAlp[i] = (1 - t) * 0.8;
        rCol[i * 3]     = r.rgb[0]; rCol[i * 3 + 1] = r.rgb[1]; rCol[i * 3 + 2] = r.rgb[2];
      }
      brainRippleMesh.geometry.attributes.position.needsUpdate = true;
      brainRippleMesh.geometry.attributes.color.needsUpdate = true;
      brainRippleMesh.geometry.attributes.size.needsUpdate = true;
      brainRippleMesh.geometry.attributes.alpha.needsUpdate = true;
    }

    // --- Trails ---
    if (brainTrailMesh) {
      var tPos = brainTrailMesh.geometry.attributes.position.array;
      var tCol = brainTrailMesh.geometry.attributes.color.array;
      for (var i = brainTrails.length - 1; i >= 0; i--) {
        brainTrails[i].age += dt;
        if (brainTrails[i].age >= TRAIL_DURATION) brainTrails.splice(i, 1);
      }
      for (var i = 0; i < TRAIL_MAX; i++) {
        var tr = brainTrails[i];
        if (!tr) {
          // Zero-length invisible line.
          tPos[i * 6] = -99; tPos[i * 6 + 1] = -99; tPos[i * 6 + 2] = -99;
          tPos[i * 6 + 3] = -99; tPos[i * 6 + 4] = -99; tPos[i * 6 + 5] = -99;
          tCol[i * 6] = 0; tCol[i * 6 + 1] = 0; tCol[i * 6 + 2] = 0;
          tCol[i * 6 + 3] = 0; tCol[i * 6 + 4] = 0; tCol[i * 6 + 5] = 0;
          continue;
        }
        var t = tr.age / TRAIL_DURATION;
        var fade = (1 - t) * (1 - t);  // quadratic fade for a gentle tail
        // Track node positions so trails follow physics drift.
        var n1 = brainNodeMap[tr.fromId], n2 = brainNodeMap[tr.toId];
        if (n1) {
          tPos[i * 6]     = (n1.x - cx) * ws;
          tPos[i * 6 + 1] = (cy - n1.y) * ws;
          tPos[i * 6 + 2] = -(n1.z3 || 0) * zDepth;
        }
        if (n2) {
          tPos[i * 6 + 3] = (n2.x - cx) * ws;
          tPos[i * 6 + 4] = (cy - n2.y) * ws;
          tPos[i * 6 + 5] = -(n2.z3 || 0) * zDepth;
        }
        tCol[i * 6]     = tr.rgb[0] * fade; tCol[i * 6 + 1] = tr.rgb[1] * fade; tCol[i * 6 + 2] = tr.rgb[2] * fade;
        tCol[i * 6 + 3] = tr.rgb[0] * fade; tCol[i * 6 + 4] = tr.rgb[1] * fade; tCol[i * 6 + 5] = tr.rgb[2] * fade;
      }
      brainTrailMesh.geometry.attributes.position.needsUpdate = true;
      brainTrailMesh.geometry.attributes.color.needsUpdate = true;
    }
  }

  // Per-frame update: sync node positions, colors, and alphas into the GPU
  // buffers, update edge positions, and reposition HTML labels.
  function updateBrainFrame() {
    brainNowMs = topoPlay.active ? topoPlay.playheadMs : Date.now();
    if (!brainPointsMesh) return;
    var geom = brainPointsMesh.geometry;
    var pos = geom.attributes.position.array;
    var col = geom.attributes.color.array;
    var siz = geom.attributes.size.array;
    var alp = geom.attributes.alpha.array;
    var hasSel = !!brainSelectedNode;
    var N = brainNodes.length;
    var zDepth = brain3D ? 1.4 : 0;
    var ws = brainWorldScale, cx = brainWorldCX, cy = brainWorldCY;
    for (var i = 0; i < N; i++) {
      var n = brainNodes[i];
      pos[i * 3]     = (n.x - cx) * ws;
      pos[i * 3 + 1] = (cy - n.y) * ws;
      pos[i * 3 + 2] = -(n.z3 || 0) * zDepth;
      var style = nounStyle(n.nounType);
      var rgb = n.rgb || style.rgb;
      var breath = 0.82 + 0.18 * Math.sin(brainT * 0.72 + n.breathPhase);
      var alpha = style.a * breath;
      var mod = 1;
      if (hasSel) {
        // Gentler dimming: unselected nodes stay at 30% (not 12%).
        if (n === brainSelectedNode || brainHop1[n.id]) { /* full */ }
        else if (brainHop2[n.id]) mod *= 0.6;
        else mod *= 0.3;
      }
      mod *= recencyFactor(n, brainNowMs);
      if (brain3D) mod *= 1 - 0.35 * (n.z3 || 0);
      alpha *= mod;
      if (brainDead(n)) alpha = 0;
      // Desaturate: mix toward luminance gray, same ratio as buildBrainPoints.
      var lum = (rgb[0] * 0.299 + rgb[1] * 0.587 + rgb[2] * 0.114) / 255;
      var sat = 0.6;
      var pr = lum + (rgb[0] / 255 - lum) * sat;
      var pg = lum + (rgb[1] / 255 - lum) * sat;
      var pb = lum + (rgb[2] / 255 - lum) * sat;
      if (n.pulseOrange > 0.01) {
        var t2 = n.pulseOrange;
        pr = pr + (1 - pr) * t2 * 0.6;
        pg = pg + (0.55 - pg) * t2 * 0.6;
        pb = pb * (1 - t2 * 0.4);
        siz[i] = (style.r * (1 + n.centrality * 1.2) + n.pulseOrange * 6) * 0.005;
      } else if (n.pulseBlue > 0.01) {
        pr = pr + (0.23 - pr) * n.pulseBlue * 0.5;
        pg = pg + (0.71 - pg) * n.pulseBlue * 0.5;
        pb = pb + (1.0 - pb) * n.pulseBlue * 0.5;
        siz[i] = (style.r * (1 + n.centrality * 1.2) + n.pulseBlue * 6) * 0.005;
      } else {
        siz[i] = (style.r * (1 + n.centrality * 1.2)) * 0.005;
      }
      col[i * 3] = pr; col[i * 3 + 1] = pg; col[i * 3 + 2] = pb;
      alp[i] = alpha;
    }
    geom.attributes.position.needsUpdate = true;
    geom.attributes.color.needsUpdate = true;
    geom.attributes.size.needsUpdate = true;
    geom.attributes.alpha.needsUpdate = true;

    // Update edge positions from current node positions.
    if (brainEdgesMesh) {
      var epos = brainEdgesMesh.geometry.attributes.position.array;
      var ecol = brainEdgesMesh.geometry.attributes.color.array;
      var E = brainEdges.length;
      var eZDepth = brain3D ? 1.4 : 0;
      var eWs = brainWorldScale, eCx = brainWorldCX, eCy = brainWorldCY;
      // Off-screen collapse point for hidden edges.
      var hideX = -99, hideY = -99, hideZ = -99;
      for (var j = 0; j < E; j++) {
        var e = brainEdges[j];
        var s = brainNodeMap[e.src], t2e = brainNodeMap[e.tgt];
        if (!s || !t2e) {
          // Missing node lookup: collapse to off-screen degenerate line.
          epos[j * 6] = hideX; epos[j * 6 + 1] = hideY; epos[j * 6 + 2] = hideZ;
          epos[j * 6 + 3] = hideX; epos[j * 6 + 4] = hideY; epos[j * 6 + 5] = hideZ;
          ecol[j * 6] = 0; ecol[j * 6 + 1] = 0; ecol[j * 6 + 2] = 0;
          ecol[j * 6 + 3] = 0; ecol[j * 6 + 4] = 0; ecol[j * 6 + 5] = 0;
          continue;
        }
        var hidden = brainDead(s) || brainDead(t2e);
        if (e.deadMs && (topoPlay.active ? e.deadMs <= brainNowMs : true)) hidden = true;
        if (hidden) {
          epos[j * 6] = hideX; epos[j * 6 + 1] = hideY; epos[j * 6 + 2] = hideZ;
          epos[j * 6 + 3] = hideX; epos[j * 6 + 4] = hideY; epos[j * 6 + 5] = hideZ;
          ecol[j * 6] = 0; ecol[j * 6 + 1] = 0; ecol[j * 6 + 2] = 0;
          ecol[j * 6 + 3] = 0; ecol[j * 6 + 4] = 0; ecol[j * 6 + 5] = 0;
          continue;
        }
        epos[j * 6]     = (s.x - eCx) * eWs;
        epos[j * 6 + 1] = (eCy - s.y) * eWs;
        epos[j * 6 + 2] = -(s.z3 || 0) * eZDepth;
        epos[j * 6 + 3] = (t2e.x - eCx) * eWs;
        epos[j * 6 + 4] = (eCy - t2e.y) * eWs;
        epos[j * 6 + 5] = -(t2e.z3 || 0) * eZDepth;
        // Selection-aware and degree-aware edge dimming via vertex color.
        var isTunnel = e.type === 'tunnel';
        var isLattice = e.type === 'lattice';
        // Degree-based dimming: edges at hub nodes (high degree) are
        // individually fainter so hundreds of overlapping edges don't
        // stack into a bright comet at the hub vertex.
        var sDeg = (brainAdjacency[e.src] || []).length;
        var tDeg = (brainAdjacency[e.tgt] || []).length;
        var maxDeg = Math.max(sDeg, tDeg, 1);
        var degDim = Math.min(1, 8 / Math.sqrt(maxDeg));
        var ea = degDim;
        if (hasSel) {
          var srcCore = e.src === brainSelectedNode.id || brainHop1[e.src];
          var tgtCore = e.tgt === brainSelectedNode.id || brainHop1[e.tgt];
          if (srcCore && tgtCore) { /* full degDim */ }
          else if (srcCore || tgtCore || brainHop2[e.src] || brainHop2[e.tgt]) ea *= 0.3;
          else ea *= 0.05;
        }
        var bc = isTunnel ? [0.86, 0.88, 0.94] : isLattice ? [1.0, 0.71, 0.24] : [0.23, 0.71, 1.0];
        ecol[j * 6] = bc[0] * ea; ecol[j * 6 + 1] = bc[1] * ea; ecol[j * 6 + 2] = bc[2] * ea;
        ecol[j * 6 + 3] = bc[0] * ea; ecol[j * 6 + 4] = bc[1] * ea; ecol[j * 6 + 5] = bc[2] * ea;
      }
      brainEdgesMesh.geometry.attributes.position.needsUpdate = true;
      brainEdgesMesh.geometry.attributes.color.needsUpdate = true;
    }

    // Update HTML label overlays for community lobes.
    updateBrainLabels();
  }

  // Project a world-space point to screen-space for HTML label positioning.
  function worldToScreen(x, y, z) {
    var v = new THREE.Vector3(x, y, z);
    v.project(brainCamera);
    return {
      x: (v.x * 0.5 + 0.5) * brainW,
      y: (-v.y * 0.5 + 0.5) * brainH,
      visible: v.z < 1,
    };
  }

  // Community lobe labels as HTML overlays — crisp text at any zoom.
  function updateBrainLabels() {
    var ranks = Object.keys(brainLobeLabels);
    // Rebuild label elements if count changed.
    if (brainLabelEls.length !== ranks.length && brainLabelContainer) {
      brainLabelContainer.innerHTML = '';
      brainLabelEls = [];
      ranks.forEach(function () {
        var lbl = document.createElement('div');
        lbl.style.cssText = 'position:absolute;font:11px ui-monospace,SFMono-Regular,Menlo,monospace;'
          + 'color:rgba(232,234,240,0.5);letter-spacing:1.5px;text-transform:uppercase;white-space:nowrap;';
        brainLabelContainer.appendChild(lbl);
        brainLabelEls.push(lbl);
      });
    }
    // Position each label at its lobe centroid.
    var groups = Object.create(null);
    brainNodes.forEach(function (n) {
      if (!n.lobe || brainLobeLabels[n.community] === undefined) return;
      (groups[n.community] = groups[n.community] || []).push(n);
    });
    ranks.forEach(function (rank, ri) {
      var lbl = brainLabelEls[ri];
      if (!lbl) return;
      var members = groups[rank];
      if (!members || !members.length) { lbl.style.display = 'none'; return; }
      var lCx = 0, lCy = 0, lCz = 0;
      var lblZDepth = brain3D ? 1.4 : 0;
      var lWs = brainWorldScale, lWcx = brainWorldCX, lWcy = brainWorldCY;
      members.forEach(function (n) {
        lCx += n.x; lCy += n.y;
        lCz += -(n.z3 || 0) * lblZDepth;
      });
      lCx /= members.length; lCy /= members.length; lCz /= members.length;
      var spread = members.reduce(function (s, n) {
        return s + Math.hypot(n.x - lCx, n.y - lCy);
      }, 0) / members.length;
      // Convert pixel centroid to world-space for projection, placing
      // the label above the lobe centroid.
      var wx = (lCx - lWcx) * lWs;
      var wy = (lWcy - lCy) * lWs + spread * lWs * 1.2;
      var sp = worldToScreen(wx, wy, lCz);
      if (!sp.visible) { lbl.style.display = 'none'; return; }
      lbl.style.display = '';
      lbl.style.left = sp.x + 'px';
      lbl.style.top = sp.y + 'px';
      lbl.style.transform = 'translate(-50%, -100%)';
      // V2-P2a: the label swatch/text use the LOBE's resolved aura color
      // (brainLobeRGB — purity-desaturated dominant code), not an
      // individual member's own node color, since members in a mixed lobe
      // carry different colors now (see pushNode's per-node fallback chain).
      var col = brainLobeRGB[rank] || BRAIN_COMM_COLORS[parseInt(rank, 10) % BRAIN_COMM_COLORS.length];
      lbl.innerHTML = '<span style="display:inline-block;width:5px;height:5px;border-radius:50%;background:rgb('
        + col[0] + ',' + col[1] + ',' + col[2] + ');margin-right:6px;vertical-align:middle;opacity:0.65"></span>'
        + String(brainLobeConfidence[rank] || brainLobeLabels[rank]).toUpperCase();
    });
  }

  // Hit test via raycaster — not needed externally, selection uses the
  // click handler's inline raycaster. Provided for compatibility.
  function brainHitTest(ex, ey) {
    if (!brainPointsMesh || !brainGLRenderer) return null;
    var rect = brainGLRenderer.domElement.getBoundingClientRect();
    brainPointer.x = ((ex - rect.left) / rect.width) * 2 - 1;
    brainPointer.y = -((ey - rect.top) / rect.height) * 2 + 1;
    brainRaycaster.setFromCamera(brainPointer, brainCamera);
    var hits = brainRaycaster.intersectObject(brainPointsMesh);
    if (hits.length > 0) {
      var node = brainNodes[hits[0].index];
      if (node && !brainHidden(node)) return node;
    }
    return null;
  }

  // Set or clear the selection. Computes hop-1 and hop-2 neighbor sets from brainAdjacency.
  function selectBrainNode(node) {
    brainSelectedNode = node;
    brainHop1 = Object.create(null);
    brainHop2 = Object.create(null);
    if (!node) return;
    var adj = brainAdjacency[node.id] || [];
    adj.forEach(function (id) { brainHop1[id] = true; });
    // 2-hop: neighbors of each hop-1 that aren't the selected node or already hop-1.
    adj.forEach(function (id) {
      (brainAdjacency[id] || []).forEach(function (id2) {
        if (id2 !== node.id && !brainHop1[id2]) brainHop2[id2] = true;
      });
    });
  }

  // Paste-ready AI query for a node: "what is likely this node and its
  // neighbors?" Built entirely from on-wire metadata; the user's AI session
  // (with the MOOTx01 tools) does the actual retrieval under its own
  // authorization. Neighbor list is capped to keep the prompt readable.
  function buildNodeQuery(node) {
    var NEIGHBOR_CAP = 12;
    var adj = brainAdjacency[node.id] || [];
    var neighbors = adj.slice(0, NEIGHBOR_CAP);
    var domain = (node.commKey && node.commKey !== "(unlabeled)" && node.commKey !== "fragments")
      ? node.commKey : null;
    var code = domain ? brainCodeByKey[domain] : null;

    var lines = [];
    lines.push("Using my MOOTx01 memory estate, look up the memory with id " + node.id +
               " (moot_memory_get) and tell me in plain language what it is.");
    if (neighbors.length) {
      lines.push("Then look up its directly connected memories: " + neighbors.join(", ") +
                 (adj.length > neighbors.length
                   ? " (plus " + (adj.length - neighbors.length) + " more not listed)."
                   : "."));
      lines.push("Explain what this node and its neighborhood are likely about as a group, " +
                 "and point out anything similar or related that is worth reading next " +
                 "(moot_connection_search or moot_memory_search can find those).");
    } else {
      lines.push("It has no direct connections yet — after summarizing it, search for " +
                 "related memories (moot_memory_search) and suggest what it should link to.");
    }
    if (domain) {
      lines.push("Console context: the management console files it under the knowledge domain " +
                 "“" + domain + "”" + (code ? " (classification code " + code + ")" : "") + ".");
    }
    return lines.join("\n");
  }

  // Copy text to the clipboard; cb(ok). The async Clipboard API needs a
  // trustworthy origin — the console is loopback (127.0.0.1), which browsers
  // treat as secure — with a hidden-textarea execCommand fallback for the
  // rest.
  function copyText(text, cb) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { cb(true); },
                                               function () { cb(copyTextFallback(text)); });
    } else {
      cb(copyTextFallback(text));
    }
  }
  function copyTextFallback(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.cssText = "position:fixed;left:-9999px;top:0";
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (_) { ok = false; }
    ta.remove();
    return ok;
  }

  // Clipboard-refused fallback (Safari right-click): the query in a
  // pre-selected textarea plus a Copy button. The button click carries the
  // user activation that the contextmenu event lacked.
  function showQueryFallback(text) {
    if ($("#queryFallback")) return;
    var wrap = el("div", "mx-modal-backdrop");
    wrap.id = "queryFallback";
    var box = el("div", "mx-modal");
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-modal", "true");
    box.setAttribute("aria-labelledby", "queryFallbackTitle");

    var h = el("h2", "mx-modal-title", "Copy this query");
    h.id = "queryFallbackTitle";
    box.appendChild(h);
    box.appendChild(el("p", "mx-modal-p",
      "Your browser only allows copying from a click. Press Copy (or ⌘C — the text is already selected), then paste it into your AI."));

    var ta = el("textarea", "mx-query-text");
    ta.value = text;
    ta.setAttribute("readonly", "readonly");
    ta.setAttribute("aria-label", "Node query");
    box.appendChild(ta);

    var opener = document.activeElement;
    function dismiss() {
      document.removeEventListener("keydown", onKey);
      wrap.remove();
      if (opener && opener.focus) opener.focus();
    }
    function onKey(e) { if (e.key === "Escape") dismiss(); }
    document.addEventListener("keydown", onKey);
    wrap.addEventListener("click", function (e) { if (e.target === wrap) dismiss(); });

    var copyBtn = el("button", "btn mx-modal-close", "Copy");
    copyBtn.setAttribute("type", "button");
    copyBtn.addEventListener("click", function () {
      ta.select();
      copyText(text, function (ok) {
        dismiss();
        topoToast(ok ? "Query copied — paste it into your AI to explore this memory"
                     : "Copy failed — select the text and press ⌘C");
      });
    });
    var closeBtn = el("button", "btn btn-ghost mx-modal-close", "Close");
    closeBtn.setAttribute("type", "button");
    closeBtn.style.marginLeft = "8px";
    closeBtn.addEventListener("click", dismiss);

    box.appendChild(copyBtn);
    box.appendChild(closeBtn);
    wrap.appendChild(box);
    document.body.appendChild(wrap);
    ta.focus();
    ta.select();
  }

  // Transient toast on the topology stage (bottom-center, auto-fades).
  function topoToast(msg) {
    var stage = $("#topoStage");
    if (!stage) return;
    var t = el("div", "topo-toast", msg);
    stage.appendChild(t);
    setTimeout(function () { t.remove(); }, 4200);
  }

  function stopBrainAnimation() {
    if (brainAnimId) { cancelAnimationFrame(brainAnimId); brainAnimId = null; }
    if (brainResizeObs) { brainResizeObs.disconnect(); brainResizeObs = null; }
    if (brainPointsMesh) {
      brainPointsMesh.geometry.dispose();
      brainPointsMesh.material.dispose();
      brainScene.remove(brainPointsMesh);
      brainPointsMesh = null;
    }
    if (brainEdgesMesh) {
      brainEdgesMesh.geometry.dispose();
      brainEdgesMesh.material.dispose();
      brainScene.remove(brainEdgesMesh);
      brainEdgesMesh = null;
    }
    if (brainRippleMesh) {
      brainRippleMesh.geometry.dispose();
      brainRippleMesh.material.dispose();
      brainScene.remove(brainRippleMesh);
      brainRippleMesh = null;
    }
    if (brainTrailMesh) {
      brainTrailMesh.geometry.dispose();
      brainTrailMesh.material.dispose();
      brainScene.remove(brainTrailMesh);
      brainTrailMesh = null;
    }
    brainRipples = []; brainTrails = []; brainLastPulseNode = null;
    if (brainControls) { brainControls.dispose(); brainControls = null; }
    if (brainGLRenderer) {
      brainGLRenderer.dispose();
      if (brainGLRenderer.domElement && brainGLRenderer.domElement.parentNode)
        brainGLRenderer.domElement.parentNode.removeChild(brainGLRenderer.domElement);
      brainGLRenderer = null;
    }
    if (brainLabelContainer && brainLabelContainer.parentNode) {
      brainLabelContainer.parentNode.removeChild(brainLabelContainer);
    }
    brainLabelContainer = null; brainLabelEls = [];
    brainSelectedNode = null; brainHop1 = Object.create(null); brainHop2 = Object.create(null); brainAdjacency = Object.create(null);
    brainScene = null; brainCamera = null; brainContainer = null;
  }

  // Decay pulse and glow magnitudes each frame — keeps magnitudes from needing
  // explicit timers alongside the animation loop.
  function tickBrainDecay(dt) {
    brainNodes.forEach(function (n) {
      if (n.pulseOrange > 0) n.pulseOrange = Math.max(0, n.pulseOrange - dt * 1.1);
      // pulseBlue: same ~1s decay as orange — yields an expanding blue ring for think events
      if (n.pulseBlue > 0)   n.pulseBlue   = Math.max(0, n.pulseBlue   - dt * 1.1);
      if (n.glowBlue > 0)    n.glowBlue    = Math.max(0, n.glowBlue    - dt * 0.075);
    });
  }

  // L2 recency brightness — alpha multiplier from how recently the node was
  // active. 1.0 under an hour old, exponential decay (tau = 7 days) toward a
  // 0.35 floor; the floor is effectively reached past 30 days. Nodes without
  // a lastActiveTs stay at full brightness (the wire format dropped the
  // field — FIX 2 payload trim — so the createdMs fallback usually applies).
  var BRAIN_HOUR_MS = 3600000;
  var BRAIN_DAY_MS = 86400000;
  function recencyFactor(n, nowMs) {
    if (!n.lastMs) return 1;
    var age = nowMs - n.lastMs;
    if (age <= BRAIN_HOUR_MS) return 1;
    return 0.35 + 0.65 * Math.exp(-(age - BRAIN_HOUR_MS) / (7 * BRAIN_DAY_MS));
  }

  // Structural depth: z3 ∈ [0,1] = hop distance from the estate's keystone
  // nodes (top-centrality pillars). Keystones float at z=0, periphery sinks
  // to z=1. Multi-source BFS from the top-K centrality nodes; nodes
  // unreachable from any keystone (disconnected fragments) get z3=1.
  // Also sets birthMs for the L5 alive(t) playback filter.
  function brainAssignDepth(nowMs) {
    // Timestamp bookkeeping for L5 playback (independent of z-mapping).
    brainNodes.forEach(function (n) {
      n.birthMs = n.createdMs || n.lastMs || null;
    });

    // Find the top-K keystone nodes by centrality.
    var K = Math.max(1, Math.min(5, Math.ceil(brainNodes.length * 0.02)));
    var sorted = brainNodes.slice().sort(function (a, b) {
      return (b.centrality || 0) - (a.centrality || 0);
    });
    var seeds = sorted.slice(0, K);

    // Build adjacency from brainEdges for BFS.
    var adj = Object.create(null);
    brainEdges.forEach(function (e) {
      (adj[e.src] = adj[e.src] || []).push(e.tgt);
      (adj[e.tgt] = adj[e.tgt] || []).push(e.src);
    });

    // Multi-source BFS: distance from nearest keystone.
    var dist = Object.create(null);
    var queue = [];
    seeds.forEach(function (n) { dist[n.id] = 0; queue.push(n.id); });
    var head = 0;
    while (head < queue.length) {
      var cur = queue[head++];
      var d = dist[cur];
      (adj[cur] || []).forEach(function (nbr) {
        if (dist[nbr] === undefined) {
          dist[nbr] = d + 1;
          queue.push(nbr);
        }
      });
    }

    // Normalize to [0,1]. Unreachable nodes (disconnected) get max depth.
    var maxDist = 1;
    brainNodes.forEach(function (n) {
      var d = dist[n.id];
      if (d !== undefined && d > maxDist) maxDist = d;
    });
    brainNodes.forEach(function (n) {
      var d = dist[n.id];
      n.z3 = d !== undefined ? d / maxDist : 1;
    });
  }

  // Three.js handles projection and depth sorting natively via the GPU
  // pipeline — no manual brainProject, brainEdgeZ, or brainUpdateDrawOrder.

  // L5 alive(t) filter — true when the node has not been ingested yet at the
  // current playhead time. Only meaningful while a playback session is active.
  function brainUnborn(n) {
    return topoPlay.active && !!n.birthMs && n.birthMs > brainNowMs;
  }

  // Tombstone filter — entities carry deadMs when the payload includes
  // tombstonedTs. Live view: a dead entity is hidden outright. Playback:
  // visible during its lifespan [birth, death), so the loop shows communities
  // dissolving as their members tombstone.
  function brainDead(n) {
    if (!n.deadMs) return false;
    return topoPlay.active ? n.deadMs <= brainNowMs : true;
  }

  // Combined visibility for nodes and edge endpoints.
  function brainHidden(n) {
    return brainUnborn(n) || brainDead(n);
  }


  // Canvas2D drawing functions removed — replaced by Three.js WebGL renderer
  // (buildBrainPoints, buildBrainLines, updateBrainFrame, updateBrainLabels
  // defined above in startBrainAnimation's section).

  // ===========================================================================
  // CONTENT PICKER — check/uncheck the estate's knowledge domains
  // ===========================================================================
  // Rows come from topoCommRows (built from the FULL real node set); keys are
  // content identities (FDC labels / buckets), so selections survive snapshot
  // refreshes and re-renders. Clicking a row toggles that domain (the first
  // click starts a selection with just it); "All" clears. Filtering HIDES deselected
  // content and RE-LAYS-OUT the selection to fill the canvas — solo a
  // continent and its nodes get the whole stage. Hues stay stable via
  // topoCommPaletteByKey regardless of subset rank order.

  /// Build the brain node/edge sets from topoRealData, honouring the content
  /// filter, and restart the animation. `isSubset` distinguishes a filter
  /// re-layout (picker rows untouched) from a fresh full build.
  function buildBrainFromRealData(isSubset) {
    var d = topoRealData;
    if (!d) return;
    // Picker rows always describe the FULL estate. On a fresh build while a
    // filter is active (e.g. "Reset layout" mid-selection, or a snapshot
    // refresh), rebuild the rows from the full set FIRST — otherwise the
    // picker would collapse to the current selection and the deselected
    // domains would be unrecoverable until a page reload.
    if (!isSubset && topoCommFilter) {
      buildRealBrainNodes(d.rawNodes, d.communities, d.W, d.H, false);
    }
    // The LAYOUT is subset-shaped whenever a filter is active, regardless of
    // how we got here — rows and layout are decoupled concerns.
    var layoutAsSubset = isSubset || !!topoCommFilter;
    var keep = function (n) {
      if (!topoCommFilter) return true;
      var key = topoCommKeyById[n.communityId];
      // Dead nodes (communityId -1) have no content key: keep them — they
      // are hidden in live view anyway and playback still needs them.
      return key === undefined || topoCommFilter.has(key);
    };
    var rawNodes = d.rawNodes.filter(keep);
    var present = Object.create(null);
    rawNodes.forEach(function (n) { present[n.id] = true; });

    brainNodes = buildRealBrainNodes(rawNodes, d.communities, d.W, d.H, layoutAsSubset);
    brainEdges = d.rawEdges
      .filter(function (e) { return present[e.source] && present[e.target]; })
      .map(function (e) {
        return {
          src: e.source, tgt: e.target,
          type: e.edgeType || "tunnel", w: e.weight || 0.5,
          // Tombstoned tunnels vanish at deadMs during playback, hidden live.
          deadMs: Date.parse(e.tombstonedTs) || null,
        };
      });
    brainAssignDepth(Date.now());
    if (isSubset) startBrainAnimation(d.container, d.W, d.H);
  }

  function commAllKeys() {
    return topoCommRows.map(function (r) { return r.key; });
  }

  // Facet-filter multiselect: from All, the first click starts a selection
  // containing just that domain; further clicks add/remove domains; removing
  // the last one (or re-checking everything) resets to All.
  function commToggle(key) {
    if (!topoCommFilter) {
      topoCommFilter = new Set([key]);
    } else {
      if (topoCommFilter.has(key)) topoCommFilter.delete(key);
      else topoCommFilter.add(key);
      if (topoCommFilter.size === commAllKeys().length || topoCommFilter.size === 0) {
        topoCommFilter = null;
      }
    }
    buildBrainFromRealData(true);
    renderCommPicker();
  }

  function renderCommPicker() {
    var panel = $("#topoCommPicker");
    if (!panel) return;
    clear(panel);
    if (!topoCommRows.length) { panel.hidden = true; return; }
    panel.hidden = false;

    var head = el("div", "cp-head");
    var title = el("span", "cp-title", "content");
    var allBtn = el("button", "cp-all", "All");
    allBtn.setAttribute("aria-pressed", topoCommFilter ? "false" : "true");
    allBtn.addEventListener("click", function () {
      topoCommFilter = null;
      buildBrainFromRealData(true);
      renderCommPicker();
    });
    head.appendChild(title);
    head.appendChild(allBtn);
    panel.appendChild(head);

    // Plain-language explainer for the classification codes behind these
    // domain labels — same modal as the Lattice view's button.
    var what = el("button", "cp-all cp-what", "What are these codes?");
    what.setAttribute("type", "button");
    what.addEventListener("click", showCodesExplainer);
    panel.appendChild(what);

    var list = el("div", "cp-list");
    topoCommRows.forEach(function (row) {
      var on = !topoCommFilter || topoCommFilter.has(row.key);
      var line = el("div", "cp-row" + (on ? "" : " off"));

      var box = el("span", "cp-box" + (on ? " on" : ""));
      box.setAttribute("role", "checkbox");
      box.setAttribute("aria-checked", on ? "true" : "false");

      var dot = el("span", "cp-dot");
      // row.rgb is the resolved community color (digit-derived from the FDC
      // code, or the palette fallback); rows without one (buckets) go neutral.
      var col = row.rgb || (row.cIdx >= 0 ? BRAIN_COMM_COLORS[row.cIdx % BRAIN_COMM_COLORS.length] : null);
      dot.style.background = col
        ? "rgb(" + col[0] + "," + col[1] + "," + col[2] + ")"
        : "rgba(232,234,240,0.35)";

      // V2-P2a: show the confidence label ("Label · 82%" / "Mixed · top:
      // …") when the row is a coded lobe; row.key (the filter identity —
      // untouched) stays the fallback for buckets and code-less lobes.
      var label = el("span", "cp-label", row.confidence || row.key);
      var size = el("span", "cp-size", String(row.size));

      line.appendChild(box);
      line.appendChild(dot);
      line.appendChild(label);
      line.appendChild(size);
      // Click anywhere on the row toggles the domain (checkbox semantics).
      line.addEventListener("click", function () { commToggle(row.key); });
      list.appendChild(line);
    });
    panel.appendChild(list);
  }

  function topoTeardown() {
    stopBrainAnimation();
    topoPlayReset();
    if (sse) sse.removeEventListener("message", topoSSEHandler);
  }

  async function renderTopology() {
    topoTeardown();
    const container = $("#topoCanvas");
    const estate = $("#topoEstate").value || "";

    let g = { structurePending: true, nodes: [], edges: [], analytics: [], communities: [] };
    try {
      g = await getJSON("/api/graph" + (estate ? "?estate=" + encodeURIComponent(estate) : ""));
    } catch (_) {
      // Endpoint unreachable — fall through with structurePending:true so the
      // honest pending overlay renders. The canvas never shows invented data.
    }

    $("#topoStructure").textContent = g.structurePending ? "pending" : "live";

    // Populate estate selector from analytics (once — avoids jump on re-render).
    const sel = $("#topoEstate");
    if (sel.options.length === 0) {
      sel.appendChild(new Option("all", ""));
      Array.from(new Set((g.analytics || []).map((a) => a.estate))).sort()
        .forEach((id) => sel.appendChild(new Option(estateDisplayName(id), id)));
    }

    // One rAF ensures the topology section is visible and fully laid out before we
    // measure — getBoundingClientRect returns 0×0 on a just-shown element otherwise.
    await new Promise(function (r) { requestAnimationFrame(r); });
    // Read dimensions from the outer stage (which has the explicit CSS height), not
    // the inner canvas container (which may still be 0×0 at this point).
    const stageRect = ($("#topoStage") || container).getBoundingClientRect();
    const W = stageRect.width > 10 ? stageRect.width : 800;
    const H = stageRect.height > 10 ? stageRect.height : 500;

    // Fetch recent events: they feed the L5 radar-loop playback timeline.
    let events = [];
    try { const ep = await getJSON("/api/events"); events = ep.events || []; } catch (_) {}

    // L5: parse + sort the playback timeline ascending by event timestamp.
    // drawerId (estate row UUID or null) is the pulse-targeting key.
    topoPlayEvents = events
      .map(function (ev) {
        return {
          ms: Date.parse(ev.ts), ts: ev.ts, kind: ev.kind,
          nounType: ev.nounType, estate: ev.estate, drawerId: ev.drawerId || null,
        };
      })
      .filter(function (ev) { return !isNaN(ev.ms); })
      .sort(function (a, b) { return a.ms - b.ms; });
    topoPlayReset();
    topoPlayUpdateSpan();
    // Radar semantics: the loop is ambient — it plays without interaction,
    // like a weather radar on a wall display. Auto-start when the timeline
    // has content; the Pause button stops it.
    if (topoPlayEvents.length > 1) topoPlayToggle();

    // Build node + edge sets from real VizGraph structure; an empty canvas
    // plus the pending overlay is the honest no-structure state.
    //
    // FIX 2b compact format: the server emits parallel arrays (g.ids, g.communityId, ...)
    // and compact edges ([[si, ti, w, et], ...]).  The legacy per-object format
    // (g.nodes / g.edges) is no longer emitted but is accepted for any cached/old
    // responses still in flight.  Detect by Array.isArray(g.ids).
    //
    // Edge-type ordinal mapping (mirrors CompactEdge.edgeTypeOrdinal in Swift/Rust):
    var edgeTypeNames = ["tunnel", "kgFact", "association", "nmf_bond"];
    var rawNodes, rawEdges;
    if (Array.isArray(g.ids)) {
      // Compact format — unpack parallel arrays into per-object form for the renderer.
      var tombstoned = g.tombstoned || {};
      // V2-P2a meaning channel: `codes` is the FDC code dictionary and
      // `codeIndex` is parallel to `ids` (-1 = no code). Both are new/
      // optional wire keys from a parallel mission — older/live payloads
      // lack them, in which case `codes`/`codeIndex` are null here and
      // every node's `code` collapses to null below. That's the exact
      // pre-V2-P2a state: fdcColor(null) and lobeCodeStats both already
      // treat a null code as "no code", so this degrades to current
      // behavior with no special-casing needed downstream.
      var codes = Array.isArray(g.codes) ? g.codes : null;
      var codeIndex = Array.isArray(g.codeIndex) ? g.codeIndex : null;
      rawNodes = g.ids.map(function (id, i) {
        var ci = codeIndex ? codeIndex[i] : -1;
        return {
          id: id,
          communityId: g.communityId[i],
          centrality:  g.centrality[i],
          anomaly:     g.anomaly[i],
          createdTs:   g.createdTs[i],
          tombstonedTs: tombstoned[String(i)] || null,
          code: (codes && typeof ci === "number" && ci >= 0) ? (codes[ci] || null) : null,
        };
      });
      // Compact edges [[si, ti, w, et]] → per-object form the renderer expects.
      rawEdges = (g.edges || []).map(function (e) {
        return {
          source: g.ids[e[0]], target: g.ids[e[1]],
          weight: e[2],
          edgeType: edgeTypeNames[e[3]] || "tunnel",
          tombstonedTs: null,  // tombstoned edges are absent from the snapshot
        };
      });
    } else {
      // Legacy per-object format (no longer emitted; accepted for graceful fallback).
      rawNodes = g.nodes || [];
      rawEdges = g.edges || [];
    }
    const nodeCount = rawNodes.length;
    const hasRealStructure = !g.structurePending && nodeCount > 0;
    if (hasRealStructure) {
      // Retain the full dataset + community→content-key map so the content
      // picker can re-layout a SUBSET without refetching.
      topoRealData = { rawNodes: rawNodes, rawEdges: rawEdges,
                       communities: g.communities || [], W: W, H: H,
                       container: container };
      topoCommKeyById = Object.create(null);
      const sizeById = Object.create(null);
      rawNodes.forEach(function (n) {
        if (n.communityId >= 0) sizeById[n.communityId] = (sizeById[n.communityId] || 0) + 1;
      });
      (g.communities || []).forEach(function (c) {
        topoCommKeyById[c.id] = c.label ||
          ((sizeById[c.id] || c.size || 0) >= 4 ? "(unlabeled)" : "fragments");
      });
      buildBrainFromRealData(false);
    } else {
      // No real structure — empty canvas + pending overlay. Never invented data.
      topoRealData = null;
      brainNodes = [];
      brainEdges = [];
      brainLobeLabels = Object.create(null);
      brainLobeRGB = Object.create(null);
      brainLobeConfidence = Object.create(null);
      topoCommRows = [];     // no content picker without real communities
    }
    renderCommPicker();
    // L4: assign per-node depth from age now that the node set is final.
    brainAssignDepth(Date.now());

    // Overlay visibility: real structure renders with the corner legend; any
    // no-structure state shows the honest pending overlay (with the analytics
    // grid when VizGraph analytics exist, a monitoring-aware message otherwise).
    const pending = $("#topoPending");
    const hasAnalytics = (g.analytics || []).length > 0;
    const monOn = lastServerData ? lastServerData.monitoringEnabled : false;

    if (!hasRealStructure && hasAnalytics) {
      // Analytics grid path: show overlay with scrollable analytics panel.
      pending.hidden = false;
      $("#topoPendingTitle").textContent = "Topology structure";
      $("#topoPendingText").textContent =
        "Showing VizGraph analytics — autonomic governor runs CognitionKit recipes on schedule to populate structure.";
      topoRenderAnalytics(g);
    } else if (!hasRealStructure) {
      // No analytics either: centered overlay with a monitoring-aware message.
      pending.hidden = false;
      $("#topoPendingTitle").textContent = "Topology structure pending";
      $("#topoPendingText").textContent = monOn
        ? "The autonomic governor builds the knowledge graph on its schedule — structure appears after its next duty cycle."
        : "Monitoring is off — turn it on to start capturing structure.";
      topoRenderAnalytics(g);    // renders static legend in #topoLegend
    } else {
      // Real structure: overlay hidden, VizGraph legend in corner.
      pending.hidden = true;
      topoRenderAnalytics(g);
    }

    startBrainAnimation(container, W, H);
    topoStartSSE();
  }

  // CSS color string for lobe rank i — keeps the DOM legend swatches in sync
  // with the canvas community colors. Reads the resolved per-lobe color
  // (digit-derived from the FDC code) recorded by buildRealBrainNodes, with
  // the static palette as the fallback for ranks that never earned a lobe.
  // communities[] arrives sorted by size desc, so array index == lobe rank
  // for the top entries.
  function brainCommCSS(i) {
    const col = brainLobeRGB[i] || BRAIN_COMM_COLORS[i % BRAIN_COMM_COLORS.length];
    return "rgb(" + col[0] + "," + col[1] + "," + col[2] + ")";
  }

  function freshClass(ts) {
    const ms = Date.parse(ts);
    if (isNaN(ms)) return "unknown";
    const ageSecs = (Date.now() - ms) / 1000;
    if (ageSecs < 60) return "fresh";
    if (ageSecs < 300) return "aging";
    return "stale";
  }

  // Three paths:
  //   1. structure live → compact corner legend, clear analytics
  //   2. structure pending + analytics present → analytics grid is primary content
  //   3. structure pending + no analytics → centered overlay with monitoring-state-aware message
  function topoRenderAnalytics(g) {
    const pendingEl = $("#topoPending");
    const analyticsBox = $("#topoAnalytics");
    const legend = $("#topoLegend");

    if (!g.structurePending) {
      pendingEl.classList.remove("topo-pending--has-analytics");
      pendingEl.removeAttribute("tabindex");
      pendingEl.removeAttribute("aria-label");
      clear(analyticsBox);
      clear(legend);
      legend.style.display = "";
      legend.appendChild(el("div", "lhead", "VizGraph signals"));
      if (!(g.analytics || []).length) {
        legend.appendChild(el("div", "lrow", "no signals yet"));
      } else {
        const bySignal = Object.create(null);
        g.analytics.forEach((a) => { bySignal[a.signal] = a.value; });
        Object.keys(bySignal).sort().forEach((sig) => {
          const row = el("div", "lrow");
          row.appendChild(el("span", null, sig));
          row.appendChild(el("b", null, String(Math.round(bySignal[sig] * 100) / 100)));
          legend.appendChild(row);
        });
      }
      if ((g.communities || []).length) {
        const sw = el("div", "lswatches");
        g.communities.slice(0, 12).forEach((c, i) => {
          const dot = el("div", "lsw");
          const rgb = fdcColor(c.code);
          dot.style.background = rgb ? "rgb(" + rgb.join(",") + ")" : brainCommCSS(i);
          sw.appendChild(dot);
        });
        legend.appendChild(sw);
      }
      return;
    }

    clear(analyticsBox);

    if (!(g.analytics || []).length) {
      // Path 3: no analytics. The overlay is hidden on this path (brain is the hero).
      // Render the static PoC-spec legend in the bottom-right corner panel.
      pendingEl.classList.remove("topo-pending--has-analytics");
      pendingEl.removeAttribute("tabindex");
      pendingEl.removeAttribute("aria-label");
      topoRenderStaticLegend(legend);
      return;
    }

    // Path 2: analytics present.
    pendingEl.classList.add("topo-pending--has-analytics");
    pendingEl.setAttribute("tabindex", "0");
    pendingEl.setAttribute("aria-label", "VizGraph analytics");
    legend.style.display = "none";
    clear(legend);

    const byEstate = Object.create(null);
    g.analytics.forEach((a) => {
      if (!byEstate[a.estate]) byEstate[a.estate] = [];
      byEstate[a.estate].push(a);
    });

    Object.keys(byEstate).sort().forEach((estate) => {
      const signals = byEstate[estate].slice().sort((a, b) => a.signal.localeCompare(b.signal));
      const section = el("div", "topo-estate-section");
      section.appendChild(el("div", "topo-estate-label", estateDisplayName(estate)));

      signals.forEach((a) => {
        const row = el("div", "topo-signal-row");
        row.appendChild(el("span", "topo-signal-name", a.signal));
        const isInt = a.signal === "community.assignment" || a.signal === "anomaly.flag";
        row.appendChild(el("span", "topo-signal-val",
          isInt ? String(Math.round(a.value)) : a.value.toFixed(3)));
        const meta = el("div", "topo-signal-meta");
        meta.appendChild(el("span", "topo-signal-samples", a.sampleCount + " samples"));
        const dot = el("div", "topo-fresh-dot " + freshClass(a.ts));
        dot.setAttribute("aria-hidden", "true");
        meta.appendChild(dot);
        row.appendChild(meta);
        section.appendChild(row);
      });

      analyticsBox.appendChild(section);
    });

    if ((g.communities || []).length) {
      const commDiv = el("div", "topo-communities");
      commDiv.appendChild(el("span", "topo-comm-label",
        g.communities.length + " communities detected across all estates"));
      const swatches = el("div", "topo-swatches");
      g.communities.slice(0, 12).forEach((c, i) => {
        const sw = el("div", "lsw");
        const rgb = fdcColor(c.code);
        sw.style.background = rgb ? "rgb(" + rgb.join(",") + ")" : brainCommCSS(i);
        sw.setAttribute("aria-hidden", "true");
        swatches.appendChild(sw);
      });
      if (g.communities.length > 12) {
        swatches.appendChild(el("span", "topo-comm-label",
          "…+" + (g.communities.length - 12) + " more"));
      }
      commDiv.appendChild(swatches);
      analyticsBox.appendChild(commDiv);
    }
  }

  // Render the static PoC-spec legend (node types / activity / edge types) in the legend panel.
  function topoRenderStaticLegend(legend) {
    clear(legend);
    legend.style.display = "";

    function sect(title) { legend.appendChild(el("div", "topo-lsect", title)); }
    function dotRow(style, label) {
      const r = el("div", "topo-lrow");
      const d = el("div", "topo-ldot");
      d.setAttribute("style", style);
      r.appendChild(d);
      r.appendChild(document.createTextNode(label));
      legend.appendChild(r);
    }
    function lineRow(style, label) {
      const r = el("div", "topo-lrow");
      const ln = el("div", "topo-lline");
      ln.setAttribute("style", style);
      r.appendChild(ln);
      r.appendChild(document.createTextNode(label));
      legend.appendChild(r);
    }

    sect("Node types");
    dotRow("background:#e8eaf0;opacity:.9", "drawer");
    dotRow("background:#3ab4ff", "diary entry");
    dotRow("background:#ff8c00;opacity:.5;border:1px dashed #ff8c00", "proposal");
    dotRow("background:rgba(232,234,240,.2);border:1px solid rgba(232,234,240,.3)", "ambient");

    sect("Activity");
    dotRow("background:#ff8c00;box-shadow:0 0 6px #ff8c00", "capture pulse");
    dotRow("background:#3ab4ff;box-shadow:0 0 6px #3ab4ff", "think glow");

    sect("Edges");
    lineRow("background:rgba(232,234,240,.35)", "tunnel");
    lineRow("border-top:1px dashed rgba(58,180,255,.4)", "kgFact");
    lineRow("border-top:1px dashed rgba(255,180,60,.4)", "lattice");
    lineRow("background:rgba(232,234,240,.1)", "association");
  }

  // =========================================================================
  // L5 RADAR-LOOP PLAYBACK — event-indexed playhead over /api/events history.
  //
  // The loop advances event-by-event (~110ms dwell + the real inter-event gap
  // capped at 400ms). Each crossing pulses the matching brain node via the
  // existing pulse/glow decay mechanics. While a playback session is active,
  // drawBrainFrame keys recency + the alive(t) filter off the playhead time.
  // Live SSE stays connected throughout — real-time pulses keep landing.
  // =========================================================================

  // Events inside the selected playback window (the most recent N, or all).
  function topoPlayWindowEvents() {
    var sel = $("#topoPlayWindow");
    var v = sel ? sel.value : "all";
    if (v === "all") return topoPlayEvents;
    var n = parseInt(v, 10);
    return n > 0 ? topoPlayEvents.slice(-n) : topoPlayEvents;
  }

  // Human-readable duration for the span readout (minutes / hours / days).
  function fmtDuration(ms) {
    var mins = Math.round(ms / 60000);
    if (mins < 90) return mins + " min";
    var hours = Math.round(ms / 3600000);
    if (hours < 48) return hours + " hours";
    return Math.round(ms / 86400000) + " days";
  }

  // Refresh "#topoPlaySpan" — e.g. "500 events · spans 3 days".
  function topoPlayUpdateSpan() {
    var spanEl = $("#topoPlaySpan");
    if (!spanEl) return;
    var win = topoPlayWindowEvents();
    if (win.length < 2) {
      spanEl.textContent = win.length + " events";
      return;
    }
    spanEl.textContent = win.length + " events · spans " +
      fmtDuration(win[win.length - 1].ms - win[0].ms);
  }

  // Pulse the brain for one replayed event. Exact node when drawerId maps to
  // a visible brain node; otherwise a random member of the event's estate-hash
  // community keeps the replay visible (deterministic community per estate).
  // Dead (tombstoned) nodes are skipped — they are not rendered and pulsing
  // them would produce geometry at invisible positions.
  // Fire a visual pulse on the node matching ev.drawerId, or on a community-pool
  // fallback node if the drawer isn't in the graph. Returns true when a pulse was
  // fired, false when no visible node was found. Callers use the return value to
  // decide pacing: a false return advances immediately (0ms) so dead-node misses
  // don't produce dead-air pauses at the dwell interval.
  function topoPlaybackPulse(ev) {
    var node = ev.drawerId ? brainNodeMap[ev.drawerId] : null;
    // Skip tombstoned nodes — fall through to the community-pool path so the
    // pulse still fires on a visible node rather than being silently dropped.
    if (node && brainDead(node)) node = null;
    if (!node) {
      var comms = Object.keys(brainCommPools);
      if (!comms.length) return false;
      var h = 0, s = String(ev.estate || "");
      for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
      var pool = brainCommPools[comms[h % comms.length]];
      if (!pool || !pool.length) return false;
      // Pick a non-dead node from the pool (max 4 attempts to avoid an infinite
      // loop in a fully-tombstoned community — unlikely but defensive).
      var tries = 0;
      do { node = pool[Math.floor(Math.random() * pool.length)]; tries++; }
      while (brainDead(node) && tries < 4);
      if (brainDead(node)) return false;
    }
    if (ev.kind === "capture") {
      node.pulseOrange = 1.0;
    } else {
      node.pulseBlue = 1.0;
      node.glowBlue = Math.min(1.0, node.glowBlue + 0.55);
    }
    // Ripple: add an expanding ring at the event node, capped at RIPPLE_MAX.
    // Oldest ripple is evicted if the buffer is full — singing in a round.
    var rgb = node.rgb || BRAIN_COMM_COLORS[node.community % BRAIN_COMM_COLORS.length];
    var rippleColor = [rgb[0] / 255, rgb[1] / 255, rgb[2] / 255];
    if (brainRipples.length >= RIPPLE_MAX) brainRipples.shift();
    brainRipples.push({ nodeId: node.id, age: 0, rgb: rippleColor });

    // Constellation trail: if the previous pulsed node is in the same
    // community as this one, draw a glowing line between them.
    if (brainLastPulseNode && brainLastPulseNode !== node &&
        brainLastPulseNode.community === node.community) {
      if (brainTrails.length >= TRAIL_MAX) brainTrails.shift();
      brainTrails.push({
        fromId: brainLastPulseNode.id, toId: node.id, age: 0,
        rgb: rippleColor,
      });
    }
    brainLastPulseNode = node;
    return true;
  }

  // Advance the playhead one event, then schedule the next step.
  //
  // Dwell is 350ms per event — fast enough for 20 ripples to overlap in
  // their 2s lifecycle (20 × 0.35 = 7s, so the oldest ripple is at 100%
  // when the newest splashes). The effect is a continuous rain of droplets
  // with ~6 concurrently visible at any moment.
  //
  // If topoPlaybackPulse returns false (no visible node), advance
  // immediately (0ms) so dead-air never accumulates.
  //
  // End-of-pass: 2.5s pause lets all ripples and trails fully fade before
  // the next loop starts clean.
  function topoPlayStep() {
    var win = topoPlayWindowEvents();
    if (!win.length) { topoPlayToggle(); return; }
    if (topoPlay.idx >= win.length) {
      topoPlay.timer = setTimeout(function () {
        brainNodes.forEach(function (n) { n.pulseOrange = 0; n.pulseBlue = 0; });
        brainRipples = [];
        brainTrails = [];
        brainLastPulseNode = null;
        topoPlay.idx = 0;
        topoPlayStep();
      }, 2500);
      return;
    }
    var ev = win[topoPlay.idx];
    topoPlay.playheadMs = ev.ms;
    var clock = $("#topoPlayClock");
    if (clock) clock.textContent = new Date(ev.ms).toLocaleString();
    var pulsed = topoPlaybackPulse(ev);
    topoPlay.idx++;
    topoPlay.timer = setTimeout(topoPlayStep, pulsed ? 350 : 0);
  }

  // Play/pause toggle. Pause freezes the playhead (the session stays active,
  // so the replayed moment stays on screen); play resumes from that position.
  function topoPlayToggle() {
    var btn = $("#topoPlayBtn");
    if (topoPlay.playing) {
      topoPlay.playing = false;
      clearTimeout(topoPlay.timer);
      topoPlay.timer = null;
      if (btn) { btn.textContent = "Play"; btn.setAttribute("aria-pressed", "false"); }
      return;
    }
    var win = topoPlayWindowEvents();
    if (!win.length) return;  // nothing to replay
    // Initialise the playhead to the first event's time BEFORE setting active=true.
    // This prevents animation frames between the active flag flip and the first
    // topoPlayStep call from seeing playheadMs=0 (epoch-0), which would make every
    // node appear alive-from-the-future and could trigger degenerate recency values.
    if (topoPlay.idx < win.length) topoPlay.playheadMs = win[topoPlay.idx].ms;
    topoPlay.playing = true;
    topoPlay.active = true;
    if (btn) { btn.textContent = "Pause"; btn.setAttribute("aria-pressed", "true"); }
    topoPlayStep();
  }

  // Window select changed: restart the loop from the new window's start.
  function topoPlayWindowChange() {
    topoPlay.idx = 0;
    topoPlayUpdateSpan();
    if (topoPlay.playing) {
      clearTimeout(topoPlay.timer);
      topoPlayStep();
    }
  }

  // Full reset back to the live (not-playing) default state.
  function topoPlayReset() {
    clearTimeout(topoPlay.timer);
    topoPlay.timer = null;
    topoPlay.playing = false;
    topoPlay.active = false;
    topoPlay.idx = 0;
    topoPlay.playheadMs = 0;
    var btn = $("#topoPlayBtn");
    if (btn) { btn.textContent = "Play"; btn.setAttribute("aria-pressed", "false"); }
    var clock = $("#topoPlayClock");
    if (clock) clock.textContent = "—";
  }

  function topoSSEHandler(m) {
    let ev; try { ev = JSON.parse(m.data); } catch (_) { return; }
    topoFeedLine(ev);
    // Live firing targets the ACTUAL node via drawerId — same targeting as
    // replay (topoPlaybackPulse handles the estate-hash fallback when the
    // drawer is not in the rendered graph).
    topoPlaybackPulse(ev);
    // Radar semantics: new frames append as they arrive — the playback log
    // ingests live events so the next sweep includes them. SSE delivers in
    // wall-clock order, so a tail push keeps topoPlayEvents sorted ascending.
    const ms = Date.parse(ev.ts);
    if (!isNaN(ms)) {
      topoPlayEvents.push({ ms: ms, ts: ev.ts, kind: ev.kind, nounType: ev.nounType,
                            estate: ev.estate, drawerId: ev.drawerId || null });
      topoPlayUpdateSpan();
    }
  }

  function topoStartSSE() {
    if (!sse && !ssePaused) startSSE();
    if (sse) sse.addEventListener("message", topoSSEHandler);
  }

  function topoFeedLine(ev) {
    const feed = $("#topoFeed");
    const line = el("div", "fline");
    line.appendChild(el("span", "fdot " + (ev.kind === "capture" ? "capture" : "think")));
    line.appendChild(el("span", null, ev.kind + "  ·  " + nounLabel(ev.nounType) + "  ·  " + estateDisplayName(ev.estate)));
    feed.appendChild(line);
    while (feed.childElementCount > 3) feed.removeChild(feed.firstChild);
    clearTimeout(topoFeedTimer);
    topoFeedTimer = setTimeout(() => { clear(feed); }, 8500);
  }

  // =========================================================================
  // VIEW ROUTER
  // =========================================================================

  const RENDER = {
    overview:      renderOverview,
    resources:     renderResources,
    connects:      renderConnects,
    estates:       renderEstates,
    pipeline:      renderPipeline,
    activity:      renderActivity,
    topology:      renderTopology,
    lexicon:       renderLexicon,
    lattice:       renderLattice,
    configuration: renderConfiguration,
  };

  function show(view) {
    $$(".navitem").forEach((b) => b.classList.toggle("on", b.dataset.view === view));
    $$(".view").forEach((s) => {
      // activity-temp is hidden via inline style — never show via .on class.
      if (s.dataset.view === "activity-temp") return;
      s.classList.toggle("on", s.dataset.view === view);
    });
    if (view !== "activity") stopSSE();
    if (view !== "topology") topoTeardown();
    (RENDER[view] || function () {})();
  }

  // =========================================================================
  // WIRING
  // =========================================================================

  document.addEventListener("DOMContentLoaded", function () {
    // Theme toggle: flips html[data-theme] and persists. The inline head
    // script applies the stored value pre-paint; this is the runtime flip.
    $("#themeToggle").addEventListener("click", function () {
      var root = document.documentElement;
      var light = root.getAttribute("data-theme") !== "light";
      if (light) root.setAttribute("data-theme", "light");
      else root.removeAttribute("data-theme");
      try { localStorage.setItem("mootmgr-theme", light ? "light" : "dark"); } catch (e) {}
    });

    $$(".navitem").forEach((b) => b.addEventListener("click", () => show(b.dataset.view)));
    $("#activityFilter").addEventListener("input", paintActivity);

    $$(".chiprow button").forEach(function (btn) {
      btn.setAttribute("aria-pressed", btn.classList.contains("active") ? "true" : "false");
      btn.addEventListener("click", function () {
        kindFilter = this.dataset.kind || null;
        $$(".chiprow button").forEach(function (b) {
          b.classList.toggle("chip-on", b === btn);
          b.classList.toggle("active", b === btn);
          b.setAttribute("aria-pressed", b === btn ? "true" : "false");
        });
        paintActivity();
      });
    });
    const allChip = $(".chiprow button[data-kind='']");
    if (allChip) { allChip.classList.add("chip-on"); allChip.setAttribute("aria-pressed", "true"); }

    $("#ssePauseBtn").addEventListener("click", function () {
      ssePaused = !ssePaused;
      this.textContent = ssePaused ? "Resume live tail" : "Pause live tail";
      if (ssePaused) stopSSE(); else startSSE();
    });
    $("#pipelineEstate").addEventListener("change", renderPipeline);
    $("#topoEstate").addEventListener("change", renderTopology);
    $("#topoReset").addEventListener("click", renderTopology);
    // L4 strata toggle — flips 3D depth on/off; Three.js geometry is
    // rebuilt to update z-coordinates. The running rAF loop renders
    // the new positions on its next frame.
    $("#topoDimToggle").addEventListener("click", function () {
      brain3D = !brain3D;
      this.setAttribute("aria-pressed", brain3D ? "true" : "false");
      buildBrainPoints();
      buildBrainLines();
    });
    // L5 playback controls.
    $("#topoPlayBtn").addEventListener("click", topoPlayToggle);
    $("#topoPlayWindow").addEventListener("change", topoPlayWindowChange);

    show("overview");
    // Refresh the Overview on a slow cadence — top-bar stays current without hammering the store.
    setInterval(function () {
      const active = $(".view.on");
      if (active && active.dataset.view === "overview") renderOverview();
    }, 5000);
  });
})();
