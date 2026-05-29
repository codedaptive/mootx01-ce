import Foundation
import SubstrateTypes
import SQLite3
import Testing
@testable import LocusKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

/// Provenance bitmap coverage — schema shape, axis encoding,
/// default zero, mutation + atomic audit, Confidence ordering, and
/// idempotent ALTER migration. Each test stands up a fresh
/// temp-directory database so the suite can run in parallel without
/// cross-contamination.
@Suite("ProvenanceTests")
struct ProvenanceTests {

    // MARK: - Test fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-provenance-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func sampleDrawer(
        id: String = "d1",
        provenance: Int64 = 0
    ) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "content-\(id)",
            wing: "wing-a",
            room: "room-a",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6",
            provenance: provenance
        )
    }

    /// SQLITE_TRANSIENT analogue used by the migration test to bind
    /// raw bytes into a hand-rolled SQLite handle. DrawerStore has
    /// its own private constant; tests reach SQLite directly to seed
    /// the legacy schema before opening a `DrawerStore`.
    private static let SQLITE_TRANSIENT_TEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func columnNames(at url: URL, table: String) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = handle else {
            if let h = handle { sqlite3_close_v2(h) }
            return []
        }
        defer { sqlite3_close_v2(opened) }
        var stmt: OpaquePointer?
        let pragma = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(opened, pragma, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 1) {
                names.append(String(cString: cString))
            }
        }
        return names
    }

    private func indexExists(at url: URL, name: String) throws -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = handle else {
            if let h = handle { sqlite3_close_v2(h) }
            return false
        }
        defer { sqlite3_close_v2(opened) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='index' AND name=?"
        guard sqlite3_prepare_v2(opened, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, Self.SQLITE_TRANSIENT_TEST)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func auditRowCount(at url: URL) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = handle else {
            if let h = handle { sqlite3_close_v2(h) }
            return -1
        }
        defer { sqlite3_close_v2(opened) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(opened, "SELECT COUNT(*) FROM provenance_audit", -1, &stmt, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - 4b. Bit layout round-trip test

    @Test("bit-layout round-trip preserves source_type, confirmation, channel (cookbook §2.5)")
    func bitLayoutRoundTrip() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        // Cookbook §2.5 v0.6 layout:
        //   source_type=.observed       (raw 1, bits 0–5)
        //   channel=.mcpAgent           (raw 2, bits 6–11)
        //   confirmation=.userConfirmed (raw 1, bits 18–23)
        // expected = 1 | (2 << 6) | (1 << 18) = 1 + 128 + 262144 = 262273 (0x40081)
        let expected: Int64 = (1) | (2 << 6) | (1 << 18)
        try await store.addDrawer(sampleDrawer(id: "d1", provenance: expected))

        let loaded = try await store.getDrawer(id: TestStorage.tid("d1"))
        #expect(loaded != nil)
        guard let d = loaded else { return }
        #expect(d.provenance == expected)
        #expect(d.sourceType == .observed)
        #expect(d.confirmation == .userConfirmed)
        #expect(d.channel == .mcpAgent)
        #expect(d.confidence == .null)           // bits 24–29 unset
        #expect(d.sensitivity == .normal)        // bits 30–35 unset
        #expect(d.enrichmentStatus == .none)     // bits 36–41 unset (NEW in v0.6)
        #expect(d.isUserConfirmed == true)
    }

    // MARK: - 4c. Default-zero test

    @Test("default provenance=0 maps to v0.6 zero-case defaults (cookbook §2.5)")
    func defaultZeroAxes() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        try await store.addDrawer(sampleDrawer())          // provenance defaults to 0

        let loaded = try await store.getDrawer(id: TestStorage.tid("d1"))
        #expect(loaded?.provenance == 0)
        #expect(loaded?.sourceType == .user)         // raw 0 → user (cookbook §2.5 default)
        #expect(loaded?.confirmation == .unconfirmed)
        #expect(loaded?.confidence == .null)         // raw 0 → null (was .unknown in v0.35)
        #expect(loaded?.channel == .uiTyped)         // raw 0 → uiTyped (was .unknown in v0.35)
        #expect(loaded?.sensitivity == .normal)
        #expect(loaded?.enrichmentStatus == EnrichmentStatus.none)   // NEW in v0.6
        #expect(loaded?.isUserConfirmed == false)
        // F13: `isInstruction` and `isContested` predicates dropped —
        // v0.6 vocabulary has no `.instruction` SourceType case and no
        // `.contested` Confirmation case (contested is a State, not a
        // confirmation; lives on adjective bitmap per cookbook §2.3).
    }

    // MARK: - 4d. mutateProvenance happy path

    @Test("mutateProvenance flips bits and writes audit row atomically (cookbook §2.5)")
    func mutateHappyPath() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        // Capture: source_type=.user (raw 0) / confirmation=.unconfirmed (raw 0)
        // — both zero in v0.6, so prior provenance = 0.
        let prior: Int64 = 0
        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111", provenance: prior))

        // New: source unchanged (.user/raw 0), confirmation flips to .userConfirmed
        // (raw 1 at bits 18–23 per cookbook §2.5) → newValue = 1 << 18 = 0x40000.
        let newValue: Int64 = (1 << 18)
        try await store.mutateProvenance(
            drawerId: "11111111-1111-4111-8111-111111111111",
            newProvenance: newValue,
            changedBy: "bob",
            reason: "user reviewed"
        )

        let loaded = try await store.getDrawer(id: "11111111-1111-4111-8111-111111111111")
        #expect(loaded?.provenance == newValue)
        #expect(loaded?.sourceType == .user)
        #expect(loaded?.confirmation == .userConfirmed)

        // Exactly one audit event, carrying the new provenance snapshot.
        let events = try await store.auditEventsForRow(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        #expect(events.count == 2)
        #expect(events.last?.afterBitmaps.provenance == newValue)
        #expect(events.last?.actor == "bob")
    }

    // MARK: - 4e. Atomicity test

    @Test("mutateProvenance on missing drawer rolls back drawers and audit")
    func mutateAtomicityOnMiss() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        // Add one drawer with provenance=5 so we can verify it
        // remains untouched after a failed mutation against a
        // different (nonexistent) id.
        try await store.addDrawer(sampleDrawer(id: "eeeeeeee-1111-4111-8111-111111111111", provenance: 5))

        do {
            try await store.mutateProvenance(
                drawerId: "99999999-9999-4999-8999-999999999999",
                newProvenance: 99,
                changedBy: "bob"
            )
            Issue.record("expected drawerNotFound for missing drawer")
        } catch let LocusKitError.drawerNotFound(id) {
            #expect(id == "99999999-9999-4999-8999-999999999999")
        }

        // Pre-existing drawer untouched.
        let stillThere = try await store.getDrawer(id: "eeeeeeee-1111-4111-8111-111111111111")
        #expect(stillThere?.provenance == 5)

        // The rejected mutation appended NO new event to the existing
        // drawer's trail (it only carries its genesis capture event).
        #expect(try await store.auditEventCountForRow(UUID(uuidString: "eeeeeeee-1111-4111-8111-111111111111")!) == 1)
    }

    // MARK: - 4f. Confidence Comparable test

    @Test("Confidence is Comparable in scale-gapped raw-value order (cookbook §2.5)")
    func confidenceComparable() {
        // Cookbook v0.6 scale-gapped raws: null=0, low=16, medium=32, high=48, verified=56.
        #expect(Confidence.medium < Confidence.high)
        #expect(Confidence.verified > Confidence.low)
        #expect(Confidence.null < Confidence.low)
        #expect(Confidence.high >= Confidence.medium)
        #expect(!(Confidence.low > Confidence.medium))
        // Verified is the new top, replacing v0.35 `.certain`.
        #expect(Confidence.verified > Confidence.high)
    }

}
