import Foundation
import SubstrateTypes
import OSLog
import LocusKit
import PersistenceKit
import PersistenceKitInMemory

/// Concrete COW branch backed by a fresh in-memory `LocusKit.Estate`.
///
/// At derivation time, each row from the parent estate is re-captured
/// into this branch estate; those branch-estate IDs are recorded in
/// `snapshotIDs`. Rows captured after derivation are "new in branch"
/// (IDs absent from `snapshotIDs`). The parent estate is never written
/// to from this class — invariant I-15.
///
/// ## Concurrency design
///
/// `final class @unchecked Sendable` is used deliberately:
/// - `BranchHandle` declares `status: BranchStatus { get }` as
///   synchronous. An `actor` would require `await` at every call site,
///   which contradicts the protocol shape. `OSAllocatedUnfairLock`
///   provides thread-safe status mutation without actor overhead
///   (available macOS 13+, target 15+).
/// - `branchEstate` and `parentEstate` are `LocusKit.Estate` actors
///   and are intrinsically thread-safe.
/// - `snapshotIDs` is written once in `init` and is never mutated
///   afterwards; safe to read concurrently without a lock.
final class EstateBranch: BranchHandle, @unchecked Sendable {

    // MARK: - BranchHandle

    let branchID: BranchID
    let name: String

    /// Synchronous status read — backed by a lock so any concurrency
    /// domain can read this without `await`.
    var status: BranchStatus { _statusLock.withLock { $0 } }

    let lineageDepth: Int

    // MARK: - Internal (accessible within GeniusLocusKit module)

    /// The in-memory estate that owns this branch's rows. Exposed
    /// internally so `glkDeriveBranch(name:fromBranch:)` can derive a
    /// child branch by reading rows from this estate.
    ///
    /// `private(set) var` (not `let`) so a terminal transition can release
    /// the heavy copied rows via `releaseRows()` — swapping in a fresh empty
    /// estate to free the O(rows) content while the O(1) status shell is
    /// retained in the coordinator registry. Only mutated on terminal
    /// transition (discard / promote / merge), which the coordinator
    /// serializes and which never races an in-flight read of a still-active
    /// branch (terminal branches are not recalled). DoS fix (memory growth).
    private(set) var branchEstate: LocusKit.Estate

    /// The parent estate this branch was derived from. Used by
    /// `compareToParent` and the E-2 promotion/merge-target check. Never
    /// written to (I-15 invariant).
    ///
    /// `private(set) var` (not `let`) so a terminal transition can release it
    /// via `releaseRows()`. A branch-of-branch's `parentEstate` references its
    /// parent branch's `branchEstate` actor; without releasing it, a terminal
    /// child keeps that whole parent estate alive — the derive→discard
    /// memory-exhaustion vector the active-branch quota is meant to close. Only
    /// read on Active branches (compareToParent / promotion validation), which
    /// the coordinator serializes strictly before any terminal transition.
    private(set) var parentEstate: LocusKit.Estate

    /// Branch-estate IDs of rows copied from the parent at derivation.
    /// Any ID NOT in this set was captured after derivation and is
    /// therefore "new in branch." Cleared by `releaseRows()` on a terminal
    /// transition (the snapshot is only meaningful while the branch can be
    /// promoted/merged, which terminal branches cannot).
    private(set) var snapshotIDs: Set<DrawerID>

    // MARK: - Private

    private let log = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")

    /// Lock protecting the `status` field. `OSAllocatedUnfairLock`
    /// stores the protected value inside itself, avoiding a separate
    /// property that could be read without acquiring the lock.
    private let _statusLock = OSAllocatedUnfairLock<BranchStatus>(initialState: .active)

    // MARK: - Init

