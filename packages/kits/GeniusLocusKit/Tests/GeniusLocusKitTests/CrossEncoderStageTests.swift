// CrossEncoderStageTests.swift
//
// The retrieval-time cross-encoder stage:
//
//   fuse      — every case of the shared fixture
//               (SynapseKit/Tests/Fixtures/encoder/cross_encoder_parity.json,
//               the lab's reference orders plus synthetic tail/tie cases)
//               reproduces its order exactly; the Rust twin reads the same file.
//   spans     — the windowed fallback and the span-row path select bounded,
//               non-empty texts; empty content selects nothing.
//   director  — on a 200-drawer in-memory estate: a nil directive is
//               byte-identical to a request without the field; bypass only
//               attaches a report; apply reaches the registered scorer with
//               the query and at most head × spans pairs, reorders within the
//               pool, re-cuts to the caller's limit and reports applied; the
//               manifest limits clamp; an unknown profile, missing query text,
//               missing model and a failing scorer degrade with their reason
//               and the incoming order; close drops the scorer.
//   packaged  — with MOOT_CROSS_ENCODER_ASSETS set (and the CrossEncoder trait
//               on) the real CoreML classifier loads once through the
//               product's resolver and the apply reports `coreml`.

import Foundation
import Testing
import LocusKit
import CorpusKit
import CorpusKitProviders
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// MARK: - Fixture

private struct FuseCase: Decodable {
    let name: String
    let incoming: [String]
    let head: Int
    let rrf_k: Int
    let logits: [String: [Float]]
    let expected: [String]
}
private struct FuseFixture: Decodable { let cases: [FuseCase] }

/// packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/<file> → packages/kits/ →
/// SynapseKit/Tests/Fixtures/encoder/ (four components up: file, suite dir, Tests, kit).
private func fuseFixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SynapseKit/Tests/Fixtures/encoder/cross_encoder_parity.json")
}

@Suite("Cross-encoder fuse parity fixture")
struct CrossEncoderFuseParityTests {
    @Test("every case reproduces the lab's fused order")
    func everyCase() throws {
        let fixture = try JSONDecoder().decode(FuseFixture.self, from: Data(contentsOf: fuseFixtureURL()))
        #expect(fixture.cases.count >= 6)
        for c in fixture.cases {
            let order = CrossEncoderStage.fuse(incoming: c.incoming, head: c.head, logits: c.logits, rrfK: c.rrf_k)
            #expect(order == c.expected, "\(c.name)")
        }
    }

    @Test("logits outside the head and a head larger than the pool are harmless")
    func edges() {
        // `zzz` is not in the pool and is ignored; `a` unscored (cross rank 2)
        // and `b` scored (cross rank 1) tie on RRF, and the tie keeps the
        // incoming order.
        let order = CrossEncoderStage.fuse(
            incoming: ["a", "b"], head: 30, logits: ["zzz": [99], "b": [1]], rrfK: 60)
        #expect(order == ["a", "b"])
        // Three candidates: the scored one at the back climbs over the unscored middle.
        #expect(CrossEncoderStage.fuse(incoming: ["a", "b", "c"], head: 30, logits: ["c": [5]], rrfK: 60) == ["a", "c", "b"])
        #expect(CrossEncoderStage.fuse(incoming: ["a"], head: 0, logits: ["a": [1]], rrfK: 60) == ["a"])
    }
}

@Suite("Cross-encoder span selection")
struct CrossEncoderSpanSelectionTests {
    @Test("the windowed fallback yields at most `limit` bounded, non-empty spans")
    func windowed() {
        let content = (0..<130).map { "w\($0)" }.joined(separator: " ")
        let spans = CrossEncoderStage.selectSpans(
            content: content, rows: nil, queryVector: nil, limit: 3, windowWords: 60, overlapDivisor: 2)
        #expect(spans.count == 3)
        #expect(spans.allSatisfy { !$0.isEmpty && $0.split(separator: " ").count <= 60 })
        // Spanner rule 2: starts 0, 30, 60 at window 60; the tail past word
        // 119 is not force-covered (the reference windowing).
        #expect(spans[0].hasPrefix("w0 w1 "))
        #expect(spans[2].hasPrefix("w60 ") && spans[2].hasSuffix(" w119"))
        #expect(CrossEncoderStage.selectSpans(content: "   ", rows: nil, queryVector: nil, limit: 3, windowWords: 60, overlapDivisor: 2).isEmpty)
        #expect(CrossEncoderStage.selectSpans(content: content, rows: nil, queryVector: nil, limit: 0, windowWords: 60, overlapDivisor: 2).isEmpty)
    }

