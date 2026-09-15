import AriaMCP
import GeniusLocusKit
import Testing
@testable import mootx01

@Test("--version reports the hydration and recall converters")
func versionOutputReportsProductConverterIdentities() {
    let lines = Mootx01.versionOutput.split(separator: "\n").map(String.init)

    #expect(lines == [
        Mootx01.versionDisplay,
        "converter hydration \(GeniusLocusKit.distillationConverter.id) \(GeniusLocusKit.distillationConverter.converterVersion)",
        "converter recall \(RecallDistillation.converter.id) \(RecallDistillation.converter.converterVersion)",
    ])
}
