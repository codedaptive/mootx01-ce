// HMMFeatureExtractor.swift
//
// Production DistillationPipeline.FeatureExtractor backed by the deterministic
// HMM/Viterbi tagger from LatticeLib.
//
// Design home: Distillation.swift comment §1 ("Provide the LatticeLib HMM tagger
// as the production FeatureExtractor"). Implemented here as a separate file so the
// seam is visible and testable in isolation.
//
// Extraction rules (ALL deterministic — no randomness, no wall-clock):
//
//   ENT (entity):    noun-tagged tokens from LatticeLib.wordClass(_:tagger:.hmm,recordNovel:false)
//   REL (relation):  verb-tagged tokens
//   NUM (numerical): tokens where every character is an ASCII digit
//   TMP (temporal):  4-digit year tokens (YYYY) — the UAX #29 tokenizer
//                    splits "YYYY-MM-DD" on hyphens, so only the year component
//                    reaches this check; detected by a pure character-class scan
//
// Rules are IDENTICAL in the Rust port (hmm_feature_extractor.rs). Both ports
// use the HMM path so results are byte-identical (LatticeLib contract: the
// non-Apple HMM/Viterbi tagger is bit-identical Swift↔Rust, cookbook §2.2).
//
// Cross-port parity:
//   - Tokenisation via Tokenizer.tokenize (UAX #29, conformance-gated).
//   - Noun/verb tagging via LatticeLib.wordClass(_:tagger:.hmm,recordNovel:false).
//     The recordNovel:false flag suppresses pool accumulation so memory-drawer
//     content never leaks to the plaintext pool pipeline. Tag results are
//     byte-identical to the recording path and to Rust's hmm_tag (parity fix).
//   - docFrequency is 0 on every emitted feature — set by the pipeline.
//
// Layer discipline (B-1/B-2): pure function, no I/O, no state, no substrate.

import Foundation
import LatticeLib
import SubstrateML

// MARK: - Production HMM feature extractor

extension NeuronKit {

    /// Function-word stop list for distillation feature extraction. Tokens in
    /// this set are NEVER emitted as ENT/REL features: they recur across an
    /// item's sentences (so they clear the recurrence threshold) but carry no
    /// topical signal — they are scaffolding, not "the words that matter". The
    /// HMM tagger tags many of them as nouns ("the"/"to"/"by" came back .noun),
    /// so the filter is applied independently of the tag.
    ///
    /// CONFORMANCE: this exact set is mirrored byte-for-byte in the Rust port
    /// (`hmm_feature_extractor.rs` `DISTILLATION_STOPWORDS`). Keep the two in
    /// lockstep — a divergence breaks cross-port factoid parity.
    static let distillationStopwords: Set<String> = [
        // articles & determiners
        "a", "an", "the", "this", "that", "these", "those", "each", "every",
        "all", "any", "some", "no", "such", "both", "either", "neither",
        "much", "many", "more", "most", "other", "another", "same", "own",
        // prepositions
        "of", "in", "on", "at", "to", "for", "with", "by", "from", "as",
        "into", "onto", "upon", "about", "above", "below", "under", "over",
        "between", "among", "through", "during", "before", "after", "since",
        "until", "without", "within", "against", "toward", "towards", "across",
        "behind", "beyond", "near",
        // conjunctions
        "and", "or", "but", "nor", "so", "yet", "if", "then", "than",
        "because", "although", "though", "while", "whereas", "unless",
        // pronouns
        "i", "me", "my", "mine", "we", "us", "our", "ours", "you", "your",
        "yours", "he", "him", "his", "she", "her", "hers", "it", "its",
        "they", "them", "their", "theirs", "who", "whom", "whose", "which",
        "what",
        // be / have / do / modals
        "is", "am", "are", "was", "were", "be", "been", "being", "has",
        "have", "had", "having", "do", "does", "did", "doing", "will",
        "would", "shall", "should", "can", "could", "may", "might", "must",
        // common adverbs / particles
        "not", "very", "too", "also", "just", "only", "even", "still",
        "again", "ever", "never", "now", "here", "there", "when", "where",
        "why", "how", "once", "up", "down", "out", "off", "back",
    ]

