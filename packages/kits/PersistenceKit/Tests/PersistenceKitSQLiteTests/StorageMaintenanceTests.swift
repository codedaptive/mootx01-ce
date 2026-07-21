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
