// Segmenter.swift
//
// Sentence segmentation for the deterministic linguistic
// pipeline. The accel/canonical-reference split mirrors the
// FDC encoder mandate pattern used by WordClassTagger:
// `sentencesByDelimiter` is the deterministic reference,
// always available and identical across platforms;
// `sentences` is the platform-routed entry point that may
// invoke an Apple acceleration on iOS / macOS / tvOS /
// watchOS / visionOS via NLTokenizer.
//
// Per the apple-nlp-accel constitutional constraint (C-2),
// the canonical reference is always available; the Apple
// path is federation-disabled acceleration that handles
// language-specific edge cases (abbreviations like "Dr.",
// quotation handling, locale-aware boundaries). Downstream
// consumers content-address by (sourceID, startOffset,
// text), so any platform-divergent segmentation surfaces
// as a SUPERSET of chunks across devices under an
// append-only conflict policy, rather than as conflicting
// writes that need reconciliation.
//
// Relocated 2026-05-27 (F16) from
// CorpusKit/Sources/CorpusKit/Chunker.swift::sentenceSegments
// to centralize linguistic-pipeline stages in EideticLib
// alongside Tokenizer / Normalizer / Stemmer /
// WordClassTagger.

import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public extension EideticLib {

    /// Segment text into sentences. Uses `NLTokenizer(unit:
    /// .sentence)` on Apple platforms; falls back to
    /// `sentencesByDelimiter` on non-Apple platforms.
    ///
    /// For empty input, returns the empty array. For
    /// non-empty input that yields no segments by either
    /// path, returns the entire input as a single substring
    /// so the caller always gets total coverage.
    ///
    /// - Parameter text: input string to segment.
    /// - Returns: ordered sentence substrings of `text`.
    static func sentences(_ text: String) -> [Substring] {
        if text.isEmpty { return [] }
        #if canImport(NaturalLanguage)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [Substring] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            out.append(text[range])
            return true
        }
        return out.isEmpty ? [text[text.startIndex..<text.endIndex]] : out
        #else
        return sentencesByDelimiter(text)
        #endif
    }

    /// Deterministic delimiter-based sentence segmentation:
    /// splits on `.`, `!`, `?`, and newline while preserving
    /// the terminator at the end of each segment. This is
    /// the canonical reference path, identical across
    /// platforms. The Rust cross-leg counterpart is
    /// `eidetic_lib::segmenter::sentences`, which implements
    /// the same algorithm (Apple NLTokenizer acceleration is
    /// deliberately Apple-only and excluded from cross-leg
    /// parity).
    ///
    /// Always callable directly when strict cross-platform
    /// identity is required.
    ///
    /// - Parameter text: input string to segment.
    /// - Returns: ordered sentence substrings of `text`.
    static func sentencesByDelimiter(_ text: String) -> [Substring] {
        if text.isEmpty { return [] }
        var out: [Substring] = []
        var lastStart = text.startIndex
        var idx = text.startIndex
        while idx < text.endIndex {
            let c = text[idx]
            if c == "." || c == "!" || c == "?" || c == "\n" {
                let next = text.index(after: idx)
                out.append(text[lastStart..<next])
                lastStart = next
            }
            idx = text.index(after: idx)
        }
        if lastStart < text.endIndex {
            out.append(text[lastStart..<text.endIndex])
        }
        return out.isEmpty ? [text[text.startIndex..<text.endIndex]] : out
    }
}
