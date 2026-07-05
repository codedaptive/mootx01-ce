/*
  moot-mgr read-plane dashboard logic.

  Vanilla JS — no frameworks, no CDN. All data comes from the resident host's
  loopback GET /api/* endpoints. This script issues ONLY reads (GET + the SSE
  GET /api/events?stream=1); it never POSTs to the control surface — the
  dashboard is read-only (GUI SPEC §2.1).

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
    panelHead(addrPanel, "Active Lattice Addresses", pending ? "requires ARIA_MCP" : addrs.length + " addresses · sorted by item count");
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
  // When /api/graph returns structurePending the synthetic graph is built
  // from event noun-type distributions — giving the visualization life while
  // real VizGraph structure accumulates in the autonomic governor's recipe
  // runs. The honest pending overlay is shown on top; it does not hide the
  // brain canvas underneath.
  //
  // Content-safety invariant: only metadata (counts, enums, ISO-8601
  // timestamps, identifiers) crosses the wire — never rung/memory content.
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

  // Canvas2D brain renderer state
  let brainCanvas = null, brainCtx = null;
  let brainNodes = [], brainEdges = [], brainNodeMap = Object.create(null);
  let brainAnimId = null, brainT = 0;
  let brainW = 0, brainH = 0;       // current logical canvas dimensions (updated on resize)
  let brainResizeObs = null;         // ResizeObserver — disconnected in stopBrainAnimation
  // Zoom state — lerped each frame toward target values.
  let brainZoomScale = 1, brainZoomX = 0, brainZoomY = 0;
  let brainZoomTS = 1, brainZoomTX = 0, brainZoomTY = 0; // target
  let brainZoomedNode = null;        // currently zoomed node (white ring + zoom in)
  let brainClickHandler = null;      // stored so stopBrainAnimation can remove it
  let brainKeyHandler = null;
  // Selection state — set by selectBrainNode(); drives neighbor highlighting.
  let brainSelectedNode = null;
  let brainHop1 = Object.create(null);    // id → true for 1-hop neighbors of selected node
  let brainHop2 = Object.create(null);    // id → true for 2-hop neighbors of selected node
  let brainAdjacency = Object.create(null);  // id → [neighbor ids] — built once from brainEdges
  // L4 strata (3D) state — toggled by #topoDimToggle. 2D is the default; all
  // 2D behavior is unchanged when off (brainProject is the identity then).
  let brain3D = false;
  // Drag-to-orbit state (3D only): yaw/pitch offsets set while dragging,
  // spring back to the fixed reading angle on release. dragging suppresses
  // the click-select that fires after mouseup.
  let brainOrbit = { yaw: 0, pitch: 0, tyaw: 0, tpitch: 0, dragging: false, moved: 0 };
  // Orbit handler refs — stored so stopBrainAnimation can detach them
  // (startBrainAnimation runs on every topology render; without removal the
  // window-level listeners would accumulate).
  let brainOrbitDown = null, brainOrbitMove = null, brainOrbitUp = null;
  let brainDrawOrder = [];  // painter-sorted node list (deepest first in 3D)
  let brainEdgesDraw = [];  // painter-sorted edge list (deepest first in 3D)
  // L3 lobe labels — community rank (lobe index) → FDC label string. Built by
  // buildRealBrainNodes from the proxy's enriched communities []{id,label,size};
  // empty on the synthetic path (synthetic lobes carry no real community).
  let brainLobeLabels = Object.create(null);
  // Content picker (community filter) state. Keys are CONTENT identities —
  // the community's FDC label, or the '(unlabeled)' / 'fragments' buckets —
  // because Louvain ids renumber on every governor cycle while labels are
  // stable. null = no filter (all visible); a Set fades non-members to 8%.
  // Module-level so the selection survives re-renders and snapshot refreshes.
  let topoCommFilter = null;
  // Picker rows for the current real-data build: [{key, label, size, cIdx}].
  let topoCommRows = [];
  // Lobe rank → content key, for hull/label fading.
  let brainLobeKey = Object.create(null);
  // The full real dataset, retained so the content picker can re-render a
  // SUBSET: filtering hides deselected communities entirely and re-lays-out
  // the selected ones to fill the canvas (solo "Business" → its nodes get
  // the whole stage). {rawNodes, rawEdges, communities, W, H, container}.
  let topoRealData = null;
  // Content key per community id for the CURRENT snapshot (rebuilt each
  // load); used to filter raw nodes before layout.
  let topoCommKeyById = Object.create(null);
  // Stable palette: content key → palette index, assigned ONCE from the
  // full dataset's size ranking so hues do not reshuffle on every filter
  // toggle or snapshot refresh.
  let topoCommPaletteByKey = Object.create(null);
  // community index → [nodes] pools — L5 estate-hash pulse fallback target.
  let brainCommPools = Object.create(null);
  // Effective "now" for recency brightness + the L5 alive(t) filter. Wall clock
  // normally; frozen to the playhead timestamp while playback is active.
  let brainNowMs = 0;
  // L5 radar-loop playback state. active = a playback session holds the playhead
  // (playing or paused mid-loop); playing = the step timer is running.
  let topoPlay = { active: false, playing: false, idx: 0, timer: null, playheadMs: 0 };
  let topoPlayEvents = [];  // /api/events parsed + sorted ascending by ts

  // Twelve community colors — one per lobe / cluster.
  const BRAIN_COMM_COLORS = [
    [255, 140,   0], [58, 180, 255], [180, 120, 255], [  0, 210, 140],
    [255,  80, 120], [255, 200,  60], [100, 200, 255], [255, 140,  80],
    [140, 200, 255], [200, 160, 255], [ 80, 220, 160], [255, 120, 160],
  ];

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

  // Generate a synthetic brain graph from event noun-type distributions.
  // N nodes across 12 community lobes — weighted by observed noun-type ratios.
  function synthBrainNodes(events, W, H) {
    var NUM_COMM = 12;
    var totalNodes = Math.min(1500, Math.max(200, events.length * 3 + 300));
    var perCommFrac = [0.15, 0.13, 0.11, 0.10, 0.09, 0.08, 0.08, 0.07, 0.06, 0.05, 0.04, 0.04];

    // Build noun-type probability distribution from observed events.
    var nc = [0, 0, 0, 0, 0, 0, 0, 0];
    events.forEach(function (ev) { if (ev.nounType >= 0 && ev.nounType < 8) nc[ev.nounType]++; });
    var evTotal = Math.max(1, nc.reduce(function (s, v) { return s + v; }, 0));
    var ratios = nc.map(function (v) { return v / evTotal; });
    // Floor: drawers are always the majority neuron type.
    if (ratios[0] < 0.58) {
      var excess = 0.58 - ratios[0];
      var rest = ratios.slice(1).reduce(function (s, v) { return s + v; }, 0);
      ratios[0] = 0.58;
      if (rest > 0) {
        for (var i = 1; i < 8; i++) ratios[i] = Math.max(0, ratios[i] * (1 - excess / rest));
      }
    }

    var centers = brainCenters(NUM_COMM, W, H);
    var nodes = [];
    var id = 0;

    for (var c = 0; c < NUM_COMM; c++) {
      var count = Math.round(totalNodes * perCommFrac[c]);
      var spread = 22 + count * 0.14;
      var ox = centers[c].x, oy = centers[c].y;

      for (var j = 0; j < count; j++) {
        var angle = Math.random() * Math.PI * 2;
        var dist = Math.abs(brainGauss()) * spread;

        // Pick noun type by cumulative probability.
        var nounType = 0;
        var r = Math.random(), cum = 0;
        for (var n = 0; n < 8; n++) { cum += ratios[n]; if (r < cum) { nounType = n; break; } }

        var sx = Math.max(20, Math.min(W - 20, ox + Math.cos(angle) * dist));
        var sy = Math.max(20, Math.min(H - 20, oy + Math.sin(angle) * dist));
        nodes.push({
          id: id++,
          x: sx, y: sy,
          ax: sx, ay: sy, vx: 0, vy: 0,  // physics anchor + velocity
          community: c,
          nounType: nounType,
          centrality: Math.pow(Math.random(), 2.6), // skewed toward low centrality
          breathPhase: Math.random() * Math.PI * 2,
          pulseOrange: 0,   // capture pulse magnitude 0..1 — decays over ~1s
          glowBlue: 0,      // think glow magnitude 0..1 — decays over ~10s
          anomaly: Math.random() < 0.011,
        });
      }
    }
    return nodes;
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

    function pushNode(n, x, y, cIdx, isLobe, commKey, colorIdx) {
      // Parse wire timestamps once at build. lastMs drives L2 recency
      // brightness and (preferred) the L4 dormancy depth; createdMs is the
      // birth instant for the L5 alive(t) filter; deadMs (tombstonedTs) hides
      // the entity in live view and ends its playback lifespan.
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
        // Community hue for the node fill (encoding rule: communityId → hue).
        // Real drawers are all nounType 0, so without this the whole estate
        // renders in the drawer style's uniform white.
        rgb: BRAIN_COMM_COLORS[(colorIdx !== undefined ? colorIdx : cIdx) % BRAIN_COMM_COLORS.length],
        nounType: n.nounType || 0,
        centrality: n.centrality || 0,
        breathPhase: Math.random() * Math.PI * 2,
        pulseOrange: 0,
        glowBlue: 0,
        anomaly: !!n.anomaly,
        lastMs: lastMs,
        createdMs: createdMs,
        deadMs: deadMs,
      };
      node.ax = node.x; node.ay = node.y;
      nodes.push(node);
    }

    // L3: record the FDC label for each community that earned a lobe.
    // brainLobeLabels keys are the lobe rank (the node `community` index used
    // on the lobe path), values are the proxy's enriched label strings.
    // Null/empty labels are skipped — drawLobeLabels draws nothing for them.
    brainLobeLabels = Object.create(null);
    lobeIds.forEach(function (cid, rank) {
      var meta = (communities || []).find(function (c) { return String(c.id) === String(cid); });
      if (meta && meta.label) brainLobeLabels[rank] = meta.label;
    });

    // Content keys for the picker: the community's FDC label when present;
    // unlabeled lobes bucket under '(unlabeled)'; sub-lobe fragments bucket
    // under 'fragments'. Labels are the stable identity across snapshots
    // (Louvain ids renumber every governor cycle).
    function contentKey(cid, members) {
      var meta = (communities || []).find(function (c) { return String(c.id) === String(cid); });
      if (meta && meta.label) return meta.label;
      return members.length >= MIN_LOBE_SIZE ? "(unlabeled)" : "fragments";
    }

    // Picker rows: one per labeled lobe (size desc), then the two buckets.
    brainLobeKey = Object.create(null);
    var rowByKey = Object.create(null);
    function addRow(key, size, cIdx, isBucket) {
      if (!rowByKey[key]) {
        rowByKey[key] = { key: key, size: 0, cIdx: cIdx, bucket: !!isBucket };
      }
      rowByKey[key].size += size;
    }

    // Lobe communities: members gathered around a shared center.
    lobeIds.forEach(function (cid, rank) {
      var members = byId[cid];
      var key = contentKey(cid, members);
      brainLobeKey[rank] = key;
      var cIdx = paletteFor(key, rank % BRAIN_COMM_COLORS.length);
      if (!isSubset) addRow(key, members.length, cIdx, key === "(unlabeled)");
      var spread = Math.max(28, members.length * 0.18);
      var center = centers[rank];
      members.forEach(function (n) {
        var angle = Math.random() * Math.PI * 2;
        var dist = Math.abs(brainGauss()) * spread;
        pushNode(n, center.x + Math.cos(angle) * dist,
                    center.y + Math.sin(angle) * dist, rank, true, key, cIdx);
      });
    });

    // Periphery fragments: each fragment gets one random anchor across the
    // canvas with its members placed tightly around it, so a tunnel-linked
    // pair stays a visible pair. Color cycles the palette per fragment.
    var lobeSet = Object.create(null);
    lobeIds.forEach(function (cid) { lobeSet[cid] = true; });
    ranked.forEach(function (cid, rank) {
      if (lobeSet[cid]) return;
      var members = byId[cid];
      var key = contentKey(cid, members);
      if (!isSubset) addRow(key, members.length, -1, true);
      var ax = 20 + Math.random() * (W - 40);
      var ay = 20 + Math.random() * (H - 40);
      var cIdx = paletteFor(key, rank % BRAIN_COMM_COLORS.length);
      members.forEach(function (n, mi) {
        var angle = (mi / members.length) * Math.PI * 2 + Math.random() * 0.8;
        var dist = members.length > 1 ? 6 + Math.random() * 8 : 0;
        pushNode(n, ax + Math.cos(angle) * dist, ay + Math.sin(angle) * dist, cIdx, false, key, cIdx);
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

  // Sparse synthetic edges — intra-community tunnel synapses and sparse
  // inter-community kgFact bridges (corpus callosum).
  function synthBrainEdges(nodes) {
    var edges = [];
    var byComm = Object.create(null);
    nodes.forEach(function (n) { (byComm[n.community] = byComm[n.community] || []).push(n.id); });

    // Target average degree ~5 per node (2 × edges / nodes = 5 → multiplier 2.5).
    // The previous 0.55 multiplier gave degree ~1.1, making hop-1 always a single node.
    Object.values(byComm).forEach(function (members) {
      var count = Math.floor(members.length * 2.5);
      for (var i = 0; i < count; i++) {
        var s = members[Math.floor(Math.random() * members.length)];
        var t = members[Math.floor(Math.random() * members.length)];
        if (s !== t) edges.push({ src: s, tgt: t, type: "tunnel", w: 0.3 + Math.random() * 0.7 });
      }
    });

    var comms = Object.keys(byComm);
    for (var i = 0; i < comms.length; i++) {
      for (var j = i + 1; j < comms.length; j++) {
        if (Math.random() < 0.11) {
          var sm = byComm[comms[i]], tm = byComm[comms[j]];
          edges.push({
            src: sm[Math.floor(Math.random() * sm.length)],
            tgt: tm[Math.floor(Math.random() * tm.length)],
            type: "kgFact", w: 0.07 + Math.random() * 0.18,
          });
        }
      }
    }
    return edges;
  }

  // Start the Canvas2D animation loop inside the topo-canvas container div.
  // Canvas gets explicit pixel CSS dimensions (not 100%) so the coordinate space
  // exactly matches what getBoundingClientRect reports — preventing the "nodes packed
  // into a sub-rectangle" bounding-box appearance. ResizeObserver keeps them in sync.
  // L2 community-aware force micro-sim. Anchor springs hold the lobe /
  // periphery layout; edge springs pull tunnel-linked nodes toward a short
  // rest length so connected memory visibly drifts together and settles;
  // damping keeps the motion organic rather than oscillating. O(N + E) per
  // frame — no pairwise repulsion (the anchor scatter already provides
  // separation at this density).
  function brainPhysicsStep(dt) {
    var K_ANCHOR = 1.6;   // spring toward layout anchor (s^-2)
    var K_EDGE = 2.2;     // spring along edges (s^-2), scaled by weight
    var REST = 26;        // edge rest length, px
    var DAMP = 0.90;      // per-frame velocity retention at 60fps
    var i, e, s, t;
    for (i = 0; i < brainEdges.length; i++) {
      e = brainEdges[i];
      s = brainNodeMap[e.src]; t = brainNodeMap[e.tgt];
      if (!s || !t) continue;
      var dx = t.x - s.x, dy = t.y - s.y;
      var d = Math.sqrt(dx * dx + dy * dy) || 0.01;
      var f = K_EDGE * (d - REST) / d * (e.w || 0.5) * dt;
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

  function startBrainAnimation(container, W, H) {
    stopBrainAnimation();

    var canvas = container.querySelector("canvas");
    if (!canvas) {
      canvas = document.createElement("canvas");
      canvas.style.position = "absolute";
      canvas.style.top = "0";
      canvas.style.left = "0";
      container.appendChild(canvas);
    }
    brainCanvas = canvas;
    brainW = W;
    brainH = H;

    // Explicit pixel CSS dimensions ensure the drawn coordinate space matches display.
    // Using 100% would stretch the canvas when W/H don't match the container.
    var dpr = window.devicePixelRatio || 1;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    canvas.style.width = W + "px";
    canvas.style.height = H + "px";
    brainCtx = canvas.getContext("2d");
    brainCtx.scale(dpr, dpr);

    // Reset zoom to default view centered on the canvas.
    brainZoomScale = 1; brainZoomX = W / 2; brainZoomY = H / 2;
    brainZoomTS = 1;    brainZoomTX = W / 2; brainZoomTY = H / 2;
    brainZoomedNode = null;

    // Pre-build O(1) node lookup used by edge rendering, plus per-community
    // pools used by the L5 estate-hash pulse fallback.
    brainNodeMap = Object.create(null);
    brainCommPools = Object.create(null);
    brainNodes.forEach(function (n) {
      brainNodeMap[n.id] = n;
      (brainCommPools[n.community] = brainCommPools[n.community] || []).push(n);
    });

    // Painter-sorted draw lists (depends on brainNodeMap, so built here).
    brainUpdateDrawOrder();

    // Pre-build undirected adjacency map for O(1) hop-1/hop-2 neighbor lookups.
    brainAdjacency = Object.create(null);
    brainEdges.forEach(function (e) {
      (brainAdjacency[e.src] = brainAdjacency[e.src] || []).push(e.tgt);
      (brainAdjacency[e.tgt] = brainAdjacency[e.tgt] || []).push(e.src);
    });

    // Drag-to-orbit (3D only): horizontal drag yaws the camera ±~17°,
    // vertical drag tilts the strata pitch ±0.10; both spring back to the
    // reading angle on release (lerp in the frame loop). A drag past 5px
    // suppresses the click-select that fires on mouseup.
    brainOrbit = { yaw: 0, pitch: 0, tyaw: 0, tpitch: 0, dragging: false, moved: 0 };
    var orbLastX = 0, orbLastY = 0;
    brainOrbitDown = function (e) {
      if (!brain3D) return;
      brainOrbit.dragging = true;
      brainOrbit.moved = 0;
      orbLastX = e.clientX; orbLastY = e.clientY;
    };
    brainOrbitMove = function (e) {
      if (!brainOrbit.dragging) return;
      var dx = e.clientX - orbLastX, dy = e.clientY - orbLastY;
      orbLastX = e.clientX; orbLastY = e.clientY;
      brainOrbit.moved += Math.abs(dx) + Math.abs(dy);
      brainOrbit.tyaw = Math.max(-0.3, Math.min(0.3, brainOrbit.tyaw + dx * 0.003));
      brainOrbit.tpitch = Math.max(-0.10, Math.min(0.10, brainOrbit.tpitch + dy * 0.0006));
    };
    brainOrbitUp = function () {
      if (!brainOrbit.dragging) return;
      brainOrbit.dragging = false;
      // Spring back to the reading angle.
      brainOrbit.tyaw = 0;
      brainOrbit.tpitch = 0;
    };
    canvas.addEventListener("mousedown", brainOrbitDown);
    window.addEventListener("mousemove", brainOrbitMove);
    window.addEventListener("mouseup", brainOrbitUp);

    // Click: zoom in on nearest node + select it; click same node or background to deselect.
    brainClickHandler = function (e) {
      // A completed orbit drag is not a selection click.
      if (brainOrbit.moved > 5) { brainOrbit.moved = 0; return; }
      var node = brainHitTest(e.offsetX, e.offsetY);
      if (node && node !== brainZoomedNode) {
        brainZoomedNode = node;
        brainZoomTS = 3.5;
        // Zoom centers on draw-space coordinates: in 3D that is the projected
        // position (the zoom transform wraps the projected scene).
        var zp = brainProject(node);
        brainZoomTX = zp.x;
        brainZoomTY = zp.y;
        selectBrainNode(node);
      } else {
        brainZoomedNode = null;
        brainZoomTS = 1;
        brainZoomTX = brainW / 2;
        brainZoomTY = brainH / 2;
        selectBrainNode(null);
      }
    };
    canvas.addEventListener("click", brainClickHandler);

    // Escape: zoom out and clear selection.
    brainKeyHandler = function (e) {
      if (e.key === "Escape" && brainZoomedNode) {
        brainZoomedNode = null;
        brainZoomTS = 1;
        brainZoomTX = brainW / 2;
        brainZoomTY = brainH / 2;
        selectBrainNode(null);
      }
    };
    document.addEventListener("keydown", brainKeyHandler);

    // ResizeObserver: scale node positions + canvas dimensions when container resizes.
    if (typeof ResizeObserver !== "undefined") {
      brainResizeObs = new ResizeObserver(function (entries) {
        if (!brainCanvas) return;
        var entry = entries[0];
        var newW = entry.contentRect.width;
        var newH = entry.contentRect.height;
        if (newW < 10 || newH < 10) return;
        var sx = newW / brainW, sy = newH / brainH;
        brainNodes.forEach(function (n) {
          n.x *= sx; n.y *= sy;
          n.ax *= sx; n.ay *= sy;  // physics anchors track the layout scale
        });
        // Translate zoom focus proportionally.
        brainZoomX *= sx; brainZoomY *= sy;
        brainZoomTX *= sx; brainZoomTY *= sy;
        brainW = newW; brainH = newH;
        var d = window.devicePixelRatio || 1;
        brainCanvas.width = Math.round(newW * d);
        brainCanvas.height = Math.round(newH * d);
        brainCanvas.style.width = newW + "px";
        brainCanvas.style.height = newH + "px";
        brainCtx.setTransform(d, 0, 0, d, 0, 0);
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
      // Lerp zoom toward target each frame (smooth ease-out approach).
      var ease = 1 - Math.pow(0.92, dt * 60);
      brainZoomScale += (brainZoomTS - brainZoomScale) * ease;
      brainZoomX += (brainZoomTX - brainZoomX) * ease;
      brainZoomY += (brainZoomTY - brainZoomY) * ease;
      // Orbit lerp: while dragging, track the hand closely; after release,
      // a slower spring carries the camera back to the reading angle.
      var oease = brainOrbit.dragging ? ease : 1 - Math.pow(0.96, dt * 60);
      brainOrbit.yaw += (brainOrbit.tyaw - brainOrbit.yaw) * oease;
      brainOrbit.pitch += (brainOrbit.tpitch - brainOrbit.pitch) * oease;
      drawBrainFrame(brainCtx, brainW, brainH);
      brainAnimId = requestAnimationFrame(frame);
    }
    brainAnimId = requestAnimationFrame(frame);
  }

  // Find the nearest node to canvas CSS coordinates (ex, ey), accounting for zoom.
  // Returns the node or null if nothing is within the click radius.
  function brainHitTest(ex, ey) {
    // Invert zoom transform: screen coord → draw-space coord.
    // drawn_x = (draw.x - brainZoomX) * scale + W/2  →  draw.x = (ex - W/2) / scale + brainZoomX
    var logX = (ex - brainW / 2) / brainZoomScale + brainZoomX;
    var logY = (ey - brainH / 2) / brainZoomScale + brainZoomY;
    var HIT = 18 / brainZoomScale; // 18px hit radius in screen space
    var best = null, bestD = HIT;
    brainNodes.forEach(function (n) {
      // Hidden entities (dead in live view, unborn/dead at the playhead)
      // are not drawn, so they must not capture clicks either.
      if (brainHidden(n)) return;
      // Compare against the projected position — in 3D nodes are drawn at
      // their perspective coordinates, not their logical layout coordinates.
      var p = brainProject(n);
      var dx = p.x - logX, dy = p.y - logY;
      var d = Math.sqrt(dx * dx + dy * dy);
      if (d < bestD) { best = n; bestD = d; }
    });
    return best;
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

  function stopBrainAnimation() {
    if (brainAnimId) { cancelAnimationFrame(brainAnimId); brainAnimId = null; }
    if (brainResizeObs) { brainResizeObs.disconnect(); brainResizeObs = null; }
    if (brainCanvas && brainClickHandler) brainCanvas.removeEventListener("click", brainClickHandler);
    if (brainKeyHandler) document.removeEventListener("keydown", brainKeyHandler);
    if (brainCanvas && brainOrbitDown) brainCanvas.removeEventListener("mousedown", brainOrbitDown);
    if (brainOrbitMove) window.removeEventListener("mousemove", brainOrbitMove);
    if (brainOrbitUp) window.removeEventListener("mouseup", brainOrbitUp);
    brainOrbitDown = null; brainOrbitMove = null; brainOrbitUp = null;
    brainClickHandler = null; brainKeyHandler = null;
    brainZoomedNode = null; brainZoomScale = 1; brainZoomTS = 1;
    brainSelectedNode = null; brainHop1 = Object.create(null); brainHop2 = Object.create(null); brainAdjacency = Object.create(null);
    brainCanvas = null; brainCtx = null;
  }

  // Decay pulse and glow magnitudes each frame — keeps magnitudes from needing
  // explicit timers alongside the animation loop.
  function tickBrainDecay(dt) {
    brainNodes.forEach(function (n) {
      if (n.pulseOrange > 0) n.pulseOrange = Math.max(0, n.pulseOrange - dt * 1.1);
      if (n.glowBlue > 0)    n.glowBlue    = Math.max(0, n.glowBlue    - dt * 0.075);
    });
  }

  // L2 recency brightness — alpha multiplier from how recently the node was
  // active. 1.0 under an hour old, exponential decay (tau = 7 days) toward a
  // 0.35 floor; the floor is effectively reached past 30 days. Nodes without
  // a lastActiveTs (all synthetic nodes) stay at full brightness.
  var BRAIN_HOUR_MS = 3600000;
  var BRAIN_DAY_MS = 86400000;
  function recencyFactor(n, nowMs) {
    if (!n.lastMs) return 1;
    var age = nowMs - n.lastMs;
    if (age <= BRAIN_HOUR_MS) return 1;
    return 0.35 + 0.65 * Math.exp(-(age - BRAIN_HOUR_MS) / (7 * BRAIN_DAY_MS));
  }

  // L4 depth assignment — z3 ∈ [0,1] per node: newest 0 (surface), oldest 1
  // (deep). Birth instant prefers createdTs (ingest clock) over lastActiveTs.
  // Nodes without any timestamp (the synthetic path) get a stable pseudo-random
  // depth derived from breathPhase so the 3D toggle still reads as strata.
  // Two distinct time semantics:
  //   birthMs (createdMs preferred)  → the alive(t) playback filter: when the
  //                                    entity entered the estate.
  //   dormancy (lastMs preferred)    → the strata Z axis: recently-touched
  //                                    memory floats at the surface, dormant
  //                                    memory settles into the depths. This is
  //                                    the "memory sediment" reading — depth is
  //                                    how long since the drawer was active,
  //                                    not how long since it was filed.
  function brainAssignDepth(nowMs) {
    var minA = Infinity, maxA = -Infinity;
    brainNodes.forEach(function (n) {
      n.birthMs = n.createdMs || n.lastMs || null;
      n.dormMs = n.lastMs || n.createdMs || null;
      if (n.dormMs) {
        var a = nowMs - n.dormMs;
        if (a < minA) minA = a;
        if (a > maxA) maxA = a;
      }
    });
    var range = Math.max(1, maxA - minA);
    brainNodes.forEach(function (n) {
      n.z3 = n.dormMs
        ? (nowMs - n.dormMs - minA) / range
        : n.breathPhase / (Math.PI * 2);
    });
  }

  // L4 perspective projection constants. PERSP is the camera distance and
  // DEPTH the pixel extent z3 maps onto — together they give the deepest
  // stratum a scale of PERSP/(PERSP+DEPTH) ≈ 0.57.
  var BRAIN_PERSP = 700;
  var BRAIN_DEPTH = 520;

  // Project a node's logical (x, y, z3) to draw coordinates. Identity in 2D.
  // 3D: fixed tilt camera looking down ~35° — points shrink and converge
  // toward an upper-middle vanishing center while deeper strata are pushed
  // down (tilt factor 0.22·H) and sway ±3° with time for parallax. Drag adds
  // a user yaw (±~17°) and pitch (±0.1 tilt) on top, springing back to the
  // reading angle on release (the orbit lerp lives in the frame loop).
  function brainProject(n) {
    if (!brain3D) return { x: n.x, y: n.y, s: 1 };
    var z = n.z3 || 0;
    var s = BRAIN_PERSP / (BRAIN_PERSP + z * BRAIN_DEPTH);
    var vx = brainW / 2, vy = brainH * 0.32;
    var drift = Math.sin(brainT * 0.15) * (3 * Math.PI / 180) + brainOrbit.yaw;
    return {
      x: vx + (n.x - vx) * s + drift * z * brainW * 0.35,
      y: vy + (n.y - vy) * s + z * brainH * (0.22 + brainOrbit.pitch),
      s: s,
    };
  }

  // Deepest endpoint of an edge — used for painter sorting and depth fog.
  function brainEdgeZ(e) {
    var s = brainNodeMap[e.src], t = brainNodeMap[e.tgt];
    return Math.max(s ? (s.z3 || 0) : 0, t ? (t.z3 || 0) : 0);
  }

  // Rebuild painter-sorted draw lists. In 3D the deepest nodes/edges draw
  // first so surface strata occlude them; in 2D the original arrays are used
  // unsorted. Requires brainNodeMap (called after startBrainAnimation builds
  // it, and again from the #topoDimToggle handler).
  function brainUpdateDrawOrder() {
    if (brain3D) {
      brainDrawOrder = brainNodes.slice().sort(function (a, b) { return (b.z3 || 0) - (a.z3 || 0); });
      brainEdgesDraw = brainEdges.slice().sort(function (a, b) { return brainEdgeZ(b) - brainEdgeZ(a); });
    } else {
      brainDrawOrder = brainNodes;
      brainEdgesDraw = brainEdges;
    }
  }

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


  function drawBrainFrame(ctx, W, H) {
    ctx.clearRect(0, 0, W, H);
    // Effective "now": the playhead timestamp while playback is active (so
    // recency brightness and the alive(t) filter replay history), wall clock
    // otherwise.
    brainNowMs = topoPlay.active ? topoPlay.playheadMs : Date.now();
    // Cache per-frame projected coordinates (px, py) and projection scale (ps)
    // on every node — hulls, edges, nodes, and rings all draw from these.
    // In 2D the projection is the identity (px = x, ps = 1).
    brainNodes.forEach(function (n) {
      var p = brainProject(n);
      n.px = p.x; n.py = p.y; n.ps = p.s;
    });
    // Apply zoom transform: center on brainZoomX/Y at current scale.
    ctx.save();
    ctx.translate(W / 2 - brainZoomX * brainZoomScale, H / 2 - brainZoomY * brainZoomScale);
    ctx.scale(brainZoomScale, brainZoomScale);
    drawCommHulls(ctx);
    drawBrainEdges(ctx);
    drawBrainNodes(ctx);
    drawLobeLabels(ctx);
    // White highlight ring on the zoomed/selected node — drawn after nodes so it sits on top.
    if (brainZoomedNode) {
      var n = brainZoomedNode;
      var ns = nounStyle(n.nounType);
      var r = (ns.r + n.centrality * 5) * n.ps * (0.82 + 0.18 * Math.sin(brainT * 0.72 + n.breathPhase));
      ctx.beginPath();
      ctx.arc(n.px, n.py, r + 4 / brainZoomScale, 0, Math.PI * 2);
      ctx.strokeStyle = "rgba(255,255,255,0.7)";
      ctx.lineWidth = 1.5 / brainZoomScale;
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(n.px, n.py, r + 8 / brainZoomScale, 0, Math.PI * 2);
      ctx.strokeStyle = "rgba(255,255,255,0.25)";
      ctx.lineWidth = 1 / brainZoomScale;
      ctx.stroke();
    }
    // Accent rings on neighbor nodes: orange for hop-1, faint orange for hop-2.
    if (brainSelectedNode) {
      Object.keys(brainHop1).forEach(function (id) {
        var nd = brainNodeMap[id];
        if (!nd) return;
        var ns2 = nounStyle(nd.nounType);
        var nr = (ns2.r + nd.centrality * 5) * nd.ps * (0.82 + 0.18 * Math.sin(brainT * 0.72 + nd.breathPhase));
        ctx.beginPath();
        ctx.arc(nd.px, nd.py, nr + 3 / brainZoomScale, 0, Math.PI * 2);
        ctx.strokeStyle = "rgba(255,140,0,0.80)";
        ctx.lineWidth = 1.2 / brainZoomScale;
        ctx.stroke();
      });
      Object.keys(brainHop2).forEach(function (id) {
        var nd = brainNodeMap[id];
        if (!nd) return;
        var ns2 = nounStyle(nd.nounType);
        var nr = (ns2.r + nd.centrality * 5) * nd.ps * (0.82 + 0.18 * Math.sin(brainT * 0.72 + nd.breathPhase));
        ctx.beginPath();
        ctx.arc(nd.px, nd.py, nr + 2 / brainZoomScale, 0, Math.PI * 2);
        ctx.strokeStyle = "rgba(255,140,0,0.35)";
        ctx.lineWidth = 0.8 / brainZoomScale;
        ctx.stroke();
      });
    }
    ctx.restore();
  }

  // Feathered radial-gradient blobs behind each community lobe.
  // Periphery fragments (lobe === false on the real-data path) are skipped:
  // they share palette indexes with lobes but are scattered canvas-wide, so
  // including them would paint phantom hulls over empty space. Synthetic
  // nodes carry no lobe flag and keep their hulls.
  function drawCommHulls(ctx) {
    var byComm = Object.create(null);
    brainNodes.forEach(function (n) {
      if (n.lobe === false) return;
      (byComm[n.community] = byComm[n.community] || []).push(n);
    });

    Object.keys(byComm).forEach(function (c) {
      var members = byComm[c];
      var ci = parseInt(c, 10);
      // Centroid/spread from projected coordinates so hulls track the 3D view.
      var cx = members.reduce(function (s, n) { return s + n.px; }, 0) / members.length;
      var cy = members.reduce(function (s, n) { return s + n.py; }, 0) / members.length;
      var spread = members.reduce(function (s, n) { return s + Math.hypot(n.px - cx, n.py - cy); }, 0) / members.length;
      var r = Math.min(spread * 1.85, 200);

      // Hull tint follows the members' stable content hue (n.rgb), not the
      // layout rank — ranks reshuffle under content-filter re-layouts.
      var col = members[0].rgb || BRAIN_COMM_COLORS[ci % BRAIN_COMM_COLORS.length];
      var grad = ctx.createRadialGradient(cx, cy, 0, cx, cy, r);
      grad.addColorStop(0,   "rgba(" + col[0] + "," + col[1] + "," + col[2] + ",0.065)");
      grad.addColorStop(0.5, "rgba(" + col[0] + "," + col[1] + "," + col[2] + ",0.03)");
      grad.addColorStop(1,   "rgba(" + col[0] + "," + col[1] + "," + col[2] + ",0)");
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.fillStyle = grad;
      ctx.fill();
    });
  }

  // Thin edge lines — three style classes:
  //   tunnel : gray    rgba(220,224,240,α)  — explicit structural link (weight 1.0)
  //   kgFact : blue    rgba(58,180,255,α)   — derived shared-subject bond (weight 0.3)
  //   lattice: amber   rgba(255,180,60,α)   — derived classification bond (weight 0.2)
  //
  // When a node is selected, edges in the selected cluster brighten; edges
  // touching 2-hop neighbors are medium; all others near-invisible. Hop-1 on
  // a lattice hub highlights its entire topic group — intended behavior.
  //
  // The final alpha is then weight-scaled (L2: heavier edges read stronger),
  // depth-fogged in 3D, and edges to not-yet-born nodes are hidden during
  // playback (L5 alive(t) filter).
  function drawBrainEdges(ctx) {
    ctx.lineWidth = 0.55;
    var hasSel = !!brainSelectedNode;
    var selId = hasSel ? brainSelectedNode.id : null;
    brainEdgesDraw.forEach(function (e) {
      var s = brainNodeMap[e.src], t = brainNodeMap[e.tgt];
      if (!s || !t) return;
      // L5: an edge to an unborn or dead endpoint does not exist at the
      // playhead; a tombstoned edge itself also disappears at its death time.
      if (brainHidden(s) || brainHidden(t)) return;
      if (e.deadMs && (topoPlay.active ? e.deadMs <= brainNowMs : true)) return;
      var isTunnel = e.type === "tunnel";
      // Lattice edges: faint amber — below kgFact (0.045) to maintain the
      // evidence-strength visual hierarchy (tunnel > kgFact > lattice).
      var isLattice = e.type === "lattice";
      var alpha;
      if (!hasSel) {
        alpha = isTunnel ? 0.10 : (isLattice ? 0.035 : 0.045);
      } else {
        var srcCore = e.src === selId || brainHop1[e.src];
        var tgtCore = e.tgt === selId || brainHop1[e.tgt];
        if (srcCore && tgtCore) {
          // Edge fully inside selected + hop-1 cluster: bright.
          // Lattice 0.30 vs kgFact 0.55 — preserves evidence-strength hierarchy
          // in the selected state (mirrors the ~2:1 gap from the unselected state).
          alpha = isTunnel ? 0.70 : (isLattice ? 0.30 : 0.55);
        } else if (srcCore || tgtCore || brainHop2[e.src] || brainHop2[e.tgt]) {
          // Edge touches outer ring: medium visibility
          alpha = isTunnel ? 0.20 : (isLattice ? 0.08 : 0.12);
        } else {
          // Unrelated: nearly invisible
          alpha = isTunnel ? 0.015 : (isLattice ? 0.006 : 0.008);
        }
      }
      // L2 weight encoding: scale the selection-state alpha into [0.4, 1.0]×
      // by edge weight — never to zero, so weak edges stay faintly present.
      alpha *= 0.4 + 0.6 * Math.min(1, e.w || 0);
      // L4 depth fog on the deepest endpoint, matching the node fog curve.
      if (brain3D) alpha *= 1 - 0.55 * brainEdgeZ(e);
      ctx.beginPath();
      ctx.moveTo(s.px, s.py);
      ctx.lineTo(t.px, t.py);
      ctx.strokeStyle = isTunnel
        ? "rgba(220,224,240," + alpha + ")"
        : (isLattice ? "rgba(255,180,60," + alpha + ")" : "rgba(58,180,255," + alpha + ")");
      ctx.stroke();
    });
  }

  // Draw each node: staggered breathing opacity + centrality-scaled radius +
  // bioluminescent blue glow (think) and expanding orange pulse ring (capture).
  // When a node is selected, unrelated nodes fade to 12% and hop-2 nodes to 55%.
  // Layered on top (multiplicative on alpha): L2 recency brightness, L4 depth
  // fog, and the L5 unborn ghost (×0.06, decorations suppressed). High-
  // centrality hubs (> 0.55) get a soft L2 halo. Iterates brainDrawOrder,
  // which is painter-sorted deepest-first in 3D.
  function drawBrainNodes(ctx) {
    var hasSel = !!brainSelectedNode;
    brainDrawOrder.forEach(function (n) {
      var style = nounStyle(n.nounType);
      // Community hue (the original encoding-map rule: communityId → hue).
      // Real-data nodes carry n.rgb from the community palette; synthetic
      // nodes fall back to the noun-type style (they have noun variety —
      // real drawers are all nounType 0 and would render uniformly white).
      var rgb = n.rgb || style.rgb;
      // ps scales radii with the perspective projection (1 in 2D).
      var baseR = style.r * (1 + n.centrality * 1.9) * n.ps;

      // Slow breathing: per-node staggered sine wave on alpha
      var breath = 0.82 + 0.18 * Math.sin(brainT * 0.72 + n.breathPhase);
      var alpha = style.a * breath;

      // mod accumulates the brightness modifiers shared by fill + halo:
      // selection dimming, recency, and depth fog.
      var mod = 1;
      if (hasSel) {
        if (n === brainSelectedNode || brainHop1[n.id]) {
          // Selected + direct neighbors: full brightness
        } else if (brainHop2[n.id]) {
          mod *= 0.55;
        } else {
          mod *= 0.12;
        }
      }
      // L2 recency: stale nodes dim toward the 0.35 floor. Keys off
      // brainNowMs, which is the playhead time during playback.
      mod *= recencyFactor(n, brainNowMs);
      // L4 depth fog: deeper strata fade.
      if (brain3D) mod *= 1 - 0.55 * (n.z3 || 0);
      alpha *= mod;

      // Tombstoned: hidden in live view; during playback the node vanishes
      // once the playhead passes its death time (dissolution made visible).
      if (brainDead(n)) return;

      // L5 unborn ghost: the node has not been ingested yet at the playhead.
      // Faint dot only — glow, halo, pulse, and anomaly dressing suppressed.
      if (brainUnborn(n)) {
        ctx.beginPath();
        ctx.arc(n.px, n.py, baseR, 0, Math.PI * 2);
        ctx.fillStyle = "rgba(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + "," + (alpha * 0.06) + ")";
        ctx.fill();
        return;
      }

      // Think event: blue bioluminescent glow spreads outward (~10s decay)
      if (n.glowBlue > 0.01) {
        var glowR = baseR * 5;
        var glowGrad = ctx.createRadialGradient(n.px, n.py, baseR, n.px, n.py, glowR);
        glowGrad.addColorStop(0, "rgba(58,180,255," + (n.glowBlue * 0.30) + ")");
        glowGrad.addColorStop(1, "rgba(58,180,255,0)");
        ctx.beginPath();
        ctx.arc(n.px, n.py, glowR, 0, Math.PI * 2);
        ctx.fillStyle = glowGrad;
        ctx.fill();
      }

      // L2 centrality glow: hubs above 0.55 get a soft halo in the node's own
      // color — radius and alpha both grow with centrality, capped subtle
      // (max halo alpha 0.18 before the shared brightness modifiers).
      if (n.centrality > 0.55) {
        var haloR = baseR * (2.5 + n.centrality * 3);
        var haloA = 0.18 * ((n.centrality - 0.55) / 0.45) * mod;
        var haloGrad = ctx.createRadialGradient(n.px, n.py, baseR, n.px, n.py, haloR);
        haloGrad.addColorStop(0, "rgba(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + "," + haloA + ")");
        haloGrad.addColorStop(1, "rgba(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + ",0)");
        ctx.beginPath();
        ctx.arc(n.px, n.py, haloR, 0, Math.PI * 2);
        ctx.fillStyle = haloGrad;
        ctx.fill();
      }

      var rv = rgb[0], gv = rgb[1], bv = rgb[2];
      ctx.beginPath();
      ctx.arc(n.px, n.py, baseR, 0, Math.PI * 2);

      if (n.anomaly) {
        // Anomaly: dimmer fill + dashed red-pink outline
        ctx.fillStyle = "rgba(" + rv + "," + gv + "," + bv + "," + (alpha * 0.55) + ")";
        ctx.fill();
        ctx.setLineDash([2, 2]);
        ctx.lineWidth = 0.9;
        ctx.strokeStyle = "rgba(255,80,120,0.65)";
        ctx.stroke();
        ctx.setLineDash([]);
        ctx.lineWidth = 0.55;
      } else {
        ctx.fillStyle = "rgba(" + rv + "," + gv + "," + bv + "," + alpha + ")";
        ctx.fill();
      }

      // Capture event: expanding orange pulse ring (~1s decay)
      if (n.pulseOrange > 0.01) {
        var ringR = baseR * (1 + (1 - n.pulseOrange) * 4);
        ctx.beginPath();
        ctx.arc(n.px, n.py, ringR, 0, Math.PI * 2);
        ctx.strokeStyle = "rgba(255,140,0," + (n.pulseOrange * 0.85) + ")";
        ctx.lineWidth = 1.4;
        ctx.stroke();
        ctx.lineWidth = 0.55;
      }
    });
  }

  // L3 community labels — FDC label text near each lobe centroid: uppercase,
  // letter-spaced, with a small leading dot in the lobe's palette color.
  // Sizes divide by brainZoomScale so labels hold a constant on-screen size
  // while zooming. Only communities that earned a lobe (and a non-null label
  // from the proxy) appear in brainLobeLabels; everything else draws nothing.
  function drawLobeLabels(ctx) {
    var ranks = Object.keys(brainLobeLabels);
    if (!ranks.length) return;

    // Group lobe members by community rank (projected coords already cached).
    var groups = Object.create(null);
    brainNodes.forEach(function (n) {
      if (!n.lobe || brainLobeLabels[n.community] === undefined) return;
      (groups[n.community] = groups[n.community] || []).push(n);
    });

    ctx.save();
    var fontPx = 11 / brainZoomScale;
    ctx.font = fontPx + "px ui-monospace, SFMono-Regular, Menlo, monospace";
    // letterSpacing is supported in current Chromium/WebKit canvas; harmless no-op otherwise.
    if ("letterSpacing" in ctx) ctx.letterSpacing = (1.5 / brainZoomScale) + "px";
    ctx.textBaseline = "middle";
    ctx.textAlign = "left";

    Object.keys(groups).forEach(function (rank) {
      var members = groups[rank];
      var cx = members.reduce(function (s, n) { return s + n.px; }, 0) / members.length;
      var cy = members.reduce(function (s, n) { return s + n.py; }, 0) / members.length;
      var spread = members.reduce(function (s, n) { return s + Math.hypot(n.px - cx, n.py - cy); }, 0) / members.length;
      // Sit the label just above the lobe's node cloud.
      var ly = cy - spread * 1.2 - 10 / brainZoomScale;

      var text = String(brainLobeLabels[rank]).toUpperCase();
      var dotR = 2.5 / brainZoomScale;
      var gap = 6 / brainZoomScale;
      var textW = ctx.measureText(text).width;
      var startX = cx - (dotR * 2 + gap + textW) / 2;

      // Label dot follows the members' stable content hue, matching the fill.
      var col = members[0].rgb || BRAIN_COMM_COLORS[parseInt(rank, 10) % BRAIN_COMM_COLORS.length];
      ctx.beginPath();
      ctx.arc(startX + dotR, ly, dotR, 0, Math.PI * 2);
      ctx.fillStyle = "rgba(" + col[0] + "," + col[1] + "," + col[2] + ",0.65)";
      ctx.fill();

      ctx.fillStyle = "rgba(232,234,240,0.4)";
      ctx.fillText(text, startX + dotR * 2 + gap, ly);
    });
    ctx.restore();
  }

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

    var list = el("div", "cp-list");
    topoCommRows.forEach(function (row) {
      var on = !topoCommFilter || topoCommFilter.has(row.key);
      var line = el("div", "cp-row" + (on ? "" : " off"));

      var box = el("span", "cp-box" + (on ? " on" : ""));
      box.setAttribute("role", "checkbox");
      box.setAttribute("aria-checked", on ? "true" : "false");

      var dot = el("span", "cp-dot");
      if (row.cIdx >= 0) {
        var col = BRAIN_COMM_COLORS[row.cIdx % BRAIN_COMM_COLORS.length];
        dot.style.background = "rgb(" + col[0] + "," + col[1] + "," + col[2] + ")";
      } else {
        dot.style.background = "rgba(232,234,240,0.35)";
      }

      var label = el("span", "cp-label", row.key);
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
    topoHideCornerElements();
  }

  async function renderTopology() {
    topoTeardown();
    const container = $("#topoCanvas");
    const estate = $("#topoEstate").value || "";

    let g = { structurePending: true, nodes: [], edges: [], analytics: [], communities: [] };
    try {
      g = await getJSON("/api/graph" + (estate ? "?estate=" + encodeURIComponent(estate) : ""));
    } catch (_) {
      // Degrade to synthetic visualization when the graph endpoint is unreachable.
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

    // Fetch recent events: they weight the synthetic node noun-type
    // distribution AND feed the L5 radar-loop playback timeline.
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

    // Build node + edge sets: real VizGraph structure when available, synthetic otherwise.
    const hasRealStructure = !g.structurePending && (g.nodes || []).length > 0;
    if (hasRealStructure) {
      // Retain the full dataset + community→content-key map so the content
      // picker can re-layout a SUBSET without refetching.
      topoRealData = { rawNodes: g.nodes, rawEdges: g.edges || [],
                       communities: g.communities || [], W: W, H: H,
                       container: container };
      topoCommKeyById = Object.create(null);
      const sizeById = Object.create(null);
      g.nodes.forEach(function (n) {
        if (n.communityId >= 0) sizeById[n.communityId] = (sizeById[n.communityId] || 0) + 1;
      });
      (g.communities || []).forEach(function (c) {
        topoCommKeyById[c.id] = c.label ||
          ((sizeById[c.id] || c.size || 0) >= 4 ? "(unlabeled)" : "fragments");
      });
      buildBrainFromRealData(false);
    } else {
      topoRealData = null;
      brainNodes = synthBrainNodes(events, W, H);
      brainEdges = synthBrainEdges(brainNodes);
      brainLobeLabels = Object.create(null);  // synthetic lobes carry no real community labels
      topoCommRows = [];     // no content picker on synthetic data
    }
    renderCommPicker();
    // L4: assign per-node depth from age now that the node set is final.
    brainAssignDepth(Date.now());

    // Decide overlay visibility: the brain canvas is always the hero.
    // The pending overlay is only shown when VizGraph analytics are present — the analytics
    // grid needs a readable dark tint to be scannable over the animated neurons.
    // On the synthetic no-analytics path the overlay stays hidden; corner elements
    // (node count top-left, watermark top-right) communicate the synthetic state instead.
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
      topoHideCornerElements();
    } else if (!hasRealStructure) {
      // No-analytics synthetic path: brain is the hero; overlay stays hidden.
      pending.hidden = true;
      topoRenderAnalytics(g);    // renders static legend in #topoLegend
      topoShowCornerElements(monOn);
    } else {
      // Real structure: overlay hidden, VizGraph legend in corner.
      pending.hidden = true;
      topoRenderAnalytics(g);
      topoHideCornerElements();
    }

    startBrainAnimation(container, W, H);
    topoStartSSE();
  }

  // CSS color string for community palette index i — keeps the DOM legend
  // swatches in sync with the canvas community colors. communities[] arrives
  // sorted by size desc, so array index == lobe rank for the top entries.
  function brainCommCSS(i) {
    const col = BRAIN_COMM_COLORS[i % BRAIN_COMM_COLORS.length];
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
          const dot = el("div", "lsw"); dot.style.background = brainCommCSS(i); sw.appendChild(dot);
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
        sw.style.background = brainCommCSS(i);
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

  // Show node-count and watermark corner elements (synthetic no-analytics path).
  function topoShowCornerElements(monOn) {
    const nodeCnt = $("#topoNodeCnt");
    const watermark = $("#topoWatermark");
    if (nodeCnt) {
      nodeCnt.hidden = false;
      const n = brainNodes.length;
      nodeCnt.innerHTML = "<strong>" + n.toLocaleString() + "</strong> synthetic nodes";
    }
    if (watermark) {
      watermark.hidden = false;
      watermark.textContent = monOn ? "synthetic · observing" : "synthetic · monitoring off";
    }
  }

  // Hide corner elements (analytics-grid path and live-structure path).
  function topoHideCornerElements() {
    const nodeCnt = $("#topoNodeCnt");
    const watermark = $("#topoWatermark");
    if (nodeCnt) nodeCnt.hidden = true;
    if (watermark) watermark.hidden = true;
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
  // a brain node; otherwise a random member of the event's estate-hash
  // community keeps the replay visible (deterministic community per estate).
  function topoPlaybackPulse(ev) {
    var node = ev.drawerId ? brainNodeMap[ev.drawerId] : null;
    if (!node) {
      var comms = Object.keys(brainCommPools);
      if (!comms.length) return;
      var h = 0, s = String(ev.estate || "");
      for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
      var pool = brainCommPools[comms[h % comms.length]];
      if (!pool || !pool.length) return;
      node = pool[Math.floor(Math.random() * pool.length)];
    }
    if (ev.kind === "capture") {
      node.pulseOrange = 1.0;
    } else {
      node.glowBlue = Math.min(1.0, node.glowBlue + 0.55);
    }
  }

  // Advance the playhead one event, then schedule the next step:
  // ~110ms dwell + the real inter-event gap capped at 400ms. After the last
  // event the playhead holds on "now" for ~2s, then loops to the window start.
  function topoPlayStep() {
    var win = topoPlayWindowEvents();
    if (!win.length) { topoPlayToggle(); return; }
    if (topoPlay.idx >= win.length) {
      // Dwell-on-now: hold at the final event so live SSE pulses share the stage.
      topoPlay.timer = setTimeout(function () {
        topoPlay.idx = 0;
        topoPlayStep();
      }, 2000);
      return;
    }
    var ev = win[topoPlay.idx];
    topoPlay.playheadMs = ev.ms;
    var clock = $("#topoPlayClock");
    if (clock) clock.textContent = new Date(ev.ms).toLocaleString();
    topoPlaybackPulse(ev);
    var next = win[topoPlay.idx + 1];
    var gap = next ? Math.min(Math.max(0, next.ms - ev.ms), 400) : 0;
    topoPlay.idx++;
    topoPlay.timer = setTimeout(topoPlayStep, 110 + gap);
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
    if (!topoPlayWindowEvents().length) return;  // nothing to replay
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
    // L4 strata toggle — flips projection + painter sort; the running rAF
    // loop picks the mode up on its next frame (no re-render needed).
    $("#topoDimToggle").addEventListener("click", function () {
      brain3D = !brain3D;
      this.setAttribute("aria-pressed", brain3D ? "true" : "false");
      brainUpdateDrawOrder();
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
