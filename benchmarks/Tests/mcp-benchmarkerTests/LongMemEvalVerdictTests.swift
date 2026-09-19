import XCTest
@testable import mcp_benchmarker

/// Verdict parsing and answer-accuracy aggregation — the path that makes a
/// judged cell comparable to a published one.
final class LongMemEvalVerdictTests: XCTestCase {

    // MARK: - Verdict parsing

    func test_parsesBareVerdicts() {
        XCTAssertEqual(lmeParseVerdict("CORRECT"), true)
        XCTAssertEqual(lmeParseVerdict("INCORRECT"), false)
    }

    func test_parsingIsCaseInsensitiveAndWhitespaceTolerant() {
        XCTAssertEqual(lmeParseVerdict("  correct \n"), true)
        XCTAssertEqual(lmeParseVerdict("\nIncorrect"), false)
    }

    /// The substring trap: "INCORRECT" contains "CORRECT". Any parser that
    /// looks for "CORRECT" inside the reply grades every INCORRECT as correct
    /// — the single most damaging way this function could fail, so it is
    /// pinned. Matching the verdict token exactly is what rules it out.
    /// The second case reads from slot 2 (the echoed "Verdict:" label).
    func test_incorrectIsNotReadAsCorrect() {
        XCTAssertEqual(lmeParseVerdict("INCORRECT"), false)
        XCTAssertEqual(lmeParseVerdict("The verdict is: INCORRECT"), false)
    }

    /// A chatty judge that uses both words: the verdict is the one in slot 1,
    /// the reply's first token. The other occurrence is prose and is never
    /// consulted — position decides, not order of appearance.
    func test_chattyReplyIsReadFromItsFirstToken() {
        XCTAssertEqual(lmeParseVerdict("CORRECT — it would be INCORRECT to say otherwise"), true)
        XCTAssertEqual(lmeParseVerdict("INCORRECT, the CORRECT answer is Paris"), false)
    }

    /// Neither word present is a judge failure, not a wrong answer. Returning
    /// nil lets the caller fall back rather than silently scoring zero.
    func test_unparseableReturnsNil() {
        XCTAssertNil(lmeParseVerdict("I'm not sure"))
        XCTAssertNil(lmeParseVerdict(""))
    }

    /// REGRESSION (MXE-BK defect 1). A negated reply contains "CORRECT" as a
    /// substring, so the previous scan-the-whole-string parser returned true
    /// for every one of these and inflated answer accuracy. None of them may
    /// ever grade as correct again.
    ///
    /// Against pre-fix code all three returned `true`; they now return nil —
    /// the verdict is not in either slot, so the caller falls back to
    /// substring grading instead of banking a correct answer it never got.
    func test_negatedRepliesNeverGradeAsCorrect() {
        for reply in ["not correct", "not exactly correct", "this is not correct"] {
            XCTAssertNotEqual(lmeParseVerdict(reply), true,
                              "negated reply \"\(reply)\" must never grade as correct")
            XCTAssertNil(lmeParseVerdict(reply),
                         "negated reply \"\(reply)\" is unparseable, not a wrong answer")
        }
    }

    /// The parser is positional, NOT a negation blocklist. A blocklist would
    /// have to resolve "not incorrect" as a double negative and return true;
    /// this parser returns nil, because the verdict is simply not in either
    /// slot. That difference is the whole point: sentiment is never read, so
    /// there is no phrasing-enumeration to get wrong.
    func test_positionalParsingIsNotANegationBlocklist() {
        XCTAssertNil(lmeParseVerdict("not incorrect"))
    }

    /// The two slots the prompt defines, pinned. Slot 2 exists because the
    /// prompt ends with a bare "Verdict:" label, so a judge echoing it is an
    /// expected shape rather than a failure.
    func test_verdictIsReadFromEitherPositionalSlot() {
        // Slot 1: the reply is the word, with markdown or punctuation on it.
        XCTAssertEqual(lmeParseVerdict("**CORRECT**"), true)
        XCTAssertEqual(lmeParseVerdict("INCORRECT."), false)
        // Slot 2: the label was echoed ahead of the verdict.
        XCTAssertEqual(lmeParseVerdict("Verdict: CORRECT"), true)
        XCTAssertEqual(lmeParseVerdict("Reasoning: it differs. Verdict: INCORRECT"), false)
        // Slot 2 does not rescue a negated verdict.
        XCTAssertNil(lmeParseVerdict("Verdict: not correct"))
    }

    /// The prompt must forbid explanation, or the positional contract above
    /// has no basis. Pinned so a future prompt edit cannot silently loosen it.
    func test_verdictPromptDemandsOneWordAndNothingElse() {
        let p = lmeVerdictPrompt(question: "q", goldAnswer: "g", candidateAnswer: "c")
        XCTAssertTrue(p.contains("exactly one word and nothing else"))
        XCTAssertTrue(p.contains("Do not explain"))
    }

    // MARK: - Verdict prompt

    func test_verdictPromptCarriesAllThreeInputs() {
        let p = lmeVerdictPrompt(question: "Where did she move?",
                                 goldAnswer: "Lisbon",
                                 candidateAnswer: "She relocated to Lisbon.")
        XCTAssertTrue(p.contains("Where did she move?"))
        XCTAssertTrue(p.contains("Lisbon"))
        XCTAssertTrue(p.contains("She relocated to Lisbon."))
        XCTAssertTrue(p.contains("CORRECT"))
    }

    // MARK: - Grading-mode divergence

    /// The reason both modes exist: substring grading rejects a
    /// semantically-correct paraphrase that a verdict judge accepts. If this
    /// ever stops being true the two modes have collapsed into one and the
    /// published-comparability claim needs re-checking.
    func test_substringGradingRejectsCorrectParaphrase() {
        XCTAssertFalse(lmeGradeJudgeAnswer("He was nineteen at the time",
                                           goldAnswer: "19"))
        XCTAssertTrue(lmeGradeJudgeAnswer("She relocated to Lisbon.",
                                          goldAnswer: "Lisbon"))
    }
}
