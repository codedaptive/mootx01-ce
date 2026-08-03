import Testing
@testable import SubstrateML

/// DCP M1 golden corpus — Swift leg. The hardcoded literals here are
/// the CROSS-PORT FIXTURE: `conflict_projection_golden.rs` asserts the
/// byte-identical strings from the same inputs, so the two ports cannot
/// silently diverge in canonical values, outcome classes, reason codes,
/// or stable identities. Ledger cases (DCP_M0_CONTRACT §10): F01–F05,
/// F07–F10, F17, F20.
@Suite struct ConflictProjectionGoldenTests {

    static let tx: Int64 = 1_700_000_000

    /// Normalize `raw` through the v0.1 registry rule for `dimension`.
    static func norm(_ dimension: String, _ raw: String) -> TypedConflictValue? {
        ConflictRuleRegistry.v01.rule(forDimension: dimension)?.normalize(raw)
    }

    static func sig(
        key: String, dimension: String, value: TypedConflictValue,
        src: String, validity: TemporalBasis, ruleID: String,
        status: ConflictClaimStatus = .asserted
    ) -> ConflictSignature {
        ConflictSignature(
            key: key, dimension: dimension, value: value,
            sourceDrawerID: src, transactionTime: tx,
            validity: validity, status: status,
            ruleID: ruleID, ruleVersion: 1)
    }

    static func employerPair() -> (ConflictSignature, ConflictSignature) {
        (
            sig(key: "person:sarah chen c0", dimension: "employer",
                value: norm("employer", "Acme Robotics")!,
                src: "drawer-a", validity: .unknown,
                ruleID: "dim.person.employer"),
            sig(key: "person:sarah chen c0", dimension: "employer",
                value: norm("employer", "Beta Corp")!,
                src: "drawer-b", validity: .unknown,
                ruleID: "dim.person.employer")
        )
    }

