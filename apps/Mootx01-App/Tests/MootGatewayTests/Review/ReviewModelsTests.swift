import Testing
import Foundation
@testable import MootGateway

// MARK: - ReviewKit model tests  (FAB5-G1 Part 1)
//
// The models are a cross-mission contract (FAB5-G2 / H2 / K1), so these tests
// pin the wire shape: ISO8601 dates, stable key order, exact tool-name raw
// values, and a full round-trip including the empty-report case.

@Suite("ReviewKit models — wire contract and round-trip (FAB5-G1)")
struct ReviewModelsTests {

    // A fixed instant so encoded output is byte-comparable.
    static let now = Date(timeIntervalSince1970: 1_783_956_800)  // 2026-07-13T15:33:20Z

    static func sampleItem(ordinal: Int = 0) -> ReviewItem {
        ReviewItem(
            id: ReviewItem.makeID(surface: .themeWeather, subjectID: "ROOM-1", ordinal: ordinal),
            title: "ROOM-1",
            detail: "momentum=0.017680074613053376",
            subjectID: "ROOM-1",
            magnitude: 0.017680074613053376,
            status: .recorded,
            provenance: ReviewProvenance(
                surface: .themeWeather,
                arguments: ["halfLifeSeconds": "604800.0"],
                responseLine: "  - ROOM-1 momentum=0.017680074613053376"))
    }

    static func sampleReport() -> ReviewReport {
        ReviewReport(
            kind: .dashboard,
            generatedAt: now,
            window: .unbounded(endingAt: now),
            sections: [
                ReviewSection(
                    id: "momentum", title: "review.section.momentum",
                    items: [sampleItem()], notice: nil),
                ReviewSection(
                    id: "conflicts", title: "review.section.conflicts",
                    items: [], notice: "moot_lens_contradiction: contradicts_tunnels: none"),
            ])
    }

    @Test("report round-trips through the wire coders unchanged")
    func reportRoundTrip() throws {
        let report = Self.sampleReport()
        let data = try ReviewReport.makeEncoder().encode(report)
        let decoded = try ReviewReport.makeDecoder().decode(ReviewReport.self, from: data)
        #expect(decoded == report)
    }

    @Test("an empty report is valid and round-trips")
    func emptyReportRoundTrip() throws {
        let empty = ReviewReport(
            kind: .weekly,
            generatedAt: Self.now,
            window: ReviewWindow(start: Self.now.addingTimeInterval(-604_800), end: Self.now),
            sections: [
                ReviewSection(id: "fading", title: "review.section.fading", items: [],
                              notice: "moot_lens_theme_weather: theme_weather: 0 result(s)"),
            ])
        #expect(empty.isEmpty)
        #expect(empty.itemCount == 0)
        #expect(empty.contributingSurfaces.isEmpty)

        let data = try ReviewReport.makeEncoder().encode(empty)
        let decoded = try ReviewReport.makeDecoder().decode(ReviewReport.self, from: data)
        #expect(decoded == empty)
    }

    @Test("dates encode as ISO8601 text, never an epoch number")
    func datesEncodeAsISO8601() throws {
        let data = try ReviewReport.makeEncoder().encode(Self.sampleReport())
        let json = try #require(String(data: data, encoding: .utf8))
        // The substrate's date convention is TEXT/ISO8601; a default encoder
        // would emit 774113600-style doubles here and break the Rust consumer.
        #expect(json.contains("\"generatedAt\":\"2026-07-13T15:33:20Z\""))
        #expect(!json.contains("1783956800"))
    }

    @Test("dates encode at whole-second resolution — sub-second input is lossy")
    func subSecondInstantsAreTruncated() throws {
        // Documented contract, pinned here so it is a decision and not a surprise:
        // a report built with a fractional instant does not round-trip identically.
        // Callers needing identity (diffing, cache keys) pass a whole-second `now`;
        // every instant ReviewSchedule emits already is one.
        let fractional = Date(timeIntervalSince1970: 1_783_956_800.75)
        let report = ReviewReport(
            kind: .dashboard, generatedAt: fractional,
            window: .unbounded(endingAt: fractional), sections: [])
        let data = try ReviewReport.makeEncoder().encode(report)
        let decoded = try ReviewReport.makeDecoder().decode(ReviewReport.self, from: data)
        #expect(decoded != report)
        #expect(decoded.generatedAt == Date(timeIntervalSince1970: 1_783_956_800))

        // Whole-second instants do round-trip identically.
        let whole = ReviewReport(
            kind: .dashboard, generatedAt: Self.now,
            window: .unbounded(endingAt: Self.now), sections: [])
        let wholeData = try ReviewReport.makeEncoder().encode(whole)
        let wholeDecoded = try ReviewReport.makeDecoder().decode(ReviewReport.self, from: wholeData)
        #expect(wholeDecoded == whole)
    }

