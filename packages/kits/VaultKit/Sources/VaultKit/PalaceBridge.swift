import Foundation
import OSLog
import GeniusLocusKit
import LocusKit

/// Direct palace → substrate import, bypassing NoteIR.
///
/// `PalaceBridge` reads the three MemPalace stores (chroma.sqlite3,
/// tunnels.json, knowledge_graph.sqlite3) and builds `CaptureFrame`s
/// natively. It is a parallel import path to the NoteIR pipeline
/// (`VaultBridge.importMemPalace`) — both exist; neither replaces the other.
///
/// ## Import guards (identical to VaultBridge)
///
/// 1. **Tombstone protection** — lineages that were withdrawn or erased
///    are never resurrected by a re-import.
/// 2. **Content-idempotent dedup** — a drawer whose lineageID is already
///    active and whose content is unchanged is counted as `drawersSkippedUnchanged`.
/// 3. **Sensitivity floor** — the import never lowers an existing drawer's
///    sensitivity tier.
/// 4. **Tunnel signature dedup** — a tunnel already present is not recreated.
///
/// ## KGFact temporal validity
///
/// `KGFact` has no `validFrom` / `validTo` / `confidence` stored fields.
/// When a KG triple carries those values, additional KGFacts are filed
/// with predicates `"temporal:valid_from"`, `"temporal:valid_to"`, and
/// `"temporal:confidence"`, anchored to the source triple ID. This
/// preserves temporal provenance without a schema change.
///
/// ## Usage
///
/// ```swift
/// let bridge = PalaceBridge(kit: glk)
/// let report = try await bridge.importPalace(at: palaceRoot, into: handle, now: now)
/// ```
public struct PalaceBridge: Sendable {

    private let kit: GeniusLocusKit
    private let log = Logger(subsystem: "com.mootx01.kit", category: "VaultKit")

    // Default field values that mirror VaultBridge / DrawerMapping defaults.
    static let addedBy = "palacebridge-import"
    static let embeddingModelID = "vaultkit-noembed-v1"
    // UDC sentinel for items without a pre-classified code.
    static let fallbackUDC = "000"

    // Collection names match MemPalaceChromaAdapter defaults — all palace files
    // created by MemPalaceChromaAdapter use these names.
    private static let drawersCollection = "mempalace_drawers"
    private static let closetsCollection = "mempalace_closets"

    public init(kit: GeniusLocusKit) {
        self.kit = kit
    }

    // MARK: - Public API

