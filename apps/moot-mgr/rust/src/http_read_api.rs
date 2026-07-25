// http_read_api.rs — Rust twin of the Swift moot-mgr HTTPReadAPI.swift.
//
// The loopback HTTP read-API: serves the read-plane endpoints from the
// ObserverSink stats store, the static dashboard assets, plus a token+Origin-
// gated control surface. Also exposes `apply_control` — the shared verb
// dispatcher both gated surfaces (this HTTP control path and the local IPC
// ControlChannel) route through, so both behave identically.
//
// ============================ SECURITY BOUNDARY =============================
// This is an MCP-adjacent endpoint. Read this block before changing any binding
// or auth check.
//
//  * LOOPBACK ONLY. The listening socket binds to 127.0.0.1 explicitly
//    (`TcpListener::bind("127.0.0.1:port")`). We NEVER bind 0.0.0.0. Off-host
//    peers cannot reach the port at all.
//
//  * READ ENDPOINTS ARE UNAUTHENTICATED BUT READ-ONLY. GET /api/server,
//    /api/estates, /api/events, /api/config, /api/graph return metadata only
//    (counts, enums, ISO-8601 timestamps). No memory/rung content ever crosses
//    this surface. A loopback-only, read-only GET can neither leak content nor
//    mutate state.
//
//  * CONTROL OVER HTTP IS GATED. POST /api/control/* (monitoring on/off, set
//    retention, estate provision/lifecycle) requires BOTH:
//      - a Bearer token (Authorization: Bearer <token>), compared in constant
//        time against the host-injected token; a missing or short token is
//        rejected 401; and
//      - an Origin check — the request must have NO Origin header (curl / same-
//        origin fetch) or a loopback Origin. A cross-origin Origin is rejected
//        403. This blocks CSRF from other local web pages.
//    Control is NEVER exposed over plain unauthenticated HTTP. The preferred
//    privileged path is the Unix domain socket (control_channel.rs); this HTTP
//    control surface exists for the browser dashboard's injected token.
// ===========================================================================
//
// Implementation: a hand-rolled std::net loopback listener + minimal HTTP
// parser, mirroring the ARIA_MCP Rust server (per bounded loopback HTTP the
// shared LoopbackHTTP library is Swift-only; the Rust vertical hand-rolls its
// own transport — parity is enforced at the wire, not the transport). Each
// accepted connection is served on a dedicated thread.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

use crate::admin_payloads::{EstateAdminResult, EstateLifecycleRequest, EstateAdminRequest};
use crate::api_payloads::{encode_sorted, ControlResult, EstatesPayload};
use crate::estate_admin::{AdminError, EstateAdmin};
use crate::manager::MootManager;

/// Header block cap — guards against an unbounded read from a misbehaving
/// (loopback-but-hostile) peer. Matches the ARIA_MCP Rust default.
const MAX_HEADER_BYTES: usize = 64 * 1024;
/// Request body cap for control POSTs.
const MAX_BODY_BYTES: usize = 1024 * 1024;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Connection concurrency cap
//
// A loopback-only, single-user local control server. 16 concurrent connections
// is generous for any realistic local dashboard or CLI tool, and low enough to
// protect against a caller that opens many blocking connections before the
// auth/control checks run (CAND-011 MEDIUM finding).
//
// The gate protocol:
//   1. try_enqueue() — NON-BLOCKING on the accept thread. Increments the
//      active count; returns false immediately when the depth limit is hit.
//      The accept thread then sheds the connection with HTTP 503 + Retry-After
//      and loops back to accept(). The accept thread NEVER blocks on the gate.
//   2. release() — called when the connection handler finishes (including on
//      error/timeout paths). Decrements active count and wakes waiting workers.
//
// Slot-leak invariant: every successful try_enqueue() MUST be paired with
// exactly one release(). The RAII guard (OnDrop) is bound on the ACCEPT
// THREAD immediately after try_enqueue succeeds, then moved into the worker
// closure. If std::thread::Builder::spawn fails (OS resource limit), the
// closure and guard are dropped by the Err destructor — releasing the slot
// automatically. If spawn succeeds, the guard lives in the worker and
// releases on any exit path (normal completion, panic, read-timeout).
//
// Note: wait_for_slot() is present on LoopbackConnGate for structural parity
// with AriaMcpKit's two-phase gate. It is NOT called in the accept loop:
// in the current single-layer design try_enqueue only returns true when a
// slot is immediately available, and calling wait_for_slot after the guard
// is bound would risk a double-release on the Condvar path.
// ─────────────────────────────────────────────────────────────────────────────

/// Maximum concurrent connections for the moot-mgr loopback control/read-API server.
///
/// 16 is generous for a single-user local management surface (dashboard, CLI).
/// Connections beyond this cap are shed with HTTP 503 + `Retry-After: 1` rather
/// than allowed to accumulate as unbounded blocking threads. Mirrors the cap in
/// the Swift port (`MootMgrMaxLoopbackConnections`). Adjust via
/// `MOOT_MGR_HTTP_MAX_CONNECTIONS` env var if needed for unusual deployments.
const MAX_LOOPBACK_CONNECTIONS: usize = 16;

