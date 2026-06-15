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

/// Provenance bitmap value types per cookbook §2.5 (v0.36 amendments)
/// and §2.8 (verification table).
///
/// The provenance bitmap is the third of three Int64 columns each
/// drawer row carries (the first being `adjectiveBitmap` per §2.3, the
/// second `operationalBitmap` per §2.4, and this one per §2.5). Where
/// adjective is cross-noun and operational is per-noun-mechanical,
/// provenance records HOW the row came into being and HOW it has been
/// reviewed since.
///
/// Provenance bitmap layout (cookbook §2.5 v0.6, low-to-high):
///
/// ```
/// bits 0–5    source_type            (contiguous, 10 cases at raw 0…9)
/// bits 6–11   channel                (contiguous with gaps)
/// bits 12–17  capture_channel        (mirrors operational §2.4)
/// bits 18–23  confirmation           (contiguous, 5 cases at raw 0…4)
/// bits 24–29  confidence             (scale-gapped, 0/16/32/48/56)
/// bits 30–35  sensitivity_at_capture (scale-gapped, mirrors adjective sensitivity)
/// bits 36–41  enrichment_status      (contiguous, 5 cases at raw 0…4)
/// bits 42–63  reserved
/// ```
///
/// F13 cascade (2026-05-27): bumped from v0.35 4-bit-floor layout to
/// cookbook v0.6 6-bit-floor with vocabulary rewrites:
/// - `SourceType` vocab restructured (10 cases per cookbook; `unknown`,
///   `userStated`, `modelInferred`, `externalDoc`, `instruction` removed
///   or remapped; `canonical`, `federationAggregate`, `tierAggregate`,
///   `pairedEstate`, `ambient`, `actuator` added).
/// - `ConfirmationState` renamed `Confirmation` with 5 cases (misplaced
///   state cases `contested`/`superseded`/`tombstoned` removed; new
///   `peerConfirmed`, `actuatorConfirmed` added).
/// - `Channel` vocab pivoted from messaging platforms (slack, email,
///   teams, etc.) to system surfaces (uiTyped, mcpAgent, fileImport,
///   federation, dream daemons).
/// - `Confidence` reduced from 7 contiguous cases to 5 scale-gapped.
/// - `Sensitivity` scale-gapped to mirror adjective sensitivity.
/// - NEW: `CaptureChannel` (mirrored from operational §2.4 — typealias
///   to the operational-layer enum for vocabulary consistency).
/// - NEW: `EnrichmentStatus` for QID lifecycle.

// MARK: - SourceType (cookbook §2.5 bits 0-5)

/// Source type axis of provenance — how the content originated.
/// Lives in bits 0–5 of the drawer's `provenance` bitmap (6 bits per
/// cookbook §2.5).
///
/// Contiguous encoding: raw values 0–9 are the v0.6 set; 10–63 are
/// reserved.
public enum SourceType: Int, Sendable, Codable {
    /// Raw 0 — content supplied by the user directly. F13: replaces v0.35
    /// `unknown` (raw 0) and `userStated` (raw 2). Default fallback.
    case user = 0
    /// Raw 1 — substrate observed the content (sensor, daemon, etc.).
    case observed = 1
    /// Raw 2 — imported from an external corpus or file. F13: subsumes
    /// v0.35 `externalDoc`.
    case imported = 2
    /// Raw 3 — substrate-blessed canonical reference (NEW in v0.6).
    case canonical = 3
    /// Raw 4 — derived from existing content via substrate inference.
    /// F13: subsumes v0.35 `modelInferred`.
    case derived = 4
    /// Raw 5 — aggregated across estate boundary (NEW in v0.6 §7.4).
    case federationAggregate = 5
    /// Raw 6 — aggregated across tier (NEW in v0.6 case 3).
    case tierAggregate = 6
    /// Raw 7 — paired-estate content (NEW in v0.6 case 1).
    case pairedEstate = 7
    /// Raw 8 — AmbientSample noun type (NEW in v0.6 §2.5).
    case ambient = 8
    /// Raw 9 — actuator-originated content (NEW in v0.6 case 2).
    case actuator = 9
}

