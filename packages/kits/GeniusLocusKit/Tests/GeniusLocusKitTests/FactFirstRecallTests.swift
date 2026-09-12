import FactExtractionKit
import Foundation
@testable import GeniusLocusKit
import LocusKit
import Testing

@Suite("Fact-first recall gate")
struct FactFirstRecallTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("solid fact carries its source as one family")
    func solidFamily() {
        let jack = fact(
            id: "jack-birthday", subject: "Jack", object: "June 20th",
            source: "source-jack", projection: "Jack birthday June 20th when is Jack birthday")
        let jill = fact(
            id: "jill-birthday", subject: "Jill", object: "May 4th",
            source: "source-jill", projection: "Jill birthday May 18th")
        let sources = [
            "source-jack": drawer(id: "source-jack", content: "Jack's birthday is June 20th."),
            "source-jill": drawer(id: "source-jill", content: "Jill's birthday is May 18th."),
        ]
        let decision = FactFirstRecallStage.decide(
            query: "when is jacks birthday", queryEntities: ["Jack"],
            facts: [jill, jack], sourceDrawers: sources)
        guard case let .solid(family) = decision else {
            Issue.record("expected a solid fact-first result")
            return
        }
        #expect(family.fact.id == "jack-birthday")
        #expect(family.source.id == "source-jack")
        #expect(family.margin >= 0.20)
        #expect(family.entityContainment == 1)
    }

    @Test("missing entity evidence and a tied head both fall through")
    func conservativeGates() {
        let first = fact(
            id: "a", subject: "Jack", object: "June 20th", source: "source-jack",
            projection: "Jack birthday June 20th")
        let second = fact(
            id: "b", subject: "Jack", object: "June 21st", source: "source-jack",
            projection: "Jack birthday June 21st")
        let sources = ["source-jack": drawer(id: "source-jack", content: "source")]
        #expect(FactFirstRecallStage.decide(
            query: "when is jacks birthday", queryEntities: [],
            facts: [first], sourceDrawers: sources) == .fallThrough)
        #expect(FactFirstRecallStage.decide(
            query: "when is jacks birthday", queryEntities: ["Jack"],
            facts: [first, second], sourceDrawers: sources) == .fallThrough)

        let staleSources = [
            "source-jack": drawer(id: "source-jack", content: "edited", settled: false),
        ]
        #expect(FactFirstRecallStage.decide(
            query: "when is jacks birthday", queryEntities: ["Jack"],
            facts: [first], sourceDrawers: staleSources) == .fallThrough)

        let weak = fact(
            id: "weak", subject: "Jack", object: "Seattle", source: "source-jack",
            projection: "Jack Seattle")
        #expect(FactFirstRecallStage.decide(
            query: "when is jacks birthday", queryEntities: ["Jack"],
            facts: [weak], sourceDrawers: sources,
            vectorScores: ["weak": 1]) == .fallThrough)
    }

    // MARK: — Gate B

    /// Gate B: a fact with a stale searchProjectionVersion is excluded from
    /// recall by FactFirstRecall's version guard. Once the correct version is
    /// stamped (exactly what the backfill writes), the fact wins the query.
    ///
    /// Design — inverted so the test discriminates:
    ///   f-unprojected (Jack) carries the content the query asks for, but its
    ///   searchProjectionVersion = "" (wrong, as if the backfill has not run).
    ///   f-projected (Jill) has the correct version but scores poorly on the
    ///   "jack birthday" query: coverage 0.5 and entity containment 0.
    ///
    ///   Phase 1: f-unprojected is excluded by the version guard (line 80 of
    ///   FactFirstRecall.swift). Jill scores 0.5 < 0.70 and has containment 0.
    ///   Decision: fallThrough.
    ///
    ///   Phase 2: f-unprojected receives FactSearchProjection.version — the
    ///   exact bytes the backfill writes. Jack now scores ≥ 0.70, margin ≥ 0.20,
    ///   containment = 1. Decision: .solid(f-unprojected).
    ///
    /// Discrimination proof: temporarily deleting lines 79-80 from
    /// FactFirstRecall.swift makes f-unprojected (Jack) eligible in Phase 1;
    /// Jack scores ≥ 0.70 and wins, so Phase 1's fallThrough assertion fails →
    /// the test goes red. Restoring those lines returns it to green.
    ///
    /// Note on empty searchProjection (the actual schema DEFAULT): for facts
    /// where searchProjection = "", line 79's explicit isEmpty check and the
    /// downstream !tokens.isEmpty guard both exclude the fact. Removing
    /// lines 79-80 alone does not expose an empty-string fact because
    /// defaultKeywordTokens("") always returns []. This test exercises line 80
    /// (the version check) — the specific condition the backfill satisfies.
    @Test("Gate B: stale-versioned fact is invisible to recall; versioned fact wins")
    func gateBSearchProjectionRecallConsequence() {
        let sourceID = "source-b"
        let source = drawer(id: sourceID, content: "Jack's birthday is in June.", settled: true)
        let sources = [sourceID: source]

        // Fact 1 (the winning candidate): Jack, with the correct projection
        // content but searchProjectionVersion = "" (wrong — the backfill has
        // not yet stamped the version). The version guard (line 80) excludes it.
        let jackProjection = FactSearchProjection.build(
            subject: "Jack", predicate: "birthday", object: "June", aliases: [])
        let unProjected = KGFact(
            id: "f-unprojected", subject: "Jack", predicate: "birthday", object: "June",
            sourceDrawerID: sourceID, searchProjection: jackProjection,
            searchProjectionVersion: "",   // wrong — excluded by the version guard
            filedAt: now)

        // Fact 2 (the decoy): Jill, correctly versioned, but low-scoring.
        // "jack birthday" ∩ {"jill", "birthday", "june"} = {"birthday"} → 0.5,
        // below the 0.70 floor; entity containment = 0 (Jill ≠ Jack).
        let jillProjection = FactSearchProjection.build(
            subject: "Jill", predicate: "birthday", object: "June", aliases: [])
        let projected = KGFact(
            id: "f-projected", subject: "Jill", predicate: "birthday", object: "June",
            sourceDrawerID: sourceID, searchProjection: jillProjection,
            searchProjectionVersion: FactSearchProjection.version, filedAt: now)

        // Phase 1 — guard active: f-unprojected (Jack) excluded by the version
        // guard. Jill is the only eligible candidate but scores 0.5 and has
        // entity containment 0 → fallThrough.
        let decision = FactFirstRecallStage.decide(
            query: "jack birthday", queryEntities: ["Jack"],
            facts: [unProjected, projected], sourceDrawers: sources)
        #expect(decision == .fallThrough,
                "Phase 1: stale-versioned Jack fact must not be returned; Jill alone fails the 0.70 score floor and entity containment gate")

        // Phase 2 — after backfill: Jack receives FactSearchProjection.version —
        // the exact bytes the gateway writes. Coverage 2/2 = 1.0, margin ≥ 0.20,
        // containment = 1 → .solid(f-unprojected).
        let nowProjected = KGFact(
            id: "f-unprojected", subject: "Jack", predicate: "birthday", object: "June",
            sourceDrawerID: sourceID, searchProjection: jackProjection,
            searchProjectionVersion: FactSearchProjection.version,   // backfill's stamp
            filedAt: now)

        let afterDecision = FactFirstRecallStage.decide(
            query: "jack birthday", queryEntities: ["Jack"],
            facts: [nowProjected, projected], sourceDrawers: sources)

        guard case let .solid(family) = afterDecision else {
            Issue.record("Phase 2: expected .solid after version stamp; got \(afterDecision)")
            return
        }
        #expect(family.fact.id == "f-unprojected",
                "Phase 2: the formerly-stale Jack fact must win once the version is stamped")
    }

    // Gate B extension: the empty-projection shape after a correct-version backfill.
    //
    // A post-migration-plus-wrong-order scenario: the fact's searchProjectionVersion
    // is correct (the backfill stamped the version) but searchProjection is "" (the
    // backfill wrote an empty string, which is the actual schema DEFAULT for unextracted
    // rows). The version guard passes; only the empty-projection guards remain.
    //
    // Two mechanisms exclude the empty-projection fact:
    //   1. FactFirstRecall.swift line 79: `!fact.searchProjection.isEmpty`
    //   2. `guard !tokens.isEmpty` (defaultKeywordTokens("") returns []).
    //
    // This test CANNOT discriminate between the two mechanisms: an empty
    // searchProjection triggers both at once — the isEmpty check fires first, and
    // even if it were removed, the downstream tokens guard would exclude the fact.
    // The test documents a defended invariant — both guards cover the empty-projection
    // shape — without claiming a discrimination it does not have.
    @Test("Gate B ext: empty-projection fact excluded; stamped fact wins")
    func gateBEmptyProjectionExcluded() {
        let sourceID = "source-empty"
        let source = drawer(id: sourceID, content: "Jack's birthday is in June.", settled: true)
        let sources = [sourceID: source]

        // Fact with a correct searchProjectionVersion but an empty searchProjection —
        // the honest shape for isolating the empty-projection guards. Subject/object
        // match the query so only the empty-projection guards prevent a hit.
        let emptyFact = KGFact(
            id: "f-empty", subject: "Jack", predicate: "birthday", object: "June",
            sourceDrawerID: sourceID, searchProjection: "",
            searchProjectionVersion: FactSearchProjection.version,
            filedAt: now)

        // Phase 1: the empty-projection fact is excluded. No eligible fact
        // remains → fallThrough.
        let decision = FactFirstRecallStage.decide(
            query: "jack birthday", queryEntities: ["Jack"],
            facts: [emptyFact], sourceDrawers: sources)
        #expect(decision == .fallThrough,
                "empty-projection fact must not be returned; excluded by isEmpty guard and downstream !tokens.isEmpty guard")

        // Phase 2: stamp the fact with the real FactSearchProjection values —
        // the exact bytes the backfill writes. Now it must win.
        let stamped = KGFact(
            id: "f-empty", subject: "Jack", predicate: "birthday", object: "June",
            sourceDrawerID: sourceID,
            searchProjection: FactSearchProjection.build(
                subject: "Jack", predicate: "birthday", object: "June", aliases: []),
            searchProjectionVersion: FactSearchProjection.version,
            filedAt: now)

        let afterDecision = FactFirstRecallStage.decide(
            query: "jack birthday", queryEntities: ["Jack"],
            facts: [stamped], sourceDrawers: sources)
        guard case let .solid(family) = afterDecision else {
            Issue.record("Phase 2: expected .solid after stamp; got \(afterDecision)")
            return
        }
        #expect(family.fact.id == "f-empty",
                "Phase 2: the stamped fact must win recall")
    }

    private func fact(
        id: String, subject: String, object: String, source: String, projection: String
    ) -> KGFact {
        KGFact(
            id: id, subject: subject, predicate: "birthday", object: object,
            sourceDrawerID: source, searchProjection: projection,
            searchProjectionVersion: FactSearchProjection.version, filedAt: now)
    }

    private func drawer(id: String, content: String, settled: Bool = true) -> Drawer {
        Drawer(
            id: id, content: content, parentNodeId: "room", addedBy: "test",
            filedAt: now, embeddingModelID: "test",
            operationalBitmap: settled ? DrawerFeatureFlags.factsExtracted.rawValue : 0)
    }
}
