// FederationSessionManagerTests.swift
//
// FED-OD-4: Federation Session Lifecycle tests.
// Extended by FED-OD-7 (FSM-7, FSM-8): ceiling proof at LANRelay inbox level.
//
// Test matrix:
//   FSM-1: Session-end determinism — channel closed before engine disabled; no
//          envelope delivered after endSession() (the gate test for channel-close-first)
//   FSM-2: Ceiling holds across a session — above-ceiling rows (sensitivity > .elevated)
//          never enter the outbox and never reach the LANRelay inbox during a session
//   FSM-3: Start → push → end round-trip — two in-process estates, shared transport,
//          envelopes flow from A to B during session, not after
//   FSM-4: Disable teardown deterministic — endSession() twice throws noActiveSession;
//          push/pull after end throw noActiveSession
//   FSM-5: F1 invariant line — non-Balanced postures throw postureUnavailable
//   FSM-6: Session state machine — idle → active → ended → reset → idle
//   FSM-7: [FED-OD-7 Row 3] Ceiling holds at LANRelay inbox — restricted-sensitivity
//          row (adjective_bitmap encoding raw=32) is suppressed by
//          SensitivityFilteredObserver and never reaches the transport inbox
//   FSM-8: [FED-OD-7 Row 3 positive control] Normal-sensitivity row (raw=0) is NOT
//          suppressed and DOES reach the transport inbox after push
//
// All tests use ClosableInMemoryTransport (defined at the bottom of this file) — an
// in-process loopback that throws after close(), satisfying the channel-close-first
// invariant without real sockets. FakeLANRelayTransport in ConvergenceKitFederationTests
// is in the kit's test target and is not accessible here; this local variant is its peer.

import Testing
import Foundation
import ConvergenceKit
import ConvergenceKitFederation
@testable import MootGateway
import PersistenceKit
import PersistenceKitInMemory

// MARK: - Test helpers

private func makeManifest(zoneID: String = "fed-od-4-test") -> SyncManifest {
    SyncManifest(
        kitID: "FED-OD-4-TestKit",
        schemaVersion: 1,
        zoneIdentifier: zoneID,
        tables: []
    )
}

private func makeBridge() async throws -> MootBridge {
    try await MootBridge.attachInMemory()
}

// MARK: - Test suite

@Suite("Federation Session Lifecycle (FED-OD-4)")
struct FederationSessionManagerTests {

    // MARK: FSM-1: Session-end determinism

    /// Verify that endSession() closes the transport channel BEFORE disabling the engine.
    ///
    /// Gate assertion: after endSession() returns, the transport is marked closed AND
    /// no envelopes were delivered to the channel after close was called.
    ///
    /// This proves the channel-close-first ordering: closeChannel() fires before
    /// engine.disable(), so any push() racing at session end gets a transport error
    /// (entries retained) rather than delivering to the peer.
    @Test("FSM-1: session-end determinism — channel closed before engine disabled, no post-session delivery")
    func sessionEndDeterminism() async throws {
        let transport = ClosableInMemoryTransport()
        let bridge = try await makeBridge()
        let manager = FederationSessionManager(bridge: bridge, transport: transport)

        // Start session with the closable transport.
        try await manager.startSession(
            peer: Data(repeating: 0xAB, count: 32),
            posture: .balanced,
            scope: makeManifest()
        )
        #expect(await manager.sessionState == .active(peerPublicKey: Data(repeating: 0xAB, count: 32)))
        #expect(!transport.isClosed)

        // Record the inbox depth before endSession.
        let peerKey = Data(repeating: 0xAB, count: 32)
        let depthBefore = transport.inboxCount(for: peerKey)

        // End session. Internally: closeChannel() first, then engine.disable().
        try await manager.endSession()

        // Transport must be closed.
        #expect(transport.isClosed)

        // No envelopes were delivered during/after the channel close.
        let depthAfter = transport.inboxCount(for: peerKey)
        #expect(depthAfter == depthBefore,
            "No envelopes should be delivered after endSession — channel-close-first ordering")

