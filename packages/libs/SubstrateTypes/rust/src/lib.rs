//! substrate-types — Layer 1 of the three-package SubstrateLib split
//! (cookbook v1.0 §20, I-30; decision 2026-05-28 §6 Phase 6).
//!
//! Pure data types — no compute, no transcendentals, no I/O.

pub mod audit_event;
pub mod bit_tensor;
pub mod bitwise;
pub mod block_mask;
pub mod count_vector;
pub mod fingerprint256;
pub mod fnv;
pub mod gset;
pub mod hamming;
pub mod hlc;
pub mod hyperplane;
pub mod lattice_anchor;
pub mod matrix_c;
pub mod matrix_f;
pub mod matrix_o;
pub mod matrix_t;
pub mod noun_type;
pub mod or_reduce;
pub mod recall_types;
pub mod row;
pub mod row_bitmaps;
pub mod row_state;
pub mod simhash;
pub mod time_range;

/// Re-export the primary types at the crate root for ergonomic
/// `use substrate_types::{...};` access.
pub use audit_event::AuditEvent;
pub use block_mask::BlockMask;
pub use fingerprint256::Fingerprint256;
pub use hlc::HLC;
pub use lattice_anchor::LatticeAnchor;
pub use matrix_c::MatrixC;
pub use matrix_f::MatrixF;
pub use matrix_o::MatrixO;
pub use matrix_t::MatrixT;
pub use noun_type::NounType;
pub use recall_types::{DistanceBreakdown, RecallResult, RecallScore, RowProjection};
pub use row::{Row, RowId};
pub use row_bitmaps::{BitVector216, RowBitmaps};
pub use row_state::{RowState, RowStateCluster, RowStateError, RowVerb};
pub use time_range::TimeRange;

pub const VERSION: &str = "1.0.0-skeleton";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skeleton_version() {
        assert_eq!(VERSION, "1.0.0-skeleton");
    }
}
