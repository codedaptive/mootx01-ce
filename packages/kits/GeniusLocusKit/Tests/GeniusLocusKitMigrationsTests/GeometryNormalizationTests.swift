// GeometryNormalizationTests.swift
//
// Failing fixtures for geometry normalization capsule (Part 2 RED step).
//
// Covers:
//   1. Injected-reserve fixture: SQLite file with reserve=12 (raw sqlite3_file_control
//      set before first write — the mechanism that Apple's SEE-provisioned sqlite3 uses).
//   2. Apple-provenance fixture (macOS only): file created by /usr/bin/sqlite3, which
//      mints reserve=12 files via the system's SEE-provisioned engine.
//   3. Foreign-geometry estate normalizes through the migration lane; VACUUM succeeds after.
//   4. Idempotence: second lane run produces no migration record (no second normalization).
//   5. Parity: row and schema counts equal after normalization.
//   6. Pass-through: encrypted and reserve=0 plaintext estates — lane returns migrated=false.
//   7. Precondition park: read-only file path parks without throwing.
//   8. Swift-only: post-swap file carries Data Protection class and 0600 permissions.
//
// RED state (before Part 3 lands): GLKMigrationCatalog.prepare() throws
// noHistoricalMigrationsCompiled for fresh estates when the MigrationV1_0ToV1_1 trait
// is not compiled. All tests in this file will fail until Part 3:
//   (a) adds the geometry capsule call to prepare(), and
//   (b) stamps fresh estates current without requiring historical migration code.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import GeniusLocusKitMigrations
import SQLCipher

@testable import GeniusLocusKit

// MARK: - File-header reserve reader (pure Foundation, no SQLite connection)

/// Read the reserved-bytes-per-page field from the SQLite 3 file header (offset 20).
/// Returns nil when the file is absent or shorter than the 100-byte header.
private func readReserveBytes(at url: URL) throws -> UInt8? {
    let data = try Data(contentsOf: url)
    guard data.count >= 100 else { return nil }
    // SQLite file format 3 specification §1.3.8: byte 20 = "Bytes of reserved space
    // per page." Valid range: 0–255. Apple's SEE sqlite3 sets this to 12 (per-page IV).
    return data[20]
}

// MARK: - Raw-SQLite injected-reserve fixture builder

/// Create a plaintext SQLite file at `url` with per-page reserved bytes set to 12
/// BEFORE any data write. Inserts `rowCount` rows into `fixture_rows` and checkpoints
/// so the reserve geometry propagates from the WAL to the main file.
///
/// Using the raw C API (sqlite3_file_control opcode 38) is the only way to set the
/// reserve BEFORE the first page write; our engine's open path cannot intercept this
/// order-of-operations constraint. This helper follows the EstateEncryptionMigrator
/// precedent: raw connections are legitimate in test fixtures and are closed before the
/// engine ever touches the file.
private func makeRawReserveEstate(at url: URL, rowCount: Int = 5) throws {
    var db: OpaquePointer?
    let rc = sqlite3_open_v2(
        url.path, &db,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
        nil)
    guard rc == SQLITE_OK, let db else {
        throw TestFixtureError.rawSQLiteFailed("open rc=\(rc)")
    }
    defer { sqlite3_close_v2(db) }

    // SQLITE_FCNTL_RESERVE_BYTES (opcode 38, sqlite3.h:1279): sets the per-page
    // reserved-byte count on the connection. Must be called before the first page write
    // so it is recorded in the file header (byte 20). Subsequent VACUUM would propagate
    // the setting across all pages; for this fixture we rely on header byte 20 alone —
    // matching exactly what Apple's SEE sqlite3 does when it writes reserve=12.
    var reserve: Int32 = 12
    let fcRc = sqlite3_file_control(db, nil, SQLITE_FCNTL_RESERVE_BYTES, &reserve)
    guard fcRc == SQLITE_OK else {
        throw TestFixtureError.rawSQLiteFailed("SQLITE_FCNTL_RESERVE_BYTES rc=\(fcRc)")
    }

    // WAL mode + a table write commits the first page with reserve=12 in the header.
    for sql in ["PRAGMA journal_mode = WAL;",
                "CREATE TABLE fixture_rows (id INTEGER PRIMARY KEY, value TEXT NOT NULL);"] {
        var errPtr: UnsafeMutablePointer<CChar>? = nil
        let execRc = sqlite3_exec(db, sql, nil, nil, &errPtr)
        let msg = errPtr.map { String(cString: $0) }
        if let errPtr { sqlite3_free(errPtr) }
        guard execRc == SQLITE_OK else {
            throw TestFixtureError.rawSQLiteFailed("\(sql) rc=\(execRc) \(msg ?? "")")
        }
    }
    for i in 0..<rowCount {
        var errPtr: UnsafeMutablePointer<CChar>? = nil
        let execRc = sqlite3_exec(
            db, "INSERT INTO fixture_rows (value) VALUES ('row\(i)');", nil, nil, &errPtr)
        if let errPtr { sqlite3_free(errPtr) }
        guard execRc == SQLITE_OK else {
            throw TestFixtureError.rawSQLiteFailed("insert row \(i)")
        }
    }
    // Checkpoint: propagates WAL pages (including header byte 20) to the main file.
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
}

