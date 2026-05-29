import Foundation
import LocusKit

/// Lattice region — a half-open interval `[low, high]` over the
/// integer lattice axis that the manifest's `zoom_window_low` /
/// `zoom_window_high` rows occupy.
///
/// The zoom-window definition lives in `docs/canon/private/SUBSTRATE_MATHEMATICS.md`
/// section 2: each estate declares a window over the shared lattice,
/// and "overlap" between a query region and an estate is non-emptiness
/// of the intersection. The region is closed on both ends so a
/// single-point region `[k, k]` is meaningful (a query at exactly one
/// lattice node, useful for unit tests and pinpoint reads).
public struct LatticeRegion: Sendable, Equatable {

    /// Lower bound of the region, inclusive.
    public let low: Int

    /// Upper bound of the region, inclusive.
    public let high: Int

    /// Construct a region. `low` must be `<= high`; otherwise the
    /// coordinator raises `.invalidLatticeRegion` when the region
    /// is presented to `fanOutRecall`.
    public init(low: Int, high: Int) {
        self.low = low
        self.high = high
    }
}

/// One estate's contribution to a fan-out recall.
///
/// The fan-out returns the per-estate contributions rather than a
/// flattened drawer list because callers often need to know which
/// estate produced which rows (audit, debugging, scoring per-estate
/// relevance). Aggregation into a single list is a one-liner on the
/// caller side if needed.
public struct EstateRecallContribution: Sendable {

    /// The handle that produced this contribution.
    public let handle: EstateHandle

    /// Drawers recalled from the estate. Hydration follows the
    /// `RecallFrame.hydrationLevel` the caller supplied; the
    /// coordinator does not re-hydrate.
    public let drawers: [Drawer]
}

/// Cross-estate read fan-out on `GeniusLocusKit`.
///
/// Lattice-scoped fan-out is this scaffold mission's only cross-estate
/// behavior. Given a `LatticeRegion`, the kit routes a `RecallFrame`
/// to every open estate whose zoom window overlaps the region, then
/// aggregates the per-estate results. Estates whose windows are
/// disjoint from the region return nothing for that query — they are
/// not consulted, so no work is done in them.
///
/// This is not federation. Federation is a ConvergenceKit and ARIA_MCP
/// concern (spec invariant I-13: the substrate does not federate).
/// Cross-estate read fan-out here only routes local reads across
/// locally-opened estates and does not cross the device boundary.
public extension GeniusLocusKit {

    // MARK: - estatesOverlapping

    /// The handles of all open estates whose zoom windows overlap
    /// `region`.
    ///
    /// Overlap is non-emptiness of the closed-interval intersection:
    /// `low <= h.zoomWindowHigh && high >= h.zoomWindowLow`. The
    /// implementation is a single pass over the registry; the kit is
    /// designed for tens of estates per device per spec § 4.10, so
    /// linear traversal is appropriate.
    ///
    /// - Throws: `.invalidLatticeRegion` if `region.low > region.high`.
    func estatesOverlapping(_ region: LatticeRegion) throws -> [EstateHandle] {
        guard region.low <= region.high else {
            throw GeniusLocusKitError.invalidLatticeRegion(
                low: region.low, high: region.high
            )
        }
        return registry.keys.filter { handle in
            handle.zoomWindowLow <= region.high &&
            handle.zoomWindowHigh >= region.low
        }
    }

    // MARK: - fanOutRecall

    /// Route a recall to every open estate whose zoom window overlaps
    /// `region`, then return the per-estate contributions.
    ///
    /// Routing semantics: an estate whose window is disjoint from the
    /// region is not consulted. An estate whose window overlaps the
    /// region runs the supplied `RecallFrame` through its existing
    /// `LocusKit.Estate.recall` surface (the same surface a caller
    /// would use through `estate(for:)`), and the resulting drawers
    /// are bundled into an `EstateRecallContribution` tagged with the
    /// originating handle.
    ///
    /// Pagination: the coordinator drains each estate's
    /// `RecallStream` fully before returning, so the caller receives
    /// the complete result set for each contributing estate. The
    /// `RecallFrame.limit` cap still applies per estate — it is a
    /// page size, not a global ceiling — which keeps the contract
    /// consistent with `Estate.recall`.
    ///
    /// Ordering: estates are visited serially in registry traversal
    /// order, which is unspecified. Callers that need a stable order
    /// across runs should sort the returned contributions by
    /// `handle.estateUUID` themselves.
    ///
    /// - Parameters:
    ///   - frame: the recall to route. Every contributing estate
    ///     receives the same frame; per-estate variants are out of
    ///     scope for the scaffold.
    ///   - region: the lattice region the query is scoped to.
    /// - Returns: one contribution per contributing estate. Empty when
    ///   no open estate's window overlaps `region`.
    /// - Throws: `.invalidLatticeRegion` if the region is inverted.
    func fanOutRecall(
        _ frame: RecallFrame,
        region: LatticeRegion
    ) async throws -> [EstateRecallContribution] {
        let targets = try estatesOverlapping(region)
        var contributions: [EstateRecallContribution] = []
        contributions.reserveCapacity(targets.count)
        for handle in targets {
            guard let estate = registry[handle] else {
                // The registry was mutated mid-fan-out (a close raced
                // an in-flight fan-out). Skip the missing entry rather
                // than throw: the caller asked for "all currently
                // overlapping estates", and one of those has just
                // ceased to be currently open. Aggregate continues.
                continue
            }
            var drawers: [Drawer] = []
            let stream = await estate.recall(frame)
            for await page in stream {
                drawers.append(contentsOf: page.rows)
            }
            contributions.append(EstateRecallContribution(handle: handle, drawers: drawers))
        }
        return contributions
    }
}
