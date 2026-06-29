// WantsEventStreamTests.swift
//
// Tests for HTTPRequest.wantsEventStream exact-parameter matching.
//
// SECURITY FIX (planned hardening 2026-06-28): the old implementation used
// `query.contains("stream=1")` which is a substring check — it would match
// "stream=10", "mystream=1", or "x=stream=1", spuriously triggering SSE
// mode. The fix splits on '&' and checks for "stream=1" as an exact
// parameter, preventing false positives.

import Testing
import Foundation
@testable import LoopbackHTTP

@Suite("wantsEventStream exact matching")
struct WantsEventStreamTests {

    /// Helper to build a minimal HTTPRequest with a given query string.
    private func req(query: String, acceptEventStream: Bool = false) -> HTTPRequest {
        var headers: [String: String] = [:]
        if acceptEventStream {
            headers["accept"] = "text/event-stream"
        }
        return HTTPRequest(
            method: "GET",
            path: "/api/events",
            query: query,
            headers: headers,
            body: Data()
        )
    }

    // MARK: - True positives: should activate SSE

    /// Exact `stream=1` parameter must activate SSE.
    @Test func exactStreamParam_returnsTrue() {
        #expect(req(query: "stream=1").wantsEventStream == true,
                "stream=1 must activate SSE")
    }

    /// `stream=1` among multiple parameters must activate SSE.
    @Test func streamParamAmongOthers_returnsTrue() {
        #expect(req(query: "foo=bar&stream=1&baz=qux").wantsEventStream == true,
                "stream=1 among other params must activate SSE")
    }

    /// `stream=1` as the last of multiple parameters must activate SSE.
    @Test func streamParamLast_returnsTrue() {
        #expect(req(query: "foo=bar&stream=1").wantsEventStream == true)
    }

    /// `stream=1` as the first of multiple parameters must activate SSE.
    @Test func streamParamFirst_returnsTrue() {
        #expect(req(query: "stream=1&foo=bar").wantsEventStream == true)
    }

    /// Accept: text/event-stream header alone must activate SSE (no query param).
    @Test func acceptHeader_returnsTrue() {
        #expect(req(query: "", acceptEventStream: true).wantsEventStream == true,
                "Accept: text/event-stream must activate SSE")
    }

    // MARK: - False positives prevented by exact matching

    /// `stream=10` must NOT activate SSE — was a false positive with contains().
    @Test func streamEqualsTen_returnsFalse() {
        #expect(req(query: "stream=10").wantsEventStream == false,
                "stream=10 must NOT activate SSE (was false-positive with contains())")
    }

    /// `stream=11` must NOT activate SSE.
    @Test func streamEqualsEleven_returnsFalse() {
        #expect(req(query: "stream=11").wantsEventStream == false)
    }

    /// `mystream=1` must NOT activate SSE — was a false positive with contains().
    @Test func prefixedStreamParam_returnsFalse() {
        #expect(req(query: "mystream=1").wantsEventStream == false,
                "mystream=1 must NOT activate SSE (was false-positive with contains())")
    }

    /// `xstream=1` must NOT activate SSE.
    @Test func xstreamParam_returnsFalse() {
        #expect(req(query: "xstream=1").wantsEventStream == false)
    }

    /// An empty query string must not activate SSE (no accept header).
    @Test func emptyQuery_returnsFalse() {
        #expect(req(query: "").wantsEventStream == false)
    }

    /// Unrelated parameters must not activate SSE.
    @Test func unrelatedParams_returnsFalse() {
        #expect(req(query: "format=json&limit=10").wantsEventStream == false)
    }
}
