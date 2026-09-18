// LegacyAppEstatePreparationTests.swift
//
// End-to-end coverage for the resident daemon's pre-open migration gate.
// Every path and key is isolated in a per-test temporary container; these
// tests never inspect or modify an installed MOOT estate or the Keychain.

import Foundation
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import Testing
@testable import MootCommunityDaemon

private struct MigrationScratch {
    let root: URL
    let support: URL
    let record: EstateRecord

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("u3-app-estate-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        record = EstateRecord(
            name: EstateCatalog.defaultName,
            directory: support
                .appendingPathComponent(EstateCatalog.productIdentifier, isDirectory: true)
                .appendingPathComponent(EstateCatalogNames.databasesFolder, isDirectory: true)
                .appendingPathComponent(EstateCatalog.defaultName, isDirectory: true)
        )
    }

    var legacyDirectory: URL {
        support.appendingPathComponent("mootx01", isDirectory: true)
    }

    var legacyDatabase: URL {
        legacyDirectory.appendingPathComponent("mootx01.sqlite", isDirectory: false)
    }

    var configurationDirectory: URL {
        record.directory.deletingLastPathComponent().deletingLastPathComponent()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class IsolatedEstateKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: Data]

    init(_ values: [URL: Data] = [:]) {
        self.values = values
    }

    func relocate(from: URL, to: URL) -> Bool {
        lock.withLock {
            if values[to] != nil { return false }
            guard let key = values.removeValue(forKey: from) else { return false }
            values[to] = key
            return true
        }
    }

    func value(at url: URL) -> Data? {
        lock.withLock { values[url] }
    }
}

private enum InjectedKeyFailure: Error {
    case unavailable
}

private func seedLegacyEstate(at databaseURL: URL) async throws -> (estateID: UUID, drawerID: String) {
    try FileManager.default.createDirectory(
        at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: databaseURL)
    ))
    let estate = try await Estate.create(
        storage: storage,
        owner: OwnerCredentials(ownerIdentifier: "u3-migration-seeder")
    )
    let drawer = try await estate.capture(CaptureFrame(
        content: "legacy estate sentinel",
        channel: .typed,
        room: "migration",
        latticeAnchor: .udc("004"),
        addedBy: "u3-migration-seeder",
        embeddingModelID: "u3-test-model"
    ))
    let result = (await estate.estateUUID, drawer.id)
    await storage.close()
    return result
}

private func makeHost(
    scratch: MigrationScratch,
    keyRelocator: @escaping LegacyAppEstatePreparation.KeyRelocator,
    readiness: LegacyAppEstateReadiness? = nil
) -> CommunityEstateHost {
    CommunityEstateHost(
        record: scratch.record,
        kit: GeniusLocusKit(),
        ownerIdentifier: "com.mootx01.daemon.u3-test",
        identityKeyStore: InMemoryEstateIdentityKeyStore(),
        legacyAppEstatePreparation: LegacyAppEstatePreparation(
            applicationSupportDirectory: scratch.support,
            relocateKey: keyRelocator
        ),
        legacyAppEstateReadiness: readiness
    )
}

@Test("U3-M1: daemon pre-open moves the legacy estate and key without changing identity or data")
func daemonPreOpenPreservesEstateDataIdentityAndKey() async throws {
    let scratch = try MigrationScratch()
    defer { scratch.remove() }
    let seeded = try await seedLegacyEstate(at: scratch.legacyDatabase)
    let key = Data((0..<32).map(UInt8.init))
    let keys = IsolatedEstateKeys([scratch.legacyDatabase: key])
    let host = makeHost(scratch: scratch) { from, to in
        keys.relocate(from: from, to: to)
    }

    let proof = try await host.openEstate()
    let handle = try await host.handle()
    let drawers = try await host.kit.allDrawers(in: handle)

    #expect(proof.estateIdentifier == seeded.estateID)
    #expect(drawers.contains { $0.id == seeded.drawerID && $0.content == "legacy estate sentinel" })
    #expect(keys.value(at: scratch.legacyDatabase) == nil)
    #expect(keys.value(at: scratch.record.databaseURL) == key)
    #expect(!FileManager.default.fileExists(atPath: scratch.legacyDatabase.path))
    #expect(FileManager.default.fileExists(atPath: scratch.record.databaseURL.path))
    try await host.closeEstate()
}

@Test("U3-M2: an existing canonical database refuses migration before either estate or key changes")
func canonicalConflictRefusesWithoutMutation() async throws {
    let scratch = try MigrationScratch()
    defer { scratch.remove() }
    let legacyBytes = Data("legacy sentinel".utf8)
    let canonicalBytes = Data("canonical sentinel".utf8)
    try FileManager.default.createDirectory(at: scratch.legacyDirectory, withIntermediateDirectories: true)
    try legacyBytes.write(to: scratch.legacyDatabase)
    try FileManager.default.createDirectory(at: scratch.record.directory, withIntermediateDirectories: true)
    try canonicalBytes.write(to: scratch.record.databaseURL)
    let key = Data(repeating: 0xA7, count: 32)
    let keys = IsolatedEstateKeys([scratch.legacyDatabase: key])
    let host = makeHost(scratch: scratch) { from, to in
        keys.relocate(from: from, to: to)
    }

    do {
        _ = try await host.openEstate()
        Issue.record("expected conflicting legacy and canonical estates to fail closed")
    } catch let error as LegacyAppEstatePreparation.Error {
        #expect(error == .conflictingDefaultEstates(
            legacy: scratch.legacyDatabase,
            catalog: scratch.record.databaseURL
        ))
    }

    #expect(try Data(contentsOf: scratch.legacyDatabase) == legacyBytes)
    #expect(try Data(contentsOf: scratch.record.databaseURL) == canonicalBytes)
    #expect(keys.value(at: scratch.legacyDatabase) == key)
    #expect(keys.value(at: scratch.record.databaseURL) == nil)
}

