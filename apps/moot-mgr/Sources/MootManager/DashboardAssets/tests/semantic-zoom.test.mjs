import test from "node:test";
import assert from "node:assert/strict";

import { BoundedTTLCache, SemanticZoomController } from "../semantic-zoom.mjs";

const community = { aggregateKey: "c-alpha", parentKey: null };
const fold = { aggregateKey: "f-alpha", parentKey: "c-alpha" };

test("prefetches once before the enter threshold", () => {
  const zoom = new SemanticZoomController({ prefetchPx: 20, enterPx: 40 });
  assert.equal(zoom.observe({ direction: "in", candidate: community, projectedPx: 19 }), null);
  const intent = zoom.observe({ direction: "in", candidate: community, projectedPx: 20 });
  assert.deepEqual(intent, {
    type: "prefetch", direction: "in", level: "community",
    focusKey: "c-alpha", parentKey: "c-alpha",
  });
  zoom.markPrefetched(intent.level, intent.focusKey);
  assert.equal(zoom.observe({ direction: "in", candidate: community, projectedPx: 30 }), null);
});

test("crossing the enter threshold produces a locked forward transition", () => {
  const zoom = new SemanticZoomController({ prefetchPx: 20, enterPx: 40 });
  const intent = zoom.observe({ direction: "in", candidate: community, projectedPx: 40 });
  assert.equal(intent.type, "transition");
  assert.equal(intent.level, "community");
  assert.equal(zoom.begin(), true);
  assert.equal(zoom.observe({ direction: "in", candidate: community, projectedPx: 80 }), null);
  assert.equal(zoom.begin(), false);
});

test("community to local preserves the community parent for reverse zoom", () => {
  const zoom = new SemanticZoomController({ prefetchPx: 20, enterPx: 40 });
  zoom.sync("community", "c-alpha", "c-alpha");
  const intent = zoom.observe({ direction: "in", candidate: fold, projectedPx: 45 });
  assert.deepEqual(intent, {
    type: "transition", direction: "in", level: "local",
    focusKey: "f-alpha", parentKey: "c-alpha",
  });
  zoom.complete("local", "f-alpha", "c-alpha");
  assert.equal(zoom.level, "local");
  assert.equal(zoom.parentKey, "c-alpha");
});

test("reverse transition uses a wider distance threshold as hysteresis", () => {
  const zoom = new SemanticZoomController({
    prefetchPx: 20, enterPx: 40, exitDistanceRatio: 1.5,
  });
  zoom.sync("local", "f-alpha", "c-alpha");
  assert.equal(zoom.observe({ direction: "out", distanceRatio: 1.49 }), null);
  assert.deepEqual(zoom.observe({ direction: "out", distanceRatio: 1.5 }), {
    type: "transition", direction: "out", level: "community",
    focusKey: "c-alpha", parentKey: "c-alpha",
  });
  zoom.complete("community", "c-alpha", "c-alpha");
  assert.deepEqual(zoom.observe({ direction: "out", distanceRatio: 1.5 }), {
    type: "transition", direction: "out", level: "estate",
    focusKey: null, parentKey: null,
  });
});

test("repeated threshold crossings produce one transition per completed level change", () => {
  const zoom = new SemanticZoomController({
    prefetchPx: 39.95, enterPx: 40, exitDistanceRatio: 1.5,
  });
  for (let cycle = 0; cycle < 20; cycle++) {
    assert.equal(
      zoom.observe({ direction: "in", candidate: community, projectedPx: 39.9 }),
      null,
    );
    const inward = zoom.observe({ direction: "in", candidate: community, projectedPx: 40 });
    assert.equal(inward.level, "community");
    assert.equal(zoom.begin(), true);
    assert.equal(zoom.observe({ direction: "out", distanceRatio: 2 }), null);
    zoom.complete("community", "c-alpha", "c-alpha");

    assert.equal(zoom.observe({ direction: "out", distanceRatio: 1.49 }), null);
    const outward = zoom.observe({ direction: "out", distanceRatio: 1.5 });
    assert.equal(outward.level, "estate");
    assert.equal(zoom.begin(), true);
    assert.equal(zoom.observe({ direction: "in", candidate: community, projectedPx: 80 }), null);
    zoom.complete("estate");
  }
});

test("click drill is immediate but cannot move beyond local", () => {
  const zoom = new SemanticZoomController();
  assert.equal(zoom.drill(community).level, "community");
  zoom.sync("local", "f-alpha", "c-alpha");
  assert.equal(zoom.drill(fold), null);
});

test("rejects an invalid threshold order", () => {
  assert.throws(
    () => new SemanticZoomController({ prefetchPx: 40, enterPx: 40 }),
    /prefetch threshold/,
  );
});

test("bounded cache expires entries and refreshes LRU order", () => {
  let now = 0;
  const cache = new BoundedTTLCache({ limit: 2, ttlMs: 100, clock: () => now });
  cache.set("a", 1);
  cache.set("b", 2);
  assert.equal(cache.get("a"), 1); // a becomes newest
  cache.set("c", 3);              // b is evicted
  assert.equal(cache.get("b"), undefined);
  assert.equal(cache.get("a"), 1);
  now = 101;
  assert.equal(cache.get("a"), undefined);
  assert.equal(cache.size, 1);
  cache.clear();
  assert.equal(cache.size, 0);
});

test("bounded cache validates its resource limits", () => {
  assert.throws(() => new BoundedTTLCache({ limit: 0 }), /limit/);
  assert.throws(() => new BoundedTTLCache({ ttlMs: 0 }), /ttl/);
});

test("failed prefetches can be retried", () => {
  const zoom = new SemanticZoomController({ prefetchPx: 20, enterPx: 40 });
  const first = zoom.observe({ direction: "in", candidate: community, projectedPx: 20 });
  zoom.markPrefetched(first.level, first.focusKey);
  assert.equal(zoom.observe({ direction: "in", candidate: community, projectedPx: 25 }), null);
  zoom.forgetPrefetched(first.level, first.focusKey);
  assert.equal(
    zoom.observe({ direction: "in", candidate: community, projectedPx: 25 }).type,
    "prefetch",
  );
});
