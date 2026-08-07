// TieredContradictionSearchTests.swift
//
// MXE-CT3 P2 — tiered contradiction lanes + synthesis assembler
// (Brain/TieredContradictionSearch.swift). The pure-core cases mirror
// rust/src/brain/tiered_contradiction_search.rs one-for-one (pair-key
// case canonicalization with PINNED cross-port literals, clamp and
// fetch budgets, lane ranking keys, assembler promotion / backfill /
// exhaustion / determinism); the estate-level cases drive the real
// seams end-to-end: the shared hunt retrieval for tiers 2/3, the typed
// sweep for tier 1, single-tier no-dedup, and synthesis promotion.

import Testing
import Foundation
import LocusKit
import VectorKit
import SubstrateTypes
import SubstrateML
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("TieredContradictionSearch")
struct TieredContradictionSearchTests {

    // MARK: - Pure-core fixtures

    /// Hand-built lexical finding (tiers 2/3). The internal memberwise
    /// init is reachable via @testable — the report shape is produced
    /// only by the verb in production.
    private static func lexical(
        _ tier: ContradictionTier, _ a: String, _ b: String, score: Float
    ) -> TierFinding {
        let ordered = TieredContradictionCore.orderedPair(a, b)
        return TierFinding(
            tier: tier,
            pairKey: TieredContradictionCore.pairKey(a, b),
            drawerA: ordered.a, drawerB: ordered.b,
            cueKind: tier == .lexicalValue ? "value_divergence" : "negation_asymmetry",
            ruleID: nil, score: score,
            sourceSnippet: "s", targetSnippet: "t",
            resultID: nil, coordinateDigest: nil, sensitivityCeilingRaw: nil)
    }

    /// Hand-built tier-1 finding.
    private static func typed(_ a: String, _ b: String, resultID: String) -> TierFinding {
        let ordered = TieredContradictionCore.orderedPair(a, b)
        return TierFinding(
            tier: .typedProven,
            pairKey: TieredContradictionCore.pairKey(a, b),
            drawerA: ordered.a, drawerB: ordered.b,
            cueKind: nil, ruleID: "employment.employer.v1", score: nil,
            sourceSnippet: nil, targetSnippet: nil,
            resultID: resultID, coordinateDigest: "digest-\(resultID)",
            sensitivityCeilingRaw: AdjectiveSensitivity.normal.rawValue)
    }

    // MARK: - Pair key (case canonicalization, cross-port pinned)