@Test("U3-M3: key relocation failure leaves the legacy set intact and creates no canonical estate")
func keyFailureCreatesNoEmptyCanonicalEstate() async throws {
    let scratch = try MigrationScratch()
    defer { scratch.remove() }
    try FileManager.default.createDirectory(at: scratch.legacyDirectory, withIntermediateDirectories: true)
    try Data("legacy database".utf8).write(to: scratch.legacyDatabase)
    let legacyWAL = URL(filePath: scratch.legacyDatabase.path + "-wal")
    try Data("legacy wal".utf8).write(to: legacyWAL)
    let host = makeHost(scratch: scratch) { _, _ in
        throw InjectedKeyFailure.unavailable
    }

    await #expect(throws: InjectedKeyFailure.self) {
        try await host.openEstate()
    }

    #expect(FileManager.default.fileExists(atPath: scratch.legacyDatabase.path))
    #expect(FileManager.default.fileExists(atPath: legacyWAL.path))
    #expect(!FileManager.default.fileExists(atPath: scratch.record.databaseURL.path))
}

@Test("U3-M4: interrupted sidecar migration resumes without replacing the sidecar already moved")
func interruptedSidecarMoveResumes() throws {
    let scratch = try MigrationScratch()
    defer { scratch.remove() }
    try FileManager.default.createDirectory(at: scratch.legacyDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: scratch.record.directory, withIntermediateDirectories: true)
    try Data("legacy database".utf8).write(to: scratch.legacyDatabase)
    try Data("legacy shm".utf8).write(to: URL(filePath: scratch.legacyDatabase.path + "-shm"))
    let alreadyMovedWAL = Data("already moved wal".utf8)
    let canonicalWAL = URL(filePath: scratch.record.databaseURL.path + "-wal")
    let canonicalSHM = URL(filePath: scratch.record.databaseURL.path + "-shm")
    try alreadyMovedWAL.write(to: canonicalWAL)
    let keys = IsolatedEstateKeys([scratch.legacyDatabase: Data(repeating: 0x5C, count: 32)])

    _ = try LegacyAppEstatePreparation(
        applicationSupportDirectory: scratch.support,
        relocateKey: { from, to in keys.relocate(from: from, to: to) }
    ).run(into: scratch.record)

    #expect(FileManager.default.fileExists(atPath: scratch.record.databaseURL.path))
    #expect(try Data(contentsOf: canonicalWAL) == alreadyMovedWAL)
    #expect(try Data(contentsOf: canonicalSHM) == Data("legacy shm".utf8))
    #expect(!FileManager.default.fileExists(atPath: scratch.legacyDatabase.path))
}

@Test("U3-M9: an already-enabled helper refuses missing canonical creation until app readiness")
func missingAppReadinessRefusesCanonicalCreation() async throws {
    let scratch = try MigrationScratch()
    defer { scratch.remove() }
    let readiness = LegacyAppEstateReadiness(
        configurationDirectory: scratch.configurationDirectory
    )
    let host = makeHost(
        scratch: scratch,
        keyRelocator: { _, _ in false },
        readiness: readiness
    )

    await #expect(throws: LegacyAppEstateReadiness.Error.self) {
        try await host.openEstate()
    }

    #expect(!readiness.isReady())
    #expect(!FileManager.default.fileExists(atPath: scratch.record.databaseURL.path))
}

@Test("U3-M10: app migration publishes readiness before the helper opens preserved data")
func appMigrationReadinessPermitsHelperOpen() async throws {
    let scratch = try MigrationScratch()
    defer { scratch.remove() }
    let seeded = try await seedLegacyEstate(at: scratch.legacyDatabase)
    let key = Data((0..<32).map { UInt8($0 ^ 0x5A) })
    let keys = IsolatedEstateKeys([scratch.legacyDatabase: key])
    let readiness = LegacyAppEstateReadiness(
        configurationDirectory: scratch.configurationDirectory
    )

    _ = try LegacyAppEstatePreparation(
        applicationSupportDirectory: scratch.support,
        relocateKey: { from, to in keys.relocate(from: from, to: to) }
    ).runAndMarkReady(into: scratch.record, readiness: readiness)

    #expect(readiness.isReady())
    #expect(keys.value(at: scratch.record.databaseURL) == key)
    let host = makeHost(
        scratch: scratch,
        keyRelocator: { from, to in keys.relocate(from: from, to: to) },
        readiness: readiness
    )
    let proof = try await host.openEstate()
    let handle = try await host.handle()
    let drawers = try await host.kit.allDrawers(in: handle)

    #expect(proof.estateIdentifier == seeded.estateID)
    #expect(drawers.contains { $0.id == seeded.drawerID && $0.content == "legacy estate sentinel" })
    try await host.closeEstate()
}

@Test("U3-M11: an existing canonical estate opens without an upgrade readiness marker")
func existingCanonicalDoesNotRequireAppReadiness() async throws {
    let scratch = try MigrationScratch()
    defer { scratch.remove() }
    let seeded = try await seedLegacyEstate(at: scratch.record.databaseURL)
    let readiness = LegacyAppEstateReadiness(
        configurationDirectory: scratch.configurationDirectory
    )
    let host = makeHost(
        scratch: scratch,
        keyRelocator: { _, _ in false },
        readiness: readiness
    )

    let proof = try await host.openEstate()
    let handle = try await host.handle()
    let drawers = try await host.kit.allDrawers(in: handle)

    #expect(!readiness.isReady())
    #expect(proof.estateIdentifier == seeded.estateID)
    #expect(drawers.contains { $0.id == seeded.drawerID })
    try await host.closeEstate()
}
