// ReviewHandlers.swift
//
// Wire type and payload builder for GET /api/review.
//
// The Review pane surfaces a high-level summary of recent estate activity
// from the ObserverSink stats store — estate count, capture count, and a
// short event feed. Metadata only; no rung or memory content crosses this
// surface (GUI SPEC §10, HTTPReadAPI.swift SECURITY BOUNDARY).

import Foundation
import ObserverSink

// MARK: - ReviewPayload (GET /api/review)

/// Summary of recent estate activity for the Review dashboard pane.
///
/// Metadata only — no rung or memory content. Mirrors the content-safety
/// invariant applied to every other read-plane endpoint.
public struct ReviewPayload: Encodable, Sendable {
    /// True when the manager has not been started (store unavailable).
    public let pending: Bool
    /// Count of distinct estates that have emitted events.
    public let estateCount: Int
    /// Total capture-kind events in the store.
    public let captureCount: Int
    /// Recent events, newest first, capped at `limit` (default 20).
    public let recentEvents: [EventPayload]

    public init(pending: Bool, estateCount: Int, captureCount: Int,
                recentEvents: [EventPayload]) {
        self.pending = pending
        self.estateCount = estateCount
        self.captureCount = captureCount
        self.recentEvents = recentEvents
    }
}

// MARK: - MootManager review builder

extension MootManager {

    /// Build the `GET /api/review` payload: recent estate activity summary.
    ///
    /// Reads from the ObserverSink stats store. On an empty store (no events
    /// yet) returns a valid payload with zero counts — the pane renders an
    /// empty state rather than an error.
    ///
    /// CONTENT-SAFETY: only event metadata (timestamp, kind, nounType, estate,
    /// dropbox, drawerID) crosses this surface. No rung or memory content.
    ///
    /// - Parameter limit: Maximum recent events to include. Default 20.
    /// - Throws: `ManagerError.notStarted` when the manager has not been started.
    public func reviewPayload(limit: Int = 20) async throws -> ReviewPayload {
        let store = try statsStore()
        let events = try await store.queryEvents(dropboxID: nil)
        let estateCount = Set(events.map { $0.estate }).count
        let captureCount = events.filter { $0.kind == "capture" }.count
        let recent = Array(events.suffix(max(0, limit)).reversed())
        return ReviewPayload(
            pending: false,
            estateCount: estateCount,
            captureCount: captureCount,
            recentEvents: recent.map(Self.projectEvent)
        )
    }
}
