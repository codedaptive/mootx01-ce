import XCTest
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
final class VerbSurfaceTests: XCTestCase {

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
    func testCaptureThenRecall() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "captured row"))
        let rows = try await kit.recall(handle, recallAllActive())
        XCTAssertTrue(rows.contains { $0.id == stored.id },
                      "captured drawer should appear in recall results")
    }

    // MARK: - mutate round-trip

    /// `capture` then `mutate`: the call reaches LocusKit's mutate
    /// stub through the GLK boundary, and the boundary re-raises the
    /// "not yet implemented" stub as
    /// `VerbError.notSupportedByEstate(verb: "mutate")`. The test
    /// confirms the dispatch chain is wired by asserting on the
    /// remapped error case rather than the LocusKit one.
    func testMutateRoundTripSurfacesNotSupported() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "mutate target"))
        await XCTAssertThrowsErrorAsync(
            try await kit.mutate(handle, MutateFrame(rowID: stored.id, kind: .confirm))
        ) { error in
            guard case VerbError.notSupportedByEstate(let verb) = error else {
                return XCTFail("expected .notSupportedByEstate, got \(error)")
            }
            XCTAssertEqual(verb, "mutate")
        }
    }

    // MARK: - withdraw round-trip

    /// `capture` then `withdraw`: the row's state flips to
    /// `.withdrawn`; a recall scoped to active rows no longer sees it.
    func testWithdrawRoundTrip() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "withdraw target"))
        try await kit.withdraw(handle, WithdrawFrame(rowID: stored.id, reason: "verb tests"))
        let activeRows = try await kit.recall(handle, recallAllActive())
        XCTAssertFalse(activeRows.contains { $0.id == stored.id },
                       "withdrawn drawer should not appear in active-only recall")
    }

    // MARK: - expunge round-trip

    /// Confirmation gate fires before dispatch — an expunge without
    /// `confirmation = true` raises `VerbError.expungeNotConfirmed` at
    /// the GLK boundary, the substrate is never reached.
    func testExpungeWithoutConfirmationRaisesGuard() async throws {
        let (kit, handle) = try await openOneEstate()
        await XCTAssertThrowsErrorAsync(
            try await kit.expunge(handle, ExpungeFrame(rowID: "any", reason: "test", confirmation: false))
        ) { error in
            guard case VerbError.expungeNotConfirmed = error else {
                return XCTFail("expected .expungeNotConfirmed, got \(error)")
            }
        }
    }

    /// With confirmation, expunge runs LocusKit's live verb body: the
    /// row is tombstoned (content zeroed, `tombstonedAt` stamped), so a
    /// recall scoped to active rows no longer sees it. Mirrors the
    /// `withdraw` round-trip — expunge is the heavier sticky tombstone.
    func testExpungeWithConfirmationTombstonesRow() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "expunge target"))
        try await kit.expunge(handle, ExpungeFrame(
            rowID: stored.id, reason: "verb tests", confirmation: true
        ))
        let activeRows = try await kit.recall(handle, recallAllActive())
        XCTAssertFalse(activeRows.contains { $0.id == stored.id },
                       "expunged drawer should not appear in active-only recall")
    }

    // MARK: - reanchor round-trip

    /// An empty reanchor (neither room nor lattice) raises
    /// `VerbError.emptyReanchor` at the GLK boundary; the substrate
    /// is never reached.
    func testReanchorEmptyRaisesGuard() async throws {
        let (kit, handle) = try await openOneEstate()
        await XCTAssertThrowsErrorAsync(
            try await kit.reanchor(handle, ReanchorFrame(rowID: "any"))
        ) { error in
            guard case VerbError.emptyReanchor = error else {
                return XCTFail("expected .emptyReanchor, got \(error)")
            }
        }
    }

    /// With a target, the call reaches LocusKit's reanchor stub and
    /// is remapped to `VerbError.notSupportedByEstate`.
    func testReanchorRoundTripSurfacesNotSupported() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "reanchor target"))
        await XCTAssertThrowsErrorAsync(
            try await kit.reanchor(handle, ReanchorFrame(
                rowID: stored.id, toLattice: .udc("003.000")
            ))
        ) { error in
            guard case VerbError.notSupportedByEstate(let verb) = error else {
                return XCTFail("expected .notSupportedByEstate, got \(error)")
            }
            XCTAssertEqual(verb, "reanchor")
        }
    }

    // MARK: - learn round-trip

    /// `learn` reaches LocusKit's learn stub and is remapped.
    func testLearnRoundTripSurfacesNotSupported() async throws {
        let (kit, handle) = try await openOneEstate()
        await XCTAssertThrowsErrorAsync(
            try await kit.learn(handle, LearnFrame(handle: "test-source"))
        ) { error in
            guard case VerbError.notSupportedByEstate(let verb) = error else {
                return XCTFail("expected .notSupportedByEstate, got \(error)")
            }
            XCTAssertEqual(verb, "learn")
        }
    }

    // MARK: - propose round-trip

    /// `propose` is substrate-driven (Brain layer) and has no
    /// LocusKit Estate method. The GLK surface validates the handle
    /// (so a stale handle still raises `estateNotOpen`), then raises
    /// `VerbError.notSupportedByEstate` directly.
    func testProposeRaisesNotSupported() async throws {
        let (kit, handle) = try await openOneEstate()
        await XCTAssertThrowsErrorAsync(
            try await kit.propose(handle, ProposeFrame(target: "row-1", kind: .amend))
        ) { error in
            guard case VerbError.notSupportedByEstate(let verb) = error else {
                return XCTFail("expected .notSupportedByEstate, got \(error)")
            }
            XCTAssertEqual(verb, "propose")
        }
    }

    /// A `propose` against a stale handle raises `estateNotOpen` from
    /// the handle-resolution step, demonstrating the surface still
    /// validates the routing precondition before reporting verb
    /// support.
    func testProposeOnStaleHandleRaisesEstateNotOpen() async throws {
        let (kit, handle) = try await openOneEstate()
        try await kit.close(handle)
        await XCTAssertThrowsErrorAsync(
            try await kit.propose(handle, ProposeFrame(target: "row-1", kind: .amend))
        ) { error in
            guard case GeniusLocusKitError.estateNotOpen = error else {
                return XCTFail("expected .estateNotOpen, got \(error)")
            }
        }
    }

    // MARK: - associate round-trip

    /// `associate` is substrate-driven (dreaming daemon) and raises
    /// `notSupportedByEstate`.
    func testAssociateRaisesNotSupported() async throws {
        let (kit, handle) = try await openOneEstate()
        await XCTAssertThrowsErrorAsync(
            try await kit.associate(handle, AssociateFrame(a: "row-a", b: "row-b", weight: 0.5))
        ) { error in
            guard case VerbError.notSupportedByEstate(let verb) = error else {
                return XCTFail("expected .notSupportedByEstate, got \(error)")
            }
            XCTAssertEqual(verb, "associate")
        }
    }

    // MARK: - AriaLexicon §7.2 acceptance-matrix conformance

    /// Every `(Verb, Noun)` pair the GLK surface routes is accepted
    /// by the AriaLexicon §7.2 matrix. If this asserts false the
    /// surface has drifted from the matrix and must be reconciled
    /// before merge.
    func testSurfaceTargetsAreAcceptedByLexicon() {
        XCTAssertTrue(
            AriaLexiconConformance.everySurfaceTargetIsAccepted(),
            "GLK surface targets must satisfy AriaLexicon §7.2"
        )
    }

    /// The lexicon's enumeration of legal pairs is non-empty and
    /// every entry is accepted by the matrix lookup. Tautological
    /// for `legalPairs` itself; here as a guard against future
    /// refactors that change the enumeration without updating the
    /// underlying lookup.
    func testEnumeratedLegalPairsAreAccepted() {
        let pairs = AriaLexiconConformance.legalPairs
        XCTAssertFalse(pairs.isEmpty, "legalPairs must enumerate at least one combination")
        for (noun, verb) in pairs {
            XCTAssertTrue(
                Acceptance.accepts(noun, verb),
                "enumerated legal pair (\(noun), \(verb)) should be accepted"
            )
        }
    }

    /// The lexicon's enumeration of illegal pairs covers everything
    /// the matrix lookup rejects. The Vector noun's row alone
    /// guarantees a non-empty set (vectors are substrate-managed and
    /// accept no verbs), which the test asserts explicitly.
    func testEnumeratedIllegalPairsAreRejected() {
        let pairs = AriaLexiconConformance.illegalPairs
        XCTAssertFalse(pairs.isEmpty, "illegalPairs must enumerate at least one combination (Vector accepts none)")
        for (noun, verb) in pairs {
            XCTAssertFalse(
                Acceptance.accepts(noun, verb),
                "enumerated illegal pair (\(noun), \(verb)) should be rejected"
            )
        }
        // Vector accepts no verbs — every verb against Vector is illegal.
        let vectorIllegal = pairs.filter { $0.0 == .vector }
        XCTAssertEqual(vectorIllegal.count, Verb.allCases.count,
                       "Vector should reject all nine verbs")
    }

    /// Every GLK method name resolves to a `Verb` case through the
    /// identity-by-name mapping. A failure here means a method on
    /// the GLK surface was renamed without updating the lexicon
    /// (or vice versa) — the conformance contract requires they
    /// stay in lock-step.
    func testGLKMethodNamesMapToLexiconVerbs() {
        let glkMethodNames = [
            "capture", "recall", "mutate", "withdraw", "expunge",
            "reanchor", "learn", "propose", "associate",
        ]
        for name in glkMethodNames {
            XCTAssertNotNil(
                AriaLexiconConformance.verb(for: name),
                "GLK method '\(name)' must map to an AriaLexicon Verb"
            )
        }
        XCTAssertEqual(glkMethodNames.count, Verb.allCases.count,
                       "GLK surface must cover all nine lexicon verbs")
    }
}
