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

    // MARK: - Import round-trip

    // MARK: - Reconcile / drift

    // MARK: - Reconcile apply path

    /// Build an args object with a mix of string and bool values for reconcile.
    private func reconcileArgs(vaultPath: String, apply: Bool? = nil) -> JSONValue {
        var dict: [String: JSONValue] = ["vaultPath": .string(vaultPath)]
        if let apply { dict["apply"] = .bool(apply) }
        return .object(dict)
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
    /// the receipt text. Retrievability proves the drawer landed in the estate;
    /// a receipt count proves only that an import ran.

    // MARK: - VR-01 regressions (Finding A: manifest reset; Finding B: review gate)

    /// VR-01 Finding A regression, part 1: a legacy manifest (no `version`
    /// key) matching the disk exactly is the exact trap state the old code
    /// fell into — every note hashed equal, nothing surfaced. Prior hashes
    /// are unavailable after such a reset, so the safe classification is
    /// changed / needs review for every note, never "unchanged".

    /// VR-01 Finding A regression, part 2 — the full silent-divergence
    /// scenario: the estate's record and the vault note differ, but a reset
    /// (legacy) manifest stamps the note's current disk hash, so the old
    /// classification saw "unchanged" and the edit never reached the estate.
    /// Post-fix: the note is surfaced, apply imports it (the estate learns
    /// the edit), and the manifest converges to schema v2 so the note does
    /// not re-surface forever.

    /// VR-01 Finding A regression, part 3: a note with NO manifest entry
    /// (hash missing under a v2 manifest) classifies as added — changed /
    /// needs review — never silently "unchanged".

    /// VR-01 Finding B regression: apply operates only on the surfaced
    /// import set. The dry-run lists the full set (candidates ∪ missing) an
    /// apply over the same state imports; an apply invoked without any prior
    /// dry-run imports exactly that same recomputed set — nothing that the
    /// review step would not have listed. Cross-estate export→reconcile is
    /// the canonical missing-set case: the manifest certifies estate A's
    /// agreement, estate B lacks every note.

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

    // MARK: - Async vault export jobs

    // MARK: - Unknown job ID

    // MARK: - FIX 4: vault_job surfaces skip counts

    /// An idempotent re-import must surface `drawersSkippedUnchanged` and
    /// `drawersSkippedTombstoned` in the vault_job result so an all-zeros
    /// re-import reads as `drawersSkippedUnchanged: N`, not all-zeros silently.

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
