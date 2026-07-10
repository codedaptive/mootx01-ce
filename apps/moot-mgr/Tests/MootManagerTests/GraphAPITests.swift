// GraphAPITests.swift
//
// P5 verify line: the resident host serves the Topology read endpoint
// (GET /api/graph); the renderer is the Three.js brain renderer in app.js.
//
// /api/graph projects the VizGraph analytic overlay the resident host CAN read
// from the ObserverSink stats store (per-estate community count, centrality /
// anomaly / NMF / decay completion signals), and marks per-node/per-edge
// STRUCTURE as pending — moot-mgr is a pure observer with no estate access, so
// it serves what is available and never fabricates nodes/edges (A1 honesty
// pattern). All of /api/graph rides the same 127.0.0.1-only, read-only listener.

import Testing
import Foundation
import ObserverSink
@testable import MootManager

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Helpers (a started host on an OS-assigned loopback port)

private func makeTempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-graph-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("stats.sqlite", isDirectory: false)
}

private func makeTempSocketPath() -> String {
    "/tmp/mm-gr-\(UUID().uuidString.prefix(8)).sock"
}

private let grToken = "0123456789abcdef0123456789abcdef"

private func makeStartedHost(
    seed: (StatsStore) async throws -> Void = { _ in }
) async throws -> (host: ResidentHost, port: UInt16) {
    let cfg = ResidentHostConfig(
        manager: ManagerConfig(storeURL: makeTempStoreURL(), retentionWindow: 1000),
        httpPort: 0,
        controlToken: grToken,
        controlSocketPath: makeTempSocketPath(),
        estatesDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-estates-\(UUID().uuidString)", isDirectory: true)
    )
    let host = ResidentHost(config: cfg, startInstant: Date(timeIntervalSince1970: 1000),
                            clock: { Date(timeIntervalSince1970: 2000) })
    try await host.start()
    let store = try await host.managerHandle().statsStore()
    try await seed(store)
    let port = await host.boundHTTPPort()
    return (host, port)
}

private func httpGET(port: UInt16, path: String) async throws
    -> (status: Int, contentType: String?, body: String)
{
    // Raw-socket client (see LoopbackHTTPTestClient): URLSession.shared times
    // out against 127.0.0.1 on the macos-26 CI runner.
    let r = try await loopbackHTTP(port: port, path: path)
    return (r.status, r.headers["content-type"], r.body)
}

private func jsonObject(port: UInt16, path: String) async throws -> [String: Any] {
    let r = try await loopbackHTTP(port: port, path: path)
    return (try JSONSerialization.jsonObject(with: Data(r.body.utf8)) as? [String: Any]) ?? [:]
}

/// Seed the five canonical VizGraph signals for one estate.
///
/// graphPayload() now derives dropboxIDs from events (FIX 1 metric-flood fix)
/// so an event with the matching dropboxID must be present for the metrics to
/// be found via the indexed query path.
private func seedVizGraph(_ store: StatsStore, estate: String) async throws {
    // Seed a matching event so graphPayload()'s event-derived dropboxID lookup
    // finds "substrateml" and queries the viz metrics below.
    try await store.insertEvent(kind: "capture", nounType: 0, rowID: "",
                                estate: estate, ts: 90, dropboxID: "substrateml")
    try await store.insertMetric(name: "community.assignment", value: 3,
                                 tags: ["estate": estate, "node_count": "12", "community_count": "3"],
                                 ts: 100, dropboxID: "substrateml")
    try await store.insertMetric(name: "centrality.score", value: 1.0,
                                 tags: ["estate": estate, "node_count": "12"],
                                 ts: 110, dropboxID: "substrateml")
    try await store.insertMetric(name: "anomaly.flag", value: 2.4,
                                 tags: ["estate": estate, "method": "z_score"],
                                 ts: 120, dropboxID: "substrateml")
    try await store.insertMetric(name: "nmf.factor", value: 0.07,
                                 tags: ["estate": estate, "rank": "4"],
                                 ts: 130, dropboxID: "substrateml")
    try await store.insertMetric(name: "edge.decayed_weight", value: 0.85,
                                 tags: ["estate": estate, "elapsed_seconds": "60"],
                                 ts: 140, dropboxID: "substrateml")
}