/// Counting-semaphore gate that bounds the number of simultaneous in-flight
/// connections on the moot-mgr loopback HTTP server. Thread-safe via
/// `Mutex<usize>` + `Condvar` (the canonical Rust pattern; std lacks a built-in
/// semaphore). Mirrors AriaMcpKit's Rust `ConcurrencyGate`.
///
/// The accept thread calls `try_enqueue()` (non-blocking); the spawned worker
/// thread calls `wait_for_slot()` (blocking Condvar wait). Call `release()` when
/// the connection handler finishes. Missing a `release()` leaks a slot and
/// eventually deadlocks the server — always pair via RAII (OnDrop guard).
pub struct LoopbackConnGate {
    /// Hard limit on simultaneously-served connections.
    max_concurrent: usize,
    /// Number of connections currently active (waiting or serving).
    /// Incremented by `try_enqueue`, decremented by `release`.
    active: Mutex<usize>,
    /// Signalled by `release()` whenever a slot becomes free.
    cvar: Condvar,
}

impl LoopbackConnGate {
    pub(crate) fn new(max_concurrent: usize) -> Arc<Self> {
        Arc::new(Self {
            max_concurrent,
            active: Mutex::new(0),
            cvar: Condvar::new(),
        })
    }

    /// Test-only constructor: returns an owned (non-Arc) gate for gate-unit
    /// tests that don't need shared ownership.
    #[doc(hidden)]
    pub fn new_for_test(max_concurrent: usize) -> Self {
        Self {
            max_concurrent,
            active: Mutex::new(0),
            cvar: Condvar::new(),
        }
    }

    /// Phase 1 (accept thread, NON-BLOCKING): test whether a new connection
    /// fits within the cap. Returns `true` and increments the active count if
    /// so (caller MUST call `release()` when done); returns `false` if the cap
    /// is already reached (caller should shed with HTTP 503 and close).
    ///
    /// This method NEVER blocks — no Condvar wait, no parking. `&self` is
    /// accepted so the method works with both `Arc<LoopbackConnGate>` (via
    /// Deref) and owned values in tests.
    pub fn try_enqueue(&self) -> bool {
        let mut count = self.active.lock().unwrap();
        if *count >= self.max_concurrent {
            return false;
        }
        *count += 1;
        true
    }

    /// Phase 2 (worker thread, BLOCKING): wait until a concurrency slot is free.
    /// Must be called after a successful `try_enqueue()`, before serving the
    /// request. In the current single-layer design (`max_concurrent` cap, no
    /// separate queued-but-waiting tier), `try_enqueue` only returns true when a
    /// slot is immediately available, so this call returns without waiting. It is
    /// present for structural parity with AriaMcpKit's gate and to support future
    /// two-tier extension without changing the call sites.
    pub fn wait_for_slot(&self) {
        let mut count = self.active.lock().unwrap();
        while *count > self.max_concurrent {
            count = self.cvar.wait(count).unwrap();
        }
    }

    /// Release a previously acquired slot. Decrements the active count and wakes
    /// all waiting worker threads so each can re-check the cap condition.
    /// `notify_all()` is correct here: a single burst of completions should wake
    /// all eligible waiters, not just one per release event.
    pub fn release(&self) {
        let mut count = self.active.lock().unwrap();
        if *count > 0 {
            *count -= 1;
        }
        self.cvar.notify_all();
    }

    /// Current active count. Informational; used by tests and gate accessor.
    pub fn current_depth(&self) -> usize {
        *self.active.lock().unwrap()
    }
}

