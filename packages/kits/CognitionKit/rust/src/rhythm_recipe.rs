//! Rhythm — fingerprint bit-activity periodicity recipe (Lens 2,
//! Prediction+Time).
//!
//! Two entry points:
//!
//! - `run_rhythm(buckets, bucket_duration_seconds, top_k)` — pure function
//!   accepting pre-fetched buckets. Use when the caller already holds the bit
//!   series (e.g. from a prior `DrawerStore::fingerprint_bit_series` call).
//!
//! - `run_rhythm_from_estate(coord, handle, bit, bucket_seconds, bucket_count,
//!   ending_at, top_k)` — estate-driven entry point. Calls
//!   `EstateCoordinator::fingerprint_bit_series` to read the bit series through
//!   the GLK layer boundary (B-1 compliant), then runs the FFT lens. Mirrors
//!   Swift `Rhythm.run(input:estate:kit:)` which calls
//!   `kit.glkFingerprintBitSeries(in:bit:bucketSeconds:bucketCount:endingAt:)`.
//!
//! The top-level GLK surface (`EstateCoordinator::fingerprint_bit_series`) was
//! added in the IMM-COG-004 parity fix — callers should use
//! `run_rhythm_from_estate` rather than reading the bit series directly via
//! the store.
//!
//! Pure FFT lens: `neuron_kit::rhythm`. Read-only.

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

/// Estate-driven Rhythm entry point.
///
/// Rust parity of `Rhythm.run(input:estate:kit:)` in the Swift port.
/// Reads the fingerprint bit-activity series through the GLK layer boundary
/// (B-1 compliant) then runs the FFT lens.
///
/// Parameters mirror Swift `Rhythm.Input`:
/// - `bit`: fingerprint bit index in `[0, 255]`.
/// - `bucket_seconds`: width of each time bucket in seconds (≥ 1).
/// - `bucket_count`: number of buckets to read.
/// - `ending_at`: upper bound of the newest bucket (epoch seconds —
///   deterministic clock, never read system time here).
/// - `top_k`: maximum dominant periods to return.
///
/// # Errors
///
/// Returns `VerbDispatchError` for stale handles, `bit > 255`,
/// or `bucket_seconds < 1`.
pub fn run_rhythm_from_estate(
    coord: &genius_locus_kit::coordinator::EstateCoordinator,
    handle: &genius_locus_kit::handle::EstateHandle,
    bit: usize,
    bucket_seconds: i64,
    bucket_count: usize,
    ending_at: i64,
    top_k: usize,
) -> Result<RhythmOutput, genius_locus_kit::coordinator::VerbDispatchError> {
    // Read the bit series through the GLK layer boundary — parity with Swift's
    // `kit.glkFingerprintBitSeries(in:bit:bucketSeconds:bucketCount:endingAt:)`.
    let buckets = coord.fingerprint_bit_series(handle, bit, bucket_seconds, bucket_count, ending_at)?;
    // bucket_duration_seconds for the FFT lens is the bucket width in seconds.
    let bucket_duration_seconds = bucket_seconds as f64;
    Ok(run_rhythm(&buckets, bucket_duration_seconds, top_k))
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

    // CK-RH-4 (Rust): run_rhythm_from_estate on an InMemory estate returns
    //                   the same result as run_rhythm on an equivalent slice.
    //                   Verifies the GLK layer plumbing (B-1 parity fix IMM-COG-004).
    #[test]
    fn ck_rh4_from_estate_matches_direct_call() {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
                        estate_types::OwnerCredentials};

        const NOW: i64 = 1_700_000_000;
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(NOW, None).expect("store"),
        );
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        // InMemory estate has no stored drawers → bit series is all-false.
        // The important thing is that the call completes without panic and
        // bit=0, bucket_seconds=3600, bucket_count=8 are all valid.
        let result = super::run_rhythm_from_estate(
            &coord, &handle,
            0,     // bit
            3600,  // bucket_seconds
            8,     // bucket_count
            NOW,   // ending_at (deterministic — no system clock)
            3,     // top_k
        );
        assert!(result.is_ok(), "run_rhythm_from_estate must not error on empty InMemory estate");
        let out = result.unwrap();
        // All-false series (no drawers) → no dominant periods (B-8 guard in FFT lens).
        let direct = run_rhythm(&vec![false; 8], 3600.0, 3);
        assert_eq!(out.periods, direct.periods,
            "estate result must equal direct call on equivalent all-false series");
        assert_eq!(out.bucket_count, 8);
    }

    // CK-RH-5 (Rust): run_rhythm_from_estate rejects bit > 255.
    #[test]
    fn ck_rh5_invalid_bit_returns_error() {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
                        estate_types::OwnerCredentials};

        const NOW: i64 = 1_700_000_000;
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(NOW, None).expect("store"),
        );
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        let result = super::run_rhythm_from_estate(
            &coord, &handle,
            256, // bit > 255 → must return error
            3600,
            8,
            NOW,
            3,
        );
        assert!(result.is_err(), "bit > 255 must return Err");
    }
}
