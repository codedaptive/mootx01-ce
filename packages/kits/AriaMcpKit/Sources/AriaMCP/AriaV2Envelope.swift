import AriaMCPWire

/// The final v2 MCP projection.  Typed operation services provide `data` and
/// compact text directly; this boundary never reparses a legacy runner result.
public enum AriaV2Envelope {
    public static let surfaceVersion = "v2"
    public static let compactTextScalarLimit = 512

    public static func success(
        tool: String,
        effect: AriaV2OperationEffect,
        data: JSONValue,
        meta: [String: JSONValue] = [:],
        compactText: String
    ) -> JSONValue {
        var mergedMeta = meta
        mergedMeta["effect"] = .string(effect.rawValue)

        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(AriaV2Envelope.compactText(compactText)),
                ]),
            ]),
            "structuredContent": .object([
                "surface_version": .string(surfaceVersion),
                "tool": .string(tool),
                "data": data,
                "meta": .object(mergedMeta),
            ]),
            "isError": .bool(false),
        ])
    }

    public static func refusal(
        tool: String,
        error: AriaV2OperationalRefusal
    ) -> JSONValue {
        var errorObject: [String: JSONValue] = [
            "code": .string(error.code),
            "message": .string(error.message),
            "retryable": .bool(error.retryable),
        ]
        if let recovery = error.recovery {
            errorObject["recovery"] = recovery
        }

        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(compactText(error.message)),
                ]),
            ]),
            "structuredContent": .object([
                "surface_version": .string(surfaceVersion),
                "tool": .string(tool),
                "error": .object(errorObject),
            ]),
            "isError": .bool(true),
        ])
    }

    /// Caps by Unicode scalar values, rather than UTF-8 bytes or grapheme
    /// clusters, as frozen by the v2 contract.
    public static func compactText(_ text: String) -> String {
        guard text.unicodeScalars.count > compactTextScalarLimit else { return text }
        let scalars = text.unicodeScalars.prefix(compactTextScalarLimit)
        let bytes = scalars.flatMap { Array($0.utf8) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A typed expected operational failure.  These project to MCP `isError:true`
/// and are distinct from malformed-protocol and invalid-argument JSON-RPC
/// errors.
public struct AriaV2OperationalRefusal: Sendable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let recovery: JSONValue?

    public init(
        code: String,
        message: String,
        retryable: Bool,
        recovery: JSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.recovery = recovery
    }
}