/// Write an HTTP 503 Service Unavailable response to the stream and close.
/// Called on the accept thread when the connection cap is reached, before any
/// request parsing or auth check. Mirrors AriaMcpKit's `send_shed_response`.
///
/// The explicit `shutdown(Write)` after flushing ensures the kernel sends a
/// FIN rather than a RST, so clients receive a clean EOF and can parse the
/// response body before the connection closes.
fn send_shed_response(stream: &mut TcpStream) {
    let body = br#"{"error":"service_unavailable","retry_after":1}"#;
    let head = format!(
        "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nRetry-After: 1\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body);
    let _ = stream.flush();
    let _ = stream.shutdown(std::net::Shutdown::Write);
}

/// RAII guard that runs a closure on drop. Used to guarantee slot release even
/// when the connection handler panics, times out, or returns early. MUST be
/// bound to a named `let` variable so the drop is deferred to end-of-scope.
struct OnDrop<F: FnOnce()>(Option<F>);
impl<F: FnOnce()> Drop for OnDrop<F> {
    fn drop(&mut self) {
        if let Some(f) = self.0.take() {
            f();
        }
    }
}
fn defer_on_drop<F: FnOnce()>(f: F) -> OnDrop<F> {
    OnDrop(Some(f))
}

/// A pre-encoded control-verb response: the JSON body plus the `ok` flag that
/// picks the HTTP status code. The gated surfaces both call `apply_control` and
/// need ONE encode path even though different verbs return different result
/// shapes (`ControlResult` vs `EstateAdminResult`). Mirrors Swift `ControlResponse`.
pub struct ControlResponse {
    /// Whether the verb succeeded (drives the HTTP status: 200 vs 400).
    pub ok: bool,
    /// The encoded JSON body (sorted-keys, compact).
    pub json: Vec<u8>,
}

impl ControlResponse {
    /// Wrap a `ControlResult`, encoding it once.
    pub fn of_control(result: &ControlResult) -> Self {
        Self::encode(result.ok, result)
    }

    /// Wrap an `EstateAdminResult`, encoding it once.
    pub fn of_admin(result: &EstateAdminResult) -> Self {
        Self::encode(result.ok, result)
    }

    fn encode<T: serde::Serialize>(ok: bool, value: &T) -> Self {
        match encode_sorted(value) {
            Ok(json) => ControlResponse { ok, json },
            Err(_) => ControlResponse {
                ok: false,
                json: br#"{"detail":"encode","ok":false}"#.to_vec(),
            },
        }
    }
}

/// A parsed HTTP request — only the fields the read-API routes on.
struct HttpRequest {
    method: String,
    /// Path without the query string.
    path: String,
    /// Raw query string (after '?'), empty when absent.
    query: String,
    /// The Authorization bearer token, if present.
    bearer_token: Option<String>,
    /// The Origin header, if present.
    origin: Option<String>,
    /// The Host header, if present. Used for DNS-rebinding protection on GET
    /// routes: any Host that is not a loopback address is rejected 421.
    host: Option<String>,
    /// The request body bytes (control POSTs).
    body: Vec<u8>,
}

/// The loopback HTTP server exposing the read-API and the gated control surface.
/// One instance per resident host. Mirrors Swift `HTTPReadAPI`.
pub struct HttpReadApi {
    manager: Arc<Mutex<MootManager>>,
    /// The admin engine the control surface routes provision/lifecycle verbs to.
    /// Reached ONLY after the gate (token+Origin over HTTP, or 0600 UDS).
    admin: Arc<Mutex<EstateAdmin>>,
    requested_port: u16,
    /// The bearer token required for POST /api/control/* over HTTP. A token
    /// shorter than 16 chars disables the control surface (treated as "no
    /// credential" — see `is_authorized`).
    control_token: String,
    /// Process start instant (epoch seconds) for the /api/server uptime.
    start_instant_epoch: f64,
    running: Arc<AtomicBool>,
    bound_port: Arc<AtomicU16>,
    accept_thread: Mutex<Option<JoinHandle<()>>>,
    /// Bounded concurrency gate. Limits simultaneous in-flight connections to
    /// `MAX_LOOPBACK_CONNECTIONS` (default 16). Connections beyond the cap are
    /// shed with HTTP 503 + Retry-After before any request parsing runs.
    /// Configurable via `MOOT_MGR_HTTP_MAX_CONNECTIONS` env var.
    conn_gate: Arc<LoopbackConnGate>,
}

impl HttpReadApi {
    /// Create the read-API server. `port` 0 = OS-assigned (handy for tests).
    /// Mirrors Swift `HTTPReadAPI.init(...)`.
    pub fn new(
        manager: Arc<Mutex<MootManager>>,
        admin: Arc<Mutex<EstateAdmin>>,
        port: u16,
        control_token: String,
        start_instant_epoch: f64,
    ) -> Self {
        // Read the connection cap from the environment; default to the module
        // constant. Clamped to [1, 1024] so a misconfigured value can't make the
        // server either unsecured (0) or permanently broken (overflow).
        let max_connections = std::env::var("MOOT_MGR_HTTP_MAX_CONNECTIONS")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(MAX_LOOPBACK_CONNECTIONS)
            .clamp(1, 1024);
        HttpReadApi {
            manager,
            admin,
            requested_port: port,
            control_token,
            start_instant_epoch,
            running: Arc::new(AtomicBool::new(false)),
            bound_port: Arc::new(AtomicU16::new(0)),
            accept_thread: Mutex::new(None),
            conn_gate: LoopbackConnGate::new(max_connections),
        }
    }

    /// Create the read-API server with an explicit connection cap. Used by
    /// test harnesses that need precise control over the gate capacity without
    /// mutating the process environment.
    #[doc(hidden)]
    pub fn new_with_cap(
        manager: Arc<Mutex<MootManager>>,
        admin: Arc<Mutex<EstateAdmin>>,
        port: u16,
        control_token: String,
        start_instant_epoch: f64,
        max_connections: usize,
    ) -> Self {
        HttpReadApi {
            manager,
            admin,
            requested_port: port,
            control_token,
            start_instant_epoch,
            running: Arc::new(AtomicBool::new(false)),
            bound_port: Arc::new(AtomicU16::new(0)),
            accept_thread: Mutex::new(None),
            conn_gate: LoopbackConnGate::new(max_connections),
        }
    }

    /// Bind the listening socket to 127.0.0.1:port and start the accept loop on a
    /// dedicated thread. Mirrors Swift `HTTPReadAPI.start()`.
    pub fn start(self: Arc<Self>) -> std::io::Result<()> {
        let listener = TcpListener::bind(("127.0.0.1", self.requested_port))?;
        let bound = listener.local_addr()?.port();
        self.bound_port.store(bound, Ordering::SeqCst);
        self.running.store(true, Ordering::SeqCst);

        let this = Arc::clone(&self);
        let running = Arc::clone(&self.running);
        let gate = Arc::clone(&self.conn_gate);
        let handle = std::thread::Builder::new()
            .name("moot-mgr.HttpReadApi.accept".to_string())
            .spawn(move || {
                for stream in listener.incoming() {
                    if !running.load(Ordering::SeqCst) {
                        break;
                    }
                    match stream {
                        Ok(mut s) => {
                            // Phase 1 (accept thread, NON-BLOCKING): check the
                            // connection cap. If the cap is reached, shed the
                            // connection immediately with HTTP 503 + Retry-After.
                            // The accept loop never parks inside the gate.
                            if !gate.try_enqueue() {
                                send_shed_response(&mut s);
                                continue;
                            }
                            // Bind the slot-release guard HERE on the accept thread,
                            // immediately after try_enqueue succeeds. If
                            // std::thread::Builder::spawn fails below (OS thread or
                            // resource limit), the closure passed to spawn is dropped
                            // with the Err — and this guard is dropped with it —
                            // releasing the slot automatically. No manual cleanup
                            // needed on the spawn-failure path.
                            //
                            // If spawn succeeds, the guard moves into the worker
                            // thread and releases the slot on any exit path:
                            // normal completion, panic, or read-timeout.
                            let gate_clone = Arc::clone(&gate);
                            let slot_guard = defer_on_drop(move || gate_clone.release());
                            let served = Arc::clone(&this);
                            // Serve each connection on its own thread so a slow
                            // peer never blocks the accept loop.
                            let spawn_result = std::thread::Builder::new()
                                .name("moot-mgr.HttpReadApi.conn".to_string())
                                .spawn(move || {
                                    // slot_guard is dropped (releasing the slot) on
                                    // any exit path from this closure: normal return,
                                    // panic, or read-timeout. The named binding is
                                    // required — an unbound defer_on_drop(...) would
                                    // drop immediately at the let site.
                                    let _slot_guard = slot_guard;
                                    served.serve(s);
                                });
                            if let Err(e) = spawn_result {
                                // Spawn failed (OS thread/resource limit). The closure
                                // above (and slot_guard) was dropped by the Err
                                // destructor, so the gate slot is already released.
                                // The TcpStream s was also dropped with the closure,
                                // closing the connection from our side.
                                eprintln!("moot-mgr: worker thread spawn failed: {e}");
                            }
                        }
                        Err(_) => {
                            if !running.load(Ordering::SeqCst) {
                                break;
                            }
                        }
                    }
                }
            })?;
        *self.accept_thread.lock().unwrap() = Some(handle);
        Ok(())
    }

    /// Stop accepting connections. Idempotent. Mirrors Swift `HTTPReadAPI.stop()`.
    ///
    /// Closing the loopback listener is achieved by flipping `running` and poking
    /// the listener with a throwaway loopback connection so `incoming()` wakes and
    /// observes the flag (the same unblock-the-accept trick the Swift port uses by
    /// closing the listening fd).
    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        let port = self.bound_port.load(Ordering::SeqCst);
        if port != 0 {
            let _ = TcpStream::connect(("127.0.0.1", port));
        }
        if let Some(handle) = self.accept_thread.lock().unwrap().take() {
            let _ = handle.join();
        }
    }

    /// The port the listener is bound to (resolves an OS-assigned port). Mirrors
    /// Swift `HTTPReadAPI.boundPort()`.
    pub fn bound_port(&self) -> u16 {
        let bound = self.bound_port.load(Ordering::SeqCst);
        if bound != 0 {
            bound
        } else {
            self.requested_port
        }
    }

    // MARK: - Connection handling

    /// Serve one accepted connection: read the request, route it, respond.
    ///
    /// A 30-second read timeout is set on the accepted socket before the
    /// request parser runs. This bounds the DoS window where a slow peer
    /// can hold a thread indefinitely by sending bytes one at a time —
    /// mirrors the Swift port's `SO_RCVTIMEO` setsockopt on the accepted fd.
    fn serve(&self, mut stream: TcpStream) {
        // Bound blocking reads: a peer that trickles bytes cannot stall a
        // handler thread longer than this window.
        let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(30)));
        let request = match read_request(&mut stream) {
            Some(r) => r,
            None => return,
        };
        let (status, content_type, body) = self.route(&request);
        write_response(&mut stream, status, &content_type, &body);
    }

    /// Route a parsed request to a (status, content-type, body). Mirrors Swift
    /// `HTTPReadAPI.route(_:)`.
    fn route(&self, request: &HttpRequest) -> (u16, String, Vec<u8>) {
        let now = self.start_instant_epoch.max(0.0);
        // The Rust host's clock for snapshot timestamps is the host start instant
        // plus the wall-time since start; but to keep the read surface
        // deterministic without a clock dependency in the engine, the host stamps
        // snapshots with `now = start_instant + uptime`. uptime is computed from
        // the system clock here at the HTTP boundary (the read plane may read the
        // clock — determinism applies to engines, not this projection).
        let wall_now = unix_now_secs();
        let uptime = (wall_now - self.start_instant_epoch).max(0.0) as i64;
        let _ = now;

        match (request.method.as_str(), request.path.as_str()) {
            // DNS-rebinding guard: reject any GET whose Host header is present
            // but not a loopback address. The browser always sends Host; a
            // rebinding attack uses a non-loopback host that resolves to
            // 127.0.0.1. 421 Misdirected Request tells the client this virtual
            // host is not served here. Absent/empty Host is allowed (curl, direct
            // native connections). POST /api/control/* is already gated by
            // Origin + Bearer token, which provides stronger protection there.
            ("GET", _) if !is_loopback_host(request.host.as_deref()) => (
                421,
                "application/json".to_string(),
                br#"{"error":"misdirected_request"}"#.to_vec(),
            ),
            ("GET", "/api/server") => self.json_response(|m| {
                m.server_payload(wall_now, uptime).map_err(err_string)
            }),
            ("GET", "/api/estates") => {
                // Keep the manager's event-derived estates list and overwrite admin
                // with the local EstateAdmin payload. The manager may populate
                // base.admin from the daemon proxy, but this route always replaces it
                // with the local admin plane section.
                let base = self.manager.lock().unwrap().estates_payload();
                match base {
                    Ok(base) => {
                        let admin_section = self.admin.lock().unwrap().payload();
                        let merged = EstatesPayload {
                            estates: base.estates,
                            admin: Some(admin_section),
                        };
                        self.encode_ok(&merged)
                    }
                    Err(e) => self.internal_error(&err_string(e)),
                }
            }
            ("GET", "/api/config") => {
                self.json_response(|m| m.config_payload().map_err(err_string))
            }
            ("GET", "/api/graph") => {
                let estate = query_value("estate", &request.query);
                let level = query_value("level", &request.query);
                let focus = query_value("focus", &request.query);
                self.json_response(|m| {
                    m.graph_payload_view(
                        wall_now, estate.as_deref(), level.as_deref(), focus.as_deref())
                        .map_err(err_string)
                })
            }
            ("GET", "/api/events") => {
                self.json_response(|m| m.events_payload(100).map_err(err_string))
            }
            // GET /api/lexicon — ARIA grammar vocabulary + LatticeLib metadata.
            // Built from aria-lexicon-lib compile-time enums and lattice-lib runtime
            // state; infallible (no store I/O). Matches the Swift host's lexiconPayload().
            ("GET", "/api/lexicon") => {
                let payload = self.manager.lock().unwrap().lexicon_payload();
                self.encode_ok(&payload)
            }
            // GET /api/lattice — lattice address snapshot.
            // Delegates to MootManager::lattice_payload, which proxies the daemon's
            // /api/lattice endpoint and returns live addresses with pending:false on
            // success. The degraded state (pending:true, addresses:[]) is the fallback
            // on connection, HTTP, or decode failure.
            ("GET", "/api/lattice") => {
                let payload = self.manager.lock().unwrap().lattice_payload();
                self.encode_ok(&payload)
            }
            ("POST", path) if path.starts_with("/api/control/") => self.handle_control(request),
            ("GET", path) => {
                // Static-asset allow-list (fixed map — no directory traversal).
                match crate::static_assets::asset_for(path) {
                    Some(asset) => (200, asset.content_type.to_string(), asset.body.into_bytes()),
                    None => not_found(),
                }
            }
            _ => not_found(),
        }
    }

    /// Build a 200 JSON response from a fallible payload builder against the
    /// manager, mapping failures to 500. Mirrors Swift `HTTPReadAPI.jsonResponse`.
    fn json_response<T, F>(&self, build: F) -> (u16, String, Vec<u8>)
    where
        T: serde::Serialize,
        F: FnOnce(&MootManager) -> Result<T, String>,
    {
        let result = {
            let guard = self.manager.lock().unwrap();
            build(&guard)
        };
        match result {
            Ok(value) => self.encode_ok(&value),
            Err(reason) => self.internal_error(&reason),
        }
    }

    fn encode_ok<T: serde::Serialize>(&self, value: &T) -> (u16, String, Vec<u8>) {
        match encode_sorted(value) {
            Ok(body) => (200, "application/json".to_string(), body),
            Err(e) => self.internal_error(&format!("{e}")),
        }
    }

    fn internal_error(&self, _reason: &str) -> (u16, String, Vec<u8>) {
        (
            500,
            "application/json".to_string(),
            br#"{"error":"internal"}"#.to_vec(),
        )
    }

    // MARK: - Control surface (gated)

    /// Handle a POST /api/control/* request: enforce Origin + token, then apply
    /// the verb. Mirrors Swift `HTTPReadAPI.handleControl(_:)`.
    fn handle_control(&self, request: &HttpRequest) -> (u16, String, Vec<u8>) {
        // 1. Origin check (CSRF guard) — runs BEFORE the token is examined.
        if !is_origin_allowed(request.origin.as_deref()) {
            return (
                403,
                "application/json".to_string(),
                br#"{"error":"forbidden_origin"}"#.to_vec(),
            );
        }
        // 2. Bearer token check (constant-time compare).
        if !self.is_authorized(request.bearer_token.as_deref()) {
            return (
                401,
                "application/json".to_string(),
                br#"{"error":"unauthorized"}"#.to_vec(),
            );
        }
        // 3. Apply the verb.
        let response = self.apply_control(&request.path, &request.body);
        let status = if response.ok { 200 } else { 400 };
        (status, "application/json".to_string(), response.json)
    }

    /// Apply a control verb identified by the request path. Shared by the HTTP
    /// control surface and (via `ControlChannel`) the UDS surface, so both gated
    /// surfaces have identical semantics. Read/retention verbs return a
    /// `ControlResult`; admin verbs return an `EstateAdminResult`. Mirrors Swift
    /// `HTTPReadAPI.applyControl(path:body:)`.
    ///
    /// Verbs:
    ///   POST /api/control/monitoring/on    → enable monitoring
    ///   POST /api/control/monitoring/off   → disable monitoring
    ///   POST /api/control/retention        → set retention; body {"seconds":N}
    ///   POST /api/control/estate/provision → provision a new estate
    ///   POST /api/control/estate/quiesce|drain|destroy → lifecycle
    pub fn apply_control(&self, path: &str, body: &[u8]) -> ControlResponse {
        match path {
            "/api/control/monitoring/on" => {
                match self.manager.lock().unwrap().set_monitoring(true) {
                    Ok(()) => ControlResponse::of_control(&ControlResult::new(true, "monitoring: ON")),
                    Err(_) => ControlResponse::of_control(&ControlResult::new(false, "error")),
                }
            }
            "/api/control/monitoring/off" => {
                match self.manager.lock().unwrap().set_monitoring(false) {
                    Ok(()) => ControlResponse::of_control(&ControlResult::new(true, "monitoring: OFF")),
                    Err(_) => ControlResponse::of_control(&ControlResult::new(false, "error")),
                }
            }
            "/api/control/retention" => {
                let seconds = serde_json::from_slice::<serde_json::Value>(body)
                    .ok()
                    .and_then(|v| v.get("seconds").and_then(|s| s.as_i64()))
                    .filter(|s| *s > 0);
                match seconds {
                    Some(s) => match self.manager.lock().unwrap().set_retention(s) {
                        Ok(()) => ControlResponse::of_control(&ControlResult::new(
                            true,
                            format!("retention: {s}s"),
                        )),
                        Err(_) => ControlResponse::of_control(&ControlResult::new(
                            false,
                            "invalid retention seconds",
                        )),
                    },
                    None => ControlResponse::of_control(&ControlResult::new(
                        false,
                        "invalid retention seconds",
                    )),
                }
            }
            "/api/control/estate/provision"
            | "/api/control/estate/quiesce"
            | "/api/control/estate/drain"
            | "/api/control/estate/destroy" => self.apply_admin_control(path, body),
            _ => ControlResponse::of_control(&ControlResult::new(false, "unknown control verb")),
        }
    }

    /// Dispatch an admin verb to the `EstateAdmin` engine. Reached only from
    /// `apply_control` — and therefore only AFTER the gate. Mirrors Swift
    /// `HTTPReadAPI.applyAdminControl(path:body:)`.
    fn apply_admin_control(&self, path: &str, body: &[u8]) -> ControlResponse {
        // The Rust admin engine threads an explicit `now` for the audit-stamp
        // seam; the read plane may read the clock at this boundary.
        let now = unix_now_secs() as i64;
        let mut admin = self.admin.lock().unwrap();
        let result: Result<EstateAdminResult, AdminControlError> = match path {
            "/api/control/estate/provision" => {
                serde_json::from_slice::<EstateAdminRequest>(body)
                    .map_err(AdminControlError::Decode)
                    .and_then(|req| admin.provision(&req, now).map_err(AdminControlError::Admin))
            }
            "/api/control/estate/quiesce" => {
                serde_json::from_slice::<EstateLifecycleRequest>(body)
                    .map_err(AdminControlError::Decode)
                    .and_then(|req| admin.quiesce(&req).map_err(AdminControlError::Admin))
            }
            "/api/control/estate/drain" => {
                serde_json::from_slice::<EstateLifecycleRequest>(body)
                    .map_err(AdminControlError::Decode)
                    .and_then(|req| admin.drain(&req).map_err(AdminControlError::Admin))
            }
            "/api/control/estate/destroy" => {
                serde_json::from_slice::<EstateLifecycleRequest>(body)
                    .map_err(AdminControlError::Decode)
                    .and_then(|req| admin.destroy(&req).map_err(AdminControlError::Admin))
            }
            _ => Ok(EstateAdminResult::of(false, "unknown admin verb")),
        };
        match result {
            Ok(r) => ControlResponse::of_admin(&r),
            Err(AdminControlError::Decode(e)) => ControlResponse::of_admin(&EstateAdminResult::of(
                false,
                format!("malformed admin request body: {e}"),
            )),
            Err(AdminControlError::Admin(e)) => {
                // Map the engine's structured errors to a refusal result.
                ControlResponse::of_admin(&EstateAdminResult::of(false, admin_error_detail(&e)))
            }
        }
    }

    // MARK: - Auth helpers

    /// Constant-time bearer-token check. Rejects a nil/empty token and any token
    /// shorter than 16 chars (a short token is not a credential — treat the
    /// surface as closed). Mirrors Swift `HTTPReadAPI.isAuthorized(_:)`.
    pub fn is_authorized(&self, presented: Option<&str>) -> bool {
        if self.control_token.len() < 16 {
            return false;
        }
        match presented {
            Some(p) if p.len() == self.control_token.len() => {
                constant_time_eq(p.as_bytes(), self.control_token.as_bytes())
            }
            _ => false,
        }
    }
}

