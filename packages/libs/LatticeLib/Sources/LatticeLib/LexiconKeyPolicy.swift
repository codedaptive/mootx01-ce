// LexiconKeyPolicy.swift
//
// Shared hygiene for single-token FDC lexicon keys. The seed artifact and the
// runtime bag builder must agree about surfaces that are too weak to carry a
// Wikidata identity by themselves.

import Foundation

enum LexiconKeyPolicy {
    private static let weakQIDSurfaceKeys: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for",
        "from", "if", "in", "into", "is", "it", "its", "of", "on", "or",
        "the", "to", "was", "we", "were", "with",
        // Operational/code surfaces that are common in captures and poor
        // standalone evidence for a knowledge-domain Q-ID.
        "api", "app", "bash", "bin", "cli", "cmd", "dev", "etc", "file",
        "get", "git", "index", "key", "local", "lock", "prune", "put",
        "read", "run", "set", "signal", "src", "tmp", "usr", "valu",
        "value", "var"
    ]

    static func isWeakQIDSurfaceKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return true }
        if key.count < 3 { return true }
        if key.allSatisfy(\.isNumber) { return true }
        return weakQIDSurfaceKeys.contains(key)
    }

    static func qidConceptAllowed(token: String, key: String, concept: String?) -> Bool {
        guard let concept, concept.hasPrefix("Q") else { return false }
        guard !isWeakQIDSurfaceKey(key) else { return false }
        return !token.contains(where: \.isNumber)
    }

    static func conceptForBag(token: String, key: String, concept: String?) -> String? {
        guard let concept else { return nil }
        if concept.hasPrefix("Q") && !qidConceptAllowed(token: token, key: key, concept: concept) {
            return nil
        }
        return concept
    }

    static func singleTokenBuildKey(_ surface: String) -> String? {
        let tokens = Tokenizer.tokenize(surface)
        guard tokens.count == 1 else { return nil }
        let key = Stemmer.stem(Normalizer.normalize(tokens[0]))
        guard !key.isEmpty, !isWeakQIDSurfaceKey(key) else { return nil }
        return key
    }
}
