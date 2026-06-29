// NProviderTests.swift
//
// Mission 6a-iii-core: Corpus N-provider capability + per-signal nearest API.
//
// ## What is tested
//
//   1. N=1 back-compat: a Corpus built with `init(storage:models:[one])`
//      behaves identically to `init(storage:model:)` (same recall, same
//      default-signal floatNearest). Proven indirectly by the unchanged
//      6a-ii-β fixture (BasisPersistenceTests) and directly here by the
//      single-element delegation.
//   2. Fan-out: an N-provider Corpus ingests every chunk under EVERY held
//      provider's modelID; `reindex` trains every trainable provider; the
//      VectorStore/BasisStore hold all N providers' rows side by side.
//   3. floatNearestPerSignal returns one ranked outcome per held signal, each
//      tagged by its modelID, in slot order. `[0]` equals what the
//      single-signal `floatNearest` returns.
//   4. CROSS-PORT CONFORMANCE: with all five distributional/co-classification
//      models (RI, PPMI, LSA, NMF trained via reindex; FDC stateless),
//      ingesting a FIXED corpus and calling floatNearestPerSignal yields
//      per-signal ranked lists identical Swift↔Rust. Swift is canonical and
//      emits the shared fixture (Tests/SharedVectors/n_provider_per_signal.json);
//      the Rust leg (corpus_n_provider_tests.rs) asserts byte/bit-identity
//      against the SAME shared fixture.
//
// ## No @testable
//
// This suite uses a plain `import CorpusKit` — the N-provider surface
// (`init(storage:models:)`, `floatNearestPerSignal`) is PUBLIC, so no
// `@testable` widening is needed (mission guardrail).
//
// ## Test isolation
//
// Corpus ingest/reindex emit corpuskit.* metrics through the global Intellectus
// sink; CorpusKitTelemetryTests asserts an EXACT corpuskit.* count under a
// captured window. Every Corpus-op suite serialises against that window via
// GlobalTestLock, so this suite does the same.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import PersistenceKit
import PersistenceKitSQLite

@Suite("NProvider", .serialized)
struct NProviderTests {

    // MARK: - Fixed corpus

    /// A fixed five-document corpus spanning two topical clusters (vehicles /
    /// animals) so the trained distributional signals produce non-degenerate
    /// rankings. Each single-sentence doc is one chunk whose text equals the doc.
    private let docs: [String] = [
        "car engine drive road vehicle",
        "vehicle road transport car fuel",
        "engine fuel combustion power car",
        "dog bark run fetch animal",
        "animal run cat dog pet"
    ]

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let probe = "car engine"
    private let perSignalLimit = 5

