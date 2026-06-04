// VaultToolsTests.swift
//
// Coverage for the moot_vault_* control surface on ARIA_MCP. Every
// dispatch case runs end-to-end against a real in-memory GeniusLocusKit
// estate (no mocks) and a unique temp vault dir removed in the test
// body. Covers: tool listing, argument validation, export→status,
// import round-trip, and export→reconcile drift detection with the
// return-only candidate seam.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: every dispatch case opens live in-memory estates and
/// touches the filesystem — same discipline as LensToolsTests.
@Suite("Vault tools", .serialized)
struct VaultToolsTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit, owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner)
    }

    @discardableResult
    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, room: String
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("004"),
            addedBy: "vault-tests",
            embeddingModelID: "test-model-v1")
        return try await kit.capture(handle, frame).id
    }

    private func makeTempVault() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vaulttools-\(UUID().uuidString)", isDirectory: true)
    }

    private func text(_ result: JSONValue) throws -> String {
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        return try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    }

    private func args(_ pairs: [String: String]) -> JSONValue {
        .object(pairs.mapValues { JSONValue.string($0) })
    }

    // MARK: - Projection

    @Test func toolListContainsTheFourVaultTools() {
        let names = Set(ToolProjection.tools().map(\.name))
        #expect(names.contains("moot_vault_export"))
        #expect(names.contains("moot_vault_import"))
        #expect(names.contains("moot_vault_status"))
        #expect(names.contains("moot_vault_reconcile"))
    }

    @Test func vaultToolsCarryVaultProvenance() {
        let vaultTools = ToolProjection.tools().filter {
            $0.name.hasPrefix("moot_vault_")
        }
        #expect(vaultTools.count == 4)
        for tool in vaultTools {
            #expect(tool.provenance == .vault)
            // A vault tool is not a lexicon tool — no (verb, noun) pair.
            #expect(tool.verb == nil)
            #expect(tool.noun == nil)
        }
    }

    @Test func vaultToolsDoNotDisturbTheFederationCount() {
        // Adding .vault provenance must not perturb the lone federation
        // tool the conformance gate counts.
        let federation = ToolProjection.tools().filter { $0.provenance == .federation }
        #expect(federation.count == 1)
    }

    // MARK: - Argument validation

    @Test func exportWithoutVaultPathIsRejected() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-noarg"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_vault_export", arguments: .object([:]))
        }
    }

    @Test func reconcileWithoutVaultPathIsRejected() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-noarg2"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_vault_reconcile", arguments: .object([:]))
        }
    }

    @Test func importWithoutVaultPathIsRejected() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-noarg3"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_vault_import", arguments: .object([:]))
        }
    }

    @Test func statusWithoutVaultPathIsRejected() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-noarg4"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_vault_status", arguments: .object([:]))
        }
    }

    // MARK: - Export → status

    @Test func exportStampsManifestAndStatusReportsIt() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-export"))
        try await capture(kit, handle, content: "Benzene is aromatic.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // status before export: no manifest.
        let pre = try text(try await dispatcher.dispatch(
            name: "moot_vault_status", arguments: args(["vaultPath": vault.path])))
        #expect(pre.contains("no export manifest"))

        // export stamps the manifest.
        let exported = try text(try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path])))
        #expect(exported.contains("vault_export:"))

        // The sidecar manifest exists at the hidden path and is hidden
        // from the note enumerator.
        let manifestURL = vault.appendingPathComponent(VaultTools.manifestRelativePath)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        // status after export: manifest present, one note.
        let post = try text(try await dispatcher.dispatch(
            name: "moot_vault_status", arguments: args(["vaultPath": vault.path])))
        #expect(post.contains("manifest present"))
        #expect(post.contains("noteCount: 1"))
    }

    // MARK: - Import round-trip

    @Test func exportThenImportIntoFreshEstateRoundTrips() async throws {
        let kit = GeniusLocusKit()
        let handleA = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-src"))
        try await capture(kit, handleA, content: "Toluene is a solvent.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let dispatcherA = ToolDispatcher(kit: kit, handle: handleA)
        _ = try await dispatcherA.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))

        // Import the produced vault into a fresh estate.
        let handleB = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-dst"))
        let dispatcherB = ToolDispatcher(kit: kit, handle: handleB)
        let imported = try text(try await dispatcherB.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path])))
        #expect(imported.contains("vault_import:"))
        #expect(imported.contains("1 written"))
    }

    // MARK: - Reconcile / drift

    @Test func reconcileWithoutManifestIsAnErrorResult() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-nomanifest"))
        let vault = makeTempVault()
        try FileManager.default.createDirectory(
            at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true)
        let body = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(body.contains("no export manifest"))
    }

    @Test func reconcileAfterExportWithNoEditsReportsZeroDrift() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-nodrift"))
        try await capture(kit, handle, content: "Phenol notes.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))
        let reconciled = try text(try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path])))
        #expect(reconciled.contains("0 added, 0 modified, 0 deleted"))
    }

    @Test func reconcileAfterEditingOneNoteFlagsExactlyThatFile() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-edit"))
        try await capture(kit, handle, content: "Original aniline note.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))

        // Find the single exported note and append a byte to it.
        let manifest = try #require(try VaultTools.readManifest(vaultURL: vault))
        #expect(manifest.files.count == 1)
        let notePath = try #require(manifest.files.keys.first)
        let noteURL = vault.appendingPathComponent(notePath)
        let original = try String(contentsOf: noteURL, encoding: .utf8)
        try (original + "\nedited.").write(to: noteURL, atomically: true, encoding: .utf8)

        let reconciled = try text(try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path])))
        // Exactly that file is modified; nothing added or deleted.
        #expect(reconciled.contains("0 added, 1 modified, 0 deleted"))
        #expect(reconciled.contains("~ \(notePath)"))
        // A candidate is returned for the modified file (return-only seam).
        let stableKey = notePath.hasSuffix(".md")
            ? String(notePath.dropLast(3)) : notePath
        #expect(reconciled.contains("candidate stableSourceKey=\(stableKey)"))
        // The seam is return-only: the output states explicitly that no
        // Proposal is written (A2 produces candidates, never Proposals).
        #expect(reconciled.contains("no Proposal written"))
    }

    @Test func reconcileReportsAddedAndDeletedWithoutActioning() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-adddel"))
        try await capture(kit, handle, content: "Keep me.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))

        // Delete the exported note, add a brand-new untracked note.
        let manifest = try #require(try VaultTools.readManifest(vaultURL: vault))
        let exportedNote = try #require(manifest.files.keys.first)
        try FileManager.default.removeItem(
            at: vault.appendingPathComponent(exportedNote))
        let newNote = vault.appendingPathComponent("Fresh/New.md")
        try FileManager.default.createDirectory(
            at: newNote.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "A new untracked note.".write(to: newNote, atomically: true, encoding: .utf8)

        let reconciled = try text(try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path])))
        #expect(reconciled.contains("1 added, 0 modified, 1 deleted"))
        #expect(reconciled.contains("+ Fresh/New.md"))
        #expect(reconciled.contains("- \(exportedNote)"))
        // The deleted drawer is still believed — reconcile actioned nothing.
        let drawers = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(drawers.count == 1)
    }
}
