import Foundation

/// JSON-RPC 2.0 wire types.
///
/// One file's worth of plain-data types so the dispatcher and the
/// stdio loop can pass requests and responses around as values.
/// Encoding goes through `JSONValue` rather than Swift Codable so that
/// dynamic fields (`params`, `result`, `error.data`) stay loss-free
/// through the round-trip. JSON-RPC 2.0 says the `id` field may be a
/// string, a number, or null; the request type carries the parsed
/// `JSONValue` and surfaces it back on the response unchanged, which
/// is what the spec requires.

/// JSON-RPC 2.0 standard error codes plus an MCP-flavored "tool
/// error" code in the implementation-defined band. Per the JSON-RPC
/// 2.0 specification, codes -32768 through -32000 are reserved for
/// pre-defined errors; -32099 through -32000 are for implementation-
/// defined server errors.
public enum JSONRPCErrorCode {
    public static let parseError: Int = -32700
    public static let invalidRequest: Int = -32600
    public static let methodNotFound: Int = -32601
    public static let invalidParams: Int = -32602
    public static let internalError: Int = -32603
    /// Implementation-defined band, reserved for the dispatch layer.
    /// Every failure of a call that reached its runner — substrate verb
    /// refusals (`VerbError`, `GeniusLocusKitError`) AND unexpected
    /// errors (CocoaError, adapter errors) — is surfaced by
    /// `ToolDispatcher.dispatch` as a `tools/call` `isError` result, not
    /// as a JSON-RPC error, so the message reaches the model instead of
    /// being dropped by clients as a bare "failed to call tool". The code
    /// stays defined for wire-compat with clients and with the Rust leg's
    /// `TOOL_DISPATCH_FAILURE`, which uses it internally as the marker its
    /// dispatch boundary converts to an `isError` result the same way.
    public static let toolDispatchFailure: Int = -32010
}

/// A parsed JSON-RPC 2.0 request or notification.
///
/// Notifications are requests without an `id` field per the spec.
/// We keep the same struct for both; an absent `id` (carried as `nil`)
/// signals a notification, which the dispatcher must not reply to.
public struct JSONRPCRequest: Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?

    public init(
        jsonrpc: String = "2.0",
        id: JSONValue?,
        method: String,
        params: JSONValue?
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }

    /// Whether this request is a notification (no `id`, no reply expected).
    public var isNotification: Bool { id == nil }

    /// Parse a JSON-RPC request from a `JSONValue` object. Returns
    /// `nil` for shapes that do not match the JSON-RPC 2.0 request
    /// schema; the caller (the dispatcher) emits an `invalidRequest`
    /// response in that case.
    public static func decode(_ value: JSONValue) -> JSONRPCRequest? {
        guard let object = value.objectValue else { return nil }
        guard let jsonrpc = object["jsonrpc"]?.stringValue, jsonrpc == "2.0" else {
            return nil
        }
        guard let method = object["method"]?.stringValue else { return nil }
        // The spec permits `id` to be a string, number, or null. We
        // pass it through verbatim; absence means notification.
        let id = object["id"]
        let params = object["params"]
        return JSONRPCRequest(jsonrpc: jsonrpc, id: id, method: method, params: params)
    }
}

/// A JSON-RPC 2.0 response — either a result or an error.
public struct JSONRPCResponse: Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONValue
    public let payload: Payload

    public enum Payload: Sendable, Equatable {
        case result(JSONValue)
        case error(JSONRPCError)
    }

    public init(id: JSONValue, payload: Payload) {
        self.jsonrpc = "2.0"
        self.id = id
        self.payload = payload
    }

    public static func ok(_ id: JSONValue, _ result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, payload: .result(result))
    }

    public static func failure(_ id: JSONValue, _ error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(id: id, payload: .error(error))
    }

    /// Encode this response to a `JSONValue` object. The caller serializes
    /// the value through `JSONValue.encoded()` for the stdio write.
    public var asJSONValue: JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string(jsonrpc),
            "id": id,
        ]
        switch payload {
        case .result(let value):
            object["result"] = value
        case .error(let error):
            object["error"] = error.asJSONValue
        }
        return .object(object)
    }
}

/// A JSON-RPC 2.0 error object.
public struct JSONRPCError: Sendable, Equatable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var asJSONValue: JSONValue {
        var object: [String: JSONValue] = [
            "code": .integer(Int64(code)),
            "message": .string(message),
        ]
        if let data = data {
            object["data"] = data
        }
        return .object(object)
    }
}
