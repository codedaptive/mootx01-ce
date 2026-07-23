//! Optional historical migration catalog for GeniusLocusKit.
//!
//! The default feature set is empty. Consumers select the oldest supported
//! estate-format floor; additive features compile only the contiguous capsules
//! from that floor to the current runtime.

#[cfg(feature = "migration-v1-0-to-v1-1")]
mod shared_content_migration;

#[cfg(feature = "migration-v1-0-to-v1-1")]
pub use shared_content_migration::*;

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