    /// Production FeatureExtractor backed by the LatticeLib HMM/Viterbi tagger.
    ///
    /// Tokenises the input with `Tokenizer.tokenize`, then classifies each token
    /// via `LatticeLib.wordClass(_:tagger:.hmm, recordNovel: false)`. Feature type dispatch:
    ///
    ///   `.entity`    — noun-tagged tokens (HMM says .noun)
    ///   `.relation`  — verb-tagged tokens (HMM says .verb)
    ///   `.numerical` — tokens whose every character is an ASCII decimal digit
    ///   `.temporal`  — 4-digit year tokens (YYYY); the UAX #29 tokenizer splits
    ///                  "YYYY-MM-DD" on hyphens so only the year component is
    ///                  classified TMP (pure character-class scan, no regex, no Date())
    ///
    /// The `.hmm` tagger choice is mandatory: it guarantees bit-identical output
    /// with the Rust port (`hmm_feature_extractor.rs`). The static word-class table
    /// fast-path inside `LatticeLib.wordClass` is cross-platform and table-resident
    /// tokens resolve identically; novel tokens fall through to the HMM and are also
    /// bit-identical. Using `.nlTagger` would break cross-port parity (cookbook §2.2).
    ///
    /// `recordNovel: false` ensures memory-drawer text never reaches the pool
    /// pipeline — the extractor processes private estate content. This matches
    /// the Rust port's `hmm_tag` call, which has no pool side effect at all.
    ///
    /// `docFrequency` is 0 on every emitted feature — the pipeline computes the real
    /// value from the incidence matrix (Stage 2). Callers must not read `docFrequency`
    /// from this extractor's output before the pipeline has set it.
    public static let hmmFeatureExtractor: DistillationPipeline.FeatureExtractor = {
        content, featureType in
        // Tokenize the content string using the UAX #29 word-boundary tokeniser.
        // Empty content is a no-op (produce no features).
        let tokens = Tokenizer.tokenize(content)
        guard !tokens.isEmpty else { return [] }

        var results: [ExtractedFeature] = []

        switch featureType {

        case .entity:
            // ENT: tokens tagged .noun by the HMM tagger, minus function words.
            // The HMM path is mandatory for cross-port byte-identity.
            //
            // recordNovel: false — the distillation extractor operates over
            // memory-drawer content that is private to the estate. Recording
            // novel tokens into the pool pipeline would leak plaintext memory
            // text to disk outside the estate's encryption/audit controls.
            // The tag result is identical (byte-for-byte) whether or not
            // recording is enabled; only the pool side effect is suppressed.
            // This matches the Rust port, which calls hmm_tag directly with
            // no pool accumulation (parity gap fix, Swift-only).
            for token in tokens {
                let lower = token.lowercased()
                // Drop function words: they recur but are scaffolding, and the
                // HMM tagger mis-tags several of them ("the"/"by") as nouns.
                if distillationStopwords.contains(lower) { continue }
                let wc = LatticeLib.wordClass(lower, tagger: .hmm, recordNovel: false)
                if wc == .noun {
                    // value = Snowball stem (groups migration/migrations into one
                    // df + one fingerprint bit); display = surface form for the
                    // factoid prose. Stemmer is bit-identical Swift↔Rust.
                    results.append(ExtractedFeature(
                        type: .entity,
                        value: Stemmer.stem(lower),
                        docFrequency: 0,
                        display: lower
                    ))
                }
            }

        case .relation:
            // REL: tokens tagged .verb by the HMM tagger, minus function words.
            // recordNovel: false — same rationale as the ENT case above;
            // private memory content must not reach the pool pipeline.
            for token in tokens {
                let lower = token.lowercased()
                if distillationStopwords.contains(lower) { continue }
                let wc = LatticeLib.wordClass(lower, tagger: .hmm, recordNovel: false)
                if wc == .verb {
                    // value = stem (unifies migrate/migrates); display = surface.
                    results.append(ExtractedFeature(
                        type: .relation,
                        value: Stemmer.stem(lower),
                        docFrequency: 0,
                        display: lower
                    ))
                }
            }

        case .numerical:
            // NUM: tokens where every character is an ASCII decimal digit (0–9).
            // Pure character-class scan — no regex, no standard library numeric
            // parser (those are not deterministic across platforms for edge cases).
            for token in tokens {
                if !token.isEmpty && token.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) {
                    results.append(ExtractedFeature(
                        type: .numerical,
                        value: token,
                        docFrequency: 0
                    ))
                }
            }

        case .temporal:
            // TMP: tokens that are a 4-digit year (YYYY — all ASCII digits, length 4).
            //
            // Note on ISO dates: the UAX #29 word-boundary tokenizer splits on
            // hyphens, so "2021-03-15" is tokenized as "2021", "03", "15" — three
            // separate tokens. The year component "2021" is classified TMP via the
            // 4-digit check. The sub-components "03" and "15" (2-digit) are NOT
            // classified as TMP. This is deterministic and consistent across both
            // Swift and Rust ports (UAX #29 conformance contract, cookbook §2.2).
            //
            // Pure character-class scan — no Date(), no regex, no wall-clock.
            for token in tokens {
                if isYear(token) {
                    results.append(ExtractedFeature(
                        type: .temporal,
                        value: token,
                        docFrequency: 0
                    ))
                }
            }
        }

        return results
    }
}

// MARK: - Temporal token classifiers

/// Returns true iff `token` is a 4-digit year string (all ASCII digits, length exactly 4).
///
/// A 4-digit year is any token matching /[0-9]{4}/ with no other characters.
/// The check is a pure character-class scan without Date() or a regex engine.
/// Byte-identical to the Rust `is_year` helper in hmm_feature_extractor.rs.
private func isYear(_ token: String) -> Bool {
    let scalars = token.unicodeScalars
    guard scalars.count == 4 else { return false }
    return scalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
}

// Note: isISODate is not implemented because the UAX #29 word-boundary
// tokenizer splits "2021-03-15" into ["2021", "03", "15"] — a hyphenated
// date string is never presented as a single token. Year components are
// classified via isYear (4-digit check). This is the correct and conformant
// behavior; both the Swift and Rust ports produce the same token stream.
