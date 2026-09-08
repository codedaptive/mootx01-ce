import Testing
@testable import ContextDistillLib

@Test func completeDispatchKeepsAllSourceAndTrailer() {
    let source = "Nora may arrive Tuesday, unless the train is cancelled.\nDo not remove the 12 boxes."
    let output = ContextDistiller().distill(
        DistillationInput(original: source, enrichmentTrailer: "trailer from original"),
        converter: .completeFormV6)
    #expect(output.compactCore == source)
    #expect(output.aiText == source + " trailer from original")
    #expect(output.converterID == "complete-form@complete-form-visible-v6")
    #expect(output.selectionDetails["complete"] as? Bool == true)
    #expect(output.selectionDetails["count_unit"] as? String == "tokens_estimate")
    #expect(output.selectedSourceSpans.count == 1)
    #expect(output.sourceSHA256 == sourceDigest(source))
}

@Test func completeDispatchInvalidReservedTextFallsBackUnchanged() {
    let source = "Linked repeats show their original numeric link prefix before the reference; the reference still denotes the whole original entry.\nRepeated-text notation: [[TSREF:n DEFINE]] introduces one exact line; [[TSREF:n REPEAT]] repeats that complete line at its current position.\n[[TSREF:9 REPEAT]]\n"
    let output = ContextDistiller().distill(DistillationInput(original: source), converter: .completeFormV6)
    #expect(output.aiText == source)
    #expect(output.selectionDetails["fallback_unchanged"] as? Bool == true)
}
