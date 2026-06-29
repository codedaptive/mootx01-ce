// LatticeAnchorInference.swift
//
// The output of the deterministic linguistic pipeline (per
// MISSION_AE_01_LINGUISTIC_PIPELINE.md). Pure data; identical
// shape to the Rust version's `LatticeAnchorInference` struct so
// callers can serialize and conformance-test cross-language.
//
// Consumed by `NeuronKit.inferLatticeAnchor(_:)` as the return type.
// The GLK capture verb path and the standing-signal enrichment scheduler
// (GLK-04) have not yet wired in this type directly. When GLK-04
// wires it in, the enrichment status bits are designed to be OR'd
// into the provenance column's bits 36-41 per cookbook section 2.5.

import Foundation

/// The result of inferring a lattice anchor from a drawer's
/// content. Carries the MDCC code, the optional Wikidata Q-ID,
/// a confidence score, and the provenance enrichment-status bit
/// transition the caller should apply.
public struct LatticeAnchorInference: Equatable, Sendable, Codable {

    /// The MDCC code resolved from the canon. Empty string means no
    /// canon entry matched; the caller should leave the drawer's
    /// code unset or fall back to a default.
    public let code: String

    /// The Wikidata Q-ID for the drawer's primary concept, or nil
    /// if the resolver could not find a confident match. When nil,
    /// the enrichment status records `qidPending` so a later
    /// enrichment pass can retry.
    public let wikidataQID: String?

    /// Confidence in the inference, packed into the 6-bit
    /// provenance confidence field's value set (0=null, 16=low,
    /// 32=medium, 48=high, 56=verified). Reported as a UInt8 so
    /// the caller can OR it into the provenance bitmap directly.
    public let confidence: UInt8

    /// The value to OR into bits 36-41 of the provenance column
    /// to record the enrichment status. Values per cookbook
    /// section 2.5: 0=none, 1=qid_pending, 2=qid_completed,
    /// 3=closure_cached, 4=qid_proposed, 5-63 reserved.
    public let enrichmentStatusBits: UInt8

    /// The pipeline mode that produced this inference. Recorded
    /// so audit and recall can distinguish deterministic-reference
    /// anchors from Apple-NL-accelerated anchors per
    /// MISSION_AE_02 and MISSION_AE_03.
    public let pipelineMode: LinguisticPipelineMode

    public init(
        code: String,
        wikidataQID: String?,
        confidence: UInt8,
        enrichmentStatusBits: UInt8,
        pipelineMode: LinguisticPipelineMode
    ) {
        self.code = code
        self.wikidataQID = wikidataQID
        self.confidence = confidence
        self.enrichmentStatusBits = enrichmentStatusBits
        self.pipelineMode = pipelineMode
    }
}

/// Confidence values mapped to the 6-bit provenance confidence
/// field's value set. Provided as a convenience for the linguistic
/// pipeline implementation; mirrors cookbook section 2.5.
public enum AnchorConfidence: UInt8 {
    case null     = 0
    case low      = 16
    case medium   = 32
    case high     = 48
    case verified = 56
}

/// Enrichment status values for bits 36-41 of the provenance
/// column. Mirrors cookbook section 2.5.
public enum EnrichmentStatus: UInt8 {
    /// The drawer has not been processed by the enrichment
    /// pipeline yet.
    case none = 0

    /// MDCC code resolved; Q-ID resolution pending (the resolver
    /// did not find a confident match and the maintenance daemon
    /// should retry).
    case qidPending = 1

    /// MDCC code and Q-ID both resolved.
    case qidCompleted = 2

    /// Q-ID resolved and the Wikidata subclass closure has been
    /// cached for graph-distance queries.
    case closureCached = 3

    /// Deterministic re-inference could not resolve the Q-ID and the
    /// maintenance daemon filed an enrichment proposal for human/agent
    /// review. A terminal "in workflow" state, NOT passive pending: the
    /// daemon's `qidPending` retry scan does not re-pick these rows, so
    /// they leave the retry backlog. Proposal acceptance flips the row to
    /// `qidCompleted` (cookbook §2.5; Q-ID-completion terminal workflow).
    case qidProposed = 4
}
