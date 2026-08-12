//! Optional historical migration catalog for GeniusLocusKit.
//!
//! The default feature set is empty. Consumers select the oldest supported
//! estate-format floor; additive features compile only the contiguous capsules
//! from that floor to the current runtime.
//!
//! Geometry normalization is unconditional — it is a file-geometry concern, not
//! a schema concern, and runs on ANY plaintext estate with nonzero
//! reserved-bytes-per-page regardless of migration floor.

// Geometry normalization: unconditional — format-agnostic, not gated on any
// migration trait because the SQLCipher attachFunc heuristic bug affects any
// plaintext estate created by Apple's SEE-provisioned sqlite3 regardless of
// the estate's schema version.
mod geometry_normalization;
pub use geometry_normalization::*;

#[cfg(feature = "migration-v1-0-to-v1-1")]
mod shared_content_migration;

#[cfg(feature = "migration-v1-0-to-v1-1")]
pub use shared_content_migration::*;

#[cfg(feature = "migration-v1-0-to-v1-1")]
mod distillation_storage_migration;

#[cfg(feature = "migration-v1-0-to-v1-1")]
pub use distillation_storage_migration::*;

use genius_locus_kit::estate_format::EstateFormatVersion;

pub fn compiled_floor() -> Option<EstateFormatVersion> {
    #[cfg(feature = "migration-v1-0-to-v1-1")]
    {
        return Some(EstateFormatVersion::V1_0);
    }
    #[cfg(not(feature = "migration-v1-0-to-v1-1"))]
    {
        None
    }
}
