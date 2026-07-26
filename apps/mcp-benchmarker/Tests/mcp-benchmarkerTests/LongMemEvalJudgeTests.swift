import Testing
import Foundation
@testable import mcp_benchmarker

// LongMemEvalJudgeTests.swift — Unit tests for LongMemEvalJudge.swift.
//
// Tests cover three surfaces:
//   1. lmeJudgePrompt: prompt format includes question and payload verbatim.
//   2. lmeGradeJudgeAnswer: deterministic normalized-substring grading.
//   3. lmeRunJudge: subprocess invocation via stub shell commands.
//
// Stub strategy for lmeRunJudge:
//   - /bin/echo <arg>: outputs its argument (ignores stdin); fast, always available.
//   - /bin/cat: reads stdin and echoes it; verifies prompt reaches the process.
//   - /bin/sh -c 'exit 1': verifies non-zero exit throws MCPError.
//
// These are unit tests (no live MCP product): they verify the judge hook
// mechanics independently of any specific AI judge binary.

// MARK: - Prompt format

@Suite("LME judge: prompt formatting")
struct LMEJudgePromptTests {

    @Test("prompt includes the question verbatim")
    func promptIncludesQuestion() {
        let p = lmeJudgePrompt(question: "What is the capital of France?",
                               payload: "France is a country in Europe.")
        #expect(p.contains("What is the capital of France?"))
    }

    @Test("prompt includes the payload verbatim")
    func promptIncludesPayload() {
        let p = lmeJudgePrompt(question: "Who wrote it?",
                               payload: "Alice wrote the report.")
        #expect(p.contains("Alice wrote the report."))
    }

    @Test("prompt ends with 'Answer:' cue")
    func promptEndsWithAnswerCue() {
        let p = lmeJudgePrompt(question: "Q?", payload: "P.")
        // The judge reads the prompt and writes after the "Answer:" cue.
        #expect(p.contains("Answer:"))
    }
}

// MARK: - Answer grading

@Suite("LME judge: answer grading")
struct LMEJudgeGradingTests {

    @Test("exact match grades true")
    func exactMatch() {
        #expect(lmeGradeJudgeAnswer("Paris", goldAnswer: "Paris"))
    }

    @Test("case-insensitive match grades true")
    func caseInsensitive() {
        #expect(lmeGradeJudgeAnswer("paris", goldAnswer: "Paris"))
    }

    @Test("gold substring of judge answer grades true")
    func goldSubstringOfJudge() {
        #expect(lmeGradeJudgeAnswer("The answer is Paris.", goldAnswer: "Paris"))
    }

    @Test("judge answer not containing gold grades false")
    func judgeDoesNotContainGold() {
        #expect(!lmeGradeJudgeAnswer("Berlin", goldAnswer: "Paris"))
    }

    @Test("empty gold answer grades false")
    func emptyGold() {
        #expect(!lmeGradeJudgeAnswer("Berlin", goldAnswer: ""))
    }

    @Test("empty judge answer grades false")
    func emptyJudge() {
        #expect(!lmeGradeJudgeAnswer("", goldAnswer: "Paris"))
    }

    @Test("both empty grades false")
    func bothEmpty() {
        #expect(!lmeGradeJudgeAnswer("", goldAnswer: ""))
    }

    @Test("whitespace-only judge answer grades false")
    func whitespaceJudge() {
        // Normalizes to empty after trimming.
        #expect(!lmeGradeJudgeAnswer("   ", goldAnswer: "Paris"))
    }

    @Test("gold with numeric content grades correctly")
    func numericGold() {
        // Oracle variant answers can be numbers.
        #expect(lmeGradeJudgeAnswer("The count is 3.", goldAnswer: "3"))
        #expect(!lmeGradeJudgeAnswer("The count is 4.", goldAnswer: "3"))
    }

    @Test("normalization collapses whitespace before matching")
    func whitespaceCollapse() {
        // "New  York" in judge, "New York" in gold — should match after normalization.
        #expect(lmeGradeJudgeAnswer("New  York City", goldAnswer: "New York"))
    }
}

// MARK: - Subprocess runner

@Suite("LME judge: subprocess runner")
struct LMEJudgeRunnerTests {

    @Test("/bin/echo returns its argument trimmed")
    func echoCommand() throws {
        // /bin/echo ignores stdin and prints its argument; exits 0.
        let result = try lmeRunJudge(cmd: "/bin/echo hello-world", prompt: "ignored")
        #expect(result == "hello-world")
    }

    @Test("/bin/cat returns the stdin prompt trimmed")
    func catReadsStin() throws {
        // /bin/cat reads stdin and echoes it.
        let result = try lmeRunJudge(cmd: "/bin/cat", prompt: "test-prompt-value")
        #expect(result == "test-prompt-value")
    }

    @Test("non-zero exit throws MCPError")
    func nonZeroExitThrows() {
        // Should throw — the process exits 1.
        var thrown = false
        do {
            _ = try lmeRunJudge(cmd: "/bin/sh -c 'exit 1'", prompt: "prompt")
        } catch {
            thrown = true
        }
        #expect(thrown, "lmeRunJudge should throw on non-zero exit")
    }

    @Test("multiline prompt reaches stdin intact")
    func multilinePrompt() throws {
        // printf reads nothing from stdin; we use a here-string approach via
        // /bin/cat to verify multiline prompts survive the pipe.
        let multiline = "line one\nline two\nline three"
        let result = try lmeRunJudge(cmd: "/bin/cat", prompt: multiline)
        // Trimming: the result should have the first and last lines intact.
        #expect(result.contains("line one"))
        #expect(result.contains("line three"))
    }
}
