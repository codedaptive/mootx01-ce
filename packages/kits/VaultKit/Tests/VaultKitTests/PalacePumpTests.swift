import Foundation
import Testing
@testable import VaultKit

// PalacePumpTests.swift — unit tests for the outbound MemPalace pump's pure
// cores (Swift leg). Conformance-gated against the Rust `palace_pump_units.rs`:
// the SAME note vectors, the SAME assertions, so the envelope codec, the
// per-item arg mapping, the response parsers, and the drift detector are proven
// byte-for-byte equivalent across the two ports.
//
// No live server here — the live scratch-pump path is exercised by the guarded
// integration tests (Swift `tools/moot-pump` PumpIntegrationTests and the Rust
// `palace_pump_live.rs`).

// MARK: - shared vector

/// A richly-populated note exercising every lossy field — the exact twin of the
/// Rust `full_note()` fixture so both ports assert against identical input.
private func fullNote() -> NoteIR {
    let note = NoteIR(
        stableSourceKey: "projects/alpha/notes/benzene",
        body: [Block(kind: "markdown", text: "A study of benzene and its ring structure.")],
        frontmatter: ["room": "research", "udc": "314"],
        links: [WikiLink(target: "Benzene", alias: "the ring", raw: "Benzene|the ring")],
        tags: ["chem", "aromatics"],
        originalPath: "projects/alpha/notes",
        originDate: OccurredAt(iso8601: "2024-03-04T05:06:07.000Z"),
        source: SourceRef(path: "attach/diagram.png", contentHash: "abc123",
                          mime: "image/png", byteSize: 2048),
        mootID: UUID(uuidString: "12345678-1234-1234-1234-1234567890ab"),
        facts: [FactIR(subject: "benzene", predicate: "has-structure", object: "aromatic-ring")],
        pathComponents: ["projects", "alpha", "notes", "benzene"],
        scope: ["agent": "nagatha"],
        kind: "note"
    )
    return note
}

// MARK: - envelope round-trip (never drop a field)

@Test func envelopeRoundTripsEveryLossyField() throws {
    let note = fullNote()
    let payload = PalaceEnvelopePayload(from: note)
    let content = try PalacePayloadEnvelope.encode(body: note.flattenedBody, payload: payload)

    // Body prose is above the marker (searchable, human-first).
    #expect(content.hasPrefix("A study of benzene"))
    #expect(content.contains("<!-- MOOT-ENVELOPE v1"))

    let decoded = try PalacePayloadEnvelope.decode(content: content)
    #expect(decoded.body == note.flattenedBody)
    let recovered = try #require(decoded.payload)
    #expect(recovered == payload)  // decode(encode(x)) == x for the payload
    // Every lossy field survived.
    #expect(recovered.frontmatter["udc"] == "314")
    #expect(recovered.links.count == 1)
    #expect(recovered.tags == ["chem", "aromatics"])
    #expect(recovered.originDate?.iso8601 == "2024-03-04T05:06:07.000Z")
    #expect(recovered.source?.byteSize == 2048)
    #expect(recovered.mootID == UUID(uuidString: "12345678-1234-1234-1234-1234567890ab"))
    #expect(recovered.facts.count == 1)
    #expect(recovered.pathComponents.count == 4)
    #expect(recovered.scope["agent"] == "nagatha")
}

@Test func reconstructNoteRecoversFullNote() throws {
    let note = fullNote()
    let args = try PalacePumpMapping.makeArgs(for: note)
    let reconstructed = try PalacePayloadEnvelope.reconstructNote(
        content: args.content, fallbackKey: "fallback")
    #expect(reconstructed.stableSourceKey == note.stableSourceKey)
    #expect(reconstructed.flattenedBody == note.flattenedBody)
    #expect(reconstructed.facts == note.facts)
    #expect(reconstructed.pathComponents == note.pathComponents)
    #expect(reconstructed.scope == note.scope)
    #expect(reconstructed.mootID == note.mootID)
}

@Test func foreignDrawerContentDecodesAsPlainProse() throws {
    let decoded = try PalacePayloadEnvelope.decode(content: "just a normal drawer, no envelope")
    #expect(decoded.body == "just a normal drawer, no envelope")
    #expect(decoded.payload == nil)
}

@Test func unsupportedEnvelopeVersionIsALoudError() {
    let bad = "body\n\n<!-- MOOT-ENVELOPE v99\n{}\nMOOT-ENVELOPE -->"
    #expect(throws: PalacePayloadEnvelope.DecodeError.unsupportedVersion(99)) {
        _ = try PalacePayloadEnvelope.decode(content: bad)
    }
}

@Test func unterminatedEnvelopeErrors() {
    let bad = "body\n\n<!-- MOOT-ENVELOPE v1\n{ \"stableSourceKey\": \"x\" "
    #expect(throws: PalacePayloadEnvelope.DecodeError.unterminated) {
        _ = try PalacePayloadEnvelope.decode(content: bad)
    }
}

// MARK: - per-item arg mapping (GAP A)

@Test func argBuildingDerivesWingRoomFromPathComponents() throws {
    let note = fullNote()
    let args = try PalacePumpMapping.makeArgs(for: note)
    // first component → wing; the rest joined with "/" → room.
    #expect(args.wing == "projects")
    #expect(args.room == "alpha/notes/benzene")
    #expect(args.sourceFile == "projects/alpha/notes/benzene")
    #expect(args.addedBy == "mootx01-pump")
    #expect(args.content.contains("<!-- MOOT-ENVELOPE v1"))
}

