//! DCP normalizer overflow rejection — Rust leg. Mirrored by
//! `ConflictProjectionOverflowTests.swift`, which asserts the same inputs
//! produce the same nothing/something answer in the Swift port. The two
//! files are a CROSS-PORT FIXTURE: an input accepted by one port and
//! refused by the other is a conformance break at exactly the values an
//! attacker picks.
//!
//! The normalizers already return `Option`, so an out-of-range value is
//! reported the same way an unparseable one is: `None`. Rejecting overflow
//! is not a range policy — `i64::MAX` seconds is still accepted, because
//! it does not overflow.
//!
//! RELEASE MODE MATTERS HERE. Before the fix, `duration` computed
//! `n * mult` unchecked: debug builds panicked with "attempt to multiply
//! with overflow", release builds wrapped and returned a value. Those are
//! two distinct defects and `duration_overflow_never_wraps` exists to pin
//! the release half — run this file with `cargo test --release` as well as
//! the default debug profile.

use substrate_ml::conflict_projection::*;

/// The duration suffixes the normalizer accepts, with their multipliers.
/// Enumerated rather than sampled: a suffix added later without a
/// checked multiply would slip past a single-suffix test.
const DURATION_SUFFIXES: &[(&str, i64)] = &[("min", 60), ("h", 3600), ("s", 1)];

// ---------------------------------------------------------------------------
// duration
// ---------------------------------------------------------------------------

/// The reporter's input. `i64::MAX * 3600` overflows; the answer is nothing.
#[test]
fn duration_reported_overflow_returns_none() {
    assert!(normalize::duration("9223372036854775807h").is_none());
}

/// The release-mode half of the defect, asserted on its own.
///
/// `(i64::MAX).wrapping_mul(3600) == -3600` — 3600 is even, so the high
/// bit falls off and the product wraps to a small NEGATIVE duration. A
/// wrapped value is worse than a panic: it becomes a fact value that flows
/// into contradiction evaluation and is compared against real durations.
/// Asserting `is_none` alone would be satisfied by a panic, so this test
/// also names the specific wrapped value that must never be produced.
#[test]
fn duration_overflow_never_wraps() {
    let wrapped = i64::MAX.wrapping_mul(3600);
    assert_eq!(wrapped, -3600, "the wrap this test exists to forbid");

    let got = normalize::duration("9223372036854775807h");
    assert!(got.is_none(), "expected None, got {got:?}");
    assert_ne!(
        got.map(|v| v.canonical_bytes()),
        Some(format!("dur:{wrapped}")),
        "release build accepted the wrapped product"
    );
}

/// `i64::MAX` and `i64::MIN` against every suffix. `s` has multiplier 1,
/// so the extremes are exactly representable and must still be ACCEPTED —
/// this mission rejects overflow, it does not impose a maximum duration.
#[test]
fn duration_extremes_rejected_only_where_they_overflow() {
    for &(suffix, mult) in DURATION_SUFFIXES {
        for extreme in [i64::MAX, i64::MIN] {
            let raw = format!("{extreme}{suffix}");
            let got = normalize::duration(&raw);
            match extreme.checked_mul(mult) {
                None => assert!(got.is_none(), "{raw} overflows but was accepted: {got:?}"),
                Some(seconds) => assert_eq!(
                    got.map(|v| v.canonical_bytes()),
                    Some(format!("dur:{seconds}")),
                    "{raw} is representable and must still normalize"
                ),
            }
        }
    }
}

/// Ordinary durations normalize exactly as they did before the fix. The
/// expected bytes are the same literals `conflict_projection_golden.rs`
/// pins, so a checked-arithmetic change cannot quietly alter results.
#[test]
fn duration_valid_inputs_unchanged() {
    assert_eq!(normalize::duration("1h").unwrap().canonical_bytes(), "dur:3600");
    assert_eq!(normalize::duration("60 min").unwrap().canonical_bytes(), "dur:3600");
    assert_eq!(normalize::duration("30s").unwrap().canonical_bytes(), "dur:30");
    assert_eq!(normalize::duration("-1h").unwrap().canonical_bytes(), "dur:-3600");
    assert!(normalize::duration("about an hour").is_none());
}

// ---------------------------------------------------------------------------
// budget_ceiling — the Swift twin (`ConflictNormalize.usdDecimal`) had three
// unchecked sites where this port already had `checked_*`. These assertions
// are the cross-port pin for all three.
// ---------------------------------------------------------------------------

/// Overflow in the fractional scaling loop: `i64::MAX * 10`.
#[test]
fn budget_ceiling_fraction_scaling_overflow_returns_none() {
    assert!(normalize::budget_ceiling("9223372036854775807.5").is_none());
}

/// Overflow in the fraction ADD, not the scaling multiply.
/// `922337203685477580 * 10 == 9223372036854775800` still fits; adding the
/// trailing `9` does not. This site is a separate `checked_add`.
#[test]
fn budget_ceiling_fraction_add_overflow_returns_none() {
    assert_eq!(922_337_203_685_477_580_i64.checked_mul(10), Some(9_223_372_036_854_775_800));
    assert!(normalize::budget_ceiling("922337203685477580.9").is_none());
}

/// Overflow in the suffix multiply, for every scaling suffix.
#[test]
fn budget_ceiling_suffix_multiply_overflow_returns_none() {
    for suffix in ["k", "m"] {
        let raw = format!("9223372036854775807{suffix}");
        assert!(normalize::budget_ceiling(&raw).is_none(), "{raw} was accepted");
    }
    // No suffix, no multiply: i64::MAX is representable and stays accepted.
    assert_eq!(
        normalize::budget_ceiling("9223372036854775807").unwrap().canonical_bytes(),
        "d:9223372036854775807"
    );
}

/// Ordinary money normalizes exactly as before — same literals as the
/// golden corpus.
#[test]
fn budget_ceiling_valid_inputs_unchanged() {
    assert_eq!(
        normalize::budget_ceiling("1,500k USD").unwrap().canonical_bytes(),
        "d:1500000"
    );
    assert_eq!(normalize::budget_ceiling("$1.5m").unwrap().canonical_bytes(), "d:1500000");
    assert_eq!(normalize::budget_ceiling("12.50").unwrap().canonical_bytes(), "d:12.5");
    assert_eq!(normalize::budget_ceiling("-0.125").unwrap().canonical_bytes(), "d:-0.125");
    assert!(normalize::budget_ceiling("about five").is_none());
}
