import Foundation
import Observation
import MootGateway

// MARK: - PortableServerController  (Engine tab, portable LAN MCP server)
//
// UI-facing state for MootLANServer: the serve toggle, the on-power-only
// switch, the bearer token (display + regenerate), the advertised name, and
// a live connection log. The controller owns the server actor and the power
// source; it polls power on a light timer so a plug/unplug re-evaluates the
// gate without any manual step.

@MainActor
@Observable
public final class PortableServerController {

    public private(set) var isServing = false
    public private(set) var statusText = String(localized: "server.status.stopped", defaultValue: "stopped")
    public private(set) var listeningPort: UInt16?
    public private(set) var connectionLog: [String] = []
    public private(set) var token: String = ""

    /// User settings, persisted so the choice survives relaunch.
    public var onPowerOnly = true
    public var serviceName = "MOOTx01"

    private var server: MootLANServer?
    private let power: PowerConditionSource = PlatformPowerSource()
    private var pollTask: Task<Void, Never>?

    public init() {
        token = (try? LANCredentialStore.groupStore().loadOrCreate().token) ?? ""
    }

    public func toggle() async {
        isServing ? await stop() : await start()
    }

    public func start() async {
        guard let credential = try? LANCredentialStore.groupStore().loadOrCreate() else {
            statusText = String(localized: "server.status.noGroup", defaultValue: "app-group container unavailable")
            return
        }
        guard let bridge = try? await GatewayRuntime.shared.bridge() else {
            statusText = String(localized: "server.status.noBridge", defaultValue: "estate not ready")
            return
        }
        let server = MootLANServer(
            bridge: bridge, credential: credential, power: power,
            config: .init(serviceName: serviceName, onPowerOnly: onPowerOnly))
        self.server = server
        await server.start()
        isServing = true
        await refresh()
        startPowerPolling()
    }

    public func stop() async {
        pollTask?.cancel(); pollTask = nil
        await server?.stop()
        server = nil
        isServing = false
        listeningPort = nil
        statusText = String(localized: "server.status.stopped", defaultValue: "stopped")
    }

    public func regenerateToken() {
        guard let store = try? LANCredentialStore.groupStore() else { return }
        token = store.regenerate().token
        // A running server holds the old credential; restart to adopt the new
        // one. Surfacing this to the user beats silently serving a stale token.
        if isServing {
            statusText = String(localized: "server.status.tokenChanged",
                                defaultValue: "token changed — restart the server to apply")
        }
    }

    private func startPowerPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.server?.powerConditionChanged()
                await self?.refresh()
            }
        }
    }

    private func refresh() async {
        guard let server else { return }
        connectionLog = await server.recentConnections()
        switch await server.currentState() {
        case .stopped:
            statusText = String(localized: "server.status.stopped", defaultValue: "stopped")
            listeningPort = nil
        case .waitingForPower:
            statusText = String(localized: "server.status.waitingPower",
                                defaultValue: "waiting for power (on-power-only)")
            listeningPort = nil
        case .listening(let port):
            listeningPort = port
            statusText = String(localized: "server.status.listening", defaultValue: "listening")
        case .failed(let reason):
            statusText = String(localized: "server.status.failed", defaultValue: "failed: \(reason)")
            listeningPort = nil
        }
    }
}
