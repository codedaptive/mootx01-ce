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
