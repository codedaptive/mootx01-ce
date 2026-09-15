// DefaultEnsembleCompositionTests.swift
//
// Gate proof: the default ensemble is exactly RI then LSA (two signals,
// always on), and the LSA lane encodes two drawers with disjoint vocabulary
// and ranks the on-topic one first on a real SQLite scratch estate.
//
// Test 1 — CorpusEnsemble.defaultEnsemble() returns exactly two models keyed
//          "random-indexing-v1" then "lsa-v1".
// Test 2 — After ingest + reindex, floatNearestPerSignal's "lsa-v1" entry is
//          a .hits outcome whose first hit is the on-topic drawer and whose
//          last is not, so a scrambled LSA ranking fails.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
@testable import CorpusKit
@testable import CorpusKitWholeRecordDense
import CorpusKitProviders

// MARK: - Test 1: default ensemble composition

@Suite("Default ensemble is exactly RI and LSA")
struct DefaultEnsembleCompositionTests {

    @Test("defaultEnsemble() returns exactly two signals: RI then LSA")
    func defaultEnsembleIsRIandLSA() {
        let ensemble = CorpusEnsemble.defaultEnsemble()
        let modelIDs = ensemble.map { $0.makeProvider().modelID }
        guard ensemble.count == 2 else {
            Issue.record("default ensemble must contain exactly two signals, got \(modelIDs)")
            return
        }
        #expect(modelIDs == ["random-indexing-v1", "lsa-v1"],
                "default ensemble must be RI then LSA, got \(modelIDs)")
        // The cases carry the providers: RI leads (the DEFAULT signal), LSA second.
        guard case .randomIndexing = ensemble[0] else {
            Issue.record("first signal must be the .randomIndexing case")
            return
        }
        guard case .lsa = ensemble[1] else {
            Issue.record("second signal must be the .lsa case")
            return
        }
    }
}

// MARK: - Test 2: LSA lane ranks the on-topic drawer first

@Suite("LSA lane floatNearest on scratch estate", .serialized)
struct LSAFloatNearestTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scratchCorpus() async throws -> Corpus {
        let storage = try makeScratchStorage()
        return try await Corpus(storage: storage, models: CorpusEnsemble.defaultEnsemble())
    }

    /// The LSA lane must rank the on-topic drawer first after two documents
    /// with disjoint vocabulary are ingested and the bases trained. Reads the
    /// "lsa-v1" entry of floatNearestPerSignal(query:limit:) — the public
    /// surface on the Corpus extension in CorpusKitWholeRecordDense — so the
    /// proof is about the LSA signal itself, not the default (RI) slot that
    /// floatNearest serves.
    ///
    /// INTELLECTUS LOCK: holds GlobalTestLock to prevent telemetry cross-contamination
    /// with concurrent tests that install Intellectus sinks (e.g. FloatLaneVocabMissTests).
    @Test("LSA lane encodes two drawers and ranks the on-topic one first")
    func lsaLaneEncodesAndReturnsHits() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await scratchCorpus()
            try await corpus.ingest(
                "rocket launch orbit satellite spacecraft mission",
                sourceID: "doc-space", now: now)
            try await corpus.ingest(
                "recipe oven bake bread flour yeast dough",
                sourceID: "doc-cook", now: now)
            // Reindex trains the RI and LSA bases; untrained distributional
            // lanes hold no float rows. The query is drawn from doc-space's
            // vocabulary so the trained basis folds it in (an out-of-vocabulary
            // query has no vector).
            try await corpus.reindex(now: now)

            let perSignal = await corpus.floatNearestPerSignal(query: "rocket orbit", limit: 10)
            guard let lsa = perSignal.first(where: { $0.modelID == "lsa-v1" }) else {
                Issue.record("the default ensemble holds an lsa-v1 signal; got \(perSignal.map(\.modelID))")
                return
            }
            guard case .hits(let results) = lsa.outcome else {
                Issue.record("expected .hits from the LSA lane on the scratch estate, got \(lsa.outcome)")
                return
            }
            let ids = results.map(\.itemID)
            #expect(ids.first == "doc-space",
                    "the LSA lane must rank the on-topic drawer first, got \(ids)")
            #expect(ids.last != "doc-space",
                    "doc-cook must rank below doc-space when both are returned, got \(ids)")
        }
    }
}
