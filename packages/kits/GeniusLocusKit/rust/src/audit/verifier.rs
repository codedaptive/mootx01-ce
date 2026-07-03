// audit/verifier.rs — Rust mirror of
// `GeniusLocusKit/Sources/GeniusLocusKit/Audit/AuditChainVerifier.swift`
// and `AuditChainReport.swift` (mission GLK-03).
//
// Pure integrity check over a `UnifiedAuditLog`. The unified log has no
// prev-hash link between entries — each entry is content-addressed by a
// SHA-256 over its own fields (see `audit/log.rs`). Integrity is therefore
// two independent properties, checked per the Swift reference:
//
//   1. Content-hash fidelity. Recompute each entry's id from its fields via
//      `UnifiedAuditEntry::new` (the same path that minted the original id)
//      and compare to the stored id. A mismatch means the entry's bytes were
//      altered after it was minted — a tampered or corrupted entry. This is
//      the substantive check.
//   2. HLC monotonicity. Walking the log in HLC order, no entry's HLC may be
//      strictly less than its predecessor's. `ordered_entries` already sorts
//      by HLC, so this holds by construction for a well-formed log; the
//      explicit check is a defensive guard that catches a future ordering bug
//      at the source rather than downstream in the projection.
//
// Output is an `AuditChainReport` per NEURONKIT_SPEC § 3.5 / invariant C-12:
// on the first violation `valid == false` and `first_broken_at_millis` is the
// offending entry's HLC physical time (milliseconds since the Unix epoch).
//
// ── Date representation: millis, not Swift's `Date` ──────────────────────
// The Swift report carries `firstEntryAt` / `lastEntryAt` / `firstBrokenAt`
// as `Date`. The Rust port carries them as `i64` epoch-milliseconds — the
// raw `HLC.physical_time` unit, no `Date` wrapper in the Rust substrate. The
// maintenance reader's `AuditVerdict` (neuron_kit) consumes
// `first_broken_at_millis` directly, so millis is the parity-correct unit.

use crate::audit::{UnifiedAuditEntry, UnifiedAuditLog};

/// Integrity report for a unified audit log. Per NEURONKIT_SPEC § 3.5.
///
/// Rust parity of the Swift `AuditChainReport`, with the three timestamps
/// expressed as `i64` epoch-milliseconds rather than `Date`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuditChainReport {
    /// True when every entry's stored id matches its recomputed content hash
    /// and HLC ordering is monotonic. False on the first violation.
    pub valid: bool,

    /// Number of entries the verifier walked.
    pub entry_count: usize,

    /// Physical time (epoch ms) of the earliest entry by HLC. `0` for an
    /// empty log — there is no entry to date, and the field is non-optional
    /// (matching the Swift epoch sentinel `Date(timeIntervalSince1970: 0)`).
    pub first_entry_at_millis: i64,

    /// Physical time (epoch ms) of the latest entry by HLC. `0` for an empty
    /// log, as with `first_entry_at_millis`.
    pub last_entry_at_millis: i64,

    /// Physical time (epoch ms) of the first entry that failed integrity, or
    /// `None` when the chain is intact. Set together with `valid == false`
    /// (C-12).
    pub first_broken_at_millis: Option<i64>,
}

/// Verifies that a `UnifiedAuditLog`'s chain is intact. Pure — no I/O, no
/// shared state, deterministic given the log. Rust parity of the Swift
/// `AuditChainVerifier` enum.
pub struct AuditChainVerifier;

