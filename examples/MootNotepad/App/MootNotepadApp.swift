import SwiftUI
import MootGateway   // MootBridge, GatewayRuntime, GatewayCall — the MOOT seam.

// =============================================================================
// MootNotepad — a tiny notes app whose ENTIRE backing store is a MOOT estate.
// =============================================================================
//
// WHAT THIS EXAMPLE TEACHES
// -------------------------
// This is the "build a brand-new app ON TOP OF MOOT" example. There is no
// Core Data, no SwiftData, no JSON file, no array-in-UserDefaults. Every note
// you see is a *drawer* filed into the MOOT, and every list you render is the
// result of asking the MOOT to recall those drawers. MOOT is the database.
//
// The whole app talks to the MOOT through exactly one object: a `MootBridge`.
// The bridge exposes the ARIA tool surface — a set of `moot_*` "tools" you
// call by name with JSON arguments. We use four of them in this app:
//
//   moot_file_memory      — create a note (file a drawer into a room)
//   moot_memory_search    — list/search notes (recall drawers as text)
//   moot_withdraw_memory  — delete a note (retire a drawer)
//   moot_estate_status    — a human-readable summary of the whole estate
//
// HOW THE PIECES FIT TOGETHER (read this once and the rest is obvious)
// --------------------------------------------------------------------
//   * MootNotepadApp (this file): on launch we point the process-wide
//     `GatewayRuntime` at a durable SQLite file inside the app sandbox, then
//     hand the same bridge to the UI. Sharing ONE bridge means the UI and the
//     App Intents (Siri / Shortcuts) read and write the SAME notes.
//   * NotepadModel (NotepadView.swift): the @MainActor view-model. Every method
//     on it is a thin wrapper that calls the bridge and turns the result into
//     SwiftUI state. This is where the MOOT calls actually happen.
//   * NotepadView (NotepadView.swift): the list + editor UI.
//   * MootNotepadShortcuts (MootNotepadShortcuts.swift): registers the two
//     system App Intents so "Hey Siri, capture this in MootNotepad" works.
//
// THE ONE EDGE YOU MUST UNDERSTAND
// --------------------------------
// The ARIA tool surface answers in TEXT, not in structured note objects.
// `moot_memory_search` returns lines shaped like:
//
//     found 3 memory(s)
//     <id>  [room]  <preview>
//     <id>  [room]  <preview>
//
// So to build a list of note rows, we PARSE those lines (see Note.parse in
// NotepadView.swift). A production app would prefer a structured recall tool
// that returns real drawer objects; until that exists, text parsing is the
// documented integration approach. We flag this everywhere it bites us with
// a // NOTE(integrate): comment.
//
// PLATFORMS: universal — the same SwiftUI code compiles for iOS and macOS.

@main
struct MootNotepadApp: App {

    // The view-model is created once and owned by the app. It is @MainActor
    // (declared in NotepadView.swift) so all UI state mutations are main-thread
    // safe under Swift 6's strict concurrency checking.
    @State private var model = NotepadModel()

    var body: some Scene {
        WindowGroup {
            NotepadView(model: model)
                // `.task` runs once when the view first appears. We do the
                // MOOT wiring here rather than in `init` because attaching the
                // estate is async (it opens SQLite, installs the schema, builds
                // the ARIA dispatcher) and `init` cannot await.
                .task {
                    await bootstrapMOOT()
                }
        }
    }

    // -------------------------------------------------------------------------
    // bootstrapMOOT — the three things every MOOT-backed app does at launch.
    // -------------------------------------------------------------------------
    private func bootstrapMOOT() async {
        // STEP 1 — Decide WHERE the MOOT lives on disk.
        //
        // We put the SQLite file in the app's Application Support directory,
        // which is the standard durable, per-app sandbox location. MootBridge
        // auto-creates any missing parent folders, so we don't have to.
        let dbURL = Self.databaseURL()

        // STEP 2 — Point the process-wide runtime at that file.
        //
        // `GatewayRuntime.shared` is a singleton actor that holds the ONE
        // MootBridge for the whole process. The App Intents (which the *system*
        // instantiates, with no chance to inject a bridge) reach the estate
        // through this same runtime. Configuring it here, before the UI asks
        // for its bridge, guarantees the UI and Siri share one estate.
        await GatewayRuntime.shared.configure(databaseURL: dbURL)

        // STEP 3 — Acquire the bridge and hand it to the UI.
        //
        // `bridge()` lazily attaches the SQLite estate on first call (and
        // returns the cached bridge thereafter). We pass it into the model so
        // every note operation flows through it.
        do {
            let bridge = try await GatewayRuntime.shared.bridge()
            await model.attach(bridge: bridge)
            // Seed sample notes the first time the app ever runs, so the list
            // isn't empty out of the box. (See NotepadModel.seedIfEmpty.)
            await model.seedIfEmpty()
            // Load the notes into the list.
            await model.refresh()
        } catch {
            // If attachment fails (e.g. disk is unwritable), surface it in the
            // UI rather than crashing — the model holds a `lastError` banner.
            await model.report(error: error)
        }
    }

    /// The durable location of this app's MOOT, inside the sandbox.
    ///
    /// We use Application Support (not Documents) because the estate is app
    /// data, not user documents the person should see in a Files browser.
    private static func databaseURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        // One subfolder keeps the .sqlite (and any SQLite sidecar files like
        // -wal / -shm) tidy and easy to delete to "reset" the app.
        return base
            .appendingPathComponent("MootNotepad", isDirectory: true)
            .appendingPathComponent("notepad.sqlite")
    }
}
