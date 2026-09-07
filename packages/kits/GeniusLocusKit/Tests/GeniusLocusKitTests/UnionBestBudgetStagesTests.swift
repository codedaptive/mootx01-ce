// UnionBestBudgetStagesTests.swift
//
// The two unionBest work bounds from the 2026-09-07 security scan, the Swift
// twin of rust/tests/union_best_budget_stages.rs:
//
//   1. Step 9.5 shingle view budget (finding aaae7a3c2): every body is
//      shingled over the same prefix, `unionBestMMRBodyCapScalars` or the
//      even share of `unionBestMMRShingleBudgetScalars`, whichever is
//      shorter. A `moot_memory_search` at its 500 hard ceiling over a wide
//      fused pool stays inside both.
//   2. Step 5.8 sub-span window budget (finding 49b0b7cd7): a pool whose
//      windows exceed the CorpusKit `SubSpanBudget` records the stage
//      `subSpan.budget` and the hits the budget left unscored carry the
//      explainer token `subSpan:budget`.
//
// Tests:
//   1. shingleViewStaysInsideTheBudgetAtThePublicLimitCeiling — 600 entropy
//      bodies of 5,000 scalars (a limit-500 pool): every body has a set, no set
//      exceeds the even share of the budget, and the view reports that the
//      budget shortened the prefix.
//   2. shingleViewWithinBudgetIsComplete — small bodies: every body has a
//      set, no truncation, a missing or empty body has none.
//   2b. capAloneIsNotATruncation — 200 bodies over the cap fit the budget at
//      the full cap: sets of cap - 2 shingles, no truncation; 300 such bodies
//      share the budget below the cap: truncation reported.
//   3. recallRecordsTheSubSpanBudgetStage — 20 ingested records of 16,000
//      scalars (about 1,700 sub-span windows), full hydration, limit 20: the
//      stage `subSpan.budget` is recorded and the unscored hits carry
//      `subSpan:budget`.
//   4. widePoolRecordsTheMMRBudgetStage — 300 captured drawers over the body
//      cap with tiny shingle sets (the locus lane supplies 256 of them, its
//      frontier ceiling, at limit 300), full hydration: 256 × cap exceeds
//      the budget, so the stage `unionBest.mmrBudget` is recorded.

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("UnionBest budget stages", .serialized)
struct UnionBestBudgetStagesTests {

    static let query = "quarterly budget review meeting notes finance team"

    /// A body of about `scalars` scalars that opens with the query terms and
    /// continues with filler drawn from a sixteen-word vocabulary. The window
    /// count grows with the token count, so the sub-span budget sees a long
    /// record, while the BM25 posting lists stay small: the in-memory row
    /// store's upsert is a linear scan, and a body of thousands of distinct
    /// tokens made one ingest cost seconds in a debug build.
    static func longBody(_ index: Int, scalars: Int) -> String {
        var body = "\(query) item \(index)"
        var word = 0
        while body.unicodeScalars.count < scalars {
            body += " " + Self.filler[word % Self.filler.count]
            word += 1
        }
        return body
    }

    static let filler = [
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
        "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
    ]

    /// A body of `scalars` scalars drawn from a 62-symbol alphabet by a linear
    /// congruential generator seeded by `index`: nearly every 3-gram is
    /// distinct, so the size of its shingle set reads back the prefix that
    /// was shingled (a 16-word filler body saturates at about 150 distinct
    /// 3-grams).
    static func entropyBody(_ index: Int, scalars: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ UInt64(index + 1)
        var out = ""
        out.reserveCapacity(scalars)
        for _ in 0..<scalars {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            out.append(alphabet[Int((state >> 33) % UInt64(alphabet.count))])
        }
        return out
    }

