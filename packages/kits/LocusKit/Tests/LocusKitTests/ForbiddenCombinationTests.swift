import Foundation
import SQLite3
import Testing
@testable import LocusKit

/// Forbidden combination coverage — the v1 constitutional rule that
/// `sensitivity = secret` AND `exportability = exportable` is rejected
/// at every adjective-bitmap write path. Per
/// `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` I-3, § 6.6, § 9.5.
///
/// Storage can represent the combination; the verb layer must not
/// produce it. Both write paths — `addDrawer` (capture) and
/// `mutateAdjective` — must throw `LocusKitError.invalidContent`
/// (via the AuditGate basis check), leaving the database untouched
/// on violation. The standalone validator throws
/// `LocusKitError.disciplineViolation`. Adjacent legal combinations
/// (elevated+exportable, restricted+exportable, secret-alone,
/// exportable-alone) must remain unaffected.
@Suite("ForbiddenCombinationTests")
struct ForbiddenCombinationTests {

    // MARK: - Bitmap constants (derived from Adjectives.swift, cookbook §2.3)

    /// `AdjectiveSensitivity.secret.rawValue == 48`, packed into bits 6–11.
    private static let secretBits: Int64 = 0xC00      // 48 << 6
    /// `AdjectiveSensitivity.elevated.rawValue == 16`, packed into bits 6–11.
    private static let elevatedBits: Int64 = 0x400    // 16 << 6
    /// `AdjectiveSensitivity.restricted.rawValue == 32`, packed into bits 6–11.
    private static let restrictedBits: Int64 = 0x800  // 32 << 6
    /// `AdjectiveExportability.public_.rawValue == 32`, packed into bits 12–17.
    private static let exportableBits: Int64 = 0x20000 // 32 << 12
    /// The forbidden combination: secret + public.
    private static let forbidden: Int64 = secretBits | exportableBits // 0x20C00

    // MARK: - Pure validator tests

    @Test("validator throws on the secret + exportable combination")
    func validatorThrowsOnForbidden() throws {
        do {
            try ForbiddenCombinationValidator.validate(Self.forbidden)
            Issue.record("expected disciplineViolation for forbidden bitmap")
        } catch let LocusKitError.disciplineViolation(from, to, _) {
            // `from` is the AdjectiveSensitivity raw (bits 6–11); `to`
            // is the AdjectiveExportability raw (bits 12–17) per cookbook §2.3.
            #expect(from == 48)   // .secret
            #expect(to == 32)     // .public_
        }
    }

    @Test("validator allows secret without exportable")
    func validatorAllowsSecretAlone() throws {
        try ForbiddenCombinationValidator.validate(Self.secretBits) // 0xC0
    }

    @Test("validator allows exportable without secret")
    func validatorAllowsExportableAlone() throws {
        try ForbiddenCombinationValidator.validate(Self.exportableBits) // 0x800
    }

    @Test("validator allows the zero bitmap (normal + contained)")
    func validatorAllowsZero() throws {
        try ForbiddenCombinationValidator.validate(0)
    }

    @Test("validator allows elevated + exportable")
    func validatorAllowsElevatedExportable() throws {
        // 0x40 | 0x800 = 0x840 — only `secret` is forbidden with exportable.
        try ForbiddenCombinationValidator.validate(Self.elevatedBits | Self.exportableBits)
    }

    @Test("validator allows restricted + exportable")
    func validatorAllowsRestrictedExportable() throws {
        // 0x80 | 0x800 = 0x880 — only `secret` is forbidden with exportable.
        try ForbiddenCombinationValidator.validate(Self.restrictedBits | Self.exportableBits)
    }