    @Test("pair key lowercases both ids and orders canonically — pinned literal parity with the Rust twin")
    func pairKeyCanonicalizesCaseAndOrder() {
        // Swift UUID.uuidString is UPPERCASE; Rust Uuid::to_string() is
        // lowercase (the c95910dff walk-lane trap). The SAME fixture
        // strings and the SAME expected literal are pinned in the Rust
        // module test `tiered_pair_key_case_canonical` — if either port
        // drifts, one of the two pins breaks.
        #expect(TieredContradictionCore.pairKey("AAAA-1111", "bbbb-2222")
                == "aaaa-1111||bbbb-2222")
        #expect(TieredContradictionCore.pairKey("bbbb-2222", "AAAA-1111")
                == "aaaa-1111||bbbb-2222")
        #expect(TieredContradictionCore.pairKey("AaAa-1111", "BBBB-2222")
                == TieredContradictionCore.pairKey("aaaa-1111", "bbbb-2222"))
        // Ordering is decided AFTER lowercasing: uppercase 'B' < 'a' in
        // raw byte order, but the canonical key still puts a-first.
        #expect(TieredContradictionCore.pairKey("BBBB-2222", "aaaa-1111")
                == "aaaa-1111||bbbb-2222")
    }

    @Test("ordered pair matches the key's canonical ordering")
    func orderedPairMatchesKeyOrdering() {
        let pair = TieredContradictionCore.orderedPair("BBBB-2222", "aaaa-1111")
        #expect(pair.a == "aaaa-1111")
        #expect(pair.b == "BBBB-2222")
        // Case-insensitive tie: total order falls back to raw compare.
        let tie = TieredContradictionCore.orderedPair("AbC", "aBc")
        #expect(tie.a == "AbC")
        #expect(tie.b == "aBc")
    }

    // MARK: - Clamp and fetch budgets

    @Test("topK clamps to the DoS ceiling; non-positive yields zero")
    func effectiveTopKClampsAndGuards() {
        #expect(TieredContradictionCore.effectiveTopK(0) == 0)
        #expect(TieredContradictionCore.effectiveTopK(-5) == 0)
        #expect(TieredContradictionCore.effectiveTopK(10) == 10)
        #expect(TieredContradictionCore.effectiveTopK(50) == 50)
        #expect(TieredContradictionCore.effectiveTopK(51) == 50)
        #expect(TieredContradictionCore.effectiveTopK(5000) == 50)
    }

    @Test("fetch budgets are K / 2K / 3K by tier")
    func fetchBudgets() {
        #expect(TieredContradictionCore.fetchBudget(for: .typedProven, topK: 7) == 7)
        #expect(TieredContradictionCore.fetchBudget(for: .lexicalStructural, topK: 7) == 14)
        #expect(TieredContradictionCore.fetchBudget(for: .lexicalValue, topK: 7) == 21)
    }

    // MARK: - Lane ranking keys

    @Test("lexical lanes rank by score descending, pairKey ascending on ties")
    func rankLexicalOrdersByScoreThenPairKey() {
        let low = Self.lexical(.lexicalValue, "cccc", "dddd", score: 0.50)
        let highA = Self.lexical(.lexicalValue, "aaaa", "bbbb", score: 0.90)
        let highB = Self.lexical(.lexicalValue, "eeee", "ffff", score: 0.90)
        let ranked = TieredContradictionCore.rankLexical([low, highB, highA])
        #expect(ranked == [highA, highB, low])
        // Deterministic: input permutation cannot change the output.
        #expect(TieredContradictionCore.rankLexical([highB, low, highA]) == ranked)
    }

    /// Proven findings for the tier-1 ranking tests, produced through
    /// the real pure sweep core (ConflictFinding has no test-reachable
    /// init in SubstrateML — building through `ConflictSweepCore.run`
    /// keeps the fixture honest).
    private static func provenPair(
        _ subject: String, _ d1: String, _ d2: String
    ) -> ConflictFinding {
        let facts = [
            KGFact(id: "\(subject)-f1", subject: subject, predicate: "Employer",
                   object: "Acme Robotics", sourceDrawerID: d1,
                   filedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            KGFact(id: "\(subject)-f2", subject: subject, predicate: "Employer",
                   object: "Beta Corp", sourceDrawerID: d2,
                   filedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        let report = ConflictSweepCore.run(
            facts: facts,
            eventTimeSecondsBySourceDrawer: [d1: 500, d2: 500],
            sensitivityRawBySourceDrawer: [
                d1: AdjectiveSensitivity.normal.rawValue,
                d2: AdjectiveSensitivity.normal.rawValue,
            ],
            acceptedSupersessionPairs: [],
            registry: .v01)
        return report.proven[0]
    }

    @Test("tier-1 ranks newest endpoint first, resultID on ties, unresolved last")
    func rankTier1RanksByRecencyThenResultID() {
        let older = Self.provenPair("Sarah Chen C0", "d1", "d2")
        let newer = Self.provenPair("Noor Haddad C1", "d3", "d4")
        let unresolved = Self.provenPair("Kim Osei C2", "d5", "d6")
        // The MAX endpoint decides: d2 is old but d1 is not — the pair's
        // most recent endpoint event is what "newest" means.
        let events: [String: Int64] = [
            "d1": 2_000, "d2": 100,
            "d3": 3_000, "d4": 100,
            // d5/d6 absent: no resolvable endpoint → ranks oldest.
        ]
        let ranked = TieredContradictionCore.rankAndTrimTier1(
            [unresolved, older, newer],
            eventTimeSecondsBySourceDrawer: events, topK: 10)
        #expect(ranked.count == 3)
        #expect(ranked[0].resultID == newer.outcome.resultID)
        #expect(ranked[1].resultID == older.outcome.resultID)
        #expect(ranked[2].resultID == unresolved.outcome.resultID)
        // The tier-1 shape: typed fields populated, lexical fields nil,
        // ceiling carried through unchanged.
        #expect(ranked[0].tier == .typedProven)
        #expect(ranked[0].score == nil)
        #expect(ranked[0].cueKind == nil)
        #expect(ranked[0].ruleID == newer.outcome.ruleID)
        #expect(ranked[0].coordinateDigest == newer.outcome.coordinateDigest)
        #expect(ranked[0].sensitivityCeilingRaw == newer.sensitivityCeilingRaw)

        // Trim respects topK.
        let trimmed = TieredContradictionCore.rankAndTrimTier1(
            [unresolved, older, newer],
            eventTimeSecondsBySourceDrawer: events, topK: 1)
        #expect(trimmed.count == 1)
        #expect(trimmed[0].resultID == newer.outcome.resultID)

        // Equal recency: resultID ascending decides, deterministically.
        let flat: [String: Int64] = [
            "d1": 500, "d2": 500, "d3": 500, "d4": 500, "d5": 500, "d6": 500,
        ]
        let tied = TieredContradictionCore.rankAndTrimTier1(
            [newer, unresolved, older],
            eventTimeSecondsBySourceDrawer: flat, topK: 10)
        let ids = tied.compactMap(\.resultID)
        #expect(ids == ids.sorted())
    }

    // MARK: - Synthesis assembler

    @Test("duplicates promote to the highest tier; lower tiers backfill from over-fetch")
    func assemblerPromotesToHighestTier() {
        let x = Self.typed("aaaa", "bbbb", resultID: "r-x")
        let xAsT3 = Self.lexical(.lexicalValue, "aaaa", "bbbb", score: 0.95)
        let y = Self.lexical(.lexicalValue, "cccc", "dddd", score: 0.80)
        let z = Self.lexical(.lexicalValue, "eeee", "ffff", score: 0.70)

        let assembly = TieredContradictionCore.assembleSynthesis(
            tier1Fetched: [x],
            tier2Fetched: [],
            tier3Fetched: [xAsT3, y, z],
            topK: 2)

        // The pair appears ONLY at tier 1.
        #expect(assembly.tier1 == [x])
        #expect(!assembly.tier3.contains { $0.pairKey == x.pairKey })
        // Tier 3 backfilled to topK from its over-fetch: z (rank 2, at
        // or beyond topK=2) moved up into the window.
        #expect(assembly.tier3 == [y, z])
        #expect(assembly.tier3Counts.fetched == 3)
        #expect(assembly.tier3Counts.returned == 2)
        #expect(assembly.tier3Counts.promotedAway == 1)
        #expect(assembly.tier3Counts.backfilled == 1)
        #expect(assembly.tier1Counts == TierLaneCounts(
            fetched: 1, returned: 1, promotedAway: 0, backfilled: 0))
    }

    @Test("a pair present in tier 2 is removed from tier 3")
    func assemblerTier2ShadowsTier3() {
        let w2 = Self.lexical(.lexicalStructural, "aaaa", "bbbb", score: 0.60)
        let w3 = Self.lexical(.lexicalValue, "aaaa", "bbbb", score: 0.90)
        let v = Self.lexical(.lexicalValue, "cccc", "dddd", score: 0.50)
        let assembly = TieredContradictionCore.assembleSynthesis(
            tier1Fetched: [], tier2Fetched: [w2], tier3Fetched: [w3, v], topK: 1)
        #expect(assembly.tier2 == [w2])
        #expect(assembly.tier3 == [v])
        #expect(assembly.tier3Counts.promotedAway == 1)
        #expect(assembly.tier3Counts.backfilled == 1)
    }

    @Test("promotion matches across ports' UUID casing — dedup keys on the canonical pair key")
    func assemblerPromotionMatchesAcrossCase() {
        // Tier-1 endpoints cased the Swift way (UPPERCASE), tier-3 the
        // Rust way (lowercase): still the same logical pair, still
        // promoted. This is the cross-tier leg of the c95910dff guard.
        let upper = Self.typed("AAAA-1111", "BBBB-2222", resultID: "r-upper")
        let lower = Self.lexical(.lexicalValue, "aaaa-1111", "bbbb-2222", score: 0.9)
        let assembly = TieredContradictionCore.assembleSynthesis(
            tier1Fetched: [upper], tier2Fetched: [], tier3Fetched: [lower], topK: 5)
        #expect(assembly.tier1 == [upper])
        #expect(assembly.tier3.isEmpty)
        #expect(assembly.tier3Counts.promotedAway == 1)
    }

    @Test("backfill exhaustion: a lane run dry returns a shorter section and the counts say so")
    func assemblerBackfillExhaustion() {
        let x = Self.typed("aaaa", "bbbb", resultID: "r-x")
        let xAsT3 = Self.lexical(.lexicalValue, "aaaa", "bbbb", score: 0.95)
        let assembly = TieredContradictionCore.assembleSynthesis(
            tier1Fetched: [x], tier2Fetched: [], tier3Fetched: [xAsT3], topK: 3)
        #expect(assembly.tier3.isEmpty)
        #expect(assembly.tier3Counts == TierLaneCounts(
            fetched: 1, returned: 0, promotedAway: 1, backfilled: 0))
        // Tier 2 was genuinely empty — zero everything, no invention.
        #expect(assembly.tier2Counts == TierLaneCounts(
            fetched: 0, returned: 0, promotedAway: 0, backfilled: 0))
    }

    @Test("sections never exceed topK even from a full over-fetch")
    func assemblerRespectsReturnWindows() {
        let fetched = (0..<4).map { i in
            Self.lexical(.lexicalStructural, "a\(i)", "b\(i)", score: 0.9 - Float(i) * 0.1)
        }
        let assembly = TieredContradictionCore.assembleSynthesis(
            tier1Fetched: [], tier2Fetched: fetched, tier3Fetched: [], topK: 2)
        #expect(assembly.tier2 == Array(fetched.prefix(2)))
        #expect(assembly.tier2Counts == TierLaneCounts(
            fetched: 4, returned: 2, promotedAway: 0, backfilled: 0))
    }

    @Test("assembler is deterministic on identical inputs")
    func assemblerDeterminism() {
        let t1 = [Self.typed("aaaa", "bbbb", resultID: "r-1")]
        let t2 = [Self.lexical(.lexicalStructural, "cccc", "dddd", score: 0.6)]
        let t3 = [
            Self.lexical(.lexicalValue, "aaaa", "bbbb", score: 0.9),
            Self.lexical(.lexicalValue, "eeee", "ffff", score: 0.5),
        ]
        let first = TieredContradictionCore.assembleSynthesis(
            tier1Fetched: t1, tier2Fetched: t2, tier3Fetched: t3, topK: 2)
        let second = TieredContradictionCore.assembleSynthesis(
            tier1Fetched: t1, tier2Fetched: t2, tier3Fetched: t3, topK: 2)
        #expect(first == second)
    }

    // MARK: - Estate seam (end-to-end)

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let modelID = "minilm-v6"

    /// Engram clusters: identical engrams are distance-0 kNN pairs;
    /// the three clusters sit > 64 bits apart so no cross-cluster
    /// candidates form.
    private let near = Fingerprint256(
        block0: 0xAAAA, block1: 0xBBBB, block2: 0xCCCC, block3: 0xDDDD)
    private let near2 = Fingerprint256(
        block0: 0x5555_5555_5555_5555, block1: 0x5555_5555_5555_5555,
        block2: 0, block3: 0)

    private func makeKit() async throws -> (GeniusLocusKit, EstateHandle, VectorStore) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "tiered-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let vectorStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        try await vectorStorage.open(schema: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vectorStorage)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit, handle, vectorStore)
    }

    /// Capture a drawer (deterministic event time) and file a vector.
    @discardableResult
    private func plant(
        _ content: String,
        engram: Fingerprint256,
        eventTime: Date = TieredContradictionSearchTests.t0,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        vectorStore: VectorStore
    ) async throws -> Drawer {
        let drawer = try await kit.capture(handle, CaptureFrame(
            content: content,
            channel: .typed,
            room: "study",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "tiered-tests",
            embeddingModelID: Self.modelID,
            eventTime: eventTime))
        try await vectorStore.addVector(
            itemID: drawer.id, engram: engram, modelID: Self.modelID,
            modelVersion: "1.0", filedAt: Self.t0)
        return drawer
    }

    /// File the typed proof pair: two Employer facts on one coordinate
    /// with exclusive values, anchored to the two drawers.
    private func proveTyped(
        _ subject: String, _ a: Drawer, _ b: Drawer,
        kit: GeniusLocusKit, handle: EstateHandle
    ) async throws {
        _ = try await kit.captureKGFact(
            handle, subject: subject, predicate: "Employer",
            object: "Acme Robotics", sourceDrawerID: a.id, now: Self.t0)
        _ = try await kit.captureKGFact(
            handle, subject: subject, predicate: "Employer",
            object: "Beta Corp", sourceDrawerID: b.id, now: Self.t0)
    }

    @Test("single tier-3 run finds value divergence through the shared hunt retrieval")
    func singleTier3RunFindsValueDivergence() async throws {
        let (kit, handle, vectorStore) = try await makeKit()
        let a = try await plant("the api timeout is 30 seconds", engram: near,
                                kit: kit, handle: handle, vectorStore: vectorStore)
        let b = try await plant("the api timeout is 90 seconds", engram: near,
                                kit: kit, handle: handle, vectorStore: vectorStore)

        let report = try await kit.tieredContradictionSearch(
            in: handle, tier: .lexicalValue, topK: 5, now: Self.t0)

        #expect(report.mode == .single(.lexicalValue))
        #expect(report.tier1.isEmpty)
        #expect(report.tier2.isEmpty)
        #expect(report.tier3.count == 1)
        let finding = try #require(report.tier3.first)
        #expect(finding.tier == .lexicalValue)
        #expect(finding.cueKind == "value_divergence")
        #expect(finding.pairKey == TieredContradictionCore.pairKey(a.id, b.id))
        #expect(Set([finding.drawerA, finding.drawerB]) == Set([a.id, b.id]))
        #expect(finding.score != nil)
        #expect(finding.sourceSnippet?.isEmpty == false)
        #expect(finding.targetSnippet?.isEmpty == false)
        #expect(finding.resultID == nil)
        #expect(report.tier3Counts == TierLaneCounts(
            fetched: 1, returned: 1, promotedAway: 0, backfilled: 0))
        #expect(report.diagnostics.vectorStoreAvailable)
        #expect(report.diagnostics.probesScanned > 0)
        // Read-and-report only: the search filed nothing.
        let estate = try await kit.estate(for: handle)
        let tunnels = try await estate.allTunnels().filter { $0.kind == .contradicts }
        #expect(tunnels.isEmpty)
    }

    @Test("a single-tier run applies NO cross-tier dedup — the purpose-run answers its own question")
    func singleTierRunDoesNotCrossDedup() async throws {
        let (kit, handle, vectorStore) = try await makeKit()
        let a = try await plant("the api timeout is 30 seconds", engram: near,
                                kit: kit, handle: handle, vectorStore: vectorStore)
        let b = try await plant("the api timeout is 90 seconds", engram: near,
                                kit: kit, handle: handle, vectorStore: vectorStore)
        try await proveTyped("Sarah Chen C0", a, b, kit: kit, handle: handle)
        let key = TieredContradictionCore.pairKey(a.id, b.id)

        // The pair is a tier-1 proof…
        let tier1Run = try await kit.tieredContradictionSearch(
            in: handle, tier: .typedProven, topK: 5, now: Self.t0)
        #expect(tier1Run.tier1.contains { $0.pairKey == key })

        // …and STILL appears in a purpose-run tier-3 report.
        let tier3Run = try await kit.tieredContradictionSearch(
            in: handle, tier: .lexicalValue, topK: 5, now: Self.t0)
        #expect(tier3Run.tier3.contains { $0.pairKey == key })
        #expect(tier3Run.tier3Counts.promotedAway == 0)
    }

    @Test("synthesis promotes the typed proof; tier sections stay separate and deterministic")
    func synthesisPromotesTypedProofOverLexical() async throws {
        let (kit, handle, vectorStore) = try await makeKit()
        // Pair 1 — typed proof AND lexical value divergence.
        let a = try await plant("the api timeout is 30 seconds", engram: near,
                                kit: kit, handle: handle, vectorStore: vectorStore)
        let b = try await plant("the api timeout is 90 seconds", engram: near,
                                kit: kit, handle: handle, vectorStore: vectorStore)
        try await proveTyped("Sarah Chen C0", a, b, kit: kit, handle: handle)
        // Pair 2 — structural negation cue only (tier 2), own cluster.
        let c = try await plant("Bob lives in Paris", engram: near2,
                                kit: kit, handle: handle, vectorStore: vectorStore)
        let d = try await plant("Bob does not live in Paris", engram: near2,
                                kit: kit, handle: handle, vectorStore: vectorStore)

        let report = try await kit.tieredContradictionSearch(
            in: handle, topK: 5, now: Self.t0)

        let provenKey = TieredContradictionCore.pairKey(a.id, b.id)
        let negationKey = TieredContradictionCore.pairKey(c.id, d.id)
        #expect(report.mode == .synthesis)
        // The proven pair renders at tier 1 ONLY.
        #expect(report.tier1.count == 1)
        #expect(report.tier1.first?.pairKey == provenKey)
        #expect(report.tier1.first?.sensitivityCeilingRaw
                == AdjectiveSensitivity.normal.rawValue)
        #expect(!report.tier3.contains { $0.pairKey == provenKey })
        #expect(report.tier3Counts.promotedAway == 1)
        // The negation pair stays at tier 2, untouched by promotion.
        #expect(report.tier2.count == 1)
        #expect(report.tier2.first?.pairKey == negationKey)
        #expect(report.tier2.first?.cueKind == "negation_asymmetry")

        // Determinism: the identical estate state yields the identical
        // report, section for section.
        let again = try await kit.tieredContradictionSearch(
            in: handle, topK: 5, now: Self.t0)
        #expect(again == report)
    }

    @Test("tier-1 lane ranks newest endpoint first end-to-end and fetches exactly topK")
    func tier1LaneRanksByRecencyEndToEnd() async throws {
        let (kit, handle, vectorStore) = try await makeKit()
        let older1 = try await plant(
            "claim one", engram: near,
            eventTime: Date(timeIntervalSince1970: 1_600_000_000),
            kit: kit, handle: handle, vectorStore: vectorStore)
        let older2 = try await plant(
            "claim two", engram: near,
            eventTime: Date(timeIntervalSince1970: 1_600_000_000),
            kit: kit, handle: handle, vectorStore: vectorStore)
        let newer1 = try await plant(
            "claim three", engram: near2,
            eventTime: Date(timeIntervalSince1970: 1_650_000_000),
            kit: kit, handle: handle, vectorStore: vectorStore)
        let newer2 = try await plant(
            "claim four", engram: near2,
            eventTime: Date(timeIntervalSince1970: 1_650_000_000),
            kit: kit, handle: handle, vectorStore: vectorStore)
        try await proveTyped("Sarah Chen C0", older1, older2, kit: kit, handle: handle)
        try await proveTyped("Noor Haddad C1", newer1, newer2, kit: kit, handle: handle)

        let report = try await kit.tieredContradictionSearch(
            in: handle, tier: .typedProven, topK: 1, now: Self.t0)
        #expect(report.tier1.count == 1)
        #expect(report.tier1.first?.pairKey
                == TieredContradictionCore.pairKey(newer1.id, newer2.id))
        // Both pairs qualified; the tier-1 fetch budget (exactly topK)
        // trimmed to the newest.
        #expect(report.diagnostics.tier1Candidates == 2)
        #expect(report.tier1Counts == TierLaneCounts(
            fetched: 1, returned: 1, promotedAway: 0, backfilled: 0))
    }

    @Test("empty estate, missing vector store, and non-positive topK all answer deterministically")
    func emptyEstateAndGuards() async throws {
        // Empty estate with a vector store: empty sections, honest zeros.
        let (kit, handle, _) = try await makeKit()
        let empty = try await kit.tieredContradictionSearch(
            in: handle, topK: 5, now: Self.t0)
        #expect(empty.tier1.isEmpty && empty.tier2.isEmpty && empty.tier3.isEmpty)
        #expect(empty.diagnostics.probesScanned == 0)
        #expect(empty.diagnostics.vectorStoreAvailable)

        // No vector store: the lexical lanes are honest no-ops; the
        // typed lane still runs (it needs no vectors).
        let bare = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "tiered-tests-bare")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let bareHandle = try await bare.open(storage: storage, owner: owner)
        let bareReport = try await bare.tieredContradictionSearch(
            in: bareHandle, topK: 5, now: Self.t0)
        #expect(!bareReport.diagnostics.vectorStoreAvailable)
        #expect(bareReport.tier2.isEmpty && bareReport.tier3.isEmpty)

        // topK <= 0: deterministic empty report, no throw, no work.
        let zero = try await kit.tieredContradictionSearch(
            in: handle, topK: 0, now: Self.t0)
        #expect(zero == TieredContradictionReport.empty(mode: .synthesis))
        let negative = try await kit.tieredContradictionSearch(
            in: handle, tier: .lexicalValue, topK: -3, now: Self.t0)
        #expect(negative == TieredContradictionReport.empty(mode: .single(.lexicalValue)))
    }
}
