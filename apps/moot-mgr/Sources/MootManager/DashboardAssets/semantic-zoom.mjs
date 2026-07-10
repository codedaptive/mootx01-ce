// Pure detail-expansion policy for the Topology renderer. The historical file
// name remains part of the dashboard asset URL, but camera zoom is deliberately
// absent from this policy. It owns no DOM or Three.js state, so an aggregate can
// gain children without any camera gesture becoming data navigation.

export const EXPANSION_DEFAULTS = Object.freeze({
  transitionMs: 420,
});

const EXPANSION_LEVEL = Object.freeze({ community: "community", fold: "local" });

export function remapDetailCommunities(previous, rawNodes, communities, intent) {
  const previousCommunities = previous?.communities || [];
  const previousNodes = previous?.rawNodes || [];
  const localTarget = intent?.level === "local"
    ? previousNodes.find((node) => node.aggregateKey === intent.focusKey)
    : null;
  if (localTarget && localTarget.communityId >= 0) {
    return {
      rawNodes: rawNodes.map((node) => ({ ...node, communityId: localTarget.communityId })),
      communities: previousCommunities.slice(),
    };
  }

  const maxCommunityID = previousCommunities.reduce(
    (maxID, community) => Math.max(
      maxID,
      typeof community.id === "number" ? community.id : -1,
    ),
    -1,
  );
  let nextCommunityID = maxCommunityID + 1;
  const communityIDMap = new Map();
  const mergedCommunities = previousCommunities.slice();
  communities.forEach((community) => {
    const newID = nextCommunityID++;
    communityIDMap.set(String(community.id), newID);
    mergedCommunities.push({ ...community, id: newID });
  });
  const singleCommunityID = communities.length === 1
    ? communityIDMap.get(String(communities[0].id))
    : undefined;
  const remappedNodes = rawNodes.map((node) => {
    const oldID = node.communityId;
    let mapped = oldID >= 0 ? communityIDMap.get(String(oldID)) : oldID;
    if (oldID >= 0 && mapped === undefined && singleCommunityID !== undefined) {
      mapped = singleCommunityID;
    }
    if (oldID >= 0 && mapped === undefined) {
      mapped = nextCommunityID++;
      communityIDMap.set(String(oldID), mapped);
      mergedCommunities.push({
        id: mapped,
        code: node.code || null,
        label: node.aggregateLabel || null,
        size: 0,
        classificationPurity: null,
      });
    }
    return { ...node, communityId: mapped };
  });
  return { rawNodes: remappedNodes, communities: mergedCommunities };
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

// Detail policy for a continuous scene. It can request children for an
// aggregate, but it never removes geometry or treats camera zoom as navigation.
export class SemanticExpansionController {
  constructor() {
    this.locked = false;
    this.expanded = new Set();
  }

  reset() {
    this.locked = false;
    this.expanded.clear();
  }

  cacheKey(level, focusKey) {
    return `${level}:${focusKey}`;
  }

  begin(intent) {
    if (this.locked || !intent || intent.type !== "transition") return false;
    this.locked = true;
    return true;
  }

  cancel() {
    this.locked = false;
  }

  complete(intent) {
    if (intent && intent.level && intent.focusKey) {
      this.expanded.add(this.cacheKey(intent.level, intent.focusKey));
    }
    this.locked = false;
  }

  canExpand(candidate) {
    if (!candidate || !candidate.aggregateKey) return false;
    const targetLevel = EXPANSION_LEVEL[candidate.aggregateLevel];
    return !!targetLevel && !this.expanded.has(this.cacheKey(targetLevel, candidate.aggregateKey));
  }

  intent(candidate) {
    if (this.locked || !this.canExpand(candidate)) return null;
    const targetLevel = EXPANSION_LEVEL[candidate.aggregateLevel];
    if (!targetLevel) return null;
    const key = this.cacheKey(targetLevel, candidate.aggregateKey);
    if (this.expanded.has(key)) return null;
    return {
      type: "transition",
      level: targetLevel,
      focusKey: candidate.aggregateKey,
      parentKey: candidate.parentKey || candidate.aggregateKey,
      expansionKey: key,
    };
  }
}
