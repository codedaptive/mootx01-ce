import Foundation
import OSLog
import LocusKit
import PersistenceKit

/// The composition layer for the GeniusLocus substrate.
///
/// `GeniusLocusKit` is the public actor that coordinates N estates on
/// one device. Each estate is its own composed substrate (LocusKit
/// today; VectorKit and CorpusKit when later sub-missions wire them in)
/// with its own manifest and its own injected storage. Estates are
/// isolated from one another: a handle reaches exactly one estate's
/// data.
///
/// This scaffold mission delivers:
///
/// - Lifecycle: `open(storage:owner:)` to admit a new estate into the
///   registry; `close(_:)` to remove it; `handles` to list what is
///   currently open.
/// - Per-handle access: `estate(for:)` returns the live `LocusKit.Estate`
///   actor associated with a handle, so callers can issue verbs through
///   the existing LocusKit surface while later sub-missions build the
///   unified verb surface (GLK-02) on top.
/// - Lattice-scoped read fan-out: `fanOutRecall(_:region:)` routes a
///   `RecallFrame` to every open estate whose zoom window overlaps the
///   query region, then aggregates results. This is the "query N
///   estates" capability at the coordination level, ahead of the
///   unified verb surface.
///
/// The per-estate unified audit log is wired here (GLK-03): each open
/// estate carries a `UnifiedAuditLog` in `auditLogs`, fed from the
/// LocusKit tier through `feedAuditLog(for:)` and verified through the
/// `verifyAuditChain` verb. The Brain layer beyond the standing-signal
/// scheduler and the matrix tier remain later sub-missions (GLK-04+).
///
/// Per the standing-signal serial-dispatch decision recorded for
/// GLK-04, the public type is an actor so the registry is serialized
/// by the actor model. No caller should assume concurrent mutation of
/// a single estate's state.
public actor GeniusLocusKit {

    /// Logger for the kit, fleet-standard subsystem and category per
    /// CLAUDE.md.
    private static let logger = Logger(
        subsystem: "com.mootx01.kit",
        category: "GeniusLocusKit"
    )

    /// Registry of currently-open estates keyed by handle.
    ///
    /// Internal so that the coordinator and read-fan-out extensions in
    /// sibling files can reach the live `Estate` references without
    /// exposing them to outside callers. Production callers go through
    /// `estate(for:)` which round-trips the lookup with a clear error.
    internal var registry: [EstateHandle: LocusKit.Estate] = [:]

    /// Registry of per-estate standing-signal schedulers. Empty until
    /// the first `registerStandingSignal` call against a given handle;
    /// the scheduler is minted lazily by `ensureScheduler(for:)` in
    /// `Brain/SignalAPI.swift`. One scheduler per estate so the
    /// single-serial-lane decision (DECISION_STANDING_SIGNAL_SCHEDULER
    /// _2026-05-21) applies per-estate, never across estates.
    internal var schedulers: [EstateHandle: StandingSignalScheduler] = [:]

    /// Registry of per-estate unified audit logs (GLK-03). One
    /// `UnifiedAuditLog` per open estate, minted empty when the estate
    /// is admitted in `open` and dropped in `close`. The log is a value
    /// type (G-Set CRDT); `feedAuditLog(for:)` bridges the estate's
    /// LocusKit audit rows into it and `verifyAuditChain` reads it.
    /// Internal so the audit extension and coordinator reach it while
    /// callers go through `auditLog(for:)`.
    internal var auditLogs: [EstateHandle: UnifiedAuditLog] = [:]

    /// Registry of active and terminal COW branches keyed by `BranchID`.
    ///
    /// Branches are inserted on `glkDeriveBranch` and retained through
    /// all lifecycle states (`.active`, `.won`, `.merged`, `.discarded`)
    /// so that `glkPromoteBranch` and `glkMergeDrawers` can resolve a
    /// `BranchHandle` to its concrete `EstateBranch`. The in-memory
    /// estate is held here as long as the kit is alive; terminal branches
    /// are not automatically evicted (the audit trail must remain
    /// accessible per I-15).
    internal var branches: [BranchID: EstateBranch] = [:]

    /// The caller-supplied `Storage` for each open estate, retained so
    /// the grant surface can build a `GrantStore` backed by the estate's
    /// own database. Captured in `open`, dropped in `close`. The
    /// coordinator never shares a storage across estates, so this keeps
    /// grants in the same backend as the estate they belong to.
    internal var storages: [EstateHandle: any Storage] = [:]

    /// Per-estate grant persistence (GRT-01). Built lazily on the first
    /// grant verb against a handle via `ensureGrantSurface(for:)`; the
    /// `grants` table lives in the estate's storage. Dropped in `close`.
    internal var grantStores: [EstateHandle: GrantStore] = [:]

    /// Per-estate scope-key custody (GRT-01). Built lazily alongside the
    /// `GrantStore`. Mode-1 scope keys live here in memory only; the
    /// vault is dropped in `close`, which discharges all held keys.
    internal var scopeVaults: [EstateHandle: ScopeKeyVault] = [:]

    /// Construct an empty kit. The estate registry starts empty;
    /// callers admit estates via `open(storage:owner:)`.
    public init() {
        Self.logger.debug("GeniusLocusKit initialized with empty registry")
    }

    /// Number of estates currently open. Useful in tests and in
    /// diagnostics; the canonical listing surface is `handles`.
    public var openEstateCount: Int { registry.count }

    /// Snapshot of currently-open estate handles.
    ///
    /// Returns a fresh array on each call; the registry is not
    /// observable directly. Callers that need a stable ordering across
    /// reads should sort the result themselves.
    public var handles: [EstateHandle] {
        Array(registry.keys)
    }
}

// MARK: - Unified audit log (GLK-03)

public extension GeniusLocusKit {

    /// Return a snapshot of the unified audit log for the given handle.
    ///
    /// The log is a value type, so the returned snapshot is safe to use
    /// outside the actor — it does not alias the registry's copy.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is
    ///   not in the registry (stale or never issued).
    func auditLog(for handle: EstateHandle) throws -> UnifiedAuditLog {
        guard let log = auditLogs[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        return log
    }

    /// Pull audit rows from the estate's LocusKit tier, bridge them into
    /// `UnifiedAuditEntry` values, and merge them into the registry's
    /// log for the handle.
    ///
    /// Idempotent: entries are content-addressed, so re-feeding the same
    /// rows is a G-Set no-op (the same ids merge over themselves). The
    /// pull is unbounded — `until: nil` means "every row since the
    /// distant past" — so no wall-clock read happens inside this method
    /// and the result is determined entirely by the estate's stored
    /// audit history. In production the standing-signals scheduler calls
    /// this before a verify pass.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is
    ///   stale; any LocusKit failure surfaced by `auditTrail`.
    func feedAuditLog(for handle: EstateHandle) async throws {
        let estate = try estate(for: handle)
        // Cross-row enumeration: the substrate exposes audit history
        // per-row via `auditTrail(rowID:)`. To feed the unified log we
        // walk every drawer in the estate and pull its event stream.
        // `bridge(event:)` returns one or more UnifiedAuditEntries per
        // event (one per column changed), so the flatMap shape is
        // deliberate.
        let drawers = try await estate.allDrawers()
        var entries: [UnifiedAuditEntry] = []
        for drawer in drawers {
            let events = try await estate.auditTrail(rowID: drawer.id)
            entries.append(contentsOf: events.flatMap { AuditBridge.bridge($0) })
        }
        auditLogs[handle, default: UnifiedAuditLog()].add(contentsOf: entries)
    }
}
