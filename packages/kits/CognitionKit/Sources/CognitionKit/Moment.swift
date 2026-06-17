import Foundation
import GeniusLocusKit
import NeuronKit
import SubstrateML
import SubstrateTypes

/// Moment recipe output: the OR-reduced window signature and ranked
/// comparison candidates, plus observation counts per window.
public struct MomentOutput: Sendable, Equatable {
    /// Signature and ranked comparison windows from the MomentSignature lens.
    public let result: MomentSignatureResult
    /// Count of fingerprints in the primary window.
    public let windowCount: Int
    /// Count of fingerprints in each comparison window, in input order.
    /// Windows whose fingerprint count was zero contributed no candidate.
    public let comparisonCounts: [Int]

    public init(result: MomentSignatureResult, windowCount: Int,
                comparisonCounts: [Int]) {
        self.result = result
        self.windowCount = windowCount
        self.comparisonCounts = comparisonCounts
    }
}

/// Moment — temporal fingerprint signature recipe (Lens 1, Time).
///
/// Reads the primary window's fingerprints from the estate, derives each
/// comparison window's OR-reduced summary the same way, and surfaces the
/// MomentSignature lens to rank how closely the comparison windows resemble
/// the primary. "What does this moment look like, and which other moments
/// feel most like it?"
///
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — GLK dormant read
/// (`glkFingerprintsCaptured`) + NeuronKit `momentSignature`. Read-only
/// (B-6, I-6). No write verb, now passed in, deterministic.
///
/// Rust peer: `run_moment` in `moment_recipe.rs`. Same flow: it reads both the
/// primary and comparison windows through the GLK surface
/// (`EstateCoordinator::glk_fingerprints_captured`, the Rust mirror of
/// `glkFingerprintsCaptured`) and feeds the MomentSignature lens. Windows are
/// `(start, end)` epoch-seconds pairs there where Swift uses `ClosedRange<Date>`.
public enum Moment {

    /// Read the primary window's fingerprints, OR-reduce each comparison
    /// window to a single candidate, and surface the MomentSignature lens.
    ///
    /// An empty primary window or empty candidate list yields a zero
    /// signature and empty ranking (B-8 total-over-edge-input posture).
    ///
    /// - Parameters:
    ///   - kit: Open GeniusLocusKit instance.
    ///   - handle: Open estate handle.
    ///   - window: Primary date range; the OR-reduced signature characterises
    ///     this moment.
    ///   - comparisonWindows: Date ranges to rank against the primary signature.
    ///     Windows with no fingerprints contribute no candidate (skipped).
    ///   - now: Current clock tick passed in for determinism (I-6). Not used
    ///     in the computation; accepted to satisfy the read-only lens-recipe
    ///     contract (B-6).
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        window: ClosedRange<Date>,
        comparisonWindows: [ClosedRange<Date>],
        now: Date
    ) async throws -> MomentOutput {
        let primaryFPs = try await kit.glkFingerprintsCaptured(in: handle, window: window)
        let windowCount = primaryFPs.count

        // Wrap as RowLite for the MomentSignature lens. `captureHLC` is not
        // consumed by `momentSignature` — only `.fingerprint` is used for
        // OR-reduce and Hamming ranking. `.zero` is the correct structural
        // placeholder when the GLK fingerprint-only surface omits HLC.
        let primaryRows: [RowLite] = primaryFPs.map {
            RowLite(fingerprint: $0, captureHLC: .zero)
        }

        // OR-reduce each comparison window to a single candidate fingerprint.
        // Windows with no fingerprints are skipped so the candidate list stays
        // compact and indices do not corrupt the ranking.
        var comparisonCounts: [Int] = []
        var candidates: [Fingerprint256] = []
        for cw in comparisonWindows {
            let fps = try await kit.glkFingerprintsCaptured(in: handle, window: cw)
            comparisonCounts.append(fps.count)
            if !fps.isEmpty {
                candidates.append(MomentSummary.orReduce(fps))
            }
        }

        let result = NeuronKit.momentSignature(
            fingerprints: primaryRows,
            candidates: candidates)

        return MomentOutput(
            result: result,
            windowCount: windowCount,
            comparisonCounts: comparisonCounts)
    }
}
