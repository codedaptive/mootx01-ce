// MockPacketsClient.swift
//
// In-process WorkPacketEstateClient stub for PacketsEngine tests.
//
// Respects the RecallFrame filterChain entries that PacketsEngine uses:
//   .exportable       — bits 12–17 of adjectiveBitmap must equal public_ (32)
//   .currentlyBelieve — bits 0–5 of adjectiveBitmap must encode a Cluster A state
//                       (active=0, pending=1, contested=2, accepted=3; value < 16)
//   .inWing(name)     — drawer must have been planted with a matching wing
//   .inRoom(name)     — drawer must have been planted with a matching room
//
// The mock tracks wing and room alongside each drawer via a parallel dictionary
// because Drawer itself does not carry resolved display names (they live in the
// node tree that the mock omits). The real estate resolves names via
// resolveNodeNames; the mock side-steps that by storing the names at plant time.

import Foundation
import LocusKit
import WorkPacketKit

// MARK: - MockPacketsClient

/// In-process WorkPacketEstateClient stub for PacketsEngine tests.
///
/// `plant` stores drawers in memory with explicit wing, room, and state
/// values. `getDrawers(ids:matchingFrame:)` applies the full filter chain
/// used by PacketsEngine — currently believed, exportable, inWing, inRoom —
/// so tests can assert that each predicate gates the read path independently.
final class MockPacketsClient: WorkPacketEstateClient, @unchecked Sendable {

    // MARK: - Storage

    private var drawers: [String: Drawer] = [:]

    // Wing and room are stored separately because Drawer does not carry
    // resolved display names; the real estate resolves them from the node
    // tree via resolveNodeNames. The mock stores them at plant time.
    private var drawerWing: [String: String] = [:]
    private var drawerRoom: [String: String] = [:]

    // MARK: - WorkPacketEstateClient

    func capture(_ frame: CaptureFrame) async throws -> Drawer {
        let drawer = Drawer(
            content: frame.content,
            parentNodeId: "room-node",
            addedBy: frame.addedBy,
            filedAt: Self.epoch,
            embeddingModelID: frame.embeddingModelID,
            udcCode: frame.latticeAnchor.udcCode
        )
        drawers[drawer.id] = drawer
        return drawer
    }

    func captureTunnel(_ frame: TunnelCaptureFrame) async throws -> Tunnel {
        Tunnel(
            id: UUID().uuidString,
            sourceWing: frame.sourceWing,
            sourceRoom: frame.sourceRoom,
            sourceDrawerId: frame.sourceDrawerId,
            targetWing: frame.targetWing,
            targetRoom: frame.targetRoom,
            targetDrawerId: frame.targetDrawerId,
            label: frame.label,
            kind: frame.kind,
            adjectiveBitmap: 0,
            operationalBitmap: 0,
            provenanceBitmap: 0,
            addedBy: frame.addedBy,
            filedAt: Self.epoch
        )
    }

    /// Return stored drawers, filtered by the `.exportable` case in the frame.
    ///
    /// The `.exportable` filter checks whether bits 12–17 of `adjectiveBitmap`
    /// equal `AdjectiveExportability.public_.rawValue` (32). This mirrors the
    /// SQL evaluation the real estate performs for this filterChain entry.
    func listDrawers(_ frame: RecallFrame) async throws -> [Drawer] {
        let wantExportable = frame.filterChain.contains {
            if case .exportable = $0 { return true }
            return false
        }
        var results = drawers.values.filter { drawer in
            guard wantExportable else { return true }
            // exportability field occupies bits 12–17; .public_ raw value is 32.
            return (drawer.adjectiveBitmap >> 12) & 0x3F == 32
        }
        .sorted { $0.filedAt > $1.filedAt }
        if let limit = frame.limit {
            results = Array(results.prefix(limit))
        }
        return results
    }

    /// Unfiltered by-id fetch. Used by lineage traversal within WorkPacketKit
    /// (LineageGraph), which applies its own re-gate before output. Not used
    /// by the moot-mgr packets handlers — those use `getDrawers(ids:matchingFrame:)`.
    func getDrawers(ids: [String]) async throws -> [Drawer] {
        ids.compactMap { drawers[$0] }
    }

