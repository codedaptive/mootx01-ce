import Testing
@testable import CognitionKit

// TemporalExplicitBoundTests — pins the strict from/to shape validation
// (codex finding 2026-08-26): the old length+delimiter check accepted
// "2023-aa-bb", which shiftISODay force-unwrapped into a fatal trap,
// attacker-reachable through moot_recall_temporal's public arguments.
@Suite("Temporal explicit bound validation")
struct TemporalExplicitBoundTests {

    @Test("strict shapes are accepted and expanded")
    func acceptsStrictShapes() throws {
        #expect(try TemporalRecall.explicitBound("2023-04-01", isFrom: true)
                == "2023-04-01T00:00:00Z")
        #expect(try TemporalRecall.explicitBound("2023-04-01", isFrom: false)
                == "2023-04-01T23:59:59Z")
        #expect(try TemporalRecall.explicitBound("2023-04-01T12:30:00Z", isFrom: true)
                == "2023-04-01T12:30:00Z")
    }

    @Test("non-digit shapes throw instead of trapping downstream")
    func rejectsMalformedShapes() {
        for bad in ["2023-aa-bb", "20230401", "2023-04-01T12:30:0Z",
                    "aaaaaaaaaaaaaaaaaaaZ", "2023-04-01T12:30:00X",
                    "２０２３-04-01"] {
            #expect(throws: (any Error).self) {
                try TemporalRecall.explicitBound(bad, isFrom: true)
            }
        }
    }
}
