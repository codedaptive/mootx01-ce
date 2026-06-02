// handle.rs — EstateHandle value type.
//
// Mirrors the Swift `EstateHandle` declared in
// `Sources/GeniusLocusKit/EstateHandle.swift`. Carries the estate's
// stable identifier and the zoom-window snapshot the coordinator's
// lattice-overlap predicate needs without re-reading the manifest.

use crate::coordinator::GeniusLocusKitError;

/// Stable identifier for an opened estate, drawn from the manifest's
/// `estate_uuid`. The Rust scaffold uses a `[u8; 16]` byte
/// representation so the type stays dependency-free; downstream
/// missions wiring GLK verb dispatch through locus_kit::Estate can
/// swap this for `uuid::Uuid` at that point.
pub type EstateUuid = [u8; 16];

/// Identifies one estate opened through the coordinator. Cloneable
/// and hashable so it can serve as a registry key.
///
/// A handle is **not** the estate. Closing an estate invalidates the
/// handle: subsequent coordinator lookups return
/// `GeniusLocusKitError::EstateNotOpen`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct EstateHandle {
    /// Stable estate identifier from the manifest.
    pub estate_uuid: EstateUuid,

    /// Zoom-window lower bound from the manifest. Cached on the
    /// handle so the lattice-overlap predicate avoids re-reading
    /// the manifest on every fan-out call. Per
    /// `docs/canon/private/SUBSTRATE_MATHEMATICS.md` §2.
    pub zoom_window_low: i64,

    /// Zoom-window upper bound from the manifest.
    pub zoom_window_high: i64,
}

impl EstateHandle {
    /// Construct a handle from manifest fields, validating the zoom
    /// window. Returns `Err(InvalidManifest)` when `low > high`.
    pub fn new(
        estate_uuid: EstateUuid,
        zoom_window_low: i64,
        zoom_window_high: i64,
    ) -> Result<Self, GeniusLocusKitError> {
        if zoom_window_low > zoom_window_high {
            return Err(GeniusLocusKitError::InvalidManifest {
                key: "zoom_window".into(),
                detail: format!(
                    "low ({}) must be <= high ({})",
                    zoom_window_low, zoom_window_high
                ),
            });
        }
        Ok(EstateHandle {
            estate_uuid,
            zoom_window_low,
            zoom_window_high,
        })
    }
}
