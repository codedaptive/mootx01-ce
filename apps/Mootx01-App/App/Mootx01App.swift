import AppIntents
import GatewayUI
#if os(macOS)
import AppKit
#endif

// MARK: - Mootx01App
//
// The MOOTx01 ecosystem app — the Apple presentation layer of the app/engine boundary. One
// codebase, two app targets (macOS + iOS/iPadOS), sharing the GatewayUI
// surface. Every platform runs the engine "server-in-app" (embedded); macOS
// adds the app-managed-daemon panel (Engine tab). The clean server binary is
// separate and untouched.
//
// Shortcuts registration: `Mootx01Shortcuts.updateAppShortcutParameters()` is
// called once at every app launch. The App Intents metadata extractor handles
// static phrase registration at build time (via the Xcode app bundle); this
// runtime call refreshes the donated phrases and surfaces them in the Shortcuts
// app and Siri. Without it the phrases registered at build time may go stale
// when content changes, so calling it here keeps them current.
//
// URL scheme (A5): `mootx01://x-callback-url/<verb>?…` is declared in
// project.yml → CFBundleURLTypes. The `onOpenURL` modifier on ContentView
// (below) routes inbound URLs through MootURLRouter.

@main
struct Mootx01App: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    #endif
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .task { await model.start() }
                .task { Mootx01Shortcuts.updateAppShortcutParameters() }
            #else
            ContentView(model: model)
                .task { await model.start() }
                .task { Mootx01Shortcuts.updateAppShortcutParameters() }
            #endif
        }
    }
}

#if os(macOS)
/// A bundled macOS app activates normally; this only forces foreground focus
/// when launched from a tool/`open` so the window comes forward.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
