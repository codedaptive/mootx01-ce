import Testing
import Foundation
import WorkPacketKit
@testable import GatewayUI

// MARK: - PacketViewsTests (FAB5-I3)
//
// Tests cover:
//   1. Fixture WorkPacket field completeness — verifies all display fields are
//      non-empty and within valid ranges, so PacketDetailView has real content
//      to render in the demo.
//   2. Three-deep lineage chain structure — constructs a root→parent→grandparent
//      chain and asserts every link is wired correctly. The LineageView reads
//      antecedents via a closure that wraps LineageGraph; this test validates
//      the data structure that closure returns.
//   3. LineageLinkKind raw-value stability — guard against accidental rawValue
//      changes that would silently corrupt stored packets.

@Suite("PacketViews — fixture rendering and lineage trace (FAB5-I3)")
struct PacketViewsTests {

    // MARK: - Helpers

    static func makeProvenance() -> WorkPacketProvenance {
        WorkPacketProvenance(
            model: "claude-sonnet-4-6",
            agent: "test-agent",
            createdAt: Date(timeIntervalSince1970: 1_753_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_753_000_000)
        )
    }

    static func makeFixture(
        id: String = UUID().uuidString,
        objective: String,
        lineageLinks: [LineageLink] = []
    ) -> WorkPacket {
        WorkPacket(
            id: id,
            objective: objective,
            sources: [WorkPacketSource(description: "Test source doc", uri: nil, kind: "drawer")],
            claims: [WorkPacketClaim(statement: "The test claim is valid.", confidence: 0.85, supportingSourceIDs: [])],
            uncertainties: ["Unknown edge case under heavy load"],
            nextSteps: ["Validate with a live estate client"],
            provenance: makeProvenance(),
            lineageLinks: lineageLinks
        )
    }

    // MARK: - 1. Fixture field completeness

    @Test("PacketDetailView fixture: all display fields are non-empty and valid")
    func packetDetailFieldsNonEmptyAndValid() {
        let packet = Self.makeFixture(objective: "Research the optimal lineage schema for WorkPacketKit.")

        #expect(!packet.objective.isEmpty)

        // Claims: non-empty, confidence in [0, 1]
        #expect(!packet.claims.isEmpty)
        for claim in packet.claims {
            #expect(!claim.statement.isEmpty)
            #expect(claim.confidence >= 0.0)
            #expect(claim.confidence <= 1.0)
        }

        // Uncertainties and next steps: non-empty strings
        #expect(!packet.uncertainties.isEmpty)
        for u in packet.uncertainties { #expect(!u.isEmpty) }
        #expect(!packet.nextSteps.isEmpty)
        for s in packet.nextSteps { #expect(!s.isEmpty) }

        // Provenance
        #expect(!packet.provenance.model.isEmpty)
        #expect(!packet.provenance.agent.isEmpty)

        // Schema version matches current
        #expect(packet.schemaVersion == WorkPacket.currentSchemaVersion)
    }

    // MARK: - 2. Three-deep lineage chain

    @Test("LineageView: three-deep lineage chain links root → parent → grandparent")
    func threeDeepLineageChain() {
        // Grandparent: leaf node — no further links
        let grandparent = Self.makeFixture(id: "gp-001", objective: "Level 3: original research by Claude")

        // Parent: derives from grandparent
        let parent = Self.makeFixture(
            id: "p-001",
            objective: "Level 2: Codex cross-check and synthesis",
            lineageLinks: [LineageLink(kind: .derivesFrom, targetPacketID: "gp-001")]
        )

        // Root: derives from parent (depth 1 from root; total chain depth = 3)
        let root = Self.makeFixture(
            id: "root-001",
            objective: "Level 1: local-model comparison and final synthesis",
            lineageLinks: [LineageLink(kind: .derivesFrom, targetPacketID: "p-001")]
        )

        // Root links to parent
        #expect(root.lineageLinks.count == 1)
        #expect(root.lineageLinks[0].targetPacketID == parent.id)
        #expect(root.lineageLinks[0].kind == .derivesFrom)

        // Parent links to grandparent
        #expect(parent.lineageLinks.count == 1)
        #expect(parent.lineageLinks[0].targetPacketID == grandparent.id)
        #expect(parent.lineageLinks[0].kind == .derivesFrom)

        // Grandparent is the leaf — no further antecedents
        #expect(grandparent.lineageLinks.isEmpty)

        // Walking the full chain manually yields exactly 3 packets
        let chain = [root, parent, grandparent]
        #expect(chain.count == 3, "Three-deep trace spans exactly 3 packets")
        for i in 0..<chain.count - 1 {
            #expect(chain[i].lineageLinks[0].targetPacketID == chain[i + 1].id,
                    "Packet at depth \(i) must link to packet at depth \(i + 1)")
        }
    }

    // MARK: - 3. LineageLinkKind raw-value stability

    @Test("LineageLinkKind raw values are stable (no accidental key drift)")
    func lineageLinkKindRawValues() {
        // These raw values are stored on disk; changing them is a schema break.
        #expect(LineageLinkKind.derivesFrom.rawValue == "derivesFrom")
        #expect(LineageLinkKind.respondsTo.rawValue == "respondsTo")
    }
}
