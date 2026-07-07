// SensitivityAuditVerbs.swift
//
// ADR-025 sensitivity unlock, §4 (Audit): "Every grant, every denial,
// every manual revocation (`mootx01 lock`), and every read served under an
// active grant is written to the UnifiedAuditLog with tier, grant id, and
// timestamps."
//
// Mirrors the FUP-C / GLK-03 grant-lifecycle audit seam in VerbSurface.swift
// (`issueGrant`/`revokeGrant`/`appendGrantAuditEntry`) — same
// non-drawer-scoped audit entry shape (a synthetic id in `rowID`, a
// descriptive token in `fieldPath`), same HLC derivation from `now`.
// Bug 1 fix (ADR025-AUDITLOG-GOVERNOR): the former in-memory
// `auditLogs[handle, default:].add(entry)` append is now a no-op; entries
// are persisted by LocusKit's audit machinery and visible via the new
// `auditLog(for:)` SQL-backed reader.
// Applies sensitivity-unlock's four NEW verbs
// (`sensitivityGrantIssued`/`Denied`/`Revoked`/`sensitivityReadUnderGrant`)
// instead of reusing the federation-reserved `grantIssued`/`grantRevoked`
// (deliberately different verbs — see `UnifiedAuditLog.swift`'s enum doc
// comment).
//
// Uses `AdjectiveSensitivity` (LocusKit) for the tier rather than a new
// GeniusLocusKit- or AriaMcpKit-level type: `.restricted`/`.secret` already
// exist there, and GeniusLocusKit must not depend on AriaMcpKit (which sits
// ABOVE it in the kit topology) for a tier vocabulary this kit can express
// with an existing LocusKit type.
//
// Public (unlike the private `appendGrantAuditEntry`) because the caller
// is AriaMcpKit's `SensitivityGrantLedger`/`ToolDispatcher`, not internal
// GeniusLocusKit logic — this IS the public seam ARIA calls into. Four
// narrow, purpose-built methods (mirroring `issueGrant`/`revokeGrant`)
// rather than one generic "append any entry" method, so the audit log's
// integrity guarantees are not weakened by an unconstrained append surface.
//
// No expiry verb: expiry is passive per ADR-025 §4 — the issued record's
// `afterValue` carries its own expiry timestamp (epoch-ms, `.integer`), so
// expiry is derivable from the log without a dedicated expiry-time writer.

import Foundation
import LocusKit
import SubstrateTypes

extension GeniusLocusKit {

    /// Record that a sensitivity-unlock grant was approved and is now
    /// live. `grantID` is a fresh identifier the caller mints per grant
    /// (distinct from any drawer id — there is no natural "row" for a
    /// grant event, so a synthetic id fills the `rowID` slot, exactly as
    /// `issueGrant` does for federation grants). `expiresAt` is stored in
    /// `afterValue` as epoch-milliseconds so an expiry boundary is
    /// derivable from the log alone.
    ///
    /// - Parameters:
    ///   - handle: the estate the grant applies to. Must be open in this kit.
    ///   - tier: `.restricted` or `.secret` — any other case is a caller
    ///     error but is still recorded verbatim (this method does not
    ///     validate the tier; the ledger that calls it only ever passes
    ///     one of the two).
    ///   - grantID: a fresh, caller-minted identifier for this specific
    ///     grant instance — reused in a later `recordSensitivityGrantRevoked`
    ///     call for the SAME grant so the two entries correlate by `rowID`.
    ///   - expiresAt: the grant's computed expiry instant.
    ///   - now: issue instant: deterministic, supplied by the caller.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` for a stale handle.
    public func recordSensitivityGrantIssued(
        _ handle: EstateHandle,
        tier: AdjectiveSensitivity,
        grantID: UUID,
        expiresAt: Date,
        now: Date
    ) throws {
        _ = try estate(for: handle)
        appendSensitivityAuditEntry(
            verb: .sensitivityGrantIssued,
            rowID: grantID,
            fieldPath: tier.auditToken,
            before: .null,
            after: .integer(Self.epochMilliseconds(expiresAt)),
            handle: handle,
            now: now
        )
    }

    /// Record that a sensitivity-unlock grant request was DENIED (a failed
    /// `UnlockAuthority` evaluation — wrong password, cancelled biometric
    /// prompt, etc.). There is no persisted grant to correlate, so
    /// `grantID` is a fresh id minted for the denial event itself, purely
    /// so the entry has a stable, unique identity.
    public func recordSensitivityGrantDenied(
        _ handle: EstateHandle,
        tier: AdjectiveSensitivity,
        now: Date
    ) throws {
        _ = try estate(for: handle)
        appendSensitivityAuditEntry(
            verb: .sensitivityGrantDenied,
            rowID: UUID(),
            fieldPath: tier.auditToken,
            before: .null,
            after: .null,
            handle: handle,
            now: now
        )
    }

