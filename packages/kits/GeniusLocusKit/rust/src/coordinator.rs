// coordinator.rs — EstateCoordinator: the estate registry and the full
// nine-verb dispatch surface, the Rust parity of the Swift `GeniusLocusKit`
// actor (Sources/GeniusLocusKit/GeniusLocusKit.swift + Verbs/VerbSurface.swift).
//
// The registry holds a live `locus_kit::Estate` per open handle; all nine
// verbs delegate to it exactly as the Swift `extension GeniusLocusKit` verbs
// delegate to `estate(for: handle)`. Six verbs (capture/recall/mutate/
// withdraw/expunge/reanchor) reach a real Estate implementation; three
// (learn/propose/associate) return `NotSupportedByEstate` until their
// Brain-layer bodies ship — matching observable Swift behavior on both legs.
//
// The boundary guards (EmptyReanchor at reanchor, ExpungeNotConfirmed at
// expunge) fire before any estate dispatch, parity of the Swift guards.
//
// The parity taxonomy (VerbError, VERB_NAMES, Verb, Noun, SurfaceTarget)
// lives in `verbs::lexicon` and is imported by both this coordinator and
// the parity tests.

use std::collections::HashMap;
use std::sync::Arc;

use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::error::LocusKitError;
use locus_kit::estate::Estate;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::RecallFrame;
use locus_kit::frames::{CaptureFrame, MutationKind};
use locus_kit::tunnel::Tunnel;

use crate::handle::{EstateHandle, EstateUuid};
use crate::verbs::lexicon::VerbError;

/// Errors raised by the GeniusLocusKit composition surface on the Rust
/// side. Mirrors the Swift `GeniusLocusKitError`; cases carry the same
/// identifying data so parity tests match behaviour across ports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GeniusLocusKitError {
    /// Caller passed a manifest that violates the kit's preconditions.
    InvalidManifest { key: String, detail: String },

    /// A handle was used after the estate it referenced was closed, or a
    /// handle that was never issued by this coordinator was passed in.
    EstateNotOpen { estate_uuid: EstateUuid },

    /// An attempt to open an estate whose UUID matches one already in the
    /// registry. Estate UUIDs are immutable per spec § 7.7, so a duplicate
    /// is almost always the same database file being opened twice.
    DuplicateEstate { estate_uuid: EstateUuid },

    /// Caller asked for a fan-out region whose `low` exceeds its `high`.
    InvalidLatticeRegion { low: i64, high: i64 },

    /// `Estate::open` failed on the underlying store (bad manifest, layout
    /// mismatch, empty owner). Carries the textual cause; the Swift side
    /// lets the LocusKit error propagate from `Estate.open`.
    EstateOpenFailed { detail: String },
}

/// The outcome of a verb dispatch. Rust needs a typed error where Swift
/// uses untyped `throws` over two domains: `estate(for:)` throwing
/// `GeniusLocusKitError.estateNotOpen` (outside the per-verb do/catch), and
/// the verb body throwing `VerbError`. This union encodes both faithfully
/// without altering the parity-gated `VerbError` enum.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerbDispatchError {
    /// The addressed estate was not open (parity of the Swift
    /// `GeniusLocusKitError.estateNotOpen` a verb propagates).
    EstateNotOpen { estate_uuid: EstateUuid },
    /// A verb-surface failure (boundary guard, underlying estate failure,
    /// or not-supported), parity of the Swift `VerbError`.
    Verb(VerbError),
}

impl From<VerbError> for VerbDispatchError {
    fn from(e: VerbError) -> Self {
        VerbDispatchError::Verb(e)
    }
}

/// Remap a LocusKit estate error to the verb surface's `VerbError`, parity
/// of the Swift `remap(verb:error:)`: a `not yet implemented` stub error
/// becomes `NotSupportedByEstate`; anything else is an
/// `UnderlyingEstateFailure`. (The GLK-error passthrough Swift's remap does
/// is handled in Rust by `estate_for` surfacing `EstateNotOpen` before the
/// verb body runs.)
fn remap(verb: &str, error: LocusKitError) -> VerbError {
    if let LocusKitError::InvalidContent(detail) = &error {
        if detail.contains("not yet implemented") {
            return VerbError::NotSupportedByEstate {
                verb: verb.to_string(),
            };
        }
    }
    VerbError::UnderlyingEstateFailure {
        verb: verb.to_string(),
        reason: format!("{error:?}"),
    }
}

