//! COW (copy-on-write) branch surface — the Rust parity of the Swift
//! `GeniusLocusKit/Branches/*` + the `glkDeriveBranch` / `glkPromoteBranch`
//! / `glkMergeDrawers` / `branchHandle(for:)` verbs in `VerbSurface.swift`.
//!
//! Following the Swift model exactly: branches are minted by verbs ON THE
//! kit (`impl EstateCoordinator` below) and retained in the coordinator's
//! `branches` registry through every lifecycle state (I-15 — the audit trail
//! must stay reachable). A branch is a logical copy of a parent estate at
//! derivation time, backed by a fresh in-memory `locus_kit::Estate`. The
//! parent is NEVER modified by derivation or by captures into the branch;
//! rows reach the parent only via an explicit `glk_promote_branch` (all
//! post-derivation rows) or `glk_merge_drawers` (a cherry-picked subset).
//!
//! The clone is behaviour-faithful so BOTH platforms return identical
//! datasets — derive snapshots the same rows, promote/merge move the same
//! rows, compare_to_parent reports the same diff.

use std::collections::BTreeSet;
use std::sync::Arc;

use locus_kit::drawer::Drawer;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::error::LocusKitError;
use locus_kit::estate::Estate;
use locus_kit::estate_types::{EstateError, LatticeAnchor, OwnerCredentials};
use locus_kit::filter::Filter;
use locus_kit::filter::{HydrationLevel, Ordering, RecallFrame};
use locus_kit::frames::CaptureFrame;
use uuid::Uuid;

use crate::coordinator::{EstateCoordinator, VerbDispatchError};
use crate::handle::EstateHandle;
use crate::intake::WriteMode;

/// Unique identifier for a COW branch, minted at derivation. Mirrors the
/// Swift `BranchID = UUID`.
pub type BranchId = Uuid;

/// Lifecycle state of a COW branch. Valid transitions:
/// `Active -> Won | Merged | Discarded`. Terminal states preserve the
/// branch estate's rows for audit access (I-15).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BranchStatus {
    Active,
    Won,
    Merged,
    Discarded,
}

/// Advisory scoring metadata for a branch (Brain-layer ranking input);
/// parity with the Swift `BranchScore`. The substrate does not derive these.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BranchScore {
    pub quality: f64,
    pub new_drawer_count: usize,
}

/// How a branch differs from its parent since derivation. `modified_in_branch`
/// is always empty (content-hash comparison ships later), matching Swift.
#[derive(Debug, Clone, PartialEq)]
pub struct DifferentialReport {
    pub new_in_branch: Vec<String>,
    pub modified_in_branch: Vec<String>,
    pub withdrawn_in_branch: Vec<String>,
}

/// Outcome of a selective `glk_merge_drawers`. `conflicts` is reserved
/// (always empty), matching Swift.
#[derive(Debug, Clone, PartialEq)]
pub struct MergeReport {
    pub merged: Vec<String>,
    pub conflicts: Vec<String>,
    pub skipped: Vec<String>,
}

/// Errors a branch verb can surface. The estate-level cases (`Estate`,
/// `Locus`) arise while building/promoting; the kit-level cases mirror the
/// Swift `GeniusLocusKitError.branchNotTracked` and the E-2 promotion-target
/// guard.
#[derive(Debug)]
pub enum BranchError {
    Estate(EstateError),
    Locus(LocusKitError),
    /// The addressed estate was not open (parity of `estate(for:)`).
    EstateNotOpen,
    /// The branch was not minted by this coordinator (parity of
    /// `GeniusLocusKitError.branchNotTracked`).
    NotTracked {
        branch_id: BranchId,
    },
    /// The promotion/merge target is not the branch's parent estate (E-2).
    PromotionTargetMismatch {
        branch_id: BranchId,
    },
    /// A verb-dispatch failure from `capture_with_mode` during promote/merge.
    /// Wraps `VerbDispatchError` so the coordinator's GLK-level capture
    /// path (encode queue, Corpus feed) can be used instead of the bare
    /// `Estate::capture` bypass (Finding #9 fix).
    VerbDispatch(VerbDispatchError),
    /// A promote/merge call addressed a branch that is no longer `Active`
    /// (already won, merged, or discarded). Terminal branches are read-only
    /// history: promoting a discarded branch would resurrect content a
    /// prior decision rejected — the migration benchmark relies on this to
    /// keep disqualified branches unpromotable across the stateless MCP
    /// boundary (C-5). Parity of `GeniusLocusKitError.branchNotActive`.
    NotActive {
        branch_id: BranchId,
        status: BranchStatus,
    },
}

impl From<EstateError> for BranchError {
    fn from(e: EstateError) -> Self {
        BranchError::Estate(e)
    }
}
impl From<LocusKitError> for BranchError {
    fn from(e: LocusKitError) -> Self {
        BranchError::Locus(e)
    }
}
impl From<VerbDispatchError> for BranchError {
    fn from(e: VerbDispatchError) -> Self {
        BranchError::VerbDispatch(e)
    }
}

