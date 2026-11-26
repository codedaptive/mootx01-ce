// subject_inadmissible_reason.rs — the refusal reason for a subject-backfill
// answer that is still inadmissible after `subject_cut_to_contract`.
//
// The reason is stored in the drawer's audit trail (the `subjectRefused`
// event), so it must match the Swift port's `subjectInadmissibleReason` byte
// for byte. Each violation is spelled by hand in Swift's camelCase rather than
// with `{:?}`, which would give `NarrativeFrame(...)`.

use locus_kit::subject_register::SubjectViolation;

/// `inadmissible: ` followed by the violations, in order, joined with `, `.
pub(crate) fn subject_inadmissible_reason(violations: &[SubjectViolation]) -> String {
    let rendered: Vec<String> = violations
        .iter()
        .map(|violation| match violation {
            SubjectViolation::Empty => "empty".to_string(),
            SubjectViolation::TooLong(count) => format!("tooLong({count})"),
            SubjectViolation::Multiline => "multiline".to_string(),
            SubjectViolation::Untrimmed => "untrimmed".to_string(),
            SubjectViolation::NarrativeFrame(prefix) => format!("narrativeFrame(\"{prefix}\")"),
        })
        .collect();
    format!("inadmissible: {}", rendered.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subject_inadmissible_reason_spells_each_violation_as_swift_does() {
        let cases: [(&[SubjectViolation], &str); 3] = [
            (&[SubjectViolation::NarrativeFrame("this is a ")], "inadmissible: narrativeFrame(\"this is a \")"),
            (
                &[SubjectViolation::Untrimmed, SubjectViolation::Multiline, SubjectViolation::TooLong(130)],
                "inadmissible: untrimmed, multiline, tooLong(130)",
            ),
            (&[SubjectViolation::Empty], "inadmissible: empty"),
        ];
        for (violations, expected) in cases {
            assert_eq!(subject_inadmissible_reason(violations), expected, "violations {violations:?}");
        }
    }
}
