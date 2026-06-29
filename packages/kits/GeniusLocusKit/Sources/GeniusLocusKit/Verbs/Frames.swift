import Foundation
import SubstrateTypes
import LocusKit

// MARK: - Re-exported LocusKit frames
//
// The GLK verb surface accepts the same frame shapes LocusKit defines
// for its verbs. Re-exporting via typealias gives callers a single
// import (`import GeniusLocusKit`) and a single namespace while
// keeping one source of truth for the frame fields. When LocusKit
// later expands a frame (e.g. LearnFrame slot set lands in LOCI_V035_19),
// the GLK surface follows without a parallel declaration to maintain.

/// Slots for the `capture` verb at the GLK surface. Identical to
/// `LocusKit.CaptureFrame`; re-exported so callers do not need to
/// import LocusKit alongside GeniusLocusKit.
public typealias CaptureFrame = LocusKit.CaptureFrame

/// Slots for the `recall` verb at the GLK surface. Identical to
/// `LocusKit.RecallFrame`.
public typealias RecallFrame = LocusKit.RecallFrame

/// Slots for the `learn` verb at the GLK surface. Identical to
/// `LocusKit.LearnFrame`, which carries the full slot set (`source`,
/// `handle`, `mode`, `refreshPolicy`).
public typealias LearnFrame = LocusKit.LearnFrame

/// Named mutation operations for the `mutate` verb. Identical to
/// `LocusKit.MutationKind`.
public typealias MutationKind = LocusKit.MutationKind

/// Lattice anchor re-export so `ReanchorFrame` and callers can name
/// the type through the GLK module.
public typealias LatticeAnchor = LocusKit.LatticeAnchor

/// Row identifier re-export. `LocusKit.RowID` is a `String` alias;
/// surfacing the name through GLK keeps frame signatures self-documenting.
public typealias RowID = LocusKit.RowID

/// Room identifier re-export.
public typealias RoomID = LocusKit.RoomID

/// Drawer re-export so the public `capture` and `recall` return
/// types are nameable through the GLK module alone. Without this
/// typealias a caller using only `import GeniusLocusKit` could
/// invoke the verbs but not bind their results to a named type,
/// breaking the file's stated "single import" promise.
public typealias Drawer = LocusKit.Drawer

// MARK: - GLK-native frames
//
// Verbs whose LocusKit signature is positional (rowID, kind, payload,
// reason, etc.) get a named frame at the GLK boundary so every verb
// reads as "one frame in, one outcome out." This matches the AriaLexicon
// "one verb applied to a noun" sentence shape and matches the frame
// shape capture/recall/learn already have in LocusKit.

/// Slots for the `withdraw` verb.
///
/// `withdraw` moves a drawer's `State` axis to `.withdrawn`; the
/// substrate preserves the row for asOf reconstruction (cookbook §10.4).
public struct WithdrawFrame: Sendable, Equatable {
    /// The drawer to withdraw.
    public let rowID: RowID
    /// Optional free-text justification, written verbatim into the
    /// bitmap-audit row's `reason` column at the substrate layer.
    public let reason: String?

    public init(rowID: RowID, reason: String? = nil) {
        self.rowID = rowID
        self.reason = reason
    }
}

/// Slots for the `mutate` verb.
///
/// `mutate` updates the row's adjective bitmap per the supplied
/// `MutationKind` (confirm, reject, contest, supersede, revive,
/// accept, correctSensitivity, correctExportability, correctTrust).
/// The substrate writes a bitmap-audit row atomically with the update
/// (cookbook §10.3).
public struct MutateFrame: Sendable {
    /// The drawer to mutate.
    public let rowID: RowID
    /// Which named mutation to apply.
    public let kind: MutationKind
    /// Optional payload string used by several mutation variants as
    /// the audit reason or free-text justification. The LocusKit mutate
    /// implementation passes it as the audit/reason string for
    /// state transitions including reject, contest, resolve, and accept.
    public let payload: String?

    public init(rowID: RowID, kind: MutationKind, payload: String? = nil) {
        self.rowID = rowID
        self.kind = kind
        self.payload = payload
    }
}

/// Slots for the `expunge` verb.
///
/// `expunge` tombstones a row and zeroizes its content blob
/// (cookbook §10.5). Destructive: requires explicit `confirmation`
/// at the GLK boundary so a wrong-button press cannot tombstone.
public struct ExpungeFrame: Sendable, Equatable {
    /// The drawer to expunge.
    public let rowID: RowID
    /// Required free-text justification. Written into the audit row
    /// before content is zeroized so the fact-of-expunge survives.
    public let reason: String
    /// Must be `true` for the verb to proceed. False signals "asked
    /// but did not confirm" and the verb raises
    /// `VerbError.expungeNotConfirmed`.
    public let confirmation: Bool

    public init(rowID: RowID, reason: String, confirmation: Bool) {
        self.rowID = rowID
        self.reason = reason
        self.confirmation = confirmation
    }
}