    /// Import a MemPalace at `palaceRoot` directly into `handle`, bypassing NoteIR.
    ///
    /// Reads all three palace stores and builds `CaptureFrame`s natively.
    /// Returns an `ImportReport` with counts of writes, updates, skips, and
    /// tunnels created. A receipt diary entry is filed under `VaultBridge.receiptAgentName`.
    ///
    /// - Parameters:
    ///   - palaceRoot: Filesystem URL for the palace root directory (the folder
    ///     that contains the `palace/` subdirectory holding `chroma.sqlite3`).
    ///   - handle: The estate to import into.
    ///   - now: Caller-supplied timestamp (determinism — never call `Date()` inside).
    ///   - mode: The encode SPEED (drain QoS) for the import's background
    ///     encoding: `.foreground` (default) drains hard on the performance
    ///     cores; `.background` yields for very large imports. SPEED only — the
    ///     WRITE strategy is chosen automatically by source size (see
    ///     `streamThreshold`): a source at or below the threshold is written in
    ///     one bulk transaction (`captureBatch`; post-import `reindex` enqueues
    ///     the encoding); a larger source streams via per-item `capture()`
    ///     (inline classification, encoding enqueued per row) so no single
    ///     transaction holds the write lock across hundreds of thousands of rows.
    public func importPalace(
        at palaceRoot: URL,
        into handle: EstateHandle,
        now: Date,
        progress: VaultProgress? = nil,
        mode: EncodeSpeed = .foreground
    ) async throws -> ImportReport {
        // Pre-read tunnels.json so their source wings are available before the
        // existingTunnelSignatures snapshot. Without this, a re-import would not
        // find tunnels created by a prior import (their sourceWing comes from
        // the JSON, not from the drawer wing set).
        let tunnelsURL = palaceRoot
            .appendingPathComponent(MemPalaceChromaAdapter.tunnelsRelativePath)
        var preloadedTunnelRecords: [MemPalaceChromaAdapter.TunnelRecord] = []
        if FileManager.default.fileExists(atPath: tunnelsURL.path) {
            let data = try Data(contentsOf: tunnelsURL)
            do {
                preloadedTunnelRecords = try JSONDecoder().decode(
                    [MemPalaceChromaAdapter.TunnelRecord].self, from: data
                )
            } catch {
                throw VaultKitError.adapterError(
                    "tunnels.json is malformed at \(tunnelsURL.path): \(error)")
            }
        }

        // Snapshot existing estate state once before any writes so all guards
        // run against a stable baseline — no per-row probes during the loop.
        let (existingLineageIDs, existingWings, existingContentByLineage) =
            try await existingDrawerState(handle: handle)
        let existingSensitivityByLineage =
            try await existingSensitivityByLineage(handle: handle)
        let tombstonedLineageIDs =
            try await existingTombstonedLineageIDs(handle: handle)
        // Include tunnel source wings in the signature scan: tunnels created by
        // a prior import have sourceWing from the JSON, not from the drawer tree.
        let tunnelSourceWings = Set(preloadedTunnelRecords.map(\.source.wing))
        var existingTunnelSignatures = try await existingTunnelSignatures(
            handle: handle, wings: existingWings.union(tunnelSourceWings)
        )

        // Fetch the estate actor once; needed for tunnel capture via estate.capture(_:).
        let estate = try await kit.estate(for: handle)

        // Declare the encode SPEED for this import's background drain before any
        // encode work is enqueued. SPEED only (foreground hard / background
        // gentle) — the write strategy below is size-gated, not set here.
        await kit.setEncodeSpeed(mode, for: handle)

        var report = ImportReport()
        var processed = 0
        // Total chroma drawer count, set once the rows are gathered below.
        // Passed to the progress callback so it reports `processed/total`
        // (not `/0`); fired every 10 records for live feedback on long imports.
        var total = 0

        // --- Store 1: chroma.sqlite3 (drawers and closets) ---
        let chromaPath = palaceRoot
            .appendingPathComponent(MemPalaceChromaAdapter.chromaRelativePath).path
        if FileManager.default.fileExists(atPath: chromaPath) {
            let db = try SQLiteReadOnly(path: chromaPath)
            // Gather all chroma rows across both collections up front so the
            // progress callback can report a real total instead of 0. The
            // rows are materialized once (no double read).
            var allRows: [(embeddingID: String, metadata: [String: String], isCloset: Bool)] = []
            for (collection, isCloset) in [
                (Self.drawersCollection, false), (Self.closetsCollection, true)
            ] {
                guard let segmentID = try MemPalaceChromaAdapter.metadataSegmentID(
                    db: db, collection: collection
                ) else { continue }
                for (embeddingID, metadata) in try MemPalaceChromaAdapter.metadataRows(
                    db: db, segmentID: segmentID
                ) {
                    allRows.append((embeddingID, metadata, isCloset))
                }
            }
            total = allRows.count

            // STREAMED IMPORT PATH — DISABLED (2026-07-02). We believe the per-item
            // streaming write path is no longer necessary and should be REMOVED at
            // the 1.1 release gate if this holds true. Rationale: the bulk
            // captureBatch path below handles every realistic import; the old stream
            // branch engaged ONLY above ImportPolicy.streamThreshold (250_000 items
            // in ONE source), which no real import reaches. So the bulk path now runs
            // UNCONDITIONALLY. The `useBulk` size gate and the per-item `else` branch
            // are preserved verbatim below, commented, for the 1.1 review — not
            // deleted:
            //
            //   let useBulk = ImportPolicy.useBulk(itemCount: total)
            //   if useBulk { /* bulk path — now the sole path, below */ } else {
            //       // Stream write: per-item capture; one transaction per row so no
            //       // single transaction holds the write lock across hundreds of
            //       // thousands of rows.
            //       for row in allRows {
            //           try await importChromaRow(
            //               embeddingID: row.embeddingID, metadata: row.metadata,
            //               isCloset: row.isCloset, handle: handle,
            //               existingLineageIDs: existingLineageIDs,
            //               existingSensitivityByLineage: existingSensitivityByLineage,
            //               tombstonedLineageIDs: tombstonedLineageIDs,
            //               existingContentByLineage: existingContentByLineage,
            //               now: now, report: &report)
            //           processed += 1
            //           if processed % 10 == 0 { progress?(processed, total) }
            //       }
            //   }
            do {
                // Bulk write: collect all frames, then captureBatch for one transaction.
                var batchFrames: [CaptureFrame] = []
                for row in allRows {
                    if let (frame, isUpdate) = buildChromaFrame(
                        embeddingID: row.embeddingID,
                        metadata: row.metadata,
                        isCloset: row.isCloset,
                        existingLineageIDs: existingLineageIDs,
                        existingSensitivityByLineage: existingSensitivityByLineage,
                        tombstonedLineageIDs: tombstonedLineageIDs,
                        existingContentByLineage: existingContentByLineage,
                        now: now,
                        report: &report
                    ) {
                        batchFrames.append(frame)
                        if isUpdate { report.drawersUpdated += 1 } else { report.drawersWritten += 1 }
                        report.fdcUnclassified += 1
                        processed += 1
                        if processed % 10 == 0 { progress?(processed, total) }
                    }
                }
                if !batchFrames.isEmpty {
                    _ = try await kit.captureBatch(handle, batchFrames)
                }
            }
        }

        // --- Store 2: tunnels.json (preloaded above for snapshot) ---
        for record in preloadedTunnelRecords {
            try await importTunnelRecord(
                record,
                estate: estate,
                existingSignatures: &existingTunnelSignatures,
                report: &report
            )
        }

        // --- Store 3: knowledge_graph.sqlite3 ---
        let kgPath = palaceRoot
            .appendingPathComponent(MemPalaceChromaAdapter.knowledgeGraphRelativePath).path
        if FileManager.default.fileExists(atPath: kgPath) {
            let db = try SQLiteReadOnly(path: kgPath)

            // KG entities: each entity becomes a drawer in knowledge_graph/entities.
            for row in try db.query(
                "SELECT id, name, type, properties, created_at FROM entities ORDER BY id"
            ) {
                guard let id = row[0] else { continue }
                try await importKGEntity(
                    id: id, name: row[1] ?? "",
                    createdAt: row[4],
                    handle: handle,
                    existingLineageIDs: existingLineageIDs,
                    existingSensitivityByLineage: existingSensitivityByLineage,
                    tombstonedLineageIDs: tombstonedLineageIDs,
                    existingContentByLineage: existingContentByLineage,
                    now: now,
                    report: &report
                )
            }

            // CAND-042 anchor-check snapshot: taken AFTER all drawer/entity
            // imports are complete so that triples referencing drawers from
            // the SAME palace import are not incorrectly rejected. The anchor
            // set is the union of pre-import lineages and lineages added in
            // this call's chroma + entity passes.
            let (postImportLineageIDs, _, _) = try await existingDrawerState(handle: handle)

            // Snapshot existing KG facts once before the triple loop so the
            // re-import dedup guard (CAND-049) can run without a per-fact probe.
            // The signature uses ASCII Unit Separator (U+001F) as a delimiter —
            // see importKGTriple for the full rationale.
            let existingKGFacts = try await kit.recallKGFacts(handle)
            var existingKGSignatures: Set<String> = Set(existingKGFacts.map {
                "\($0.subject)\u{1F}\($0.predicate)\u{1F}\($0.object)\u{1F}\($0.sourceDrawerID)"
            })

            // KG triples: each triple becomes a KGFact. Temporal validity
            // (valid_from, valid_to, confidence) is encoded as additional KGFacts
            // because KGFact has no stored temporal validity fields.
            for row in try db.query(
                """
                SELECT id, subject, predicate, object, valid_from, valid_to,
                       CAST(confidence AS TEXT), source_drawer_id
                FROM triples ORDER BY id
                """
            ) {
                guard let id = row[0] else { continue }
                try await importKGTriple(
                    id: id,
                    subject: row[1] ?? "",
                    predicate: row[2] ?? "",
                    object: row[3] ?? "",
                    validFrom: row[4],
                    validTo: row[5],
                    confidenceText: row[6],
                    sourceDrawerID: row[7] ?? "",
                    handle: handle,
                    existingLineageIDs: postImportLineageIDs,
                    tombstonedLineageIDs: tombstonedLineageIDs,
                    existingKGSignatures: &existingKGSignatures,
                    now: now,
                    report: &report
                )
            }
        }

        try await writeImportReceipt(report, source: palaceRoot.path, handle: handle, now: now)
        log.info(
            """
            palace-bridge import: \(report.drawersWritten, privacy: .public) written, \
            \(report.drawersUpdated, privacy: .public) updated, \
            \(report.itemsSkipped, privacy: .public) skipped, \
            \(report.drawersSkippedUnchanged, privacy: .public) unchanged, \
            \(report.drawersSkippedTombstoned, privacy: .public) tombstoned, \
            \(report.tunnelsCreated, privacy: .public) tunnels
            """
        )
        // Final 100% tick so the caller sees completion at the true total.
        if processed > 0 { progress?(processed, total) }
        return report
    }

