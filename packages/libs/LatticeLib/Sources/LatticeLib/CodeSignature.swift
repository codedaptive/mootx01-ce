// CodeSignature.swift
//
// FDC §7.1 signature assembly (build-time): merge a code's three source bags
// (label / title / article) with source weights, then accumulate every
// ancestor's terms so the most specific code carries the full weight of its
// lineage. The SimHash fingerprint (§5.1) is computed in a later pass once the
// global concept vocabulary is known. Pure and deterministic.

import Foundation

/// Pinned source-type weights (cookbook constants): the FDC label is most
/// precise, the article title authoritative, the article body broad.
public struct SourceWeights: Sendable, Equatable {
    public let label: Int
    public let title: Int
    public let article: Int
    public init(label: Int = 3, title: Int = 2, article: Int = 1) {
        self.label = label; self.title = title; self.article = article
    }
}

/// A code's assembled signature: the weighted, ancestor-accumulated term bag.
/// `fingerprint` is filled in the later SimHash pass (nil until then).
public struct CodeSignature: Sendable, Codable, Equatable {
    public let code: String
    public let terms: [String: Int]      // conceptID/surface -> accumulated weight
    public var fingerprint: String?      // hex 256-bit, set in the SimHash pass
    public init(code: String, terms: [String: Int], fingerprint: String? = nil) {
        self.code = code; self.terms = terms; self.fingerprint = fingerprint
    }
}

public enum SignatureAssembler {

    /// §7.1 step 3 — merge a code's three source bags with source weights.
    public static func merge(
        label: ConceptBag, title: ConceptBag, article: ConceptBag,
        weights: SourceWeights = .init()
    ) -> [String: Int] {
        var sig: [String: Int] = [:]
        for (k, w) in label   { sig[k, default: 0] += w * weights.label }
        for (k, w) in title   { sig[k, default: 0] += w * weights.title }
        for (k, w) in article { sig[k, default: 0] += w * weights.article }
        return sig
    }

    /// §7.1 step 4 — accumulate ancestors. Each code's final signature is its
    /// own merged terms plus every ancestor's own merged terms (each ancestor
    /// contributes once; the result is order-independent). `ancestorsOf`
    /// returns a code's ancestor codes (all prefixes); missing ancestors are
    /// skipped.
    public static func accumulateAncestors(
        ownTerms: [String: [String: Int]],
        ancestorsOf: (String) -> [String]
    ) -> [String: CodeSignature] {
        var out: [String: CodeSignature] = [:]
        for (code, own) in ownTerms {
            var terms = own
            for ancestor in ancestorsOf(code) {
                guard let aTerms = ownTerms[ancestor] else { continue }
                for (k, w) in aTerms { terms[k, default: 0] += w }
            }
            out[code] = CodeSignature(code: code, terms: terms)
        }
        return out
    }
}
