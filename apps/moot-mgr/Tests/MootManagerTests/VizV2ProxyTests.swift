// VizV2ProxyTests.swift
//
// VIZ_V2 L0+L1+L3 (moot-mgr store-read leg) wire-contract tests.
//
//   L0 — GraphNodePayload carries an optional `createdTs` (ISO-8601 ingest
//        timestamp) decoded from the stored topology snapshot and re-encoded
//        as an explicit JSON null when absent.  nounType and lastActiveTs were
//        removed from GraphNodePayload wire format (FIX 2 payload trim).
//        GraphEdgePayload carries only weight + tombstonedTs; decayedWeight
//        and createdTs were removed.  Stored snapshots that still include
//        those keys are decoded without error (unknown keys ignored).
//   Dissolution — GraphNodePayload/GraphEdgePayload carry an optional
//        `tombstonedTs` (ISO-8601, null = alive now) with the same explicit-
//        null encode and absent-key-tolerant decode, so tombstoned drawers
//        and tunnels are preserved in the stored snapshot for playback rendering.
//   L1 — EventPayload carries `drawerId` (the estate row UUID string from
//        EventRow.rowIDStr; empty string projects to nil → JSON null).
//   L3 — Community descriptors {id, size, dominantUdcCode} stored by the
//        governor are enriched at the moot-mgr boundary to {id, label, size}
//        via FDC.label(for:); the raw dominantUdcCode never crosses to the browser.

import Testing
import Foundation
import ObserverSink
import LatticeLib
@testable import MootManager

// MARK: - Helpers

private func makeTempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-vizv2-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("stats.sqlite", isDirectory: false)
}

private func makeStartedManager() async throws -> MootManager {
    let manager = MootManager(config: ManagerConfig(storeURL: makeTempStoreURL(),
                                                    retentionWindow: 1000))
    try await manager.start()
    return manager
}

/// Decode encoded payload JSON into a JSONSerialization dictionary so tests can
/// distinguish "key absent" from "key present with null" (NSNull).
private func jsonDict<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try APIJSON.encode(value)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - L1: EventPayload.drawerId

struct EventDrawerIdTests {

    @Test("projectEvent round-trips the estate row UUID into drawerId")
    func drawerIdRoundTrip() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }
        let store = try await manager.statsStore()

        let rowUUID = UUID().uuidString
        try await store.insertEvent(kind: "capture", nounType: 1, rowID: rowUUID,
                                    estate: "home", ts: 100, dropboxID: "d")

        let rows = try await store.queryEvents(dropboxID: nil)
        let row = try #require(rows.first)
        let payload = MootManager.projectEvent(row)
        #expect(payload.drawerId == rowUUID)
    }

    @Test("Empty rowIDStr projects to nil drawerId (wire null, never empty string)")
    func emptyRowIDProjectsNil() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }
        let store = try await manager.statsStore()

        try await store.insertEvent(kind: "think", nounType: 2, rowID: "",
                                    estate: "home", ts: 100, dropboxID: "d")

        let rows = try await store.queryEvents(dropboxID: nil)
        let row = try #require(rows.first)
        let payload = MootManager.projectEvent(row)
        #expect(payload.drawerId == nil)
    }

    @Test("EventPayload JSON always carries the drawerId key — null when nil")
    func drawerIdExplicitNull() throws {
        let withId = EventPayload(ts: "1970-01-01T00:00:00.000Z", kind: "capture",
                                  nounType: 1, estate: "e", dropbox: "d",
                                  drawerId: "ABC-123")
        let withIdObj = try jsonDict(withId)
        #expect((withIdObj["drawerId"] as? String) == "ABC-123")

        let withoutId = EventPayload(ts: "1970-01-01T00:00:00.000Z", kind: "capture",
                                     nounType: 1, estate: "e", dropbox: "d",
                                     drawerId: nil)
        let withoutIdObj = try jsonDict(withoutId)
        #expect(withoutIdObj.keys.contains("drawerId"), "drawerId key must be present")
        #expect(withoutIdObj["drawerId"] is NSNull, "nil drawerId must encode as JSON null")
    }

    @Test("eventsPayload rows include drawerId end-to-end")
    func eventsPayloadCarriesDrawerId() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }
        let store = try await manager.statsStore()

        let rowUUID = UUID().uuidString
        try await store.insertEvent(kind: "capture", nounType: 1, rowID: rowUUID,
                                    estate: "home", ts: 100, dropboxID: "d")

        let payload = try await manager.eventsPayload()
        #expect(payload.events.first?.drawerId == rowUUID)

        // The encoded envelope row carries the key on the wire.
        let obj = try jsonDict(payload)
        let events = obj["events"] as? [[String: Any]] ?? []
        let row = try #require(events.first)
        #expect((row["drawerId"] as? String) == rowUUID)
    }
}

