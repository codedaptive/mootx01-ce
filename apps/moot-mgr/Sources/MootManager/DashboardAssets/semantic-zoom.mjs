// Pure semantic-zoom policy for the Topology renderer. This module deliberately
// owns no DOM or Three.js state so the intent rules stay deterministic and can
// be tested with Node's built-in test runner.

export const SEMANTIC_ZOOM_DEFAULTS = Object.freeze({
  prefetchPx: 42,
  enterPx: 72,
  exitDistanceRatio: 1.7,
  transitionMs: 260,
});

const NEXT_LEVEL = Object.freeze({ estate: "community", community: "local" });
const PREVIOUS_LEVEL = Object.freeze({ local: "community", community: "estate" });

function finiteOr(value, fallback) {
  return Number.isFinite(value) ? value : fallback;
}

export class BoundedTTLCache {
  constructor({ limit = 6, ttlMs = 60000, clock = () => performance.now() } = {}) {
    if (!Number.isInteger(limit) || limit < 1) throw new Error("cache limit must be positive");
    if (!(ttlMs > 0)) throw new Error("cache ttl must be positive");
    this.limit = limit;
    this.ttlMs = ttlMs;
    this.clock = clock;
    this.entries = new Map();
  }

  get size() { return this.entries.size; }

  clear() { this.entries.clear(); }

  delete(key) { return this.entries.delete(key); }

  get(key) {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (this.clock() - entry.storedAt > this.ttlMs) {
      this.entries.delete(key);
      return undefined;
    }
    this.entries.delete(key);
    this.entries.set(key, entry);
    return entry.value;
  }

  set(key, value) {
    this.entries.delete(key);
    this.entries.set(key, { value, storedAt: this.clock() });
    while (this.entries.size > this.limit) {
      this.entries.delete(this.entries.keys().next().value);
    }
  }
}

export class SemanticZoomController {
  constructor(options = {}) {
    this.config = Object.freeze({
      prefetchPx: finiteOr(options.prefetchPx, SEMANTIC_ZOOM_DEFAULTS.prefetchPx),
      enterPx: finiteOr(options.enterPx, SEMANTIC_ZOOM_DEFAULTS.enterPx),
      exitDistanceRatio: finiteOr(
        options.exitDistanceRatio,
        SEMANTIC_ZOOM_DEFAULTS.exitDistanceRatio,
      ),
      transitionMs: finiteOr(options.transitionMs, SEMANTIC_ZOOM_DEFAULTS.transitionMs),
    });
    if (this.config.prefetchPx >= this.config.enterPx) {
      throw new Error("semantic zoom prefetch threshold must be below enter threshold");
    }
    this.level = "estate";
    this.focusKey = null;
    this.parentKey = null;
    this.locked = false;
    this.prefetched = new Set();
  }

  sync(level, focusKey = null, parentKey = null) {
    this.level = level || "estate";
    this.focusKey = focusKey || null;
    this.parentKey = parentKey || null;
    this.locked = false;
    this.prefetched.clear();
  }

  cacheKey(level, focusKey) {
    return `${level || "estate"}:${focusKey || ""}`;
  }

  markPrefetched(level, focusKey) {
    this.prefetched.add(this.cacheKey(level, focusKey));
  }

  forgetPrefetched(level, focusKey) {
    this.prefetched.delete(this.cacheKey(level, focusKey));
  }

  begin() {
    if (this.locked) return false;
    this.locked = true;
    return true;
  }

  cancel() {
    this.locked = false;
  }

  complete(level, focusKey = null, parentKey = null) {
    this.sync(level, focusKey, parentKey);
  }

  drill(candidate) {
    if (this.locked || !candidate || !candidate.aggregateKey) return null;
    const targetLevel = NEXT_LEVEL[this.level];
    if (!targetLevel) return null;
    return {
      type: "transition",
      direction: "in",
      level: targetLevel,
      focusKey: candidate.aggregateKey,
      parentKey: candidate.parentKey || candidate.aggregateKey,
    };
  }

  observe({ direction, candidate, projectedPx = 0, distanceRatio = 1 } = {}) {
    if (this.locked) return null;
    if (direction === "out") {
      const targetLevel = PREVIOUS_LEVEL[this.level];
      if (!targetLevel || distanceRatio < this.config.exitDistanceRatio) return null;
      return {
        type: "transition",
        direction: "out",
        level: targetLevel,
        focusKey: targetLevel === "community" ? this.parentKey : null,
        parentKey: targetLevel === "community" ? this.parentKey : null,
      };
    }

    if (direction !== "in" || !candidate || !candidate.aggregateKey) return null;
    const targetLevel = NEXT_LEVEL[this.level];
    if (!targetLevel) return null;
    const intent = {
      direction: "in",
      level: targetLevel,
      focusKey: candidate.aggregateKey,
      parentKey: candidate.parentKey || candidate.aggregateKey,
    };
    if (projectedPx >= this.config.enterPx) {
      return { ...intent, type: "transition" };
    }
    const key = this.cacheKey(targetLevel, candidate.aggregateKey);
    if (projectedPx >= this.config.prefetchPx && !this.prefetched.has(key)) {
      return { ...intent, type: "prefetch" };
    }
    return null;
  }
}