/// Internal error union for admin-verb dispatch (decode vs engine).
enum AdminControlError {
    Decode(serde_json::Error),
    Admin(AdminError),
}

/// Human-readable detail for an `AdminError`. Mirrors Swift
/// `HTTPReadAPI.adminErrorDetail`.
fn admin_error_detail(e: &AdminError) -> String {
    e.detail()
}

/// Constant-time byte equality. Folds all byte diffs into one accumulator so the
/// loop time does not reveal the first mismatch. Mirrors Swift
/// `HTTPReadAPI.constantTimeEqual`.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

/// True if the Origin header is acceptable for a control write: absent (curl /
/// native fetch) or an exact loopback origin. Any other origin is rejected
/// (CSRF / DNS-rebinding guard). Mirrors Swift `HTTPReadAPI.isOriginAllowed(_:)`.
///
/// The check parses the scheme prefix and then validates the suffix after the
/// loopback host is empty or a port (`:<digits>`). Prefix-only comparison would
/// accept attacker-owned names like `localhost.evil` or `127.0.0.1.evil`.
pub fn is_origin_allowed(origin: Option<&str>) -> bool {
    match origin.map(str::trim) {
        None | Some("") => true,
        Some(o) => is_loopback_origin(o),
    }
}

/// True if `origin` is an exact loopback origin: scheme is http/https, host is
/// `localhost`, `127.0.0.1`, or `[::1]`, and the only suffix after the host is
/// an optional port (`:` followed by ASCII digits only).
fn is_loopback_origin(origin: &str) -> bool {
    let lo = origin.to_ascii_lowercase();
    [
        "http://127.0.0.1",
        "http://localhost",
        "https://127.0.0.1",
        "https://localhost",
        "http://[::1]",
        "https://[::1]",
    ]
    .iter()
    .any(|prefix| lo.strip_prefix(prefix).is_some_and(is_valid_origin_suffix))
}