// MARK: - L0: createdTs on graph nodes (edges no longer carry createdTs)

struct GraphCreatedTsTests {

    @Test("Stored graph snapshot decodes createdTs on nodes — extra edge keys tolerated")
    func proxyDecodesCreatedTs() throws {
        // The stored snapshot (written by the governor) may still carry nounType,
        // lastActiveTs, decayedWeight, and createdTs on edges — keys that were
        // removed from the wire format in FIX 2.  The synthesised decoder ignores
        // unknown keys, so existing snapshots decode without error.
        let wire = """
        {"nodes":[{"id":"n1","nounType":1,"communityId":0,"centrality":0.5,
                   "anomaly":false,"lastActiveTs":null,
                   "createdTs":"2026-06-09T20:13:05Z"}],
         "edges":[{"source":"n1","target":"n1","edgeType":"tunnel",
                   "weight":0.9,"decayedWeight":0.7,
                   "createdTs":"2026-06-09T20:13:05Z"},
                  {"source":"n1","target":"n1","edgeType":"kgFact",
                   "weight":0.4,"decayedWeight":0.3,"createdTs":null}],
         "structurePending":false,
         "communities":[]}
        """
        let proxy = try JSONDecoder().decode(StoredGraphPayload.self,
                                             from: Data(wire.utf8))
        // Node createdTs is still in the wire format — decoded correctly.
        #expect(proxy.nodes.first?.createdTs == "2026-06-09T20:13:05Z")
        // Edge createdTs was removed; extra key is silently ignored on decode.
        // Verify edges were decoded (not dropped) and have the expected weight.
        #expect(proxy.edges.count == 2)
        #expect(proxy.edges.first?.weight == 0.9)
    }

    @Test("StoredGraphPayload decode tolerates a snapshot that omits createdTs entirely")
    func proxyToleratesMissingCreatedTs() throws {
        let wire = """
        {"nodes":[{"id":"n1","nounType":1,"communityId":0,"centrality":0.5,
                   "anomaly":false,"lastActiveTs":null}],
         "edges":[{"source":"n1","target":"n1","edgeType":"tunnel",
                   "weight":0.9,"decayedWeight":0.7}],
         "structurePending":false}
        """
        let proxy = try JSONDecoder().decode(StoredGraphPayload.self,
                                             from: Data(wire.utf8))
        #expect(proxy.nodes.first?.createdTs == nil)
        // Edge has no createdTs field — verify it decoded correctly.
        #expect(proxy.edges.first?.tombstonedTs == nil)
        #expect(proxy.communities == nil)
    }

    @Test("Node payload re-encodes createdTs with an explicit null; edge payload omits it")
    func createdTsExplicitNull() throws {
        // Node: createdTs still on wire format — encodes as explicit null.
        let node = GraphNodePayload(id: "n1", communityId: 0,
                                    centrality: 0.5, anomaly: false,
                                    createdTs: nil, tombstonedTs: nil)
        let nodeObj = try jsonDict(node)
        #expect(nodeObj["createdTs"] is NSNull)
        // nounType and lastActiveTs removed from wire — must not appear in encoded output.
        #expect(!nodeObj.keys.contains("nounType"), "nounType must not be in wire output")
        #expect(!nodeObj.keys.contains("lastActiveTs"), "lastActiveTs must not be in wire output")

        // Edge: createdTs removed from wire format — must not appear in encoded output.
        let edge = GraphEdgePayload(source: "a", target: "b", edgeType: "kgFact",
                                    weight: 0.4, tombstonedTs: nil)
        let edgeObj = try jsonDict(edge)
        #expect(!edgeObj.keys.contains("createdTs"), "createdTs must not be in edge wire output")
        #expect(!edgeObj.keys.contains("decayedWeight"), "decayedWeight must not be in edge wire output")

        let stamped = GraphNodePayload(id: "n2", communityId: 1,
                                       centrality: 0.9, anomaly: true,
                                       createdTs: "2026-06-09T20:13:05Z",
                                       tombstonedTs: nil)
        let stampedObj = try jsonDict(stamped)
        #expect((stampedObj["createdTs"] as? String) == "2026-06-09T20:13:05Z")
    }
}

