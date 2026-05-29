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
}
