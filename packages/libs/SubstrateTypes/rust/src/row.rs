//! Substrate row data structures per cookbook §2.1.
//!
//! Moved here from substrate-lib in Phase 6.6 of the pre-ship
//! refactor (decision 2026-05-28 §6.6). Pure data; the substrate
//! that holds rows (and the verbs that mutate them) stay in
//! substrate-lib.

use crate::fingerprint256::Fingerprint256;
use crate::lattice_anchor::LatticeAnchor;
use crate::noun_type::NounType;
use crate::row_state::RowState;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct RowId(pub u128);

#[derive(Debug, Clone)]
pub struct Row {
    pub id: RowId,
    pub noun_type: NounType,
    pub state: RowState,
    pub adjective_bitmap: i64,
    pub operational_bitmap: i64,
    pub provenance_bitmap: i64,
    pub fingerprint: Fingerprint256,
    pub lattice_anchor: LatticeAnchor,
    pub lineage_id: Option<RowId>,
    pub content: Option<Vec<u8>>,
}