// MARK: - Dissolution: tombstonedTs on graph nodes/edges

struct GraphTombstonedTsTests {

    @Test("Stored graph snapshot decodes tombstonedTs on nodes and edges")
    func proxyDecodesTombstonedTs() throws {
        // A dead node ships the sentinel communityId -1 / centrality 0.0 and a
        // dead tunnel edge carries its real endpoints; live entries pin null.
        let wire = """
        {"nodes":[{"id":"n1","nounType":1,"communityId":0,"centrality":0.5,
                   "anomaly":false,"lastActiveTs":null,
                   "createdTs":"2026-06-01T08:00:00Z","tombstonedTs":null},
                  {"id":"n2","nounType":1,"communityId":-1,"centrality":0.0,
                   "anomaly":false,"lastActiveTs":null,
                   "createdTs":"2026-06-01T08:00:00Z",
                   "tombstonedTs":"2026-06-09T20:13:05Z"}],
         "edges":[{"source":"n1","target":"n2","edgeType":"tunnel",
                   "weight":0.9,"decayedWeight":0.7,
                   "createdTs":"2026-06-01T08:00:00Z",
                   "tombstonedTs":"2026-06-09T20:13:05Z"},
                  {"source":"n1","target":"n1","edgeType":"kgFact",
                   "weight":0.4,"decayedWeight":0.3,"createdTs":null,
                   "tombstonedTs":null}],
         "structurePending":false,
         "communities":[]}
        """
        let proxy = try JSONDecoder().decode(StoredGraphPayload.self,
                                             from: Data(wire.utf8))
        #expect(proxy.nodes.first?.tombstonedTs == nil)
        #expect(proxy.nodes.last?.tombstonedTs == "2026-06-09T20:13:05Z")
        #expect(proxy.nodes.last?.communityId == -1)
        #expect(proxy.nodes.last?.centrality == 0.0)
        #expect(proxy.edges.first?.tombstonedTs == "2026-06-09T20:13:05Z")
        // kgFact derived edges remain live-facts-only: tombstonedTs null.
        #expect(proxy.edges.last?.tombstonedTs == nil)
    }

    @Test("StoredGraphPayload decode tolerates a snapshot that omits tombstonedTs entirely")
    func proxyToleratesMissingTombstonedTs() throws {
        let wire = """
        {"nodes":[{"id":"n1","nounType":1,"communityId":0,"centrality":0.5,
                   "anomaly":false,"lastActiveTs":null}],
         "edges":[{"source":"n1","target":"n1","edgeType":"tunnel",
                   "weight":0.9,"decayedWeight":0.7}],
         "structurePending":false}
        """
        let proxy = try JSONDecoder().decode(StoredGraphPayload.self,
                                             from: Data(wire.utf8))
        #expect(proxy.nodes.first?.tombstonedTs == nil)
        #expect(proxy.edges.first?.tombstonedTs == nil)
    }

    @Test("Node and edge payloads re-encode tombstonedTs with an explicit null")
    func tombstonedTsExplicitNull() throws {
        let node = GraphNodePayload(id: "n1", communityId: 0,
                                    centrality: 0.5, anomaly: false,
                                    createdTs: nil, tombstonedTs: nil)
        let nodeObj = try jsonDict(node)
        #expect(nodeObj.keys.contains("tombstonedTs"), "tombstonedTs key must be present")
        #expect(nodeObj["tombstonedTs"] is NSNull, "nil tombstonedTs must encode as JSON null")

        let edge = GraphEdgePayload(source: "a", target: "b", edgeType: "kgFact",
                                    weight: 0.4, tombstonedTs: nil)
        let edgeObj = try jsonDict(edge)
        #expect(edgeObj.keys.contains("tombstonedTs"))
        #expect(edgeObj["tombstonedTs"] is NSNull)
    }

    @Test("A dead-node fixture round-trips tombstonedTs decode → encode — extra keys tolerated")
    func deadNodeRoundTrip() throws {
        // The stored snapshot may carry nounType and lastActiveTs (removed from
        // wire format in FIX 2).  They are silently ignored on decode.
        let wire = """
        {"id":"dead-1","nounType":0,"communityId":-1,"centrality":0.0,
         "anomaly":false,"lastActiveTs":null,
         "createdTs":"2026-06-01T08:00:00Z",
         "tombstonedTs":"2026-06-09T20:13:05Z"}
        """
        let node = try JSONDecoder().decode(GraphNodePayload.self,
                                            from: Data(wire.utf8))
        #expect(node.tombstonedTs == "2026-06-09T20:13:05Z")

        let obj = try jsonDict(node)
        #expect((obj["tombstonedTs"] as? String) == "2026-06-09T20:13:05Z")
        #expect((obj["createdTs"] as? String) == "2026-06-01T08:00:00Z")
        #expect((obj["communityId"] as? Int) == -1)
        #expect((obj["centrality"] as? Double) == 0.0)
    }
}

