// PacketsHandlers.swift
//
// Wire types and PacketsEngine for GET /api/packets, /api/packets/:id,
// and /api/packets/:id/lineage.
//
// Exportability invariant: only LocusKit drawers marked .public_ appear on
// any /api/packets* surface. Non-exportable drawers (the LocusKit default,
// .private_) are silently excluded at the RecallFrame filter layer. This is
// the content-safety boundary — WorkPacket drawers that agents have not
// explicitly marked exportable never cross the read API.
//
// PacketsEngine is injectable via WorkPacketEstateClient so tests can drive
// it with a mock client rather than a real SQLite estate.

import Foundation
import WorkPacketKit
import LocusKit

// MARK: - Wire types

/// Summary of a single work packet for the Packets list view.
/// Metadata only — claim statements and source URIs are excluded.
public struct PacketSummaryPayload: Encodable, Sendable {
    /// Estate-assigned drawer ID (not the packet's own UUID).
    public let drawerID: String
    /// The packet's own stable UUID (`WorkPacket.id`).
    public let packetID: String
    /// Agent-authored objective string.
    public let objective: String
    /// Provenance agent identifier.
    public let agent: String
    /// Provenance model identifier.
    public let model: String
    /// ISO-8601 creation timestamp from `WorkPacketProvenance.createdAt`.
    public let createdAt: String
    /// Number of claims in this packet.
    public let claimCount: Int
    /// Number of lineage links (derivesFrom / respondsTo edges).
    public let lineageLinkCount: Int
}

/// Envelope for the GET /api/packets list response.
public struct PacketsPayload: Encodable, Sendable {
    /// True when the packets engine is not configured on this host.
    public let pending: Bool
    /// Exportable work packets, newest first, up to the requested limit.
    public let packets: [PacketSummaryPayload]

    public init(pending: Bool, packets: [PacketSummaryPayload]) {
        self.pending = pending
        self.packets = packets
    }
}

/// Detail view for a single work packet (GET /api/packets/:id).
/// Metadata and counts — full content not surfaced through the read API.
public struct PacketDetailPayload: Encodable, Sendable {
    public let drawerID: String
    public let packetID: String
    public let objective: String
    public let agent: String
    public let model: String
    public let createdAt: String
    public let updatedAt: String
    /// Count of claim entries (not their text — content-safety).
    public let claimCount: Int
    /// Count of source references.
    public let sourceCount: Int
    /// Count of uncertainty strings.
    public let uncertaintyCount: Int
    /// Count of next-step strings.
    public let nextStepCount: Int
    /// Typed lineage edges embedded in the packet JSON.
    public let lineageLinks: [LineageLinkWirePayload]
}

/// Lineage-only view for a work packet (GET /api/packets/:id/lineage).
public struct PacketLineagePayload: Encodable, Sendable {
    /// The drawer ID of the packet whose lineage is listed.
    public let drawerID: String
    /// Typed lineage edges from the packet's embedded JSON (source of truth).
    public let links: [LineageLinkWirePayload]
}

/// A single typed lineage edge from a work packet.
public struct LineageLinkWirePayload: Encodable, Sendable {
    /// `"derivesFrom"` or `"respondsTo"`.
    public let kind: String
    /// Estate-assigned drawer ID of the antecedent packet.
    public let targetPacketID: String
}

// MARK: - PacketsEngine