    @Test("stored span rows are ranked by cosine and rebuilt from their word bounds")
    func rows() {
        let content = (0..<20).map { "w\($0)" }.joined(separator: " ")
        let rows = [
            SpanRerankVector(index: 0, int8: [10, 0], scale: 0.01, startWord: 0, endWord: 5),
            SpanRerankVector(index: 1, int8: [100, 0], scale: 0.01, startWord: 5, endWord: 10),
            SpanRerankVector(index: 2, int8: [50, 0], scale: 0.01, startWord: 10, endWord: 40),
        ]
        let spans = CrossEncoderStage.selectSpans(
            content: content, rows: rows, queryVector: [1, 0], limit: 2, windowWords: 60, overlapDivisor: 2)
        #expect(spans == ["w5 w6 w7 w8 w9", "w10 w11 w12 w13 w14 w15 w16 w17 w18 w19"])
        // A row of the wrong dimension is not this model's; with none usable the
        // fallback windows the content instead.
        let wrong = [SpanRerankVector(index: 0, int8: [1, 2, 3], scale: 1, startWord: 0, endWord: 5)]
        let fallback = CrossEncoderStage.selectSpans(
            content: content, rows: wrong, queryVector: [1, 0], limit: 2, windowWords: 60, overlapDivisor: 2)
        #expect(fallback == [content])
    }
}

// MARK: - Director

/// Records every (query, spans) it scores; a span carrying `favored` wins.
private actor ScoreLog {
    var calls: [(query: String, spans: [String])] = []
    func record(_ query: String, _ spans: [String]) { calls.append((query, spans)) }
}

private struct FakePairScorer: PairScorer {
    let profile: CrossEncoderProfile = .minilmL6
    let favored: String
    let log: ScoreLog
    let failing: Bool
    var backend: String { "fake" }
    func score(query: String, spans: [String]) async throws -> [Float] {
        await log.record(query, spans)
        if failing { throw EncoderError.inferenceFailed("fake failure") }
        return spans.map { $0.contains(favored) ? 10 : -10 }
    }
}

