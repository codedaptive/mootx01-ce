import Testing
import Foundation
import AriaMCP
@testable import MootGateway

// MARK: - Live-estate smoke  (FAB5-G1 Verification)
//
// The mission requires all four reports to build against a LIVE local estate.
// This suite does exactly that, over the real wire, against a running resident
// daemon — no fixtures, no stubs.
//
// It is OFF by default. A test that needs a daemon on a fixed port would fail on
// any machine without one, so it runs only when MOOT_LIVE_REVIEW_SMOKE=1 is set.
// The default endpoint is the daemon's conventional loopback address; override
// with MOOT_LIVE_REVIEW_ENDPOINT.
//
//   MOOT_LIVE_REVIEW_SMOKE=1 swift test --package-path apps/Mootx01-App \
//       --filter ReviewLiveSmokeTests
//
// The fixture suites cover the same builders deterministically; this one proves
// the surfaces answer as parsed on a real estate.

/// Test-only reader that speaks JSON-RPC `tools/call` to a running daemon over
/// HTTP. Deliberately not shipped in MootGateway: production callers reach the
/// tool surface through MootBridge (`MootToolCallingReviewReader`), which owns
/// transport selection. This exists only to prove the wire.
private actor LiveDaemonReviewReader: ReviewSurfaceReading {
    private let transport: HTTPTransport
    private var nextID: Int64 = 1

    // 90 s, not the transport's 30 s default: the live smoke on a real estate
    // showed moot_memory_search exceeding 30 s (hybrid recall over ~6k facts and
    // a full drawer set), which timed the section out. A smoke run must exercise
    // the surface, not the timeout.
    init(endpoint: URL, timeout: TimeInterval = 90.0) {
        self.transport = HTTPTransport(endpoint: endpoint, timeout: timeout)
    }

    func call(_ surface: ReviewSurface, arguments: [String: JSONValue]) async -> ReviewToolResponse {
        let id = nextID
        nextID += 1
        let request = JSONRPCRequest(
            id: .integer(id),
            method: "tools/call",
            params: .object([
                "name": .string(surface.rawValue),
                "arguments": .object(arguments),
            ]))
        do {
            guard let response = try await transport.send(request) else {
                return ReviewToolResponse(text: "no response frame", isError: true)
            }
            switch response.payload {
            case .error(let error):
                return ReviewToolResponse(text: error.message, isError: true)
            case .result(let value):
                // MCP tool result: { content: [{ type: "text", text: … }], isError: Bool }
                let object = value.objectValue
                let text = (object?["content"]?.arrayValue ?? [])
                    .compactMap { $0.objectValue?["text"]?.stringValue }
                    .joined(separator: "\n")
                let isError = object?["isError"]?.boolValue ?? false
                return ReviewToolResponse(text: text, isError: isError)
            }
        } catch {
            return ReviewToolResponse(text: "\(error)", isError: true)
        }
    }
}

@Suite("Review builders — live local estate smoke (FAB5-G1)")
struct ReviewLiveSmokeTests {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MOOT_LIVE_REVIEW_SMOKE"] == "1"
    }

    static var endpoint: URL {
        let raw = ProcessInfo.processInfo.environment["MOOT_LIVE_REVIEW_ENDPOINT"]
            ?? "http://127.0.0.1:4242"
        // Force-unwrap is confined to this opt-in suite: a malformed override is a
        // caller error that should fail loudly, not silently fall back.
        return URL(string: raw)!
    }

    @Test("all four reports build against a live local estate",
          .enabled(if: ReviewLiveSmokeTests.isEnabled),
          arguments: ReviewKind.allCases)
    func buildsAgainstLiveEstate(kind: ReviewKind) async throws {
        let reader = LiveDaemonReviewReader(endpoint: Self.endpoint)
        // A real instant, truncated to a whole second: ReviewReport encodes dates at
        // second resolution, so a sub-second `now` would not survive the round-trip
        // check below. Every instant ReviewSchedule produces is already whole-second.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let builder = ReviewBuilderFactory.builder(
            for: kind, schedule: ReviewSchedule(calendar: ReviewSchedule.utcCalendar))
        let report = await builder.build(now: now, reader: reader)

        #expect(report.kind == kind)
        #expect(report.generatedAt == now)
        #expect(!report.sections.isEmpty)
        // Every section either produced items or explained itself.
        for section in report.sections {
            #expect(!section.items.isEmpty || section.notice != nil)
            for item in section.items {
                #expect(!item.provenance.responseLine.isEmpty)
                #expect(item.provenance.surface.rawValue.hasPrefix("moot_"))
            }
        }
        // And the live report serializes for the downstream consumers.
        let data = try ReviewReport.makeEncoder().encode(report)
        let decoded = try ReviewReport.makeDecoder().decode(ReviewReport.self, from: data)
        #expect(decoded == report)

        // Printed so the smoke run's evidence can be pasted into the completion
        // report verbatim rather than summarized from memory.
        let summary = report.sections
            .map { "\($0.id)=\($0.items.count)" }
            .joined(separator: " ")
        print("LIVE SMOKE \(kind.rawValue): items=\(report.itemCount) sections[\(summary)] "
              + "surfaces=\(report.contributingSurfaces.map(\.rawValue).joined(separator: ","))")
    }
}
