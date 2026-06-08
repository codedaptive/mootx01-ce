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
//  * READ ENDPOINTS ARE UNAUTHENTICATED BUT READ-ONLY. GET /api/server,
//    /api/estates, /api/events, /api/config return metadata only (counts,
//    enums, ISO-8601 timestamps). No memory/rung content ever crosses this
//    surface (concepts §1.6, GUI SPEC §10). A loopback-only, read-only GET can
//    neither leak content nor mutate state.
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
        admin: EstateAdmin? = nil
    ) {
        self.manager = manager
        self.requestedPort = port
        self.controlToken = controlToken
        self.startInstant = startInstant
        self.clock = clock
        self.admin = admin
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
        // never occupies the cooperative pool. Each accepted connection is
        // handed to the actor for serving.
        let thread = Thread { [weak self, fd, running] in
            while running.get() {
                guard let cfd = POSIXSocket.acceptOne(fd) else {
                    if !running.get() { break }
                    continue
                }
                guard let self else { close(cfd); break }
                Task { await self.serve(cfd) }
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
        guard let request = HTTPRequest.read(fd: fd) else { close(fd); return }
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
            // Merge the admin section (host-provisioned estates + mount state)
            // into the event-derived rollups. Read-only projection — the admin
            // engine's mutating verbs live on the gated control surface, never
            // here (GUI SPEC §4.2: the Estates view reads mount state, dispatches
            // lifecycle over the control channel).
            return await jsonResponse {
                let base = try await self.manager.estatesPayload()
                let adminSection = await self.admin?.payload()
                return EstatesPayload(estates: base.estates, admin: adminSection)
            }
        case ("GET", "/api/config"):
            return await jsonResponse { try await self.manager.configPayload() }
        case ("GET", "/api/graph"):
            // Topology snapshot. The optional ?estate= filter is parsed and
            // forwarded; structure is pending (the resident host has no estate
            // access — see MootManager.graphPayload), so the host serves the
            // available VizGraph analytic overlay and marks nodes/edges pending.
            let estate = Self.queryValue("estate", in: request.query)
            return await jsonResponse { try await self.manager.graphPayload(now: self.clock(), estate: estate) }
        case ("GET", "/api/events"):
            // SSE live-tail (Accept: text/event-stream or ?stream=1) is handled
            // in serve(_:) before routing; here we serve the one-shot JSON
            // snapshot.
            return await jsonResponse { try await self.manager.eventsPayload() }
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
    static func isOriginAllowed(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty else { return true }
        let lowered = origin.lowercased()
        return lowered.hasPrefix("http://127.0.0.1")
            || lowered.hasPrefix("http://localhost")
            || lowered.hasPrefix("https://127.0.0.1")
            || lowered.hasPrefix("https://localhost")
            || lowered.hasPrefix("http://[::1]")
            || lowered.hasPrefix("https://[::1]")
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
