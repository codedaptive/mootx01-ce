import Foundation
import Testing
@testable import LocusKit

/// Cookbook §2.5 + §2.8 verification-table conformance gate for the
/// Drawer provenance bitmap constants LocusKit owns: SourceType,
/// Channel, CaptureChannel (mirrored from operational §2.4),
/// Confirmation, Confidence, Sensitivity, EnrichmentStatus.
///
/// Cookbook §2.8: "Implementations MUST surface this table as an
/// automated conformance test that fails when a source constant
/// deviates from spec." This file enforces that gate for the
/// provenance layout per cookbook §2.5 v0.6.
///
/// F13 cascade (2026-05-27): added after the v0.6 vocab + raw-value
/// migration to lock the new constants in place.
@Suite("ProvenanceBitmapConformanceTests")
struct ProvenanceBitmapConformanceTests {

    private func makeDrawer(provenance: Int64) -> Drawer {
        Drawer(
            content: "c", parentNodeId: "test-parent", addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "minilm-v6",
            provenance: provenance
        )
    }

    // MARK: - SourceType (cookbook §2.5 bits 0-5)

    private static let sourceTypeTable: [(source: SourceType, expectedRaw: Int)] = [
        (SourceType.user, 0),
        (SourceType.observed, 1),
        (SourceType.imported, 2),
        (SourceType.canonical, 3),
        (SourceType.derived, 4),
        (SourceType.federationAggregate, 5),
        (SourceType.tierAggregate, 6),
        (SourceType.pairedEstate, 7),
        (SourceType.ambient, 8),
        (SourceType.actuator, 9),
    ]

    @Test("SourceType raw values match cookbook §2.5")
    func sourceTypeRawValuesMatchTable() {
        var mismatches: [String] = []
        for entry in Self.sourceTypeTable {
            if entry.source.rawValue != entry.expectedRaw {
                mismatches.append("SourceType.\(entry.source) expected raw=\(entry.expectedRaw), got \(entry.source.rawValue)")
            }
        }
        if !mismatches.isEmpty {
            Issue.record(Comment(rawValue: "SourceType diverges from cookbook §2.5:\n" + mismatches.joined(separator: "\n")))
        }
    }

