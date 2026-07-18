// VaultTools.swift
//
// The VaultKit control surface on ARIA_MCP — the `moot_vault_*` tool
// family that exposes VaultKit's `VaultBridge` (export / import / status)
// plus drift detection (`moot_vault_reconcile`) and a candidate-enqueue
// seam. Same dispatch shape as LensTools/RecipeTools:
// matched by name ABOVE the lexicon projection (these tools have no
// (verb, noun) pair, so `parseToolName` would reject them).
//
// ## Shipped MCP binary
//
// The shipped MCP binary is the Swift port (`mootx01`, built from
// `apps/mootx01` via `swift build`). The Rust `aria-mcp` bin (`apps/aria-mcp-server/rust/`)
// is a parity sibling; both ports are live and in sync (see ADR-VAULTKIT-002,
// and the new ADR recorded in cp-vault-bidir which documents that the Rust
// mirror has landed). The `moot_vault_*` tools are wired in both dispatch
// surfaces.
//
// ## Drift detection owns its own hash stamp
//
// VaultKit's export stamps NO per-note content hash: `DrawerMapping`
// writes no hash frontmatter key, and `NoteIR.Attachment.contentHash` is
// attachment-only and unused on note export. So this layer owns the
// hash. `moot_vault_export` writes a sidecar manifest at
// `.moot/export-manifest.json` inside the vault — a hidden directory, so
// `ObsidianAdapter`'s `.skipsHiddenFiles` enumerator never mis-reads it
// as a note on re-import. The manifest maps each note's vault-relative
// path to its SHA-256 at export time. SHA-256 (CryptoKit, an Apple
// system framework already used across the repo) is the file-IDENTITY
// hash — exact content-change detection — not a semantic fingerprint;
// the substrate's SimHash/Fingerprint primitives answer a different
// question and are not what drift needs.

import Foundation
import CryptoKit
import GeniusLocusKit
import LocusKit
import PersistenceKit
import VaultKit

/// Namespace for the vault tool surface. No instances.
enum VaultTools {

    // MARK: - Tool names

    /// The five `moot_vault_*` stems, dispatched by name above the
    /// lexicon projection.
    static let vaultToolNames: Set<String> = [
        "moot_vault_export", "moot_vault_import",
        "moot_vault_status", "moot_vault_reconcile",
        "moot_vault_job",
    ]

    /// True when `name` is one of the vault tools dispatched by name.
    static func isVaultTool(_ name: String) -> Bool {
        vaultToolNames.contains(name)
    }

    // MARK: - Export manifest (the drift stamp this layer owns)

    /// Vault-relative path of the sidecar export manifest. The `.moot`
    /// directory is hidden, so `ObsidianAdapter.toIR` (which enumerates
    /// with `.skipsHiddenFiles`) never reads the manifest as a note.
    static let manifestRelativePath = ".moot/export-manifest.json"

    /// One file's stamp: its SHA-256 content hash at export time.
    struct ManifestEntry: Codable, Sendable, Equatable {
        let sha256: String
    }

    /// The sidecar manifest `moot_vault_export` writes after a successful
    /// bridge export. `reconcile` diffs current file hashes against
    /// `files`; `status` reports the header.
    struct ExportManifest: Codable, Sendable, Equatable {
        /// ISO8601 instant the export ran. Display / status only; not part
        /// of the drift compare.
        let exportedAt: String
        /// Note count at export (`== files.count`). Carried for the status
        /// summary so it needs no re-enumeration.
        let noteCount: Int
        /// Vault-relative path (forward slashes, e.g. `Chem/Aromatics.md`)
        /// → content stamp.
        let files: [String: ManifestEntry]
    }

    // MARK: - tools/list projection