impl AuditChainVerifier {
    /// Verify the log and return the integrity report.
    pub fn verify(log: &UnifiedAuditLog) -> AuditChainReport {
        let entries = log.ordered_entries();

        let (first, last) = match (entries.first(), entries.last()) {
            (Some(f), Some(l)) => (f, l),
            _ => {
                // Empty log: vacuously valid. No entry to date.
                return AuditChainReport {
                    valid: true,
                    entry_count: 0,
                    first_entry_at_millis: 0,
                    last_entry_at_millis: 0,
                    first_broken_at_millis: None,
                };
            }
        };

        let first_at = first.hlc.physical_time;
        let last_at = last.hlc.physical_time;
        let count = entries.len();

        let mut previous_hlc = None;
        for entry in &entries {
            // (2) HLC monotonicity — no reversal relative to the prior entry
            // in HLC order.
            if let Some(prev) = previous_hlc {
                if entry.hlc < prev {
                    return AuditChainReport {
                        valid: false,
                        entry_count: count,
                        first_entry_at_millis: first_at,
                        last_entry_at_millis: last_at,
                        first_broken_at_millis: Some(entry.hlc.physical_time),
                    };
                }
            }
            previous_hlc = Some(entry.hlc);

            // (1) Content-hash fidelity — recompute the id from the entry's
            // fields via the same content-hashing constructor that minted the
            // original id. An intact entry round-trips to an identical hash.
            let recomputed = UnifiedAuditEntry::new(
                entry.tier,
                entry.hlc,
                entry.verb,
                entry.row_id,
                entry.field_path.clone(),
                entry.before_value.clone(),
                entry.after_value.clone(),
                entry.origin_row_id,
            );
            if recomputed.id != entry.id {
                return AuditChainReport {
                    valid: false,
                    entry_count: count,
                    first_entry_at_millis: first_at,
                    last_entry_at_millis: last_at,
                    first_broken_at_millis: Some(entry.hlc.physical_time),
                };
            }
        }

        AuditChainReport {
            valid: true,
            entry_count: count,
            first_entry_at_millis: first_at,
            last_entry_at_millis: last_at,
            first_broken_at_millis: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audit::{
        AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog, UnifiedAuditValue,
        UnifiedAuditVerb,
    };
    use substrate_types::hlc::HLC;

    fn entry_at(physical_ms: i64, field: &str) -> UnifiedAuditEntry {
        UnifiedAuditEntry::new(
            AuditTier::Locus,
            HLC::new(physical_ms, 0, 0),
            UnifiedAuditVerb::Capture,
            EntryUUID([7u8; 16]),
            field.to_string(),
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Bitmap(1),
            None,
        )
    }

    // AV-1: an empty log is vacuously valid with zero count and zero dates.
    #[test]
    fn av1_empty_log_is_valid() {
        let report = AuditChainVerifier::verify(&UnifiedAuditLog::new());
        assert!(report.valid);
        assert_eq!(report.entry_count, 0);
        assert_eq!(report.first_entry_at_millis, 0);
        assert_eq!(report.last_entry_at_millis, 0);
        assert!(report.first_broken_at_millis.is_none());
    }

    // AV-2: a well-formed multi-entry log verifies clean; dates frame the span.
    #[test]
    fn av2_clean_log_verifies() {
        let mut log = UnifiedAuditLog::new();
        log.add(entry_at(1000, "adjective"));
        log.add(entry_at(2000, "operational"));
        log.add(entry_at(3000, "provenance"));
        let report = AuditChainVerifier::verify(&log);
        assert!(report.valid, "intact chain must verify");
        assert_eq!(report.entry_count, 3);
        assert_eq!(report.first_entry_at_millis, 1000);
        assert_eq!(report.last_entry_at_millis, 3000);
        assert!(report.first_broken_at_millis.is_none());
    }

    // AV-3: a tampered entry (stored id ≠ recomputed hash) is rejected at
    // the add boundary — the verify-on-ingress defence in UnifiedAuditLog::add
    // (codex a477800) catches the mismatch before the entry reaches the log.
    // The chain verifier therefore sees only honest entries and reports valid.
    // The verifier's content-hash check remains defence-in-depth for entries
    // that might enter via an unexpected path in the future.
    #[test]
    fn av3_tampered_entry_rejected_at_add_boundary() {
        let mut log = UnifiedAuditLog::new();
        log.add(entry_at(1000, "adjective"));

        let mut tampered = entry_at(2000, "operational");
        // Alter a field WITHOUT recomputing the id — simulates the forgery
        // a hostile peer might supply. The stored id no longer matches the
        // wire encoding of the mutated entry.
        tampered.field_path = "provenance".to_string();
        log.add(tampered);

        // add rejects the tampered entry; only the honest entry at t=1000 remains.
        assert_eq!(
            log.ordered_entries().len(),
            1,
            "tampered entry must be rejected at the add boundary (codex a477800)"
        );

        // The chain verifier reports valid: it sees only honest entries.
        // This validates that the verify-on-ingress defence and the
        // verifier's own defence-in-depth check are consistent.
        let report = AuditChainVerifier::verify(&log);
        assert!(
            report.valid,
            "chain is valid when only honest entries are present"
        );
        assert_eq!(report.entry_count, 1);
        assert_eq!(report.first_entry_at_millis, 1000);
        assert!(report.first_broken_at_millis.is_none());
    }
}