/// True if `suffix` is the remainder of an origin after the loopback host:
/// either empty (bare host) or `:` followed by one or more ASCII digits (port).
/// Rejects `.evil`, `@user`, path components, and any other trailing content.
fn is_valid_origin_suffix(suffix: &str) -> bool {
    suffix.is_empty()
        || suffix.strip_prefix(':').is_some_and(|port| {
            !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit())
        })
}

/// True if the Host header is acceptable for a GET route: absent/empty (curl /
/// native connections that omit the Host header) or a loopback host+port pair.
/// Rejects any Host that is not a recognised loopback address.
///
/// Unlike `is_origin_allowed`, this does NOT strip a scheme prefix — the Host
/// header contains only `host` or `host:port`, never a scheme. IPv6 literals
/// carry brackets: `[::1]` or `[::1]:PORT`. Mirrors Swift
/// `HTTPReadAPI.isLoopbackHost(_:)`.
pub fn is_loopback_host(host: Option<&str>) -> bool {
    match host.map(str::trim) {
        None | Some("") => true, // absent or empty — allow (curl / direct)
        Some(h) => {
            let h_lower = h.to_ascii_lowercase();
            // Strip port. IPv6 literals `[::1]` or `[::1]:PORT` require special
            // handling because they contain colons inside the brackets.
            let bare = if h_lower.starts_with('[') {
                // Extract content inside the leading `[…]`.
                let inner = h_lower
                    .split(']')
                    .next()
                    .unwrap_or("")
                    .trim_start_matches('[');
                inner.to_string()
            } else {
                // IPv4 or hostname: strip port after the LAST colon.
                // `rfind` not `find` so "127.0.0.1:4242" → "127.0.0.1".
                match h_lower.rfind(':') {
                    Some(pos) => h_lower[..pos].to_string(),
                    None => h_lower,
                }
            };
            matches!(bare.as_str(), "127.0.0.1" | "localhost" | "::1")
        }
    }
}

