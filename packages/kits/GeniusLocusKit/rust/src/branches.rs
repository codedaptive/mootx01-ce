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

use crate::coordinator::EstateCoordinator;
use crate::handle::EstateHandle;

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

    /// Rebuild a `CaptureFrame` from a stored row, preserving content,
    /// capture channel, room, the full lattice anchor, author, embedding
    /// model, adjective sensitivity, and content kind (the fields the Swift
    /// re-capture preserves).
    fn capture_frame_from(row: &Drawer) -> CaptureFrame {
        let mut frame = CaptureFrame::new(
            row.content.clone(),
            row.capture_channel(),
            row.room.clone(),
            LatticeAnchor::new(
                row.udc_code.clone(),
                row.udc_facets.clone(),
                row.wikidata_qid.clone(),
                row.wikidata_qids_secondary.clone(),
            ),
            row.added_by.clone(),
            row.embedding_model_id.clone(),
        );
        frame.sensitivity = row.adjective_sensitivity();
        frame.kind = row.content_kind();
        frame
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
    ) -> Result<Self, BranchError> {
        let branch_id = Uuid::new_v4();
        let branch_estate = Self::new_branch_estate(branch_id, now)?;
        let mut snapshot_ids = BTreeSet::new();
        for row in snapshot_rows {
            let stored = branch_estate.capture(Self::capture_frame_from(row), now)?;
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

    /// Re-capture every post-derivation row into the parent estate and
    /// transition to `Won`. Returns the count promoted. `pub(crate)` — driven
    /// by the coordinator's `glk_promote_branch`.
    pub(crate) fn promote(&mut self, now: i64) -> Result<usize, BranchError> {
        // `.full` recall: each promoted row is re-captured into the parent
        // estate (which requires non-empty content), so the content body must
        // be loaded. Mirrors the Swift glkPromoteBranch `.full` frame.
        let new_rows: Vec<Drawer> = Self::recall_all_full(&self.branch_estate, now)
            .into_iter()
            .filter(|row| !self.snapshot_ids.contains(&row.id))
            .collect();
        for row in &new_rows {
            self.parent_estate
                .capture(Self::capture_frame_from(row), now)?;
        }
        self.status = BranchStatus::Won;
        Ok(new_rows.len())
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
                    self.parent_estate
                        .capture(Self::capture_frame_from(row), now)?;
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
        let branch = EstateBranch::build(name.into(), parent.clone(), &snapshot_rows, 1, now)?;
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
        let branch = EstateBranch::build(name.into(), parent_estate, &snapshot_rows, depth, now)?;
        let id = branch.branch_id;
        self.branches.insert(id, branch);
        Ok(id)
    }

    /// Promote a tracked branch into the estate addressed by `handle`,
    /// re-capturing every post-derivation row into the parent and
    /// transitioning the branch to `Won`. Parity of `glkPromoteBranch`.
    /// Guards: branch must be tracked; `handle` must address the branch's
    /// parent estate (E-2).
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
        let branch = self
            .branches
            .get_mut(&branch_id)
            .ok_or(BranchError::NotTracked { branch_id })?;
        if branch.parent_estate_uuid() != target_uuid {
            return Err(BranchError::PromotionTargetMismatch { branch_id });
        }
        branch.promote(now)
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
}
