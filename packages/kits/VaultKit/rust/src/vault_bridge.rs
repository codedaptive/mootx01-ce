//! VaultBridge, ImportReport, and ExportReport — the public facade.
//!
//! `VaultBridge` is a thin facade: a `VaultAdapter` handles file ⇄ `NoteIR`,
//! and `DrawerMapping` handles `NoteIR` ⇄ substrate. The bridge fuses the two
//! into one operation per MOOT. Mirrors Swift `VaultBridge`.
//!
//! `now` is always passed by the caller — never read from the wall clock
//! internally — so the bridge is deterministic. The caller supplies a
//! milliseconds-since-epoch integer.
//!
//! ## Audit receipts
//!
//! Every successful export and import run writes one receipt into the
//! estate's diary — "what left, where, when, how many." The bitmap-audit
//! trail is per-row and cannot carry an estate-level payload, so receipts
//! use the diary: the estate-level event log whose `Migration` event class
//! exists for exactly this.

use crate::drawer_mapping::{ms_to_iso8601, DrawerMapping, ImportOutcome};
use crate::error::VaultKitError;
use crate::vault_adapter::VaultAdapter;
use crate::vault_export_scope::VaultExportScope;
use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle, EncodeSpeed};
use locus_kit::{
    adjectives::{AdjectiveSensitivity, State},
    diary_entry::DiaryEntry,
    diary_operational::{DiaryActorClass, DiaryEventClass, DiarySeverity},
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::CaptureFrame,
    tunnel_operational::TunnelKind,
};
use std::collections::HashSet;
use std::path::Path;
use uuid::Uuid;

/// Counts returned by an import run. Mirrors Swift `ImportReport`.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ImportReport {
    /// Drawers captured for a lineage not previously present.
    pub drawers_written: usize,

    /// Re-imports that superseded an existing drawer (idempotent update).
    pub drawers_updated: usize,

    /// `.references` tunnels created across all notes (post-dedup).
    pub tunnels_created: usize,

    /// Notes that could not be imported (e.g. empty content under I-5).
    pub items_skipped: usize,

    /// Drawers whose UDC came from a live FDC anchor or an explicit
    /// frontmatter `udc`.
    pub fdc_classified: usize,

    /// Drawers that landed with the `"000"` fallback UDC because no live
    /// FDC anchor resolved and no explicit `udc` was supplied.
    pub fdc_unclassified: usize,

    /// Per-field count of imported notes whose value for that `NoteIR`
    /// field did not ride into the substrate (zero-loss invariant C-13:
    /// any dropped field is recorded, never silent). Keys are `NoteIR`
    /// field names; values are how many written/updated notes carried a
    /// non-default value the current mapping does not persist.
    /// All structured fields now land: facts and scope land as KG facts;
    /// hierarchy lands as the full room path; tags land as KG facts
    /// (subject "tag:<t>", predicate "tagged"); kind != "note" lands as
    /// a KG fact (subject "record:kind", predicate "is"). This map is
    /// currently empty for every fully-structured fixture (hard-close #29).
    /// `BTreeMap` for deterministic iteration. Mirrors Swift `ImportReport.fieldsDropped`.
    pub fields_dropped: std::collections::BTreeMap<String, usize>,

    /// Re-imports whose lineage already has an ACTIVE drawer with byte-identical
    /// content. No supersession, no UUID rotation — true idempotent no-op.
    /// Fixes FINDING-1a. Mirrors Swift `ImportReport.drawersSkippedUnchanged`.
    pub drawers_skipped_unchanged: usize,

    /// Re-imports whose lineage was previously erased (withdrawn) in the
    /// estate. The tombstone is respected; the note is NOT resurrected.
    /// Fixes FINDING-1b. Mirrors Swift `ImportReport.drawersSkippedTombstoned`.
    pub drawers_skipped_tombstoned: usize,

    /// Re-imports where a DisciplineViolation fired AFTER the supersession
    /// cascade had already committed the successor drawer row but before the
    /// predecessor belief-state flip completed. The estate contains an orphaned
    /// successor alongside the un-flipped predecessor; unlike `items_skipped`,
    /// the write was partially applied. Never silent (zero-loss invariant C-13):
    /// surfaced so a reconciliation pass can detect the gap. Mirrors Swift
    /// `ImportReport.drawersSkippedPartialWrite`.
    pub drawers_skipped_partial_write: usize,

    /// Number of drawers enqueued for semantic encoding after the import.
    ///
    /// The bulk `capture_batch` path intentionally skips the per-item encode
    /// enqueue to avoid flooding the queue for large imports. After the batch
    /// write completes, `import_notes` calls `collect_reindex_jobs` and enqueues
    /// the resulting change references via `enqueue_change_batch` (capped at
    /// `REINDEX_MAX_JOBS` = 10,000 per call).
    ///
    /// The per-item path (`capture_with_mode(WriteMode::Regular)`) enqueues each
    /// drawer individually; `enqueued_for_encode` is 0 for those runs.
    ///
    /// A value of 0 on a bulk import means either every drawer was already
    /// indexed (idempotent re-import) or the estate has no registered Corpus.
    /// Mirrors Swift `ImportReport.enqueuedForEncode`.
    pub enqueued_for_encode: usize,
}

