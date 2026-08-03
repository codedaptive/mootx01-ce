// ConflictProjectionSweepTests.swift
//
// DCP M3 — sweep orchestration, Swift leg. The pure-core cases mirror
// rust/src/brain/conflict_projection_sweep.rs one-for-one (F06, planted
// shape, F20 at sweep level, mixed tallies); the estate-level case
// drives the real read seam end-to-end: capture → captureKGFact →
// conflictProjectionSweep, then the accepted-supersession conversion.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateML
@testable import GeniusLocusKit

@Suite("Conflict projection sweep — typed proving lane", .serialized)
struct ConflictProjectionSweepTests {

    // MARK: - Pure core (mirrors the Rust module tests)

    static func fact(
        _ id: String, _ subject: String, _ object: String, _ source: String
    ) -> KGFact {
        KGFact(
            id: id, subject: subject, predicate: "Employer", object: object,
            sourceDrawerID: source,
            filedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Planted shape: same coordinate, different enum values, same event
    /// time → proven: 1 with full finding detail.
    @Test func plantedShapeIsProven() {
        let report = ConflictSweepCore.run(
            facts: [
                Self.fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
                Self.fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
            ],
            eventTimeSecondsBySourceDrawer: ["d1": 500, "d2": 500],
            // Real tiers, not arbitrary integers: only a defined tier
            // exercises the ceiling the proposal loop compares against.
            sensitivityRawBySourceDrawer: [
                "d1": AdjectiveSensitivity.normal.rawValue,
                "d2": AdjectiveSensitivity.restricted.rawValue,
            ],
            acceptedSupersessionPairs: [],
            registry: .v01)
        #expect(report.pairsEvaluated == 1)
        #expect(report.counts.provenContradiction == 1)
        #expect(report.proven.count == 1)
        let finding = try! #require(report.proven.first)
        #expect(finding.outcome.kind == .provenContradiction)
        // Ceiling is the MAX over both axes of both endpoints. These
        // facts carry no adjective bitmap, so both read Normal and the
        // more sensitive DRAWER — d2's restricted tier — is what wins.
        #expect(finding.sensitivityCeilingRaw == AdjectiveSensitivity.restricted.rawValue)
        // And that is above the ceiling the proposal loop enforces, so
        // this finding is provable but not proposable.
        #expect(finding.sensitivityCeilingRaw > AdjectiveSensitivity.elevated.rawValue)
        #expect(finding.outcome.sourceDrawerIDs == ["d1", "d2"])
    }

    /// F06 — an accepted supersedes tunnel between the source drawers
    /// converts the same pair to HistoricalSuccession.
    @Test func f06AcceptedSupersessionIsHistorical() {
        let report = ConflictSweepCore.run(
            facts: [
                Self.fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
                Self.fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
            ],
            eventTimeSecondsBySourceDrawer: ["d1": 500, "d2": 500],
            sensitivityRawBySourceDrawer: [:],
            // Insertion order must not matter — pairKey canonicalizes.
            acceptedSupersessionPairs: [GeniusLocusKit.pairKey("d2", "d1")],
            registry: .v01)
        #expect(report.counts.provenContradiction == 0)
        #expect(report.counts.historicalSuccession == 1)
        #expect(report.historical.first?.outcome.kind == .historicalSuccession)
    }

    /// F20 at sweep level — reversing fact order changes nothing about
    /// the result identities.
    @Test func f20FactOrderCannotChangeResultIDs() {
        let a = Self.fact("f1", "Sarah Chen C0", "Acme Robotics", "d1")
        let b = Self.fact("f2", "Sarah Chen C0", "Beta Corp", "d2")
        let times: [String: Int64] = ["d1": 500, "d2": 500]
        let fwd = ConflictSweepCore.run(
            facts: [a, b], eventTimeSecondsBySourceDrawer: times,
            sensitivityRawBySourceDrawer: [:], acceptedSupersessionPairs: [],
            registry: .v01)
        let rev = ConflictSweepCore.run(
            facts: [b, a], eventTimeSecondsBySourceDrawer: times,
            sensitivityRawBySourceDrawer: [:], acceptedSupersessionPairs: [],
            registry: .v01)
        #expect(fwd.proven.count == 1)
        #expect(rev.proven.count == 1)
        #expect(fwd.proven.first?.outcome.resultID == rev.proven.first?.outcome.resultID)
    }

    /// Mixed outcomes tally into the additive count lines; agreement and
    /// unknown-vs-known review are counted, not detailed.
    @Test func mixedOutcomesTally() {
        let report = ConflictSweepCore.run(
            facts: [
                // Agreement pair (same value, different drawers).
                Self.fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
                Self.fact("f2", "Sarah Chen C0", "Acme Robotics", "d2"),
                // Candidate-review pair (known vs unknown validity).
                Self.fact("f3", "Noor Haddad C1", "Beta Corp", "d3"),
                Self.fact("f4", "Noor Haddad C1", "Vireo Systems", "d4"),
            ],
            // d4 has no event time → unknown validity → review.
            eventTimeSecondsBySourceDrawer: ["d1": 500, "d2": 500, "d3": 500],
            sensitivityRawBySourceDrawer: [:],
            acceptedSupersessionPairs: [],
            registry: .v01)
        #expect(report.pairsEvaluated == 2)
        #expect(report.counts.agreement == 1)
        #expect(report.counts.candidateReview == 1)
        #expect(report.counts.provenContradiction == 0)
        #expect(report.proven.isEmpty)
    }

    /// Trap 2 — an endpoint whose sensitivity could not be resolved
    /// yields the MAXIMUM ceiling, not `.normal`. That is the value the
    /// proposal gate reads, so a hydration gap can no longer produce a
    /// proposal for a row of unknown sensitivity.
    ///
    /// Asserted at the pure core rather than end-to-end on purpose: in the
    /// estate seam a drawer that fails to hydrate also fails the proposal
    /// loop's endpoint-resolution guard, so an end-to-end test would pass
    /// for the wrong reason and could not distinguish a fail-closed
    /// ceiling from a fail-open one.
    @Test func unresolvedEndpointSensitivityFailsClosed() {
        let facts = [
            Self.fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
            Self.fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
        ]
        let times: [String: Int64] = ["d1": 500, "d2": 500]
        let secretRaw = AdjectiveSensitivity.secret.rawValue

        // Neither endpoint resolvable.
        let both = ConflictSweepCore.run(
            facts: facts, eventTimeSecondsBySourceDrawer: times,
            sensitivityRawBySourceDrawer: [:],
            acceptedSupersessionPairs: [], registry: .v01)
        #expect(both.proven.count == 1)
        #expect(both.proven.first?.sensitivityCeilingRaw == secretRaw)

        // One resolvable NORMAL endpoint must not pull the ceiling down —
        // the unresolved side still dominates the MAX.
        let one = ConflictSweepCore.run(
            facts: facts, eventTimeSecondsBySourceDrawer: times,
            sensitivityRawBySourceDrawer: ["d1": AdjectiveSensitivity.normal.rawValue],
            acceptedSupersessionPairs: [], registry: .v01)
        #expect(one.proven.first?.sensitivityCeilingRaw == secretRaw)
        #expect((one.proven.first?.sensitivityCeilingRaw ?? 0)
                > AdjectiveSensitivity.elevated.rawValue)
    }

    // MARK: - Per-fact sensitivity ceiling

    /// A fact carrying `sensitivity` on its own adjective axis.
    ///
    /// Sensitivity lives at bits 6–11 of `adjectiveBitmap` (cookbook
    /// §2.3, the same layout `Drawer` uses). LocusKit publishes the
    /// decoder (`KGFact.adjectiveSensitivity`) but no encoder, so the
    /// shift is written out here rather than hidden behind a local
    /// helper that would silently rot if the field ever moved. Every
    /// test below asserts the round-trip before relying on it.
    static func fact(
        _ id: String, _ subject: String, _ object: String, _ source: String,
        sensitivity: AdjectiveSensitivity
    ) -> KGFact {
        KGFact(
            id: id, subject: subject, predicate: "Employer", object: object,
            sourceDrawerID: source,
            adjectiveBitmap: Int64(sensitivity.rawValue) << 6,
            filedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Both source drawers at the Normal tier — the setup every test in
    /// this section shares, so the only sensitivity in play is the
    /// facts' own.
    static let normalDrawers: [String: Int] = [
        "d1": AdjectiveSensitivity.normal.rawValue,
        "d2": AdjectiveSensitivity.normal.rawValue,
    ]

    /// The regression case. A RESTRICTED fact anchored to a NORMAL
    /// drawer: before the ceiling counted each fact's own axis this
    /// finding came back at raw 0 and the renderer emitted the whole
    /// PROVEN block — result id, rule, coordinate, value digests,
    /// temporal bases, reasons and dense source rows — for a claim the
    /// legacy contradiction view in the same response had already
    /// filtered out on the fact's own tier.
    ///
    /// The renderer's thresholds are asserted here as inequalities
    /// rather than by calling it: AriaMcpKit sits above this kit and
    /// cannot be imported from GLK's tests. The two predicates mirror
    /// `RecipeTools.swift:985` (`>= secretRaw` → drop the finding) and
    /// `:987` (`>= restrictedRaw` → coordinate digest only), and their
    /// Rust twins at `recipe_tools.rs:186,190`.
    @Test func restrictedFactOnNormalDrawerRaisesCeiling() {
        let restricted = Self.fact(
            "f1", "Sarah Chen C0", "Acme Robotics", "d1",
            sensitivity: .restricted)
        // Guard the bitmap encoding this fixture depends on.
        #expect(restricted.adjectiveSensitivity == .restricted)

        let report = ConflictSweepCore.run(
            facts: [
                restricted,
                Self.fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
            ],
            eventTimeSecondsBySourceDrawer: ["d1": 500, "d2": 500],
            sensitivityRawBySourceDrawer: Self.normalDrawers,
            acceptedSupersessionPairs: [],
            registry: .v01)

        #expect(report.counts.provenContradiction == 1)
        let finding = try! #require(report.proven.first)
        // Restricted exactly — which puts it AT the renderer's digest
        // threshold (`>= restrictedRaw`, RecipeTools.swift:987) and BELOW
        // its suppression threshold (`>= secretRaw`, :985): a coordinate
        // digest is emitted in place of the PROVEN block, and the finding
        // is not dropped. The restricted tier exists so a sensitive
        // conflict can still be signalled without disclosure.
        #expect(finding.sensitivityCeilingRaw == AdjectiveSensitivity.restricted.rawValue)
        #expect(finding.sensitivityCeilingRaw < AdjectiveSensitivity.secret.rawValue)
    }

    /// A SECRET fact on a Normal drawer takes the finding past the
    /// renderer's suppression threshold entirely (`RecipeTools.swift:985`,
    /// `recipe_tools.rs:186`): no line is emitted at all, not even the
    /// coordinate digest.
    @Test func secretFactOnNormalDrawerSuppressesTheFinding() {
        let secret = Self.fact(
            "f1", "Sarah Chen C0", "Acme Robotics", "d1", sensitivity: .secret)
        #expect(secret.adjectiveSensitivity == .secret)

        let report = ConflictSweepCore.run(
            facts: [
                secret,
                Self.fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
            ],
            eventTimeSecondsBySourceDrawer: ["d1": 500, "d2": 500],
            sensitivityRawBySourceDrawer: Self.normalDrawers,
            acceptedSupersessionPairs: [],
            registry: .v01)

        #expect(report.counts.provenContradiction == 1)
        let finding = try! #require(report.proven.first)
        #expect(finding.sensitivityCeilingRaw >= AdjectiveSensitivity.secret.rawValue)
    }

    /// The finding is carried, never dropped. A sensitive fact still
    /// projects, still pairs, and still proves — only its disclosure is
    /// reduced. Filtering sensitive facts out ahead of projection (the
    /// legacy view's approach) would remove them from contradiction
    /// detection altogether and leave the renderer's restricted tier with
    /// nothing to render.
    @Test func sensitiveFactStillProvesAndIsCounted() {
        let report = ConflictSweepCore.run(
            facts: [
                Self.fact("f1", "Sarah Chen C0", "Acme Robotics", "d1",
                          sensitivity: .secret),
                Self.fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
            ],
            eventTimeSecondsBySourceDrawer: ["d1": 500, "d2": 500],
            sensitivityRawBySourceDrawer: Self.normalDrawers,
            acceptedSupersessionPairs: [],
            registry: .v01)
        #expect(report.diagnostics.projected == 2)
        #expect(report.pairsEvaluated == 1)
        #expect(report.proven.count == 1)
        #expect(report.proven.first?.outcome.reasons.contains(.valuesExclusive) == true)
    }

    /// No over-redaction. `f1` and `f2` are Normal facts that prove
    /// against each other; `f3` is a Restricted fact on an unrelated
    /// coordinate that happens to share `f1`'s source drawer. The finding
    /// must still render in full.
    ///
    /// This is the case that fails the rejected mechanism. Folding each
    /// fact's tier into the DRAWER-keyed map with `max` would leave `d1`
    /// holding Restricted — inherited from `f3` — and the unrelated
    /// `f1`/`f2` finding would collapse to a coordinate digest. Nobody
    /// would see that happen: over-redaction raises no error, it just
    /// quietly empties the surface the typed lane exists to fill.
    @Test func unrelatedNormalFactsSharingADrawerAreNotOverRedacted() {
        let poisoner = Self.fact(
            "f3", "Noor Haddad C1", "Vireo Systems", "d1",
            sensitivity: .restricted)
        #expect(poisoner.adjectiveSensitivity == .restricted)

        let report = ConflictSweepCore.run(
            facts: [
                Self.fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
                Self.fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
                // Same source drawer as f1, different coordinate — so it
                // never pairs, and its only possible influence is through
                // a shared map key.
                poisoner,
            ],
            eventTimeSecondsBySourceDrawer: ["d1": 500, "d2": 500],
            sensitivityRawBySourceDrawer: Self.normalDrawers,
            acceptedSupersessionPairs: [],
            registry: .v01)

        #expect(report.counts.provenContradiction == 1)
        let finding = try! #require(report.proven.first)
        #expect(finding.sensitivityCeilingRaw == AdjectiveSensitivity.normal.rawValue)
        // Below the digest threshold → the full PROVEN block renders.
        #expect(finding.sensitivityCeilingRaw < AdjectiveSensitivity.restricted.rawValue)
    }

    /// Sourceless facts get their own ceiling slot and cannot contaminate
    /// anything else.
    ///
    /// Facts filed with no source drawer id all share the drawer key
    /// `""`. That shared key is the second reason the drawer-keyed fold
    /// was rejected: folding fact tiers into a drawer-keyed map would
    /// store one Secret sourceless fact's tier under `""` and hand it to
    /// every other sourceless fact in the estate. Keying on the evidence
    /// locator gives each fact a slot of its own regardless of source.
    ///
    /// Two facts about the terrain are asserted together here so a later
    /// reader does not mistake the second for a bug and "fix" it:
    ///
    /// 1. A pair with an empty `sourceDrawerID` on either side is
    ///    InvalidInput at the evaluator (SubstrateML
    ///    `ConflictProjection.swift`, the `source_drawer_id.is_empty()`
    ///    guard mirrored at `conflict_projection.rs:579-580`). It never
    ///    becomes a finding, so it never reaches a ceiling — which means
    ///    the `""` collision cannot surface through a finding as the code
    ///    stands. The per-fact keying is what guarantees it still could
    ///    not if that guard were ever relaxed.
    /// 2. A sourceless Secret fact sharing a sweep with an unrelated
    ///    sourced pair leaves that pair's ceiling at Normal.
    ///
    /// The discriminating test against the rejected fold is
    /// `unrelatedNormalFactsSharingADrawerAreNotOverRedacted`; this one
    /// pins the sourceless corner of the same contract.
    @Test func sourcelessFactsGetTheirOwnCeilingSlot() {
        let report = ConflictSweepCore.run(
            facts: [
                // An ordinary sourced pair, both Normal.
                Self.fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
                Self.fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
                // A SECRET sourceless fact, and a sourced claim on the
                // same coordinate so the two actually pair.
                Self.fact("f3", "Noor Haddad C1", "Vireo Systems", "",
                          sensitivity: .secret),
                Self.fact("f4", "Noor Haddad C1", "Beta Corp", "d2"),
            ],
            eventTimeSecondsBySourceDrawer: ["": 500, "d1": 500, "d2": 500],
            sensitivityRawBySourceDrawer: Self.normalDrawers,
            acceptedSupersessionPairs: [],
            registry: .v01)

        #expect(report.pairsEvaluated == 2)
        // (1) The sourceless pair is judged InvalidInput, never a finding.
        #expect(report.counts.unknownOrInvalid == 1)
        // (2) The unrelated sourced pair keeps its Normal ceiling.
        #expect(report.counts.provenContradiction == 1)
        let finding = try! #require(report.proven.first)
        #expect(finding.sensitivityCeilingRaw == AdjectiveSensitivity.normal.rawValue)
    }

    /// The two axes are symmetric and independent. A Restricted DRAWER
    /// under a Normal fact still yields a Restricted ceiling — the
    /// behaviour that existed before this change is intact — and a
    /// Restricted FACT under a Normal drawer now yields the same ceiling.
    /// Neither axis can be satisfied by the other.
    @Test func drawerAxisAndFactAxisAreSymmetric() {
        let restrictedRaw = AdjectiveSensitivity.restricted.rawValue
        let times: [String: Int64] = ["d1": 500, "d2": 500]

        // Restricted DRAWER, Normal facts.
        let byDrawer = ConflictSweepCore.run(
            facts: [
                Self.fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
                Self.fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
            ],
            eventTimeSecondsBySourceDrawer: times,
            sensitivityRawBySourceDrawer: [
                "d1": AdjectiveSensitivity.normal.rawValue,
                "d2": restrictedRaw,
            ],
            acceptedSupersessionPairs: [],
            registry: .v01)
        #expect(byDrawer.proven.first?.sensitivityCeilingRaw == restrictedRaw)

        // Restricted FACT, Normal drawers.
        let byFact = ConflictSweepCore.run(
            facts: [
                Self.fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
                Self.fact("f2", "Sarah Chen C0", "Beta Corp", "d2",
                          sensitivity: .restricted),
            ],
            eventTimeSecondsBySourceDrawer: times,
            sensitivityRawBySourceDrawer: Self.normalDrawers,
            acceptedSupersessionPairs: [],
            registry: .v01)
        #expect(byFact.proven.first?.sensitivityCeilingRaw == restrictedRaw)
    }

    // MARK: - Estate seam (end-to-end read path)

    private func openEstate(
        owner: String
    ) async throws -> (GeniusLocusKit, EstateHandle, LocusKit.Estate) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let creds = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: creds)
        let handle = try await kit.open(
            storage: storage, owner: creds,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let estate = try await kit.estate(for: handle)
        return (kit, handle, estate)
    }

    /// The full read seam: two captured drawers (same event time), two
    /// active facts on one coordinate with exclusive values → proven: 1;
    /// then an ACTIVE supersedes tunnel between the drawers converts the
    /// pair to HistoricalSuccession on the next sweep (F06 end-to-end).
    @Test func estateSweepProvesThenSupersedes() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "conflict-sweep")
        let eventTime = Date(timeIntervalSince1970: 1_690_000_000)
        var drawers: [Drawer] = []
        for content in ["Employer claim one.", "Employer claim two."] {
            let frame = CaptureFrame(
                content: content,
                channel: .typed,
                room: "conflict-tests",
                latticeAnchor: LatticeAnchor(udcCode: "000"),
                addedBy: "conflict-sweep-tests",
                embeddingModelID: "test-model-v1",
                eventTime: eventTime)
            drawers.append(try await kit.capture(handle, frame))
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await kit.captureKGFact(
            handle, subject: "Sarah Chen C0", predicate: "Employer",
            object: "Acme Robotics", sourceDrawerID: drawers[0].id, now: now)
        _ = try await kit.captureKGFact(
            handle, subject: "Sarah Chen C0", predicate: "Employer",
            object: "Beta Corp", sourceDrawerID: drawers[1].id, now: now)

        let first = try await kit.conflictProjectionSweep(in: handle)
        #expect(first.diagnostics.scanned == 2)
        #expect(first.diagnostics.projected == 2)
        #expect(first.pairsEvaluated == 1)
        #expect(first.counts.provenContradiction == 1)
        #expect(first.proven.first?.outcome.reasons.contains(.valuesExclusive) == true)

        // Accepted supersession: file an ACTIVE supersedes tunnel between
        // the two source drawers, then re-sweep.
        let names = try await estate.resolveNodeNames(
            parentNodeIds: [drawers[0].parentNodeId, drawers[1].parentNodeId])
        let aNames = try #require(names[drawers[0].parentNodeId])
        let bNames = try #require(names[drawers[1].parentNodeId])
        _ = try await estate.capture(TunnelCaptureFrame(
            sourceWing: aNames.wing,
            sourceRoom: aNames.room,
            targetWing: bNames.wing,
            targetRoom: bNames.room,
            label: "supersession accepted in review",
            addedBy: "conflict-sweep-tests",
            sourceDrawerId: drawers[0].id,
            targetDrawerId: drawers[1].id,
            kind: .supersedes,
            originClass: .derived,
            lifecycle: .active))

        let second = try await kit.conflictProjectionSweep(in: handle)
        #expect(second.counts.provenContradiction == 0)
        #expect(second.counts.historicalSuccession == 1)
        #expect(second.historical.first?.outcome.kind == .historicalSuccession)
    }
}
