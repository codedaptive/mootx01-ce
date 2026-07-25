import Testing
import Foundation
@testable import WorkPacketKit

// WorkPacketCodableTests — round-trip Codable conformance for WorkPacket v1.
//
// Covers: round-trip encode/decode, unknown-field preservation across
// a schema-version bump, required-field presence, ISO8601 date encoding.

@Suite("WorkPacket Codable")
struct WorkPacketCodableTests {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // Fixed date for determinism — CLAUDE.md rule (never call Date() inside a test).
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePacket(id: String = "test-id-001") -> WorkPacket {
        WorkPacket(
            id: id,
            objective: "Validate the schema round-trip",
            sources: [
                WorkPacketSource(id: "src-1", description: "Spec document", uri: "docs/spec.md", kind: "file"),
            ],
            claims: [
                WorkPacketClaim(id: "claim-1", statement: "Round-trip is lossless", confidence: 0.95, supportingSourceIDs: ["src-1"]),
            ],
            uncertainties: ["Unknown future schema fields"],
            nextSteps: ["Write more tests"],
            provenance: WorkPacketProvenance(
                model: "test-model",
                agent: "test-agent",
                createdAt: fixedDate,
                updatedAt: fixedDate
            ),
            lineageLinks: [
                LineageLink(kind: .derivesFrom, targetPacketID: "parent-packet-001"),
            ]
        )
    }

    // MARK: - Round-trip

    @Test("round-trip produces equal WorkPacket")
    func roundTripProducesEqualPacket() throws {
        let original = makePacket()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(WorkPacket.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.schemaVersion == original.schemaVersion)
        #expect(decoded.objective == original.objective)
        #expect(decoded.sources == original.sources)
        #expect(decoded.claims == original.claims)
        #expect(decoded.uncertainties == original.uncertainties)
        #expect(decoded.nextSteps == original.nextSteps)
        #expect(decoded.lineageLinks == original.lineageLinks)
        #expect(decoded.provenance.model == original.provenance.model)
        #expect(decoded.provenance.agent == original.provenance.agent)
    }

    @Test("schemaVersion is 1 for current packets")
    func schemaVersionIs1() throws {
        let packet = makePacket()
        let data = try encoder.encode(packet)
        let decoded = try decoder.decode(WorkPacket.self, from: data)
        #expect(decoded.schemaVersion == 1)
        #expect(WorkPacket.currentSchemaVersion == 1)
    }

    // MARK: - Unknown-field preservation

    @Test("unknown fields from a future schema version are preserved on re-encode")
    func unknownFieldsPreservedOnReEncode() throws {
        // Simulate a v2 packet that added a "tags" field unknown to v1 decoder.
        let v2JSON = """
        {
          "schemaVersion": 2,
          "id": "future-packet-001",
          "objective": "Test forward compatibility",
          "sources": [],
          "claims": [],
          "uncertainties": [],
          "nextSteps": [],
          "provenance": {
            "model": "future-model",
            "agent": "future-agent",
            "createdAt": "2023-11-14T22:13:20Z",
            "updatedAt": "2023-11-14T22:13:20Z"
          },
          "lineageLinks": [],
          "tags": ["important", "validated"],
          "priority": 42
        }
        """.data(using: .utf8)!

        // Decode with v1 decoder — known fields load, unknowns land in additionalFields.
        let decoded = try decoder.decode(WorkPacket.self, from: v2JSON)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.id == "future-packet-001")
        #expect(!decoded.additionalFields.isEmpty, "additionalFields must capture unknown keys")
        #expect(decoded.additionalFields["tags"] != nil, "tags field must be preserved")
        #expect(decoded.additionalFields["priority"] != nil, "priority field must be preserved")

        // Re-encode and decode again — unknown fields survive the cycle.
        let reEncoded = try encoder.encode(decoded)
        let reDecoded = try decoder.decode(WorkPacket.self, from: reEncoded)
        #expect(reDecoded.additionalFields["tags"] != nil, "tags must survive re-encode")
        #expect(reDecoded.additionalFields["priority"] != nil, "priority must survive re-encode")
    }

    // MARK: - Confidence bounds

    @Test("claim confidence 0.0 and 1.0 round-trip correctly")
    func confidenceBoundsRoundTrip() throws {
        let packet = makePacket()
        let zeroClaim = WorkPacketClaim(id: "c-zero", statement: "Zero confidence", confidence: 0.0)
        let fullClaim = WorkPacketClaim(id: "c-full", statement: "Full confidence", confidence: 1.0)
        let rebuilt = WorkPacket(
            id: packet.id,
            objective: packet.objective,
            claims: [zeroClaim, fullClaim],
            provenance: packet.provenance
        )
        let data = try encoder.encode(rebuilt)
        let decoded = try decoder.decode(WorkPacket.self, from: data)
        #expect(decoded.claims[0].confidence == 0.0)
        #expect(decoded.claims[1].confidence == 1.0)
        _ = packet  // suppress unused warning
    }

    // MARK: - Empty collections

    @Test("empty optional collections decode without error")
    func emptyCollectionsDecodeSafely() throws {
        let minimal = WorkPacket(
            id: "minimal-001",
            objective: "Minimal packet",
            provenance: WorkPacketProvenance(
                model: "m", agent: "a",
                createdAt: fixedDate, updatedAt: fixedDate
            )
        )
        let data = try encoder.encode(minimal)
        let decoded = try decoder.decode(WorkPacket.self, from: data)
        #expect(decoded.sources.isEmpty)
        #expect(decoded.claims.isEmpty)
        #expect(decoded.uncertainties.isEmpty)
        #expect(decoded.nextSteps.isEmpty)
        #expect(decoded.lineageLinks.isEmpty)
    }

    // MARK: - LineageLinkKind encoding

    @Test("LineageLinkKind encodes as expected raw strings")
    func lineageLinkKindEncodesAsRawString() throws {
        let packet = makePacket()
        let data = try encoder.encode(packet)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"derivesFrom\""), "derivesFrom must be encoded as its raw string value")
    }

    @Test("respondsTo link kind round-trips")
    func respondsToLinkKindRoundTrips() throws {
        let packet = WorkPacket(
            id: "responder-001",
            objective: "Test respondsTo",
            provenance: WorkPacketProvenance(
                model: "m", agent: "a",
                createdAt: fixedDate, updatedAt: fixedDate
            ),
            lineageLinks: [LineageLink(kind: .respondsTo, targetPacketID: "target-001")]
        )
        let data = try encoder.encode(packet)
        let decoded = try decoder.decode(WorkPacket.self, from: data)
        #expect(decoded.lineageLinks.first?.kind == .respondsTo)
        #expect(decoded.lineageLinks.first?.targetPacketID == "target-001")
    }

    // MARK: - Date encoding

    @Test("dates encode as ISO8601 strings")
    func datesEncodeAsISO8601() throws {
        let packet = makePacket()
        let data = try encoder.encode(packet)
        let json = String(data: data, encoding: .utf8)!
        // ISO8601 dates contain 'T' and 'Z'
        #expect(json.contains("\"createdAt\""))
        #expect(json.contains("Z\""), "ISO8601 dates must end with Z")
    }
}
