import AppKit
import MootCommunityUI
import SwiftUI

@main
struct Mootx01CommunityApp: App {
    @NSApplicationDelegateAdaptor(CommunityAppDelegate.self) private var delegate
    @State private var model = CommunityAppModel()

    var body: some Scene {
        WindowGroup {
            CommunityContentView(model: model)
                .frame(minWidth: 760, minHeight: 520)
                .task { await model.maintainConnection() }
        }
        .commands { CommunityCaptureCommands(model: model) }

        Window(String(localized: "Quick Capture"), id: "quick-capture") {
            Group {
                if model.isEstateReady {
                    CommunityCaptureView(model: model.captureModel, compact: true)
                } else {
                    ContentUnavailableView(
                        String(localized: "Quick Capture unavailable"),
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(model.status)
                    )
                }
            }
            .frame(minWidth: 420, minHeight: 420)
        }
    }
}

private struct CommunityCaptureCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let model: CommunityAppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(String(localized: "Quick Capture")) {
                openWindow(id: "quick-capture")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!model.isEstateReady)
        }
    }
}

final class CommunityAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