    /// Create a new branch estate, copying `snapshotRows` into it.
    ///
    /// Each parent row is re-captured (a new ID is minted for each);
    /// the resulting branch-estate IDs populate `snapshotIDs`. Rows
    /// captured by callers after init are "new in branch."
    ///
    /// - Parameters:
    ///   - name: Human-readable label for this branch.
    ///   - parentEstate: The estate this branch was derived from.
    ///   - snapshotRows: Rows recalled from the parent at derivation time.
    ///   - lineageDepth: Generation depth (1 = direct child of an estate).
    init(
        name: String,
        parentEstate: LocusKit.Estate,
        snapshotRows: [Drawer],
        lineageDepth: Int
    ) async throws {
        self.branchID = UUID()
        self.name = name
        self.parentEstate = parentEstate
        self.lineageDepth = lineageDepth

        // A fresh in-memory estate per branch keeps each branch's rows
        // fully isolated. The estateID is a new UUID; the owner
        // identifier encodes the branchID for traceability in logs.
        // Identity keys: Estate.open resolves the key store from the
        // backend, so this `.inMemory` estate mints its Ed25519 identity
        // into an in-memory store — a branch is ephemeral and must never
        // leave a permanent com.mootx01.estate.identity item in the login
        // keychain (one per derive/discard cycle, unbounded growth).
        let branchID = self.branchID
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let credentials = OwnerCredentials(ownerIdentifier: "branch-\(branchID.uuidString)")
        _ = try await LocusKit.Estate.create(storage: storage, owner: credentials)
        let estate = try await LocusKit.Estate.open(storage: storage, owner: credentials)
        self.branchEstate = estate

        // Copy each parent row into the branch estate. The branch-estate
        // IDs (not the parent IDs) are what snapshotIDs tracks, because
        // the parent IDs are not accessible after derivation without
        // re-querying the parent. compareToParent compares current branch
        // IDs against snapshotIDs to detect "new in branch" rows.
        //
        // Resolve parentNodeId → (wing, room) display names once for
        // the whole batch. Drawer no longer carries wing/room stored
        // properties (node-tree migration); wing and room are both
        // recovered from the node tree via resolveNodeNames.
        //
        // Wing integrity: wing is a grant/federation boundary.
        // All security/placement/lifecycle fields are preserved so a
        // branch snapshot is a faithful copy of the parent's estate state.
        // lineageID is intentionally NOT preserved — branch promotion is
        // copy semantics, not move semantics; a new lineage prevents
        // unintended supersession cascades across estate boundaries.
        let parentNodeIds = Array(Set(snapshotRows.map(\.parentNodeId)))
        let nodeNames = try await parentEstate.resolveNodeNames(parentNodeIds: parentNodeIds)
        var ids = Set<DrawerID>()
        for row in snapshotRows {
            let names = nodeNames[row.parentNodeId]
            let wingName = names?.wing       // nil → CaptureFrame defaults to defaultWing()
            let roomName = names?.room ?? ""
            let frame = CaptureFrame(
                content: row.content,
                channel: row.captureChannel,
                room: roomName,
                latticeAnchor: LatticeAnchor(
                    udcCode: row.udcCode,
                    udcFacets: row.udcFacets,
                    wikidataQID: row.wikidataQID,
                    wikidataQidsSecondary: row.wikidataQidsSecondary
                ),
                addedBy: row.addedBy,
                embeddingModelID: row.embeddingModelID,
                sensitivity: row.adjectiveSensitivity,
                kind: row.contentKind,
                provenanceChannel: row.channel,
                sourceType: row.sourceType,
                provenanceSensitivity: row.sensitivity,
                confirmation: row.confirmation,
                confidence: row.confidence,
                eventTime: row.eventTime,
                featureFlags: row.featureFlags,
                exportability: row.exportability,
                wing: wingName,
                // Subject carries over: promotion copies identical content,
                // so the source drawer's subject stays true. The capture
                // verb restamps pipeline/at (a carried subject re-enters as
                // a fresh assertion); a source without one stays debt.
                subject: row.subject
            )
            let stored = try await estate.capture(frame)
            ids.insert(stored.id)
        }
        self.snapshotIDs = ids
    }

    // MARK: - Internal status transition