/// Counts returned by an export run, including the per-tier exclusion counts
/// the data-movement privacy tiers bulk-channel rules produced. Exclusions are
/// reported, never silent (zero-loss reporting symmetry with C-13). Mirrors
/// Swift `ExportReport`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExportReport {
    /// Notes written to the vault.
    pub notes_exported: usize,

    /// Secret-tier drawers the scope filters admitted but the bulk channel
    /// excluded. Secret never rides bulk export, under any scope.
    pub excluded_secret_tier: usize,

    /// Private-tier (`Restricted`) drawers excluded because the scope did
    /// not carry the explicit private-tier opt-in
    /// (`VaultExportScope::includes_private_tier`).
    pub excluded_private_tier: usize,

    /// The scope the export ran under.
    pub scope: VaultExportScope,
}

/// The public facade: bridges a MOOT estate and a Markdown vault in both
/// directions. Mirrors Swift `VaultBridge`.
///
/// `coordinator` is `&mut` because `import_notes` routes through
/// `capture_with_mode(WriteMode::Regular)`, which mounts and feeds the per-estate
/// encode queue (dual-path intake fix, G7). Export methods only need an immutable
/// borrow; holding `&mut` is compatible — Rust coerces `&mut T` to `&T` for read-only
/// dispatch. Callers that only export may hold the coord mutably for the bridge
/// lifetime with no behavioural change.
pub struct VaultBridge<'a> {
    coordinator: &'a mut EstateCoordinator,
    adapter: Box<dyn VaultAdapter>,
    mapping: DrawerMapping,
}

impl<'a> VaultBridge<'a> {
    /// Actor name receipts are filed under. Receipts are read back via
    /// `EstateCoordinator::diary_entries` / `Estate::read_diary` with this
    /// name. Mirrors Swift `VaultBridge.receiptAgentName`.
    pub const RECEIPT_AGENT_NAME: &'static str = "vaultkit";

    /// Construct a `VaultBridge`.
    ///
    /// - `coordinator`: the open `EstateCoordinator` whose estates this bridge
    ///   reads and writes. `&mut` is required because import routes through the
    ///   mode-aware capture verb (`capture_with_mode`), which mounts and feeds the
    ///   per-estate encode queue.
    /// - `adapter`: the vault format adapter. Pass `Box::new(ObsidianAdapter::new())`
    ///   for the default Obsidian behaviour.
    /// - `mapping`: the substrate mapping policy.
    pub fn new(
        coordinator: &'a mut EstateCoordinator,
        adapter: Box<dyn VaultAdapter>,
        mapping: DrawerMapping,
    ) -> Self {
        Self { coordinator, adapter, mapping }
    }

    // MARK: - Export

    /// Project an estate to a Markdown vault. Mirrors Swift
    /// `VaultBridge.export(estate:to:scope:now:)`.
    ///
    /// Enforces the data-movement privacy tiers privacy-tier rules on this bulk
    /// channel: secret-tier drawers never export, private-tier drawers
    /// export only under `VaultExportScope::BelievedIncludingPrivate`, and
    /// every tier exclusion is counted in the returned `ExportReport` —
    /// visible, never silent. A successful run writes one audit receipt to
    /// the estate's diary.
    ///
    /// `now` is milliseconds-since-epoch, supplied by the caller and stamped
    /// on the audit receipt.
    pub fn export(
        &self,
        handle: &EstateHandle,
        vault_path: &Path,
        now: i64,
        scope: VaultExportScope,
        progress: Option<&crate::vault_adapter::VaultProgress<'_>>,
    ) -> Result<ExportReport, VaultKitError> {
        let projection = self.mapping.export(self.coordinator, handle, now, scope)?;
        // Forward the progress callback to the adapter, which fires it every
        // 100 notes and at the final note. Mirrors Swift `VaultBridge.export`,
        // which passes `progress` into `adapter.fromIR(_:to:progress:)`.
        self.adapter
            .from_ir_with_progress(&projection.notes, vault_path, progress)?;
        let report = ExportReport {
            notes_exported: projection.notes.len(),
            excluded_secret_tier: projection.excluded_secret_tier,
            excluded_private_tier: projection.excluded_private_tier,
            scope,
        };
        let entry = format!(
            "{{\"operation\":\"vault-export\",\"scope\":\"{}\",\"destination\":{},\"notesExported\":{},\"excludedSecretTier\":{},\"excludedPrivateTier\":{},\"occurredAt\":\"{}\"}}",
            report.scope.as_str(),
            json_string(&vault_path.display().to_string()),
            report.notes_exported,
            report.excluded_secret_tier,
            report.excluded_private_tier,
            ms_to_iso8601(now),
        );
        self.write_receipt(&entry, handle, now)?;
        Ok(report)
    }

