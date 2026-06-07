//! VaultBridge and ImportReport — the public facade.
//!
//! `VaultBridge` is a thin facade: a `VaultAdapter` handles file ⇄ `NoteIR`,
//! and `DrawerMapping` handles `NoteIR` ⇄ substrate. The bridge fuses the two
//! into one operation per MOOT. Mirrors Swift `VaultBridge`.
//!
//! `now` is always passed by the caller — never read from the wall clock
//! internally — so the bridge is deterministic. The caller supplies a
//! milliseconds-since-epoch integer.

use crate::drawer_mapping::{DrawerMapping, ImportOutcome};
use crate::error::VaultKitError;
use crate::vault_adapter::VaultAdapter;
use crate::vault_export_scope::VaultExportScope;
use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
use locus_kit::{
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
}

/// The public facade: bridges a MOOT estate and a Markdown vault in both
/// directions. Mirrors Swift `VaultBridge`.
pub struct VaultBridge<'a> {
    coordinator: &'a EstateCoordinator,
    adapter: Box<dyn VaultAdapter>,
    mapping: DrawerMapping,
}

impl<'a> VaultBridge<'a> {
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

    /// Project an estate to a Markdown vault. Mirrors Swift `VaultBridge.export(estate:to:scope:)`.
    ///
    /// `scope` controls which drawers are included in the export (default
    /// `VaultExportScope::Believed` when called through `run_export` in
    /// `vault_tools.rs`). Use `VaultExportScope::Confirmed` to export only
    /// user-confirmed drawers, `VaultExportScope::Unconfirmed` for the
    /// capture-inbox view, or `VaultExportScope::Exportable` for publicly-
    /// exportable drawers only.
    ///
    /// `now` is milliseconds-since-epoch, supplied by the caller.
    pub fn export(
        &self,
        handle: &EstateHandle,
        vault_path: &Path,
        now: i64,
        scope: VaultExportScope,
    ) -> Result<(), VaultKitError> {
        let notes = self.mapping.export(self.coordinator, handle, now, scope)?;
        self.adapter.from_ir(&notes, vault_path)?;
        Ok(())
    }

    // MARK: - Import

    /// Import a Markdown vault into an estate via the capture seam. Idempotent
    /// on each note's `stable_source_key`. Every captured drawer satisfies I-5.
    /// Mirrors Swift `VaultBridge.importVault(at:into:)`.
    ///
    /// `now` is milliseconds-since-epoch, supplied by the caller.
    pub fn import_vault(
        &self,
        vault_path: &Path,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<ImportReport, VaultKitError> {
        let notes = self.adapter.to_ir(vault_path)?;

        // Snapshot existing state once so written-vs-updated and tunnel
        // de-duplication need no per-note probe.
        let (existing_lineage_ids, existing_wings) =
            self.existing_drawer_state(handle, now)?;
        let mut existing_tunnel_sigs = self.existing_tunnel_signatures(handle, &existing_wings)?;

        let mut report = ImportReport::default();
        for note in &notes {
            let outcome = self.mapping.import_note(
                note,
                self.coordinator,
                handle,
                &existing_lineage_ids,
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
                }
                ImportOutcome::Updated { tunnels_created, fdc_classified } => {
                    report.drawers_updated += 1;
                    report.tunnels_created += tunnels_created;
                    if fdc_classified {
                        report.fdc_classified += 1;
                    } else {
                        report.fdc_unclassified += 1;
                    }
                }
                ImportOutcome::Skipped { .. } => {
                    report.items_skipped += 1;
                }
            }
        }
        Ok(report)
    }

    // MARK: - Snapshot helpers

    /// The lineage IDs of currently-believed drawers and the wings they occupy.
    fn existing_drawer_state(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<(HashSet<Uuid>, HashSet<String>), VaultKitError> {
        let frame = RecallFrame {
            filter_chain: vec![Filter::Unconfirmed],
            hydration_level: HydrationLevel::Structured,
            limit: None,
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
        };
        let drawers = self
            .coordinator
            .recall(handle, frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let lineage_ids: HashSet<Uuid> = drawers.iter().map(|d| d.lineage_id).collect();
        let wings: HashSet<String> = drawers.into_iter().map(|d| d.wing).collect();
        Ok((lineage_ids, wings))
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
