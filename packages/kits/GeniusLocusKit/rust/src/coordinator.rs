// coordinator.rs — EstateCoordinator: the estate registry + unified verb
// surface, the Rust parity of the Swift `GeniusLocusKit` actor
// (Sources/GeniusLocusKit/GeniusLocusKit.swift + Verbs/VerbSurface.swift).
//
// This is the downstream mission that wires the real Rust LocusKit estate:
// the registry holds a live `locus_kit::Estate` per open handle, and the
// six core verbs (capture/recall/mutate/withdraw/expunge/reanchor) delegate
// to it exactly as the Swift `extension GeniusLocusKit` verbs delegate to
// `estate(for: handle)`. The clone is behaviour-faithful so BOTH platforms
// return identical datasets — the precondition for the conformance tents
// pitched many levels up the tree.
//
// The Brain-layer verbs (propose/associate/learn) are NOT here: they remain
// `NotSupportedByEstate` on the `verbs::surface::Surface` lexicon surface in
// both languages until the Brain layer ships. The AriaLexicon name-identity
// + boundary-guard parity lives on `Surface`; the live dispatch lives here,
// matching the Swift split between the verb-name vocabulary and the actor's
// verb implementations.

use std::collections::HashMap;
use std::sync::Arc;

use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::error::LocusKitError;
use locus_kit::estate::Estate;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::RecallFrame;
use locus_kit::frames::{CaptureFrame, MutationKind};

use crate::handle::{EstateHandle, EstateUuid};
use crate::verbs::surface::VerbError;

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
            return VerbError::NotSupportedByEstate { verb: verb.to_string() };
        }
    }
    VerbError::UnderlyingEstateFailure { verb: verb.to_string(), reason: format!("{error:?}") }
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
        Self { registry: HashMap::new(), branches: HashMap::new() }
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
        let estate = Estate::open(store, owner)
            .map_err(|e| GeniusLocusKitError::EstateOpenFailed { detail: format!("{e:?}") })?;
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
            return Err(GeniusLocusKitError::EstateNotOpen { estate_uuid: handle.estate_uuid });
        }
        Ok(())
    }

    /// Resolve a handle to its live estate. Parity of the Swift
    /// `estate(for:)`; returns `EstateNotOpen` for a stale or never-issued
    /// handle.
    pub fn estate_for(&self, handle: &EstateHandle) -> Result<&Estate, GeniusLocusKitError> {
        self.registry
            .get(handle)
            .ok_or(GeniusLocusKitError::EstateNotOpen { estate_uuid: handle.estate_uuid })
    }

    // Internal: resolve to an estate, mapping the not-open case into the
    // verb-dispatch error domain (parity of `estate(for:)` propagating
    // `estateNotOpen` out of a verb).
    fn estate_for_verb(&self, handle: &EstateHandle) -> Result<&Estate, VerbDispatchError> {
        self.registry
            .get(handle)
            .ok_or(VerbDispatchError::EstateNotOpen { estate_uuid: handle.estate_uuid })
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
        estate.capture(frame, now).map_err(|e| remap("capture", e).into())
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

    // MARK: - mutate

    /// Apply a named mutation to a drawer. The LocusKit `mutate` is a stub
    /// that returns `InvalidContent("mutate not yet implemented")`, which
    /// `remap` turns into `NotSupportedByEstate { verb: "mutate" }` — parity
    /// of the Swift comment and behaviour.
    pub fn mutate(
        &self,
        handle: &EstateHandle,
        row_id: &str,
        kind: MutationKind,
        payload: Option<&str>,
    ) -> Result<(), VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.mutate(row_id, kind, payload).map_err(|e| remap("mutate", e).into())
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
        estate.withdraw(row_id, reason, now).map_err(|e| remap("withdraw", e).into())
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
            return Err(VerbError::ExpungeNotConfirmed { row_id: row_id.to_string() }.into());
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
            return Err(VerbError::EmptyReanchor { row_id: row_id.to_string() }.into());
        }
        let estate = self.estate_for_verb(handle)?;
        estate
            .reanchor(row_id, to_room, to_lattice)
            .map_err(|e| remap("reanchor", e).into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;

    fn open_one() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
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
        coord.withdraw(&h, &stored.id, Some("obsolete"), NOW).expect("withdraw");
        // The row is no longer in the unconfirmed set after withdrawal.
        let rows = coord.recall(&h, unconfirmed(), NOW).expect("recall");
        assert!(rows.iter().all(|r| r.id != stored.id), "withdrawn row left the set");
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
            VerbDispatchError::Verb(VerbError::EmptyReanchor { row_id: "row-1".to_string() })
        );
    }

    // CO-5: mutate hits the LocusKit stub and is remapped to
    // NotSupportedByEstate — parity of the Swift remap behaviour.
    #[test]
    fn co5_mutate_is_not_supported_yet() {
        let (coord, h) = open_one();
        let err = coord.mutate(&h, "row-1", MutationKind::Confirm, None).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::NotSupportedByEstate { verb: "mutate".to_string() })
        );
    }

    // CO-6: a verb on a closed handle surfaces EstateNotOpen (the parity of
    // estate(for:) propagating out of a verb).
    #[test]
    fn co6_verb_on_closed_handle_is_estate_not_open() {
        let (mut coord, h) = open_one();
        coord.close(&h).expect("close");
        let err = coord.capture(&h, cap_frame("delta"), NOW).unwrap_err();
        assert_eq!(err, VerbDispatchError::EstateNotOpen { estate_uuid: h.estate_uuid });
    }
}
