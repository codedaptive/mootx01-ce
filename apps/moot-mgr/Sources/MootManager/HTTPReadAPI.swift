// HTTPReadAPI.swift
//
// The loopback HTTP read-API for moot-mgr (P3). Serves the read-plane endpoints
// from the ObserverSink stats store, plus a token+Origin-gated control surface.
//
// ============================ SECURITY BOUNDARY =============================
// This is an MCP-adjacent endpoint. The comment-fidelity rule calls these out
// specifically — read this block before changing any binding or auth check.
//
//  * LOOPBACK ONLY. The listening socket binds to 127.0.0.1 explicitly
//    (POSIXSocket.listenLoopbackTCP pins sin_addr to INADDR_LOOPBACK). We NEVER
//    bind INADDR_ANY / 0.0.0.0 (concepts §1.6: "Bind any HTTP strictly to
//    127.0.0.1"). Because the bind is loopback-only, off-host peers cannot reach
//    the port at all.
//
//  * READ ENDPOINTS ARE UNAUTHENTICATED BUT HOST-VALIDATED. GET /api/server,
//    /api/estates, /api/events, /api/config return metadata only (counts,
//    enums, ISO-8601 timestamps). No memory/rung content ever crosses this
//    surface (concepts §1.6, GUI SPEC §10). A GET with a non-loopback Host
//    header is rejected 421 (DNS-rebinding guard: `isLoopbackHost` in serve(_:)).
//    Absent/empty Host is allowed (curl, direct native connections).
//
//  * CONTROL OVER HTTP IS GATED. POST /api/control/* (monitoring on/off, set
//    retention) requires BOTH:
//      - a Bearer token (Authorization: Bearer <token>), compared in constant
//        time against the app-injected token; a missing or short token is
//        rejected 401; and
//      - an Origin check — the request must have NO Origin header (same-origin
//        fetch / curl) or a loopback Origin. A cross-origin Origin is rejected
//        403. This blocks CSRF from other local web pages (concepts §1.6:
//        "check Origin to block CSRF from other local pages").
//    Control is NEVER exposed over plain unauthenticated HTTP. The preferred
//    privileged path is the Unix domain socket (ControlChannel.swift); this
//    HTTP control surface exists for the Concept-B browser dashboard's injected
//    token (concepts §1.6 / GUI SPEC §10).
// ===========================================================================
//
// Implementation note: the listening + per-connection I/O run on a dedicated
// background Thread using POSIX sockets (LoopbackHTTP.POSIXSocket). NWListener was the
// mission's first choice but cannot bind a server socket in this build
// environment (EINVAL); the POSIX path is zero-dependency (system libc) and
// enforces the same loopback-only boundary directly. See the completion report.
// Each request that needs the store hops onto the MootManager actor via an
// async Task; the socket fd stays owned by the connection handler.

import Foundation
import OSLog
import LoopbackHTTP

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Concurrency cap

// The moot-mgr loopback control/read-API server is a single-user local service.
// 16 concurrent connections is generous for any realistic local dashboard or CLI
// tool, and low enough to protect against a caller that opens many blocking
// connections before the auth/control checks run (CAND-011 MEDIUM finding).
//
// The gate uses the same two-phase protocol as AriaMcpKit's ConcurrencyGate:
//   1. tryEnqueue() — NON-BLOCKING on the accept thread. Returns false
//      immediately when the cap is reached; the connection is shed with HTTP
//      503 + Retry-After: 1. The accept thread NEVER blocks on the gate.
//   2. waitForSlot() — BLOCKING semaphore wait inside the spawned Task.
//      Enforces the concurrent-service cap.
//   3. release() — called (via defer) when the connection handler exits,
//      including on all error and timeout paths.
//
// Configurable via `MOOT_MGR_HTTP_MAX_CONNECTIONS` environment variable.