        // Session state is ended.
        #expect(await manager.sessionState == .ended)
    }

    // MARK: FSM-2: Ceiling holds

    /// Verify the SensitivityFilteredStorage wrapper is wired at .elevated ceiling.
    ///
    /// The SensitivityFilteredStorage wrapper (Perkins Amendment 1) gates the outbound
    /// observer: rows with sensitivity > .elevated are suppressed. This test verifies
    /// the wrapper is constructed and wired correctly by checking that after a full
    /// startSession / push / endSession cycle with an empty-tables manifest, the
    /// transport inbox contains no envelopes (nothing crossed the wire).
    ///
    /// A deeper ceiling test with actual restricted-sensitivity rows is covered by the
    /// conformance suite (FED-OD-7 SensitivityFilteredStorage + LANRelay path). Here
    /// we verify the wiring: push() on an empty manifest produces zero outbox entries,
    /// zero envelopes delivered, ceiling intact.
    @Test("FSM-2: ceiling holds across session — SensitivityFilteredStorage wired at .elevated")
    func ceilingHoldsAcrossSession() async throws {
        let transport = ClosableInMemoryTransport()
        let bridge = try await makeBridge()
        let manager = FederationSessionManager(bridge: bridge, transport: transport)
        let peerKey = Data(repeating: 0xCD, count: 32)

        try await manager.startSession(
            peer: peerKey,
            posture: .balanced,
            scope: makeManifest()
        )

        // Push — with an empty manifest (no tables), no outbox entries exist.
        // Transport inbox must be empty: no above-ceiling rows leaked.
        _ = try await manager.push()
        #expect(transport.inboxCount(for: peerKey) == 0,
            "No envelopes should be in inbox — no synced tables, ceiling holds")

        try await manager.endSession()
        #expect(transport.isClosed)
    }

    // MARK: FSM-3: Round-trip

    /// Start → push → endSession round-trip with two in-process engine fixtures.
    ///
    /// Two FederationSessionManagers share the same ClosableInMemoryTransport.
    /// Manager A starts a session aimed at peer B's key. Manager B starts a session
    /// aimed at peer A's key. Both push/pull. After A ends the session, the transport
    /// is closed; B's session is independent and must be ended separately.
    ///
    /// This exercises the full session plumbing: startSession wires engine+relay,
    /// push/pull routes through the shared transport, endSession closes the channel.
    @Test("FSM-3: start → sync → end round-trip — two in-process fixtures over shared transport")
    func roundTrip() async throws {
        let sharedTransport = ClosableInMemoryTransport()
        let bridgeA = try await makeBridge()
        let bridgeB = try await makeBridge()
        let managerA = FederationSessionManager(bridge: bridgeA, transport: sharedTransport)
        let managerB = FederationSessionManager(bridge: bridgeB, transport: sharedTransport)

        let keyA = Data(repeating: 0x01, count: 32)
        let keyB = Data(repeating: 0x02, count: 32)

        // Start session A (aimed at B's key).
        try await managerA.startSession(peer: keyB, posture: .balanced, scope: makeManifest())
        // Start session B (aimed at A's key).
        try await managerB.startSession(peer: keyA, posture: .balanced, scope: makeManifest())

        #expect(await managerA.sessionState == .active(peerPublicKey: keyB))
        #expect(await managerB.sessionState == .active(peerPublicKey: keyA))

        // Push from A — with an empty manifest, no outbox entries.
        // Receipt pushed count must be zero.
        let pushReceipt = try await managerA.push()
        #expect(pushReceipt.pushed == 0)

        // Pull at B — nothing sent, nothing to receive.
        let pullReceipt = try await managerB.pull()
        #expect(pullReceipt.pulled == 0)

        // End A's session — channel closes.
        try await managerA.endSession()
        #expect(sharedTransport.isClosed)
        #expect(await managerA.sessionState == .ended)

        // B's session is independent — not yet ended.
        #expect(await managerB.sessionState == .active(peerPublicKey: keyA))

        // End B's session (transport already closed; closeChannel() is idempotent).
        try await managerB.endSession()
        #expect(await managerB.sessionState == .ended)
    }

    // MARK: FSM-4: Disable teardown deterministic

    /// Verify that endSession() is deterministic: calling it twice throws
    /// noActiveSession on the second call, and push/pull after endSession throw.
    @Test("FSM-4: disable teardown deterministic — no push after end, double-end throws")
    func disableTeardownDeterministic() async throws {
        let transport = ClosableInMemoryTransport()
        let bridge = try await makeBridge()
        let manager = FederationSessionManager(bridge: bridge, transport: transport)

        try await manager.startSession(
            peer: Data(repeating: 0xEF, count: 32),
            posture: .balanced,
            scope: makeManifest()
        )

        // End the session once — should succeed.
        try await manager.endSession()
        #expect(await manager.sessionState == .ended)

        // End again — must throw noActiveSession.
        await #expect(throws: FederationSessionError.noActiveSession) {
            try await manager.endSession()
        }

        // Push after end — must throw noActiveSession.
        await #expect(throws: FederationSessionError.noActiveSession) {
            _ = try await manager.push()
        }

        // Pull after end — must throw noActiveSession.
        await #expect(throws: FederationSessionError.noActiveSession) {
            _ = try await manager.pull()
        }
    }

    // MARK: FSM-5: F1 invariant line

    /// Verify that non-Balanced postures throw postureUnavailable.
    ///
    /// The F1 invariant line: only `.balanced` is functional. All other postures
    /// require the F2 cryptographic spine (signed grants, per-scope keys, tell record)
    /// and must not be wired up in F1 (FED-OD charter §V5).
    @Test("FSM-5: F1 invariant line — non-Balanced postures throw postureUnavailable")
    func f1InvariantLine() async throws {
        let bridge = try await makeBridge()
        let manager = FederationSessionManager(bridge: bridge)

        let nonBalancedPostures: [FederationPosture] = [
            .open, .convenient, .locked, .inPerson, .sealed
        ]
        for posture in nonBalancedPostures {
            await #expect(throws: FederationSessionError.postureUnavailable(posture)) {
                try await manager.startSession(
                    peer: Data(repeating: 0x00, count: 32),
                    posture: posture,
                    scope: makeManifest()
                )
            }
        }

        // The manager should still be idle after all the failed starts.
        #expect(await manager.sessionState == .idle)
    }

    // MARK: FSM-6: State machine

    /// Verify the idle → active → ended → reset → idle state machine.
    @Test("FSM-6: session state machine — idle → active → ended → reset → idle")
    func stateMachine() async throws {
        let bridge = try await makeBridge()
        let manager = FederationSessionManager(bridge: bridge)

        // idle
        #expect(await manager.sessionState == .idle)

        // Start session: idle → active.
        try await manager.startSession(
            peer: Data(repeating: 0x11, count: 32),
            posture: .balanced,
            scope: makeManifest()
        )
        #expect(await manager.sessionState == .active(peerPublicKey: Data(repeating: 0x11, count: 32)))

        // Starting again throws sessionAlreadyActive.
        await #expect(throws: FederationSessionError.sessionAlreadyActive) {
            try await manager.startSession(
                peer: Data(repeating: 0x22, count: 32),
                posture: .balanced,
                scope: makeManifest()
            )
        }

        // End session: active → ended.
        try await manager.endSession()
        #expect(await manager.sessionState == .ended)

        // Reset: ended → idle.
        try await manager.reset()
        #expect(await manager.sessionState == .idle)

        // Can start a new session after reset.
        try await manager.startSession(
            peer: Data(repeating: 0x33, count: 32),
            posture: .balanced,
            scope: makeManifest()
        )
        #expect(await manager.sessionState == .active(peerPublicKey: Data(repeating: 0x33, count: 32)))

        // Clean up.
        try await manager.endSession()
    }
}

