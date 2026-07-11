#!/usr/bin/env node

import http from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const assets = join(here, "../../Sources/MootManager/DashboardAssets");
const port = Number.parseInt(process.env.PORT || "4317", 10);
const graphDelayMs = Number.parseInt(process.env.GRAPH_DELAY_MS || "35", 10);
const estateNodeCount = 52717;
const estateEdgeCount = 70000;
const firstCommunitySize = 1900;
const remainingCommunitySize = estateNodeCount - firstCommunitySize;
const communityBaseSize = Math.floor(remainingCommunitySize / 95);
const communityRemainder = remainingCommunitySize - communityBaseSize * 95;
const generatedTs = "2026-07-09T22:00:00Z";

const contentTypes = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
};

function communityPosition(index) {
  if (index === 0) return { x: 0, y: 0, z: 0.08 };
  const side = index % 2 === 0 ? -1 : 1;
  const slot = Math.floor((index - 1) / 2);
  const angle = (slot / 48) * Math.PI * 2;
  const radial = 0.24 + (slot % 6) * 0.075;
  return {
    x: Math.max(-0.92, Math.min(0.92, side * 0.34 + Math.cos(angle) * radial * 0.72)),
    y: Math.max(-0.82, Math.min(0.82, Math.sin(angle) * radial * 1.25)),
    z: Math.sin(angle * 1.7) * 0.32,
  };
}

function community(index) {
  const position = communityPosition(index);
  const size = index === 0
    ? firstCommunitySize
    : communityBaseSize + (index === 95 ? communityRemainder : 0);
  const code = String((index * 37 + 101) % 1000).padStart(3, "0");
  return {
    id: index,
    stableKey: `c-${index}`,
    code,
    label: index === 0 ? "Human experience" : `Knowledge domain ${index + 1}`,
    size,
    x: position.x,
    y: position.y,
    z: position.z,
    foldCount: 64,
    representativeIds: [`n-${index}-0`, `n-${index}-1`],
    classificationPurity: 0.58 + (index % 8) * 0.05,
  };
}

const communities = Array.from({ length: 96 }, (_, index) => community(index));

function bridge(level, sourceKey, targetKey, index) {
  return {
    level,
    sourceKey,
    targetKey,
    edgeType: index % 7 === 0 ? "kgFact" : "tunnel",
    weight: 1 + (index % 11),
    edgeCount: 2 + (index % 31),
  };
}

const estateBridges = [];
for (let index = 0; index < communities.length; index++) {
  estateBridges.push(bridge(
    "community",
    communities[index].stableKey,
    communities[(index + 1) % communities.length].stableKey,
    index,
  ));
  if (index % 3 === 0) {
    estateBridges.push(bridge(
      "community",
      communities[index].stableKey,
      communities[(index + 17) % communities.length].stableKey,
      index + 100,
    ));
  }
}

function communityIndex(focus) {
  const match = /^c-(\d+)$/.exec(focus || "");
  return match ? Number(match[1]) % communities.length : 0;
}

function foldsFor(focus) {
  const cIndex = communityIndex(focus);
  const parent = communities[cIndex];
  return Array.from({ length: 64 }, (_, index) => {
    const angle = (index / 64) * Math.PI * 2;
    const ring = 0.018 + Math.floor(index / 16) * 0.028;
    return {
      stableKey: `f-${cIndex}-${index}`,
      communityKey: parent.stableKey,
      code: String((cIndex * 37 + index * 11 + 101) % 1000).padStart(3, "0"),
      label: index === 0 ? `${parent.label} core` : `${parent.label} fold ${index + 1}`,
      size: Math.max(12, Math.floor(parent.size / 64)),
      x: parent.x + Math.cos(angle) * ring,
      y: parent.y + Math.sin(angle) * ring,
      z: parent.z + Math.sin(angle * 2) * 0.035,
      representativeIds: [`n-${cIndex}-${index * 2}`],
    };
  });
}

function foldBridges(folds) {
  const result = [];
  for (let index = 0; index < folds.length; index++) {
    result.push(bridge(
      "fold",
      folds[index].stableKey,
      folds[(index + 1) % folds.length].stableKey,
      index,
    ));
    if (index % 4 === 0) {
      result.push(bridge(
        "fold",
        folds[index].stableKey,
        folds[(index + 9) % folds.length].stableKey,
        index + 100,
      ));
    }
  }
  return result;
}

function q16Base64(positions) {
  const buffer = Buffer.allocUnsafe(positions.length * 6);
  positions.forEach((position, index) => {
    buffer.writeInt16LE(Math.round(Math.max(-1, Math.min(1, position.x)) * 32767), index * 6);
    buffer.writeInt16LE(Math.round(Math.max(-1, Math.min(1, position.y)) * 32767), index * 6 + 2);
    buffer.writeInt16LE(Math.round(Math.max(-1, Math.min(1, position.z)) * 32767), index * 6 + 4);
  });
  return buffer.toString("base64");
}

