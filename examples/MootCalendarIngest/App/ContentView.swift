import SwiftUI

// MARK: - ContentView
//
// The UI for MootCalendarIngest. Deliberately small — the teaching value is in
// CalendarIngestModel.swift (where EventKit meets the MOOT). This view just
// wires buttons and fields to the model's methods and shows the results.
//
// The flow a developer reads top-to-bottom on screen mirrors the demo:
//   1. Grant Calendar access (EventKit READ permission).
//   2. (Simulator only) Seed sample EVENTS into Calendar so there is data.
//   3. Load this week's events (a pure READ of Calendar).
//   4. Sync them into the MOOT (one moot_file_memory call per event).
//   5. Search the MOOT to prove the events are now searchable memories.
//
// @MainActor because it drives UI and calls into the @MainActor model.
@MainActor
struct ContentView: View {

    // The shared model, injected by the App via .environmentObject.
    @EnvironmentObject private var model: CalendarIngestModel

    var body: some View {
        NavigationStack {
            // Use a Form for the platform-standard grouped layout. All padding
            // uses semantic .leading (never .left) per layout-direction rules.
            Form {
                // Status line — always visible so the reader can follow state.
                Section {
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // STEP 1 + 2 — permission + (simulator) sample events.
                Section(String(localized: "Calendar (legacy app — we only read it)")) {
                    Button(String(localized: "Grant calendar access")) {
                        Task { await model.requestCalendarAccess() }
                    }

                    // Simulator's Calendar is empty; this creates 3 demo events
                    // so steps 3–5 have data. The ONLY write we make to Calendar.
                    Button(String(localized: "Seed sample events")) {
                        model.seedSampleCalendarEvents()
                    }
                    .disabled(!model.hasCalendarAccess)

                    // STEP 3 — read this week's events (read-only).
                    Button(String(localized: "Load this week's events")) {
                        model.loadThisWeek()
                    }
                    .disabled(!model.hasCalendarAccess)
                }

                // The events list, with a live count.
                Section(String(localized: "This week (\(model.events.count) event(s))")) {
                    if model.events.isEmpty {
                        Text(String(localized: "No events loaded yet."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.events) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.body)
                                Text(row.mootContent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // STEP 4 — the bridge: write each event into the MOOT.
                Section(String(localized: "Ingest into MOOT")) {
                    Button(String(localized: "Sync this week to MOOT")) {
                        Task { await model.syncThisWeekToMoot() }
                    }
                    .disabled(model.events.isEmpty)

                    if model.writtenCount > 0 {
                        Text(String(localized: "Last sync filed \(model.writtenCount) event(s) into the MOOT."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // STEP 5 — read the MOOT back; the events are now searchable.
                Section(String(localized: "Search memory (read the MOOT back)")) {
                    HStack {
                        TextField(String(localized: "e.g. standup, lunch"), text: $model.searchQuery)
                            .textFieldStyle(.roundedBorder)
                        Button(String(localized: "Search")) {
                            Task { await model.searchMemory() }
                        }
                    }
                    if !model.searchResult.isEmpty {
                        // The MOOT answers in TEXT (see the "tool results are
                        // text" note in the model). We render it verbatim, with a
                        // monospaced font so the "<id> [room] <preview>" lines
                        // line up.
                        Text(model.searchResult)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(String(localized: "MootCalendarIngest"))
        }
    }
}
