import Testing
import Foundation
@testable import ContextDistillLib

private func scalarCount(_ text: String) -> Int { text.unicodeScalars.count }

private struct ReferenceExpansionVector: Decodable {
    let definition_bytes: Int
    let repeat_count: Int
    let error_code: String
    let error_message: String
    let max_bytes: Int
    let max_ratio: Int
}

@Test func completeReferenceExpansionIsBoundedBySharedSettingsVector() throws {
    let url = try #require(Bundle.module.url(forResource: "reference-expansion-limits", withExtension: "json", subdirectory: "Vectors"))
    let vector = try JSONDecoder().decode(ReferenceExpansionVector.self, from: Data(contentsOf: url))
    let definition = String(repeating: "x", count: vector.definition_bytes) + "\n"
    let body = "[[TSREF:1 DEFINE]] " + definition
        + String(repeating: "[[TSREF:1 REPEAT]]\n", count: vector.repeat_count)
    let source = CompleteText.notice + CompleteText.refLegend + body

    let result = try CompleteContentReducer.distill(source, count: scalarCount)

    #expect(result.text == source)
    #expect(result.referenceExpansionError?.code == vector.error_code)
    #expect(result.referenceExpansionError?.message == vector.error_message)
    #expect(result.referenceExpansionError?.maxBytes == vector.max_bytes)
    #expect(result.referenceExpansionError?.maxRatio == vector.max_ratio)
    #expect(result.referenceExpansionError?.attemptedBytes ?? 0 <= vector.max_bytes + vector.definition_bytes)
    #expect(!result.visibleRefs)
}

@Test func completePythonGoldenParity() throws {
    struct Fixture: Decodable { let vectors: [Vector] }
    struct Vector: Decodable {
        let name: String, counter: String, source: String, text: String, version: String
        let source_sha256: String, representation_sha256: String
        let visible_refs: Bool
        let original_tokens: Int, output_tokens: Int
    }
    let url = try #require(Bundle.module.url(forResource: "complete-form-v6", withExtension: "json", subdirectory: "Vectors"))
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    for vector in fixture.vectors {
        let count: (String) -> Int = { text in
            vector.counter == "utf8" ? text.utf8.count : estimateTokens(text)
        }
        let result = try CompleteContentReducer.distill(vector.source, count: count)
        #expect(result.text.utf8.elementsEqual(vector.text.utf8), "\(vector.name) / \(vector.counter)")
        #expect(result.version == vector.version)
        #expect(result.sourceSHA256 == vector.source_sha256)
        #expect(result.representationSHA256 == vector.representation_sha256, "\(vector.name) / \(vector.counter)")
        #expect(result.visibleRefs == vector.visible_refs)
        #expect(result.originalTokens == vector.original_tokens)
        #expect(result.outputTokens == vector.output_tokens, "\(vector.name) / \(vector.counter)")
    }
}

@Test func completeUnsupportedPreservesExactText() throws {
    for text in ["", "Nora may arrive tomorrow, unless the train is cancelled.\r\n", "{\"a\":1.0}", "{\"a\":-0}", "{\"a\":1,\"a\":2}", "  ```json\n{ \"a\": 1 }\n  ```\n"] {
        let result = try CompleteContentReducer.distill(text, count: scalarCount)
        #expect(result.text == text)
        #expect(result.sourceSHA256 == result.representationSHA256)
        #expect(result.originalTokens == scalarCount(text))
        #expect(!result.qualityQualified && !result.modelAssistance)
    }
}

@Test func completeVisibleReferencesRemainBoundToEntries() throws {
    let line = "- [[001-long-linked-entry-name]] - low - " + String(repeating: "Complete qualified description ", count: 5) + "\n"
    let source = "# Index\n\n" + (0..<20).map { "## `file\($0)`\n\n" + line + "\n" }.joined()
    let result = try CompleteContentReducer.distill(source, count: scalarCount)
    #expect(result.visibleRefs)
    #expect(result.text.contains("entry 001: [[TSREF:1 REPEAT]]\n"))
    let limits = CompleteText.ExpansionLimits(maxBytes: 8_388_608, maxRatio: 64)
    #expect(try CompleteText.expandVisible(result.text, limits: limits).text == source)
    #expect(try CompleteContentReducer.distill(result.text, count: scalarCount).text == result.text)
    #expect(result.outputTokens < result.originalTokens)
    let corrupt = result.text.replacingOccurrences(of: "entry 001:", with: "entry 002:")
    #expect(throws: CompleteContentError.self) { try CompleteContentReducer.distill(corrupt, count: scalarCount) }
}

@Test func completeClocksRequireEntireMonotonicTranscript() {
    let source = "Title\n## Transcript\n" + (0..<50).map { "[00:\(String(format: "%02d", $0))] Spoken segment.\n" }.joined()
    let reduced = CompleteText.clocks(source, count: scalarCount)
    #expect(reduced.contains("0 Spoken segment.\n"))
    #expect(reduced.contains("49 Spoken segment.\n"))
    #expect(CompleteText.clocks(source + "No clock\n", count: scalarCount) == source + "No clock\n")
    #expect(CompleteText.clocks(source + "[00:00] Earlier\n", count: scalarCount) == source + "[00:00] Earlier\n")
    #expect(CompleteText.clocks(source, count: { _ in 1 }) == source)
}

@Test func completeTimestampFactoringKeepsFencesAndOrder() throws {
    let source = (0..<30).map { "2026-09-08T10:\(String(format: "%02d", $0)) (Bob in a long named channel) — message \($0)\n" }.joined()
        + "```\n2026-09-08T10:01 (Bob in a long named channel) — unchanged\n```\n"
    let result = try CompleteContentReducer.distill(source, count: scalarCount)
    #expect(result.text.hasPrefix(CompleteText.timestampIntro))
    #expect(result.text.contains("[T1 10:29] message 29\n"))
    #expect(result.text.contains("```\n2026-09-08T10:01 (Bob in a long named channel) — unchanged\n```"))
    #expect(try CompleteContentReducer.distill(result.text, count: scalarCount).text == result.text)
}
