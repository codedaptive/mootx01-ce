import Foundation
import Testing
@testable import VaultKit

// PalaceFourNounTests.swift — unit tests for the canonical four-noun palace
// pump's pure cores (Swift leg). Conformance-gated against the Rust
// `palace_four_noun.rs`: the SAME item vectors, the SAME expected canonical
// envelope bytes, so the per-noun mapping, the generic versioned envelope, the
// drift manifest, and the per-noun response parsing are proven byte-for-byte
// equivalent across the two ports.
//
// The cross-implementation guard is the EXPECTED-BYTES literal: each port
// encodes the same `PalaceItem` and asserts the result equals the exact same
// string. A drift in either port's canonical JSON (key order, slash escaping,
// marker, version) fails the matching assertion in that port.

// MARK: - shared per-noun vectors (twins of the Rust fixtures)

/// A drawer item with the full metadata surface MemPalace's add_drawer cannot
/// carry natively (lineage id, bitmaps, udc, event time) riding the envelope.
private func drawerItem() -> PalaceItem {
    PalaceItem(
        noun: .drawer,
        sourceID: "drawer_alpha_research_001",
        body: "A study of benzene.",
        nativeFields: [
            "wing": .string("alpha"),
            "room": .string("research"),
            "content": .string("A study of benzene."),
        ],
        envelopeFields: [
            "noun": .string("drawer"),
            "id": .string("drawer_alpha_research_001"),
            "lineageID": .string("12345678-1234-1234-1234-1234567890AB"),
            "adjectiveBitmap": .number(5),
            "udcCode": .string("314"),
        ])
}

/// A tunnel item — endpoints native, kind + bitmaps on the envelope (create_tunnel
/// carries no kind/bitmap arg). The envelope rides the `label`.
private func tunnelItem() -> PalaceItem {
    PalaceItem(
        noun: .tunnel,
        sourceID: "tunnel_001",
        body: "tunnel: alpha/research → beta/notes [supersedes]",
        nativeFields: [
            "source_wing": .string("alpha"),
            "source_room": .string("research"),
            "target_wing": .string("beta"),
            "target_room": .string("notes"),
            "label": .string("supersedes"),
        ],
        envelopeFields: [
            "noun": .string("tunnel"),
            "id": .string("tunnel_001"),
            "kind": .number(2),
            "provenanceBitmap": .number(1),
        ])
}

/// A KG-fact item — clean triple native, the rest on `source_closet`. The clean
/// triple stays well-formed; the envelope is far larger than 128 chars so it
/// CANNOT ride the object (the original write-failure bug).
private func factItem() -> PalaceItem {
    PalaceItem(
        noun: .kgFact,
        sourceID: "fact_001",
        body: "benzene → has-structure → aromatic-ring",
        nativeFields: [
            "subject": .string("benzene"),
            "predicate": .string("has-structure"),
            "object": .string("aromatic-ring"),
            "valid_from": .string("2024-03-04"),
        ],
        envelopeFields: [
            "noun": .string("kgFact"),
            "id": .string("fact_001"),
            "sourceDrawerID": .string("drawer_alpha_research_001"),
            "filedAt": .string("2024-03-04T05:06:07.000Z"),
        ])
}

/// A diary item — agent/topic/entry native, the rest on the envelope.
private func diaryItem() -> PalaceItem {
    PalaceItem(
        noun: .diaryEntry,
        sourceID: "diary_001",
        body: "Filed the benzene study.",
        nativeFields: [
            "agent_name": .string("nagatha"),
            "topic": .string("research"),
            "entry": .string("Filed the benzene study."),
            "wing": .string("alpha"),
        ],
        envelopeFields: [
            "noun": .string("diaryEntry"),
            "id": .string("diary_001"),
            "room": .string("research"),
        ])
}

// MARK: - per-noun mapping (tool + native args)