    @Test("SourceType field lives at bits 0-5 (cookbook §2.5)")
    func sourceTypeFieldPosition() {
        for entry in Self.sourceTypeTable {
            let drawer = makeDrawer(provenance: Int64(entry.expectedRaw))
            #expect(drawer.sourceType == entry.source,
                "provenance=\(entry.expectedRaw) should decode to \(entry.source)")
        }
    }

    // MARK: - Channel (cookbook §2.5 bits 6-11)

    private static let channelTable: [(channel: Channel, expectedRaw: Int)] = [
        (Channel.uiTyped, 0),
        (Channel.uiVoiced, 1),
        (Channel.mcpAgent, 2),
        (Channel.fileImport, 3),
        (Channel.apiGrounding, 4),
        (Channel.federationInbound, 5),
        (Channel.dreamProposal, 6),
        (Channel.dreamAssociation, 7),
        (Channel.dreamMiningResult, 8),
        (Channel.deviceSensor, 15),
        (Channel.actuatorOutcome, 16),
    ]

    @Test("Channel raw values match cookbook §2.5")
    func channelRawValuesMatchTable() {
        var mismatches: [String] = []
        for entry in Self.channelTable {
            if entry.channel.rawValue != entry.expectedRaw {
                mismatches.append("Channel.\(entry.channel) expected raw=\(entry.expectedRaw), got \(entry.channel.rawValue)")
            }
        }
        if !mismatches.isEmpty {
            Issue.record(Comment(rawValue: "Channel diverges from cookbook §2.5:\n" + mismatches.joined(separator: "\n")))
        }
    }

    @Test("Channel field lives at bits 6-11 (cookbook §2.5)")
    func channelFieldPosition() {
        for entry in Self.channelTable {
            let bitmap = Int64(entry.expectedRaw) << 6
            let drawer = makeDrawer(provenance: bitmap)
            #expect(drawer.channel == entry.channel,
                "provenance=\(bitmap) (\(entry.expectedRaw) << 6) should decode to \(entry.channel)")
        }
    }

    // MARK: - Confirmation (cookbook §2.5 bits 18-23)

    private static let confirmationTable: [(confirmation: LocusKit.Confirmation, expectedRaw: Int)] = [
        (LocusKit.Confirmation.unconfirmed, 0),
        (LocusKit.Confirmation.userConfirmed, 1),
        (LocusKit.Confirmation.automatedConfirmed, 2),
        (LocusKit.Confirmation.peerConfirmed, 3),
        (LocusKit.Confirmation.actuatorConfirmed, 4),
    ]

    @Test("Confirmation raw values match cookbook §2.5")
    func confirmationRawValuesMatchTable() {
        var mismatches: [String] = []
        for entry in Self.confirmationTable {
            if entry.confirmation.rawValue != entry.expectedRaw {
                mismatches.append("Confirmation.\(entry.confirmation) expected raw=\(entry.expectedRaw), got \(entry.confirmation.rawValue)")
            }
        }
        if !mismatches.isEmpty {
            Issue.record(Comment(rawValue: "Confirmation diverges from cookbook §2.5:\n" + mismatches.joined(separator: "\n")))
        }
    }

    @Test("Confirmation field lives at bits 18-23 (cookbook §2.5)")
    func confirmationFieldPosition() {
        for entry in Self.confirmationTable {
            let bitmap = Int64(entry.expectedRaw) << 18
            let drawer = makeDrawer(provenance: bitmap)
            #expect(drawer.confirmation == entry.confirmation,
                "provenance=\(bitmap) (\(entry.expectedRaw) << 18) should decode to \(entry.confirmation)")
        }
    }

    // MARK: - Confidence (cookbook §2.5 bits 24-29, scale-gapped)

    private static let confidenceTable: [(confidence: Confidence, expectedRaw: Int)] = [
        (Confidence.null, 0),
        (Confidence.low, 16),
        (Confidence.medium, 32),
        (Confidence.high, 48),
        (Confidence.verified, 56),
    ]

    @Test("Confidence raw values are scale-gapped per cookbook §2.5")
    func confidenceRawValuesMatchTable() {
        var mismatches: [String] = []
        for entry in Self.confidenceTable {
            if entry.confidence.rawValue != entry.expectedRaw {
                mismatches.append("Confidence.\(entry.confidence) expected raw=\(entry.expectedRaw), got \(entry.confidence.rawValue)")
            }
        }
        if !mismatches.isEmpty {
            Issue.record(Comment(rawValue: "Confidence diverges from cookbook §2.5:\n" + mismatches.joined(separator: "\n")))
        }
    }

    @Test("Confidence field lives at bits 24-29 (cookbook §2.5)")
    func confidenceFieldPosition() {
        for entry in Self.confidenceTable {
            let bitmap = Int64(entry.expectedRaw) << 24
            let drawer = makeDrawer(provenance: bitmap)
            #expect(drawer.confidence == entry.confidence,
                "provenance=\(bitmap) (\(entry.expectedRaw) << 24) should decode to \(entry.confidence)")
        }
    }

    // MARK: - Sensitivity (cookbook §2.5 bits 30-35, scale-gapped)

    private static let sensitivityTable: [(sensitivity: Sensitivity, expectedRaw: Int)] = [
        (Sensitivity.normal, 0),
        (Sensitivity.elevated, 16),
        (Sensitivity.restricted, 32),
        (Sensitivity.secret, 48),
    ]

    @Test("Sensitivity raw values mirror adjective sensitivity per cookbook §2.5")
    func sensitivityRawValuesMatchTable() {
        var mismatches: [String] = []
        for entry in Self.sensitivityTable {
            if entry.sensitivity.rawValue != entry.expectedRaw {
                mismatches.append("Sensitivity.\(entry.sensitivity) expected raw=\(entry.expectedRaw), got \(entry.sensitivity.rawValue)")
            }
        }
        if !mismatches.isEmpty {
            Issue.record(Comment(rawValue: "Sensitivity diverges from cookbook §2.5:\n" + mismatches.joined(separator: "\n")))
        }
    }

    @Test("Sensitivity field lives at bits 30-35 (cookbook §2.5)")
    func sensitivityFieldPosition() {
        for entry in Self.sensitivityTable {
            let bitmap = Int64(entry.expectedRaw) << 30
            let drawer = makeDrawer(provenance: bitmap)
            #expect(drawer.sensitivity == entry.sensitivity,
                "provenance=\(bitmap) (\(entry.expectedRaw) << 30) should decode to \(entry.sensitivity)")
        }
    }

    // MARK: - EnrichmentStatus (cookbook §2.5 bits 36-41, NEW in v0.6)

    private static let enrichmentTable: [(enrichment: EnrichmentStatus, expectedRaw: Int)] = [
        (EnrichmentStatus.none, 0),
        (EnrichmentStatus.qidPending, 1),
        (EnrichmentStatus.qidCompleted, 2),
        (EnrichmentStatus.closureCached, 3),
        (EnrichmentStatus.qidProposed, 4),
    ]

    @Test("EnrichmentStatus raw values match cookbook §2.5 (NEW in v0.6)")
    func enrichmentRawValuesMatchTable() {
        var mismatches: [String] = []
        for entry in Self.enrichmentTable {
            if entry.enrichment.rawValue != entry.expectedRaw {
                mismatches.append("EnrichmentStatus.\(entry.enrichment) expected raw=\(entry.expectedRaw), got \(entry.enrichment.rawValue)")
            }
        }
        if !mismatches.isEmpty {
            Issue.record(Comment(rawValue: "EnrichmentStatus diverges from cookbook §2.5:\n" + mismatches.joined(separator: "\n")))
        }
    }

    @Test("EnrichmentStatus field lives at bits 36-41 (cookbook §2.5)")
    func enrichmentFieldPosition() {
        for entry in Self.enrichmentTable {
            let bitmap = Int64(entry.expectedRaw) << 36
            let drawer = makeDrawer(provenance: bitmap)
            #expect(drawer.enrichmentStatus == entry.enrichment,
                "provenance=\(bitmap) (\(entry.expectedRaw) << 36) should decode to \(entry.enrichment)")
        }
    }

    // MARK: - Full composite (all six axes simultaneously)

    /// sourceType=.observed(1) | channel=.mcpAgent(2)<<6 |
    /// confirmation=.userConfirmed(1)<<18 | confidence=.high(48)<<24 |
    /// sensitivity=.elevated(16)<<30 | enrichmentStatus=.qidCompleted(2)<<36
    @Test("Composite provenance bitmap round-trips through all six accessors (cookbook §2.5)")
    func compositeProvenanceRoundtrip() {
        let raw: Int64 =
            Int64(SourceType.observed.rawValue)
            | (Int64(Channel.mcpAgent.rawValue) << 6)
            | (Int64(LocusKit.Confirmation.userConfirmed.rawValue) << 18)
            | (Int64(Confidence.high.rawValue) << 24)
            | (Int64(Sensitivity.elevated.rawValue) << 30)
            | (Int64(EnrichmentStatus.qidCompleted.rawValue) << 36)

        let drawer = makeDrawer(provenance: raw)
        #expect(drawer.sourceType == .observed)
        #expect(drawer.channel == .mcpAgent)
        #expect(drawer.confirmation == .userConfirmed)
        #expect(drawer.confidence == .high)
        #expect(drawer.sensitivity == .elevated)
        #expect(drawer.enrichmentStatus == .qidCompleted)
        #expect(drawer.isUserConfirmed)
    }
}
