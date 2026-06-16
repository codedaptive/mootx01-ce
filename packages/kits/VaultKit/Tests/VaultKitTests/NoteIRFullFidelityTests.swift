import Foundation
import Testing
@testable import VaultKit

// VK_IR_01 — NoteIR full-fidelity extension tests.
//
// Covers the four fields added per ADR-007 Decision 1 (`facts`,
// `pathComponents`, `scope`, `kind`) and the back-compat guarantee:
// JSON serialized BEFORE the extension (no new keys) must decode with
// the documented defaults. Pre-existing NoteIR behavior is covered by
// NoteIRTests.swift, which this mission leaves unmodified.

@Suite("NoteIR full-fidelity extension")
struct NoteIRFullFidelityTests {

    @Test("new fields default to empty/[]/'note' from the memberwise init")
    func defaultsFromInit() {
        let ir = NoteIR(stableSourceKey: "a/b", body: [Block(text: "x")])
        #expect(ir.facts.isEmpty)
        #expect(ir.pathComponents.isEmpty)
        #expect(ir.scope.isEmpty)
        #expect(ir.kind == "note")
    }

    @Test("legacy pre-extension JSON (no new keys) decodes with defaults")
    func preExtensionDecode() throws {
        // Shape exactly as the pre-extension encoder produced it: the
        // nine original fields only, optionals omitted.
        let legacy = """
        {"body":[{"kind":"markdown","text":"hello"}],\
        "frontmatter":{"wing":"w"},\
        "links":[],\
        "originalPath":"projects/alpha",\
        "stableSourceKey":"alpha/hello",\
        "tags":["t1"]}
        """
        let ir = try JSONDecoder().decode(NoteIR.self, from: Data(legacy.utf8))
        #expect(ir.stableSourceKey == "alpha/hello")
        #expect(ir.facts == [])
        #expect(ir.pathComponents == [])
        #expect(ir.scope == [:])
        #expect(ir.kind == "note")
    }

    @Test("full-fidelity fields round-trip through Codable")
    func fullFidelityRoundTrip() throws {
        let ir = NoteIR(
            stableSourceKey: "alpha/fact-sheet",
            body: [Block(text: "body")],
            facts: [
                FactIR(subject: "alice", predicate: "works_at", object: "acme",
                       validFrom: "2024-03-04T05:06:07.000Z",
                       validTo: nil,
                       confidence: 0.9),
                FactIR(subject: "acme", predicate: "located_in", object: "berlin"),
            ],
            pathComponents: ["projects", "alpha", "notes"],
            scope: ["userId": "u-1", "agentId": "ag-7"],
            kind: "fact"
        )
        let data = try JSONEncoder().encode(ir)
        let back = try JSONDecoder().decode(NoteIR.self, from: data)
        #expect(back == ir)
    }

    @Test("FactIR optional window/confidence omit their keys when nil")
    func factIROptionalKeysOmitted() throws {
        let fact = FactIR(subject: "s", predicate: "p", object: "o")
        let json = String(decoding: try JSONEncoder().encode(fact), as: UTF8.self)
        #expect(!json.contains("validFrom"))
        #expect(!json.contains("validTo"))
        #expect(!json.contains("confidence"))
    }
}
