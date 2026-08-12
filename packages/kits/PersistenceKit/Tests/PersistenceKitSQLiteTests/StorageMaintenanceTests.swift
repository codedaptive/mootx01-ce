// StorageMaintenanceTests.swift
//
// StorageMaintenance contract coverage (GLK shared-content 1.1, P5):
// WAL checkpoint + VACUUM release freed pages to the FILESYSTEM, with
// quiescence, disk-capacity, progress, cancellation, and post-operation
// introspection contracts, plus the explicit in-memory no-op behaviour.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import SQLCipher
@testable import PersistenceKitSQLite

@Suite("StorageMaintenance", .serialized)
struct StorageMaintenanceTests {

    private func makeStorage() throws -> (SQLiteStorage, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("estate.sqlite")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)))
        return (storage, dbURL)
    }

    private var schema: SchemaDeclaration {
        SchemaDeclaration(
            kitID: "MaintenanceTestKit",
            version: 1,
            tables: [TableDeclaration(
                name: "bulk",
                columns: [.text("row_id"), .text("payload")],
                primaryKey: ["row_id"])])
    }

    /// Fill the bulk table with ~2 MB of rows, then delete every row —
    /// the deleted pages land on the freelist, NOT back on the filesystem.
    private func churn(_ storage: SQLiteStorage) async throws {
        let blob = String(repeating: "x", count: 4096)
        for index in 0..<500 {
            _ = try await storage.rowStore.insert(
                table: "bulk",
                values: ["row_id": .text("row-\(index)"), "payload": .text(blob)])
        }
        _ = try await storage.rowStore.delete(table: "bulk", where: .isTrue)
    }

    // MARK: - Reclamation

    @Test func vacuumReleasesFreedPagesToTheFilesystem() async throws {
        let (storage, url) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await storage.open(schema: schema)
        try await churn(storage)

        // Deleted pages are reclaimable but NOT yet released.
        let estimate = try await storage.estimatedReclaimableBytes()
        #expect(estimate > 0)

        let report = try await storage.performMaintenance()
        #expect(report.backend == "sqlite")
        #expect(report.performed)
        #expect(report.note == nil)
        #expect(report.freelistPagesBefore > 0)
        #expect(report.freelistPagesAfter == 0)
        #expect(report.pageCountAfter < report.pageCountBefore)
        #expect(report.walBytesAfter == 0)
        #expect(report.reclaimedBytes > 0)
        #expect(report.fileSizeBytesAfter + report.walBytesAfter
            < report.fileSizeBytesBefore + report.walBytesBefore)
        #expect(report.durationSeconds >= 0)

        // The report's after-size is the REAL file size on disk.
        let onDisk = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64
        #expect(onDisk == report.fileSizeBytesAfter)

        // Post-maintenance the estimate collapses to ~0 (no freelist, no WAL).
        #expect(try await storage.estimatedReclaimableBytes() == 0)

        // Data written before maintenance is untouched (VACUUM is lossless):
        // the table is still queryable and empty exactly as churn left it.
        #expect(try await storage.rowStore.count(table: "bulk", where: nil) == 0)
        await storage.close()
    }

    // MARK: - Progress

    @Test func progressReportsAllPhasesInOrder() async throws {
        let (storage, url) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await storage.open(schema: schema)
        try await churn(storage)

        final class PhaseLog: @unchecked Sendable {
            private let lock = NSLock()
            private var phases: [StorageMaintenancePhase] = []
            func append(_ phase: StorageMaintenancePhase) {
                lock.lock(); phases.append(phase); lock.unlock()
            }
            var snapshot: [StorageMaintenancePhase] {
                lock.lock(); defer { lock.unlock() }; return phases
            }
        }
        let log = PhaseLog()
        _ = try await storage.performMaintenance(
            progress: { log.append($0.phase) },
            shouldCancel: nil)
        #expect(log.snapshot == [.preflight, .walCheckpoint, .vacuum, .introspection])
        await storage.close()
    }

    // MARK: - Cancellation

    @Test func cancellationIsHonouredAtThePhaseBoundary() async throws {
        let (storage, url) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await storage.open(schema: schema)
        try await churn(storage)

        // Cancel at the third boundary — the VACUUM phase. The checkpoint
        // has run; the freelist must be UNTOUCHED (no partial reclaim).
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        }
        let counter = Counter()
        await #expect(throws: StorageMaintenanceError.cancelled(atPhase: .vacuum)) {
            _ = try await storage.performMaintenance(
                progress: nil,
                shouldCancel: { counter.next() >= 3 })
        }
        // Freelist pages still awaiting reclaim — cancellation lost nothing.
        #expect(try await storage.estimatedReclaimableBytes() > 0)
        await storage.close()
    }

    // MARK: - Quiescence

    @Test func openTransactionIsRejectedNotQuiescent() async throws {
        let (storage, url) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await storage.open(schema: schema)

        try await storage.transaction(isolation: .serializable) { _ in
            // The estate connection holds an open transaction here; the
            // maintenance pass must refuse rather than deadlock or corrupt.
            await #expect(throws: StorageMaintenanceError.notQuiescent(
                reason: "a transaction is open on the estate connection")) {
                _ = try await storage.performMaintenance()
            }
        }
        // After the transaction commits, maintenance proceeds normally.
        let report = try await storage.performMaintenance()
        #expect(report.performed)
        await storage.close()
    }

    // MARK: - Geometry normalization followed by VACUUM, one session

    /// Build a plaintext SQLite file with reserved-bytes-per-page = 12 (Apple's
    /// SEE-provisioned sqlite3 sets this for per-page IVs) BEFORE any data write.
    /// Byte 20 of the file header is only settable on an empty database, so the
    /// PRAGMA runs first and a checkpoint materializes the header.
    private func makeForeignGeometryFile(at url: URL, rows: Int) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw StorageError.backendError(underlying: "fixture: open failed")
        }
        defer { sqlite3_close(handle) }
        // SQLITE_FCNTL_RESERVE_BYTES (opcode 38, sqlite3.h:1279) is the only way to
        // set the per-page reserve, and it must run before the first page write so the
        // value lands in file-header byte 20 — there is no equivalent PRAGMA. This is
        // exactly what Apple's SEE-provisioned sqlite3 does.
        var reserve: Int32 = 12
        guard sqlite3_file_control(handle, nil, SQLITE_FCNTL_RESERVE_BYTES, &reserve) == SQLITE_OK else {
            throw StorageError.backendError(underlying: "fixture: SQLITE_FCNTL_RESERVE_BYTES failed")
        }
        for sql in [
            "PRAGMA journal_mode = WAL;",
            "CREATE TABLE bulk (row_id TEXT PRIMARY KEY, payload TEXT);",
        ] {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw StorageError.backendError(
                    underlying: "fixture: \(sql) — \(String(cString: sqlite3_errmsg(handle)))")
            }
        }
        // Enough payload that the WAL and the page cache are genuinely populated:
        // the defect under test only bites when the connection holds live WAL/SHM
        // state, which a handful of rows does not produce.
        let blob = String(repeating: "x", count: 4096)
        sqlite3_exec(handle, "BEGIN", nil, nil, nil)
        for index in 0..<rows {
            let sql = "INSERT INTO bulk VALUES ('row-\(index)', '\(blob)');"
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw StorageError.backendError(underlying: "fixture: insert \(index)")
            }
        }
        sqlite3_exec(handle, "COMMIT", nil, nil, nil)
        sqlite3_exec(handle, "DELETE FROM bulk;", nil, nil, nil)  // pages → freelist
        sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
    }

    /// Contract guard: `normalizeGeometry` must leave the connection it reopened
    /// usable for a subsequent VACUUM, in the SAME session.
    ///
    /// Normalization swaps the estate file by rename and reopens the connection on
    /// the new inode, then removes the pre-swap sidecars. Callers rely on being able
    /// to run maintenance immediately afterwards — `completeSharedContentReclaim`
    /// does exactly that — so the reopened connection must be fully live.
    ///
    /// Verified against a copy of a real 4.6 GB estate during the beta-16
    /// investigation as well as at this fixture size; both pass. This test pins the
    /// invariant so a future change to the swap/reopen/cleanup order cannot silently
    /// break the reclaim path.
    @Test func normalizeGeometryLeavesTheConnectionUsableForVacuum() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-geo-vacuum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("estate.sqlite")

        try makeForeignGeometryFile(at: dbURL, rows: 500)
        let reserveBefore = try Data(contentsOf: dbURL)[20]
        #expect(reserveBefore == 12, "fixture must carry foreign geometry")

        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)))
        try await storage.open(schema: schema)

        let geometry = try await storage.normalizeGeometry()
        #expect(geometry.normalized, "reserve=12 estate must be normalized")
        #expect(try Data(contentsOf: dbURL)[20] == 0, "reserve must be 0 after normalization")

        // The failure this test exists for: VACUUM on the same connection, in the
        // same session, immediately after normalization.
        let report = try await storage.performMaintenance()
        #expect(report.performed, "VACUUM must run on the connection normalization reopened")
        await storage.close()
    }

    // MARK: - Production-sized estate regression gate

    /// Regression gate for the VACUUM SQLITE_CANTOPEN failure on large estates.
    /// Opens a .gitignored copy of the production estate (4.3 GB) and asserts
    /// performMaintenance() does not throw.
    /// Skips gracefully when the fixture is absent (CI, other machines).
    @Test func vacuumSucceedsOnProductionSizedEstate() async throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let fixturesDir = testFileURL
            .deletingLastPathComponent()            // PersistenceKitSQLiteTests/
            .deletingLastPathComponent()            // Tests/
            .appendingPathComponent("fixtures/production-estate")
        let masterURL = fixturesDir.appendingPathComponent("master/estate.sqlite")
        let cloneURL  = fixturesDir.appendingPathComponent("clone/estate.sqlite")
        guard FileManager.default.fileExists(atPath: masterURL.path) else { return }
        try? FileManager.default.removeItem(at: cloneURL)
        try FileManager.default.createDirectory(
            at: cloneURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: masterURL, to: cloneURL)
        defer { try? FileManager.default.removeItem(at: cloneURL) }
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: cloneURL, busyTimeout: 30.0)))
        // Regression gate: must not throw.
        let report = try await storage.performMaintenance()
        #expect(report.performed)
        #expect(report.reclaimedBytes >= 0)
        await storage.close()
    }

    // MARK: - Explicit in-memory behaviour

    @Test func inMemoryBackendIsAnExplicitNoOp() async throws {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        try await storage.open(schema: schema)
        #expect(try await storage.estimatedReclaimableBytes() == 0)
        let report = try await storage.performMaintenance()
        #expect(report.backend == "inmemory")
        #expect(report.performed == false)
        #expect(report.note != nil)
        #expect(report.reclaimedBytes == 0)
        await storage.close()
    }
}
