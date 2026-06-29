import SwiftUI
import MootGateway   // The MOOTx01 SDK product. Gives us MootBridge, GatewayRuntime,
                     // and (re-exported through the App Intent types) the parallel estate.

// ============================================================================
// MootTodoApp — the SIDECAR pattern, demonstrated end to end.
// ============================================================================
//
// WHAT THIS EXAMPLE TEACHES
// -------------------------
// This is an ordinary to-do app. It has its OWN primary store: a tiny Codable
// JSON file in the app container, driven by a @MainActor @Observable model
// (see TodoModel below). That store is the app's source of truth. It does NOT
// depend on MOOTx01 at all — you could delete every MOOT line and the to-do
// list would still work.
//
// The interesting part is the SIDECAR. Alongside the primary store we run a
// PARALLEL MOOT (a MOOTx01 estate). Every time a todo is added or toggled, we
// ALSO mirror that fact into the MOOT with a single call. The MOOT thus
// accumulates a searchable, full-text memory of everything the app ever did —
// "for free," beside the app, with about five lines of glue.
//
// The payoff: the "Search memory" field at the bottom of the screen queries
// the MOOT (not the primary store) with full-text search. The app gained a
// capability — search across all historical todo state — that its own little
// JSON store never had. That is the whole point of sidecaring a MOOT: you keep
// your existing store, and you get memory as a bolt-on.
//
// HOW MOOTx01 IS WIRED IN (the three touch points)
// -------------------------------------------------
//   1. At launch we point the process-wide GatewayRuntime at a durable SQLite
//      estate (configure(databaseURL:)). Calling bridge() registers the bridge
//      with IntentRuntimeBridge; App Intents resolve through
//      IntentRuntimeBridge.shared.bridge(), so Siri/Shortcuts and our UI share ONE MOOT.
//   2. Our UI gets its bridge from GatewayRuntime.shared.bridge() — NOT a
//      separate attach — so UI writes and intent writes land in the same MOOT.
//   3. We seed sample data on first launch if the MOOT is empty.
//
// Everything MOOT-related funnels through MootBridge.callTool(...), the public
// ARIA tool surface. We never reach around it into the substrate.

@main
struct MootTodoApp: App {

    // The app's primary store. This is the source of truth for the to-do list.
    // It is plain Swift + a JSON file — deliberately dependency-free so the
    // contrast with the MOOT sidecar stays crystal clear.
    @State private var model = TodoModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // .task runs once when the view appears. We use it to do the
                // one-time MOOT wiring: configure the runtime, hand the bridge
                // to the model, and seed sample data if the estate is empty.
                .task {
                    await bootstrapMoot()
                }
        }
        #if os(macOS)
        // A sensible default window size on macOS. Pure cosmetics; nothing to
        // do with MOOTx01.
        .defaultSize(width: 460, height: 640)
        #endif
    }

    // ------------------------------------------------------------------------
    // bootstrapMoot — the launch-time MOOT wiring, in one place.
    // ------------------------------------------------------------------------
    @MainActor
    private func bootstrapMoot() async {
        // STEP 1: Choose a durable on-disk location for the MOOT, inside the
        // app's own sandbox container. We put it under Application Support so
        // it survives launches and is backed up like normal app data.
        // MootBridge.attachSQLite auto-creates parent directories, so we don't
        // have to mkdir by hand.
        let dbURL = MootTodoApp.estateURL()

        // STEP 2: Point the PROCESS-WIDE runtime at that estate. The App
        // Intents (CaptureDrawerIntent / RecallDrawerIntent, registered by
        // MootTodoShortcuts) reach the MOOT through GatewayRuntime.shared too —
        // so configuring it here means Siri, Shortcuts, the Action Button, and
        // our own UI all operate on the SAME estate. configure() is a no-op if
        // something already attached (first attachment wins), which is exactly
        // what we want.
        await GatewayRuntime.shared.configure(databaseURL: dbURL)

        // STEP 3: Get the shared bridge and hand it to our model. From here on
        // the model uses this bridge for every mirror-write and every search.
        // Because we go through GatewayRuntime.shared.bridge() (and NOT a fresh
        // MootBridge.attachSQLite of our own), the UI and the intents literally
        // share one bridge instance over one estate.
        do {
            let bridge = try await GatewayRuntime.shared.bridge()
            model.attach(bridge: bridge)

            // STEP 4: First-launch sample data. Searches for "TODO" with limit 1;
            // if no matching row is found and todos are empty, seeds three sample
            // todos. A MOOT with non-TODO content is not treated as fresh.
            // Seed writes flow through the same add() path as user taps.
            await model.seedSampleDataIfEmpty()
        } catch {
            // If the MOOT fails to attach, the to-do list still works — the
            // sidecar is additive. We surface the error in the model so the UI
            // can show it, but we never block the primary store on it.
            model.recordMootError(error)
        }
    }

    // The on-disk path for the SQLite estate, inside Application Support.
    // Static so it can be reused if needed without an app instance.
    private static func estateURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        // Namespacing under a folder keeps the estate tidy and easy to find.
        return base
            .appendingPathComponent("MootTodo", isDirectory: true)
            .appendingPathComponent("moot.sqlite")
    }
}