    /// Frame-gated by-id read. Applies the full set of filterChain predicates
    /// that `PacketsEngine` uses: `.currentlyBelieve`, `.exportable`,
    /// `.inWing`, and `.inRoom`. A drawer that passes all active predicates is
    /// returned; one that fails any predicate is absent from the result —
    /// indistinguishable from a drawer that does not exist.
    func getDrawers(
        ids: [String], matchingFrame frame: RecallFrame, preservePhysicalUUIDSpellings: Bool
    ) async throws -> [Drawer] {
        let wantCurrentlyBelieve = frame.filterChain.contains {
            if case .currentlyBelieve = $0 { return true }
            return false
        }
        let wantExportable = frame.filterChain.contains {
            if case .exportable = $0 { return true }
            return false
        }
        var wantWing: String? = nil
        var wantRoom: String? = nil
        for filter in frame.filterChain {
            if case .inWing(let w) = filter { wantWing = w }
            if case .inRoom(let r) = filter { wantRoom = r }
        }

        return ids.compactMap { drawers[$0] }.filter { drawer in
            // .currentlyBelieve — bits 0–5 of adjectiveBitmap encode State.
            // Cluster A (active=0, pending=1, contested=2, accepted=3) has raw
            // values 0–3, all less than 16 (Cluster B boundary).
            if wantCurrentlyBelieve {
                let stateRaw = Int(drawer.adjectiveBitmap & 0x3F)
                // (stateRaw >> 4) & 0x3 == 0 means Cluster A.
                guard (stateRaw >> 4) & 0x3 == 0 else { return false }
            }
            // .exportable — bits 12–17 of adjectiveBitmap must be .public_ (32).
            if wantExportable {
                guard (drawer.adjectiveBitmap >> 12) & 0x3F == 32 else { return false }
            }
            // .inWing — drawer wing must match.
            if let wing = wantWing {
                guard drawerWing[drawer.id] == wing else { return false }
            }
            // .inRoom — drawer room must match.
            if let room = wantRoom {
                guard drawerRoom[drawer.id] == room else { return false }
            }
            return true
        }
    }

    // MARK: - Test helpers

    /// Plant a pre-encoded WorkPacket content string as a drawer.
    ///
    /// - Parameters:
    ///   - id:         Drawer ID. Defaults to a fresh UUID.
    ///   - content:    JSON-encoded WorkPacket string.
    ///   - exportable: When true, stamps adjectiveBitmap with .public_ (bits 12–17 = 32).
    ///                 When false (default), adjectiveBitmap is 0 (.private_).
    ///   - wing:       Wing name for .inWing filter matching. Defaults to the
    ///                 estate's default wing (LocusKit.defaultWingName).
    ///   - room:       Room name for .inRoom filter matching. Defaults to
    ///                 WorkPacketStore.room ("work-packets").
    ///   - state:      Raw State value for the adjectiveBitmap bits 0–5. Defaults
    ///                 to 0 (.active, Cluster A — currently believed). Pass
    ///                 State.withdrawn.rawValue (18) or State.superseded.rawValue
    ///                 (16) to plant a non-currently-believed drawer.
    @discardableResult
    func plant(id: String = UUID().uuidString,
               content: String,
               exportable: Bool,
               wing: String = LocusKit.defaultWingName,
               room: String = WorkPacketStore.room,
               state: Int = 0) -> Drawer {
        // exportability at bits 12–17: .public_ = 32 << 12.
        var bitmap: Int64 = exportable ? (Int64(32) << 12) : 0
        // state at bits 0–5.
        bitmap |= Int64(state) & 0x3F
        let drawer = Drawer(
            id: id,
            content: content,
            parentNodeId: "room-node",
            addedBy: "MockPacketsClient",
            filedAt: Self.epoch,
            embeddingModelID: "none",
            adjectiveBitmap: bitmap
        )
        drawers[id] = drawer
        drawerWing[id] = wing
        drawerRoom[id] = room
        return drawer
    }

    // MARK: - Private

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
}
