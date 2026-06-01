import Testing
import Foundation
import AriaLexiconLib
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// One round-trip per verb against a composed estate, plus the
/// AriaLexicon §7.2 acceptance-matrix conformance.
///
/// `capture`, `recall`, `withdraw`, and `expunge` round-trip through
/// LocusKit's live verb surface. `mutate`, `reanchor`, and `learn`
/// reach LocusKit's stubs and the GLK boundary re-raises the
/// "not yet implemented" failure as
/// `VerbError.notSupportedByEstate(verb:)` so callers see a single
/// case across all stubbed-verb dispatches. `propose` and `associate`
/// are substrate-driven (Brain layer) and have no LocusKit Estate
/// method — the GLK surface raises `notSupportedByEstate` directly.
/// In every case the verb call reaches the GLK boundary, resolves the
/// handle through `estate(for:)`, and dispatches; the assertion is on
/// the observed outcome.
@Suite("Verb surface round-trips")
struct VerbSurfaceTests {

    /// In-memory storage seeded for one estate. Each call returns a
    /// fresh isolated storage so a verb test never sees another
    /// test's data.
    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        return InMemoryStorage(configuration: config)
    }

    /// Open one estate through `GeniusLocusKit` and return the kit and
    /// handle so each test can address the estate via the unified verb
    /// surface.
    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-verb-tests")
        let storage = makeStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Canonical CaptureFrame the round-trip tests file when they need
    /// a row in the estate to act against. `content` varies per call
    /// so each test's drawer is identifiable in recall results.
    private func captureFrame(content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "verb-tests",
            latticeAnchor: .udc("000.000"),
            addedBy: "verb-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    /// A recall frame that matches every newly captured row in the
    /// test estate. Uses `.unconfirmed` because the evaluator's default
    /// insertion (§7.9.5) sets a know-now state cluster when no
    /// explicit state filter is provided, so a confirmation-axis
    /// filter alone is the simplest one-row-class match. Ordering is
    /// capture-time descending so the most recently filed row appears
    /// first. Matches the pattern used by the GLK fan-out tests.
    private func recallAllActive() -> RecallFrame {
        RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
    }

    // MARK: - capture round-trip

    /// `capture` then `recall`: a row filed through the GLK verb
    /// surface is recoverable through the GLK verb surface.
    @Test
    func captureThenRecall() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "captured row"))
        let rows = try await kit.recall(handle, recallAllActive())
        #expect(rows.contains { $0.id == stored.id },
                "captured drawer should appear in recall results")
    }

    // MARK: - mutate round-trip

    /// `capture` then `mutate(.confirm)`: the call reaches LocusKit's
    /// live mutate path through the GLK boundary and transitions the
    /// row's confirmation axis to `.userConfirmed`. Verified by recalling
    /// the row under a user-confirmed frame and reading its confirmation.
    @Test
    func mutateConfirmRoundTripTransitionsConfirmation() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "mutate target"))
        try await kit.mutate(handle, MutateFrame(rowID: stored.id, kind: .confirm))

        // The row now satisfies a user-confirmed recall frame.
        let confirmedFrame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let rows = try await kit.recall(handle, confirmedFrame)
        let row = try #require(rows.first { $0.id == stored.id },
                               "confirmed row should appear in a user-confirmed recall")
        #expect(row.confirmation == .userConfirmed)
    }

    /// A state-axis mutation kind (`.reject`) is not yet wired, so the GLK
    /// boundary re-raises LocusKit's "not yet implemented" marker as
    /// `VerbError.notSupportedByEstate(verb: "mutate")`. Confirms the
    /// dispatch chain's error remap is intact for unimplemented kinds.
    @Test
    func mutateStateAxisKindSurfacesNotSupported() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "reject target"))
        let thrown = await #expect(throws: VerbError.self) {
            try await kit.mutate(handle, MutateFrame(rowID: stored.id, kind: .reject))
        }
        if case .notSupportedByEstate(let verb)? = thrown {
            #expect(verb == "mutate")
        } else {
            Issue.record("expected .notSupportedByEstate, got \(String(describing: thrown))")
        }
    }

    // MARK: - withdraw round-trip

    /// `capture` then `withdraw`: the row's state flips to
    /// `.withdrawn`; a recall scoped to active rows no longer sees it.
    @Test
    func withdrawRoundTrip() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "withdraw target"))
        try await kit.withdraw(handle, WithdrawFrame(rowID: stored.id, reason: "verb tests"))
        let activeRows = try await kit.recall(handle, recallAllActive())
        #expect(!activeRows.contains { $0.id == stored.id },
                "withdrawn drawer should not appear in active-only recall")
    }

    // MARK: - expunge round-trip

    /// Confirmation gate fires before dispatch — an expunge without
    /// `confirmation = true` raises `VerbError.expungeNotConfirmed` at
    /// the GLK boundary, the substrate is never reached.
    @Test
    func expungeWithoutConfirmationRaisesGuard() async throws {
        let (kit, handle) = try await openOneEstate()
        let thrown = await #expect(throws: VerbError.self) {
            try await kit.expunge(handle, ExpungeFrame(rowID: "any", reason: "test", confirmation: false))
        }
        if case .expungeNotConfirmed? = thrown {} else {
            Issue.record("expected .expungeNotConfirmed, got \(String(describing: thrown))")
        }
    }

    /// With confirmation, expunge runs LocusKit's live verb body: the
    /// row is tombstoned (content zeroed, `tombstonedAt` stamped), so a
    /// recall scoped to active rows no longer sees it. Mirrors the
    /// `withdraw` round-trip — expunge is the heavier sticky tombstone.
    @Test
    func expungeWithConfirmationTombstonesRow() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "expunge target"))
        try await kit.expunge(handle, ExpungeFrame(
            rowID: stored.id, reason: "verb tests", confirmation: true
        ))
        let activeRows = try await kit.recall(handle, recallAllActive())
        #expect(!activeRows.contains { $0.id == stored.id },
                "expunged drawer should not appear in active-only recall")
    }

    // MARK: - reanchor round-trip

    /// An empty reanchor (neither room nor lattice) raises
    /// `VerbError.emptyReanchor` at the GLK boundary; the substrate
    /// is never reached.
    @Test
    func reanchorEmptyRaisesGuard() async throws {
        let (kit, handle) = try await openOneEstate()
        let thrown = await #expect(throws: VerbError.self) {
            try await kit.reanchor(handle, ReanchorFrame(rowID: "any"))
        }
        if case .emptyReanchor? = thrown {} else {
            Issue.record("expected .emptyReanchor, got \(String(describing: thrown))")
        }
    }

    /// `capture` then `reanchor`: the drawer's lattice anchor moves to
    /// the supplied target. Recall sees the updated anchor on the returned
    /// row. Mirrors `testWithdrawRoundTrip` — the prior stub-surfaces-
    /// notSupported version was correct only while `Estate.reanchor` was a
    /// stub; now that the verb is implemented it is a real round-trip.
    @Test
    func reanchorRoundTrip() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "reanchor target"))
        // Reanchor the drawer to a new lattice position.
        try await kit.reanchor(handle, ReanchorFrame(
            rowID: stored.id, toLattice: .udc("003.000")
        ))
        // Recall should return the drawer with the updated anchor.
        let rows = try await kit.recall(handle, recallAllActive())
        guard let updated = rows.first(where: { $0.id == stored.id }) else {
            Issue.record("reanchored drawer should still appear in active recall")
            return
        }
        #expect(updated.udcCode == "003.000",
                "lattice anchor should reflect the reanchor target")
    }

    // MARK: - learn round-trip

    /// `learn` reaches LocusKit's learn stub and is remapped.
    @Test
    func learnRoundTripSurfacesNotSupported() async throws {
        let (kit, handle) = try await openOneEstate()
        let thrown = await #expect(throws: VerbError.self) {
            try await kit.learn(handle, LearnFrame(handle: "test-source"))
        }
        if case .notSupportedByEstate(let verb)? = thrown {
            #expect(verb == "learn")
        } else {
            Issue.record("expected .notSupportedByEstate, got \(String(describing: thrown))")
        }
    }

    // MARK: - propose round-trip

    /// `propose` is substrate-driven (Brain layer) and has no
    /// LocusKit Estate method. The GLK surface validates the handle
    /// (so a stale handle still raises `estateNotOpen`), then raises
    /// `VerbError.notSupportedByEstate` directly.
    @Test
    func proposeRaisesNotSupported() async throws {
        let (kit, handle) = try await openOneEstate()
        let thrown = await #expect(throws: VerbError.self) {
            try await kit.propose(handle, ProposeFrame(target: "row-1", kind: .amend))
        }
        if case .notSupportedByEstate(let verb)? = thrown {
            #expect(verb == "propose")
        } else {
            Issue.record("expected .notSupportedByEstate, got \(String(describing: thrown))")
        }
    }

    /// A `propose` against a stale handle raises `estateNotOpen` from
    /// the handle-resolution step, demonstrating the surface still
    /// validates the routing precondition before reporting verb
    /// support.
    @Test
    func proposeOnStaleHandleRaisesEstateNotOpen() async throws {
        let (kit, handle) = try await openOneEstate()
        try await kit.close(handle)
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.propose(handle, ProposeFrame(target: "row-1", kind: .amend))
        }
        if case .estateNotOpen? = thrown {} else {
            Issue.record("expected .estateNotOpen, got \(String(describing: thrown))")
        }
    }

    // MARK: - associate round-trip

    /// `associate` is substrate-driven (dreaming daemon) and raises
    /// `notSupportedByEstate`.
    @Test
    func associateRaisesNotSupported() async throws {
        let (kit, handle) = try await openOneEstate()
        let thrown = await #expect(throws: VerbError.self) {
            try await kit.associate(handle, AssociateFrame(a: "row-a", b: "row-b", weight: 0.5))
        }
        if case .notSupportedByEstate(let verb)? = thrown {
            #expect(verb == "associate")
        } else {
            Issue.record("expected .notSupportedByEstate, got \(String(describing: thrown))")
        }
    }

    // MARK: - AriaLexicon §7.2 acceptance-matrix conformance

    /// Every `(Verb, Noun)` pair the GLK surface routes is accepted
    /// by the AriaLexicon §7.2 matrix. If this asserts false the
    /// surface has drifted from the matrix and must be reconciled
    /// before merge.
    @Test
    func surfaceTargetsAreAcceptedByLexicon() {
        #expect(
            AriaLexiconConformance.everySurfaceTargetIsAccepted(),
            "GLK surface targets must satisfy AriaLexicon §7.2"
        )
    }

    /// The lexicon's enumeration of legal pairs is non-empty and
    /// every entry is accepted by the matrix lookup. Tautological
    /// for `legalPairs` itself; here as a guard against future
    /// refactors that change the enumeration without updating the
    /// underlying lookup.
    @Test
    func enumeratedLegalPairsAreAccepted() {
        let pairs = AriaLexiconConformance.legalPairs
        #expect(!pairs.isEmpty, "legalPairs must enumerate at least one combination")
        for (noun, verb) in pairs {
            #expect(
                Acceptance.accepts(noun, verb),
                "enumerated legal pair (\(noun), \(verb)) should be accepted"
            )
        }
    }

    /// The lexicon's enumeration of illegal pairs covers everything
    /// the matrix lookup rejects. The Vector noun's row alone
    /// guarantees a non-empty set (vectors are substrate-managed and
    /// accept no verbs), which the test asserts explicitly.
    @Test
    func enumeratedIllegalPairsAreRejected() {
        let pairs = AriaLexiconConformance.illegalPairs
        #expect(!pairs.isEmpty, "illegalPairs must enumerate at least one combination (Vector accepts none)")
        for (noun, verb) in pairs {
            #expect(
                !Acceptance.accepts(noun, verb),
                "enumerated illegal pair (\(noun), \(verb)) should be rejected"
            )
        }
        // Vector accepts no verbs — every verb against Vector is illegal.
        let vectorIllegal = pairs.filter { $0.0 == .vector }
        #expect(vectorIllegal.count == Verb.allCases.count,
                "Vector should reject all nine verbs")
    }

    /// Every GLK method name resolves to a `Verb` case through the
    /// identity-by-name mapping. A failure here means a method on
    /// the GLK surface was renamed without updating the lexicon
    /// (or vice versa) — the conformance contract requires they
    /// stay in lock-step.
    @Test
    func glkMethodNamesMapToLexiconVerbs() {
        let glkMethodNames = [
            "capture", "recall", "mutate", "withdraw", "expunge",
            "reanchor", "learn", "propose", "associate",
        ]
        for name in glkMethodNames {
            #expect(
                AriaLexiconConformance.verb(for: name) != nil,
                "GLK method '\(name)' must map to an AriaLexicon Verb"
            )
        }
        #expect(glkMethodNames.count == Verb.allCases.count,
                "GLK surface must cover all nine lexicon verbs")
    }
}
