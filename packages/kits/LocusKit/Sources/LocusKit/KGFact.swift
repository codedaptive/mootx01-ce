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

/// A knowledge-graph fact extracted from drawer content per spec
/// `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 4.1.
///
/// `KGFact` is the first-class noun for rung 1.5 of the substrate: a
/// subject-predicate-object triple distilled from a verbatim drawer,
/// retaining a backreference to the source drawer so the fact's
/// provenance is always recoverable.
///
/// This mission ships only the value type and its operational
/// accessors. The `kg_facts` table and CRUD path land in
/// LOCI_V035_06B; nothing in this file touches persistence.
///
/// Three Int64 bitmap columns carry the operational axes:
///
/// - `adjectiveBitmap` — state, trust, sensitivity, exportability per
///   § 5.5. Accessors live alongside `Drawer`'s in `Adjectives.swift`;
///   `KGFact` reuses the same encoding so a fact and its source
///   drawer can be filtered by the same retrieval-layer predicates.
/// - `operationalBitmap` — extractor class, assertion kind,
///   specificity, confidence band, and the canonical flag per § 5.6.
///   See `KGFactOperational.swift` for the four enums and the
///   computed accessors (`extractorClass`, `assertionKind`,
///   `specificity`, `confidenceBand`, `isCanonical`).
/// - `provenanceBitmap` — source type, confirmation, confidence,
///   channel, sensitivity per `Q1_DECISION_PROVENANCE_BITMAP.md`.
///   Carried verbatim from the source drawer's provenance at
///   extraction time; the v1 accessors live on `Drawer` and are
///   re-exposed for `KGFact` in a later mission once the persistence
///   path requires them.
///
/// All three bitmaps default to `0` so callers extracting facts
/// without operational metadata get the safe baseline (extractor
/// `.manual`, assertion `.asserted`, specificity `.general`,
/// confidence `.unknown`, non-canonical) without having to thread
/// every axis through the call site.
public struct KGFact: Equatable, Hashable, Codable, Sendable {

    /// Stable identifier for this fact. Defaults to a fresh UUID
    /// string when omitted; callers replaying or importing previously-
    /// extracted facts supply a deterministic id (typically derived
    /// from `sourceDrawerID` + `subject` + `predicate` + `object`) so
    /// the kg_facts table can dedupe on re-extraction.
    public let id: String

    /// Subject of the triple. Free-form string; the substrate does
    /// not enforce an entity vocabulary at this layer. Entity-
    /// canonicalisation is a downstream concern handled when the
    /// federated KG layer activates (post LOCI-9).
    public let subject: String

    /// Predicate of the triple — the relationship vocabulary item
    /// linking subject and object. Free-form string at this rung;
    /// closed vocabularies (e.g., the tunnel-kind enum's relationship
    /// names) are enforced only by the agents extracting facts, not
    /// by the value type.
    public let predicate: String

    /// Object of the triple. Free-form string. May reference another
    /// entity by id or carry a literal value depending on the
    /// predicate; the value type makes no distinction.
    public let object: String

    /// Identifier of the drawer this fact was extracted from. Every
    /// fact must trace back to a drawer; cross-drawer derivations
    /// (multi-source synthesis) record the primary source here and
    /// surface the secondary sources in a derivation-link table that
    /// ships with the federated layer.
    public let sourceDrawerID: String

    /// Adjective bitmap encoding state, trust, sensitivity, and
    /// exportability per spec § 5.5. Shares the encoding with
    /// `Drawer.adjectiveBitmap` — accessors live in
    /// `Adjectives.swift` and apply to `KGFact` once persistence
    /// surfaces them. Defaults to `0` (state `.active`, trust
    /// `.verbatim`, sensitivity `.normal`, exportability `.private_`).
    public let adjectiveBitmap: Int64

    /// Operational bitmap encoding extractor class, assertion kind,
    /// specificity, confidence band, and the canonical flag per spec
    /// § 5.6. See `KGFactOperational.swift` for the four enums and
    /// the computed accessors. Defaults to `0` (extractor `.manual`,
    /// assertion `.asserted`, specificity `.general`, confidence
    /// `.unknown`, `isCanonical` false).
    public let operationalBitmap: Int64

    /// Provenance bitmap carried from the source drawer at extraction
    /// time per `Q1_DECISION_PROVENANCE_BITMAP.md`. Held verbatim so a
    /// fact's source-type / confirmation / confidence / channel /
    /// sensitivity remain recoverable without joining back to the
    /// drawer row. Defaults to `0` (all axes unknown / sensitivity
    /// normal).
    public let provenanceBitmap: Int64

    /// When this fact was filed. Stored as TEXT ISO8601 in SQLite
    /// per the MOOTx01 fleet rule once persistence ships.
    public let filedAt: Date

    /// Designated initializer.
    public init(
        id: String = UUID().uuidString,
        subject: String,
        predicate: String,
        object: String,
        sourceDrawerID: String,
        adjectiveBitmap: Int64 = 0,
        operationalBitmap: Int64 = 0,
        provenanceBitmap: Int64 = 0,
        filedAt: Date
    ) {
        self.id = id
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.sourceDrawerID = sourceDrawerID
        self.adjectiveBitmap = adjectiveBitmap
        self.operationalBitmap = operationalBitmap
        self.provenanceBitmap = provenanceBitmap
        self.filedAt = filedAt
    }
}

// MARK: - Adjective accessor (mirrors Drawer pattern)

public extension KGFact {

    /// Decode bits 18–23 of `adjectiveBitmap` as a `Trust` (6-bit field,
    /// cookbook §2.3 / §5.5 — shared with Drawer). Returns
    /// `.verbatim` for unrecognised raw values — the neutral baseline
    /// matching `Drawer.trust` in `Adjectives.swift`. The four-axis
    /// adjective bitmap is shared with `Drawer`; only the `trust`
    /// accessor is exposed here because it is the axis the
    /// extraction pipeline consults most often when filing facts.
    /// State, exportability, and sensitivity accessors land alongside
    /// the persistence path in LOCI_V035_06B when retrieval needs
    /// them.
    var trust: Trust {
        // Cookbook §2.3: trust at bits 18–23.
        Trust(rawValue: Int(BitField.extractField(adjectiveBitmap, shift: 18, width: 6))) ?? .verbatim
    }
}
