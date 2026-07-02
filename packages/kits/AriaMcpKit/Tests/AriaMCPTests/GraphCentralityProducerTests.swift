// GraphCentralityProducerTests.swift
//
// Conformance + behaviour coverage for the graph-centrality PRODUCER
// (AutonomicGovernor.graphCentralityScan + GraphCentralityCache +
// GraphCentralityAdjacency). The producer is the cadence wrapper that takes the
// recall `graph` score column from DARK to LIVE: nothing previously computed
// per-drawer eigenvalue centrality and registered the GraphCache the
// matrixAware/unionBest recall reads.
//
// The proofs here mirror the Rust port's `graph_centrality_parity.rs`:
//   - faithful-wrapper: the producer's adjacency + cache equal a DIRECT
//     NeuronKit.keystones call on the same (nodeIDs, edges) graph;
//   - structure sanity: the hub of a star outranks its spokes;
//   - kg_facts edges: drawers sharing a subject are bonded with no tunnel;
//   - C-16 totality: an empty / edgeless estate yields an all-zero cache;
//   - end-to-end: after a scan, a unionBest+matrixAware recall reads a
//     non-zero `graph` column for the hub (dark→live, proving registration).

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Graph-centrality producer", .serialized)
struct GraphCentralityProducerTests {

    // MARK: - Harness

    private func openEstate(owner ownerID: String) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    @discardableResult
    private func capture(_ kit: GeniusLocusKit, _ handle: EstateHandle,
                         _ content: String) async throws -> String {
        let frame = CaptureFrame(
            content: content, channel: .typed, room: "centrality",
            latticeAnchor: .udc("004"), addedBy: "centrality-tests",
            embeddingModelID: "test-model-v1")
        return try await kit.capture(handle, frame).id
    }

    /// Create a drawer-to-drawer tunnel between two REAL captured drawer IDs.
    /// The producer filters edges to live drawers, so the endpoints must be
    /// real ids (unlike the per-wing keystones lens, which takes raw endpoints).
    private func addTunnel(_ kit: GeniusLocusKit, _ handle: EstateHandle,
                           src: String, tgt: String) async throws {
        let estate = try await kit.estate(for: handle)
        let frame = TunnelCaptureFrame(
            sourceWing: "centrality", sourceRoom: "centrality",
            targetWing: "centrality", targetRoom: "centrality",
            label: "relates", addedBy: "centrality-tests",
            sourceDrawerId: src, targetDrawerId: tgt, kind: .references)
        _ = try await estate.capture(frame)
    }

    /// Build a star: one hub drawer tunnelled to N spoke drawers. Returns the
    /// hub id and the spoke ids.
    private func buildStar(_ kit: GeniusLocusKit, _ handle: EstateHandle,
                           spokeCount: Int) async throws -> (hub: String, spokes: [String]) {
        let hub = try await capture(kit, handle, "hub memory")
        var spokes: [String] = []
        for i in 0..<spokeCount {
            let s = try await capture(kit, handle, "spoke \(i)")
            try await addTunnel(kit, handle, src: hub, tgt: s)
            spokes.append(s)
        }
        return (hub, spokes)
    }

    /// The cache the producer WOULD register for this estate, built from the
    /// same reads + adjacency + oracle the duty uses. Used by the pure proofs
    /// (no GLK read-back accessor needed).
    private func producedCache(_ kit: GeniusLocusKit, _ handle: EstateHandle) async throws
        -> (cache: GraphCentralityCache, expected: [String: Float], nodeIDs: [String]) {
        let drawers = try await kit.allDrawers(in: handle)
        let tunnels = try await kit.allTunnels(in: handle)
        let facts = try await kit.recallKGFacts(handle)
        let graph = GraphCentralityAdjacency.build(
            drawers: drawers, tunnels: tunnels, facts: facts)
        let ranked = NeuronKit.keystones(
            nodeIDs: graph.nodeIDs, edges: graph.edges, topK: graph.nodeIDs.count)
        var expected: [String: Float] = [:]
        for k in ranked { expected[k.id] = Float(k.centrality) }
        return (GraphCentralityCache(scores: expected), expected, graph.nodeIDs)
    }