/// Actor for work-packet read access over the estate substrate.
///
/// Applies the exportability filter: only drawers marked `.public_` in their
/// LocusKit adjective bitmap are surfaced. `.private_` drawers (the LocusKit
/// default) are silently excluded from all read surfaces per the
/// no-memory-bodies policy.
///
/// Constructed with any `WorkPacketEstateClient` conformer — use
/// `EstateAdapter(estate)` in production; supply a mock in tests.
public actor PacketsEngine {

    private let client: any WorkPacketEstateClient
    private let wing: String
    private let decoder: JSONDecoder

    // exportability bit for .public_ (raw 32) shifted into bits 12–17.
    // Used by the mock client; the real estate evaluates Filter.exportable via SQL.
    static let exportabilityPublicBit: Int64 = Int64(32) << 12

    public init(client: any WorkPacketEstateClient,
                wing: String = LocusKit.defaultWingName) {
        self.client = client
        self.wing = wing
        self.decoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }()
    }

    // MARK: - List

    /// Return exportable work packets, newest first, up to `limit`.
    ///
    /// The `Filter.exportable` case in the RecallFrame filterChain ensures only
    /// drawers with `adjectiveBitmap` bits 12–17 equal to `AdjectiveExportability
    /// .public_` (raw 32) are returned. Non-exportable packets are silently absent.
    public func list(limit: Int? = nil) async throws -> PacketsPayload {
        let frame = RecallFrame(
            filterChain: [.currentlyBelieve, .exportable, .inWing(wing), .inRoom(WorkPacketStore.room)],
            hydrationLevel: .full,
            limit: limit,
            ordering: .byCaptureTimeDesc
        )
        let drawers = try await client.listDrawers(frame)
        let summaries = drawers.compactMap { summarise(drawerID: $0.id, content: $0.content) }
        return PacketsPayload(pending: false, packets: summaries)
    }

    // MARK: - Fetch

    /// Fetch a single exportable work packet by its drawer ID.
    ///
    /// Returns `nil` when the drawer is absent OR when it is non-exportable
    /// (exportability != .public_). The caller receives no signal distinguishing
    /// the two cases — both surface as 404.
    public func fetch(drawerID: String) async throws -> PacketDetailPayload? {
        let drawers = try await client.getDrawers(ids: [drawerID])
        guard let drawer = drawers.first else { return nil }
        // Enforce exportability at the fetch level so direct-ID lookups
        // cannot bypass the list-level filter.
        guard drawer.exportability == .public_ else { return nil }
        guard let packet = try? decode(content: drawer.content) else { return nil }
        return PacketDetailPayload(
            drawerID: drawer.id,
            packetID: packet.id,
            objective: packet.objective,
            agent: packet.provenance.agent,
            model: packet.provenance.model,
            createdAt: iso8601(packet.provenance.createdAt),
            updatedAt: iso8601(packet.provenance.updatedAt),
            claimCount: packet.claims.count,
            sourceCount: packet.sources.count,
            uncertaintyCount: packet.uncertainties.count,
            nextStepCount: packet.nextSteps.count,
            lineageLinks: packet.lineageLinks.map(wireLink)
        )
    }

    // MARK: - Lineage

    /// Return the lineage links for an exportable work packet.
    ///
    /// Reads `WorkPacket.lineageLinks` (the embedded JSON, which is the source
    /// of truth per the atomicity policy in WorkPacketStore.swift). Returns `nil`
    /// when the drawer is absent or non-exportable.
    public func lineage(drawerID: String) async throws -> PacketLineagePayload? {
        let drawers = try await client.getDrawers(ids: [drawerID])
        guard let drawer = drawers.first else { return nil }
        guard drawer.exportability == .public_ else { return nil }
        guard let packet = try? decode(content: drawer.content) else { return nil }
        return PacketLineagePayload(drawerID: drawerID,
                                   links: packet.lineageLinks.map(wireLink))
    }

    // MARK: - Private helpers

    private func summarise(drawerID: String, content: String) -> PacketSummaryPayload? {
        guard let packet = try? decode(content: content) else { return nil }
        return PacketSummaryPayload(
            drawerID: drawerID,
            packetID: packet.id,
            objective: packet.objective,
            agent: packet.provenance.agent,
            model: packet.provenance.model,
            createdAt: iso8601(packet.provenance.createdAt),
            claimCount: packet.claims.count,
            lineageLinkCount: packet.lineageLinks.count
        )
    }

    private func decode(content: String) throws -> WorkPacket {
        guard let data = content.data(using: .utf8) else {
            throw PacketsEngineError.invalidContent
        }
        return try decoder.decode(WorkPacket.self, from: data)
    }

    private func wireLink(_ link: LineageLink) -> LineageLinkWirePayload {
        LineageLinkWirePayload(kind: link.kind.rawValue,
                               targetPacketID: link.targetPacketID)
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - PacketsEngineError

enum PacketsEngineError: Error {
    case invalidContent
}