    @Test("encoding is byte-stable for the same input")
    func encodingIsByteStable() throws {
        let encoder = ReviewReport.makeEncoder()
        let first = try encoder.encode(Self.sampleReport())
        let second = try encoder.encode(Self.sampleReport())
        #expect(first == second)
    }

    @Test("surface raw values are the exact registered ARIA tool names")
    func surfaceRawValuesMatchToolNames() {
        // A rename here is a runtime tool-not-found, so the names are pinned.
        #expect(ReviewSurface.themeWeather.rawValue == "moot_lens_theme_weather")
        #expect(ReviewSurface.contradiction.rawValue == "moot_lens_contradiction")
        #expect(ReviewSurface.keystones.rawValue == "moot_lens_keystones")
        #expect(ReviewSurface.drift.rawValue == "moot_lens_drift")
        #expect(ReviewSurface.cohesion.rawValue == "moot_lens_cohesion")
        #expect(ReviewSurface.memorySearch.rawValue == "moot_memory_search")
        #expect(ReviewSurface.factSearch.rawValue == "moot_fact_search")
        #expect(ReviewSurface.journal.rawValue == "moot_read_journal")
        #expect(ReviewSurface.allCases.count == 8)
    }

    @Test("no surface is a mutation verb")
    func surfacesAreReadOnly() {
        // The Review module's read-only guarantee is structural: it can only name
        // tools that exist in this enum.
        let mutationVerbs: Set<String> = [
            "moot_file_memory", "moot_file_fact", "moot_update_memory",
            "moot_retire_fact", "moot_withdraw_memory", "moot_move_memory",
            "moot_link_memories", "moot_write_journal", "moot_review_tunnel",
            "moot_distill", "moot_reindex", "moot_run_migration",
        ]
        for surface in ReviewSurface.allCases {
            #expect(!mutationVerbs.contains(surface.rawValue))
        }
    }

    @Test("review kind raw values are stable wire identifiers")
    func kindRawValues() {
        #expect(ReviewKind.dashboard.rawValue == "dashboard")
        #expect(ReviewKind.morning.rawValue == "morning")
        #expect(ReviewKind.endOfDay.rawValue == "endOfDay")
        #expect(ReviewKind.weekly.rawValue == "weekly")
        #expect(ReviewKind.allCases.count == 4)
    }

    @Test("item id falls back to the ordinal when the surface names no row")
    func itemIDFallsBackToOrdinal() {
        #expect(ReviewItem.makeID(surface: .drift, subjectID: nil, ordinal: 2)
                == "moot_lens_drift:2")
        #expect(ReviewItem.makeID(surface: .keystones, subjectID: "ABC", ordinal: 2)
                == "moot_lens_keystones:ABC")
    }

    @Test("contributingSurfaces reports every surface that produced an item")
    func contributingSurfaces() {
        let report = ReviewReport(
            kind: .morning, generatedAt: Self.now,
            window: .unbounded(endingAt: Self.now),
            sections: [
                ReviewSection(id: "a", title: "a", items: [Self.sampleItem()]),
                ReviewSection(id: "b", title: "b", items: [
                    ReviewItem(
                        id: "moot_read_journal:0", title: "2026-07-13T15:00:00Z",
                        detail: "did a thing",
                        provenance: ReviewProvenance(surface: .journal, responseLine: "x")),
                ]),
                ReviewSection(id: "c", title: "c", items: [], notice: "empty"),
            ])
        // Declaration order, not encounter order.
        #expect(report.contributingSurfaces == [.themeWeather, .journal])
        #expect(report.itemCount == 2)
        #expect(!report.isEmpty)
    }

    @Test("item status models proposed findings without a boolean flag")
    func itemStatus() {
        #expect(ReviewItemStatus.recorded.rawValue == "recorded")
        #expect(ReviewItemStatus.proposed.rawValue == "proposed")
        #expect(ReviewItemStatus.allCases.count == 2)
    }
}