    // MARK: - Exportability derivation

    /// Exportability adjective for imported palace content. Palace/markdown
    /// sources are already-public material, so the policy default is `.public_`
    /// (a `.private_` default would wrongly wall off content that was never
    /// protected). A frontmatter `exportability:` label overrides the default.
    /// Clamped to `.private_` when sensitivity is `.secret`: the capture gate
    /// rejects a secret+public row (invariant I-22), so a secret classification
    /// always wins over the public source default.
    private static func importExportability(
        label: String?,
        sensitivity: AdjectiveSensitivity
    ) -> AdjectiveExportability {
        if sensitivity == .secret { return .private_ }
        return label.flatMap { DrawerMapping.exportability(fromLabel: $0) } ?? .public_
    }

    // MARK: - Chroma row import

    private func importChromaRow(
        embeddingID: String,
        metadata: [String: String],
        isCloset: Bool,
        handle: EstateHandle,
        existingLineageIDs: Set<UUID>,
        existingSensitivityByLineage: [UUID: AdjectiveSensitivity],
        tombstonedLineageIDs: Set<UUID>,
        existingContentByLineage: [UUID: String],
        now: Date,
        report: inout ImportReport
    ) async throws {
        let content = metadata["chroma:document"] ?? ""
        // Rows with no content produce empty-content drawers that violate I-5
        // and never surface in recall — skip and count as itemsSkipped.
        guard !content.isEmpty else {
            report.itemsSkipped += 1
            return
        }

        let lineageID = DrawerMapping.lineageID(forStableSourceKey: embeddingID)

        // Guard 1: tombstone protection — never resurrect a withdrawn/erased lineage.
        if tombstonedLineageIDs.contains(lineageID) {
            report.drawersSkippedTombstoned += 1
            return
        }

        // Guard 3: sensitivity floor — never lower an existing drawer's tier.
        // Parsed BEFORE the content-idempotent dedup guard so a re-import of
        // unchanged content that carries a higher sensitivity tier still applies
        // the upgrade (the content-skip guard must not short-circuit a pending
        // sensitivity promotion).
        let requestedSensitivity = DrawerMapping.sensitivity(fromLabel: metadata["sensitivity"] ?? "") ?? .normal
        let flooredSensitivity: AdjectiveSensitivity
        if let floor = existingSensitivityByLineage[lineageID],
           floor.rawValue > requestedSensitivity.rawValue {
            flooredSensitivity = floor
        } else {
            flooredSensitivity = requestedSensitivity
        }

        // Guard 2: content-idempotent dedup — skip only when BOTH the content is
        // unchanged AND no sensitivity upgrade is pending. An upgrade from (say)
        // .normal → .elevated on unchanged content is a legitimate write that must
        // not be suppressed.
        let existingTierRaw = existingSensitivityByLineage[lineageID]?.rawValue
        let isSensitivityUpgrade = existingTierRaw.map { flooredSensitivity.rawValue > $0 } ?? false
        if existingContentByLineage[lineageID] == content, !isSensitivityUpgrade {
            report.drawersSkippedUnchanged += 1
            return
        }

        let wing: String? = nonEmpty(metadata["wing"])
        let room = resolveRoom(frontmatter: metadata, wingKey: wing)

        let eventTime: Date? = metadata["filed_at"]
            .flatMap(MemPalaceChromaAdapter.canonicalISO8601(fromMemPalace:))
            .flatMap { parseISO8601($0) }

        let frame = CaptureFrame(
            content: content,
            channel: .importedFile,
            room: room,
            // UDC "000" = unclassified sentinel; the GLK capture seam classifies
            // content on ingestion when the sentinel is present.
            latticeAnchor: LatticeAnchor(udcCode: Self.fallbackUDC),
            addedBy: Self.addedBy,
            embeddingModelID: Self.embeddingModelID,
            sensitivity: flooredSensitivity,
            // Prose is the correct kind for palace drawer text content.
            kind: .prose,
            lineageID: lineageID,
            eventTime: eventTime ?? now,
            exportability: Self.importExportability(
                label: metadata["exportability"], sensitivity: flooredSensitivity),
            wing: wing
        )

        let isUpdate = existingLineageIDs.contains(lineageID)
        _ = try await kit.capture(handle, frame)

        if isUpdate {
            report.drawersUpdated += 1
        } else {
            report.drawersWritten += 1
        }
        // Palace rows carry no pre-classified UDC; all count as unclassified.
        report.fdcUnclassified += 1
    }

