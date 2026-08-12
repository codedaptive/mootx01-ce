// ProxyDispositionLogic.swift
//
// Pure, I/O-free disposition logic for the stdio→HTTP proxy bridge.
// Lives in MootInstallerCore so MootInstallerCoreTests can exercise it
// without importing the executable target.

import Foundation

/// The three outcomes of evaluating an HTTP response envelope.
///
/// .silent — no frame written (202 notification ack, per MCP spec)
/// .relay  — relay the body verbatim to the JSON-RPC client
/// .error  — synthesize a JSON-RPC -32603 error with the given message
public enum ProxyDisposition {
    case silent
    case relay
    case error(String)
}

/// Maps an HTTP response envelope onto a `ProxyDisposition`.
///
/// - Parameters:
///   - statusCode: HTTP status code, or nil when the response is not an
///     HTTPURLResponse (a non-HTTP transport reply, always an error).
///   - bodyEmpty: true when the response body has zero bytes.
///
/// Used by `ProxyCommand.forward(_:to:session:writer:)` and tested
/// independently in `ProxyDispositionTests`.
public func proxyDisposition(statusCode: Int?, bodyEmpty: Bool) -> ProxyDisposition {
    guard let status = statusCode else {
        return .error("proxy: non-HTTP response")
    }
    // HTTP 202: notification acknowledged — per MCP spec, no reply.
    if status == 202 { return .silent }
    // Any other empty body is a failure, not a notification (daemon
    // mid-restart, 500/503, rejected request). Without an id-echoing
    // error the client hangs forever on the pending request.
    if bodyEmpty { return .error("proxy: empty response (HTTP \(status))") }
    // Non-2xx: do NOT relay the body. It may not be a JSON-RPC envelope,
    // and a malformed frame poisons the stream.
    if !(200..<300).contains(status) { return .error("proxy: HTTP \(status)") }
    return .relay
}

/// Extract the JSON-RPC `id` of a request frame, re-encoded as a JSON
/// literal (quoted string or bare number).
///
/// Returns nil for:
/// - notifications (no `id` key)
/// - `id: null` (not a valid request id)
/// - boolean ids (`true`/`false` — aligns with Rust which rejects `Value::Bool`)
/// - unparseable frames
///
/// All of the above receive no synthesized error reply.
public func proxyRequestID(of frame: Data) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
          let id = obj["id"] else { return nil }
    if let s = id as? String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
    if let n = id as? NSNumber {
        // Reject boolean NSNumbers: JSONSerialization maps JSON true/false to
        // CFBoolean singletons that bridge to NSNumber. A boolean id is not a
        // valid JSON-RPC id, and the Rust port rejects Value::Bool — both ports
        // must agree on shared disposition test vectors.
        if n === (true as NSNumber) || n === (false as NSNumber) { return nil }
        return "\(n)"
    }
    return nil
}