/// Extract a single query-string value by key from a raw `a=b&c=d` query.
/// Returns the percent-decoded value for `key`, or `None` if absent. Only the
/// first occurrence is honoured. Mirrors Swift `HTTPReadAPI.queryValue(_:in:)`.
pub fn query_value(key: &str, query: &str) -> Option<String> {
    for pair in query.split('&') {
        let mut kv = pair.splitn(2, '=');
        let k = kv.next().unwrap_or("");
        if k == key {
            let raw = kv.next().unwrap_or("");
            return Some(percent_decode(raw));
        }
    }
    None
}

/// Minimal percent-decoder for query values (no external dep). Decodes `%XX` and
/// `+` → space, leaving invalid sequences verbatim.
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hi = (bytes[i + 1] as char).to_digit(16);
                let lo = (bytes[i + 2] as char).to_digit(16);
                match (hi, lo) {
                    (Some(h), Some(l)) => {
                        out.push((h * 16 + l) as u8);
                        i += 3;
                    }
                    _ => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Stringify a manager error for the read-API 500 path.
fn err_string<E: std::fmt::Debug>(e: E) -> String {
    format!("{e:?}")
}

/// The current Unix time in seconds (f64). Used only at the HTTP/read boundary
/// for snapshot timestamps + uptime — NOT inside any engine (the engines take an
/// explicit `now`). The read plane may read the clock; determinism applies to
/// the store engines, which receive computed values.
fn unix_now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

// ───────────────────────── minimal HTTP transport ──────────────────────────

/// Read and parse one HTTP request from the stream (headers + optional body).
/// Returns `None` on a malformed or oversized request. Hand-rolled to keep the
/// host zero-dependency (mirrors the ARIA_MCP Rust transport's minimal parser).
fn read_request(stream: &mut TcpStream) -> Option<HttpRequest> {
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    // Read until we have the full header block (CRLFCRLF) or hit the cap.
    let header_end = loop {
        if let Some(pos) = find_subsequence(&buf, b"\r\n\r\n") {
            break pos;
        }
        if buf.len() > MAX_HEADER_BYTES {
            return None;
        }
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            // Connection closed before a full header block.
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
    };

    let head = String::from_utf8_lossy(&buf[..header_end]).into_owned();
    let mut lines = head.split("\r\n");
    let request_line = lines.next()?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next()?.to_string();
    let target = parts.next()?.to_string();
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target, String::new()),
    };

    let mut bearer_token = None;
    let mut origin = None;
    let mut host = None;
    let mut content_length = 0usize;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            let name_l = name.trim().to_lowercase();
            let value = value.trim();
            match name_l.as_str() {
                "authorization" => {
                    if let Some(tok) = value.strip_prefix("Bearer ").or_else(|| value.strip_prefix("bearer ")) {
                        bearer_token = Some(tok.trim().to_string());
                    }
                }
                "origin" => origin = Some(value.to_string()),
                // Host header: parsed for DNS-rebinding guard on GET routes.
                "host" => host = Some(value.to_string()),
                "content-length" => content_length = value.parse().unwrap_or(0),
                _ => {}
            }
        }
    }

    // Collect the body (already-buffered bytes after the header block + more).
    let mut body: Vec<u8> = buf[header_end + 4..].to_vec();
    let content_length = content_length.min(MAX_BODY_BYTES);
    while body.len() < content_length {
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(content_length);

    Some(HttpRequest {
        method,
        path,
        query,
        bearer_token,
        origin,
        host,
        body,
    })
}

