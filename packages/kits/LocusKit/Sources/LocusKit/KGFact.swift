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

/// Optional machine-extraction fields threaded through the composed KGFact
/// capture door. Manual and imported callers use `.empty`.
public struct KGFactExtractionMetadata: Sendable, Equatable, Hashable, Codable {
    public let evidenceQuote: String
    public let evidenceStart: Int
    public let evidenceEnd: Int
    public let evidenceStartUTF8Byte: Int
    public let evidenceEndUTF8Byte: Int
    public let sourceDigest: String
    public let extractorProviderID: String
    public let extractorModelID: String
    public let extractorModelVersion: String
    public let extractionSchemaVersion: String
    public let searchProjection: String
    public let searchProjectionVersion: String
    public let operationalBitmap: Int64

    public init(
        evidenceQuote: String, evidenceStart: Int, evidenceEnd: Int,
        evidenceStartUTF8Byte: Int, evidenceEndUTF8Byte: Int,
        sourceDigest: String, extractorProviderID: String, extractorModelID: String,
        extractorModelVersion: String, extractionSchemaVersion: String,
        searchProjection: String, searchProjectionVersion: String,
        operationalBitmap: Int64
    ) {
        self.evidenceQuote = evidenceQuote
        self.evidenceStart = evidenceStart
        self.evidenceEnd = evidenceEnd
        self.evidenceStartUTF8Byte = evidenceStartUTF8Byte
        self.evidenceEndUTF8Byte = evidenceEndUTF8Byte
        self.sourceDigest = sourceDigest
        self.extractorProviderID = extractorProviderID
        self.extractorModelID = extractorModelID
        self.extractorModelVersion = extractorModelVersion
        self.extractionSchemaVersion = extractionSchemaVersion
        self.searchProjection = searchProjection
        self.searchProjectionVersion = searchProjectionVersion
        self.operationalBitmap = operationalBitmap
    }

    public static let empty = KGFactExtractionMetadata(
        evidenceQuote: "", evidenceStart: -1, evidenceEnd: -1,
        evidenceStartUTF8Byte: -1, evidenceEndUTF8Byte: -1, sourceDigest: "",
        extractorProviderID: "", extractorModelID: "", extractorModelVersion: "",
        extractionSchemaVersion: "", searchProjection: "", searchProjectionVersion: "",
        operationalBitmap: 0)
}

/// A knowledge-graph fact extracted from drawer content per spec
/// `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 4.1.
///
/// `KGFact` is the first-class noun for rung 1.5 of the substrate: a
/// subject-predicate-object triple distilled from a verbatim drawer,
/// retaining a backreference to the source drawer so the fact's
/// provenance is always recoverable.
///
/// The `kg_facts` table and CRUD path are implemented in `DrawerStore`
/// (`addKGFact`, `getKGFact`, `getKGFacts`, `allKGFacts`).
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
///   channel, sensitivity per `the packed provenance layout`.
///   Carried verbatim from the source drawer's provenance at
///   extraction time. Provenance accessors shared with `Drawer`
///   live in `Provenance.swift`.
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

    /// Identifier of the drawer this fact was extracted from — a
    /// **local** drawer id, or `""` when the fact is not anchored to a
    /// drawer. Nothing else is ever stored here: a host identity, a
    /// foreign palace's key, and a foreign record id each have their own
    /// field below. A non-empty value must resolve to a drawer in this
    /// estate; the capture verb fails the write when it does not.
    /// Cross-drawer derivations (multi-source synthesis) record the
    /// primary source here and surface the secondary sources in a
    /// derivation-link table that ships with the federated layer.
    public let sourceDrawerID: String

    /// Identity of the agent or host binary that filed this fact — for
    /// example `"mootx01"` or `"aria-mcp-server"` when the fact arrives
    /// through the MCP surface. Free-form; `""` when the filer is not
    /// recorded. This is provenance about *who wrote the row*, which is
    /// a different question from which drawer the fact was drawn from,
    /// so it does not share `sourceDrawerID`'s slot.
    public let addedBy: String

    /// The foreign palace's stable source key for the drawer this fact
    /// anchors to, carried verbatim from the exporting estate. Set only
    /// on palace-imported facts; `""` otherwise. The key is meaningful
    /// in the *foreign* estate's namespace and resolves to no local
    /// drawer, which is why it cannot live in `sourceDrawerID`.
    ///
    /// The palace re-import dedup signature (CAND-049) is built over
    /// this value, so it must survive round-trips byte-for-byte.
    public let foreignSourceKey: String

    /// The foreign palace's own identifier for the record that produced
    /// this fact — the triple id, e.g. `"t_fleet_works_with_skippy_0001"`.
    /// Set only on palace-imported facts; `""` otherwise. Like
    /// `foreignSourceKey` this names a row in the foreign estate, not a
    /// local drawer.
    public let foreignRecordID: String

    /// Verbatim evidence from the source drawer. Empty for manual, imported,
    /// or legacy facts that predate source-grounded extraction.
    public let evidenceQuote: String

    /// Half-open evidence range in Unicode code points. `-1/-1` means the
    /// fact has no machine-resolved source range.
    public let evidenceStart: Int
    public let evidenceEnd: Int

    /// UTF-8 byte form of the same half-open evidence range. Kept alongside
    /// code-point offsets so Swift and Rust never infer each other's index unit.
    public let evidenceStartUTF8Byte: Int
    public let evidenceEndUTF8Byte: Int

    /// SHA-256 of the exact source content used for extraction.
    public let sourceDigest: String

    /// Provider/model/schema provenance for rebuild and audit.
    public let extractorProviderID: String
    public let extractorModelID: String
    public let extractorModelVersion: String
    public let extractionSchemaVersion: String

    /// Rebuildable lexical/vector input for fact-first recall. This is a
    /// retrieval projection, never an assertion shown to a caller.
    public let searchProjection: String
    public let searchProjectionVersion: String

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
    /// time per `the packed provenance layout`. Held verbatim so a
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
        addedBy: String = "",
        foreignSourceKey: String = "",
        foreignRecordID: String = "",
        evidenceQuote: String = "",
        evidenceStart: Int = -1,
        evidenceEnd: Int = -1,
        evidenceStartUTF8Byte: Int = -1,
        evidenceEndUTF8Byte: Int = -1,
        sourceDigest: String = "",
        extractorProviderID: String = "",
        extractorModelID: String = "",
        extractorModelVersion: String = "",
        extractionSchemaVersion: String = "",
        searchProjection: String = "",
        searchProjectionVersion: String = "",
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
        self.addedBy = addedBy
        self.foreignSourceKey = foreignSourceKey
        self.foreignRecordID = foreignRecordID
        self.evidenceQuote = evidenceQuote
        self.evidenceStart = evidenceStart
        self.evidenceEnd = evidenceEnd
        self.evidenceStartUTF8Byte = evidenceStartUTF8Byte
        self.evidenceEndUTF8Byte = evidenceEndUTF8Byte
        self.sourceDigest = sourceDigest
        self.extractorProviderID = extractorProviderID
        self.extractorModelID = extractorModelID
        self.extractorModelVersion = extractorModelVersion
        self.extractionSchemaVersion = extractionSchemaVersion
        self.searchProjection = searchProjection
        self.searchProjectionVersion = searchProjectionVersion
        self.adjectiveBitmap = adjectiveBitmap
        self.operationalBitmap = operationalBitmap
        self.provenanceBitmap = provenanceBitmap
        self.filedAt = filedAt
    }
}

