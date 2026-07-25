import Testing
import Foundation
import AriaMCP
import MootGateway
@testable import GatewayUI

// MARK: - Review Center live-estate smoke  (FAB5-G2 Verification)
//
// The mission's Verification line asks for a walk of all four reviews against a
// LIVE estate. This is that walk, driven through the same code paths the Review
// tab uses — `ReviewCenterModel` builds each report over the real wire, and then
// the view layer's own decisions are checked on the live rows:
//
//   * every section title on real data resolves to prose, never a dotted key
//   * every item title renders, whether it is a key, a UUID, or a fact subject
//   * the coverage line is sane (no year-1 distantPast leaking from the dashboard)
//   * the suggestion policy offers exactly the right tool on real rows, and
//     offers NOTHING on the room-keyed and aggregate rows
//   * nothing is mutated: the recording performer proves the walk is read-only
//
// That last point is the reason this suite can safely run against Bob's real
// estate: it never commits an action. It stages nothing and performs nothing —
// the performer it holds is a recorder, and the walk asserts its call log is
// empty at the end.
//
// OFF by default. A test needing a daemon on a fixed port would fail on any
// machine without one, so it runs only when MOOT_LIVE_REVIEW_UI_SMOKE=1 is set:
//
//   MOOT_LIVE_REVIEW_UI_SMOKE=1 swift test --package-path apps/Mootx01-App \
//       --filter ReviewCenterLiveSmokeTests
//
// The fixture suites cover the same code deterministically; this one proves the
// view layer holds up on an estate with ~98k memories and ~6k facts.

/// Reads the live daemon over HTTP. Test-only, and a copy of the same harness
/// FAB5-G1's `ReviewLiveSmokeTests` uses — production reaches the tool surface
/// through `MootBridge`, which owns transport selection, so this shape is never
/// shipped.
private actor LiveDaemonReader: ReviewSurfaceReading {
    private let transport: HTTPTransport
    private var nextID: Int64 = 1

    /// 90 s, not the transport's 30 s default. FAB5-G1's live run found
    /// `moot_memory_search` exceeding 30 s on this estate (hybrid recall over the
    /// full drawer set), which timed the section out and left it showing a
    /// timeout notice. A smoke run must exercise the surface, not the timeout.
    /// The shipped app is unaffected: it reaches the estate through the
    /// in-process transport, which has no timeout at all.
    init(endpoint: URL, timeout: TimeInterval = 90.0) {
        self.transport = HTTPTransport(endpoint: endpoint, timeout: timeout)
    }

    func call(
        _ surface: ReviewSurface, arguments: [String: JSONValue]
    ) async -> ReviewToolResponse {
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
                let object = value.objectValue
                let text = (object?["content"]?.arrayValue ?? [])
                    .compactMap { $0.objectValue?["text"]?.stringValue }
                    .joined(separator: "\n")
                return ReviewToolResponse(
                    text: text, isError: object?["isError"]?.boolValue ?? false)
            }
        } catch {
            return ReviewToolResponse(text: "\(error)", isError: true)
        }
    }
}

@Suite("Review Center — live estate walk (FAB5-G2)")
@MainActor
struct ReviewCenterLiveSmokeTests {

