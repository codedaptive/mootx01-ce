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

// MARK: - L0: createdTs on graph nodes and explicit edges

struct GraphCreatedTsTests {

    @Test("Stored graph snapshot decodes createdTs on nodes and explicit edges")
    func proxyDecodesCreatedTs() throws {
        // The stored snapshot (written by the governor) may still carry nounType,
        // lastActiveTs and decayedWeight are legacy extras. Edge createdTs is
        // intentionally retained so the compact projection can restore replay.
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
        // Explicit edge birth is retained; derived kgFact has no single birth.
        #expect(proxy.edges.count == 2)
        #expect(proxy.edges.first?.weight == 0.9)
        #expect(proxy.edges.first?.createdTs == "2026-06-09T20:13:05Z")
        #expect(proxy.edges.first?.createdEpochSeconds == 1_781_035_985)
        #expect(proxy.edges.last?.createdTs == nil)
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

    @Test("Stored node and explicit-edge shapes preserve createdTs")
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

        // Derived edge: no factual birth, so the optional key stays absent.
        let edge = GraphEdgePayload(source: "a", target: "b", edgeType: "kgFact",
                                    weight: 0.4, tombstonedTs: nil)
        let edgeObj = try jsonDict(edge)
        #expect(!edgeObj.keys.contains("createdTs"), "createdTs must not be in edge wire output")
        #expect(!edgeObj.keys.contains("decayedWeight"), "decayedWeight must not be in edge wire output")

        let tunnel = GraphEdgePayload(source: "a", target: "b", edgeType: "tunnel",
                                      weight: 1.0, createdTs: "2026-06-09T20:13:05Z",
                                      tombstonedTs: nil)
        let tunnelObj = try jsonDict(tunnel)
        #expect((tunnelObj["createdTs"] as? String) == "2026-06-09T20:13:05Z")

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
        #expect(proxy.edges.first?.createdEpochSeconds == 1_780_300_800)
        #expect(proxy.edges.first?.tombstonedEpochSeconds == 1_781_035_985)
        // kgFact derived edges remain live-facts-only: tombstonedTs null.
        #expect(proxy.edges.last?.tombstonedTs == nil)
    }