@Suite("Cross-encoder stage in recall", .serialized)
struct CrossEncoderStageDirectorTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// 200 drawers; every fourth carries the query terms at differing lengths
    /// (the SpanRerankStageTests corpus) and every drawer carries a unique
    /// `tag<i>zz` token so a scorer can favour exactly one.
    private func openEstate(owner ownerID: String) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusKit.CorpusContentEngine(
            standaloneOn: corpusStorage,
            models: [.miniLM(inference: { tokens in
                let v = Float((tokens.first ?? 0) % 7 + 1) / 7.0
                return Array(repeating: v, count: 384)
            })])
        for i in 0..<200 {
            let padding = (0..<(i % 9 + 1)).map { "filler\($0 + i)" }.joined(separator: " ")
            let content = i % 4 == 0
                ? "ledger note tag\(i)zz \(padding) reconciled by clerk \(i % 13)"
                : "invoice archive tag\(i)zz \(padding) filed by assistant \(i % 11)"
            let frame = CaptureFrame(content: content, channel: .typed, room: "cross-stage-tests",
                                     latticeAnchor: .udc("000"), addedBy: "cross-stage-tests",
                                     embeddingModelID: "test-model-v1")
            let drawer = try await kit.capture(handle, frame)
            try await corpus.ingest(content, contentID: drawer.id, now: Self.t0)
        }
        await kit.registerCorpus(corpus, for: handle)
        return (kit: kit, handle: handle)
    }

    private func request(limit: Int = 20, query: String? = "ledger reconciled clerk", frontierK: Int? = nil, directive: RerankDirective?) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(filterChain: [], hydrationLevel: .full, ordering: .byCaptureTimeDesc),
            mode: .unionBest, scoring: .matrixAware, limit: limit,
            fallback: .failClosed, queryText: query, origin: .internal,
            frontierK: frontierK, rerankDirective: directive)
    }

    /// The page an apply widens to: the pool as the limit, at the frontier the
    /// caller's own limit-20 request computes (`min(max(20 × 4, 64), 256)`).
    private func poolPage(_ kit: GeniusLocusKit, _ handle: EstateHandle) async throws -> GLKRecallResult {
        try await kit.recall(handle, request(limit: 50, frontierK: 80, directive: nil))
    }

    @Test("nil is byte-identical and carries no report; bypass only attaches a report")
    func nilAndBypass() async throws {
        let (kit, handle) = try await openEstate(owner: "ce-nil")
        let plain = try await kit.recall(handle, request(directive: nil))
        #expect(plain.hits.count >= 20)
        #expect(plain.crossEncoder == nil)
        let again = try await kit.recall(handle, request(directive: nil))
        #expect(again.hits.map(\.id) == plain.hits.map(\.id))
        let bypass = try await kit.recall(handle, request(directive: .bypass(reason: "strategy")))
        #expect(bypass.hits.map(\.id) == plain.hits.map(\.id))
        #expect(bypass.crossEncoder?.status == .bypassed)
        #expect(bypass.crossEncoder?.requested == false)
        #expect(bypass.crossEncoder?.reason == "strategy")
        #expect(bypass.degradedStages == plain.degradedStages)
        #expect(bypass.request.rerankDirective == .bypass(reason: "strategy"))
    }

    @Test("apply reaches the scorer, reorders within the pool, re-cuts to the limit and reports applied")
    func apply() async throws {
        let (kit, handle) = try await openEstate(owner: "ce-apply")
        let plain = try await kit.recall(handle, request(directive: nil))
        let wide = try await poolPage(kit, handle)
        #expect(wide.hits.count > 20)
        // Favour a candidate inside the head (incoming rank 6..30) so the
        // fusion can lift it above candidates it trailed.
        let favoredHit = try #require(wide.hits.dropFirst(5).first)
        let favoredIndexBefore = try #require(wide.hits.firstIndex { $0.id == favoredHit.id })
        let favored = try #require(favoredHit.drawer?.content.split(separator: " ").first { $0.hasPrefix("tag") }).description
        let log = ScoreLog()
        await kit.registerPairScorer(FakePairScorer(favored: favored, log: log, failing: false), for: handle)

        let applied = try await kit.recall(handle, request(directive: .apply(reason: "explicit")))
        let report = try #require(applied.crossEncoder)
        #expect(report.status == .applied)
        #expect(report.requested)
        #expect(report.reason == "explicit")
        #expect(report.backend == "fake")
        #expect(report.profileID == CrossEncoderProfile.minilmL6.modelID)
        #expect(report.modelVersion == CrossEncoderProfile.minilmL6.modelVersion)
        #expect(report.pool == min(50, wide.hits.count))
        #expect(report.head == min(30, report.pool))
        #expect(report.spans == 3)
        #expect(report.scored == report.head)
        #expect(report.coldLoad == false)   // registered, not loaded
        #expect(report.stageMillis != nil)
        // The caller's limit and the original request come back.
        #expect(applied.hits.count == 20)
        #expect(applied.request.limit == 20)
        #expect(applied.degradedStages == plain.degradedStages)
        // Membership of the caller's cut is drawn from the pool, never outside it.
        let poolIDs = Set(wide.hits.prefix(report.pool).map(\.id))
        #expect(applied.hits.allSatisfy { poolIDs.contains($0.id) })
        // The favoured candidate rose.
        let favoredIndexAfter = try #require(applied.hits.firstIndex { $0.id == favoredHit.id })
        #expect(favoredIndexAfter < favoredIndexBefore)
        // The scorer saw the query and at most head candidates × spans pairs.
        let calls = await log.calls
        #expect(calls.count == report.head)
        #expect(calls.allSatisfy { $0.query == "ledger reconciled clerk" && !$0.spans.isEmpty && $0.spans.count <= 3 })
        #expect(calls.contains { $0.spans.contains { $0.contains(favored) } })
    }

    @Test("the manifest limits clamp the pool, head and spans")
    func manifestLimits() async throws {
        let (kit, handle) = try await openEstate(owner: "ce-limits")
        try await kit.provisionCrossEncoderLimits(pool: 8, head: 4, spans: 1, for: handle)
        #expect(await kit.provisionedCrossEncoderLimits(profile: .minilmL6, for: handle) == CrossEncoderLimits(pool: 8, head: 4, spans: 1))
        // Above the profile clamps to the profile.
        try await kit.provisionCrossEncoderLimits(pool: 500, head: 400, spans: 9, for: handle)
        #expect(await kit.provisionedCrossEncoderLimits(profile: .minilmL6, for: handle) == CrossEncoderLimits(pool: 50, head: 30, spans: 3))
        try await kit.provisionCrossEncoderLimits(pool: 8, head: 4, spans: 1, for: handle)
        let log = ScoreLog()
        await kit.registerPairScorer(FakePairScorer(favored: "none", log: log, failing: false), for: handle)
        let applied = try await kit.recall(handle, request(limit: 5, directive: .apply()))
        let report = try #require(applied.crossEncoder)
        #expect(report.status == .applied)
        #expect((report.pool, report.head, report.spans) == (8, 4, 1))
        #expect(applied.hits.count == 5)
        let calls = await log.calls
        #expect(calls.count == 4)
        #expect(calls.allSatisfy { $0.spans.count == 1 })
    }

    @Test("an unknown profile, no query text, no model and a failing scorer degrade with the incoming order")
    func degrades() async throws {
        let (kit, handle) = try await openEstate(owner: "ce-degrade")
        let plain = try await kit.recall(handle, request(directive: nil))
        // An apply with a packaged profile widens the lanes to the pool, so
        // its incoming order is the pool-wide page; a degrade hands back the
        // caller's cut of THAT page. An unknown profile never widens.
        let wide = try await poolPage(kit, handle)
        let poolHead = Array(wide.hits.prefix(20).map(\.id))

        let unknown = try await kit.recall(handle, request(directive: RerankDirective(action: .apply, profileID: "nope-v9")))
        #expect(unknown.hits.map(\.id) == plain.hits.map(\.id))
        #expect(unknown.crossEncoder?.status == .degraded)
        #expect(unknown.crossEncoder?.reason == CrossEncoderStage.Reason.profileUnknown)
        #expect(unknown.degradedStages.contains(CrossEncoderStage.degradedStage))

        let noModel = try await kit.recall(handle, request(directive: .apply()))
        #expect(noModel.hits.map(\.id) == poolHead)
        #expect(noModel.crossEncoder?.status == .degraded)
        #expect([CrossEncoderStage.Reason.modelUnavailable, CrossEncoderStage.Reason.capabilityOff]
            .contains(noModel.crossEncoder?.reason ?? ""))
        #expect(await kit.isPairScorerRegistered(for: handle) == false)

        let noQuery = try await kit.recall(handle, request(query: nil, directive: .apply()))
        #expect(noQuery.crossEncoder?.status == .degraded)
        #expect(noQuery.crossEncoder?.reason == CrossEncoderStage.Reason.noQueryText)

        let log = ScoreLog()
        await kit.registerPairScorer(FakePairScorer(favored: "none", log: log, failing: true), for: handle)
        let failed = try await kit.recall(handle, request(directive: .apply()))
        #expect(failed.hits.map(\.id) == poolHead)
        #expect(failed.crossEncoder?.status == .degraded)
        #expect(failed.crossEncoder?.reason == CrossEncoderStage.Reason.scorerFailed)
        #expect(failed.degradedStages.contains(CrossEncoderStage.degradedStage))
    }

    @Test("close drops the scorer slot")
    func closeReleases() async throws {
        let (kit, handle) = try await openEstate(owner: "ce-close")
        await kit.registerPairScorer(FakePairScorer(favored: "none", log: ScoreLog(), failing: false), for: handle)
        #expect(await kit.isPairScorerRegistered(for: handle))
        try await kit.close(handle)
        #expect(await kit.isPairScorerRegistered(for: handle) == false)
    }

