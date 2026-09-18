// EstateStorageBackendTests.swift
//
// `GeniusLocusKit.storageBackend(for:)` reports the PersistenceKit backend an
// open estate runs on, labelled the way the status surfaces print it. The
// resident's `/api/admin/estates` reads this instead of the process
// environment.
//
// Coverage:
//   1. inMemoryEstateReportsInMemory — and a closed handle reports nil
//   2. sqliteEstateReportsSQLite
//   3. postureRefusesAPostgreSQLRecord — no file, no key, a named error

import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import Testing
@testable import GeniusLocusKit

@Suite("EstateStorageBackend")
struct EstateStorageBackendTests {

    @Test func inMemoryEstateReportsInMemory() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "backend-test")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        #expect(await kit.storageBackend(for: handle) == .inMemory)
        #expect(EstateStorageBackend.inMemory.rawValue == "InMemory")
        try await kit.close(handle)
        #expect(await kit.storageBackend(for: handle) == nil)
    }

    @Test func sqliteEstateReportsSQLite() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("estate-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "backend-test")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: dir.appendingPathComponent("estate.sqlite")),
            encryptionConfig: .plaintext))
        _ = try await Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        #expect(await kit.storageBackend(for: handle) == .sqlite)
        #expect(EstateStorageBackend.sqlite.rawValue == "SQLite")
        #expect(EstateStorageBackend.postgresql.rawValue == "PostgreSQL")
        try await kit.close(handle)
    }

    @Test func postureRefusesAPostgreSQLRecord() throws {
        let record = EstateRecord(name: "pg", directory: URL(fileURLWithPath: "/tmp/never-created/pg", isDirectory: true),
                                  backend: .postgresql(connectionString: "postgresql://h/d"))
        var thrown: EstateOpenPosture.Error?
        do { _ = try EstateOpenPosture.resolve(for: record) } catch let e as EstateOpenPosture.Error { thrown = e }
        guard case .backendHasNoDatabaseFile(let name, let backend)? = thrown else {
            Issue.record("expected backendHasNoDatabaseFile, got \(String(describing: thrown))"); return
        }
        #expect(name == "pg")
        #expect(backend == "postgresql")
        #expect(String(describing: thrown!).contains("postgresql backend"))
    }
}
