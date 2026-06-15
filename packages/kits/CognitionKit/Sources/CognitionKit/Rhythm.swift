import Foundation
import GeniusLocusKit
import NeuronKit

/// Rhythm recipe output: the dominant periodic components extracted from the
/// bit activity series, plus the count of time buckets read.
public struct RhythmOutput: Sendable, Equatable {
    /// Dominant periods sorted by relative magnitude descending.
    public let periods: [DominantPeriod]
    /// Count of time buckets in the series read from the estate.
    public let bucketCount: Int

    public init(periods: [DominantPeriod], bucketCount: Int) {
        self.periods = periods
        self.bucketCount = bucketCount
    }
}

/// Rhythm — fingerprint bit-activity periodicity recipe (Lens 2,
/// Prediction+Time).
///
/// Reads a time-bucketed boolean activity series for one fingerprint bit
/// position from the estate and surfaces the Rhythm lens to identify dominant
/// periodic patterns in that bit's activity. "Does activity in this bit cycle
/// on a daily, weekly, or monthly cadence?"
///
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — GLK dormant read
/// (`glkFingerprintBitSeries`) + NeuronKit `rhythm`. Read-only (B-6, I-6).
/// No write verb, now passed in, deterministic.
///
/// Rust peer: `run_rhythm` in `rhythm_recipe.rs`. The Rust version accepts
/// a pre-fetched `&[bool]` because the Rust `EstateCoordinator` does not yet
/// expose the dormant fingerprint-bit-series surface.
public enum Rhythm {

    /// Read the bit activity series for one fingerprint bit and surface the
    /// Rhythm lens.
    ///
    /// Series shorter than 4 buckets, all-constant series, or `topK ≤ 0`
    /// yield an empty period list (B-8 total-over-edge-input posture, matching
    /// `NeuronKit.rhythm`).
    ///
    /// - Parameters:
    ///   - kit: Open GeniusLocusKit instance.
    ///   - handle: Open estate handle.
    ///   - bit: Bit position in [0, 255] of the Fingerprint256.
    ///   - bucketSeconds: Width of each time bucket in seconds (≥ 1).
    ///   - bucketCount: Number of buckets to return (≥ 1); controls how far
    ///     back the series extends from `endingAt`.
    ///   - endingAt: Closed right edge of the last bucket.
    ///   - topK: Maximum dominant periods to return.
    ///   - now: Current clock tick for determinism (I-6).
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        bit: Int,
        bucketSeconds: Int,
        bucketCount: Int,
        endingAt: Date,
        topK: Int,
        now: Date
    ) async throws -> RhythmOutput {
        let buckets = try await kit.glkFingerprintBitSeries(
            in: handle,
            bit: bit,
            bucketSeconds: bucketSeconds,
            bucketCount: bucketCount,
            endingAt: endingAt)

        let periods = NeuronKit.rhythm(
            buckets: buckets,
            bucketDurationSeconds: Double(bucketSeconds),
            topK: topK)

        return RhythmOutput(periods: periods, bucketCount: buckets.count)
    }
}