    /// Golden identity literals (generated once, pinned in both ports).
    @Test func goldenStableIdentities() {
        let (a, b) = Self.employerPair()
        #expect(a.stableID
            == "d8cdc5118b6c55e03f62865f41d492651c6b4ce1c901c604d3f3d85899827950")
        #expect(b.stableID
            == "f5a34a5d6bc457c026373d07da6bc4b9b1e6b23f9fe5fa2306ce10fe0333475f")
    }

    /// F03 — genuinely different values → ProvenContradiction, and
    /// F20 — pair order can never change the result identity.
    @Test func f03f20PlantedContradictionAndPairOrderInvariance() {
        let (a, b) = Self.employerPair()
        let fwd = ConflictEvaluator.evaluate(a, b, registry: .v01)
        let rev = ConflictEvaluator.evaluate(b, a, registry: .v01)
        #expect(fwd.kind == .provenContradiction)
        #expect(fwd.resultID
            == "c29f4790ef9f84f0846252d21768cdd64bc82ded5cf1867b11e29514a0b38212")
        #expect(rev.resultID == fwd.resultID)
        #expect(rev.kind == fwd.kind)
        #expect(fwd.sourceDrawerIDs == ["drawer-a", "drawer-b"])
        #expect(fwd.reasons == [.sameCoordinate, .validityUnknown, .valuesExclusive])
    }

    /// F01 — identical decision, different wording → Agreement.
    @Test func f01WordingVariantsAgree() {
        let a = Self.sig(key: "person:x", dimension: "employer",
            value: Self.norm("employer", "  acme   ROBOTICS ")!,
            src: "d1", validity: .unknown, ruleID: "dim.person.employer")
        let b = Self.sig(key: "person:x", dimension: "employer",
            value: Self.norm("employer", "Acme Robotics")!,
            src: "d2", validity: .unknown, ruleID: "dim.person.employer")
        #expect(a.value.canonicalBytes == "e:dim.person.employer#acme robotics")
        let out = ConflictEvaluator.evaluate(a, b, registry: .v01)
        #expect(out.kind == .agreement)
        #expect(out.reasons == [.sameCoordinate, .valueEquivalent])
    }

    /// F02 — equivalent units agree exactly (1h == 60min == dur:3600),
    /// and budget normalization folds k/m suffixes ($1.5m == 1,500k USD).
    @Test func f02EquivalentUnitsAgree() {
        #expect(ConflictNormalize.duration("1h")?.canonicalBytes == "dur:3600")
        #expect(ConflictNormalize.duration("60 min")?.canonicalBytes == "dur:3600")
        #expect(Self.norm("decision:budget_ceiling", "1,500k USD")?.canonicalBytes
            == "d:1500000")
        #expect(Self.norm("decision:budget_ceiling", "$1.5m")?.canonicalBytes
            == "d:1500000")
        #expect(Self.norm("decision:budget_ceiling", "12.50")?.canonicalBytes
            == "d:12.5")
        let a = Self.sig(key: "decision:phoenix", dimension: "decision:budget_ceiling",
            value: Self.norm("decision:budget_ceiling", "1,500k USD")!,
            src: "d1", validity: .point(epochSeconds: 100),
            ruleID: "dim.decision.budget_ceiling")
        let b = Self.sig(key: "decision:phoenix", dimension: "decision:budget_ceiling",
            value: Self.norm("decision:budget_ceiling", "$1.5m")!,
            src: "d2", validity: .point(epochSeconds: 100),
            ruleID: "dim.decision.budget_ceiling")
        #expect(ConflictEvaluator.evaluate(a, b, registry: .v01).kind == .agreement)
    }

    /// F04 — true vs false for the same proposition → ProvenContradiction.
    @Test func f04BooleanOppositionContradicts() {
        // Boolean values through an unregistered dimension would be
        // rule_unknown; pin the VALUE layer here (registry-level boolean
        // rules arrive with a real boolean dimension) plus the evaluator
        // over a single-valued registered dimension using dates.
        #expect(TypedConflictValue.boolean(true).canonicalBytes == "b:true")
        #expect(TypedConflictValue.boolean(false).canonicalBytes == "b:false")
        #expect(!TypedConflictValue.boolean(true)
            .isEquivalent(to: .boolean(false)))
        let a = Self.sig(key: "decision:phoenix", dimension: "decision:launch_date",
            value: Self.norm("decision:launch_date", "2026-09-15")!,
            src: "d1", validity: .unknown, ruleID: "dim.decision.launch_date")
        let b = Self.sig(key: "decision:phoenix", dimension: "decision:launch_date",
            value: Self.norm("decision:launch_date", "2026-10-01")!,
            src: "d2", validity: .unknown, ruleID: "dim.decision.launch_date")
        #expect(a.value.canonicalBytes == "dt:2026-09-15")
        #expect(ConflictEvaluator.evaluate(a, b, registry: .v01).kind
            == .provenContradiction)
    }

    /// F05 — same dimension, different scopes → Irrelevant (scope_mismatch).
    @Test func f05DistinctScopesAreIrrelevant() {
        let a = Self.sig(key: "org:acme/project:phoenix/release",
            dimension: "decision:launch_date",
            value: Self.norm("decision:launch_date", "2026-09-15")!,
            src: "d1", validity: .unknown, ruleID: "dim.decision.launch_date")
        let b = Self.sig(key: "org:acme/project:altair/release",
            dimension: "decision:launch_date",
            value: Self.norm("decision:launch_date", "2026-10-01")!,
            src: "d2", validity: .unknown, ruleID: "dim.decision.launch_date")
        let out = ConflictEvaluator.evaluate(a, b, registry: .v01)
        #expect(out.kind == .irrelevant)
        #expect(out.reasons == [.scopeMismatch])
    }

    /// F07 — overlapping validity remains contradictory; disjoint
    /// validity is HistoricalSuccession, not contradiction.
    @Test func f07ValidityOverlapVsDisjoint() {
        func mk(_ src: String, _ v: TemporalBasis, _ city: String) -> ConflictSignature {
            Self.sig(key: "person:x", dimension: "city",
                value: Self.norm("city", city)!,
                src: src, validity: v, ruleID: "dim.person.city")
        }
        let overlap = ConflictEvaluator.evaluate(
            mk("d1", .interval(from: 0, to: 100), "Lisbon"),
            mk("d2", .interval(from: 50, to: 150), "Osaka"),
            registry: .v01)
        #expect(overlap.kind == .provenContradiction)
        #expect(overlap.reasons == [.sameCoordinate, .validityOverlap, .valuesExclusive])

        let disjoint = ConflictEvaluator.evaluate(
            mk("d1", .interval(from: 0, to: 40), "Lisbon"),
            mk("d2", .interval(from: 50, to: 150), "Osaka"),
            registry: .v01)
        #expect(disjoint.kind == .historicalSuccession)

        // Accepted supersession converts even overlap into succession.
        let superseded = ConflictEvaluator.evaluate(
            mk("d1", .interval(from: 0, to: 100), "Lisbon"),
            mk("d2", .interval(from: 50, to: 150), "Osaka"),
            registry: .v01, acceptedSupersession: true)
        #expect(superseded.kind == .historicalSuccession)
        #expect(superseded.reasons.contains(.acceptedSupersession))
    }

    /// F08 — multi-valued dimensions never contradict.
    @Test func f08MultiValuedCompatible() {
        let registry = ConflictRuleRegistry(rules: [
            ConflictRule(
                ruleID: "dim.test.tags", version: 1, dimension: "tags",
                cardinality: .set,
                normalize: { .string(ConflictNormalize.collapse($0)) }),
        ])
        let a = Self.sig(key: "project:x", dimension: "tags",
            value: .string("alpha"), src: "d1", validity: .unknown,
            ruleID: "dim.test.tags")
        let b = Self.sig(key: "project:x", dimension: "tags",
            value: .string("beta"), src: "d2", validity: .unknown,
            ruleID: "dim.test.tags")
        let out = ConflictEvaluator.evaluate(a, b, registry: registry)
        #expect(out.kind == .compatiblePlurality)
        #expect(out.reasons.contains(.cardinalityMulti))
    }

    /// F09 — unknown rule/cardinality → CandidateReview, never proof.
    @Test func f09UnknownRuleIsReviewOnly() {
        let a = Self.sig(key: "person:x", dimension: "favorite color",
            value: .string("red"), src: "d1", validity: .unknown,
            ruleID: ConflictRuleRegistry.unknownRuleID)
        let b = Self.sig(key: "person:x", dimension: "favorite color",
            value: .string("blue"), src: "d2", validity: .unknown,
            ruleID: ConflictRuleRegistry.unknownRuleID)
        let out = ConflictEvaluator.evaluate(a, b, registry: .v01)
        #expect(out.kind == .candidateReview)
        #expect(out.reasons.contains(.ruleUnknown))
    }

    /// F10 — ambiguous date is unparseable; unknown-vs-known validity
    /// is review, never proof.
    @Test func f10AmbiguityStaysUnknown() {
        #expect(ConflictNormalize.isoDate("03/04/26") == nil)
        #expect(ConflictNormalize.isoDate("2026-9-15") == nil)
        let a = Self.sig(key: "person:x", dimension: "city",
            value: Self.norm("city", "Lisbon")!,
            src: "d1", validity: .point(epochSeconds: 100),
            ruleID: "dim.person.city")
        let b = Self.sig(key: "person:x", dimension: "city",
            value: Self.norm("city", "Osaka")!,
            src: "d2", validity: .unknown, ruleID: "dim.person.city")
        let out = ConflictEvaluator.evaluate(a, b, registry: .v01)
        #expect(out.kind == .candidateReview)
        #expect(out.reasons.contains(.validityUnknown))
    }

    /// F17 — malformed inputs are InvalidInput, and withdrawn/rejected
    /// standing never evaluates.
    @Test func f17MalformedAndWithdrawnAreInvalid() {
        let (a0, b) = Self.employerPair()
        let malformed = Self.sig(key: a0.key, dimension: a0.dimension,
            value: a0.value, src: a0.sourceDrawerID,
            validity: .interval(from: 100, to: 0), ruleID: a0.ruleID)
        #expect(ConflictEvaluator.evaluate(malformed, b, registry: .v01).kind
            == .invalidInput)
        let withdrawn = Self.sig(key: a0.key, dimension: a0.dimension,
            value: a0.value, src: a0.sourceDrawerID,
            validity: .unknown, ruleID: a0.ruleID, status: .withdrawn)
        #expect(ConflictEvaluator.evaluate(withdrawn, b, registry: .v01).kind
            == .invalidInput)
        #expect(ConflictNormalize.usdDecimal("about five") == nil)
    }

    /// Decimal canonicalization: trailing-zero stripping and scale folding.
    @Test func decimalCanonicalBytes() {
        #expect(TypedConflictValue.decimal(mantissa: 1250, scale: 2).canonicalBytes
            == "d:12.5")
        #expect(TypedConflictValue.decimal(mantissa: 1_500_000, scale: 0).canonicalBytes
            == "d:1500000")
        #expect(TypedConflictValue.decimal(mantissa: -125, scale: 3).canonicalBytes
            == "d:-0.125")
    }
}