// MARK: - L3: community enrichment at the proxy boundary

struct CommunityEnrichmentTests {

    @Test("A known FDC code enriches to its bundled-taxonomy label")
    func knownCodeGetsLabel() throws {
        // "000" carries a label in the bundled FDC frame (FDCRuntimeTests pins
        // this). Compare against the runtime lookup rather than hardcoding the
        // heading text, so a frame-data refresh does not break this test.
        let expected = try #require(FDC.label(for: "000"))
        let enriched = MootManager.enrichCommunities([
            ARIACommunityDescriptor(id: 0, size: 9, dominantUdcCode: "000")
        ])
        #expect(enriched.count == 1)
        #expect(enriched.first?.id == 0)
        #expect(enriched.first?.size == 9)
        #expect(enriched.first?.label == expected)
    }

    @Test("Unknown and empty codes enrich to a nil label (JSON null)")
    func unknownCodeNullLabel() throws {
        let enriched = MootManager.enrichCommunities([
            ARIACommunityDescriptor(id: 0, size: 5, dominantUdcCode: "999.99999"),
            ARIACommunityDescriptor(id: 1, size: 2, dominantUdcCode: ""),
        ])
        #expect(enriched.count == 2)
        #expect(enriched[0].label == nil)
        #expect(enriched[1].label == nil)

        // On the wire the label key is present with an explicit null.
        let obj = try jsonDict(enriched[0])
        #expect(obj.keys.contains("label"))
        #expect(obj["label"] is NSNull)
    }

    @Test("dominantUdcCode never crosses to the browser — only id/label/size")
    func dominantUdcCodeDropped() throws {
        let enriched = MootManager.enrichCommunities([
            ARIACommunityDescriptor(id: 3, size: 7, dominantUdcCode: "000")
        ])
        let obj = try jsonDict(try #require(enriched.first))
        #expect(Set(obj.keys) == ["id", "label", "size"])
        #expect((obj["id"] as? Int) == 3)
        #expect((obj["size"] as? Int) == 7)

        // Serialized bytes carry no trace of the raw classification code key.
        let data = try APIJSON.encode(enriched)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(!text.contains("dominantUdcCode"))
    }

    @Test("StoredGraphPayload descriptors with a missing dominantUdcCode enrich to nil label")
    func missingCodeTolerated() throws {
        let wire = """
        {"nodes":[],"edges":[],"structurePending":false,
         "communities":[{"id":0,"size":4}]}
        """
        let proxy = try JSONDecoder().decode(StoredGraphPayload.self,
                                             from: Data(wire.utf8))
        let enriched = MootManager.enrichCommunities(proxy.communities ?? [])
        #expect(enriched.first?.label == nil)
        #expect(enriched.first?.size == 4)
    }
}

// MARK: - Topology enrichment cache

struct TopologyEnrichmentCacheTests {

    /// Minimal valid snapshot JSON for one node + one community, with a
    /// distinguishing generatedTs so cache turnover is observable.
    private func snapshotJSON(generatedTs: String, code: String) -> Data {
        Data("""
        {"nodes":[{"id":"n1","nounType":0,"communityId":0,"centrality":1.0,
          "anomaly":false,"lastActiveTs":null,"createdTs":null,"tombstonedTs":null}],
         "edges":[],
         "structurePending":false,
         "communities":[{"id":0,"size":1,"dominantUdcCode":"\(code)"}],
         "generatedTs":"\(generatedTs)"}
        """.utf8)
    }

    @Test("Repeated polls of an unchanged snapshot serve the cached enrichment identically")
    func cacheHitServesIdenticalPayload() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }
        let store = try await manager.statsStore()

        try await store.writeTopologySnapshot(
            estate: "estate-cache", generatedAt: Date(timeIntervalSince1970: 1_000),
            payload: snapshotJSON(generatedTs: "T1", code: "510"))

        let first = try await manager.graphPayload(now: Date(timeIntervalSince1970: 2_000))
        let second = try await manager.graphPayload(now: Date(timeIntervalSince1970: 2_005))

