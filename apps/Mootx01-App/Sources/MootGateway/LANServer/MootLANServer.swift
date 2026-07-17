import Foundation
import Network
import AriaMCP
import MootIntentKit
import OSLog

// MARK: - MootLANServer  (the portable, credentialed LAN MCP server)
//
// Bob's direction: Mootx01-App is a "server on the iPhone" — this makes it a
// server on the LAN too. An NWListener accepts MCP-over-HTTP connections,
// LANRequestGate enforces bearer auth + the read-only remote surface + the
// public-only export posture, and authorized JSON-RPC is handed to the SAME
// in-process dispatcher the app already runs (MootBridge.handle). "ARIA is
// always the server" holds — the app IS hosting ARIA — and the Swift/Rust
// parity boundary is untouched (this is app-side framing over the engine).
//
// The listener advertises _mootx01._tcp so tonight's LANDaemonBrowser (and
// any MCP client) can discover it. This is the APP advertising its OWN
// listener — distinct from the standalone daemon's Bonjour, which is an
// engine mission.
//
// On-power gate: the server serves only while the PowerConditionSource reports
// onPower. A transition to battery tears the listener down. Honest iOS truth:
// the listener also requires the app to be alive — "on power" narrows when it
// serves, it does not buy background longevity.
//
// Why NWListener and not the kit's LoopbackHTTP (validated 2026-07-11): the
// kit's HTTP transport is `AriaMCP.HTTPServer` over `LoopbackHTTP.POSIXSocket`,
// which is hard-pinned to `INADDR_LOOPBACK` ("never INADDR_ANY") BY SECURITY
// DESIGN and whose `HTTPRequest.read`/`HTTPResponse.send` are fd-coupled
// (they recv/send on a POSIX fd). This server is deliberately OFF-loopback
// (LAN bind + `_mootx01._tcp` Bonjour advertisement + iOS, where app-sandbox
// listen sockets favour NWListener), driven by NWConnection which yields
// `Data`, not an fd. So the loopback/fd primitives cannot compose here; only
// the transport-neutral pieces are reused — `ARIA_MCPDispatcher.handle` (the
// dispatch seam) and `JSONRPCRequest.decode` / `JSONRPCResponse` (the wire
// types, via LANRequestGate). The LAN-bind + auth posture extends the CE
// transport off loopback — see the decision record annotating
// ADR-LOOPBACKHTTP-001.

