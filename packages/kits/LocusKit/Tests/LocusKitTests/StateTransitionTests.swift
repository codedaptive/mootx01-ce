import Foundation
import SQLite3
import Testing
@testable import LocusKit

/// State-transition coverage for the legal-transition table
/// (spec § 6.2) and the `DrawerStore.mutateState` write path
/// (spec § 6.1 cluster topology + I-2 audit atomicity).
///
/// The validator tests are pure-function — they exercise
/// `DrawerStateValidator.validate` directly with no SQLite. The
/// `mutateState` tests stand up a fresh temp database per test
/// so the suite can run in parallel without cross-contamination,
/// mirroring `BitmapAuditTests`'s fixture shape.
///
/// Note on the type name: the state enum is `State` in
/// `Adjectives.swift`. An earlier draft used the placeholder name
/// `DrawerState` for clarity, but the shipped type is `State` and
/// the validator's parameter types reflect that.
@Suite("StateTransitionTests")
struct StateTransitionTests {

    // MARK: - Fixture helpers (SQLite tests only)

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-state-transition-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    // Row identity is a UUID (DECISION_ROW_IDENTITY_UUID): fixtures use
    // real UUIDs, matching the contract any synced estate already requires.
    static let idD1 = "11111111-1111-4111-8111-111111111111"
    static let idD2 = "22222222-2222-4222-8222-222222222222"
    static let idD3 = "33333333-3333-4333-8333-333333333333"
    static let idD4 = "44444444-4444-4444-8444-444444444444"
    static let idAbsent = "99999999-9999-4999-8999-999999999999"

    /// Count audit-log events for a drawer row — the new source of truth
    /// (the gate appends AuditEvents; bitmap_audit is retired for state).
    private func auditEventCount(_ store: DrawerStore, _ id: String) async throws -> Int {
        let uuid = UUID(uuidString: id)!
        return try await store.auditEventCountForRow(uuid)
    }

    private func sampleDrawer(
        id: String = idD1,
        adjectiveBitmap: Int64 = 0
    ) -> Drawer {
        Drawer(
            id: id,
            content: "content-\(id)",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: 0
        )
    }