#if MOOTX01_CROSS_ENCODER
    @Test("the packaged CoreML classifier loads once through the resolver and applies (MOOT_CROSS_ENCODER_ASSETS)")
    func packaged() async throws {
        guard let root = ProcessInfo.processInfo.environment["MOOT_CROSS_ENCODER_ASSETS"], !root.isEmpty else { return }
        let apple = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("apple", isDirectory: true)
        guard FileManager.default.fileExists(atPath: apple.path) else { return }
        // Stage the assets in the resolver's download slot of a scratch
        // configuration directory: <scratch>/models/<modelID>/.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-packaged-\(UUID().uuidString)", isDirectory: true)
        let target = scratch.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(CrossEncoderProfile.minilmL6.modelID, isDirectory: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: apple, to: target)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let (kit, handle) = try await openEstate(owner: "ce-packaged")
        await kit.setModelDirectoryResolver(BundledModelDirectoryResolver(dataDirectory: scratch))
        let first = try await kit.recall(handle, request(directive: .apply()))
        let report = try #require(first.crossEncoder)
        #expect(report.status == .applied, "\(report)")
        #expect(report.backend == "coreml")
        #expect(report.coldLoad)
        #expect(report.scored == report.head)
        #expect(first.hits.count == 20)
        let second = try await kit.recall(handle, request(directive: .apply()))
        #expect(second.crossEncoder?.status == .applied)
        #expect(second.crossEncoder?.coldLoad == false)
        #expect(second.hits.map(\.id) == first.hits.map(\.id))
        let bypass = try await kit.recall(handle, request(directive: .bypass()))
        #expect(bypass.crossEncoder?.status == .bypassed)
    }
#endif
}