/// Slots for the `reanchor` verb.
///
/// `reanchor` updates a row's lattice anchor or its room/wing, leaving
/// content and fingerprint blocks other than Block 1 untouched
/// (cookbook §10.2). At least one of `toRoom`, `toWing`, or `toLattice`
/// must be non-nil; an empty reanchor is rejected at the GLK boundary as
/// `VerbError.emptyReanchor`.
public struct ReanchorFrame: Sendable, Equatable {
    /// The drawer to reanchor.
    public let rowID: RowID
    /// Target room. `nil` keeps the current room.
    public let toRoom: RoomID?
    /// Target wing. `nil` keeps the current wing. Cross-wing moves require this field.
    public let toWing: String?
    /// Target lattice anchor. `nil` keeps the current anchor.
    public let toLattice: LatticeAnchor?

    public init(
        rowID: RowID,
        toRoom: RoomID? = nil,
        toWing: String? = nil,
        toLattice: LatticeAnchor? = nil
    ) {
        self.rowID = rowID
        self.toRoom = toRoom
        self.toWing = toWing
        self.toLattice = toLattice
    }
}

/// Learned reference re-export so the public `learn` return type is nameable
/// through the GLK module alone.
public typealias LearnedReference = LocusKit.LearnedReference

// MARK: - Substrate noun re-exports for seam consumers
//
// NeuronKit's dreaming and maintenance daemons use these value types in
// their seam protocols. Re-exporting them through GeniusLocusKit lets those
// files import ONLY GeniusLocusKit, eliminating the ProposeFrame ambiguity
// that arises when both GeniusLocusKit and LocusKit are imported directly
// (both modules define `ProposeFrame` with different `ProposalKind` types).

/// Recall-trace row re-export. The dreaming daemon reads these through
/// `DreamingSubstrateReader.recentRecallTraces`.
public typealias RecallTraceItem = LocusKit.RecallTraceItem

/// Tunnel (association edge) re-export. The dreaming daemon reads these
/// through `DreamingSubstrateReader.existingTunnels`.
public typealias Tunnel = LocusKit.Tunnel

/// Diary entry re-export. The dreaming and maintenance daemons write one
/// cycle summary per run through `DreamingProposalSink.recordCycleDiary` /
/// `MaintenanceProposalSink.recordCycleDiary`.
public typealias DiaryEntry = LocusKit.DiaryEntry

/// Sensitivity adjective re-export. Used in NeuronKit test helpers that
/// construct drawers, and in the maintenance daemon's forbidden-combination scan.
public typealias AdjectiveSensitivity = LocusKit.AdjectiveSensitivity

/// Exportability adjective re-export. Paired with `AdjectiveSensitivity` for
/// the I-3 forbidden-combination check (secret AND public).
public typealias AdjectiveExportability = LocusKit.AdjectiveExportability

/// Proposal re-export so the public `propose` return type is nameable
/// through the GLK module alone.
public typealias Proposal = LocusKit.Proposal

/// Association re-export so the public `associate` return type is nameable
/// through the GLK module alone.
public typealias Association = LocusKit.Association

/// Slots for the `propose` verb.
///
/// `propose` creates a Proposal row with `state = pending` (cookbook
/// §10.7). Per AriaLexicon's flow taxonomy, `propose` is
/// substrate-driven — emitted by the Brain layer's standing signals,
/// not invoked synchronously by application callers. The GLK verb
/// surface defines the frame so the nine-verb shape is consistent;
/// `propose` is fully live in the GLK-02 verb surface.
public struct ProposeFrame: Sendable, Equatable {
    /// The row this proposal is about (the target). Carried as a
    /// `RowID` because the substrate's RowReference resolves through
    /// the proposal table at write time; that resolution is Brain-layer
    /// work and not part of this scaffold.
    public let target: RowID
    /// Typed proposal taxonomy. See `ProposalKind` for the full
    /// vocabulary including production labels and test cases. The verb
    /// surface maps this GLK `ProposalKind` to a `LocusKit.ProposalKind`
    /// via `mapBrainKindToSubstrate`; the substrate-axis enum's rawValue
    /// is what is persisted and what the Rust port matches against.
    public let kind: ProposalKind
    /// Optional justification for the proposed change.
    public let justification: String?

    public init(target: RowID, kind: ProposalKind, justification: String? = nil) {
        self.target = target
        self.kind = kind
        self.justification = justification
    }
}

/// Slots for the `associate` verb.
///
/// `associate` creates or strengthens an Association row between two
/// rows (cookbook §10.8). Substrate-driven (Brain layer / dreaming
/// daemon). The GLK surface declares the frame so the nine-verb shape
/// is consistent; `associate` is fully live in the GLK-02 verb surface.
public struct AssociateFrame: Sendable, Equatable {
    /// One endpoint of the association.
    public let a: RowID
    /// The other endpoint.
    public let b: RowID
    /// Weight of the association in [0, 1]. The Brain layer interprets
    /// this; at the GLK boundary it is opaque.
    public let weight: Double

    public init(a: RowID, b: RowID, weight: Double) {
        self.a = a
        self.b = b
        self.weight = weight
    }
}
