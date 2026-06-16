// fan_out.rs — Lattice-scoped read fan-out across open estates.
//
// Mirrors `Sources/GeniusLocusKit/CrossEstateRead.swift`. The
// overlap predicate is the conformance-gated unit: every shipping
// implementation across both legs must agree on which open estates
// a query region selects, given identical inputs. Parity tests live
// in `tests/parity.rs`.

use crate::coordinator::{EstateCoordinator, GeniusLocusKitError};
use crate::handle::EstateHandle;
use locus_kit::filter::RecallFrame;

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

/// One estate's contribution to a fan-out recall.
///
/// The contribution carries the recalled drawer ids (`drawer_ids`),
/// the id projection of the `Drawer` values the Swift contribution
/// returns in `EstateRecallContribution.drawers` — the conformance
/// unit here is the per-estate id SET (which drawers each overlapping
/// estate recalled), so the Rust port carries ids rather than full
/// `Drawer` payloads. The fan-out routes the supplied `RecallFrame`
/// through each overlapping estate's live `locus_kit::Estate.recall`
/// (the same surface a caller reaches through `estate_for`), so the
/// ids are real recalled rows, not a routing placeholder.
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

    /// Route `frame` to every open estate whose zoom window overlaps
    /// `region`, then return one contribution per contributing estate
    /// carrying that estate's recalled drawer ids.
    ///
    /// Mirrors the Swift `GeniusLocusKit.fanOutRecall(_:region:)`: each
    /// overlapping handle runs the supplied `RecallFrame` through its
    /// live `locus_kit::Estate.recall` (via the coordinator's internal
    /// `recall`, which leaves `trace_limit` None — fan-out is an
    /// internal read, B-10a compliant), and the resulting drawer ids
    /// are bundled into an `EstateRecallContribution` tagged with the
    /// originating handle. Estates disjoint from `region` are not
    /// consulted, so no work is done in them and they are absent from
    /// the result.
    ///
    /// `now` is explicit per the Rust substrate's determinism
    /// convention (the Swift estate reads its own clock).
    ///
    /// - Errors: `InvalidLatticeRegion` if `region.low > region.high`.
    pub fn fan_out_recall(
        &self,
        frame: RecallFrame,
        region: LatticeRegion,
        now: i64,
    ) -> Result<Vec<EstateRecallContribution>, GeniusLocusKitError> {
        let targets = self.estates_overlapping(region)?;
        let mut contributions: Vec<EstateRecallContribution> =
            Vec::with_capacity(targets.len());
        for handle in targets {
            // `recall` returns EstateNotOpen only if the handle is not in
            // the registry; `estates_overlapping` sourced these handles
            // from that same registry, so a miss means the registry was
            // mutated mid-fan-out (a close raced an in-flight fan-out).
            // Skip the missing entry rather than fail — parity with the
            // Swift `guard let estate = registry[handle] else { continue }`.
            let drawers = match self.recall(&handle, frame.clone(), now) {
                Ok(drawers) => drawers,
                Err(_) => continue,
            };
            let drawer_ids = drawers.into_iter().map(|d| d.id).collect();
            contributions.push(EstateRecallContribution { handle, drawer_ids });
        }
        Ok(contributions)
    }
}
