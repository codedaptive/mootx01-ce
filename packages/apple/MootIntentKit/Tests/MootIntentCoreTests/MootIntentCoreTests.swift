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

    @Test("structured recall accepts complete rows and rejects opaque rows")
    func structuredRecallPolicy() {
        let structured: JSONValue = .object([
            "results": .array([
                .object([
                    "id": .string("drawer-1"),
                    "room": .string("notes"),
                    "content": .string("Public content"),
                ]),
                .object([
                    "id": .string("opaque-drawer"),
                    "subject": .string("Restricted"),
                ]),
            ]),
        ])

        #expect(StructuredRecallResults.drawers(from: structured) == [
            RecalledDrawer(id: "drawer-1", content: "Public content", room: "notes"),
        ])
    }

    @Test("widget snapshots persist through the Community projection store")
    func widgetSnapshotRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moot-intent-core-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try WidgetSnapshotStore(directory: directory)
        let timestamp = Date(timeIntervalSince1970: 123)
        let snapshot = WidgetSnapshot.from(
            drawers: [RecalledDrawer(id: "drawer-1", content: "Remember this", room: "notes")],
            updatedAt: timestamp)
        try store.write(snapshot)

        #expect(store.read() == snapshot)
    }
}
