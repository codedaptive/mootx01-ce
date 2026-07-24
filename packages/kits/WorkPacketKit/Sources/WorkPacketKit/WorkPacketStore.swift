import Foundation
import LocusKit

// WorkPacketStore — drawer-backed work-packet persistence.
//
// Packets are stored as the content of LocusKit drawers:
//   kind  = .structuredJSON
//   room  = WorkPacketStore.room  ("work-packets")
//   wing  = caller-supplied (defaults to "Agentic Memory")
//   UDC   = "004" (Computer Science / Data Processing — default per spec I-5)
//
// Lineage atomicity policy (Kong binding condition, FAB5-I1):
//   JSON lineageLinks are the source of truth. Tunnels are a best-effort
//   index for the estate's graph machinery (ARIA, NeuronKit topology).
//   The estate's `capture` verbs are not transactional across noun types,
//   so a tunnel write failure after the drawer capture succeeds does NOT
//   cause the store to throw — the packet is durably filed; the tunnel is
//   dropped silently. LineageGraph traces antecedents via JSON, not tunnels.
//   A future reconciliation pass can re-file missing tunnels from the JSON.
//
// All persistence routes through WorkPacketEstateClient — no direct SQL.

// MARK: - WorkPacketStore

/// Actor that stores and retrieves work packets over the estate substrate.
public actor WorkPacketStore {

    // MARK: Constants

    /// Room within the estate where work-packet drawers are filed.
    public static let room: String = "work-packets"

    /// Actor identifier stamped on drawers and tunnels filed by this store.
    static let addedBy: String = "WorkPacketKit"

    /// Placeholder model ID for the modelID-tagging contract (invariant I-4).
    /// WorkPacketKit does not generate embeddings; this placeholder satisfies
    /// the non-empty requirement so a future model bump can compare correctly.
    static let embeddingModelID: String = "none"

    /// UDC 004 = "Computer Science / Data Processing". Agentic work records
    /// are classification 004 content per the UDC hierarchy.
    static let udcCode: String = "004"

    // MARK: State

    private let client: any WorkPacketEstateClient
    private let wing: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: Init

    /// - Parameters:
    ///   - client: estate operation surface (use `EstateAdapter` in production).
    ///   - wing: wing within the estate to file packets into. Defaults to
    ///     `defaultWingName` ("Agentic Memory").
    public init(client: any WorkPacketEstateClient, wing: String = defaultWingName) {
        self.client = client
        self.wing = wing
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - store

    /// Encode a `WorkPacket` as JSON and file it as a drawer.
    ///
    /// If `packet.lineageLinks` is non-empty, tunnels are also filed as a
    /// best-effort index (see atomicity policy in file header — JSON is
    /// the source of truth; a tunnel write failure does not roll back the
    /// drawer capture).
    ///
    /// - Parameters:
    ///   - packet: the packet to persist.
    ///   - now: capture timestamp. Pass `Date()` at the call site; internal
    ///     paths that need determinism pass a fixed value (CLAUDE.md rule).
    ///   - latticeAnchor: optional override for the UDC anchor. Defaults to
    ///     `LatticeAnchor.udc("004")` (Computer Science — default for agentic
    ///     work records). Supply a domain-specific anchor when the packet
    ///     describes content in a different UDC class.
    /// - Returns: the drawer ID of the filed packet, which equals `packet.id`.
    @discardableResult
    public func store(
        _ packet: WorkPacket,
        now: Date,
        latticeAnchor: LatticeAnchor? = nil
    ) async throws -> String {
        let jsonData = try encoder.encode(packet)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw WorkPacketKitError.encodingFailure("UTF-8 encoding failed for packet \(packet.id)")
        }

        // .actuator = agent-driven (actuator-driven) capture — raw 5 per cookbook §2.4.
        var frame = CaptureFrame(
            content: jsonString,
            channel: .actuator,
            room: WorkPacketStore.room,
            latticeAnchor: latticeAnchor ?? .udc(WorkPacketStore.udcCode),
            addedBy: WorkPacketStore.addedBy,
            embeddingModelID: WorkPacketStore.embeddingModelID
        )
        frame.kind = ContentKind.structuredJSON
        frame.wing = wing
        frame.eventTime = now

        _ = try await client.capture(frame)

        // Best-effort tunnel filing — tunnel failure does not roll back the drawer.
        for link in packet.lineageLinks {
            try? await storeTunnel(
                sourcePacketID: packet.id,
                link: link
            )
        }

        return packet.id
    }

    // MARK: - fetch

    /// Fetch and decode a single work packet by its drawer ID.
    ///
    /// Returns `nil` when no drawer with that ID exists in the estate.
    public func fetch(drawerID: String) async throws -> WorkPacket? {
        let drawers = try await client.getDrawers(ids: [drawerID])
        guard let drawer = drawers.first else { return nil }
        return try decodePacket(from: drawer)
    }

    // MARK: - list

    /// List all currently-believed work packets in the configured wing and room.
    ///
    /// Returns packets in descending capture-time order (newest first), up to
    /// `limit` rows. `nil` limit returns all matching packets.
    public func list(limit: Int? = nil) async throws -> [WorkPacket] {
        let frame = RecallFrame(
            filterChain: [.currentlyBelieve, .inWing(wing), .inRoom(WorkPacketStore.room)],
            hydrationLevel: .full,
            limit: limit,
            ordering: .byCaptureTimeDesc
        )
        let drawers = try await client.listDrawers(frame)
        return drawers.compactMap { try? decodePacket(from: $0) }
    }

    // MARK: - Private

    /// Decode a WorkPacket from a drawer's content field.
    private func decodePacket(from drawer: Drawer) throws -> WorkPacket {
        guard let data = drawer.content.data(using: .utf8) else {
            throw WorkPacketKitError.decodingFailure("drawer \(drawer.id) content is not valid UTF-8")
        }
        return try decoder.decode(WorkPacket.self, from: data)
    }

    /// File a lineage tunnel from a source packet to the link target.
    private func storeTunnel(sourcePacketID: String, link: LineageLink) async throws {
        let kind: TunnelKind = switch link.kind {
        case .derivesFrom: .derivesFrom
        case .respondsTo:  .respondsTo
        }

        let frame = TunnelCaptureFrame(
            sourceWing: wing,
            sourceRoom: WorkPacketStore.room,
            targetWing: wing,
            targetRoom: WorkPacketStore.room,
            label: link.kind.rawValue,
            addedBy: WorkPacketStore.addedBy,
            sourceDrawerId: sourcePacketID,
            targetDrawerId: link.targetPacketID,
            kind: kind,
            originClass: .derived
        )
        _ = try await client.captureTunnel(frame)
    }
}
