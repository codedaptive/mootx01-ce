import WidgetKit
import SwiftUI
import MootIntentKit

// MARK: - MootRecallWidget  (Tier 3 — recall on the home screen / desktop)
//
// Renders the derived projection the app maintains in the app-group
// container (WidgetSnapshotStore). This process never opens the estate —
// see the store's header for the one-estate-one-host rationale and the
// export gate (only explicitly public drawers can be in the projection).

@main
struct MootRecallWidgetBundle: WidgetBundle {
    var body: some Widget {
        MootRecallWidget()
    }
}

struct MootRecallWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MootRecallWidget", provider: SnapshotProvider()) { entry in
            RecallWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(Text(String(localized: "widget.recall.title", defaultValue: "Recent Memories")))
        .description(Text(String(localized: "widget.recall.description", defaultValue: "Your most recent public memories from the MOOT.")))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Timeline

struct SnapshotTimelineEntry: TimelineEntry {
    let date: Date
    let entries: [WidgetSnapshot.Entry]
}

struct SnapshotProvider: TimelineProvider {

    private func currentEntry() -> SnapshotTimelineEntry {
        let snapshot = (try? WidgetSnapshotStore.groupStore())?.read()
        return SnapshotTimelineEntry(
            date: snapshot?.updatedAt ?? Date(),
            entries: snapshot?.entries ?? [])
    }

    func placeholder(in context: Context) -> SnapshotTimelineEntry {
        SnapshotTimelineEntry(date: Date(), entries: [
            .init(id: UUID().uuidString,
                  content: String(localized: "widget.recall.placeholder", defaultValue: "A memory you filed"),
                  room: String(localized: "widget.recall.placeholder.room", defaultValue: "workspace")),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotTimelineEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotTimelineEntry>) -> Void) {
        // The app pushes reloads on every projection refresh; the 30-minute
        // re-read is only a backstop for a stale timeline after reboot.
        completion(Timeline(
            entries: [currentEntry()],
            policy: .after(Date(timeIntervalSinceNow: 30 * 60))))
    }
}

// MARK: - View

struct RecallWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotTimelineEntry

    private var visibleEntries: [WidgetSnapshot.Entry] {
        Array(entry.entries.prefix(family == .systemSmall ? 2 : 4))
    }

    var body: some View {
        if visibleEntries.isEmpty {
            Text(String(localized: "widget.recall.empty",
                        defaultValue: "No public memories yet. Mark a capture public to see it here."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleEntries) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.content)
                            .font(.caption)
                            .lineLimit(family == .systemSmall ? 2 : 1)
                        Text(item.room)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
