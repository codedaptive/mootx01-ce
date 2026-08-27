// BundleDigest.swift
//
// Swift port of verify_contract.py's bundle-digest algorithm.
//
// The fixture-bundle digest is SHA-256 over:
//   for path in [contract.json, fixtures/capture.json, fixtures/estate.json,
//                fixtures/identity.json, fixtures/lan.json,
//                fixtures/obsidian.json, fixtures/review.json,
//                fixtures/transfer.json]  (sorted alphabetically):
//     SHA-256.update(relative_path + "\n" + canonical_json + "\n")
//
// "Canonical JSON" = JSON serialised with sorted keys, no extraneous whitespace,
// no NaN/Inf, UTF-8 encoded.  The Python json.dumps equivalent in Swift is
// JSONSerialization with .sortedKeys + no escaping slashes + no pretty-print.
//
// The resulting hex string must match fixture-bundle.sha256.

import Foundation
import CryptoKit

/// Compute the SHA-256 fixture-bundle digest for the Community 1.1 contract.
///
/// - Parameter contractRoot: directory containing `contract.json`, `fixtures/`,
///   and `fixture-bundle.sha256`.
/// - Returns: the 64-character lowercase hex digest.
/// - Throws: if any file cannot be read or parsed.
func computeFixtureBundleDigest(contractRoot: URL) throws -> String {
    let contractPath = contractRoot.appendingPathComponent("contract.json")
    let fixtureDir  = contractRoot.appendingPathComponent("fixtures")

    // Enumerate fixture files in sorted order, exactly as Python sorted() does.
    let fm = FileManager.default
    let fixtureContents = try fm.contentsOfDirectory(at: fixtureDir,
                                                      includingPropertiesForKeys: nil)
    let fixturePaths = fixtureContents
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    // Ordered list of (path, relative-name) pairs.
    var sources: [(url: URL, relative: String)] = []
    sources.append((contractPath, "contract.json"))
    for path in fixturePaths {
        sources.append((path, "fixtures/\(path.lastPathComponent)"))
    }

    // Accumulate into a single SHA-256 hasher (streaming, not per-file).
    var hasher = SHA256()
    for (url, relative) in sources {
        let raw = try Data(contentsOf: url)
        guard let parsed = try? JSONSerialization.jsonObject(with: raw, options: []) else {
            throw BundleDigestError.parseFailure(url.lastPathComponent)
        }
        // Canonical JSON: sorted keys, no pretty-print, no slash escaping.
        // JSONSerialization does not support .withoutEscapingSlashes in all
        // SDK versions, so we produce the bytes with sortedKeys and handle
        // slash escaping in a post-pass — the only character JSON escapes that
        // Python json.dumps does NOT escape is "/", so we un-escape "\/" → "/".
        guard let canonical = try? JSONSerialization.data(
            withJSONObject: parsed,
            options: [.sortedKeys]
        ) else {
            throw BundleDigestError.serializationFailure(url.lastPathComponent)
        }
        // Un-escape forward slashes: Swift's JSONSerialization may escape "/" as "\/"
        // but Python's json.dumps does not (allow_nan=False, ensure_ascii=False).
        let canonicalStr = String(decoding: canonical, as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        guard let canonicalBytes = canonicalStr.data(using: .utf8) else {
            throw BundleDigestError.encodingFailure(url.lastPathComponent)
        }
        // Feed: relative_path + "\n" + canonical_json + "\n"
        let relativeBytes = Data((relative + "\n").utf8)
        let trailingNewline = Data("\n".utf8)
        hasher.update(data: relativeBytes)
        hasher.update(data: canonicalBytes)
        hasher.update(data: trailingNewline)
    }
    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Verify the stored digest matches the computed one.
///
/// - Parameter contractRoot: directory containing `fixture-bundle.sha256`.
/// - Returns: the verified hex digest (same value either way).
/// - Throws: BundleDigestError.mismatch if they differ.
func verifyFixtureBundleDigest(contractRoot: URL) throws -> String {
    let computed = try computeFixtureBundleDigest(contractRoot: contractRoot)
    let storedPath = contractRoot.appendingPathComponent("fixture-bundle.sha256")
    let stored = try String(contentsOf: storedPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard computed == stored else {
        throw BundleDigestError.mismatch(computed: computed, stored: stored)
    }
    return computed
}

enum BundleDigestError: Error, CustomStringConvertible {
    case parseFailure(String)
    case serializationFailure(String)
    case encodingFailure(String)
    case mismatch(computed: String, stored: String)

    var description: String {
        switch self {
        case .parseFailure(let f): return "failed to parse \(f)"
        case .serializationFailure(let f): return "failed to serialize \(f)"
        case .encodingFailure(let f): return "failed to encode \(f)"
        case .mismatch(let c, let s): return "digest mismatch: computed=\(c) stored=\(s)"
        }
    }
}
