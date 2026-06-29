import AppIntents
import MootGateway   // CaptureDrawerIntent + RecallDrawerIntent live in the library.

// =============================================================================
// MootNotepadShortcuts — register the app's voice/Shortcuts entry points.
// =============================================================================
//
// WHY THIS LIVES IN THE APP TARGET (not the library)
// ---------------------------------------------------
// An `AppShortcutsProvider` is the thing Apple's App Intents metadata extractor
// scans at BUILD time to register intents with the system. That extractor only
// runs over an actual app BUNDLE — so the provider MUST live in the app target,
// even though the intent TYPES themselves (CaptureDrawerIntent, etc.) are
// public in MootGateway. The library ships the verbs; the app declares which
// ones it publishes and what phrases trigger them.
//
// HOW THESE REACH THE SAME NOTES AS THE UI
// ----------------------------------------
// When Siri fires `CaptureDrawerIntent`, the SYSTEM creates the intent — our
// app code never sees the constructor. The intent's `perform()` resolves the
// estate through `IntentRuntimeBridge.shared.bridge()`. The app's launch path
// calls `GatewayRuntime.shared.bridge()`, which registers the bridge into
// `IntentRuntimeBridge`, so the UI and Siri share one estate.
//
// THE TWO VERBS WE PUBLISH
// ------------------------
//   CaptureDrawerIntent — files a new note. Maps to moot_file_memory. We pin
//                         its `location` to "notes" via a captured default so
//                         voice-captured notes land in the same room the app's
//                         UI reads from. (The intent itself defaults to
//                         "memories"; we want "notes" — see the init below.)
//   RecallDrawerIntent  — searches notes. Maps to moot_memory_search.

struct MootNotepadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // CAPTURE — "Hey Siri, take a note in MootNotepad: buy milk."
        //
        // We construct the intent with location "notes" so a voice capture is
        // filed into the very room (NotepadModel.room) the app's list reads.
        // If we used the intent's default ("memories"), voice notes would land
        // in a different room and never appear in this app's list — a subtle
        // bug worth pointing out, hence this explicit construction.
        AppShortcut(
            intent: CaptureDrawerIntent(content: "", location: NotepadRoom.value),
            phrases: [
                "Take a note in \(.applicationName)",
                "Capture this in \(.applicationName)",
                "New note in \(.applicationName)",
            ],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil"
        )

        // RECALL — "Hey Siri, search my notes in MootNotepad for milk."
        AppShortcut(
            intent: RecallDrawerIntent(),
            phrases: [
                "Search my notes in \(.applicationName)",
                "Find a note in \(.applicationName)",
            ],
            shortTitle: "Search Notes",
            systemImageName: "magnifyingglass"
        )
    }
}

// One source of truth for the room name, shared by the Shortcuts provider and
// the model so they cannot drift apart. (A plain enum constant — the value is
// what matters; the type just namespaces it.)
enum NotepadRoom {
    /// The MOOT "room" (location) every MootNotepad note is filed into.
    static let value = "notes"
}
