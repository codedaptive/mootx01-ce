import Foundation
import SubstrateTypes
import SubstrateKernel
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

/// A proposed change to the substrate, awaiting confirmation.
///
/// `Proposal` is the row-shaped noun behind the `proposal` lexicon
/// entry (`AriaLexiconLib/Acceptance.swift` — proposal accepts mutate,
/// withdraw, expunge, recall). A proposal records an intended write —
/// "create this tunnel", "mutate this drawer", "promote this
/// association" — that a confirmation step (human, agent, or automated
/// threshold) later accepts or rejects. The propose path is the
/// substrate's only autonomous write surface per cookbook §10.7; this
/// type is the durable record it produces.
///
/// This mission ships only the value type, its operational accessors,
/// the `proposals` table, and store persistence. No verb behaviour
/// (propose / accept / reject / withdraw / expunge / recall) is
/// implemented here — the verb missions target this substrate later.
///
/// `Proposal` mirrors `KGFact` structurally: an identity, three Int64
/// bitmap columns, and content fields, with one addition `KGFact`
/// predates — a required `latticeAnchor`. Per cookbook §2.7 (I-16)
/// every row carries a lattice anchor; proposals are anchored to their
/// target's anchor. The anchor is the field `KGFact` lacks because
/// `KGFact` was written before I-16 universalised the requirement.
///
/// Conformance note: `Proposal` is `Equatable, Codable, Sendable` but
/// deliberately **not** `Hashable`, where `KGFact` is. The difference
/// is the embedded `LatticeAnchor`, which is `Equatable, Codable,
/// Sendable` but not `Hashable` (see `EstateTypes.swift`). Synthesised
/// `Hashable` would require every stored property to be `Hashable`, so
/// `Proposal` cannot be `Hashable` without a hand-written conformance
/// or widening `LatticeAnchor` — neither warranted here, since nothing
/// keys a `Set`/dictionary on `Proposal`. The Rust port mirrors this:
/// it derives `PartialEq, Eq` but not `Hash`.
///
/// Three Int64 bitmap columns carry the operational axes:
///
/// - `adjectiveBitmap` — the proposal's own lifecycle state, trust,
///   sensitivity, exportability per cookbook §2.3. Shares the encoding
///   with `Drawer`'s adjective bitmap (accessors in `Adjectives.swift`).
///   The `state` accessor below decodes the lifecycle axis a proposal
///   moves through (`pending` → `accepted` / `rejected` / `withdrawn`).
/// - `operationalBitmap` — proposal kind, target object type,
///   confirmation source, generated-by class, and confidence bucket
///   per cookbook §2.4 ("Proposal operational"). See
///   `ProposalOperational.swift` for the five enums and the computed
///   accessors.
/// - `provenanceBitmap` — source type, confirmation, confidence,
///   channel, sensitivity per `Q1_DECISION_PROVENANCE_BITMAP.md`.
///
/// All three bitmaps default to `0` so callers constructing a bare
/// proposal get the safe baseline (kind `.newTunnel`, target `.drawer`,
/// confirmation `.human`, generated-by `.dreamingDaemon`, confidence
/// `.null`; state `.active`) without threading every axis through the
/// call site. The lifecycle `pending` state is applied by the propose
/// verb in a later mission, not by this value type — mirroring how
/// `KGFact` leaves its safe-baseline defaults at `0`.
public struct Proposal: Equatable, Codable, Sendable {

    /// Stable identifier for this proposal. Defaults to a fresh UUID
    /// string when omitted; callers replaying or importing proposals
    /// supply a deterministic id. Row identity is a UUID per cookbook
    /// I-29.
    public let id: String

    /// Identifier of the row this proposal acts on — the
    /// `RowReference` of cookbook §10.7's `propose(target:…)`. Empty
    /// for a brand-new-object proposal (target object type
    /// `.noneBrandNew`), where the proposal creates a row that does
    /// not yet exist; non-empty for proposals that mutate, withdraw,
    /// or promote an existing row.
    public let targetRowID: String