@Test func drawerMapsToAddDrawerWithEnvelopeInContent() throws {
    let call = try PalacePumpMapping.call(for: drawerItem())
    #expect(call.tool == "mempalace_add_drawer")
    #expect(call.arguments["wing"]?.stringValue == "alpha")
    #expect(call.arguments["room"]?.stringValue == "research")
    #expect(call.arguments["added_by"]?.stringValue == "mootx01-pump")
    // The envelope rides content; body is above the marker (searchable).
    let content = try #require(call.arguments["content"]?.stringValue)
    #expect(content.hasPrefix("A study of benzene."))
    #expect(content.contains("<!-- MOOT-ENVELOPE v1"))
}

@Test func tunnelMapsEndpointsNativeAndEnvelopeRidesLabel() throws {
    let call = try PalacePumpMapping.call(for: tunnelItem())
    #expect(call.tool == "mempalace_create_tunnel")
    #expect(call.arguments["source_wing"]?.stringValue == "alpha")
    #expect(call.arguments["target_room"]?.stringValue == "notes")
    // label = human label, blank line, envelope. The kind/bitmaps ride it.
    let label = try #require(call.arguments["label"]?.stringValue)
    #expect(label.hasPrefix("supersedes"))
    #expect(label.contains("\"kind\":2"))
}

@Test func factTripleStaysCleanAndEnvelopeRidesSourceCloset() throws {
    let call = try PalacePumpMapping.call(for: factItem())
    #expect(call.tool == "mempalace_kg_add")
    // The triple is the CLEAN native value — the envelope never touches it.
    #expect(call.arguments["object"]?.stringValue == "aromatic-ring")
    #expect(call.arguments["valid_from"]?.stringValue == "2024-03-04")
    let closet = try #require(call.arguments["source_closet"]?.stringValue)
    #expect(closet.contains("<!-- MOOT-ENVELOPE v1"))
    // source_closet carries the envelope, NOT the object (the 128-cap bug fix).
    #expect(closet.contains("\"sourceDrawerID\":\"drawer_alpha_research_001\""))
}

@Test func factWithNoEnvelopeSendsNoSourceCloset() throws {
    // A fact with an empty envelope-field map sends a clean triple, no closet.
    let bare = PalaceItem(
        noun: .kgFact, sourceID: "f2", body: "a → b → c",
        nativeFields: ["subject": .string("a"), "predicate": .string("b"), "object": .string("c")],
        envelopeFields: [:])
    let call = try PalacePumpMapping.call(for: bare)
    #expect(call.arguments["source_closet"] == nil)
}

@Test func diaryMapsToDiaryWriteWithEnvelopeInEntry() throws {
    let call = try PalacePumpMapping.call(for: diaryItem())
    #expect(call.tool == "mempalace_diary_write")
    #expect(call.arguments["agent_name"]?.stringValue == "nagatha")
    #expect(call.arguments["topic"]?.stringValue == "research")
    let entry = try #require(call.arguments["entry"]?.stringValue)
    #expect(entry.hasPrefix("Filed the benzene study."))
    #expect(entry.contains("<!-- MOOT-ENVELOPE v1"))
}

// MARK: - generic envelope round-trip (encode → decode identity, per noun)

@Test func fourNounEnvelopeRoundTripsEveryNoun() throws {
    for item in [drawerItem(), tunnelItem(), factItem(), diaryItem()] {
        let encoded = try PalacePayloadEnvelope.encodeFields(body: item.body, fields: item.envelopeFields)
        let decoded = try PalacePayloadEnvelope.decodeFields(content: encoded)
        #expect(decoded.body == item.body)
        #expect(decoded.fields == item.envelopeFields)  // decode(encode(x)) == x
    }
}

@Test func emptyFieldsEmitsNoEnvelope() throws {
    let encoded = try PalacePayloadEnvelope.encodeFields(body: "just prose", fields: [:])
    #expect(encoded == "just prose")  // no marker, body unchanged
    let decoded = try PalacePayloadEnvelope.decodeFields(content: encoded)
    #expect(decoded.body == "just prose")
    #expect(decoded.fields.isEmpty)
}