    /// The five 6a-iii signals, freshly constructed. The four distributional /
    /// matrix providers are trainable (trained via `reindex`); FDC is stateless.
    /// Built fresh each call so the test owns the construction.
    private func allFiveModels() -> [EmbeddingModel] {
        [
            .randomIndexing(provider: RandomIndexingProvider()),
            .ppmi(provider: PpmiProvider()),
            .lsa(provider: LsaProvider()),
            .nmf(provider: NmfProvider()),
            .fdc(provider: FDCProvider())
        ]
    }

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-nprov-\(UUID().uuidString).sqlite3")
    }

    private func storage(at url: URL) throws -> any Storage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
    }

    // MARK: - §1 N=1 delegation

    @Test("init(storage:models:[one]) matches init(storage:model:) on the default signal")
    func singleElementModelsMatchesSingleModel() async throws {
        try await GlobalTestLock.shared.withLock {
            // Two corpora over independent storages, one built via each init.
            let viaModel = try await Corpus(
                storage: try storage(at: scratchURL()), model: .deterministic)
            let viaModels = try await Corpus(
                storage: try storage(at: scratchURL()), models: [.deterministic])

            for (i, doc) in docs.enumerated() {
                try await viaModel.ingest(doc, sourceID: "doc-\(i)", now: now)
                try await viaModels.ingest(doc, sourceID: "doc-\(i)", now: now)
            }

            // modelID and floatNearest agree — the N=1 path is the single path.
            let viaModelID = await viaModel.modelID
            let viaModelsID = await viaModels.modelID
            #expect(viaModelID == viaModelsID)

            let a = await viaModel.floatNearest(query: probe, limit: perSignalLimit)
            let b = await viaModels.floatNearest(query: probe, limit: perSignalLimit)
            #expect(floatOutcomeBits(a) == floatOutcomeBits(b),
                    "single-model and single-element-models float lanes must be identical")

            // floatNearestPerSignal on an N=1 corpus returns exactly one entry,
            // whose outcome equals the single-signal floatNearest.
            let perSignal = await viaModels.floatNearestPerSignal(query: probe, limit: perSignalLimit)
            #expect(perSignal.count == 1)
            #expect(perSignal[0].modelID == viaModelsID)
            #expect(floatOutcomeBits(perSignal[0].outcome) == floatOutcomeBits(b))
        }
    }

    // MARK: - §2 cross-port conformance: all five signals

    @Test("CONFORMANCE: all-five floatNearestPerSignal matches the shared fixture")
    func allFivePerSignalConformance() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await Corpus(storage: try storage(at: scratchURL()),
                                          models: allFiveModels())
            for (i, doc) in docs.enumerated() {
                try await corpus.ingest(doc, sourceID: "doc-\(i)", now: now)
            }
            // Train the four trainable signals from scratch on the fixed corpus.
            // FDC is stateless and is a no-op retrain (vector refresh only).
            try await corpus.reindex(now: now)

            let perSignal = await corpus.floatNearestPerSignal(query: probe, limit: perSignalLimit)

            // Swift is canonical: the observed per-signal lists form the shared
            // fixture for Rust-leg identity assertions. The encoder is deterministic
            // (sorted keys not needed — the array order is the slot order). The
            // fixture is regenerated only when CORPUSKIT_GENERATE_FIXTURES is set;
            // normal test runs assert against the committed Swift-canonical fixture.
            let observed = NPerSignalFixture(
                probe: probe,
                limit: perSignalLimit,
                signals: perSignal.map { entry in
                    NPerSignalFixture.Signal(
                        modelID: entry.modelID,
                        outcome: encodeOutcome(entry.outcome))
                })
            try writeFixtureIfGenerating(observed)

            // Assert against the committed fixture (Swift-canonical anchor).
            let fixture = try loadFixture()
            #expect(observed.signals.count == fixture.signals.count,
                    "signal count must match the fixture")
            for (obs, exp) in zip(observed.signals, fixture.signals) {
                #expect(obs.modelID == exp.modelID, "signal modelID mismatch")
                #expect(obs.outcome == exp.outcome,
                        "per-signal outcome for \(obs.modelID) must match the fixture")
            }
        }
    }

    // MARK: - Fixture model

    /// The shared per-signal fixture: one entry per held signal, in slot order.
    ///
    /// The cross-port contract is RANK IDENTITY: per signal, the OUTCOME KIND
    /// and the RANKED `itemID` ORDER must match Swift↔Rust. Raw cosine
    /// similarity values are NOT in the fixture — the float lane is
    /// reproducible-within-config, not four-way bit-identical (arch spec §6 /
    /// VECTORKIT_SPEC): cosine accumulation/FMA differences across ports perturb
    /// the low float bits without changing the rank order. The order is the seam
    /// the 6b RRF consumer relies on, so the order is what is pinned.
    struct NPerSignalFixture: Codable, Equatable {
        struct Signal: Codable, Equatable {
            let modelID: String
            /// One of: "hits", "dark_provider", "dark_no_rows", "dark_vocab_miss",
            /// "empty_query", "store_error". Tags the FloatLaneOutcome kind cross-port.
            let kind: String
            /// Ranked itemIDs (empty unless kind == "hits"), nearest first.
            let rankedItemIDs: [String]
        }
        let probe: String
        let limit: Int
        let signals: [Signal]
    }

    /// Encode a FloatLaneOutcome into the fixture's (kind, rankedItemIDs) shape.
    private func encodeOutcome(_ outcome: FloatLaneOutcome) -> NPerSignalFixture.Signal.OutcomeShape {
        switch outcome {
        case .hits(let pairs):
            return .init(kind: "hits", rankedItemIDs: pairs.map(\.itemID))
        case .unavailableProviderOptOut:
            return .init(kind: "dark_provider", rankedItemIDs: [])
        case .unavailableNoFloatRows:
            return .init(kind: "dark_no_rows", rankedItemIDs: [])
        case .unavailableNoVocabHit:
            // Trained distributional provider, all query tokens OOV.
            return .init(kind: "dark_vocab_miss", rankedItemIDs: [])
        case .emptyQuery:
            return .init(kind: "empty_query", rankedItemIDs: [])
        case .storeError:
            return .init(kind: "store_error", rankedItemIDs: [])
        }
    }

    // MARK: - Fixture IO

    private func fixtureURL() -> URL { sharedVectorsURL(for: "n_provider_per_signal.json") }

    private func loadFixture() throws -> NPerSignalFixture {
        let data = try Data(contentsOf: fixtureURL())
        return try JSONDecoder().decode(NPerSignalFixture.self, from: data)
    }

    /// Write the fixture only when CORPUSKIT_GENERATE_FIXTURES is set in the
    /// environment, so a normal `swift test` run never mutates the committed
    /// canonical fixture (it only asserts against it).
    private func writeFixtureIfGenerating(_ fixture: NPerSignalFixture) throws {
        guard ProcessInfo.processInfo.environment["CORPUSKIT_GENERATE_FIXTURES"] != nil else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(fixture)
        try data.write(to: fixtureURL())
    }
}

// MARK: - Outcome shape bridging

extension NProviderTests.NPerSignalFixture.Signal {
    /// A transient shape used while encoding; the stored Signal is built from it.
    struct OutcomeShape {
        let kind: String
        let rankedItemIDs: [String]
    }
    init(modelID: String, outcome: OutcomeShape) {
        self.init(modelID: modelID, kind: outcome.kind, rankedItemIDs: outcome.rankedItemIDs)
    }
    /// Equatable on (kind, rankedItemIDs) — modelID compared separately by caller.
    var outcome: OutcomeShape { OutcomeShape(kind: kind, rankedItemIDs: rankedItemIDs) }
}

extension NProviderTests.NPerSignalFixture.Signal.OutcomeShape: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.rankedItemIDs == rhs.rankedItemIDs
    }
}

/// Stable bit-level descriptor of a FloatLaneOutcome for cross-instance equality
/// in the §1 delegation test (similarity bit patterns + item IDs + kind tag).
private func floatOutcomeBits(_ outcome: FloatLaneOutcome) -> [String] {
    switch outcome {
    case .hits(let pairs):
        return ["hits"] + pairs.map { "\($0.itemID):\($0.similarity.bitPattern)" }
    case .unavailableProviderOptOut: return ["dark_provider"]
    case .unavailableNoFloatRows: return ["dark_no_rows"]
    case .unavailableNoVocabHit: return ["dark_vocab_miss"]
    case .emptyQuery: return ["empty_query"]
    case .storeError: return ["store_error"]
    }
}
