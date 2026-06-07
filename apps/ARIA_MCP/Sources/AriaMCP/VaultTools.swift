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
// The shipped MCP binary is the Swift port (installer/install.sh builds
// `mootx01-mcp` via `swift build`). The Rust `aria-mcp` bin (`apps/ARIA_MCP/rust/`)
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

    /// The four `moot_vault_*` stems, dispatched by name above the
    /// lexicon projection.
    static let vaultToolNames: Set<String> = [
        "moot_vault_export", "moot_vault_import",
        "moot_vault_status", "moot_vault_reconcile",
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
                description: "Re-hash a vault's notes and report drift (added / modified / deleted) vs the export manifest. Returns candidates for the downstream loop; writes no Proposal and expunges no drawer.",
                inputSchema: objectSchema(
                    properties: [
                        "vaultPath": vaultPathSchema,
                    ],
                    required: ["vaultPath"]),
                provenance: .vault),
        ]
    }

    // MARK: - Dispatch

    /// Run the named vault tool. Same contract as `LensTools.dispatch`:
    /// out-of-band faults (missing `vaultPath`, malformed `estateID`)
    /// throw `JSONRPCError`; everything else returns a `text_result`.
    static func dispatch(
        name: String,
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        defaultHandle: EstateHandle,
        resolveHandle: ([String: JSONValue]) throws -> EstateHandle
    ) async throws -> JSONValue {
        // `vaultPath` is required for all four tools; reject early.
        let vaultURL = URL(
            fileURLWithPath: try requireString(args, "vaultPath"), isDirectory: true)

        switch name {
        case "moot_vault_export":
            // export/import target an estate, resolved through the
            // dispatcher's own registry exactly like the lexicon tools.
            // Parse the optional scope string; default to .believed.
            let scope = try parseScope(args["scope"])
            return try await runExport(
                kit: kit, handle: try resolveHandle(args), vaultURL: vaultURL, scope: scope)

        case "moot_vault_import":
            return try await runImport(
                kit: kit, handle: try resolveHandle(args), vaultURL: vaultURL)

        case "moot_vault_status":
            // status reads only the filesystem — no estate is consulted,
            // so it takes no estateID.
            return try runStatus(vaultURL: vaultURL)

        case "moot_vault_reconcile":
            return try runReconcile(vaultURL: vaultURL)

        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown vault tool: \(name)")
        }
    }

    // MARK: - Handlers

    /// Export the estate to the vault, then stamp the drift manifest over
    /// every note just written. `now` is sampled at the handler boundary
    /// (the export instant is a real wall-clock event, not a deterministic
    /// computation — same precedent as `LensTools` sampling `Date()`); the
    /// manifest build itself is deterministic given `now`.
    private static func runExport(
        kit: GeniusLocusKit, handle: EstateHandle, vaultURL: URL,
        scope: VaultExportScope = .believed
    ) async throws -> JSONValue {
        let bridge = VaultBridge(kit: kit)
        try await bridge.export(estate: handle, to: vaultURL, scope: scope)

        let manifest = try buildManifest(vaultURL: vaultURL, now: Date())
        try writeManifest(manifest, to: vaultURL)

        return ToolDispatcher.textResult("""
        vault_export: \(manifest.noteCount) note(s) → \(vaultURL.path)
        manifest: \(manifestRelativePath) (sha256 ×\(manifest.files.count))
        scope: \(scope.rawValue)
        exportedAt: \(manifest.exportedAt)
        """)
    }

    /// Import the vault into the estate and report the `ImportReport`
    /// counts. The bridge is idempotent per note's `stableSourceKey`.
    private static func runImport(
        kit: GeniusLocusKit, handle: EstateHandle, vaultURL: URL
    ) async throws -> JSONValue {
        let bridge = VaultBridge(kit: kit)
        let report = try await bridge.importVault(at: vaultURL, into: handle)

        return ToolDispatcher.textResult("""
        vault_import: \(report.drawersWritten) written, \(report.drawersUpdated) updated, \(report.itemsSkipped) skipped
        tunnels: \(report.tunnelsCreated)
        fdc: \(report.fdcClassified) classified, \(report.fdcUnclassified) unclassified
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

    /// Re-hash the vault and report drift against the export manifest,
    /// then surface added/modified files as candidates (return-only seam).
    ///
    /// Leg (b) of the QueueKit decision: no QueueKit instance is mounted
    /// in the MCP dispatch context (the dispatcher carries only kit +
    /// handle; `QueueKit.send` needs a root URL + an HLC clock, which
    /// would break determinism and exceed additive scope). So reconcile
    /// RETURNS the candidates rather than enqueuing them. A2 does not
    /// parse edits into Proposals and writes no Proposal noun; deletions
    /// are reported, never actioned (no drawer is expunged here).
    private static func runReconcile(vaultURL: URL) throws -> JSONValue {
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

        // Candidate-enqueue seam (return-only). Each added/modified file
        // becomes a candidate carrying enough for the downstream loop to
        // parse and stage: the stableSourceKey (the vault-relative path
        // without the `.md` extension — the same key DrawerMapping derives
        // on export), the vault path, and the new content hash.
        let candidatePaths = (added + modified).sorted()

        var lines = [
            "vault_reconcile: \(added.count) added, \(modified.count) modified, \(deletedSorted.count) deleted",
        ]
        lines.append("added:")
        lines += added.map { "  + \($0)" }
        lines.append("modified:")
        lines += modified.map { "  ~ \($0)" }
        lines.append("deleted (reported, not actioned):")
        lines += deletedSorted.map { "  - \($0)" }
        lines.append("candidates (returned, not enqueued — no Proposal written):")
        for path in candidatePaths {
            let key = path.hasSuffix(".md") ? String(path.dropLast(3)) : path
            let hash = current[path]?.sha256 ?? ""
            lines.append("  candidate stableSourceKey=\(key) vaultPath=\(path) sha256=\(hash)")
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
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

    /// Enumerate every `.md` file under `vaultURL` and stamp its SHA-256,
    /// keyed by vault-relative path. Mirrors `ObsidianAdapter`'s note
    /// enumeration (`.md`, `.skipsHiddenFiles`) so the manifest's key set
    /// matches the notes the bridge writes and reads — and so the `.moot`
    /// manifest itself (hidden) is never hashed into its own stamp.
    static func hashAllNotes(vaultURL: URL) throws -> [String: ManifestEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var out: [String: ManifestEntry] = [:]
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
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