// MARK: - Channel (cookbook §2.5 bits 6-11)

/// Channel axis — the system surface the content arrived on.
/// Lives in bits 6–11 of `provenance` (6 bits per cookbook §2.5).
///
/// F13 vocab pivot from messaging-platform-focused v0.35 (slack,
/// email, teams, etc.) to system-surface-focused v0.6 (UI input
/// methods, MCP agent, dream daemons, federation). Cases with gaps
/// 9–14 reserved per cookbook for future expansion.
public enum Channel: Int, Sendable, Codable {
    case uiTyped = 0
    case uiVoiced = 1
    case mcpAgent = 2
    case fileImport = 3
    case apiGrounding = 4
    case federationInbound = 5
    case dreamProposal = 6
    case dreamAssociation = 7
    case dreamMiningResult = 8
    // raws 9–14 reserved per cookbook §2.5
    case deviceSensor = 15        // NEW
    case actuatorOutcome = 16     // NEW
    // raws 17–63 reserved
}

// MARK: - CaptureChannel (cookbook §2.5 bits 12-17, mirrored from operational §2.4)
//
// CaptureChannel is defined in DrawerOperational.swift; cookbook §2.5
// says these bits "mirror" the operational §2.4 capture_channel field,
// so the same enum is used here. The provenance bitmap stores its own
// independent copy of the capture channel that was active when the
// drawer was filed — the operational bitmap's value can drift through
// the row's lifecycle (e.g., a captured drawer is later re-channeled),
// but the provenance record locks in the original.

// MARK: - Confirmation (cookbook §2.5 bits 18-23)

/// Confirmation axis — review status. Lives in bits 18–23 of
/// `provenance` (6 bits per cookbook §2.5).
///
/// F13 rename from `ConfirmationState`. Misplaced v0.35 state cases
/// (`contested`, `superseded`, `tombstoned`) removed — those belong
/// in the adjective bitmap's State field, not on the confirmation
/// axis. NEW: `peerConfirmed` (cross-estate), `actuatorConfirmed`.
public enum Confirmation: Int, Sendable, Codable {
    case unconfirmed = 0
    case userConfirmed = 1
    case automatedConfirmed = 2    // F13: was v0.35 `modelConfirmed`
    case peerConfirmed = 3         // NEW: cross-estate confirmation
    case actuatorConfirmed = 4     // NEW
    // raws 5–63 reserved
}

// MARK: - Confidence (cookbook §2.5 bits 24-29)

/// Confidence axis — system posterior. Lives in bits 24–29 of
/// `provenance` (6 bits scale-gapped per cookbook §2.5).
///
/// F13 raw-value rewrite: v0.35 had 7 contiguous cases (unknown=0
/// through certain=6); cookbook v0.6 has 5 scale-gapped cases
/// (null=0, low=16, medium=32, high=48, verified=56). `Comparable`
/// ordering preserved by raw-value comparison.
public enum Confidence: Int, Sendable, Codable, Comparable {
    case null = 0          // F13: was `unknown` in v0.35
    case low = 16
    case medium = 32
    case high = 48
    case verified = 56     // F13: was `certain` in v0.35

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Sensitivity (cookbook §2.5 bits 30-35)

/// Sensitivity at capture — per-drawer access posture frozen at the
/// moment of capture. Lives in bits 30–35 of `provenance` (6 bits
/// scale-gapped per cookbook §2.5; mirrors adjective sensitivity raws).
///
/// F13 raw-value rewrite: v0.35 contiguous 0/1/2/3 → v0.6 scale-gapped
/// 0/16/32/48 to mirror `AdjectiveSensitivity`. Cross-field comparison
/// (provenance sensitivity == adjective sensitivity) is now a direct
/// raw-value equality.
public enum Sensitivity: Int, Sendable, Codable {
    case normal = 0
    case elevated = 16
    case restricted = 32
    case secret = 48
}

// MARK: - EnrichmentStatus (cookbook §2.5 bits 36-41, NEW in v0.6)

/// Enrichment status — QID resolution lifecycle. Lives in bits 36–41
/// of `provenance` (6 bits per cookbook §2.5). NEW in v0.6.
public enum EnrichmentStatus: Int, Sendable, Codable {
    case none = 0
    case qidPending = 1
    case qidCompleted = 2
    case closureCached = 3
    /// Q-ID could not be resolved by deterministic re-inference and an
    /// enrichment proposal has been filed for human/agent review. A
    /// terminal "in workflow" state, NOT passive pending: the maintenance
    /// daemon's `qidPending` scan does not re-pick these rows, so they
    /// leave the retry backlog. Proposal acceptance moves the row to
    /// `qidCompleted` (cookbook §2.5; Q-ID-completion terminal workflow).
    case qidProposed = 4
    // raws 5–63 reserved
}

// MARK: - Drawer accessors

public extension Drawer {

