//! Forbidden adjective-bitmap combination validator. Ports
//! `ForbiddenCombinationValidator.swift`.
//!
//! Enforces the constitutional forbidden combination per cookbook §9.5
//! (safety invariants) and the §2.8 verification table.
//!
//! The forbidden combination is:
//!
//!   sensitivity = secret    (`AdjectiveSensitivity::Secret`, raw 48,
//!                            bits 6–11)
//!   AND
//!   exportability = public  (`AdjectiveExportability::Public`,
//!                            raw 32, bits 12–17)
//!
//! F11 cascade (2026-05-27): field positions and raws bumped from
//! v0.35 (bits 4–7 / 8–11; raws 12 / 8) to cookbook v0.6 (bits 6–11
//! / 12–17; raws 48 / 32).
//!
//! Storage can represent the combination; the verb layer must not
//! produce it. This validator is called at every adjective-bitmap write
//! path before any transaction opens, so a violation leaves the
//! database exactly as it was — the row never reaches INSERT and the
//! audit table never receives a row.
//!
//! The validator deliberately does not import `AdjectiveSensitivity` or
//! `AdjectiveExportability`. The bit constants below are hand-derived
//! from those enums' shipped raw values so future renames or added
//! intermediate tiers cannot silently shift this check. The numeric
//! encoding at bits 4–11 is the contract; the enum names are
//! documentation.

use crate::error::LocusKitError;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_kernel::bit_field;

// MARK: - Forbidden field values (cookbook §2.3)
//
// F18 atomic centralization: the prior SENSITIVITY_MASK / SECRET_VALUE /
// EXPORTABILITY_MASK / EXPORTABLE_VALUE constants were removed. The checks
// now extract each field via `bit_field` and compare to the cookbook-spec'd
// raw directly: sensitivity=secret is raw 48 at bits 6-11; exportability=
// public is raw 32 at bits 12-17.

// MARK: - Public API

/// Validate that `bitmap` does not encode a forbidden combination.
///
/// Returns `LocusKitError::DisciplineViolation` with `from` set to the
/// sensitivity raw value (bits 6–11) and `to` set to the exportability
/// raw value (bits 12–17). The `from` / `to` field reuse is the same
/// pattern `drawer_state_validator` uses to keep `LocusKitError`
/// independent of the typed enums.
///
/// The validator only inspects bits 6–17; state bits (0–5) and trust
/// bits (18–23) are ignored.
pub fn validate(bitmap: i64) -> Result<(), LocusKitError> {
    if is_secret_and_exportable(bitmap) {
        return Err(LocusKitError::DisciplineViolation {
            // F18: cookbook §2.3 sensitivity (bits 6-11) + exportability (bits 12-17).
            from: bit_field::extract_field(bitmap, 6, 6),
            to: bit_field::extract_field(bitmap, 12, 6),
            reason: "forbidden combination: sensitivity=secret AND \
                     exportability=exportable (spec I-3, § 6.6)"
                .to_string(),
        });
    }
    Ok(())
}

// MARK: - Private checks

/// True when `bitmap` encodes both `secret` in bits 4–7 and
/// `exportable` in bits 8–11. Other bits are not inspected.
fn is_secret_and_exportable(bitmap: i64) -> bool {
    // F18 atomic centralization: extract each field and compare to the
    // cookbook-spec'd raw value. Sensitivity=secret is raw 48 at bits 6-11;
    // exportability=public is raw 32 at bits 12-17 (cookbook §2.3).
    let sensitivity = bit_field::extract_field(bitmap, 6, 6);
    let exportability = bit_field::extract_field(bitmap, 12, 6);
    sensitivity == 48 && exportability == 32
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adjectives::{AdjectiveExportability, AdjectiveSensitivity};

    /// The combination "secret + exportable" is illegal — the entire
    /// purpose of the validator.
    #[test]
    fn secret_and_exportable_is_rejected() {
        let bitmap = (AdjectiveSensitivity::Secret.raw_value() << 6)
            | (AdjectiveExportability::Public.raw_value() << 12);
        let err = validate(bitmap).unwrap_err();
        match err {
            LocusKitError::DisciplineViolation { from, to, reason } => {
                assert_eq!(from, AdjectiveSensitivity::Secret.raw_value());
                assert_eq!(to, AdjectiveExportability::Public.raw_value());
                assert!(reason.contains("forbidden combination"));
                assert!(reason.contains("I-3"));
            }
            other => panic!("expected DisciplineViolation, got {:?}", other),
        }
    }

    /// Secret alone (private exportability) is legal.
    #[test]
    fn secret_with_private_exportability_is_legal() {
        let bitmap = AdjectiveSensitivity::Secret.raw_value() << 6;
        assert!(validate(bitmap).is_ok());
    }

    /// Exportable alone (normal sensitivity) is legal.
    #[test]
    fn exportable_with_normal_sensitivity_is_legal() {
        let bitmap = AdjectiveExportability::Public.raw_value() << 12;
        assert!(validate(bitmap).is_ok());
    }

    /// Each non-secret sensitivity combined with exportable is legal.
    #[test]
    fn restricted_or_elevated_or_normal_with_exportable_is_legal() {
        for sens in [
            AdjectiveSensitivity::Normal,
            AdjectiveSensitivity::Elevated,
            AdjectiveSensitivity::Restricted,
        ] {
            let bitmap =
                (sens.raw_value() << 6) | (AdjectiveExportability::Public.raw_value() << 12);
            assert!(
                validate(bitmap).is_ok(),
                "sens={:?} + exportable must be legal",
                sens
            );
        }
    }

    /// All-zero bitmap (defaults: state=active, sens=normal,
    /// exportability=private, trust=verbatim) is legal — the no-op
    /// case.
    #[test]
    fn zero_bitmap_is_legal() {
        assert!(validate(0).is_ok());
    }

    /// State and trust bits (0–3, 12–15) don't influence the
    /// validator — only bits 4–11 matter.
    #[test]
    fn state_and_trust_bits_ignored() {
        // Set every bit in 0–3 (state) and 12–15 (trust) but leave
        // sens/exportability at normal/private = legal.
        let bitmap = 0xF | 0xF000;
        assert!(validate(bitmap).is_ok());
    }

    /// Setting bits OUTSIDE the inspected ranges does not turn a legal
    /// combination into an illegal one.
    #[test]
    fn high_bits_do_not_affect_validation() {
        let bitmap = (AdjectiveSensitivity::Restricted.raw_value() << 6)
            | (AdjectiveExportability::Public.raw_value() << 12)
            | (1 << 30);
        assert!(validate(bitmap).is_ok());
    }
}