    // MARK: - Batch frame builder

    /// Apply the three import guards and build a `CaptureFrame` for the chroma
    /// row, without calling `kit.capture`. Returns `nil` (with `report` counters
    /// updated for the skip) when any guard fires. Used by the batch path so all
    /// frames can be collected first and submitted in a single `captureBatch` call.
    ///
    /// The caller is responsible for incrementing `drawersWritten`/`drawersUpdated`
    /// and `fdcUnclassified` on a non-nil return so the report stays consistent.
    private func buildChromaFrame(
        embeddingID: String,
        metadata: [String: String],
        isCloset: Bool,
        existingLineageIDs: Set<UUID>,
        existingSensitivityByLineage: [UUID: AdjectiveSensitivity],
        tombstonedLineageIDs: Set<UUID>,
        existingContentByLineage: [UUID: String],
        now: Date,
        report: inout ImportReport
    ) -> (CaptureFrame, isUpdate: Bool)? {
        let content = metadata["chroma:document"] ?? ""
        guard !content.isEmpty else {
            report.itemsSkipped += 1
            return nil
        }
        let lineageID = DrawerMapping.lineageID(forStableSourceKey: embeddingID)
        if tombstonedLineageIDs.contains(lineageID) {
            report.drawersSkippedTombstoned += 1
            return nil
        }
        // Sensitivity floor parsed BEFORE the content-idempotent skip so a
        // re-import of unchanged content that carries a higher sensitivity tier
        // still applies the upgrade. See importChromaRow for the same pattern.
        let requestedSensitivity = DrawerMapping.sensitivity(fromLabel: metadata["sensitivity"] ?? "") ?? .normal
        let flooredSensitivity: AdjectiveSensitivity
        if let floor = existingSensitivityByLineage[lineageID],
           floor.rawValue > requestedSensitivity.rawValue {
            flooredSensitivity = floor
        } else {
            flooredSensitivity = requestedSensitivity
        }
        let existingTierRaw = existingSensitivityByLineage[lineageID]?.rawValue
        let isSensitivityUpgrade = existingTierRaw.map { flooredSensitivity.rawValue > $0 } ?? false
        if existingContentByLineage[lineageID] == content, !isSensitivityUpgrade {
            report.drawersSkippedUnchanged += 1
            return nil
        }
        let wing: String? = nonEmpty(metadata["wing"])
        let room = resolveRoom(frontmatter: metadata, wingKey: wing)
        let eventTime: Date? = metadata["filed_at"]
            .flatMap(MemPalaceChromaAdapter.canonicalISO8601(fromMemPalace:))
            .flatMap { parseISO8601($0) }
        let frame = CaptureFrame(
            content: content,
            channel: .importedFile,
            room: room,
            latticeAnchor: LatticeAnchor(udcCode: Self.fallbackUDC),
            addedBy: Self.addedBy,
            embeddingModelID: Self.embeddingModelID,
            sensitivity: flooredSensitivity,
            kind: .prose,
            lineageID: lineageID,
            eventTime: eventTime ?? now,
            exportability: Self.importExportability(
                label: metadata["exportability"], sensitivity: flooredSensitivity),
            wing: wing
        )
        let isUpdate = existingLineageIDs.contains(lineageID)
        return (frame, isUpdate)
    }

