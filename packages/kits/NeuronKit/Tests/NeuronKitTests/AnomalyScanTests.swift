import Testing
@testable import NeuronKit

// Anomaly-scan lens (SPEC § 7.5). Tests assert the behavioral claims
// the spec makes — not the implementation. anomalies flags the entries
// of a value series that stand out from the rest by z-score magnitude;
// the sign carries direction (negative = below the mean — the
// "doesn't fit" signal the contradiction lens uses). Pure,
// deterministic (B-5, I-18); total over edge inputs (B-8) including
// the zero-spread guard.

@Suite("Anomaly-scan lens (SPEC § 7.5)")
struct AnomalyScanTests {

    // AN-1: a single spike in a flat series is flagged (high positive z).
    @Test("a spike is flagged with positive z")
    func spikeIsFlagged() {
        let flagged = NeuronKit.anomalies(values: [10, 10, 10, 10, 100], threshold: 1.5)
        #expect(flagged.count == 1)
        #expect(flagged[0].index == 4)
        #expect(flagged[0].zScore > 0, "the spike is above the mean")
    }

    // AN-2: a low outlier is flagged with a NEGATIVE z (the "doesn't
    // fit" signal the contradiction lens uses).
    @Test("a low outlier is flagged with negative z")
    func lowOutlierIsNegativeZ() {
        let flagged = NeuronKit.anomalies(values: [9, 10, 9, 10, 0], threshold: 1.5)
        #expect(flagged.contains { $0.index == 4 && $0.zScore < 0 },
                "the low outlier is below the mean")
    }

    // AN-3: a flat series has no outliers (guarded zero-spread), and an
    // empty series is total.
    @Test("flat and empty series have no anomalies")
    func flatSeriesNoAnomalies() {
        #expect(NeuronKit.anomalies(values: [5, 5, 5], threshold: 1).isEmpty)
        #expect(NeuronKit.anomalies(values: [], threshold: 1).isEmpty)
    }
}
