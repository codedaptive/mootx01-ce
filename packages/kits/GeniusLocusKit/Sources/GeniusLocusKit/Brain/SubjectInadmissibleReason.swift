// SubjectInadmissibleReason.swift
//
// The refusal reason the subject-backfill sweep stores when a producer's
// answer still breaks `SubjectRegister` after the cut. The reason lands in
// the audit trail and must match the Rust port's `subject_inadmissible_reason`
// byte for byte, so each violation's rendering is spelled out here rather
// than left to Swift's default description of the enum.

import LocusKit

extension GeniusLocusKit {

    /// `inadmissible: ` followed by `violations` joined with `, `, each as
    /// `empty`, `tooLong(<n>)`, `multiline`, `untrimmed` or
    /// `narrativeFrame("<prefix>")` (the prefix verbatim).
    static func subjectInadmissibleReason(_ violations: [SubjectRegister.Violation]) -> String {
        "inadmissible: " + violations.map { violation in
            switch violation {
            case .empty: "empty"
            case .tooLong(let count): "tooLong(\(count))"
            case .multiline: "multiline"
            case .untrimmed: "untrimmed"
            case .narrativeFrame(let prefix): "narrativeFrame(\"\(prefix)\")"
            }
        }.joined(separator: ", ")
    }
}