    // MARK: - Tunnel record import

    /// Import one tunnel record from tunnels.json, respecting signature dedup.
    private func importTunnelRecord(
        _ record: MemPalaceChromaAdapter.TunnelRecord,
        estate: Estate,
        existingSignatures: inout Set<String>,
        report: inout ImportReport
    ) async throws {
        let rawLabel = record.label ?? ""
        // Use a meaningful label even for unlabeled tunnels (I-5: non-empty body).
        // The resolved label is computed BEFORE the signature so the signature
        // matches what gets stored — empty raw labels are filled in here, and
        // the stored tunnel uses the same filled-in value.
        let resolvedLabel = rawLabel.isEmpty
            ? "\(record.source.wing)/\(record.source.room) -> \(record.target.wing)/\(record.target.room)"
            : rawLabel

        // Guard 4: tunnel signature dedup — skip already-present tunnels.
        // Signature uses resolvedLabel (the label that was actually stored) so
        // lookups on re-import match what a prior import wrote.
        let sig = DrawerMapping.tunnelSignature(
            sourceWing: record.source.wing,
            sourceRoom: record.source.room,
            targetRoom: record.target.room,
            label: resolvedLabel,
            kind: .references
        )
        guard !existingSignatures.contains(sig) else { return }
        existingSignatures.insert(sig)

        let tunnelFrame = TunnelCaptureFrame(
            sourceWing: record.source.wing,
            sourceRoom: record.source.room,
            targetWing: record.target.wing,
            targetRoom: record.target.room,
            label: resolvedLabel,
            addedBy: Self.addedBy,
            kind: .references,
            originClass: .userExplicit
        )
        _ = try await estate.capture(tunnelFrame)
        report.tunnelsCreated += 1
    }

