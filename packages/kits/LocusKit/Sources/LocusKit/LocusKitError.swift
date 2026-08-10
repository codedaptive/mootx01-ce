import Foundation

/// Errors thrown by LocusKit.
///
/// Every failure mode the kit surfaces is enumerated here so
/// callers can recover specifically — for example, treating a
/// missing drawer as a routine query miss while still
/// propagating SQLite failures. Equatable conformance comes
/// free from the associated-value shapes and is exercised by
/// the test suite.
public enum LocusKitError: Error, Sendable, Equatable {

    /// SQLite could not open or create the database at the
    /// configured URL. The associated message is the
    /// human-readable string produced by `sqlite3_errmsg`,
    /// surfaced verbatim so logs preserve the underlying
    /// diagnostic.
    case databaseUnavailable(String)

    /// No drawer exists for the supplied identifier.
    case drawerNotFound(id: String)

    /// No tunnel exists for the supplied identifier.
    case tunnelNotFound(id: String)

    /// No diary entry exists for the supplied identifier.
    case diaryEntryNotFound(id: String)

    /// No recall trace item exists for the supplied identifier.
    /// Thrown by `DrawerStore.markRecallTraceUsed` when the target row
    /// is absent — callers can treat this as a stale reward signal.
    case recallTraceItemNotFound(id: String)

    /// A SQLite call returned a non-OK result code. The
    /// associated string is the message produced by
    /// `sqlite3_errmsg` so callers can log the underlying
    /// diagnostic without losing detail.
    case sqliteError(String)

    /// Schema version on disk is newer than this build expects.
    /// Reserved for the migration workflow added in a later
    /// LOCI mission; this mission never throws this case.
    case schemaTooNew(found: Int, expected: Int)

    /// Drawer, tunnel, or diary content failed validation.
    /// The associated message names the rule that was violated
    /// (for example, "wing must not be empty"). The message is
    /// the contract — tests assert on it.
    case invalidContent(String)

    /// A verb call or mutation would violate a substrate invariant —
    /// an illegal state transition (§ 6.2), a forbidden combination
    /// (I-3), or an expunge without confirmation. The associated values
    /// name the rule that was violated so callers can log precisely.
    ///
    /// `from` and `to` are the `State` raw values (Int) rather than
    /// the enum cases so the error is `Equatable` without requiring
    /// `State` to be in `LocusKitError`'s dependency set. Callers that
    /// need the typed cases convert via `State(rawValue:)`.
    case disciplineViolation(from: Int, to: Int, reason: String)

    /// A stored TEXT value in a required column could not be parsed
    /// to its declared type (UUID or ISO 8601 timestamp). Parity with
    /// `PersistenceKit.StorageError.corruptStoredValue` (commit
    /// 0ff08d93). Thrown instead of silently substituting a default
    /// (random UUID, epoch-0 date) so callers know their stored data
    /// is corrupt and cannot be trusted.
    ///
    /// - `table`: the LocusKit table name (e.g. "drawers").
    /// - `column`: the column whose stored text was unparseable.
    /// - `storedText`: the raw string that failed to parse,
    ///   reproduced verbatim for log diagnosis.
    case corruptStoredValue(table: String, column: String, storedText: String)

    /// A verb call targets a feature that is not yet implemented in
    /// this version of LocusKit. The associated message names the
    /// feature so callers can distinguish clearly between "not found"
    /// (data missing) and "not supported" (code missing). Thrown
    /// instead of silently producing a sentinel or stub result per
    /// the P1 mandate: fail-loud unsupported is required when the
    /// producing data does not exist.
    case notSupported(String)

    /// A dataset handle exists for `datasetId` but its belief state is
    /// in cluster B (withdrawn, superseded, decayed, or expired) — the
    /// dataset is no longer actively believed. The backing table is NOT
    /// dropped by the withdrawal; it persists until the handle is erased
    /// via `VerbSurface.expunge`. Thrown by
    /// `Estate.resolveActiveDatasetHandle(datasetId:)` (MX-TAB-4).
    case withdrawnDatasetHandle(datasetId: UUID)

    /// The tunnel's lifecycle has moved beyond `.proposed` since the caller's
    /// last read — a stale model-review write was rejected. The user's lifecycle
    /// decision (accept or withdraw via `respondToTunnel`) prevails.
    /// Thrown by `DrawerStore.stampTunnelReview` when the tunnel is no longer
    /// `.proposed` at write time. Callers (e.g. `endorseTunnel`,
    /// `objectToTunnel`) should treat this as a no-op: the vote arrived after
    /// the user settled the question.
    case tunnelNoLongerProposed(id: String)
}

extension LocusKitError: CustomStringConvertible {
    /// English description without internal Swift type-chain noise
    /// (LocusKitError.invalidContent(...), GateViolation cases, etc.).
    /// Used at the GeniusLocusKit boundary (VerbSurface.remap) so
    /// VerbError.underlyingEstateFailure.reason carries English text
    /// that the AriaMcpKit describe_gate_rejection parser can parse.
    public var description: String {
        switch self {
        case .databaseUnavailable(let msg):
            return "database unavailable: \(msg)"
        case .drawerNotFound(let id):
            return "drawer not found: \(id)"
        case .tunnelNotFound(let id):
            return "tunnel not found: \(id)"
        case .diaryEntryNotFound(let id):
            return "diary entry not found: \(id)"
        case .recallTraceItemNotFound(let id):
            return "recall trace item not found: \(id)"
        case .sqliteError(let msg):
            return "SQLite error: \(msg)"
        case .schemaTooNew(let found, let expected):
            return "schema version \(found) is newer than expected \(expected)"
        case .invalidContent(let msg):
            // The msg already contains the English text produced by
            // GateViolation::description (Swift) or GateViolation::Display (Rust),
            // e.g. "state mutation rejected by gate: illegal state transition: active --reject-->".
            // Pass it through verbatim so upstream parsers (describe_gate_rejection) can
            // find the sentinel "illegal state transition: " as a substring.
            return "InvalidContent: \(msg)"
        case .disciplineViolation(let from, let to, let reason):
            return "discipline violation (\(from)→\(to)): \(reason)"
        case .corruptStoredValue(let table, let column, let storedText):
            return "corrupt stored value in \(table).\(column): '\(storedText)'"
        case .notSupported(let msg):
            return "not supported: \(msg)"
        case .withdrawnDatasetHandle(let datasetId):
            return "dataset handle withdrawn: \(datasetId.uuidString)"
        case .tunnelNoLongerProposed(let id):
            return "tunnel no longer proposed: \(id)"
        }
    }
}
