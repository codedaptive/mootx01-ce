import Foundation
import Testing

@testable import GeniusLocusKit

/// Batch ceiling of `AdornmentPass.run` (GENIUSLOCUSKIT_SPEC § 16.1): one
/// pass never fetches more than `ADORNMENT_PASS_MAX_BATCH_SIZE` pairs,
/// whatever the caller asked for. The Rust port pins the same literals
/// (`clamped_batch_size_pins_ceiling`).
@Suite("AdornmentPass batch ceiling")
struct AdornmentPassBatchCeilingTests {

    /// Literal pin shared with the Rust port: 999_999 clamps to 5000; the
    /// default and any in-range request pass through unchanged.
    @Test func clampedBatchSizePinsCeiling() {
        #expect(ADORNMENT_PASS_MAX_BATCH_SIZE == 5000)
        #expect(AdornmentPass.clampedBatchSize(999_999) == 5000)
        #expect(AdornmentPass.clampedBatchSize(AdornmentPass.defaultBatchSize) == 50)
        #expect(AdornmentPass.clampedBatchSize(5000) == 5000)
        #expect(AdornmentPass.clampedBatchSize(0) == 0)
    }

    /// The default batch stays well inside the ceiling — the hourly signal
    /// fire is never clamped.
    @Test func defaultBatchIsUnderTheCeiling() {
        #expect(AdornmentPass.defaultBatchSize < ADORNMENT_PASS_MAX_BATCH_SIZE)
    }
}
