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

/// `KGFact` operational value types per
/// `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 5.6.
///
/// Four typed axes plus one flag describe how a fact was extracted
/// and how strongly it is asserted. They pack into the low 14 bits of
/// `KGFact.operationalBitmap`:
///
/// ```
/// bits 0–3   KGExtractorClass   (contiguous, 6 cases at raw 0…5)
/// bits 4–6   KGAssertionKind    (contiguous, 4 cases at raw 0…3)
/// bits 7–9   KGSpecificity      (scale-gapped, raws 0/2/4/6)
/// bits 10–12 KGConfidenceBand   (scale-gapped, raws 0/1/2/4/6)
/// bit  13    isCanonical        (1 bit, exclusive)
/// ```
///
/// Pattern mirrors `Adjectives.swift` and `TunnelOperational.swift`:
/// named-enum accessors decode each axis from a single Int64 column
/// with a safe fallback to the zero case when an unrecognised raw
/// value appears (including the intentional scale-gap sentinels —
/// raws 1, 3, 5 for specificity; raws 3, 5 for confidence band).

/// What kind of extractor produced this fact. Per spec § 5.6.
/// Contiguous encoding: 6 used, 10 reserved within the 4-bit field.
///
/// The cases form a rough rigour ladder — `.manual` is human-asserted,
/// `.foundationModel` is general-purpose LLM extraction,
/// `.specializedModel` is a domain-tuned extractor, `.rulesBased` is
/// deterministic pattern matching, `.importedKG` is content lifted
/// from an external knowledge graph, and `.federated` is a fact
/// replicated from another estate.
public enum KGExtractorClass: Int, Sendable, Codable {
    case manual = 0
    case foundationModel = 1
    case specializedModel = 2
    case rulesBased = 3
    case importedKG = 4
    case federated = 5
}

/// How firmly the fact is asserted. Per spec § 5.6. Contiguous
/// encoding; 4 used, 4 reserved within the 3-bit field.
///
/// `.asserted` is the default (the extractor stands behind the
/// triple). `.inferred` marks derived facts that did not appear
/// verbatim in the source. `.hypothesized` is provisional and
/// downgrades retrieval weight. `.contradicted` records that another
/// fact disputes this one without retracting either — the resolution
/// happens at retrieval time.
public enum KGAssertionKind: Int, Sendable, Codable {
    case asserted = 0
    case inferred = 1
    case hypothesized = 2
    case contradicted = 3
}

/// How specific the fact's claim is along the entity-to-instance
/// spectrum. Per spec § 5.6. Scale-gapped encoding (raws 0/2/4/6) so
/// future intermediate tiers can slot in semantically without
/// disturbing existing equality or ordering masks. Sentinels at raws
/// 1, 3, 5 are intentionally `nil`.
///
/// `Comparable` so retrieval-layer filters such as
/// `fact.specificity >= .specific` compose without raw-value math,
/// matching the pattern `TunnelStrength` uses in
/// `TunnelOperational.swift`.
public enum KGSpecificity: Int, Sendable, Codable, Comparable {
    case general = 0
    case domain = 2
    case specific = 4
    case instance = 6

    public static func < (lhs: KGSpecificity, rhs: KGSpecificity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Coarse confidence band for the fact. Per spec § 5.6. Scale-gapped
/// encoding with one near-zero cluster (`.unknown` / `.low` /
/// `.medium` at raws 0/1/2) and a gap before `.high` (raw 4) and
/// `.certain` (raw 6); sentinels at raws 3, 5 are intentionally
/// `nil` so a future `veryHigh` tier can slot between `.high` and
/// `.certain` without renumbering.
///
/// `Comparable` so retrieval-layer filters such as
/// `fact.confidenceBand >= .high` compose without raw-value math.
/// Distinct from `Confidence` on the provenance bitmap — that axis
/// describes the *source* of a drawer, this axis describes the
/// *extractor*'s belief in the fact.
public enum KGConfidenceBand: Int, Sendable, Codable, Comparable {
    case unknown = 0
    case low = 1
    case medium = 2
    case high = 4
    case certain = 6

    public static func < (lhs: KGConfidenceBand, rhs: KGConfidenceBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - KGFact accessors

// Layout per spec § 5.6 (low-to-high):
//   bits 0–3   KGExtractorClass   (4 bits, contiguous, 6 cases)
//   bits 4–6   KGAssertionKind    (3 bits, contiguous, 4 cases)
//   bits 7–9   KGSpecificity      (3 bits, scale-gapped, raws 0/2/4/6)
//   bits 10–12 KGConfidenceBand   (3 bits, scale-gapped, raws 0/1/2/4/6)
//   bit  13    isCanonical        (1 bit; 0 = local, 1 = canonical_to_estate)
// Unknown raw values fall back to the zero case of each axis,
// matching the `Drawer` adjective accessors in `Adjectives.swift`.
public extension KGFact {

    /// Decode bits 0–3 of `operationalBitmap` as a `KGExtractorClass`.
    /// Returns `.manual` for unrecognised raw values (raws 6–15 are
    /// reserved). Manual is the safe baseline — surfacing an unknown
    /// extractor as "human-asserted" makes a future-version fact look
    /// more trustworthy than it should, which is the failure mode we
    /// want: forces a review pass rather than silently downgrading.
    var extractorClass: KGExtractorClass {
        // v0.35 layout: extractor_class at bits 0-3.
        KGExtractorClass(rawValue: Int(BitField.extractField(operationalBitmap, shift: 0, width: 4))) ?? .manual
    }

    /// Decode bits 4–6 of `operationalBitmap` as a `KGAssertionKind`.
    /// Returns `.asserted` for unrecognised raw values (raws 4–7 are
    /// reserved).
    var assertionKind: KGAssertionKind {
        // v0.35 layout: assertion_kind at bits 4-6.
        KGAssertionKind(rawValue: Int(BitField.extractField(operationalBitmap, shift: 4, width: 3))) ?? .asserted
    }

    /// Decode bits 7–9 of `operationalBitmap` as a `KGSpecificity`.
    /// Returns `.general` for unrecognised raw values, including the
    /// intentionally-gapped scale raws 1, 3, 5 (sentinels) and the
    /// unused raw 7.
    var specificity: KGSpecificity {
        // v0.35 layout: specificity at bits 7-9.
        KGSpecificity(rawValue: Int(BitField.extractField(operationalBitmap, shift: 7, width: 3))) ?? .general
    }

    /// Decode bits 10–12 of `operationalBitmap` as a
    /// `KGConfidenceBand`. Returns `.unknown` for unrecognised raw
    /// values, including the intentionally-gapped scale raws 3, 5
    /// (sentinels) and the unused raw 7.
    var confidenceBand: KGConfidenceBand {
        // v0.35 layout: confidence_band at bits 10-12.
        KGConfidenceBand(rawValue: Int(BitField.extractField(operationalBitmap, shift: 10, width: 3))) ?? .unknown
    }

    /// Decode bit 13 of `operationalBitmap`. True when this fact has
    /// been promoted to canonical-to-estate status (a fact every
    /// agent in the estate should treat as load-bearing); false when
    /// it is local to its source drawer.
    var isCanonical: Bool {
        // v0.35 layout: bit 13 flag.
        BitField.extractFlag(operationalBitmap, bit: 13)
    }
}
