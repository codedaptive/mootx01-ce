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
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — GLK dormant reads
/// (`glkDrawerIDsForEventTimeWindow` + `glkEventLagPairs`) + SubstrateML
/// `TemporalCausalityFold.fold` (input shaping, I-17) + NeuronKit `precedence`.
/// Read-only (B-6, I-6). No write verb. The `now` parameter is accepted for
/// signature parity but is not read by this recipe.
///
/// Rust peer: `run_precedence` in `precedence_recipe.rs`, called from the
/// `moot_lens_precedence` arm in AriaMcpKit `lens_tools.rs`. The Rust caller
/// performs the same Option A eventTime filter via `store.all_drawers()`
/// (metadata-only in Rust) before passing entries to `run_precedence`.
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
    /// Option A: only drawers whose `eventTime` falls within `window` contribute
    /// causal pairs. The causality fold (HLC ordering inside the audit log) is
    /// unchanged — only WHICH drawers participate is gated by eventTime. The
    /// allowed-ID set is built via `glkDrawerIDsForEventTimeWindow`, which uses
    /// `.structured` (no-blob) hydration so content is never read from storage.
    /// Drawers without an explicit eventTime fall back to `filedAt` (resolved
    /// eagerly at capture time), so the fallback is always non-nil.
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
        // Uses glkDrawerIDsForEventTimeWindow — a metadata-only (.structured hydration)
        // GLK scan that projects away the content blob. Drawer.id is a String (UUID
        // string representation); the audit log's UnifiedAuditEntry.rowID is a UUID.
        // allowedRowIDs carries lowercased UUID strings matched in glkEventLagPairs
        // via entry.rowID.uuidString.lowercased().
        // Sensitivity ceiling (#38): only drawers within the MCP disclosure
        // ceiling (normal/elevated) contribute causal pairs. Restricted/secret
        // drawers are excluded so their field-value coordinates are not emitted.
        let rawIDs = try await kit.glkDrawerIDsForEventTimeWindow(in: handle, window: window)
        let estate = try await kit.estate(for: handle)
        // Use structured hydration (no blob) — we only need IDs and
        // sensitivity bits, not content. The prior allDrawers() loaded
        // full content, causing a full-corpus scan per MCP request.
        let allDrawers = try await estate.allDrawers(hydrationLevel: .structured, limit: nil)
        // Lowercase sensitive IDs to match rawIDs, which are lowercased by
        // glkDrawerIDsForEventTimeWindow. Without this, uppercase drawer
        // IDs (from UUID().uuidString) are never subtracted and restricted/
        // secret drawers leak their field-value coordinates.
        let sensitiveIDs = Set(
            allDrawers.filter { !$0.adjectiveSensitivity.isBulkExportable }
                .map { $0.id.lowercased() }
        )
        let allowedIDs = rawIDs.subtracting(sensitiveIDs)
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
