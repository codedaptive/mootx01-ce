// coordinator.rs — EstateCoordinator scaffold.
//
// Mirrors the Swift `EstateCoordinator` surface (open / close / list /
// estate_for) on the Rust side. The scaffold does not call into a
// real LocusKit Rust port — that port does not yet exist — so the
// coordinator holds an opaque per-estate state that downstream
// missions will replace with a live Estate handle when the Rust
// port is wired through.

use std::collections::HashMap;

use crate::handle::{EstateHandle, EstateUuid};

/// Per-estate state slot in the coordinator's registry. Today this is
/// just a marker tagging the estate as live; later missions hang the
/// concrete Estate value off this struct when the LocusKit Rust port
/// lands.
#[derive(Debug, Clone)]
pub struct EstateState {
    /// Estate display name from the manifest. Stored so diagnostics
    /// can surface a human-readable label without re-reading the
    /// manifest on every call.
    pub estate_name: String,
}

/// Errors raised by the GeniusLocusKit composition surface on the
/// Rust side. The case set mirrors the Swift `GeniusLocusKitError`
/// declared in `Sources/GeniusLocusKit/GeniusLocusKitError.swift`.
/// Cases carry the same identifying data so parity tests can match
/// behavior across ports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GeniusLocusKitError {
    /// Caller passed a manifest that violates the kit's preconditions.
    InvalidManifest { key: String, detail: String },

    /// A handle was used after the estate it referenced was closed,
    /// or a handle that was never issued by this coordinator was
    /// passed in.
    EstateNotOpen { estate_uuid: EstateUuid },

    /// An attempt to open an estate whose UUID matches one already
    /// in the registry. Estate UUIDs are immutable per spec § 7.7,
    /// so a duplicate is almost always the same database file being
    /// opened twice.
    DuplicateEstate { estate_uuid: EstateUuid },

    /// Caller asked for a fan-out region whose `low` exceeds its
    /// `high`. Surfaced explicitly so callers distinguish a
    /// programmer error from an empty-result outcome.
    InvalidLatticeRegion { low: i64, high: i64 },
}

/// The coordinator. Owns the registry of currently-open estates.
///
/// Construction is cheap; the registry starts empty. Callers admit
/// estates via `open` and address them by `EstateHandle` thereafter.
#[derive(Debug, Default, Clone)]
pub struct EstateCoordinator {
    registry: HashMap<EstateHandle, EstateState>,
}

impl EstateCoordinator {
    /// Construct a coordinator with an empty registry.
    pub fn new() -> Self {
        Self {
            registry: HashMap::new(),
        }
    }

    /// Number of estates currently open.
    pub fn open_estate_count(&self) -> usize {
        self.registry.len()
    }

    /// Snapshot of currently-open estate handles. Order is
    /// `HashMap`-iteration order — unspecified across runs. Callers
    /// that need stable ordering should sort by `estate_uuid`.
    pub fn handles(&self) -> Vec<EstateHandle> {
        self.registry.keys().copied().collect()
    }

    /// Admit an estate into the registry. Returns the freshly
    /// constructed handle.
    ///
    /// The Swift coordinator calls `LocusKit.Estate.open` here to
    /// open the underlying substrate. The Rust scaffold has no
    /// LocusKit Rust port to delegate to yet, so it accepts the
    /// manifest fields directly and trusts the caller to have opened
    /// the substrate already. The signature matches what downstream
    /// missions will pass when the port lands.
    ///
    /// Refuses to admit an estate whose UUID is already registered
    /// (per spec § 7.7 estate UUIDs are immutable, so a duplicate is
    /// almost certainly the same file being opened twice).
    pub fn open(
        &mut self,
        estate_uuid: EstateUuid,
        zoom_window_low: i64,
        zoom_window_high: i64,
        estate_name: String,
    ) -> Result<EstateHandle, GeniusLocusKitError> {
        let handle = EstateHandle::new(estate_uuid, zoom_window_low, zoom_window_high)?;
        if self.registry.contains_key(&handle) {
            return Err(GeniusLocusKitError::DuplicateEstate { estate_uuid });
        }
        self.registry.insert(handle, EstateState { estate_name });
        Ok(handle)
    }

    /// Remove an estate from the registry. The handle becomes stale;
    /// subsequent `state_for` lookups return `EstateNotOpen`.
    pub fn close(&mut self, handle: &EstateHandle) -> Result<(), GeniusLocusKitError> {
        if self.registry.remove(handle).is_none() {
            return Err(GeniusLocusKitError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            });
        }
        Ok(())
    }

    /// Reach the live state for a handle. Mirrors `estate(for:)` on
    /// the Swift side; the returned reference is the per-handle
    /// access point.
    pub fn state_for(&self, handle: &EstateHandle) -> Result<&EstateState, GeniusLocusKitError> {
        self.registry
            .get(handle)
            .ok_or(GeniusLocusKitError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            })
    }
}
