import test from "node:test";
import assert from "node:assert/strict";

import {
  aggregateVisualStyle,
  aggregateVisualWeight,
  BoundedTTLCache,
  brainFieldCenters,
  EXPANSION_DEFAULTS,
  remapDetailCommunities,
  SemanticExpansionController,
  stableUnit,
} from "../semantic-zoom.mjs";

const community = { aggregateLevel: "community", aggregateKey: "c-alpha", parentKey: null };
const otherCommunity = { aggregateLevel: "community", aggregateKey: "c-beta", parentKey: null };
const fold = { aggregateLevel: "fold", aggregateKey: "f-alpha", parentKey: "c-alpha" };

test("detail expansion has a bounded visual morph", () => {
  assert.deepEqual(EXPANSION_DEFAULTS, { transitionMs: 420 });
});

test("aggregate mass is monotonic, bounded, and visibly differentiated", () => {
  const tiny = aggregateVisualStyle(1, 50_000, "community");
  const medium = aggregateVisualStyle(500, 50_000, "community");
  const large = aggregateVisualStyle(50_000, 50_000, "community");
  assert.ok(aggregateVisualWeight(1, 50_000) >= 0);
  assert.ok(large.weight <= 1);
  assert.ok(tiny.tissueSize < medium.tissueSize);
  assert.ok(medium.tissueSize < large.tissueSize);
  assert.ok(large.tissueSize / medium.tissueSize > 1.5);
  assert.ok(tiny.coreSize > 0, "one-memory aggregates remain visible and clickable");
  assert.ok(aggregateVisualStyle(500, 50_000, "fold").tissueSize < medium.tissueSize);
});

test("fallback brain field is deterministic and uses both hemispheres", () => {
  const first = brainFieldCenters(20, 900, 600);
  const second = brainFieldCenters(20, 900, 600);
  assert.deepEqual(first, second);
  assert.equal(first.length, 20);
  assert.ok(first.some((point) => point.x < 450));
  assert.ok(first.some((point) => point.x > 450));
  assert.ok(new Set(first.map((point) => `${point.x}:${point.y}`)).size > 18);
});

test("salted fallback samples do not collapse axes together", () => {
  const samples = Array.from({ length: 256 }, (_, index) => ({
    x: stableUnit(`node-${index}`, "x"),
    y: stableUnit(`node-${index}`, "y"),
    z: stableUnit(`node-${index}`, "z"),
  }));
  assert.ok(samples.some((sample) => Math.abs(sample.x - sample.y) > 0.25));
  assert.ok(samples.some((sample) => Math.abs(sample.y - sample.z) > 0.25));
});

test("explicit community expansion requests its children", () => {
  const expansion = new SemanticExpansionController();
  assert.deepEqual(expansion.intent(community), {
    type: "transition", level: "community", focusKey: "c-alpha",
    parentKey: "c-alpha", expansionKey: "community:c-alpha",
  });
});

test("aggregate kind chooses the detail endpoint independently", () => {
  const expansion = new SemanticExpansionController();
  const intent = expansion.intent(fold);
  assert.deepEqual(intent, {
    type: "transition", level: "local", focusKey: "f-alpha",
    parentKey: "c-alpha", expansionKey: "local:f-alpha",
  });
});

test("completed expansion stays visible and another aggregate can expand", () => {
  const expansion = new SemanticExpansionController();
  const first = expansion.intent(community);
  assert.equal(expansion.begin(first), true);
  assert.equal(expansion.intent(otherCommunity), null);
  assert.equal(expansion.begin(first), false);
  expansion.complete(first);
  assert.equal(expansion.intent(community), null);
  assert.equal(expansion.intent(otherCommunity).focusKey, "c-beta");
});

test("real memories have no child endpoint", () => {
  const expansion = new SemanticExpansionController();
  assert.equal(expansion.intent({ id: "memory" }), null);
});

test("reset clears accumulated expansion state", () => {
  const expansion = new SemanticExpansionController();
  const first = expansion.intent(community);
  expansion.begin(first);
  expansion.complete(first);
  assert.equal(expansion.intent(community), null);
  expansion.reset();
  assert.equal(expansion.intent(community).focusKey, "c-alpha");
});

test("community detail receives fresh community ids without changing ancestors", () => {
  const previous = {
    rawNodes: [{ id: "parent", communityId: 4, aggregateKey: "c-alpha" }],
    communities: [{ id: 4, label: "Parent", size: 100 }],
  };
  const result = remapDetailCommunities(
    previous,
    [{ id: "fold", communityId: 0, aggregateKey: "f-alpha" }],
    [{ id: 0, label: "Fold", size: 25 }],
    { level: "community", focusKey: "c-alpha" },
  );
  assert.deepEqual(result.communities, [
    { id: 4, label: "Parent", size: 100 },
    { id: 5, label: "Fold", size: 25 },
  ]);
  assert.equal(result.rawNodes[0].communityId, 5);
});

test("local detail reuses its visible fold community without double-counting metadata", () => {
  const previous = {
    rawNodes: [
      { id: "parent", communityId: 4, aggregateKey: "c-alpha" },
      { id: "fold", communityId: 5, aggregateKey: "f-alpha" },
    ],
    communities: [
      { id: 4, label: "Parent", size: 100 },
      { id: 5, label: "Fold", size: 25 },
    ],
  };
  const result = remapDetailCommunities(
    previous,
    [{ id: "memory", communityId: 0 }],
    [{ id: 0, label: "Parent", size: 100 }],
    { level: "local", focusKey: "f-alpha" },
  );
  assert.deepEqual(result.communities, previous.communities);
  assert.equal(result.rawNodes[0].communityId, 5);
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
