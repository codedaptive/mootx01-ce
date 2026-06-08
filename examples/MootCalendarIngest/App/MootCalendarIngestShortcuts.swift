import AppIntents
import MootGateway   // CaptureDrawerIntent, RecallDrawerIntent are PUBLIC here.

// MARK: - MootCalendarIngestShortcuts
//
// This is what makes the SDK's App Intents REAL — discoverable by Siri,
// Spotlight, and the Shortcuts app. The intent TYPES (CaptureDrawerIntent,
// RecallDrawerIntent) ship inside the MootGateway library, but a library
// CANNOT register shortcuts with the system. Only an AppShortcutsProvider
// declared in the APP TARGET registers them. So this tiny file is the bridge
// between "the SDK defines the intents" and "the OS knows about them."
//
// Why does this matter for THIS example?
//
//   Once registered, you can say to Siri "Recall Memories with MootCalendarIngest"
//   and it will run RecallDrawerIntent against the SAME MOOT this app fills with
//   your calendar events. The intents reach the estate via GatewayRuntime.shared,
//   which our App configured at launch — so Siri sees your ingested calendar.
//
// Each intent below uses its public no-argument initializer; the user supplies
// the parameters (the text to capture, the query to recall) at invocation time.

struct MootCalendarIngestShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        // CAPTURE — file a new memory by voice. perform() inside the SDK calls
        // moot_file_memory on the shared bridge.
        AppShortcut(
            intent: CaptureDrawerIntent(),
            phrases: [
                "Capture a memory in \(.applicationName)",
                "File a memory with \(.applicationName)"
            ],
            shortTitle: "Capture Memory",
            systemImageName: "tray.and.arrow.down"
        )

        // RECALL — read memories back by query. perform() inside the SDK calls
        // moot_memory_search on the shared bridge — including the events this
        // app ingested from Calendar.
        AppShortcut(
            intent: RecallDrawerIntent(),
            phrases: [
                "Recall memories in \(.applicationName)",
                "Search my memories with \(.applicationName)"
            ],
            shortTitle: "Recall Memories",
            systemImageName: "magnifyingglass"
        )
    }
}