/// Maximum concurrent connections for the moot-mgr loopback HTTP server.
///
/// 16 is generous for a single-user local management surface (dashboard, CLI).
/// Connections beyond this cap are shed with HTTP 503 + `Retry-After: 1` rather
/// than allowed to accumulate as unbounded blocking tasks. Matches the Rust port
/// (`MAX_LOOPBACK_CONNECTIONS`).
private let MootMgrMaxLoopbackConnections: Int = {
    if let v = ProcessInfo.processInfo.environment["MOOT_MGR_HTTP_MAX_CONNECTIONS"],
       let n = Int(v) {
        return max(1, min(n, 1024))
    }
    return 16
}()

/// Bounded concurrency gate for the moot-mgr loopback HTTP server.
///
/// Backed by a `DispatchSemaphore` (same pattern as AriaMcpKit's
/// `ConcurrencyGate`). `@unchecked Sendable` because `DispatchSemaphore` and
/// the `Atomic` counter satisfy the cross-thread safety requirement.
///
/// The accept thread calls `tryEnqueue()` (non-blocking). If it returns `false`
/// the connection is shed immediately with HTTP 503. If it returns `true` the
/// accept thread dispatches a Task that calls `waitForSlot()` before serving.
/// Call `release()` when the handler finishes — always pair via `defer`.
final class MootMgrConnGate: @unchecked Sendable {
    let maxConcurrent: Int

    /// Number of connections currently enqueued (waiting or actively serving).
    /// Incremented by tryEnqueue, decremented by release.
    private var activeCount: Int = 0
    private let lock = NSLock()
    /// Semaphore: starts at maxConcurrent free slots. waitForSlot() decrements
    /// (blocks if 0); release() signals (wakes one waiter).
    private let semaphore: DispatchSemaphore

    init(maxConcurrent: Int = MootMgrMaxLoopbackConnections) {
        self.maxConcurrent = maxConcurrent
        self.semaphore = DispatchSemaphore(value: maxConcurrent)
    }

    /// Phase 1 (accept thread, NON-BLOCKING): test whether a new connection fits
    /// within the cap. Returns `true` and increments the active count if so
    /// (caller MUST eventually call `release()`); returns `false` if the cap is
    /// already reached (caller should shed with HTTP 503 and close the fd).
    ///
    /// This method NEVER blocks — no semaphore wait, no parking.
    func tryEnqueue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeCount < maxConcurrent else { return false }
        activeCount += 1
        return true
    }

    /// Phase 2 (worker Task, BLOCKING): wait until a concurrency slot is free.
    /// Must be called after a successful `tryEnqueue()`, before serving the
    /// request. In the current single-layer design, tryEnqueue only returns true
    /// when a slot is immediately available, so this wait returns without
    /// blocking. Present for structural parity with AriaMcpKit's gate.
    func waitForSlot() {
        semaphore.wait()
    }

    /// Release a previously acquired slot. Decrements activeCount and signals
    /// the semaphore so the next waiting Task can proceed. Always call via
    /// `defer` in the connection handler to ensure release on all exit paths.
    func release() {
        lock.lock()
        if activeCount > 0 { activeCount -= 1 }
        lock.unlock()
        semaphore.signal()
    }

    /// Current active connection count. Informational; used in tests.
    var currentDepth: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeCount
    }
}

// MARK: - HTTPReadAPI