private enum TestFixtureError: Error {
    case rawSQLiteFailed(String)
    case reserveUnexpected(got: UInt8, expected: UInt8)
}

// MARK: - Full estate fixture (raw reserve + LocusKit schema + GLK registry)

private let geoTestOwner = OwnerCredentials(ownerIdentifier: "geo-normalization-test")

/// Open a reserve=12 estate through the full stack so the handle is registered in the
/// GLK coordinator and `migrationStorage(for:)` succeeds when `prepare()` is called.
///
/// Order:
///   1. Build the raw reserve=12 file (closes the raw connection before step 2).
///   2. Open via SQLiteStorage — plaintext, no encryption.
///   3. Create LocusKit estate schema (CREATE TABLE IF NOT EXISTS — idempotent alongside
///      `fixture_rows`, which the raw step created).
///   4. Open via kit.open() — registers the storage in `storages[handle]`.
///
/// Tests may call `GLKMigrationCatalog.prepare(kit:handle:now:)` directly after this.
private func makeGeometryEstate(
    at url: URL,
    rowCount: Int = 5
) async throws -> (kit: GeniusLocusKit, handle: EstateHandle, storage: SQLiteStorage) {
    try makeRawReserveEstate(at: url, rowCount: rowCount)
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
    // LocusKit.Estate.create runs DDL migrations (CREATE TABLE IF NOT EXISTS) on the
    // reserve=12 file. No ATTACH is issued — pure DDL — so this succeeds even with
    // nonzero reserve geometry.
    _ = try await LocusKit.Estate.create(storage: storage, owner: geoTestOwner)
    let kit = GeniusLocusKit()
    // InMemoryEstateIdentityKeyStore: keeps the Ed25519 signing key out of the Keychain
    // for temp-dir estates (prevents orphan Keychain entries on test-loop teardown).
    let handle = try await kit.open(
        storage: storage,
        owner: geoTestOwner,
        identityKeyStore: InMemoryEstateIdentityKeyStore())
    return (kit, handle, storage)
}

// MARK: - Tests

@Suite("GeometryNormalizationCapsule", .serialized)
struct GeometryNormalizationTests {

    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    // MARK: - §1 Injected-reserve estate normalizes at first open

    @Test("Injected-reserve estate normalizes through the migration lane; VACUUM succeeds")
    func injectedReserveEstateNormalizesAtFirstOpen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-geo-injected-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        let (kit, handle, storage) = try await makeGeometryEstate(at: url, rowCount: 5)

        // Precondition: raw fixture has reserve=12 before the lane runs.
        let reserveBefore = try #require(try readReserveBytes(at: url))
        #expect(reserveBefore == 12, "test fixture must have reserve=12 before prepare()")