    // MARK: - KG entity import

    private func importKGEntity(
        id: String,
        name: String,
        createdAt: String?,
        handle: EstateHandle,
        existingLineageIDs: Set<UUID>,
        existingSensitivityByLineage: [UUID: AdjectiveSensitivity],
        tombstonedLineageIDs: Set<UUID>,
        existingContentByLineage: [UUID: String],
        now: Date,
        report: inout ImportReport
    ) async throws {
        let content = name.isEmpty ? id : name
        let lineageID = DrawerMapping.lineageID(forStableSourceKey: id)

        if tombstonedLineageIDs.contains(lineageID) {
            report.drawersSkippedTombstoned += 1
            return
        }
        if existingContentByLineage[lineageID] == content {
            report.drawersSkippedUnchanged += 1
            return
        }

        let eventTime: Date? = createdAt
            .flatMap(MemPalaceChromaAdapter.canonicalISO8601(fromMemPalace:))
            .flatMap { parseISO8601($0) }

        let sensitivity = existingSensitivityByLineage[lineageID] ?? .normal

        let frame = CaptureFrame(
            content: content,
            channel: .importedFile,
            room: "knowledge_graph/entities",
            latticeAnchor: LatticeAnchor(udcCode: Self.fallbackUDC),
            addedBy: Self.addedBy,
            embeddingModelID: Self.embeddingModelID,
            sensitivity: sensitivity,
            kind: .prose,
            lineageID: lineageID,
            eventTime: eventTime ?? now,
            exportability: Self.importExportability(label: nil, sensitivity: sensitivity),
            wing: "knowledge_graph"
        )

        let isUpdate = existingLineageIDs.contains(lineageID)
        _ = try await kit.capture(handle, frame)

        if isUpdate {
            report.drawersUpdated += 1
        } else {
            report.drawersWritten += 1
        }
        report.fdcUnclassified += 1
    }

    // MARK: - KG triple import