    // MARK: - Import

    /// Import a Markdown vault into an estate via the capture seam. Idempotent
    /// on each note's `stable_source_key`. Every captured drawer satisfies I-5.
    /// Mirrors Swift `VaultBridge.importVault(at:into:now:)`.
    ///
    /// Import is ungated (data-movement privacy tiers: arrival is free), but each note's
    /// sensitivity tier is preserved from the IR when the adapter supplies it
    /// (`sensitivity` frontmatter → `CaptureFrame.sensitivity`). A successful
    /// run writes one audit receipt to the estate's diary.
    ///
    /// `now` is milliseconds-since-epoch, supplied by the caller and stamped
    /// on the audit receipt.
    /// `mode`: encode SPEED (`EncodeSpeed::Foreground` default / `Background`).
    /// SPEED only; the write strategy (bulk transaction vs per-item stream) is
    /// chosen automatically by source size (`import_policy`) — the same
    /// gate-agnostic policy PalaceBridge uses.
    pub fn import_vault(
        &mut self,
        vault_path: &Path,
        handle: &EstateHandle,
        now: i64,
        progress: Option<&crate::vault_adapter::VaultProgress<'_>>,
        mode: EncodeSpeed,
    ) -> Result<ImportReport, VaultKitError> {
        let notes = self.adapter.to_ir(vault_path)?;
        self.import_notes(&notes, handle, &vault_path.display().to_string(), now, progress, mode)
    }

    /// Import a filtered subset of a Markdown vault into an estate.
    ///
    /// Identical to `import_vault` but restricts the import to notes whose
    /// vault-relative path is contained in `candidate_paths`. Used by
    /// `moot_vault_reconcile` apply mode so only the M added/modified
    /// candidates land in the estate and `drawers_updated` reports M, not
    /// the full vault size N.
    ///
    /// The adapter reads all notes from disk; the filter is applied before
    /// the capture loop — non-candidate notes never enter the estate at all.
    /// Idempotence per `stable_source_key` is preserved: a candidate already
    /// present in the estate is updated, not duplicated.
    ///
    /// `candidate_paths` contains vault-relative paths
    /// (e.g. `"Chem/Benzene.md"`) in the same forward-slash format as the
    /// manifest keys. Paths not present on disk are silently ignored.
    ///
    /// Mirrors Swift `VaultBridge.importVault(at:includingPaths:into:now:)`.
    /// `mode`: encode SPEED; the write strategy is size-gated automatically (`import_policy`).
    /// Defaults to `false` for reconcile operations (typically small candidate sets).
    pub fn import_vault_filtered(
        &mut self,
        vault_path: &Path,
        candidate_paths: &std::collections::HashSet<String>,
        handle: &EstateHandle,
        now: i64,
        progress: Option<&crate::vault_adapter::VaultProgress<'_>>,
        mode: EncodeSpeed,
    ) -> Result<ImportReport, VaultKitError> {
        let all_notes = self.adapter.to_ir(vault_path)?;
        // Restrict to the candidate set. A note's vault-relative path is
        // stable_source_key + ".md" (the inverse of what ObsidianAdapter
        // constructs on read). Non-candidate notes are dropped before the
        // capture loop.
        let filtered: Vec<_> = all_notes
            .into_iter()
            .filter(|note| {
                let note_path = format!("{}.md", note.stable_source_key);
                candidate_paths.contains(&note_path)
            })
            .collect();
        self.import_notes(&filtered, handle, &vault_path.display().to_string(), now, progress, mode)
    }

    /// Import one MemPalace palace directly into an estate — all three
    /// MemPalace stores (`palace/chroma.sqlite3`, `tunnels.json`,
    /// `knowledge_graph.sqlite3`) read READ-ONLY by
    /// `MemPalaceChromaAdapter` and fed through the same idempotent
    /// capture path as `import_vault` (stable keys, tunnel dedup, audit
    /// receipt). See the adapter for the complete field → `NoteIR` table.
    /// Mirrors Swift `VaultBridge.importMemPalace(at:into:now:adapter:)`.
    ///
    /// `palace_root` is the palace root directory (e.g. `~/.mempalace`);
    /// `now` is milliseconds-since-epoch, supplied by the caller and
    /// stamped on the audit receipt. `adapter` is parameterized so tests
    /// can point at fixture palaces with non-default collections.
    /// `mode`: encode SPEED; the write strategy is size-gated automatically (`import_policy`).
    /// Cutting import time for large palaces from O(N×commit) to O(1×commit).
    /// Run `moot_reindex` + `moot_dream` afterward to rebuild dense lanes.
    pub fn import_mem_palace(
        &mut self,
        palace_root: &Path,
        handle: &EstateHandle,
        now: i64,
        adapter: &crate::mem_palace_chroma_adapter::MemPalaceChromaAdapter,
        progress: Option<&crate::vault_adapter::VaultProgress<'_>>,
        mode: EncodeSpeed,
    ) -> Result<ImportReport, VaultKitError> {
        let notes = adapter.to_ir(palace_root)?;
        self.import_notes(&notes, handle, &palace_root.display().to_string(), now, progress, mode)
    }