/// The loopback HTTP server exposing the moot-mgr read-API and the gated HTTP
/// control surface. One instance per resident host.
public actor HTTPReadAPI {

    // MARK: - Configuration

    /// The manager the API reads from and dispatches control verbs to.
    private let manager: MootManager

    /// The admin engine that provisions and tears down estates. Optional: a host
    /// configured without an admin plane (the pure-observer CLI cut) leaves this
    /// nil, and the admin verbs then report "admin plane not available" rather
    /// than 404 — the gate still applies, there is simply nothing to drive. When
    /// present, the admin verbs in `applyControl` route to it. Reached ONLY after
    /// the gate (see the SECURITY BOUNDARY block) — admin is a privileged write.
    private let admin: EstateAdmin?

    /// The TCP port requested on 127.0.0.1 (0 = OS-assigned).
    private let requestedPort: UInt16

    /// The bearer token required for POST /api/control/* over HTTP. Compared in
    /// constant time. A control request without a matching token is rejected.
    private let controlToken: String

    /// Process start instant, used to compute uptime for /api/server. Injected
    /// so tests are deterministic.
    private let startInstant: Date

    /// A clock the API stamps on snapshots. Injected for determinism in tests.
    private let clock: @Sendable () -> Date

    private let logger = Logger(subsystem: "com.mootx01.kit", category: "HTTPReadAPI")

    /// Bounded concurrency gate: limits simultaneous in-flight connections to
    /// `MootMgrMaxLoopbackConnections` (default 16, overrideable via env var).
    /// Connections beyond the cap are shed with HTTP 503 + Retry-After before
    /// any request parsing runs. Mirrors the Rust port's `LoopbackConnGate`.
    private let connGate: MootMgrConnGate

    /// The listening socket fd; -1 when not running.
    private var listenFD: Int32 = -1
    /// The actual bound port (resolved when requestedPort was 0).
    private var actualPort: UInt16 = 0
    /// The accept-loop thread.
    private var acceptThread: Thread?
    /// Set false to stop the accept loop.
    private let running = RunningFlag()

    // MARK: - Init

    /// Create the read-API server.
    ///
    /// - Parameters:
    ///   - manager:      The started `MootManager` to read from.
    ///   - port:         TCP port to bind on 127.0.0.1 (0 = OS-assigned).
    ///   - controlToken: Bearer token gating the HTTP control surface. A token
    ///                   shorter than 16 chars disables the control surface
    ///                   (treated as "no credential" — see `isAuthorized`).
    ///   - startInstant: The host start time (for uptime).
    ///   - clock:        Injected clock for snapshot timestamps.
    ///   - admin:        The admin engine for estate provisioning/lifecycle. nil
    ///                   for a read-only/observer host (admin verbs then report
    ///                   "not available"). Defaulted so existing call sites are
    ///                   unchanged.
    public init(
        manager: MootManager,
        port: UInt16,
        controlToken: String,
        startInstant: Date,
        clock: @escaping @Sendable () -> Date = { Date() },
        admin: EstateAdmin? = nil,
        maxConnections: Int? = nil
    ) {
        self.manager = manager
        self.requestedPort = port
        self.controlToken = controlToken
        self.startInstant = startInstant
        self.clock = clock
        self.admin = admin
        // Use the explicit override when provided (tests); otherwise read the env
        // var / default inside MootMgrConnGate.init.
        if let cap = maxConnections {
            self.connGate = MootMgrConnGate(maxConcurrent: max(1, cap))
        } else {
            self.connGate = MootMgrConnGate()
        }
    }

    // MARK: - Lifecycle

    /// Bind the listening socket to 127.0.0.1:port and start the accept loop.
    ///
    /// - Throws: `SocketError` if the socket cannot be created/bound.
    public func start() throws {
        let (fd, port) = try POSIXSocket.listenLoopbackTCP(port: requestedPort)
        self.listenFD = fd
        self.actualPort = port
        running.set(true)

        // The accept loop blocks on accept(); run it on a dedicated thread so it
        // never occupies the cooperative pool. Each accepted connection is handed
        // to the actor for serving, subject to the concurrency gate.
        let gate = connGate
        let thread = Thread { [weak self, fd, running, gate] in
            while running.get() {
                guard let cfd = POSIXSocket.acceptOne(fd) else {
                    if !running.get() { break }
                    continue
                }
                guard let self else { close(cfd); break }

                // Phase 1 (accept thread, NON-BLOCKING): depth check only.
                // tryEnqueue increments the active count and returns false
                // immediately when the cap is reached — it never blocks. The
                // accept loop sheds the connection inline with HTTP 503 +
                // Retry-After and loops back to accept() without parking.
                guard gate.tryEnqueue() else {
                    // Cap exceeded: write 503 and close before any request
                    // parsing runs. This keeps the shed path on the accept
                    // thread (fast, no dispatch) and matches the Rust port.
                    Self.sendShedResponse(fd: cfd)
                    close(cfd)
                    continue
                }

                Task {
                    // Phase 2 (worker Task): wait for a concurrency slot.
                    // In the current single-layer design tryEnqueue only
                    // returns true when a slot is available, so this returns
                    // immediately. Present for structural parity with
                    // AriaMcpKit's two-phase gate.
                    gate.waitForSlot()
                    // Slot-release invariant: release MUST be called on every
                    // exit path — normal completion, host shutdown, or error.
                    defer { gate.release() }
                    await self.serve(cfd)
                }
            }
        }
        thread.name = "com.mootx01.kit.HTTPReadAPI.accept"
        thread.start()
        self.acceptThread = thread
        logger.info("HTTPReadAPI listening on 127.0.0.1:\(port)")
    }

    /// Stop accepting connections and close the listener. Idempotent.
    public func stop() async {
        running.set(false)
        if listenFD >= 0 {
            // Closing the listening fd unblocks accept() so the thread exits.
            close(listenFD)
            listenFD = -1
        }
        acceptThread = nil
    }

    /// The port the listener is bound to (resolves an OS-assigned port).
    public func boundPort() -> UInt16 {
        actualPort != 0 ? actualPort : requestedPort
    }

    // MARK: - Connection handling

    /// Serve one accepted connection: read the request, route it, respond.
    private func serve(_ fd: Int32) async {
        // Bound blocking reads: a peer that trickles bytes cannot stall a handler
        // thread longer than this window. Mirrors the Rust port's
        // `stream.set_read_timeout(Duration::from_secs(30))`.
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let request = HTTPRequest.read(fd: fd) else { close(fd); return }

        // DNS-rebinding guard: reject any GET whose Host header is present but
        // not a loopback address. A browser always sends Host; a rebinding attack
        // uses a non-loopback domain that resolves to 127.0.0.1. Absent/empty
        // Host is allowed (curl, direct native connections). POST /api/control/*
        // is already gated by Origin + Bearer token which provides stronger
        // protection there.
        if request.method == "GET", !Self.isLoopbackHost(request.headers["host"]) {
            HTTPResponse.json(status: 421, body: Data(#"{"error":"misdirected_request"}"#.utf8)).send(fd: fd)
            close(fd)
            return
        }

        // The SSE live-tail is the one streaming path. Decide it here, before
        // routing: LoopbackHTTP's response writer is buffered-only, and the
        // stream's source + lifetime are the consumer's (ADR-LOOPBACKHTTP-001).
        // streamEvents owns the fd from here and closes it when the stream ends.
        if request.method == "GET", request.path == "/api/events", request.wantsEventStream {
            await streamEvents(fd: fd)
            return
        }
        let response = await route(request)
        response.send(fd: fd)
        close(fd)
    }

    // MARK: - Routing

    /// Route a parsed request to a response.
    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/server"):
            return await jsonResponse { try await self.manager.serverPayload(
                now: self.clock(),
                uptimeSeconds: max(0, Int(self.clock().timeIntervalSince(self.startInstant)))
            ) }
        case ("GET", "/api/estates"):
            // Merge the admin section into the event-derived rollups.
            // Priority: local EstateAdmin (host-provisioned, when wired) over the
            // ARIA_MCP proxy (base.admin, populated by MootManager.estatesPayload()).
            // On a pure-observer host (no admin engine), adminSection is nil and
            // the proxy data surfaces unmodified (adminSection ?? base.admin).
            // Read-only — the admin engine's mutating verbs live on the gated
            // control surface (GUI SPEC §4.2).
            return await jsonResponse {
                let base = try await self.manager.estatesPayload()
                let adminSection = await self.admin?.payload()
                return EstatesPayload(estates: base.estates, admin: adminSection ?? base.admin)
            }
        case ("GET", "/api/config"):
            return await jsonResponse { try await self.manager.configPayload() }
        case ("GET", "/api/graph"):
            // Topology snapshot. The optional ?estate= filter selects which
            // estate's snapshot to serve from the shared stats store. When no
            // snapshot has been written (governor startup pass not yet complete)
            // the response is structurePending:true with an empty graph.
            let estate = Self.queryValue("estate", in: request.query)
            return await jsonResponse { try await self.manager.graphPayload(now: self.clock(), estate: estate) }
        case ("GET", "/api/events"):
            // SSE live-tail (Accept: text/event-stream or ?stream=1) is handled
            // in serve(_:) before routing; here we serve the one-shot JSON
            // snapshot.
            return await jsonResponse { try await self.manager.eventsPayload() }
        case ("GET", "/api/lexicon"):
            // ARIA grammar + LatticeLib metadata as static JSON. All data is
            // compile-time constant (AriaLexiconLib enums, LatticeLib version).
            // No store access — safe to serve even before monitoring starts.
            return await jsonResponse { await self.manager.lexiconPayload() }
        case ("GET", "/api/lattice"):
            // Active lattice addresses (UDC/MDCC codes) with drawer counts,
            // proxied from ARIA_MCP and annotated with FDC heading labels.
            // Degrades to empty list when ARIA_MCP is unreachable (pending:true).
            return await jsonResponse { await self.manager.latticePayload() }
        case ("POST", let path) where path.hasPrefix("/api/control/"):
            return await handleControl(request)
        case ("GET", let path):
            // The read-plane web dashboard (P4): a GET that is not an /api/*
            // route is matched against the fixed static-asset allow-list. The
            // allow-list (StaticAssets.asset) maps only "/", "/index.html",
            // "/app.css", "/app.js" — there is no directory mapping, so an
            // arbitrary path cannot traverse the filesystem. Anything off the
            // list is 404. Static serving rides the same loopback-only listener
            // and is read-only (GUI SPEC §2.1).
            guard let asset = StaticAssets.asset(for: path) else { return .notFound }
            return .asset(contentType: asset.contentType, body: Data(asset.body.utf8))
        default:
            return .notFound
        }
    }

    /// Build a 200 JSON response from a throwing payload builder, mapping
    /// failures to 500. Keeps each route a one-liner.
    private func jsonResponse<T: Encodable>(
        _ build: () async throws -> T
    ) async -> HTTPResponse {
        do {
            let data = try APIJSON.encode(try await build())
            return .json(status: 200, body: data)
        } catch {
            logger.error("read-API error: \(String(describing: error))")
            return .json(status: 500, body: Data(#"{"error":"internal"}"#.utf8))
        }
    }

    // MARK: - Control surface (gated)

    /// Handle a POST /api/control/* request: enforce token + Origin, then apply
    /// the verb. See the SECURITY BOUNDARY block at the top of the file.
    private func handleControl(_ request: HTTPRequest) async -> HTTPResponse {
        // 1. Origin check (CSRF guard) — runs BEFORE the token is examined.
        guard Self.isOriginAllowed(request.origin) else {
            return .json(status: 403, body: Data(#"{"error":"forbidden_origin"}"#.utf8))
        }
        // 2. Bearer token check (constant-time compare).
        guard isAuthorized(request.bearerToken) else {
            return .json(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        }
        // 3. Apply the verb.
        let response = await applyControl(path: request.path, body: request.body)
        return .json(status: response.ok ? 200 : 400, body: response.json)
    }

    /// Apply a control verb identified by the request path. Shared by the HTTP
    /// control surface and (via `ControlChannel`) the UDS surface, so both gated
    /// surfaces have identical semantics.
    ///
    /// Read/retention verbs (monitoring/retention) return a `ControlResult`.
    /// Admin verbs (estate provision/lifecycle) return a richer
    /// `EstateAdminResult` (estate UUID + mount state). Both are surfaced through
    /// the `ControlResponse` envelope so a single encode path serves both
    /// surfaces; callers read `response.ok` for the status code and encode
    /// `response.json` verbatim.
    ///
    /// Verbs:
    ///   POST /api/control/monitoring/on       → enable monitoring
    ///   POST /api/control/monitoring/off      → disable monitoring
    ///   POST /api/control/retention           → set retention; body {"seconds":N}
    ///   POST /api/control/estate/provision    → provision a new estate (body: EstateAdminRequest)
    ///   POST /api/control/estate/quiesce      → quiesce  (body: EstateLifecycleRequest)
    ///   POST /api/control/estate/drain        → drain    (body: EstateLifecycleRequest)
    ///   POST /api/control/estate/destroy      → destroy  (body: EstateLifecycleRequest, confirmName required)
    func applyControl(path: String, body: Data) async -> ControlResponse {
        switch path {
        case "/api/control/monitoring/on":
            do { try await manager.setMonitoring(true); return .of(ControlResult(ok: true, detail: "monitoring: ON")) }
            catch { return .of(ControlResult(ok: false, detail: "error")) }
        case "/api/control/monitoring/off":
            do { try await manager.setMonitoring(false); return .of(ControlResult(ok: true, detail: "monitoring: OFF")) }
            catch { return .of(ControlResult(ok: false, detail: "error")) }
        case "/api/control/retention":
            guard
                let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                let seconds = (obj["seconds"] as? NSNumber)?.intValue,
                seconds > 0
            else { return .of(ControlResult(ok: false, detail: "invalid retention seconds")) }
            do {
                try await manager.setRetention(window: TimeInterval(seconds))
                return .of(ControlResult(ok: true, detail: "retention: \(seconds)s"))
            } catch { return .of(ControlResult(ok: false, detail: "invalid retention seconds")) }
        case "/api/control/estate/provision",
             "/api/control/estate/quiesce",
             "/api/control/estate/drain",
             "/api/control/estate/destroy":
            return await applyAdminControl(path: path, body: body)
        default:
            return .of(ControlResult(ok: false, detail: "unknown control verb"))
        }
    }

    /// Dispatch an admin verb to the `EstateAdmin` engine. Reached only from
    /// `applyControl` — and therefore only AFTER the gate (token+Origin over
    /// HTTP, or 0600 UDS). A host with no admin engine wired reports the verb as
    /// unavailable rather than 404, so the gate boundary is unchanged.
    private func applyAdminControl(path: String, body: Data) async -> ControlResponse {
        guard let admin else {
            return .of(EstateAdminResult(ok: false, detail: "admin plane not available on this host"))
        }
        let decoder = JSONDecoder()
        do {
            switch path {
            case "/api/control/estate/provision":
                let req = try decoder.decode(EstateAdminRequest.self, from: body)
                return .of(try await admin.provision(req))
            case "/api/control/estate/quiesce":
                let req = try decoder.decode(EstateLifecycleRequest.self, from: body)
                return .of(try await admin.quiesce(req))
            case "/api/control/estate/drain":
                let req = try decoder.decode(EstateLifecycleRequest.self, from: body)
                return .of(try await admin.drain(req))
            case "/api/control/estate/destroy":
                let req = try decoder.decode(EstateLifecycleRequest.self, from: body)
                return .of(try await admin.destroy(req))
            default:
                return .of(EstateAdminResult(ok: false, detail: "unknown admin verb"))
            }
        } catch let error as AdminError {
            // Map the engine's structured validation/guard errors to a refusal
            // result (ok:false) — these are caller errors, not host faults.
            return .of(EstateAdminResult(ok: false, detail: Self.adminErrorDetail(error)))
        } catch let error as DecodingError {
            return .of(EstateAdminResult(ok: false, detail: "malformed admin request body: \(Self.decodingDetail(error))"))
        } catch {
            // GLK / storage failure — a host-side fault. Report ok:false with the
            // reason so the wizard surfaces which phase failed (concepts §1.8).
            logger.error("admin verb \(path, privacy: .public) failed: \(String(describing: error))")
            return .of(EstateAdminResult(ok: false, detail: "estate operation failed: \(error)"))
        }
    }

    /// Human-readable detail for an `AdminError`, surfaced in the verb result.
    static func adminErrorDetail(_ error: AdminError) -> String {
        switch error {
        case let .invalidRequest(detail): return "invalid request: \(detail)"
        case let .unknownEstate(uuid): return "unknown estate '\(uuid)'"
        case .destroyConfirmMismatch: return "destroy refused: confirm name does not match the estate name"
        }
    }

    /// A short reason string for a `DecodingError` (which field/shape was wrong).
    static func decodingDetail(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, _): return "missing field '\(key.stringValue)'"
        case let .typeMismatch(_, ctx): return ctx.debugDescription
        case let .valueNotFound(_, ctx): return ctx.debugDescription
        case let .dataCorrupted(ctx): return ctx.debugDescription
        @unknown default: return "decoding error"
        }
    }

    // MARK: - Test support

    /// The concurrency gate for this server. Exposed so tests can inspect
    /// gate depth without going through the full resident-host harness.
    var testConnGate: MootMgrConnGate { connGate }

    // MARK: - Shed response

    /// Write an HTTP 503 Service Unavailable response to `fd` and close it.
    /// Called on the accept thread when the connection cap is reached, before
    /// any request parsing or auth check runs. Mirrors the Rust port's
    /// `send_shed_response`. The `shutdown(.send)` after writing ensures a
    /// FIN is sent so the client sees a clean EOF and can parse the body.
    static func sendShedResponse(fd: Int32) {
        let body = Data(#"{"error":"service_unavailable","retry_after":1}"#.utf8)
        let head = "HTTP/1.1 503 Service Unavailable\r\n" +
            "Content-Type: application/json\r\n" +
            "Retry-After: 1\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        let headData = Data(head.utf8)
        headData.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
        body.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
        // Graceful shutdown: send FIN so the client can read the response body
        // before the connection closes. Mirrors Rust `stream.shutdown(Write)`.
        Darwin.shutdown(fd, SHUT_WR)
    }

    // MARK: - Auth helpers

    /// Constant-time bearer-token check.
    ///
    /// Rejects a nil/empty token and any token shorter than 16 characters (a
    /// short token is not a credential — treat the control surface as closed
    /// rather than guessable). The comparison is constant-time over the token
    /// bytes so a timing side-channel cannot probe the secret.
    func isAuthorized(_ presented: String?) -> Bool {
        guard controlToken.count >= 16 else { return false }
        guard let presented, presented.count == controlToken.count else { return false }
        return Self.constantTimeEqual(presented, controlToken)
    }

    /// Constant-time string equality over UTF-8 bytes. Folds all byte diffs into
    /// one accumulator so the loop time does not reveal the first mismatch.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    /// True if the Origin header is acceptable for a control write: absent
    /// (curl / native fetch with no Origin) or a loopback origin. Any other
    /// origin is cross-origin and rejected (CSRF guard).
    ///
    /// The scheme+host prefix is matched exactly and the suffix validated to be
    /// empty or a port — this is equivalent to extracting the host and comparing
    /// it. Prefix-only comparison would accept attacker-owned names like
    /// `localhost.evil` or `127.0.0.1.evil` (the DNS-rebinding spoofing vector).
    static func isOriginAllowed(_ origin: String?) -> Bool {
        guard let origin else { return true }
        let lowered = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return true }
        return Self.isLoopbackOrigin(lowered)
    }

    /// True if `origin` (already lowercased) is an exact loopback origin.
    /// The check matches one of six canonical loopback scheme+host prefixes
    /// and then validates the suffix is empty (bare host) or a port (`:<digits>`).
    /// Prefix-only comparison would accept attacker-owned names like
    /// `localhost.evil` or `127.0.0.1.evil`; the suffix validation closes that gap.
    private static func isLoopbackOrigin(_ origin: String) -> Bool {
        [
            "http://127.0.0.1",
            "http://localhost",
            "https://127.0.0.1",
            "https://localhost",
            "http://[::1]",
            "https://[::1]",
        ].contains { prefix in
            guard origin.hasPrefix(prefix) else { return false }
            return Self.isValidOriginSuffix(String(origin.dropFirst(prefix.count)))
        }
    }

    /// True if `suffix` is the remainder of an origin after the loopback host:
    /// either empty (bare host) or `:` followed by one or more digits (port).
    private static func isValidOriginSuffix(_ suffix: String) -> Bool {
        if suffix.isEmpty { return true }
        guard suffix.first == ":" else { return false }
        let port = suffix.dropFirst()
        return !port.isEmpty && port.allSatisfy(\.isNumber)
    }

    /// True if the Host header is acceptable for a GET route: absent/empty (curl /
    /// native connections that omit Host) or a loopback host+port pair.
    ///
    /// The Host header contains only `host` or `host:port`, never a scheme. IPv6
    /// literals carry brackets: `[::1]` or `[::1]:PORT`. Absent/empty Host is
    /// allowed — curl and direct native connections may omit it.
    ///
    /// Mirrors Rust `is_loopback_host`. Called from `serve(_:)` to block DNS
    /// rebinding attacks on the unauthenticated GET routes.
    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return true // absent or empty — allow (curl / direct native connections)
        }
        let lower = host.lowercased()
        // Strip port. IPv6 literals `[::1]` or `[::1]:PORT` need special handling
        // because they contain colons inside the brackets.
        let bare: String
        if lower.hasPrefix("[") {
            // Extract the content inside the leading `[…]`.
            bare = lower
                .components(separatedBy: "]").first
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[")) }
                ?? lower
        } else {
            // IPv4 or hostname: strip port after the LAST colon so
            // "127.0.0.1:4242" → "127.0.0.1".
            if let lastColon = lower.lastIndex(of: ":") {
                bare = String(lower[lower.startIndex..<lastColon])
            } else {
                bare = lower
            }
        }
        return bare == "127.0.0.1" || bare == "localhost" || bare == "::1"
    }

    // MARK: - SSE live tail

    /// Stream recent events as Server-Sent Events. Holds the connection open and
    /// polls the store on a fixed cadence, emitting events newer than the last
    /// one sent. Metadata only — same projection as the snapshot path. Closes
    /// the fd when the stream ends.
    ///
    /// The poll cadence (not a push) is deliberate: the Phase-1 store has no
    /// change-notification hook, so the live tail is a bounded poll. 1s keeps
    /// the dashboard feeling live without hammering SQLite. The stream is bounded
    /// by a deadline so a forgotten client cannot run forever in a headless
    /// context; the browser reconnects automatically.
    func streamEvents(fd: Int32) async {
        // LoopbackHTTP owns the SSE wire framing (the text/event-stream head and
        // the `data: …` frame encoding); this method owns the stream's source
        // (the store poll), its cadence, and the connection lifetime.
        let sse = SSEStream(fd: fd)
        guard sse.writeHead() else { close(fd); return }

        var lastSent = Date(timeIntervalSince1970: 0)
        let deadline = clock().addingTimeInterval(3600)

        while clock() < deadline && running.get() {
            let snapshot: EventsPayload
            do { snapshot = try await manager.eventsPayload(limit: 200) }
            catch { break }
            // eventsPayload is newest-first; emit oldest-of-the-new first so the
            // client sees chronological order, and advance lastSent.
            let fresh = snapshot.events.reversed().filter { ev in
                guard let d = Self.parseISO(ev.ts) else { return false }
                return d > lastSent
            }
            var sendFailed = false
            for ev in fresh {
                if let d = Self.parseISO(ev.ts) { lastSent = max(lastSent, d) }
                if let data = try? APIJSON.encode(ev),
                   let json = String(data: data, encoding: .utf8) {
                    if !sse.send(json) {
                        sendFailed = true; break
                    }
                }
            }
            if sendFailed { break }   // peer hung up
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        close(fd)
    }

    /// Extract a single query-string value by key from a raw `a=b&c=d` query.
    ///
    /// Returns the percent-decoded value for `key`, or nil if absent. Only the
    /// first occurrence is honoured. Used by `GET /api/graph` for the optional
    /// `?estate=` filter; kept tiny and dependency-free (the wire parser does not
    /// decompose the query itself).
    static func queryValue(_ key: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.first.map(String.init) == key else { continue }
            let raw = kv.count > 1 ? String(kv[1]) : ""
            return raw.removingPercentEncoding ?? raw
        }
        return nil
    }

    /// Parse an ISO-8601 UTC timestamp produced by `MootManager.iso8601String`.
    static func parseISO(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.date(from: s)
    }
}

// MARK: - RunningFlag

/// A tiny thread-safe boolean shared between the actor and the blocking accept
/// thread. The accept loop runs outside actor isolation, so it needs a
/// Sendable, lock-guarded flag rather than actor-isolated state.
final class RunningFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
