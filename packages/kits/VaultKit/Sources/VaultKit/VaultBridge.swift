import Foundation
import OSLog
import GeniusLocusKit
import LocusKit

/// Counts returned by an import run.
public struct ImportReport: Sendable, Equatable {

    /// Drawers captured for a lineage not previously present.
    public var drawersWritten: Int

    /// Re-imports that superseded an existing drawer (idempotent update).
    public var drawersUpdated: Int

    /// `.references` tunnels created across all notes (post-dedup).
    public var tunnelsCreated: Int

    /// Notes that could not be imported (e.g. empty content under I-5).
    public var itemsSkipped: Int

    /// Drawers whose UDC came from a live FDC anchor or an explicit
    /// frontmatter `udc`.
    public var fdcClassified: Int

    /// Drawers that landed with the `"000"` fallback UDC because no live
    /// FDC anchor resolved and no explicit `udc` was supplied.
    public var fdcUnclassified: Int

    /// Per-field count of imported notes whose value for that `NoteIR`
    /// field did not ride into the substrate (zero-loss invariant C-13:
    /// any dropped field is recorded, never silent). Keys are `NoteIR`
    /// field names; values are how many written/updated notes carried a
    /// non-default value that the current mapping does not persist.
    /// All structured fields now land: facts and scope land as KG facts;
    /// hierarchy lands as the full room path; tags land as KG facts
    /// (subject "tag:<t>", predicate "tagged"); kind != "note" lands as
    /// a KG fact (subject "record:kind", predicate "is"). This dictionary
    /// is currently empty for every fully-structured fixture.
    public var fieldsDropped: [String: Int]

    public init(
        drawersWritten: Int = 0,
        drawersUpdated: Int = 0,
        tunnelsCreated: Int = 0,
        itemsSkipped: Int = 0,
        fdcClassified: Int = 0,
        fdcUnclassified: Int = 0,
        fieldsDropped: [String: Int] = [:]
    ) {
        self.drawersWritten = drawersWritten
        self.drawersUpdated = drawersUpdated
        self.tunnelsCreated = tunnelsCreated
        self.itemsSkipped = itemsSkipped
        self.fdcClassified = fdcClassified
        self.fdcUnclassified = fdcUnclassified
        self.fieldsDropped = fieldsDropped
    }
}

/// Counts returned by an export run, including the per-tier exclusion
/// counts the ADR-007 Decision 2 bulk-channel rules produced. Exclusions
/// are reported, never silent (zero-loss reporting symmetry with C-13).
public struct ExportReport: Sendable, Equatable {

    /// Notes written to the vault.
    public var notesExported: Int

    /// Secret-tier drawers the scope filters admitted but the bulk channel
    /// excluded. Secret never rides bulk export, under any scope.
    public var excludedSecretTier: Int

    /// Private-tier (`.restricted`) drawers excluded because the scope did
    /// not carry the explicit private-tier opt-in
    /// (`VaultExportScope.includesPrivateTier`).
    public var excludedPrivateTier: Int

    /// The scope the export ran under.
    public var scope: VaultExportScope

    public init(
        notesExported: Int = 0,
        excludedSecretTier: Int = 0,
        excludedPrivateTier: Int = 0,
        scope: VaultExportScope = .believed
    ) {
        self.notesExported = notesExported
        self.excludedSecretTier = excludedSecretTier
        self.excludedPrivateTier = excludedPrivateTier
        self.scope = scope
    }
}

/// The public surface a control layer (ARIA_MCP, later) calls to bridge a
/// MOOT estate and a Markdown vault in both directions.
///
/// `VaultBridge` is a thin facade: `ObsidianAdapter` (or any
/// `VaultAdapter`) handles file ⇄ `NoteIR`, and `DrawerMapping` handles
/// `NoteIR` ⇄ substrate. The bridge fuses the two into one projection per
/// MOOT. Synchronous-per-call is sufficient for V1; the long-run enqueue,
/// drift detection, and watched-source scheduler are A2 (Stream va), not
/// here.
public struct VaultBridge: Sendable {

    private let kit: GeniusLocusKit
    private let adapter: VaultAdapter
    private let mapping: DrawerMapping

    private static let log = Logger(subsystem: "com.mootx01.kit", category: "VaultKit")

