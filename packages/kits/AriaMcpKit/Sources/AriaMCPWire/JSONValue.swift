import Foundation

/// A tagged-union representation of an arbitrary JSON value.
///
/// JSON-RPC `params` and `result` fields are dynamic — their shape
/// depends on the method. The Swift Codable surface in Foundation
/// does not give us a stable "any JSON" type, and `Any` cannot cross
/// Sendable boundaries cleanly under Swift 6 strict concurrency. So
/// we hand-roll a minimal value enum that round-trips through
/// JSONSerialization with no information loss and that the tool
/// dispatcher can pattern-match on without re-decoding.
///
/// The enum carries the JSON model's six shapes: null, boolean,
/// number (split into integer and double so integer tool arguments
/// like `limit` survive a round-trip without becoming `1.0`), string,
/// array, and object. The object case stores an unordered
/// `[String: JSONValue]` map; `JSONSerialization` determines encode-side
/// key ordering. Consumers should not rely on object-key ordering.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {

    /// Decode a JSON value from an `Any` produced by `JSONSerialization`.
    /// Throws `JSONValueError.unsupportedType` for shapes the JSON model
    /// does not represent (notably custom NSObject subclasses).
    public static func from(_ any: Any) throws -> JSONValue {
        if any is NSNull {
            return .null
        }
        if let n = any as? NSNumber {
            // NSNumber is the Foundation bridge target for both Bool
            // and numeric types. Bool comes through as a CFBoolean which
            // tests equal to kCFBooleanTrue; distinguishing it here
            // preserves the original JSON shape (true / false vs 1 / 0).
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            // Integer vs double: JSONSerialization hands integers back
            // as NSNumber with an integer type code. Comparing the
            // double round-trip to the int64 round-trip preserves
            // integer-ness for whole-number values that arrived as
            // integers, and tags any fractional value as `.double`.
            let asInt = n.int64Value
            let asDouble = n.doubleValue
            if Double(asInt) == asDouble && !asDouble.isInfinite && !asDouble.isNaN {
                let typeCode = String(cString: n.objCType)
                // Foundation's NSNumber types encode as one-character
                // type codes: "i","l","q","s","c" are integer widths.
                // "d","f" mean the value originated as a double or
                // float and must stay double on the way out.
                if typeCode == "d" || typeCode == "f" {
                    return .double(asDouble)
                }
                return .integer(asInt)
            }
            return .double(asDouble)
        }
        if let s = any as? String {
            return .string(s)
        }
        if let arr = any as? [Any] {
            return .array(try arr.map(JSONValue.from))
        }
        if let obj = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(obj.count)
            for (key, value) in obj {
                out[key] = try JSONValue.from(value)
            }
            return .object(out)
        }
        throw JSONValueError.unsupportedType(String(describing: type(of: any)))
    }

    /// Produce a Foundation-side value suitable for `JSONSerialization`.
    /// `JSONSerialization` does not accept Swift enums; it walks
    /// `NSNumber`, `NSNull`, `String`, `[Any]`, and `[String: Any]`.
    public var foundationObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let b):
            return NSNumber(value: b)
        case .integer(let i):
            return NSNumber(value: i)
        case .double(let d):
            return NSNumber(value: d)
        case .string(let s):
            return s
        case .array(let arr):
            return arr.map { $0.foundationObject }
        case .object(let dict):
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, value) in dict {
                out[key] = value.foundationObject
            }
            return out
        }
    }

    /// Convenience: parse a UTF-8 JSON byte buffer into a `JSONValue`.
    public static func parse(_ data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONValue.from(any)
    }

    /// Convenience: serialize a `JSONValue` to a UTF-8 JSON byte buffer.
    public func encoded() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: foundationObject,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )
    }
}

// MARK: - Accessors

extension JSONValue {

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var integerValue: Int64? {
        switch self {
        case .integer(let i): return i
        case .double(let d):
            // Use Int64(exactly:) so out-of-range doubles (e.g. 1e100) and
            // non-whole doubles return nil instead of crashing (precondition
            // failure) or silently truncating. Mirrors the "exactly" contract:
            // nil if the conversion is lossy for any reason (out-of-range,
            // fractional, NaN, ±inf).
            return Int64(exactly: d)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

public enum JSONValueError: Error, Equatable {
    case unsupportedType(String)
}
