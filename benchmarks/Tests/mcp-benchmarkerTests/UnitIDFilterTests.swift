import Foundation
import Testing
@testable import mcp_benchmarker

@Suite("UnitIDFilter — --ids pinned debug subsets")
struct UnitIDFilterTests {

    private func tempFile(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ids-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("loadUnitIDs skips blanks and comments, trims whitespace")
    func loadSkipsBlanksAndComments() throws {
        let path = try tempFile("# pinned subset\n a1 \n\nb2\n#c3\n")
        let ids = try loadUnitIDs(path)
        #expect(ids == Set(["a1", "b2"]))
    }

    @Test("loadUnitIDs throws on a missing file")
    func loadThrowsOnMissingFile() {
        #expect(throws: (any Error).self) {
            _ = try loadUnitIDs("/nonexistent/ids.txt")
        }
    }

    @Test("loadUnitIDs throws on a file with no ids")
    func loadThrowsOnEmpty() throws {
        let path = try tempFile("# only comments\n\n")
        #expect(throws: (any Error).self) {
            _ = try loadUnitIDs(path)
        }
    }

    @Test("filterUnits keeps exactly the requested units")
    func filterKeepsRequested() throws {
        let units = ["q1", "q2", "q3", "q4"]
        let out = try filterUnits(units, ids: Set(["q2", "q4"]), id: { $0 }, lane: "t")
        #expect(out == ["q2", "q4"])
    }

    @Test("filterUnits passes everything through when ids is nil")
    func filterNilPassthrough() throws {
        let units = ["q1", "q2"]
        let out = try filterUnits(units, ids: nil, id: { $0 }, lane: "t")
        #expect(out == units)
    }

    @Test("filterUnits fails loud when a requested id is absent")
    func filterFailsLoudOnMissing() {
        #expect(throws: (any Error).self) {
            _ = try filterUnits(["q1"], ids: Set(["q1", "zz"]), id: { $0 }, lane: "t")
        }
    }

    // MARK: normalizeUnitID — item (c) gate

    // Three cases. A normaliser that strips too much (e.g. also eating the
    // "scene_" prefix) passes a one-case test; all three together discriminate.

    @Test("normalizeUnitID strips evidence prefix from stem-form id")
    func normalizeStripsPrefix() {
        // "ET1__scene_3_q_7" → "scene_3_q_7"
        // Fails if the prefix stripping is absent, broken, or over-strips.
        #expect(normalizeUnitID("ET1__scene_3_q_7") == "scene_3_q_7")
    }

    @Test("normalizeUnitID returns bare id unchanged")
    func normalizeBarePassthrough() {
        // "scene_3_q_7" → "scene_3_q_7" — no prefix, must not be modified.
        #expect(normalizeUnitID("scene_3_q_7") == "scene_3_q_7")
    }

    @Test("normalizeUnitID returns an id with no __scene_ marker unchanged")
    func normalizeNoSceneMarkerPassthrough() {
        // "some_other_id" has no "__scene_" substring; must be returned as-is.
        #expect(normalizeUnitID("some_other_id") == "some_other_id")
    }
}
