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

    /// Re-imports whose lineage already has an ACTIVE drawer with
    /// byte-identical content. No supersession, no UUID rotation — true
    /// idempotent no-op. Fixes FINDING-1a: previously every re-import
    /// triggered the supersession cascade regardless of whether content
    /// had changed.
    public var drawersSkippedUnchanged: Int

    /// Re-imports whose lineage was previously erased (withdrawn) in
    /// the estate. The tombstone is respected; the note is NOT
    /// resurrected. Fixes FINDING-1b: previously an erased lineage
    /// would re-import as a fresh active drawer.
    public var drawersSkippedTombstoned: Int

    /// Re-imports where a DisciplineViolation fired AFTER the supersession
    /// cascade had already committed the successor drawer row but before the
    /// predecessor belief-state flip completed. The estate contains an
    /// orphaned successor alongside the un-flipped predecessor; unlike plain
    /// `itemsSkipped`, the write was partially applied. Never silent (zero-loss
    /// invariant C-13): callers must surface this count so a reconciliation
    /// pass can detect the gap.
    public var drawersSkippedPartialWrite: Int

    /// Number of drawers enqueued for semantic encoding after the import.
    ///
    /// The bulk `captureBatch` path intentionally skips the per-item encode
    /// enqueue to avoid flooding the queue for large imports. After the batch
    /// write completes, `importNotes` calls `reindexMissing` to enqueue
    /// encode jobs for every newly-imported drawer that is not yet in the
    /// Corpus BundleStore (capped at `reindexMaxJobs` = 10,000 per call).
    ///
    /// The per-item path (`kit.capture(mode:)`) enqueues each drawer
    /// individually; `enqueuedForEncode` is 0 for those runs.
    ///
    /// A value of 0 on a bulk import means either every drawer was already
    /// indexed (idempotent re-import) or the estate has no registered Corpus.
    public var enqueuedForEncode: Int

    public init(
        drawersWritten: Int = 0,
        drawersUpdated: Int = 0,
        tunnelsCreated: Int = 0,
        itemsSkipped: Int = 0,
        fdcClassified: Int = 0,
        fdcUnclassified: Int = 0,
        fieldsDropped: [String: Int] = [:],
        drawersSkippedUnchanged: Int = 0,
        drawersSkippedTombstoned: Int = 0,
        drawersSkippedPartialWrite: Int = 0,
        enqueuedForEncode: Int = 0
    ) {
        self.drawersWritten = drawersWritten
        self.drawersUpdated = drawersUpdated
        self.tunnelsCreated = tunnelsCreated
        self.itemsSkipped = itemsSkipped
        self.fdcClassified = fdcClassified
        self.fdcUnclassified = fdcUnclassified
        self.fieldsDropped = fieldsDropped
        self.drawersSkippedUnchanged = drawersSkippedUnchanged
        self.drawersSkippedTombstoned = drawersSkippedTombstoned
        self.drawersSkippedPartialWrite = drawersSkippedPartialWrite
        self.enqueuedForEncode = enqueuedForEncode
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
        scope: VaultExportScope = .exportable
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
/// Callback fired periodically during import/export to report progress.
public typealias VaultProgress = @Sendable (Int, Int) -> Void

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
    ///   - scope: which drawers to include. Defaults to `.exportable`
    ///     (CAND-032) — only drawers explicitly marked exportable, so a default
    ///     disk export never writes non-exportable/private rows. Broader scopes
    ///     (`.believed`, `.believedIncludingPrivate`) are explicit opt-ins.
    ///   - now: the operation instant, supplied by the caller (determinism
    ///     rule — the bridge never reads the wall clock) and stamped on the
    ///     audit receipt.
    /// - Returns: an `ExportReport` with the exported-note count and the
    ///   per-tier exclusion counts.
    @discardableResult
    public func export(
        estate handle: EstateHandle,
        to vaultURL: URL,
        scope: VaultExportScope = .exportable,
        now: Date,
        progress: VaultProgress? = nil
    ) async throws -> ExportReport {
        let projection = try await mapping.export(kit: kit, handle: handle, scope: scope)
        try adapter.fromIR(projection.notes, to: vaultURL, progress: progress)
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
    /// - Parameter mode: encode SPEED for the import's background encoding —
    ///   `.foreground` (default) drains hard, `.background` yields for very large
    ///   imports. SPEED only; the WRITE strategy (one bulk `captureBatch`
    ///   transaction vs per-item streaming) is chosen automatically by source
    ///   size (`ImportPolicy.streamThreshold`) — the same gate-agnostic policy
    ///   PalaceBridge uses.
    public func importVault(
        at vaultURL: URL,
        into handle: EstateHandle,
        now: Date,
        progress: VaultProgress? = nil,
        mode: EncodeSpeed = .foreground
    ) async throws -> ImportReport {
        let notes = try adapter.toIR(vaultURL: vaultURL)
        return try await importNotes(notes, into: handle, source: vaultURL.path, now: now, mode: mode)
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
    ///   - mode: encode SPEED (`.foreground` default / `.background`). The write
    ///     strategy is size-gated automatically (`ImportPolicy`) — a small
    ///     reconcile candidate set writes in one bulk transaction, a huge one
    ///     streams per-item.
    /// - Returns: an `ImportReport` reflecting only the candidate set.
    public func importVault(
        at vaultURL: URL,
        includingPaths candidatePaths: Set<String>,
        into handle: EstateHandle,
        now: Date,
        progress: VaultProgress? = nil,
        mode: EncodeSpeed = .foreground
    ) async throws -> ImportReport {
        let allNotes = try adapter.toIR(vaultURL: vaultURL)
        // Restrict to the candidate set. A note's vault-relative path is
        // stableSourceKey + ".md" (the inverse of what ObsidianAdapter uses
        // on read). Notes whose path is not in the candidate set are skipped
        // without entering the capture loop.
        let filteredNotes = allNotes.filter { note in
            candidatePaths.contains(note.stableSourceKey + ".md")
        }
        return try await importNotes(filteredNotes, into: handle, source: vaultURL.path, now: now, mode: mode)
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
    ///   - mode: encode SPEED (`.foreground` default / `.background`). The write
    ///     strategy (one bulk `captureBatch` transaction vs per-item streaming)
    ///     is chosen automatically by source size (`ImportPolicy`) — not by the
    ///     caller.
    /// - Returns: an `ImportReport`, same semantics as `importVault`.
    public func importMemPalace(
        at palaceRoot: URL,
        into handle: EstateHandle,
        now: Date,
        adapter: MemPalaceChromaAdapter = MemPalaceChromaAdapter(),
        progress: VaultProgress? = nil,
        mode: EncodeSpeed = .foreground
    ) async throws -> ImportReport {
        let notes = try adapter.toIR(vaultURL: palaceRoot)
        return try await importNotes(notes, into: handle, source: palaceRoot.path, now: now, mode: mode)
    }

    /// The shared import core: capture canonical notes into an estate via
    /// the capture seam. `importVault` and `importMemPalace` differ only
    /// in which adapter produced the notes; everything from the existing-
    /// state snapshot to the audit receipt is identical and lives here.
    ///
    /// When `batch` is `true`, all capture frames are collected upfront
    /// and written in one SQLite transaction via `captureBatch`, then
    /// post-capture work (KG facts, tunnels) is applied per-note. When
    /// `false`, the original per-note loop runs unchanged.
    private func importNotes(
        _ notes: [NoteIR],
        into handle: EstateHandle,
        source: String,
        now: Date,
        progress: VaultProgress? = nil,
        mode: EncodeSpeed = .foreground
    ) async throws -> ImportReport {
        // Declare the encode SPEED for this import's background drain before any
        // encode work is enqueued — the same gate-agnostic policy PalaceBridge
        // uses (T1/T7). SPEED only; the write strategy is size-gated below.
        await kit.setEncodeSpeed(mode, for: handle)
        // Snapshot existing state once so written-vs-updated and tunnel
        // de-duplication need no per-note probe.
        // existingContentByLineage: the verbatim content of every active
        // drawer keyed by lineageID — used by the content-idempotent check
        // (FINDING-1a) to skip re-imports where nothing changed.
        let (existingLineageIDs, existingWings, existingContentByLineage, existingStableSourceKeyByLineage) =
            try await existingDrawerState(handle: handle)
        // The current tier of every believed drawer across ALL sensitivity
        // levels, so the import sensitivity floor can never be lowered by a
        // re-import (supersession-downgrade defense — see importNote).
        let existingSensitivityByLineage = try await existingSensitivityByLineage(handle: handle)
        // tombstonedLineageIDs: lineage IDs that exist in the estate but
        // whose last known state is erased/withdrawn (FINDING-1b). A note
        // whose lineage is in this set must NOT be resurrected on re-import.
        let tombstonedLineageIDs = try await existingTombstonedLineageIDs(
            handle: handle, activeLineageIDs: existingLineageIDs)
        var existingTunnelSignatures = try await existingTunnelSignatures(
            handle: handle, wings: existingWings
        )

        var report = ImportReport()

        // Size gate (automatic — NOT user-controlled), single-sourced in
        // ImportPolicy so every source gate uses the same boundary: a source at
        // or below the threshold is written in one bulk `captureBatch`
        // transaction; a larger one streams per-item so no single transaction
        // holds the write lock across hundreds of thousands of notes.
        let useBulk = ImportPolicy.useBulk(itemCount: notes.count)
        if useBulk {
            // Bulk path: collect qualified (note, frame, isUpdate, classified)
            // tuples, submit all frames in one transaction, then apply post-capture
            // work (KG facts, tunnels) per-note using the returned drawer IDs.
            // Guard-skipped notes update report counters inside buildNoteFrame.
            var qualified: [(note: NoteIR, frame: CaptureFrame, isUpdate: Bool, classified: Bool)] = []
            for note in notes {
                if let (frame, isUpdate, classified) = mapping.buildNoteFrame(
                    for: note,
                    existingLineageIDs: existingLineageIDs,
                    existingSensitivityByLineage: existingSensitivityByLineage,
                    tombstonedLineageIDs: tombstonedLineageIDs,
                    existingContentByLineage: existingContentByLineage,
                    existingStableSourceKeyByLineage: existingStableSourceKeyByLineage,
                    report: &report
                ) {
                    qualified.append((note, frame, isUpdate, classified))
                }
            }
            if !qualified.isEmpty {
                let frames = qualified.map(\.frame)
                let drawers = try await kit.captureBatch(handle, frames)
                for (item, drawer) in zip(qualified, drawers) {
                    let tunnels = try await mapping.applyNotePostCapture(
                        note: item.note,
                        frame: item.frame,
                        drawer: drawer,
                        kit: kit,
                        handle: handle,
                        existingTunnelSignatures: &existingTunnelSignatures,
                        now: now
                    )
                    if item.isUpdate {
                        report.drawersUpdated += 1
                    } else {
                        report.drawersWritten += 1
                    }
                    report.tunnelsCreated += tunnels
                    if item.classified { report.fdcClassified += 1 } else { report.fdcUnclassified += 1 }
                    recordDroppedFields(of: item.note, in: &report)
                }
            }
        } else {
            // Per-item path: unchanged from before batch support was added.
            for note in notes {
                let outcome = try await mapping.importNote(
                    note,
                    kit: kit,
                    handle: handle,
                    existingLineageIDs: existingLineageIDs,
                    existingSensitivityByLineage: existingSensitivityByLineage,
                    tombstonedLineageIDs: tombstonedLineageIDs,
                    existingContentByLineage: existingContentByLineage,
                    existingStableSourceKeyByLineage: existingStableSourceKeyByLineage,
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
                case .skippedUnchanged:
                    // Content-idempotent no-op: lineage active, content unchanged.
                    // No substrate write occurs; the count is surfaced for observability.
                    report.drawersSkippedUnchanged += 1
                case .skippedTombstoned:
                    // Tombstone respected: lineage was erased, not resurrected.
                    // Surfaced in the report so callers know which notes were blocked.
                    report.drawersSkippedTombstoned += 1
                case .skippedWithPartialWrite:
                    // Partial write: successor row committed, predecessor not flipped.
                    // The estate has an orphaned successor; count surfaced for
                    // reconciliation — never absorbed into itemsSkipped.
                    report.drawersSkippedPartialWrite += 1
                }
            }
        }

        // Encode-enqueue sweep: the bulk `captureBatch` path intentionally skips
        // the per-item encode hook (to avoid O(N) queue writes inside a single
        // transaction on large imports). After the batch write completes, enqueue
        // all newly-imported drawers that are not yet in the Corpus BundleStore via
        // `reindexMissing` (idempotent, capped at reindexMaxJobs = 10,000 per call).
        // The per-item path uses `kit.capture(mode:)` which enqueues each drawer
        // individually, so the sweep is a no-op (returns 0) for those runs.
        report.enqueuedForEncode = try await kit.reindexMissing(handle: handle, now: now)

        try await writeImportReceipt(report, source: source, handle: handle, now: now)
        Self.log.info(
            "imported vault: \(report.drawersWritten, privacy: .public) written, \(report.drawersUpdated, privacy: .public) updated, \(report.itemsSkipped, privacy: .public) skipped, \(report.drawersSkippedUnchanged, privacy: .public) unchanged, \(report.drawersSkippedTombstoned, privacy: .public) tombstoned, \(report.drawersSkippedPartialWrite, privacy: .public) partial-write (DisciplineViolation after cascade), \(report.enqueuedForEncode, privacy: .public) enqueued for encode"
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
        "drawersSkippedPartialWrite":\(report.drawersSkippedPartialWrite),\
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

    /// The lineage IDs and wing set of currently-believed drawers, plus a
    /// map from lineageID → verbatim content for the content-idempotent
    /// check (FINDING-1a).
    ///
    /// `existingContentByLineage` is keyed by lineageID and stores the
    /// content of the current best-believed drawer for that lineage. When
    /// a lineage has more than one believed row (unusual but possible during
    /// a supersession race), the first one encountered wins — the check is
    /// conservative: if any active content matches the import content, no
    /// supersession is issued.
    ///
    /// Hydration: `.full` is required to populate `drawer.content`; the
    /// `.structured` hydration level reads metadata rows only and leaves
    /// content blank.
    private func existingDrawerState(
        handle: EstateHandle
    ) async throws -> (lineageIDs: Set<UUID>, wings: Set<String>, contentByLineage: [UUID: String], stableSourceKeyByLineage: [UUID: String]) {
        // limit: 10_000_000 means "all drawers" — the same full-scan intent
        // as the sibling existingSensitivityByLineage call below. Without an
        // explicit limit the estate scan caps at 256, silently truncating
        // estates with more than 256 drawers and causing written-vs-updated
        // misclassification for drawers #257+.
        // Hydration level is .full so drawer.content is populated for the
        // content-idempotent check (FINDING-1a). The cost is one extra blob
        // read per drawer versus .structured, which is acceptable at import time
        // since the vault is the authoritative source being reconciled.
        //
        // Security (Finding 6 — all-tier gap): the scan must cover ALL active
        // (non-tombstoned) drawers regardless of confirmation state or sensitivity
        // tier. The previous filterChain: [.unconfirmed] made confirmed, restricted,
        // and secret lineages invisible to the collision guard — a hostile vault note
        // claiming one of those lineage UUIDs with different content would bypass
        // the guard and poison that lineage. The fix mirrors existingSensitivityByLineage,
        // which already lifts the sensitivity ceiling to .secret for the same reason.
        // This is an internal integrity guard only: lineage IDs and content hashes are
        // read locally for collision detection and never leave this function.
        let drawers = try await kit.recall(
            handle,
            RecallFrame(
                filterChain: [
                    .currentlyBelieve,
                    .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                    .any([.trustworthy, .requiresConfirmation]),
                    .sensitivityAtMost(.secret),
                ],
                hydrationLevel: .full,
                limit: 10_000_000
            )
        )
        // Resolve display names (wing, room) from the node tree in one batch
        // (ADR-017: Drawer no longer stores wing/room).
        let estate = try await kit.estate(for: handle)
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: drawers.map(\.parentNodeId))

        var lineageIDs: Set<UUID> = []
        var wings: Set<String> = []
        var contentByLineage: [UUID: String] = [:]
        // stableSourceKeyByLineage: the vault path ("<wing>/<room>/<slug>") that
        // the export would assign to each drawer. Used by the lineage-hijack guard
        // (path-identity discriminator) to distinguish a legitimate round-trip edit
        // (same file, same path) from a hostile note at a different path claiming
        // the victim's moot_id. Computed from the CURRENT estate content and
        // node-tree names — the same inputs the export uses — so this key exactly
        // matches the stableSourceKey a note carries when it returns from an export.
        // First-seen wins (matches the contentByLineage policy above).
        var stableSourceKeyByLineage: [UUID: String] = [:]
        for drawer in drawers {
            lineageIDs.insert(drawer.lineageID)
            if let names = nodeNames[drawer.parentNodeId] {
                wings.insert(names.wing)
                // Compute the vault path the export would use for this drawer so
                // the hijack guard can compare against the incoming note's path.
                if stableSourceKeyByLineage[drawer.lineageID] == nil {
                    let slug = DrawerMapping.slug(from: drawer.content, id: drawer.lineageID)
                    stableSourceKeyByLineage[drawer.lineageID] = "\(names.wing)/\(names.room)/\(slug)"
                }
            }
            // Store the first-seen content for each lineageID. When multiple
            // rows share a lineage (supersession race), any content match
            // prevents an unnecessary supersession — conservative is correct.
            if contentByLineage[drawer.lineageID] == nil {
                contentByLineage[drawer.lineageID] = drawer.content
            }
        }
        return (lineageIDs, wings, contentByLineage, stableSourceKeyByLineage)
    }

    /// The set of lineage IDs the import path must not resurrect — lineages
    /// that have been deliberately deleted (state = 18 withdrawn, or cluster C
    /// erased/tombstoned) minus any lineage that currently has an active head.
    ///
    /// ## What belongs in the tombstone set
    ///
    /// Only genuinely-removed lineages block re-import. "Withdrawn" (state 18)
    /// is the explicit operator-retraction: the user or agent deliberately said
    /// "this note should not resurface." Cluster C (rejected=32, tombstoned=33)
    /// is a legal-compliance hard delete. Neither should be undone by a vault
    /// re-import.
    ///
    /// The previous implementation used `.usedToBelieve` (all of cluster B:
    /// superseded=16, decayed=17, withdrawn=18, expired=19). That incorrectly
    /// treated normal content-update predecessors as tombstones:
    ///
    ///   1. Import note (v1) → drawer1 (lineage L, state active)
    ///   2. Import updated note (v2) → supersession cascade: drawer1 becomes
    ///      (L, superseded), drawer2 created (L, active). Update succeeds.
    ///   3. Import updated note (v3) → `usedToBelieve` returns drawer1 (L,
    ///      superseded) → L in tombstone set → tombstone guard fires before
    ///      the active-head / sensitivity-upgrade branch → `.skippedTombstoned`
    ///      → update BLOCKED. Sensitivity raises after any content update
    ///      were permanently blocked by the same false positive.
    ///
    /// Fix: restrict the cluster-B recall to `Filter.state(.withdrawn)` only —
    /// the single state value that represents a deliberate operator retraction
    /// with no active successor. Belt-and-suspenders: subtract `activeLineageIDs`
    /// so a lineage cannot be simultaneously active and in the tombstone set,
    /// guarding against any future cluster-B state that might also have
    /// active successors.
    ///
    /// - Parameter activeLineageIDs: the set of lineages with a currently-
    ///   believed active drawer, computed by `existingDrawerState` immediately
    ///   before this call. Used as the subtraction mask.
    private func existingTombstonedLineageIDs(
        handle: EstateHandle,
        activeLineageIDs: Set<UUID>
    ) async throws -> Set<UUID> {
        // Cluster B — withdrawn only (state = 18): explicit operator retraction.
        //
        // NOT .usedToBelieve (all of cluster B): superseded (16) is a normal
        // content-update predecessor, decayed (17) is matrix-confidence decay,
        // expired (19) is TTL expiry — all three can coexist with an active
        // successor and must not block re-import. Only withdrawn (18) means
        // "deliberately removed; do not resurface."
        let withdrawnDrawers = try await kit.recall(
            handle,
            RecallFrame(
                filterChain: [.state(.withdrawn)],
                hydrationLevel: .structured,
                limit: 10_000_000
            )
        )
        // Belt-and-suspenders: subtract the active-head set so a lineage can
        // never be simultaneously active and tombstoned. This is a defence-in-
        // depth guard — under the corrected .state(.withdrawn) filter no
        // withdrawn lineage should have an active head; the subtraction guards
        // against any edge case where that assumption is violated.
        let withdrawnIDs = Set(withdrawnDrawers.map(\.lineageID))
            .subtracting(activeLineageIDs)

        // Cluster C: expunged/tombstoned lineages (tombstonedAt != nil,
        // state ≥ 32). Invisible to the recall pipeline. Reached via the
        // GLK passthrough to Estate.allDrawers() — the only scan that
        // includes tombstoned rows. B-1 compliant: VaultKit never imports
        // LocusKit's DrawerStore directly.
        let erasedIDs = try await kit.tombstonedLineageIDs(handle)

        return withdrawnIDs.union(erasedIDs)
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