    @Test("the shingle view stays inside the budget at the public limit ceiling")
    func shingleViewStaysInsideTheBudgetAtThePublicLimitCeiling() {
        let bodies: [String?] = (0..<600).map { Self.entropyBody($0, scalars: 5_000) }
        let view = GeniusLocusKit.unionBestMMRShingles(bodies: bodies)
        #expect(view.truncated, "600 over-cap bodies share the budget below the cap")
        let withSets = view.sets.filter { $0 != nil }.count
        #expect(withSets == 600, "every body gets a set: the budget shortens, it never excludes")
        // The even share: 1,000,000 / 600 = 1,666 scalars each, at most 1,664
        // 3-grams per set, so the aggregate shingled scalars stay inside the budget.
        let share = GeniusLocusKit.unionBestMMRShingleBudgetScalars / 600
        #expect(share < GeniusLocusKit.unionBestMMRBodyCapScalars, "the share is below the cap for this pool")
        let maxSet = view.sets.compactMap { $0?.count }.max() ?? 0
        #expect(maxSet <= share - 2,
                "a 3-gram set over an even-share prefix holds at most share - 2 shingles; got \(maxSet)")
        #expect(600 * share <= GeniusLocusKit.unionBestMMRShingleBudgetScalars, "shingled scalars exceed the budget")
        // The sets are one measure: every body was shingled over the whole
        // share (nearly every 3-gram of an entropy body is distinct), so no
        // slot is a free rider.
        let minSet = view.sets.compactMap { $0?.count }.min() ?? 0
        #expect(minSet > share * 9 / 10, "every set covers its prefix; smallest \(minSet) for share \(share)")
    }

    @Test("a shingle view within the budget is complete")
    func shingleViewWithinBudgetIsComplete() {
        let bodies: [String?] = ["alpha beta gamma", "", "delta epsilon", nil]
        let view = GeniusLocusKit.unionBestMMRShingles(bodies: bodies)
        #expect(!view.truncated)
        #expect(view.sets[0] != nil)
        #expect(view.sets[1] == nil, "an empty body builds no set")
        #expect(view.sets[2] != nil)
        #expect(view.sets[3] == nil, "a slot without a body builds no set")
    }

    @Test("the cap alone is not a truncation")
    func capAloneIsNotATruncation() {
        // 200 over-cap bodies: 200 × 4,096 = 819,200 fits the budget, so every
        // body is cut by the cap alone (the measure, not a truncation).
        let twoHundred: [String?] = (0..<200).map { Self.entropyBody($0, scalars: 5_000) }
        let fits = GeniusLocusKit.unionBestMMRShingles(bodies: twoHundred)
        #expect(!fits.truncated, "the cap alone shortening a body is not a budget truncation")
        let fullCapMax = fits.sets.compactMap { $0?.count }.max() ?? 0
        #expect(fullCapMax <= GeniusLocusKit.unionBestMMRBodyCapScalars - 2,
                "a full-cap set holds at most cap - 2 shingles; got \(fullCapMax)")
        #expect(fullCapMax > GeniusLocusKit.unionBestMMRBodyCapScalars * 9 / 10,
                "a full-cap prefix was shingled; got \(fullCapMax)")

        // 300 over-cap bodies: 300 × 4,096 exceeds the budget, so the share
        // drops to 3,333 scalars and the view reports it.
        let threeHundred: [String?] = (0..<300).map { Self.entropyBody($0, scalars: 5_000) }
        let shared = GeniusLocusKit.unionBestMMRShingles(bodies: threeHundred)
        #expect(shared.truncated, "300 over-cap bodies share the budget below the cap")
        let share = GeniusLocusKit.unionBestMMRShingleBudgetScalars / 300
        let sharedMax = shared.sets.compactMap { $0?.count }.max() ?? 0
        #expect(sharedMax <= share - 2, "sets follow the share; got \(sharedMax) for share \(share)")
        #expect(sharedMax > share * 9 / 10, "the share was shingled whole; got \(sharedMax) for share \(share)")
    }

    /// An estate for the end-to-end stage tests: `count` drawers whose bodies
    /// `body(i)` gives, the first `ingested` of them also in a standalone
    /// corpus registered on the estate.
    private func openEstate(
        count: Int, ingested: Int, body: (Int) -> String
    ) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-budget-stages")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        // The deterministic model (the Rust twin's `Deterministic`): a hashed
        // float lane, so the 1,024 sub-span embeddings the budget allows cost
        // nothing and the test measures the bound, not the provider.
        let corpus = try await CorpusContentEngine(standaloneOn: corpusStorage, models: [.deterministic])
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        for i in 0..<count {
            let text = body(i)
            let frame = CaptureFrame(
                content: text, channel: .typed, room: "budget-stages",
                latticeAnchor: .udc("000"), addedBy: "budget-stages",
                embeddingModelID: "test-model-v1")
            let drawer = try await kit.capture(handle, frame)
            if i < ingested {
                try await corpus.ingest(text, contentID: drawer.id, now: now)
            }
        }
        await kit.registerCorpus(corpus, for: handle)
        return (kit, handle)
    }

    private func fullRequest(limit: Int) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed], hydrationLevel: .full, ordering: .byCaptureTimeDesc),
            mode: .unionBest, scoring: .matrixAware, limit: limit,
            fallback: .failClosed, queryText: Self.query, origin: .internal,
            // The budget stage only exists with the step 5.8 switch on.
            subSpanScoring: .on)
    }

    @Test("a recall over long ingested records records the sub-span budget stage and marks the unscored hits")
    func recallRecordsTheSubSpanBudgetStage() async throws {
        try await withIntellectusLock {
            // 20 records of 16,000 scalars (about 2,000 tokens, about 85
            // sub-span windows each under the 16 KiB record cap): their
            // 1,700-odd windows exceed the 1,024-window budget. Every drawer
            // is returned at limit 20, so the unscored ones are in the hits.
            let count = 20
            let (kit, handle) = try await openEstate(count: count, ingested: count) {
                Self.longBody($0, scalars: 16_000)
            }
            let result = try await kit.recall(handle, fullRequest(limit: count))
            #expect(!result.hits.isEmpty, "the bounded recall still answers")
            #expect(result.degradedStages.contains("subSpan.budget"),
                    "the sub-span window budget truncated on about 1,700 windows; stages: \(result.degradedStages)")
            let flagged = result.hits.filter { hit in
                hit.explanation.contains { $0.hasPrefix("score:") && $0.contains(" subSpan:budget") }
            }.count
            #expect(flagged > 0, "every candidate is returned at limit \(count), so the unscored ones carry the explainer token")
            #expect(flagged < result.hits.count, "the budget scored the first candidates")
        }
    }

    @Test("a wide full-hydration pool records the MMR shingle budget stage")
    func widePoolRecordsTheMMRBudgetStage() async throws {
        try await withIntellectusLock {
            // 300 bodies over the body cap: the locus lane supplies 256 of
            // them, its frontier ceiling, at limit 300, and 256 × 4,096
            // exceeds the 1,000,000 aggregate budget, so the share drops
            // below the cap. The bodies repeat three characters so their
            // shingle sets are tiny and the step 10 intersections cost
            // nothing: the stage depends on the scalars shingled, not on the
            // sets' sizes. No corpus content, so no BM25 supply and no
            // sub-span windows.
            let count = 300
            let (kit, handle) = try await openEstate(count: count, ingested: 0) { i in
                String(repeating: "ab ", count: 1_400) + "item \(i)"
            }
            let result = try await kit.recall(handle, fullRequest(limit: count))
            #expect(!result.hits.isEmpty, "the bounded recall still answers")
            #expect(result.degradedStages.contains("unionBest.mmrBudget"),
                    "the shingle budget shortened the prefix on 256 over-cap bodies; stages: \(result.degradedStages)")
            #expect(!result.degradedStages.contains("subSpan.budget"),
                    "no corpus record was long enough to spend the window budget; stages: \(result.degradedStages)")
        }
    }
}