// MARK: - Codable compatibility

public extension KGFact {
    private enum CodingKeys: String, CodingKey {
        case id, subject, predicate, object, sourceDrawerID, addedBy
        case foreignSourceKey, foreignRecordID
        case evidenceQuote, evidenceStart, evidenceEnd
        case evidenceStartUTF8Byte, evidenceEndUTF8Byte, sourceDigest
        case extractorProviderID, extractorModelID, extractorModelVersion
        case extractionSchemaVersion, searchProjection, searchProjectionVersion
        case adjectiveBitmap, operationalBitmap, provenanceBitmap, filedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            subject: try values.decode(String.self, forKey: .subject),
            predicate: try values.decode(String.self, forKey: .predicate),
            object: try values.decode(String.self, forKey: .object),
            sourceDrawerID: try values.decode(String.self, forKey: .sourceDrawerID),
            addedBy: try values.decodeIfPresent(String.self, forKey: .addedBy) ?? "",
            foreignSourceKey: try values.decodeIfPresent(String.self, forKey: .foreignSourceKey) ?? "",
            foreignRecordID: try values.decodeIfPresent(String.self, forKey: .foreignRecordID) ?? "",
            evidenceQuote: try values.decodeIfPresent(String.self, forKey: .evidenceQuote) ?? "",
            evidenceStart: try values.decodeIfPresent(Int.self, forKey: .evidenceStart) ?? -1,
            evidenceEnd: try values.decodeIfPresent(Int.self, forKey: .evidenceEnd) ?? -1,
            evidenceStartUTF8Byte: try values.decodeIfPresent(Int.self, forKey: .evidenceStartUTF8Byte) ?? -1,
            evidenceEndUTF8Byte: try values.decodeIfPresent(Int.self, forKey: .evidenceEndUTF8Byte) ?? -1,
            sourceDigest: try values.decodeIfPresent(String.self, forKey: .sourceDigest) ?? "",
            extractorProviderID: try values.decodeIfPresent(String.self, forKey: .extractorProviderID) ?? "",
            extractorModelID: try values.decodeIfPresent(String.self, forKey: .extractorModelID) ?? "",
            extractorModelVersion: try values.decodeIfPresent(String.self, forKey: .extractorModelVersion) ?? "",
            extractionSchemaVersion: try values.decodeIfPresent(String.self, forKey: .extractionSchemaVersion) ?? "",
            searchProjection: try values.decodeIfPresent(String.self, forKey: .searchProjection) ?? "",
            searchProjectionVersion: try values.decodeIfPresent(String.self, forKey: .searchProjectionVersion) ?? "",
            adjectiveBitmap: try values.decodeIfPresent(Int64.self, forKey: .adjectiveBitmap) ?? 0,
            operationalBitmap: try values.decodeIfPresent(Int64.self, forKey: .operationalBitmap) ?? 0,
            provenanceBitmap: try values.decodeIfPresent(Int64.self, forKey: .provenanceBitmap) ?? 0,
            filedAt: try values.decode(Date.self, forKey: .filedAt))
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(subject, forKey: .subject)
        try values.encode(predicate, forKey: .predicate)
        try values.encode(object, forKey: .object)
        try values.encode(sourceDrawerID, forKey: .sourceDrawerID)
        try values.encode(addedBy, forKey: .addedBy)
        try values.encode(foreignSourceKey, forKey: .foreignSourceKey)
        try values.encode(foreignRecordID, forKey: .foreignRecordID)
        try values.encode(evidenceQuote, forKey: .evidenceQuote)
        try values.encode(evidenceStart, forKey: .evidenceStart)
        try values.encode(evidenceEnd, forKey: .evidenceEnd)
        try values.encode(evidenceStartUTF8Byte, forKey: .evidenceStartUTF8Byte)
        try values.encode(evidenceEndUTF8Byte, forKey: .evidenceEndUTF8Byte)
        try values.encode(sourceDigest, forKey: .sourceDigest)
        try values.encode(extractorProviderID, forKey: .extractorProviderID)
        try values.encode(extractorModelID, forKey: .extractorModelID)
        try values.encode(extractorModelVersion, forKey: .extractorModelVersion)
        try values.encode(extractionSchemaVersion, forKey: .extractionSchemaVersion)
        try values.encode(searchProjection, forKey: .searchProjection)
        try values.encode(searchProjectionVersion, forKey: .searchProjectionVersion)
        try values.encode(adjectiveBitmap, forKey: .adjectiveBitmap)
        try values.encode(operationalBitmap, forKey: .operationalBitmap)
        try values.encode(provenanceBitmap, forKey: .provenanceBitmap)
        try values.encode(filedAt, forKey: .filedAt)
    }
}