@Test func argBuildingFallsBackForFlatAndEmptyPaths() throws {
    let flat = NoteIR(stableSourceKey: "k",
                      body: [Block(kind: "markdown", text: "c")])
    let args = try PalacePumpMapping.makeArgs(for: flat)
    #expect(args.wing == "mootx01")
    #expect(args.room == "general")

    var one = flat
    one.pathComponents = ["solo"]
    let args1 = try PalacePumpMapping.makeArgs(for: one)
    #expect(args1.wing == "solo")
    #expect(args1.room == "general")
}

@Test func sanitizeCollapsesUnsafeRunsToSingleHyphen() {
    #expect(PalacePumpMapping.sanitize("My Project!! Name") == "My-Project-Name")
    #expect(PalacePumpMapping.sanitize("  spaced  ") == "spaced")
    #expect(PalacePumpMapping.sanitize("keep_under-score") == "keep_under-score")
    #expect(PalacePumpMapping.sanitize("***") == "")
}

// MARK: - response parsing (GAP B / GAP C)

@Test func parseAddDrawerIDHandlesFreshAndDuplicateShapes() throws {
    let fresh = [#"{"success": true, "drawer_id": "drawer_w_r_abc", "wing": "w", "room": "r"}"#]
    #expect(try PalaceResponseParsing.parseAddDrawerID(textBlocks: fresh) == "drawer_w_r_abc")

    let dup = [#"{"success": true, "reason": "already_exists", "drawer_id": "drawer_w_r_abc"}"#]
    #expect(try PalaceResponseParsing.parseAddDrawerID(textBlocks: dup) == "drawer_w_r_abc")

    // A non-JSON diagnostic block is skipped; a missing id is an error.
    #expect(throws: (any Error).self) {
        _ = try PalaceResponseParsing.parseAddDrawerID(textBlocks: ["not json"])
    }
}

@Test func parseGetDrawerExtractsIDAndFullContent() throws {
    let block = [#"{"drawer_id": "drawer_w_r_abc", "content": "the full verbatim body", "wing": "w", "room": "r", "metadata": {"filed_at": "2026-06-10T18:17:52"}}"#]
    let fetched = try PalaceResponseParsing.parseGetDrawer(textBlocks: block)
    #expect(fetched.drawerID == "drawer_w_r_abc")
    #expect(fetched.content == "the full verbatim body")
}

// MARK: - drift detection (GAP F)

@Test func driftDetectorPassesOnTheVerifiedLiveSurface() {
    // The full four-noun live surface (v3.3.3): the four write tools (one per
    // noun) plus the read/verify tools. A live surface that satisfies every
    // manifest tool produces no findings.
    let live = [
        PalaceLiveTool(name: "mempalace_add_drawer", requiredArgs: ["wing", "room", "content"]),
        PalaceLiveTool(name: "mempalace_create_tunnel",
                       requiredArgs: ["source_wing", "source_room", "target_wing", "target_room"]),
        PalaceLiveTool(name: "mempalace_kg_add", requiredArgs: ["subject", "predicate", "object"]),
        PalaceLiveTool(name: "mempalace_diary_write", requiredArgs: ["agent_name", "entry"]),
        PalaceLiveTool(name: "mempalace_get_drawer", requiredArgs: ["drawer_id"]),
        PalaceLiveTool(name: "mempalace_list_tunnels", requiredArgs: []),
        PalaceLiveTool(name: "mempalace_kg_query", requiredArgs: ["entity"]),
        PalaceLiveTool(name: "mempalace_diary_read", requiredArgs: ["agent_name"]),
        PalaceLiveTool(name: "mempalace_list_drawers", requiredArgs: []),
        PalaceLiveTool(name: "mempalace_search", requiredArgs: ["query"]),
    ]
    let findings = PalaceDriftDetector.diff(live: live)
    #expect(findings.isEmpty)
}

@Test func driftDetectorFlagsARenamedTool() {
    // add_drawer renamed → create_drawer: the pump's tool is now missing.
    let live = [
        PalaceLiveTool(name: "mempalace_create_drawer", requiredArgs: ["wing", "room", "content"]),
    ]
    let findings = PalaceDriftDetector.diff(live: live)
    #expect(findings.contains(.toolMissing(name: "mempalace_add_drawer")))
}

@Test func driftDetectorFlagsANewRequiredArgThePumpCannotSupply() {
    // MemPalace now requires an "owner_key" the pump does not send.
    let live = [
        PalaceLiveTool(name: "mempalace_add_drawer",
                       requiredArgs: ["wing", "room", "content", "owner_key"]),
    ]
    let findings = PalaceDriftDetector.diff(live: live)
    #expect(findings.contains(.newRequiredArgUnsupplied(tool: "mempalace_add_drawer", arg: "owner_key")))
}

@Test func liveToolParseReadsToolsListPayload() throws {
    let payload = Data(#"{"tools":[{"name":"mempalace_add_drawer","inputSchema":{"required":["wing","room","content"],"properties":{}}},{"name":"mempalace_get_drawer","inputSchema":{"required":["drawer_id"]}}]}"#.utf8)
    let tools = try PalaceLiveTool.parse(toolsListJSON: payload)
    #expect(tools.count == 2)
    #expect(tools[0].name == "mempalace_add_drawer")
    #expect(tools[0].requiredArgs.contains("wing"))
}
