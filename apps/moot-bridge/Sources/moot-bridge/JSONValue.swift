import Foundation

// JSONValue.swift — the loosely-typed JSON value the bridge uses to parse and
// rebuild JSON-RPC messages whose shapes are not known at compile time.
//
// Carried over verbatim (our code) from the proven benchmarker skeleton
// (tools/mcp-benchmarker/.../MCPClient.swift). The bridge is engine-agnostic: it
// does not know the two backends' tool names or result shapes at compile time,
// so it parses just enough of each message to classify + translate it and
// re-encodes the rest. A full typed model would couple the bridge to one server's
// schema; this stays decoupled.

/// An error raised while talking to an MCP backend.
struct MCPError: Error, Sendable, CustomStringConvertible {
    let description: String
}

/// A loosely-typed JSON value, used both to build tool-call arguments and to
/// parse tool results from servers whose result shapes are not known at compile
/// time (the bridge is engine-agnostic).
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
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

    /// The value at an object key, or nil if not an object / key absent.
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// The string payload, if this value is a string.
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The object payload, if this value is an object.
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// The array payload, if this value is an array.
    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}
