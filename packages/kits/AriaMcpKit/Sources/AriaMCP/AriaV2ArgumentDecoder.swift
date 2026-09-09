import Foundation
import AriaMCPWire

/// The structured data carried by every v2 invalid-argument JSON-RPC error.
public struct AriaV2InvalidArgument: Sendable, Equatable {
    public let code: String
    public let path: String
    public let message: String
    public let allowed: [String]?
    public let correction: String?

    public init(
        code: String = "invalid_argument",
        path: String,
        message: String,
        allowed: [String]? = nil,
        correction: String? = nil
    ) {
        self.code = code
        self.path = path
        self.message = message
        self.allowed = allowed
        self.correction = correction
    }

    public var jsonRPCError: JSONRPCError {
        var data: [String: JSONValue] = [
            "code": .string(code),
            "path": .string(path),
            "message": .string(message),
        ]
        if let allowed {
            data["allowed"] = .array(allowed.sorted().map(JSONValue.string))
        }
        if let correction {
            data["correction"] = .string(correction)
        }
        return JSONRPCError(
            code: JSONRPCErrorCode.invalidParams,
            message: message,
            data: .object(data)
        )
    }
}

/// Strict shared decoding for v2 argument objects.  Family request types own
/// their domain rules; this decoder owns object shape, keys, scalar types, and
/// canonical UUID acceptance.
public struct AriaV2ArgumentDecoder: Sendable {
    public let arguments: [String: JSONValue]

    public init(_ value: JSONValue, allowedKeys: Set<String>) throws {
        guard let arguments = value.objectValue else {
            throw AriaV2InvalidArgument(
                path: "arguments",
                message: "arguments must be a JSON object",
                allowed: allowedKeys.sorted(),
                correction: "Pass an object whose keys are declared by this tool."
            ).jsonRPCError
        }

        let unknown = Set(arguments.keys).subtracting(allowedKeys).sorted()
        if let key = unknown.first {
            throw AriaV2InvalidArgument(
                path: key,
                message: "Unknown argument '\(key)'.",
                allowed: allowedKeys.sorted(),
                correction: "Remove the argument or use one of the declared keys."
            ).jsonRPCError
        }
        self.arguments = arguments
    }

    public func has(_ key: String) -> Bool {
        arguments[key] != nil
    }

    public func requireString(_ key: String) throws -> String {
        let value = try requiredValue(for: key)
        guard let string = value.stringValue else {
            throw invalidScalar(key, expected: "string")
        }
        return string
    }

    public func optionalString(_ key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value.stringValue else {
            throw invalidScalar(key, expected: "string")
        }
        return string
    }

    public func requireBoolean(_ key: String) throws -> Bool {
        let value = try requiredValue(for: key)
        guard let boolean = value.boolValue else {
            throw invalidScalar(key, expected: "boolean")
        }
        return boolean
    }

    public func optionalBoolean(_ key: String) throws -> Bool? {
        guard let value = arguments[key] else { return nil }
        guard let boolean = value.boolValue else {
            throw invalidScalar(key, expected: "boolean")
        }
        return boolean
    }

    public func requireInteger(_ key: String) throws -> Int64 {
        let value = try requiredValue(for: key)
        guard let integer = value.integerValue else {
            throw invalidScalar(key, expected: "integer")
        }
        return integer
    }

    public func optionalInteger(_ key: String) throws -> Int64? {
        guard let value = arguments[key] else { return nil }
        guard let integer = value.integerValue else {
            throw invalidScalar(key, expected: "integer")
        }
        return integer
    }

    public func requireUUID(_ key: String) throws -> UUID {
        try decodeUUID(try requireString(key), path: key)
    }

    public func optionalUUID(_ key: String) throws -> UUID? {
        guard let string = try optionalString(key) else { return nil }
        return try decodeUUID(string, path: key)
    }

    /// Requires exactly one supplied key from a mutually exclusive group.
    public func requireExactlyOne(of keys: [String]) throws -> String {
        let supplied = keys.filter { arguments[$0] != nil }
        guard supplied.count == 1, let key = supplied.first else {
            throw AriaV2InvalidArgument(
                code: "conflicting_arguments",
                path: keys.sorted().joined(separator: "|"),
                message: "Provide exactly one of \(keys.sorted().joined(separator: ", ")).",
                allowed: keys.sorted(),
                correction: "Remove the conflicting argument or provide one required argument."
            ).jsonRPCError
        }
        return key
    }

    public static func canonicalUUID(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    /// Physical UUID spellings used by the two portable estate writers.
    /// Public v2 values remain canonical lowercase; bounded lower lookups use
    /// both spellings so either port can open and operate on the same estate.
    public static func storageIdentitySpellings(_ uuid: UUID) -> [String] {
        let native = uuid.uuidString
        let canonical = canonicalUUID(uuid)
        return native == canonical ? [native] : [native, canonical]
    }

    public static func matchingStorageIdentity(_ uuid: UUID, among candidates: [String]) -> String? {
        candidates.first { UUID(uuidString: $0) == uuid }
    }

    private func requiredValue(for key: String) throws -> JSONValue {
        guard let value = arguments[key], value != .null else {
            throw AriaV2InvalidArgument(
                path: key,
                message: "Missing required argument '\(key)'.",
                correction: "Provide a non-null value for \(key)."
            ).jsonRPCError
        }
        return value
    }

    private func invalidScalar(_ key: String, expected: String) -> JSONRPCError {
        AriaV2InvalidArgument(
            path: key,
            message: "Argument '\(key)' must be a \(expected).",
            correction: "Provide \(key) as a \(expected)."
        ).jsonRPCError
    }

    private func decodeUUID(_ string: String, path: String) throws -> UUID {
        guard let uuid = UUID(uuidString: string) else {
            throw AriaV2InvalidArgument(
                path: path,
                message: "Argument '\(path)' must be a UUID.",
                correction: "Provide a valid UUID; accepted input casing is normalized on output."
            ).jsonRPCError
        }
        return uuid
    }
}
