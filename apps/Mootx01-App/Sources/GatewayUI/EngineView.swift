import SwiftUI
import MootGateway
#if os(macOS)
import AppKit
#endif

// MARK: - EngineView  (the host-mode tab)
//
// Makes ADR-005's host model visible. Every platform runs the engine
// "server-in-app" (embedded, in-process, app-lifetime) — the cross-platform
// analog. macOS adds the "app-managed daemon": spawn and supervise the real
// server binary over stdio. This tab shows the current mode and, on macOS,
// the daemon panel.

struct EngineView: View {
    @Bindable var model: AppModel
    @State private var discovery = DiscoveryController()
    @State private var portable = PortableServerController()
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

                portableServerPanel

                syncPanel

                discoveryPanel
            }
            .padding(20)
        }
        .onDisappear {
            discovery.stop()
            Task { await portable.stop() }
        }
    }

    // MARK: - Sync status tile (CVK-ICLOUD P5-M2)

    /// Minimal iCloud sync status tile. Shows container, push-accelerated state,
    /// and last sync time for this session. Tier tracking (AdaptivePollScheduler
    /// internal state) is not exposed by the engine's public surface; see
    /// CloudKitSyncEngine.swift — a follow-up can surface it when the scheduler
    /// exposes currentTier publicly.
    private var syncPanel: some View {
        SyncTileView()
    }

    private var portableServerPanel: some View {
        GroupBox(String(localized: "Portable LAN server (MCP)")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Serve this estate to MCP clients on your local network over a credentialed connection. Remote callers are read-only and see only public (exportable) memory — the same serve-out gate as callback recall. This device stays the one host; the server bridges to the same in-process engine."))
                    .font(.caption).foregroundStyle(.secondary)

                Toggle(String(localized: "Only serve while on power"), isOn: $portable.onPowerOnly)
                    .font(.caption)
                    .disabled(portable.isServing)

                HStack {
                    Button(portable.isServing
                           ? String(localized: "Stop server")
                           : String(localized: "Start server")) {
                        Task { await portable.toggle() }
                    }
                    Spacer()
                    Circle().fill(portable.listeningPort != nil ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(portable.statusText).font(.caption.monospaced()).foregroundStyle(.secondary)
                }

                if let port = portable.listeningPort {
                    Text(String(localized: "Listening on port \(String(port)) · advertised as \(portable.serviceName)"))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Bearer token")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if portable.token.isEmpty {
                            Text(String(localized: "•••• (authenticate to reveal)"))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button(String(localized: "Reveal")) { Task { await portable.revealToken() } }
                                .font(.caption)
                        } else {
                            Text(portable.token).font(.caption2.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            Button(String(localized: "Regenerate")) { portable.regenerateToken() }
                                .font(.caption)
                        }
                    }
                    Text(String(localized: "The token lives behind the device unlock system (Face ID / Touch ID / passcode); starting the server and revealing the token both require it. Clients send it as “Authorization: Bearer <token>”. Regenerating invalidates every existing client."))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if !portable.connectionLog.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Recent connections")).font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(portable.connectionLog.prefix(6).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }

                #if os(iOS)
                Label {
                    Text(String(localized: "On iPhone/iPad the server runs only while the app is active — “on power” narrows when it serves, it does not keep it alive in the background."))
                } icon: { Image(systemName: "bolt.badge.clock") }
                .font(.caption2).foregroundStyle(.secondary)
                #endif
            }
            .padding(6)
        }
    }

    private var discoveryPanel: some View {
        GroupBox(String(localized: "LAN daemons (discovery)")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Browse the local network for MOOT resident daemons advertising _mootx01._tcp. Daemon-side advertisement is an engine mission that has not shipped — until it does, an empty result here is the honest answer, not a failure."))
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button(discovery.isBrowsing
                           ? String(localized: "Stop browsing")
                           : String(localized: "Browse for daemons")) {
                        discovery.toggleBrowsing()
                    }
                    Spacer()
                    Circle().fill(discovery.isBrowsing ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(discovery.isBrowsing
                         ? String(localized: "browsing")
                         : String(localized: "idle"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }

                if discovery.isBrowsing && discovery.serviceNames.isEmpty {
                    Text(String(localized: "No daemons found yet."))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                ForEach(discovery.serviceNames, id: \.self) { name in
                    HStack {
                        Text(name).font(.caption.monospaced())
                        Spacer()
                        if let endpoint = discovery.resolved[name] {
                            Text(endpoint).font(.caption2.monospaced())
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        } else {
                            Button(String(localized: "Resolve")) {
                                Task { await discovery.resolve(name) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .padding(6)
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
                Text(String(localized: "Spawn the real, untouched server binary as a supervised child and talk to it over stdio. The binary is the clean, Rust-mirrored server — the app adds nothing to it (ADR-005)."))
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

// MARK: - SyncTileView (CVK-ICLOUD P5-M2)
//
// Minimal iCloud sync status tile for the Engine tab.
//
// DESIGN RATIONALE:
// MootSyncDriver is an actor; its internal state (enabled, cloudKitEngine,
// last-sync receipt) is not directly observable from a SwiftUI view without
// either (a) adding @Observable conformance to the actor or (b) a bridging
// observable wrapper object. Adding that infrastructure is out of P5-M2 scope
// (the mission says "minimal"). This tile therefore:
//   - Shows the configured container identifier (static property — no await).
//   - Tracks last-synced time LOCALLY via @State from a manual "Sync now" tap.
//   - Does NOT show pushed/pulled counts (syncNow() returns Bool, not a receipt).
//   - Does NOT show AdaptivePollScheduler tier (not yet exposed publicly).
//
// A follow-up can add a SyncStatusMonitor @Observable bridge and expose counts
// and tier if the diagnostic value justifies the surface area.

private struct SyncTileView: View {
    @State private var lastSynced: Date? = nil
    @State private var syncRunning = false

    var body: some View {
        GroupBox(String(localized: "iCloud sync")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "CloudKit zone-subscription silent push accelerates the poll loop. Each zone-change notification fires an immediate pull and resets to the fast poll tier. Polling alone is the correctness guarantee — push is best-effort."))
                    .font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Image(systemName: "icloud")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(MootSyncDriver.containerIdentifier)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Button(syncRunning
                           ? String(localized: "Syncing…")
                           : String(localized: "Sync now")) {
                        Task {
                            syncRunning = true
                            _ = await MootSyncDriver.shared.syncNow()
                            lastSynced = Date()
                            syncRunning = false
                        }
                    }
                    .disabled(syncRunning)
                    Spacer()
                    if let date = lastSynced {
                        Text(date.formatted(.relative(presentation: .named)))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(String(localized: "Last synced"))
                    } else {
                        Text(String(localized: "not synced this session"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
    }
}