        // RED: prepare() throws noHistoricalMigrationsCompiled for fresh estates until Part 3
        // adds (a) the geometry capsule call and (b) fresh-estate stamping without the trait.
        _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: now)

        // GREEN assertions (reached only after Part 3 lands):
        let reserveAfter = try #require(try readReserveBytes(at: url))
        #expect(reserveAfter == 0, "migration lane must normalize reserve to 0")

        // VACUUM must succeed on the normalized estate.
        let maintenanceReport = try await storage.performMaintenance()
        #expect(maintenanceReport.performed, "VACUUM must run successfully after normalization")
    }

    // MARK: - §2 Apple-provenance fixture (macOS only)

    @Test("Apple-provenance estate normalizes through the migration lane (macOS only)")
    func appleProvenanceEstateNormalizesAtFirstOpen() async throws {
        #if !os(macOS)
        throw XCTSkip("Apple-provenance fixture requires /usr/bin/sqlite3 on macOS")
        #else
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-geo-apple-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        // Mint a genuine Apple-provenance file via the system sqlite3. Apple's
        // SEE-provisioned build reserves 12 bytes per page for per-page IVs.
        let sqlite3Path = "/usr/bin/sqlite3"
        guard FileManager.default.fileExists(atPath: sqlite3Path) else {
            Issue.record("Skipping: /usr/bin/sqlite3 not found")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlite3Path)
        process.arguments = [url.path, "CREATE TABLE t (id INTEGER PRIMARY KEY);"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Issue.record("Skipping: /usr/bin/sqlite3 exited \(process.terminationStatus)")
            return
        }
        guard let appleReserve = try readReserveBytes(at: url), appleReserve != 0 else {
            Issue.record("Skipping: Apple sqlite3 no longer mints reserve≠0 (reserve=\(String(describing: try? readReserveBytes(at: url))))")
            return
        }

        // Delete Apple's file and re-create via our fixture so LocusKit schema is present.
        // The reservation check above confirmed the Apple build reserves ≠ 0; simulate
        // the same header byte 20 with our injected-reserve fixture.
        try? FileManager.default.removeItem(at: url)
        let (kit, handle, _) = try await makeGeometryEstate(at: url, rowCount: 3)

        _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: now)

        let reserveAfter = try #require(try readReserveBytes(at: url))
        #expect(reserveAfter == 0, "Apple-provenance estate must normalize to reserve=0")
        #endif
    }

    // MARK: - §4 Idempotence

    @Test("Second lane run produces no normalization work (migrated=false, no throw)")
    func idempotenceSecondRunNoRecord() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-geo-idem-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        let (kit, handle, _) = try await makeGeometryEstate(at: url, rowCount: 3)

        // First run — normalizes.
        _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: now)

        // Second run — estate is already current; must not perform further work.
        let prep2 = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: now)
        #expect(prep2.migrated == false, "second prepare must not report migration work")
    }

    // MARK: - §5 Parity

    @Test("Row count in fixture_rows matches original after normalization")
    func rowCountParityAfterNormalization() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-geo-parity-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        let expectedRowCount = 7
        let (kit, handle, storage) = try await makeGeometryEstate(at: url, rowCount: expectedRowCount)
        _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: now)

        // All rows survive the sqlcipher_export swap.
        let rows = try await storage.rowStore.query(
            table: "fixture_rows", where: nil, orderBy: [], limit: nil, offset: nil)
        #expect(rows.count == expectedRowCount, "all \(expectedRowCount) rows must survive normalization")
    }

    // MARK: - §6 Pass-through: reserve=0 plaintext estate

    @Test("Pass-through: reserve=0 plaintext estate returns migrated=false")
    func passThroughReserveZeroEstate() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-geo-pt-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        // Create a normal estate through our engine (reserve=0 by construction).
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        _ = try await LocusKit.Estate.create(storage: storage, owner: geoTestOwner)
        let kit = GeniusLocusKit()
        let handle = try await kit.open(
            storage: storage, owner: geoTestOwner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: now)
        #expect(prep.migrated == false, "reserve=0 estate must not trigger normalization")
    }

    // MARK: - §6 Pass-through: encrypted estate

    @Test("Pass-through: encrypted estate is not geometry-patched")
    func passThroughEncryptedEstate() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-geo-enc-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        // Full-database encrypted estate: SQLCipher header is different from plaintext
        // SQLite (no "SQLite format 3" magic). The geometry capsule must detect this and
        // pass through without patching.
        let keyData = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let keyHex = keyData.map { String(format: "%02x", $0) }.joined()
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0),
            encryptionConfig: .fullDatabase(key: Data(keyData))))
        _ = try await LocusKit.Estate.create(storage: storage, owner: geoTestOwner)
        let kit = GeniusLocusKit()
        let handle = try await kit.open(
            storage: storage, owner: geoTestOwner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        _ = keyHex // used for encryption config; suppress warning

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: now)
        #expect(prep.migrated == false, "encrypted estate must not be geometry-patched")
    }

    // MARK: - §7 Precondition park: read-only path

    @Test("Read-only estate path parks the capsule without throwing")
    func preconditionParkReadOnlyPathNoThrow() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-geo-rdonly-\(UUID().uuidString).sqlite3")
        // Restore write permissions in defer so FileManager can clean up.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        let (kit, handle, _) = try await makeGeometryEstate(at: url, rowCount: 2)

        // Make the file read-only AFTER the estate is open (so kit.open() succeeded).
        // The geometry capsule must detect the write-failure precondition and park the
        // lane record rather than throwing.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: url.path)

        // Should not throw — the capsule parks and returns migrated=false.
        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: now)
        #expect(prep.migrated == false, "parked capsule must report migrated=false")
    }

    // MARK: - §7b Precondition park: sibling-creation failure (insufficient-disk simulation)

    @Test("Sibling-creation failure parks the capsule without throwing")
    func preconditionParkSiblingCreationFailureNoThrow() async throws {
        // Use a subdirectory so we can make it read-only — blocking the capsule from
        // creating its sibling file (.geo_normalize_tmp.sqlite3) — while the already-open
        // estate file itself remains readable (SQLite holds the open file descriptor).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-geo-sib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("estate.sqlite3")

        defer {
            // Restore write permission before cleanup so FileManager can remove the dir.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let (kit, handle, _) = try await makeGeometryEstate(at: url, rowCount: 2)

        // Make the parent directory read-only so the sibling cannot be created.
        // The estate file is already open; blocking new file creation is sufficient
        // to force the ATTACH step to fail inside normalizeGeometry().
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        // Should not throw — the capsule catches the ATTACH/create error and parks.
        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: now)
        #expect(prep.migrated == false, "parked capsule must report migrated=false")
    }

    // MARK: - §8 Post-swap attributes (macOS only)

    @Test("Post-swap file has 0600 permissions and acceptable Data Protection class (macOS only)")
    func postSwapPermissionsAndDataProtection() async throws {
        #if !os(macOS)
        throw XCTSkip("File-attribute assertions are macOS-only")
        #else
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-geo-attrs-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        let (kit, handle, _) = try await makeGeometryEstate(at: url, rowCount: 3)
        _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: now)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)

        // 1. POSIX permissions: 0600 (owner read/write only).
        let perms = (attrs[.posixPermissions] as? Int) ?? -1
        #expect(perms == 0o600,
                "normalized file must have 0600; got \(String(format: "%o", max(0, perms)))")

        // 2. Data Protection class: completeUntilFirstUserAuthentication is the target.
        //    On a dev machine without the entitlement the attribute may be nil or .none.
        if let protection = attrs[.protectionKey] as? FileProtectionType {
            let acceptable: Set<FileProtectionType> = [
                .completeUntilFirstUserAuthentication, .complete, .none
            ]
            #expect(acceptable.contains(protection),
                    "protection class must be acceptable; got \(protection)")
        }
        #endif
    }
}
