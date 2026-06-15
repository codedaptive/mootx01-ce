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

/// `LearnedReference` operational value types per cookbook § 2.4
/// ("LearnedReference operational", temporal-dominant, 6-bit floor).
///
/// Four axes describe how a learned reference refreshes, how stale it has
/// grown, how it was acquired, and where it came from. They pack into the
/// low 19 bits of `LearnedReference.operationalBitmap`:
///
/// ```
/// bits 0–5    refresh_policy   (scale-gapped, raws 0/16/24/32/48/56)
/// bits 6–11   drift_severity   (scale-gapped, raws 0/16/32/48)
/// bit  12     mode             (1 bit, 0=byReference 1=byIngestion)
/// bits 13–18  source           (contiguous, raws 0…5)
/// bits 19–63  reserved
/// ```
///
/// Pattern mirrors `KGFactOperational` / `AssociationOperational`:
/// named-enum accessors decode each axis from a single Int64 column with a
/// safe fallback to the zero case when an unrecognised raw value appears
/// (including the intentional scale-gap sentinels).

// MARK: - RefreshPolicy

/// How often the reference is re-grounded against its source. Per cookbook
/// § 2.4 bits 0–5. Scale-gapped encoding so future cadences slot in without
/// disturbing existing masks; unrecognised raws fall back to `.none`.
///
/// `Comparable` orders by raw value (increasing refresh aggressiveness:
/// none < monthly < weekly < daily < onDemand < realtime), matching the
/// `AssociationDecayClass` pattern.
public enum RefreshPolicy: Int, Sendable, Codable, Comparable {
    case none = 0
    case monthly = 16
    case weekly = 24
    case daily = 32
    case onDemand = 48
    case realtime = 56

    public static func < (lhs: RefreshPolicy, rhs: RefreshPolicy) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - DriftSeverity

/// How far the reference has drifted from its source since last grounded.
/// Per cookbook § 2.4 bits 6–11. Scale-gapped encoding (raws 0/16/32/48);
/// unrecognised raws fall back to `.none`.
///
/// `Comparable` orders by raw value (increasing severity:
/// none < minor < major < critical).
public enum DriftSeverity: Int, Sendable, Codable, Comparable {
    case none = 0
    case minor = 16
    case major = 32
    case critical = 48

    public static func < (lhs: DriftSeverity, rhs: DriftSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - LearnMode

/// Whether the reference is held by pointer or its content was ingested.
/// Per cookbook § 2.4 bit 12 (a single-bit field). `.byReference` (0) keeps
/// only the handle; `.byIngestion` (1) means the content was pulled into
/// the estate at learn time.
public enum LearnMode: Int, Sendable, Codable {
    case byReference = 0
    case byIngestion = 1
}

// MARK: - LearnedReferenceSource

/// Where the reference was acquired from. Per cookbook § 2.4 bits 13–18,
/// contiguous. Six cases used; raws 6–63 reserved and fall back to `.user`.
/// (Distinct from the content `sourceCatalogID`, which identifies *which*
/// catalog entry; this axis records the *acquisition channel*.)
public enum LearnedReferenceSource: Int, Sendable, Codable {
    case user = 0
    case federation = 1
    case householdPairing = 2
    case fleetPairing = 3
    case tierInheritance = 4
    case pairedEstate = 5
}

// MARK: - LearnedReference accessors

// Layout per cookbook § 2.4 (low-to-high):
//   bits 0–5    refresh_policy   (6 bits, scale-gapped, raws 0/16/24/32/48/56)
//   bits 6–11   drift_severity   (6 bits, scale-gapped, raws 0/16/32/48)
//   bit  12     mode             (1 bit, 0=byReference 1=byIngestion)
//   bits 13–18  source           (6 bits, contiguous, raws 0…5)
// Unknown raw values fall back to the zero case of each field axis,
// matching the `KGFact` / `Association` operational accessors.
public extension LearnedReference {

    /// Decode bits 0–5 of `operationalBitmap` as a `RefreshPolicy`.
    /// Returns `.none` for unrecognised raws, including the scale-gap
    /// sentinels.
    var refreshPolicy: RefreshPolicy {
        // Cookbook § 2.4: refresh_policy at bits 0–5.
        RefreshPolicy(rawValue: Int(BitField.extractField(operationalBitmap, shift: 0, width: 6))) ?? .none
    }

    /// Decode bits 6–11 of `operationalBitmap` as a `DriftSeverity`.
    /// Returns `.none` for unrecognised raws, including the scale-gap
    /// sentinels.
    var driftSeverity: DriftSeverity {
        // Cookbook § 2.4: drift_severity at bits 6–11.
        DriftSeverity(rawValue: Int(BitField.extractField(operationalBitmap, shift: 6, width: 6))) ?? .none
    }

    /// Decode bit 12 of `operationalBitmap` as a `LearnMode`. Bit clear =
    /// `.byReference`, bit set = `.byIngestion`.
    var mode: LearnMode {
        // Cookbook § 2.4: mode at bit 12.
        BitField.extractFlag(operationalBitmap, bit: 12) ? .byIngestion : .byReference
    }

    /// Decode bits 13–18 of `operationalBitmap` as a `LearnedReferenceSource`.
    /// Returns `.user` for unrecognised raws (raws 6–63 reserved).
    var acquisitionSource: LearnedReferenceSource {
        // Cookbook § 2.4: source at bits 13–18.
        LearnedReferenceSource(rawValue: Int(BitField.extractField(operationalBitmap, shift: 13, width: 6))) ?? .user
    }
}
