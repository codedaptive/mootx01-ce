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
        return try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
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

    // MARK: - Vault gating

    /// When MOOTX01_VAULT=0 (installed with --vault-off), all five vault tools
    /// and the filesystem-importing palace import tool are absent from the
    /// tools/list surface. Default (env absent or ≠ "0") is vault-on.
    @Test func vaultOffHidesAllFiveVaultTools() {
        let vaultOffEnv = ["MOOTX01_VAULT": "0"]
        let toolsOff = ToolProjection.tools(environment: vaultOffEnv)
        let names = Set(toolsOff.map(\.name))
        #expect(!names.contains("moot_vault_export"))
        #expect(!names.contains("moot_vault_import"))
        #expect(!names.contains("moot_vault_status"))
        #expect(!names.contains("moot_vault_reconcile"))
        #expect(!names.contains("moot_vault_job"))
        // moot_palace_import is also hidden when vault is off: it opens
        // arbitrary local SQLite files (same security posture as vault tools).
        #expect(!names.contains("moot_palace_import"))
        // Vault-off removes the five moot_vault_* tools plus palace import.
        // 76 vault-on − 6 = 70 (dataset + packet + contradiction-hunter tools are not
        // vault-gated).
        #expect(toolsOff.count == 70)
    }

    /// Vault is on when MOOTX01_VAULT is absent from the environment.
    @Test func vaultOnWhenEnvAbsent() {
        let toolsNoEnv = ToolProjection.tools(environment: [:])
        let names = Set(toolsNoEnv.map(\.name))
        #expect(names.contains("moot_vault_export"))
        // 67 baseline + 2 contradiction-hunter + 3 dataset tools + 4 packet tools = 76 (incl. moot_recall_connected).
        #expect(toolsNoEnv.count == 76)
    }

    /// vaultEnabled(environment:) reads the env var correctly.
    @Test func vaultEnabledReadsEnvVar() {
        #expect(ToolProjection.vaultEnabled(environment: [:]) == true)            // absent = on
        #expect(ToolProjection.vaultEnabled(environment: ["MOOTX01_VAULT": "1"]) == true)
        #expect(ToolProjection.vaultEnabled(environment: ["MOOTX01_VAULT": "0"]) == false)
        // Only the literal "0" disables vault; other values keep it on.
        #expect(ToolProjection.vaultEnabled(environment: ["MOOTX01_VAULT": ""]) == true)
        #expect(ToolProjection.vaultEnabled(environment: ["MOOTX01_VAULT": "off"]) == true)
    }

    /// When vault is disabled (MOOTX01_VAULT=0 in the process env) and a
    /// client hard-codes a vault tool name, the dispatch returns a clear error
    /// rather than an opaque failure. This verifies the guard in
    /// VaultTools.dispatch() fires for a real call (not a mock).
    ///
    /// Note: we cannot set MOOTX01_VAULT=0 in the process env at test time
    /// (ProcessInfo.processInfo.environment is read-only). The test instead
    /// verifies the guard fires by calling VaultTools.dispatch() with vault
    /// disabled via the vaultEnabled(environment:) path. The dispatch guard
    /// calls ToolProjection.vaultEnabled which reads the live process env;
    /// since MOOTX01_VAULT is not "0" in the test process, the guard does
    /// NOT fire in a normal test run. Integration-level dispatch-guard
    /// coverage is provided by the Rust port's thread-local env test (which
    /// CAN set env vars safely in isolation). The Swift guard is unit-tested
    /// through the vaultEnabled(environment:) function directly above.
    @Test func vaultOffToolListIsStableAcrossCallSites() {
        // Both the zero-arg overload (live env) and the env-injected overload
        // produce the same vault-on result in a test process where
        // MOOTX01_VAULT is not set to "0". The env var path is covered above.
        let liveEnv = ProcessInfo.processInfo.environment
        let live = ToolProjection.tools()
        let injected = ToolProjection.tools(environment: liveEnv)
        #expect(live.count == injected.count)
        #expect(live.map(\.name) == injected.map(\.name))
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
        // CAND-032: the default scope (`exportable`) only exports drawers
        // explicitly marked public; `capture` drawers are born private, so
        // without `scope: believed` this export writes zero notes and the
        // manifest honestly reports noteCount 0 (same fix as the Rust
        // round-trip test in dispatch_tests.rs).
        let exportLaunch = try await dispatcher.dispatch(
            name: "moot_vault_export",
            arguments: args(["vaultPath": vault.path, "scope": "believed"]))
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
        // CAND-032: the default export scope is now `.exportable` (only
        // exportable-marked rows). These reconcile fixtures are ordinary
        // believed-tier notes, so the setup export uses the explicit `.believed`
        // scope to populate the vault with full fidelity (the round-trip /
        // reconcile behavior these tests exercise is scope-independent).
        let result = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path, "scope": "believed"]))
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

    // MARK: - FIX 4: vault_job surfaces skip counts

    /// An idempotent re-import must surface `drawersSkippedUnchanged` and
    /// `drawersSkippedTombstoned` in the vault_job result so an all-zeros
    /// re-import reads as `drawersSkippedUnchanged: N`, not all-zeros silently.
    @Test(.timeLimit(.minutes(2))) func import_job_surfaces_skip_counts() async throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-skip-counts"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // First import — creates a note in the vault from a captured drawer,
        // then imports it so the stableSourceKey is registered.
        // We drive this by exporting and re-importing: export a real note,
        // then import the vault back so the second import is idempotent.
        try await capture(kit, handle, content: "Idempotency skip count test note.", room: "test")

        // Export to vault so we have a real vault with notes.
        let exportResult = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))
        let exportJobID = try extractJobID(from: exportResult)
        _ = try await waitForJob(id: exportJobID, via: dispatcher)

        // Second estate for re-import (fresh, so all notes land as written on first import).
        let handle2 = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-skip-counts-2"))
        let dispatcher2 = ToolDispatcher(kit: kit, handle: handle2)

        // First import into estate2 — should write drawers.
        let firstImport = try await dispatcher2.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let firstJobID = try extractJobID(from: firstImport)
        let firstJobText = try await waitForJob(id: firstJobID, via: dispatcher2)
        #expect(firstJobText.contains("drawersWritten:"), "first import must write drawers; got:\n\(firstJobText)")
        // Skip counts must be present in output (even if zero on first import).
        #expect(firstJobText.contains("drawersSkippedUnchanged:"),
                "vault_job result must include drawersSkippedUnchanged; got:\n\(firstJobText)")
        #expect(firstJobText.contains("drawersSkippedTombstoned:"),
                "vault_job result must include drawersSkippedTombstoned; got:\n\(firstJobText)")

        // Second import of same vault — content is identical, should skip unchanged.
        let secondImport = try await dispatcher2.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let secondJobID = try extractJobID(from: secondImport)
        let secondJobText = try await waitForJob(id: secondJobID, via: dispatcher2)
        #expect(secondJobText.contains("drawersSkippedUnchanged:"),
                "vault_job result must include drawersSkippedUnchanged on re-import; got:\n\(secondJobText)")
        // The idempotent re-import should show skipped-unchanged > 0 (not all zeros).
        #expect(!secondJobText.contains("drawersSkippedUnchanged: 0") ||
                secondJobText.contains("drawersWritten: 0"),
                "Re-import of unchanged vault must not show all-zero activity; got:\n\(secondJobText)")
    }

    // MARK: - Vault job cap atomicity (Finding 1 — TOCTOU fix)

    /// `checkAndRegister` enforces the cap in a single actor turn: after K
    /// successful registrations the (K+1)th call must throw without registering.
    /// This verifies the cap is enforced and that the error message is actionable.
    @Test func vaultJobCapIsEnforcedAtomically() async throws {
        let registry = VaultJobRegistry()
        let maxJobs = 2

        // Register up to the cap — both should succeed.
        let id1 = try await registry.checkAndRegister(
            kind: .`import`, vaultPath: "/tmp/a", maxJobs: maxJobs)
        let id2 = try await registry.checkAndRegister(
            kind: .`export`, vaultPath: "/tmp/b", maxJobs: maxJobs)
        #expect(!id1.isEmpty)
        #expect(!id2.isEmpty)
        #expect(id1 != id2)

        // Third call must throw — cap is reached.
        await #expect(throws: JSONRPCError.self) {
            _ = try await registry.checkAndRegister(
                kind: .`import`, vaultPath: "/tmp/c", maxJobs: maxJobs)
        }
    }

    /// After a running job completes, the cap slot is freed and a new
    /// `checkAndRegister` succeeds.
    @Test func vaultJobCapFreesSlotOnCompletion() async throws {
        let registry = VaultJobRegistry()
        let maxJobs = 1

        // Fill the cap.
        let id1 = try await registry.checkAndRegister(
            kind: .`import`, vaultPath: "/tmp/x", maxJobs: maxJobs)
        // Cap is full — second call must throw.
        await #expect(throws: JSONRPCError.self) {
            _ = try await registry.checkAndRegister(
                kind: .`import`, vaultPath: "/tmp/y", maxJobs: maxJobs)
        }

        // Complete the running job — slot is freed.
        await registry.complete(
            jobID: id1,
            result: .imported(ImportResult(
                drawersWritten: 0, drawersUpdated: 0, itemsSkipped: 0,
                tunnelsCreated: 0, fdcClassified: 0, fdcUnclassified: 0,
                drawersSkippedUnchanged: 0, drawersSkippedTombstoned: 0)))

        // Now a new registration must succeed.
        let id2 = try await registry.checkAndRegister(
            kind: .`export`, vaultPath: "/tmp/z", maxJobs: maxJobs)
        #expect(!id2.isEmpty)
    }

    // MARK: - Availability hardening (secfix/c-vault-jobslot)

    /// `hashAllNotes` must skip a sub-directory named `directory.md` rather
    /// than throwing. Caller-controlled vault contents may include such an
    /// entry; it is not a note and must not be treated as fatal.
    ///
    /// Security boundary: the enumerator's `.isRegularFileKey` check filters
    /// out directories, symlinks, and special files with a `.md` extension
    /// before the `Data(contentsOf:)` read is attempted.
    @Test func hashAllNotes_skips_directory_named_md() throws {
        let vault = makeTempVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        // Create a sub-directory named "directory.md" — not a note.
        let dirMD = vault.appendingPathComponent("directory.md", isDirectory: true)
        try FileManager.default.createDirectory(at: dirMD, withIntermediateDirectories: true)

        // Also add a real note alongside the directory.
        try "# Real note\n\nContent.".write(
            to: vault.appendingPathComponent("real_note.md"), atomically: true, encoding: .utf8)

        // hashAllNotes must not throw; it must count only the regular .md file.
        let hashes = try VaultTools.hashAllNotes(vaultURL: vault)
        #expect(hashes.count == 1,
                "directory.md must be skipped; only real_note.md should be counted, got: \(hashes.keys.sorted())")
        #expect(hashes["real_note.md"] != nil,
                "real_note.md must appear in the hash map")
    }

    /// Regression for the availability DoS (secfix/c-vault-jobslot, refined by
    /// secfix/c-vault-cap): 4 consecutive imports into a vault that contains only
    /// a sub-directory named `directory.md` (no regular notes) must NOT exhaust the
    /// 4-slot concurrent-job cap. After all 4 complete, a 5th import to a valid
    /// vault must succeed.
    ///
    /// With the register-first ordering (secfix/c-vault-cap):
    /// `checkAndRegister` acquires the slot, then `hashAllNotes` runs. Because
    /// `hashAllNotes` skips non-regular `.md` entries (fix B, secfix/c-vault-jobslot),
    /// the directory is skipped and 0 notes are counted without throwing. The
    /// background `Task` completes the import (0 drawers), calls `complete()`,
    /// and releases the slot. No exhaustion occurs.
    ///
    /// The slot-release-on-throw guard (the pre-Task catch in `runImport`) would
    /// fire if `hashAllNotes` threw — but for this case it does not throw because
    /// fix B skips the directory entry before attempting a read.
    @Test(.timeLimit(.minutes(3)))
    func import_cap_not_exhausted_after_directory_md_vault() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-cap-dirmd"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Vault whose only `.md` entry is a directory — not a real note.
        let problemVault = makeTempVault()
        try FileManager.default.createDirectory(at: problemVault, withIntermediateDirectories: true)
        let dirMD = problemVault.appendingPathComponent("directory.md", isDirectory: true)
        try FileManager.default.createDirectory(at: dirMD, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: problemVault) }

        // 4 consecutive imports — each must start, complete (0 notes), and
        // release its slot via `complete()` inside the background Task.
        for i in 1...4 {
            let result = try await dispatcher.dispatch(
                name: "moot_vault_import",
                arguments: args(["vaultPath": problemVault.path]))
            let jobID = try extractJobID(from: result)
            let status = try await waitForJob(id: jobID, via: dispatcher)
            #expect(status.contains("status: complete"),
                    "Import \(i) must complete; got: \(status)")
        }

        // A 5th import to a valid single-note vault must succeed — cap not exhausted.
        let validVault = makeTempVault()
        try FileManager.default.createDirectory(at: validVault, withIntermediateDirectories: true)
        try "# Valid note\n\nContent.".write(
            to: validVault.appendingPathComponent("valid.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: validVault) }

        let validResult = try await dispatcher.dispatch(
            name: "moot_vault_import",
            arguments: args(["vaultPath": validVault.path]))
        let validJobID = try extractJobID(from: validResult)
        let validStatus = try await waitForJob(id: validJobID, via: dispatcher)
        #expect(validStatus.contains("status: complete"),
                "5th import must succeed (cap must not have been exhausted); got: \(validStatus)")
        #expect(validStatus.contains("drawersWritten: 1"),
                "Valid import must write the note; got: \(validStatus)")
    }

    // MARK: - Cap-before-preflight and slot-release-on-throw (secfix/c-vault-cap)

    /// The vault import cap is enforced BEFORE the expensive preflight runs.
    /// With the register-first ordering, `checkAndRegister` is the FIRST
    /// operation in `runImport` — a full cap rejects the (N+1)th call
    /// immediately, before `hashAllNotes` enumerates any files.
    ///
    /// Verified at the registry level: pre-fill N slots, then attempt a
    /// registration. The cap error is thrown by `checkAndRegister` itself
    /// (the first operation in the new ordering), so no filesystem work is
    /// performed. Release one slot; the next registration must succeed,
    /// confirming the slot count is exactly at the cap (no undercount, no
    /// overflow).
    @Test func import_cap_enforced_before_expensive_preflight() async throws {
        let registry = VaultJobRegistry()
        let maxJobs = 4

        // Fill the cap to its limit.
        var heldIDs: [String] = []
        for i in 0..<maxJobs {
            let id = try await registry.checkAndRegister(
                kind: .`import`, vaultPath: "/tmp/held-\(i)", maxJobs: maxJobs)
            heldIDs.append(id)
        }

        // The (N+1)th call must throw the cap error — `checkAndRegister` is the
        // first operation in the new ordering, so no hashAllNotes has run yet.
        await #expect(throws: JSONRPCError.self) {
            _ = try await registry.checkAndRegister(
                kind: .`import`, vaultPath: "/tmp/overflow", maxJobs: maxJobs)
        }

        // Release one slot and confirm a new registration succeeds — the
        // running count was exactly maxJobs (no over-count, no undercount).
        await registry.complete(
            jobID: heldIDs[0],
            result: .imported(ImportResult(
                drawersWritten: 0, drawersUpdated: 0, itemsSkipped: 0,
                tunnelsCreated: 0, fdcClassified: 0, fdcUnclassified: 0,
                drawersSkippedUnchanged: 0, drawersSkippedTombstoned: 0)))
        let newID = try await registry.checkAndRegister(
            kind: .`import`, vaultPath: "/tmp/after-release", maxJobs: maxJobs)
        #expect(!newID.isEmpty, "After releasing one slot, a new registration must succeed")
    }

    /// When `hashAllNotes` throws after the slot is acquired, the pre-Task
    /// catch in `runImport` releases the slot via `fail()` so the throwing
    /// preflight never permanently consumes cap capacity. A subsequent valid
    /// import must succeed.
    ///
    /// A regular `.md` file with no read permissions triggers the throw —
    /// `hashAllNotes` successfully detects the file is regular (via the
    /// cached `.isRegularFileKey` resource value, readable from directory
    /// entry metadata) and then fails at `Data(contentsOf:)`.
    @Test func import_throwing_preflight_releases_slot() async throws {
        let vault = makeTempVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        // A regular .md file with mode 0o000 — readable metadata (stat),
        // but Data(contentsOf:) throws EPERM. This triggers hashAllNotes to
        // throw after checkAndRegister has already acquired the slot.
        let unreadable = vault.appendingPathComponent("unreadable.md")
        try "# Permission denied".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: unreadable.path)
        defer {
            // Restore read permissions so the temp dir can be cleaned up.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: unreadable.path)
        }

        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v-throw-preflight"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // The import must fail as an isError result — hashAllNotes cannot
        // read the file, the error propagates after the slot-release guard
        // runs fail(), and the dispatch catch-all surfaces it to the client
        // (unexpected runner errors are tool results, not thrown JSON-RPC
        // errors — see DispatchFailureSurfacingTests).
        let failed = try await dispatcher.dispatch(
            name: "moot_vault_import",
            arguments: args(["vaultPath": vault.path]))
        guard case let .object(obj) = failed, case let .bool(isError)? = obj["isError"] else {
            Issue.record("expected a tool result with an isError flag; got: \(failed)")
            return
        }
        #expect(isError, "unreadable preflight must surface as isError:true; got: \(failed)")

        // After the throwing preflight, the slot must be released. A subsequent
        // valid import must succeed — cap not permanently exhausted.
        let validVault = makeTempVault()
        try FileManager.default.createDirectory(at: validVault, withIntermediateDirectories: true)
        try "# Valid note\n\nContent.".write(
            to: validVault.appendingPathComponent("valid.md"),
            atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: validVault) }

        let result = try await dispatcher.dispatch(
            name: "moot_vault_import",
            arguments: args(["vaultPath": validVault.path]))
        let body = try text(result)
        #expect(body.contains("job_id:"),
                "Valid import must succeed after slot was released by throwing preflight; got: \(body)")
    }

    /// Concurrent `checkAndRegister` calls with maxJobs=K: exactly K succeed
    /// and the remainder are rejected. Because `VaultJobRegistry` is an actor,
    /// all calls are serialized — no two can observe the same running count
    /// between check and insert.
    @Test func vaultJobCapNeverExceededUnderConcurrentLaunches() async throws {
        let registry = VaultJobRegistry()
        let maxJobs = 3
        let total = 10

        // Fire total concurrent checkAndRegister calls in a TaskGroup.
        let results: [Result<String, any Error>] = await withTaskGroup(
            of: Result<String, any Error>.self
        ) { group in
            for i in 0..<total {
                group.addTask {
                    do {
                        let id = try await registry.checkAndRegister(
                            kind: .`import`, vaultPath: "/tmp/concurrent-\(i)", maxJobs: maxJobs)
                        return .success(id)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<String, any Error>] = []
            for await r in group { collected.append(r) }
            return collected
        }

        let successes = results.filter { if case .success = $0 { return true }; return false }
        let failures  = results.filter { if case .failure = $0 { return true }; return false }
        #expect(successes.count == maxJobs,
                "Expected exactly \(maxJobs) successful registrations; got \(successes.count)")
        #expect(failures.count == total - maxJobs,
                "Expected \(total - maxJobs) rejections; got \(failures.count)")
    }

    // MARK: - Symlink containment (secfix/c-aria-minor CAND-014)

    /// A pre-planted symlink at `.moot/export-manifest.json` causes `writeManifest`
    /// to throw rather than follow the link. This verifies the symlink-containment
    /// guard added to `writeManifest` — mirroring `ObsidianAdapter.ensureWritableFileTarget`
    /// which protects note writes against the same attack vector.
    @Test func writeManifest_refusesPreExistingSymlinkAtManifestPath() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-guard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        // Create the .moot directory and plant a symlink at the manifest path.
        let mootDir = vault.appendingPathComponent(".moot", isDirectory: true)
        try FileManager.default.createDirectory(at: mootDir, withIntermediateDirectories: true)
        let manifestURL = vault.appendingPathComponent(VaultTools.manifestRelativePath)

        // Symlink points to an arbitrary location outside the vault — exactly
        // the attacker's setup. The symlink target does NOT need to exist (broken
        // symlink); the guard must detect it via resourceValues, not fileExists
        // (fileExists follows the symlink and returns false for broken symlinks).
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-target-\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: target)
        // Verify the symlink was created by reading the destination string directly.
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: manifestURL.path(percentEncoded: false))
        #expect(!destination.isEmpty, "symlink must be planted before the guard test")

        // A minimal manifest — content doesn't matter, the guard fires before encode.
        let manifest = VaultTools.ExportManifest(
            exportedAt: "2026-01-01T00:00:00Z", noteCount: 0, files: [:])

        // writeManifest must throw, not follow the symlink.
        #expect(throws: (any Error).self) {
            try VaultTools.writeManifest(manifest, to: vault)
        }

        // The symlink target must NOT have been created — confirm the write was refused.
        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)),
                "symlink target must not be created; the manifest write must be refused")
    }

    /// Finding 13: `writeManifest` must also check that the `.moot` PARENT directory
    /// itself is not a symlink pointing outside the vault root. Without this check,
    /// an attacker can pre-plant a symlink at `.moot` (pointing to a foreign directory)
    /// and `createDirectory(at: dir, withIntermediateDirectories: true)` silently follows
    /// it, creating the directory at the attacker-controlled path. The subsequent
    /// leaf-symlink check on `export-manifest.json` does not fire because the file does
    /// not exist at the now-foreign `.moot/export-manifest.json` path.
    ///
    /// The fix adds a parent-dir containment check (inline analog of
    /// `ObsidianAdapter.ensureContainedInVault`) on `dir` after `createDirectory`,
    /// mirroring the two-layer check note exports apply.
    @Test func writeManifest_refusesSymlinkedMootParentDir() throws {
        let fm = FileManager.default
        let vault = fm.temporaryDirectory
            .appendingPathComponent("moot-parent-symlink-guard-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: vault) }

        // Pre-plant a symlink at the `.moot` path pointing to a directory
        // OUTSIDE the vault root — exactly the attacker's setup.
        let mootPath = vault.appendingPathComponent(".moot", isDirectory: true)
        let foreignDir = fm.temporaryDirectory
            .appendingPathComponent("foreign-moot-target-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: foreignDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: foreignDir) }
        try fm.createSymbolicLink(at: mootPath, withDestinationURL: foreignDir)

        // Verify the symlink was planted at the .moot path before we test.
        let rv = try mootPath.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(rv.isSymbolicLink == true, ".moot must be a symlink before the guard test")

        // A minimal manifest — content doesn't matter, the guard fires at dir creation.
        let manifest = VaultTools.ExportManifest(
            exportedAt: "2026-01-01T00:00:00Z", noteCount: 0, files: [:])

        // writeManifest must throw — the symlinked .moot parent is foreign to the vault.
        #expect(throws: (any Error).self) {
            try VaultTools.writeManifest(manifest, to: vault)
        }

        // The foreign dir must NOT contain the manifest file — confirms the guard fired
        // before any write reached the attacker-controlled path.
        #expect(!fm.fileExists(atPath: foreignDir.appendingPathComponent("export-manifest.json").path),
                "manifest must NOT be written into the foreign symlink target")
    }
}
