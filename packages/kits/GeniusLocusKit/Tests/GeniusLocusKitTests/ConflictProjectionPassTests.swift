import Foundation
import Testing
import LocusKit
import SubstrateML
@testable import GeniusLocusKit

/// DCP M2 — projection + coordinate index, Swift leg. The hardcoded
/// key/transaction-time/stableID literals are the CROSS-PORT FIXTURE:
/// `brain/conflict_projection_pass.rs` asserts the byte-identical strings
/// from the same fact, so the two ports cannot silently diverge in key
/// derivation, units handling, or identity. Ledger case F16 (oversized
/// bucket → truncation diagnostics) lives here per DCP_M0_CONTRACT §10.
@Suite struct ConflictProjectionPassTests {

    static func fact(
        id: String = "fact-1",
        subject: String = "Sarah Chen C0",
        predicate: String = "Employer",
        object: String = "Acme Robotics",
        sourceDrawerID: String = "drawer-a",
        adjectiveBitmap: Int64 = 0
    ) -> KGFact {
        KGFact(
            id: id, subject: subject, predicate: predicate, object: object,
            sourceDrawerID: sourceDrawerID, adjectiveBitmap: adjectiveBitmap,
            filedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Golden projection literals (generated once, pinned in both ports).
    @Test func goldenProjection() {
        let result = ConflictProjector.project(
            facts: [Self.fact()],
            eventTimeSecondsBySourceDrawer: ["drawer-a": 1_690_000_000],
            registry: .v01)
        #expect(result.diagnostics.scanned == 1)
        #expect(result.diagnostics.projected == 1)
        let s = try! #require(result.signatures.first)
        #expect(s.key == "person:sarah chen c0")
        #expect(s.dimension == "employer")
        #expect(s.transactionTime == 1_700_000_000)
        #expect(s.validity == .point(epochSeconds: 1_690_000_000))
        #expect(s.evidenceLocator == "kgfact:fact-1")
        #expect(s.stableID
            == "714b2f821567fb1a93f23e6f03e205538a4c490306d64d142811f3e53ddbc018")
    }

    /// Exclusions are counted, never silently dropped: non-active state,
    /// unregistered dimension, and unparseable object each take their own
    /// diagnostic lane (report coverage + unknown_or_invalid lines).
    @Test func exclusionsAreCounted() {
        let facts = [
            Self.fact(id: "f-active"),
            // State bits 0–5: withdrawn = 18.
            Self.fact(id: "f-withdrawn", adjectiveBitmap: 18),
            Self.fact(id: "f-unregistered", predicate: "favorite color"),
            // Registered dimension, object outside the closed enum set.
            Self.fact(id: "f-unparsed", object: "Globex Corp"),
        ]
        let result = ConflictProjector.project(
            facts: facts, eventTimeSecondsBySourceDrawer: [:], registry: .v01)
        #expect(result.diagnostics.scanned == 4)
        #expect(result.diagnostics.projected == 1)
        #expect(result.diagnostics.inactive == 1)
        #expect(result.diagnostics.unregistered == 1)
        #expect(result.diagnostics.unparsed == 1)
        // No event time supplied → unknown validity (M0 §5), still projects.
        #expect(result.signatures.first?.validity == TemporalBasis.unknown)
    }

    /// Predicate spelling folds through dimensionKey: "Primary Language"
    /// reaches the `primary language` rule.
    @Test func predicateSpellingFolds() {
        let result = ConflictProjector.project(
            facts: [Self.fact(predicate: "  Primary   Language ", object: "Rust")],
            eventTimeSecondsBySourceDrawer: [:], registry: .v01)
        #expect(result.diagnostics.projected == 1)
        #expect(result.signatures.first?.ruleID == "dim.person.primary_language")
    }

    /// Index pairs only within a coordinate, and never pairs two claims
    /// from the same source drawer.
    @Test func indexPairsWithinCoordinateOnly() {
        let project = { (facts: [KGFact]) -> [ConflictSignature] in
            ConflictProjector.project(
                facts: facts, eventTimeSecondsBySourceDrawer: [:],
                registry: .v01).signatures
        }
        let signatures = project([
            Self.fact(id: "f1", object: "Acme Robotics", sourceDrawerID: "d1"),
            Self.fact(id: "f2", object: "Beta Corp", sourceDrawerID: "d2"),
            // Same coordinate, same drawer as f1 — must not pair with f1.
            Self.fact(id: "f3", object: "Halcyon Labs", sourceDrawerID: "d1"),
            // Different subject — different bucket, no pairs.
            Self.fact(id: "f4", subject: "Noor Haddad C1", sourceDrawerID: "d3"),
        ])
        var index = ConflictCoordinateIndex()
        index.insert(contentsOf: signatures)
        let pairs = index.pairs()
        // f1–f2, f2–f3 (f1–f3 same drawer, f4 alone in its bucket).
        #expect(pairs.count == 2)
        #expect(index.truncatedBuckets == 0)
        for pair in pairs {
            #expect(pair.a.sourceDrawerID != pair.b.sourceDrawerID)
            #expect(ConflictCoordinateIndex.bucketKey(pair.a)
                == ConflictCoordinateIndex.bucketKey(pair.b))
        }
    }

