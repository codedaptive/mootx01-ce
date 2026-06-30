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
    let branchEstate: LocusKit.Estate

    /// The parent estate this branch was derived from. Used by
    /// `compareToParent`. Never written to; I-15 invariant.
    let parentEstate: LocusKit.Estate

    /// Branch-estate IDs of rows copied from the parent at derivation.
    /// Any ID NOT in this set was captured after derivation and is
    /// therefore "new in branch."
    let snapshotIDs: Set<DrawerID>

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
        // Wing integrity (ADR-016): wing is a grant/federation boundary.
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
                wing: wingName
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

    /// Transition the branch to `.discarded`. Rows are retained for the
    /// audit trail; `recall` continues to work after discard.
    func discard() async throws {
        _statusLock.withLock { $0 = .discarded }
        log.debug("EstateBranch '\(self.name, privacy: .public)' discarded")
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
