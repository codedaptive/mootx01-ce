#if canImport(CoreML)
import Foundation
import Testing
@testable import CorpusKitProviders

@Suite("CoreML span inference input shapes")
struct CoreMLSpanInferenceTests {
    @Test("single enumerated shape is fixed; multiple shapes remain flexible")
    func enumeratedShapeClassification() {
        #expect(CoreMLSpanInference.fixedSequenceLength(
            enumeratedShapes: [[1, 512]]) == 512)
        #expect(CoreMLSpanInference.fixedSequenceLength(
            enumeratedShapes: [[1, 128], [1, 512]]) == nil)
    }

    @Test("singleton ranges are fixed; a sequence range remains flexible")
    func rangeShapeClassification() {
        #expect(CoreMLSpanInference.fixedSequenceLength(
            sizeRanges: [NSRange(location: 1, length: 1), NSRange(location: 512, length: 1)]) == 512)
        #expect(CoreMLSpanInference.fixedSequenceLength(
            sizeRanges: [NSRange(location: 1, length: 1), NSRange(location: 1, length: 512)]) == nil)
    }

    @Test("fixed 512 input pads ids and masks padding")
    func fixedInputPaddingAndAttentionMask() {
        let prepared = CoreMLSpanInference.prepareInputs(
            tokenIDs: [101, 202, 102], padTokenID: 0, fixedLength: 512)

        #expect(prepared.ids.count == 512)
        #expect(Array(prepared.ids.prefix(3)) == [101, 202, 102])
        #expect(prepared.ids.dropFirst(3).allSatisfy { $0 == 0 })
        #expect(Array(prepared.attentionMask.prefix(3)) == [1, 1, 1])
        #expect(prepared.attentionMask.dropFirst(3).allSatisfy { $0 == 0 })
        #expect(prepared.tokenTypeIDs.allSatisfy { $0 == 0 })
    }

    @Test("fixed input truncates and flexible input preserves real length")
    func truncationAndFlexibleInput() {
        let truncated = CoreMLSpanInference.prepareInputs(
            tokenIDs: [101, 11, 12, 102], padTokenID: 0, fixedLength: 3)
        #expect(truncated.ids == [101, 11, 12])
        #expect(truncated.attentionMask == [1, 1, 1])

        let flexible = CoreMLSpanInference.prepareInputs(
            tokenIDs: [101, 202, 102], padTokenID: 0, fixedLength: nil)
        #expect(flexible.ids == [101, 202, 102])
        #expect(flexible.attentionMask == [1, 1, 1])
    }
}
#endif
