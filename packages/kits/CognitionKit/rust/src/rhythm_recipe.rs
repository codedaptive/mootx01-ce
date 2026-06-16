//! Rhythm — fingerprint bit-activity periodicity recipe (Lens 2,
//! Prediction+Time).
//!
//! Accepts pre-fetched buckets. `fingerprint_bit_series` is implemented in
//! `LocusKit::ContainerFingerprintStore` (Swift and Rust), but the Rust
//! `EstateCoordinator` does not yet re-export it as a top-level GLK surface —
//! the Swift port has `GeniusLocusKit.glkFingerprintBitSeries` for this.
//! Callers using the Rust port read the bit series directly via
//! `ContainerFingerprintStore::fingerprint_bit_series` and pass the slice here.
//!
//! Pure function: FFT over the bit-activity series to surface dominant
//! periodic patterns, delegating entirely to `neuron_kit::rhythm`. Read-only.

pub use neuron_kit::{rhythm, DominantPeriod};

/// Rhythm recipe output: the dominant periods in the bit-activity series
/// and the length of the input series.
#[derive(Debug, Clone, PartialEq)]
pub struct RhythmOutput {
    pub periods: Vec<DominantPeriod>,
    /// Number of buckets in the input series.
    pub bucket_count: usize,
}

/// FFT over `buckets` (one bool per time bucket) and return the top-k
/// dominant periodic activity patterns.
///
/// Empty `buckets` or `top_k == 0` yields an empty period list (B-8).
pub fn run_rhythm(
    buckets: &[bool],
    bucket_duration_seconds: f64,
    top_k: usize,
) -> RhythmOutput {
    let bucket_count = buckets.len();
    let periods = rhythm(buckets, bucket_duration_seconds, top_k);
    RhythmOutput { periods, bucket_count }
}

#[cfg(test)]
mod tests {
    use super::*;

    // CK-RH-1 (Rust): recipe output equals direct lens call on same shaped input.
    #[test]
    fn ck_rh1_matches_direct_lens_call() {
        // Alternating true/false series — creates periodic signal.
        let buckets: Vec<bool> = (0..16).map(|i| i % 2 == 0).collect();
        let bucket_duration_seconds = 64.0;
        let top_k = 3;

        let expected = rhythm(&buckets, bucket_duration_seconds, top_k);
        let out = run_rhythm(&buckets, bucket_duration_seconds, top_k);

        assert_eq!(out.periods, expected,
            "run_rhythm must equal the direct lens call");
        assert_eq!(out.bucket_count, 16);
    }

    // CK-RH-2 (Rust): all-false series yields empty period list (B-8).
    #[test]
    fn ck_rh2_all_false_is_guarded() {
        let buckets = vec![false; 8];
        let out = run_rhythm(&buckets, 3600.0, 3);
        assert!(out.periods.is_empty(),
            "all-constant series carries no frequency information");
    }

    // CK-RH-3 (Rust): top_k = 0 yields empty period list (B-8).
    #[test]
    fn ck_rh3_top_k_zero_is_guarded() {
        let buckets: Vec<bool> = (0..8).map(|i| i % 2 == 0).collect();
        let out = run_rhythm(&buckets, 60.0, 0);
        assert!(out.periods.is_empty());
    }
}
