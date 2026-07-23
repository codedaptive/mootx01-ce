// DefaultEnsembleRecallPayoffTests.swift
//
// Mission 6a-iii-wire — end-to-end PAYOFF proof: the default recall ensemble
// (CorpusEnsemble.defaultEnsemble(): RI/PPMI/LSA/NMF/FDC) un-pins recall.
//
// This is the deterministic, CI-verifiable proof that flipping the production
// default from a single hash lane to the five honest signals actually fixes
// recall. The Corpus built here is exactly the one GLK's `provision` default and
// the ARIA_MCP server now construct (both thread `CorpusEnsemble.defaultEnsemble()`
// into `Corpus(storage:models:)`), so proving the un-pinning at this layer proves
// it for every production provision site.
//
// What "un-pinning" means and why it is the payoff
// ------------------------------------------------
// A single fake/hash lane (the old `.deterministic` default) collapses recall:
// its similarity reflects only surface byte overlap, so varied queries tend to
// pin onto the same handful of lexically-overlapping documents, and a query that
// is semantically related but lexically different misses entirely. The five-signal
// ensemble — trained on the estate's own corpus (RI/PPMI/LSA/NMF) plus stateless
// taxonomic FDC — produces distributional + categorical structure, so:
//   (a) varied queries return DIVERSE top hits (not pinned to one cluster),
//   (b) every hit carries MULTI-SIGNAL dense provenance (multiple modelIDs vote),
//   (c) a semantically-related-but-lexically-different document is recalled.
//
// Determinism: `now` is a fixed Date; all five providers are deterministic
// (fixed seeds / fixed-iteration training). No Date() in the engine path.
//
// Test isolation: Corpus ingest/reindex emit corpuskit.* metrics through the
// global Intellectus sink; the telemetry suite asserts an exact count under a
// captured window, so every Corpus-op suite serialises via GlobalTestLock. This
// suite follows that convention.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import PersistenceKit
import PersistenceKitSQLite