/// A read-write COW branch backed by a fresh in-memory estate. Minted and
/// retained by `EstateCoordinator`; mirrors the Swift `EstateBranch`.
pub struct EstateBranch {
    pub branch_id: BranchId,
    pub name: String,
    pub lineage_depth: usize,
    /// The branch's own estate — captures land here only.
    branch_estate: Estate,
    /// The parent estate (Arc-shares the parent's store). `promote` /
    /// `merge_drawers` write here; nothing else does (I-15).
    parent_estate: Estate,
    /// Branch-estate IDs copied from the parent at derivation. Any branch ID
    /// not in this set was captured after derivation ("new in branch").
    snapshot_ids: BTreeSet<String>,
    status: BranchStatus,
}

impl EstateBranch {
    /// Recall every unconfirmed row from an estate at `.structured` hydration,
    /// draining all pages. Used by the ID-only scans (`recall`,
    /// `compare_to_parent`) where the content body is not needed — `.structured`
    /// returns `content = ""` per spec § 7.3, which is correct for ID diffing.
    fn recall_all(estate: &Estate, now: i64) -> Vec<Drawer> {
        let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
        frame.hydration_level = HydrationLevel::Structured;
        frame.ordering = Ordering::ByCaptureTimeDesc;
        estate.recall(frame, now).collect_all()
    }

    /// Recall every unconfirmed row from an estate at `.full` hydration. Used by
    /// `promote` / `merge_drawers`, which immediately re-capture each row's
    /// content into the parent estate via `Estate::capture` (which rejects empty
    /// content). `.structured` would return `content = ""` and fail the capture
    /// guard for every row — mirrors the Swift `glkPromoteBranch` /
    /// `glkMergeDrawers` `.full` recall frame.
    fn recall_all_full(estate: &Estate, now: i64) -> Vec<Drawer> {
        let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
        frame.hydration_level = HydrationLevel::Full;
        frame.ordering = Ordering::ByCaptureTimeDesc;
        estate.recall(frame, now).collect_all()
    }

    /// Rebuild a `CaptureFrame` from a stored row, preserving all
    /// security-relevant, placement-relevant, and lifecycle-relevant fields:
    /// content, capture channel, room, wing (ADR-016 grant/federation
    /// boundary), lattice anchor, author, embedding model, adjective
    /// sensitivity, content kind, the full provenance bitmap
    /// (source_type, channel, provenance_sensitivity, confirmation,
    /// confidence), event_time, feature_flags, and exportability.
    ///
    /// `wing_name` is the resolved display name of the drawer's grandparent
    /// wing node (None → CaptureFrame falls through to the default wing
    /// "Agentic Memory", preserving existing behaviour for default-wing rows
    /// where the node-tree walk can't resolve the wing).
    /// `room_name` is the resolved display name of the drawer's parent
    /// room node — Drawer no longer stores wing/room strings directly
    /// (ADR-017 node tree migration). Callers resolve both from the
    /// source estate's NodeStore via `resolve_node_names`.
    ///
    /// `lineageID` is intentionally NOT preserved — branch promotion is
    /// copy semantics, not move semantics; a new lineage prevents
    /// unintended supersession cascades across estate boundaries.
    fn capture_frame_from(row: &Drawer, wing_name: Option<&str>, room_name: &str) -> CaptureFrame {
        let mut frame = CaptureFrame::new(
            row.content.clone(),
            row.capture_channel(),
            room_name,
            LatticeAnchor::new(
                row.udc_code.clone(),
                row.udc_facets.clone(),
                row.wikidata_qid.clone(),
                row.wikidata_qids_secondary.clone(),
            ),
            row.added_by.clone(),
            row.embedding_model_id.clone(),
        );
        // Operational: sensitivity, kind already decoded from operational/adjective bitmaps.
        frame.sensitivity = row.adjective_sensitivity();
        frame.kind = row.content_kind();
        // Provenance bitmap axes — preserve original capture context so a
        // promoted/merged/derived row reflects who captured it and how,
        // not the branch-promotion agent's identity.
        frame.source_type = row.source_type();
        frame.provenance_channel = row.channel();
        frame.provenance_sensitivity = row.sensitivity();
        frame.confirmation = row.confirmation();
        frame.confidence = row.confidence();
        // Temporal: preserve original event_time so temporal recall accuracy
        // is not reset to branch-promotion time for historical ingests.
        // event_time is epoch seconds in both Drawer and CaptureFrame.
        frame.event_time = Some(row.event_time);
        // Feature flags: isKeystone, isLockedZone, hasLinks etc. affect
        // wing boundary enforcement — must survive branch round-trips.
        frame.feature_flags = row.feature_flags();
        // Exportability: born-public drawers must remain public after
        // branch promotion; born-private must remain private.
        frame.exportability = row.exportability();
        // Wing (ADR-016): the grant/federation boundary. None falls through
        // to DEFAULT_WING_NAME in estate_verbs so existing default-wing rows
        // are unaffected; non-default-wing rows land in the correct wing.
        frame.wing = wing_name.map(|w| w.to_owned());
        frame
    }

