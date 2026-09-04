import Foundation
import EventKit          // Apple's framework for reading/writing Calendar data.
import MootGateway       // MootBridge, GatewayRuntime — the MOOT seam.
import AriaMCP           // JSONValue — every MOOT tool argument is a JSONValue.

// MARK: - CalendarRow
//
// A tiny, display-only struct for one calendar event in our list. We keep our
// OWN lightweight copy (id + title + time range) rather than holding onto live
// EKEvent objects in the UI — EKEvents belong to Calendar's store, and copying
// out the few fields we render keeps the UI simple and Sendable-friendly.
struct CalendarRow: Identifiable, Sendable {
    let id: String        // EKEvent.eventIdentifier — Calendar's stable id.
    let title: String
    let start: Date
    let end: Date

    /// One line of MOOT content for this event, e.g.
    /// "Team standup — Jun 9, 9:00 AM – Jun 9, 9:30 AM".
    /// This is EXACTLY the text we file into the MOOT as a drawer's content.
    var mootContent: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return "\(title) — \(df.string(from: start)) – \(df.string(from: end))"
    }
}

// MARK: - CalendarIngestModel
//
// The whole example lives here. Two sides meet in this one type:
//
//   LEFT  — EventKit. We READ Apple Calendar (request access, query THIS WEEK's
//           events across all calendars). We never change a real user event;
//           the only events we ever WRITE are the optional "seed sample events"
//           the demo creates so the simulator has something to show.
//
//   RIGHT — MootGateway. We WRITE each event into the MOOT via the ARIA tool
//           `moot_file_memory`, and we READ the MOOT back via `moot_memory_search`
//           plus `moot_memory_get` for the bodies.
//
// The bridge between them is the loop in `syncThisWeekToMoot()`: for each event
// EventKit hands us, we call one MOOT tool. That is the entire "give a legacy
// app a memory" trick.
//
// @MainActor: this is a SwiftUI ObservableObject driving UI, so all its mutable
// state is main-actor isolated (Swift 6 strict concurrency).
@MainActor
final class CalendarIngestModel: ObservableObject {

    // MARK: Published UI state

    /// This week's events, as read from Calendar. Drives the events list.
    @Published var events: [CalendarRow] = []

    /// How many events were written into the MOOT by the last sync.
    @Published var writtenCount: Int = 0

    /// The text the user typed into the "Search memory" box.
    @Published var searchQuery: String = ""

    /// The MOOT's textual answer to the last search (we render it verbatim —
    /// see the "tool results are text" note below).
    @Published var searchResult: String = ""

    /// Human-readable status line (permissions, errors, progress).
    @Published var status: String = "Starting up…"

    /// Whether Calendar access has been granted. Until true, the read buttons
    /// have nothing to read.
    @Published var hasCalendarAccess: Bool = false

    // MARK: Private state

    /// EventKit's handle to the Calendar database. ONE store, reused. Creating
    /// an EKEventStore does NOT prompt for permission — only the explicit
    /// request call below does.
    private let eventStore = EKEventStore()

    /// The MOOT seam. We fetch it once from GatewayRuntime.shared (configured at
    /// app launch) and hold it. nil until `attach()` runs.
    private var bridge: MootBridge?

    // MARK: MOOT attach

    /// Pull the shared bridge. The App already called
    /// GatewayRuntime.shared.configure(databaseURL:) at launch, so this lands on
    /// the durable SQLite estate.
    func attach() async {
        do {
            bridge = try await GatewayRuntime.shared.bridge()
            status = "MOOT attached. Grant calendar access to begin."
        } catch {
            status = "Could not attach MOOT: \(error.localizedDescription)"
        }
    }

    // MARK: Sample MOOT data (so the app is not empty on first run)

