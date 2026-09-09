import Foundation
import LocusKit

// WorkPacketEstateClient — protocol seam for the estate write/read surface.
//
// WorkPacketStore and LineageGraph accept any type conforming to this
// protocol, so tests can supply a mock without a real SQLite estate.
// EstateAdapter adapts a real LocusKit Estate for production use.
//
// NOTE: The protocol uses `listDrawers(_ frame:) -> [Drawer]` (not the
// streaming `Estate.recall`) because `RecallStream.init` is internal to
// LocusKit — tests outside that package cannot construct one. Collecting
// all pages into [Drawer] preserves the same filter/limit/ordering
// semantics while crossing the package boundary cleanly.

// MARK: - WorkPacketEstateClient

/// The estate operations WorkPacketKit requires.
///
/// Callers in production pass `EstateAdapter(estate)`. Tests supply a
/// mock conformance. No LocusKit internals cross this boundary.
public protocol WorkPacketEstateClient: Sendable {

    /// File a new drawer into the estate.
    func capture(_ frame: CaptureFrame) async throws -> Drawer

    /// File a new tunnel (lineage edge) into the estate.
    func captureTunnel(_ frame: TunnelCaptureFrame) async throws -> Tunnel

    /// Return all drawers matching the frame's filters, collected from all
    /// recall pages. The `limit` field in the frame caps the result count.
    func listDrawers(_ frame: RecallFrame) async throws -> [Drawer]

    /// Fetch specific drawers by their row IDs, unfiltered. Used by lineage
    /// traversal, which reports ids only and re-gates them before output.
    func getDrawers(ids: [String]) async throws -> [Drawer]

    /// Fetch specific drawers by their row IDs, returning only those that
    /// pass `frame`'s filter chain (the estate's recall filter pipeline —
    /// state, wing/room, sensitivity ceiling, tombstone exclusion). The
    /// packet read gate (SPEC § 5 B-4) is built on this call.
    func getDrawers(
        ids: [String], matchingFrame frame: RecallFrame,
        preservePhysicalUUIDSpellings: Bool
    ) async throws -> [Drawer]
}

// MARK: - EstateAdapter

/// Production adapter: wraps a LocusKit `Estate` actor and forwards calls
/// to the WorkPacketEstateClient protocol surface.
///
/// Constructed once per store at the callsite that opens the estate:
/// ```swift
/// let store = WorkPacketStore(client: EstateAdapter(estate))
/// ```
public struct EstateAdapter: WorkPacketEstateClient {

    private let estate: Estate

    public init(_ estate: Estate) {
        self.estate = estate
    }

    public func capture(_ frame: CaptureFrame) async throws -> Drawer {
        try await estate.capture(frame)
    }

    public func captureTunnel(_ frame: TunnelCaptureFrame) async throws -> Tunnel {
        try await estate.capture(frame)
    }

    /// Collects all pages from `Estate.recall` into a flat array, respecting
    /// the frame's `limit` field as a ceiling on total returned rows.
    public func listDrawers(_ frame: RecallFrame) async throws -> [Drawer] {
        let stream = await estate.recall(frame)
        var results: [Drawer] = []
        for await page in stream {
            results.append(contentsOf: page.rows)
        }
        return results
    }

    public func getDrawers(ids: [String]) async throws -> [Drawer] {
        try await estate.getDrawers(ids: ids)
    }

    /// Frame-gated by-id load: `Estate.getDrawers(ids:matchingFrame:hydrationLevel:)`
    /// runs the exact recall filter pipeline over the loaded rows; only the
    /// `admissible` subset is returned. Packets are read at `.full` hydration
    /// because the caller decodes the JSON body.
    public func getDrawers(
        ids: [String], matchingFrame frame: RecallFrame,
        preservePhysicalUUIDSpellings: Bool
    ) async throws -> [Drawer] {
        try await estate.getDrawers(
            ids: ids, matchingFrame: frame, hydrationLevel: .full,
            preservePhysicalUUIDSpellings: preservePhysicalUUIDSpellings
        ).admissible
    }
}
