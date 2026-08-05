// SubjectRegisterTests.swift
//
// Conformance vectors for the AI-facing register contract (PR-09) —
// identical cases and expected verdicts in Rust
// `subject_register.rs::register_conformance_vectors`. Verdicts only;
// model output text is never pinned.

import Testing
@testable import LocusKit

@Suite("Subject register — conformance vectors")
struct SubjectRegisterTests {

    @Test func registerConformanceVectors() {
        #expect(SubjectRegister.violations(
            "Quarterly planning moved to Thursday; Sarah sends invites Monday.").isEmpty)
        #expect(SubjectRegister.violations("") == [.empty])
        #expect(SubjectRegister.violations("   ") == [.empty])
        #expect(SubjectRegister.violations(" leading space subject.") == [.untrimmed])
        #expect(SubjectRegister.violations("line one\nline two") == [.multiline])
        let long = String(repeating: "x", count: 121)
        #expect(SubjectRegister.violations(long) == [.tooLong(121)])
        #expect(SubjectRegister.violations("This is a note about the meeting.")
                == [.narrativeFrame("this is a ")])
        #expect(SubjectRegister.violations("Note: deploy gate changed.")
                == [.narrativeFrame("note: ")])
        // Compound: untrimmed + narrative frame.
        #expect(SubjectRegister.violations(" The user said the gate moved. ")
                == [.untrimmed, .narrativeFrame("the user said ")])
        // Exactly at the cap: admissible.
        let exact = String(repeating: "y", count: 120)
        #expect(SubjectRegister.violations(exact).isEmpty)
    }
}
