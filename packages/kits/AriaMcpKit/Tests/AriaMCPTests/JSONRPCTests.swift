import Testing
@testable import AriaMCP

/// Round-trip tests for the JSON-RPC envelope decoding and encoding.
///
/// Cover the shapes Part 1 must accept: a normal request with an id,
/// a notification (no id), a malformed envelope. These tests do not
/// reach the dispatcher; they pin the wire types alone.
@Suite("JSON-RPC envelope")
struct JSONRPCTests {

    @Test func testDecodeRequestWithStringID() throws {
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string("req-1"),
            "method": .string("ping"),
        ])
        let request = try #require(JSONRPCRequest.decode(frame))
        #expect(request.method == "ping")
        #expect(request.id == .string("req-1"))
        #expect(!request.isNotification)
    }

    @Test func testDecodeNotificationHasNoID() throws {
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized"),
        ])
        let request = try #require(JSONRPCRequest.decode(frame))
        #expect(request.isNotification)
        #expect(request.id == nil)
    }

    @Test func testDecodeRejectsWrongVersion() {
        let frame: JSONValue = .object([
            "jsonrpc": .string("1.0"),
            "id": .integer(1),
            "method": .string("ping"),
        ])
        #expect(JSONRPCRequest.decode(frame) == nil)
    }

    @Test func testResponseEncodingPreservesIDShape() throws {
        let response = JSONRPCResponse.ok(.integer(42), .object(["ok": .bool(true)]))
        let encoded = response.asJSONValue
        let object = try #require(encoded.objectValue)
        #expect(object["id"] == .integer(42))
        #expect(object["jsonrpc"] == .string("2.0"))
        #expect(object["result"] == .object(["ok": .bool(true)]))
    }

    @Test func testErrorResponseCarriesCodeAndMessage() throws {
        let response = JSONRPCResponse.failure(
            .null,
            JSONRPCError(code: JSONRPCErrorCode.methodNotFound, message: "no such method")
        )
        let object = try #require(response.asJSONValue.objectValue)
        #expect(object["id"] == .null)
        let errorObject = try #require(object["error"]?.objectValue)
        #expect(errorObject["code"] == .integer(Int64(JSONRPCErrorCode.methodNotFound)))
        #expect(errorObject["message"] == .string("no such method"))
    }

    @Test func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object([
            "name": .string("aria-mcp"),
            "count": .integer(7),
            "ratio": .double(0.5),
            "flag": .bool(true),
            "absent": .null,
            "items": .array([.string("a"), .string("b")]),
        ])
        let encoded = try value.encoded()
        let decoded = try JSONValue.parse(encoded)
        #expect(decoded == value)
    }

    // MARK: - integerValue overflow guard (Finding 2)

    /// A JSON double far outside Int64 range (1e100) must return nil from
    /// integerValue — not crash. Before the fix, Int64(d) precondition-trapped
    /// on any double > Int64.max, killing the server process.
    @Test func integerValueReturnsNilForOutOfRangeDouble() {
        let v: JSONValue = .double(1e100)
        #expect(v.integerValue == nil)
    }

    /// Negative out-of-range double also returns nil.
    @Test func integerValueReturnsNilForNegativeOutOfRangeDouble() {
        let v: JSONValue = .double(-1e100)
        #expect(v.integerValue == nil)
    }

    /// +Infinity returns nil (not crash, not garbage).
    @Test func integerValueReturnsNilForPositiveInfinity() {
        let v: JSONValue = .double(Double.infinity)
        #expect(v.integerValue == nil)
    }

    /// A fractional double returns nil — unchanged behavior.
    @Test func integerValueReturnsNilForFractionalDouble() {
        let v: JSONValue = .double(42.5)
        #expect(v.integerValue == nil)
    }

    /// A whole-valued double within Int64 range returns the integer — unchanged behavior.
    @Test func integerValueReturnsSomeForWholeDouble() {
        let v: JSONValue = .double(42.0)
        #expect(v.integerValue == 42)
    }
}