    /// `nonisolated` because the `.enabled(if:)` trait evaluates it in a Sendable
    /// closure outside the suite's main-actor isolation. Reading the environment
    /// needs no isolation anyway.
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MOOT_LIVE_REVIEW_UI_SMOKE"] == "1"
    }

    nonisolated static var endpoint: URL {
        let raw = ProcessInfo.processInfo.environment["MOOT_LIVE_REVIEW_UI_ENDPOINT"]
            ?? "http://127.0.0.1:4242"
        // Force-unwrap: the default is a literal and an override that will not
        // parse should fail loudly rather than silently skip the walk.
        return URL(string: raw)!
    }

    // Gated by a trait, not by an assertion inside the body: a machine with no
    // daemon must SKIP this, and a failed `#require` would fail it instead.
    // Same mechanism FAB5-G1's live smoke uses.
    @Test("all four reviews build and render from a live estate, mutating nothing",
          .enabled(if: ReviewCenterLiveSmokeTests.isEnabled))
    func liveWalk() async throws {
        let reader = LiveDaemonReader(endpoint: Self.endpoint)
        // A whole-second instant, as the shipped model uses, so `generatedAt`
        // round-trips through the G1 wire coders.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let center = ReviewCenterModel(
            kinds: ReviewKind.allCases,
            clock: { now },
            makeReader: { reader })
        // The recorder is the read-only proof: the walk never commits, and its
        // call log is asserted empty below.
        let performer = RecordingActionPerformer()
        let coordinator = ReviewActionCoordinator(performer: performer)

        for kind in ReviewKind.allCases {
            await center.loadIfNeeded(kind)
            guard case .loaded(let report) = center.state(for: kind) else {
                Issue.record("\(kind.rawValue): no report built from the live estate")
                continue
            }

            // What the user would see at the top of the screen.
            let coverage = ReviewReportView.coverage(of: report)
            #expect(!coverage.contains("0001"), "\(kind.rawValue): distantPast leaked")

            var sectionSummaries: [String] = []
            var offeredTools: Set<String> = []
            for section in report.sections {
                let title = ReviewDisplayStrings.title(forKey: section.title)
                #expect(!title.contains("review."),
                        "\(kind.rawValue)/\(section.id): unresolved key \(section.title)")
                sectionSummaries.append("\(section.id)=\(section.items.count)")

                // Honest emptiness, on live data.
                if section.items.isEmpty {
                    #expect(section.notice?.isEmpty == false,
                            "\(kind.rawValue)/\(section.id): empty with no notice")
                } else {
                    #expect(section.notice == nil,
                            "\(kind.rawValue)/\(section.id): items AND a notice")
                }

                for item in section.items {
                    #expect(!ReviewDisplayStrings.title(forKey: item.title).isEmpty)
                    #expect(!item.provenance.responseLine.isEmpty,
                            "\(section.id): item \(item.id) has no provenance line")
                    let actions = ReviewAction.suggestions(
                        forSectionID: section.id, item: item)
                    offeredTools.formUnion(actions.map(\.tool))
                    // Every suggestion on a live row must carry a real estate id
                    // — a button that posts an empty id is a guaranteed refusal.
                    for action in actions {
                        #expect(!action.subjectID.isEmpty)
                        #expect(item.subjectID == action.subjectID)
                    }
                    // Nothing settled: the coordinator has performed nothing.
                    #expect(!coordinator.isSettled(item))
                }
            }

            // Room-keyed and aggregate sections must offer nothing, on real rows.
            for section in report.sections where ["momentum", "fading", "drift", "duplicates"].contains(section.id) {
                for item in section.items {
                    #expect(ReviewAction.suggestions(
                        forSectionID: section.id, item: item).isEmpty,
                        "\(section.id) offered an action for a non-row subject")
                }
            }

            print("""
                LIVE UI \(kind.rawValue): items=\(report.itemCount) \
                sections[\(sectionSummaries.joined(separator: " "))] \
                surfaces=\(report.contributingSurfaces.map(\.rawValue).sorted().joined(separator: ",")) \
                actions=\(offeredTools.sorted().joined(separator: ",")) \
                coverage="\(coverage)"
                """)

            // The report the app holds must survive the wire coders — FAB5-K1
            // consumes the same JSON.
            let encoded = try ReviewReport.makeEncoder().encode(report)
            #expect(try ReviewReport.makeDecoder().decode(
                ReviewReport.self, from: encoded) == report,
                "\(kind.rawValue): report did not round-trip")
        }

        // THE READ-ONLY PROOF for the whole walk.
        #expect(performer.calls.isEmpty, "the live walk mutated the estate")
        #expect(coordinator.pending == nil)
        #expect(coordinator.lastOutcome == nil)
    }
}
