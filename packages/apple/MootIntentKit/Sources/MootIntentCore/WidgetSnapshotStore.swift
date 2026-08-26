import Foundation

// MARK: - WidgetSnapshot / WidgetSnapshotStore  (recall widget projection)
//
// The recall widget runs in its own process and must never open the estate
// (one estate, one host). Like Core Spotlight donation, the widget
// renders a DERIVED PROJECTION, never canonical storage: the app writes this
// snapshot from a publicOnly recall (`filter:exportable` — the same §6.2
// export gate Spotlight uses), so only explicitly public drawers can appear
// on the home screen / desktop. The widget's TimelineProvider only reads.
//
// One JSON file in the app-group container, written atomically. A corrupt or
// absent file reads as nil — the widget then shows its empty state; it never
// crashes and never falls back to touching the estate.

/// What the recall widget renders: the most recent public drawers.
public struct WidgetSnapshot: Codable, Sendable, Equatable {

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        /// Drawer id — stable, same id recall/Spotlight/Shortcuts use.
        public let id: String
        /// Content preview (recall returns up to 120 chars; the widget view
        /// truncates further as the family size requires).
        public let content: String
        /// The drawer's room, shown as the entry's caption.
        public let room: String

        public init(id: String, content: String, room: String) {
            self.id = id
            self.content = content
            self.room = room
        }
    }

    public let entries: [Entry]
    /// When the app last refreshed the projection.
    public let updatedAt: Date

    public init(entries: [Entry], updatedAt: Date) {
        self.entries = entries
        self.updatedAt = updatedAt
    }

    /// Project recall results (already export-gated by the caller) into
    /// snapshot entries, preserving recall order.
    public static func from(drawers: [RecalledDrawer], updatedAt: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            entries: drawers.map { Entry(id: $0.id, content: $0.content, room: $0.room) },
            updatedAt: updatedAt)
    }
}

public struct WidgetSnapshotStore: Sendable {

    /// The snapshot file. Lives beside (not inside) the ShareInbox spool.
    public let fileURL: URL

    /// Open (creating the directory if needed) a store rooted at an explicit
    /// directory. Tests use temp directories; production uses `groupStore()`.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("WidgetSnapshot.json")
    }

    /// The production store in the app-group container. Fails explicitly
    /// when the group container is unavailable (same posture as the spool).
    public static func groupStore() throws -> WidgetSnapshotStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ShareInboxSpool.appGroupID) else {
            throw ShareInboxSpool.SpoolError.groupContainerUnavailable(ShareInboxSpool.appGroupID)
        }
        return try WidgetSnapshotStore(
            directory: container.appendingPathComponent("WidgetProjection", isDirectory: true))
    }

    /// Atomic write so the widget process never reads a half-written file.
    public func write(_ snapshot: WidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    /// nil on absent or undecodable snapshot — the widget's empty state.
    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
