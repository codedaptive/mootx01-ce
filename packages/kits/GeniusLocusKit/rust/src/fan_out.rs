// fan_out.rs — Lattice-scoped read fan-out across open estates.
//
// Mirrors `Sources/GeniusLocusKit/CrossEstateRead.swift`. The
// overlap predicate is the conformance-gated unit: every shipping
// implementation across both ports must agree on which open estates
// a query region selects, given identical inputs. Parity tests live
// in `tests/parity.rs`.

use crate::coordinator::{EstateCoordinator, GeniusLocusKitError};
use crate::handle::EstateHandle;

/// A closed integer interval `[low, high]` over the lattice axis.
/// Closed on both ends so a single-point region `[k, k]` is
/// meaningful — useful for pinpoint reads and unit tests. Per
/// `docs/canon/private/SUBSTRATE_MATHEMATICS.md` §2.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LatticeRegion {
    pub low: i64,
    pub high: i64,
}

impl LatticeRegion {
    pub fn new(low: i64, high: i64) -> Self {
        Self { low, high }
    }
}

/// One estate's contribution to a fan-out recall. The GLK fan-out
/// returns drawer-id strings (not full `Drawer` values) because the
/// GLK verb bodies have not yet been wired to dispatch through a
/// live `locus_kit::Estate`; the parity test verifies the routing
/// decision (which estates are selected) rather than the per-drawer
/// payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EstateRecallContribution {
    pub handle: EstateHandle,
    pub drawer_ids: Vec<String>,
}

impl EstateCoordinator {
    /// The handles of all open estates whose zoom windows overlap
    /// `region`.
    ///
    /// Overlap is non-emptiness of the closed-interval intersection:
    /// `region.low <= h.zoom_window_high && region.high >= h.zoom_window_low`.
    /// Mirrors the Swift predicate bit-for-bit.
    pub fn estates_overlapping(
        &self,
        region: LatticeRegion,
    ) -> Result<Vec<EstateHandle>, GeniusLocusKitError> {
        if region.low > region.high {
            return Err(GeniusLocusKitError::InvalidLatticeRegion {
                low: region.low,
                high: region.high,
            });
        }
        let mut out: Vec<EstateHandle> = self
            .handles()
            .into_iter()
            .filter(|h| h.zoom_window_low <= region.high && h.zoom_window_high >= region.low)
            .collect();
        // Sort by UUID so the parity test sees a deterministic order
        // across runs. The Swift surface leaves order unspecified;
        // the conformance gate compares the SET, not the sequence.
        // Sorting here keeps the test asserts simple without changing
        // the contract.
        out.sort_by_key(|h| h.estate_uuid);
        Ok(out)
    }

    /// Fan-out recall scaffold. Without the LocusKit Rust port, the
    /// coordinator cannot actually issue a recall verb against each
    /// estate; it returns a contribution per overlapping handle with
    /// an empty `drawer_ids` list, which the parity test asserts
    /// against the per-handle expectation. The function exists so
    /// downstream missions land the live recall delegation behind a
    /// stable signature.
    pub fn fan_out_recall(
        &self,
        region: LatticeRegion,
    ) -> Result<Vec<EstateRecallContribution>, GeniusLocusKitError> {
        let targets = self.estates_overlapping(region)?;
        Ok(targets
            .into_iter()
            .map(|handle| EstateRecallContribution {
                handle,
                drawer_ids: Vec::new(),
            })
            .collect())
    }
}
