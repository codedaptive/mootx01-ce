import Testing
@testable import ContextDistillLib

@Test func selectionBudgetPreservesOversizedSource() {
    let source = String(repeating: "é", count: 16385)
    let result = intentSpan(source, trailer: "", peerDialogue: true, bounded: true)
    #expect(result.core == source)
    #expect(result.selectionDetails["unsupported_shapes"] as? [String] == ["source-byte-budget"])
}

@Test func selectionBudgetPreservesManyAtoms() {
    let source = (0..<600).map { "- Item \($0) contains evidence." }.joined(separator: "\n")
    let result = intentSpan(source, trailer: "", peerDialogue: true, bounded: true)
    #expect(result.core == source)
    #expect(result.selectionDetails["unsupported_shapes"] as? [String] == ["atom-budget"])
    #expect(intentSpan(source, trailer: "", peerDialogue: true, bounded: true).core == result.core)
}

@Test func selectionWorkBudgetPreservesSource() {
    let source = (0..<250).map { "Unique item \($0) describes orchard storage." }.joined(separator: "\n")
    let result = intentSpan(source, trailer: "", peerDialogue: true, bounded: true)
    #expect(result.core == source)
    #expect(result.selectionDetails["unsupported_shapes"] as? [String] == ["selector-work-budget"])
}
