// EideticLib.swift
//
// The deterministic text-to-anchor utility. Pass a term to
// EideticLib.lookup; get back an Anchor with an MDCC code, the
// canon entry's Wikidata Q-ID, a confidence, and the canon
// version that produced the answer.
//
// lookup grounds a term against the default MDCC scheme by
// resolving it through the bundled MDCC canon (from LatticeKit).
// Network is never consulted. Determinism is guaranteed against
// the pinned canon version recorded in LatticeKit's bundled canon.

import Foundation
import LatticeKit

/// The EideticLib module surface. Stateless from the caller's
/// perspective; internally caches the parsed reference data
/// on first lookup so subsequent calls don't re-parse JSON.
public enum EideticLib {

    /// The module version.
    public static let version: String = "0.1.0"

    // Cached reference data. Parsed once on first access and
    // reused for the lifetime of the process. The cache
    // doesn't expire because the data is shipped as a build-
    // time constant; if it could change, it wouldn't be safe
    // to cache like this.
    //
    // The MDCC canon (CC0/public-domain) is the classification
    // source. The Wikidata subset (CC0) confirms the canon
    // entry's Q-ID anchor. No CC-BY-SA data is cached or bundled.
    private static let cachedCanon: LatticeCanon? = LatticeKit.bundledCanon()
    private static let cachedSubset: WikidataSubset? = WikidataSubset.loadBundled()

    /// The bundled manifest for the MDCC default scheme. Derived from
    /// LatticeKit's canon version rather than loaded from a JSON stub:
    /// the manifest is scheme metadata, and the real canon lives in
    /// LatticeKit.
    private static let derivedMDCCManifest = LatticeSchemeManifest(
        canonVersion: LatticeKit.canonVersion,
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
    /// bundled LatticeKit canon version; always present.
    public static func defaultSchemeManifest() -> LatticeSchemeManifest? {
        derivedMDCCManifest
    }

    /// Classifies a string against the MDCC code grammar without
    /// consulting any canon. Returns whether the code is malformed,
    /// well-formed-and-known (callers resolve the entry through
    /// their bound LatticeKit canon), or well-formed-but-pending —
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
    /// against the bundled MDCC canon.
    ///
    /// Composes the pipeline: tokenize, normalize, stem, resolve
    /// against the MDCC canon, then carry the resolved canon
    /// entry's CC0 Wikidata Q-ID (confirmed against the bundled
    /// CC0 subset).
    public static func lookup(_ term: String) -> Anchor {
        guard let canon = cachedCanon else {
            return Anchor.notImplemented
        }

        let tokens = Tokenizer.tokenize(term)
        let normalized = tokens.map(Normalizer.normalize)
        let stemmed = normalized.map(Stemmer.stem)

        guard let resolution = LatticeResolver.resolve(
            normalized: normalized,
            stemmed: stemmed,
            canon: canon
        ) else {
            // No canon match: empty anchor, never a fallback code.
            return Anchor(
                mdccCode: "",
                wikidataQID: nil,
                confidence: 0,
                dataVersion: canon.canonVersion
            )
        }

        // The Q-ID step: the resolved canon entry's source identity
        // is its CC0 Wikidata Q-ID. WikidataResolver confirms it
        // against the bundled CC0 subset before surfacing it.
        var qid: String? = resolution.sourceIdentity
        if let subset = cachedSubset,
           let entry = canon.entry(for: resolution.code) {
            qid = WikidataResolver.resolve(entry: entry, subset: subset)?.qid
        }

        return Anchor(
            mdccCode: resolution.code,
            wikidataQID: qid,
            confidence: resolution.confidence,
            dataVersion: canon.canonVersion
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

    /// The MDCC code resolved from the canon at the best-matching
    /// entry. Empty string means no canon entry matched the term.
    public let mdccCode: String

    /// The Wikidata Q-ID for the primary concept (the resolved
    /// canon entry's source identity), or nil if no entry matched.
    public let wikidataQID: String?

    /// Confidence packed into the substrate provenance
    /// confidence field's value set: 0=null, 16=low, 32=medium,
    /// 48=high, 56=verified.
    public let confidence: UInt8

    /// The MDCC canon version that produced this answer. Lets
    /// callers record provenance per substrate invariant I-4.
    public let dataVersion: String

    public init(
        mdccCode: String,
        wikidataQID: String?,
        confidence: UInt8,
        dataVersion: String
    ) {
        self.mdccCode = mdccCode
        self.wikidataQID = wikidataQID
        self.confidence = confidence
        self.dataVersion = dataVersion
    }

    /// The sentinel anchor returned only when the bundled canon
    /// fails to load — a build/configuration error, not a runtime
    /// condition.
    public static let notImplemented = Anchor(
        mdccCode: "",
        wikidataQID: nil,
        confidence: 0,
        dataVersion: "0.1.0-stub"
    )
}
