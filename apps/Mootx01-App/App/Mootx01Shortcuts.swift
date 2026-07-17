import AppIntents
import MootGateway
import MootIntentKit

// MARK: - Mootx01Shortcuts  (the app-target AppShortcutsProvider)
//
// The AppShortcutsProvider MUST live in the app target (not the linked
// package) for the App Intents metadata extractor to register these with the
// system — which is what makes them appear in the Shortcuts app and Siri, and
// callable for real. The intent TYPES live in MootIntentKit (shared); the app
// declares which ones it publishes and their invocation phrases.
//
// Only the two phrase-friendly verbs are auto-donated; the rest stay
// Shortcuts-composable as plain App Intents.

struct Mootx01Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureDrawerIntent(),
            phrases: [
                "Capture this in \(.applicationName)",
                "Remember this with \(.applicationName)",
            ],
            shortTitle: "Capture Memory",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: RecallDrawerIntent(),
            phrases: [
                "Recall from \(.applicationName)",
                "Search my memories in \(.applicationName)",
            ],
            shortTitle: "Recall Memories",
            systemImageName: "tray.and.arrow.up"
        )
    }
}