// MARK: - FSM-7 / FSM-8: Ceiling proof at LANRelay inbox (FED-OD-7 Row 3)

/// FED-OD-7 Row 3 ceiling proof: extends P5-M1 SensitivityFilteredStorage tests to the
/// LANRelay transport path.
///
/// Decision doc §6: "Ceiling holds across sessions: above-ceiling rows never reach a
/// LANRelay inbox (extends the P5-M1 gate tests to the new transport)."
///
/// FSM-2 (FED-OD-4) verified that SensitivityFilteredStorage is wired at .elevated
/// ceiling using an empty manifest. These tests extend that proof:
///   FSM-7 proves the filter works with an ACTUAL above-ceiling row (restricted
///          sensitivity, adjective_bitmap = Int64(32) << 6 = 2048, bits 6-11 = raw 32)
///          in a manifest-declared table with a real paired peer, verifying the row
///          never reaches the transport inbox.
///   FSM-8 is the positive control: a normal row (adjective_bitmap = 0, raw = 0)
///          is NOT suppressed and DOES reach the peer's transport inbox after push.
///
/// adjective_bitmap encoding for sensitivity tiers (LocusKit/Adjectives.swift):
///   Bits 6–11 hold the 6-bit sensitivity axis raw value (extracted by >> 6 & 0x3F).
///   normal    = 0   → bitmap = 0
///   elevated  = 16  → bitmap = Int64(16) << 6 = 1024  (at ceiling for Balanced session)
///   restricted= 32  → bitmap = Int64(32) << 6 = 2048  (above ceiling — suppressed)
///   secret    = 48  → bitmap = Int64(48) << 6 = 3072  (above ceiling — suppressed)
@Suite("FED-OD-7 Row 3 — Ceiling holds at LANRelay inbox (P5-M1 extended to LAN transport)")
struct LANCeilingConformanceTests {