/// The coordinator. Owns the registry of currently-open estates and is the
/// live verb-dispatch surface. Construction is cheap; the registry starts
/// empty. Callers admit estates via `open` and address them by
/// `EstateHandle` thereafter.
///
/// It also owns the COW-branch registry (`branches`), parity of the Swift
/// actor's `branches: [BranchID: EstateBranch]`: branches are inserted by
/// `glk_derive_branch` and retained through every lifecycle state so the
/// audit trail stays reachable (I-15). The branch verbs live in
/// `branches.rs` as an `impl EstateCoordinator` block.
#[derive(Default)]
pub struct EstateCoordinator {
    registry: HashMap<EstateHandle, Estate>,
    pub(crate) branches: HashMap<crate::branches::BranchId, crate::branches::EstateBranch>,
}

impl EstateCoordinator {
    /// Construct a coordinator with empty estate and branch registries.
    pub fn new() -> Self {
        Self {
            registry: HashMap::new(),
            branches: HashMap::new(),
        }
    }

    /// Number of estates currently open.
    pub fn open_estate_count(&self) -> usize {
        self.registry.len()
    }

    /// Snapshot of currently-open estate handles. `HashMap`-iteration order
    /// (unspecified); callers needing stable order sort by `estate_uuid`.
    pub fn handles(&self) -> Vec<EstateHandle> {
        self.registry.keys().copied().collect()
    }

    /// Admit an estate into the registry. Opens the underlying
    /// `locus_kit::Estate` over `store` (parity of the Swift
    /// `LocusKit.Estate.open(storage:owner:)` call inside the actor's
    /// `open`), derives the handle's UUID from the opened estate, and
    /// registers it under a fresh `EstateHandle` carrying the zoom window.
    ///
    /// Refuses a UUID already registered (spec § 7.7: estate UUIDs are
    /// immutable, so a duplicate is almost certainly the same store opened
    /// twice).
    pub fn open(
        &mut self,
        store: Arc<dyn DrawerStore>,
        owner: OwnerCredentials,
        zoom_window_low: i64,
        zoom_window_high: i64,
    ) -> Result<EstateHandle, GeniusLocusKitError> {
        let estate =
            Estate::open(store, owner).map_err(|e| GeniusLocusKitError::EstateOpenFailed {
                detail: format!("{e:?}"),
            })?;
        let estate_uuid: EstateUuid = estate.estate_uuid().into_bytes();
        let handle = EstateHandle::new(estate_uuid, zoom_window_low, zoom_window_high)?;
        if self.registry.contains_key(&handle) {
            return Err(GeniusLocusKitError::DuplicateEstate { estate_uuid });
        }
        self.registry.insert(handle, estate);
        Ok(handle)
    }

