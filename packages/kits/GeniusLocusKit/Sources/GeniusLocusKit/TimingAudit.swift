// TimingAudit.swift
//
// C3/A6 (benchmark reset 2026-08-13): the composition-layer seam that lets
// the ARIA surface page an estate's audit log for the timing derivation
// (`moot_timing_report`). GLK adds handle validation only — the scan itself
// is LocusKit's `Estate.auditEvents(after:limit:)` pass-through to
// PersistenceKit's HLC-ordered `AuditLog.iterate`. The derivation engine
// (NeuronKit `deriveTimings`) is pure; callers above this seam map events
// and keep the watermark, so no timing state lives in the substrate.

import Foundation
import LocusKit
// Scoped imports: AuditEvent and the HLC cursor live in SubstrateTypes; a
// blanket import would collide with LocusKit on LatticeAnchor.
import struct SubstrateTypes.AuditEvent
import struct SubstrateTypes.HLC

extension GeniusLocusKit {
    /// Estate-wide audit page in HLC order, strictly after `after` (nil =
    /// from the beginning), capped at `limit` events.
    ///
    /// Read-only and safe to call while drains run — the audit log is
    /// append-only, so a page is a consistent prefix snapshot.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    public func auditEvents(
        _ handle: EstateHandle, after: HLC?, limit: Int
    ) async throws -> [AuditEvent] {
        let estate = try estate(for: handle)
        return try await estate.auditEvents(after: after, limit: limit)
    }
}
