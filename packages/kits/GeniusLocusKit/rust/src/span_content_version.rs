//! The persisted span-row content version.  This deliberately remains FNV-1a
//! 64 over UTF-8 because existing rows use that identity.

use corpus_kit::encoder::spanner;
use synapsekit::vector_store::SpanVectorRow;

/// FNV-1a 64-bit content version, rendered as lower-case fixed-width hex.
pub fn span_content_version(content: &str) -> String {
    let mut hash: u64 = 14_695_981_039_346_656_037;
    for byte in content.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(1_099_511_628_211);
    }
    format!("{hash:016x}")
}

/// Whether a serving-generation span set must be rebuilt before strict
/// recall may treat it as fresh. This covers indexed drawers whose rows are
/// absent, malformed, or stamped with a non-canonical content version.
pub fn requires_repair(
    content: &str,
    expected_dimension: usize,
    max_spans: usize,
    rows: &[SpanVectorRow],
    has_malformed_rows: bool,
) -> bool {
    if has_malformed_rows || rows.is_empty() || rows.len() > max_spans {
        return true;
    }
    let expected = span_content_version(content);
    let word_count = spanner::words(content).len();
    rows.iter().enumerate().any(|(offset, row)| {
        row.index != offset as u32
            || row.int8.len() != expected_dimension
            || !row.scale.is_finite()
            || row.scale <= 0.0
            || row.start_word >= row.end_word
            || row.end_word > word_count
            || row.content_version != expected
    })
}

#[cfg(test)]
mod tests {
    use super::{requires_repair, span_content_version};
    use synapsekit::vector_store::SpanVectorRow;

    #[test]
    fn pins_utf8_fnv1a_not_a_replacement_digest() {
        assert_eq!(span_content_version(""), "cbf29ce484222325");
        assert_eq!(span_content_version("hello"), "a430d84680aabd0b");
        assert_ne!(span_content_version("cafe"), span_content_version("café"));
    }

    #[test]
    fn indexed_old_or_malformed_span_sets_are_repair_debt() {
        let expected = span_content_version("legacy transcript");
        let valid = SpanVectorRow {
            index: 0,
            int8: vec![1, 2],
            scale: 0.5,
            start_word: 0,
            end_word: 2,
            content_version: expected,
        };
        assert!(!requires_repair(
            "legacy transcript",
            2,
            3,
            &[valid.clone()],
            false
        ));
        let mut stale = valid.clone();
        stale.content_version = "old-content-hash".to_string();
        assert!(requires_repair("legacy transcript", 2, 3, &[stale], false));
        let mut wrong_dimension = valid.clone();
        wrong_dimension.int8.push(3);
        assert!(requires_repair(
            "legacy transcript",
            2,
            3,
            &[wrong_dimension],
            false
        ));
        let mut invalid_scale = valid.clone();
        invalid_scale.scale = f32::NAN;
        assert!(requires_repair(
            "legacy transcript",
            2,
            3,
            &[invalid_scale],
            false
        ));
        let mut invalid_bounds = valid.clone();
        invalid_bounds.end_word = 3;
        assert!(requires_repair(
            "legacy transcript",
            2,
            3,
            &[invalid_bounds],
            false
        ));
        assert!(requires_repair("legacy transcript", 2, 3, &[], false));
        assert!(requires_repair("legacy transcript", 2, 3, &[valid], true));
    }
}
