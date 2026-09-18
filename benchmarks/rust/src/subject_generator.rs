// subject_generator.rs — deterministic AI-facing subject from record content.
//
// CANONICAL ALGORITHM. This is the exact Rust twin of SubjectGenerator.swift.
// Same inputs must produce identical outputs on both legs; conformance is
// gated by conformance/subject_vectors.json.
//
// See SubjectGenerator.swift for the full algorithm description. Summary:
//   1. Trim leading/trailing whitespace.
//   2. Scan for first sentence boundary: '.', '?', or '!' followed by ASCII
//      whitespace or end-of-string. Period followed by a digit is NOT a
//      boundary (decimal point in a numeric literal).
//   3. Extract from start through (and including) the punctuation char, trim.
//   4. When no boundary is found, use the entire trimmed string.
//   5. Cap at 120 Unicode scalar values via chars().take(120).
//      For all ASCII corpus content this matches Swift's prefix(120).

/// Generates a deterministic AI-facing subject from record content.
///
/// Returns the first complete sentence of the trimmed content, capped at 120
/// Unicode scalar values. When no sentence boundary is found, returns the
/// entire trimmed content (or its first 120 scalars). Empty input returns an
/// empty string.
///
/// Pure function: same input always produces the same output. No randomness,
/// no clock, no I/O.
pub fn deterministic_subject(content: &str) -> String {
    let t = content.trim();
    if t.is_empty() {
        return String::new();
    }

    // Scan byte-by-byte. The sentence-ending punctuation characters ('.', '?',
    // '!') and ASCII whitespace are all single-byte in UTF-8, so byte scanning
    // is correct and faster than character scanning for the boundary check.
    // Multi-byte Unicode characters are passed through unchanged — they never
    // match any boundary byte, and t[..cut] is always a valid UTF-8 slice
    // because cut lands immediately after an ASCII punctuation byte.
    let bytes = t.as_bytes();
    let mut cut: Option<usize> = None; // exclusive end of sentence (byte index)

    for i in 0..bytes.len() {
        let b = bytes[i];
        if b == b'.' || b == b'?' || b == b'!' {
            let next = i + 1;
            // A period followed by a decimal digit is a numeric literal
            // separator (e.g. "3.14"), not a sentence boundary.
            if b == b'.' && next < bytes.len() && bytes[next].is_ascii_digit() {
                continue;
            }
            // Boundary: punctuation at end-of-string or followed by whitespace.
            if next >= bytes.len()
                || bytes[next] == b' '
                || bytes[next] == b'\n'
                || bytes[next] == b'\r'
                || bytes[next] == b'\t'
            {
                cut = Some(i + 1); // one past the punctuation char
                break;
            }
        }
    }

    let sentence = if let Some(c) = cut {
        // Trim any whitespace the slice may have — handles the end-of-string
        // case where the punctuation is the last char and cut == bytes.len().
        t[..c].trim()
    } else {
        t
    };

    // Normalize embedded newlines to spaces BEFORE the length cap — twin of
    // the Swift generator's fix for the CRLF-grapheme overflow (LongMemEval-m
    // question 8b9d4367: cap-then-replace grew the subject to 123 chars and
    // the import rejected it). Per-scalar 1:1 replacement plus trim is
    // identical to the old order for every subject the old order produced
    // within contract.
    let single_line: String = sentence
        .chars()
        .map(|c| if c == '\r' || c == '\n' { ' ' } else { c })
        .collect();

    // Cap at 120 Unicode scalar values. For ASCII content this matches Swift's
    // String.prefix(120) (extended grapheme clusters == scalars for ASCII).
    // Trim again: the cap can land immediately after a space, and the row
    // renderer never trims.
    let capped: String = single_line.trim().chars().take(120).collect();
    capped.trim().to_string()
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — conformance-gated against subject_vectors.json
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use std::fs;
    use std::path::PathBuf;

    // ─── Inline unit tests ────────────────────────────────────────────────────

    #[test]
    fn period_space_is_boundary() {
        assert_eq!(
            deterministic_subject("Harrow count survey north zone result: 12. Field crew verified the total."),
            "Harrow count survey north zone result: 12."
        );
    }

    #[test]
    fn question_mark_space_is_boundary() {
        assert_eq!(
            deterministic_subject("What did the Harrow count survey record for the north zone? The answer was 12."),
            "What did the Harrow count survey record for the north zone?"
        );
    }

    #[test]
    fn exclamation_space_is_boundary() {
        assert_eq!(
            deterministic_subject("Batch B14 lab test output: 74 units! Technician sign-off on file."),
            "Batch B14 lab test output: 74 units!"
        );
    }

    #[test]
    fn no_boundary_short() {
        assert_eq!(
            deterministic_subject("user: Hello world how are you"),
            "user: Hello world how are you"
        );
    }

    #[test]
    fn no_boundary_long_truncates_at_120() {
        let input: String = "abcdefghij".repeat(13); // 130 chars
        let result = deterministic_subject(&input);
        let expected: String = "abcdefghij".repeat(12); // 120 chars
        assert_eq!(result, expected);
        assert_eq!(result.chars().count(), 120);
    }

    #[test]
    fn decimal_point_not_boundary() {
        assert_eq!(
            deterministic_subject("  Station S-7 log: reading 1.8 m/s at 0800.  More info."),
            "Station S-7 log: reading 1.8 m/s at 0800."
        );
    }

    #[test]
    fn empty_string() {
        assert_eq!(deterministic_subject(""), "");
    }

    #[test]
    fn whitespace_only() {
        assert_eq!(deterministic_subject("   \t\n  "), "");
    }

    #[test]
    fn leading_trailing_whitespace_stripped() {
        assert_eq!(deterministic_subject("  trimmed content. more."), "trimmed content.");
    }

    #[test]
    fn boundary_at_end_of_string() {
        assert_eq!(deterministic_subject("Only one sentence."), "Only one sentence.");
    }

    #[test]
    fn period_followed_by_newline_is_boundary() {
        assert_eq!(
            deterministic_subject("First sentence.\nSecond sentence."),
            "First sentence."
        );
    }

    // ─── Conformance vector tests ─────────────────────────────────────────────

    #[derive(Deserialize)]
    struct VectorFile {
        cases: Vec<VectorCase>,
    }

    #[derive(Deserialize)]
    struct VectorCase {
        id: String,
        input: String,
        expected: String,
    }

    /// Returns the path to `benchmarks/conformance/` by walking up
    /// from this source file's directory (rust/src/) three levels.
    fn conformance_path(filename: &str) -> PathBuf {
        // file!() = rust/src/subject_generator.rs (relative to crate root)
        // The crate root is benchmarks/rust/
        let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        manifest
            .parent() // benchmarks/
            .expect("mcp-benchmarker dir")
            .join("conformance")
            .join(filename)
    }

    #[test]
    fn conformance_vectors_all_pass() {
        let path = conformance_path("subject_vectors.json");
        let data = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("cannot read {}: {}", path.display(), e));
        let file: VectorFile = serde_json::from_str(&data)
            .unwrap_or_else(|e| panic!("cannot parse subject_vectors.json: {}", e));

        for case in &file.cases {
            let got = deterministic_subject(&case.input);
            assert_eq!(
                got, case.expected,
                "case '{}': input={:?}",
                case.id,
                &case.input[..case.input.len().min(60)]
            );
        }
    }
}