        // Cache hit must be invisible in the result: same nodes, same
        // enriched communities, same generatedTs.
        #expect(first.generatedTs == "T1")
        #expect(second.generatedTs == "T1")
        #expect(first.nodes == second.nodes)
        #expect(first.communities == second.communities)
    }

    @Test("A new snapshot invalidates the cache — fresh decode and enrichment")
    func newSnapshotInvalidatesCache() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }
        let store = try await manager.statsStore()

        try await store.writeTopologySnapshot(
            estate: "estate-cache", generatedAt: Date(timeIntervalSince1970: 1_000),
            payload: snapshotJSON(generatedTs: "T1", code: "510"))
        _ = try await manager.graphPayload(now: Date(timeIntervalSince1970: 2_000))

        // Governor writes a NEW snapshot (different bytes): the next poll
        // must serve the new content, not the cached old enrichment.
        try await store.writeTopologySnapshot(
            estate: "estate-cache", generatedAt: Date(timeIntervalSince1970: 1_300),
            payload: snapshotJSON(generatedTs: "T2", code: "700"))
        let after = try await manager.graphPayload(now: Date(timeIntervalSince1970: 2_300))

        #expect(after.generatedTs == "T2")
    }
}

// MARK: - FIX 2 payload size — dropped fields must not appear in encoded output

struct GraphPayloadSizeTests {

    /// Build a `GraphPayload` containing 50 k nodes and verify two things:
    ///
    /// 1. **Absent fields**: `nounType`, `lastActiveTs` (nodes) and `decayedWeight`,
    ///    `createdTs` (edges) must never appear in the encoded JSON.
    /// 2. **Size ceiling**: the 50 k-node array must encode to fewer than 6 MB.
    ///    The old format (8 fields per node + 7 fields per edge) would have been
    ///    ~7.5 MB for the same fixture; the new format trims ~1.5 MB off nodes alone.
    @Test("50k-node GraphPayload encodes without dropped fields and within size ceiling")
    func fiftyKNodePayloadSizeAndFieldAbsence() throws {
        // Build 50,000 minimal nodes and a small edge set to exercise both types.
        // IDs are short strings to keep the fixture realistic but not bloated by UUIDs.
        let nodes = (0..<50_000).map { i in
            GraphNodePayload(id: "\(i)", communityId: i % 16,
                             centrality: 0.5, anomaly: false,
                             createdTs: nil, tombstonedTs: nil)
        }
        let edges = (0..<100).map { i in
            GraphEdgePayload(source: "\(i)", target: "\(i + 1)",
                             edgeType: "tunnel", weight: 0.8,
                             tombstonedTs: nil)
        }
        let payload = GraphPayload(
            nodes: nodes,
            edges: edges,
            communities: [],
            analytics: [],
            structurePending: false,
            pending: [],
            generatedTs: "2026-07-05T00:00:00.000Z",
            estate: "test",
            snapshotTs: "2026-07-05T00:00:00.000Z"
        )

        let data = try APIJSON.encode(payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        // --- Size gate: new format must be under 6 MB ---
        // 50 k nodes × ~110 bytes + edges + envelope ≈ 5.6 MB.
        // With the old format (+ nounType + lastActiveTs per node) it would be
        // ~7.5 MB — the ceiling of 6 MB would NOT have passed before FIX 2.
        #expect(data.count < 6_000_000,
                "50k-node payload must be < 6 MB; got \(data.count) bytes")

        // --- Field-absence gate: dropped fields must not appear in wire output ---
        #expect(!text.contains("\"nounType\""),
                "nounType must not appear in wire output (removed FIX 2)")
        #expect(!text.contains("\"lastActiveTs\""),
                "lastActiveTs must not appear in wire output (removed FIX 2)")
        #expect(!text.contains("\"decayedWeight\""),
                "decayedWeight must not appear in wire output (removed FIX 2)")
        // createdTs appears on NODES (kept) but must not appear on EDGES (removed).
        // Validate indirectly: after dropping all node entries, no edge createdTs remains.
        // The simplest check: ensure the total createdTs count matches the node count
        // (one explicit null per node, zero per edge).
        let createdTsCount = text.components(separatedBy: "\"createdTs\"").count - 1
        // createdTs appears on nodes (one explicit null each) but not on edges.
        // So the count must equal exactly the number of nodes.
        #expect(createdTsCount == nodes.count, "createdTs count must equal node count (not edges)")
    }
}
