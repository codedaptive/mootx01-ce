import Foundation
import SubstrateTypes
import SubstrateKernel
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

/// `Proposal` operational value types per cookbook §2.4 ("Proposal
/// operational", v0.36, 6-bit floor).
///
/// Five typed axes describe what a proposal proposes and how it was
/// generated. They pack into the low 30 bits of
/// `Proposal.operationalBitmap`:
///
/// ```
/// bits 0–5   ProposalKind                (contiguous, raws 0…8)
/// bits 6–11  ProposalTargetObjectType    (contiguous, raws 0…6)
/// bits 12–17 ProposalConfirmationSource  (contiguous, raws 0…3)
/// bits 18–23 ProposalGeneratedByClass    (contiguous, raws 0…4)
/// bits 24–29 ProposalConfidenceBucket    (scale-gapped, raws 0/8/16/32/48)
/// bits 30–63 reserved
/// ```
///
/// Pattern mirrors `KGFactOperational.swift`: named-enum accessors
/// decode each axis from a single Int64 column with a safe fallback to
/// the zero case when an unrecognised raw value appears (including the
/// intentional scale-gap sentinels of the confidence bucket).
///
/// Unlike `KGFact` (a LocusKit-internal layout), the Proposal
/// operational layout *is* specified by cookbook §2.4, so the
/// conformance gate in `ProposalTests` pins every raw value and field
/// position to the cookbook table.

// MARK: - ProposalKind

/// What kind of write this proposal proposes. Per cookbook §2.4 bits
/// 0–5. Contiguous encoding: 9 used (raws 0…8), the rest reserved
/// within the 6-bit field.
///
/// `.newTunnel`, `.mutateDrawer`, `.withdrawDrawer`, `.newKGFact`,
/// `.associationPromotion`, and `.miningPatternAdjustment` are the
/// original kinds; `.actionProposal` (case 2 actuators),
/// `.recordObservation`, and `.tierAdvisory` (case 3 tiering) are the
/// v0.36 additions.
///
/// Distinct from `GeniusLocusKit`'s Brain-layer `ProposalKind` (the
/// routing-queue signal labels) — this is the substrate row's kind
/// axis from cookbook §2.4, a different vocabulary at a different
/// altitude.
public enum ProposalKind: Int, Sendable, Codable {
    case newTunnel = 0
    case mutateDrawer = 1
    case withdrawDrawer = 2
    case newKGFact = 3
    case associationPromotion = 4
    case miningPatternAdjustment = 5
    case actionProposal = 6
    case recordObservation = 7
    case tierAdvisory = 8
}

// MARK: - ProposalTargetObjectType

/// The kind of row this proposal targets. Per cookbook §2.4 bits 6–11.
/// Contiguous encoding; 7 used (raws 0…6).
///
/// `.noneBrandNew` marks a proposal that creates a row not yet in the
/// substrate (e.g. a `.newTunnel` proposal), where `targetRowID` is
/// empty. `.systemState` (case 2) targets the estate's own state
/// rather than a noun row.
public enum ProposalTargetObjectType: Int, Sendable, Codable {
    case drawer = 0
    case tunnel = 1
    case kgfact = 2
    case association = 3
    case noneBrandNew = 4
    case ambientSample = 5
    case systemState = 6
}

// MARK: - ProposalConfirmationSource

/// Who or what confirms this proposal. Per cookbook §2.4 bits 12–17.
/// Contiguous encoding; 4 used (raws 0…3).
///
/// `.human` and `.agent` are interactive confirmations;
/// `.automatedThreshold` is a confidence-gated automatic accept;
/// `.actuator` (case 2) is an actuator policy confirming an action
/// proposal it executed.
public enum ProposalConfirmationSource: Int, Sendable, Codable {
    case human = 0
    case agent = 1
    case automatedThreshold = 2
    case actuator = 3
}

// MARK: - ProposalGeneratedByClass

/// What class of producer generated this proposal. Per cookbook §2.4
/// bits 18–23. Contiguous encoding; 5 used (raws 0…4).
///
/// `.dreamingDaemon` is the background dreaming pass, `.mcpAgent` an
/// MCP-connected agent, `.federationSync` a federation inbound,
/// `.manual` a hand-authored proposal, and `.tierAggregator` (NEW) a
/// tier-rollup producer.
public enum ProposalGeneratedByClass: Int, Sendable, Codable {
    case dreamingDaemon = 0
    case mcpAgent = 1
    case federationSync = 2
    case manual = 3
    case tierAggregator = 4
}

// MARK: - ProposalConfidenceBucket

