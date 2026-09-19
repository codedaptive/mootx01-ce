import Testing
import Foundation
@testable import mcp_benchmarker

// SubjectGeneratorTests.swift — conformance-gated coverage for the canonical
// deterministicSubject algorithm. Every inline case here is also pinned as a
// conformance vector in conformance/subject_vectors.json so that the Rust twin
// (subject_generator.rs) is validated against the same expected outputs.

// MARK: - Fixture path helper (mirrors ConformanceVectorTests.swift)

/// Resolves the path to `benchmarks/conformance/<filename>.json`
/// from this test file's location.
private func conformancePath(_ name: String, file: String = #filePath) -> URL? {
    let url = URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("conformance")
        .appendingPathComponent(name + ".json")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

// MARK: - Decodable conformance file structures

private struct SubjectVectorFile: Decodable {
    let cases: [SubjectVectorCase]
}

private struct SubjectVectorCase: Decodable {
    let id: String
    let input: String
    let expected: String
}

// MARK: - Tests

@Suite struct SubjectGeneratorTests {

    // MARK: Sentence boundary detection

    @Test("Period followed by space yields first sentence")
    func periodSpace() {
        let result = deterministicSubject("Harrow count survey north zone result: 12. Field crew verified the total.")
        #expect(result == "Harrow count survey north zone result: 12.")
    }

    @Test("Question mark followed by space yields first sentence")
    func questionMark() {
        let result = deterministicSubject("What did the Harrow count survey record for the north zone? The answer was 12.")
        #expect(result == "What did the Harrow count survey record for the north zone?")
    }

    @Test("Exclamation mark followed by space yields first sentence")
    func exclamationMark() {
        let result = deterministicSubject("Batch B14 lab test output: 74 units! Technician sign-off on file.")
        #expect(result == "Batch B14 lab test output: 74 units!")
    }

    @Test("No sentence boundary — entire content is returned")
    func noBoundaryShort() {
        let result = deterministicSubject("user: Hello world how are you")
        #expect(result == "user: Hello world how are you")
    }

    @Test("No boundary with content exceeding 120 chars — truncated to 120")
    func noBoundaryLong() {
        // 130 characters, no sentence-ending punctuation followed by whitespace.
        let input = String(repeating: "abcdefghij", count: 13)
        #expect(input.count == 130)
        let result = deterministicSubject(input)
        let expected = String(repeating: "abcdefghij", count: 12)  // 120 chars
        #expect(result == expected)
        #expect(result.count == 120)
    }

    @Test("Decimal point (period followed by digit) is not a sentence boundary")
    func decimalPoint() {
        // Trimmed: "Station S-7 log: reading 1.8 m/s at 0800.  More info."
        // Period after "1" at "1.8" → next char is '8' (digit) → NOT a boundary.
        // Period after "0800" → next char is ' ' (space) → boundary.
        let result = deterministicSubject("  Station S-7 log: reading 1.8 m/s at 0800.  More info.")
        #expect(result == "Station S-7 log: reading 1.8 m/s at 0800.")
    }

    @Test("Empty input returns empty string")
    func emptyInput() {
        #expect(deterministicSubject("") == "")
    }

    @Test("Whitespace-only input returns empty string")
    func whitespaceOnly() {
        #expect(deterministicSubject("   \t\n  ") == "")
    }

    @Test("Leading and trailing whitespace stripped before extraction")
    func leadingTrailingWhitespace() {
        let result = deterministicSubject("  trimmed content. more.")
        #expect(result == "trimmed content.")
    }

    @Test("Sentence boundary at end of string")
    func boundaryAtEnd() {
        let result = deterministicSubject("Only one sentence.")
        #expect(result == "Only one sentence.")
    }

    @Test("Period followed by newline is a sentence boundary")
    func periodNewline() {
        let result = deterministicSubject("First sentence.\nSecond sentence.")
        #expect(result == "First sentence.")
    }

    // MARK: Conformance vector cross-check

    @Test("Conformance vectors from subject_vectors.json all pass")
    func conformanceVectors() throws {
        let url = try #require(
            conformancePath("subject_vectors"),
            "conformance/subject_vectors.json not found — run from mcp-benchmarker package root"
        )
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(SubjectVectorFile.self, from: data)
        for v in file.cases {
            let got = deterministicSubject(v.input)
            #expect(
                got == v.expected,
                "case '\(v.id)': input=\(v.input.prefix(60).debugDescription), got=\(got.debugDescription)"
            )
        }
    }
}
