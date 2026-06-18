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
                description: "Import a Markdown vault into a MOOT estate via the capture seam. Idempotent per note; returns written/updated/tunnel/skipped and FDC-classification counts.",
                inputSchema: objectSchema(
                    properties: [
                        "vaultPath": vaultPathSchema,
                        "estateID": estateIDSchema,
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
        jobRegistry: VaultJobRegistry
    ) async throws -> JSONValue {
        // Guard: vault surface is disabled (installed with --vault-off).
        // Return a clear refusal rather than an opaque failure. The tool
        // should never be called when disabled (it is absent from tools/list),
        // but the guard ensures a clean error if a client hard-codes the name.
        // MOOTX01_VAULT env var: absent/≠"0" = enabled; "0" = disabled (ADR-015).
        guard ToolProjection.vaultEnabled else {
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
            return try await runImport(
                kit: kit, handle: try resolveHandle(args), vaultURL: vaultURL,
                jobRegistry: jobRegistry)

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
    private static func runExport(
        kit: GeniusLocusKit, handle: EstateHandle, vaultURL: URL,
        scope: VaultExportScope = .believed,
        jobRegistry: VaultJobRegistry
    ) async throws -> JSONValue {
        let jobID = UUID().uuidString
        await jobRegistry.register(jobID: jobID, kind: .`export`, vaultPath: vaultURL.path)

        let bridge = VaultBridge(kit: kit)
        let capturedScope = scope

        Task {
            do {
                // `now: Date()` samples the export instant at the access
                // surface (the deterministic bridge stamps it on the audit
                // receipt). The returned ExportReport's note count is also
                // available from the manifest below; tier-exclusion counts
                // surface via the receipt in the estate diary.
                _ = try await bridge.export(
                    estate: handle, to: vaultURL, scope: capturedScope, now: Date())
                let manifest = try VaultTools.buildManifest(vaultURL: vaultURL, now: Date())
                try VaultTools.writeManifest(manifest, to: vaultURL)
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
    /// A quick `hashAllNotes` scan runs synchronously before the Task so
    /// the immediate response can include `note_count` (useful for progress
    /// framing). `hashAllNotes` is a pure filesystem enumeration over `Data`
    /// reads — typically under 1 ms even for large vaults. The bridge import
    /// itself runs in an unstructured `Task`; all captured values satisfy
    /// Swift 6 task-capture requirements (see `runExport` for the same
    /// Sendability analysis). The bridge is idempotent per note's
    /// `stableSourceKey`.
    private static func runImport(
        kit: GeniusLocusKit, handle: EstateHandle, vaultURL: URL,
        jobRegistry: VaultJobRegistry
    ) async throws -> JSONValue {
        let noteCount = try hashAllNotes(vaultURL: vaultURL).count

        let jobID = UUID().uuidString
        await jobRegistry.register(jobID: jobID, kind: .`import`, vaultPath: vaultURL.path)

        let bridge = VaultBridge(kit: kit)

        Task {
            do {
                // `now: Date()` samples the import instant at the access
                // surface; the bridge stamps it on the audit receipt.
                let report = try await bridge.importVault(at: vaultURL, into: handle, now: Date())
                await jobRegistry.complete(
                    jobID: jobID,
                    result: .imported(ImportResult(
                        drawersWritten: report.drawersWritten,
                        drawersUpdated: report.drawersUpdated,
                        itemsSkipped: report.itemsSkipped,
                        tunnelsCreated: report.tunnelsCreated,
                        fdcClassified: report.fdcClassified,
                        fdcUnclassified: report.fdcUnclassified)))
            } catch {
                await jobRegistry.fail(jobID: jobID, errorMsg: error.localizedDescription)
            }
        }

        return ToolDispatcher.textResult("""
        job_id: \(jobID)
        vault: \(vaultURL.path)
        note_count: \(noteCount)
        poll: moot_vault_job to check status
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
                at: vaultURL, includingPaths: candidatePaths, into: handle, now: now)
            lines.append("apply: true — candidates actioned via vault import")
            lines.append("  drawersWritten: \(report.drawersWritten)")
            lines.append("  drawersUpdated: \(report.drawersUpdated)")
            lines.append("  itemsSkipped: \(report.itemsSkipped)")
            lines.append("  tunnelsCreated: \(report.tunnelsCreated)")
            lines.append("  fdcClassified: \(report.fdcClassified)")
            lines.append("  fdcUnclassified: \(report.fdcUnclassified)")
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
            return ToolDispatcher.textResult("""
            job_id: \(job.jobID)
            kind: \(job.kind.rawValue)
            vault: \(job.vaultPath)
            status: running
            elapsed_s: \(elapsedStr)
            """)
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
    /// Sorted keys keep the on-disk JSON byte-stable across exports.
    static func writeManifest(_ manifest: ExportManifest, to vaultURL: URL) throws {
        let dir = vaultURL.appendingPathComponent(".moot", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = vaultURL.appendingPathComponent(manifestRelativePath)
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
            "Export scope: believed (default), exportable, confirmed, unconfirmed. " +
            "Controls which drawers are included. " +
            "'believed' exports all currently-believed drawers regardless of confirmation state. " +
            "'exportable' restricts to drawers marked as public. " +
            "'confirmed' restricts to user-confirmed drawers. " +
            "'unconfirmed' is the capture-inbox (pre-review) subset."
        )
    }

    /// Parse the optional `scope` argument to a `VaultExportScope`.
    ///
    /// - Returns the named scope, or `.believed` when the argument is absent.
    /// - Throws `JSONRPCError.invalidParams` when the argument is present but
    ///   names an unknown scope. Clear error surfaces to the MCP client.
    private static func parseScope(_ value: JSONValue?) throws -> VaultExportScope {
        guard let strValue = value?.stringValue, !strValue.isEmpty else {
            return .believed   // absent or empty → default
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
}
