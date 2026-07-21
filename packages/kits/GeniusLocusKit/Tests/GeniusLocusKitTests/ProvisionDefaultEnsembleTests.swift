// ProvisionDefaultEnsembleTests.swift
//
// Mission 6a-iii-wire — payoff proof THROUGH the GLK provision default.
//
// The CorpusKit-level payoff test (DefaultEnsembleRecallPayoffTests) proves the
// ensemble un-pins recall when a Corpus is built directly from
// CorpusEnsemble.defaultEnsemble(). THIS test proves the production seam: that
// `GeniusLocusKit.provision(...)` — called with NO explicit embedding argument,
// exactly as every production caller (EstateAdmin, the ARIA_MCP server's
// provision path) calls it — now wires the Corpus on the five-signal ensemble.
//
// If the provision default ever silently regresses to a single provider, the
// per-signal provenance assertion below fails immediately.
//
// Determinism: `now` is fixed; all five providers are deterministic. No Date()
// in the engine path.

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitSQLite
@testable import GeniusLocusKit

@Suite("Provision wires the five-signal default ensemble", .serialized)
struct ProvisionDefaultEnsembleTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private let docs: [(id: String, text: String)] = [
        ("space-1", "rocket launch orbit satellite spacecraft mission"),
        ("space-2", "astronaut spacecraft orbit station module docking"),
        ("space-3", "telescope galaxy star planet nebula cosmos observation"),
        ("cook-1", "recipe oven bake bread flour yeast dough"),
        ("cook-2", "saute pan onion garlic simmer sauce stove"),
        ("cook-3", "knife chop vegetable dice prep cutting board"),
        ("garden-1", "soil seed plant water sunlight grow sprout"),
        ("garden-2", "prune shrub hedge trim branch leaf foliage")
    ]

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-provision-ensemble-\(UUID().uuidString).sqlite3")
    }

    private func sqliteStorage() throws -> any Storage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: scratchURL(), busyTimeout: 5.0)))
    }

    private func glkParams() -> EstateProvisionParams {
        EstateProvisionParams(
            estateName: "EnsembleEstate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none)
    }

    private func rankedIDs(_ outcome: FloatLaneOutcome) -> [String] {
        if case .hits(let pairs) = outcome { return pairs.map(\.itemID) }
        return []
    }

    /// Provision a GLK estate with NO explicit embedding argument (the default),
    /// capture a diverse corpus through the ATTACHED production path (Drawer
    /// rows are canonical; the engine indexes them via the LocusKit adapter),
    /// and reindex (trains the trainable signals). Returns the registered
    /// engine plus the drawer-ID → cluster map (attached mode assigns Drawer
    /// IDs at capture; content mutation through CorpusKit is rejected).
    private func provisionAndTrain(
        _ kit: GeniusLocusKit
    ) async throws -> (corpus: CorpusContentEngine, clusters: [String: String]) {
        let storage = try sqliteStorage()
        let owner = OwnerCredentials(ownerIdentifier: "ensemble-default-test")
        // The production call shape: NO embeddingModels argument → the flipped
        // default (CorpusEnsemble.defaultEnsemble()).
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: glkParams())
        // Reach the engine the provision path wired (internal; @testable).
        let corpus = try #require(await kit.corpusKits[handle],
                                  "provision(.glk) must register a Corpus engine")
        var clusters: [String: String] = [:]
        for doc in docs {
            let frame = CaptureFrame(
                content: doc.text, channel: .typed, room: "ensemble",
                latticeAnchor: LatticeAnchor(udcCode: "004"),
                addedBy: "ensemble-test", embeddingModelID: "ensemble-v1")
            let drawer = try await kit.capture(handle, frame, mode: .impatient)
            clusters[drawer.id] = String(doc.id.prefix(while: { $0 != "-" }))
        }
        try await corpus.reindex(now: now)
        return (corpus, clusters)
    }

    // The provisioned Corpus must hold ALL FIVE default signals — proving the
    // provision default is the ensemble, not a single provider.
    @Test("provision default wires all five honest signals")
    func provisionWiresFiveSignals() async throws {
        let kit = GeniusLocusKit()
        let (corpus, _) = try await provisionAndTrain(kit)

        let perSignal = await corpus.floatNearestPerSignal(
            query: "orbit spacecraft mission", limit: 3)
        let modelIDs = perSignal.map(\.modelID)
        #expect(
            modelIDs == ["random-indexing-v1", "ppmi-v1", "lsa-v1", "nmf-v1", "fdc-v1"],
            "provision default must wire the five-signal ensemble, got \(modelIDs)")
    }

    // Recall un-pins through the provision path: varied queries → distinct top hits.
    @Test("recall un-pins through the provision default")
    func recallUnpinsThroughProvision() async throws {
        let kit = GeniusLocusKit()
        let (corpus, clusters) = try await provisionAndTrain(kit)

        let queries: [(probe: String, cluster: String)] = [
            ("orbit spacecraft mission", "space"),
            ("bake bread oven", "cook"),
            ("plant soil water grow", "garden")
        ]
        var topHits: [String] = []
        for q in queries {
            let ids = rankedIDs(await corpus.floatNearest(query: q.probe, limit: 3))
            let top = try #require(ids.first, "query '\(q.probe)' must return hits")
            #expect(clusters[top] == q.cluster,
                    "query '\(q.probe)' top '\(top)' must be in cluster '\(q.cluster)'")
            topHits.append(top)
        }
        #expect(Set(topHits).count == queries.count,
                "varied queries must recall DISTINCT top docs (un-pinned), got \(topHits)")
    }
}