// MARK: - /api/graph shape

struct GraphAPITests {

    @Test("Local edge budget preserves a structural spanning forest before overlays")
    func localEdgeBudgetPreservesStructure() {
        let nodes = ["a", "b", "c", "d"].enumerated().map { index, id in
            GraphNodePayload(
                id: id, communityId: 0, centrality: index == 0 ? 1 : 0.5,
                anomaly: false, createdTs: nil, tombstonedTs: nil,
                representative: index == 0)
        }
        var edges = [
            GraphEdgePayload(source: "a", target: "b", edgeType: "tunnel", weight: 1,
                             tombstonedTs: nil),
            GraphEdgePayload(source: "b", target: "c", edgeType: "tunnel", weight: 0.8,
                             tombstonedTs: nil),
            GraphEdgePayload(source: "c", target: "d", edgeType: "kgFact", weight: 0.3,
                             tombstonedTs: nil),
        ]
        edges += (0..<20).map { index in
            GraphEdgePayload(source: index.isMultiple(of: 2) ? "a" : "b",
                             target: index.isMultiple(of: 2) ? "d" : "c",
                             edgeType: "nmf_bond", weight: 0.2, tombstonedTs: nil)
        }
        let bounded = MootManager.boundedLocalEdges(edges, nodes: nodes, limit: 3)
        #expect(bounded.count == 3)
        #expect(bounded.allSatisfy { $0.edgeType != "nmf_bond" })
        #expect(Set(bounded.flatMap { [$0.source, $0.target] }) == Set(["a", "b", "c", "d"]))
    }

    @Test("Topology V3 serves aggregate estate/community views and bounded local nodes")
    func topologyV3Levels() async throws {
        let snapshot = Data("""
        {"nodes":[
          {"id":"n1","communityId":0,"centrality":1,"anomaly":false,"createdTs":null,
           "tombstonedTs":null,"communityKey":"c-alpha","foldKey":"f-one",
           "x":0.1,"y":0.2,"z":0.3,"representative":true},
          {"id":"n2","communityId":0,"centrality":0.5,"anomaly":false,"createdTs":null,
           "tombstonedTs":null,"communityKey":"c-alpha","foldKey":"f-one",
           "x":0.2,"y":0.3,"z":0.4,"representative":false}],
         "edges":[{"source":"n1","target":"n2","edgeType":"tunnel","weight":1,
                   "createdTs":null,"tombstonedTs":null}],
         "structurePending":false,"topologyVersion":3,"coordinateFrameVersion":1,
         "communities":[{"id":0,"size":2,"dominantUdcCode":"006","stableKey":"c-alpha",
                         "x":0.1,"y":0.2,"z":0.3,"foldCount":1,
                         "representativeIds":["n1"],"classificationPurity":1}],
         "folds":[{"stableKey":"f-one","communityKey":"c-alpha","size":2,
                   "dominantUdcCode":"006","x":0.12,"y":0.22,"z":0.32,
                   "representativeIds":["n1"]}],
         "bridges":[],"generatedTs":"2026-07-09T00:00:00Z"}
        """.utf8)
        let (host, port) = try await makeStartedHost { store in
            try await store.writeTopologySnapshot(
                estate: "estate-v3", generatedAt: Date(timeIntervalSince1970: 1_000),
                payload: snapshot)
        }
        defer { Task { await host.stop() } }

        let estate = try await jsonObject(port: port, path: "/api/graph?estate=estate-v3&level=estate")
        #expect((estate["viewLevel"] as? String) == "estate")
        #expect((estate["ids"] as? [Any])?.isEmpty == true)
        #expect((estate["communities"] as? [Any])?.count == 1)

        let community = try await jsonObject(
            port: port, path: "/api/graph?estate=estate-v3&level=community&focus=c-alpha")
        #expect((community["viewLevel"] as? String) == "community")
        #expect((community["folds"] as? [Any])?.count == 1)
        #expect((community["ids"] as? [Any])?.isEmpty == true,
                "community view renders persisted fold aggregates, not raw nodes")

