import Testing
import Foundation
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import VaultKit

/// End-to-end bridge tests against a real in-memory estate. Each test
/// opens its own estate and writes only inside a unique temp vault dir,
/// which it removes in the body.
@Suite("VaultBridge import/export")
struct VaultBridgeTests {

    // MARK: - Fixtures

    /// Open one estate through GeniusLocusKit over in-memory storage.
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "vaultkit-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func makeTempVault() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultkit-bridge-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Count `.md` files under `vaultURL`, skipping hidden files. Synchronous
    /// helper used to verify export output without async enumeration.
    private func countMDFiles(in vaultURL: URL) -> Int {
        var count = 0
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        while let next = enumerator.nextObject() as? URL {
            if next.pathExtension == "md" { count += 1 }
        }
        return count
    }

    /// Return first `.md` file under `vaultURL`, skipping hidden files. Nil if none.
    private func firstMDFile(in vaultURL: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        while let next = enumerator.nextObject() as? URL {
            if next.pathExtension == "md" { return next }
        }
        return nil
    }

    /// Build a one-note fixture vault with a wikilink. Returns the vault URL.
    private func seedVault() throws -> URL {
        let vault = makeTempVault()
        try write(
            """
            ---
            room: research
            ---
            A study of [[Benzene]] and its ring structure.
            """,
            to: vault.appendingPathComponent("Chem/Aromatics.md")
        )
        return vault
    }

