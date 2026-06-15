import AppIntents

// MARK: - MootShortcutsProvider
//
// Donates the six caller-driven verb intents to the system Shortcuts catalog.
// Visible in the Shortcuts app once an Xcode app bundle declares this
// package's AppIntentsPackage — a packaging step, not a capability gap.
// The intents themselves are fully functional today in-process.
//
// Siri phrases follow Apple's best-practice pattern: short, verb-first, with
// the app name. Phrase tokens match Shortcuts' spoken-parameter injection.

@available(iOS 16.0, macOS 13.0, *)
public struct MootShortcutsProvider: AppShortcutsProvider {

    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureDrawerIntent(),
            phrases: [
                "Capture in \(.applicationName)",
                "Remember this in \(.applicationName)",
            ],
            shortTitle: "Capture Memory",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: RecallDrawerIntent(),
            phrases: [
                "Recall from \(.applicationName)",
                "Search \(.applicationName)",
            ],
            shortTitle: "Recall Memories",
            systemImageName: "tray.and.arrow.up"
        )
        AppShortcut(
            intent: ReanchorDrawerIntent(),
            phrases: [
                "Move memory in \(.applicationName)",
            ],
            shortTitle: "Move Memory",
            systemImageName: "folder"
        )
        AppShortcut(
            intent: MutateDrawerIntent(),
            phrases: [
                "Update memory in \(.applicationName)",
            ],
            shortTitle: "Update Memory",
            systemImageName: "pencil"
        )
        AppShortcut(
            intent: WithdrawDrawerIntent(),
            phrases: [
                "Withdraw memory in \(.applicationName)",
            ],
            shortTitle: "Withdraw Memory",
            systemImageName: "tray.and.arrow.up.fill"
        )
        AppShortcut(
            intent: ExpungeDrawerIntent(),
            phrases: [
                "Erase memory in \(.applicationName)",
            ],
            shortTitle: "Erase Memory",
            systemImageName: "trash"
        )
    }
}
