// AuditProbe.swift
//
// Internal audit probe helpers used by the autonomic governor's cheap
// change-detection checks (ADR025-AUDITLOG-GOVERNOR O(N) RAM fixes).
//
// Visibility: public, not internal. The governor lives in NeuronKit, a
// different module from GeniusLocusKit, so it cannot reach `internal` methods.
// These methods are deliberately narrow (audit event count only — no row data)
// and documented as governor-specific. Callers outside the governor should
// prefer the full audit query API (Bug 1 additions to GeniusLocusKit.swift)
// unless they specifically need the cheap change-detection probe.
//
// Design: `Storage.auditLog.count()` is a single SQL `COUNT(*)` call —
// O(1) index scan, zero row data returned. It serves as a reliable
// change-detection watermark: if the count hasn't changed since the last
// governor compute, no new audit events have been appended, so cached
// governor outputs remain valid. No HLC round-trip is needed.
//
// Alternative considered: `iterate(after: lastHLC, rowID: nil, limit: 1)` —
// the `after: HLC` probe approach described in the mission. Accurate, but
// requires persisting and round-tripping an HLC struct (Codable, but extra
// JSON overhead vs a plain Int). `count()` is simpler for this use-case;
// if two separate processes append at the same tick the count still advances.
// Chosen for simplicity. If `AuditLog` gains `latestHLC()` in a future
// mission, migrate — but count works correctly today.

import Foundation

extension GeniusLocusKit {

    /// Returns `true` if the audit log for `handle` has grown since `savedCount`
    /// audit events were observed.
    ///
    /// Used by the autonomic governor as a cheap change-detection check before
    /// triggering an expensive full-estate load (topology / centrality / preference):
    ///
    ///     let changed = try await kit.hasAuditGrown(for: handle, since: savedCount)
    ///     guard changed else {
    ///         // Re-register from cache, no recompute needed.
    ///         await kit.registerGraphCache(cachedScores, for: handle)
    ///         return
    ///     }
    ///     // ... full load + recompute path ...
    ///
    /// When `savedCount` is `nil`, the estate has never been probed — returns
    /// `true` (safe direction: first run always computes). When the estate is
    /// not open (`storages[handle]` is nil), returns `true` (conservative:
    /// assume data may have changed rather than serving stale cache).
    ///
    /// - Complexity: O(1) — issues a single `SELECT COUNT(*) FROM _storagekit_audit`
    ///   against the audit table. No row data is returned.
    ///
    /// - Parameters:
    ///   - handle:     The open estate to probe.
    ///   - savedCount: The event count recorded after the last successful governor
    ///                 compute. Pass `nil` to force recompute on the first run.
    /// - Returns: `true` if new events exist (recompute needed); `false` if
    ///   the estate is unchanged (cache is valid).
    public func hasAuditGrown(for handle: EstateHandle, since savedCount: Int?) async throws -> Bool {
        guard let savedCount else {
            // First run — no baseline to compare against.
            return true
        }
        guard let storage = storages[handle] else {
            // Estate not open — conservative: assume changed.
            return true
        }
        let currentCount = try await storage.auditLog.count()
        return currentCount != savedCount
    }

    /// Returns the current total audit-event count for `handle`, or `0` if the
    /// estate is not open.
    ///
    /// Called by the autonomic governor after a successful compute (topology/
    /// centrality/preference) to stamp the watermark. The returned count is
    /// persisted via `estate.setMeta` and passed to `hasAuditGrown(for:since:)`
    /// on the next cadence tick.
    ///
    /// - Complexity: O(1) — `SELECT COUNT(*)` on the audit table.
    public func auditEventCount(for handle: EstateHandle) async throws -> Int {
        guard let storage = storages[handle] else { return 0 }
        return try await storage.auditLog.count()
    }
}
