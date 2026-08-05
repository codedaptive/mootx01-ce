//! The AI-facing register contract as a testable artifact (PR-09).
//! Every subject producer validates its output here before writing, so
//! the register is enforced by ONE shared gate. Checks are deliberately
//! DETERMINISTIC and shallow: length cap, single-line, trimmed, and a
//! small narrative-frame prefix lint — deeper register qualities are
//! producer guidance, not machine-checkable. Conformance vectors pin the
//! verdicts on both legs; model OUTPUT TEXT is never pinned (two models
//! never match bytes — provenance labeling carries the truth of origin).
//!
//! Twin of Swift `SubjectRegister.swift` (verdicts byte-identical on the
//! shared vectors).

use crate::drawer_store::SUBJECT_LENGTH_CONTRACT;

/// One violated rule. A subject may violate several at once; the
/// validator reports all of them so a producer can fix in one pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubjectViolation {
    /// Empty (or whitespace-only) subject. Absence is spelled NULL, never "".
    Empty,
    /// Over the character cap (payload: actual count).
    TooLong(usize),
    /// Contains a newline — the dense row is one line by contract.
    Multiline,
    /// Leading/trailing whitespace — the row renderer never trims.
    Untrimmed,
    /// Starts with a narrative frame (payload: the matched prefix).
    /// A subject states the claim, it does not introduce itself.
    NarrativeFrame(&'static str),
}

/// Narrative-frame prefixes (lowercased comparison). Kept SHORT and
/// unambiguous — this is a lint, not a language model. Twin: Swift
/// `SubjectRegister.narrativeFramePrefixes` (identical list and order).
pub const NARRATIVE_FRAME_PREFIXES: [&str; 6] = [
    "this memory ",
    "this is a ",
    "a note about ",
    "note: ",
    "a memory about ",
    "the user said ",
];

/// Validate a candidate subject against the register contract.
/// Empty vec = admissible. Mirrors Swift `SubjectRegister.violations`.
pub fn violations(subject: &str) -> Vec<SubjectViolation> {
    let mut out = Vec::new();
    let trimmed = subject.trim();
    if trimmed.is_empty() {
        // Empty dominates: nothing else is meaningful on "".
        return vec![SubjectViolation::Empty];
    }
    if subject != trimmed {
        out.push(SubjectViolation::Untrimmed);
    }
    if subject.contains('\n') || subject.contains('\r') {
        out.push(SubjectViolation::Multiline);
    }
    let n = subject.chars().count();
    if n > SUBJECT_LENGTH_CONTRACT {
        out.push(SubjectViolation::TooLong(n));
    }
    let lowered = trimmed.to_lowercase();
    for prefix in NARRATIVE_FRAME_PREFIXES {
        if lowered.starts_with(prefix) {
            out.push(SubjectViolation::NarrativeFrame(prefix));
            break;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Conformance vectors — identical cases and expected verdicts in
    /// Swift `SubjectRegisterTests`. Verdicts only; never model text.
    #[test]
    fn register_conformance_vectors() {
        assert!(violations("Quarterly planning moved to Thursday; Sarah sends invites Monday.").is_empty());
        assert_eq!(violations(""), vec![SubjectViolation::Empty]);
        assert_eq!(violations("   "), vec![SubjectViolation::Empty]);
        assert_eq!(violations(" leading space subject."), vec![SubjectViolation::Untrimmed]);
        assert_eq!(
            violations("line one\nline two"),
            vec![SubjectViolation::Multiline]
        );
        let long = "x".repeat(121);
        assert_eq!(violations(&long), vec![SubjectViolation::TooLong(121)]);
        assert_eq!(
            violations("This is a note about the meeting."),
            vec![SubjectViolation::NarrativeFrame("this is a ")]
        );
        assert_eq!(
            violations("Note: deploy gate changed."),
            vec![SubjectViolation::NarrativeFrame("note: ")]
        );
        // Compound: untrimmed + narrative frame.
        assert_eq!(
            violations(" The user said the gate moved. "),
            vec![
                SubjectViolation::Untrimmed,
                SubjectViolation::NarrativeFrame("the user said "),
            ]
        );
        // Exactly at the cap: admissible.
        let exact = "y".repeat(120);
        assert!(violations(&exact).is_empty());
    }
}
