// EideticLib.swift
//
// The deterministic text-to-anchor utility. Pass a term to
// EideticLib.lookup; get back an Anchor with an FDC code, the
// dominant concept's Wikidata Q-ID, a confidence, and the FDC
// signatures version that produced the answer.
//
// lookup grounds a term through LatticeLib's FDC encoder
// (FDC.encodeAnchor): the text is canonicalized to a concept bag
// and matched against the pinned FDC signatures. Network is never
// consulted; determinism is guaranteed against the pinned FDC
// artifacts bundled in LatticeLib.

import Foundation
import LatticeLib

/// The EideticLib module surface. Stateless from the caller's
/// perspective; internally caches the parsed reference data
/// on first lookup so subsequent calls don't re-parse JSON.
public enum EideticLib {

    /// The module version.
    public static let version: String = "0.1.0"

    // Reference data is owned and cached by LatticeLib's FDC runtime
    // (the pinned lexicon, frame, and signatures, parsed once per
    // process). EideticLib holds no classification data of its own —
    // lookup delegates to FDC.encodeAnchor.

    /// The bundled manifest for the MDCC default scheme. Derived from
    /// LatticeLib's canon version rather than loaded from a JSON stub:
    /// the manifest is scheme metadata, and the real canon lives in
    /// LatticeLib.
    private static let derivedLatticeManifest = LatticeSchemeManifest(
        canonVersion: LatticeLib.canonVersion,
        dataVersion: version,
        // MDCC is original work; the scheme itself is unlicensed. The
        // bundled leaves resolve against the CC0 MDCC canon. Foreign-
        // licensed leaves are not part of this default scheme.
        licenseNote: "MDCC scheme: original work, unlicensed; "
            + "leaves resolve against the CC0 MDCC canon.",
        offlineResolvable: true
    )

    /// The default classification scheme. Always `.mdcc`. MDCC
    /// ships complete with the bundle and resolves offline.
    /// Foreign schemes require activation consent — see
    /// `activationConsent`.
    public static let defaultScheme: ClassificationScheme = .mdcc

    /// The manifest for the MDCC default scheme. Derived from the
    /// bundled LatticeLib canon version; always present.
    public static func defaultSchemeManifest() -> LatticeSchemeManifest? {
        derivedLatticeManifest
    }

    /// Classifies a string against the MDCC code grammar without
    /// consulting any canon. Returns whether the code is malformed,
    /// well-formed-and-known (callers resolve the entry through
    /// their bound LatticeLib canon), or well-formed-but-pending —
    /// the valid-but-unknown state from the launch plan. Pending
    /// codes round-trip intact and are queryable as pending until
    /// the next canon pull resolves them.
    ///
    /// The `knownCodes` set lets a caller carry the known/pending
    /// decision through EideticLib without EideticLib having to know
    /// the full canon at this call site.
    public static func classifyLatticeCode(
        _ code: String,
        knownCodes: Set<String> = []
    ) -> LatticeCodeState {
        guard LatticeCodeGrammar.isWellFormed(code) else {
            return .malformed(code)
        }
        if knownCodes.contains(code) {
            return .known(code)
        }
        return .pending(code)
    }

    /// Looks up the lattice anchor for a term. Deterministic
    /// against LatticeLib's pinned FDC artifacts.
    ///
    /// Delegates to `FDC.encodeAnchor`: the term is canonicalized to a
    /// concept bag and matched to an FDC code, and the bag's dominant
    /// Wikidata Q-ID is carried as the anchor concept. No network.
    public static func lookup(_ term: String) -> Anchor {
        guard FDC.isAvailable else {
            return Anchor.notImplemented
        }

        let (code, qid) = FDC.encodeAnchor(term)
        guard let code else {
            // UNRESOLVED: empty anchor, never a fallback code.
            return Anchor(
                code: "",
                wikidataQID: nil,
                confidence: 0,
                dataVersion: FDC.dataVersion
            )
        }

        // FDC carries no calibrated confidence score; a resolved code
        // is reported at `medium` (32 in the provenance confidence value
        // set: 0=null, 16=low, 32=medium, 48=high, 56=verified).
        return Anchor(
            code: code,
            wikidataQID: qid,
            confidence: 32,
            dataVersion: FDC.dataVersion
        )
    }

    /// The activation consent surface for foreign-data schemes.
    /// Foreign sources cannot be fetched until consent has been
    /// recorded for them. The gate is logged and unskippable: every
    /// acceptance is a `ConsentRecord` in the ledger, and the
    /// pipeline refuses to run without a matching record.
    public static let activationConsent: ActivationConsent = ActivationConsent()
}

/// The result of a EideticLib lookup. Pure data, byte-identical
/// shape to the Rust port's `Anchor` struct.
public struct Anchor: Equatable, Sendable, Codable {

    /// The FDC code matched for the term. Empty string means the
    /// term was UNRESOLVED (no signature overlap) — never a guess.
    public let code: String

    /// The dominant concept's Wikidata Q-ID (the highest-weighted
    /// Q-ID in the term's concept bag), or nil if the bag carried
    /// no Q-ID concept.
    public let wikidataQID: String?

    /// Confidence packed into the substrate provenance
    /// confidence field's value set: 0=null, 16=low, 32=medium,
    /// 48=high, 56=verified.
    public let confidence: UInt8

    /// The FDC signatures version that produced this answer. Lets
    /// callers record provenance per substrate invariant I-4.
    public let dataVersion: String

    public init(
        code: String,
        wikidataQID: String?,
        confidence: UInt8,
        dataVersion: String
    ) {
        self.code = code
        self.wikidataQID = wikidataQID
        self.confidence = confidence
        self.dataVersion = dataVersion
    }

    /// The sentinel anchor returned only when the bundled canon
    /// fails to load — a build/configuration error, not a runtime
    /// condition.
    public static let notImplemented = Anchor(
        code: "",
        wikidataQID: nil,
        confidence: 0,
        dataVersion: "0.1.0-stub"
    )
}