/// Write an HTTP/1.1 response with the given status, content-type, and body.
fn write_response(stream: &mut TcpStream, status: u16, content_type: &str, body: &[u8]) {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        421 => "Misdirected Request",
        500 => "Internal Server Error",
        _ => "OK",
    };
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(header.as_bytes());
    let _ = stream.write_all(body);
    let _ = stream.flush();
}

/// Find the first index of `needle` in `haystack`, or `None`.
fn find_subsequence(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn not_found() -> (u16, String, Vec<u8>) {
    (404, "text/plain; charset=utf-8".to_string(), b"not found".to_vec())
}

#[cfg(test)]
mod tests {
    use super::is_loopback_host;

    // ── is_loopback_host — DNS-rebinding guard ────────────────────────────────

    #[test]
    fn loopback_host_allows_absent_or_empty() {
        // Absent / empty Host: allow — curl and direct native callers omit it.
        assert!(is_loopback_host(None));
        assert!(is_loopback_host(Some("")));
        assert!(is_loopback_host(Some("   ")));
    }

    #[test]
    fn loopback_host_accepts_ipv4_loopback() {
        assert!(is_loopback_host(Some("127.0.0.1")));
        assert!(is_loopback_host(Some("127.0.0.1:8080")));
        assert!(is_loopback_host(Some("127.0.0.1:65535")));
    }

    #[test]
    fn loopback_host_accepts_localhost_case_insensitive() {
        assert!(is_loopback_host(Some("localhost")));
        assert!(is_loopback_host(Some("LOCALHOST")));
        assert!(is_loopback_host(Some("localhost:9000")));
        assert!(is_loopback_host(Some("LOCALHOST:4242")));
    }

    #[test]
    fn loopback_host_accepts_ipv6_loopback_literal() {
        // Bare, with brackets, with brackets+port.
        assert!(is_loopback_host(Some("[::1]")));
        assert!(is_loopback_host(Some("[::1]:8080")));
        assert!(is_loopback_host(Some("[::1]:65535")));
    }

    #[test]
    fn loopback_host_rejects_cross_origin() {
        assert!(!is_loopback_host(Some("evil.example.com")));
        assert!(!is_loopback_host(Some("evil.example.com:8080")));
        assert!(!is_loopback_host(Some("192.168.1.5")));
        assert!(!is_loopback_host(Some("192.168.1.5:9000")));
        // DNS-rebinding spoofs: must not match because they END with loopback tokens.
        assert!(!is_loopback_host(Some("localhost.evil")));
        assert!(!is_loopback_host(Some("127.0.0.1.evil")));
        assert!(!is_loopback_host(Some("fake-localhost")));
        assert!(!is_loopback_host(Some("not-localhost")));
    }
}