    /// Import one KG triple as a `KGFact`. Temporal validity (valid_from, valid_to,
    /// confidence) is encoded as additional KGFacts with predicates
    /// `"temporal:valid_from"`, `"temporal:valid_to"`, and `"temporal:confidence"`,
    /// anchored to the triple id. `fdcUnclassified` in the report is incremented once
    /// per call regardless of auxiliary temporal facts.
    ///
    /// ## Import guards (CAND-042 and CAND-049)
    ///
    /// **CAND-042 — Foreign-anchor rejection:** A KG fact that references a
    /// `sourceDrawerID` which does not correspond to a believed drawer lineage in
    /// the estate is rejected. A fact from a foreign palace that references a
    /// drawer that was never imported would otherwise create a dangling reference.
    /// The anchor is resolved via `DrawerMapping.lineageID(forStableSourceKey:)`
    /// (the same deterministic hash the import path uses for drawer identity) and
    /// checked against `existingLineageIDs` — the set captured AFTER the chroma
    /// and entity passes complete, so triples referencing drawers imported in the
    /// same `importPalace` call are correctly accepted.
    ///
    /// **CAND-049 — Re-import dedup:** Each fact is identified by a deterministic
    /// signature `"\(subject)\u{1F}\(predicate)\u{1F}\(object)\u{1F}\(sourceDrawerID)"`.
    /// If the signature is already present in `existingKGSignatures` the fact is
    /// skipped. The ASCII Unit Separator (U+001F) is chosen as a delimiter because
    /// it cannot appear in natural-language subject/predicate/object values
    /// serialised from MemPalace's chroma/triple stores. On first write the
    /// signature is added to `existingKGSignatures` so that a batch import within a
    /// single call also avoids within-batch duplicates.
    private func importKGTriple(
        id: String,
        subject: String,
        predicate: String,
        object: String,
        validFrom: String?,
        validTo: String?,
        confidenceText: String?,
        sourceDrawerID: String,
        handle: EstateHandle,
        existingLineageIDs: Set<UUID>,
        tombstonedLineageIDs: Set<UUID>,
        existingKGSignatures: inout Set<String>,
        now: Date,
        report: inout ImportReport
    ) async throws {
        // CAND-042: Reject facts whose source anchor does not exist in the estate.
        // An empty sourceDrawerID is allowed (estate-level facts have no anchor).
        if !sourceDrawerID.isEmpty {
            let srcLineage = DrawerMapping.lineageID(forStableSourceKey: sourceDrawerID)
            // Tombstone guard: lineage was withdrawn/erased — anchor is gone.
            if tombstonedLineageIDs.contains(srcLineage) {
                report.itemsSkipped += 1
                return
            }
            // Foreign-anchor guard (CAND-042): the anchor must be a currently-
            // believed drawer in this estate. A fact referencing a drawer that
            // was never imported (foreign palace) is rejected to prevent dangling
            // cross-estate references. Tombstoned lineages are already excluded
            // above; this check covers the case where the lineage was never
            // imported at all.
            if !existingLineageIDs.contains(srcLineage) {
                report.itemsSkipped += 1
                return
            }
        }

        // CAND-049: Skip re-imported facts that are content-identical to an
        // already-present fact. The canonical signature encodes the four semantic
        // identity fields using ASCII Unit Separator (U+001F) as a delimiter.
        let sig = "\(subject)\u{1F}\(predicate)\u{1F}\(object)\u{1F}\(sourceDrawerID)"
        if existingKGSignatures.contains(sig) {
            // Duplicate detected — do not create a second active KGFact.
            report.itemsSkipped += 1
            return
        }

        _ = try await kit.captureKGFact(
            handle,
            subject: subject,
            predicate: predicate,
            object: object,
            sourceDrawerID: sourceDrawerID,
            now: now
        )
        // Register this signature so within-batch duplicates are also caught.
        existingKGSignatures.insert(sig)
        report.fdcUnclassified += 1

        // Additional KGFacts for temporal validity fields that KGFact itself
        // has no stored columns for.
        if let vf = validFrom, !vf.isEmpty {
            _ = try await kit.captureKGFact(
                handle,
                subject: id,
                predicate: "temporal:valid_from",
                object: vf,
                sourceDrawerID: sourceDrawerID,
                now: now
            )
        }
        if let vt = validTo, !vt.isEmpty {
            _ = try await kit.captureKGFact(
                handle,
                subject: id,
                predicate: "temporal:valid_to",
                object: vt,
                sourceDrawerID: sourceDrawerID,
                now: now
            )
        }
        if let conf = confidenceText.flatMap(Double.init) {
            _ = try await kit.captureKGFact(
                handle,
                subject: id,
                predicate: "temporal:confidence",
                object: String(conf),
                sourceDrawerID: sourceDrawerID,
                now: now
            )
        }
    }

    // MARK: - Snapshot helpers (mirrors VaultBridge private helpers)