    /// The shared import core: capture canonical notes into an estate via
    /// the capture seam. `import_vault` and `import_mem_palace` differ only
    /// in which adapter produced the notes; everything from the existing-
    /// state snapshot to the audit receipt is identical and lives here.
    /// The write strategy is size-gated automatically (`import_policy`): at or
    /// below the threshold all frames are collected upfront and submitted in one
    /// `capture_batch` transaction (post-capture KG/tunnel work runs per-note
    /// afterward); above it the original per-note loop streams. `mode` sets the
    /// encode SPEED only. Mirrors Swift `VaultBridge.importNotes(_:into:source:now:mode:)`.
    ///
    /// `&mut self` is required because `import_note` calls `capture_with_mode`
    /// (dual-path intake fix) which needs `&mut EstateCoordinator`.
    fn import_notes(
        &mut self,
        notes: &[crate::note_ir::NoteIR],
        handle: &EstateHandle,
        source: &str,
        now: i64,
        progress: Option<&crate::vault_adapter::VaultProgress<'_>>,
        mode: EncodeSpeed,
    ) -> Result<ImportReport, VaultKitError> {
        // The import path does not emit per-note progress in either port: Swift
        // `VaultBridge.importNotes` accepts `progress` but never fires it, and the
        // public importers forward it here only to keep the signatures aligned.
        // Only the export path reports progress (via the adapter). Discarded
        // explicitly to preserve the Swift-parity signature without firing.
        let _ = progress;
        // Declare the encode SPEED for this import's background drain before any
        // encode work is enqueued — the same gate-agnostic policy PalaceBridge
        // uses (T1/T7). SPEED only; the write strategy is size-gated below.
        self.coordinator.set_encode_speed(handle, mode);
        // Snapshot existing state once so written-vs-updated and tunnel
        // de-duplication need no per-note probe.
        // existing_content_by_lineage: verbatim content of every active drawer
        // keyed by lineage_id — used by the content-idempotent check (FINDING-1a)
        // to skip re-imports where nothing changed.
        let (existing_lineage_ids, existing_wings, existing_content_by_lineage, existing_stable_source_key_by_lineage) =
            self.existing_drawer_state(handle, now)?;
        // The current tier of every believed drawer across ALL sensitivity
        // levels, so the import sensitivity floor can never be lowered by a
        // re-import (supersession-downgrade defense — see import_note).
        let existing_sensitivity = self.existing_sensitivity_by_lineage(handle, now)?;
        // tombstoned_lineage_ids: lineages that were previously erased/withdrawn
        // (FINDING-1b). Notes whose lineage appears here must NOT be resurrected.
        let tombstoned_lineage_ids =
            self.existing_tombstoned_lineage_ids(handle, now, &existing_lineage_ids)?;
        let mut existing_tunnel_sigs = self.existing_tunnel_signatures(handle, &existing_wings)?;

        let mut report = ImportReport::default();

        // Size gate (automatic — NOT user-controlled), single-sourced in
        // import_policy so every source gate uses the same boundary: a source at
        // or below the threshold is written in one bulk capture_batch transaction;
        // a larger one streams per-item.
        let use_bulk = crate::import_policy::use_bulk(notes.len());
        if use_bulk {
            // Bulk path: collect qualified (note, frame, is_update, classified)
            // tuples, submit all frames in one transaction via capture_batch,
            // then apply post-capture work (KG facts, tunnels) per-note.
            // Guard-skipped notes update report counters inside build_note_frame.
            let mut qualified: Vec<(&crate::note_ir::NoteIR, CaptureFrame, bool, bool)> = Vec::new();
            for note in notes {
                if let Some((frame, is_update, classified)) = self.mapping.build_note_frame(
                    note,
                    &existing_lineage_ids,
                    &existing_sensitivity,
                    &tombstoned_lineage_ids,
                    &existing_content_by_lineage,
                    &existing_stable_source_key_by_lineage,
                    &mut report.items_skipped,
                    &mut report.drawers_skipped_unchanged,
                    &mut report.drawers_skipped_tombstoned,
                ) {
                    qualified.push((note, frame, is_update, classified));
                }
            }
            if !qualified.is_empty() {
                let frames: Vec<CaptureFrame> = qualified.iter().map(|(_, f, _, _)| f.clone()).collect();
                let drawers = self.coordinator
                    .capture_batch(handle, frames, now / 1000)
                    .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
                for ((note, frame, is_update, classified), drawer) in qualified.iter().zip(drawers.iter()) {
                    let tunnels = self.mapping.apply_note_post_capture(
                        note,
                        frame,
                        drawer,
                        self.coordinator,
                        handle,
                        &mut existing_tunnel_sigs,
                        now,
                    )?;
                    if *is_update { report.drawers_updated += 1; } else { report.drawers_written += 1; }
                    report.tunnels_created += tunnels;
                    if *classified { report.fdc_classified += 1; } else { report.fdc_unclassified += 1; }
                    Self::record_dropped_fields(note, &mut report);
                }
            }
        } else {
            // Per-item path: unchanged from before batch support was added.
            for note in notes {
                let outcome = self.mapping.import_note(
                    note,
                    self.coordinator,
                    handle,
                    &existing_lineage_ids,
                    &existing_sensitivity,
                    &tombstoned_lineage_ids,
                    &existing_content_by_lineage,
                    &existing_stable_source_key_by_lineage,
                    &mut existing_tunnel_sigs,
                    now,
                )?;
                match outcome {
                    ImportOutcome::Written { tunnels_created, fdc_classified } => {
                        report.drawers_written += 1;
                        report.tunnels_created += tunnels_created;
                        if fdc_classified { report.fdc_classified += 1; } else { report.fdc_unclassified += 1; }
                        Self::record_dropped_fields(note, &mut report);
                    }
                    ImportOutcome::Updated { tunnels_created, fdc_classified } => {
                        report.drawers_updated += 1;
                        report.tunnels_created += tunnels_created;
                        if fdc_classified { report.fdc_classified += 1; } else { report.fdc_unclassified += 1; }
                        Self::record_dropped_fields(note, &mut report);
                    }
                    ImportOutcome::Skipped { .. } => {
                        report.items_skipped += 1;
                    }
                    ImportOutcome::SkippedUnchanged => {
                        // Content-idempotent no-op: lineage active, content unchanged.
                        // No substrate write occurs; the count is surfaced for observability.
                        report.drawers_skipped_unchanged += 1;
                    }
                    ImportOutcome::SkippedTombstoned => {
                        // Tombstone respected: lineage was erased, not resurrected.
                        // Surfaced in the report so callers know which notes were blocked.
                        report.drawers_skipped_tombstoned += 1;
                    }
                    ImportOutcome::SkippedWithPartialWrite { .. } => {
                        // Partial write: the supersession cascade committed the
                        // successor row before the predecessor belief-state flip
                        // failed (DisciplineViolation). The estate has an orphaned
                        // successor; the count is surfaced for reconciliation —
                        // never absorbed into items_skipped (zero-loss C-13).
                        report.drawers_skipped_partial_write += 1;
                    }
                }
            }
        }
        // Encode-enqueue sweep: the bulk `capture_batch` path intentionally skips
        // the per-item encode hook (to avoid O(N) queue writes inside a single
        // transaction on large imports). After the batch write completes, collect
        // all newly-imported drawers not yet in the Corpus BundleStore and enqueue
        // them for BM25/vector encoding (idempotent, capped at REINDEX_MAX_JOBS =
        // 10,000 per call). The per-item path uses `capture_with_mode(Regular)` which
        // enqueues each drawer individually, so this sweep returns 0 for those runs.
        if let Some((corpus, jobs)) = self
            .coordinator
            .collect_reindex_jobs(handle)
            .map_err(|e| VaultKitError::VerbError(format!("collect_reindex_jobs failed: {e:?}")))?
        {
            report.enqueued_for_encode = jobs.len();
            if jobs.is_empty() {
                // Nothing was missing: no new chunks enter the corpus, so the
                // Merkle tree and every embedding are exactly as current as
                // before this import — skip the tail entirely (an unchanged
                // reimport must be free). Swift twin: the total == 0 guard in
                // GeniusLocusKit.reindexMissing.
                eprintln!("[vault-import] nothing to index — reindex tail skipped");
            } else {
                eprintln!(
                    "[vault-import] {} drawers enqueued on the encode stream (embedded via the live basis at drain)",
                    jobs.len()
                );
                corpus
                    .enqueue_change_batch(&jobs)
                    .map_err(|e| VaultKitError::VerbError(format!("enqueue_change_batch failed: {e:?}")))?;
                self.coordinator
                    .rollup_after_reindex(handle, now / 1000)
                    .map_err(|e| VaultKitError::VerbError(format!("rollup_after_reindex failed: {e:?}")))?;
            }
        }

        let entry = format!(
            "{{\"operation\":\"vault-import\",\"source\":{},\"drawersWritten\":{},\"drawersUpdated\":{},\"itemsSkipped\":{},\"tunnelsCreated\":{},\"occurredAt\":\"{}\"}}",
            json_string(source),
            report.drawers_written,
            report.drawers_updated,
            report.items_skipped,
            report.tunnels_created,
            ms_to_iso8601(now),
        );
        self.write_receipt(&entry, handle, now)?;
        Ok(report)
    }

