// Digest.swift
// Content fingerprinting and token estimation for ContextDistillLib.
//
// Mirrors three Python functions from distill_plus_converter.py:
//   source_digest(content)  → hashlib.sha256(content.encode("utf-8")).hexdigest()
//   estimate_tokens(text)   → (3*utf8 + 16*words + 12) // 24
//   split_enrichment(text)  → TRAILER_RE.search(text) split
//
// No regex. The TRAILER_RE scanner is hand-written in Scanners.swift.
// CryptoKit provides SHA-256; Foundation provides nothing else here.

import CryptoKit
import Foundation

// MARK: - Source digest

/// Returns the SHA-256 hex digest of `content` encoded as UTF-8.
///
/// Mirrors Python's `source_digest`:
/// ```python
/// def source_digest(content: str) -> str:
///     return hashlib.sha256(content.encode("utf-8")).hexdigest()
/// ```
///
/// Used to fingerprint estate records and verify identity between the Swift
/// port and the Python oracle.
public func sourceDigest(_ content: String) -> String {
    // Encode as UTF-8 bytes — identical to Python's content.encode("utf-8").
    let bytes = Array(content.utf8)
    let digest = SHA256.hash(data: bytes)
    // Hex-encode with zero-padded lowercase two-char bytes, as hashlib does.
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Token estimation

/// Estimates the token count of `text` using the deterministic advisory formula.
///
/// Mirrors Python's `estimate_tokens`:
/// ```python
/// def estimate_tokens(text: str) -> int:
///     words = text.split()
///     if not words:
///         return 0
///     return (3 * len(text.encode("utf-8")) + 16 * len(words) + 12) // 24
/// ```
///
/// `text.split()` is Python's no-argument split: splits on any whitespace,
/// strips leading/trailing, never produces empty strings.  The denominator 24
/// and the UTF-8 weight 3 come from TokenCompaction v1.  Integer division
/// floors (Python `//`), matching Swift's `/` on non-negative integers.
///
/// Note: Python's `len(text.encode("utf-8"))` counts UTF-8 bytes, not code
/// points.  `len(words)` counts whitespace-separated tokens after stripping.
public func estimateTokens(_ text: String) -> Int {
    // pySplit mirrors Python str.split() — split on whitespace, strip, no empties.
    let scalars = Array(text.unicodeScalars)
    let words = pySplit(scalars)
    guard !words.isEmpty else { return 0 }
    let utf8Bytes = text.utf8.count
    let wordCount = words.count
    // Python integer floor division: (a + b + c) // d is safe for non-negatives.
    return (3 * utf8Bytes + 16 * wordCount + 12) / 24
}

// MARK: - Enrichment trailer split

/// Splits a distilled string into its body and grammar-v1 enrichment trailer.
///
/// Mirrors Python's `split_enrichment`:
/// ```python
/// def split_enrichment(distilled: str) -> tuple[str, str]:
///     match = TRAILER_RE.search(distilled)
///     if not match:
///         return distilled.strip(), ""
///     return distilled[:match.start()].rstrip(), match.group("trailer").strip()
/// ```
///
/// TRAILER_RE: `(?P<trailer>\s+\(\*\[\s.*?\s\]\*\))\s*$`  (re.DOTALL)
///
/// The function returns:
/// - `body`: text before the trailer, right-stripped of whitespace.
/// - `trailer`: the trailer group stripped of leading/trailing whitespace;
///   empty string when no trailer is present.
///
/// The split is performed on the combined reconstruction text
/// `original + " " + enrichment_trailer` by the converter.  This function
/// receives that combined string as `text`.
public func splitEnrichment(_ text: String) -> (body: String, trailer: String) {
    let scalars = Array(text.unicodeScalars)
    guard let match = trailerRESearch(scalars) else {
        // No trailer — strip leading/trailing whitespace from the whole string.
        return (pyRstrip(scalars).asString(), "")
    }
    // body = text[:match.start].rstrip()
    let bodyScalars = pyRstrip(Array(scalars[..<match.start]))
    // trailer = match.group("trailer").strip()  → groups[0] (index 0 of groups array)
    let trailerText: String
    if let grpStr = match.groups[0] {
        // strip() the captured group
        let grpScalars = Array(grpStr.unicodeScalars)
        trailerText = pyStrip(grpScalars).asString()
    } else {
        trailerText = ""
    }
    return (bodyScalars.asString(), trailerText)
}

// MARK: - Internal helpers

/// Converts any `Collection<Unicode.Scalar>` to a Swift `String`.
extension Collection where Element == Unicode.Scalar {
    /// Builds a `String` from the scalar collection.
    func asString() -> String {
        var s = ""
        s.unicodeScalars.append(contentsOf: self)
        return s
    }
}
