import Foundation

/// Identifies a recall lane that is not yet available in this version.
///
/// Carried by `GeniusLocusKitError.recallLaneUnavailable` so callers can
/// branch on the specific missing lane without string matching.
public enum RecallLane: String, Sendable, Equatable {
    /// The CorpusKit BM25 + vector lane.
    case corpus
    /// The standalone vector similarity lane.
    case vector
    /// The matrix co-occurrence / temporal signal lane. Reserved for a future mission.
    case matrix
}

/// Errors raised by the GeniusLocusKit composition surface.
///
/// Per CLAUDE.md, every kit owns an enum-typed error and never falls
/// back to optionals-plus-logging. Cases span lifecycle, manifest
/// validation, read fan-out, signal scheduling, branch management,
/// and cross-estate federation.
public enum GeniusLocusKitError: Error, Sendable, Equatable, CustomStringConvertible {

    /// Caller passed a manifest that violates the kit's preconditions.
    /// `key` is the offending manifest field (e.g. `"estate_uuid"`,
    /// `"zoom_window"`); `detail` is the human-readable explanation.
    case invalidManifest(key: String, detail: String)

    /// A handle was used after the estate it referenced was closed,
    /// or a handle that was never issued by this kit instance was
    /// passed in. The carried UUID matches the handle's `estateUUID`.
    case estateNotOpen(estateUUID: UUID)

    /// An attempt to open an estate whose UUID matches one already in
    /// the registry. Per spec § 7.7, estate UUIDs are immutable, so a
    /// duplicate open is almost certainly the same database file being
    /// opened twice — refuse rather than risk shadowing the live entry.
    case duplicateEstate(estateUUID: UUID)

    /// The underlying LocusKit `Estate.open` call failed. The associated
    /// value is the textual description of the underlying error; the
    /// concrete type is hidden because it crosses the GeniusLocusKit
    /// boundary and callers should not depend on LocusKit's internal
    /// error taxonomy through this kit.
    case underlyingEstateFailure(reason: String)

    /// The caller asked for a fan-out region whose `low` exceeds its
    /// `high`. Treated as a programmer error; surfaced explicitly so
    /// tests can distinguish it from an empty-result outcome.
    case invalidLatticeRegion(low: Int, high: Int)

    /// `subscribe`, `unsubscribe`, or `requestFire` referenced a
    /// SignalID that is not currently registered with the addressed
    /// estate's standing-signal scheduler. Raised at the GLK
    /// boundary so callers see a single case across all
    /// signal-handle faults.
    case schedulerSignalNotRegistered(SignalID)

    /// `signalSubscribe`, `signalUnsubscribe`, `signalStatus`, or
    /// `signalRequestFire` was called against an estate handle that
    /// has no scheduler yet. The scheduler is created lazily on
    /// `registerStandingSignal`; calling the read or subscription
    /// surface before any signal is registered raises this so the
    /// programmer sees the ordering fault rather than an empty
    /// response.
    case schedulerNotStarted(estateUUID: UUID)

    /// A `glkPromoteBranch` or `glkMergeDrawers` call referenced a
    /// `BranchHandle` whose `branchID` is not tracked in the kit's
    /// branch registry. This happens when a handle was created outside
    /// the kit or the kit was restarted and in-memory branch state was
    /// lost.
    case branchNotTracked(branchID: BranchID)

    /// A `glkPromoteBranch` or `glkMergeDrawers` call addressed a
    /// destination estate that is not the branch's parent. Promotion
    /// re-captures branch content into the destination; with per-estate
    /// keys a mismatched destination would silently move content across
    /// an estate (and key) boundary. The destination's `estateUUID` must
    /// equal the UUID of the estate the branch was derived from.
    /// `expectedEstateUUID` is the branch's parent; `actualEstateUUID` is
    /// the destination that was passed.
    case invalidPromotionTarget(branchID: BranchID, expectedEstateUUID: UUID, actualEstateUUID: UUID)

    /// A cross-estate federated read was refused because the source
    /// estate holds no valid grant naming the requester as grantee.
    /// This is the substrate-level enforcement of the A-versus-C
    /// refusal (DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §13,
    /// cookbook I-23): absent a grant, B's content is never disclosed
    /// to A. `reason` distinguishes no-grant from expired/revoked.
    case crossEstateReadRefused(source: UUID, requester: UUID, reason: FederatedReadRefusalReason)

    /// The caller requested a recall lane that is not available in this version.
    ///
    /// Raised when a lane is requested before its required kit is registered
    /// (e.g. `corpusOnly` with no corpus registered and `failClosed`). The
    /// `matrix` lane is reserved for a future mission.
    case recallLaneUnavailable(RecallLane)

    /// A verb was called on an estate whose mount state is `.quiesced` or
    /// `.draining` — the estate is in a winding-down state and no new work
    /// is accepted. The caller should wait for the estate to finish existing
    /// work, then reopen or destroy it. The carried UUID is the estate's UUID.
    case estateQuiesced(estateUUID: UUID)

    /// `destroy(storage:corpusStorage:handle:)` was called on a handle that
    /// is still in the `.mounted` or `.draining` state. The caller must call
    /// `close(_:)` (or `quiesce` → `drain` → `close`) before destroying the
    /// backing stores, so that in-flight work flushes cleanly and the audit
    /// trail is consistent. The estate can be force-destroyed after close.
    case destroyRequiresClose(estateUUID: UUID)

    public var description: String {
        switch self {
        case let .invalidManifest(key, detail):
            return "invalid manifest field '\(key)': \(detail)"
        case let .estateNotOpen(uuid):
            return "estate \(uuid) is not open in this kit"
        case let .duplicateEstate(uuid):
            return "estate \(uuid) is already open"
        case let .underlyingEstateFailure(reason):
            return "underlying LocusKit.Estate failure: \(reason)"
        case let .invalidLatticeRegion(low, high):
            return "invalid lattice region: low \(low) > high \(high)"
        case let .schedulerSignalNotRegistered(id):
            return "signal \(id.rawValue) is not registered with the addressed estate's scheduler"
        case let .schedulerNotStarted(uuid):
            return "estate \(uuid) has no standing-signal scheduler — register a signal first"
        case let .branchNotTracked(id):
            return "branch \(id) is not tracked in this kit instance"
        case let .invalidPromotionTarget(id, expected, actual):
            return "branch \(id) cannot be promoted into estate \(actual): its parent estate is \(expected)"
        case let .crossEstateReadRefused(source, requester, reason):
            return "cross-estate read of \(source) by \(requester) refused: \(reason)"
        case let .recallLaneUnavailable(lane):
            return "recall lane '\(lane.rawValue)' is not available in this version"
        case let .estateQuiesced(uuid):
            return "estate \(uuid) is quiesced and not accepting new work"
        case let .destroyRequiresClose(uuid):
            return "destroy requires the estate \(uuid) to be closed first — call close() before destroy()"
        }
    }
}