    // MARK: - Audit receipts

    /// File one receipt into the estate diary through the coordinator's
    /// sanctioned `estate_for` access point (the same seam `DrawerMapping`
    /// uses for standalone tunnel capture). The coordinator's
    /// `add_diary_entry` facade fixes wing/room/bitmap to the agent-diary
    /// convention, so the receipt — which carries the `Migration` event
    /// class and its own wing/room — is constructed here and written via
    /// `Estate::add_diary_entry` directly.
    ///
    /// `filed_at` carries the caller-supplied `now` converted from the
    /// bridge's milliseconds to the diary's epoch-seconds convention, so the
    /// receipt is deterministic and queryable by time.
    fn write_receipt(
        &self,
        entry_text: &str,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<(), VaultKitError> {
        // Spec § 5.6 diary operational bitmap: Migration event (bits 0–3 —
        // "data migrated in or out of estate"), Info severity (bits 4–6),
        // MigrationTool actor (bits 7–9). Standalone batch membership and no
        // follow-up flag (both zero). Mirrors Swift `VaultBridge.receiptBitmap`.
        let bitmap = DiaryEventClass::Migration.raw_value()
            | (DiarySeverity::Info.raw_value() << 4)
            | (DiaryActorClass::MigrationTool.raw_value() << 7);
        let mut entry = DiaryEntry::new(
            Uuid::new_v4().to_string(),
            Self::RECEIPT_AGENT_NAME.to_string(),
            entry_text.to_string(),
            "vault-receipt".to_string(),
            "wing_vaultkit".to_string(),
            "receipts".to_string(),
            now / 1000,
            // Receipts carry no embedding; the storage layer requires a
            // non-empty model id (same convention as the dreaming daemon).
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

    // MARK: - Zero-loss accounting (C-13)

    /// Record which of an imported note's `NoteIR` fields did NOT ride
    /// into the substrate, per the zero-loss invariant C-13. Mirrors
    /// Swift `VaultBridge.recordDroppedFields(of:in:)`.
    ///
    /// All structured `NoteIR` fields now land in the substrate (hard-close #29):
    ///   - facts → KG facts (subject/predicate/object)
    ///   - scope → KG facts (subject "scope:<key>")
    ///   - path_components → full room path
    ///   - tags → KG facts (subject "tag:<t>", predicate "tagged")
    ///   - kind (when != "note") → KG fact (subject "record:kind", predicate "is")
    ///
    /// This method records nothing for any fully-structured note.
    /// The `fields_dropped` map remains in the public API for future
    /// additions and for any adapter that introduces genuinely unmappable fields.
    fn record_dropped_fields(_note: &crate::note_ir::NoteIR, _report: &mut ImportReport) {
        // All fields now land in substrate — nothing to record for the current
        // mapping. See doc comment above for the complete field disposition.
    }

    // MARK: - Snapshot helpers

    /// The lineage IDs and wing set of currently-believed drawers, plus a
    /// map from `lineage_id` → verbatim content for the content-idempotent
    /// check (FINDING-1a). Mirrors Swift `VaultBridge.existingDrawerState`.
    ///
    /// Hydration level is `Full` so `drawer.content` is populated.
    /// `Structured` reads metadata rows only and leaves content empty, which
    /// would make the content-idempotent check always false (spurious supersession).
    ///
    /// When a lineage has more than one active row (supersession race), the
    /// first-seen content wins — the check is conservative: any active content
    /// match prevents an unnecessary supersession.
    fn existing_drawer_state(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<(HashSet<Uuid>, HashSet<String>, std::collections::HashMap<Uuid, String>, std::collections::HashMap<Uuid, String>), VaultKitError> {
        // limit 10_000_000 = "all drawers" — the same full-scan intent as the
        // sibling existing_sensitivity_by_lineage below. Without an explicit
        // limit the recall scan caps at the candidate floor (256), silently
        // truncating estates with more than 256 drawers and causing
        // written-vs-updated misclassification for drawers #257+. Matches Swift
        // VaultBridge.existingDrawerState. trace_limit None: not a reward-cycle
        // caller.
        // HydrationLevel::Full: required to populate drawer.content for the
        // content-idempotent check (FINDING-1a). Structured would leave content
        // blank, making every re-import appear changed.
        //
        // Security (Finding 6 — all-tier gap): the scan must cover ALL active
        // (non-tombstoned) drawers regardless of confirmation state or sensitivity
        // tier. The previous filter_chain: vec![Filter::Unconfirmed] made confirmed,
        // restricted, and secret lineages invisible to the collision guard — a hostile
        // vault note claiming one of those lineage IDs with different content would
        // bypass the guard and poison that lineage. The fix mirrors
        // existing_sensitivity_by_lineage (lines below), which already lifts the
        // sensitivity ceiling to Secret for the same reason. This is an internal
        // integrity guard only: lineage IDs and content hashes are read locally for
        // collision detection and never leave this function.
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
            hydration_level: HydrationLevel::Full,
            limit: Some(10_000_000),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let drawers: Vec<locus_kit::drawer::Drawer> = self
            .coordinator
            .recall(handle, frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;

        // Resolve wing display names from the node tree (node-tree integrity: Drawer no
        // longer stores wing/room strings directly).
        let node_names = crate::drawer_mapping::resolve_drawer_node_names(
            self.coordinator, handle, &drawers,
        );

        let mut lineage_ids: HashSet<Uuid> = HashSet::new();
        let mut wings: HashSet<String> = HashSet::new();
        let mut content_by_lineage: std::collections::HashMap<Uuid, String> =
            std::collections::HashMap::new();
        // stable_source_key_by_lineage: the vault path ("<wing>/<room>/<slug>")
        // the export would assign to each drawer. Used by the lineage-hijack guard
        // (path-identity discriminator) to distinguish a legitimate round-trip edit
        // (same file, same path) from a hostile note at a different path claiming
        // the victim's moot_id. Computed from current estate content and node-tree
        // names — same inputs the export uses — so this key exactly matches the
        // stable_source_key a note carries when it returns from an export.
        // First-seen wins (matches the content_by_lineage policy above).
        let mut stable_source_key_by_lineage: std::collections::HashMap<Uuid, String> =
            std::collections::HashMap::new();
        for d in drawers {
            lineage_ids.insert(d.lineage_id);
            // Wing and room resolved from the node tree via parent_node_id.
            if let Some((wing, room)) = node_names.get(&d.parent_node_id) {
                wings.insert(wing.clone());
                // Compute the vault path the export would use for this drawer so
                // the hijack guard can compare against the incoming note's path.
                stable_source_key_by_lineage
                    .entry(d.lineage_id)
                    .or_insert_with(|| {
                        let slug = DrawerMapping::slug(&d.content, &d.lineage_id.to_string());
                        format!("{}/{}/{}", wing, room, slug)
                    });
            }
            // Store the first-seen content for each lineage_id. When multiple
            // rows share a lineage (supersession race), any content match
            // prevents an unnecessary supersession — conservative is correct.
            content_by_lineage.entry(d.lineage_id).or_insert(d.content);
        }
        Ok((lineage_ids, wings, content_by_lineage, stable_source_key_by_lineage))
    }

    /// The set of lineage IDs the import path must not resurrect — lineages
    /// that have been deliberately deleted (state = 18 withdrawn, or cluster C
    /// erased/tombstoned) minus any lineage that currently has an active head.
    /// Mirrors Swift `VaultBridge.existingTombstonedLineageIDs`.
    ///
    /// ## What belongs in the tombstone set
    ///
    /// Only genuinely-removed lineages block re-import. `Withdrawn` (state 18)
    /// is the explicit operator-retraction: the user or agent deliberately said
    /// "this note should not resurface." Cluster C (`Rejected`=32, `Tombstoned`=33)
    /// is a legal-compliance hard delete. Neither should be undone by a vault
    /// re-import.
    ///
    /// The previous implementation used `Filter::UsedToBelieve` (all of cluster B:
    /// Superseded=16, Decayed=17, Withdrawn=18, Expired=19). That incorrectly
    /// treated normal content-update predecessors as tombstones:
    ///
    ///   1. Import note (v1) → drawer1 (lineage L, state Active)
    ///   2. Import updated note (v2) → supersession: drawer1 (L, Superseded),
    ///      drawer2 (L, Active). Update succeeds.
    ///   3. Import updated note (v3) → `UsedToBelieve` returns drawer1 (L,
    ///      Superseded) → L in tombstone set → tombstone guard fires before
    ///      the active-head / sensitivity-upgrade branch → skipped-tombstoned
    ///      → update BLOCKED. Sensitivity raises after any content update
    ///      were permanently blocked by the same false positive.
    ///
    /// Fix: restrict the cluster-B recall to `Filter::State(State::Withdrawn)` only —
    /// the single state value that represents a deliberate operator retraction
    /// with no active successor. Belt-and-suspenders: subtract `active_lineage_ids`
    /// so a lineage cannot be simultaneously active and in the tombstone set.
    ///
    /// `active_lineage_ids`: the set of lineages with a currently-believed active
    /// drawer, computed by `existing_drawer_state` immediately before this call.
    fn existing_tombstoned_lineage_ids(
        &self,
        handle: &EstateHandle,
        now: i64,
        active_lineage_ids: &HashSet<Uuid>,
    ) -> Result<HashSet<Uuid>, VaultKitError> {
        // Cluster B — withdrawn only (state = 18): explicit operator retraction.
        //
        // NOT Filter::UsedToBelieve (all of cluster B): Superseded (16) is a normal
        // content-update predecessor, Decayed (17) is matrix-confidence decay,
        // Expired (19) is TTL expiry — all three can coexist with an active
        // successor and must not block re-import. Only Withdrawn (18) means
        // "deliberately removed; do not resurface."
        let frame = RecallFrame {
            filter_chain: vec![Filter::State(State::Withdrawn)],
            hydration_level: HydrationLevel::Structured,
            limit: Some(10_000_000),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let withdrawn_drawers = self
            .coordinator
            .recall(handle, frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        // Belt-and-suspenders: subtract the active-head set so a lineage can
        // never be simultaneously active and tombstoned. Defence-in-depth guard —
        // under the corrected State::Withdrawn filter no withdrawn lineage should
        // have an active head; the subtraction guards against any edge case where
        // that assumption is violated.
        let withdrawn_ids: HashSet<Uuid> = withdrawn_drawers
            .into_iter()
            .map(|d| d.lineage_id)
            .filter(|id| !active_lineage_ids.contains(id))
            .collect();

        // Cluster C: expunged/tombstoned lineages (tombstoned_at IS NOT NULL,
        // state ≥ 32). Invisible to the recall pipeline. Reached via the GLK
        // passthrough to Estate::all_drawers() — the only scan that includes
        // tombstoned rows. B-1 compliant: VaultKit never imports LocusKit's
        // DrawerStore directly.
        let erased_ids = self
            .coordinator
            .tombstoned_lineage_ids(handle)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;

        Ok(withdrawn_ids.union(&erased_ids).copied().collect())
    }

    /// The current sensitivity tier of every believed drawer, keyed by
    /// lineage (max across versions of a lineage). The recall lifts the
    /// evaluator's implicit `Elevated` ceiling with an explicit
    /// `SensitivityAtMost(Secret)` so restricted and secret drawers are
    /// visible — they must be, or the import floor could not protect them.
    /// Used only to enforce the no-downgrade floor on re-import; it does not
    /// affect written-vs-updated classification. Mirrors Swift
    /// `VaultBridge.existingSensitivityByLineage`.
    fn existing_sensitivity_by_lineage(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<std::collections::HashMap<Uuid, AdjectiveSensitivity>, VaultKitError> {
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
            // limit 10_000_000 = "all drawers" (full-scan intent). Without an
            // explicit limit the recall scan caps at the candidate floor (256),
            // silently missing drawers #257+ on estates with >256 drawers and
            // weakening the no-downgrade sensitivity floor. Matches Swift.
            limit: Some(10_000_000),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            // trace_limit None: VaultBridge scans do not participate in the
            // reward cycle and must not write trace rows.
            trace_limit: None,
        };
        let drawers = self
            .coordinator
            .recall(handle, frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let mut map: std::collections::HashMap<Uuid, AdjectiveSensitivity> =
            std::collections::HashMap::new();
        for drawer in drawers {
            let tier = drawer.adjective_sensitivity();
            map.entry(drawer.lineage_id)
                .and_modify(|cur| {
                    if tier.raw_value() > cur.raw_value() {
                        *cur = tier;
                    }
                })
                .or_insert(tier);
        }
        Ok(map)
    }

    /// The stable signatures of existing `.references` tunnels, so a re-import
    /// does not duplicate them.
    fn existing_tunnel_signatures(
        &self,
        handle: &EstateHandle,
        wings: &HashSet<String>,
    ) -> Result<HashSet<String>, VaultKitError> {
        let mut sigs: HashSet<String> = HashSet::new();
        for wing in wings {
            let tunnels = self
                .coordinator
                .recall_tunnels(handle, wing)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
            for tunnel in tunnels.into_iter().filter(|t| t.kind == TunnelKind::References) {
                sigs.insert(DrawerMapping::tunnel_signature(
                    &tunnel.source_wing,
                    &tunnel.source_room,
                    &tunnel.target_room,
                    &tunnel.label,
                    TunnelKind::References,
                ));
            }
        }
        Ok(sigs)
    }
}

/// Minimal JSON string encoder for receipt fields that carry arbitrary
/// filesystem paths (quotes/backslashes escaped per RFC 8259). Mirrors
/// Swift `VaultBridge.jsonString(_:)`.
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