    /// Remove an estate from the registry. The handle becomes stale;
    /// subsequent `estate_for` lookups return `EstateNotOpen`.
    pub fn close(&mut self, handle: &EstateHandle) -> Result<(), GeniusLocusKitError> {
        if self.registry.remove(handle).is_none() {
            return Err(GeniusLocusKitError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            });
        }
        Ok(())
    }

    /// Resolve a handle to its live estate. Parity of the Swift
    /// `estate(for:)`; returns `EstateNotOpen` for a stale or never-issued
    /// handle.
    pub fn estate_for(&self, handle: &EstateHandle) -> Result<&Estate, GeniusLocusKitError> {
        self.registry
            .get(handle)
            .ok_or(GeniusLocusKitError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            })
    }

    // Internal: resolve to an estate, mapping the not-open case into the
    // verb-dispatch error domain (parity of `estate(for:)` propagating
    // `estateNotOpen` out of a verb).
    fn estate_for_verb(&self, handle: &EstateHandle) -> Result<&Estate, VerbDispatchError> {
        self.registry
            .get(handle)
            .ok_or(VerbDispatchError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            })
    }

    // MARK: - capture

    /// File a new drawer into the estate addressed by `handle`. Parity of
    /// the Swift `capture(_:_:)`. `now` is explicit per the Rust substrate's
    /// determinism convention (the Swift estate reads its own clock).
    pub fn capture(
        &self,
        handle: &EstateHandle,
        frame: CaptureFrame,
        now: i64,
    ) -> Result<Drawer, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .capture(frame, now)
            .map_err(|e| remap("capture", e).into())
    }

    // MARK: - recall

    /// Recall rows from the estate addressed by `handle`, draining the
    /// stream into a materialized array. Parity of the Swift `recall(_:_:)`.
    pub fn recall(
        &self,
        handle: &EstateHandle,
        frame: RecallFrame,
        now: i64,
    ) -> Result<Vec<Drawer>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        Ok(estate.recall(frame, now).collect_all())
    }

    // MARK: - recall_tunnels

    /// Read the tunnels originating in `wing` for the estate addressed by
    /// `handle` — the graph-read accessor a structural reasoning lens
    /// (keystone centrality) needs. The drawer-to-drawer tunnels are the
    /// edges of the association graph. Read-only; parallels `recall`.
    pub fn recall_tunnels(
        &self,
        handle: &EstateHandle,
        wing: &str,
    ) -> Result<Vec<Tunnel>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .tunnels_from_wing(wing)
            .map_err(|e| remap("recall_tunnels", e).into())
    }

    // MARK: - mutate

    /// Apply a named mutation to a drawer. The `Confirm` kind is live — it
    /// transitions the row's confirmation axis to `UserConfirmed` and returns
    /// `Ok`. The state-axis kinds (Reject/Contest/Resolve/Supersede/Revive)
    /// are not yet wired in LocusKit and return
    /// `InvalidContent("…not yet implemented…")`, which `remap` turns into
    /// `NotSupportedByEstate { verb: "mutate" }` — parity of the Swift surface.
    pub fn mutate(
        &self,
        handle: &EstateHandle,
        row_id: &str,
        kind: MutationKind,
        payload: Option<&str>,
    ) -> Result<(), VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .mutate(row_id, kind, payload)
            .map_err(|e| remap("mutate", e).into())
    }

    // MARK: - withdraw

    /// Withdraw a drawer — move its `State` axis to `withdrawn`. Parity of
    /// the Swift `withdraw(_:_:)`.
    pub fn withdraw(
        &self,
        handle: &EstateHandle,
        row_id: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .withdraw(row_id, reason, now)
            .map_err(|e| remap("withdraw", e).into())
    }

    // MARK: - expunge

    /// Tombstone a drawer and zeroize its content. Raises
    /// `VerbError::ExpungeNotConfirmed` at the boundary when `confirmation`
    /// is false (the substrate is not reached) — parity of the Swift guard.
    pub fn expunge(
        &self,
        handle: &EstateHandle,
        row_id: &str,
        reason: &str,
        confirmation: bool,
    ) -> Result<(), VerbDispatchError> {
        if !confirmation {
            return Err(VerbError::ExpungeNotConfirmed {
                row_id: row_id.to_string(),
            }
            .into());
        }
        let estate = self.estate_for_verb(handle)?;
        estate
            .expunge(row_id, reason, confirmation)
            .map_err(|e| remap("expunge", e).into())
    }

    // MARK: - reanchor

    /// Move a drawer's room and/or lattice anchor. At least one of `to_room`
    /// / `to_lattice` must be present; an empty reanchor raises
    /// `VerbError::EmptyReanchor` at the boundary before dispatch — parity
    /// of the Swift guard.
    pub fn reanchor(
        &self,
        handle: &EstateHandle,
        row_id: &str,
        to_room: Option<&str>,
        to_lattice: Option<LatticeAnchor>,
    ) -> Result<(), VerbDispatchError> {
        if to_room.is_none() && to_lattice.is_none() {
            return Err(VerbError::EmptyReanchor {
                row_id: row_id.to_string(),
            }
            .into());
        }
        let estate = self.estate_for_verb(handle)?;
        estate
            .reanchor(row_id, to_room, to_lattice)
            .map_err(|e| remap("reanchor", e).into())
    }

    // MARK: - learn

    /// Ingest a learned reference into the estate addressed by `handle`.
    ///
    /// `learn` is grounding-driven per AriaLexicon's flow taxonomy. The
    /// underlying `Estate::learn` is a stub that returns `InvalidContent`
    /// ("learn not yet implemented"); `remap` turns that into
    /// `VerbError::NotSupportedByEstate { verb: "learn" }` — parity of the
    /// Swift GLK surface, which raises `VerbError.notSupportedByEstate(verb:
    /// "learn")` until the Brain layer ships.
    ///
    /// Validates the handle first so a stale handle raises
    /// `EstateNotOpen` uniformly, matching the other verbs.
    pub fn learn(
        &self,
        handle: &EstateHandle,
        _source_handle: &str,
    ) -> Result<(), VerbDispatchError> {
        // Validate handle before attempting dispatch — stale handle must raise
        // EstateNotOpen, not NotSupportedByEstate.
        self.estate_for_verb(handle)?;
        Err(VerbError::NotSupportedByEstate {
            verb: "learn".to_string(),
        }
        .into())
    }

    // MARK: - propose

    /// Brain-layer verb — substrate-driven proposal creation. Validates
    /// the handle first so a stale handle raises `EstateNotOpen` uniformly
    /// (parity of Swift `estate(for:)` propagating out of a verb). Returns
    /// `NotSupportedByEstate` until the Brain layer ships, matching the
    /// Swift GLK surface's `VerbError.notSupportedByEstate(verb: "propose")`.
    pub fn propose(
        &self,
        handle: &EstateHandle,
        _frame: crate::verbs::frames::ProposeFrame,
    ) -> Result<(), VerbDispatchError> {
        self.estate_for_verb(handle)?;
        Err(VerbError::NotSupportedByEstate {
            verb: "propose".to_string(),
        }
        .into())
    }

    // MARK: - associate

    /// Brain-layer verb — substrate-driven association creation. Validates
    /// the handle first so a stale handle raises `EstateNotOpen` uniformly
    /// (parity of Swift `estate(for:)` propagating out of a verb). Returns
    /// `NotSupportedByEstate` until the Brain layer ships, matching the
    /// Swift GLK surface's `VerbError.notSupportedByEstate(verb: "associate")`.
    pub fn associate(
        &self,
        handle: &EstateHandle,
        _frame: crate::verbs::frames::AssociateFrame,
    ) -> Result<(), VerbDispatchError> {
        self.estate_for_verb(handle)?;
        Err(VerbError::NotSupportedByEstate {
            verb: "associate".to_string(),
        }
        .into())
    }

    // MARK: - recall_kg_facts

    /// Recall kg-fact rows for the estate addressed by `handle`.
    ///
    /// Stub: the DrawerStore trait has no `all_kg_facts()` accessor (only
    /// `kg_facts_for_drawer(source_drawer_id)`, a filtered query). Until the
    /// trait gains an all-facts read path, this method returns
    /// `NotSupportedByEstate` so the MCP surface advertises the tool honestly
    /// without pretending it works. (Swift reconciliation item: the Swift server
    /// also has no live `kgFact_recall` handler — it falls through to
    /// methodNotFound. Rust surfaces error_result instead.)
    pub fn recall_kg_facts(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::kg_fact::KGFact>, VerbDispatchError> {
        self.estate_for_verb(handle)?;
        Err(VerbError::NotSupportedByEstate {
            verb: "recall_kg_facts".to_string(),
        }
        .into())
    }

    // MARK: - recall_diary_entries

    /// Recall diary-entry rows for the estate addressed by `handle`.
    ///
    /// Stub: the DrawerStore trait has `read_diary(agent_name, last_n)` (by-agent
    /// filtered query) but no all-entries read path. Returns
    /// `NotSupportedByEstate` until the trait gains an unconstrained accessor.
    pub fn recall_diary_entries(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::diary_entry::DiaryEntry>, VerbDispatchError> {
        self.estate_for_verb(handle)?;
        Err(VerbError::NotSupportedByEstate {
            verb: "recall_diary_entries".to_string(),
        }
        .into())
    }

    // MARK: - recall_proposals

    /// Recall proposal rows for the estate addressed by `handle`.
    ///
    /// Stub: the DrawerStore trait has `proposals_for_target(target_row_id)` but
    /// no all-proposals read path. Returns `NotSupportedByEstate` until the
    /// trait gains an unconstrained accessor.
    pub fn recall_proposals(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::proposal::Proposal>, VerbDispatchError> {
        self.estate_for_verb(handle)?;
        Err(VerbError::NotSupportedByEstate {
            verb: "recall_proposals".to_string(),
        }
        .into())
    }

    // MARK: - recall_associations

    /// Recall association rows for the estate addressed by `handle`.
    ///
    /// Stub: the DrawerStore trait has `associations_from(wing, room)` and
    /// `associations_to(wing, room)` (filtered queries) but no all-associations
    /// read path. Returns `NotSupportedByEstate` until the trait gains an
    /// unconstrained accessor.
    pub fn recall_associations(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::association::Association>, VerbDispatchError> {
        self.estate_for_verb(handle)?;
        Err(VerbError::NotSupportedByEstate {
            verb: "recall_associations".to_string(),
        }
        .into())
    }

    // MARK: - recall_learned_references

    /// Recall learned-reference rows for the estate addressed by `handle`.
    ///
    /// Stub: the DrawerStore trait has `learned_references_from_source(source_catalog_id)`
    /// (filtered by catalog entry) but no all-references read path. Returns
    /// `NotSupportedByEstate` until the trait gains an unconstrained accessor.
    pub fn recall_learned_references(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::learned_reference::LearnedReference>, VerbDispatchError> {
        self.estate_for_verb(handle)?;
        Err(VerbError::NotSupportedByEstate {
            verb: "recall_learned_references".to_string(),
        }
        .into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};

    const NOW: i64 = 1_700_000_000;

    fn open_one() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let handle = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .expect("open");
        (coord, handle)
    }

    fn cap_frame(content: &str) -> CaptureFrame {
        CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        )
    }

    fn unconfirmed() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    fn confirmed() -> RecallFrame {
        // Admit user-confirmed rows (the evaluator's default ceiling, here
        // explicit) so a confirmed row is returned by recall.
        let mut f = RecallFrame::new(vec![Filter::UserConfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CO-1: capture then recall returns the captured drawer with matching
    // content — the live verb dispatch produces a real dataset (the whole
    // point: the GLK boundary returns the estate's rows, not a stub).
    #[test]
    fn co1_capture_then_recall_returns_the_row() {
        let (coord, h) = open_one();
        let stored = coord.capture(&h, cap_frame("alpha"), NOW).expect("capture");
        assert_eq!(stored.content, "alpha");
        let rows = coord.recall(&h, unconfirmed(), NOW).expect("recall");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, stored.id);
        assert_eq!(rows[0].content, "alpha");
    }

    // CO-2: withdraw moves the row off the unconfirmed/active set — the verb
    // reaches the real estate and mutates state.
    #[test]
    fn co2_withdraw_transitions_state() {
        let (coord, h) = open_one();
        let stored = coord.capture(&h, cap_frame("beta"), NOW).expect("capture");
        coord
            .withdraw(&h, &stored.id, Some("obsolete"), NOW)
            .expect("withdraw");
        // The row is no longer in the unconfirmed set after withdrawal.
        let rows = coord.recall(&h, unconfirmed(), NOW).expect("recall");
        assert!(
            rows.iter().all(|r| r.id != stored.id),
            "withdrawn row left the set"
        );
    }

    // CO-3: expunge without confirmation is refused at the boundary; the
    // substrate is never reached. Parity of the Swift guard.
    #[test]
    fn co3_expunge_requires_confirmation() {
        let (coord, h) = open_one();
        let stored = coord.capture(&h, cap_frame("gamma"), NOW).expect("capture");
        let err = coord.expunge(&h, &stored.id, "cleanup", false).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::ExpungeNotConfirmed { row_id: stored.id })
        );
    }

    // CO-4: an empty reanchor (neither room nor lattice) is refused at the
    // boundary. Parity of the Swift guard.
    #[test]
    fn co4_empty_reanchor_is_refused() {
        let (coord, h) = open_one();
        let err = coord.reanchor(&h, "row-1", None, None).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::EmptyReanchor {
                row_id: "row-1".to_string()
            })
        );
    }

    // CO-5: mutate(Confirm) reaches the real estate and transitions the row's
    // confirmation axis to UserConfirmed — the live verb dispatch produces a
    // real state change (parity of Swift Estate.mutate(.confirm)).
    #[test]
    fn co5_mutate_confirm_transitions_confirmation() {
        use locus_kit::provenance::Confirmation;
        let (coord, h) = open_one();
        let stored = coord.capture(&h, cap_frame("delta"), NOW).expect("capture");
        coord
            .mutate(&h, &stored.id, MutationKind::Confirm, None)
            .expect("mutate confirm");
        // The row now satisfies the user-confirmed ceiling.
        let rows = coord.recall(&h, confirmed(), NOW).expect("recall");
        let row = rows
            .iter()
            .find(|r| r.id == stored.id)
            .expect("confirmed row present in recall");
        assert_eq!(row.confirmation(), Confirmation::UserConfirmed);
    }

    // CO-5b: a state-axis mutation kind (Reject) is not yet wired and remaps
    // to NotSupportedByEstate — the dispatch chain's error mapping is intact.
    #[test]
    fn co5b_state_axis_mutate_is_not_supported() {
        let (coord, h) = open_one();
        let stored = coord
            .capture(&h, cap_frame("epsilon"), NOW)
            .expect("capture");
        let err = coord
            .mutate(&h, &stored.id, MutationKind::Reject, None)
            .unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::NotSupportedByEstate {
                verb: "mutate".to_string()
            })
        );
    }

    // CO-6: a verb on a closed handle surfaces EstateNotOpen (the parity of
    // estate(for:) propagating out of a verb).
    #[test]
    fn co6_verb_on_closed_handle_is_estate_not_open() {
        let (mut coord, h) = open_one();
        coord.close(&h).expect("close");
        let err = coord.capture(&h, cap_frame("delta"), NOW).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
    }

    // -----------------------------------------------------------------
    // recall_tunnels — coordinator-level read over the association graph.
    // Mirrors Swift `RecallTunnelsTests` case-for-case.
    // -----------------------------------------------------------------

    fn tunnel_frame(
        source: &str,
        target: &str,
        label: &str,
    ) -> locus_kit::frames::TunnelCaptureFrame {
        locus_kit::frames::TunnelCaptureFrame::new(source, "r1", target, "r2", label, "bilby")
    }

    // CO-7: tunnels captured into the estate are returned by the wing's read
    // through the coordinator surface.
    #[test]
    fn co7_recall_tunnels_returns_outgoing() {
        let (coord, h) = open_one();
        let estate = coord.estate_for(&h).expect("estate");
        estate
            .capture_tunnel(tunnel_frame("study", "kitchen", "links"), NOW)
            .unwrap();
        estate
            .capture_tunnel(tunnel_frame("study", "garden", "relates"), NOW + 1)
            .unwrap();

        let tunnels = coord.recall_tunnels(&h, "study").expect("recall_tunnels");
        assert_eq!(tunnels.len(), 2);
        let targets: std::collections::BTreeSet<&str> =
            tunnels.iter().map(|t| t.target_wing.as_str()).collect();
        assert_eq!(targets, ["garden", "kitchen"].into_iter().collect());
        assert!(tunnels.iter().all(|t| t.source_wing == "study"));
    }

    // CO-8: a wing with no outgoing tunnels reads empty (never errors).
    #[test]
    fn co8_recall_tunnels_empty_for_unlinked_wing() {
        let (coord, h) = open_one();
        let estate = coord.estate_for(&h).expect("estate");
        estate
            .capture_tunnel(tunnel_frame("study", "kitchen", "links"), NOW)
            .unwrap();

        let tunnels = coord.recall_tunnels(&h, "attic").expect("recall_tunnels");
        assert!(tunnels.is_empty());
    }

    // CO-9: a verb on a closed handle surfaces EstateNotOpen, not an empty
    // result — parity of the Swift stale-handle case.
    #[test]
    fn co9_recall_tunnels_on_closed_handle_is_estate_not_open() {
        let (mut coord, h) = open_one();
        coord.close(&h).expect("close");
        let err = coord.recall_tunnels(&h, "study").unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
    }

    // -----------------------------------------------------------------
    // v2b-p2 stub verb methods — learn and non-drawer recall.
    // Each method validates the handle first (stale handle → EstateNotOpen)
    // then returns NotSupportedByEstate so the MCP surface advertises the
    // tool honestly without pretending it works.
    // -----------------------------------------------------------------

    // CO-10: learn raises NotSupportedByEstate — the Brain layer has not
    // shipped, parity of Swift GLK.learn raising the same.
    #[test]
    fn co10_learn_raises_not_supported() {
        let (coord, h) = open_one();
        let err = coord.learn(&h, "some-handle").unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::NotSupportedByEstate {
                verb: "learn".to_string()
            })
        );
    }

    // CO-11: recall_kg_facts raises NotSupportedByEstate — no all-facts
    // DrawerStore accessor exists yet.
    #[test]
    fn co11_recall_kg_facts_raises_not_supported() {
        let (coord, h) = open_one();
        let err = coord.recall_kg_facts(&h).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::NotSupportedByEstate {
                verb: "recall_kg_facts".to_string()
            })
        );
    }

    // CO-12: recall_diary_entries raises NotSupportedByEstate — no
    // all-entries DrawerStore accessor exists yet.
    #[test]
    fn co12_recall_diary_entries_raises_not_supported() {
        let (coord, h) = open_one();
        let err = coord.recall_diary_entries(&h).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::NotSupportedByEstate {
                verb: "recall_diary_entries".to_string()
            })
        );
    }

    // CO-13: recall_proposals raises NotSupportedByEstate — no all-proposals
    // DrawerStore accessor exists yet.
    #[test]
    fn co13_recall_proposals_raises_not_supported() {
        let (coord, h) = open_one();
        let err = coord.recall_proposals(&h).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::NotSupportedByEstate {
                verb: "recall_proposals".to_string()
            })
        );
    }

    // CO-14: recall_associations raises NotSupportedByEstate — no
    // all-associations DrawerStore accessor exists yet.
    #[test]
    fn co14_recall_associations_raises_not_supported() {
        let (coord, h) = open_one();
        let err = coord.recall_associations(&h).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::NotSupportedByEstate {
                verb: "recall_associations".to_string()
            })
        );
    }

    // CO-15: recall_learned_references raises NotSupportedByEstate — no
    // all-references DrawerStore accessor exists yet.
    #[test]
    fn co15_recall_learned_references_raises_not_supported() {
        let (coord, h) = open_one();
        let err = coord.recall_learned_references(&h).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::NotSupportedByEstate {
                verb: "recall_learned_references".to_string()
            })
        );
    }

    // CO-16: stub verbs on a closed handle raise EstateNotOpen, not
    // NotSupportedByEstate — handle validation runs first.
    #[test]
    fn co16_stubs_on_closed_handle_raise_estate_not_open() {
        let (mut coord, h) = open_one();
        coord.close(&h).expect("close");

        assert_eq!(
            coord.learn(&h, "h").unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
        assert_eq!(
            coord.recall_kg_facts(&h).unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
        assert_eq!(
            coord.recall_diary_entries(&h).unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
        assert_eq!(
            coord.recall_proposals(&h).unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
        assert_eq!(
            coord.recall_associations(&h).unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
        assert_eq!(
            coord.recall_learned_references(&h).unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
    }
}
