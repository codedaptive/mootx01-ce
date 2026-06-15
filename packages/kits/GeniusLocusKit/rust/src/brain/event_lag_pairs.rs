// brain/event_lag_pairs.rs — lag-bucketed event-pair conversion.
//
// Rust mirror of EventLagPairs.swift (dormant-surfaces mission, Part 5).
//
// `event_lag_pairs` converts a HLC-ascending slice of UnifiedAuditEntry
// values into the input shape TemporalCausalityFold consumes. Only entries
// whose `hlc.physical_time` falls within `[lower_ms, upper_ms]` are
// included; entries outside the window are dropped.
//
// Conversion rules mirror EventLagPairs.swift exactly:
//   Bitmap(v)      → "bitmap:{v}"
//   StringValue(s) → "string:{s}"
//   Integer(v)     → "integer:{v}"
//   Bytes(b)       → "bytes:{b.len()}"
//   Null           → empty coord list
//
// Only Capture and Expunge verbs contribute field coordinates; all
// other verbs produce an empty coord list (watermark advance, no pairs).

use substrate_ml::temporal_causality_fold::{TemporalAuditEntry, TemporalFieldCoord};

use crate::audit::{UnifiedAuditEntry, UnifiedAuditValue, UnifiedAuditVerb};

/// Convert a HLC-ascending audit-entry slice into the input shape
/// `TemporalCausalityFold` consumes, filtered to the given ms window.
///
/// `entries` must be pre-sorted ascending by HLC (the caller's
/// `UnifiedAuditLog::ordered_entries()` guarantees this). The result
/// preserves the same order with only out-of-window entries removed.
///
/// Pass the result to `TemporalCausalityFold::fold` to obtain the
/// (antecedent, consequent, lag_bucket) delta pairs for the T matrix.
pub fn event_lag_pairs(
    entries: &[UnifiedAuditEntry],
    lower_ms: i64,
    upper_ms: i64,
) -> Vec<TemporalAuditEntry> {
    entries
        .iter()
        .filter(|e| e.hlc.physical_time >= lower_ms && e.hlc.physical_time <= upper_ms)
        .map(|entry| {
            // Only Capture and Expunge contribute field coordinates.
            // Other verbs advance the fold watermark but produce no pairs.
            if entry.verb != UnifiedAuditVerb::Capture
                && entry.verb != UnifiedAuditVerb::Expunge
            {
                return TemporalAuditEntry::new(entry.hlc, vec![]);
            }
            let coord: Option<TemporalFieldCoord> = match &entry.after_value {
                UnifiedAuditValue::Bitmap(v) => Some(TemporalFieldCoord::new(
                    entry.field_path.clone(),
                    format!("bitmap:{}", v),
                )),
                UnifiedAuditValue::StringValue(s) => Some(TemporalFieldCoord::new(
                    entry.field_path.clone(),
                    format!("string:{}", s),
                )),
                UnifiedAuditValue::Integer(v) => Some(TemporalFieldCoord::new(
                    entry.field_path.clone(),
                    format!("integer:{}", v),
                )),
                // Byte payloads contribute a size-only coord; raw bytes are
                // too high-cardinality to use as T-matrix coordinates.
                UnifiedAuditValue::Bytes(b) => Some(TemporalFieldCoord::new(
                    entry.field_path.clone(),
                    format!("bytes:{}", b.len()),
                )),
                // Null after-value: entry advances watermark, no coordinate.
                UnifiedAuditValue::Null => None,
            };
            let coords = coord.into_iter().collect();
            TemporalAuditEntry::new(entry.hlc, coords)
        })
        .collect()
}
