import AriaMCPWire
import Foundation

/// Where a failed call was determined.
///
/// A transport failure does not prove whether the daemon applied a mutation:
/// the response can be lost after commit. Recovering callers use this value to
/// replay reads while returning an explicit ambiguous outcome for writes.
public enum GatewayCallFailureDisposition: Sendable, Equatable {
    case none
    case server
    case transport
    case ambiguous
}

/// A daemon call's complete wire record, retained for truthful Community UI
/// status and strict structured-response decoding.
public struct GatewayCall: Sendable {
    public let requestJSON: String
    public let responseJSON: String
    public let text: String
    public let structured: JSONValue?
    public let isError: Bool
    public let failureDisposition: GatewayCallFailureDisposition

    public init(
        requestJSON: String,
        responseJSON: String,
        text: String,
        structured: JSONValue?,
        isError: Bool,
        failureDisposition: GatewayCallFailureDisposition = .none
    ) {
        self.requestJSON = requestJSON
        self.responseJSON = responseJSON
        self.text = text
        self.structured = structured
        self.isError = isError
        self.failureDisposition = failureDisposition
    }
}

/// Package-only decoding shared by the remote Community caller.
package enum GatewayResponseDecoder {
    package static func rendered(
        request: JSONRPCRequest,
        response: JSONRPCResponse
    ) -> GatewayCall {
        let (text, structured, isError) = flatten(response)
        return GatewayCall(
            requestJSON: pretty(request.asRequestJSONValue),
            responseJSON: pretty(response.asJSONValue),
            text: text,
            structured: structured,
            isError: isError,
            failureDisposition: isError ? .server : .none
        )
    }

    package static func unanswered(
        request: JSONRPCRequest,
        note: String
    ) -> GatewayCall {
        GatewayCall(
            requestJSON: pretty(request.asRequestJSONValue),
            responseJSON: "(\(note))",
            text: "",
            structured: nil,
            isError: true,
            failureDisposition: .transport
        )
    }

    package static func transportFailure(
        request: JSONRPCRequest,
        error: any Error
    ) -> GatewayCall {
        let reason = String(describing: error)
        return GatewayCall(
            requestJSON: pretty(request.asRequestJSONValue),
            responseJSON: "(transport failure: \(reason))",
            text: reason,
            structured: nil,
            isError: true,
            failureDisposition: .transport
        )
    }

    private static func flatten(
        _ response: JSONRPCResponse
    ) -> (String, JSONValue?, Bool) {
        switch response.payload {
        case .error(let error):
            return ("JSON-RPC error \(error.code): \(error.message)", nil, true)
        case .result(let value):
            guard let object = value.objectValue else {
                return (pretty(value), nil, false)
            }
            let isError = object["isError"]?.boolValue ?? false
            let structured = isError ? nil : object["structuredContent"]
            guard let content = object["content"]?.arrayValue else {
                return (pretty(value), structured, isError)
            }
            let text = content.compactMap { block in
                block.objectValue?["text"]?.stringValue
            }.joined(separator: "\n")
            return (text.isEmpty ? pretty(value) : text, structured, isError)
        }
    }

    private static func pretty(_ value: JSONValue) -> String {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value.foundationObject,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "(unrenderable JSON: \(error))"
        }
    }
}

extension JSONRPCRequest {
    package var asRequestJSONValue: JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string(jsonrpc),
            "method": .string(method),
        ]
        if let id { object["id"] = id }
        if let params { object["params"] = params }
        return .object(object)
    }
}