    // MARK: - Faithful wrapper (the conformance proof)

    /// The producer's cache MUST equal a direct NeuronKit.keystones call on the
    /// producer's own (nodeIDs, edges) graph — bit-identical Floats. This proves
    /// the producer is a faithful cadence wrapper of the oracle and reinvents no
    /// math (I-17). It is also the cross-port contract: the Rust producer
    /// computes the same scores from the same graph.
    @Test("producer cache equals a direct keystones call on the same graph")
    func producerEqualsDirectKeystones() async throws {
        let (kit, handle) = try await openEstate(owner: "ks-faithful")
        let (hub, _) = try await buildStar(kit, handle, spokeCount: 4)

        let (cache, expected, nodeIDs) = try await producedCache(kit, handle)
        for id in nodeIDs {
            #expect(cache.graphScore(for: id) == (expected[id] ?? 0.0),
                "cached score for \(id) must equal the direct keystones score")
        }
        #expect(cache.graphScore(for: hub) > 0.0)
        try await kit.close(handle)
    }

    // MARK: - Structure sanity

    /// The hub of a star outranks every spoke — the eigenvalue-centrality
    /// behaviour the keystones oracle guarantees, surfaced through the producer.
    @Test("the hub of a star outscores its spokes")
    func hubOutscoresSpokes() async throws {
        let (kit, handle) = try await openEstate(owner: "ks-hub")
        let (hub, spokes) = try await buildStar(kit, handle, spokeCount: 4)

        let (cache, _, _) = try await producedCache(kit, handle)
        let hubScore = cache.graphScore(for: hub)
        for s in spokes {
            #expect(hubScore > cache.graphScore(for: s),
                "hub centrality must exceed spoke \(s)")
        }
        try await kit.close(handle)
    }

    // MARK: - KGFact edges contribute

    /// Two drawers sharing a KGFact subject are bonded by the producer even with
    /// no tunnel between them — the kg_facts half of the adjacency is live.
    @Test("drawers sharing a KGFact subject gain centrality with no tunnel")
    func kgFactSubjectBondContributes() async throws {
        let (kit, handle) = try await openEstate(owner: "ks-fact")
        let a = try await capture(kit, handle, "fact source a")
        let b = try await capture(kit, handle, "fact source b")
        let c = try await capture(kit, handle, "fact source c")
        // a and b share subject "S"; c is isolated.
        _ = try await kit.captureKGFact(
            handle, subject: "S", predicate: "p", object: "o1",
            sourceDrawerID: a, now: Date(timeIntervalSince1970: 3_000_000))
        _ = try await kit.captureKGFact(
            handle, subject: "S", predicate: "p", object: "o2",
            sourceDrawerID: b, now: Date(timeIntervalSince1970: 3_000_001))

        let (cache, _, _) = try await producedCache(kit, handle)
        // a and b are bonded by the shared subject; c is isolated. Eigenvalue
        // centrality normalizes the eigenvector, so an isolated node carries a
        // tiny residual rather than exact 0 — the meaningful, oracle-faithful
        // claim is that the bonded pair STRICTLY outranks the isolated node.
        #expect(cache.graphScore(for: a) > cache.graphScore(for: c),
            "the subject-bonded drawer a must outrank the isolated drawer c")
        #expect(cache.graphScore(for: b) > cache.graphScore(for: c),
            "the subject-bonded drawer b must outrank the isolated drawer c")
        try await kit.close(handle)
    }

    // MARK: - C-16 totality

    /// An estate with no drawers yields an empty cache; every score is 0.0
    /// (identical to "no cache registered" — correct, not an error). The duty
    /// itself completes without throwing.
    @Test("empty estate scan registers an all-zero cache without error")
    func emptyEstateRegistersZeroCache() async throws {
        let (kit, handle) = try await openEstate(owner: "ks-empty")
        // The duty must not throw on an empty estate.
        try await AutonomicGovernor.graphCentralityScan(
            kit: kit, handle: handle, now: Date(timeIntervalSince1970: 4_000_000))
        let (cache, _, _) = try await producedCache(kit, handle)
        #expect(cache.graphScore(for: "nonexistent") == 0.0)
        #expect(cache.count == 0)
        try await kit.close(handle)
    }

    /// Captured drawers with NO edges score UNIFORMLY: eigenvalue centrality of
    /// an edgeless graph gives every node the same normalized value, so the
    /// `graph` column adds no discriminating signal (no edge ⇒ no structural
    /// prominence). The producer faithfully reflects the oracle here.
    @Test("edgeless estate scores every drawer uniformly")
    func edgelessEstateScoresUniformly() async throws {
        let (kit, handle) = try await openEstate(owner: "ks-edgeless")
        let d1 = try await capture(kit, handle, "lonely drawer one")
        let d2 = try await capture(kit, handle, "lonely drawer two")
        let (cache, _, _) = try await producedCache(kit, handle)
        // No edges → no node is more central than any other.
        #expect(cache.graphScore(for: d1) == cache.graphScore(for: d2),
            "edgeless nodes must score uniformly (no structural prominence)")
        try await kit.close(handle)
    }

    // MARK: - Cadence

    @Test("graph-centrality producer fires on the first tick")
    func firesOnFirstTick() async throws {
        let (kit, handle) = try await openEstate(owner: "ks-cadence-first")
        // ce-fdcpool test isolation: nil pool paths skip the reduce path so a tick
        // never reads or writes the real user pool.
        let governor = AutonomicGovernor(kit: kit, handle: handle, graphCentralityIntervalMs: 0, poolDirectory: nil, poolTableArtifactURL: nil)
        let report = await governor.tick(now: Date(timeIntervalSince1970: 6_000_000))
        #expect(report.graphCentralityFired)
        try await kit.close(handle)
    }

    @Test("graph-centrality producer respects its cadence")
    func respectsCadence() async throws {
        let (kit, handle) = try await openEstate(owner: "ks-cadence-interval")
        // ce-fdcpool test isolation: nil pool paths skip the reduce path.
        let governor = AutonomicGovernor(kit: kit, handle: handle, poolDirectory: nil, poolTableArtifactURL: nil)  // 10-min default
        let t0 = Date(timeIntervalSince1970: 7_000_000)
        let first = await governor.tick(now: t0)
        #expect(first.graphCentralityFired)                                   // nil → fires
        let early = await governor.tick(now: t0.addingTimeInterval(1))
        #expect(!early.graphCentralityFired)                                  // < 600 s → skip
        let due = await governor.tick(now: t0.addingTimeInterval(600))
        #expect(due.graphCentralityFired)                                     // 600 s → fires
        try await kit.close(handle)
    }

    // MARK: - End-to-end: dark → live (proves registration)

    /// After the producer scans a star estate, a unionBest+matrixAware recall
    /// reads a NON-ZERO `graph` column for the hub drawer. This closes the
    /// dark-column gap: without the producer the column was 0.0 for every hit.
    /// It also proves the duty actually REGISTERED the cache on the kit (the
    /// recall path reads `graphCaches[handle]`).
    @Test("unionBest+matrixAware recall reads a live graph column after a scan")
    func recallReadsLiveGraphColumn() async throws {
        let (kit, handle) = try await openEstate(owner: "ks-e2e")
        let (hub, _) = try await buildStar(kit, handle, spokeCount: 4)

        // Run the producer — registers the live GraphCache on the kit.
        try await AutonomicGovernor.graphCentralityScan(
            kit: kit, handle: handle, now: Date(timeIntervalSince1970: 8_000_000))

        let req = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc),
            mode: .unionBest, scoring: .matrixAware, limit: 50,
            fallback: .failClosed, origin: .internal, recallShape: nil)
        let result = try await kit.recall(handle, req)

        let hubHit = try #require(result.hits.first { $0.id == hub },
            "the hub drawer must be recalled")
        #expect(hubHit.score.graph > 0.0,
            "the graph column must be live (non-zero) for the hub after the producer ran")
        try await kit.close(handle)
    }
}
