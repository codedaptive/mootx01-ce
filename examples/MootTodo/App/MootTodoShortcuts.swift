import AppIntents
import MootGateway   // CaptureDrawerIntent / RecallDrawerIntent are public here.

// ============================================================================
// MootTodoShortcuts — registers MOOTx01's App Intents with the system.
// ============================================================================
//
// WHY THIS LIVES IN THE APP TARGET (not the library)
// ---------------------------------------------------
// The intent TYPES (CaptureDrawerIntent, RecallDrawerIntent) ship inside the
// MootGateway library. But an AppShortcutsProvider only registers shortcuts
// with the system when it is compiled into an APP BUNDLE. So the provider lives
// here, in the app target, and simply references the library's intent types.
//
// HOW THESE INTENTS REACH THE SAME MOOT AS THE UI
// -----------------------------------------------
// Intents resolve their estate through `IntentRuntimeBridge.shared.bridge()`.
// At launch, `GatewayRuntime.shared.bridge()` registers the app's bridge with
// `IntentRuntimeBridge`, so a Shortcut that captures a memory writes into the
// EXACT same SQLite estate the to-do sidecar mirrors into — and the app's
// "Search memory" field will find it. One MOOT, many front doors.
//
// WHAT THE USER GETS
// ------------------
//   • "Capture in MootTodo …"  → files a free-form memory into the MOOT.
//   • "Recall in MootTodo …"    → searches the MOOT and speaks the result.
//
// These are genuine, callable shortcuts: from Siri, Spotlight, the Shortcuts
// app, and the Action Button.

struct MootTodoShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {

        // CAPTURE — write a memory into the MOOT. Maps to moot_file_memory
        // inside CaptureDrawerIntent.perform(). The phrase uses
        // \(.applicationName) so it reads naturally as "Capture in MootTodo".
        AppShortcut(
            intent: CaptureDrawerIntent(),
            phrases: [
                "Capture in \(.applicationName)",
                "Remember this in \(.applicationName)",
            ],
            shortTitle: "Capture Memory",
            systemImageName: "tray.and.arrow.down"
        )

        // RECALL — read memories back from the MOOT. Maps to moot_memory_search
        // inside RecallDrawerIntent.perform(); it returns/speaks the result.
        AppShortcut(
            intent: RecallDrawerIntent(),
            phrases: [
                "Recall in \(.applicationName)",
                "Search memory in \(.applicationName)",
            ],
            shortTitle: "Recall Memories",
            systemImageName: "magnifyingglass"
        )
    }
}
