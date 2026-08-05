// SubjectRegister.swift
//
// The AI-facing register contract as a testable artifact (PR-09).
// Every subject producer — the filing/backfill AI (ai-v1), the miniLLM
// rider (minillm-v1), the deterministic writers (consolidation-v1,
// seed-v1) — validates its output here before writing, so the register
// is enforced by ONE shared gate rather than restated per producer.
//
// The checks are deliberately DETERMINISTIC and shallow: length cap,
// single-line, trimmed, and a small narrative-frame prefix lint. The
// register's deeper qualities (entities front-loaded, telegraphic) are
// producer guidance, not machine-checkable — pinning them here would
// turn style advice into false rejections. Conformance vectors pin the
// verdicts on both legs; model OUTPUT TEXT is never pinned (two models
// never match bytes — provenance labeling carries the truth of origin).
//
// Twin: Rust `subject_register.rs` (verdicts byte-identical on the
// shared vectors).

public enum SubjectRegister {

    /// Maximum subject length in characters — the store contract.
    public static let maxLength = DrawerStore.subjectLengthContract

    /// One violated rule. A subject may violate several at once; the
    /// validator reports all of them so a producer can fix in one pass.
    public enum Violation: Equatable, Sendable {
        /// Empty (or whitespace-only) subject. Absence is spelled NULL,
        /// never "".
        case empty
        /// Over the character cap (payload: actual count).
        case tooLong(Int)
        /// Contains a newline — the dense row is one line by contract.
        case multiline
        /// Leading/trailing whitespace — the row renderer never trims.
        case untrimmed
        /// Starts with a narrative frame (payload: the matched prefix).
        /// A subject states the claim, it does not introduce itself.
        case narrativeFrame(String)
    }

    /// Narrative-frame prefixes (lowercased comparison). Kept SHORT and
    /// unambiguous — this is a lint, not a language model. Twin: Rust
    /// `NARRATIVE_FRAME_PREFIXES` (identical list, identical order).
    public static let narrativeFramePrefixes: [String] = [
        "this memory ",
        "this is a ",
        "a note about ",
        "note: ",
        "a memory about ",
        "the user said ",
    ]

    /// Validate a candidate subject against the register contract.
    /// Empty array = admissible.
    public static func violations(_ subject: String) -> [Violation] {
        var out: [Violation] = []
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty dominates: nothing else is meaningful on "".
            return [.empty]
        }
        if subject != trimmed {
            out.append(.untrimmed)
        }
        if subject.contains("\n") || subject.contains("\r") {
            out.append(.multiline)
        }
        if subject.count > maxLength {
            out.append(.tooLong(subject.count))
        }
        let lowered = trimmed.lowercased()
        for prefix in narrativeFramePrefixes where lowered.hasPrefix(prefix) {
            out.append(.narrativeFrame(prefix))
            break
        }
        return out
    }
}
