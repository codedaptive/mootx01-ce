// http_read_api.rs — Rust twin of the Swift moot-mgr HTTPReadAPI.swift.
//
// The loopback HTTP read-API: serves the read-plane endpoints from the
// ObserverSink stats store, the static dashboard assets, plus a token+Origin-
// gated control surface. Also exposes `apply_control` — the shared verb
// dispatcher both gated surfaces (this HTTP control path and the UDS
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
// parser, mirroring the ARIA_MCP Rust server (per ADR-LOOPBACKHTTP-001 the
// shared LoopbackHTTP library is Swift-only; the Rust vertical hand-rolls its
// own transport — parity is enforced at the wire, not the transport). Each
// accepted connection is served on a dedicated thread.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::{Arc, Mutex};
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
        HttpReadApi {
            manager,
            admin,
            requested_port: port,
            control_token,
            start_instant_epoch,
            running: Arc::new(AtomicBool::new(false)),
            bound_port: Arc::new(AtomicU16::new(0)),
            accept_thread: Mutex::new(None),
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
        let handle = std::thread::Builder::new()
            .name("moot-mgr.HttpReadApi.accept".to_string())
            .spawn(move || {
                for stream in listener.incoming() {
                    if !running.load(Ordering::SeqCst) {
                        break;
                    }
                    match stream {
                        Ok(s) => {
                            let served = Arc::clone(&this);
                            // Serve each connection on its own thread so a slow
                            // peer never blocks the accept loop.
                            let _ = std::thread::Builder::new()
                                .name("moot-mgr.HttpReadApi.conn".to_string())
                                .spawn(move || served.serve(s));
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
    fn serve(&self, mut stream: TcpStream) {
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
            ("GET", "/api/server") => self.json_response(|m| {
                m.server_payload(wall_now, uptime).map_err(err_string)
            }),
            ("GET", "/api/estates") => {
                // Merge the host's own EstateAdmin section into the event-derived
                // rollups. Priority: local EstateAdmin (host-provisioned) over the
                // base.admin (which is None in the Rust port — no ARIA proxy).
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
                self.json_response(|m| {
                    m.graph_payload(wall_now, estate.as_deref()).map_err(err_string)
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
            // The Rust host has no HTTP client and returns the honest degraded state
            // (pending: true, addresses: []) — identical to Swift's fallback when
            // ARIA_MCP is unreachable. See MootManager::lattice_payload for the full
            // rationale. Infallible (no store I/O).
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
/// native fetch) or a loopback origin. Any other origin is cross-origin and
/// rejected (CSRF guard). Mirrors Swift `HTTPReadAPI.isOriginAllowed(_:)`.
pub fn is_origin_allowed(origin: Option<&str>) -> bool {
    match origin {
        None => true,
        Some(o) if o.is_empty() => true,
        Some(o) => {
            let lo = o.to_lowercase();
            lo.starts_with("http://127.0.0.1")
                || lo.starts_with("http://localhost")
                || lo.starts_with("https://127.0.0.1")
                || lo.starts_with("https://localhost")
                || lo.starts_with("http://[::1]")
                || lo.starts_with("https://[::1]")
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
