import Testing
import GeniusLocusKit
@testable import CognitionKit

@Suite("Text-pair savings")
struct DistilledSavingsTextTests {
    @Test func disabled() {
        #expect(DistilledSavings.text(original: "private body", reduced: "body",
                                     enabled: false, skimmed: "") == "")
    }
    @Test func directAndSkim() {
        let original = "alpha beta gamma delta epsilon"
        let reduced = "alpha beta gamma"
        let preview = "alpha"
        let o = GeniusLocusKit.estimatedTokenCount(of: original)
        let r = GeniusLocusKit.estimatedTokenCount(of: reduced)
        let p = GeniusLocusKit.estimatedTokenCount(of: preview)
        #expect(DistilledSavings.text(original: original, reduced: reduced, enabled: true)
                == DistilledSavings.measure(originalTokens: o, distilledTokens: r,
                                            skimOmittedTokens: nil).display)
        #expect(DistilledSavings.text(original: original, reduced: reduced,
                                     enabled: true, skimmed: preview)
                == DistilledSavings.measure(originalTokens: o, distilledTokens: r,
                                            skimOmittedTokens: r - p).display)
    }
    @Test func emptyUnicodeAndGrowth() {
        #expect(DistilledSavings.text(original: "", reduced: "", enabled: true)
            == "🌱 Distilled: ~0 tokens returned vs ~0 original · ~0 saved (0%)")
        #expect(DistilledSavings.text(original: "é🙂", reduced: "é🙂", enabled: true)
            .contains("~0 saved (0%)"))
        let growth = DistilledSavings.text(original: "a", reduced: "a", enabled: true,
                                          skimmed: "a much longer preview")
        #expect(growth.contains("increase"))
        #expect(!growth.contains("omitted"))
    }
}