    /// Seed approach: on first launch the MOOT is empty. We ask the MOOT for any
    /// memory; if it answers with no rows, we file two sample drawers so the Search
    /// box finds something before the user has synced any real events. A real
    /// app would NOT seed fake memories — this is purely demo convenience.
    func seedSampleMemoriesIfEmpty() async {
        guard let bridge else { return }

        // An empty estate answers with an empty `results` array in the
        // structured block; that decides whether to seed.
        let probe = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string("calendar"),
            // JSONValue's integer case is `.integer(Int64)` (there is no
            // `.number`); the MOOT tool surface reads `limit` as an integer.
            "limit": .integer(1)
        ])
        guard resultRows(in: probe.structured).isEmpty else { return }  // already has data

        // File two starter drawers in the "calendar" room — the same room our
        // real ingested events will land in — so search results look coherent.
        for sample in [
            "Welcome — file this week's events into your MOOT with the Sync button.",
            "Tip — after syncing, search 'standup' or 'lunch' to recall an event."
        ] {
            _ = await bridge.callTool("moot_file_memory", arguments: [
                "content": .string(sample),
                "location": .string("calendar")
            ])
        }
        status = "Seeded sample memories. Grant calendar access to ingest real events."
    }

    // MARK: EventKit — request access (full: reads real events + writes demo seed)

    /// Ask iOS for permission to read Calendar. EXPLAIN: merely having an
    /// EKEventStore grants nothing — this call is what triggers the system
    /// permission alert (with our NSCalendarsUsageDescription string). We request
    /// FULL access because we both read events and (for the demo seed only) write
    /// sample events. Real user events are never altered.
    func requestCalendarAccess() async {
        do {
            // requestFullAccessToEvents is the iOS 17+ API. It returns true once
            // the user taps Allow.
            let granted = try await eventStore.requestFullAccessToEvents()
            hasCalendarAccess = granted
            status = granted
                ? "Calendar access granted. Load this week's events."
                : "Calendar access denied. Enable it in Settings to ingest events."
        } catch {
            hasCalendarAccess = false
            status = "Calendar access error: \(error.localizedDescription)"
        }
    }

    // MARK: EventKit — read THIS WEEK's events (read-only)

    /// Read every event in the current week, across ALL calendars. This is a
    /// pure READ of Calendar — we build a date predicate and ask the store to
    /// match it. Calendar is untouched.
    func loadThisWeek() {
        guard hasCalendarAccess else {
            status = "Grant calendar access first."
            return
        }

        // 1. Compute the week's bounds with the user's calendar (respects their
        //    locale's first-day-of-week). startOfWeek → 7 days later.
        let cal = Calendar.current
        let now = Date()
        guard let weekInterval = cal.dateInterval(of: .weekOfYear, for: now) else {
            status = "Could not compute this week's date range."
            return
        }
        let weekStart = weekInterval.start
        let weekEnd = weekInterval.end

        // 2. Build EventKit's query predicate. `calendars: nil` means "all
        //    calendars." This object describes WHICH events to read — it does
        //    not modify anything.
        let predicate = eventStore.predicateForEvents(
            withStart: weekStart,
            end: weekEnd,
            calendars: nil
        )

        // 3. Run the read. events(matching:) returns Calendar's events for the
        //    range. Still read-only.
        let ekEvents = eventStore.events(matching: predicate)

        // 4. Copy out the few fields we display into our own Sendable rows,
        //    sorted by start time. We do not hold EKEvents in the UI.
        events = ekEvents
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .map { ek in
                CalendarRow(
                    id: ek.eventIdentifier ?? UUID().uuidString,
                    title: ek.title ?? "(untitled event)",
                    start: ek.startDate ?? now,
                    end: ek.endDate ?? now
                )
            }

        status = events.isEmpty
            ? "No events this week. Try 'Seed sample events' to create some."
            : "Loaded \(events.count) event(s) this week."
    }

    // MARK: EventKit — seed sample EVENTS (the only writes we make to Calendar)

    /// Create 3 EKEvents this week in the default calendar so the demo has data
    /// (the simulator's Calendar is empty). This is the ONE place we write to
    /// Calendar, and it exists only because there is nothing to read otherwise.
    /// It does NOT modify any existing event — it adds three clearly-labeled
    /// demo events. We then reload so they appear in the list.
    func seedSampleCalendarEvents() {
        guard hasCalendarAccess else {
            status = "Grant calendar access first."
            return
        }

        let cal = Calendar.current
        let now = Date()
        // Anchor the samples at the start of today so they fall inside this week.
        let dayStart = cal.startOfDay(for: now)

        // (title, hoursFromDayStart, durationMinutes)
        let samples: [(String, Int, Int)] = [
            ("Team standup", 9, 30),
            ("Lunch with Pat", 12, 60),
            ("Design review", 15, 45)
        ]

        for (title, hour, minutes) in samples {
            // EKEvent.init(eventStore:) makes a NEW, unsaved event tied to the
            // store. Setting its fields and saving is how EventKit writes.
            let event = EKEvent(eventStore: eventStore)
            event.title = title
            event.startDate = cal.date(byAdding: .hour, value: hour, to: dayStart) ?? now
            event.endDate = cal.date(byAdding: .minute, value: minutes, to: event.startDate) ?? now
            // Write to the user's DEFAULT calendar.
            event.calendar = eventStore.defaultCalendarForNewEvents

            do {
                // save(_:span:commit:) persists the new event. span:.thisEvent
                // because these are single (non-recurring) events.
                try eventStore.save(event, span: .thisEvent, commit: true)
            } catch {
                status = "Could not create sample event '\(title)': \(error.localizedDescription)"
                return
            }
        }

        status = "Created 3 sample events. Loading…"
        loadThisWeek()   // refresh the list so the new events show up.
    }

    // MARK: THE BRIDGE — write this week's events into the MOOT

    /// The core demonstration: for EACH event we read from Calendar, file one
    /// drawer into the MOOT via the ARIA tool `moot_file_memory`. The drawer's
    /// `content` is the event's one-line description; its `location` (room) is
    /// "calendar" so all ingested events live together and are easy to recall.
    ///
    /// Calendar is NOT changed by this — we only read it (in loadThisWeek) and
    /// write into the MOOT here. This is "giving a legacy app a memory": the
    /// memory lives in the MOOT, not in Calendar.
    func syncThisWeekToMoot() async {
        guard let bridge else {
            status = "MOOT not attached yet."
            return
        }
        guard !events.isEmpty else {
            status = "No events loaded. Load this week first."
            return
        }

        var written = 0
        for row in events {
            // ONE MOOT call per event. moot_file_memory files a verbatim drawer.
            // It returns TEXT like "filed memory <id>\nroom: calendar\nlineage: …";
            // we only need to know it did not error.
            let call = await bridge.callTool("moot_file_memory", arguments: [
                "content": .string(row.mootContent),     // the event line
                "location": .string("calendar")           // the room it files into
            ])
            if !call.isError {
                written += 1
            }
        }

        writtenCount = written
        status = "Filed \(written) of \(events.count) event(s) into the MOOT (room: calendar)."
    }

    // MARK: READ the MOOT back — prove the events are now searchable

    /// Search the MOOT and show the result. This proves the ingested calendar
    /// events became real, searchable MOOT memories.
    ///
    /// THE RESULT CONTRACT (important for SDK readers): every recall tool
    /// answers with text for people AND a `structuredContent` block,
    /// `{ "results": [ { "id", "room", "subject", "content" }, … ] }`, exposed
    /// as `IntentCallResult.structured`. Search rows are travel rows with no
    /// body, so we collect their ids and fetch the bodies with one batched
    /// `moot_memory_get` at depth:full, then render one line per drawer.
    func searchMemory() async {
        guard let bridge else {
            status = "MOOT not attached yet."
            return
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResult = "Type something to search for."
            return
        }

        let search = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string(q)
        ])
        if search.isError {
            searchResult = "Search failed: \(search.text)"
            return
        }
        let ids: [JSONValue] = resultRows(in: search.structured).compactMap { row in
            if case let .string(id)? = row["id"] { return .string(id) }
            return nil
        }
        guard !ids.isEmpty else {
            searchResult = "No memories matched \"\(q)\"."
            return
        }
        let get = await bridge.callTool("moot_memory_get", arguments: [
            "ids": .array(ids),
            "depth": .string("full"),
        ])
        if get.isError {
            searchResult = "Recall failed: \(get.text)"
            return
        }
        let lines: [String] = resultRows(in: get.structured).compactMap { row in
            guard case let .string(content)? = row["content"] else { return nil }
            if case let .string(room)? = row["room"] { return "[\(room)] \(content)" }
            return content
        }
        searchResult = lines.joined(separator: "\n")
    }

    /// Every result row of a recall tool's `structuredContent` block as a
    /// dictionary, or [] when the tool sent no block. Optional fields are
    /// ABSENT (never null) when the tool has nothing to say.
    private func resultRows(in structured: JSONValue?) -> [[String: JSONValue]] {
        guard case let .object(top)? = structured,
              case let .array(items)? = top["results"] else { return [] }
        return items.compactMap { item in
            if case let .object(row) = item { return row }
            return nil
        }
    }
}