    /// Free-form explanation of why this proposal was generated — the
    /// `justification` of cookbook §10.7. Optional: automated-threshold
    /// proposals may carry none. The substrate enforces no vocabulary.
    public let justification: String?

    /// The adjective set this proposal would apply to its target if
    /// accepted — the `candidate_state` of cookbook §10.7. Encoded in
    /// the same adjective bitmap layout as `Drawer.adjectiveBitmap`
    /// (cookbook §2.3). Defaults to `0` (the target's adjectives
    /// unchanged from the safe baseline); the accept path reads this to
    /// know what to write.
    public let candidateState: Int64

    /// The proposal's lattice anchor — required on every row per
    /// cookbook §2.7 (I-16). Proposals are anchored to their target's
    /// anchor. `udcCode` must be non-empty at storage; `addProposal`
    /// rejects an empty anchor with `LocusKitError.invalidContent`,
    /// mirroring the capture-path guard in `EstateVerbs.swift`.
    public let latticeAnchor: LatticeAnchor

    /// Adjective bitmap encoding the proposal's own lifecycle state,
    /// trust, sensitivity, and exportability per cookbook §2.3. The
    /// `state` accessor decodes the lifecycle axis. Defaults to `0`
    /// (state `.active`); the propose verb stamps `.pending`.
    public let adjectiveBitmap: Int64

    /// Operational bitmap encoding proposal kind, target object type,
    /// confirmation source, generated-by class, and confidence bucket
    /// per cookbook §2.4. See `ProposalOperational.swift`. Defaults to
    /// `0` (kind `.newTunnel`, target `.drawer`, confirmation `.human`,
    /// generated-by `.dreamingDaemon`, confidence `.null`).
    public let operationalBitmap: Int64

    /// Provenance bitmap per `Q1_DECISION_PROVENANCE_BITMAP.md`.
    /// Defaults to `0` (all axes unknown / sensitivity normal).
    public let provenanceBitmap: Int64

    /// When this proposal was filed. Stored as TEXT ISO8601 in SQLite
    /// per the MOOTx01 fleet rule.
    public let filedAt: Date

    /// Designated initializer.
    public init(
        id: String = UUID().uuidString,
        targetRowID: String,
        justification: String? = nil,
        candidateState: Int64 = 0,
        latticeAnchor: LatticeAnchor,
        adjectiveBitmap: Int64 = 0,
        operationalBitmap: Int64 = 0,
        provenanceBitmap: Int64 = 0,
        filedAt: Date
    ) {
        self.id = id
        self.targetRowID = targetRowID
        self.justification = justification
        self.candidateState = candidateState
        self.latticeAnchor = latticeAnchor
        self.adjectiveBitmap = adjectiveBitmap
        self.operationalBitmap = operationalBitmap
        self.provenanceBitmap = provenanceBitmap
        self.filedAt = filedAt
    }
}

// MARK: - Adjective accessor (mirrors KGFact / Drawer pattern)

public extension Proposal {

    /// Decode bits 0–5 of `adjectiveBitmap` as a `State` (6-bit field,
    /// cookbook §2.3 — shared with `Drawer`). Returns `.active` for
    /// unrecognised raw values, the neutral fail-closed baseline
    /// matching `State(rawValue:)` elsewhere. `state` is the axis a
    /// proposal moves through over its lifecycle — `pending` while it
    /// awaits confirmation, then `accepted`, `rejected`, or `withdrawn`
    /// — so it is the adjective axis surfaced here, the way `KGFact`
    /// surfaces `trust`.
    var state: State {
        // Cookbook §2.3: state at bits 0–5.
        State(rawValue: Int(BitField.extractField(adjectiveBitmap, shift: 0, width: 6))) ?? .active
    }
}