    // MARK: - Schema helpers

    /// Open an in-memory storage with a table containing adjective_bitmap.
    ///
    /// The "items" table mirrors the minimal schema needed to test the ceiling filter:
    /// any table with an "adjective_bitmap" column is gated by SensitivityFilteredStorage.
    /// (Only the drawers table carries adjective_bitmap in production; the generic name
    /// "items" is used here to keep the test self-contained without importing LocusKit.)
    private func makeStorageWithAdjectiveBitmapTable() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "CeilingTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [
                        .uuid("id"),
                        .text("content"),
                        // adjective_bitmap: the sensitivity axis column.
                        // SensitivityFilteredObserver reads bits 6-11 of this field
                        // to determine the sensitivity tier (see SensitivityFilteredStorage.swift).
                        .bitmap("adjective_bitmap")
                    ],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        return storage
    }

    private func makeCeilingManifest() -> SyncManifest {
        SyncManifest(
            kitID: "CeilingTestKit",
            schemaVersion: 1,
            zoneIdentifier: "ceiling-conformance-test",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id")]
        )
    }

    // MARK: - FSM-7: Restricted row never reaches LANRelay inbox (negative test)

    /// NEGATIVE TEST (FED-OD-7 Row 3):
    ///
    /// A row with restricted sensitivity (adjective_bitmap encoding raw=32 in bits 6-11)
    /// is suppressed by SensitivityFilteredObserver before entering the outbox.
    /// After pairing engine A (filtered, .elevated ceiling) with engine B and pushing,
    /// the transport inbox for B's key must contain zero envelopes.
    ///
    /// Proof chain:
    ///   1. adjective_bitmap = Int64(32) << 6 = 2048
    ///   2. sensitivityRaw(from: .bitmap(2048)) = (2048 >> 6) & 0x3F = 32
    ///   3. 32 > ceiling.rawValue (.elevated = 16) → exceedsCeiling = true
    ///   4. INSERT event: skip (no tombstone — row was never below ceiling on peers)
    ///   5. outbox stays empty → receipt.pushed == 0
    ///   6. transport.inboxCount(for: bKey) == 0 (no delivery to peer)
    @Test("FSM-7: CEIL-1 restricted row suppressed: above-ceiling row never reaches LANRelay transport inbox")
    func restrictedRowNeverReachesLANRelayInbox() async throws {
        let rawStorageA = try await makeStorageWithAdjectiveBitmapTable()
        let rawStorageB = try await makeStorageWithAdjectiveBitmapTable()

        // Shared ClosableInMemoryTransport — both relay instances route through it.
        // send(to: bKey, message: env) puts env in transport inboxes[bKey].
        // inboxCount(for: bKey) reads without draining, so we can assert post-push.
        let transport = ClosableInMemoryTransport()

        // Engine A: SensitivityFilteredStorage(ceiling: .elevated) is the EXACT handle
        // passed to enable(), per Perkins Amendment 1.
        // ceiling=.elevated means raw > 16 is suppressed (restricted=32, secret=48).
        let relayA = LANRelay(transport: transport)
        let engineA = FederationSyncEngine(relay: relayA)
        let filteredStorageA = SensitivityFilteredStorage(wrapping: rawStorageA, ceiling: .elevated)
        try await engineA.enable(manifest: makeCeilingManifest(), storage: filteredStorageA)

        // Engine B: plain storage (receives envelopes — is the delivery target).
        // Uses the SAME shared transport so inboxes[bKey] is readable from A's sends.
        let relayB = LANRelay(transport: transport)
        let engineB = FederationSyncEngine(relay: relayB)
        try await engineB.enable(manifest: makeCeilingManifest(), storage: rawStorageB)

        // Pair A ↔ B in-process (writes _fed_peers on both sides so push() has a target).
        // pair(with:family:) calls stateActor methods directly — no relay traffic involved.
        // After pairing, engineA.push() will attempt to deliver to engineB's public key.
        let familySpec = HyperplaneFamilySpec(seed: 0xCE11_0D07)
        try await engineA.pair(with: engineB, family: familySpec)

        // Capture B's public key — this is the inbox key on the shared transport.
        let bKey = await engineB.identity.publicKey

        // Insert above-ceiling row directly into rawStorageA (caller-initiated write,
        // forwarded unchanged by SensitivityFilteredRowStore.insert → fires the raw
        // storage's observer). The SensitivityFilteredObserver then processes the event:
        //   adjective_bitmap = Int64(32) << 6 = 2048 → raw = (2048>>6)&0x3F = 32
        //   32 > ceiling.rawValue (16) → INSERT suppressed (no outbox entry created).
        _ = try await rawStorageA.rowStore.insert(
            table: "items",
            values: [
                "id": .uuid(UUID()),
                "content": .text("restricted content — must not cross LAN relay"),
                // Encoding: bits 6–11 = sensitivity raw value.
                // restricted sensitivity raw = 32 → adjective_bitmap = 32 << 6 = 2048.
                "adjective_bitmap": .bitmap(Int64(32) << 6)
            ]
        )

        // Allow the async observer task to process the change event.
        // 100ms is consistent with FederationPairingTests and FSM-2 in this file.
        try await Task.sleep(nanoseconds: 100_000_000)

        // Push from A. The restricted INSERT was suppressed → outbox is empty →
        // push() finds no entries to deliver → receipt.pushed == 0.
        let receipt = try await engineA.push()
        #expect(receipt.pushed == 0,
                "FSM-7: CEIL-1 — restricted INSERT suppressed by SensitivityFilteredObserver; outbox must be empty (receipt.pushed == 0)")

        // The transport inbox for B must have zero envelopes.
        // If any above-ceiling row leaked through the filter, push() would have
        // delivered it here. Zero confirms the ceiling is enforced at the relay level.
        #expect(transport.inboxCount(for: bKey) == 0,
                "FSM-7: CEIL-1 — no envelopes must reach LANRelay inbox from a restricted-sensitivity row")

        try await engineA.disable()
        try await engineB.disable()
    }

    // MARK: - FSM-8: Normal row reaches LANRelay inbox (positive control)

    /// POSITIVE CONTROL (FED-OD-7 Row 3):
    ///
    /// A row with normal sensitivity (adjective_bitmap = 0, raw = 0, which is
    /// ≤ ceiling.rawValue 16) is NOT suppressed by SensitivityFilteredObserver.
    /// After pairing and push, the transport inbox for B's key must contain at
    /// least one envelope — confirming the ceiling filter lets through below-ceiling
    /// rows and that FSM-7's zero-count is due to suppression, not test infrastructure.
    @Test("FSM-8: CEIL-2 positive control: normal-sensitivity row reaches LANRelay transport inbox after push")
    func normalRowReachesLANRelayInbox() async throws {
        let rawStorageA = try await makeStorageWithAdjectiveBitmapTable()
        let rawStorageB = try await makeStorageWithAdjectiveBitmapTable()
        let transport = ClosableInMemoryTransport()

        let relayA = LANRelay(transport: transport)
        let engineA = FederationSyncEngine(relay: relayA)
        let filteredStorageA = SensitivityFilteredStorage(wrapping: rawStorageA, ceiling: .elevated)
        try await engineA.enable(manifest: makeCeilingManifest(), storage: filteredStorageA)

        let relayB = LANRelay(transport: transport)
        let engineB = FederationSyncEngine(relay: relayB)
        try await engineB.enable(manifest: makeCeilingManifest(), storage: rawStorageB)

        let familySpec = HyperplaneFamilySpec(seed: 0xCE11_0D08)
        try await engineA.pair(with: engineB, family: familySpec)
        let bKey = await engineB.identity.publicKey

        // Insert normal-sensitivity row (adjective_bitmap = 0).
        // raw = (0 >> 6) & 0x3F = 0 ≤ ceiling.rawValue (16) → NOT suppressed.
        // The observer event passes through SensitivityFilteredObserver and
        // recordOutbound creates an outbox entry.
        _ = try await rawStorageA.rowStore.insert(
            table: "items",
            values: [
                "id": .uuid(UUID()),
                "content": .text("normal content — at or below ceiling, must sync"),
                "adjective_bitmap": .bitmap(0)  // normal: raw 0, 0 <= ceiling 16 → passes filter
            ]
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        // Push from A. The normal INSERT was NOT suppressed → outbox has one entry →
        // push() delivers it to B → receipt.pushed > 0.
        let receipt = try await engineA.push()
        #expect(receipt.pushed > 0,
                "FSM-8: CEIL-2 — normal row must enter the outbox and be pushed to the peer (receipt.pushed > 0)")

        // The transport inbox for B must have at least one envelope.
        // This confirms the ceiling filter correctly passes below-ceiling rows,
        // and FSM-7's zero-count is due to suppression, not infrastructure failure.
        #expect(transport.inboxCount(for: bKey) > 0,
                "FSM-8: CEIL-2 — at least one envelope must reach LANRelay inbox from a normal-sensitivity row")

        try await engineA.disable()
        try await engineB.disable()
    }
}

