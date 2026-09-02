// OracleVectors.swift
// JSONL loader for the intent-span-v22 oracle vectors.
//
// The four vector beds (debug7, sample30, locomo, blind200) live in Vectors/
// inside the test target.  Package.swift declares them as .copy("Vectors") so
// they are accessible via Bundle.module at runtime.
//
// Row layout (every field that matters for Part 1):
//   "original"   — raw source text; input to ContextShape.classify(_:)
//   "shape"      — expected ShapeDecision serialised as a JSON object
//   "drawer_id"  — opaque record identifier (used in failure messages only)
//   "candidate"  — always "intent-span" for these beds (not used by the classifier)
//   "event_time" — ISO timestamp of the record (not used by the classifier)
//
// Every other field is an expected output of a later part and is preserved in
// `rawJSON` for forward-compatibility but is NOT inspected by Part-1 tests.

import Foundation

/// A single row from an intent-span-v22 oracle JSONL file.
///
/// `@unchecked Sendable` is safe here because the row is populated once from
/// a frozen JSONL file and is never mutated.  The `[String: Any]` fields use
/// Foundation types (NSString, NSNumber, NSArray, NSDictionary) which are all
/// immutable after construction from JSONSerialization.
public struct OracleRow: @unchecked Sendable {

    /// The raw source text to classify.  Corresponds to Python's `original`.
    public let original: String

    /// The expected ``ShapeDecision`` as a Foundation object graph, ready for
    /// ``JSONSerialization``.  Loaded directly from the JSONL row's "shape" key.
    public let shape: [String: Any]

    /// Opaque record identifier for failure-message context.
    public let drawerID: String

    /// The raw grammar-v1 enrichment trailer from the stored p2.3 rendering.
    /// May be an empty string when no trailer is present.
    /// Used by Part 5 to construct the ``DistillationInput`` for ``ContextDistiller``.
    public let enrichmentTrailer: String

    /// Full raw JSON object for this row, kept as [String: Any] for forward
    /// compatibility with later parts that inspect additional fields.
    public let rawJSON: [String: Any]
}

// MARK: - Loader

/// Loads all rows from the named oracle bed.
///
/// - Parameter bed: One of "debug7", "sample30", "locomo", "blind200".
/// - Returns: All rows in file order.  Blank lines at the end of the JSONL file
///   are silently skipped.
/// - Note: Crashes with a clear message if the resource file is missing or
///   contains malformed JSON.  Oracle files are frozen and must be valid.
public func loadOracleRows(bed: String) -> [OracleRow] {
    // Bundle.module is populated by the .copy("Vectors") resource declaration
    // in Package.swift.  The subdirectory argument must match the directory name
    // inside the test bundle, which SwiftPM sets to "Vectors".
    guard let url = Bundle.module.url(
        forResource: "\(bed)-intent-span-v22",
        withExtension: "jsonl",
        subdirectory: "Vectors"
    ) else {
        preconditionFailure(
            "OracleVectors: missing resource \(bed)-intent-span-v22.jsonl — " +
            "check that Package.swift declares .copy(\"Vectors\") for the test target"
        )
    }

    let raw: String
    do {
        raw = try String(contentsOf: url, encoding: .utf8)
    } catch {
        preconditionFailure("OracleVectors: cannot read \(url): \(error)")
    }

    // Split on newlines.  The file ends with a trailing newline; filter blank lines.
    let jsonLines = raw.components(separatedBy: "\n").filter {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }

    return jsonLines.enumerated().map { (lineIndex, line) in
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            preconditionFailure(
                "OracleVectors: malformed JSON at \(bed) line \(lineIndex + 1): \(line.prefix(80))"
            )
        }

        guard let original = dict["original"] as? String else {
            preconditionFailure(
                "OracleVectors: missing 'original' field at \(bed) line \(lineIndex + 1)"
            )
        }
        guard let shape = dict["shape"] as? [String: Any] else {
            preconditionFailure(
                "OracleVectors: missing or invalid 'shape' field at \(bed) line \(lineIndex + 1)"
            )
        }

        let drawerID = (dict["drawer_id"] as? String) ?? "<unknown>"
        // enrichment_trailer is "" when absent (matches Python split_enrichment semantics).
        let enrichmentTrailer = (dict["enrichment_trailer"] as? String) ?? ""

        return OracleRow(original: original, shape: shape, drawerID: drawerID,
                         enrichmentTrailer: enrichmentTrailer, rawJSON: dict)
    }
}

// MARK: - Canonical JSON helper

/// Encodes `obj` as canonical JSON: sorted keys, no extra whitespace.
///
/// Used by conformance tests to compare ``ShapeDecision.asDict()`` against the
/// expected shape from an oracle row, ignoring insertion-order differences in
/// Foundation dictionaries.
///
/// - Throws: When `obj` is not representable as JSON (should never happen for
///   values constructed from Int, String, and Array/Dictionary of those).
public func canonicalJSON(_ obj: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    guard let str = String(data: data, encoding: .utf8) else {
        throw JSONError.encoding
    }
    return str
}

private enum JSONError: Error { case encoding }