    /// Resolve a drawer's wing and room display names from its parent_node_id
    /// via a NodeStore reference. Falls back to (None, "") when the store is
    /// absent or lookup fails (non-fatal). wing = None means the node tree
    /// could not be walked — CaptureFrame will fall through to defaultWing().
    ///
    /// Node topology (ADR-017): root → wing (depth 1) → room (depth 2) →
    /// drawers. room_node.parent_id → wing_node.display_name.
    ///
    /// The NodeStore comes from the coordinator's `node_stores` registry —
    /// `estate.node_store` is `pub(crate)` in LocusKit and not accessible
    /// from this crate.
    fn resolve_node_names(
        ns: Option<&Arc<locus_kit::node_store::NodeStore>>,
        drawer: &Drawer,
    ) -> (Option<String>, String) {
        let ns = match ns {
            Some(ns) => ns,
            None => return (None, String::new()),
        };
        let room_uuid = match Uuid::parse_str(&drawer.parent_node_id) {
            Ok(u) => u,
            Err(_) => return (None, String::new()),
        };
        let room_node = match ns.get_node(room_uuid) {
            Ok(Some(n)) => n,
            _ => return (None, String::new()),
        };
        let room_name = room_node.display_name.clone();
        // Walk one level up: room_node.parent_id is the wing node's UUID.
        let wing_name = room_node
            .parent_id
            .and_then(|wing_uuid| ns.get_node(wing_uuid).ok().flatten())
            .map(|wing_node| wing_node.display_name);
        (wing_name, room_name)
    }

    /// Build a fresh, isolated in-memory branch estate (owner encodes the
    /// branch id, matching the Swift `branch-<uuid>`).  InMemoryDrawerStore
    /// allocates its own InMemoryStorage; backend identity is at the type.
    fn new_branch_estate(branch_id: BranchId, now: i64) -> Result<Estate, BranchError> {
        let store = Arc::new(InMemoryDrawerStore::new(now, None)?);
        let owner = OwnerCredentials::new(format!("branch-{branch_id}"));
        Ok(Estate::create(store, owner, None)?)
    }

    /// Copy `snapshot_rows` into a new branch estate, recording the minted
    /// branch-estate IDs as the derivation snapshot. Shared by both derive
    /// entry points. `pub(crate)` — branches are minted through the
    /// coordinator's verbs, mirroring the Swift `glkDeriveBranch`.
    pub(crate) fn build(
        name: String,
        parent_estate: Estate,
        snapshot_rows: &[Drawer],
        lineage_depth: usize,
        now: i64,
        node_store: Option<&Arc<locus_kit::node_store::NodeStore>>,
    ) -> Result<Self, BranchError> {
        let branch_id = Uuid::new_v4();
        let branch_estate = Self::new_branch_estate(branch_id, now)?;
        let mut snapshot_ids = BTreeSet::new();
        for row in snapshot_rows {
            let (wing, room) = Self::resolve_node_names(node_store, row);
            let stored = branch_estate.capture(
                Self::capture_frame_from(row, wing.as_deref(), &room),
                now,
            )?;
            snapshot_ids.insert(stored.id);
        }
        Ok(EstateBranch {
            branch_id,
            name,
            lineage_depth,
            branch_estate,
            parent_estate,
            snapshot_ids,
            status: BranchStatus::Active,
        })
    }

    /// Current lifecycle status.
    pub fn status(&self) -> BranchStatus {
        self.status
    }

    /// The parent estate's UUID — used by the coordinator's E-2 guard to
    /// confirm a promotion/merge targets the branch's actual parent.
    pub(crate) fn parent_estate_uuid(&self) -> Uuid {
        self.parent_estate.estate_uuid()
    }

    /// The branch estate (read-only) — the coordinator reads it to derive a
    /// child branch (branch-of-branch).
    pub(crate) fn branch_estate(&self) -> &Estate {
        &self.branch_estate
    }

    /// Capture a new drawer into this branch estate only. The parent is
    /// untouched (I-15).
    pub fn capture(&self, frame: CaptureFrame, now: i64) -> Result<Drawer, BranchError> {
        Ok(self.branch_estate.capture(frame, now)?)
    }

    /// Recall all rows from this branch estate.
    pub fn recall(&self, now: i64) -> Vec<Drawer> {
        Self::recall_all(&self.branch_estate, now)
    }

    /// Recall from this branch estate with a caller-supplied frame — the
    /// per-query read path the migration benchmark uses (read-only; the
    /// parent is never touched).
    pub fn recall_with(&self, frame: RecallFrame, now: i64) -> Vec<Drawer> {
        self.branch_estate.recall(frame, now).collect_all()
    }

    /// Transition the branch to `Discarded`. Rows are retained for audit;
    /// `recall` still works afterwards.
    pub(crate) fn set_discarded(&mut self) {
        self.status = BranchStatus::Discarded;
    }

    /// Compare the current branch state to the derivation snapshot.
    pub fn compare_to_parent(&self, now: i64) -> DifferentialReport {
        let current_ids: BTreeSet<String> = self.recall(now).into_iter().map(|d| d.id).collect();
        let new_in_branch: Vec<String> = current_ids
            .difference(&self.snapshot_ids)
            .cloned()
            .collect();
        let withdrawn_in_branch: Vec<String> = self
            .snapshot_ids
            .difference(&current_ids)
            .cloned()
            .collect();
        DifferentialReport {
            new_in_branch,
            modified_in_branch: Vec::new(),
            withdrawn_in_branch,
        }
    }