/// Coarse confidence bucket for the proposal. Per cookbook §2.4 bits
/// 24–29. Scale-gapped encoding (raws 0/8/16/32/48) so future
/// intermediate buckets can slot in without disturbing existing
/// equality or ordering masks; every other raw is an intentional
/// sentinel that falls back to `.null`.
///
/// `Comparable` so retrieval-layer filters such as
/// `proposal.confidenceBucket >= .high` compose without raw-value
/// math, matching the pattern `KGConfidenceBand` uses in
/// `KGFactOperational.swift`.
public enum ProposalConfidenceBucket: Int, Sendable, Codable, Comparable {
    case null = 0
    case low = 8
    case medium = 16
    case high = 32
    case verified = 48

    public static func < (lhs: ProposalConfidenceBucket, rhs: ProposalConfidenceBucket) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Proposal accessors

// Layout per cookbook §2.4 (low-to-high):
//   bits 0–5   ProposalKind                (6 bits, contiguous, raws 0…8)
//   bits 6–11  ProposalTargetObjectType    (6 bits, contiguous, raws 0…6)
//   bits 12–17 ProposalConfirmationSource  (6 bits, contiguous, raws 0…3)
//   bits 18–23 ProposalGeneratedByClass    (6 bits, contiguous, raws 0…4)
//   bits 24–29 ProposalConfidenceBucket    (6 bits, scale-gapped, 0/8/16/32/48)
// Unknown raw values fall back to the zero case of each axis, matching
// the `KGFact` operational accessors in `KGFactOperational.swift`.
public extension Proposal {

    /// Decode bits 0–5 of `operationalBitmap` as a `ProposalKind`.
    /// Returns `.newTunnel` for unrecognised raw values (raws 9–63
    /// reserved).
    var proposalKind: ProposalKind {
        // Cookbook §2.4: proposal_kind at bits 0–5.
        ProposalKind(rawValue: Int(BitField.extractField(operationalBitmap, shift: 0, width: 6))) ?? .newTunnel
    }

    /// Decode bits 6–11 of `operationalBitmap` as a
    /// `ProposalTargetObjectType`. Returns `.drawer` for unrecognised
    /// raw values (raws 7–63 reserved).
    var targetObjectType: ProposalTargetObjectType {
        // Cookbook §2.4: target_object_type at bits 6–11.
        ProposalTargetObjectType(rawValue: Int(BitField.extractField(operationalBitmap, shift: 6, width: 6))) ?? .drawer
    }

    /// Decode bits 12–17 of `operationalBitmap` as a
    /// `ProposalConfirmationSource`. Returns `.human` for unrecognised
    /// raw values (raws 4–63 reserved).
    var confirmationSource: ProposalConfirmationSource {
        // Cookbook §2.4: confirmation_source at bits 12–17.
        ProposalConfirmationSource(rawValue: Int(BitField.extractField(operationalBitmap, shift: 12, width: 6))) ?? .human
    }

    /// Decode bits 18–23 of `operationalBitmap` as a
    /// `ProposalGeneratedByClass`. Returns `.dreamingDaemon` for
    /// unrecognised raw values (raws 5–63 reserved).
    var generatedByClass: ProposalGeneratedByClass {
        // Cookbook §2.4: generated_by_class at bits 18–23.
        ProposalGeneratedByClass(rawValue: Int(BitField.extractField(operationalBitmap, shift: 18, width: 6))) ?? .dreamingDaemon
    }

    /// Decode bits 24–29 of `operationalBitmap` as a
    /// `ProposalConfidenceBucket`. Returns `.null` for unrecognised
    /// raw values, including the intentionally-gapped scale sentinels.
    var confidenceBucket: ProposalConfidenceBucket {
        // Cookbook §2.4: confidence_bucket at bits 24–29.
        ProposalConfidenceBucket(rawValue: Int(BitField.extractField(operationalBitmap, shift: 24, width: 6))) ?? .null
    }

    /// Compose a proposal `operationalBitmap` from its four typed axes per
    /// cookbook §2.4 (kind 0–5, target object type 6–11, generated-by class
    /// 18–23, confidence bucket 24–29; confirmation source 12–17 is left at
    /// its zero case `.human` until a confirmation step runs). Field
    /// placement goes through the conformance-gated `BitField.writeField`
    /// primitive — never hand-rolled shift/mask math. Used by the autonomic
    /// daemon sinks to stamp genuine provenance on the proposals they emit.
    static func composeOperational(
        kind: ProposalKind,
        targetObjectType: ProposalTargetObjectType,
        generatedBy: ProposalGeneratedByClass,
        confidence: ProposalConfidenceBucket
    ) -> Int64 {
        var bits: Int64 = 0
        bits = BitField.writeField(Int64(kind.rawValue), into: bits, shift: 0, width: 6)
        bits = BitField.writeField(Int64(targetObjectType.rawValue), into: bits, shift: 6, width: 6)
        bits = BitField.writeField(Int64(generatedBy.rawValue), into: bits, shift: 18, width: 6)
        bits = BitField.writeField(Int64(confidence.rawValue), into: bits, shift: 24, width: 6)
        return bits
    }
}