    /// - Parameters:
    ///   - kit: the opened `GeniusLocusKit` instance whose estates this
    ///     bridge reads and writes.
    ///   - adapter: the vault format adapter. Defaults to Obsidian.
    ///   - mapping: the substrate mapping policy (actor id, embedding-model
    ///     id, FDC feature flag). Defaults are import-safe.
    public init(
        kit: GeniusLocusKit,
        adapter: VaultAdapter = ObsidianAdapter(),
        mapping: DrawerMapping = DrawerMapping()
    ) {
        self.kit = kit
        self.adapter = adapter
        self.mapping = mapping
    }

    // MARK: - Export

    /// Project an estate to a Markdown vault — drawers → notes,
    /// `.references` tunnels → wikilinks, room → folders,
    /// provenance/anchors → frontmatter. One vault per MOOT.
    ///
    /// Enforces the ADR-007 Decision 2 privacy-tier rules on this bulk
    /// channel: secret-tier drawers never export, private-tier drawers
    /// export only under `.believedIncludingPrivate`, and every tier
    /// exclusion is counted in the returned `ExportReport` — visible,
    /// never silent. A successful run writes one audit receipt to the
    /// estate's diary (see `writeExportReceipt`).
    ///
    /// - Parameters:
    ///   - handle: the estate to project.
    ///   - vaultURL: the vault root directory to write under.
    ///   - scope: which drawers to include. Defaults to `.believed`,
    ///     which includes all currently-believed drawers regardless of
    ///     confirmation state — fixing the confirmed-drop bug from the
    ///     previous `.unconfirmed`-only filter.
    ///   - now: the operation instant, supplied by the caller (determinism
    ///     rule — the bridge never reads the wall clock) and stamped on the
    ///     audit receipt.
    /// - Returns: an `ExportReport` with the exported-note count and the
    ///   per-tier exclusion counts.
    @discardableResult
    public func export(
        estate handle: EstateHandle,
        to vaultURL: URL,
        scope: VaultExportScope = .believed,
        now: Date
    ) async throws -> ExportReport {
        let projection = try await mapping.export(kit: kit, handle: handle, scope: scope)
        try adapter.fromIR(projection.notes, to: vaultURL)
        let report = ExportReport(
            notesExported: projection.notes.count,
            excludedSecretTier: projection.excludedSecretTier,
            excludedPrivateTier: projection.excludedPrivateTier,
            scope: scope
        )
        try await writeExportReceipt(report, destination: vaultURL.path, handle: handle, now: now)
        Self.log.info("exported \(report.notesExported, privacy: .public) notes to vault (scope: \(scope.rawValue, privacy: .public), excluded secret: \(report.excludedSecretTier, privacy: .public), excluded private: \(report.excludedPrivateTier, privacy: .public))")
        return report
    }

    // MARK: - Import

    /// Import a Markdown vault into an estate via the capture seam.
    ///
    /// Idempotent on each note's `stableSourceKey`: a re-import supersedes
    /// the existing drawer (no duplicate) and creates no duplicate
    /// tunnels. Every captured drawer satisfies invariant I-5.
    ///
    /// Import is ungated (ADR-007: arrival is free), but each note's
    /// sensitivity tier is preserved from the IR when the adapter supplies
    /// it (`sensitivity` frontmatter → `CaptureFrame.sensitivity`). A
    /// successful run writes one audit receipt to the estate's diary (see
    /// `writeImportReceipt`).
    ///
    /// - Parameters:
    ///   - vaultURL: the vault root directory to read.
    ///   - handle: the estate to import into.
    ///   - now: the operation instant, supplied by the caller (determinism
    ///     rule — the bridge never reads the wall clock) and stamped on the
    ///     audit receipt.
    /// - Returns: an `ImportReport` with written/updated/tunnel/skipped
    ///   and FDC-classified counts.
    public func importVault(
        at vaultURL: URL,
        into handle: EstateHandle,
        now: Date
    ) async throws -> ImportReport {
        let notes = try adapter.toIR(vaultURL: vaultURL)
        return try await importNotes(notes, into: handle, source: vaultURL.path, now: now)
    }