        let local = try await jsonObject(
            port: port, path: "/api/graph?estate=estate-v3&level=local&focus=f-one")
        #expect((local["ids"] as? [Any])?.count == 2)
        #expect((local["positionQ16"] as? String)?.isEmpty == false)

        let missingFocus = try await jsonObject(
            port: port, path: "/api/graph?estate=estate-v3&level=local")
        #expect((missingFocus["viewLevel"] as? String) == "estate")
        #expect((missingFocus["ids"] as? [Any])?.isEmpty == true,
                "a malformed drill request must retain the aggregate budget")
    }

    @Test("Topology V3 Other structure drills into accounting-preserving slices")
    func topologyV3OtherStructureDrill() async throws {
        let nodes: [[String: Any]] = (0..<100).map { index in
            var node: [String: Any] = [:]
            node["id"] = "n-\(index)"
            node["communityId"] = index
            node["centrality"] = 0.1
            node["anomaly"] = false
            node["communityKey"] = String(format: "c-%03d", index)
            node["x"] = Double(index) / 100.0 - 0.5
            node["y"] = Double(index % 10) / 10.0 - 0.5
            node["z"] = 0.0
            node["representative"] = true
            return node
        }
        let communities: [[String: Any]] = (0..<100).map { index in
            var community: [String: Any] = [:]
            community["id"] = index
            community["size"] = 1
            community["dominantUdcCode"] = "005"
            community["stableKey"] = String(format: "c-%03d", index)
            community["x"] = Double(index) / 100.0 - 0.5
            community["y"] = Double(index % 10) / 10.0 - 0.5
            community["z"] = 0.0
            community["foldCount"] = 1
            community["representativeIds"] = ["n-\(index)"]
            community["classificationPurity"] = 1.0
            return community
        }
        let snapshot = try JSONSerialization.data(withJSONObject: [
            "nodes": nodes, "edges": [], "structurePending": false,
            "topologyVersion": 3, "coordinateFrameVersion": 1,
            "communities": communities, "folds": [], "bridges": [],
            "generatedTs": "2026-07-10T00:00:00Z",
        ], options: [.sortedKeys])
        let (host, port) = try await makeStartedHost { store in
            try await store.writeTopologySnapshot(
                estate: "estate-other", generatedAt: Date(timeIntervalSince1970: 1_000),
                payload: snapshot)
        }
        defer { Task { await host.stop() } }

        let estate = try await jsonObject(
            port: port, path: "/api/graph?estate=estate-other&level=estate")
        let estateCommunities = try #require(estate["communities"] as? [[String: Any]])
        let other = try #require(estateCommunities.first { ($0["stableKey"] as? String) == "__other__" })
        #expect((other["size"] as? Int) == 5)

        let community = try await jsonObject(
            port: port, path: "/api/graph?estate=estate-other&level=community&focus=__other__")
        let slices = try #require(community["folds"] as? [[String: Any]])
        #expect(!slices.isEmpty)
        #expect(slices.reduce(0) { $0 + ($1["size"] as? Int ?? 0) } == 5)
        let sliceKey = try #require(slices.first?["stableKey"] as? String)

        let local = try await jsonObject(
            port: port, path: "/api/graph?estate=estate-other&level=local&focus=\(sliceKey)")
        #expect((local["ids"] as? [String])?.isEmpty == false,
                "every visible Other slice must open into real bounded nodes")
    }

    @Test("GET /api/graph returns the topology snapshot envelope shape")
    func graphEnvelopeShape() async throws {
        let (host, port) = try await makeStartedHost { try await seedVizGraph($0, estate: "home") }
        defer { Task { await host.stop() } }

        let (status, ctype, _) = try await httpGET(port: port, path: "/api/graph")
        #expect(status == 200)
        #expect(ctype?.hasPrefix("application/json") == true)

        let obj = try await jsonObject(port: port, path: "/api/graph")
        // FIX 2b compact format: nodes are parallel arrays (ids, communityId, ...)
        // not a per-object "nodes" array. Edges are compact [[si,ti,w,et]].
        // codes/codeIndex are the V2-P1b dictionary-encoded per-node classification
        // codes — always present alongside the other parallel arrays.
        for key in ["ids", "communityId", "centrality", "anomaly", "createdTs",
                    "tombstoned", "codes", "codeIndex", "edges", "edgeTimeOrigin", "communities", "analytics",
                    "positionQ16", "representatives", "folds", "bridges", "topologyVersion",
                    "coordinateFrameVersion", "viewLevel", "focusKey", "activityIds", "activityKeys",
                    "totalNodeCount", "totalEdgeCount", "lodTruncated",
                    "structurePending", "pending", "generatedTs", "estate", "snapshotTs"] {
            #expect(obj[key] != nil, "missing /api/graph field: \(key)")
        }
    }

    @Test("Structure is pending and nodes/edges are empty, never fabricated")
    func structurePending() async throws {
        let (host, port) = try await makeStartedHost { try await seedVizGraph($0, estate: "home") }
        defer { Task { await host.stop() } }
        let obj = try await jsonObject(port: port, path: "/api/graph")
        #expect((obj["structurePending"] as? Bool) == true)
        // FIX 2b compact format: nodes are parallel arrays. When structurePending
        // is true, all parallel arrays are empty (no nodes, no edges).
        #expect((obj["ids"] as? [Any])?.isEmpty == true, "ids must be empty when pending")
        #expect((obj["edges"] as? [Any])?.isEmpty == true, "edges must be empty when pending")
        // V2-P1b: codes/codeIndex are always present, empty on the fallback path.
        #expect((obj["codes"] as? [Any])?.isEmpty == true, "codes must be empty when pending")
        #expect((obj["codeIndex"] as? [Any])?.isEmpty == true, "codeIndex must be empty when pending")
        // The gap is enumerated honestly, not silently empty.
        #expect((obj["pending"] as? [Any])?.isEmpty == false)
        // generatedTs is null when no snapshot has been written.
        #expect(obj.keys.contains("generatedTs"), "generatedTs key must be present on wire")
        #expect(obj["generatedTs"] is NSNull, "generatedTs is null when no snapshot")
    }

    @Test("Analytic overlay surfaces the five VizGraph signals from the store")
    func analyticsOverlay() async throws {
        let (host, port) = try await makeStartedHost { try await seedVizGraph($0, estate: "home") }
        defer { Task { await host.stop() } }
        let obj = try await jsonObject(port: port, path: "/api/graph")
        let analytics = obj["analytics"] as? [[String: Any]] ?? []
        let signals = Set(analytics.compactMap { $0["signal"] as? String })
        #expect(signals == ["community.assignment", "centrality.score",
                            "nmf.factor", "anomaly.flag", "edge.decayed_weight"])
        // Each row carries estate, value, ts, sampleCount.
        let row = try #require(analytics.first)
        for key in ["estate", "signal", "value", "ts", "sampleCount"] {
            #expect(row.keys.contains(key), "missing analytic row field: \(key)")
        }
    }

    @Test("community.assignment value drives the fallback community count")
    func communityRollup() async throws {
        let (host, port) = try await makeStartedHost { try await seedVizGraph($0, estate: "home") }
        defer { Task { await host.stop() } }
        let obj = try await jsonObject(port: port, path: "/api/graph")
        let communities = obj["communities"] as? [[String: Any]] ?? []
        // Seeded community.assignment value = 3 → three legend entries for "home".
        #expect(communities.count == 3)
        // Wire shape is {id, code, label, size} (VIZ_V2 L3). The local fallback
        // knows only the count: code and label are explicit nulls (no udcCode
        // locally) and size is 0 (member counts unknown without ARIA structure).
        let row = try #require(communities.first)
        #expect(Set(row.keys) == ["id", "code", "label", "size"])
        #expect(row["code"] is NSNull)
        #expect(row["label"] is NSNull)
        #expect((row["size"] as? Int) == 0)
        // Ids are a stable running index across the fallback rollup.
        let ids = communities.compactMap { $0["id"] as? Int }
        #expect(ids == [0, 1, 2])
    }

    @Test("?estate= filters the analytic overlay to one estate")
    func estateFilter() async throws {
        let (host, port) = try await makeStartedHost { store in
            try await seedVizGraph(store, estate: "home")
            try await seedVizGraph(store, estate: "work")
        }
        defer { Task { await host.stop() } }

        let all = try await jsonObject(port: port, path: "/api/graph")
        let allEstates = Set(((all["analytics"] as? [[String: Any]]) ?? [])
            .compactMap { $0["estate"] as? String })
        #expect(allEstates == ["home", "work"])
        #expect((all["estate"] as? String) == "all")

        let filtered = try await jsonObject(port: port, path: "/api/graph?estate=work")
        let oneEstate = Set(((filtered["analytics"] as? [[String: Any]]) ?? [])
            .compactMap { $0["estate"] as? String })
        #expect(oneEstate == ["work"])
        #expect((filtered["estate"] as? String) == "work")
    }

    @Test("Non-VizGraph metrics are excluded from the graph overlay")
    func excludesNonVizMetrics() async throws {
        let (host, port) = try await makeStartedHost { store in
            try await seedVizGraph(store, estate: "home")
            try await store.insertMetric(name: "locus.op", value: 1,
                                         tags: ["estate": "home"], ts: 200, dropboxID: "locuskit")
        }
        defer { Task { await host.stop() } }
        let obj = try await jsonObject(port: port, path: "/api/graph")
        let signals = Set(((obj["analytics"] as? [[String: Any]]) ?? [])
            .compactMap { $0["signal"] as? String })
        #expect(!signals.contains("locus.op"))
    }

    @Test("Empty store yields an honest empty overlay, still pending")
    func emptyStore() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        let obj = try await jsonObject(port: port, path: "/api/graph")
        #expect((obj["analytics"] as? [Any])?.isEmpty == true)
        #expect((obj["communities"] as? [Any])?.isEmpty == true)
        #expect((obj["structurePending"] as? Bool) == true)
    }

    @Test("community.assignment value is capped at 10,000 — guards unbounded allocation")
    func communityCountCap() async throws {
        // A crafted metric with a value far above any sane community count.
        // The cap (10_000) prevents an unbounded allocation loop in graphPayload().
        // An event with the same dropboxID is required so graphPayload()'s
        // event-derived dropboxID lookup (FIX 1 metric-flood fix) finds the metric.
        let (host, port) = try await makeStartedHost { store in
            try await store.insertEvent(kind: "capture", nounType: 0, rowID: "",
                                        estate: "home", ts: 90, dropboxID: "substrateml")
            try await store.insertMetric(
                name: "community.assignment", value: 999_999,
                tags: ["estate": "home", "node_count": "12", "community_count": "999999"],
                ts: 100, dropboxID: "substrateml")
        }
        defer { Task { await host.stop() } }
        let obj = try await jsonObject(port: port, path: "/api/graph")
        let communities = obj["communities"] as? [[String: Any]] ?? []
        // The cap is 10,000 — never more than that regardless of the stored value.
        #expect(communities.count <= 10_000)
        #expect(communities.count == 10_000)
    }

    // Audit Finding #5 — the /api/graph endpoint chain proved end-to-end:
    // governor writes a topology snapshot → moot-mgr reads it → HTTP response
    // carries real structure (structurePending: false, nodes non-empty).
    // Prior tests only exercised the pending path (no snapshot in store).
    @Test("Graph endpoint returns real structure when a topology snapshot is present")
    func graphEndpointReturnsRealStructureWhenSnapshotPopulated() async throws {
        // Minimal valid StoredGraphPayload that the autonomic governor writes.
        // The store accepts any UTF-8 bytes; we produce JSON that the governor
        // would produce: structurePending:false, at least one node.
        let snapshotJSON = Data("""
        {"nodes":[{"id":"node-fixture-1","nounType":0,"communityId":0,
          "centrality":0.5,"anomaly":false,"lastActiveTs":null,
          "createdTs":"2020-01-01T00:00:00Z","tombstonedTs":null}],
         "edges":[],
         "structurePending":false,
         "generatedTs":"2020-01-01T00:00:00Z"}
        """.utf8)
        let (host, port) = try await makeStartedHost { store in
            // Write a topology snapshot for estate "fixture-estate" so the
            // chain store.write → store.read → graphPayload → HTTP is exercised.
            try await store.writeTopologySnapshot(
                estate: "fixture-estate",
                generatedAt: Date(timeIntervalSince1970: 1_577_836_800), // 2020-01-01
                payload: snapshotJSON
            )
        }
        defer { Task { await host.stop() } }

        let obj = try await jsonObject(port: port, path: "/api/graph?estate=fixture-estate")

        // Chain proved: structurePending must be false when a snapshot is present.
        #expect((obj["structurePending"] as? Bool) == false)
        // FIX 2b compact format: nodes are encoded as parallel arrays.
        // The `ids` array carries node UUIDs; `"nodes"` key is absent.
        let ids = obj["ids"] as? [String] ?? []
        #expect(ids.count == 1, "compact ids array must have 1 entry")
        #expect(ids.first == "node-fixture-1", "first id must be node-fixture-1")
        #expect((obj["positionQ16"] as? String)?.isEmpty == true,
                "legacy snapshots without coordinates must retain layout fallback")
    }

    // V2-P1b end-to-end: governor writes a snapshot whose nodes carry udcCode →
    // moot-mgr decodes and dictionary-encodes → HTTP response carries codes/codeIndex.
    @Test("Graph endpoint dictionary-encodes per-node udcCode as codes/codeIndex")
    func graphEndpointDictionaryEncodesNodeCodes() async throws {
        let snapshotJSON = Data("""
        {"nodes":[{"id":"node-a","communityId":0,"centrality":0.5,"anomaly":false,
                   "createdTs":null,"tombstonedTs":null,"udcCode":"657"},
                  {"id":"node-b","communityId":0,"centrality":0.6,"anomaly":false,
                   "createdTs":null,"tombstonedTs":null,"udcCode":"615.85"},
                  {"id":"node-c","communityId":0,"centrality":0.7,"anomaly":false,
                   "createdTs":null,"tombstonedTs":null,"udcCode":"657"},
                  {"id":"node-d","communityId":0,"centrality":0.8,"anomaly":false,
                   "createdTs":null,"tombstonedTs":null}],
         "edges":[],
         "structurePending":false,
         "generatedTs":"2020-01-01T00:00:00Z"}
        """.utf8)
        let (host, port) = try await makeStartedHost { store in
            try await store.writeTopologySnapshot(
                estate: "codes-estate",
                generatedAt: Date(timeIntervalSince1970: 1_577_836_800),
                payload: snapshotJSON
            )
        }
        defer { Task { await host.stop() } }

        let obj = try await jsonObject(port: port, path: "/api/graph?estate=codes-estate")
        let ids = obj["ids"] as? [String] ?? []
        #expect(ids == ["node-a", "node-b", "node-c", "node-d"])
        let codes = obj["codes"] as? [String] ?? []
        let codeIndex = obj["codeIndex"] as? [Int] ?? []
        // Deduped, first-seen order: "657" (node-a) before "615.85" (node-b).
        #expect(codes == ["657", "615.85"])
        // node-a→0, node-b→1, node-c→0 (reused slot), node-d→-1 (no code).
        #expect(codeIndex == [0, 1, 0, -1])
    }
}

