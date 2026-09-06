import Foundation
import Testing
import LocusKit
@testable import AriaMCP

// FederatedRedactionTests — pins the federated-search provenance redaction
// mapping (codex finding 2026-08-26): restricted/secret rows must redact
// BOTH content-derived columns. The subject marker without a nil
// bestSpan leaked a body-derived preview for exactly the rows whose
// subject said they were redacted. The Rust twin nils best_span for
// these sensitivities; this suite keeps the Swift port on that contract.
// ENC-W6B: firstSentence renamed to bestSpan throughout.
@Suite("Federated search redaction")
struct FederatedRedactionTests {

    @Test("restricted row redacts subject AND drops bestSpan")
    func restrictedRedactsBothColumns() {
        let row = ToolDispatcher.federatedCandidateRow(
            id: "d-1", sensitivity: .restricted,
            subject: "salary discussion", content: "The offer was 240k.",
            eventTime: "2026-01-01T00:00:00Z")
        #expect(row.subject == ResultComposer.restrictedMarker)
        #expect(row.bestSpan == nil)
    }

    @Test("secret row redacts subject AND drops bestSpan")
    func secretRedactsBothColumns() {
        let row = ToolDispatcher.federatedCandidateRow(
            id: "d-2", sensitivity: .secret,
            subject: "medical note", content: "Diagnosis confirmed on Friday.",
            eventTime: "2026-01-02T00:00:00Z")
        #expect(row.subject == ResultComposer.secretMarker)
        #expect(row.bestSpan == nil)
    }

    @Test("normal and elevated rows keep both columns")
    func normalKeepsBothColumns() {
        for sensitivity in [Sensitivity.normal, .elevated] {
            let row = ToolDispatcher.federatedCandidateRow(
                id: "d-3", sensitivity: sensitivity,
                subject: "trip plan", content: "Flight leaves at nine.",
                eventTime: "2026-01-03T00:00:00Z")
            #expect(row.subject == "trip plan")
            #expect(row.bestSpan == "Flight leaves at nine.")
        }
    }

    @Test("empty content renders absent, never an empty column")
    func emptyContentIsAbsent() {
        let row = ToolDispatcher.federatedCandidateRow(
            id: "d-4", sensitivity: .normal,
            subject: "bare row", content: "", eventTime: "2026-01-04T00:00:00Z")
        #expect(row.bestSpan == nil)
    }
}
