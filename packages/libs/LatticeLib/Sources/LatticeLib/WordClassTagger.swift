// WordClassTagger.swift
//
// The public Step 1 entry point: LatticeLib.wordClass(_:) classifies a
// single token as .noun, .verb, or .other (cookbook §2.1, canonical
// §3 Step 1). Implemented as an extension on the existing EideticLib
// enum so EideticLib.swift stays untouched (mission Tier 3 invariant).
//
// Two tiers, per the encoder contract:
//   1. Fast path — static-table membership (constant time, no tagger).
//   2. Fallback — platform tagger for novel tokens. On Apple this is
//      NLTagger with .lexicalClass; elsewhere the deterministic
//      HMM/Viterbi tagger in HMMTagger (integer-scored, byte-identical
//      Swift↔Rust). The platform boundary is contract-bearing
//      (cookbook §2.2): table-resident tokens are bit-identical across
//      ALL platforms; novel-token tagging is platform-specific (Apple's
//      NLTagger and the HMM are different engines and need not agree),
//      but the non-Apple HMM path is itself bit-identical across ports.
//
// Step 1 operates on the raw lowercased token. It does NOT lemmatize:
// lemmatization is Step 2 (cookbook §2.1 step 1 vs §3.2).

import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public extension LatticeLib {

    /// Classifies a single token under FDC encoder Step 1.
    ///
    /// Lowercases the token, then takes the fast path: a token present
    /// in the LIVE word-class table snapshot resolves in constant time
    /// with no tagger invoked (cookbook §2.1). The verb set is checked
    /// before the noun set, so a token listed under both resolves to
    /// `.verb` (mission Part 2). A token absent from the table falls
    /// to the platform tagger; an empty token is `.other`.
    ///
    /// Reads the table through `WordClassTableCache` (the process-wide
    /// LIVE-SWAPPABLE holder, cookbook §1.3/§2.2): a token merged into the
    /// writable artifact by `PoolReducer.reduce` and swapped in via
    /// `WordClassTableCache.swap`/`reloadFromPrecedence` is classified
    /// from the table on the VERY NEXT call — in-session, no process
    /// restart.
    ///
    /// Deterministic given (input, table-version): for a fixed table
    /// version the same token yields the same `WordClass` on every
    /// platform for any table-resident token. A live swap advances the
    /// table version (`WordClassTableCache.version`); within one version
    /// the classification is stable. Novel-token results depend on the
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
    /// version, the platform string, and the tagger version.
    ///
    /// Wired with the real local-file submitter (NovelPoolSubmitter.makeDefault)
    /// so drained batches are written as JSON files to the configured pool
    /// directory (LATTICE_POOL_DIR env var, or the platform Application Support
    /// default). The no-op submitter may only be used in tests or in an
    /// embedded-host where the pool directory is explicitly unwanted.
    internal static let sharedNovelCache = NovelTokenCache(
        tableVersion: WordClassTableCache.table?.tableVersion ?? "",
        platform: currentPlatform,
        taggerVersion: currentTaggerVersion,
        submitter: NovelPoolSubmitter.makeDefault()
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
    /// deterministic HMM/Viterbi artifact version.
    internal static var currentTaggerVersion: String {
        #if canImport(NaturalLanguage)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        // The non-Apple HMM/Viterbi model version. Mirrors the Rust port's
        // HMM_VITERBI_VERSION. Bump when the HMMTagger model tables change.
        return "hmm-viterbi-1"
        #endif
    }

    /// Tags a novel (non-table) token via the platform tagger and
    /// records the result into the shared pool cache (cookbook §2.2).
    ///
    /// Apple: `NLTagger` with `.lexicalClass`, gated by
    /// `taggerEnabled`. Non-Apple: the deterministic HMM/Viterbi tagger
    /// (`HMMTagger.tag`) — an integer-scored 3-state HMM that is
    /// byte-identical across the Swift and Rust ports (cookbook §2.2).
    /// The two engines (Apple NLTagger vs the HMM) are not expected to
    /// agree with each other; the HMM's guarantee is cross-platform
    /// self-consistency of the non-Apple path.
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

    // MARK: - Estate-tagger-choice overloads (Layer-2a)

    /// Classifies a single token under FDC encoder Step 1, dispatching the
    /// novel-token fallback path according to the estate's configured
    /// `NovelTokenTaggerChoice`.
    ///
    /// Identical fast-path logic to the parameterless `wordClass(_:)`: the
    /// static word-class table is checked first (verb before noun), and only
    /// tokens absent from the table reach the tagger. The `tagger` parameter
    /// controls ONLY the novel-token fallback, not the table lookup.
    ///
    /// Use this overload when you have a concrete estate tagger choice to
    /// thread through from `EstateConfiguration.novelTokenTagger` (bridged to
    /// the LatticeLib `NovelTokenTaggerChoice` by the consumer). Use the
    /// parameterless overload when no estate context is available (e.g.
    /// build-time editorial tooling or legacy call sites).
    ///
    /// - Parameters:
    ///   - token: a single raw token (not a phrase).
    ///   - tagger: which novel-token tagger engine to invoke on a table miss.
    /// - Returns: the token's `WordClass`.
    static func wordClass(_ token: String, tagger: NovelTokenTaggerChoice) -> WordClass {
        let lowered = token.lowercased()

        if lowered.isEmpty {
            return .other
        }

        if WordClassTableCache.verbSet.contains(lowered) {
            return .verb
        }
        if WordClassTableCache.nounSet.contains(lowered) {
            return .noun
        }

        return tagNovelToken(lowered, tagger: tagger)
    }

    /// Tags a novel (non-table) token using the specified tagger choice and
    /// records the result into the shared pool cache.
    ///
    /// Dispatch rules:
    ///   - `.hmm` → always uses the deterministic HMM/Viterbi tagger,
    ///     regardless of platform. This is the cross-port conformance path.
    ///   - `.nlTagger` on Apple → uses `NLTagger` with `.lexicalClass`,
    ///     gated by `taggerEnabled` (min_os_version guard). Falls through
    ///     to `.other` when the gate fails (fail-closed, same as the
    ///     legacy Apple path).
    ///   - `.nlTagger` on non-Apple → NaturalLanguage is unavailable;
    ///     the HMM is used instead. This case should not be reachable in
    ///     production (PersistenceKit rejects `.nlTagger` on Rust), but
    ///     the Swift non-Apple build must still compile and behave correctly.
    ///
    /// Internal so tests can exercise it directly under `@testable import`.
    internal static func tagNovelToken(_ lowered: String, tagger: NovelTokenTaggerChoice) -> WordClass {
        let tagged: WordClass
        switch tagger {
        case .hmm:
            // Deterministic HMM/Viterbi — the cross-port baseline.
            tagged = hmmViterbiTag(lowered)
        case .nlTagger:
            #if canImport(NaturalLanguage)
            // Apple NLTagger path, gated by the table's pinned min_os_version.
            let minOS = WordClassTableCache.table?.minOSVersion ?? ""
            guard taggerEnabled(
                osVersion: ProcessInfo.processInfo.operatingSystemVersion,
                minOSVersion: minOS
            ) else {
                // OS below the pinned NLTagger version: return .other without
                // recording (same fail-closed behaviour as the legacy path).
                return .other
            }
            tagged = appleLexicalClass(lowered)
            #else
            // NLTagger requested but NaturalLanguage is absent (non-Apple build).
            // Fall back to HMM: this call site should not be reachable in production
            // (Rust rejects NlTagger at configuration time), but the build must
            // be correct on all platforms.
            tagged = hmmViterbiTag(lowered)
            #endif
        }

        // Fire-and-forget accumulation toward the pool submission.
        sharedNovelCache.record(token: lowered, wordClass: tagged)
        return tagged
    }

    /// HMM/Viterbi tagger — always available on all platforms.
    ///
    /// Delegates to `HMMTagger.tag`: a deterministic 3-state HMM
    /// (noun/verb/other) decoded with integer Viterbi over a small
    /// morphological observation alphabet, with hand-specified integer
    /// log-weight priors (cookbook §2.2). The model tables are mirrored
    /// verbatim in the Rust port, so the result is byte-identical
    /// Swift↔Rust; it is NOT required to match Apple's NLTagger output.
    ///
    /// Available on ALL platforms (not gated by `canImport(NaturalLanguage)`):
    /// it is the cross-port baseline, the default tagger for `.hmm` estates,
    /// and the non-Apple fallback used by the legacy `tagNovelToken` path.
    /// The estate-choice overload `tagNovelToken(_:tagger:)` dispatches here
    /// for `.hmm` regardless of platform.
    private static func hmmViterbiTag(_ lowered: String) -> WordClass {
        return HMMTagger.tag(lowered)
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
    #endif
}