// MARK: - Topology renderer asset wiring

// The Topology renderer is the Three.js brain renderer inside app.js — no
// separate renderer asset is shipped. These tests pin explicit expansion and
// compact-position wiring, while the retired /sigma.js path stays off the
// allow-list.
struct TopologyRendererAssetTests {

    @Test("Retired /sigma.js path is off the allow-list and serves 404")
    func sigmaRetired() async throws {
        #expect(StaticAssets.asset(for: "/sigma.js") == nil)
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        let (status, _, _) = try await httpGET(port: port, path: "/sigma.js")
        #expect(status == 404)
    }

    @Test("The dashboard loads /app.js and the Topology view binds /api/graph")
    func dashboardWiresTopology() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        let (_, _, html) = try await httpGET(port: port, path: "/")
        #expect(html.contains("/app.js"))
        #expect(html.contains("id=\"topoDotSize\""))
        #expect(html.contains("Double-click a dot to explore"))
        let (_, _, js) = try await httpGET(port: port, path: "/app.js")
        let (zoomStatus, _, zoom) = try await httpGET(port: port, path: "/semantic-zoom.mjs")
        #expect(zoomStatus == 200)
        #expect(zoom.contains("SemanticExpansionController"))
        #expect(zoom.contains("EXPANSION_DEFAULTS"))
        #expect(zoom.contains("remapDetailCommunities"))
        #expect(js.contains("/api/graph"))
        #expect(js.contains("new THREE.WebGLRenderer"))
        #expect(js.contains("function topoExpand"))
        #expect(js.contains("function topoMergeSceneLayer"))
        #expect(!js.contains("topoScheduleSemanticZoom"))
        #expect(!js.contains("addEventListener('wheel'"))
        #expect(!js.contains("topoCaptureTransitionGhost"))
        #expect(js.contains("topoPrepareDetailMorph"))
        #expect(js.contains("brainControls.zoomToCursor = true"))
        #expect(js.contains("brainControls.zoomSpeed = 0.65"))
        #expect(js.contains("brainControls.rotateSpeed = 0.55"))
        #expect(js.contains("gl_PointSize = max(1.0, size * uPointScale * uPixelRatio);"))
        #expect(js.contains("addEventListener('dblclick'"))
        #expect(js.contains("mootmgr-topology-dot-scale"))
        #expect(js.contains("function focusBrainNode"))
        #expect(js.contains("function topoTickBrainPivot"))
        #expect(js.contains("function cancelPendingBrainSelection"))
        #expect(js.contains("Expansion never selects the node"))
        #expect(js.contains("brainCamera.position.copy(pivot.startCamera).add(delta)"))
        #expect(js.contains("addEventListener('contextmenu'"))
        #expect(js.contains("copyNodeQuery(node)"))
        #expect(!js.contains("tsp-copy"))
        #expect(js.contains("vertexShader: RIPPLE_VS"))
        #expect(!js.contains("TISSUE_FS"))
        #expect(!js.contains("brainTissueMesh"))
        #expect(js.contains("function buildAggregateQuery"))
        #expect(js.contains("topoAggregateCandidate(e.clientX, e.clientY)"))
        #expect(js.contains("topoCommitExpansionIntent"))
        #expect(js.contains("var playing = false"))
        #expect(js.contains("g.positionQ16"))
        #expect(js.contains("selectBrainNode"))
    }
}