    /// Import a filtered subset of a Markdown vault into an estate.
    ///
    /// Identical to `importVault(at:into:now:)` but restricts the import
    /// to notes whose vault-relative path is in `includingPaths`. Used by
    /// `moot_vault_reconcile` apply mode so only the added/modified
    /// candidates land in the estate and `drawersUpdated` reports the
    /// candidate count (M), not the full vault size (N).
    ///
    /// The adapter reads all notes from disk; the filter is applied before
    /// the capture loop — non-candidate notes never enter the estate at all.
    /// Idempotence per `stableSourceKey` is preserved: a candidate already
    /// present in the estate is updated, not duplicated.
    ///
    /// - Parameters:
    ///   - vaultURL: the vault root directory to read.
    ///   - includingPaths: vault-relative paths (e.g. `"Chem/Benzene.md"`)
    ///     of the notes to process. Paths not present on disk are silently
    ///     ignored (forward-slash, same format as the manifest keys).
    ///   - handle: the estate to import into.
    ///   - now: the operation instant, supplied by the caller (determinism
    ///     rule — the bridge never reads the wall clock) and stamped on the
    ///     audit receipt.
    /// - Returns: an `ImportReport` reflecting only the candidate set.
    public func importVault(
        at vaultURL: URL,
        includingPaths candidatePaths: Set<String>,
        into handle: EstateHandle,
        now: Date
    ) async throws -> ImportReport {
        let allNotes = try adapter.toIR(vaultURL: vaultURL)
        // Restrict to the candidate set. A note's vault-relative path is
        // stableSourceKey + ".md" (the inverse of what ObsidianAdapter uses
        // on read). Notes whose path is not in the candidate set are skipped
        // without entering the capture loop.
        let filteredNotes = allNotes.filter { note in
            candidatePaths.contains(note.stableSourceKey + ".md")
        }
        return try await importNotes(filteredNotes, into: handle, source: vaultURL.path, now: now)
    }

    /// Import one MemPalace palace directly into an estate — all three
    /// MemPalace stores (`palace/chroma.sqlite3`, `tunnels.json`,
    /// `knowledge_graph.sqlite3`) read READ-ONLY by
    /// `MemPalaceChromaAdapter` and fed through the same idempotent
    /// capture path as `importVault` (stable keys, tunnel dedup, audit
    /// receipt). See the adapter for the complete field → `NoteIR` table.
    ///
    /// - Parameters:
    ///   - palaceRoot: the palace root directory (e.g. `~/.mempalace`).
    ///   - handle: the estate to import into.
    ///   - now: the operation instant, supplied by the caller (determinism
    ///     rule) and stamped on the audit receipt.
    ///   - adapter: the MemPalace adapter; default reads the standard
    ///     collection names. Parameterized so tests can point at fixture
    ///     palaces with non-default collections.
    /// - Returns: an `ImportReport`, same semantics as `importVault`.
    public func importMemPalace(
        at palaceRoot: URL,
        into handle: EstateHandle,
        now: Date,
        adapter: MemPalaceChromaAdapter = MemPalaceChromaAdapter()
    ) async throws -> ImportReport {
        let notes = try adapter.toIR(vaultURL: palaceRoot)
        return try await importNotes(notes, into: handle, source: palaceRoot.path, now: now)
    }

    /// The shared import core: capture canonical notes into an estate via
    /// the capture seam. `importVault` and `importMemPalace` differ only
    /// in which adapter produced the notes; everything from the existing-
    /// state snapshot to the audit receipt is identical and lives here.
    private func importNotes(
        _ notes: [NoteIR],
        into handle: EstateHandle,
        source: String,
        now: Date
    ) async throws -> ImportReport {
        // Snapshot existing state once so written-vs-updated and tunnel
        // de-duplication need no per-note probe.
        let (existingLineageIDs, existingWings) = try await existingDrawerState(handle: handle)
        // The current tier of every believed drawer across ALL sensitivity
        // levels, so the import sensitivity floor can never be lowered by a
        // re-import (supersession-downgrade defense — see importNote).
        let existingSensitivityByLineage = try await existingSensitivityByLineage(handle: handle)
        var existingTunnelSignatures = try await existingTunnelSignatures(
            handle: handle, wings: existingWings
        )

        var report = ImportReport()
        for note in notes {
            let outcome = try await mapping.importNote(
                note,
                kit: kit,
                handle: handle,
                existingLineageIDs: existingLineageIDs,
                existingSensitivityByLineage: existingSensitivityByLineage,
                existingTunnelSignatures: &existingTunnelSignatures,
                now: now
            )
            switch outcome {
            case let .written(tunnels, classified):
                report.drawersWritten += 1
                report.tunnelsCreated += tunnels
                if classified { report.fdcClassified += 1 } else { report.fdcUnclassified += 1 }
                recordDroppedFields(of: note, in: &report)
            case let .updated(tunnels, classified):
                report.drawersUpdated += 1
                report.tunnelsCreated += tunnels
                if classified { report.fdcClassified += 1 } else { report.fdcUnclassified += 1 }
                recordDroppedFields(of: note, in: &report)
            case .skipped:
                report.itemsSkipped += 1
            }
        }

        try await writeImportReceipt(report, source: source, handle: handle, now: now)
        Self.log.info(
            "imported vault: \(report.drawersWritten, privacy: .public) written, \(report.drawersUpdated, privacy: .public) updated, \(report.itemsSkipped, privacy: .public) skipped"
        )
        return report
    }