    static func tools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_vault_export",
                description: "Project a MOOT estate to a Markdown vault (drawers → notes, reference tunnels → wikilinks) and stamp a drift manifest.",
                inputSchema: objectSchema(
                    properties: [
                        "vaultPath": vaultPathSchema,
                        "estateID": estateIDSchema,
                        "scope": scopeSchema,
                    ],
                    required: ["vaultPath"]),
                provenance: .vault),
            ProjectedTool(
                name: "moot_vault_import",
                description: "Import a Markdown vault into a MOOT estate via the capture seam. Returns a job_id immediately — the import runs in the background and takes approximately 2 seconds per document. A 100-note vault takes ~3 minutes; a 500-note vault takes ~17 minutes. Do NOT cancel or re-issue an import because it appears slow — it is working. Poll with moot_vault_job to check progress. Duplicate imports are idempotent but waste time.",
                inputSchema: objectSchema(
                    properties: [
                        "vaultPath": vaultPathSchema,
                        "estateID": estateIDSchema,
                        "mode": stringSchema("Optional encode SPEED for the background encoding that follows the import: \"foreground\" (default) drains the encode queue hard; \"background\" yields for very large vaults. SPEED only — the write strategy (bulk transaction vs per-item stream) is chosen automatically by source size, not by this argument. Omit to use the default (foreground)."),
                    ],
                    required: ["vaultPath"]),
                provenance: .vault),
            ProjectedTool(
                name: "moot_vault_status",
                description: "Report whether a vault carries an export manifest, and if so its note count and last-export time. Reads the filesystem only; mutates nothing.",
                inputSchema: objectSchema(
                    properties: [
                        "vaultPath": vaultPathSchema,
                    ],
                    required: ["vaultPath"]),
                provenance: .vault),
            ProjectedTool(
                name: "moot_vault_reconcile",
                description: """
                Re-hash a vault's notes and report drift (added / modified / deleted) vs the export \
                manifest. Dry-run by default: returns candidates and writes nothing. Pass apply=true \
                to action the added and modified candidates by importing them into the estate \
                synchronously — completing the reconcile workflow. Deleted files are always reported \
                only; no drawer is expunged by this tool.
                """,
                inputSchema: objectSchema(
                    properties: [
                        "vaultPath": vaultPathSchema,
                        "estateID": estateIDSchema,
                        "apply": applySchema,
                    ],
                    required: ["vaultPath"]),
                provenance: .vault),
            ProjectedTool(
                name: "moot_vault_job",
                description: "Poll the status and result of a vault import or export job started by moot_vault_import or moot_vault_export. Returns status (running / complete / failed), elapsed_s, and on completion the result counts or error description.",
                inputSchema: objectSchema(
                    properties: [
                        "job_id": jobIDSchema,
                    ],
                    required: ["job_id"]),
                provenance: .vault),
        ]
    }

    private static var jobIDSchema: JSONValue {
        stringSchema("Job ID returned by moot_vault_import or moot_vault_export.")
    }

    // MARK: - Dispatch

    /// Run the named vault tool. Same contract as `LensTools.dispatch`:
    /// out-of-band faults (missing `vaultPath` or `job_id`, malformed
    /// `estateID`) throw `JSONRPCError`; everything else returns a result.
    ///
    /// `moot_vault_import` and `moot_vault_export` return a `job_id`
    /// immediately and run the bridge in a background `Task`. Poll with
    /// `moot_vault_job` to retrieve the outcome.
    static func dispatch(
        name: String,
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        defaultHandle: EstateHandle,
        resolveHandle: ([String: JSONValue]) throws -> EstateHandle,
        jobRegistry: VaultJobRegistry,
        environment: [String: String]
    ) async throws -> JSONValue {
        // Guard: vault surface is disabled (installed with --vault-off).
        // Return a clear refusal rather than an opaque failure. The tool
        // should never be called when disabled (it is absent from tools/list),
        // but the guard ensures a clean error if a client hard-codes the name.
        // MOOTX01_VAULT env var: absent/≠"0" = enabled; "0" = disabled (ADR-015).
        guard ToolProjection.vaultEnabled(environment: environment) else {
            return ToolDispatcher.errorResult(
                "vault is disabled; reinstall with mootx01 install --vault-on to enable import/export"
            )
        }

        // moot_vault_job only needs a job_id — no vaultPath.
        if name == "moot_vault_job" {
            let jobID = try requireString(args, "job_id")
            return await runJob(jobID: jobID, registry: jobRegistry)
        }

        // All remaining vault tools require vaultPath.
        let vaultURL = URL(
            fileURLWithPath: try requireString(args, "vaultPath"), isDirectory: true)

        switch name {
        case "moot_vault_export":
            // export/import target an estate, resolved through the
            // dispatcher's own registry exactly like the lexicon tools.
            // Parse the optional scope string; default to .believed.
            let scope = try parseScope(args["scope"])
            return try await runExport(
                kit: kit, handle: try resolveHandle(args), vaultURL: vaultURL,
                scope: scope, jobRegistry: jobRegistry)

        case "moot_vault_import":
            // mode = encode SPEED (foreground default); the WRITE strategy (bulk
            // vs per-item stream) is size-gated automatically (ImportPolicy), not
            // chosen here. Fail-closed on an unknown value.
            let modeStr = (args["mode"]?.stringValue ?? "foreground").lowercased()
            let importMode: EncodeSpeed
            switch modeStr {
            case "foreground": importMode = .foreground
            case "background": importMode = .background
            default:
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "mode must be \"foreground\" or \"background\"; omit it to use the default (foreground)")
            }
            return try await runImport(
                kit: kit, handle: try resolveHandle(args), vaultURL: vaultURL,
                mode: importMode, jobRegistry: jobRegistry)

        case "moot_vault_status":
            // status reads only the filesystem — no estate is consulted,
            // so it takes no estateID.
            return try runStatus(vaultURL: vaultURL)

        case "moot_vault_reconcile":
            // `apply` is optional — absent or false means dry-run.
            let apply = args["apply"]?.boolValue ?? false
            return try await runReconcile(
                kit: kit, handle: try resolveHandle(args),
                vaultURL: vaultURL, apply: apply, now: Date())

        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown vault tool: \(name)")
        }
    }

    // MARK: - Handlers

    /// Register a vault export job and immediately return its `job_id`.
    ///
    /// The bridge export and manifest stamp run in an unstructured `Task`
    /// so the MCP channel is freed before the bridge finishes — critical
    /// for vaults large enough to exceed the MCP timeout. All captured
    /// values (`VaultBridge` struct Sendable, `EstateHandle` Sendable,
    /// `VaultExportScope` enum Sendable, `URL` struct Sendable,
    /// `VaultJobRegistry` actor Sendable) satisfy Swift 6 task-capture
    /// requirements. `Date()` inside the Task samples the real export
    /// instant (a wall-clock event, not a deterministic computation —
    /// same precedent as `LensTools` sampling `Date()` for manifests).
    /// Maximum number of vault jobs (import or export) that may run concurrently.
    ///
    /// Each vault job spawns an unstructured Task that performs potentially
    /// expensive filesystem and estate work. Without a cap an attacker with
    /// access to the local MCP server can issue back-to-back vault calls to
    /// exhaust memory and I/O bandwidth. Four concurrent jobs is generous for
    /// any legitimate single-user workflow; the cap is checked against the live
    /// running-job count before registration so it is enforced per-process.
    private static let maxConcurrentVaultJobs = 4

    private static func runExport(
        kit: GeniusLocusKit, handle: EstateHandle, vaultURL: URL,
        scope: VaultExportScope = .exportable,
        jobRegistry: VaultJobRegistry
    ) async throws -> JSONValue {
        // Atomic cap-check-and-register: a single actor turn enforces the cap
        // and inserts the job record. Using two separate actor calls
        // (runningJobCount then register) had a TOCTOU window — concurrent
        // launches could all pass the guard before any registered, exceeding
        // the cap. checkAndRegister closes that window.
        let jobID = try await jobRegistry.checkAndRegister(
            kind: .`export`, vaultPath: vaultURL.path, maxJobs: maxConcurrentVaultJobs)

        let bridge = VaultBridge(kit: kit)
        let capturedScope = scope

        Task {
            do {
                // `now: Date()` samples the export instant at the access
                // surface (the deterministic bridge stamps it on the audit
                // receipt). The returned ExportReport's note count is also
                // available from the manifest below; tier-exclusion counts
                // surface via the receipt in the estate diary.
                let capturedJobID = jobID
                let capturedRegistry = jobRegistry
                _ = try await bridge.export(
                    estate: handle, to: vaultURL, scope: capturedScope, now: Date(),
                    progress: { processed, total in
                        Task { await capturedRegistry.updateProgress(
                            jobID: capturedJobID, processed: processed, total: total) }
                    })
                let manifest = try VaultTools.buildManifest(vaultURL: vaultURL, now: Date())
                try VaultTools.writeManifest(manifest, to: vaultURL)
                // Export companion CSVs for dataset handles (MX-TAB-7b §6).
                // Non-fatal — CSV export failures are silently collected so a broken
                // DatasetStore never prevents the vault export from completing.
                // Warnings are not surfaced in the async response (a future
                // job-result extension can add datasetsExported).
                _ = await VaultTools.exportDatasetCSVs(
                    vaultURL: vaultURL, kit: kit, handle: handle)
                await jobRegistry.complete(
                    jobID: jobID,
                    result: .exported(ExportResult(
                        noteCount: manifest.noteCount,
                        exportedAt: manifest.exportedAt)))
            } catch {
                await jobRegistry.fail(jobID: jobID, errorMsg: error.localizedDescription)
            }
        }

        return ToolDispatcher.textResult("""
        job_id: \(jobID)
        vault: \(vaultURL.path)
        scope: \(capturedScope.rawValue)
        poll: moot_vault_job to check status
        """)
    }

    /// Register a vault import job and immediately return its `job_id`.
    ///
    /// The cap (`checkAndRegister`) is acquired BEFORE `hashAllNotes` so
    /// concurrent expensive preflight work is bounded to `maxConcurrentVaultJobs`.
    /// Running `hashAllNotes` outside the cap defeated its purpose: up to the
    /// HTTP transport concurrency limit worth of filesystem traversal + full-file
    /// reads + SHA-256 hashing could run simultaneously before the cap was consulted.
    ///
    /// If `hashAllNotes` throws after the slot is acquired (e.g. permission-denied
    /// on a regular `.md` file), `jobRegistry.fail(jobID:)` releases the slot so it
    /// is never permanently consumed. The background `Task`'s own do/catch owns the
    /// slot from the moment the Task is created onward.
    ///
    /// Slot-release invariant: every successful `checkAndRegister` is matched by
    /// exactly one terminal `fail(jobID:)` or `complete(jobID:result:)` on every
    /// code path — the pre-Task catch handles preflight throws; the Task's catch
    /// handles bridge throws.
    ///
    /// The bridge import itself runs in an unstructured `Task`; all captured
    /// values satisfy Swift 6 task-capture requirements (see `runExport` for
    /// the same Sendability analysis). The bridge is idempotent per note's
    /// `stableSourceKey`.
    private static func runImport(
        kit: GeniusLocusKit, handle: EstateHandle, vaultURL: URL,
        mode: EncodeSpeed, jobRegistry: VaultJobRegistry
    ) async throws -> JSONValue {
        // Acquire the cap slot BEFORE running the expensive preflight.
        // The cap must bound expensive filesystem/estate work; running hashAllNotes
        // outside checkAndRegister allowed up to the HTTP transport concurrency
        // limit worth of parallel hashing before the cap was consulted.
        // Atomic cap-check-and-register: a single actor turn enforces the cap
        // and inserts the job record, closing the TOCTOU window that existed
        // when count-check and register were two separate actor calls.
        let jobID = try await jobRegistry.checkAndRegister(
            kind: .`import`, vaultPath: vaultURL.path, maxJobs: maxConcurrentVaultJobs)

        // Preflight: enumerate notes while holding the cap slot. Non-regular
        // .md entries (directories, symlinks) are skipped inside hashAllNotes
        // and return 0 without throwing. If this throws on a genuinely
        // unreadable regular .md file, release the slot via fail() so the
        // throwing preflight never permanently consumes a cap slot.
        // Pre-flight: retain the full note map (not just count) so non-dataset paths
        // can be derived below without a second filesystem walk.
        let allNotes: [String: ManifestEntry]
        let noteCount: Int
        do {
            allNotes = try hashAllNotes(vaultURL: vaultURL)
            noteCount = allNotes.count
        } catch {
            // Preflight failed after the slot was acquired — release it so a
            // throwing preflight never permanently consumes a cap slot.
            await jobRegistry.fail(jobID: jobID, errorMsg: error.localizedDescription)
            throw error
        }

        // Scan for dataset handle notes (contentKind: 7) before the Task.
        // Scan is synchronous and filesystem-only — no estate access required.
        // The results are Sendable (array of VaultDatasetNoteRecord) and safe to
        // capture in the background Task below.
        //
        // Dataset notes are excluded from the bridge import because DrawerMapping
        // does not re-honour `contentKind` on import — importing them through the
        // standard path creates drawers with contentKind=0 (wrong). They are instead
        // imported via the direct estate path after the bridge finishes (MX-TAB-7b §6).
        let datasetNotes = VaultTools.scanDatasetNotes(vaultURL: vaultURL)
        let datasetNotePaths = Set(datasetNotes.map { $0.path })
        let nonDatasetPaths: Set<String> = datasetNotes.isEmpty
            ? []
            : Set(allNotes.keys.filter { !datasetNotePaths.contains($0) })

        let bridge = VaultBridge(kit: kit)

        Task {
            do {
                // `now: Date()` samples the import instant at the access
                // surface; the bridge stamps it on the audit receipt.
                let capturedJobID = jobID
                let capturedRegistry = jobRegistry

                // Step A: bridge import for non-dataset notes.
                // When dataset notes are present, use the filtered overload so only
                // non-dataset paths enter the standard capture loop. Otherwise the
                // full (unfiltered) import is used — preserving the progress callback.
                let report: ImportReport
                if datasetNotes.isEmpty {
                    report = try await bridge.importVault(
                        at: vaultURL, into: handle, now: Date(),
                        progress: { processed, total in
                            Task { await capturedRegistry.updateProgress(
                                jobID: capturedJobID, processed: processed, total: total) }
                        },
                        mode: mode)
                } else {
                    // Filtered import: dataset note paths excluded. The filtered
                    // overload has no progress callback (candidate sets are small).
                    report = try await bridge.importVault(
                        at: vaultURL, includingPaths: nonDatasetPaths, into: handle,
                        now: Date(), mode: mode)
                }

                // Step B: import dataset notes via the direct estate path (MX-TAB-7b §6).
                // Non-fatal — dataset import failures do not discard the bridge result.
                _ = await VaultTools.importDatasetNotes(
                    vaultURL: vaultURL,
                    datasetNotes: datasetNotes,
                    kit: kit,
                    handle: handle,
                    now: Date())

                await jobRegistry.complete(
                    jobID: jobID,
                    result: .imported(ImportResult(
                        drawersWritten: report.drawersWritten,
                        drawersUpdated: report.drawersUpdated,
                        itemsSkipped: report.itemsSkipped,
                        tunnelsCreated: report.tunnelsCreated,
                        fdcClassified: report.fdcClassified,
                        fdcUnclassified: report.fdcUnclassified,
                        drawersSkippedUnchanged: report.drawersSkippedUnchanged,
                        drawersSkippedTombstoned: report.drawersSkippedTombstoned)))
            } catch {
                await jobRegistry.fail(jobID: jobID, errorMsg: error.localizedDescription)
            }
        }

        return ToolDispatcher.textResult("""
        job_id: \(jobID)
        vault: \(vaultURL.path)
        note_count: \(noteCount)
        status: RUNNING — import is processing in the background.
        IMPORTANT: Vault imports are long-running (~2 seconds per document). A \(noteCount)-note \
        vault will take approximately \(noteCount * 2 / 60) minutes. Do NOT cancel or re-issue \
        the import — it is running correctly. Poll moot_vault_job with this job_id to check progress.
        """)
    }

    /// Report manifest presence and, when present, its header. Pure
    /// filesystem read — mutates nothing.
    private static func runStatus(vaultURL: URL) throws -> JSONValue {
        guard let manifest = try readManifest(vaultURL: vaultURL) else {
            return ToolDispatcher.textResult("""
            vault_status: no export manifest at \(manifestRelativePath)
            path: \(vaultURL.path)
            (run moot_vault_export to stamp one)
            """)
        }
        return ToolDispatcher.textResult("""
        vault_status: manifest present
        path: \(vaultURL.path)
        noteCount: \(manifest.noteCount)
        lastExport: \(manifest.exportedAt)
        """)
    }

    /// Re-hash the vault and report drift against the export manifest.
    ///
    /// Dry-run mode (`apply=false`, the default): returns the candidate list
    /// and writes nothing. Each added/modified file is reported with its
    /// stableSourceKey and new SHA-256. Deletions are always reported only;
    /// no drawer is ever expunged here.
    ///
    /// Apply mode (`apply=true`): actions the added/modified candidates by
    /// calling `VaultBridge.importVault` synchronously. The import is
    /// idempotent per note's `stableSourceKey` — a re-reconcile after a
    /// partial run is safe. Returns the full drift report plus the import
    /// counts. Deletions are still reported only, never actioned.
    ///
    /// `now` is the operation instant, supplied by the caller (determinism
    /// rule — this method never reads the wall clock).
    private static func runReconcile(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        vaultURL: URL,
        apply: Bool,
        now: Date
    ) async throws -> JSONValue {
        guard let manifest = try readManifest(vaultURL: vaultURL) else {
            return ToolDispatcher.errorResult(
                "vault_reconcile: no export manifest at \(manifestRelativePath). Run moot_vault_export first.")
        }
        let current = try hashAllNotes(vaultURL: vaultURL)

        // Drift = exact hash compare of the current note set against the
        // export stamp. A path present now but absent from the manifest is
        // added; a path whose SHA-256 differs is modified; a path in the
        // manifest but gone from disk is deleted.
        var added: [String] = []
        var modified: [String] = []
        for (path, entry) in current {
            if let stamped = manifest.files[path] {
                if stamped.sha256 != entry.sha256 { modified.append(path) }
            } else {
                added.append(path)
            }
        }
        let deleted = manifest.files.keys.filter { current[$0] == nil }
        added.sort(); modified.sort()
        let deletedSorted = deleted.sorted()

        // Candidate paths: the added and modified notes whose content has drifted
        // from the export stamp. In dry-run mode these are reported only. In apply
        // mode these drive the path-scoped import so only M candidates are
        // actioned, not the entire N-note vault.
        let candidatePaths = Set(added + modified)
        let candidatePathsSorted = candidatePaths.sorted()

        var lines = [
            "vault_reconcile: \(added.count) added, \(modified.count) modified, \(deletedSorted.count) deleted",
        ]
        lines.append("added:")
        lines += added.map { "  + \($0)" }
        lines.append("modified:")
        lines += modified.map { "  ~ \($0)" }
        lines.append("deleted (reported, not actioned):")
        lines += deletedSorted.map { "  - \($0)" }

        if apply {
            // Apply mode: import only the candidate set (added + modified paths)
            // so drawersUpdated reports M (candidates actioned), not N (vault
            // size). candidatePaths drives the path-scoped import overload —
            // non-candidate notes never enter the capture loop.
            let bridge = VaultBridge(kit: kit)
            let report = try await bridge.importVault(
                at: vaultURL, includingPaths: candidatePaths, into: handle, now: now, mode: .foreground)
            lines.append("apply: true — candidates actioned via vault import")
            lines.append("  drawersWritten: \(report.drawersWritten)")
            lines.append("  drawersUpdated: \(report.drawersUpdated)")
            lines.append("  itemsSkipped: \(report.itemsSkipped)")
            lines.append("  tunnelsCreated: \(report.tunnelsCreated)")
            lines.append("  fdcClassified: \(report.fdcClassified)")
            lines.append("  fdcUnclassified: \(report.fdcUnclassified)")
            lines.append("  drawersSkippedUnchanged: \(report.drawersSkippedUnchanged)")
            lines.append("  drawersSkippedTombstoned: \(report.drawersSkippedTombstoned)")
        } else {
            // Dry-run mode: report candidates only, write nothing.
            lines.append("candidates (dry-run — pass apply=true to action):")
            for path in candidatePathsSorted {
                let key = path.hasSuffix(".md") ? String(path.dropLast(3)) : path
                let hash = current[path]?.sha256 ?? ""
                lines.append("  candidate stableSourceKey=\(key) vaultPath=\(path) sha256=\(hash)")
            }
            lines.append("no Proposal written — dry-run")
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    /// Return the current status of a vault job, or an error result when
    /// `jobID` is not registered. Sampling `Date()` here is correct —
    /// `elapsed_s` is a real-time measurement, not a deterministic
    /// computation.
    private static func runJob(
        jobID: String, registry: VaultJobRegistry
    ) async -> JSONValue {
        guard let job = await registry.job(for: jobID) else {
            return ToolDispatcher.errorResult("unknown job_id: \(jobID)")
        }
        let elapsed = Date().timeIntervalSince(job.startedAt)
        let elapsedStr = String(format: "%.1f", elapsed)

        switch job.status {
        case .running:
            var runningLines = """
            job_id: \(job.jobID)
            kind: \(job.kind.rawValue)
            vault: \(job.vaultPath)
            status: running
            elapsed_s: \(elapsedStr)
            """
            if let p = job.latestProgress {
                runningLines += "\nprogress: \(p.processed)/\(p.total)"
            }
            return ToolDispatcher.textResult(runningLines)
        case .complete:
            switch job.result {
            case .imported(let r):
                return ToolDispatcher.textResult("""
                job_id: \(job.jobID)
                kind: \(job.kind.rawValue)
                vault: \(job.vaultPath)
                status: complete
                elapsed_s: \(elapsedStr)
                drawersWritten: \(r.drawersWritten)
                drawersUpdated: \(r.drawersUpdated)
                itemsSkipped: \(r.itemsSkipped)
                tunnelsCreated: \(r.tunnelsCreated)
                fdcClassified: \(r.fdcClassified)
                fdcUnclassified: \(r.fdcUnclassified)
                drawersSkippedUnchanged: \(r.drawersSkippedUnchanged)
                drawersSkippedTombstoned: \(r.drawersSkippedTombstoned)
                """)
            case .exported(let r):
                return ToolDispatcher.textResult("""
                job_id: \(job.jobID)
                kind: \(job.kind.rawValue)
                vault: \(job.vaultPath)
                status: complete
                elapsed_s: \(elapsedStr)
                noteCount: \(r.noteCount)
                exportedAt: \(r.exportedAt)
                """)
            case nil:
                // Unreachable: registry.complete always sets result before
                // transitioning to .complete.
                return ToolDispatcher.errorResult(
                    "job \(jobID): complete but no result recorded — unexpected state")
            }
        case .failed:
            return ToolDispatcher.textResult("""
            job_id: \(job.jobID)
            kind: \(job.kind.rawValue)
            vault: \(job.vaultPath)
            status: failed
            elapsed_s: \(elapsedStr)
            error: \(job.errorMessage ?? "(unknown error)")
            """)
        }
    }

    // MARK: - Manifest IO + hashing

    /// SHA-256 every `.md` note under `vaultURL` and assemble the manifest.
    static func buildManifest(vaultURL: URL, now: Date) throws -> ExportManifest {
        let files = try hashAllNotes(vaultURL: vaultURL)
        // Fresh formatter per call: ISO8601DateFormatter is not Sendable,
        // so it cannot be a shared static under Swift 6 strict concurrency
        // (same per-call construction LensTools uses).
        return ExportManifest(
            exportedAt: ISO8601DateFormatter().string(from: now),
            noteCount: files.count,
            files: files)
    }

    /// Enumerate every `.md` note file under `vaultURL` and stamp its SHA-256,
    /// keyed by vault-relative path. Mirrors `ObsidianAdapter.toIR` exactly:
    /// - `.skipsHiddenFiles` so `.moot/export-manifest.json` is never included
    ///   in its own stamp.
    /// - Skips non-regular `.md` entries (directories, symlinks, special files
    ///   with a `.md` extension). Caller-controlled vault contents may include a
    ///   directory named `something.md` or a broken `.md` symlink — these are
    ///   not notes. Reading their resource value and skipping non-regular entries
    ///   prevents a spurious throw and, as defense-in-depth, avoids triggering
    ///   the slot-release guard in `runImport` on non-note entries. A genuinely
    ///   unreadable REGULAR `.md` file still throws — that is a real error; the
    ///   guard releases the slot via `fail()` and propagates the error to the caller.
    /// - Skips OKF navigation files (`index.md`, `log.md`) that `fromIR`
    ///   emits for progressive-disclosure nav but that `toIR` never imports
    ///   as notes. Without this skip the manifest count is inflated by one
    ///   per folder, breaking `noteCount` assertions and drift detection.
    static func hashAllNotes(vaultURL: URL) throws -> [String: ManifestEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var out: [String: ManifestEntry] = [:]
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
            // Skip non-regular .md entries (directories, symlinks, special files).
            // The enumerator prefetches .isRegularFileKey; reading it here is a
            // cache hit — no additional filesystem round-trip.
            guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  rv.isRegularFile == true else { continue }
            // Skip OKF navigation files — mirrors ObsidianAdapter.toIR which
            // skips files with stem "index" or "log" on read.
            let stem = fileURL.deletingPathExtension().lastPathComponent
            if stem == "index" || stem == "log" { continue }
            let rel = relativePath(of: fileURL, under: vaultURL)
            let data = try Data(contentsOf: fileURL)
            out[rel] = ManifestEntry(sha256: sha256Hex(data))
        }
        return out
    }

    /// Write the manifest to `.moot/export-manifest.json` atomically.
    ///
    /// Applies a symlink-containment guard before writing — the same pattern
    /// `ObsidianAdapter.ensureWritableFileTarget` uses for note writes in
    /// VaultKit. `ObsidianAdapter`'s guard is internal to VaultKit and cannot
    /// be called from here, so the check is applied inline. If a pre-existing
    /// symlink exists at the manifest path, the write is refused unconditionally:
    /// a symlink could redirect the write outside the vault root and is never a
    /// legitimate state for this layer-owned sidecar file.
    ///
    /// Sorted keys keep the on-disk JSON byte-stable across exports.
    static func writeManifest(_ manifest: ExportManifest, to vaultURL: URL) throws {
        let dir = vaultURL.appendingPathComponent(".moot", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        // Parent-dir containment guard (Finding 13): verify that the `.moot` directory
        // itself resolves inside the vault root after `createDirectory`. An attacker can
        // pre-plant a symlink at the `.moot` path pointing to a foreign directory;
        // createDirectory(withIntermediateDirectories: true) silently follows it and
        // creates the target there, so all subsequent writes land outside the vault.
        // The leaf-symlink check below does not catch this because the manifest file
        // does not yet exist at the now-foreign path.
        //
        // This is an inline analog of ObsidianAdapter.ensureContainedInVault — that
        // helper is internal to VaultKit and unreachable from AriaMcpKit. The logic
        // is identical: resolve symlinks on both sides and verify the dir path stays
        // inside the vault root. Called after createDirectory so resolvingSymlinksInPath
        // can fully walk any symlink chain that was pre-planted.
        let vaultResolved = vaultURL.resolvingSymlinksInPath().standardizedFileURL.path
        let dirResolved   = dir.resolvingSymlinksInPath().standardizedFileURL.path
        guard dirResolved == vaultResolved || dirResolved.hasPrefix(vaultResolved + "/") else {
            throw VaultKitError.adapterError(
                ".moot parent directory resolves outside the vault root after symlink expansion; write refused")
        }

        let url = vaultURL.appendingPathComponent(manifestRelativePath)

        // Leaf symlink-containment guard: refuse a pre-existing symlink at the manifest
        // path. A symlink here could redirect the manifest write to an attacker-
        // controlled path outside the vault. This mirrors the guard
        // ObsidianAdapter.ensureWritableFileTarget applies to note write targets:
        // reject any pre-existing symlink unconditionally, regardless of where it
        // points. VaultKitError.adapterError is the correct error type — this layer
        // owns the vault sidecar file and VaultKitError is already the error surface
        // for vault adapter faults.
        //
        // NOTE: `resourceValues(forKeys:)` is used directly (not guarded by
        // `fileExists`) because `fileExists` follows the symlink and returns `false`
        // for a broken symlink — which would silently skip the guard. `resourceValues`
        // with `.isSymbolicLinkKey` correctly returns `isSymbolicLink = true` for
        // both live and broken symlinks, closing the attack vector in both cases.
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw VaultKitError.adapterError(
                "manifest path targets a pre-existing symlink; write refused")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    /// Read and decode the manifest, or `nil` when none has been stamped.
    static func readManifest(vaultURL: URL) throws -> ExportManifest? {
        let url = vaultURL.appendingPathComponent(manifestRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ExportManifest.self, from: data)
    }

    /// Lowercase hex SHA-256 of `data`.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Forward-slash vault-relative path of `fileURL` under `root`. A
    /// local copy of `ObsidianAdapter`'s path logic (that helper is
    /// internal to VaultKit); same precedent as the LensTools schema
    /// helpers being small local copies.
    static func relativePath(of fileURL: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        var i = 0
        while i < rootComponents.count, i < fileComponents.count,
              rootComponents[i] == fileComponents[i] {
            i += 1
        }
        return fileComponents[i...].joined(separator: "/")
    }

    // MARK: - Argument decoding

    private static func requireString(
        _ args: [String: JSONValue], _ key: String
    ) throws -> String {
        guard let value = args[key]?.stringValue, !value.isEmpty else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Missing required string argument: \(key)")
        }
        return value
    }

    // MARK: - JSON schema helpers (same small copies as LensTools)

    private static var vaultPathSchema: JSONValue {
        stringSchema("Filesystem path of the vault directory.")
    }

    private static var estateIDSchema: JSONValue {
        stringSchema("Optional UUID of the open estate to target. Omit for the default estate.")
    }

    /// Schema for the optional `apply` argument on `moot_vault_reconcile`.
    ///
    /// When `true`, the tool actions the detected candidates by importing them
    /// into the estate synchronously. When absent or `false`, the tool is a
    /// pure dry-run that reports candidates without writing anything.
    private static var applySchema: JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(
                "When true, import added/modified vault notes into the estate. " +
                "Omit or set false for a dry-run that reports candidates without writing."
            ),
        ])
    }

    /// Schema for the optional `scope` argument on `moot_vault_export`.
    private static var scopeSchema: JSONValue {
        stringSchema(
            "Export scope: exportable (default), believed, believed-including-private, confirmed, unconfirmed. " +
            "Controls which drawers are included. " +
            "'exportable' (default) restricts to drawers marked as public — a default export never writes non-exportable/private rows. " +
            "'believed' exports all currently-believed drawers regardless of confirmation state. " +
            "'confirmed' restricts to user-confirmed drawers. " +
            "'unconfirmed' is the capture-inbox (pre-review) subset."
        )
    }

    /// Parse the optional `scope` argument to a `VaultExportScope`.
    ///
    /// - Returns the named scope, or `.exportable` when the argument is absent
    ///   (CAND-032: a default disk export writes only exportable-marked rows).
    /// - Throws `JSONRPCError.invalidParams` when the argument is present but
    ///   names an unknown scope. Clear error surfaces to the MCP client.
    private static func parseScope(_ value: JSONValue?) throws -> VaultExportScope {
        guard let strValue = value?.stringValue, !strValue.isEmpty else {
            return .exportable   // absent or empty → default (CAND-032)
        }
        guard let scope = VaultExportScope(rawValue: strValue) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown export scope '\(strValue)'. " +
                    "Valid values: \(VaultExportScope.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return scope
    }

    private static func objectSchema(
        properties: [String: JSONValue], required: [String]
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    private static func stringSchema(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func booleanSchema(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    // MARK: - Dataset round-trip helpers (MX-TAB-7b §6)
    //
    // These helpers power the export companion CSV write and the import direct
    // estate path that bypasses DrawerMapping (which does not re-honour contentKind).
    // Mirrors the corresponding block in the Rust twin's vault_tools.rs.

    /// Vault CSV companion size cap (mirrors Rust VAULT_CSV_SIZE_CAP_BYTES: 100 MiB).
    private static let vaultCSVSizeCapBytes: Int64 = 100 * 1_048_576

    /// Maximum rows exported per dataset companion CSV.
    private static let datasetExportRowCap = 1_000_000

    /// A dataset handle note record from a vault scan.
    ///
    /// Declared as a `Sendable` struct (rather than a named tuple) so it can be
    /// captured safely in the unstructured `Task` inside `runImport`.
    private struct VaultDatasetNoteRecord: Sendable {
        let path: String
        let frontmatter: [String: String]
        let body: String
    }

    /// Parse a Markdown note's YAML frontmatter block into a string dictionary.
    ///
    /// Handles BOM prefix. Strips surrounding double-quotes from string values.
    /// Returns an empty dict when no frontmatter block is found.
    private static func parseFrontmatter(_ content: String) -> [String: String] {
        let s = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        guard s.hasPrefix("---") else { return [:] }
        var result: [String: String] = [:]
        let lines = s.components(separatedBy: "\n")
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("---") { break }
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIdx])
                    .trimmingCharacters(in: .whitespaces)
                var val = String(line[line.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)
                // Strip surrounding double-quotes (YAML bare-string quoting convention).
                if val.count >= 2 && val.hasPrefix("\"") && val.hasSuffix("\"") {
                    val = String(val.dropFirst().dropLast())
                }
                if !key.isEmpty { result[key] = val }
            }
            i += 1
        }
        return result
    }

    /// Extract the body of a Markdown note — the text after the closing `---` block.
    private static func extractMdBody(_ content: String) -> String {
        let s = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        guard s.hasPrefix("---") else { return s }
        let lines = s.components(separatedBy: "\n")
        var i = 1
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("---") {
                let tail = lines[(i + 1)...]
                return tail.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            i += 1
        }
        return ""
    }

    /// Scan the vault for dataset handle notes (contentKind: 7 in frontmatter).
    ///
    /// Mirrors `ObsidianAdapter.toIR`: skips hidden directories and OKF nav files.
    /// Returns an empty array on any filesystem error (non-fatal caller contract).
    private static func scanDatasetNotes(vaultURL: URL) -> [VaultDatasetNoteRecord] {
        var results: [VaultDatasetNoteRecord] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
            guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  rv.isRegularFile == true else { continue }
            // Skip OKF navigation files (mirrors hashAllNotes / ObsidianAdapter.toIR).
            let stem = fileURL.deletingPathExtension().lastPathComponent
            if stem == "index" || stem == "log" { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let content = String(data: data, encoding: .utf8) else { continue }
            let fm_ = parseFrontmatter(content)
            // contentKind 7 → ContentKind.dataset (LocusKit/Sources/Drawers/ContentKind.swift).
            guard fm_["contentKind"] == "7" else { continue }
            results.append(VaultDatasetNoteRecord(
                path: relativePath(of: fileURL, under: vaultURL),
                frontmatter: fm_,
                body: extractMdBody(content)))
        }
        return results
    }

    /// Map a ColumnType to the label used in vault CSV headers (all-caps).
    /// Mirrors Rust `vault_column_type_label`.
    private static func vaultColumnTypeLabel(_ ct: ColumnType) -> String {
        switch ct {
        case .int:   return "INT"
        case .float: return "FLOAT"
        case .bool:  return "BOOL"
        default:     return "TEXT"
        }
    }

    /// Parse a vault CSV header label back to ColumnType (case-insensitive).
    /// Unknown labels default to .text. Mirrors Rust `column_type_from_label`.
    private static func columnTypeFromLabel(_ label: String) -> ColumnType {
        switch label.uppercased() {
        case "INT", "INTEGER": return .int
        case "FLOAT", "REAL", "DOUBLE": return .float
        case "BOOL", "BOOLEAN": return .bool
        default: return .text
        }
    }

    /// RFC-4180 CSV field escaping: wraps the field in double-quotes when it
    /// contains a comma, double-quote, newline, or carriage return.
    private static func escapeCSVField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else {
            return s
        }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Render a TypedValue as a CSV cell string for companion CSV export.
    ///
    /// Null → empty string (the import side reads empty → null, matching
    /// the moot_file_dataset CSV path). Float → Swift's `String(d)` which is
    /// the shortest-roundtrip f64 representation, matching the Rust `format!("{}", d)`
    /// via the `ryu` crate. Never Float32.
    private static func typedValueToCSVText(_ v: TypedValue) -> String {
        switch v {
        case .null:          return ""
        case .bool(let b):   return b ? "true" : "false"
        case .int(let i):    return "\(i)"
        case .bitmap(let i): return "\(i)"
        // f64 shortest roundtrip — matches Rust twin's ryu format!("{}", d).
        case .float(let d):  return String(d)
        case .text(let s):   return s
        case .uuid(let u):   return u.uuidString
        case .timestamp(let date): return ISO8601DateFormatter().string(from: date)
        default:             return ""
        }
    }

    /// Map a frontmatter sensitivity label to AdjectiveSensitivity.
    private static func vaultSensitivityToAdjectiveSensitivity(
        from label: String?
    ) -> AdjectiveSensitivity {
        switch label?.lowercased() {
        case "elevated":   return .elevated
        case "restricted": return .restricted
        case "secret":     return .secret
        default:           return .normal
        }
    }

    /// Export companion CSV files alongside dataset handle notes in the vault.
    ///
    /// Called as a post-step in `runExport` after `bridge.export` and
    /// `writeManifest` complete. For each note with `contentKind: 7`, queries
    /// the DatasetStore and writes a companion `<slug>.csv` next to the `.md`.
    ///
    /// ## Sensitivity gate (MX-TAB-SEC-1 A4)
    ///
    /// Handles with `sensitivity: restricted` or `sensitivity: secret` in their
    /// frontmatter have their note exported (by `bridge.export`) but NO companion
    /// CSV written. This prevents bulk CSV data from leaving the estate unprotected
    /// alongside a sensitive handle note. A logged notice and a warning entry are
    /// emitted for each skipped handle.
    ///
    /// Non-fatal: individual failures are collected as warnings and returned.
    /// Returns `(csvCount, warnings)`.
    static func exportDatasetCSVs(
        vaultURL: URL, kit: GeniusLocusKit, handle: EstateHandle
    ) async -> (count: Int, warnings: [String]) {
        let datasetNotes = scanDatasetNotes(vaultURL: vaultURL)
        guard !datasetNotes.isEmpty else { return (0, []) }

        let datasetStore: any DatasetStore
        do {
            datasetStore = try await kit.datasetStore(for: handle)
        } catch {
            return (0, ["vault_export: no DatasetStore; dataset CSVs skipped: \(error.localizedDescription)"])
        }

        var count = 0
        var warnings: [String] = []

        for note in datasetNotes {
            // A4: Sensitivity gate — skip CSV for restricted/secret dataset handles
            // (MX-TAB-SEC-1 A4).
            //
            // The .md handle note is already in the vault (written by bridge.export,
            // which applies the bulk-channel tier rules). This gate prevents companion
            // CSV data from riding alongside a sensitive handle note.
            //
            // Behaviour:
            //   - normal / elevated:   note exported AND csv exported (no change)
            //   - restricted / secret: note exported, CSV is SKIPPED with a logged notice
            //
            // "restricted" and "secret" map to ADR-007 tiers that are excluded from
            // bulk data export. Their CSV content must not leave the estate unprotected.
            let noteSensitivity = vaultSensitivityToAdjectiveSensitivity(
                from: note.frontmatter["sensitivity"])
            if noteSensitivity == .restricted || noteSensitivity == .secret {
                let sensLabel = note.frontmatter["sensitivity"] ?? "restricted"
                Logging.osLog.notice(
                    "vault_export: sensitive dataset handle at \(note.path, privacy: .public) (sensitivity: \(sensLabel, privacy: .public)) — note exported, CSV skipped per MX-TAB-SEC-1 A4")
                warnings.append(
                    "vault_export: \(note.path): sensitivity=\(sensLabel) — " +
                    "CSV skipped (handle note exported; dataset CSV withheld)")
                continue
            }

            // Decode DatasetHandleContent from the note body to get the dataset UUID.
            let handleContent: DatasetHandleContent
            do {
                handleContent = try DatasetHandleContent.decode(from: note.body)
            } catch {
                warnings.append("vault_export: \(note.path): cannot decode DatasetHandleContent; skipped")
                continue
            }

            let datasetId = handleContent.datasetId

            // Query rows (capped at datasetExportRowCap to bound file size).
            let rows: [StorageRow]
            do {
                rows = try await datasetStore.queryRows(
                    id: datasetId, predicate: nil, orderBy: [],
                    limit: datasetExportRowCap, offset: nil, columns: nil)
            } catch {
                warnings.append("vault_export: \(note.path): queryRows failed (\(error.localizedDescription)); skipped")
                continue
            }

            // Build CSV: header row (column names only), then one data row per StorageRow.
            let colNames = handleContent.columns.map(\.name)
            var csvLines: [String] = []
            // Header: just column names, RFC-4180 escaped.
            csvLines.append(colNames.map { escapeCSVField($0) }.joined(separator: ","))
            // Data rows: column order matches header.
            for row in rows {
                let cells = colNames.map { col in
                    escapeCSVField(typedValueToCSVText(row.values[col] ?? .null))
                }
                csvLines.append(cells.joined(separator: ","))
            }
            let csvContent = csvLines.joined(separator: "\n")

            // Companion CSV path: replace `.md` with `.csv` (e.g. Wing/Room/Slug.csv).
            // Matches Rust: format!("{}.csv", &rel_path[..rel_path.len() - 3])
            let noteURL = vaultURL.appendingPathComponent(note.path)
            let csvURL = noteURL.deletingPathExtension().appendingPathExtension("csv")

            do {
                try csvContent.write(to: csvURL, atomically: true, encoding: .utf8)
                count += 1
            } catch {
                let csvPath = VaultTools.relativePath(of: csvURL, under: vaultURL)
                warnings.append("vault_export: failed to write \(csvPath) (\(error.localizedDescription))")
            }
        }

        return (count, warnings)
    }

    /// Import dataset handle notes via the direct estate path (bypasses DrawerMapping).
    ///
    /// For each `VaultDatasetNoteRecord` with `contentKind: 7`:
    ///   1. Decode `DatasetHandleContent` from note body.
    ///   2. Validate column identifiers before DDL.
    ///   3. Read companion `.csv` at same path with `.csv` extension.
    ///   4. Parse CSV; check size cap.
    ///   5. `createDataset` → `appendRows` → `captureDatasetHandle`.
    ///   6. Compute signatures non-fatally.
    ///
    /// Returns `(importedCount, warnings)`.
    private static func importDatasetNotes(
        vaultURL: URL,
        datasetNotes: [VaultDatasetNoteRecord],
        kit: GeniusLocusKit,
        handle: EstateHandle,
        now: Date
    ) async -> (imported: Int, warnings: [String]) {
        guard !datasetNotes.isEmpty else { return (0, []) }

        let datasetStore: any DatasetStore
        do {
            datasetStore = try await kit.datasetStore(for: handle)
        } catch {
            return (0, ["vault_import: no DatasetStore; dataset notes skipped: \(error.localizedDescription)"])
        }

        let estate: LocusKit.Estate
        do {
            estate = try await kit.estate(for: handle)
        } catch {
            return (0, ["vault_import: estate not accessible for dataset import; dataset notes skipped: \(error.localizedDescription)"])
        }

        var imported = 0
        var warnings: [String] = []

        for note in datasetNotes {
            // 1. Decode DatasetHandleContent from the note body.
            let handleContent: DatasetHandleContent
            do {
                handleContent = try DatasetHandleContent.decode(from: note.body)
            } catch {
                warnings.append("vault_import: \(note.path): cannot decode DatasetHandleContent; skipped")
                continue
            }

            let datasetId = handleContent.datasetId

            // 2. Validate column identifiers BEFORE any DDL.
            var validationFailed = false
            for col in handleContent.columns {
                do {
                    try validateDatasetColumnIdentifier(col.name)
                } catch {
                    warnings.append("vault_import: \(note.path): invalid column identifier \"\(col.name)\"; skipped")
                    validationFailed = true
                    break
                }
            }
            if validationFailed { continue }

            // 3. Build column declarations from handle content (types preserved from original).
            let columnDecls = handleContent.columns.map { col in
                ColumnDeclaration(name: col.name, type: columnTypeFromLabel(col.dataType))
            }
            let schema = DatasetSchema(columns: columnDecls, primaryKeyColumn: nil)

            // 4. Locate and read companion CSV.
            // Companion path: replace `.md` with `.csv` (mirrors Rust path logic).
            let noteURL = vaultURL.appendingPathComponent(note.path)
            let csvURL = noteURL.deletingPathExtension().appendingPathExtension("csv")
            let csvRelPath = VaultTools.relativePath(of: csvURL, under: vaultURL)

            let fm = FileManager.default
            guard fm.fileExists(atPath: csvURL.path) else {
                // No companion CSV — log warning but skip this note.
                // (Handle was exported without a backing table, or CSV was deleted.)
                warnings.append("vault_import: \(note.path): no companion CSV at \(csvRelPath); skipped")
                continue
            }

            let attrs = try? fm.attributesOfItem(atPath: csvURL.path)
            let csvSize = (attrs?[.size] as? Int64) ?? Int64((attrs?[.size] as? Int) ?? 0)
            if csvSize > vaultCSVSizeCapBytes {
                let capMiB = vaultCSVSizeCapBytes / 1_048_576
                let fileMiB = Double(csvSize) / 1_048_576.0
                warnings.append(
                    "vault_import: \(csvRelPath) exceeds \(capMiB) MiB size cap " +
                    "(\(String(format: "%.1f", fileMiB)) MiB); skipped")
                continue
            }

            guard let csvData = try? Data(contentsOf: csvURL),
                  let csvContent = String(data: csvData, encoding: .utf8) else {
                warnings.append("vault_import: \(note.path): cannot read companion CSV; skipped")
                continue
            }

            // 5. Parse CSV.
            let csvLines = vaultSplitCSVLines(csvContent)
            guard !csvLines.isEmpty else {
                warnings.append("vault_import: \(csvRelPath) is empty; skipped")
                continue
            }

            // Header line provides column-name → field-index mapping.
            let headerFields = vaultParseCSVRecord(csvLines[0])
            var colIndex: [String: Int] = [:]
            for (i, h) in headerFields.enumerated() { colIndex[h] = i }

            let colTypes: [(name: String, type: ColumnType)] = handleContent.columns.map { col in
                (col.name, columnTypeFromLabel(col.dataType))
            }

            var typedRows: [[String: TypedValue]] = []
            typedRows.reserveCapacity(max(0, csvLines.count - 1))
            for line in csvLines.dropFirst() {
                let fields = vaultParseCSVRecord(line)
                var row: [String: TypedValue] = [:]
                for (colName, colType) in colTypes {
                    let cell: String? = colIndex[colName].flatMap { i in
                        i < fields.count && !fields[i].isEmpty ? fields[i] : nil
                    }
                    row[colName] = vaultParseTypedValue(cell, as: colType)
                }
                typedRows.append(row)
            }

            // 6a. Create dataset table (idempotent via CREATE TABLE IF NOT EXISTS).
            do {
                try await datasetStore.createDataset(id: datasetId, schema: schema, indexes: [])
            } catch {
                warnings.append("vault_import: \(note.path): createDataset failed (\(error.localizedDescription)); skipped")
                continue
            }

            // 6b. Append rows. On failure, drop the table (atomic intent).
            if !typedRows.isEmpty {
                do {
                    try await datasetStore.appendRows(id: datasetId, rows: typedRows)
                } catch {
                    try? await datasetStore.dropDataset(id: datasetId)
                    warnings.append("vault_import: \(note.path): appendRows failed (\(error.localizedDescription)); table dropped")
                    continue
                }
            }

            // 6c. captureDatasetHandle — the ONLY authorised creation path for .dataset drawers.
            // Source description preserved from the original handle content (audit-trail fidelity).
            let sensitivity = vaultSensitivityToAdjectiveSensitivity(
                from: note.frontmatter["sensitivity"])
            let udc = note.frontmatter["udc"].flatMap { $0.isEmpty ? nil : $0 } ?? "000"
            let room = note.frontmatter["room"].flatMap { $0.isEmpty ? nil : $0 } ?? "Datasets"
            let columnSummaries = handleContent.columns.map { col in
                DatasetColumnSummary(name: col.name, dataType: col.dataType)
            }

            let drawer: Drawer
            do {
                drawer = try await estate.captureDatasetHandle(
                    datasetId: datasetId,
                    columns: columnSummaries,
                    rowCount: typedRows.count,
                    sourceDescription: handleContent.sourceDescription,
                    wing: note.frontmatter["wing"].flatMap { $0.isEmpty ? nil : $0 },
                    room: room,
                    addedBy: "aria-mcp-vault-import",
                    sensitivity: sensitivity,
                    latticeAnchor: LatticeAnchor.udc(udc))
            } catch {
                try? await datasetStore.dropDataset(id: datasetId)
                warnings.append("vault_import: \(note.path): captureDatasetHandle failed (\(error.localizedDescription)); table dropped")
                continue
            }

            // 6d. Signatures (MX-TAB-5) — non-fatal.
            // The dataset and handle are already committed; signature failure is recoverable.
            do {
                let sampledRows = try await datasetStore.queryRows(
                    id: datasetId, predicate: nil, orderBy: [],
                    limit: datasetSignatureSampleSize, offset: nil, columns: nil)
                var stats: [String: ColumnStats] = [:]
                for col in schema.columns {
                    stats[col.name] = try await datasetStore.columnStats(
                        id: datasetId, column: col.name)
                }
                _ = try await kit.computeDatasetSignatures(
                    handle: handle,
                    drawerId: drawer.id,
                    columns: columnSummaries,
                    columnStats: stats,
                    sampledRows: sampledRows,
                    now: now)
            } catch {
                warnings.append("vault_import: \(note.path): signatures pending (\(error.localizedDescription))")
            }

            imported += 1
        }

        return (imported, warnings)
    }

    // MARK: - Private vault CSV parsing (private copies of DatasetTools helpers)
    //
    // DatasetTools helpers are private to that enum and cannot be called from here.
    // The implementations are identical; any change to one must mirror the other.

    /// Split vault CSV content into non-empty logical lines (normalising line endings).
    private static func vaultSplitCSVLines(_ content: String) -> [String] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Parse one RFC-4180 CSV record into field strings.
    private static func vaultParseCSVRecord(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        current.append("\""); i += 2; continue
                    } else { inQuotes = false; i += 1; continue }
                } else { current.append(ch); i += 1 }
            } else {
                if ch == "\"" { inQuotes = true; i += 1 }
                else if ch == "," {
                    fields.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""; i += 1
                } else { current.append(ch); i += 1 }
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    /// Convert a raw string cell (nil = empty cell) to TypedValue.
    /// Mirrors DatasetTools.parseTypedValue and Rust parse_vault_csv_cell.
    private static func vaultParseTypedValue(_ raw: String?, as type_: ColumnType) -> TypedValue {
        guard let s = raw, !s.isEmpty else { return .null }
        switch type_ {
        case .int:
            return Int64(s).map { .int($0) } ?? .text(s)
        case .float:
            return Double(s).map { .float($0) } ?? .text(s)
        case .bool:
            switch s.lowercased() {
            case "true", "1", "yes": return .bool(true)
            case "false", "0", "no": return .bool(false)
            default: return .text(s)
            }
        case .text:
            return .text(s)
        default:
            return .text(s)
        }
    }
}
