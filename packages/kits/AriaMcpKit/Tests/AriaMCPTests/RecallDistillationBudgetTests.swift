import Testing
@testable import AriaMCP

@Test func recallDistillationLargeBatchPreservesCompleteEvidence() {
    let source = String(repeating: "Unique evidence must not disappear.\n", count: 10_000)
    for _ in 0..<50 { #expect(RecallDistillation.render(source) == source) }
}

@Test func recallDistillationAtomBudgetPreservesWhitespaceToo() {
    let source = "\n  " + (0..<600).map { "- Item \($0) contains evidence." }.joined(separator: "\n") + "\n  "
    #expect(RecallDistillation.render(source) == source)
}
