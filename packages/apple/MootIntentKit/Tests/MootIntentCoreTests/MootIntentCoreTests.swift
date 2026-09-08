import AriaMCP
import Foundation
import Testing
@testable import MootIntentCore

@Suite("Community intent core")
struct MootIntentCoreTests {
    @Test("capture subjects normalize caller text and derive a bounded fallback")
    func captureSubjectPolicy() {
        #expect(CaptureSubject.resolve(supplied: "  A\nsubject  ", body: "ignored") == "A subject")

        let derived = CaptureSubject.resolve(
            supplied: nil,
            body: "This is the first complete sentence. A second sentence must not appear.")
        #expect(derived == "This is the first complete sentence.")
        #expect(derived.count <= CaptureSubject.maxLength)
    }

    @Test("structured recall accepts rows with their own text and rejects opaque id-only rows")
    func structuredRecallPolicy() {
        let structured: JSONValue = .object([
            "results": .array([
                // A search row: subject, best span, room; no body (spec § 8.3).
                .object([
                    "id": .string("drawer-1"),
                    "subject": .string("Public subject"),
                    "bestSpan": .string("the best span of the body"),
                    "room": .string("notes"),
                    "eventTime": .string("2026-01-01T00:00:00Z"),
                    "score": .double(0.5),
                ]),
                // A memory-get row: body present, no room resolved.
                .object([
                    "id": .string("drawer-2"),
                    "subject": .string("Read back"),
                    "content": .string("Public content"),
                ]),
                // A gated row: id only.
                .object([
                    "id": .string("opaque-drawer"),
                ]),
                // A redacted search row keeps the server's marker as its text.
                .object([
                    "id": .string("drawer-3"),
                    "subject": .string("[restricted]"),
                ]),
            ]),
        ])

        let drawers = StructuredRecallResults.drawers(from: structured)
        #expect(drawers == [
            RecalledDrawer(id: "drawer-1", subject: "Public subject", bestSpan: "the best span of the body", room: "notes"),
            RecalledDrawer(id: "drawer-2", subject: "Read back", content: "Public content"),
            RecalledDrawer(id: "drawer-3", subject: "[restricted]"),
        ])
        #expect(drawers.map(\.excerpt) == ["the best span of the body", "Public content", "[restricted]"])
    }

    @Test("widget snapshots persist through the Community projection store")
    func widgetSnapshotRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moot-intent-core-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try WidgetSnapshotStore(directory: directory)
        let timestamp = Date(timeIntervalSince1970: 123)
        let snapshot = WidgetSnapshot.from(
            drawers: [RecalledDrawer(id: "drawer-1", subject: "Remember this", room: "notes")],
            updatedAt: timestamp)
        try store.write(snapshot)

        #expect(store.read() == snapshot)
    }
}
