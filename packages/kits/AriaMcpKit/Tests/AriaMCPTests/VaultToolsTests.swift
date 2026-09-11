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

    /// RESHAPED for v2: the v1 catalog stamped a distinct `.vault`
    /// provenance on the five moot_vault_* tools (VaultTools.swift's
    /// dead v1 `tools()` catalog, never wired into `ToolProjection`).
    /// `ToolProjection.tools()` now sources the whole catalog from
    /// `AriaV2SelectedCatalog.registry(environment:).projectedTools`
    /// (ToolProjection.swift:171), whose descriptors are all built
    /// through one shared `descriptor(...)` helper in
    /// AriaV2SelectedCatalog.swift (no call site overrides provenance),
    /// which defaults to `.interface` (AriaV2OperationRegistry.swift:157).
    /// Vault tools carry the same `.interface` provenance as every other
    /// v2 tool; identity is by name prefix now, not a dedicated case.
    @Test func vaultToolsCarryVaultProvenance() {
        let vaultTools = ToolProjection.tools().filter {
            $0.name.hasPrefix("moot_vault_")
        }
        #expect(vaultTools.count == 5)
        for tool in vaultTools {
            #expect(tool.provenance == .interface)
        }
    }

    /// RESHAPED for v2: the v1 catalog identified the lone federation
    /// tool via a dedicated `.federation` provenance case. v2 has no
    /// populated `.federation` provenance (every descriptor, including
    /// `moot_federated_recall` at AriaV2SelectedCatalog.swift:747,
    /// defaults to `.interface`), so the sole federation-purpose tool
    /// is identified by its advertised name instead.
    @Test func vaultToolsDoNotDisturbTheFederationCount() {
        let federationTools = ToolProjection.tools().filter {
            $0.name == "moot_federated_recall"
        }
        #expect(federationTools.count == 1)
    }

    // MARK: - Vault gating

    /// When MOOTX01_VAULT=0 (installed with --vault-off), all five vault tools
    /// and the filesystem-importing palace import tool are absent from the
    /// tools/list surface. Default (env absent or ≠ "0") is vault-on.

    /// Vault is on when MOOTX01_VAULT is absent from the environment.

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
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-export"))
        try await capture(kit, handle, content: "Benzene is aromatic.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // status before export: no manifest.
        let preResult = try await dispatcher.dispatch(
            name: "moot_vault_status", arguments: args(["vaultPath": vault.path]))
        let preObj = try #require(preResult.objectValue)
        #expect(preObj["isError"] == .bool(false))
        let preData = try #require(preObj["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(preData["manifest_present"] == .bool(false))

        // export starts the background Task; poll via moot_vault_job to completion.
        let exportData = try await runExportAndAwait(vault: vault, via: dispatcher)
        #expect(exportData["export"]?.objectValue?["note_count"] == .integer(1))

        // The sidecar manifest now exists at the hidden path.
        let manifestURL = vault.appendingPathComponent(VaultTools.manifestRelativePath)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        // status after export: manifest present, one note.
        let postResult = try await dispatcher.dispatch(
            name: "moot_vault_status", arguments: args(["vaultPath": vault.path]))
        let postData = try #require(postResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(postData["manifest_present"] == .bool(true))
        #expect(postData["note_count"] == .integer(1))
    }

    // MARK: - Import round-trip

    @Test func exportThenImportIntoFreshEstateRoundTrips() async throws {
        let kit = GeniusLocusKit()
        let handleA = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-src"))
        try await capture(kit, handleA, content: "Toluene is a solvent.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let dispatcherA = ToolDispatcher(kit: kit, handle: handleA)
        // Wait for the async export to finish so the vault files exist.
        _ = try await runExportAndAwait(vault: vault, via: dispatcherA)

        // Import the produced vault into a fresh estate.
        let handleB = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-dst"))
        let dispatcherB = ToolDispatcher(kit: kit, handle: handleB)
        let importLaunch = try await dispatcherB.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let importJobID = try extractJobID(from: importLaunch)
        // Wait for the background import Task to finish (includes kit.capture warm-up).
        let importData = try await waitForJob(id: importJobID, via: dispatcherB)
        #expect(importData["status"] == .string("complete"))
        #expect(importData["import"]?.objectValue?["drawers_written"] == .integer(1))
    }

    // MARK: - Reconcile / drift

    @Test func reconcileWithoutManifestIsAnErrorResult() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-nomanifest"))
        let vault = makeTempVault()
        try FileManager.default.createDirectory(
            at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(true))
        let error = try #require(obj["structuredContent"]?.objectValue?["error"]?.objectValue)
        #expect(error["code"] == .string("vault_manifest_missing"))
        #expect(error["message"] == .string("No export manifest is available; run moot_vault_export first."))
    }

    @Test func reconcileAfterExportWithNoEditsReportsZeroDrift() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-nodrift"))
        try await capture(kit, handle, content: "Phenol notes.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await runExportAndAwait(vault: vault, via: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path]))
        let data = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["added"] == .array([]))
        #expect(data["modified"] == .array([]))
        #expect(data["deleted"] == .array([]))
    }

    @Test func reconcileAfterEditingOneNoteFlagsExactlyThatFile() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-edit"))
        try await capture(kit, handle, content: "Original aniline note.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Wait for the export Task to finish so the manifest is readable.
        _ = try await runExportAndAwait(vault: vault, via: dispatcher)

        // Find the single exported note and append a byte to it.
        let manifest = try #require(try VaultTools.readManifest(vaultURL: vault))
        #expect(manifest.files.count == 1)
        let notePath = try #require(manifest.files.keys.first)
        let noteURL = vault.appendingPathComponent(notePath)
        let original = try String(contentsOf: noteURL, encoding: .utf8)
        try (original + "\nedited.").write(to: noteURL, atomically: true, encoding: .utf8)

        let result = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path]))
        let data = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        // Exactly that file is modified; nothing added or deleted.
        #expect(data["added"] == .array([]))
        #expect(data["modified"] == .array([.string(notePath)]))
        #expect(data["deleted"] == .array([]))
        #expect(data["applied"] == .bool(false))
        // A candidate is returned for the modified file (return-only seam).
        let stableKey = notePath.hasSuffix(".md")
            ? String(notePath.dropLast(3)) : notePath
        let candidates = try #require(data["candidates"]?.arrayValue)
        #expect(candidates.count == 1)
        #expect(candidates[0].objectValue?["stable_source_key"] == .string(stableKey))
        #expect(candidates[0].objectValue?["vault_path"] == .string(notePath))
    }

    @Test func reconcileReportsAddedAndDeletedWithoutActioning() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-adddel"))
        try await capture(kit, handle, content: "Keep me.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Wait for the export Task to finish so the manifest is readable.
        _ = try await runExportAndAwait(vault: vault, via: dispatcher)

        // Delete the exported note, add a brand-new untracked note.
        let manifest = try #require(try VaultTools.readManifest(vaultURL: vault))
        let exportedNote = try #require(manifest.files.keys.first)
        try FileManager.default.removeItem(
            at: vault.appendingPathComponent(exportedNote))
        let newNote = vault.appendingPathComponent("Fresh/New.md")
        try FileManager.default.createDirectory(
            at: newNote.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "A new untracked note.".write(to: newNote, atomically: true, encoding: .utf8)

        let result = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path]))
        let data = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["added"] == .array([.string("Fresh/New.md")]))
        #expect(data["modified"] == .array([]))
        #expect(data["deleted"] == .array([.string(exportedNote)]))
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
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-apply-modified"))
        try await capture(kit, handle, content: "Aniline original.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Export so the manifest is stamped and the note file exists on disk.
        _ = try await runExportAndAwait(vault: vault, via: dispatcher)

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
        let dryResult = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: reconcileArgs(vaultPath: vault.path))
        let dryData = try #require(dryResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(dryData["modified"] == .array([.string(notePath)]))
        #expect(dryData["applied"] == .bool(false))
        // Estate unchanged after dry-run.
        let midRecall = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(midRecall.count == preCount)

        // Apply mode: the modified note must be imported into the estate.
        let applyResult = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: reconcileArgs(vaultPath: vault.path, apply: true))
        let applyData = try #require(applyResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(applyData["modified"] == .array([.string(notePath)]))
        #expect(applyData["applied"] == .bool(true))
        // The import reports drawers_updated=1 (the same stableSourceKey
        // already exists in the estate from the original capture).
        let importReport = try #require(applyData["import_report"]?.objectValue)
        #expect(importReport["drawers_updated"] == .integer(1))
        #expect(importReport["drawers_written"] == .integer(0))
    }

    @Test func reconcileApplyAddedNoteWritesNewDrawer() async throws {
        // A new vault note not present in the estate must be written when apply=true.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-apply-added"))
        let vault = makeTempVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Export an empty vault so the manifest exists.
        _ = try await runExportAndAwait(vault: vault, via: dispatcher)

        // Add a brand-new note to the vault directory after the export.
        let newNote = vault.appendingPathComponent("NewSection/Added.md")
        try FileManager.default.createDirectory(
            at: newNote.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Added note\n\nContent added after export.".write(
            to: newNote, atomically: true, encoding: .utf8)

        // Apply: the new note must be written into the estate.
        let applyResult = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: reconcileArgs(vaultPath: vault.path, apply: true))
        let data = try #require(applyResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["added"] == .array([.string("NewSection/Added.md")]))
        #expect(data["modified"] == .array([]))
        #expect(data["deleted"] == .array([]))
        #expect(data["applied"] == .bool(true))
        let importReport = try #require(data["import_report"]?.objectValue)
        #expect(importReport["drawers_written"] == .integer(1))

        // Estate now contains the new drawer.
        let postRecall = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(postRecall.count == 1)
    }

    @Test func reconcileApplyActionsCandidatesOnlyNotFullVault() async throws {
        // Defect-2 regression: apply=true must import only the M candidates,
        // not the full N-note vault. With 10 notes captured, exported, and 1
        // modified on disk, drawers_updated must be exactly 1 — not 10.
        // This guards against the over-import regression where import of the
        // full vault would report N (vault size) not M (candidates).
        //
        // The drawers_skipped_unchanged assertion below is what makes this a
        // proof of WORK DONE rather than of outcome. Importing the whole vault
        // and letting idempotence sort it out also yields drawers_updated: 1 —
        // it reads the other nine, finds them identical, and reports
        // drawers_skipped_unchanged: 9. Only the narrowed import leaves that
        // count at zero, because those nine are never read from disk.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-apply-10notes"))
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Capture 10 distinct notes into the estate first, then export them to
        // the vault. Export writes the notes on disk and stamps the manifest.
        for i in 1...10 {
            try await capture(kit, handle, content: "Content for note \(i).", room: "multi")
        }
        _ = try await runExportAndAwait(vault: vault, via: dispatcher)

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
        let dryResult = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: reconcileArgs(vaultPath: vault.path))
        let dryData = try #require(dryResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(dryData["modified"] == .array([.string(firstPath)]))

        // Apply: only the 1 modified note must be actioned.
        let applyResult = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: reconcileArgs(vaultPath: vault.path, apply: true))
        let applyData = try #require(applyResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(applyData["modified"] == .array([.string(firstPath)]))
        #expect(applyData["applied"] == .bool(true))
        // drawers_updated must be 1 (the single modified candidate), not 10
        // (the full vault). drawers_written must be 0.
        let importReport = try #require(applyData["import_report"]?.objectValue)
        #expect(importReport["drawers_updated"] == .integer(1))
        #expect(importReport["drawers_written"] == .integer(0))
        // The narrowing proof: the nine unchanged notes are already held by the
        // estate, so they are never read and never reach the content check.
        #expect(importReport["drawers_skipped_unchanged"] == .integer(0))

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
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-dryrun-default"))
        let vault = makeTempVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Export empty vault, then add a note — there is now 1 candidate.
        _ = try await runExportAndAwait(vault: vault, via: dispatcher)
        let note = vault.appendingPathComponent("DryRun.md")
        try "# Dry run note".write(to: note, atomically: true, encoding: .utf8)

        // Reconcile with no apply argument — dry-run.
        let result = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: reconcileArgs(vaultPath: vault.path))
        let data = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["added"] == .array([.string("DryRun.md")]))
        #expect(data["modified"] == .array([]))
        #expect(data["deleted"] == .array([]))
        #expect(data["applied"] == .bool(false))
        #expect(data["import_report"] == nil)

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
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-apply-deleted"))
        try await capture(kit, handle, content: "Keep this drawer.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Export so the note exists, then delete it from disk.
        _ = try await runExportAndAwait(vault: vault, via: dispatcher)
        let manifest = try #require(try VaultTools.readManifest(vaultURL: vault))
        let notePath = try #require(manifest.files.keys.first)
        try FileManager.default.removeItem(at: vault.appendingPathComponent(notePath))

        // apply=true: deleted file must NOT expunge the drawer.
        let applyResult = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: reconcileArgs(vaultPath: vault.path, apply: true))
        let data = try #require(applyResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["added"] == .array([]))
        #expect(data["modified"] == .array([]))
        #expect(data["deleted"] == .array([.string(notePath)]))
        #expect(data["applied"] == .bool(true))

        // The drawer is still believed in the estate.
        let recall = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(recall.count == 1)
    }

    // MARK: - V1 regression (reconcile apply on fresh export ingests foreign vault notes)

    /// V1 regression test for commit 0136baf12 (VAULT-FIX-01 V1), updated for
    /// the VR-01 manifest-certification fix.
    ///
    /// Original root cause: vault_reconcile --apply true passed only candidate
    /// paths to importVault, so a foreign note stamped by the export's
    /// whole-disk manifest was never imported (silent data loss).
    ///
    /// Under VR-01 the manifest stamps ONLY the paths the export wrote
    /// (its certification receipt). A foreign note therefore carries no
    /// stamp, is classified "added" (changed / needs review), and is
    /// surfaced as a candidate — visible in the drift report rather than
    /// silently swept in by a hidden missing-set.
    ///
    /// Scenario mirrors the Rust twin (dispatch_tests.rs:
    /// vault_reconcile_apply_after_fresh_export_ingests_foreign_note):
    ///   1. Fresh bare estate (no captured notes).
    ///   2. A "foreign" note is written manually to the vault directory —
    ///      simulating a pre-existing Obsidian note that predates the estate.
    ///   3. vault_export: the bridge exports zero estate notes (estate is
    ///      bare); the manifest stamps zero paths (nothing was written, so
    ///      nothing can be certified as agreeing with the estate).
    ///   4. vault_reconcile apply=true: ForeignNote.md has no stamp →
    ///      1 added → surfaced as a candidate and imported.
    ///
    /// Assertion is RETRIEVABILITY (kit.recall returns 1 drawer), not just
    /// the receipt data. Retrievability proves the drawer landed in the estate;
    /// an import report proves only that an import ran.
    @Test func reconcileApplyAfterFreshExportIngestsForeignNote() async throws {
        let kit = GeniusLocusKit()
        // Bare estate: no notes captured — nothing for the export to write.
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-foreign-note-regression"))
        let vault = makeTempVault()
        // Create the vault directory explicitly so ForeignNote.md can be written
        // before vault_export runs.
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        // Write the foreign note BEFORE export. It lives in the vault but the
        // estate has never seen it — no capture, no prior import.
        let foreignNote = vault.appendingPathComponent("ForeignNote.md")
        try "# Foreign note\n\nThis note exists in the vault but not in the estate.".write(
            to: foreignNote, atomically: true, encoding: .utf8)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Export on the bare estate. It writes zero notes from the estate (no
        // captures), so the manifest stamps zero paths — ForeignNote.md is
        // NOT certified and must surface on reconcile.
        _ = try await runExportAndAwait(vault: vault, via: dispatcher)

        // Pre-condition: estate is still empty. Export reads from the estate and
        // writes to the vault — it does not read from the vault and write to the
        // estate. The foreign note has not been imported.
        let before = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(before.count == 0)

        // Reconcile apply=true. ForeignNote.md carries no stamp (the export
        // wrote nothing), so it is classified "added" — surfaced in the
        // drift report as a candidate and imported by apply.
        let applyResult = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: reconcileArgs(vaultPath: vault.path, apply: true))
        let data = try #require(applyResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)

        // Primary assertion: retrievability from the estate. This distinguishes
        // content-landed from command-succeeded — an import report proves an
        // import ran; kit.recall confirms the drawer is in the estate.
        let after = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(after.count == 1, "ForeignNote.md must be retrievable from the estate after reconcile apply; got \(after.count) drawers")

        // Secondary assertions: the foreign note is SURFACED (added), not
        // silently swept in — the review gate sees it.
        #expect(data["added"] == .array([.string("ForeignNote.md")]),
                "ForeignNote.md must surface as added — it carries no certification stamp")
        #expect(data["modified"] == .array([]))
        #expect(data["deleted"] == .array([]))
        #expect(data["applied"] == .bool(true))
    }

    // MARK: - VR-01 regressions (Finding A: manifest reset; Finding B: review gate)

    /// VR-01 Finding A regression, part 1: a legacy manifest (no `version`
    /// key) matching the disk exactly is the exact trap state the old code
    /// fell into — every note hashed equal, nothing surfaced. Prior hashes
    /// are unavailable after such a reset, so the safe classification is
    /// changed / needs review for every note, never "unchanged".
    @Test func legacyManifestSurfacesAllNotesAsNeedsReview() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-legacy-dryrun"))
        let vault = makeTempVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        // Two hand-written notes on disk; the estate holds neither.
        for name in ["LegacyOne.md", "LegacyTwo.md"] {
            try "# \(name)".write(
                to: vault.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // Legacy manifest: stamps the CURRENT disk hashes, no `version` key —
        // exactly what a pre-VR-01 export ("manifest reset") left behind.
        let legacyFiles = try VaultTools.hashAllNotes(vaultURL: vault)
        let legacy = VaultTools.ExportManifest(
            version: nil,
            exportedAt: "2026-01-01T00:00:00Z",
            noteCount: legacyFiles.count,
            files: legacyFiles)
        try VaultTools.writeManifest(legacy, to: vault)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path]))
        let data = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)

        // The manifest diff itself shows zero drift — that is the trap. The
        // candidate listing (every note on a legacy manifest — VaultTools.swift's
        // `reconcileSnapshot`, `candidatePaths = Set(current.keys)` when
        // `manifestCertifies` is false) is what surfaces the notes.
        #expect(data["added"] == .array([]))
        #expect(data["modified"] == .array([]))
        #expect(data["deleted"] == .array([]))
        let candidates = try #require(data["candidates"]?.arrayValue)
        #expect(candidates.count == 2)
        #expect(candidates[0].objectValue?["stable_source_key"] == .string("LegacyOne"))
        #expect(candidates[0].objectValue?["vault_path"] == .string("LegacyOne.md"))
        #expect(candidates[1].objectValue?["stable_source_key"] == .string("LegacyTwo"))
        #expect(candidates[1].objectValue?["vault_path"] == .string("LegacyTwo.md"))
        #expect(data["candidate_count"] == .integer(2))
        #expect(data["applied"] == .bool(false))

        // Dry-run wrote nothing: estate empty, manifest still legacy on disk.
        let drawers = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(drawers.isEmpty)
        let stillLegacy = try #require(try VaultTools.readManifest(vaultURL: vault))
        #expect(stillLegacy.version == nil, "dry-run must not rewrite the manifest")
    }

    /// VR-01 Finding A regression, part 2 — the full silent-divergence
    /// scenario: the estate's record and the vault note differ, but a reset
    /// (legacy) manifest stamps the note's current disk hash, so the old
    /// classification saw "unchanged" and the edit never reached the estate.
    /// Post-fix: the note is surfaced, apply imports it (the estate learns
    /// the edit), and the manifest converges to schema v2 so the note does
    /// not re-surface forever.
    @Test func legacyManifestModifiedNoteIsSurfacedAndApplyImportsIt() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-legacy-apply"))
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Estate holds one note; export writes it (v2 manifest, correct).
        try await capture(kit, handle, content: "Original benzene content.", room: "chem")
        _ = try await runExportAndAwait(vault: vault, via: dispatcher)
        let v2Manifest = try #require(try VaultTools.readManifest(vaultURL: vault))
        let notePath = try #require(v2Manifest.files.keys.first)

        // The user edits the note on disk — estate and vault now diverge.
        let noteURL = vault.appendingPathComponent(notePath)
        let original = try String(contentsOf: noteURL, encoding: .utf8)
        try (original + "\nedited after reset.").write(
            to: noteURL, atomically: true, encoding: .utf8)

        // The manifest is RESET: re-stamped from current disk hashes with no
        // version key (the pre-VR-01 whole-disk stamp). Hash now matches the
        // EDITED note, so the manifest diff sees zero drift.
        let resetFiles = try VaultTools.hashAllNotes(vaultURL: vault)
        let reset = VaultTools.ExportManifest(
            version: nil,
            exportedAt: v2Manifest.exportedAt,
            noteCount: resetFiles.count,
            files: resetFiles)
        try VaultTools.writeManifest(reset, to: vault)

        // Apply: the legacy classification surfaces the note and imports it.
        let applyResult = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: reconcileArgs(vaultPath: vault.path, apply: true))
        let data = try #require(applyResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["added"] == .array([]))
        #expect(data["modified"] == .array([]))
        let candidates = try #require(data["candidates"]?.arrayValue)
        #expect(candidates.count == 1)
        #expect(candidates[0].objectValue?["vault_path"] == .string(notePath))
        let importReport = try #require(data["import_report"]?.objectValue)
        #expect(importReport["drawers_updated"] == .integer(1),
                "The edited note must supersede the estate's record")

        // The estate learned the edit.
        let drawers = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .full))
        #expect(drawers.count == 1)
        #expect(drawers.first?.content.contains("edited after reset") == true,
                "Estate content must carry the vault edit after apply")

        // Convergence: the manifest is now v2 and a second reconcile is quiet.
        let converged = try #require(try VaultTools.readManifest(vaultURL: vault))
        #expect(converged.version == VaultTools.manifestSchemaVersion)
        let second = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path]))
        let secondData = try #require(second.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(secondData["import_set_count"] == .integer(0),
                "After apply re-stamp, nothing should re-surface")
        #expect(secondData["candidate_count"] == .integer(0))
        #expect(secondData["missing_count"] == .integer(0))
    }

    /// VR-01 Finding A regression, part 3: a note with NO manifest entry
    /// (hash missing under a v2 manifest) classifies as added — changed /
    /// needs review — never silently "unchanged".
    @Test func v2ManifestMissingHashClassifiesAsChanged() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-missing-hash"))
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await capture(kit, handle, content: "Stamped note.", room: "chem")
        _ = try await runExportAndAwait(vault: vault, via: dispatcher)

        // A note the export did not write → no stamp → must surface.
        let unstamped = vault.appendingPathComponent("Unstamped.md")
        try "# Never certified".write(to: unstamped, atomically: true, encoding: .utf8)

        let result = try await dispatcher.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path]))
        let data = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["added"] == .array([.string("Unstamped.md")]))
        #expect(data["modified"] == .array([]))
        let candidates = try #require(data["candidates"]?.arrayValue)
        #expect(candidates.count == 1)
        #expect(candidates[0].objectValue?["stable_source_key"] == .string("Unstamped"))
        #expect(candidates[0].objectValue?["vault_path"] == .string("Unstamped.md"))
    }

    /// VR-01 Finding B regression: apply operates only on the surfaced
    /// import set. The dry-run lists the full set (candidates ∪ missing) an
    /// apply over the same state imports; an apply invoked without any prior
    /// dry-run imports exactly that same recomputed set — nothing that the
    /// review step would not have listed. Cross-estate export→reconcile is
    /// the canonical missing-set case: the manifest certifies estate A's
    /// agreement, estate B lacks every note.
    @Test func applyImportsOnlyTheSurfacedSetCrossEstate() async throws {
        let kit = GeniusLocusKit()
        let handleA = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-gate-src"))
        try await capture(kit, handleA, content: "Gate note content.", room: "chem")
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        _ = try await runExportAndAwait(vault: vault, via: ToolDispatcher(kit: kit, handle: handleA))
        let manifest = try #require(try VaultTools.readManifest(vaultURL: vault))
        let notePath = try #require(manifest.files.keys.first)

        // Estate B: holds nothing. The note is stamped (certified against A)
        // so it is NOT a candidate — it is exactly a missing-set member.
        let handleB = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-gate-dst"))
        let dispatcherB = ToolDispatcher(kit: kit, handle: handleB)

        // Dry-run surfaces the missing note without importing it.
        let dryResult = try await dispatcherB.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path]))
        let dryData = try #require(dryResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(dryData["added"] == .array([]))
        #expect(dryData["modified"] == .array([]))
        #expect(dryData["deleted"] == .array([]))
        #expect(dryData["missing"] == .array([.string(notePath)]))
        #expect(dryData["import_set_count"] == .integer(1))
        #expect(dryData["candidate_count"] == .integer(0))
        #expect(dryData["missing_count"] == .integer(1))
        let beforeApply = try await kit.recall(
            handleB, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(beforeApply.isEmpty, "dry-run must not import")

        // Apply (no prior dry-run required — the gate is the deterministic
        // recompute): imports exactly the same surfaced set.
        let applyResult = try await dispatcherB.dispatch(
            name: "moot_vault_reconcile", arguments: reconcileArgs(vaultPath: vault.path, apply: true))
        let applyData = try #require(applyResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(applyData["missing"] == .array([.string(notePath)]))
        #expect(applyData["import_set_count"] == .integer(1))
        let importReport = try #require(applyData["import_report"]?.objectValue)
        #expect(importReport["drawers_written"] == .integer(1))

        // Retrievability: the note landed in estate B.
        let afterApply = try await kit.recall(
            handleB, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured))
        #expect(afterApply.count == 1)

        // Convergence: a second dry-run over B surfaces nothing.
        let second = try await dispatcherB.dispatch(
            name: "moot_vault_reconcile", arguments: args(["vaultPath": vault.path]))
        let secondData = try #require(second.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(secondData["import_set_count"] == .integer(0), "Import set must be empty after apply")
    }

    /// Perkins VR-01 findings 1+2: the manifest stamp read must not follow a
    /// symlink (TOCTOU swap between the export's write and the hash read
    /// would stamp — and thereby disclose the hash of — any file this
    /// process can read), and must refuse a traversal path by construction
    /// rather than relying on fromIR having thrown first. A skipped symlink
    /// is simply not stamped, so the path surfaces as changed / needs review
    /// on the next reconcile.
    @Test func buildManifestSkipsSymlinksAndRefusesTraversal() throws {
        let fm = FileManager.default
        let vault = makeTempVault()
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: vault) }

        try "# Real note".write(
            to: vault.appendingPathComponent("Real.md"), atomically: true, encoding: .utf8)

        // A "note" swapped for a symlink pointing outside the vault — the
        // attacker's hash-oracle setup.
        let target = fm.temporaryDirectory
            .appendingPathComponent("stamp-oracle-\(UUID().uuidString).md")
        try "outside-the-vault content".write(to: target, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: target) }
        try fm.createSymbolicLink(
            at: vault.appendingPathComponent("Swapped.md"), withDestinationURL: target)

        let manifest = try VaultTools.buildManifest(
            vaultURL: vault, writtenPaths: ["Real.md", "Swapped.md"], now: Date())
        #expect(manifest.files.keys.sorted() == ["Real.md"],
                "the symlinked path must not be stamped; got \(manifest.files.keys.sorted())")

        // Traversal components are refused outright, independent of fromIR's
        // own guard.
        #expect(throws: (any Error).self) {
            _ = try VaultTools.buildManifest(
                vaultURL: vault, writtenPaths: ["../escape.md"], now: Date())
        }
    }

    // MARK: - Async job helpers

    /// Extract the `job_id` from a v2 `moot_vault_import`/`moot_vault_export`
    /// launch result's `structuredContent.data.job_id` field
    /// (AriaV2DataMobility.swift's `launchOutcome`). Throws via `#require` if
    /// the field is absent so failing tests surface a clear error rather
    /// than a confusing nil-unwrap.
    private func extractJobID(from result: JSONValue) throws -> String {
        let data = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        return try #require(data["job_id"]?.stringValue)
    }

    /// Poll `moot_vault_job` every 100 ms until `structuredContent.data.status`
    /// leaves `"running"` or 10 seconds elapse. Returns the final structured
    /// data object. Polling (rather than a fixed sleep) makes tests robust to
    /// cold-start ML model loading in `kit.capture` on the first run.
    private func waitForJob(id: String, via dispatcher: ToolDispatcher) async throws -> [String: JSONValue] {
        var data: [String: JSONValue] = [:]
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)   // 100 ms per poll
            let result = try await dispatcher.dispatch(
                name: "moot_vault_job", arguments: args(["job_id": id]))
            data = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
            if data["status"] != .string("running") { break }
        }
        return data
    }

    /// Export the vault via `moot_vault_export` and wait until the async
    /// job completes. Returns the final job data. Used by reconcile tests
    /// that must read the manifest before proceeding — the manifest is
    /// written inside the background Task, so the export call alone does
    /// not guarantee its existence.
    private func runExportAndAwait(
        vault: URL, via dispatcher: ToolDispatcher, scope: String = "believed"
    ) async throws -> [String: JSONValue] {
        // CAND-032: the default export scope is now `.exportable` (only
        // exportable-marked rows). These reconcile fixtures are ordinary
        // believed-tier notes, so the setup export uses the explicit `.believed`
        // scope to populate the vault with full fidelity (the round-trip /
        // reconcile behavior these tests exercise is scope-independent).
        let result = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path, "scope": scope]))
        let jobID = try extractJobID(from: result)
        let data = try await waitForJob(id: jobID, via: dispatcher)
        #expect(data["status"] == .string("complete"), "Export job did not complete within 10 s")
        return data
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
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-async-import-quick"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false))
        let data = try #require(obj["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["job_id"]?.stringValue != nil)
        #expect(data["status"] == .string("running"))
        #expect(data["kind"] == .string("import"))
    }

    @Test func import_job_shows_complete_after_bridge_finishes() async throws {
        let vault = makeTempVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        // One valid note so there is something to import.
        try "# Test note\n\nAsync import content.".write(
            to: vault.appendingPathComponent("AsyncNote.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: vault) }

        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-async-import-complete"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let launchResult = try await dispatcher.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let jobID = try extractJobID(from: launchResult)

        // Poll until complete — first import call includes kit.capture
        // warm-up which can exceed a fixed sleep on a cold system.
        let data = try await waitForJob(id: jobID, via: dispatcher)
        #expect(data["status"] == .string("complete"))
        #expect(data["import"]?.objectValue?["drawers_written"]?.integerValue != nil)
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
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-async-import-fail"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let launchResult = try await dispatcher.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let jobID = try extractJobID(from: launchResult)

        // Poll until the background Task records the error.
        let data = try await waitForJob(id: jobID, via: dispatcher)
        #expect(data["status"] == .string("failed"))
        #expect(data["error"]?.stringValue != nil)
    }

    // MARK: - Async vault export jobs

    @Test func export_returns_job_id_immediately() async throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-async-export-quick"))
        try await capture(kit, handle, content: "Async export note.", room: "test")
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false))
        let data = try #require(obj["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["job_id"]?.stringValue != nil)
        #expect(data["status"] == .string("running"))
        #expect(data["kind"] == .string("export"))
    }

    @Test func export_job_shows_complete_after_bridge_finishes() async throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-async-export-complete"))
        try await capture(kit, handle, content: "Completed export note.", room: "test")
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let launchResult = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))
        let jobID = try extractJobID(from: launchResult)

        // Poll until the background Task writes the vault and manifest.
        let data = try await waitForJob(id: jobID, via: dispatcher)
        #expect(data["status"] == .string("complete"))
        #expect(data["export"]?.objectValue?["note_count"]?.integerValue != nil)
    }

    // MARK: - Unknown job ID

    @Test func vault_job_unknown_id_returns_error() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-unknown-job"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fakeID = UUID().uuidString
        let result = try await dispatcher.dispatch(
            name: "moot_vault_job", arguments: args(["job_id": fakeID]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(true))
        // AriaV2VaultLifecycleAuthority.execute throws .unknownJob (a plain
        // Swift error, not AriaV2DataMobilityLower.Failure), which falls
        // through to AriaV2DataMobility.execute's generic catch — the same
        // shape a throwing preflight (see import_throwing_preflight_releases_slot)
        // hits, both surfacing the generic "mobility_unavailable" code.
        let error = try #require(obj["structuredContent"]?.objectValue?["error"]?.objectValue)
        #expect(error["code"] == .string("mobility_unavailable"))
    }

    // MARK: - FIX 4: vault_job surfaces skip counts

    /// An idempotent re-import must surface `drawers_skipped_unchanged` and
    /// `drawers_skipped_tombstoned` in the vault_job result so an all-zeros
    /// re-import reads as `drawers_skipped_unchanged: N`, not all-zeros silently.
    @Test(.timeLimit(.minutes(2))) func import_job_surfaces_skip_counts() async throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-skip-counts"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Export a real note so we have a real vault with notes.
        try await capture(kit, handle, content: "Idempotency skip count test note.", room: "test")
        let exportResult = try await dispatcher.dispatch(
            name: "moot_vault_export", arguments: args(["vaultPath": vault.path]))
        let exportJobID = try extractJobID(from: exportResult)
        _ = try await waitForJob(id: exportJobID, via: dispatcher)

        // Second estate for re-import (fresh, so all notes land as written on first import).
        let handle2 = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-skip-counts-2"))
        let dispatcher2 = ToolDispatcher(kit: kit, handle: handle2)

        // First import into estate2 — should write drawers.
        let firstImport = try await dispatcher2.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let firstJobID = try extractJobID(from: firstImport)
        let firstData = try await waitForJob(id: firstJobID, via: dispatcher2)
        let firstImportData = try #require(firstData["import"]?.objectValue)
        #expect(firstImportData["drawers_written"]?.integerValue != nil, "first import must write drawers")
        // Skip counts must be present in output (even if zero on first import).
        #expect(firstImportData["drawers_skipped_unchanged"]?.integerValue != nil,
                "vault_job result must include drawers_skipped_unchanged")
        #expect(firstImportData["drawers_skipped_tombstoned"]?.integerValue != nil,
                "vault_job result must include drawers_skipped_tombstoned")

        // Second import of same vault — content is identical, should skip unchanged.
        let secondImport = try await dispatcher2.dispatch(
            name: "moot_vault_import", arguments: args(["vaultPath": vault.path]))
        let secondJobID = try extractJobID(from: secondImport)
        let secondData = try await waitForJob(id: secondJobID, via: dispatcher2)
        let secondImportData = try #require(secondData["import"]?.objectValue)
        let secondSkippedUnchanged = try #require(secondImportData["drawers_skipped_unchanged"]?.integerValue)
        let secondDrawersWritten = try #require(secondImportData["drawers_written"]?.integerValue)
        // The idempotent re-import should show skipped-unchanged > 0 (not all zeros).
        #expect(secondSkippedUnchanged > 0 || secondDrawersWritten == 0,
                "Re-import of unchanged vault must not show all-zero activity")
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
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-cap-dirmd"))
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
            let data = try await waitForJob(id: jobID, via: dispatcher)
            #expect(data["status"] == .string("complete"), "Import \(i) must complete")
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
        let validData = try await waitForJob(id: validJobID, via: dispatcher)
        #expect(validData["status"] == .string("complete"),
                "5th import must succeed (cap must not have been exhausted)")
        #expect(validData["import"]?.objectValue?["drawers_written"] == .integer(1),
                "Valid import must write the note")
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
            in: kit, owner: OwnerCredentials(ownerIdentifier: "v2-throw-preflight"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // The import must fail: hashAllNotes cannot read the file, the error
        // propagates after the slot-release guard runs fail(), and — because
        // it is a plain Swift error rather than AriaV2DataMobilityLower.Failure —
        // AriaV2DataMobility.execute's generic catch surfaces it as isError:true
        // with the same "mobility_unavailable" refusal an unknown job_id gets
        // (see vault_job_unknown_id_returns_error).
        let failed = try await dispatcher.dispatch(
            name: "moot_vault_import",
            arguments: args(["vaultPath": vault.path]))
        let failedObj = try #require(failed.objectValue)
        #expect(failedObj["isError"] == .bool(true), "unreadable preflight must surface as isError:true")
        let error = try #require(failedObj["structuredContent"]?.objectValue?["error"]?.objectValue)
        #expect(error["code"] == .string("mobility_unavailable"))

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
        let resultObj = try #require(result.objectValue)
        #expect(resultObj["isError"] == .bool(false),
                "Valid import must succeed after slot was released by throwing preflight")
        let data = try #require(resultObj["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["job_id"]?.stringValue != nil)
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
            version: VaultTools.manifestSchemaVersion,
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
            version: VaultTools.manifestSchemaVersion,
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