// MARK: - Adjective accessor (mirrors Drawer pattern)

public extension KGFact {

    /// Decode bits 18–23 of `adjectiveBitmap` as a `Trust` (6-bit field,
    /// cookbook §2.3 / §5.5 — shared with Drawer). Returns
    /// `.verbatim` for unrecognised raw values — the neutral baseline
    /// matching `Drawer.trust` in `Adjectives.swift`. The four-axis
    /// adjective bitmap is shared with `Drawer`; `KGFact` exposes all
    /// four axes (`state`, `adjectiveSensitivity`, `exportability`,
    /// `trust`) so a fact can be filtered by the same retrieval-layer
    /// predicates as its source drawer. Encoding and fail-closed
    /// defaults match the `Drawer` accessors in `Adjectives.swift`.
    var trust: Trust {
        // Cookbook §2.3: trust at bits 18–23.
        Trust(rawValue: Int(BitField.extractField(adjectiveBitmap, shift: 18, width: 6))) ?? .verbatim
    }

    /// Decode bits 0–5 of `adjectiveBitmap` as a `State`. Returns
    /// `.active` for unrecognised raw values so retrieval filters that
    /// look for current beliefs fail closed (an unknown row surfaces for
    /// review rather than silently disappearing). Cookbook §2.3 6-bit
    /// field. Mirrors `Drawer.state` and Rust `KGFact::state`.
    var state: State {
        // Cookbook §2.3: state at bits 0–5.
        State(rawValue: Int(BitField.extractField(adjectiveBitmap, shift: 0, width: 6))) ?? .active
    }

    /// Decode bits 6–11 of `adjectiveBitmap` as an `AdjectiveSensitivity`.
    /// Returns `.normal` for unrecognised raw values, matching the
    /// estate-level default access posture. Named `adjectiveSensitivity`
    /// (not `sensitivity`) to match the `Drawer` convention and stay
    /// unambiguous about which bitmap axis is read. Cookbook §2.3 6-bit
    /// field. Mirrors `Drawer.adjectiveSensitivity` and Rust
    /// `KGFact::adjective_sensitivity`.
    var adjectiveSensitivity: AdjectiveSensitivity {
        // Cookbook §2.3: sensitivity at bits 6–11.
        AdjectiveSensitivity(rawValue: Int(BitField.extractField(adjectiveBitmap, shift: 6, width: 6))) ?? .normal
    }

    /// Decode bits 12–17 of `adjectiveBitmap` as an `AdjectiveExportability`.
    /// Returns `.private_` for unrecognised raw values — non-exportable is
    /// the safe fallback for an unknown encoding. Cookbook §2.3 6-bit field.
    /// Mirrors `Drawer.exportability` and Rust `KGFact::exportability`.
    var exportability: AdjectiveExportability {
        // Cookbook §2.3: exportability at bits 12–17.
        AdjectiveExportability(rawValue: Int(BitField.extractField(adjectiveBitmap, shift: 12, width: 6))) ?? .private_
    }
}