    /// Cherry-pick branch rows into the parent by branch-estate ID; transition
    /// to `Merged`. Driven by the coordinator's `glk_merge_drawers`.
    pub(crate) fn merge_drawers(
        &mut self,
        drawer_ids: &[String],
        now: i64,
    ) -> Result<MergeReport, BranchError> {
        // `.full` recall: each cherry-picked row is re-captured into the parent
        // estate (which requires non-empty content). Mirrors the Swift
        // glkMergeDrawers `.full` frame.
        let rows = Self::recall_all_full(&self.branch_estate, now);
        let mut merged = Vec::new();
        let mut skipped = Vec::new();
        for id in drawer_ids {
            match rows.iter().find(|r| &r.id == id) {
                Some(row) => {
                    // Wing integrity (ADR-016): resolve both wing and room so
                    // non-default-wing rows land in the correct wing rather than
                    // silently falling back to defaultWing() on merge.
                    let (wing, room) = Self::resolve_node_names(
                        self.branch_estate.node_store(), row,
                    );
                    self.parent_estate.capture(
                        Self::capture_frame_from(row, wing.as_deref(), &room),
                        now,
                    )?;
                    merged.push(id.clone());
                }
                None => skipped.push(id.clone()),
            }
        }
        self.status = BranchStatus::Merged;
        Ok(MergeReport {
            merged,
            conflicts: Vec::new(),
            skipped,
        })
    }
}

// MARK: - Branch verbs on the kit (parity of VerbSurface.swift branch verbs)

