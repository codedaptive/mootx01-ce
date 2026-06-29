import Foundation

// PalaceJSONValue.swift — a loosely-typed JSON value used to carry the
// per-noun envelope fields the four-noun palace pump preserves losslessly.
//
// ## Why a loosely-typed value here, when the rest of VaultKit is typed
//
// `NoteIR` and `CorpusDocument` are strongly typed because they are the
// long-lived IR contract. The palace envelope is different: it must carry the
// FULL metadata surface of FOUR substrate nouns (drawer, tunnel, KG fact,
// diary entry) — lineage ids, bitmaps, UDC facets, event-vs-filed time,
// Wikidata QIDs, tombstone state — whatever MemPalace's per-noun tool cannot
// accept as a native argument. A closed Swift struct per noun would have to
// enumerate every column of every noun and re-enumerate on every schema
// growth. The carrier is therefore a JSON value map keyed by the substrate
// field name, decided by the caller's per-noun projection (which knows the
// noun's schema). The mapper folds this map into the envelope without per-
// field knowledge, so adding a column to a noun never touches the mapper.
//
// ## Determinism
//
// Canonical encoding (sorted keys, slashes unescaped) is required so the Swift
// and Rust ports emit byte-identical envelopes for identical input — the
// cross-language conformance anchor for the four-noun pump. See
// ``PalacePayloadEnvelope`` for the codec that uses it.

/// A loosely-typed JSON value carrying one envelope field. `Codable` with
/// standard JSON encoding; `Equatable` so round-trip vectors assert
/// `decode(encode(x)) == x`. Canonical key ordering and slash behavior are
/// the responsibility of the codec that wraps this type (see
/// `PalacePayloadEnvelope.canonicalFieldsJSON`).
public enum PalaceJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PalaceJSONValue])
    case object([String: PalaceJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([PalaceJSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: PalaceJSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// The value at an object key, or nil when not an object / key absent.
    public subscript(key: String) -> PalaceJSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// The string payload, when this value is a string.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The boolean payload, when this value is a bool.
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// This value as a Foundation JSON object (`String`/`Bool`/`Double`/
    /// `[Any]`/`[String: Any]`/`NSNull`), for handing to ``MCPStdioClient``'s
    /// `callTool(_:arguments:)` which takes `[String: Any]`.
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.foundationValue)
        case .object(let o): return o.mapValues(\.foundationValue)
        }
    }
}
