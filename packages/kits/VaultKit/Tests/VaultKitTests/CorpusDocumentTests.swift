import Foundation
import Testing
@testable import VaultKit

// VK_IR_01 — CorpusDocument envelope tests.
//
// The golden fixture `Fixtures/corpus_document_v1.json` is the shared
// cross-language conformance vector: the Rust suite
// (`rust/tests/corpus_document.rs`) loads the SAME file and asserts the
// same byte-for-byte encode and value-for-value decode. Any change to
// the fixture must keep both suites green in the same commit.

@Suite("CorpusDocument canonical envelope")
struct CorpusDocumentTests {

    /// Path of the shared golden fixture, resolved relative to this
    /// source file so no Package.swift resource processing is needed
    /// (the Rust suite reaches the same file via CARGO_MANIFEST_DIR).
    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/corpus_document_v1.json")
    }

    /// The canonical sample document. The Rust test constructs the
    /// exact same document — field for field — so both ports prove
    /// they serialize identical values to identical bytes.
    static func goldenDocument() -> CorpusDocument {
        let fullFidelityNote = NoteIR(
            stableSourceKey: "projects/alpha/fact-sheet",
            body: [Block(kind: "markdown", text: "Alice works at Acme.\nSee [[Acme HQ|HQ]].")],
            frontmatter: ["created": "2024-03-04T05:06:07.000Z", "wing": "work"],
            links: [WikiLink(target: "Acme HQ", alias: "HQ", raw: "Acme HQ|HQ")],
            tags: ["org", "people"],
            originalPath: "projects/alpha",
            originDate: OccurredAt(iso8601: "2024-03-04T05:06:07.000Z"),
            source: SourceRef(
                path: "attachments/acme.pdf",
                contentHash: "ab12cd34",
                mime: "application/pdf",
                byteSize: 2048
            ),
            mootID: UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
            facts: [
                FactIR(subject: "alice", predicate: "works_at", object: "acme",
                       validFrom: "2024-03-04T05:06:07.000Z",
                       confidence: 0.9),
                FactIR(subject: "acme", predicate: "located_in", object: "berlin"),
            ],
            pathComponents: ["projects", "alpha"],
            scope: ["agentId": "ag-7", "userId": "u-1"],
            kind: "fact"
        )
        let minimalNote = NoteIR(
            stableSourceKey: "inbox/hello",
            body: [Block(text: "hello world")]
        )
        return CorpusDocument(name: "golden-estate", notes: [fullFidelityNote, minimalNote])
    }

    @Test("encode matches the golden fixture byte-for-byte")
    func encodeMatchesFixture() throws {
        let encoded = try Self.goldenDocument().canonicalJSON()
        let fixture = try Data(contentsOf: Self.fixtureURL)
        #expect(encoded == fixture,
                "canonical encode diverged from fixture; actual: \(String(decoding: encoded, as: UTF8.self))")
    }

    @Test("decode of the golden fixture yields the expected values")
    func decodeFixture() throws {
        let fixture = try Data(contentsOf: Self.fixtureURL)
        let decoded = try CorpusDocument.decode(fixture)
        #expect(decoded == Self.goldenDocument())
        #expect(decoded.formatVersion == 1)
        #expect(decoded.notes.count == 2)
        #expect(decoded.notes[0].facts.count == 2)
        #expect(decoded.notes[1].kind == "note")
    }

    @Test("canonical encode is deterministic across invocations")
    func encodeIsDeterministic() throws {
        let a = try Self.goldenDocument().canonicalJSON()
        let b = try Self.goldenDocument().canonicalJSON()
        #expect(a == b)
    }

    @Test("unknown formatVersion produces the typed error, not best-effort decode")
    func unknownVersionIsTypedError() throws {
        let payload = Data(#"{"formatVersion":2,"name":"future","notes":[]}"#.utf8)
        #expect(throws: VaultKitError.unsupportedFormatVersion(2)) {
            _ = try CorpusDocument.decode(payload)
        }
    }

    @Test("version check fires before notes parsing — bad notes behind a bad version still report the version error")
    func versionCheckedFirst() throws {
        // `notes` here is structurally invalid; the strict decoder must
        // reject on formatVersion BEFORE ever looking at it.
        let payload = Data(#"{"formatVersion":99,"name":"x","notes":[{"bogus":true}]}"#.utf8)
        #expect(throws: VaultKitError.unsupportedFormatVersion(99)) {
            _ = try CorpusDocument.decode(payload)
        }
    }

    @Test("envelope round-trips notes containing legacy-defaulted fields")
    func envelopeRoundTrip() throws {
        let doc = Self.goldenDocument()
        let back = try CorpusDocument.decode(doc.canonicalJSON())
        #expect(back == doc)
    }
}
