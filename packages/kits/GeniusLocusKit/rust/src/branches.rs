//! COW (copy-on-write) branch surface — the Rust parity of the Swift
//! `GeniusLocusKit/Branches/*` + the `glkDeriveBranch` / `glkPromoteBranch`
//! / `glkMergeDrawers` verbs in `Verbs/VerbSurface.swift`.
//!
//! A branch is a logical copy of a parent estate at derivation time, backed
//! by a fresh in-memory `locus_kit::Estate`. The parent is NEVER modified by
//! derivation or by captures into the branch — spec invariant I-15. Rows are
//! propagated into the parent only by an explicit `promote` (all post-
//! derivation rows) or `merge_drawers` (a cherry-picked subset).
//!
//! ## Why this is where GLK-rust binds the real LocusKit estate
//!
//! The rest of the GLK Rust scaffold mocks LocusKit recall behind a trait.
//! Branching cannot be mocked: it IS capture/recall over a real estate. So
//! this module depends on `locus_kit` directly (acyclic — LocusKit does not
//! depend on GLK) and on `persistence_kit` for the in-memory `Storage`
//! backend. This is the "downstream mission wires the real Rust port" the
//! crate's dependency comment anticipated.
//!
//! ## Registry-light shape vs. the Swift actor
//!
//! The Swift verbs live on the `GeniusLocusKit` actor and resolve an
//! `EstateHandle` to an estate through a kit-held registry, with a
//! `branchNotTracked` guard and an E-2 "promotion target must be the
//! branch's parent" guard. The Rust port folds those away: an `EstateBranch`
//! HOLDS its parent estate (a cheap `Arc`-sharing clone of the parent), so
//! `promote` / `merge_drawers` write to that parent directly — the target is
//! the branch's parent by construction, so the E-2 guard is structural and
//! the not-tracked guard is unnecessary. The COW semantics are identical.

use std::collections::BTreeSet;
use std::sync::Arc;