    /// Count currently-believed drawers in an estate.
    private func currentDrawers(_ kit: GeniusLocusKit, _ handle: EstateHandle) async throws -> [Drawer] {
        try await kit.recall(handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .full))
    }

    // MARK: - currentlyBelieve recall helper (for scope tests)

    /// Count currently-believed drawers using the default `.believed` scope,
    /// which includes confirmed and unconfirmed.
    private func believedDrawers(
        _ kit: GeniusLocusKit, _ handle: EstateHandle
    ) async throws -> [Drawer] {
        // `.believed` scope filter chain: currentlyBelieve + any confirmation + any trust.
        try await kit.recall(handle, RecallFrame(
            filterChain: [
                .currentlyBelieve,
                .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                .any([.trustworthy, .requiresConfirmation]),
            ],
            hydrationLevel: .full))
    }

    // MARK: - Import writes drawers + tunnels

    @Test("import writes drawers with .importedFile channel and .imported/.references tunnels")
    func importWritesDrawersAndTunnels() async throws {
        let (kit, handle) = try await openEstate()
        let vault = try seedVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        let report = try await bridge.importVault(at: vault, into: handle)

        #expect(report.drawersWritten == 1)
        #expect(report.drawersUpdated == 0)
        #expect(report.tunnelsCreated == 1)
        #expect(report.itemsSkipped == 0)

        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1)
        let drawer = try #require(drawers.first)
        #expect(drawer.captureChannel == .importedFile)
        #expect(drawer.room == "research")
        #expect(drawer.featureFlags.contains(.hasLinks))

        let tunnels = try await kit.recallTunnels(handle, wing: drawer.wing)
        let refs = tunnels.filter { $0.kind == .references }
        #expect(refs.count == 1)
        let ref = try #require(refs.first)
        #expect(ref.originClass == .imported)
        #expect(ref.label == "Benzene")
    }

    // MARK: - Idempotency

    @Test("re-import is idempotent: drawer count stable, no dup reference tunnels")
    func reimportIsIdempotent() async throws {
        let (kit, handle) = try await openEstate()
        let vault = try seedVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))

        let first = try await bridge.importVault(at: vault, into: handle)
        #expect(first.drawersWritten == 1)
        #expect(first.drawersUpdated == 0)

        let second = try await bridge.importVault(at: vault, into: handle)
        #expect(second.drawersWritten == 0)
        #expect(second.drawersUpdated == 1)        // superseded, not duplicated
        #expect(second.tunnelsCreated == 0)        // de-duplicated

        // Currently-believed drawer count is stable at 1.
        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1)

        // Reference tunnel count is stable at 1.
        let drawer = try #require(drawers.first)
        let refs = try await kit.recallTunnels(handle, wing: drawer.wing).filter { $0.kind == .references }
        #expect(refs.count == 1)
    }

    // MARK: - I-5 guard

    @Test("note with empty content is skipped, never emitted as a frame")
    func emptyContentSkipped() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        // Frontmatter only, empty body.
        try write("---\nroom: r\n---\n", to: vault.appendingPathComponent("Empty.md"))

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        let report = try await bridge.importVault(at: vault, into: handle)
        #expect(report.itemsSkipped == 1)
        #expect(report.drawersWritten == 0)

        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.isEmpty)
    }

    @Test("capture rejects a frame missing the I-5 udcCode (the guard the bridge satisfies)")
    func captureRejectsEmptyUDC() async throws {
        let (kit, handle) = try await openEstate()
        let badFrame = CaptureFrame(
            content: "x",
            channel: .importedFile,
            room: "r",
            latticeAnchor: LatticeAnchor(udcCode: ""),   // I-5 violation
            addedBy: "a",
            embeddingModelID: "m"
        )
        await #expect(throws: (any Error).self) {
            _ = try await kit.capture(handle, badFrame)
        }
    }

    // MARK: - Feature-flag-off (EideticLib classification disabled)

    @Test("feature-flag-off import lands the fallback UDC and counts as unclassified")
    func featureFlagOffFallbackUDC() async throws {
        let (kit, handle) = try await openEstate()
        let vault = try seedVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        let report = try await bridge.importVault(at: vault, into: handle)
        #expect(report.fdcClassified == 0)
        #expect(report.fdcUnclassified == 1)

        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.first?.udcCode == "000")
    }

    // MARK: - Export scope tests

    @Test("confirmed drawers ARE included in the default .believed scope export")
    func believedScopeIncludesConfirmedDrawers() async throws {
        // This is the confirmed-drop bug fix: previously confirmed drawers
        // were silently excluded because the filter was hard-coded to
        // .unconfirmed. The .believed scope must include both.
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // Import a note (it lands as unconfirmed by default).
        let sourceVault = try seedVault()
        defer { try? FileManager.default.removeItem(at: sourceVault) }
        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        _ = try await bridge.importVault(at: sourceVault, into: handle)

        // Confirm the drawer. `mutate` with `.confirm` moves the
        // confirmation state from unconfirmed → userConfirmed.
        let drawers = try await currentDrawers(kit, handle)
        let drawer = try #require(drawers.first)
        try await kit.mutate(handle, MutateFrame(rowID: drawer.id, kind: .confirm))

        // Export with default scope (`.believed`).
        // The confirmed drawer MUST appear in the vault.
        try await bridge.export(estate: handle, to: vault)

        // The vault must contain exactly one note.
        #expect(countMDFiles(in: vault) == 1, "confirmed drawer must be exported under .believed scope")
    }

    @Test("unconfirmed scope exports only unconfirmed drawers (legacy behavior)")
    func unconfirmedScopeExportsOnlyUnconfirmed() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let sourceVault = try seedVault()
        defer { try? FileManager.default.removeItem(at: sourceVault) }
        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        _ = try await bridge.importVault(at: sourceVault, into: handle)

        // Confirm the drawer.
        let drawers = try await currentDrawers(kit, handle)
        let drawer = try #require(drawers.first)
        try await kit.mutate(handle, MutateFrame(rowID: drawer.id, kind: .confirm))

        // Export with .unconfirmed scope — the confirmed drawer is excluded.
        try await bridge.export(estate: handle, to: vault, scope: .unconfirmed)

        // After confirmation the drawer is NOT unconfirmed, so it must be absent.
        #expect(countMDFiles(in: vault) == 0, "confirmed drawer must be excluded under .unconfirmed scope")
    }

    // MARK: - moot_id round-trip identity tests

    @Test("export→re-import preserves lineage via moot_id (no duplicate drawers)")
    func mootIDPreservesLineageOnRoundTrip() async throws {
        let (kit, handle) = try await openEstate()
        let sourceVault = try seedVault()
        let exportVault = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: sourceVault)
            try? FileManager.default.removeItem(at: exportVault)
        }

        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        let first = try await bridge.importVault(at: sourceVault, into: handle)
        #expect(first.drawersWritten == 1)

        // Export — moot_id is written into frontmatter.
        try await bridge.export(estate: handle, to: exportVault)

        // Re-import the exported vault. The moot_id must map back to the
        // SAME lineage, so it supersedes rather than duplicates.
        let second = try await bridge.importVault(at: exportVault, into: handle)
        #expect(second.drawersWritten == 0)
        #expect(second.drawersUpdated == 1, "re-import via moot_id must supersede")

        // Drawer count stable at 1.
        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1)
    }

    @Test("renaming exported file but keeping moot_id preserves lineage on re-import")
    func renamedFileWithMootIDPreservesLineage() async throws {
        let (kit, handle) = try await openEstate()
        let sourceVault = try seedVault()
        let exportVault = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: sourceVault)
            try? FileManager.default.removeItem(at: exportVault)
        }

        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        _ = try await bridge.importVault(at: sourceVault, into: handle)
        try await bridge.export(estate: handle, to: exportVault)

        // Find the exported .md file, rename it.
        let original = try #require(firstMDFile(in: exportVault))
        let renamed = original.deletingLastPathComponent()
            .appendingPathComponent("completely-different-name.md")
        try FileManager.default.moveItem(at: original, to: renamed)

        // Re-import the vault with the renamed file. moot_id in frontmatter
        // must win over the new filename's FNV-derived key.
        let report = try await bridge.importVault(at: exportVault, into: handle)
        // Must supersede (not write a new drawer) even though the file was renamed.
        #expect(report.drawersWritten == 0)
        #expect(report.drawersUpdated == 1, "moot_id must win over filename after rename")
        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1, "rename must not create a duplicate drawer")
    }

    // MARK: - End-to-end export → import → equivalence

    @Test("export an estate, import the produced vault into a fresh estate, structural equivalence holds")
    func endToEndExportImport() async throws {
        let (kitA, handleA) = try await openEstate()
        let sourceVault = try seedVault()
        let exportVault = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: sourceVault)
            try? FileManager.default.removeItem(at: exportVault)
        }

        let mapping = DrawerMapping(classifyOnImport: false)
        let bridgeA = VaultBridge(kit: kitA, mapping: mapping)
        _ = try await bridgeA.importVault(at: sourceVault, into: handleA)

        // Export estate A to a vault, then import that vault into fresh estate B.
        try await bridgeA.export(estate: handleA, to: exportVault)

        let (kitB, handleB) = try await openEstate()
        let bridgeB = VaultBridge(kit: kitB, mapping: mapping)
        let reportB = try await bridgeB.importVault(at: exportVault, into: handleB)
        #expect(reportB.drawersWritten == 1)

        let drawersA = try await currentDrawers(kitA, handleA)
        let drawersB = try await currentDrawers(kitB, handleB)
        // Same number of currently-believed drawers.
        #expect(drawersA.count == drawersB.count)

        // The original content survives the projection (B's content carries
        // A's content; rendering may append the wikilink markup).
        let aContent = try #require(drawersA.first?.content)
        let bContent = try #require(drawersB.first?.content)
        #expect(bContent.contains(aContent))

        // The reference link survives across the round-trip.
        let refsB = try await kitB.recallTunnels(handleB, wing: drawersB.first!.wing)
            .filter { $0.kind == .references }
        #expect(refsB.contains { $0.label == "Benzene" })
    }
}