    /// Count `bitmap_audit` rows scoped to a single drawer + adjective
    /// column. `bitmap_audit` is retired; this helper queries the old
    /// table directly for backward-compatibility assertions only.
    private func adjectiveAuditCount(at url: URL, drawerId: String) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = handle else {
            if let h = handle { sqlite3_close_v2(h) }
            return 0
        }
        defer { sqlite3_close_v2(opened) }
        let sql = """
            SELECT COUNT(*) FROM bitmap_audit
            WHERE noun = 'drawer' AND row_id = ? AND column_name = 'adjectiveBitmap'
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(opened, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT_TEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, drawerId, -1, SQLITE_TRANSIENT_TEST)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Read the latest (changed_at DESC) bitmap_audit row's prior/new
    /// pair for the adjective column of one drawer. `bitmap_audit` is
    /// retired; this helper is retained for any test that still reads
    /// the old table. Returns nil when no row exists.
    private func latestAdjectiveAudit(
        at url: URL,
        drawerId: String
    ) throws -> (prior: Int64, new: Int64)? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = handle else {
            if let h = handle { sqlite3_close_v2(h) }
            return nil
        }
        defer { sqlite3_close_v2(opened) }
        let sql = """
            SELECT prior_value, new_value FROM bitmap_audit
            WHERE noun = 'drawer' AND row_id = ? AND column_name = 'adjectiveBitmap'
            ORDER BY changed_at DESC LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(opened, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT_TEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, drawerId, -1, SQLITE_TRANSIENT_TEST)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1))
    }

    // MARK: - Validator: legal transitions (pure function)
    //
    // One @Test per legal (from, to, via) triple from spec § 6.2.
    // Each asserts `validate` does not throw — a green here means
    // the row is in the legal-transition table.

    @Test("legal: pending → active via mutateConfirm")
    func legalPendingToActiveConfirm() throws {
        try DrawerStateValidator.validate(from: .pending, to: .active, via: .observe)
    }

    @Test("legal: pending → rejected via mutateReject")
    func legalPendingToRejectedReject() throws {
        try DrawerStateValidator.validate(from: .pending, to: .rejected, via: .reject)
    }

    @Test("legal: active → contested via mutateContest")
    func legalActiveToContestedContest() throws {
        try DrawerStateValidator.validate(from: .active, to: .contested, via: .contest)
    }

    @Test("legal: contested → active via mutateResolve")
    func legalContestedToActiveResolve() throws {
        try DrawerStateValidator.validate(from: .contested, to: .active, via: .resolveContest)
    }

    @Test("illegal (F14): contested → superseded — cookbook §9.2 only permits active → superseded")
    func illegalContestedToSupersededSupersede() {
        // F14 cascade: LocusKit's v0.35 verb table permitted this transition,
        // but cookbook §9.2 only allows active → superseded via .supersede.
        // Consuming SubstrateLib's RowStateAutomaton correctly tightens.
        #expect(throws: LocusKitError.self) {
            try DrawerStateValidator.validate(from: .contested, to: .superseded, via: .supersede)
        }
    }

    @Test("legal: active → decayed via maintenance")
    func legalActiveToDecayedMaintenance() throws {
        try DrawerStateValidator.validate(from: .active, to: .decayed, via: .decay)
    }

    @Test("legal: active → withdrawn via withdraw")
    func legalActiveToWithdrawnWithdraw() throws {
        try DrawerStateValidator.validate(from: .active, to: .withdrawn, via: .retract)
    }

    @Test("legal: active → expired via maintenance")
    func legalActiveToExpiredMaintenance() throws {
        try DrawerStateValidator.validate(from: .active, to: .expired, via: .expire)
    }

    // revive surface (cookbook §9.3): all four Cluster-B historical
    // states restore to active via .observe. The automaton legalizes
    // every one; the superseded lineage-conflict rule is enforced one
    // layer up at Estate.mutate, not in this pure transition check.

    @Test("legal: decayed → active via revive (.observe)")
    func legalDecayedToActiveRevive() throws {
        try DrawerStateValidator.validate(from: .decayed, to: .active, via: .observe)
    }

    @Test("legal: withdrawn → active via revive (.observe) — unwithdraw")
    func legalWithdrawnToActiveRevive() throws {
        try DrawerStateValidator.validate(from: .withdrawn, to: .active, via: .observe)
    }

    @Test("legal: expired → active via revive (.observe) — TTL revive")
    func legalExpiredToActiveRevive() throws {
        try DrawerStateValidator.validate(from: .expired, to: .active, via: .observe)
    }

    @Test("legal: superseded → active via revive (.observe) — lineage rule is enforced at Estate.mutate")
    func legalSupersededToActiveRevive() throws {
        // The automaton admits superseded → active; it is stateless and
        // cannot see lineage. The "living successor" contradiction is a
        // store-level domain rule checked in Estate.mutate's revive guard
        // (see EstateMutateRevive tests), not here.
        try DrawerStateValidator.validate(from: .superseded, to: .active, via: .observe)
    }

    @Test("legal: active → accepted via mutateAccept (any → accepted)")
    func legalActiveToAcceptedAccept() throws {
        try DrawerStateValidator.validate(from: .active, to: .accepted, via: .promote)
    }

    @Test("legal: active → tombstoned via expunge (any → tombstoned)")
    func legalActiveToTombstonedExpunge() throws {
        try DrawerStateValidator.validate(from: .active, to: .tombstoned, via: .tombstone)
    }

    @Test("illegal (F14): tombstoned → accepted — tombstoned is absolute terminal per cookbook §9.2")
    func illegalTombstonedToAcceptedAccept() {
        // F14 cascade: LocusKit's v0.35 permitted any → accepted via wildcard.
        // Cookbook §9.2 only permits active → accepted via .promote.
        #expect(throws: LocusKitError.self) {
            try DrawerStateValidator.validate(from: .tombstoned, to: .accepted, via: .promote)
        }
    }

    @Test("illegal (F14): tombstoned → tombstoned — tombstoned is absolute terminal")
    func illegalTombstonedToTombstonedExpunge() {
        // F14 cascade: LocusKit's v0.35 permitted re-expunging tombstoned rows
        // (a no-op idempotence). Cookbook §9.2 makes tombstoned absolute
        // terminal — no outgoing transitions at all.
        #expect(throws: LocusKitError.self) {
            try DrawerStateValidator.validate(from: .tombstoned, to: .tombstoned, via: .tombstone)
        }
    }

    // MARK: - Validator: illegal transitions throw disciplineViolation

    @Test("illegal: active → pending (no transition)")
    func illegalActiveToPending() {
        #expect(throws: LocusKitError.self) {
            try DrawerStateValidator.validate(from: .active, to: .pending, via: .observe)
        }
    }

    @Test("illegal: rejected → active (terminal, cannot revive)")
    func illegalRejectedToActive() {
        #expect(throws: LocusKitError.self) {
            try DrawerStateValidator.validate(from: .rejected, to: .active, via: .observe)
        }
    }

    @Test("illegal: accepted → active (terminal, cannot revive)")
    func illegalAcceptedToActive() {
        #expect(throws: LocusKitError.self) {
            try DrawerStateValidator.validate(from: .accepted, to: .active, via: .observe)
        }
    }

    @Test("illegal: tombstoned → active (terminal, cannot revive)")
    func illegalTombstonedToActive() {
        #expect(throws: LocusKitError.self) {
            try DrawerStateValidator.validate(from: .tombstoned, to: .active, via: .observe)
        }
    }

    @Test("illegal: active → active via mutateConfirm (wrong from-state for confirm)")
    func illegalActiveToActiveConfirm() {
        #expect(throws: LocusKitError.self) {
            try DrawerStateValidator.validate(from: .active, to: .active, via: .observe)
        }
    }

    @Test("legal (F14): pending → withdrawn via retract — cookbook §9.2 allows direct retraction")
    func legalPendingToWithdrawnRetract() throws {
        // F14 cascade: LocusKit's v0.35 table required pending → active → withdrawn.
        // Cookbook §9.2 permits direct pending → withdrawn via .retract;
        // SubstrateLib's transition map encodes this directly.
        try DrawerStateValidator.validate(from: .pending, to: .withdrawn, via: .retract)
    }

    @Test("illegal: disciplineViolation carries from/to raw values and reason")
    func illegalCarriesRawValuesAndReason() {
        do {
            try DrawerStateValidator.validate(from: .active, to: .pending, via: .observe)
            Issue.record("validate should have thrown")
        } catch let LocusKitError.disciplineViolation(from, to, reason) {
            #expect(from == State.active.rawValue)
            #expect(to == State.pending.rawValue)
            #expect(reason.contains("§9.2"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - mutateState SQLite tests

    @Test("mutateState: legal mutation persists and writes one audit row")
    func mutateStatePersistsAndAudits() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        try await store.addDrawer(sampleDrawer(id: Self.idD1, adjectiveBitmap: 0)) // .active

        try await store.mutateState(
            drawerId: Self.idD1,
            to: .withdrawn,
            via: .retract,
            changedBy: "test",
            now: t(1_700_000_500)
        )

        let fetched = try await store.getDrawer(id: Self.idD1)
        #expect(fetched?.state == .withdrawn)

        // Two events now: the genesis capture, then the withdraw.
        // The gate sealed both; afterBitmaps 6-bit state field on the
        // second is withdrawn (snapshot model, not bitmap_audit deltas).
        let count = try await auditEventCount(store, Self.idD1)
        #expect(count == 2)
        let events = try await store.auditEventsForRow(UUID(uuidString: Self.idD1)!)
        #expect((events.last?.afterBitmaps.adjective ?? -1) & 0x3F == 18) // withdrawn
    }

    @Test("mutateState: preserves upper adjectiveBitmap bits, flips only bits 0–3")
    func mutateStatePreservesUpperBits() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        // Upper bits encode trust/sensitivity/exportability — must
        // survive the state mutation untouched.
        // v0.6 gate-legal upper bits: sensitivity=elevated(16) at bits 6-11
        // and trust=observed(1) at bits 18-23 (the older (4<<4)|(8<<8)|(3<<12)
        // pattern packed illegal enum values the gate now rejects).
        let upper: Int64 = (16 << 6) | (1 << 18)
        let initial = upper | 0 // active in low bits
        try await store.addDrawer(sampleDrawer(id: Self.idD2, adjectiveBitmap: initial))

        try await store.mutateState(
            drawerId: Self.idD2,
            to: .decayed,
            via: .decay,
            changedBy: "test",
            now: t(1_700_000_600)
        )

        let fetched = try await store.getDrawer(id: Self.idD2)
        #expect(fetched?.state == .decayed)
        // Upper bits (outside the 6-bit state field, mask ~0x3F) unchanged.
        let bitmap = fetched?.adjectiveBitmap ?? -1
        #expect(bitmap & ~Int64(0x3F) == upper)
        #expect(bitmap & 0x3F == Int64(State.decayed.rawValue))
    }

    @Test("mutateState: illegal mutation throws, leaves state and audit table unchanged")
    func mutateStateIllegalThrowsAtomically() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        try await store.addDrawer(sampleDrawer(id: Self.idD3, adjectiveBitmap: 0)) // .active

        await #expect(throws: LocusKitError.self) {
            // active → pending is not in cookbook §9.2's transition map
            // (no verb produces pending from active; pending is an
            // entry-only state).
            try await store.mutateState(
                drawerId: Self.idD3,
                to: .pending,
                via: .observe,
                changedBy: "test",
                now: t(1_700_000_700)
            )
        }

        let fetched = try await store.getDrawer(id: Self.idD3)
        #expect(fetched?.state == .active)
        // Only the genesis capture event; the rejected mutation appended none.
        let count = try await auditEventCount(store, Self.idD3)
        #expect(count == 1)
    }

    @Test("mutateState: terminal lock — tombstoned cannot revive to active")
    func mutateStateTerminalLock() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        try await store.addDrawer(sampleDrawer(id: Self.idD4, adjectiveBitmap: 0)) // .active

        // Legal: active → tombstoned via expunge.
        try await store.mutateState(
            drawerId: Self.idD4,
            to: .tombstoned,
            via: .tombstone,
            changedBy: "test",
            now: t(1_700_000_800)
        )
        let mid = try await store.getDrawer(id: Self.idD4)
        #expect(mid?.state == .tombstoned)

        // Illegal: tombstoned to active via revive.
        await #expect(throws: LocusKitError.self) {
            try await store.mutateState(
                drawerId: Self.idD4,
                to: .active,
                via: .observe,
                changedBy: "test",
                now: t(1_700_000_900)
            )
        }

        let after = try await store.getDrawer(id: Self.idD4)
        #expect(after?.state == .tombstoned)
        // Two events now: the genesis capture + the legal expunge.
        // The failed revive added none.
        let count = try await auditEventCount(store, Self.idD4)
        #expect(count == 2)
    }

    @Test("mutateState: missing drawer throws drawerNotFound")
    func mutateStateMissingDrawer() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        await #expect(throws: LocusKitError.drawerNotFound(id: Self.idAbsent)) {
            try await store.mutateState(
                drawerId: Self.idAbsent,
                to: .withdrawn,
                via: .retract,
                changedBy: "test",
                now: t(1_700_001_000)
            )
        }
    }

    // MARK: - S-1 enforcement (cookbook §9.5.1)

    @Test("S-1: mutateState rejects promote→accepted when trust < canonical")
    func mutateStateS1RejectsLowTrustPromote() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        // Cookbook §2.3: state at bits 0-5 (active = raw 0), trust at
        // bits 18-23. Trust=.observed (raw 1) is BELOW canonical (raw 3),
        // so promoting to .accepted must violate S-1.
        let lowTrustAdjective: Int64 = (1 << 18)   // state=active, trust=observed
        try await store.addDrawer(
            sampleDrawer(id: Self.idD1, adjectiveBitmap: lowTrustAdjective)
        )

        await #expect(throws: LocusKitError.self) {
            try await store.mutateState(
                drawerId: Self.idD1,
                to: .accepted,
                via: .promote,
                changedBy: "test",
                now: t(1_700_000_700)
            )
        }

        // Row state unchanged after rejected mutation.
        let after = try await store.getDrawer(id: Self.idD1)
        #expect(after?.state == .active)
        #expect(after?.trust == .observed)
    }

    @Test("S-1: mutateState accepts promote→accepted when trust ≥ canonical")
    func mutateStateS1AcceptsCanonicalTrustPromote() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        // Trust=.canonical (raw 3) satisfies S-1 (accepted requires
        // trust ≥ canonical).
        let canonicalTrustAdjective: Int64 = (3 << 18)
        try await store.addDrawer(
            sampleDrawer(id: Self.idD2, adjectiveBitmap: canonicalTrustAdjective)
        )

        try await store.mutateState(
            drawerId: Self.idD2,
            to: .accepted,
            via: .promote,
            changedBy: "test",
            now: t(1_700_000_700)
        )

        let after = try await store.getDrawer(id: Self.idD2)
        #expect(after?.state == .accepted)
        #expect(after?.trust == .canonical)
    }

    // MARK: - contested → rejected (the fix, cookbook §9.2)

    @Test("legal: contested → rejected via reject")
    func legalContestedToRejectedReject() throws {
        // Cookbook §9.2: a contested memory judged false must be terminally
        // rejectable. Both Pending and Contested are legal sources for .reject.
        try DrawerStateValidator.validate(from: .contested, to: .rejected, via: .reject)
    }

    @Test("illegal: active → rejected (only pending and contested may reject)")
    func illegalActiveToRejectedReject() {
        // Active → Reject is not in the §9.2 transition table;
        // only Pending and Contested are legal reject sources.
        #expect(throws: LocusKitError.self) {
            try DrawerStateValidator.validate(from: .active, to: .rejected, via: .reject)
        }
    }

    @Test("illegal: accepted → rejected (audit-grade terminal; reject is blocked)")
    func illegalAcceptedToRejectedReject() {
        // Accepted is an audit-grade terminal. Reject from Accepted must fail;
        // the gate enforces this via the absence of the entry in §9.2's table.
        #expect(throws: LocusKitError.self) {
            try DrawerStateValidator.validate(from: .accepted, to: .rejected, via: .reject)
        }
    }

    @Test("mutateState: contested → rejected persists and writes audit event")
    func mutateStateContestedToRejectedPersistsAndAudits() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        try await store.addDrawer(sampleDrawer(id: Self.idD1, adjectiveBitmap: 0)) // .active

        // Move to contested first (active → contest → contested).
        try await store.mutateState(
            drawerId: Self.idD1,
            to: .contested,
            via: .contest,
            changedBy: "test",
            now: t(1_700_000_400)
        )
        let contested = try await store.getDrawer(id: Self.idD1)
        #expect(contested?.state == .contested)

        // Now reject from contested (contested → reject → rejected).
        try await store.mutateState(
            drawerId: Self.idD1,
            to: .rejected,
            via: .reject,
            changedBy: "test",
            now: t(1_700_000_500)
        )

        let rejected = try await store.getDrawer(id: Self.idD1)
        #expect(rejected?.state == .rejected)

        // Three audit events: genesis capture, contest, then reject.
        let count = try await auditEventCount(store, Self.idD1)
        #expect(count == 3)
        let events = try await store.auditEventsForRow(UUID(uuidString: Self.idD1)!)
        // The final event must record the rejected state in its afterBitmaps.
        #expect((events.last?.afterBitmaps.adjective ?? -1) & 0x3F
                == Int64(State.rejected.rawValue))
    }

    @Test("mutateState: accepted → reject is blocked (audit-grade terminal)")
    func mutateStateAcceptedToRejectedIsBlocked() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        // Canonical trust so the promote guard and S-1 gate both pass.
        let canonicalTrust: Int64 = (3 << 18)
        try await store.addDrawer(sampleDrawer(id: Self.idD2, adjectiveBitmap: canonicalTrust))

        try await store.mutateState(
            drawerId: Self.idD2,
            to: .accepted,
            via: .promote,
            changedBy: "test",
            now: t(1_700_000_600)
        )
        #expect((try await store.getDrawer(id: Self.idD2))?.state == .accepted)

        // Attempt to reject an accepted row must be blocked at the gate.
        await #expect(throws: LocusKitError.self) {
            try await store.mutateState(
                drawerId: Self.idD2,
                to: .rejected,
                via: .reject,
                changedBy: "test",
                now: t(1_700_000_700)
            )
        }
        // State must not have changed.
        #expect((try await store.getDrawer(id: Self.idD2))?.state == .accepted)
    }
}

