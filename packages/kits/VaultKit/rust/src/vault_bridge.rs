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
//! ## Audit receipts (ADR-007 Decision 2)
//!
//! Every successful export and import run writes one receipt into the
//! estate's diary — "what left, where, when, how many." The bitmap-audit
//! trail is per-row and cannot carry an estate-level payload, so receipts
//! use the diary: the estate-level event log whose `Migration` event class
//! (spec § 5.6) exists for exactly this. See `DECISION_NEEDED_VK-TIER-01`.

use crate::drawer_mapping::{ms_to_iso8601, DrawerMapping, ImportOutcome};
use crate::error::VaultKitError;
use crate::vault_adapter::VaultAdapter;
use crate::vault_export_scope::VaultExportScope;
use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    diary_entry::DiaryEntry,
    diary_operational::{DiaryActorClass, DiaryEventClass, DiarySeverity},
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
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
}

/// Counts returned by an export run, including the per-tier exclusion counts
/// the ADR-007 Decision 2 bulk-channel rules produced. Exclusions are
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
pub struct VaultBridge<'a> {
    coordinator: &'a EstateCoordinator,
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
    ///   reads and writes.
    /// - `adapter`: the vault format adapter. Pass `Box::new(ObsidianAdapter::new())`
    ///   for the default Obsidian behaviour.
    /// - `mapping`: the substrate mapping policy.
    pub fn new(
        coordinator: &'a EstateCoordinator,
        adapter: Box<dyn VaultAdapter>,
        mapping: DrawerMapping,
    ) -> Self {
        Self { coordinator, adapter, mapping }
    }

    // MARK: - Export

    /// Project an estate to a Markdown vault. Mirrors Swift
    /// `VaultBridge.export(estate:to:scope:now:)`.
    ///
    /// Enforces the ADR-007 Decision 2 privacy-tier rules on this bulk
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
    ) -> Result<ExportReport, VaultKitError> {
        let projection = self.mapping.export(self.coordinator, handle, now, scope)?;
        self.adapter.from_ir(&projection.notes, vault_path)?;
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
    /// Import is ungated (ADR-007: arrival is free), but each note's
    /// sensitivity tier is preserved from the IR when the adapter supplies it
    /// (`sensitivity` frontmatter → `CaptureFrame.sensitivity`). A successful
    /// run writes one audit receipt to the estate's diary.
    ///
    /// `now` is milliseconds-since-epoch, supplied by the caller and stamped
    /// on the audit receipt.
    pub fn import_vault(
        &self,
        vault_path: &Path,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<ImportReport, VaultKitError> {
        let notes = self.adapter.to_ir(vault_path)?;
        self.import_notes(&notes, handle, &vault_path.display().to_string(), now)
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
    pub fn import_vault_filtered(
        &self,
        vault_path: &Path,
        candidate_paths: &std::collections::HashSet<String>,
        handle: &EstateHandle,
        now: i64,
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
        self.import_notes(&filtered, handle, &vault_path.display().to_string(), now)
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
    pub fn import_mem_palace(
        &self,
        palace_root: &Path,
        handle: &EstateHandle,
        now: i64,
        adapter: &crate::mem_palace_chroma_adapter::MemPalaceChromaAdapter,
    ) -> Result<ImportReport, VaultKitError> {
        let notes = adapter.to_ir(palace_root)?;
        self.import_notes(&notes, handle, &palace_root.display().to_string(), now)
    }

    /// The shared import core: capture canonical notes into an estate via
    /// the capture seam. `import_vault` and `import_mem_palace` differ only
    /// in which adapter produced the notes; everything from the existing-
    /// state snapshot to the audit receipt is identical and lives here.
    /// Mirrors Swift `VaultBridge.importNotes(_:into:source:now:)`.
    fn import_notes(
        &self,
        notes: &[crate::note_ir::NoteIR],
        handle: &EstateHandle,
        source: &str,
        now: i64,
    ) -> Result<ImportReport, VaultKitError> {
        // Snapshot existing state once so written-vs-updated and tunnel
        // de-duplication need no per-note probe.
        let (existing_lineage_ids, existing_wings) =
            self.existing_drawer_state(handle, now)?;
        // The current tier of every believed drawer across ALL sensitivity
        // levels, so the import sensitivity floor can never be lowered by a
        // re-import (supersession-downgrade defense — see import_note).
        let existing_sensitivity = self.existing_sensitivity_by_lineage(handle, now)?;
        let mut existing_tunnel_sigs = self.existing_tunnel_signatures(handle, &existing_wings)?;

        let mut report = ImportReport::default();
        for note in notes {
            let outcome = self.mapping.import_note(
                note,
                self.coordinator,
                handle,
                &existing_lineage_ids,
                &existing_sensitivity,
                &mut existing_tunnel_sigs,
                now,
            )?;
            match outcome {
                ImportOutcome::Written { tunnels_created, fdc_classified } => {
                    report.drawers_written += 1;
                    report.tunnels_created += tunnels_created;
                    if fdc_classified {
                        report.fdc_classified += 1;
                    } else {
                        report.fdc_unclassified += 1;
                    }
                    Self::record_dropped_fields(note, &mut report);
                }
                ImportOutcome::Updated { tunnels_created, fdc_classified } => {
                    report.drawers_updated += 1;
                    report.tunnels_created += tunnels_created;
                    if fdc_classified {
                        report.fdc_classified += 1;
                    } else {
                        report.fdc_unclassified += 1;
                    }
                    Self::record_dropped_fields(note, &mut report);
                }
                ImportOutcome::Skipped { .. } => {
                    report.items_skipped += 1;
                }
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

    // MARK: - Audit receipts (ADR-007 Decision 2)

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

    /// The lineage IDs of currently-believed drawers and the wings they occupy.
    fn existing_drawer_state(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<(HashSet<Uuid>, HashSet<String>), VaultKitError> {
        // limit 10_000_000 = "all drawers" — the same full-scan intent as the
        // sibling existing_sensitivity_by_lineage below. Without an explicit
        // limit the recall scan caps at the candidate floor (256), silently
        // truncating estates with more than 256 drawers and causing
        // written-vs-updated misclassification for drawers #257+. Matches Swift
        // VaultBridge.existingDrawerState. trace_limit None: not a reward-cycle
        // caller.
        let frame = RecallFrame {
            filter_chain: vec![Filter::Unconfirmed],
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
        let lineage_ids: HashSet<Uuid> = drawers.iter().map(|d| d.lineage_id).collect();
        let wings: HashSet<String> = drawers.into_iter().map(|d| d.wing).collect();
        Ok((lineage_ids, wings))
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