    private func existingDrawerState(
        handle: EstateHandle
    ) async throws -> (lineageIDs: Set<UUID>, wings: Set<String>, contentByLineage: [UUID: String]) {
        // limit: 10_000_000 = "all drawers" — same full-scan intent as VaultBridge.
        // Hydration .full so content is available for the content-idempotent check.
        let drawers = try await kit.recall(
            handle,
            RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .full,
                limit: 10_000_000
            )
        )
        let estate = try await kit.estate(for: handle)
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: drawers.map(\.parentNodeId))

        var lineageIDs: Set<UUID> = []
        var wings: Set<String> = []
        var contentByLineage: [UUID: String] = [:]
        for drawer in drawers {
            lineageIDs.insert(drawer.lineageID)
            if let resolvedWing = nodeNames[drawer.parentNodeId]?.wing {
                wings.insert(resolvedWing)
            }
            if contentByLineage[drawer.lineageID] == nil {
                contentByLineage[drawer.lineageID] = drawer.content
            }
        }
        return (lineageIDs, wings, contentByLineage)
    }

    private func existingTombstonedLineageIDs(
        handle: EstateHandle
    ) async throws -> Set<UUID> {
        // Cluster B: withdrawn lineages — visible via usedToBelieve.
        let withdrawnDrawers = try await kit.recall(
            handle,
            RecallFrame(
                filterChain: [.usedToBelieve],
                hydrationLevel: .structured,
                limit: 10_000_000
            )
        )
        let withdrawnIDs = Set(withdrawnDrawers.map(\.lineageID))
        // Cluster C: tombstoned/erased lineages — invisible to recall,
        // reached via the dedicated GLK passthrough.
        let erasedIDs = try await kit.tombstonedLineageIDs(handle)
        return withdrawnIDs.union(erasedIDs)
    }

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
                    // Explicit ceiling so restricted/secret drawers are visible;
                    // without it the evaluator's implicit floor hides them.
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

    // MARK: - Audit receipt

    private func writeImportReceipt(
        _ report: ImportReport,
        source: String,
        handle: EstateHandle,
        now: Date
    ) async throws {
        let entry = """
        {"operation":"palace-bridge-import",\
        "source":\(jsonString(source)),\
        "drawersWritten":\(report.drawersWritten),\
        "drawersUpdated":\(report.drawersUpdated),\
        "itemsSkipped":\(report.itemsSkipped),\
        "tunnelsCreated":\(report.tunnelsCreated),\
        "occurredAt":"\(OccurredAt(date: now).iso8601)"}
        """
        try await kit.addDiaryEntry(in: handle, DiaryEntry(
            agentName: VaultBridge.receiptAgentName,
            entry: entry,
            topic: "vault-receipt",
            wing: "wing_vaultkit",
            room: "receipts",
            filedAt: now,
            // Receipts carry no embedding; non-empty model id is required by schema.
            embeddingModelID: "no-embedding",
            operationalBitmap: VaultBridge.receiptBitmap
        ))
    }

    // MARK: - Helpers

    /// Resolve a room string from palace metadata.
    ///
    /// Priority order (mirrors DrawerMapping.makeCaptureFrame):
    /// 1. Explicit `room` frontmatter key.
    /// 2. Wing-stripped path components when the first component matches the wing.
    /// 3. All path components joined with "/".
    /// 4. Hard default "imported" (I-5: non-empty room invariant).
    private func resolveRoom(frontmatter: [String: String], wingKey: String?) -> String {
        if let explicit = nonEmpty(frontmatter["room"]) { return explicit }
        let components = ["wing", "hall", "room"].compactMap { k -> String? in
            guard let v = frontmatter[k], !v.isEmpty else { return nil }
            return v
        }
        let wk = wingKey ?? ""
        let contentComponents: [String]
        if !wk.isEmpty, components.first == wk, components.count > 1 {
            contentComponents = Array(components.dropFirst())
        } else {
            contentComponents = components
        }
        if contentComponents.count > 1 { return contentComponents.joined(separator: "/") }
        return contentComponents.first ?? "imported"
    }

    /// Return `s` when non-nil and non-empty, else nil.
    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Parse a canonical ISO8601 string (output of `canonicalISO8601`) into a `Date`.
    private func parseISO8601(_ s: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: s) { return d }
        // Fallback: drop fractional seconds.
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: s)
    }

    /// Minimal JSON string encoder for receipt fields (RFC 8259 escaping).
    private func jsonString(_ s: String) -> String {
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
}
