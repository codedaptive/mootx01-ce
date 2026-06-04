import Testing
import Foundation
@testable import VaultKit

/// `NoteIR` is the language-neutral boundary contract. These tests pin
/// the JSON-serializability that lets a future non-Swift producer emit
/// the same IR with a mechanical port (ADR-VAULTKIT-001 (f)).
@Suite("NoteIR boundary contract")
struct NoteIRTests {

    @Test("NoteIR round-trips through JSON unchanged")
    func jsonRoundTrip() throws {
        let note = NoteIR(
            stableSourceKey: "Area/Sub/Note",
            body: [Block(kind: "markdown", text: "Hello [[World]] #tag")],
            frontmatter: ["wing": "wing_owner", "room": "inbox", "udc": "004"],
            links: [WikiLink(target: "World", alias: nil, raw: "World")],
            tags: ["tag"],
            originalPath: "Area/Sub",
            originDate: OccurredAt(iso8601: "2024-01-02T03:04:05.000Z"),
            source: SourceRef(path: "att/x.pdf", contentHash: "abc", mime: "application/pdf", byteSize: 12)
        )

        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(NoteIR.self, from: data)
        #expect(decoded == note)
    }

    @Test("flattenedBody joins ordered blocks with newlines")
    func flattenedBodyJoinsBlocks() {
        let note = NoteIR(
            stableSourceKey: "k",
            body: [Block(text: "first"), Block(text: "second")]
        )
        #expect(note.flattenedBody == "first\nsecond")
    }

    @Test("OccurredAt formats and parses in LocusKit's ISO8601 form")
    func occurredAtFormat() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let occ = OccurredAt(date: date)
        // Fractional seconds + internet date-time, matching LKISO8601.
        #expect(occ.iso8601.contains("T"))
        #expect(occ.iso8601.contains("."))
        // Re-parse is within a millisecond of the original instant.
        let parsed = occ.date
        #expect(parsed != nil)
        #expect(abs(parsed!.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.001)
    }
}
