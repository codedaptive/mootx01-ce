// ProxyDispositionTests.swift
//
// Decision-table and requestID conformance tests for the stdio→HTTP proxy's
// pure disposition logic (proxyDisposition, proxyRequestID in MootInstallerCore).
// All tests are I/O-free: they call free functions with no URLSession or stdout
// dependency.
//
// Rows are drawn from the shared invariant:
//   - id-bearing frame + 202          → .silent
//   - id-bearing frame + 2xx + body   → .relay
//   - id-bearing frame + empty body   → .error (regardless of status)
//   - id-bearing frame + non-2xx body → .error
//   - non-HTTP response (nil status)  → .error
//   - notification / null id           → no error frame emitted
//   - boolean id                       → nil (aligns with Rust Value::Bool rejection)

import Foundation
import Testing

@testable import MootInstallerCore

@Suite("proxyDisposition — decision table")
struct ProxyDispositionTests {

    // MARK: — .silent

    @Test("202 empty body → silent")
    func status202EmptyIsSilent() {
        let result = proxyDisposition(statusCode: 202, bodyEmpty: true)
        guard case .silent = result else {
            Issue.record("Expected .silent, got \(result)")
            return
        }
    }

    @Test("202 non-empty body → silent (notification ack body is ignored)")
    func status202NonEmptyIsSilent() {
        let result = proxyDisposition(statusCode: 202, bodyEmpty: false)
        guard case .silent = result else {
            Issue.record("Expected .silent, got \(result)")
            return
        }
    }

    // MARK: — .relay

    @Test("200 non-empty body → relay")
    func status200NonEmptyIsRelay() {
        let result = proxyDisposition(statusCode: 200, bodyEmpty: false)
        guard case .relay = result else {
            Issue.record("Expected .relay, got \(result)")
            return
        }
    }

    @Test("201 non-empty body → relay")
    func status201NonEmptyIsRelay() {
        let result = proxyDisposition(statusCode: 201, bodyEmpty: false)
        guard case .relay = result else {
            Issue.record("Expected .relay, got \(result)")
            return
        }
    }

    // MARK: — .error (empty body)

    @Test("200 empty body → error (daemon restart race: accepted then reset)")
    func status200EmptyBodyIsError() {
        let result = proxyDisposition(statusCode: 200, bodyEmpty: true)
        guard case .error(let msg) = result else {
            Issue.record("Expected .error, got \(result)")
            return
        }
        #expect(msg.contains("empty response"))
        #expect(msg.contains("200"))
    }

    @Test("500 empty body → error")
    func status500EmptyBodyIsError() {
        let result = proxyDisposition(statusCode: 500, bodyEmpty: true)
        guard case .error(let msg) = result else {
            Issue.record("Expected .error, got \(result)")
            return
        }
        #expect(msg.contains("empty response"))
        #expect(msg.contains("500"))
    }

    @Test("503 empty body → error")
    func status503EmptyBodyIsError() {
        let result = proxyDisposition(statusCode: 503, bodyEmpty: true)
        guard case .error(let msg) = result else {
            Issue.record("Expected .error, got \(result)")
            return
        }
        #expect(msg.contains("empty response"))
        #expect(msg.contains("503"))
    }

    // MARK: — .error (non-2xx body present)

    @Test("500 non-empty body → error (body not relayed — may not be JSON-RPC)")
    func status500NonEmptyBodyIsError() {
        let result = proxyDisposition(statusCode: 500, bodyEmpty: false)
        guard case .error(let msg) = result else {
            Issue.record("Expected .error, got \(result)")
            return
        }
        #expect(msg.contains("500"))
    }

    @Test("503 non-empty body → error")
    func status503NonEmptyBodyIsError() {
        let result = proxyDisposition(statusCode: 503, bodyEmpty: false)
        guard case .error(let msg) = result else {
            Issue.record("Expected .error, got \(result)")
            return
        }
        #expect(msg.contains("503"))
    }

    @Test("404 non-empty body → error")
    func status404NonEmptyBodyIsError() {
        let result = proxyDisposition(statusCode: 404, bodyEmpty: false)
        guard case .error(let msg) = result else {
            Issue.record("Expected .error, got \(result)")
            return
        }
        #expect(msg.contains("404"))
    }

    // MARK: — .error (non-HTTP response)

    @Test("nil statusCode (non-HTTP response) → error")
    func nilStatusCodeIsError() {
        let result = proxyDisposition(statusCode: nil, bodyEmpty: false)
        guard case .error(let msg) = result else {
            Issue.record("Expected .error, got \(result)")
            return
        }
        #expect(msg.contains("non-HTTP"))
    }

    @Test("nil statusCode empty body → error")
    func nilStatusCodeEmptyBodyIsError() {
        let result = proxyDisposition(statusCode: nil, bodyEmpty: true)
        guard case .error = result else {
            Issue.record("Expected .error, got \(result)")
            return
        }
    }
}

@Suite("proxyRequestID — conformance rows")
struct ProxyRequestIDTests {

    private func frameData(_ json: String) -> Data { Data(json.utf8) }

    @Test("numeric id → bare number literal")
    func numericID() {
        let frame = frameData(#"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{}}"#)
        #expect(proxyRequestID(of: frame) == "42")
    }

    @Test("string id → quoted literal")
    func stringID() {
        let frame = frameData(#"{"jsonrpc":"2.0","id":"req-abc","method":"tools/call","params":{}}"#)
        #expect(proxyRequestID(of: frame) == "\"req-abc\"")
    }

    @Test("string id with embedded quotes → escaped")
    func stringIDWithQuotes() {
        // id is: req"x
        let frame = frameData("{\"jsonrpc\":\"2.0\",\"id\":\"req\\\"x\",\"method\":\"tools/call\",\"params\":{}}")
        let result = proxyRequestID(of: frame)
        #expect(result != nil)
        // Result must be a quoted string literal embeddable in a JSON object
        #expect(result?.hasPrefix("\"") == true)
        #expect(result?.hasSuffix("\"") == true)
    }

    @Test("notification (no id) → nil")
    func notificationReturnsNil() {
        let frame = frameData(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#)
        #expect(proxyRequestID(of: frame) == nil)
    }

    @Test("id:null → nil (Rust rejects null id)")
    func nullIDReturnsNil() {
        let frame = frameData(#"{"jsonrpc":"2.0","id":null,"method":"tools/call","params":{}}"#)
        #expect(proxyRequestID(of: frame) == nil)
    }

    @Test("id:true → nil (Rust rejects Value::Bool)")
    func boolTrueIDReturnsNil() {
        let frame = frameData(#"{"jsonrpc":"2.0","id":true,"method":"tools/call","params":{}}"#)
        #expect(proxyRequestID(of: frame) == nil)
    }

    @Test("id:false → nil (Rust rejects Value::Bool)")
    func boolFalseIDReturnsNil() {
        let frame = frameData(#"{"jsonrpc":"2.0","id":false,"method":"tools/call","params":{}}"#)
        #expect(proxyRequestID(of: frame) == nil)
    }

    @Test("malformed JSON → nil")
    func malformedJSONReturnsNil() {
        let frame = frameData("not json at all {{")
        #expect(proxyRequestID(of: frame) == nil)
    }

    @Test("empty frame → nil")
    func emptyFrameReturnsNil() {
        let frame = frameData("")
        #expect(proxyRequestID(of: frame) == nil)
    }
}
