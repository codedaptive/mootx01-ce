import Foundation

// JSONValue — type-erased JSON value for unknown-field preservation.
//
// WorkPacket.additionalFields captures any JSON key not recognised by the
// v1 schema. On re-encode those keys are written back verbatim, so a v1
// reader round-tripping a v2 packet does not silently drop future fields.
// This type is internal; callers see only the WorkPacket surface.

// MARK: - JSONValue

/// Type-erased JSON value covering the six JSON primitives plus the two
/// structural types. Internal to WorkPacketKit.
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:              try container.encodeNil()
        case .bool(let b):      try container.encode(b)
        case .int(let i):       try container.encode(i)
        case .double(let d):    try container.encode(d)
        case .string(let s):    try container.encode(s)
        case .array(let a):     try container.encode(a)
        case .object(let o):    try container.encode(o)
        }
    }
}