    /// Decode bits 0–5 of `provenance` as a `SourceType`. Returns
    /// `.user` for unrecognised raw values (the neutral default per
    /// cookbook §2.5).
    var sourceType: SourceType {
        SourceType(rawValue: Int(BitField.extractField(provenance, shift: 0, width: 6))) ?? .user
    }

    /// Decode bits 6–11 of `provenance` as a `Channel`. Returns
    /// `.uiTyped` for unrecognised raw values (which includes the
    /// reserved-gap range 9–14, 17–63).
    var channel: Channel {
        Channel(rawValue: Int(BitField.extractField(provenance, shift: 6, width: 6))) ?? .uiTyped
    }

    /// Decode bits 12–17 of `provenance` as a `CaptureChannel`.
    /// Mirrors the operational-bitmap capture_channel field per cookbook
    /// §2.5. Returns `.typed` for unrecognised raw values.
    var provenanceCaptureChannel: CaptureChannel {
        CaptureChannel(rawValue: Int(BitField.extractField(provenance, shift: 12, width: 6))) ?? .typed
    }

    /// Decode bits 18–23 of `provenance` as a `Confirmation`.
    /// Returns `.unconfirmed` for unrecognised raw values so
    /// retrieval-layer filters that exclude unconfirmed content
    /// fail closed rather than open.
    var confirmation: Confirmation {
        Confirmation(rawValue: Int(BitField.extractField(provenance, shift: 18, width: 6))) ?? .unconfirmed
    }

    /// Decode bits 24–29 of `provenance` as a `Confidence`. Returns
    /// `.null` for unrecognised raw values (which includes the scale
    /// gaps between cookbook §2.5 raws 0/16/32/48/56).
    var confidence: Confidence {
        Confidence(rawValue: Int(BitField.extractField(provenance, shift: 24, width: 6))) ?? .null
    }

    /// Decode bits 30–35 of `provenance` as a `Sensitivity`. Returns
    /// `.normal` for unrecognised raw values, matching the
    /// estate-level default access posture. Mirrors the adjective
    /// sensitivity raws per cookbook §2.5.
    var sensitivity: Sensitivity {
        Sensitivity(rawValue: Int(BitField.extractField(provenance, shift: 30, width: 6))) ?? .normal
    }

    /// Decode bits 36–41 of `provenance` as an `EnrichmentStatus`.
    /// Returns `.none` for unrecognised raw values. NEW in v0.6.
    var enrichmentStatus: EnrichmentStatus {
        EnrichmentStatus(rawValue: Int(BitField.extractField(provenance, shift: 36, width: 6))) ?? .none
    }

    /// Convenience predicate — true when the drawer has been
    /// reviewed and approved by the user (the highest-trust
    /// confirmation axis). Used by retrieval layers that only
    /// surface user-vetted content for agent action context.
    var isUserConfirmed: Bool { confirmation == .userConfirmed }
}