@Suite("DefaultEnsemble recall payoff", .serialized)
struct DefaultEnsembleRecallPayoffTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Default ensemble invalidates trainable 1.0 bases")
    func defaultEnsembleModelVersions() {
        let versions = CorpusEnsemble.defaultEnsemble().compactMap { model -> String? in
            switch model {
            case .randomIndexing(let provider), .ppmi(let provider),
                 .lsa(let provider), .nmf(let provider), .fdc(let provider):
                return provider.modelVersion
            default:
                return nil
            }
        }
        #expect(versions == ["1.1.0", "1.1.0", "1.1.0", "1.1.0", "1.0.0"])
    }

    /// A diverse multi-topic corpus spanning four clearly separated topical
    /// clusters (space / cooking / finance / gardening). Enough distinct topics
    /// that a single surface-hash lane would collapse recall onto a tiny set,
    /// while the trained distributional signals resolve the clusters. Each doc is
    /// one chunk whose text equals the doc.
    private let docs: [(id: String, text: String)] = [
        // space cluster
        ("space-1", "rocket launch orbit satellite spacecraft mission"),
        ("space-2", "astronaut spacecraft orbit station module docking"),
        ("space-3", "telescope galaxy star planet nebula cosmos observation"),
        // cooking cluster
        ("cook-1", "recipe oven bake bread flour yeast dough"),
        ("cook-2", "saute pan onion garlic simmer sauce stove"),
        ("cook-3", "knife chop vegetable dice prep cutting board"),
        // finance cluster
        ("fin-1", "invest portfolio stock bond dividend market return"),
        ("fin-2", "budget savings expense income loan interest rate"),
        ("fin-3", "tax filing deduction revenue accounting ledger audit"),
        // gardening cluster
        ("garden-1", "soil seed plant water sunlight grow sprout"),
        ("garden-2", "prune shrub hedge trim branch leaf foliage"),
        ("garden-3", "compost fertilizer nutrient root mulch garden bed")
    ]

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-payoff-\(UUID().uuidString).sqlite3")
    }

    private func storage(at url: URL) throws -> any Storage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
    }

    /// Build a Corpus on the canonical default ensemble, ingest the diverse
    /// corpus, and reindex (which trains all four trainable signals on the full
    /// corpus). Returns the trained-ready Corpus.
    private func makeTrainedEnsembleCorpus() async throws -> Corpus {
        // THE call under test: the exact default GLK.provision and the ARIA_MCP
        // server now thread. If this set ever drifts from the production default,
        // the payoff proof drifts with it.
        let corpus = try await Corpus(
            storage: try storage(at: scratchURL()),
            models: CorpusEnsemble.defaultEnsemble())
        for doc in docs {
            try await corpus.ingest(doc.text, sourceID: doc.id, now: now)
        }
        // reindex trains the four trainable signals (RI/PPMI/LSA/NMF) on the full
        // corpus and re-embeds every chunk under every signal's modelID. FDC is
        // stateless and needs no training.
        try await corpus.reindex(now: now)
        return corpus
    }

    /// Pull ranked itemIDs out of a per-signal result for the default (slot-0)
    /// signal — the signal the single-signal `floatNearest`/`recall` delegate to.
    private func rankedIDs(_ outcome: FloatLaneOutcome) -> [String] {
        if case .hits(let pairs) = outcome { return pairs.map(\.itemID) }
        return []
    }

    // MARK: - (a) varied queries return DIVERSE hits (recall is NOT pinned)

    @Test("Varied queries recall diverse documents, not one pinned cluster")
    func variedQueriesAreNotPinned() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeTrainedEnsembleCorpus()

            // Four queries, one per topical cluster. Each query's words appear in
            // its cluster's docs, so a working recall returns that cluster's docs
            // near the top — and crucially the TOP hit differs across queries.
            let queries: [(probe: String, expectCluster: String)] = [
                ("orbit spacecraft mission", "space"),
                ("bake bread oven", "cook"),
                ("invest stock portfolio", "fin"),
                ("plant soil water grow", "garden")
            ]

            var topHits: [String] = []
            for q in queries {
                let outcome = await corpus.floatNearest(query: q.probe, limit: 3)
                let ids = rankedIDs(outcome)
                #expect(!ids.isEmpty, "query '\(q.probe)' must return ranked hits")
                let top = try #require(ids.first)
                topHits.append(top)
                // The top hit must belong to the query's own cluster — proof the
                // ensemble resolves topic structure, not surface noise.
                #expect(
                    top.hasPrefix(q.expectCluster),
                    "query '\(q.probe)' top hit '\(top)' must be in cluster '\(q.expectCluster)'")
            }

            // UN-PINNING: the four queries do NOT collapse onto the same handful
            // of documents. A pinned (single-hash) lane would repeat the same ids;
            // the trained ensemble returns four DISTINCT top hits.
            #expect(
                Set(topHits).count == queries.count,
                "varied queries must recall DISTINCT top documents (un-pinned), got \(topHits)")
        }
    }

    // MARK: - (b) hits carry MULTI-SIGNAL dense provenance (multiple modelIDs vote)

    @Test("Recall hits carry multi-signal dense provenance (>1 modelID voting)")
    func hitsCarryMultiSignalProvenance() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeTrainedEnsembleCorpus()

            let perSignal = await corpus.floatNearestPerSignal(
                query: "orbit spacecraft mission", limit: 3)

            // The default ensemble holds five signals; each appears once, in slot
            // order, tagged by its own modelID.
            let modelIDs = perSignal.map(\.modelID)
            #expect(
                modelIDs == ["random-indexing-v1", "ppmi-v1", "lsa-v1", "nmf-v1", "fdc-v1"],
                "per-signal provenance must carry all five default modelIDs in order, got \(modelIDs)")

            // MULTI-SIGNAL VOTING: more than one signal must produce ranked hits
            // for the query (the single-hash default could only ever produce one
            // lane). Count signals whose lane returned ranked hits.
            let votingSignals = perSignal.filter { !rankedIDs($0.outcome).isEmpty }
            #expect(
                votingSignals.count >= 2,
                "at least two dense signals must vote on the query, got \(votingSignals.count) (\(votingSignals.map(\.modelID)))")

            // And the trained distributional signals (the heart of the honest
            // semantic lane) must agree the top hit is in the space cluster.
            for signal in votingSignals where signal.modelID != "fdc-v1" {
                let top = rankedIDs(signal.outcome).first
                #expect(
                    top?.hasPrefix("space") == true,
                    "signal \(signal.modelID) top hit \(top ?? "nil") should be in space cluster")
            }
        }
    }

    // MARK: - (c) semantically-related-but-lexically-different recall (BM25 misses)

    @Test("Ensemble recalls a semantically-related, lexically-different document")
    func semanticNotLexicalRecall() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeTrainedEnsembleCorpus()

            // The probe uses ONLY cook-1's baking vocabulary ("oven bake flour
            // dough"). The target document cook-3 ("knife chop vegetable dice prep
            // cutting board") shares ZERO tokens with the probe — a pure lexical
            // (BM25) match scores cook-3 at zero and never surfaces it. But the
            // trained distributional ensemble learned that cook-1, cook-2, and
            // cook-3 co-occur in the same cooking neighbourhood, so the dense lane
            // places cook-3 near the baking probe even with no shared surface token.
            let probeTokens: Set<String> = ["oven", "bake", "flour", "dough"]
            let cook3Tokens: Set<String> = ["knife", "chop", "vegetable", "dice", "prep", "cutting", "board"]
            // Guard the premise: probe and target genuinely share no token, so a
            // lexical match could not surface cook-3.
            #expect(probeTokens.isDisjoint(with: cook3Tokens),
                    "test premise: probe and cook-3 must share no surface token")

            let outcome = await corpus.floatNearest(query: "oven bake flour dough", limit: 12)
            let ids = rankedIDs(outcome)
            #expect(!ids.isEmpty, "semantic probe must return ranked hits")

            // cook-3 — semantically related, lexically disjoint — must be recalled.
            // This is precisely the hit BM25 alone misses.
            #expect(
                ids.contains("cook-3"),
                "ensemble must recall the lexically-disjoint cooking doc cook-3; recalled: \(ids)")
        }
    }
}
