import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - EngineView  (the host-mode tab)
//
// Makes the host model visible. Every platform runs the engine
// "server-in-app" (embedded, in-process, app-lifetime) — the cross-platform
// analog. macOS adds the "app-managed daemon": spawn and supervise the real
// server binary over stdio. This tab shows the current mode and, on macOS,
// the daemon panel.

struct EngineView: View {
    @Bindable var model: AppModel
    #if os(macOS)
    @State private var daemon = DaemonController()
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "Host mode")).font(.title3.weight(.semibold))

                embeddedCard

                #if os(macOS)
                daemonPanel
                #else
                Label {
                    Text(String(localized: "Spawning a standalone daemon and handing it a database is a macOS-only capability — iOS/iPadOS can't run a persistent subprocess. Here, the app is always the server."))
                } icon: { Image(systemName: "ipad.and.iphone") }
                .font(.caption).foregroundStyle(.secondary)
                #endif
            }
            .padding(20)
        }
    }

    private var embeddedCard: some View {
        GroupBox(String(localized: "Server-in-app (embedded)")) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cpu").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "This app owns its estate in-process; the engine is alive only while the app runs. This is the shared model across macOS, iOS, and iPadOS."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let path = model.databasePath {
                        Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        }
    }

    #if os(macOS)
    private var daemonPanel: some View {
        GroupBox(String(localized: "App-managed daemon (macOS only)")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Spawn the real, untouched server binary as a supervised child and talk to it over stdio. The binary is the clean, Rust-mirrored server — the app adds nothing to it."))
                    .font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Server binary")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField(String(localized: "path to aria-mcp / mootx01 serve"), text: $daemon.binaryPath)
                            .textFieldStyle(.roundedBorder)
                        Button(String(localized: "Choose…")) { chooseBinary() }
                    }
                }

                HStack {
                    if daemon.isRunning {
                        Button(String(localized: "Stop daemon")) { Task { await daemon.stop() } }
                        Button(String(localized: "Verify (tools/list)")) { Task { await daemon.verify() } }
                    } else {
                        Button(String(localized: "Spawn managed daemon")) { Task { await daemon.start() } }
                            .disabled(daemon.binaryPath.isEmpty)
                    }
                    Spacer()
                    Circle().fill(daemon.isRunning ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(daemon.status).font(.caption.monospaced()).foregroundStyle(.secondary)
                }

                Label {
                    Text(String(localized: "Handing off this app's own live estate (ownership transfer app→daemon) additionally needs an in-app estate close() — an engine follow-up. This panel spawns + supervises a daemon on its own estate to prove the mechanism."))
                } icon: { Image(systemName: "arrow.left.arrow.right") }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            daemon.binaryPath = url.path
        }
    }
    #endif
}
