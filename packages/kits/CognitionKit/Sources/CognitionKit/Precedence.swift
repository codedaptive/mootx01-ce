import Foundation
import GeniusLocusKit
import NeuronKit
import SubstrateML
import SubstrateTypes

/// Precedence recipe output: the ranked antecedents for a target field-value
/// coordinate, plus the count of audit entries read.
public struct PrecedenceOutput: Sendable, Equatable {
    /// Antecedents sorted by co-occurrence count descending.
    public let antecedents: [AntecedentRank]
    /// Count of audit entries read from the estate for the window.
    public let entryCount: Int

    public init(antecedents: [AntecedentRank], entryCount: Int) {
        self.antecedents = antecedents
        self.entryCount = entryCount
    }
}

/// Precedence — temporal causality antecedent recipe (Lens 3, Prediction).
///
/// Reads the estate's audit entries for a window via the GLK event-lag-pair
/// surface, folds them through `TemporalCausalityFold` into T-matrix deltas
/// (pure input shaping — the fold produces the delta pairs the lens consumes
/// and is not a reasoning step of its own), and surfaces the Precedence lens
/// to rank the strongest antecedents for a target field-value coordinate.
/// "What typically happens just before this field takes this value?"
///
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — GLK dormant read
/// (`glkEventLagPairs`) + SubstrateML `TemporalCausalityFold.fold` (input
/// shaping, I-17) + NeuronKit `precedence`. Read-only (B-6, I-6). No write
/// verb, now passed in, deterministic.
///
/// Rust peer: `run_precedence` in `precedence_recipe.rs`. Accepts pre-fetched
/// `[TemporalAuditEntry]` because the Rust `EstateCoordinator` audit log is
/// not yet exposed through its dormant surface; callers provide the entries
/// directly.
public enum Precedence {

    // Fold window in minutes: 128 matches the largest `MatrixTier.lagBuckets`
    // bucket. Pairs further apart than this cannot contribute to the T matrix.
    private static let foldWindowMinutes: Int = 128

    /// Read the estate's audit entries, fold them into T-matrix deltas, and
    /// rank antecedents for the target field-value coordinate.
    ///
    /// Empty entry set, k ≤ 0, or no entry targeting `target` yields an
    /// empty antecedent list (B-8 total-over-edge-input posture).
    ///
    /// Option A (Bob's ruling, Wave C): only drawers whose `eventTime` falls
    /// within `window` contribute causal pairs. The causality fold (HLC
    /// ordering inside the audit log) is unchanged — only WHICH drawers
    /// participate is gated by eventTime. Drawers without an explicit
    /// eventTime fall back to `filedAt` (resolved eagerly at capture time),
    /// so the fallback is always non-nil.
    ///
    /// - Parameters:
    ///   - kit: Open GeniusLocusKit instance.
    ///   - handle: Open estate handle.
    ///   - window: Closed date range; only entries within this range are used.
    ///   - target: The field-value coordinate whose antecedents are sought.
    ///   - k: Maximum antecedents to return.
    ///   - now: Current clock tick for determinism (I-6).
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        window: ClosedRange<Date>,
        target: TemporalFieldCoord,
        k: Int,
        now: Date
    ) async throws -> PrecedenceOutput {
        // Option A: pre-filter drawers by eventTime before gathering audit entries.
        // Only drawers whose eventTime falls within the window contribute causal pairs.
        // Uses GeniusLocusKit.allDrawers(in:) — a dormant (read-only) GLK surface.
        // Drawer.id is a String (UUID string representation); the audit log's
        // UnifiedAuditEntry.rowID is a UUID. allowedRowIDs carries String IDs
        // (lowercased) matched in glkEventLagPairs via entry.rowID.uuidString.
        let allDrawers = try await kit.allDrawers(in: handle)
        let allowedIDs: Set<String> = Set(
            allDrawers
                .filter { window.contains($0.eventTime) }
                .map { $0.id.lowercased() }
        )
        let entries = try await kit.glkEventLagPairs(
            in: handle, window: window, allowedRowIDs: allowedIDs)
        let entryCount = entries.count

        // Fold from watermark .zero so every entry in the window is treated
        // as "new" — all contribute causal pairs. Mirrors the T-matrix cold-
        // start path used by MatrixTier.rebuildTemporal. fold() returns a
        // FoldResult (named struct); access .deltas by field name.
        let foldResult = TemporalCausalityFold.fold(
            entries: entries,
            windowMinutes: foldWindowMinutes,
            startWatermark: .zero)

        let antecedents = NeuronKit.precedence(
            pairs: foldResult.deltas,
            target: target,
            k: k)

        return PrecedenceOutput(antecedents: antecedents, entryCount: entryCount)
    }
}