public actor MootLANServer {

    public struct Config: Sendable {
        public var port: UInt16
        public var serviceName: String
        public var onPowerOnly: Bool
        public init(port: UInt16 = 0, serviceName: String = "MOOTx01", onPowerOnly: Bool = true) {
            self.port = port
            self.serviceName = serviceName
            self.onPowerOnly = onPowerOnly
        }
    }

    public enum ServerState: Sendable, Equatable {
        case stopped
        case waitingForPower           // on-power-only, currently on battery
        case denied(String)            // owner authentication failed/canceled
        case listening(port: UInt16)
        case failed(String)
    }

    private let bridge: MootBridge
    private let credentialProvider: any LANCredentialProviding
    private let power: PowerConditionSource
    private var config: Config
    private let log = Logger(subsystem: "com.codedaptive.mootx01", category: "lan-server")

    /// Resolved at start() via the owner-presence prompt; held only while
    /// the server is up so every serve session re-validates the owner.
    private var credential: LANCredential?
    private var listener: NWListener?
    private(set) var state: ServerState = .stopped
    private var connectionLog: [String] = []

    public init(bridge: MootBridge, credentialProvider: any LANCredentialProviding,
                power: PowerConditionSource, config: Config) {
        self.bridge = bridge
        self.credentialProvider = credentialProvider
        self.power = power
        self.config = config
    }

    public func currentState() -> ServerState { state }
    public func recentConnections() -> [String] { connectionLog }

    /// Start serving if the power gate allows; otherwise wait for power.
    /// Order matters: the power precheck runs BEFORE credential resolution,
    /// so the owner is never prompted to unlock for a server that cannot
    /// serve anyway. Resolution triggers the device unlock system
    /// (Face ID / Touch ID / passcode) — Bob's owner-presence validation.
    public func start() async {
        if config.onPowerOnly && !power.current().allowsServing {
            state = .waitingForPower
            log.info("LAN server deferred: on battery, on-power-only is set")
            return
        }
        do {
            credential = try await credentialProvider.resolve()
        } catch {
            state = .denied("\(error)")
            log.error("LAN server denied: \(String(describing: error), privacy: .public)")
            return
        }
        startListening()
    }

    /// Re-evaluate the power gate (call when the power condition changes):
    /// start if newly on power, stop if newly on battery. A resume with no
    /// held credential re-runs start() — i.e. the owner re-authenticates;
    /// power loss does not become a way to inherit a stale authorization.
    public func powerConditionChanged() async {
        guard config.onPowerOnly else { return }
        let serving = listener != nil
        let allowed = power.current().allowsServing
        if allowed && !serving && state == .waitingForPower {
            if credential != nil {
                startListening()
            } else {
                await start()
            }
        } else if !allowed && serving {
            log.info("LAN server pausing: no longer on power")
            teardownListener()
            state = .waitingForPower
        }
    }

    public func stop() {
        teardownListener()
        credential = nil   // next start re-validates the owner
        state = .stopped
    }

    private func startListening() {
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(
                using: params,
                on: config.port == 0 ? .any : (NWEndpoint.Port(rawValue: config.port) ?? .any))
            // Advertise the app's own listener (app-side Bonjour, pairs with
            // LANDaemonBrowser). TXT carries the MCP transport marker.
            listener.service = NWListener.Service(
                name: config.serviceName,
                type: LANDaemonDiscovery.serviceType,
                txtRecord: NWTXTRecord(["mcp": "1", "transport": "http-jsonrpc"]))
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.listenerStateChanged(state) }
            }
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            state = .failed("\(error)")
            log.error("LAN server failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    private func listenerStateChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            let port = listener?.port?.rawValue ?? config.port
            state = .listening(port: port)
            log.info("LAN server listening on \(port)")
        case .failed(let error):
            state = .failed("\(error)")
            teardownListener()
        default:
            break
        }
    }

    private func teardownListener() {
        listener?.cancel()
        listener = nil
    }

    // MARK: connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffered
            if let data { accumulated.append(data) }
            Task {
                let done = await self.tryRespond(connection, accumulated: accumulated)
                if !done && error == nil && !isComplete {
                    // Body not whole yet — keep buffering on this connection.
                    await self.receive(connection, buffered: accumulated)
                }
            }
        }
    }

    /// Returns true when a response was written (or the request was rejected);
    /// false when the request is incomplete and more bytes are needed.
    private func tryRespond(_ connection: NWConnection, accumulated: Data) async -> Bool {
        guard let parsed = LANRequestGate.parse(accumulated) else { return false }
        guard let credential else {
            // No owner-validated credential in hand — refuse, never guess.
            write(connection, status: 503, jsonBody: errorBody("Server has no validated credential"))
            return true
        }

        let admission = LANRequestGate.admit(parsed, credential: credential)
        switch admission {
        case .rejected(let status, let reason):
            noteConnection("rejected \(status): \(reason)")
            write(connection, status: status, jsonBody: errorBody(reason))
            return true

        case .authorized(let rpc):
            // Remote surface: read-only allowlist + public-only export posture.
            guard LANRequestGate.isRemotelyPermitted(rpc) else {
                noteConnection("forbidden method \(rpc.method)")
                write(connection, status: 403, jsonBody: errorBody("Method not permitted for remote callers"))
                return true
            }
            let posted = LANRequestGate.enforceRemoteExportPosture(rpc)
            let response = await bridge.handle(posted)
            noteConnection("ok \(rpc.method)")
            if let response {
                write(connection, status: 200, jsonBody: encodeResponse(response))
            } else {
                // Notification (no id): JSON-RPC forbids a reply.
                write(connection, status: 202, jsonBody: Data())
            }
            return true
        }
    }

    private func noteConnection(_ line: String) {
        connectionLog.insert(line, at: 0)
        if connectionLog.count > 50 { connectionLog.removeLast() }
    }

    private func write(_ connection: NWConnection, status: Int, jsonBody: Data) {
        let reason = Self.statusReason(status)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(jsonBody.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(jsonBody)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func encodeResponse(_ response: JSONRPCResponse) -> Data {
        let value: JSONValue
        switch response.payload {
        case .result(let result):
            value = .object(["jsonrpc": .string("2.0"), "id": response.id ?? .null, "result": result])
        case .error(let error):
            value = .object([
                "jsonrpc": .string("2.0"),
                "id": response.id ?? .null,
                "error": .object(["code": .integer(Int64(error.code)), "message": .string(error.message)]),
            ])
        }
        return (try? value.encoded()) ?? errorBody("response encoding failed")
    }

    private func errorBody(_ message: String) -> Data {
        let value = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .null,
            "error": .object(["code": .integer(-32600), "message": .string(message)]),
        ])
        return (try? value.encoded()) ?? Data(#"{"error":"\#(message)"}"#.utf8)
    }

    private static func statusReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 405: return "Method Not Allowed"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