// MARK: - CROSS-IMPLEMENTATION GUARD (exact canonical bytes)
//
// These exact strings are the shared vectors the Rust `palace_four_noun.rs`
// asserts against verbatim. Same field map → same canonical JSON (sorted keys,
// no slash escaping) → same envelope bytes in both ports. If either port's
// canonical encoder drifts, its matching assertion fails.

/// The expected canonical envelope for the drawer item's body+fields.
private let expectedDrawerEnvelope =
    "A study of benzene.\n\n<!-- MOOT-ENVELOPE v1\n"
    + "{\"adjectiveBitmap\":5,\"id\":\"drawer_alpha_research_001\",\"lineageID\":\"12345678-1234-1234-1234-1234567890AB\",\"noun\":\"drawer\",\"udcCode\":\"314\"}"
    + "\nMOOT-ENVELOPE -->"

/// The expected canonical envelope for the fact item riding source_closet
/// (empty body — the fact's text is the clean native triple, not the closet).
private let expectedFactCloset =
    "\n\n<!-- MOOT-ENVELOPE v1\n"
    + "{\"filedAt\":\"2024-03-04T05:06:07.000Z\",\"id\":\"fact_001\",\"noun\":\"kgFact\",\"sourceDrawerID\":\"drawer_alpha_research_001\"}"
    + "\nMOOT-ENVELOPE -->"

@Test func canonicalBytesMatchSharedVectorDrawer() throws {
    let encoded = try PalacePayloadEnvelope.encodeFields(
        body: "A study of benzene.", fields: drawerItem().envelopeFields)
    #expect(encoded == expectedDrawerEnvelope)
}

@Test func canonicalBytesMatchSharedVectorFactCloset() throws {
    let encoded = try PalacePayloadEnvelope.encodeFields(
        body: "", fields: factItem().envelopeFields)
    #expect(encoded == expectedFactCloset)
}

// MARK: - drift manifest (all four write tools + read tools)

@Test func driftManifestCoversAllFourNounWriteTools() {
    let names = Set(PalaceDriftDetector.expectedManifest.map(\.name))
    #expect(names.isSuperset(of: [
        "mempalace_add_drawer", "mempalace_create_tunnel",
        "mempalace_kg_add", "mempalace_diary_write",
    ]))
    // The KG manifest must accept source_closet (the unbounded envelope field).
    let kg = try! #require(PalaceDriftDetector.expectedManifest.first { $0.name == "mempalace_kg_add" })
    #expect(kg.suppliedArgs.contains("source_closet"))
    #expect(kg.requiredArgs == ["subject", "predicate", "object"])
}

@Test func driftIsCleanWhenAllToolsPresent() {
    // A live surface that satisfies every manifest tool produces no findings.
    let live = PalaceDriftDetector.expectedManifest.map {
        PalaceLiveTool(name: $0.name, requiredArgs: $0.requiredArgs)
    }
    #expect(PalaceDriftDetector.diff(live: live).isEmpty)
}

// MARK: - per-noun response parsing

@Test func parsesPerNounAssignedID() {
    #expect(PalaceResponseParsing.assignedIDKey(for: .drawer) == "drawer_id")
    #expect(PalaceResponseParsing.assignedIDKey(for: .tunnel) == "id")
    #expect(PalaceResponseParsing.assignedIDKey(for: .kgFact) == "triple_id")
    #expect(PalaceResponseParsing.assignedIDKey(for: .diaryEntry) == "entry_id")

    let tunnelBlock = "{\"success\":true,\"id\":\"tunnel_alpha_001\"}"
    #expect(PalaceResponseParsing.parseAssignedID(textBlocks: [tunnelBlock], idKey: "id") == "tunnel_alpha_001")
    // already_exists shape still carries the id.
    let dupe = "{\"success\":true,\"reason\":\"already_exists\",\"triple_id\":\"t_42\"}"
    #expect(PalaceResponseParsing.parseAssignedID(textBlocks: [dupe], idKey: "triple_id") == "t_42")
    // No id key → nil (a write that produced no row).
    #expect(PalaceResponseParsing.parseAssignedID(textBlocks: ["{\"success\":false}"], idKey: "entry_id") == nil)
}
