//! PalaceBridge — direct MemPalace → substrate import, bypassing NoteIR.
//!
//! Rust port of `Sources/VaultKit/PalaceBridge.swift`. The two implementations
//! must produce byte-identical ImportReports for the same palace fixture.
//!
//! Reads the three MemPalace stores directly:
//!   1. `palace/chroma.sqlite3` — chromaDB drawers and closets.
//!   2. `tunnels.json` — explicit cross-wing tunnel records.
//!   3. `knowledge_graph.sqlite3` — KG entities and triples.
//!
//! ## Import guards (mirrors Swift PalaceBridge)
//!
//!   1. Tombstone protection — lineages withdrawn/erased are never resurrected.
//!   2. Content-idempotent dedup — unchanged active drawers are skipped.
//!   3. Sensitivity floor — existing tier is never lowered on re-import.
//!   4. Tunnel signature dedup — present tunnels are not recreated.
//!
//! ## KGFact temporal validity
//!
//! `KGFact` has no `valid_from` / `valid_to` / `confidence` stored fields.
//! When a KG triple carries those values, additional KGFacts are filed with
//! predicates `"temporal:valid_from"`, `"temporal:valid_to"`, and
//! `"temporal:confidence"`, anchored to the triple id.
//!
//! ## Time convention
//!
//! `now` is epoch-MILLISECONDS (from `wall_now`, epoch-millisecond instants), which is exactly what
//! every sink here — capture / capture_batch, add_kg_fact, and the diary receipt
//! — expects, so it is passed DIRECTLY. The palace's `filed_at` metadata is also
//! milliseconds (`iso8601_to_ms`), so an imported drawer's `event_time` flows
//! through with no unit conversion and the source's sub-second precision is kept.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use rusqlite::{Connection, OpenFlags};
use serde::Deserialize;
use uuid::Uuid;

use crate::drawer_mapping::{iso8601_to_ms, ms_to_iso8601, DrawerMapping};
use crate::error::VaultKitError;
use crate::mem_palace_chroma_adapter::{
    canonical_iso8601_from_mem_palace, metadata_rows, metadata_segment_id,
    CHROMA_RELATIVE_PATH, KNOWLEDGE_GRAPH_RELATIVE_PATH, TUNNELS_RELATIVE_PATH,
};
use crate::vault_bridge::ImportReport;
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::EncodeSpeed;
use genius_locus_kit::handle::EstateHandle;
use locus_kit::{
    adjectives::{AdjectiveExportability, AdjectiveSensitivity},
    diary_entry::DiaryEntry,
    diary_operational::{DiaryActorClass, DiaryEventClass, DiarySeverity},
    drawer_operational::{CaptureChannel, ContentKind},
    estate_types::LatticeAnchor,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::{CaptureFrame, TunnelCaptureFrame},
    tunnel_operational::TunnelKind,
};

/// Agent name that audit receipts are filed under. Matches Swift
/// `VaultBridge.receiptAgentName` so receipts appear under the same
/// diary agent regardless of which bridge produced them.
const RECEIPT_AGENT_NAME: &str = "vaultkit";

/// ChromaDB drawer collection name (matches MemPalaceChromaAdapter default).
const DRAWERS_COLLECTION: &str = "mempalace_drawers";

/// ChromaDB closet collection name (matches MemPalaceChromaAdapter default).
const CLOSETS_COLLECTION: &str = "mempalace_closets";

/// UDC sentinel for items without a pre-classified code. "000" signals
/// the GLK capture seam to classify via EideticLib on ingestion.
const FALLBACK_UDC: &str = "000";

/// `addedBy` tag on all PalaceBridge-imported rows.
const ADDED_BY: &str = "palacebridge-import";

/// Embedding model placeholder for rows with no vector. Non-empty by schema contract.
const EMBEDDING_MODEL_ID: &str = "vaultkit-noembed-v1";

/// One tunnel record from `tunnels.json`.
#[derive(Debug, Deserialize)]
struct TunnelRecord {
    #[allow(dead_code)]
    id: String,
    source: TunnelEndpoint,
    target: TunnelEndpoint,
    label: Option<String>,
    #[allow(dead_code)]
    created_at: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TunnelEndpoint {
    wing: String,
    room: String,
}

/// Direct MemPalace → substrate importer, bypassing NoteIR.
///
/// Mirrors Swift `PalaceBridge`. Hold a mutable reference to an
/// `EstateCoordinator` (the same pattern as `VaultBridge`).

pub struct PalaceBridge<'a> {
    coordinator: &'a mut EstateCoordinator,
}

impl<'a> PalaceBridge<'a> {
    /// Create a new `PalaceBridge` wrapping the given coordinator.
    pub fn new(coordinator: &'a mut EstateCoordinator) -> Self {
        Self { coordinator }
    }

