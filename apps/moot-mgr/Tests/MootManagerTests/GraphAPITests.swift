// GraphAPITests.swift
//
// P5 verify line: the resident host serves the Topology read endpoint
// (GET /api/graph); the renderer is the Canvas2D brain renderer in app.js.
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
        for key in ["ids", "communityId", "centrality", "anomaly", "createdTs",
                    "tombstoned", "edges", "communities", "analytics",
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
    }
}

// MARK: - Topology renderer asset wiring

// The Topology renderer is the Canvas2D brain renderer inside app.js — no
// separate renderer asset is shipped. These tests pin the wiring: the
// dashboard HTML loads app.js, app.js binds /api/graph and contains the
// Canvas2D renderer entry points, and the retired /sigma.js path stays off
// the allow-list.
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
        let (_, _, js) = try await httpGET(port: port, path: "/app.js")
        #expect(js.contains("/api/graph"))
        // Canvas2D brain renderer entry points live in app.js itself.
        #expect(js.contains("drawBrainFrame"))
        #expect(js.contains("selectBrainNode"))
    }
}
