// SubjectInadmissibleReasonTests.swift
//
// The stored refusal reason for a register-rejected subject answer; the
// expected strings are the contract's literals, shared with the Rust port.

import Testing
import LocusKit
@testable import GeniusLocusKit

struct SubjectInadmissibleReasonTests {

    @Test(arguments: [
        ([SubjectRegister.Violation.narrativeFrame("this is a ")], #"inadmissible: narrativeFrame("this is a ")"#),
        ([.untrimmed, .multiline, .tooLong(130)], "inadmissible: untrimmed, multiline, tooLong(130)"),
        ([.empty], "inadmissible: empty"),
    ])
    func subjectInadmissibleReason(violations: [SubjectRegister.Violation], expected: String) {
        #expect(GeniusLocusKit.subjectInadmissibleReason(violations) == expected)
    }
}