    /// Import all three MemPalace stores at `palace_root` into `handle`.
    ///
    /// Returns an `ImportReport` with counts of writes, updates, skips, and
    /// tunnels created. A receipt diary entry is filed under `RECEIPT_AGENT_NAME`.
    ///
    /// `now` is milliseconds-since-epoch, supplied by the caller
    /// (determinism — never read from the wall clock inside).
    ///
    /// `mode`: the encode SPEED (drain QoS) for the import's background encoding —
    /// `EncodeSpeed::Foreground` (drain hard) or `EncodeSpeed::Background` (yield
    /// for very large imports). SPEED only — the WRITE strategy is fixed (not
    /// caller-chosen): every source is written bulk via `capture_batch`, in
    /// `import_policy::BULK_WINDOW`-sized transaction windows so no single
    /// transaction holds the write lock across an arbitrarily large source (the
    /// per-item stream path is disabled — see the marker in the body). KG
    /// entities, triples, and tunnels are always imported per-item (they require
    /// individual post-capture work).
    pub fn import_palace(
        &mut self,
        palace_root: &Path,
        handle: &EstateHandle,
        now: i64,
        progress: Option<&crate::vault_adapter::VaultProgress<'_>>,
        mode: EncodeSpeed,
    ) -> Result<ImportReport, VaultKitError> {
        // Pre-read tunnels.json before the snapshot so tunnel source wings
        // are included in existingTunnelSignatures. Without this a re-import
        // would not find tunnels created by a prior import because their
        // sourceWing comes from the JSON, not from the drawer wing set.
        let tunnel_records = self.read_tunnel_records(palace_root)?;
        let tunnel_source_wings: HashSet<String> =
            tunnel_records.iter().map(|r| r.source.wing.clone()).collect();

        // Snapshot existing estate state once before any writes.
        let (existing_lineage_ids, existing_wings, existing_content_by_lineage) =
            self.existing_drawer_state(handle, now)?;
        let existing_sensitivity = self.existing_sensitivity_by_lineage(handle, now)?;
        // Exportability snapshot: compared against the would-be exportability
        // BEFORE the content-idempotent skip so a public→private label change
        // on unchanged content is not silently suppressed (security fix codex
        // 7c952932). Ordered newest-first; first-wins gives the most recently
        // imported exportability per lineage — the value a reimport would supersede.
        let existing_exportability = self.existing_exportability_by_lineage(handle, now)?;
        let tombstoned_lineage_ids = self.existing_tombstoned_lineage_ids(handle, now)?;
        // Include tunnel source wings in the signature scan so re-imports
        // correctly detect tunnels created by a prior import.
        let combined_wings: HashSet<String> =
            existing_wings.union(&tunnel_source_wings).cloned().collect();
        let mut existing_tunnel_sigs = self.existing_tunnel_signatures(handle, &combined_wings)?;

        // Declare the encode SPEED for this import's background drain before any
        // encode work is enqueued. SPEED only (foreground hard / background gentle)
        // — the write strategy below is size-gated, not set here.
        self.coordinator.set_encode_speed(handle, mode);

        let mut report = ImportReport::default();
        let mut processed: usize = 0;
        // Total chroma drawer count, set once the rows are gathered below.
        // Passed to the progress callback so it reports `processed/total`
        // (not `/0`); fired every 10 records for live feedback on long imports.
        let mut total: usize = 0;

        // --- Store 1: palace/chroma.sqlite3 ---
        let chroma_path = palace_root.join(CHROMA_RELATIVE_PATH);
        if chroma_path.exists() {
            let conn = Connection::open_with_flags(&chroma_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
                .map_err(|e| VaultKitError::AdapterError(format!("chroma.sqlite3: {e}")))?;
            // Gather all chroma rows across both collections up front so the
            // progress callback can report a real total instead of 0. The
            // rows are materialized once (no double read).
            let mut all_rows: Vec<(String, HashMap<String, String>, bool)> = Vec::new();
            for (collection, is_closet) in
                &[(DRAWERS_COLLECTION, false), (CLOSETS_COLLECTION, true)]
            {
                let seg_id = match metadata_segment_id(&conn, collection).map_err(|e| {
                    VaultKitError::AdapterError(format!("segment_id: {e}"))
                })? {
                    Some(id) => id,
                    None => continue,
                };
                let rows = metadata_rows(&conn, &seg_id)
                    .map_err(|e| VaultKitError::AdapterError(format!("metadata_rows: {e}")))?;
                for (embedding_id, metadata) in rows {
                    all_rows.push((embedding_id, metadata, *is_closet));
                }
            }
            total = all_rows.len();

            // STREAMED IMPORT PATH — DISABLED (2026-07-02). We believe the
            // per-item streaming write path is no longer necessary and should be
            // REMOVED at the 1.1 release gate if this holds true. Rationale: the
            // bulk `capture_batch` path below handles every realistic import; the
            // old stream branch engaged ONLY above import_policy::STREAM_THRESHOLD
            // (250_000 items in ONE source), which no real import reaches. So the
            // bulk path now runs UNCONDITIONALLY. The `use_bulk` size gate and the
            // per-item `else` branch are preserved verbatim below, commented, for
            // the 1.1 review — not deleted:
            //
            //   let use_bulk = crate::import_policy::use_bulk(total);
            //   if use_bulk { /* bulk path — now the sole path, below */ } else {
            //       // Stream path: one transaction per row so no single
            //       // transaction holds the write lock across hundreds of
            //       // thousands of rows.
            //       for (embedding_id, metadata, is_closet) in &all_rows {
            //           self.import_chroma_row(
            //               embedding_id, metadata, *is_closet, handle,
            //               &existing_lineage_ids, &existing_sensitivity,
            //               &tombstoned_lineage_ids, &existing_content_by_lineage,
            //               now, &mut report,
            //           )?;
            //           processed += 1;
            //           if processed % 10 == 0 { if let Some(p) = &progress { p(processed, total); } }
            //       }
            //   }
            {
                // Bulk path: collect all frames, then submit in
                // import_policy::BULK_WINDOW-sized transaction windows.
                let mut batch_frames: Vec<(CaptureFrame, bool /* is_update */)> = Vec::new();
                for (embedding_id, metadata, is_closet) in &all_rows {
                    if let Some((frame, is_update)) = self.build_chroma_frame(
                        embedding_id,
                        metadata,
                        *is_closet,
                        &existing_lineage_ids,
                        &existing_sensitivity,
                        &tombstoned_lineage_ids,
                        &existing_content_by_lineage,
                        &existing_exportability,
                        now,
                        &mut report,
                    ) {
                        batch_frames.push((frame, is_update));
                    }
                }
                if !batch_frames.is_empty() {
                    // Submit in BULK_WINDOW-sized windows — one transaction per
                    // window — so no single transaction holds the write lock (or
                    // the classified in-memory batch) across an arbitrarily large
                    // source (codex 26c7a364). A source at or under the window is
                    // exactly one transaction, byte-identical to the pre-window
                    // behavior. Report/progress bookkeeping advances per committed
                    // window, so a mid-import failure reports only rows that
                    // actually landed.
                    for window in batch_frames.chunks(crate::import_policy::BULK_WINDOW) {
                        let frames: Vec<CaptureFrame> =
                            window.iter().map(|(f, _)| f.clone()).collect();
                        // `now` (wall_now, epoch-millisecond instants) is epoch-MILLISECONDS — the same
                        // unit capture, the stream path, and the KG paths all expect —
                        // so it is passed directly with no conversion.
                        self.coordinator
                            .capture_batch(handle, frames, now)
                            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
                        for (_, is_update) in window {
                            if *is_update { report.drawers_updated += 1; } else { report.drawers_written += 1; }
                            report.fdc_unclassified += 1;
                            processed += 1;
                            if processed % 10 == 0 { if let Some(p) = &progress { p(processed, total); } }
                        }
                    }
                }
            }
        }

        // --- Store 2: tunnels.json (preloaded above) ---
        for record in &tunnel_records {
            self.import_tunnel_record(record, handle, &mut existing_tunnel_sigs, now, &mut report)?;
        }

        // --- Store 3: knowledge_graph.sqlite3 ---
        let kg_path = palace_root.join(KNOWLEDGE_GRAPH_RELATIVE_PATH);
        if kg_path.exists() {
            let conn = Connection::open_with_flags(&kg_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
                .map_err(|e| VaultKitError::AdapterError(format!("knowledge_graph.sqlite3: {e}")))?;

            // KG entities: each entity becomes a drawer in knowledge_graph/entities.
            {
                let mut stmt = conn
                    .prepare(
                        "SELECT id, name, type, properties, created_at FROM entities ORDER BY id",
                    )
                    .map_err(|e| VaultKitError::AdapterError(format!("entities: {e}")))?;
                let rows = stmt
                    .query_map([], |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, Option<String>>(1)?,
                            row.get::<_, Option<String>>(4)?,
                        ))
                    })
                    .map_err(|e| VaultKitError::AdapterError(format!("entities query: {e}")))?;
                for row in rows {
                    let (id, name, created_at) =
                        row.map_err(|e| VaultKitError::AdapterError(format!("{e}")))?;
                    self.import_kg_entity(
                        &id,
                        name.as_deref().unwrap_or(""),
                        created_at.as_deref(),
                        handle,
                        &existing_lineage_ids,
                        &existing_sensitivity,
                        &tombstoned_lineage_ids,
                        &existing_content_by_lineage,
                        now,
                        &mut report,
                    )?;
                }
            }

            // CAND-042 + CAND-049: take a post-import snapshot of lineage IDs
            // and existing KG fact signatures AFTER all entity imports complete
            // but BEFORE the triple loop. This ensures:
            //   CAND-042 — triples that reference a drawer imported in THIS call
            //     (not only prior calls) pass the anchor existence check.
            //   CAND-049 — only signatures absent from the estate at this moment
            //     are written; identical re-imported facts are counted as skipped.
            let (post_import_lineage_ids, _, _) =
                self.existing_drawer_state(handle, now)?;
            let existing_kg_facts = self
                .coordinator
                .recall_kg_facts(handle)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
            // Canonical separator: U+001F (ASCII Unit Separator) — cannot appear
            // in natural-language subject/predicate/object/sourceDrawerID values
            // from MemPalace stores. Matches the Swift PalaceBridge dedup signature.
            let mut existing_kg_signatures: HashSet<String> = existing_kg_facts
                .iter()
                .map(|f| {
                    format!(
                        "{}\x1f{}\x1f{}\x1f{}",
                        f.subject, f.predicate, f.object, f.source_drawer_id
                    )
                })
                .collect();

            // KG triples: each triple becomes a KGFact. Temporal validity
            // (valid_from, valid_to, confidence) encoded as additional KGFacts.
            {
                let mut stmt = conn
                    .prepare(
                        "SELECT id, subject, predicate, object, valid_from, valid_to, \
                         CAST(confidence AS TEXT), source_drawer_id \
                         FROM triples ORDER BY id",
                    )
                    .map_err(|e| VaultKitError::AdapterError(format!("triples: {e}")))?;
                let rows = stmt
                    .query_map([], |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, Option<String>>(1)?,
                            row.get::<_, Option<String>>(2)?,
                            row.get::<_, Option<String>>(3)?,
                            row.get::<_, Option<String>>(4)?,
                            row.get::<_, Option<String>>(5)?,
                            row.get::<_, Option<String>>(6)?,
                            row.get::<_, Option<String>>(7)?,
                        ))
                    })
                    .map_err(|e| VaultKitError::AdapterError(format!("triples query: {e}")))?;
                for row in rows {
                    let (id, subject, predicate, object, valid_from, valid_to, conf, src_drawer) =
                        row.map_err(|e| VaultKitError::AdapterError(format!("{e}")))?;
                    self.import_kg_triple(
                        &id,
                        subject.as_deref().unwrap_or(""),
                        predicate.as_deref().unwrap_or(""),
                        object.as_deref().unwrap_or(""),
                        valid_from.as_deref(),
                        valid_to.as_deref(),
                        conf.as_deref(),
                        src_drawer.as_deref().unwrap_or(""),
                        handle,
                        &tombstoned_lineage_ids,
                        &post_import_lineage_ids,
                        &mut existing_kg_signatures,
                        now,
                        &mut report,
                    )?;
                }
            }
        }

        let source = palace_root.display().to_string();
        let entry = format!(
            "{{\"operation\":\"palace-bridge-import\",\"source\":{},\
             \"drawersWritten\":{},\"drawersUpdated\":{},\"itemsSkipped\":{},\
             \"tunnelsCreated\":{},\"occurredAt\":\"{}\"}}",
            json_string(&source),
            report.drawers_written,
            report.drawers_updated,
            report.items_skipped,
            report.tunnels_created,
            ms_to_iso8601(now),
        );
        self.write_receipt(&entry, handle, now)?;
        // Final 100% tick so consumers see completion at the true total.
        if processed > 0 { if let Some(p) = &progress { p(processed, total); } }
        Ok(report)
    }

    // MARK: - Batch frame builder

    /// Apply the three import guards and build a `CaptureFrame` for the chroma
    /// row WITHOUT calling `capture`. Returns `None` (with `report` counters
    /// updated for the skip) when any guard fires. Used by the batch path so
    /// all frames can be collected first and submitted in one `capture_batch`.
    ///
    /// Mirrors Swift `PalaceBridge.buildChromaFrame(...)`.
    #[allow(clippy::too_many_arguments)]
    fn build_chroma_frame(
        &self,
        embedding_id: &str,
        metadata: &HashMap<String, String>,
        _is_closet: bool,
        existing_lineage_ids: &HashSet<Uuid>,
        existing_sensitivity: &HashMap<Uuid, AdjectiveSensitivity>,
        tombstoned_lineage_ids: &HashSet<Uuid>,
        existing_content_by_lineage: &HashMap<Uuid, String>,
        existing_exportability: &HashMap<Uuid, AdjectiveExportability>,
        now: i64,
        report: &mut ImportReport,
    ) -> Option<(CaptureFrame, bool /* is_update */)> {
        let content = metadata.get("chroma:document").map(|s| s.as_str()).unwrap_or("");
        if content.is_empty() {
            report.items_skipped += 1;
            return None;
        }
        let lineage_id = DrawerMapping::lineage_id(embedding_id);
        if tombstoned_lineage_ids.contains(&lineage_id) {
            report.drawers_skipped_tombstoned += 1;
            return None;
        }
        // Sensitivity floor parsed BEFORE the content-idempotent skip so a
        // re-import of unchanged content that carries a higher sensitivity tier
        // still applies the upgrade. Mirrors the Swift PalaceBridge fix.
        let requested = sensitivity_from_label(metadata.get("sensitivity").map(|s| s.as_str()));
        let floored = if let Some(existing) = existing_sensitivity.get(&lineage_id) {
            if existing.raw_value() > requested.raw_value() { *existing } else { requested }
        } else {
            requested
        };
        // Derive exportability BEFORE the content-idempotent skip so a
        // public→private label change on unchanged content is not suppressed
        // (security fix codex 7c952932: exportability was previously derived
        // only after the skip, so an exportability-only change was invisible
        // to the guard and the stale public bit remained in the estate).
        let would_be_exportability =
            import_exportability(metadata.get("exportability").map(String::as_str), floored);
        // Content-idempotent dedup: skip only when content is unchanged, no
        // sensitivity upgrade is pending, AND exportability is unchanged. A
        // public→private change must not be suppressed — it leaves stale public
        // bits that bypass the default bulk-export policy.
        let existing_tier_raw = existing_sensitivity.get(&lineage_id).map(|s| s.raw_value());
        let is_sensitivity_upgrade = existing_tier_raw.map(|r| floored.raw_value() > r).unwrap_or(false);
        let is_exportability_change = existing_exportability
            .get(&lineage_id)
            .map(|e| *e != would_be_exportability)
            .unwrap_or(false);
        if existing_content_by_lineage.get(&lineage_id).map(|s| s.as_str()) == Some(content)
            && !is_sensitivity_upgrade
            && !is_exportability_change
        {
            report.drawers_skipped_unchanged += 1;
            return None;
        }
        let wing: Option<String> = metadata.get("wing").filter(|s| !s.is_empty()).map(|s| s.clone());
        let room = resolve_room(metadata, wing.as_deref());
        let event_time_ms: Option<i64> = metadata
            .get("filed_at")
            .and_then(|s| canonical_iso8601_from_mem_palace(s))
            .and_then(|s| iso8601_to_ms(&s));
        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::ImportedFile,
            &room,
            LatticeAnchor::udc(FALLBACK_UDC),
            ADDED_BY,
            EMBEDDING_MODEL_ID,
        );
        frame.sensitivity = floored;
        // Re-use the exportability derived above (before the skip check).
        frame.exportability = would_be_exportability;
        frame.kind = ContentKind::Prose;
        frame.lineage_id = Some(lineage_id);
        // event_time_ms is epoch-MILLISECONDS (iso8601_to_ms) and
        // CaptureFrame.event_time is now epoch-MILLISECONDS too, as is
        // `now` (wall_now), so it flows straight through with no unit conversion
        // — the source's sub-second precision is preserved end to end.
        frame.event_time = Some(event_time_ms.unwrap_or(now));
        frame.wing = wing;
        let is_update = existing_lineage_ids.contains(&lineage_id);
        Some((frame, is_update))
    }

    // MARK: - Chroma row import

    // DISABLED (2026-07-02): the sole caller was the per-item STREAMED import
    // branch in `import_palace`, now commented out (the bulk `capture_batch` path
    // handles every realistic import; streaming only engaged above the 250_000-item
    // STREAM_THRESHOLD). Kept, not deleted, pending the 1.1 release gate — remove
    // this method together with the commented stream branch and import_policy's
    // `use_bulk`/`STREAM_THRESHOLD` if the streamed path is confirmed unnecessary.
    #[allow(dead_code)]
    #[allow(clippy::too_many_arguments)]
    fn import_chroma_row(
        &mut self,
        embedding_id: &str,
        metadata: &HashMap<String, String>,
        _is_closet: bool,
        handle: &EstateHandle,
        existing_lineage_ids: &HashSet<Uuid>,
        existing_sensitivity: &HashMap<Uuid, AdjectiveSensitivity>,
        tombstoned_lineage_ids: &HashSet<Uuid>,
        existing_content_by_lineage: &HashMap<Uuid, String>,
        existing_exportability: &HashMap<Uuid, AdjectiveExportability>,
        now: i64,
        report: &mut ImportReport,
    ) -> Result<(), VaultKitError> {
        let content = metadata.get("chroma:document").map(|s| s.as_str()).unwrap_or("");
        // Skip rows with no content (I-5: non-empty body rule).
        if content.is_empty() {
            report.items_skipped += 1;
            return Ok(());
        }

        let lineage_id = DrawerMapping::lineage_id(embedding_id);

        // Guard 1: tombstone protection.
        if tombstoned_lineage_ids.contains(&lineage_id) {
            report.drawers_skipped_tombstoned += 1;
            return Ok(());
        }

        // Guard 3: sensitivity floor — never lower an existing tier. Parsed
        // BEFORE the content-idempotent dedup guard so a re-import of unchanged
        // content that carries a higher sensitivity tier still applies the
        // upgrade (the dedup guard must not short-circuit a pending sensitivity
        // promotion). Mirrors the Swift PalaceBridge fix.
        let requested = sensitivity_from_label(metadata.get("sensitivity").map(|s| s.as_str()));
        let floored = if let Some(existing) = existing_sensitivity.get(&lineage_id) {
            if existing.raw_value() > requested.raw_value() {
                *existing
            } else {
                requested
            }
        } else {
            requested
        };

        // Derive exportability BEFORE the content-idempotent skip so a
        // public→private label change on unchanged content is not suppressed
        // (security fix codex 7c952932). Mirrors build_chroma_frame.
        let would_be_exportability =
            import_exportability(metadata.get("exportability").map(String::as_str), floored);

        // Guard 2: content-idempotent dedup — skip only when content is unchanged,
        // no sensitivity upgrade is pending, AND exportability is unchanged. A
        // public→private change must not be suppressed — it leaves stale public
        // bits that bypass the default bulk-export policy.
        let existing_tier_raw = existing_sensitivity.get(&lineage_id).map(|s| s.raw_value());
        let is_sensitivity_upgrade = existing_tier_raw.map(|r| floored.raw_value() > r).unwrap_or(false);
        let is_exportability_change = existing_exportability
            .get(&lineage_id)
            .map(|e| *e != would_be_exportability)
            .unwrap_or(false);
        if existing_content_by_lineage.get(&lineage_id).map(|s| s.as_str()) == Some(content)
            && !is_sensitivity_upgrade
            && !is_exportability_change
        {
            report.drawers_skipped_unchanged += 1;
            return Ok(());
        }

        let wing: Option<String> = metadata
            .get("wing")
            .filter(|s| !s.is_empty())
            .map(|s| s.clone());
        let room = resolve_room(metadata, wing.as_deref());

        let event_time_ms: Option<i64> = metadata
            .get("filed_at")
            .and_then(|s| canonical_iso8601_from_mem_palace(s))
            .and_then(|s| iso8601_to_ms(&s));

        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::ImportedFile,
            &room,
            // UDC "000" = unclassified sentinel; the substrate classifies on ingestion.
            LatticeAnchor::udc(FALLBACK_UDC),
            ADDED_BY,
            EMBEDDING_MODEL_ID,
        );
        frame.sensitivity = floored;
        // Re-use the exportability derived above (before the skip check).
        frame.exportability = would_be_exportability;
        frame.kind = ContentKind::Prose;
        frame.lineage_id = Some(lineage_id);
        // event_time_ms is epoch-MILLISECONDS (iso8601_to_ms) and
        // CaptureFrame.event_time is now epoch-MILLISECONDS too, as is
        // `now` (wall_now), so it flows straight through with no unit conversion
        // — the source's sub-second precision is preserved end to end.
        frame.event_time = Some(event_time_ms.unwrap_or(now));
        frame.wing = wing;

        let is_update = existing_lineage_ids.contains(&lineage_id);
        self.coordinator
            .capture(handle, frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;

        if is_update {
            report.drawers_updated += 1;
        } else {
            report.drawers_written += 1;
        }
        // Palace rows carry no pre-classified UDC; all count as unclassified.
        report.fdc_unclassified += 1;
        Ok(())
    }

    // MARK: - Tunnel record import

    fn import_tunnel_record(
        &mut self,
        record: &TunnelRecord,
        handle: &EstateHandle,
        existing_sigs: &mut HashSet<String>,
        now: i64,
        report: &mut ImportReport,
    ) -> Result<(), VaultKitError> {
        let raw_label = record.label.as_deref().unwrap_or("");
        // Resolved label: non-empty, even for unlabeled tunnels (I-5).
        let resolved_label = if raw_label.is_empty() {
            format!(
                "{}/{} -> {}/{}",
                record.source.wing, record.source.room,
                record.target.wing, record.target.room
            )
        } else {
            raw_label.to_owned()
        };

        // Guard 4: tunnel signature dedup. Signature uses resolved_label so it
        // matches what was stored in the prior import.
        let sig = DrawerMapping::tunnel_signature(
            &record.source.wing,
            &record.source.room,
            &record.target.room,
            &resolved_label,
            TunnelKind::References,
        );
        if existing_sigs.contains(&sig) {
            return Ok(());
        }
        existing_sigs.insert(sig);

        let frame = TunnelCaptureFrame::new(
            &record.source.wing,
            &record.source.room,
            &record.target.wing,
            &record.target.room,
            &resolved_label,
            ADDED_BY,
        );

        let estate = self
            .coordinator
            .estate_for(handle)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        estate
            .capture_tunnel(frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        report.tunnels_created += 1;
        Ok(())
    }

    // MARK: - KG entity import

    #[allow(clippy::too_many_arguments)]
    fn import_kg_entity(
        &mut self,
        id: &str,
        name: &str,
        created_at: Option<&str>,
        handle: &EstateHandle,
        existing_lineage_ids: &HashSet<Uuid>,
        existing_sensitivity: &HashMap<Uuid, AdjectiveSensitivity>,
        tombstoned_lineage_ids: &HashSet<Uuid>,
        existing_content_by_lineage: &HashMap<Uuid, String>,
        now: i64,
        report: &mut ImportReport,
    ) -> Result<(), VaultKitError> {
        let content = if name.is_empty() { id } else { name };
        let lineage_id = DrawerMapping::lineage_id(id);

        if tombstoned_lineage_ids.contains(&lineage_id) {
            report.drawers_skipped_tombstoned += 1;
            return Ok(());
        }
        if existing_content_by_lineage.get(&lineage_id).map(|s| s.as_str()) == Some(content) {
            report.drawers_skipped_unchanged += 1;
            return Ok(());
        }

        let event_time_ms: Option<i64> = created_at
            .and_then(canonical_iso8601_from_mem_palace)
            .and_then(|s| iso8601_to_ms(&s));

        let sensitivity = existing_sensitivity
            .get(&lineage_id)
            .copied()
            .unwrap_or(AdjectiveSensitivity::Normal);

        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::ImportedFile,
            "knowledge_graph/entities",
            LatticeAnchor::udc(FALLBACK_UDC),
            ADDED_BY,
            EMBEDDING_MODEL_ID,
        );
        frame.sensitivity = sensitivity;
        frame.exportability = import_exportability(None, sensitivity);
        frame.kind = ContentKind::Prose;
        frame.lineage_id = Some(lineage_id);
        // event_time_ms is epoch-MILLISECONDS (iso8601_to_ms) and
        // CaptureFrame.event_time is now epoch-MILLISECONDS too, as is
        // `now` (wall_now), so it flows straight through with no unit conversion
        // — the source's sub-second precision is preserved end to end.
        frame.event_time = Some(event_time_ms.unwrap_or(now));
        frame.wing = Some("knowledge_graph".to_owned());

        let is_update = existing_lineage_ids.contains(&lineage_id);
        self.coordinator
            .capture(handle, frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;

        if is_update {
            report.drawers_updated += 1;
        } else {
            report.drawers_written += 1;
        }
        report.fdc_unclassified += 1;
        Ok(())
    }

    // MARK: - KG triple import

    #[allow(clippy::too_many_arguments)]
    fn import_kg_triple(
        &mut self,
        id: &str,
        subject: &str,
        predicate: &str,
        object: &str,
        valid_from: Option<&str>,
        valid_to: Option<&str>,
        confidence_text: Option<&str>,
        source_drawer_id: &str,
        handle: &EstateHandle,
        tombstoned_lineage_ids: &HashSet<Uuid>,
        // CAND-042: snapshot of ALL lineage IDs in the estate after chroma+entity
        // imports — so a triple that references a drawer imported in THIS call
        // passes the anchor check. Triples referencing lineages absent from the
        // estate (foreign anchors) are rejected and counted as items_skipped.
        post_import_lineage_ids: &HashSet<Uuid>,
        // CAND-049: running set of KG fact content signatures
        // (`subject\x1fpredicate\x1fobject\x1fsource_drawer_id`). Starts as the
        // pre-import estate snapshot; updated in place as new facts land so
        // within-call duplicates are also caught.
        existing_kg_signatures: &mut HashSet<String>,
        now: i64,
        report: &mut ImportReport,
    ) -> Result<(), VaultKitError> {
        // CAND-042: reject facts whose source anchor does not exist in the estate.
        // Check tombstone first (already-withdrawn anchor), then existence check.
        if !source_drawer_id.is_empty() {
            let src_lineage = DrawerMapping::lineage_id(source_drawer_id);
            if tombstoned_lineage_ids.contains(&src_lineage) {
                report.items_skipped += 1;
                return Ok(());
            }
            // Foreign-anchor rejection: the source drawer lineage must exist in the
            // estate after all chroma+entity imports in this call. A fact whose anchor
            // was never imported (random string, alien palace, etc.) is silently
            // rejected here to prevent phantom KG facts with no substrate owner.
            if !post_import_lineage_ids.contains(&src_lineage) {
                report.items_skipped += 1;
                return Ok(());
            }
        }

        // The Rust substrate requires source_drawer_id to be non-empty (unlike
        // Swift which accepts "" as "not anchored"). When the palace triple has
        // no source drawer, use the triple's own id as the anchor — it is the
        // record that produced this fact.
        //
        // IMPORTANT: effective_src must be computed BEFORE the CAND-049 dedup
        // check so that the signature uses the value that will actually be stored
        // in the estate (effective_src, not the raw empty source_drawer_id). If
        // we signed with raw source_drawer_id and stored effective_src, a re-
        // import would compute a different signature and miss the dedup.
        let effective_src = if source_drawer_id.is_empty() { id } else { source_drawer_id };

        // CAND-049: skip re-imported facts that are content-identical. The
        // signature encodes all four identity-bearing fields of a KGFact using
        // U+001F (ASCII Unit Separator) as a delimiter — a character that cannot
        // appear in natural-language values from MemPalace stores. Uses
        // effective_src (not raw source_drawer_id) so the signature matches the
        // stored field on re-import.
        let sig = format!(
            "{}\x1f{}\x1f{}\x1f{}",
            subject, predicate, object, effective_src
        );
        if existing_kg_signatures.contains(&sig) {
            report.items_skipped += 1;
            return Ok(());
        }

        self.coordinator
            .add_kg_fact(handle, subject, predicate, object, effective_src, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        // Record the signature so within-call duplicates are caught on subsequent
        // iterations without a round-trip to the estate.
        existing_kg_signatures.insert(sig);
        report.fdc_unclassified += 1;

        // Additional KGFacts for temporal validity fields that KGFact has no
        // stored columns for.
        if let Some(vf) = valid_from.filter(|s| !s.is_empty()) {
            self.coordinator
                .add_kg_fact(handle, id, "temporal:valid_from", vf, effective_src, now)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        }
        if let Some(vt) = valid_to.filter(|s| !s.is_empty()) {
            self.coordinator
                .add_kg_fact(handle, id, "temporal:valid_to", vt, effective_src, now)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        }
        if let Some(conf) = confidence_text.and_then(|s| s.parse::<f64>().ok()) {
            self.coordinator
                .add_kg_fact(
                    handle,
                    id,
                    "temporal:confidence",
                    &conf.to_string(),
                    effective_src,
                    now,
                )
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        }
        Ok(())
    }

    // MARK: - Pre-read tunnels.json

    fn read_tunnel_records(&self, palace_root: &Path) -> Result<Vec<TunnelRecord>, VaultKitError> {
        let tunnels_path = palace_root.join(TUNNELS_RELATIVE_PATH);
        if !tunnels_path.exists() {
            return Ok(vec![]);
        }
        let data = std::fs::read(&tunnels_path)
            .map_err(|e| VaultKitError::AdapterError(format!("tunnels.json read: {e}")))?;
        serde_json::from_slice(&data).map_err(|e| {
            VaultKitError::AdapterError(format!("tunnels.json is malformed: {e}"))
        })
    }

    // MARK: - Snapshot helpers (mirrors VaultBridge)

    fn existing_drawer_state(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<(HashSet<Uuid>, HashSet<String>, HashMap<Uuid, String>), VaultKitError> {
        let frame = RecallFrame {
            filter_chain: vec![Filter::Unconfirmed],
            hydration_level: HydrationLevel::Full,
            limit: Some(10_000_000),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let drawers = self
            .coordinator
            .recall(handle, frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let node_names =
            crate::drawer_mapping::resolve_drawer_node_names(self.coordinator, handle, &drawers);

        let mut lineage_ids = HashSet::new();
        let mut wings = HashSet::new();
        let mut content_by_lineage: HashMap<Uuid, String> = HashMap::new();
        for d in drawers {
            lineage_ids.insert(d.lineage_id);
            if let Some((wing, _)) = node_names.get(&d.parent_node_id) {
                wings.insert(wing.clone());
            }
            content_by_lineage.entry(d.lineage_id).or_insert(d.content);
        }
        Ok((lineage_ids, wings, content_by_lineage))
    }

    fn existing_tombstoned_lineage_ids(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<HashSet<Uuid>, VaultKitError> {
        let frame = RecallFrame {
            filter_chain: vec![Filter::UsedToBelieve],
            hydration_level: HydrationLevel::Structured,
            limit: Some(10_000_000),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let withdrawn = self
            .coordinator
            .recall(handle, frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let withdrawn_ids: HashSet<Uuid> = withdrawn.into_iter().map(|d| d.lineage_id).collect();
        let erased_ids = self
            .coordinator
            .tombstoned_lineage_ids(handle)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        Ok(withdrawn_ids.union(&erased_ids).copied().collect())
    }

    fn existing_sensitivity_by_lineage(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<HashMap<Uuid, AdjectiveSensitivity>, VaultKitError> {
        let frame = RecallFrame {
            filter_chain: vec![
                Filter::CurrentlyBelieve,
                Filter::Any(vec![
                    Filter::UserConfirmed,
                    Filter::Unconfirmed,
                    Filter::AutomatedConfirmedOnly,
                ]),
                Filter::Any(vec![Filter::Trustworthy, Filter::RequiresConfirmation]),
                Filter::SensitivityAtMost(AdjectiveSensitivity::Secret),
            ],
            hydration_level: HydrationLevel::Structured,
            limit: Some(10_000_000),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let drawers = self
            .coordinator
            .recall(handle, frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let mut map: HashMap<Uuid, AdjectiveSensitivity> = HashMap::new();
        for d in drawers {
            let tier = d.adjective_sensitivity();
            map.entry(d.lineage_id)
                .and_modify(|cur| {
                    if tier.raw_value() > cur.raw_value() {
                        *cur = tier;
                    }
                })
                .or_insert(tier);
        }
        Ok(map)
    }

    /// Snapshot of the most recently imported exportability per lineage, used by
    /// the content-idempotent skip guard to detect exportability-only changes
    /// (e.g. public → private) that must not be suppressed.
    ///
    /// Uses the same recall frame as `existing_sensitivity_by_lineage`. Ordered
    /// newest-first (`ByCaptureTimeDesc`); first-wins (via `entry().or_insert`)
    /// gives the most recent exportability per lineage — the value a reimport
    /// would supersede. Mirrors Swift `PalaceBridge.existingExportabilityByLineage`.
    fn existing_exportability_by_lineage(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<HashMap<Uuid, AdjectiveExportability>, VaultKitError> {
        let frame = RecallFrame {
            filter_chain: vec![
                Filter::CurrentlyBelieve,
                Filter::Any(vec![
                    Filter::UserConfirmed,
                    Filter::Unconfirmed,
                    Filter::AutomatedConfirmedOnly,
                ]),
                Filter::Any(vec![Filter::Trustworthy, Filter::RequiresConfirmation]),
                // Explicit ceiling so restricted/secret drawers are visible;
                // without it the evaluator's implicit floor hides them.
                Filter::SensitivityAtMost(AdjectiveSensitivity::Secret),
            ],
            hydration_level: HydrationLevel::Structured,
            limit: Some(10_000_000),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let drawers = self
            .coordinator
            .recall(handle, frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let mut map: HashMap<Uuid, AdjectiveExportability> = HashMap::new();
        for d in drawers {
            // First-wins (newest-first ordering) gives the most recent
            // exportability per lineage — the value a reimport would supersede.
            map.entry(d.lineage_id).or_insert_with(|| d.exportability());
        }
        Ok(map)
    }

    fn existing_tunnel_signatures(
        &self,
        handle: &EstateHandle,
        wings: &HashSet<String>,
    ) -> Result<HashSet<String>, VaultKitError> {
        let mut sigs = HashSet::new();
        for wing in wings {
            let tunnels = self
                .coordinator
                .recall_tunnels(handle, wing)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
            for t in tunnels.into_iter().filter(|t| t.kind == TunnelKind::References) {
                sigs.insert(DrawerMapping::tunnel_signature(
                    &t.source_wing,
                    &t.source_room,
                    &t.target_room,
                    &t.label,
                    TunnelKind::References,
                ));
            }
        }
        Ok(sigs)
    }

    // MARK: - Audit receipt

    fn write_receipt(
        &self,
        entry_text: &str,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<(), VaultKitError> {
        let bitmap = DiaryEventClass::Migration.raw_value()
            | (DiarySeverity::Info.raw_value() << 4)
            | (DiaryActorClass::MigrationTool.raw_value() << 7);
        let mut entry = DiaryEntry::new(
            Uuid::new_v4().to_string(),
            RECEIPT_AGENT_NAME.to_string(),
            entry_text.to_string(),
            "vault-receipt".to_string(),
            "wing_vaultkit".to_string(),
            "receipts".to_string(),
            now,
            "no-embedding".to_string(),
        );
        entry.operational_bitmap = bitmap;
        let estate = self
            .coordinator
            .estate_for(handle)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        estate
            .add_diary_entry(&entry)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))
    }
}

// MARK: - Module-level helpers

/// Resolve room from palace metadata. Priority order mirrors Swift PalaceBridge.
/// Exportability adjective for imported palace content. Palace/markdown sources
/// are already-public material, so the policy default is `Public` (a `Private`
/// default would wrongly wall off content that was never protected). A
/// frontmatter `exportability:` label overrides. Clamped to `Private` when
/// sensitivity is `Secret`: the capture gate rejects a secret+public row
/// (invariant I-22). Mirrors Swift `PalaceBridge.importExportability`.
fn import_exportability(
    label: Option<&str>,
    sensitivity: AdjectiveSensitivity,
) -> AdjectiveExportability {
    if sensitivity == AdjectiveSensitivity::Secret {
        return AdjectiveExportability::Private;
    }
    label
        .and_then(DrawerMapping::exportability_from_label)
        .unwrap_or(AdjectiveExportability::Public)
}

fn resolve_room(metadata: &HashMap<String, String>, wing_key: Option<&str>) -> String {
    if let Some(explicit) = metadata.get("room").filter(|s| !s.is_empty()) {
        return explicit.clone();
    }
    let components: Vec<&str> = ["wing", "hall", "room"]
        .iter()
        .filter_map(|&k| metadata.get(k).filter(|s| !s.is_empty()).map(|s| s.as_str()))
        .collect();
    let wk = wing_key.unwrap_or("");
    let content: Vec<&str> = if !wk.is_empty() && components.first() == Some(&wk) && components.len() > 1 {
        components[1..].to_vec()
    } else {
        components.clone()
    };
    if content.len() > 1 {
        content.join("/")
    } else {
        content.into_iter().next().unwrap_or("imported").to_owned()
    }
}

/// Derive sensitivity from a label string. Returns `Normal` for absent/unknown labels.
fn sensitivity_from_label(label: Option<&str>) -> AdjectiveSensitivity {
    match label {
        Some("elevated") => AdjectiveSensitivity::Elevated,
        Some("restricted") => AdjectiveSensitivity::Restricted,
        Some("secret") => AdjectiveSensitivity::Secret,
        _ => AdjectiveSensitivity::Normal,
    }
}

/// Minimal JSON string encoder for receipt fields (RFC 8259 escaping).
fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
    use locus_kit::{
        drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
        estate_types::OwnerCredentials,
    };
    use std::sync::Arc;

    /// Fixed operation instant (ms) used across all tests.
    const NOW: i64 = 1_000_000_000_000i64;

    fn fixture_palace_root() -> std::path::PathBuf {
        // Same fixture used by MemPalaceChromaAdapterTests.
        let manifest = env!("CARGO_MANIFEST_DIR");
        std::path::PathBuf::from(manifest)
            .join("../Tests/VaultKitTests/Fixtures/mempalace")
    }

    fn open_estate() -> (EstateCoordinator, EstateHandle) {
        let mut coordinator = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
        let handle = coordinator
            .open(store, OwnerCredentials::new("palacebridge-rust-tests"), 0, 100)
            .expect("open estate");
        (coordinator, handle)
    }

    #[test]
    fn fixture_import_basic() {
        let palace_root = fixture_palace_root();
        let (mut coordinator, handle) = open_estate();
        let report = PalaceBridge::new(&mut coordinator)
            .import_palace(&palace_root, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        assert!(report.drawers_written > 0, "expected drawers_written > 0");
        assert!(report.tunnels_created > 0, "expected tunnels_created > 0");
        assert_eq!(report.drawers_updated, 0);
    }

    #[test]
    fn fixture_import_idempotent() {
        let palace_root = fixture_palace_root();
        let (mut coordinator, handle) = open_estate();
        let first = PalaceBridge::new(&mut coordinator)
            .import_palace(&palace_root, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        let second = PalaceBridge::new(&mut coordinator)
            .import_palace(&palace_root, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        assert_eq!(second.drawers_written, 0);
        assert_eq!(second.drawers_updated, 0);
        assert_eq!(
            second.drawers_skipped_unchanged,
            first.drawers_written + first.drawers_updated
        );
    }

    #[test]
    fn tunnel_dedup_on_reimport() {
        let palace_root = fixture_palace_root();
        let (mut coordinator, handle) = open_estate();
        let first = PalaceBridge::new(&mut coordinator)
            .import_palace(&palace_root, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        let second = PalaceBridge::new(&mut coordinator)
            .import_palace(&palace_root, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        assert_eq!(second.tunnels_created, 0, "re-import must not duplicate tunnels");
        assert!(first.tunnels_created > 0, "first import must create tunnels");
    }

    /// CAND-042: a KG triple whose source_drawer_id does not correspond to any
    /// lineage in the estate is rejected (items_skipped incremented) and the KG
    /// fact count does not grow.
    #[test]
    fn cand042_foreign_anchor_fact_rejected() {
        use rusqlite::Connection;

        let (mut coordinator, handle) = open_estate();

        // First: import the fixture palace so the estate has some drawers.
        let palace_root = fixture_palace_root();
        PalaceBridge::new(&mut coordinator)
            .import_palace(&palace_root, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        let kg_facts_before = coordinator.recall_kg_facts(&handle).unwrap();
        let count_before = kg_facts_before.len();

        // Build a synthetic palace directory with a knowledge_graph.sqlite3
        // that contains a single triple referencing a foreign source_drawer_id —
        // one that cannot map to any lineage in the estate.
        let synthetic_palace = std::env::temp_dir()
            .join(format!("synthetic-palace-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&synthetic_palace).unwrap();
        let kg_path = synthetic_palace.join(KNOWLEDGE_GRAPH_RELATIVE_PATH);

        {
            let conn = Connection::open(&kg_path).unwrap();
            conn.execute_batch(
                "CREATE TABLE triples (
                    id TEXT PRIMARY KEY,
                    subject TEXT NOT NULL DEFAULT '',
                    predicate TEXT NOT NULL DEFAULT '',
                    object TEXT NOT NULL DEFAULT '',
                    valid_from TEXT,
                    valid_to TEXT,
                    confidence REAL,
                    source_drawer_id TEXT NOT NULL DEFAULT ''
                );
                INSERT INTO triples (id, subject, predicate, object, source_drawer_id)
                VALUES ('t-foreign', 'alien:subject', 'alien:predicate', 'alien:object',
                        'totally-foreign-drawer-id-not-in-estate');
                CREATE TABLE entities (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    type TEXT,
                    properties TEXT,
                    created_at TEXT
                );",
            )
            .unwrap();
        }

        let second = PalaceBridge::new(&mut coordinator)
            .import_palace(
                &synthetic_palace,
                &handle,
                NOW,
                None,
                EncodeSpeed::Foreground,
            )
            .unwrap();
        let kg_facts_after = coordinator.recall_kg_facts(&handle).unwrap();

        // The foreign-anchor triple must be counted as skipped.
        assert!(
            second.items_skipped >= 1,
            "CAND-042: foreign-anchor KG fact must be rejected (items_skipped >= 1), \
             got items_skipped={}",
            second.items_skipped
        );
        // The KG fact count must not grow.
        assert_eq!(
            kg_facts_after.len(),
            count_before,
            "CAND-042: foreign-anchor KG fact must not land in the estate \
             (count_before={} count_after={})",
            count_before,
            kg_facts_after.len()
        );

        std::fs::remove_dir_all(&synthetic_palace).ok();
    }

    /// CAND-049: re-importing an identical KG fact does not create a duplicate.
    #[test]
    fn cand049_kg_fact_deduplication_on_reimport() {
        let palace_root = fixture_palace_root();
        let (mut coordinator, handle) = open_estate();

        // First import: KG facts land.
        let first = PalaceBridge::new(&mut coordinator)
            .import_palace(&palace_root, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        let count_after_first = coordinator.recall_kg_facts(&handle).unwrap().len();

        // Second import of the same fixture: facts must be deduped.
        let second = PalaceBridge::new(&mut coordinator)
            .import_palace(&palace_root, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        let count_after_second = coordinator.recall_kg_facts(&handle).unwrap().len();

        // The fixture must produce at least one KG fact on first import.
        assert!(
            first.fdc_unclassified > 0,
            "CAND-049: fixture must produce at least one KG fact on first import, \
             got fdc_unclassified={}",
            first.fdc_unclassified
        );
        // Second import must report at least one skipped (the duplicate facts).
        assert!(
            second.items_skipped > 0,
            "CAND-049: re-import should skip duplicate KG facts, got items_skipped={}",
            second.items_skipped
        );
        // KG fact count must not grow on re-import.
        assert_eq!(
            count_after_second,
            count_after_first,
            "CAND-049: re-import must not duplicate KG facts \
             (after_first={} after_second={})",
            count_after_first,
            count_after_second
        );
    }

    // MARK: - Security regression: codex 7c952932 — exportability-only changes
    // must not be suppressed by the content-idempotent skip guard.

    /// Write a minimal chroma.sqlite3 at `<dir>/palace/chroma.sqlite3` with one
    /// row. The content is constant across calls; only `exportability_label`
    /// changes so the test can exercise the exportability-change detection path.
    fn make_exportability_chroma(dir: &std::path::Path, exportability_label: &str) {
        let palace_dir = dir.join("palace");
        std::fs::create_dir_all(&palace_dir).unwrap();
        let chroma_path = palace_dir.join("chroma.sqlite3");
        // Drop the file first so re-calls produce a fresh schema (SQLite doesn't
        // support DROP TABLE + re-INSERT idioms cleanly across reconnects here).
        let _ = std::fs::remove_file(&chroma_path);
        let conn = Connection::open(&chroma_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE collections (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                dimension INTEGER,
                database_id TEXT NOT NULL,
                config_json_str TEXT,
                schema_str TEXT
            );
            CREATE TABLE segments (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                scope TEXT NOT NULL,
                collection TEXT NOT NULL
            );
            CREATE TABLE embeddings (
                id INTEGER PRIMARY KEY,
                segment_id TEXT NOT NULL,
                embedding_id TEXT NOT NULL,
                seq_id BLOB NOT NULL,
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE (segment_id, embedding_id)
            );
            CREATE TABLE embedding_metadata (
                id INTEGER REFERENCES embeddings(id),
                key TEXT NOT NULL,
                string_value TEXT,
                int_value INTEGER,
                float_value REAL,
                bool_value INTEGER,
                PRIMARY KEY (id, key)
            );
            INSERT INTO collections (id, name, database_id)
            VALUES ('col-1', 'mempalace_drawers', 'db-1');
            INSERT INTO segments (id, type, scope, collection)
            VALUES ('seg-1', 'urn:chroma:segment/sqlite-metadata', 'METADATA', 'col-1');
            INSERT INTO embeddings (id, segment_id, embedding_id, seq_id)
            VALUES (1, 'seg-1', 'exportability-regression-doc-001', x'00');",
        )
        .unwrap();
        // The content is intentionally identical across imports; only exportability
        // varies so the test isolates the exportability-change detection path.
        conn.execute(
            "INSERT INTO embedding_metadata (id, key, string_value)
             VALUES (1, 'chroma:document', 'Stable content that never changes between imports.')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO embedding_metadata (id, key, string_value) VALUES (1, 'exportability', ?1)",
            [exportability_label],
        )
        .unwrap();
    }

    /// Recall currently-believed drawers (cluster A), with sensitivity ceiling
    /// extended to Secret so all tiers are visible.
    fn current_drawers_all(
        coord: &EstateCoordinator,
        handle: &EstateHandle,
    ) -> Vec<locus_kit::drawer::Drawer> {
        let frame = RecallFrame {
            filter_chain: vec![
                Filter::CurrentlyBelieve,
                Filter::Any(vec![
                    Filter::UserConfirmed,
                    Filter::Unconfirmed,
                    Filter::AutomatedConfirmedOnly,
                ]),
                Filter::Any(vec![Filter::Trustworthy, Filter::RequiresConfirmation]),
                Filter::SensitivityAtMost(locus_kit::adjectives::AdjectiveSensitivity::Secret),
            ],
            hydration_level: HydrationLevel::Full,
            limit: Some(10_000_000),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        coord.recall(handle, frame, NOW).expect("recall")
    }

    /// Security regression (codex 7c952932): a public→private exportability change
    /// on otherwise-unchanged content must NOT be suppressed by the
    /// content-idempotent skip guard.
    ///
    /// Scenario:
    ///   1. Import with exportability=public  → drawer written, exportability=Public.
    ///   2. Re-import, same body, exportability=private → must NOT skip; must update
    ///      the drawer and flip its exportability bit to Private.
    ///
    /// Mirrors Swift `PalaceBridgeTests.exportabilityChangeNotSkipped`.
    #[test]
    fn exportability_change_not_skipped() {
        let temp = std::env::temp_dir()
            .join(format!("vaultkit-exportability-skip-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&temp).unwrap();

        let (mut coordinator, handle) = open_estate();

        // Step 1: first import — content with exportability=public.
        make_exportability_chroma(&temp, "public");
        let first = PalaceBridge::new(&mut coordinator)
            .import_palace(&temp, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        assert_eq!(first.drawers_written, 1, "first import must write the drawer");
        assert_eq!(first.drawers_skipped_unchanged, 0);

        let drawers = current_drawers_all(&coordinator, &handle);
        assert_eq!(drawers.len(), 1, "one drawer in estate after first import");
        assert_eq!(
            drawers[0].exportability(),
            AdjectiveExportability::Public,
            "drawer must be Public after first import"
        );

        // Step 2: re-import with same content but exportability=private.
        // The skip guard must NOT suppress this update.
        make_exportability_chroma(&temp, "private");
        let second = PalaceBridge::new(&mut coordinator)
            .import_palace(&temp, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        assert_eq!(
            second.drawers_skipped_unchanged,
            0,
            "exportability public→private must NOT be skipped (codex 7c952932): \
             drawers_skipped_unchanged={} drawers_updated={}",
            second.drawers_skipped_unchanged,
            second.drawers_updated
        );
        assert_eq!(
            second.drawers_updated,
            1,
            "exportability-only change must produce drawers_updated=1"
        );

        // Verify the exportability bit flipped to Private.
        let after_second = current_drawers_all(&coordinator, &handle);
        assert_eq!(after_second.len(), 1);
        assert_eq!(
            after_second[0].exportability(),
            AdjectiveExportability::Private,
            "drawer exportability must be Private after re-import with exportability:private"
        );

        std::fs::remove_dir_all(&temp).ok();
    }

    /// Idempotency companion to `exportability_change_not_skipped`: when both
    /// content and exportability are truly unchanged on re-import the skip guard
    /// must fire.
    ///
    /// This test uses a fresh two-step estate (no superseded predecessors) so the
    /// tombstone set is empty and `drawers_skipped_unchanged` is the only path that
    /// can absorb the row.
    ///
    /// Mirrors Swift `PalaceBridgeTests.unchangedExportabilitySkipped`.
    #[test]
    fn unchanged_exportability_skipped() {
        let temp = std::env::temp_dir()
            .join(format!("vaultkit-exportability-idempotent-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&temp).unwrap();

        let (mut coordinator, handle) = open_estate();

        // Step 1: first import with exportability=private.
        make_exportability_chroma(&temp, "private");
        let first = PalaceBridge::new(&mut coordinator)
            .import_palace(&temp, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        assert_eq!(first.drawers_written, 1, "first import must write the drawer");

        // Step 2: re-import with the same content and the same exportability=private.
        // Nothing changed — the skip guard must fire. The estate has exactly one
        // active drawer and no superseded predecessors, so the tombstone set is
        // empty and the unchanged guard is the only matching path.
        let second = PalaceBridge::new(&mut coordinator)
            .import_palace(&temp, &handle, NOW, None, EncodeSpeed::Foreground)
            .unwrap();
        assert_eq!(
            second.drawers_skipped_unchanged,
            1,
            "truly-unchanged re-import (same content + same exportability=private) \
             must be counted as skipped-unchanged: written={} updated={} \
             skipped_unchanged={} skipped_tombstoned={} items_skipped={}",
            second.drawers_written,
            second.drawers_updated,
            second.drawers_skipped_unchanged,
            second.drawers_skipped_tombstoned,
            second.items_skipped
        );
        assert_eq!(second.drawers_updated, 0);

        std::fs::remove_dir_all(&temp).ok();
    }
}
