import SwiftUI
import GatewayUI
#if os(macOS)
import AppKit
#endif

// MARK: - Mootx01App
//
// The MOOTx01 ecosystem app — the Apple presentation layer of ADR-005. One
// codebase, two app targets (macOS + iOS/iPadOS), sharing the GatewayUI
// surface. Every platform runs the engine "server-in-app" (embedded); macOS
// adds the app-managed-daemon panel (Engine tab). The clean server binary is
// separate and untouched.

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
            #else
            ContentView(model: model)
                .task { await model.start() }
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