    // MARK: - Audit receipts (ADR-007 Decision 2)

    /// Actor name receipts are filed under. Receipts are read back via
    /// `GeniusLocusKit.readDiaryEntries(in:agentName:lastN:)` with this name.
    public static let receiptAgentName = "vaultkit"

    /// Diary operational bitmap for a bulk-operation receipt, per spec § 5.6:
    /// `DiaryEventClass.migration` (bits 0–3 — "data migrated in or out of
    /// the estate"), `DiarySeverity.info` (bits 4–6), and
    /// `DiaryActorClass.migrationTool` (bits 7–9). Standalone batch
    /// membership and no follow-up flag (both zero).
    static let receiptBitmap: Int64 =
        Int64(DiaryEventClass.migration.rawValue)
        | (Int64(DiarySeverity.info.rawValue) << 4)
        | (Int64(DiaryActorClass.migrationTool.rawValue) << 7)

    /// Write the export receipt: one diary entry per successful export run
    /// (ADR-007 Decision 2 — "every bulk operation writes an audit receipt:
    /// what left, where, when, how many"). The bitmap-audit trail is per-row
    /// and cannot carry an estate-level payload, so receipts use the diary —
    /// the estate-level event log whose `migration` event class exists for
    /// exactly this (see DECISION_NEEDED_VK-TIER-01).
    ///
    /// The entry body is canonical JSON with a fixed key order, shared
    /// verbatim with the Rust port.
    private func writeExportReceipt(
        _ report: ExportReport,
        destination: String,
        handle: EstateHandle,
        now: Date
    ) async throws {
        let entry = """
        {"operation":"vault-export","scope":"\(report.scope.rawValue)",\
        "destination":\(Self.jsonString(destination)),\
        "notesExported":\(report.notesExported),\
        "excludedSecretTier":\(report.excludedSecretTier),\
        "excludedPrivateTier":\(report.excludedPrivateTier),\
        "occurredAt":"\(OccurredAt(date: now).iso8601)"}
        """
        try await writeReceipt(entry, handle: handle, now: now)
    }

    /// Write the import receipt: one diary entry per successful import run.
    /// Same channel and shape rationale as `writeExportReceipt`. Import has
    /// no tier exclusions (arrival is free); the counts mirror `ImportReport`.
    private func writeImportReceipt(
        _ report: ImportReport,
        source: String,
        handle: EstateHandle,
        now: Date
    ) async throws {
        let entry = """
        {"operation":"vault-import",\
        "source":\(Self.jsonString(source)),\
        "drawersWritten":\(report.drawersWritten),\
        "drawersUpdated":\(report.drawersUpdated),\
        "itemsSkipped":\(report.itemsSkipped),\
        "tunnelsCreated":\(report.tunnelsCreated),\
        "occurredAt":"\(OccurredAt(date: now).iso8601)"}
        """
        try await writeReceipt(entry, handle: handle, now: now)
    }


    /// File one receipt into the estate diary through the existing GLK
    /// write surface. `filedAt` carries the caller-supplied `now` so the
    /// receipt is deterministic and queryable by time.
    private func writeReceipt(_ entry: String, handle: EstateHandle, now: Date) async throws {
        try await kit.addDiaryEntry(in: handle, DiaryEntry(
            agentName: Self.receiptAgentName,
            entry: entry,
            topic: "vault-receipt",
            wing: "wing_vaultkit",
            room: "receipts",
            filedAt: now,
            // Receipts carry no embedding; the storage layer requires a
            // non-empty model id (same convention as the dreaming daemon).
            embeddingModelID: "no-embedding",
            operationalBitmap: Self.receiptBitmap
        ))
    }

