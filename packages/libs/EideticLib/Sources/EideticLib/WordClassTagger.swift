// WordClassTagger.swift
//
// The public Step 1 entry point: EideticLib.wordClass(_:) classifies a
// single token as .noun, .verb, or .other (cookbook §2.1, canonical
// §3 Step 1). Implemented as an extension on the existing EideticLib
// enum so EideticLib.swift stays untouched (mission Tier 3 invariant).
//
// Two tiers, per the encoder contract:
//   1. Fast path — static-table membership (constant time, no tagger).
//   2. Fallback — platform tagger for novel tokens. On Apple this is
//      NLTagger with .lexicalClass; elsewhere the Penn-Treebank
//      HMM/Viterbi tagger. The platform boundary is contract-bearing
//      (cookbook §2.2): table-resident tokens are bit-identical across
//      platforms; novel-token tagging is platform-specific.
//
// Step 1 operates on the raw lowercased token. It does NOT lemmatize:
// lemmatization is Step 2 (cookbook §2.1 step 1 vs §3.2).

import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public extension EideticLib {

    /// Classifies a single token under FDC encoder Step 1.
    ///
    /// Lowercases the token, then takes the fast path: a token present
    /// in the bundled word-class table resolves in constant time with
    /// no tagger invoked (cookbook §2.1). The verb set is checked
    /// before the noun set, so a token listed under both resolves to
    /// `.verb` (mission Part 2). A token absent from the table falls
    /// to the platform tagger; an empty token is `.other`.
    ///
    /// Deterministic with respect to the bundled table: the same token
    /// yields the same `WordClass` on every platform for any
    /// table-resident token. Novel-token results depend on the
    /// platform tagger and are not cross-platform guaranteed
    /// (cookbook §2.2, §8).
    ///
    /// - Parameter token: a single raw token (not a phrase). Callers
    ///   with a phrase tokenize first via `Tokenizer`.
    /// - Returns: the token's `WordClass`.
    static func wordClass(_ token: String) -> WordClass {
        let lowered = token.lowercased()

        // An empty (or whitespace-only lowercased) token is never a
        // noun or verb; short-circuit to .other so the tagger is not
        // invoked on empty input.
        if lowered.isEmpty {
            return .other
        }

        // Fast path: static-table membership. Verb set first, then
        // noun set (cookbook §2.1, mission Part 2 ordering).
        if WordClassTableCache.verbSet.contains(lowered) {
            return .verb
        }
        if WordClassTableCache.nounSet.contains(lowered) {
            return .noun
        }

        // Novel token: fall to the platform tagger.
        return tagNovelToken(lowered)
    }

    /// Whether the platform tagger may run, given the running OS
    /// version and the table's pinned `min_os_version` (cookbook
    /// §1.3, §2.2). The static table is seeded from a specific
    /// NLTagger version; a build/runtime on an OS below that version
    /// must use the table only and return `.other` for novel tokens
    /// rather than invoke an older, differently-behaving tagger.
    ///
    /// Pure and total over its inputs so the gate is unit-testable
    /// without an actual old OS. A `minOSVersion` that does not parse
    /// as `major[.minor]` disables the tagger (fail closed).
    static func taggerEnabled(
        osVersion: OperatingSystemVersion,
        minOSVersion: String
    ) -> Bool {
        let parts = minOSVersion
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) }
        guard let first = parts.first, let major = first else {
            // Unparseable min version: fail closed, table only.
            return false
        }
        let minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        if osVersion.majorVersion != major {
            return osVersion.majorVersion > major
        }
        return osVersion.minorVersion >= minor
    }

    /// The process-wide novel-token accumulation cache wired into the
    /// fallback path (cookbook §2.2). Stamped with the bundled table
    /// version, the platform string, and the tagger version. Uses the
    /// default no-op submitter until the pool endpoint is wired.
    internal static let sharedNovelCache = NovelTokenCache(
        tableVersion: WordClassTableCache.table?.tableVersion ?? "",
        platform: currentPlatform,
        taggerVersion: currentTaggerVersion
    )

    /// The platform string for the pool wire format (cookbook §2.3):
    /// `"apple"` where `NaturalLanguage` is available, else `"other"`.
    internal static var currentPlatform: String {
        #if canImport(NaturalLanguage)
        return "apple"
        #else
        return "other"
        #endif
    }

    /// The tagger version string for the pool wire format (cookbook
    /// §2.3): the running NLTagger OS version on Apple, else the
    /// HMM/Viterbi artifact version.
    internal static var currentTaggerVersion: String {
        #if canImport(NaturalLanguage)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        // Mirrors the Rust port's HMM_VITERBI_VERSION.
        return "hmm-viterbi-stub-0"
        #endif
    }

    /// Tags a novel (non-table) token via the platform tagger and
    /// records the result into the shared pool cache (cookbook §2.2).
    ///
    /// Apple: `NLTagger` with `.lexicalClass`, gated by
    /// `taggerEnabled`. Non-Apple: the Penn-Treebank HMM/Viterbi
    /// tagger. Until the compiled HMM artifact is bundled (cookbook
    /// §2.2 / Known Ambiguities), the non-Apple path is a deterministic
    /// stub that defaults to `.other`.
    ///
    /// When the min_os_version gate disables the tagger, no tagging
    /// occurs and nothing is recorded — the table-only path returns
    /// `.other` without polluting the pool with an untagged token.
    ///
    /// Internal so tests can exercise it directly under
    /// `@testable import`.
    internal static func tagNovelToken(_ lowered: String) -> WordClass {
        #if canImport(NaturalLanguage)
        // min_os_version gate: below the table's pinned NLTagger
        // version, use the table only (return .other) rather than an
        // older tagger. No tagging means no pool record.
        let minOS = WordClassTableCache.table?.minOSVersion ?? ""
        guard taggerEnabled(
            osVersion: ProcessInfo.processInfo.operatingSystemVersion,
            minOSVersion: minOS
        ) else {
            return .other
        }
        let tagged = appleLexicalClass(lowered)
        #else
        let tagged = hmmViterbiTag(lowered)
        #endif

        // Fire-and-forget accumulation toward the 50-entry pool
        // submission. Does not affect the returned WordClass.
        sharedNovelCache.record(token: lowered, wordClass: tagged)
        return tagged
    }

    #if canImport(NaturalLanguage)
    /// Apple lexical-class tagging for a single word via `NLTagger`.
    /// Maps `.noun`→`.noun`, `.verb`→`.verb`, everything else
    /// (preposition, determiner, adjective, punctuation, …)→`.other`.
    private static func appleLexicalClass(_ token: String) -> WordClass {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = token
        let (tag, _) = tagger.tag(
            at: token.startIndex,
            unit: .word,
            scheme: .lexicalClass
        )
        switch tag {
        case .some(.noun):
            return .noun
        case .some(.verb):
            return .verb
        default:
            return .other
        }
    }
    #else
    /// Non-Apple Penn-Treebank HMM/Viterbi fallback.
    ///
    /// Known Ambiguities resolution: the compiled HMM/Viterbi artifact
    /// (cookbook §2.2) is not yet bundled. This deterministic stub
    /// keeps the platform-dispatch seam intact and defaults every
    /// novel token to `.other`; the fast-path table covers the vast
    /// majority of tokens and the conformance vectors exercise
    /// table-resident tokens. Producing the real artifact is a
    /// documented follow-up.
    private static func hmmViterbiTag(_ lowered: String) -> WordClass {
        return .other
    }
    #endif
}
