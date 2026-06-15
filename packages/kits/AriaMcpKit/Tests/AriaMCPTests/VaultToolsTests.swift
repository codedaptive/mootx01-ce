// VaultToolsTests.swift
//
// Coverage for the moot_vault_* control surface on ARIA_MCP. Every
// dispatch case runs end-to-end against a real in-memory GeniusLocusKit
// estate (no mocks) and a unique temp vault dir removed in the test
// body. Covers: tool listing, argument validation, export→status,
// import round-trip, export→reconcile drift detection with the
// return-only candidate seam, and async import/export job lifecycle
// (job_id returned immediately, background Task drives VaultBridge,
// moot_vault_job polls status).

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

    @Test func toolListContainsFiveVaultTools() {
        let names = Set(ToolProjection.tools().map(\.name))
        #expect(names.contains("moot_vault_export"))
        #expect(names.contains("moot_vault_import"))
        #expect(names.contains("moot_vault_status"))
        #expect(names.contains("moot_vault_reconcile"))
        #expect(names.contains("moot_vault_job"))
    }

    @Test func vaultToolsCarryVaultProvenance() {
        let vaultTools = ToolProjection.tools().filter {
            $0.name.hasPrefix("moot_vault_")
        }
        #expect(vaultTools.count == 5)
        for tool in vaultTools {
            #expect(tool.provenance == .vault)
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

        // export starts the background Task and returns a job_id immediately.
        let exportLaunch = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))
        let exportJobID = try extractJobID(from: exportLaunch)

        // Wait until the background Task finishes writing the vault + manifest.
        let exportStatus = try await waitForJob(id: exportJobID, via: dispatcher)
        #expect(exportStatus.contains("status: complete"))

        // The sidecar manifest now exists at the hidden path and is hidden
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
        // Wait for the async export to finish so the vault files exist.
        try await runExportAndAwait(vault: vault, via: dispatcherA)

        // Import the produced vault into a fresh estate.
        let handleB = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-dst"))
        let dispatcherB = ToolDispatcher(kit: kit, handle: handleB)
        let importLaunch = try await dispatcherB.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let importJobID = try extractJobID(from: importLaunch)
        // Wait for the import bridge to finish (includes kit.capture warm-up).
        let importStatus = try await waitForJob(id: importJobID, via: dispatcherB)
        #expect(importStatus.contains("status: complete"))
        #expect(importStatus.contains("drawersWritten: 1"))
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

        try await runExportAndAwait(vault: vault, via: dispatcher)
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

        // Wait for the export Task to finish so the manifest is readable.
        try await runExportAndAwait(vault: vault, via: dispatcher)

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

        // Wait for the export Task to finish so the manifest is readable.
        try await runExportAndAwait(vault: vault, via: dispatcher)

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

    // MARK: - Reconcile apply path

    /// Build an args object with a mix of string and bool values for reconcile.
    private func reconcileArgs(vaultPath: String, apply: Bool? = nil) -> JSONValue {
        var dict: [String: JSONValue] = ["vaultPath": .string(vaultPath)]
        if let apply { dict["apply"] = .bool(apply) }
        return .object(dict)
    }

    @Test func reconcileApplyActionsModifiedNoteIntoEstate() async throws {
        // Verify the reconcile→apply round-trip: export, edit one note on
        // disk, then reconcile apply=true — the edit must land in the estate.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-apply-modified"))
        try await capture(kit, handle, content: "Aniline original.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Export so the manifest is stamped and the note file exists on disk.
        try await runExportAndAwait(vault: vault, via: dispatcher)

        // Snapshot the drawer count in the estate before the edit.
        let preRecall = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        let preCount = preRecall.count

        // Edit the exported note on disk — this creates a modified candidate.
        let manifest = try #require(try VaultTools.readManifest(vaultURL: vault))
        let notePath = try #require(manifest.files.keys.first)
        let noteURL = vault.appendingPathComponent(notePath)
        let original = try String(contentsOf: noteURL, encoding: .utf8)
        try (original + "\nAdded in reconcile-apply test.").write(
            to: noteURL, atomically: true, encoding: .utf8)

        // Dry-run first: must report 1 modified, write nothing.
        let dryRun = try text(try await dispatcher.dispatch(
            name: "moot_vault_reconcile",
            arguments: reconcileArgs(vaultPath: vault.path)))
        #expect(dryRun.contains("0 added, 1 modified, 0 deleted"))
        #expect(dryRun.contains("dry-run"))
        // Estate unchanged after dry-run.
        let midRecall = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(midRecall.count == preCount)

        // Apply mode: the modified note must be imported into the estate.
        let applyResult = try text(try await dispatcher.dispatch(
            name: "moot_vault_reconcile",
            arguments: reconcileArgs(vaultPath: vault.path, apply: true)))
        #expect(applyResult.contains("0 added, 1 modified, 0 deleted"))
        #expect(applyResult.contains("apply: true"))
        // The import bridge reports drawersUpdated=1 (the same stableSourceKey
        // already exists in the estate from the original capture).
        #expect(applyResult.contains("drawersUpdated: 1") || applyResult.contains("drawersWritten: 1"))
    }

    @Test func reconcileApplyAddedNoteWritesNewDrawer() async throws {
        // A new vault note not present in the estate must be written when apply=true.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-apply-added"))
        let vault = makeTempVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Export an empty vault so the manifest exists.
        try await runExportAndAwait(vault: vault, via: dispatcher)

        // Add a brand-new note to the vault directory after the export.
        let newNote = vault.appendingPathComponent("NewSection/Added.md")
        try FileManager.default.createDirectory(
            at: newNote.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Added note\n\nContent added after export.".write(
            to: newNote, atomically: true, encoding: .utf8)

        // Apply: the new note must be written into the estate.
        let applyResult = try text(try await dispatcher.dispatch(
            name: "moot_vault_reconcile",
            arguments: reconcileArgs(vaultPath: vault.path, apply: true)))
        #expect(applyResult.contains("1 added, 0 modified, 0 deleted"))
        #expect(applyResult.contains("apply: true"))
        #expect(applyResult.contains("drawersWritten: 1"))

        // Estate now contains the new drawer.
        let postRecall = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(postRecall.count == 1)
    }

    @Test func reconcileApplyActionsCandidatesOnlyNotFullVault() async throws {
        // Defect-2 regression: apply=true must import only the M candidates,
        // not the full N-note vault. With 10 notes captured, exported, and 1
        // modified on disk, drawersUpdated must be exactly 1 — not 10.
        // This guards against the over-import regression where import of the
        // full vault would report N (vault size) not M (candidates).
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-apply-10notes"))
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Capture 10 distinct notes into the estate first, then export them to
        // the vault. Export writes the notes on disk and stamps the manifest.
        for i in 1...10 {
            try await capture(kit, handle, content: "Content for note \(i).", room: "multi")
        }
        try await runExportAndAwait(vault: vault, via: dispatcher)

        // Snapshot drawer count: 10 from the captures above.
        let preRecall = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(preRecall.count == 10)

        // Edit exactly one vault note on disk to create a single modified candidate.
        let manifest = try #require(try VaultTools.readManifest(vaultURL: vault))
        #expect(manifest.files.count == 10)
        let firstPath = try #require(manifest.files.keys.sorted().first)
        let editedURL = vault.appendingPathComponent(firstPath)
        let original = try String(contentsOf: editedURL, encoding: .utf8)
        try (original + "\nEdited for apply-only test.").write(
            to: editedURL, atomically: true, encoding: .utf8)

        // Dry-run confirms exactly 1 modified candidate.
        let dryRun = try text(try await dispatcher.dispatch(
            name: "moot_vault_reconcile",
            arguments: reconcileArgs(vaultPath: vault.path)))
        #expect(dryRun.contains("0 added, 1 modified, 0 deleted"))

        // Apply: only the 1 modified note must be actioned.
        let applyResult = try text(try await dispatcher.dispatch(
            name: "moot_vault_reconcile",
            arguments: reconcileArgs(vaultPath: vault.path, apply: true)))
        #expect(applyResult.contains("0 added, 1 modified, 0 deleted"))
        #expect(applyResult.contains("apply: true"))
        // drawersUpdated must be 1 (the single modified candidate),
        // not 10 (the full vault). drawersWritten must be 0.
        #expect(applyResult.contains("drawersUpdated: 1"))
        #expect(applyResult.contains("drawersWritten: 0"))

        // The estate still has 10 drawers — no new ones were created.
        let postRecall = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(postRecall.count == 10)
    }

    @Test func reconcileApplyDryRunDefaultLeavesEstateUnchanged() async throws {
        // Calling reconcile without apply (or apply=false) never touches the estate,
        // even when candidates exist.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-dryrun-default"))
        let vault = makeTempVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Export empty vault, then add a note — there is now 1 candidate.
        try await runExportAndAwait(vault: vault, via: dispatcher)
        let note = vault.appendingPathComponent("DryRun.md")
        try "# Dry run note".write(to: note, atomically: true, encoding: .utf8)

        // Reconcile with no apply argument — dry-run.
        let result = try text(try await dispatcher.dispatch(
            name: "moot_vault_reconcile",
            arguments: reconcileArgs(vaultPath: vault.path)))
        #expect(result.contains("1 added, 0 modified, 0 deleted"))
        #expect(result.contains("dry-run"))
        #expect(!result.contains("apply: true"))

        // Estate must be unchanged — no drawers written.
        let recall = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(recall.count == 0)
    }

    @Test func reconcileApplyDeletedFilesAreNeverActioned() async throws {
        // Deleted vault notes are always reported only. Even with apply=true,
        // no drawer is expunged from the estate.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-apply-deleted"))
        try await capture(kit, handle, content: "Keep this drawer.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Export so the note exists, then delete it from disk.
        try await runExportAndAwait(vault: vault, via: dispatcher)
        let manifest = try #require(try VaultTools.readManifest(vaultURL: vault))
        let notePath = try #require(manifest.files.keys.first)
        try FileManager.default.removeItem(at: vault.appendingPathComponent(notePath))

        // apply=true: deleted file must NOT expunge the drawer.
        let applyResult = try text(try await dispatcher.dispatch(
            name: "moot_vault_reconcile",
            arguments: reconcileArgs(vaultPath: vault.path, apply: true)))
        #expect(applyResult.contains("0 added, 0 modified, 1 deleted"))
        #expect(applyResult.contains("apply: true"))

        // The drawer is still believed in the estate.
        let recall = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(recall.count == 1)
    }

    // MARK: - Async job helpers

    /// Scan the plain-text result body for a `job_id: <UUID>` line and
    /// return the UUID string. Throws if no such line exists so failing
    /// tests surface a clear error rather than a confusing nil-unwrap.
    private func extractJobID(from result: JSONValue) throws -> String {
        let body = try text(result)
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("job_id:") {
                return String(trimmed.dropFirst("job_id:".count)
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        struct NoJobID: Error {}
        throw NoJobID()
    }

    /// Poll `moot_vault_job` every 100 ms until the job leaves `running`
    /// state or 10 seconds elapse. Returns the final status text.
    /// Using polling rather than a fixed sleep makes tests robust to
    /// cold-start ML model loading in `kit.capture` on the first run.
    private func waitForJob(id: String, via dispatcher: ToolDispatcher) async throws -> String {
        var statusText = ""
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)   // 100 ms per poll
            let result = try await dispatcher.dispatch(
                name: "moot_vault_job", arguments: args(["job_id": id]))
            statusText = try text(result)
            if !statusText.contains("status: running") { break }
        }
        return statusText
    }

    /// Export the vault via `moot_vault_export` and wait until the async
    /// job completes. Used by reconcile tests that must read the manifest
    /// before proceeding — the manifest is written inside the background
    /// Task, so the export call alone does not guarantee its existence.
    private func runExportAndAwait(vault: URL, via dispatcher: ToolDispatcher) async throws {
        let result = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))
        let jobID = try extractJobID(from: result)
        let status = try await waitForJob(id: jobID, via: dispatcher)
        #expect(status.contains("status: complete"), "Export job did not complete within 10 s")
    }

    // MARK: - Async vault import jobs

    @Test func import_returns_job_id_immediately() async throws {
        // An empty vault is sufficient — hashAllNotes returns zero and the
        // tool should return with a job_id before the background Task runs.
        let vault = makeTempVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-async-import-quick"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let body = try text(result)
        #expect(body.contains("job_id:"))
    }

    @Test func import_job_shows_complete_after_bridge_finishes() async throws {
        let vault = makeTempVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        // One valid note so there is something for the bridge to import.
        try "# Test note\n\nAsync import content.".write(
            to: vault.appendingPathComponent("AsyncNote.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: vault) }

        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-async-import-complete"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let launchResult = try await dispatcher.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let jobID = try extractJobID(from: launchResult)

        // Poll until complete — first import call includes kit.capture
        // warm-up which can exceed a fixed sleep on a cold system.
        let statusText = try await waitForJob(id: jobID, via: dispatcher)
        #expect(statusText.contains("status: complete"))
        #expect(statusText.contains("drawersWritten:"))
    }

    @Test func import_job_shows_failed_on_bridge_error() async throws {
        let vault = makeTempVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        // Invalid UTF-8 bytes in a .md file: hashAllNotes reads as Data
        // (succeeds), but ObsidianAdapter.toIR reads as UTF-8 and throws,
        // so the background Task marks the job failed.
        try Data([0xFF, 0xFE]).write(
            to: vault.appendingPathComponent("invalid.md"), options: .atomic)
        defer { try? FileManager.default.removeItem(at: vault) }

        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-async-import-fail"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let launchResult = try await dispatcher.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let jobID = try extractJobID(from: launchResult)

        // Poll until the background Task records the error.
        let statusText = try await waitForJob(id: jobID, via: dispatcher)
        #expect(statusText.contains("status: failed"))
        #expect(statusText.contains("error:"))
    }

    // MARK: - Async vault export jobs

    @Test func export_returns_job_id_immediately() async throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-async-export-quick"))
        try await capture(kit, handle, content: "Async export note.", room: "test")
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))
        let body = try text(result)
        #expect(body.contains("job_id:"))
    }

    @Test func export_job_shows_complete_after_bridge_finishes() async throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-async-export-complete"))
        try await capture(kit, handle, content: "Completed export note.", room: "test")
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let launchResult = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))
        let jobID = try extractJobID(from: launchResult)

        // Poll until the background Task writes the vault and manifest.
        let statusText = try await waitForJob(id: jobID, via: dispatcher)
        #expect(statusText.contains("status: complete"))
        #expect(statusText.contains("noteCount:"))
    }

    // MARK: - Unknown job ID

    @Test func vault_job_unknown_id_returns_error() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-unknown-job"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fakeID = UUID().uuidString
        let result = try await dispatcher.dispatch(
            name: "moot_vault_job", arguments: args(["job_id": fakeID]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true)
        let body = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(body.contains("unknown job_id"))
    }
}