use locus_kit::drawer::Drawer;
use locus_kit::error::LocusKitError;
use locus_kit::estate::Estate;
use locus_kit::estate_types::{EstateError, LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{HydrationLevel, Ordering, RecallFrame};
use locus_kit::filter::Filter;
use locus_kit::frames::CaptureFrame;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;

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

/// Advisory scoring metadata for a branch (Brain-layer ranking input). The
/// substrate does not derive or enforce these — parity with the Swift
/// `BranchScore`.
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

/// Outcome of a selective `merge_drawers`. `conflicts` is reserved (always
/// empty), matching Swift.
#[derive(Debug, Clone, PartialEq)]
pub struct MergeReport {
    pub merged: Vec<String>,
    pub conflicts: Vec<String>,
    pub skipped: Vec<String>,
}

/// Errors a branch operation can surface — a thin union over the two
/// underlying LocusKit error types.
#[derive(Debug)]
pub enum BranchError {
    Estate(EstateError),
    Locus(LocusKitError),
}

impl From<EstateError> for BranchError {
    fn from(e: EstateError) -> Self { BranchError::Estate(e) }
}
impl From<LocusKitError> for BranchError {
    fn from(e: LocusKitError) -> Self { BranchError::Locus(e) }
}

/// A read-write COW branch backed by a fresh in-memory estate.
pub struct EstateBranch {
    pub branch_id: BranchId,
    pub name: String,
    pub lineage_depth: usize,
    /// The branch's own estate — captures land here only.
    branch_estate: Estate,
    /// The parent estate, sharing the parent's store (`Arc`). `promote` /
    /// `merge_drawers` write here; nothing else does (I-15).
    parent_estate: Estate,
    /// Branch-estate IDs copied from the parent at derivation. Any branch ID
    /// not in this set was captured after derivation ("new in branch").
    snapshot_ids: BTreeSet<String>,
    status: BranchStatus,
}

impl EstateBranch {
    /// Recall every unconfirmed row from an estate, draining all pages —
    /// the snapshot read `glkDeriveBranch` and the promote/merge scans use.
    fn recall_all(estate: &Estate, now: i64) -> Vec<Drawer> {
        let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
        frame.hydration_level = HydrationLevel::Structured;
        frame.ordering = Ordering::ByCaptureTimeDesc;
        estate.recall(frame, now).collect_all()
    }

    /// Rebuild a `CaptureFrame` from a stored row, preserving the fields the
    /// Swift re-capture preserves: content, capture channel, room, the full
    /// lattice anchor, author, embedding model, adjective sensitivity, and
    /// content kind. (`CaptureFrame::new` defaults sensitivity/kind, so they
    /// are set explicitly after construction.)
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

    /// Build a fresh, isolated in-memory branch estate. The owner encodes the
    /// branch id for log traceability, matching the Swift `branch-<uuid>`.
    fn new_branch_estate(branch_id: BranchId, now: i64) -> Result<Estate, BranchError> {
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store = Arc::new(InMemoryDrawerStore::new(storage, now, None)?);
        let owner = OwnerCredentials::new(format!("branch-{branch_id}"));
        let estate = Estate::create(store, owner, None)?;
        Ok(estate)
    }

    /// Copy `snapshot_rows` into a new branch estate, recording the minted
    /// branch-estate IDs as the derivation snapshot. Shared by both derive
    /// entry points.
    fn build(
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

    /// Derive a branch from a parent estate (lineage depth 1). All current
    /// parent rows are copied into a fresh branch estate; the parent is
    /// untouched. Parity of `glkDeriveBranch(name:from:)`.
    pub fn derive(name: impl Into<String>, parent: &Estate, now: i64) -> Result<Self, BranchError> {
        let snapshot_rows = Self::recall_all(parent, now);
        Self::build(name.into(), parent.clone(), &snapshot_rows, 1, now)
    }

    /// Derive a child branch from another branch (lineage depth + 1). Parity
    /// of `glkDeriveBranch(name:fromBranch:)`.
    pub fn derive_from_branch(
        name: impl Into<String>,
        parent_branch: &EstateBranch,
        now: i64,
    ) -> Result<Self, BranchError> {
        let snapshot_rows = Self::recall_all(&parent_branch.branch_estate, now);
        Self::build(
            name.into(),
            parent_branch.branch_estate.clone(),
            &snapshot_rows,
            parent_branch.lineage_depth + 1,
            now,
        )
    }

    /// Current lifecycle status.
    pub fn status(&self) -> BranchStatus { self.status }

    /// Capture a new drawer into this branch estate only. The parent is
    /// untouched (I-15).
    pub fn capture(&self, frame: CaptureFrame, now: i64) -> Result<Drawer, BranchError> {
        Ok(self.branch_estate.capture(frame, now)?)
    }

    /// Recall all rows from this branch estate.
    pub fn recall(&self, now: i64) -> Vec<Drawer> {
        Self::recall_all(&self.branch_estate, now)
    }

    /// Recall from this branch estate with a caller-supplied frame. The
    /// per-query read path the migration benchmark uses (it issues one
    /// `recall_with` per query frame and is otherwise read-only). The parent
    /// is never touched.
    pub fn recall_with(&self, frame: RecallFrame, now: i64) -> Vec<Drawer> {
        self.branch_estate.recall(frame, now).collect_all()
    }

    /// Transition the branch to `Discarded`. Rows are retained for audit;
    /// `recall` still works afterwards.
    pub fn discard(&mut self) {
        self.status = BranchStatus::Discarded;
    }

    /// Compare the current branch state to the derivation snapshot.
    /// `new_in_branch` = branch IDs absent from the snapshot;
    /// `withdrawn_in_branch` = snapshot IDs no longer present.
    pub fn compare_to_parent(&self, now: i64) -> DifferentialReport {
        let current_ids: BTreeSet<String> =
            self.recall(now).into_iter().map(|d| d.id).collect();
        let new_in_branch: Vec<String> =
            current_ids.difference(&self.snapshot_ids).cloned().collect();
        let withdrawn_in_branch: Vec<String> =
            self.snapshot_ids.difference(&current_ids).cloned().collect();
        DifferentialReport {
            new_in_branch,
            modified_in_branch: Vec::new(),
            withdrawn_in_branch,
        }
    }

    /// Promote the branch into its parent: re-capture every row added after
    /// derivation (not in the snapshot) into the parent estate, then
    /// transition to `Won`. Returns the number of rows promoted. Parity of
    /// `glkPromoteBranch`.
    pub fn promote(&mut self, now: i64) -> Result<usize, BranchError> {
        let new_rows: Vec<Drawer> = self
            .recall(now)
            .into_iter()
            .filter(|row| !self.snapshot_ids.contains(&row.id))
            .collect();
        for row in &new_rows {
            self.parent_estate.capture(Self::capture_frame_from(row), now)?;
        }
        self.status = BranchStatus::Won;
        Ok(new_rows.len())
    }

    /// Cherry-pick specific branch rows into the parent by branch-estate ID,
    /// then transition to `Merged`. IDs not present in the branch are
    /// `skipped`. Parity of `glkMergeDrawers`.
    pub fn merge_drawers(&mut self, drawer_ids: &[String], now: i64) -> Result<MergeReport, BranchError> {
        let rows = self.recall(now);
        let mut merged = Vec::new();
        let mut skipped = Vec::new();
        for id in drawer_ids {
            match rows.iter().find(|r| &r.id == id) {
                Some(row) => {
                    self.parent_estate.capture(Self::capture_frame_from(row), now)?;
                    merged.push(id.clone());
                }
                None => skipped.push(id.clone()),
            }
        }
        self.status = BranchStatus::Merged;
        Ok(MergeReport { merged, conflicts: Vec::new(), skipped })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_700_000_000;

    /// Build a parent estate seeded with `contents.len()` rows.
    fn parent_with(contents: &[&str]) -> Estate {
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store = Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
        let estate = Estate::create(store, OwnerCredentials::new("owner"), None).unwrap();
        for c in contents {
            let frame = CaptureFrame::new(
                *c,
                locus_kit::drawer_operational::CaptureChannel::Typed,
                "study",
                LatticeAnchor::udc("0"),
                "alice",
                "test-v1",
            );
            estate.capture(frame, NOW).unwrap();
        }
        estate
    }

    fn branch_capture(branch: &EstateBranch, content: &str) -> Drawer {
        let frame = CaptureFrame::new(
            content,
            locus_kit::drawer_operational::CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("0"),
            "bob",
            "test-v1",
        );
        branch.capture(frame, NOW).unwrap()
    }

    // BR-1: derivation snapshots all parent rows; the parent is untouched.
    #[test]
    fn br1_derive_snapshots_parent_and_leaves_it_unmodified() {
        let parent = parent_with(&["alpha", "beta"]);
        let branch = EstateBranch::derive("b1", &parent, NOW).unwrap();
        assert_eq!(branch.recall(NOW).len(), 2, "branch starts with the 2 parent rows");
        assert_eq!(branch.lineage_depth, 1);
        assert_eq!(branch.status(), BranchStatus::Active);
        // I-15: parent unchanged by derivation.
        assert_eq!(EstateBranch::recall_all(&parent, NOW).len(), 2);
    }

    // BR-2: a capture into the branch is isolated; compareToParent reports it
    // as new-in-branch and the parent is still untouched (I-15).
    #[test]
    fn br2_branch_capture_is_isolated_and_diffed() {
        let parent = parent_with(&["alpha"]);
        let branch = EstateBranch::derive("b2", &parent, NOW).unwrap();
        branch_capture(&branch, "gamma");
        assert_eq!(branch.recall(NOW).len(), 2);
        let diff = branch.compare_to_parent(NOW);
        assert_eq!(diff.new_in_branch.len(), 1, "the new row is new-in-branch");
        assert!(diff.withdrawn_in_branch.is_empty());
        assert!(diff.modified_in_branch.is_empty());
        // I-15: parent still has only its original row.
        assert_eq!(EstateBranch::recall_all(&parent, NOW).len(), 1);
    }

    // BR-3: promote re-captures only post-derivation rows into the parent and
    // transitions to Won. The snapshot rows are NOT duplicated into the parent.
    #[test]
    fn br3_promote_moves_new_rows_and_wins() {
        let parent = parent_with(&["alpha"]);
        let mut branch = EstateBranch::derive("b3", &parent, NOW).unwrap();
        branch_capture(&branch, "gamma");
        branch_capture(&branch, "delta");
        let promoted = branch.promote(NOW).unwrap();
        assert_eq!(promoted, 2, "two post-derivation rows promoted");
        assert_eq!(branch.status(), BranchStatus::Won);
        // Parent now has its original row plus the two promoted ones (the
        // snapshot copy is not re-added).
        assert_eq!(EstateBranch::recall_all(&parent, NOW).len(), 3);
    }

    // BR-4: merge cherry-picks by branch-estate ID; unknown IDs are skipped;
    // status becomes Merged.
    #[test]
    fn br4_merge_cherry_picks_by_id() {
        let parent = parent_with(&["alpha"]);
        let mut branch = EstateBranch::derive("b4", &parent, NOW).unwrap();
        let g = branch_capture(&branch, "gamma");
        branch_capture(&branch, "delta");
        let report = branch
            .merge_drawers(&[g.id.clone(), "no-such-id".to_string()], NOW)
            .unwrap();
        assert_eq!(report.merged, vec![g.id]);
        assert_eq!(report.skipped, vec!["no-such-id".to_string()]);
        assert!(report.conflicts.is_empty());
        assert_eq!(branch.status(), BranchStatus::Merged);
        // Parent got exactly the one cherry-picked row (original + 1).
        assert_eq!(EstateBranch::recall_all(&parent, NOW).len(), 2);
    }

    // BR-5: branch-of-branch increments lineage depth and snapshots the
    // parent branch's current rows.
    #[test]
    fn br5_branch_of_branch_lineage_depth() {
        let parent = parent_with(&["alpha"]);
        let b1 = EstateBranch::derive("b1", &parent, NOW).unwrap();
        branch_capture(&b1, "gamma");
        let b2 = EstateBranch::derive_from_branch("b2", &b1, NOW).unwrap();
        assert_eq!(b2.lineage_depth, 2);
        assert_eq!(b2.recall(NOW).len(), 2, "child snapshots parent branch's 2 rows");
    }

    // BR-6: discard transitions to Discarded but rows remain recallable
    // (audit retention), and the parent is never touched.
    #[test]
    fn br6_discard_retains_rows_and_spares_parent() {
        let parent = parent_with(&["alpha"]);
        let mut branch = EstateBranch::derive("b6", &parent, NOW).unwrap();
        branch_capture(&branch, "gamma");
        branch.discard();
        assert_eq!(branch.status(), BranchStatus::Discarded);
        assert_eq!(branch.recall(NOW).len(), 2, "rows retained after discard");
        assert_eq!(EstateBranch::recall_all(&parent, NOW).len(), 1, "I-15: parent untouched");
    }
}
