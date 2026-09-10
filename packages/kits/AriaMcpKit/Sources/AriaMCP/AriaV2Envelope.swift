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

    /// Attach a coaching hint to a non-error v2 result envelope (RULING 3, §12.5).
    ///
    /// Two mutations, both guarded by `isError` check:
    /// 1. `structuredContent["hint"]` — top-level string sibling of "data" and "meta",
    ///    present ONLY when a hint fires, absent otherwise.
    /// 2. `content[0].text` — `"\nhint: <text>"` appended AFTER the 512 Unicode-scalar
    ///    body clamp. The hint line itself is not clamped.
    ///
    /// Never on a refusal (`isError:true`). Safe to call unconditionally — re-checks
    /// the flag so call-order is not load-bearing.
    ///
    /// Parity: Swift twin of Rust `v2::render::apply_hint`.
    public static func applyHint(_ hint: String, to result: JSONValue) -> JSONValue {
        guard case .object(var envelope) = result else { return result }
        // Re-check: never mutate an error result.
        if case .bool(true) = envelope["isError"] { return result }

        // 1. structuredContent["hint"]
        if case .object(var sc) = envelope["structuredContent"] {
            sc["hint"] = .string(hint)
            envelope["structuredContent"] = .object(sc)
        }

        // 2. content[0].text — append "\nhint: <text>" after the 512-scalar body.
        if case .array(var contentArray) = envelope["content"],
           !contentArray.isEmpty,
           case .object(var firstItem) = contentArray[0],
           case .string(let existing) = firstItem["text"] {
            firstItem["text"] = .string(existing + "\nhint: " + hint)
            contentArray[0] = .object(firstItem)
            envelope["content"] = .array(contentArray)
        }

        return .object(envelope)
    }

    /// Append a periodic coaching block to `content[0].text` of a non-error v2
    /// result envelope (§12.5 periodic coaching cadence, FACT E).
    ///
    /// Unlike `applyHint`, the block has no `structuredContent` key — it is text only,
    /// appended after any hint line already present. Never on a refusal.
    ///
    /// Called at the v2 dispatcher choke point when `modeSessionState.shouldCoach()`
    /// returns `true`. Gated by the caller, but re-checks `isError` for safety.
    ///
    /// Parity: Swift twin of Rust `v2::render::apply_coaching_block`.
    public static func applyCoachingBlock(_ block: String, to result: JSONValue) -> JSONValue {
        guard case .object(var envelope) = result else { return result }
        // Re-check: never mutate an error result.
        if case .bool(true) = envelope["isError"] { return result }

        // Append coaching block to content[0].text after any hint already present.
        if case .array(var contentArray) = envelope["content"],
           !contentArray.isEmpty,
           case .object(var firstItem) = contentArray[0],
           case .string(let existing) = firstItem["text"] {
            firstItem["text"] = .string(existing + "\n" + block)
            contentArray[0] = .object(firstItem)
            envelope["content"] = .array(contentArray)
        }

        return .object(envelope)
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
