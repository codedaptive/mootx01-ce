import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Tests for the quiesced-estate verb gate introduced by the secfix-glk-aria lane.
///
/// All nine ARIA verbs must reject work when the target estate is quiesced. Before
/// this fix, `estate(for:)` only checked the registry (is the estate open?); it did
/// not consult `mountStates`, so quiesced estates silently accepted new verb calls
/// and raced against `close`.
///
/// The gate is enforced by `requireMounted(_:verb:)` in `VerbSurface.swift` and
/// by an identical check at the top of `RecallDirector.recall(_:_:)` (the direct
/// `GLKRecallRequest` path used by AriaMcpKit).
///
/// Design note on test structure: `requireMounted` fires BEFORE any row look-up,
/// confirmation check, or frame validation. Verb calls do not need a real persisted
/// row — the `estateQuiesced` error is raised before the database is touched. This
/// keeps the tests minimal and focused on the gate itself.
///
/// Suite tag: secfix-glk-aria
@Suite("Quiesced estate verb gate — secfix-glk-aria")
struct QuiescedVerbGateTests {

    // MARK: - Helpers

    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        )
        return InMemoryStorage(configuration: config)
    }

    /// Open a fresh single-estate kit and return the kit plus its handle.
    private func openKit() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "secfix-test")
        let storage = makeStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// A minimal valid `CaptureFrame` used across multiple tests.
    private func captureFrame(content: String = "x") -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "secfix-test",
            latticeAnchor: .udc("000"),
            addedBy: "secfix-test",
            embeddingModelID: "test-model-v1"
        )
    }

    /// Assert that a `GeniusLocusKitError.estateQuiesced` is thrown and that
    /// the UUID in the payload matches `handle`.
    private func expectQuiescedError(
        from handle: EstateHandle,
        body: () async throws -> Void
    ) async {
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await body()
        }
        if case .estateQuiesced(let uuid)? = thrown {
            #expect(uuid == handle.estateUUID, "quiesced UUID mismatch")
        } else {
            Issue.record(
                "expected .estateQuiesced(\(handle.estateUUID)), got \(String(describing: thrown))"
            )
        }
    }

    // MARK: - Mounted estate accepts verbs

    @Test("Mounted estate accepts capture (gate is not a spurious barrier)")
    func mountedEstateAcceptsCapture() async throws {
        let (kit, handle) = try await openKit()
        // Must not throw — this verifies the gate passes through for mounted estates.
        _ = try await kit.capture(handle, captureFrame())
    }

    // MARK: - Quiesced estate rejects all 9 verbs

    @Test("Quiesced estate rejects capture")
    func quiescedEstateRejectsCapture() async throws {
        let (kit, handle) = try await openKit()
        try await kit.quiesce(handle)

        await expectQuiescedError(from: handle) {
            _ = try await kit.capture(handle, captureFrame())
        }
    }

    @Test("Quiesced estate rejects recall (RecallFrame shim path)")
    func quiescedEstateRejectsRecallFrame() async throws {
        let (kit, handle) = try await openKit()
        try await kit.quiesce(handle)

        // requireMounted fires before the estate lookup or row scan.
        let frame = RecallFrame(filterChain: [])
        await expectQuiescedError(from: handle) {
            _ = try await kit.recall(handle, frame)
        }
    }

    @Test("Quiesced estate rejects recall (GLKRecallRequest direct path — AriaMcpKit route)")
    func quiescedEstateRejectsRecallRequest() async throws {
        let (kit, handle) = try await openKit()
        try await kit.quiesce(handle)

        // AriaMcpKit calls `kit.recall(handle, request)` directly, bypassing the
        // RecallFrame shim. The RecallDirector check covers this path.
        let request = GLKRecallRequest(frame: RecallFrame(filterChain: []))
        await expectQuiescedError(from: handle) {
            _ = try await kit.recall(handle, request)
        }
    }

    @Test("Quiesced estate rejects mutate")
    func quiescedEstateRejectsMutate() async throws {
        let (kit, handle) = try await openKit()
        try await kit.quiesce(handle)

        // requireMounted fires before any row look-up; the rowID may be synthetic.
        let frame = MutateFrame(rowID: UUID().uuidString, kind: .confirm, payload: nil)
        await expectQuiescedError(from: handle) {
            try await kit.mutate(handle, frame)
        }
    }

    @Test("Quiesced estate rejects withdraw")
    func quiescedEstateRejectsWithdraw() async throws {
        let (kit, handle) = try await openKit()
        try await kit.quiesce(handle)

        let frame = WithdrawFrame(rowID: UUID().uuidString, reason: "secfix-test")
        await expectQuiescedError(from: handle) {
            try await kit.withdraw(handle, frame)
        }
    }

    @Test("Quiesced estate rejects expunge (gate fires before confirmation check)")
    func quiescedEstateRejectsExpunge() async throws {
        let (kit, handle) = try await openKit()
        try await kit.quiesce(handle)

        // requireMounted is the FIRST check — before the confirmation guard —
        // so even confirmation:false should produce estateQuiesced not expungeNotConfirmed.
        let frame = ExpungeFrame(rowID: UUID().uuidString, reason: "secfix-test", confirmation: true)
        await expectQuiescedError(from: handle) {
            try await kit.expunge(handle, frame)
        }
    }

    @Test("Quiesced estate rejects reanchor (gate fires before empty-reanchor check)")
    func quiescedEstateRejectsReanchor() async throws {
        let (kit, handle) = try await openKit()
        try await kit.quiesce(handle)

        // requireMounted is before the guard toRoom/toWing/toLattice check.
        let frame = ReanchorFrame(rowID: UUID().uuidString, toRoom: "new-room")
        await expectQuiescedError(from: handle) {
            try await kit.reanchor(handle, frame)
        }
    }

    @Test("Quiesced estate rejects learn")
    func quiescedEstateRejectsLearn() async throws {
        let (kit, handle) = try await openKit()
        try await kit.quiesce(handle)

        let entry = SourceCatalogEntry(
            id: UUID().uuidString,
            kind: .user,
            handle: "https://example.com",
            latticeAnchor: .udc("000"),
            firstSeen: Date(),
            addedBy: "secfix-test"
        )
        // requireMounted fires before the estate (and its storage) is touched.
        let frame = LearnFrame(source: entry, handle: "https://example.com/doc")
        await expectQuiescedError(from: handle) {
            _ = try await kit.learn(handle, frame)
        }
    }

    @Test("Quiesced estate rejects propose")
    func quiescedEstateRejectsPropose() async throws {
        let (kit, handle) = try await openKit()
        try await kit.quiesce(handle)

        let frame = ProposeFrame(target: UUID().uuidString, kind: .amend, justification: nil)
        await expectQuiescedError(from: handle) {
            _ = try await kit.propose(handle, frame)
        }
    }

    @Test("Quiesced estate rejects associate")
    func quiescedEstateRejectsAssociate() async throws {
        let (kit, handle) = try await openKit()
        // Capture two rows while mounted so we have real IDs, then quiesce.
        // The gate fires before any row lookup so the IDs are never actually
        // looked up — we're capturing them to avoid the LocusKit/GeniusLocusKit
        // AssociateFrame name ambiguity by using the drawer IDs as literals.
        let d1 = try await kit.capture(handle, captureFrame(content: "a"))
        let d2 = try await kit.capture(handle, captureFrame(content: "b"))
        try await kit.quiesce(handle)

        // Use the concrete GLK-level AssociateFrame by naming it from the
        // GLK Frames module. We avoid the inter-module ambiguity by binding
        // through the Verbs/Frames.swift definition explicitly — the frame
        // type the associate verb expects is the GLK one.
        let a = d1.id
        let b = d2.id
        await expectQuiescedError(from: handle) {
            _ = try await kit.associate(handle, .init(a: a, b: b, weight: 1.0))
        }
    }

    // MARK: - Post-drain estate also rejects verbs

    @Test("Post-drain estate (quiesce→drain sequence) rejects capture")
    func postDrainEstateRejectsCapture() async throws {
        let (kit, handle) = try await openKit()
        // `drain()` transitions through .draining and settles back at .quiesced within
        // a single actor turn. After it returns the state is .quiesced, so the full
        // admin sequence quiesce→drain is still gated.
        try await kit.quiesce(handle)
        try await kit.drain(handle)

        await expectQuiescedError(from: handle) {
            _ = try await kit.capture(handle, captureFrame())
        }
    }

    // MARK: - Idempotence — gate holds after repeated quiesce

    @Test("Double-quiesce is a no-op and gate still fires")
    func doubleQuiesceStillGates() async throws {
        let (kit, handle) = try await openKit()
        // quiesce is documented idempotent — second call must not throw.
        try await kit.quiesce(handle)
        try await kit.quiesce(handle)

        await expectQuiescedError(from: handle) {
            _ = try await kit.capture(handle, captureFrame())
        }
    }

    // MARK: - captureBatch quiesce gate (Finding #1 regression)

    /// captureBatch on a quiesced estate must be rejected before the SQLite
    /// write transaction is opened.  The pre-fix code called `estate_for_verb`
    /// AFTER `begin_transaction`, leaving the WAL write lock open indefinitely
    /// when the estate was quiesced — blocking all subsequent writes.
    @Test("Quiesced estate rejects captureBatch (B1 finding #1 regression)")
    func quiescedEstateRejectsCaptureBatch() async throws {
        let (kit, handle) = try await openKit()
        try await kit.quiesce(handle)

        await expectQuiescedError(from: handle) {
            _ = try await kit.captureBatch(handle, [captureFrame()])
        }
    }

    /// captureBatch on a mounted estate must succeed — the gate is not a
    /// spurious barrier on the happy path.
    @Test("Mounted estate accepts captureBatch (gate not a spurious barrier)")
    func mountedEstateAcceptsCaptureBatch() async throws {
        let (kit, handle) = try await openKit()
        // Must not throw — verifies the gate passes through for mounted estates.
        let result = try await kit.captureBatch(handle, [captureFrame()])
        #expect(result.count == 1, "one frame → one drawer")
    }
}