    /// F16 — an oversized bucket keeps its first `bucketCap` signatures
    /// and reports the truncation; work stays bounded, loss stays visible.
    @Test func f16OversizedBucketTruncates() {
        let signatures = ConflictProjector.project(
            facts: [
                Self.fact(id: "f1", object: "Acme Robotics", sourceDrawerID: "d1"),
                Self.fact(id: "f2", object: "Beta Corp", sourceDrawerID: "d2"),
                Self.fact(id: "f3", object: "Halcyon Labs", sourceDrawerID: "d3"),
            ],
            eventTimeSecondsBySourceDrawer: [:], registry: .v01).signatures
        var index = ConflictCoordinateIndex(bucketCap: 2)
        index.insert(contentsOf: signatures)
        #expect(index.truncatedBuckets == 1)
        #expect(index.truncatedBucketKeys == ["person:sarah chen c0|employer"])
        // First two kept in insertion order → exactly one pair.
        let pairs = index.pairs()
        #expect(pairs.count == 1)
        #expect(pairs[0].a.sourceDrawerID == "d1")
        #expect(pairs[0].b.sourceDrawerID == "d2")
    }

    /// The pair walk is deterministic: same inserts, same order out.
    @Test func pairWalkIsDeterministic() {
        let signatures = ConflictProjector.project(
            facts: [
                Self.fact(id: "f1", object: "Acme Robotics", sourceDrawerID: "d1"),
                Self.fact(id: "f2", object: "Beta Corp", sourceDrawerID: "d2"),
                Self.fact(id: "f3", subject: "Noor Haddad C1",
                          object: "Halcyon Labs", sourceDrawerID: "d3"),
                Self.fact(id: "f4", subject: "Noor Haddad C1",
                          object: "Vireo Systems", sourceDrawerID: "d4"),
            ],
            eventTimeSecondsBySourceDrawer: [:], registry: .v01).signatures
        var first = ConflictCoordinateIndex()
        first.insert(contentsOf: signatures)
        var second = ConflictCoordinateIndex()
        second.insert(contentsOf: signatures)
        let a = first.pairs().map { "\($0.a.stableID)+\($0.b.stableID)" }
        let b = second.pairs().map { "\($0.a.stableID)+\($0.b.stableID)" }
        #expect(a == b)
        #expect(a.count == 2)
        // Buckets walk in sorted key order: noor before sarah.
        #expect(first.pairs()[0].a.key == "person:noor haddad c1")
    }

    /// End-to-end through the M1 evaluator: two active facts, same
    /// coordinate, different enum values, same event time → the pair the
    /// index yields evaluates to ProvenContradiction.
    @Test func indexedPairEvaluatesToProvenContradiction() {
        let result = ConflictProjector.project(
            facts: [
                Self.fact(id: "f1", object: "Acme Robotics", sourceDrawerID: "d1"),
                Self.fact(id: "f2", object: "Beta Corp", sourceDrawerID: "d2"),
            ],
            eventTimeSecondsBySourceDrawer: ["d1": 500, "d2": 500],
            registry: .v01)
        var index = ConflictCoordinateIndex()
        index.insert(contentsOf: result.signatures)
        let pairs = index.pairs()
        #expect(pairs.count == 1)
        let outcome = ConflictEvaluator.evaluate(
            pairs[0].a, pairs[0].b, registry: .v01)
        #expect(outcome.kind == .provenContradiction)
    }
}