    @Test("validator still throws when state and trust bits are set alongside the forbidden combination")
    func validatorIgnoresUnrelatedBits() throws {
        // State `.pending` (raw 1) in bits 0–5 and Trust `.canonical`
        // (raw 3) in bits 18–23 — neither axis interacts with the
        // secret/public check, which only inspects bits 6–17.
        let bitmap = Self.forbidden | 0x1 | (Int64(Trust.canonical.rawValue) << 18)
        do {
            try ForbiddenCombinationValidator.validate(bitmap)
            Issue.record("expected disciplineViolation for forbidden bitmap with adjacent bits set")
        } catch LocusKitError.disciplineViolation {
            // expected
        }
    }

    // MARK: - SQLite integration tests

    @Test("capture (addDrawer) rejects a drawer with the forbidden adjective bitmap")
    func captureRejectsForbiddenAdjective() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        let d = sampleDrawer(id: "d1", adjectiveBitmap: Self.forbidden)
        do {
            try await store.addDrawer(d)
            Issue.record("expected gate rejection for capture of forbidden bitmap")
        } catch LocusKitError.invalidContent {
            // The gate's prior==nil branch runs ForbiddenCombinations.check
            // and catches I-22 (secret + exportable) on the capture event.
        }

        // The validator runs before INSERT, so the row never reaches
        // the database — confirm zero drawers persisted.
        #expect(try drawerCount(at: url) == 0)
    }

    @Test("mutateAdjective rejects the forbidden bitmap, leaves prior state and audit table untouched")
    func mutateAdjectiveRejectsForbidden() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        // Seed a drawer with a clean adjective bitmap so the rejection
        // assertion below can verify the prior value is preserved.
        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111", adjectiveBitmap: 0))

        do {
            try await store.mutateAdjective(
                drawerId: "11111111-1111-4111-8111-111111111111",
                newAdjective: Self.forbidden,
                changedBy: "test"
            )
            Issue.record("expected gate rejection for mutateAdjective with forbidden bitmap")
        } catch LocusKitError.invalidContent {
            // expected — I-22 enforced in the gate basis check now
        }

        // The gate rejects on the merged result, so the row is unchanged
        // and the only audit event is the original genesis capture (the
        // rejected mutateAdjective appended nothing).
        let loaded = try await store.getDrawer(id: "11111111-1111-4111-8111-111111111111")
        #expect(loaded?.adjectiveBitmap == 0)
        #expect(try await store.auditEventCountForRow(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!) == 1)
    }

    @Test("mutateAdjective allows elevated + exportable")
    func mutateAdjectiveAllowsElevatedExportable() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111", adjectiveBitmap: 0))
        // elevated (sensitivity raw 16 at bits 6–11) + exportable
        // (exportability raw 32 at bits 12–17). Allowed: only secret +
        // exportable is forbidden.
        let allowed: Int64 = Self.elevatedBits | Self.exportableBits
        try await store.mutateAdjective(
            drawerId: "11111111-1111-4111-8111-111111111111",
            newAdjective: allowed,
            changedBy: "test"
        )

        let loaded = try await store.getDrawer(id: "11111111-1111-4111-8111-111111111111")
        #expect(loaded?.adjectiveBitmap == allowed)
    }

    // MARK: - Test fixture helpers

    private func makeTempURL() -> URL {
        let name = "locuskit-forbidden-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func sampleDrawer(
        id: String,
        adjectiveBitmap: Int64
    ) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "content-\(id)",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: 0
        )
    }

    private static let SQLITE_TRANSIENT_TEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `drawers` row count — used to assert that a rejected capture
    /// left the database empty.
    private func drawerCount(at url: URL) throws -> Int {
        try scalarCount(at: url, sql: "SELECT COUNT(*) FROM drawers")
    }

    /// Total `bitmap_audit` row count — used to assert that a
    /// rejected `mutateAdjective` wrote nothing to the audit trail.
    private func totalAuditRows(at url: URL) throws -> Int {
        try scalarCount(at: url, sql: "SELECT COUNT(*) FROM bitmap_audit")
    }

    private func scalarCount(at url: URL, sql: String) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = handle else {
            if let h = handle { sqlite3_close_v2(h) }
            return -1
        }
        defer { sqlite3_close_v2(opened) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(opened, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