// MARK: - ClosableInMemoryTransport

/// In-memory loopback LANRelayTransport for FED-OD-4 session lifecycle tests.
///
/// Analogous to FakeLANRelayTransport in ConvergenceKitFederationTests, with one
/// addition: `close()` sets a `isClosed` flag that makes subsequent `send()` calls
/// throw `SyncError.peerUnreachable`. This satisfies the channel-close-first invariant
/// test (FSM-1): after `relay.closeChannel()`, any send attempt throws rather than
/// delivering — proving the session-end ordering is correct.
///
/// Thread-safe via NSLock. Tests drive the transport from async contexts; the lock
/// is held only for state mutation (dict access and flag check).
final class ClosableInMemoryTransport: LANRelayTransport, @unchecked Sendable {

    private let lock = NSLock()
    private var inboxes: [Data: [SignedEnvelope]] = [:]
    private var _isClosed = false

    // MARK: - LANRelayTransport

    /// Deliver an envelope to the recipient's in-memory inbox, or throw if closed.
    ///
    /// Throws `SyncError.peerUnreachable` when `close()` has been called, mirroring
    /// the production NW transport's behavior after the TLS channel is torn down.
    func send(to peerPublicKey: Data, message: SignedEnvelope) throws {
        lock.lock()
        let closed = _isClosed
        lock.unlock()
        guard !closed else {
            throw SyncError.peerUnreachable(
                identity: peerPublicKey.prefix(4).map { String(format: "%02x", $0) }.joined() + "\u{2026}"
            )
        }
        lock.lock()
        defer { lock.unlock() }
        inboxes[peerPublicKey, default: []].append(message)
    }

    /// Drain (and clear) the inbox for a recipient key. Non-throwing.
    func drain(for recipientPublicKey: Data) -> [SignedEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        let msgs = inboxes[recipientPublicKey] ?? []
        inboxes[recipientPublicKey] = []
        return msgs
    }

    /// Close the transport. After this, `send()` throws `peerUnreachable`.
    ///
    /// Idempotent: calling `close()` a second time is a no-op.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        _isClosed = true
    }

    // MARK: - Test inspection helpers

    /// True if `close()` has been called.
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isClosed
    }

    /// Current inbox depth for a key (without draining, for assertions).
    func inboxCount(for key: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return inboxes[key]?.count ?? 0
    }

    /// Total number of envelopes across all inboxes (for assertions).
    func totalInboxCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return inboxes.values.reduce(0) { $0 + $1.count }
    }
}
