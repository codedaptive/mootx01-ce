// LexRank.swift
//
// FDC §7.2 article reduction: LexRank — PageRank/eigenvector centrality over a
// sentence-similarity graph — selects the N most central sentences of an
// article before Steps 1-3 run over it. Build-time only (never invoked at
// runtime), so it has no cross-platform agreement constraint; it is still
// deterministic (fixed tokenization, fixed similarity, fixed power iteration
// via SubstrateML.EigenvalueCentrality).
//
// Pipeline: segment -> per-sentence stemmed term-frequency vectors -> cosine
// similarity graph (thresholded, symmetric) -> eigenvector centrality -> the
// top-N sentences, returned in original order.

import Foundation
import NaturalLanguage
import SubstrateML

public enum LexRank {

    public static let defaultSentences = 10
    public static let similarityThreshold = 0.1

    /// Reduce `text` to its `n` most central sentences (joined by spaces, in
    /// original order). Returns `text` unchanged when it has `<= n` sentences.
    public static func reduce(_ text: String, sentences n: Int = defaultSentences) -> String {
        let sents = segment(text)
        // Guard against negative n: .prefix(n) traps on negative values.
        // A negative sentence count is nonsensical, so return text unchanged.
        guard n >= 0, sents.count > n else { return text }

        // Per-sentence stemmed term-frequency vectors.
        let vecs = sents.map { termFrequencies($0) }

        // Symmetric thresholded cosine-similarity adjacency.
        var adjacency = EigenvalueCentrality.Adjacency(repeating: [], count: sents.count)
        for i in 0..<sents.count {
            for j in (i + 1)..<sents.count {
                let s = cosine(vecs[i], vecs[j])
                if s >= similarityThreshold {
                    adjacency[i].append((neighbor: j, weight: s))
                    adjacency[j].append((neighbor: i, weight: s))
                }
            }
        }

        let scores = EigenvalueCentrality.compute(adjacency: scores0Guard(adjacency, sents.count))
        // Top-n by score (ties by earlier sentence), then restore original order.
        let chosen = (0..<sents.count)
            .sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
            .prefix(n)
            .sorted()
        return chosen.map { sents[$0] }.joined(separator: " ")
    }

    // EigenvalueCentrality expects one row per node; an all-empty adjacency
    // (no edges above threshold) still needs `count` rows so indices line up.
    private static func scores0Guard(_ a: EigenvalueCentrality.Adjacency, _ count: Int) -> EigenvalueCentrality.Adjacency {
        a.count == count ? a : EigenvalueCentrality.Adjacency(repeating: [], count: count)
    }

    // MARK: - sentence segmentation (NLTokenizer; build-time only)
    private static func segment(_ text: String) -> [String] {
        let tk = NLTokenizer(unit: .sentence)
        tk.string = text
        var out: [String] = []
        tk.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out
    }

    // MARK: - term-frequency vector (stemmed content tokens)
    private static func termFrequencies(_ sentence: String) -> [String: Double] {
        var tf: [String: Double] = [:]
        for token in Tokenizer.tokenize(sentence) {
            let t = Stemmer.stem(Normalizer.normalize(token))
            if t.count >= 2 { tf[t, default: 0] += 1 }   // drop 1-char noise
        }
        return tf
    }

    private static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let (small, big) = a.count <= b.count ? (a, b) : (b, a)
        var dot = 0.0
        for (k, v) in small { if let w = big[k] { dot += v * w } }
        guard dot > 0 else { return 0 }
        let na = sqrt(a.values.reduce(0) { $0 + $1 * $1 })
        let nb = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        return dot / (na * nb)
    }
}