    @Test("Compact edges append factual epoch seconds and leave derived edges four fields")
    func compactEdgeTemporalShape() throws {
        let nodes = [
            GraphNodePayload(id: "a", communityId: 0, centrality: 1, anomaly: false,
                             createdTs: nil, tombstonedTs: nil),
            GraphNodePayload(id: "b", communityId: 0, centrality: 0.5, anomaly: false,
                             createdTs: nil, tombstonedTs: nil),
        ]
        let edges = [
            GraphEdgePayload(source: "a", target: "b", edgeType: "tunnel", weight: 1,
                             createdTs: "2026-06-01T08:00:00Z",
                             tombstonedTs: "2026-06-09T20:13:05Z"),
            GraphEdgePayload(source: "a", target: "b", edgeType: "kgFact", weight: 0.3,
                             createdTs: nil, tombstonedTs: nil),
        ]
        let payload = GraphPayload(nodes: nodes, edges: edges, communities: [], analytics: [],
                                   structurePending: false, pending: [], generatedTs: nil,
                                   estate: "test", snapshotTs: "2026-06-10T00:00:00Z")
        let obj = try #require(JSONSerialization.jsonObject(with: APIJSON.encode(payload)) as? [String: Any])
        let compact = try #require(obj["edges"] as? [[Any]])
        #expect((obj["edgeTimeOrigin"] as? NSNumber)?.int64Value == 1_780_300_800)
        #expect(compact[0].count == 6)
        #expect((compact[0][4] as? NSNumber)?.int64Value == 0)
        #expect((compact[0][5] as? NSNumber)?.int64Value == 735_185)
        #expect(compact[1].count == 4)
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

// MARK: - V2-P1b: per-node classification codes, dictionary-encoded on GraphPayload

struct GraphNodeCodesTests {

    @Test("codes dedupe in first-seen order; codeIndex is parallel to ids with -1 for no code")
    func codesDedupeFirstSeenOrder() throws {
        // n1="657", n2="615.85", n3="657" (repeat — must reuse n1's slot, not
        // append a duplicate), n4 has no udcCode at all (absent → sentinel -1).
        let nodes = [
            GraphNodePayload(id: "n1", communityId: 0, centrality: 0.1, anomaly: false,
                             createdTs: nil, tombstonedTs: nil, udcCode: "657"),
            GraphNodePayload(id: "n2", communityId: 0, centrality: 0.2, anomaly: false,
                             createdTs: nil, tombstonedTs: nil, udcCode: "615.85"),
            GraphNodePayload(id: "n3", communityId: 0, centrality: 0.3, anomaly: false,
                             createdTs: nil, tombstonedTs: nil, udcCode: "657"),
            GraphNodePayload(id: "n4", communityId: 0, centrality: 0.4, anomaly: false,
                             createdTs: nil, tombstonedTs: nil, udcCode: nil),
        ]
        let payload = GraphPayload(
            nodes: nodes, edges: [], communities: [], analytics: [],
            structurePending: false, pending: [], generatedTs: nil,
            estate: "test", snapshotTs: "2026-07-09T00:00:00.000Z"
        )
        let obj = try jsonDict(payload)
        #expect((obj["codes"] as? [String]) == ["657", "615.85"])
        #expect((obj["codeIndex"] as? [Int]) == [0, 1, 0, -1])
    }

    @Test("Empty-string udcCode is the same sentinel as absent — never a dictionary entry")
    func emptyCodeIsSentinelNotDictionaryEntry() throws {
        let nodes = [
            GraphNodePayload(id: "n1", communityId: 0, centrality: 0.1, anomaly: false,
                             createdTs: nil, tombstonedTs: nil, udcCode: ""),
            GraphNodePayload(id: "n2", communityId: 0, centrality: 0.2, anomaly: false,
                             createdTs: nil, tombstonedTs: nil, udcCode: "540"),
        ]
        let payload = GraphPayload(
            nodes: nodes, edges: [], communities: [], analytics: [],
            structurePending: false, pending: [], generatedTs: nil,
            estate: "test", snapshotTs: "2026-07-09T00:00:00.000Z"
        )
        let obj = try jsonDict(payload)
        #expect((obj["codes"] as? [String]) == ["540"])
        #expect((obj["codeIndex"] as? [Int]) == [-1, 0])
    }

    @Test("StoredGraphPayload tolerates a snapshot predating udcCode — every node gets -1")
    func decodeToleratesSnapshotPredatingUdcCode() throws {
        let wire = """
        {"nodes":[{"id":"n1","communityId":0,"centrality":0.5,"anomaly":false},
                  {"id":"n2","communityId":1,"centrality":0.6,"anomaly":false}],
         "edges":[],
         "structurePending":false}
        """
        let proxy = try JSONDecoder().decode(StoredGraphPayload.self, from: Data(wire.utf8))
        #expect(proxy.nodes.map(\.udcCode) == [nil, nil])

        let payload = GraphPayload(
            nodes: proxy.nodes, edges: proxy.edges, communities: [], analytics: [],
            structurePending: false, pending: [], generatedTs: nil,
            estate: "test", snapshotTs: "2026-07-09T00:00:00.000Z"
        )
        let obj = try jsonDict(payload)
        #expect((obj["codes"] as? [String]) == [])
        #expect((obj["codeIndex"] as? [Int]) == [-1, -1])
    }

    @Test("Node payload re-encodes udcCode with an explicit null when absent")
    func udcCodeExplicitNullWhenAbsent() throws {
        let node = GraphNodePayload(id: "n1", communityId: 0, centrality: 0.5, anomaly: false,
                                    createdTs: nil, tombstonedTs: nil, udcCode: nil)
        let obj = try jsonDict(node)
        #expect(obj.keys.contains("udcCode"), "udcCode key must be present")
        #expect(obj["udcCode"] is NSNull, "nil udcCode must encode as JSON null")

        let coded = GraphNodePayload(id: "n2", communityId: 0, centrality: 0.5, anomaly: false,
                                     createdTs: nil, tombstonedTs: nil, udcCode: "657")
        let codedObj = try jsonDict(coded)
        #expect((codedObj["udcCode"] as? String) == "657")
    }

    @Test("Local-fallback GraphPayload (no nodes) emits codes/codeIndex as empty, never null")
    func fallbackEmitsEmptyArraysNotNull() throws {
        let payload = GraphPayload(
            nodes: [], edges: [], communities: [], analytics: [],
            structurePending: true,
            pending: ["topology snapshot not yet available"],
            generatedTs: nil, estate: "all", snapshotTs: "2026-07-09T00:00:00.000Z"
        )
        let obj = try jsonDict(payload)
        #expect((obj["codes"] as? [Any])?.isEmpty == true)
        #expect((obj["codeIndex"] as? [Any])?.isEmpty == true)
        #expect(!(obj["codes"] is NSNull))
        #expect(!(obj["codeIndex"] is NSNull))
    }
}

// MARK: - L3: community enrichment at the proxy boundary

struct CommunityEnrichmentTests {

    @Test("A known FDC code enriches to its bundled-taxonomy label")
    func knownCodeGetsLabel() throws {
        // "006" carries a label in the bundled FDC frame (FDCRuntimeTests pins
        // this). Compare against the runtime lookup rather than hardcoding the
        // heading text, so a frame-data refresh does not break this test.
        let expected = try #require(FDC.label(for: "006"))
        let enriched = MootManager.enrichCommunities([
            ARIACommunityDescriptor(id: 0, size: 9, dominantUdcCode: "006")
        ])
        #expect(enriched.count == 1)
        #expect(enriched.first?.id == 0)
        #expect(enriched.first?.size == 9)
        #expect(enriched.first?.code == "006")
        #expect(enriched.first?.label == expected)
    }

    @Test("Unknown, empty, and 000 codes enrich to nil code/label (JSON null)")
    func unknownCodeNullLabel() throws {
        let enriched = MootManager.enrichCommunities([
            ARIACommunityDescriptor(id: 0, size: 5, dominantUdcCode: "999.99999"),
            ARIACommunityDescriptor(id: 1, size: 2, dominantUdcCode: ""),
            ARIACommunityDescriptor(id: 2, size: 7, dominantUdcCode: "000"),
        ])
        #expect(enriched.count == 3)
        #expect(enriched[0].label == nil)
        #expect(enriched[1].label == nil)
        #expect(enriched[2].code == nil)
        #expect(enriched[2].label == nil)

        // On the wire the label key is present with an explicit null.
        let obj = try jsonDict(enriched[0])
        #expect(obj.keys.contains("label"))
        #expect(obj["label"] is NSNull)
    }

    @Test("dominantUdcCode crosses as `code` — wire shape is id/code/label/size")
    func dominantUdcCodePassedThrough() throws {
        // The community's classification code crosses the surface on the same
        // basis as /api/lattice (a pure function of the pinned public frame,
        // never memory content); the dashboard derives community colors from
        // its digits. Only the wire key changes: dominantUdcCode → code.
        let enriched = MootManager.enrichCommunities([
            ARIACommunityDescriptor(id: 3, size: 7, dominantUdcCode: "006")
        ])
        let obj = try jsonDict(try #require(enriched.first))
        #expect(Set(obj.keys) == ["id", "code", "label", "size"])
        #expect((obj["id"] as? Int) == 3)
        #expect((obj["code"] as? String) == "006")
        #expect((obj["size"] as? Int) == 7)

        // The ARIA-side key never leaks; empty and 000 codes become explicit nulls.
        let data = try APIJSON.encode(enriched)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(!text.contains("dominantUdcCode"))
        let emptied = MootManager.enrichCommunities([
            ARIACommunityDescriptor(id: 4, size: 1, dominantUdcCode: ""),
            ARIACommunityDescriptor(id: 5, size: 1, dominantUdcCode: "000"),
        ])
        let emptyObj = try jsonDict(try #require(emptied.first))
        #expect(emptyObj["code"] is NSNull)
        let rootObj = try jsonDict(try #require(emptied.last))
        #expect(rootObj["code"] is NSNull)
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

        // Cache hit must be invisible in the result: both calls return the same
        // generatedTs (from the snapshot) and the same enriched communities.
        // snapshotTs legitimately differs (caller-supplied `now` varies between
        // polls), so byte-for-byte equality is not the right assertion here.
        #expect(first.generatedTs == "T1")
        #expect(second.generatedTs == "T1")
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

    /// Build a `GraphPayload` containing 50 k nodes and 100 edges and verify:
    ///
    /// 1. **Compact wire format (FIX 2b)**: `ids`, `communityId`, `centrality`,
    ///    `anomaly`, `createdTs`, `tombstoned` parallel arrays are present;
    ///    old per-object `nodes` key is absent; edges are compact `[[si,ti,w,et]]`.
    /// 2. **Absent fields from FIX 2**: `nounType`, `lastActiveTs` (stored-snapshot
    ///    fields), `decayedWeight` (edge field) must not appear on the wire.
    /// 3. **Size ceiling**: 50 k-node payload must encode to fewer than 5 MB.
    ///    The per-object format (before FIX 2b) would have been ~5.6 MB for the
    ///    same fixture; the compact format is ~1 MB (short IDs used in test).
    /// 4. **Code dictionary (V2-P1b)**: ~135 distinct classification codes
    ///    cycled across the 50k nodes dictionary-encode as `codes`/`codeIndex`
    ///    without meaningfully moving the payload size — the dictionary is
    ///    sized to the distinct-code count, not the node count.
    @Test("50k-node GraphPayload encodes in compact parallel format and within 5 MB ceiling")
    func fiftyKNodePayloadSizeAndFieldAbsence() throws {
        // Build 50,000 minimal nodes and a small edge set to exercise both types.
        // IDs are short strings to keep the fixture realistic but not bloated by UUIDs.
        // ~135 distinct classification codes cycled across the nodes (V2-P1b) —
        // exercises the dictionary encoder at a realistic distinct-code count.
        let distinctCodeCount = 135
        let nodes = (0..<50_000).map { i in
            GraphNodePayload(id: "\(i)", communityId: i % 16,
                             centrality: 0.5, anomaly: false,
                             createdTs: nil, tombstonedTs: nil,
                             udcCode: String(format: "%03d", i % distinctCodeCount))
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

        // --- Size gate: compact format + 135-code dictionary must be under 5 MB ---
        // Compact parallel arrays + [[si,ti,w,et]] edges: ~1 MB for this short-ID fixture.
        // The per-object format (pre-FIX 2b) was ~5.6 MB — compact saves 4.6 MB. The
        // 135-entry code dictionary adds well under 1 KB (dictionary sized to distinct
        // codes, not the 50k node count) plus one Int per node for codeIndex.
        #expect(data.count < 5_000_000,
                "50k-node compact payload with 135-code dictionary must be < 5 MB; got \(data.count) bytes")

        // --- Compact format presence gate ---
        // Top-level parallel-array keys must be present.
        #expect(text.contains("\"ids\""),
                "compact format must emit \"ids\" parallel array key")
        #expect(text.contains("\"communityId\""),
                "compact format must emit \"communityId\" parallel array key")
        #expect(text.contains("\"centrality\""),
                "compact format must emit \"centrality\" parallel array key")
        #expect(text.contains("\"codes\""),
                "compact format must emit \"codes\" dictionary key (V2-P1b)")
        #expect(text.contains("\"codeIndex\""),
                "compact format must emit \"codeIndex\" parallel array key (V2-P1b)")
        // Legacy per-object \"nodes\" key must NOT appear (replaced by parallel arrays).
        #expect(!text.contains("\"nodes\""),
                "compact format must not emit old per-object \"nodes\" key")
        // Edges in compact [[si,ti,w,et]] format have no \"source\" or \"target\" keys.
        #expect(!text.contains("\"source\""),
                "compact edges must not contain per-edge \"source\" key")
        #expect(!text.contains("\"target\""),
                "compact edges must not contain per-edge \"target\" key")

        // --- Field-absence gate: dropped fields must not appear in wire output ---
        #expect(!text.contains("\"nounType\""),
                "nounType must not appear in wire output (removed FIX 2)")
        #expect(!text.contains("\"lastActiveTs\""),
                "lastActiveTs must not appear in wire output (removed FIX 2)")
        #expect(!text.contains("\"decayedWeight\""),
                "decayedWeight must not appear in wire output (removed FIX 2)")

        // createdTs appears once (as the parallel array key) not 50k times.
        let createdTsKeyCount = text.components(separatedBy: "\"createdTs\"").count - 1
        #expect(createdTsKeyCount == 1, "createdTs must appear once (parallel array key), got \(createdTsKeyCount)")

        // --- Code dictionary gate (V2-P1b): sized to distinct codes, never per-node ---
        // "udcCode" is a stored-node field, not a GraphPayload wire key — it must not
        // leak onto the compact wire (codes/codeIndex are the only wire representation).
        #expect(!text.contains("\"udcCode\""),
                "udcCode must not appear on the GraphPayload wire (dictionary-encoded instead)")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let codes = obj?["codes"] as? [String] ?? []
        let codeIndex = obj?["codeIndex"] as? [Int] ?? []
        #expect(codes.count == distinctCodeCount,
                "codes dictionary must hold exactly \(distinctCodeCount) distinct entries, got \(codes.count)")
        #expect(codeIndex.count == 50_000,
                "codeIndex must be parallel to ids (50k entries), got \(codeIndex.count)")
        #expect(codeIndex.allSatisfy { $0 >= 0 && $0 < distinctCodeCount },
                "every codeIndex entry must be a valid index into codes (no -1s expected — every node has a code)")
    }
}
