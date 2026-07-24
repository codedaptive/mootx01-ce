import Testing
import Foundation
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import VaultKit

// VaultResidentServiceTests.swift
//
// Tests for VaultWatcher, ResidentReconcilePolicy, and VaultResidentService.
// Uses in-memory estate + temp vault directories so no on-disk state persists.

// Thread-safe collector for async @Sendable closures in tests.
private actor ChangeCollector {
    var changed: [[String]] = []
    var deleted: [[String]] = []
    func appendChanged(_ c: [String]) { changed.append(c) }
    func appendDeleted(_ d: [String]) { deleted.append(d) }
    func allChanged() -> [String] { changed.flatMap { $0 } }
    func allDeleted() -> [String] { deleted.flatMap { $0 } }
}

@Suite("VaultResidentService")
struct VaultResidentServiceTests {

    // MARK: - Helpers

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "resident-tests-\(UUID())")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func makeTempVault(suffix: String = "") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resident-test-\(UUID().uuidString)\(suffix)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - VaultWatcher: poll detects new and modified files

    @Test("VaultWatcher detects a new .md file on next poll")
    func watcherDetectsNewFile() async throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let watcher = VaultWatcher(vaultURL: vault, pollIntervalSeconds: 1)
        let collector = ChangeCollector()

        await watcher.start { changed, _ in
            await collector.appendChanged(changed)
        }

        // Write a file after the first snapshot was taken.
        let note = vault.appendingPathComponent("TestNote.md")
        try "# Hello".write(to: note, atomically: true, encoding: .utf8)

        // Wait for poll + callback.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await watcher.stop()

        let allChanged = await collector.allChanged()
        #expect(!allChanged.isEmpty, "Expected at least one change callback")
        #expect(allChanged.contains("TestNote.md"))
    }

    @Test("VaultWatcher detects deleted .md file")
    func watcherDetectsDeletion() async throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // Write file before watcher starts so it's in the initial snapshot.
        let note = vault.appendingPathComponent("Gone.md")
        try "# Gone".write(to: note, atomically: true, encoding: .utf8)

        let watcher = VaultWatcher(vaultURL: vault, pollIntervalSeconds: 1)
        let collector = ChangeCollector()

        await watcher.start { _, deleted in
            await collector.appendDeleted(deleted)
        }

        try? FileManager.default.removeItem(at: note)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await watcher.stop()

        let allDeleted = await collector.allDeleted()
        #expect(!allDeleted.isEmpty, "Expected at least one deletion callback")
        #expect(allDeleted.contains("Gone.md"))
    }

    // MARK: - ResidentReconcilePolicy: fence predicate

    @Test("isVaultFenced blocks non-public exportability")
    func fenceBlocksNonPublic() {
        #expect(isVaultFenced(exportability: .private_))
    }

    @Test("isVaultFenced allows public_ exportability")
    func fenceAllowsPublic() {
        #expect(!isVaultFenced(exportability: .public_))
    }

    // MARK: - VaultResidentService: startup resync (vault→estate)

    @Test("Service startup resync imports pre-existing vault notes into estate")
    func startupResyncImportsVaultNotes() async throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // Write a note before starting the service — simulates missed change.
        let note = vault.appendingPathComponent("Existing.md")
        try "# Existing note\nThis was here before the service started.".write(
            to: note, atomically: true, encoding: .utf8)

        let (kit, handle) = try await openEstate()
        let service = VaultResidentService(
            kit: kit,
            handle: handle,
            vaultURL: vault,
            pollIntervalSeconds: 60,   // long poll so test controls timing
            estatePollSeconds: 600
        )

        // Start performs startup resync; vault note should be imported.
        try await service.start()
        await service.stop()

        // Verify at least one drawer landed in the estate from the import.
        // We check unconfirmed drawers (importVault captures as unconfirmed by default).
        let drawers = try await kit.recall(handle, RecallFrame(
            filterChain: [.any([.unconfirmed, .userConfirmed, .automatedConfirmedOnly]), .currentlyBelieve],
            hydrationLevel: .structured,
            limit: 100
        ))
        #expect(!drawers.isEmpty,
                "Startup resync should have imported at least one drawer from the pre-existing vault note")
    }

    // MARK: - VaultResidentService: vault deletion blocked

    @Test("Service reports blocked vault deletions without erasing estate drawers")
    func vaultDeletionBlocked() async throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let note = vault.appendingPathComponent("ToDelete.md")
        try "# Delete me".write(to: note, atomically: true, encoding: .utf8)

        let (kit, handle) = try await openEstate()
        let service = VaultResidentService(
            kit: kit,
            handle: handle,
            vaultURL: vault,
            pollIntervalSeconds: 1,    // fast poll for test
            estatePollSeconds: 600
        )
        try await service.start()

        // Delete the vault note.
        try FileManager.default.removeItem(at: note)

        // Wait for watcher poll to fire.
        try await Task.sleep(nanoseconds: 1_600_000_000)
        await service.stop()

        let blocked = await service.blockedDeletions
        #expect(!blocked.isEmpty, "Vault deletion should be reported as blocked")
        #expect(blocked.contains(where: { $0.vaultPath.hasSuffix("ToDelete.md") }))
    }

    // MARK: - VaultResidentService: vault not found throws

    @Test("Service start throws VaultResidentError.vaultNotFound for non-existent vault")
    func startThrowsForMissingVault() async throws {
        let (kit, handle) = try await openEstate()
        let noVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-vault-\(UUID().uuidString)", isDirectory: true)
        let service = VaultResidentService(kit: kit, handle: handle, vaultURL: noVault)

        await #expect(throws: VaultResidentError.self) {
            try await service.start()
        }
    }
}
