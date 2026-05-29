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

/// DiaryEntry operational value types per
/// `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 5.6.
///
/// Four typed axes describe a diary entry's event semantics and
/// operational state, packed into the per-row `operationalBitmap`
/// Int64 column added by LOCI_V035_07B.
///
/// Pattern follows `TunnelOperational.swift` exactly: named-enum
/// accessors decode each axis from a single Int64 column with a
/// safe fallback to the zero case when an unrecognised raw value
/// appears.

/// What kind of substrate event this diary entry records.
/// Contiguous encoding, 12 cases used, raw values 12–15 reserved.
/// Per spec § 5.6, bits 0–3.
public enum DiaryEventClass: Int, Sendable, Codable {
    case capture        = 0   // a drawer or KGFact was written
    case mutation       = 1   // an adjective bitmap field was updated
    case withdraw       = 2   // state moved to the withdrew cluster
    case expunge        = 3   // hard removal from the estate
    case propose        = 4   // a proposal was emitted
    case associate      = 5   // an association tunnel was created
    case learn          = 6   // an agent updated a belief or model
    case signalEmission = 7   // a standing signal fired
    case maintenance    = 8   // substrate maintenance pass completed
    case migration      = 9   // data migrated in or out of estate
    case training       = 10  // training event recorded
    case auditTombstone = 11  // an audit row was tombstoned
    // 12–15 reserved
}

/// Log severity of this diary entry. Scale-gapped encoding (0/2/4/6)
/// so future intermediate tiers can slot in without disturbing masks.
/// `Comparable` so retrieval filters like `severity >= .warning`
/// compose without raw-value arithmetic. Per spec § 5.6, bits 4–6.
/// Sentinels: raw values 1, 3, 5, 7 return nil on init.
public enum DiarySeverity: Int, Sendable, Codable, Comparable {
    case trace   = 0
    case info    = 2
    case warning = 4
    case error   = 6

    public static func < (lhs: DiarySeverity, rhs: DiarySeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What kind of actor produced this diary entry. Contiguous encoding,
/// 5 cases used, raw values 5–7 reserved. Per spec § 5.6, bits 7–9.
public enum DiaryActorClass: Int, Sendable, Codable {
    case user            = 0
    case substrateDaemon = 1
    case mcpAgent        = 2
    case migrationTool   = 3
    case federationPeer  = 4
    // 5–7 reserved
}

/// Whether this entry is standalone or part of a batch operation.
/// Contiguous encoding, 4 cases used, raw values 4–7 reserved.
/// Per spec § 5.6, bits 10–12.
public enum DiaryBatchMembership: Int, Sendable, Codable {
    case standalone  = 0
    case batchStart  = 1
    case batchMember = 2
    case batchEnd    = 3
    // 4–7 reserved
}

// MARK: - DiaryEntry operational accessors

// Layout per spec § 5.6 (low-to-high):
//   bits 0–3   DiaryEventClass      (4 bits, contiguous, 12 cases)
//   bits 4–6   DiarySeverity        (3 bits, scale-gapped, 0/2/4/6)
//   bits 7–9   DiaryActorClass      (3 bits, contiguous, 5 cases)
//   bits 10–12 DiaryBatchMembership (3 bits, contiguous, 4 cases)
//   bit  13    requiresFollowup     (1 bit, exclusive)
//   bits 14–63 reserved
//
public extension DiaryEntry {

    /// Decode bits 0–3 of `operationalBitmap` as a `DiaryEventClass`.
    /// Returns `.capture` for unrecognised raw values.
    var eventClass: DiaryEventClass {
        // v0.35 layout: event_class at bits 0-3.
        DiaryEventClass(rawValue: Int(BitField.extractField(operationalBitmap, shift: 0, width: 4))) ?? .capture
    }

    /// Decode bits 4–6 of `operationalBitmap` as a `DiarySeverity`.
    /// Returns `.trace` for unrecognised raw values (including
    /// the intentionally-gapped scale raws 1, 3, 5, 7).
    var severity: DiarySeverity {
        // v0.35 layout: severity at bits 4-6.
        DiarySeverity(rawValue: Int(BitField.extractField(operationalBitmap, shift: 4, width: 3))) ?? .trace
    }

    /// Decode bits 7–9 of `operationalBitmap` as a `DiaryActorClass`.
    /// Returns `.user` for unrecognised raw values.
    var actorClass: DiaryActorClass {
        // v0.35 layout: actor_class at bits 7-9.
        DiaryActorClass(rawValue: Int(BitField.extractField(operationalBitmap, shift: 7, width: 3))) ?? .user
    }

    /// Decode bits 10–12 of `operationalBitmap` as a `DiaryBatchMembership`.
    /// Returns `.standalone` for unrecognised raw values.
    var batchMembership: DiaryBatchMembership {
        // v0.35 layout: batch_membership at bits 10-12.
        DiaryBatchMembership(rawValue: Int(BitField.extractField(operationalBitmap, shift: 10, width: 3))) ?? .standalone
    }

    /// True when bit 13 is set — this entry requires a follow-up action.
    /// False (informational) by default.
    var requiresFollowup: Bool {
        // v0.35 layout: bit 13 flag.
        BitField.extractFlag(operationalBitmap, bit: 13)
    }
}