    /// Transition the branch to a terminal status.
    ///
    /// Called by `glkPromoteBranch` and `glkMergeDrawers` on the GLK
    /// verb surface to signal promotion or merge completion. Using a
    /// dedicated method keeps `_statusLock` private while allowing
    /// module-level callers to drive the lifecycle.
    func setStatus(_ newStatus: BranchStatus) {
        _statusLock.withLock { $0 = newStatus }
    }

    // MARK: - BranchHandle conformance

    /// Capture a drawer into this branch estate. The parent is untouched.
    func capture(_ frame: CaptureFrame) async throws -> Drawer {
        try await branchEstate.capture(frame)
    }

    /// Recall drawers from this branch estate, draining the stream fully.
    func recall(_ frame: RecallFrame) async throws -> [Drawer] {
        let stream = await branchEstate.recall(frame)
        var rows: [Drawer] = []
        for await page in stream {
            rows.append(contentsOf: page.rows)
        }
        return rows
    }

    /// Transition the branch to `.discarded` and release its heavy row store.
    /// The coordinator keeps the status shell so C-5 can still refuse a
    /// disqualified branch as unpromotable, but the O(rows) copied content is
    /// freed — a derive→discard loop no longer accumulates row copies (DoS
    /// fix). No caller reads a discarded branch's rows.
    func discard() async throws {
        _statusLock.withLock { $0 = .discarded }
        try await releaseRows()
        log.debug("EstateBranch '\(self.name, privacy: .public)' discarded")
    }

    /// Drop the branch estate's copied rows, replacing it with a fresh empty
    /// estate and clearing the snapshot set. Called on every terminal
    /// transition (discard / promote / merge) after any work that needs the
    /// rows has completed. Reduces a terminal branch to an O(1) status shell.
    func releaseRows() async throws {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let credentials = OwnerCredentials(
            ownerIdentifier: "branch-\(branchID.uuidString)-released")
        _ = try await LocusKit.Estate.create(storage: storage, owner: credentials)
        let empty = try await LocusKit.Estate.open(storage: storage, owner: credentials)
        self.branchEstate = empty
        self.snapshotIDs = []
        // Also drop the reference to the parent estate. A branch-of-branch's
        // parentEstate is its parent branch's branchEstate actor; without this,
        // a terminal child keeps that whole parent estate alive (the
        // derive→discard memory-exhaustion vector). parentEstate is only read on
        // Active branches, strictly before this terminal transition, so an empty
        // sentinel is safe. Mirrors the Rust release_rows parent-estate release.
        let parentConfig = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let parentStorage = InMemoryStorage(configuration: parentConfig)
        let parentCredentials = OwnerCredentials(
            ownerIdentifier: "branch-\(branchID.uuidString)-parent-released")
        _ = try await LocusKit.Estate.create(storage: parentStorage, owner: parentCredentials)
        self.parentEstate = try await LocusKit.Estate.open(
            storage: parentStorage, owner: parentCredentials)
    }

    /// Compare the current branch state to the parent.
    ///
    /// `newInBranch` = current branch IDs not in `snapshotIDs` (added
    /// after derivation). `withdrawnInBranch` = `snapshotIDs` no longer
    /// in the current branch set (removed after derivation).
    /// `modifiedInBranch` is always empty — content-hash comparison
    /// ships in a later sub-mission.
    func compareToParent(over interval: DateInterval) async throws -> DifferentialReport {
        // `interval` is stored as metadata in the report (period field)
        // and is not used to filter the recall results. Row filtering by
        // capture date requires RecallFrame date-range support, which
        // ships in a later sub-mission. Callers receive the full diff
        // regardless of interval width; the period label allows consumers
        // to correlate which window the report describes.
        let frame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let currentRows = try await recall(frame)
        let currentIDs = Set(currentRows.map(\.id))

        let newIDs = currentIDs.subtracting(snapshotIDs)
        let withdrawnIDs = snapshotIDs.subtracting(currentIDs)

        return DifferentialReport(
            newInBranch: Array(newIDs),
            modifiedInBranch: [],
            withdrawnInBranch: Array(withdrawnIDs),
            period: interval
        )
    }
}