function localPayload(focus) {
  const match = /^f-(\d+)-(\d+)$/.exec(focus || "") || [null, "0", "0"];
  const cIndex = Number(match[1]) % communities.length;
  const foldIndex = Number(match[2]) % 64;
  const parent = communities[cIndex];
  const fold = foldsFor(parent.stableKey)[foldIndex];
  const count = 2000;
  const ids = Array.from({ length: count }, (_, index) => `n-${cIndex}-${foldIndex}-${index}`);
  const positions = ids.map((_, index) => {
    const angle = index * 2.399963229728653;
    const radius = 0.0025 * Math.sqrt(index);
    return {
      x: fold.x + Math.cos(angle) * radius,
      y: fold.y + Math.sin(angle) * radius,
      z: fold.z + Math.sin(angle * 0.37) * 0.045,
    };
  });
  const edges = [];
  for (let index = 1; index < count; index++) edges.push([index - 1, index, 0.9, 0]);
  for (let index = 0; edges.length < 12000; index++) {
    const source = index % count;
    const target = (source + 17 + (index % 97)) % count;
    if (source !== target) edges.push([source, target, 0.25 + (index % 7) * 0.08, index % 11 === 0 ? 1 : 0]);
  }
  return graphEnvelope({
    viewLevel: "local",
    focusKey: fold.stableKey,
    ids,
    communityId: Array(count).fill(0),
    centrality: ids.map((_, index) => 1 / (1 + index * 0.015)),
    anomaly: ids.map((_, index) => index % 337 === 0),
    createdTs: ids.map((_, index) => `2026-07-${String(1 + (index % 9)).padStart(2, "0")}T12:00:00Z`),
    codes: [fold.code, parent.code],
    codeIndex: ids.map((_, index) => index % 5 === 0 ? 1 : 0),
    positionQ16: q16Base64(positions),
    representatives: [0, 17, 83, 211],
    edges,
    communities: [parent],
    folds: [fold],
    bridges: [],
    lodTruncated: true,
    activityIds: ids.slice(0, 100),
    activityKeys: Array(100).fill(fold.stableKey),
  });
}

function graphEnvelope(overrides = {}) {
  return {
    ids: [], communityId: [], centrality: [], anomaly: [], createdTs: [],
    tombstoned: {}, codes: [], codeIndex: [], edges: [], edgeTimeOrigin: 0,
    positionQ16: "", representatives: [], communities: [], folds: [], bridges: [],
    topologyVersion: 3, coordinateFrameVersion: 1,
    viewLevel: "estate", focusKey: null,
    activityIds: [], activityKeys: [],
    totalNodeCount: estateNodeCount, totalEdgeCount: estateEdgeCount,
    lodTruncated: false, analytics: [], structurePending: false, pending: false,
    generatedTs, estate: "fixture-estate", snapshotTs: generatedTs,
    ...overrides,
  };
}

const estatePayload = graphEnvelope({
  communities,
  bridges: estateBridges,
  viewLevel: "estate",
  activityIds: Array.from({ length: 100 }, (_, index) => `n-0-0-${index}`),
  activityKeys: Array(100).fill("c-0"),
});

function graphPayload(url) {
  const level = url.searchParams.get("level") || "estate";
  const focus = url.searchParams.get("focus");
  if (level === "community" && focus) {
    const folds = foldsFor(focus);
    return graphEnvelope({
      viewLevel: "community",
      focusKey: focus,
      communities: [communities[communityIndex(focus)]],
      folds,
      bridges: foldBridges(folds),
      activityIds: Array.from({ length: 100 }, (_, index) => `n-${communityIndex(focus)}-0-${index}`),
      activityKeys: Array(100).fill(folds[0].stableKey),
    });
  }
  if (level === "local" && focus) return localPayload(focus);
  return estatePayload;
}

const events = Array.from({ length: 100 }, (_, index) => ({
  ts: `2026-07-09T22:${String(index % 60).padStart(2, "0")}:00Z`,
  kind: index % 4 === 0 ? "think" : "capture",
  nounType: 0,
  estate: "fixture-estate",
  drawerId: `n-0-0-${index}`,
}));

function json(response, value, delay = 0) {
  const body = JSON.stringify(value);
  setTimeout(() => {
    response.writeHead(200, {
      "Content-Type": "application/json; charset=utf-8",
      "Content-Length": Buffer.byteLength(body),
      "Cache-Control": "no-store",
    });
    response.end(body);
  }, delay);
}

async function staticAsset(response, name) {
  const body = await readFile(join(assets, name));
  response.writeHead(200, {
    "Content-Type": contentTypes[extname(name)] || "application/octet-stream",
    "Content-Length": body.length,
    "Cache-Control": "no-store",
  });
  response.end(body);
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://127.0.0.1:${port}`);
  if (url.pathname === "/api/graph") return json(response, graphPayload(url), graphDelayMs);
  if (url.pathname === "/api/events" && url.searchParams.get("stream") === "1") {
    response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store" });
    response.write(": topology fixture\n\n");
    return;
  }
  if (url.pathname === "/api/events") return json(response, { events });
  if (url.pathname === "/api/server") return json(response, {
    running: true, monitoringEnabled: true, uptimeSeconds: 3600,
    estateCount: 1, totalMetrics: 0, totalEvents: events.length,
  });
  if (url.pathname === "/api/estates") return json(response, { estates: [] });
  if (url.pathname === "/api/config") return json(response, {
    monitoringEnabled: true, retentionSeconds: 604800, retentionCutoff: generatedTs,
  });
  if (url.pathname === "/") return staticAsset(response, "index.html");
  const allowed = new Map([
    ["/app.css", "app.css"], ["/app.js", "app.js"],
    ["/semantic-zoom.mjs", "semantic-zoom.mjs"],
    ["/three.min.js", "three.min.js"], ["/OrbitControls.js", "OrbitControls.js"],
  ]);
  if (allowed.has(url.pathname)) return staticAsset(response, allowed.get(url.pathname));
  response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
  response.end("not found");
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`Topology V3 fixture: http://127.0.0.1:${port}\n`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