impl EstateCoordinator {
    /// Derive a COW branch from the estate addressed by `handle` (lineage
    /// depth 1). Snapshots all current parent rows into a fresh branch estate
    /// and retains the branch in the registry. Parity of
    /// `glkDeriveBranch(name:from:)`. Returns the new branch's id.
    pub fn glk_derive_branch(
        &mut self,
        name: impl Into<String>,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<BranchId, BranchError> {
        let parent = self
            .estate_for(handle)
            .map_err(|_| BranchError::EstateNotOpen)?;
        // `.full` snapshot: the rows are re-captured into the branch estate
        // (which requires non-empty content). Mirrors the Swift derive
        // `recallRows` `.full` frame.
        let snapshot_rows = EstateBranch::recall_all_full(parent, now);
        let branch = EstateBranch::build(name.into(), parent.clone(), &snapshot_rows, 1, now, parent.node_store())?;
        let id = branch.branch_id;
        self.branches.insert(id, branch);
        Ok(id)
    }

    /// Derive a child branch from an existing tracked branch (lineage depth
    /// + 1). Parity of `glkDeriveBranch(name:fromBranch:)`.
    pub fn glk_derive_branch_from_branch(
        &mut self,
        name: impl Into<String>,
        parent_branch_id: BranchId,
        now: i64,
    ) -> Result<BranchId, BranchError> {
        let parent_branch =
            self.branches
                .get(&parent_branch_id)
                .ok_or(BranchError::NotTracked {
                    branch_id: parent_branch_id,
                })?;
        // `.full` snapshot: re-captured into the child branch estate (requires
        // non-empty content). Mirrors the Swift derive-from-branch `.full` frame.
        let snapshot_rows = EstateBranch::recall_all_full(parent_branch.branch_estate(), now);
        let parent_estate = parent_branch.branch_estate().clone();
        let depth = parent_branch.lineage_depth + 1;
        let ns = parent_estate.node_store().cloned();
        let branch = EstateBranch::build(name.into(), parent_estate, &snapshot_rows, depth, now, ns.as_ref())?;
        let id = branch.branch_id;
        self.branches.insert(id, branch);
        Ok(id)
    }

    /// Promote a tracked branch into the estate addressed by `handle`,
    /// re-capturing every post-derivation row into the parent and
    /// transitioning the branch to `Won`. Parity of `glkPromoteBranch`.
    /// Guards: branch must be tracked; `handle` must address the branch's
    /// parent estate (E-2).
    ///
    /// Capture routes through `capture_with_mode(Regular)` so promoted rows
    /// are enqueued for BM25/vector encoding (Finding #9 fix). The old path
    /// called `EstateBranch::promote` which used bare `Estate::capture`,
    /// bypassing the coordinator's encode queue and leaving promoted memories
    /// dark for semantic search. Mirrors Swift `glkPromoteBranch`'s
    /// `capture(handle, captureFrame, mode: .regular)` call.
    pub fn glk_promote_branch(
        &mut self,
        branch_id: BranchId,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<usize, BranchError> {
        let target_uuid = self
            .estate_for(handle)
            .map_err(|_| BranchError::EstateNotOpen)?
            .estate_uuid();

        // Phase 1 — extract the post-derivation rows (and their resolved room
        // names) with an immutable borrow of the branch so we can release it
        // before calling capture_with_mode. The borrow conflict:
        // `branches.get_mut()` mutably borrows `self`,
        // which prevents also calling `&mut self.capture_with_mode`. Collecting
        // the rows first lets us drop the branch reference before the capture loop.
        let new_rows: Vec<_> = {
            let branch = self
                .branches
                .get(&branch_id)
                .ok_or(BranchError::NotTracked { branch_id })?;
            // Lifecycle guard: the Swift doc contract ("Must be in `.active`
            // status") was previously unenforced on either leg, which let a
            // DISCARDED branch — e.g. one the migration benchmark
            // disqualified for silent concept loss — be promoted by any
            // caller holding its id (C-5 bypass).
            if branch.status() != BranchStatus::Active {
                return Err(BranchError::NotActive { branch_id, status: branch.status() });
            }
            if branch.parent_estate_uuid() != target_uuid {
                return Err(BranchError::PromotionTargetMismatch { branch_id });
            }
            // `.full` recall: each promoted row is re-captured into the parent
            // estate (which requires non-empty content). Mirrors Swift `.full` frame.
            let rows: Vec<Drawer> = EstateBranch::recall_all_full(&branch.branch_estate, now)
                .into_iter()
                .filter(|row| !branch.snapshot_ids.contains(&row.id))
                .collect();
            // Resolve wing and room names while we still hold the branch
            // estate reference (Drawer no longer stores either — ADR-017).
            // Wing integrity (ADR-016): non-default-wing rows must land in
            // the correct wing after promotion, not silently in defaultWing().
            let resolved: Vec<(Drawer, Option<String>, String)> = rows
                .into_iter()
                .map(|row| {
                    let (wing, room) = EstateBranch::resolve_node_names(
                        branch.branch_estate.node_store(), &row,
                    );
                    (row, wing, room)
                })
                .collect();
            resolved
            // branch reference dropped here — immutable borrow of self.branches ends.
        };

        // Phase 2 — capture each post-derivation row through the coordinator's
        // GLK-level verb so the encode queue (BM25/vector lane) is fed. Parity
        // of Swift `capture(handle, captureFrame, mode: .regular)` in `glkPromoteBranch`.
        for (row, wing, room) in &new_rows {
            self.capture_with_mode(
                handle,
                EstateBranch::capture_frame_from(row, wing.as_deref(), room),
                now,
                WriteMode::Regular,
            )
            .map_err(BranchError::from)?;
        }

        // Phase 3 — transition the branch to Won. This mutably borrows
        // self.branches again, which is safe because Phase 2 holds no branch ref.
        let branch = self
            .branches
            .get_mut(&branch_id)
            .ok_or(BranchError::NotTracked { branch_id })?;
        branch.status = BranchStatus::Won;

        Ok(new_rows.len())
    }

    /// Cherry-pick specific branch rows into the estate addressed by
    /// `handle`, transitioning the branch to `Merged`. Parity of
    /// `glkMergeDrawers`. Same guards as `glk_promote_branch`.
    pub fn glk_merge_drawers(
        &mut self,
        drawer_ids: &[String],
        branch_id: BranchId,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<MergeReport, BranchError> {
        let target_uuid = self
            .estate_for(handle)
            .map_err(|_| BranchError::EstateNotOpen)?
            .estate_uuid();
        let branch = self
            .branches
            .get_mut(&branch_id)
            .ok_or(BranchError::NotTracked { branch_id })?;
        // Lifecycle guard: same invariant as glk_promote_branch — terminal
        // branches (won/merged/discarded) are read-only history and cannot
        // cherry-pick content into the parent.
        if branch.status() != BranchStatus::Active {
            return Err(BranchError::NotActive { branch_id, status: branch.status() });
        }
        if branch.parent_estate_uuid() != target_uuid {
            return Err(BranchError::PromotionTargetMismatch { branch_id });
        }
        branch.merge_drawers(drawer_ids, now)
    }

    /// Discard a tracked branch (status -> `Discarded`); rows retained for
    /// audit. Parity of `BranchHandle.discard()`.
    pub fn glk_discard_branch(&mut self, branch_id: BranchId) -> Result<(), BranchError> {
        let branch = self
            .branches
            .get_mut(&branch_id)
            .ok_or(BranchError::NotTracked { branch_id })?;
        branch.set_discarded();
        Ok(())
    }

    /// Resolve a tracked branch by id to a read-only handle — the stateless
    /// recovery accessor (parity of `branchHandle(for:)`). `None` when no
    /// branch with that id was minted by this coordinator.
    pub fn branch_handle_for(&self, branch_id: BranchId) -> Option<&EstateBranch> {
        self.branches.get(&branch_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;

    const NOW: i64 = 1_700_000_000;

    /// Build a coordinator with one open parent estate seeded with the given
    /// row contents. Returns (coordinator, parent handle).
    fn coord_with_parent(contents: &[&str]) -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let handle = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        for c in contents {
            let frame = CaptureFrame::new(
                *c,
                CaptureChannel::Typed,
                "study",
                LatticeAnchor::udc("0"),
                "alice",
                "test-v1",
            );
            // Capture into the parent via the live verb surface.
            coord.capture(&handle, frame, NOW).unwrap();
        }
        (coord, handle)
    }

    fn branch_capture(coord: &EstateCoordinator, branch_id: BranchId, content: &str) -> String {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("0"),
            "bob",
            "test-v1",
        );
        coord
            .branch_handle_for(branch_id)
            .unwrap()
            .capture(frame, NOW)
            .unwrap()
            .id
    }

    // BR-1: glk_derive_branch snapshots all parent rows; the parent is
    // untouched (I-15).
    #[test]
    fn br1_derive_snapshots_parent() {
        let (mut coord, h) = coord_with_parent(&["alpha", "beta"]);
        let bid = coord.glk_derive_branch("b1", &h, NOW).unwrap();
        let branch = coord.branch_handle_for(bid).unwrap();
        assert_eq!(
            branch.recall(NOW).len(),
            2,
            "branch starts with the 2 parent rows"
        );
        assert_eq!(branch.lineage_depth, 1);
        assert_eq!(branch.status(), BranchStatus::Active);
        // I-15: parent unchanged by derivation.
        assert_eq!(coord.recall(&h, all_frame(), NOW).unwrap().len(), 2);
    }

    fn all_frame() -> RecallFrame {
        // .full hydration: these branch tests recall drawers and re-file their
        // content (promote / merge), so the content body must be loaded — a
        // .structured recall returns content == "" (spec § 7.3 / Swift parity).
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Full;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // BR-2: a branch capture is isolated; compareToParent reports it as
    // new-in-branch; the parent stays untouched (I-15).
    #[test]
    fn br2_branch_capture_isolated_and_diffed() {
        let (mut coord, h) = coord_with_parent(&["alpha"]);
        let bid = coord.glk_derive_branch("b2", &h, NOW).unwrap();
        branch_capture(&coord, bid, "gamma");
        let branch = coord.branch_handle_for(bid).unwrap();
        assert_eq!(branch.recall(NOW).len(), 2);
        let diff = branch.compare_to_parent(NOW);
        assert_eq!(diff.new_in_branch.len(), 1);
        assert!(diff.withdrawn_in_branch.is_empty());
        assert_eq!(
            coord.recall(&h, all_frame(), NOW).unwrap().len(),
            1,
            "I-15: parent untouched"
        );
    }

    // BR-3: promote moves only post-derivation rows into the parent; status
    // -> Won.
    #[test]
    fn br3_promote_moves_new_rows_and_wins() {
        let (mut coord, h) = coord_with_parent(&["alpha"]);
        let bid = coord.glk_derive_branch("b3", &h, NOW).unwrap();
        branch_capture(&coord, bid, "gamma");
        branch_capture(&coord, bid, "delta");
        let promoted = coord.glk_promote_branch(bid, &h, NOW).unwrap();
        assert_eq!(promoted, 2);
        assert_eq!(
            coord.branch_handle_for(bid).unwrap().status(),
            BranchStatus::Won
        );
        assert_eq!(
            coord.recall(&h, all_frame(), NOW).unwrap().len(),
            3,
            "parent + 2 promoted"
        );
    }

    // BR-4: merge cherry-picks by id; unknown ids skipped; status -> Merged.
    #[test]
    fn br4_merge_cherry_picks() {
        let (mut coord, h) = coord_with_parent(&["alpha"]);
        let bid = coord.glk_derive_branch("b4", &h, NOW).unwrap();
        let g = branch_capture(&coord, bid, "gamma");
        branch_capture(&coord, bid, "delta");
        let report = coord
            .glk_merge_drawers(&[g.clone(), "no-such-id".to_string()], bid, &h, NOW)
            .unwrap();
        assert_eq!(report.merged, vec![g]);
        assert_eq!(report.skipped, vec!["no-such-id".to_string()]);
        assert_eq!(
            coord.branch_handle_for(bid).unwrap().status(),
            BranchStatus::Merged
        );
        assert_eq!(
            coord.recall(&h, all_frame(), NOW).unwrap().len(),
            2,
            "parent + 1 merged"
        );
    }

    // BR-5: branch-of-branch increments lineage depth and snapshots the
    // parent branch's current rows.
    #[test]
    fn br5_branch_of_branch_lineage_depth() {
        let (mut coord, h) = coord_with_parent(&["alpha"]);
        let b1 = coord.glk_derive_branch("b1", &h, NOW).unwrap();
        branch_capture(&coord, b1, "gamma");
        let b2 = coord.glk_derive_branch_from_branch("b2", b1, NOW).unwrap();
        let child = coord.branch_handle_for(b2).unwrap();
        assert_eq!(child.lineage_depth, 2);
        assert_eq!(
            child.recall(NOW).len(),
            2,
            "child snapshots parent branch's 2 rows"
        );
    }

    // BR-6: discard retains rows; parent untouched. And an untracked branch
    // id is rejected (parity of branchNotTracked).
    #[test]
    fn br6_discard_and_not_tracked_guard() {
        let (mut coord, h) = coord_with_parent(&["alpha"]);
        let bid = coord.glk_derive_branch("b6", &h, NOW).unwrap();
        branch_capture(&coord, bid, "gamma");
        coord.glk_discard_branch(bid).unwrap();
        assert_eq!(
            coord.branch_handle_for(bid).unwrap().status(),
            BranchStatus::Discarded
        );
        assert_eq!(
            coord.branch_handle_for(bid).unwrap().recall(NOW).len(),
            2,
            "rows retained"
        );
        assert_eq!(
            coord.recall(&h, all_frame(), NOW).unwrap().len(),
            1,
            "I-15: parent untouched"
        );

        let bogus = Uuid::new_v4();
        match coord.glk_promote_branch(bogus, &h, NOW) {
            Err(BranchError::NotTracked { branch_id }) => assert_eq!(branch_id, bogus),
            other => panic!("expected NotTracked, got {other:?}"),
        }
    }

    // BR-8 (Finding #9 fix): promoted rows are enqueued for BM25/vector
    // encoding via `capture_with_mode(Regular)`, not bypassing the encode
    // queue via bare `Estate::capture`. After `await_encode_drain`, the
    // promoted memory is BM25-searchable through the coordinator's hybrid
    // recall path. Pre-fix: `glk_promote_branch` called `EstateBranch::promote`
    // which wrote directly to `parent_estate.capture`, leaving promoted rows
    // dark for semantic search.
    #[test]
    fn br8_promoted_rows_are_semantically_searchable_after_drain() {
        use crate::coordinator::{EstateKind, EstateProvisionParams, SyncMode};
        use crate::recall::{
            GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallEvidencePath,
            RecallFallbackPolicy,
        };
        use corpus_kit::corpus::EmbeddingModelConfig;
        use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
        use locus_kit::estate_types::LatticeAnchor;
        use locus_kit::filter::{Filter, RecallFrame};
        use persistence_kit::inmemory::InMemoryStorage;
        use std::sync::Arc;

        const T: i64 = 1_700_000_000_000;

        // Provision a GLK estate (corpus-backed so BM25 lane is live).
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::with_storage(Arc::clone(&storage), T, None).unwrap(),
        );
        let storage_dyn: Arc<dyn persistence_kit::storage::Storage> = storage;
        let mut coord = EstateCoordinator::new();
        let params = EstateProvisionParams {
            estate_name: "br8-branch-encode-test".to_string(),
            kind: EstateKind::Glk,
            zoom_window_low: 1,
            zoom_window_high: 10,
            framework_profile: "KnowledgeWork".to_string(),
            sync_mode: SyncMode::None,
        };
        let handle = coord
            .provision(
                store,
                storage_dyn,
                None,
                OwnerCredentials::new("owner-br8"),
                params,
                vec![EmbeddingModelConfig::Deterministic],
            )
            .expect("provision GLK estate for br8");

        // Seed one row into the parent, derive a branch, add a new row
        // into the branch only (the post-derivation "new" row).
        let seed_frame = CaptureFrame::new(
            "seed row — present at derivation, not promoted",
            CaptureChannel::Typed,
            "lab",
            LatticeAnchor::udc("000"),
            "br8-agent",
            "test-model-v1",
        );
        coord
            .capture_with_mode(&handle, seed_frame, T, WriteMode::Regular)
            .expect("seed capture");
        coord.await_encode_drain(&handle).expect("seed drain");

        let bid = coord
            .glk_derive_branch("br8-branch", &handle, T)
            .expect("derive branch");

        // Capture a distinctive phrase into the branch (post-derivation row).
        let branch_frame = CaptureFrame::new(
            "tangerine-unique-phrase-for-promote-encode-test",
            CaptureChannel::Typed,
            "lab",
            LatticeAnchor::udc("000"),
            "br8-agent",
            "test-model-v1",
        );
        coord
            .branch_handle_for(bid)
            .expect("branch exists")
            .capture(branch_frame, T)
            .expect("branch capture");

        // Promote the branch: post-derivation row should route through
        // capture_with_mode(Regular), enqueuing onto the Corpus ingest queue.
        let promoted = coord
            .glk_promote_branch(bid, &handle, T)
            .expect("promote branch");
        assert_eq!(promoted, 1, "exactly one post-derivation row promoted");

        // Drain the encode queue so the promoted row is indexed in BM25.
        coord
            .await_encode_drain(&handle)
            .expect("encode drain after promote");

        // Verify the promoted row is reachable via the BM25 (corpus) lane —
        // the lane that was dark before Finding #9 was fixed.
        let recall_req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
            .with_mode(GLKRecallMode::Hybrid)
            .with_scoring(GLKRecallScoring::Raw)
            .with_limit(10)
            .with_fallback(RecallFallbackPolicy::FailClosed)
            .with_query_text("tangerine-unique-phrase-for-promote-encode-test".to_string());

        let results = coord
            .recall_scored(&handle, recall_req, T)
            .expect("hybrid recall after promote");

        let found = results.hits.iter().any(|hit| {
            hit.sources.contains(&RecallEvidencePath::CorpusBm25)
        });
        assert!(
            found,
            "promoted row must be reachable via CorpusBm25 lane after drain; got {} hits",
            results.hits.len()
        );
    }

    // -----------------------------------------------------------------------
    // Wing integrity (ADR-016) — Finding A: branch re-capture preserves wing
    //
    // Before this fix `capture_frame_from` built a CaptureFrame without the
    // `wing` field, silently re-filing every derived/promoted/merged row into
    // DEFAULT_WING_NAME regardless of its original wing. These tests verify
    // the fix across all three branch paths.
    // -----------------------------------------------------------------------

    /// Helper: open a fresh coordinator + estate, capture a wing-tagged row,
    /// return (coordinator, handle). The coordinator carries the InMemory
    /// node_store so resolveNodeNames can walk wing→room.
    fn coord_with_wing_row(wing: &str, room: &str, content: &str) -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let handle = coord
            .open(store, OwnerCredentials::new("wing-integrity-owner"), 0, 100)
            .unwrap();
        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc("000"),
            "wing-integrity-agent",
            "test-model-v1",
        );
        frame.wing = Some(wing.to_owned());
        coord.capture(&handle, frame, NOW).unwrap();
        (coord, handle)
    }

    /// Recall all rows in an estate whose wing matches `wing_name`.
    fn recall_in_wing(
        coord: &EstateCoordinator,
        handle: &EstateHandle,
        wing_name: &str,
    ) -> Vec<locus_kit::drawer::Drawer> {
        let mut frame = RecallFrame::new(vec![Filter::Unconfirmed, Filter::InWing(wing_name.to_owned())]);
        frame.hydration_level = HydrationLevel::Full;
        coord.recall(handle, frame, NOW).unwrap()
    }

    // BR-WI-1: derive preserves wing (Finding A — derivation path).
    //
    // A row captured into the parent in "User Canon" must appear in the
    // branch's "User Canon" wing after glk_derive_branch.
    #[test]
    fn br_wi1_derive_preserves_wing() {
        let (mut coord, handle) = coord_with_wing_row("User Canon", "study", "wing-tagged-derive");

        let bid = coord.glk_derive_branch("wing-derive-branch", &handle, NOW).unwrap();
        let branch = coord.branch_handle_for(bid).unwrap();

        // Recall from branch using InWing filter: the row must appear.
        let mut frame = RecallFrame::new(vec![
            Filter::Unconfirmed,
            Filter::InWing("User Canon".to_owned()),
        ]);
        frame.hydration_level = HydrationLevel::Full;
        let wing_rows: Vec<_> = branch
            .recall_with(frame, NOW)
            .into_iter()
            .filter(|r| r.content == "wing-tagged-derive")
            .collect();
        assert_eq!(
            wing_rows.len(),
            1,
            "derived branch row must be in 'User Canon' wing — wing was dropped before this fix"
        );
    }

    // BR-WI-2: promote preserves wing (Finding A — promotion path).
    //
    // A row captured directly into the branch (post-derivation) in "User Canon"
    // must land in "User Canon" in the parent estate after glk_promote_branch.
    #[test]
    fn br_wi2_promote_preserves_wing() {
        let (mut coord, handle) = coord_with_wing_row("default-wing", "study", "seed");

        let bid = coord.glk_derive_branch("wing-promote-branch", &handle, NOW).unwrap();

        // Capture a wing-tagged row into the branch (post-derivation → new row).
        let mut frame = CaptureFrame::new(
            "branch-wing-tagged-promote",
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("000"),
            "agent",
            "test-v1",
        );
        frame.wing = Some("User Canon".to_owned());
        coord
            .branch_handle_for(bid)
            .unwrap()
            .capture(frame, NOW)
            .unwrap();

        // Promote: the wing-tagged row should land in "User Canon" in the parent.
        coord.glk_promote_branch(bid, &handle, NOW).unwrap();

        let parent_wing_rows = recall_in_wing(&coord, &handle, "User Canon");
        assert!(
            parent_wing_rows.iter().any(|r| r.content == "branch-wing-tagged-promote"),
            "promoted branch row must land in 'User Canon' wing — wing was dropped before this fix"
        );
    }

    // BR-WI-3: derive preserves exportability (Finding A — field audit).
    //
    // A born-public row must remain public after derivation. Silently
    // re-privatizing it would break recall filters scoped to exportable content.
    #[test]
    fn br_wi3_derive_preserves_exportability() {
        use locus_kit::adjectives::AdjectiveExportability;

        let (mut coord, handle) = {
            let mut c = EstateCoordinator::new();
            let store: Arc<dyn DrawerStore> =
                Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
            let h = c
                .open(store, OwnerCredentials::new("exp-owner"), 0, 100)
                .unwrap();
            let mut f = CaptureFrame::new(
                "born-public-content",
                CaptureChannel::Typed,
                "pub-room",
                LatticeAnchor::udc("000"),
                "agent",
                "test-v1",
            );
            f.exportability = AdjectiveExportability::Public;
            c.capture(&h, f, NOW).unwrap();
            (c, h)
        };

        let bid = coord.glk_derive_branch("exportability-branch", &handle, NOW).unwrap();
        let branch = coord.branch_handle_for(bid).unwrap();

        let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
        frame.hydration_level = HydrationLevel::Full;
        let rows = branch.recall_with(frame, NOW);
        let row = rows
            .iter()
            .find(|r| r.content == "born-public-content")
            .expect("must find born-public row in branch");
        assert_eq!(
            row.exportability(),
            AdjectiveExportability::Public,
            "exportability must be preserved on derive — born-public row went private before fix"
        );
    }
}