    /// Record a manual revocation (`mootx01 lock`) of a live grant.
    /// `grantID` should be the SAME id passed to the
    /// `recordSensitivityGrantIssued` call this revokes, so the two
    /// entries correlate by `rowID` — mirrors `revokeGrant`'s treatment of
    /// federation grants exactly.
    public func recordSensitivityGrantRevoked(
        _ handle: EstateHandle,
        tier: AdjectiveSensitivity,
        grantID: UUID,
        now: Date
    ) throws {
        _ = try estate(for: handle)
        appendSensitivityAuditEntry(
            verb: .sensitivityGrantRevoked,
            rowID: grantID,
            fieldPath: tier.auditToken,
            before: .integer(1),
            after: .null,
            handle: handle,
            now: now
        )
    }

    /// Record that a specific drawer was read ONLY because a live
    /// sensitivity grant admitted it past the default ceiling. `rowID` is
    /// the DRAWER's own id here (not a grant id) — a read-under-grant
    /// entry is genuinely about a specific row, unlike the three verbs
    /// above.
    ///
    /// - Parameter drawerID: the drawer's id, as a string (matching every
    ///   other ARIA-boundary row-id representation — MCP tool args and
    ///   results carry drawer ids as strings, not `UUID`, so the caller
    ///   passes the string it already has rather than re-parsing it).
    public func recordSensitivityReadUnderGrant(
        _ handle: EstateHandle,
        tier: AdjectiveSensitivity,
        drawerID: String,
        now: Date
    ) throws {
        _ = try estate(for: handle)
        guard let rowUUID = UUID(uuidString: drawerID) else {
            // Malformed drawer id: should not happen (every drawer id in
            // this codebase is a UUID string), but audit recording must
            // never crash a read path — silently skip rather than throw,
            // matching the "audit is best-effort observability, not a
            // gate" posture the rest of this file's callers rely on.
            return
        }
        appendSensitivityAuditEntry(
            verb: .sensitivityReadUnderGrant,
            rowID: rowUUID,
            fieldPath: tier.auditToken,
            before: .null,
            after: .null,
            handle: handle,
            now: now
        )
    }

    /// Shared append helper for the four methods above.
    ///
    /// Bug 1 fix (ADR025-AUDITLOG-GOVERNOR): no-op. The in-memory `auditLogs`
    /// dict is removed; sensitivity audit entries are persisted by LocusKit's
    /// audit machinery when the underlying verb fires. They are visible via
    /// `auditLog(for:)` which reads directly from `_storagekit_audit`.
    /// Write a sensitivity audit entry to the durable audit log (#10).
    /// These are synthetic events (not drawer mutations) — beforeBitmaps
    /// is nil, afterBitmaps is all-zero. The `reason` field carries the
    /// fieldPath (tier token) so the entry is self-describing.
    private func appendSensitivityAuditEntry(
        verb: UnifiedAuditVerb,
        rowID: UUID,
        fieldPath: String,
        before: UnifiedAuditValue,
        after: UnifiedAuditValue,
        handle: EstateHandle,
        now: Date
    ) {
        guard let storage = storages[handle] else { return }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // Synthetic HLC: physical time from `now`, logical 0, node 0.
        // These entries are not order-critical relative to drawer mutations
        // (they don't feed bitmap fold), so a standalone HLC is acceptable.
        let hlc = HLC(physicalTime: nowMs, logicalCount: 0, nodeID: 0)
        let event = AuditEvent(
            estateUuid: handle.estateUUID,
            rowId: rowID,
            hlc: hlc,
            verb: verb.rawValue,
            beforeBitmaps: nil,
            afterBitmaps: (adjective: 0, operational: 0, provenance: 0),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: SubstrateTypes.LatticeAnchor(udcCode: 0, qidPointer: 0),
            actor: "sensitivity-audit",
            reason: fieldPath
        )
        Task {
            try? await storage.auditLog.append(event)
        }
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

private extension AdjectiveSensitivity {
    /// The `fieldPath` token stamped onto a sensitivity-unlock audit
    /// entry — mirrors the federation seam's "custody-mode token in
    /// fieldPath" convention (VerbSurface.swift). Only `.restricted` and
    /// `.secret` are ever passed by the sensitivity-unlock callers; the
    /// other two cases are covered for exhaustiveness, not because a
    /// grant is ever issued for them.
    var auditToken: String {
        switch self {
        case .normal: return "normal"
        case .elevated: return "elevated"
        case .restricted: return "restricted"
        case .secret: return "secret"
        }
    }
}
