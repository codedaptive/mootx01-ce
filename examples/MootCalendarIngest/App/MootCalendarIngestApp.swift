import SwiftUI
import MootGateway   // MootBridge, GatewayRuntime — the MOOT seam.
import AriaMCP       // JSONValue — every tool argument is a JSONValue.

// MARK: - MootCalendarIngestApp
//
// THE BIG IDEA of this example:
//
//   Apple Calendar is a "legacy app you cannot change." You do not own its
//   source, you cannot add a MOOT to it, and you would never want to fork it.
//   But it holds valuable data: your events. This app shows how to give that
//   legacy app a MEMORY without touching it at all — we READ its events with
//   EventKit and WRITE them into the MOOT through the MootGateway SDK. Calendar
//   is never modified. Not one byte. We are a polite reader, nothing more.
//
// THE WIRING (this file's job):
//
//   1. Pick ONE durable SQLite file in the app sandbox to hold the MOOT.
//   2. Tell `GatewayRuntime.shared` to use that file. The runtime is the
//      process-wide holder of the single MootBridge. Both this app's UI AND any
//      App Intents (Siri/Shortcuts) pull their bridge from this same runtime,
//      so they all read and write the SAME estate.
//   3. On first launch, SEED a couple of sample MOOT drawers so the app is not
//      empty out of the box (the simulator's MOOT starts blank).
//
// Everything that actually talks to Calendar lives in CalendarIngestModel.swift.

@main
struct MootCalendarIngestApp: App {

    // The model owns all MOOT + Calendar state. @StateObject so SwiftUI keeps
    // one instance alive for the whole app lifetime.
    @StateObject private var model = CalendarIngestModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    // .task runs once when the view first appears — our app-launch
                    // hook. We do the MOOT wiring here because it is async.
                    await configureMootAndSeed()
                }
        }
    }

    /// The MOOT path: a `.sqlite` file inside the app's Application Support
    /// directory. This is durable (survives relaunch) and inside the sandbox.
    /// MootBridge.attachSQLite auto-creates parent directories, so we do not
    /// have to mkdir anything ourselves.
    private static func mootDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base
            .appendingPathComponent("MootCalendarIngest", isDirectory: true)
            .appendingPathComponent("moot.sqlite", isDirectory: false)
    }

    /// App-launch MOOT setup, run exactly once per launch.
    @MainActor
    private func configureMootAndSeed() async {
        let url = Self.mootDatabaseURL()

        // STEP 1 — point the shared runtime at our durable estate. Calling
        // configure(databaseURL:) BEFORE anyone asks for a bridge guarantees
        // the first attachment lands on this SQLite file (not an in-memory one).
        // This MUST happen before any App Intent runs so Siri/Shortcuts share
        // the same MOOT as the UI.
        await GatewayRuntime.shared.configure(databaseURL: url)

        // STEP 2 — hand the model the bridge from the shared runtime. The model
        // uses GatewayRuntime.shared.bridge() internally, so it will pick up the
        // exact estate we just configured. We trigger it here so any first-launch
        // attach cost is paid at startup, not on the first button tap.
        await model.attach()

        // STEP 3 — SAMPLE DATA approach. The simulator's MOOT is empty on first
        // run. We do a quick search; if the MOOT reports "found 0", we file two
        // sample drawers so the "Search memory" box has something to find before
        // the user has synced any real calendar events. This is purely demo
        // convenience — a real app would not seed fake memories.
        await model.seedSampleMemoriesIfEmpty()
    }
}
