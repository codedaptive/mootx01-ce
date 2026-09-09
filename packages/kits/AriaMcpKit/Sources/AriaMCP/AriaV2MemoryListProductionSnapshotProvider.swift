import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit

/// The selected surface supplies this authority. ARIA never fabricates an
/// authorization generation from process state or a grant snapshot.
public struct AriaV2MemoryListAuthorizationState: Sendable, Equatable {
    public let estateID: UUID
    public let callerID: String
    public let contextID: String
    public let policyVersion: String
    public let generation: String

    public init(estateID: UUID, callerID: String, contextID: String, policyVersion: String, generation: String) {
        self.estateID = estateID
        self.callerID = callerID
        self.contextID = contextID
        self.policyVersion = policyVersion
        self.generation = generation
    }
}

/// Read and authorize the selected caller's current memory-list state.
/// Implementations must return a new state on every invocation so the caller
/// can detect authorization changes around immutable snapshot acquisition.
public protocol AriaV2MemoryListAuthorizationAuthority: Sendable {
    func authorizeMemoryList(
        estateID: UUID,
        authorization: AriaV2MemoryListAuthorization
    ) async throws -> AriaV2MemoryListAuthorizationState
}

public enum AriaV2MemoryListProductionSnapshotError: Error, Sendable, Equatable {
    case authorizationMismatch
    case authorizationChanged
    case handleEstateMismatch
    case invalidMemoryID
}

/// Production bridge from the lower immutable snapshot seam to the v2 memory
/// list provider. The selected surface owns registration, the live
/// authorization authority, and service construction.
public struct AriaV2MemoryListProductionSnapshotProvider: AriaV2MemoryListSnapshotProvider, Sendable {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle
    public let authorizationAuthority: any AriaV2MemoryListAuthorizationAuthority

    public init(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        authorizationAuthority: any AriaV2MemoryListAuthorizationAuthority
    ) {
        self.kit = kit
        self.handle = handle
        self.authorizationAuthority = authorizationAuthority
    }

    public func immutableAuthorizedSnapshot(
        estateID: UUID,
        wing: String,
        room: String?,
        filter: String?,
        authorization: AriaV2MemoryListAuthorization
    ) async throws -> AriaV2MemoryListSnapshot {
        let before = try await checkedAuthorization(estateID: estateID, authorization: authorization)
        guard handle.estateUUID == before.estateID else {
            throw AriaV2MemoryListProductionSnapshotError.handleEstateMismatch
        }

        // Preserve InventorySnapshotError verbatim so the list service can map
        // both row and byte bounds to inventory_too_large without a page.
        let rawSnapshot = try await kit.captureInventorySnapshot(for: handle)

        let afterCapture = try await checkedAuthorization(estateID: estateID, authorization: authorization)
        guard afterCapture == before else {
            throw AriaV2MemoryListProductionSnapshotError.authorizationChanged
        }

        // Decode the complete bounded snapshot before filtering. A corrupt row
        // therefore fails the whole request instead of disappearing from a page.
        let inventory = try LocusInventorySnapshotInterpreter.decode(rawSnapshot)
        let rows = try inventory.drawers.compactMap { record -> AriaV2MemoryListRow? in
            try project(record, wing: wing, room: room, filter: filter)
        }

        let beforeReturn = try await checkedAuthorization(estateID: estateID, authorization: authorization)
        guard beforeReturn == before else {
            throw AriaV2MemoryListProductionSnapshotError.authorizationChanged
        }
        return .init(estateID: before.estateID, authorizationGeneration: before.generation, rows: rows)
    }

    private func checkedAuthorization(
        estateID: UUID,
        authorization: AriaV2MemoryListAuthorization
    ) async throws -> AriaV2MemoryListAuthorizationState {
        let state = try await authorizationAuthority.authorizeMemoryList(
            estateID: estateID, authorization: authorization)
        guard state.estateID == estateID,
              state.callerID == authorization.callerID,
              state.contextID == authorization.contextID,
              state.policyVersion == authorization.policyVersion,
              !state.generation.isEmpty else {
            throw AriaV2MemoryListProductionSnapshotError.authorizationMismatch
        }
        return state
    }

    private func project(
        _ record: LocusInventorySnapshotDrawer,
        wing requestedWing: String,
        room requestedRoom: String?,
        filter: String?
    ) throws -> AriaV2MemoryListRow? {
        let drawer = record.drawer
        // Capture provenance is immutable and independently sensitivity-tagged.
        // Read the raw six-bit field so reserved values fail closed instead of
        // inheriting the general provenance accessor's legacy Normal fallback.
        guard Self.isPublicCaptureProvenance(drawer.provenance) else {
            return nil
        }
        guard let memoryID = UUID(uuidString: drawer.id) else {
            throw AriaV2MemoryListProductionSnapshotError.invalidMemoryID
        }
        // This is the established memory-list posture. It is intentionally
        // independent of any grant: restricted and secret rows never cross
        // this bulk-export endpoint.
        guard drawer.tombstonedAt == nil,
              !drawer.isKnewPast,
              !drawer.isTerminal,
              drawer.adjectiveSensitivity.isBulkExportable,
              record.ancestry.count == 3 else {
            return nil
        }
        let wing = record.ancestry[1]
        let room = record.ancestry[2]
        guard wing.displayName == requestedWing,
              requestedRoom == nil || room.displayName == requestedRoom else {
            return nil
        }
        if filter == "missing_subject" {
            guard drawer.subject == nil else { return nil }
        } else if filter != nil {
            return nil
        }

        let ancestry = Array(record.ancestry.dropFirst())
        var projection: [String: JSONValue] = [
            "fetch": .object([
                "tool": .string("moot_memory_get"),
                "arguments": .object([
                    "memory_id": .string(AriaV2ArgumentDecoder.canonicalUUID(memoryID)),
                ]),
            ]),
        ]
        if filter != "missing_subject" {
            projection["provenance"] = .string(canonicalProvenance(drawer.sourceType))
            if let subject = drawer.subject {
                projection["subject"] = .string(AriaV2Envelope.compactText(subject))
            }
        }
        return .init(
            memoryID: memoryID,
            ancestryIDs: ancestry.map(\.id),
            ancestryNames: ancestry.map(\.displayName),
            eligibilityState: "current",
            visibilityState: "bulk_exportable",
            projection: projection
        )
    }

    static func isPublicCaptureProvenance(_ provenance: Int64) -> Bool {
        matchesPublicCaptureSensitivity(Int((provenance >> 30) & 0x3f))
    }

    private static func matchesPublicCaptureSensitivity(_ raw: Int) -> Bool {
        raw == 0 || raw == 16
    }

    private func canonicalProvenance(_ sourceType: SourceType) -> String {
        switch sourceType {
        case .user: return "user"
        case .observed: return "observed"
        case .imported: return "imported"
        case .canonical: return "canonical"
        case .derived: return "derived"
        case .federationAggregate: return "federation_aggregate"
        case .tierAggregate: return "tier_aggregate"
        case .pairedEstate: return "paired_estate"
        case .ambient: return "ambient"
        case .actuator: return "actuator"
        }
    }
}