    /// Minimal JSON string encoder for receipt fields that carry arbitrary
    /// filesystem paths (quotes/backslashes escaped per RFC 8259).
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Zero-loss accounting (C-13)

    /// Record which of an imported note's `NoteIR` fields did NOT ride
    /// into the substrate, per the zero-loss invariant C-13: a dropped
    /// field is recorded in the `ImportReport`, never silent.
    ///
    /// All structured `NoteIR` fields now land in the substrate:
    ///   - content → drawer content
    ///   - room (full hierarchy via pathComponents) → drawer room
    ///   - frontmatter-carried provenance → drawer capture frame fields
    ///   - links → `.references` tunnels
    ///   - origin date → drawer eventTime
    ///   - feature flags → drawer featureFlags bitmap
    ///   - facts → KG facts (subject/predicate/object)
    ///   - scope entries → KG facts (subject "scope:<key>")
    ///   - tags → KG facts (subject "tag:<t>", predicate "tagged")
    ///   - kind (when != "note") → KG fact (subject "record:kind")
    ///
    /// This method now reports nothing for any fully-structured note.
    /// The `fieldsDropped` dictionary remains in the public API for future
    /// additions and for any adapter that introduces genuinely unmappable
    /// fields.
    private func recordDroppedFields(of note: NoteIR, in report: inout ImportReport) {
        // All fields now land in substrate — nothing to record for the current
        // mapping. See doc comment above for the complete field disposition.
    }

    // MARK: - Snapshot helpers

    /// The lineage IDs of currently-believed drawers and the set of wings
    /// they occupy. Used to classify written vs. updated and to scope the
    /// tunnel-signature snapshot.
    private func existingDrawerState(
        handle: EstateHandle
    ) async throws -> (lineageIDs: Set<UUID>, wings: Set<String>) {
        // limit: 10_000_000 means "all drawers" — the same full-scan intent
        // as the sibling existingSensitivityByLineage call below. Without an
        // explicit limit the estate scan caps at 256, silently truncating
        // estates with more than 256 drawers and causing written-vs-updated
        // misclassification for drawers #257+.
        let drawers = try await kit.recall(
            handle,
            RecallFrame(
                // UserConfirmed: all rows written via Estate.capture are stamped at write time.
                filterChain: [.userConfirmed],
                hydrationLevel: .structured,
                limit: 10_000_000
            )
        )
        return (Set(drawers.map(\.lineageID)), Set(drawers.map(\.wing)))
    }

    /// The current sensitivity tier of every believed drawer, keyed by
    /// lineage (max across versions of a lineage). The recall lifts the
    /// evaluator's implicit `.elevated` ceiling with an explicit
    /// `.sensitivityAtMost(.secret)` so restricted and secret drawers are
    /// visible — they must be, or the import floor could not protect them.
    /// Used only to enforce the no-downgrade floor on re-import; it does not
    /// affect written-vs-updated classification.
    private func existingSensitivityByLineage(
        handle: EstateHandle
    ) async throws -> [UUID: AdjectiveSensitivity] {
        let drawers = try await kit.recall(
            handle,
            RecallFrame(
                filterChain: [
                    .currentlyBelieve,
                    .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                    .any([.trustworthy, .requiresConfirmation]),
                    .sensitivityAtMost(.secret),
                ],
                hydrationLevel: .structured,
                limit: 10_000_000
            )
        )
        var map: [UUID: AdjectiveSensitivity] = [:]
        for drawer in drawers {
            let tier = drawer.adjectiveSensitivity
            if let current = map[drawer.lineageID] {
                if tier.rawValue > current.rawValue { map[drawer.lineageID] = tier }
            } else {
                map[drawer.lineageID] = tier
            }
        }
        return map
    }

    /// The stable signatures of existing `.references` tunnels, so a
    /// re-import does not duplicate them.
    private func existingTunnelSignatures(
        handle: EstateHandle,
        wings: Set<String>
    ) async throws -> Set<String> {
        var signatures: Set<String> = []
        for wing in wings {
            let tunnels = try await kit.recallTunnels(handle, wing: wing)
            for tunnel in tunnels where tunnel.kind == .references {
                signatures.insert(DrawerMapping.tunnelSignature(
                    sourceWing: tunnel.sourceWing,
                    sourceRoom: tunnel.sourceRoom,
                    targetRoom: tunnel.targetRoom,
                    label: tunnel.label,
                    kind: tunnel.kind
                ))
            }
        }
        return signatures
    }
}
