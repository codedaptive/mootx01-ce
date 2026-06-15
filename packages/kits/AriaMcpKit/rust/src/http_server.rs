//! Loopback HTTP MCP transport — Rust version.
//!
//! Mirrors the Swift `HTTPServer` wire behavior: a client POSTs one JSON-RPC
//! frame and receives one JSON-RPC frame as the `application/json` response
//! body. The JSON-RPC surface is identical to the stdio loop (`server.rs`);
//! only the framing differs (HTTP body vs newline-delimited stdin/stdout).
//!
//! # No-FFI
//!
//! Per ADR-LOOPBACKHTTP-001 the shared `LoopbackHTTP` library is Swift-only.
//! This Rust vertical hand-rolls its own `std::net` listener and a minimal HTTP
//! parser; parity with the Swift transport is enforced at the JSON-RPC wire, not
//! the transport implementation. The two servers are independent verticals.
//!
//! # Concurrency model
//!
//! `run_http_loop` spawns one thread per accepted connection, bounded by a
//! `ConcurrencyGate` (default maxConcurrent=64, maxQueued=256). The accept
//! loop uses a TWO-PHASE gate protocol so it never parks inside the gate:
//!
//!   1. `try_enqueue()` — non-blocking depth check on the accept thread.
//!      Returns false immediately on overflow; the connection is shed inline
//!      with HTTP 503 + `Retry-After: 1`. The accept loop never stalls.
//!   2. `wait_for_slot()` — blocking Condvar wait inside the spawned worker
//!      thread. Enforces `max_concurrent`; the accept loop is already back
//!      at `accept()` by the time this blocks.
//!
//! The `Dispatcher` is wrapped in `Arc<Mutex<>>` so it can be shared safely
//! across the per-connection threads. The request bytes are read BEFORE
//! locking the dispatcher — a slow client writing its request cannot hold the
//! Mutex and serialize unrelated concurrent requests. The lock scope covers
//! only the actual dispatch call (`route`), not the socket read.
//!
//! `serve_once` (used by tests) runs synchronously on the caller thread —
//! one connection, no thread spawn. Tests never touch the gate.
//!
//! # Security
//!
//! Binds loopback only (`127.0.0.1`), never `0.0.0.0`. No authentication on the
//! Community-Edition transport (ADR-LOOPBACKHTTP-001); the Enterprise OAuth layer
//! composes above the transport in v2.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicI64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

use crate::dispatcher::Dispatcher;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JSONRPCRequest, JSONRPCResponse, JsonValue};
use crate::server::ServerConfig;
use observer_sink::StatsStore;

/// Header block cap — guards against an unbounded read from a misbehaving
/// (loopback-but-hostile) peer. Matches the Swift LoopbackHTTP default.
const MAX_HEADER_BYTES: usize = 64 * 1024;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Transport metrics
//
// All counters are process-global atomics. `run_http_loop` reads env vars to
// configure the gate once; counters accumulate for the process lifetime.
//
// Metric parity with Swift HTTPServer:
//   rpc_count          globalRPCCounter
//   connections        globalInflightCounter
//   connections_hwm    globalInflightHighWater
//   4xx_count          global4xxCounter
//   5xx_count          global5xxCounter
//   shed_count         globalShedCounter
//   latency_ns_total   globalLatencyNsTotal
//   latency_fast_count globalLatencyBucketFast  (<1 ms)
//   latency_mid_count  globalLatencyBucketMid   (1–50 ms)
//   latency_slow_count globalLatencyBucketSlow  (>50 ms)
// ─────────────────────────────────────────────────────────────────────────────

/// Cumulative RPC calls since process start (status != 202).
pub static GLOBAL_RPC_COUNTER: AtomicUsize = AtomicUsize::new(0);
/// Current in-flight connections.
pub static GLOBAL_INFLIGHT_COUNTER: AtomicUsize = AtomicUsize::new(0);
/// All-time peak simultaneous in-flight connections.
pub static GLOBAL_INFLIGHT_HWM: AtomicUsize = AtomicUsize::new(0);
/// Cumulative 4xx responses.
pub static GLOBAL_4XX_COUNTER: AtomicUsize = AtomicUsize::new(0);
/// Cumulative 5xx responses (transport errors; JSON-RPC errors are HTTP 200).
pub static GLOBAL_5XX_COUNTER: AtomicUsize = AtomicUsize::new(0);
/// Cumulative requests shed to 503 because the gate queue was full.
pub static GLOBAL_SHED_COUNTER: AtomicUsize = AtomicUsize::new(0);
/// Cumulative service time in nanoseconds.
pub static GLOBAL_LATENCY_NS_TOTAL: AtomicI64 = AtomicI64::new(0);
/// Requests completing in <1 ms.
pub static GLOBAL_LATENCY_FAST: AtomicUsize = AtomicUsize::new(0);
/// Requests completing in 1–50 ms.
pub static GLOBAL_LATENCY_MID: AtomicUsize = AtomicUsize::new(0);
/// Requests completing in >50 ms.
pub static GLOBAL_LATENCY_SLOW: AtomicUsize = AtomicUsize::new(0);

/// Record one request's service latency into the cumulative total and the
/// appropriate fast/mid/slow bucket (mirrors Swift `recordLatencyNs`).
fn record_latency_ns(ns: u64) {
    GLOBAL_LATENCY_NS_TOTAL.fetch_add(ns as i64, Ordering::Relaxed);
    // Inclusive upper bounds prevent off-by-one gaps between buckets.
    match ns {
        0..=999_999            => { GLOBAL_LATENCY_FAST.fetch_add(1, Ordering::Relaxed); }
        1_000_000..=49_999_999 => { GLOBAL_LATENCY_MID.fetch_add(1, Ordering::Relaxed); }
        _                      => { GLOBAL_LATENCY_SLOW.fetch_add(1, Ordering::Relaxed); }
    }
}

/// Update the in-flight high-water mark if `current` exceeds the stored value.
/// Compare-exchange loop so concurrent updaters converge on the true max
/// (mirrors Swift `updateInflightHighWater`).
fn update_inflight_hwm(current: usize) {
    let mut stored = GLOBAL_INFLIGHT_HWM.load(Ordering::Relaxed);
    while current > stored {
        match GLOBAL_INFLIGHT_HWM.compare_exchange_weak(
            stored, current, Ordering::Relaxed, Ordering::Relaxed,
        ) {
            Ok(_) => break,
            Err(new_stored) => stored = new_stored,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ConcurrencyGate
//
// A Condvar-backed counting semaphore that bounds in-flight connections.
// Rust's std does not ship a built-in semaphore, so we build one from
// `Mutex<usize>` + `Condvar`, which is the canonical pattern.
//
// Sizing mirrors the Swift ConcurrencyGate defaults:
//   max_concurrent = 64, max_queued = 256
// Both are configurable via env vars (MOOTX01_HTTP_MAX_CONCURRENT,
// MOOTX01_HTTP_MAX_QUEUED) read once at `run_http_loop` entry.
//
// IMPORTANT: The accept loop uses a TWO-PHASE protocol so it never
// parks inside the gate:
//
//   1. try_enqueue() — NON-BLOCKING depth check called on the accept thread.
//      Increments `active` and returns true if within bounds, or decrements
//      and returns false (overflow → 503 shed inline, accept loop continues).
//   2. wait_for_slot() — BLOCKING Condvar wait, called INSIDE the spawned
//      worker thread, not on the accept thread.
//
// Why the split matters:
//   Old (wrong): accept → try_acquire (depth check + Condvar wait combined) →
//     spawn thread → accept loop parks inside the Mutex when max_concurrent
//     slots are occupied; OS TCP backlog absorbs overflow; 503 cannot be
//     returned promptly.
//   New (correct): accept → try_enqueue (never blocks) → spawn thread →
//     thread calls wait_for_slot (blocks if needed) → accept loop is always
//     free to accept the next fd and shed overflow inline.
// ─────────────────────────────────────────────────────────────────────────────

/// Counting-semaphore gate that bounds the number of simultaneous in-flight
/// HTTP connections. Thread-safe via `Mutex<usize>` + `Condvar`.
///
/// The accept thread calls `try_enqueue()` (non-blocking); the spawned worker
/// thread calls `wait_for_slot()` (blocking Condvar wait). When the request
/// completes, call `release()`.
pub struct ConcurrencyGate {
    pub max_concurrent: usize,
    pub max_queued: usize,
    /// Number of connections currently enqueued (waiting for a slot or
    /// actively serving). Incremented by `try_enqueue`, decremented by
    /// `release`. Does NOT include connections that have been shed.
    active: Mutex<usize>,
    /// Signalled whenever a slot is freed by `release()`.
    cvar: Condvar,
}

impl ConcurrencyGate {
    /// Create a new gate with the given bounds.
    pub fn new(max_concurrent: usize, max_queued: usize) -> Arc<Self> {
        Arc::new(Self {
            max_concurrent,
            max_queued,
            active: Mutex::new(0),
            cvar: Condvar::new(),
        })
    }

    /// Phase 1 (accept thread, NON-BLOCKING): test whether the connection may
    /// be accepted into the gate. Returns `true` if the depth was within bounds
    /// (connection enqueued; caller MUST eventually call `release()`); returns
    /// `false` if the queue is full (caller should send 503 and close).
    ///
    /// This method never blocks. It only inspects and increments `active`
    /// under the lock — no Condvar wait. The Condvar wait happens in
    /// `wait_for_slot()`, which the spawned worker thread calls after
    /// `try_enqueue()` returns true.
    pub fn try_enqueue(self: &Arc<Self>) -> bool {
        let mut count = self.active.lock().unwrap();
        // Reject immediately when the combined depth limit is reached.
        if *count >= self.max_concurrent + self.max_queued {
            return false;
        }
        *count += 1;
        true
        // Lock released here (drop). No Condvar wait on the accept thread.
    }

    /// Phase 2 (worker thread, BLOCKING): wait until a concurrency slot is
    /// free. Must be called after a successful `try_enqueue()`, before
    /// beginning request service. Blocks if `active > max_concurrent`; returns
    /// as soon as `release()` decrements `active` below `max_concurrent` and
    /// signals the condvar.
    pub fn wait_for_slot(&self) {
        let mut count = self.active.lock().unwrap();
        // active was already incremented by try_enqueue. Wait until our slot
        // is within the max_concurrent window. Other threads may have changed
        // count between try_enqueue and here; the loop re-checks on each wake.
        while *count > self.max_concurrent {
            count = self.cvar.wait(count).unwrap();
        }
        // Slot granted — hold the count at current level until release().
    }

    /// Release a previously acquired slot. Decrements active and wakes one
    /// waiting worker thread (mirrors Swift `ConcurrencyGate.release()`).
    pub fn release(&self) {
        let mut count = self.active.lock().unwrap();
        if *count > 0 {
            *count -= 1;
        }
        self.cvar.notify_one();
    }

    /// Current gate depth (enqueued + actively serving). Informational.
    pub fn current_depth(&self) -> usize {
        *self.active.lock().unwrap()
    }

    // ─── Legacy one-shot convenience (tests / serve_once path) ─────────────

    /// Combined `try_enqueue()` + `wait_for_slot()`. Returns `true` if the
    /// connection was accepted and the slot was granted (caller MUST release),
    /// `false` if the queue was full (no slot acquired, no release needed).
    ///
    /// Preserved for callers that are NOT on the accept thread (e.g. unit
    /// tests, `serve_once`). Do NOT call this on the accept thread — it
    /// can block, stalling the accept loop.
    pub fn try_acquire(self: &Arc<Self>) -> bool {
        if !self.try_enqueue() {
            return false;
        }
        self.wait_for_slot();
        true
    }
}

/// Write an HTTP 503 Service Unavailable with `Retry-After: 1` to the stream
/// and close. Called on the accept thread when the gate queue is full, without
/// involving the dispatcher (mirrors Swift `HTTPServer.sendShedResponse`).
pub fn send_shed_response(stream: &mut TcpStream) {
    let body = br#"{"error":"service_unavailable","retry_after":1}"#;
    let head = format!(
        "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nRetry-After: 1\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - run_http_loop (hardened, multi-threaded)
// ─────────────────────────────────────────────────────────────────────────────

/// Run the resident loopback HTTP MCP transport on `127.0.0.1:port` until the
/// process is terminated. Returns only if the bind fails.
///
/// Spawns one thread per accepted connection (bounded by `ConcurrencyGate`).
/// Connections beyond `max_concurrent + max_queued` receive HTTP 503 immediately.
///
/// `stats_store`: optional stats store for topology snapshot reads.
pub fn run_http_loop(
    port: u16,
    max_body_bytes: usize,
    config: ServerConfig,
    stats_store: Option<Arc<StatsStore>>,
) -> std::io::Result<()> {
    // Read gate configuration from env (same keys as Swift, same defaults).
    let max_concurrent = std::env::var("MOOTX01_HTTP_MAX_CONCURRENT")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(64)
        .clamp(1, 1024);
    let max_queued = std::env::var("MOOTX01_HTTP_MAX_QUEUED")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(256)
        .clamp(0, 4096);

    let gate = ConcurrencyGate::new(max_concurrent, max_queued);

    // Dispatcher is shared across connection threads via Arc<Mutex<>>.
    // The Mutex serializes tool dispatch; for I/O-bound MCP calls this is
    // the same throughput profile as the previous sequential model but
    // allows concurrent read-only routing (GET endpoints) to proceed without
    // waiting on active dispatches.
    let dispatcher = Arc::new(Mutex::new(
        Dispatcher::new(config.registry, &config.server_name, &config.server_version)
    ));

    let listener = bind_loopback(port)?;
    let bound = listener.local_addr()?.port();
    eprintln!("aria-mcp: HTTP listening on 127.0.0.1:{bound} (max body {max_body_bytes} bytes, max_concurrent={max_concurrent}, max_queued={max_queued})");

    loop {
        let (mut stream, _) = match listener.accept() {
            Ok(pair) => pair,
            Err(e) => { eprintln!("aria-mcp: accept error: {e}"); continue; }
        };

        // Phase 1 (accept thread, NON-BLOCKING): depth check only. try_enqueue
        // increments `active` and returns false immediately when the gate is
        // at capacity — it never blocks on the Condvar. This means the accept
        // loop always processes connections promptly and can shed overflow
        // inline with a 503, rather than parking inside the Mutex and pushing
        // overflow into the OS TCP backlog.
        if !gate.try_enqueue() {
            GLOBAL_SHED_COUNTER.fetch_add(1, Ordering::Relaxed);
            send_shed_response(&mut stream);
            continue;
        }

        let gate_clone = Arc::clone(&gate);
        let dispatcher_clone = Arc::clone(&dispatcher);
        let stats_store_clone = stats_store.clone();

        std::thread::spawn(move || {
            // Phase 2 (worker thread): wait_for_slot() is the Condvar wait
            // that enforces max_concurrent. Runs on the worker thread, not the
            // accept thread — the accept loop is already back at the top.
            gate_clone.wait_for_slot();

            let in_flight = GLOBAL_INFLIGHT_COUNTER.fetch_add(1, Ordering::Relaxed) + 1;
            update_inflight_hwm(in_flight);
            let start = Instant::now();
            defer_on_drop(|| {
                GLOBAL_INFLIGHT_COUNTER.fetch_sub(1, Ordering::Relaxed);
                gate_clone.release();
                let elapsed_ns = start.elapsed().as_nanos() as u64;
                record_latency_ns(elapsed_ns);
            });

            // Read the request bytes BEFORE locking the dispatcher (fix #26).
            // A slow client holds the TCP socket open while writing its
            // request; reading here — outside the Mutex — means a slow
            // sender cannot block other connections from being dispatched.
            // The dispatcher lock scope is now limited to the actual dispatch
            // call (route), which is the known Arc<Mutex<>> dispatch ceiling.
            let request = read_request(&mut stream, max_body_bytes);

            let dispatch = dispatcher_clone.lock().unwrap();
            if let Some(req) = request {
                let (status, body) = route(&req, &dispatch, stats_store_clone.as_deref());

                // Release the dispatcher lock before writing the response —
                // the lock scope is strictly request-parse → route → done,
                // with no I/O holding the mutex.
                drop(dispatch);

                match status {
                    400..=499 => { GLOBAL_4XX_COUNTER.fetch_add(1, Ordering::Relaxed); }
                    500..=599 => { GLOBAL_5XX_COUNTER.fetch_add(1, Ordering::Relaxed); }
                    _ => {}
                }
                if status != 202 {
                    GLOBAL_RPC_COUNTER.fetch_add(1, Ordering::Relaxed);
                }
                write_http_response(&mut stream, status, &body);
            }
            // If read_request returned None (malformed/truncated headers) the
            // connection is dropped silently — no response written, consistent
            // with the serve_stream behavior.
        });
    }
}

/// A trivial RAII guard that runs a closure on drop. Used in `run_http_loop`
/// thread bodies to ensure gate release + latency recording even when
/// `serve_stream` returns early.
struct OnDrop<F: FnOnce()>(Option<F>);
impl<F: FnOnce()> Drop for OnDrop<F> {
    fn drop(&mut self) { if let Some(f) = self.0.take() { f(); } }
}
fn defer_on_drop<F: FnOnce()>(f: F) -> OnDrop<F> { OnDrop(Some(f)) }

/// Bind a TCP listener to the loopback interface only. Never `INADDR_ANY`.
pub fn bind_loopback(port: u16) -> std::io::Result<TcpListener> {
    TcpListener::bind(("127.0.0.1", port))
}

/// Test-only variant of `run_http_loop`: uses a pre-bound listener and
/// serves exactly `connection_count` connections then returns. Returns a
/// `JoinHandle` for the server thread so callers can synchronize shutdown.
///
/// Uses the same two-phase gate + pre-lock read logic as `run_http_loop`:
/// `try_enqueue()` on the accept thread (non-blocking), `wait_for_slot()` on
/// the worker thread (blocking Condvar wait), request read before the
/// dispatcher lock. Enables integration tests that drive real threaded
/// behavior without the process-lifetime loop.
///
/// Gate is provided by the caller so tests can configure capacity precisely.
#[doc(hidden)]
pub fn run_http_loop_for_test(
    listener: TcpListener,
    dispatcher: Arc<Mutex<Dispatcher>>,
    gate: Arc<ConcurrencyGate>,
    connection_count: usize,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut served = 0;
        while served < connection_count {
            let (mut stream, _) = match listener.accept() {
                Ok(p) => p,
                Err(_) => break,
            };
            // Phase 1: non-blocking depth check on the accept thread.
            if !gate.try_enqueue() {
                GLOBAL_SHED_COUNTER.fetch_add(1, Ordering::Relaxed);
                send_shed_response(&mut stream);
                served += 1;
                continue;
            }
            let gate_c = Arc::clone(&gate);
            let disp_c = Arc::clone(&dispatcher);
            std::thread::spawn(move || {
                // Phase 2: blocking Condvar wait on the worker thread.
                gate_c.wait_for_slot();

                let start = Instant::now();
                let _guard = defer_on_drop(|| {
                    gate_c.release();
                    let _ = start.elapsed(); // latency recording omitted in test helper
                });

                // Read request BEFORE locking the dispatcher (fix #26).
                let request = read_request(&mut stream, 4 * 1024 * 1024);
                let lock = disp_c.lock().unwrap();
                if let Some(req) = request {
                    let (status, body) = route(&req, &lock, None);
                    drop(lock);
                    match status {
                        400..=499 => { GLOBAL_4XX_COUNTER.fetch_add(1, Ordering::Relaxed); }
                        500..=599 => { GLOBAL_5XX_COUNTER.fetch_add(1, Ordering::Relaxed); }
                        _ => {}
                    }
                    if status != 202 {
                        GLOBAL_RPC_COUNTER.fetch_add(1, Ordering::Relaxed);
                    }
                    write_http_response(&mut stream, status, &body);
                }
            });
            served += 1;
        }
    })
}

/// Accept one connection and serve it synchronously (no thread spawn, no gate).
/// Used by tests to drive single connections deterministically. Does NOT
/// update inflight/latency/gate counters — only rpc/4xx/5xx are incremented
/// (via `serve_stream`). This matches the test expectation that counter state
/// remains predictable without the async complexity of the threaded path.
pub fn serve_once(
    listener: &TcpListener,
    dispatcher: &Dispatcher,
    max_body_bytes: usize,
    stats_store: Option<&StatsStore>,
) {
    match listener.accept() {
        Ok((mut stream, _)) => serve_stream(&mut stream, dispatcher, max_body_bytes, stats_store),
        Err(e) => eprintln!("aria-mcp: accept error: {e}"),
    }
}

/// A parsed HTTP request: method, path (without query string), Origin,
/// Accept header, query string, and body.
struct HttpRequest {
    method: String,
    path: String,
    /// Raw query string after '?', or "".
    query: String,
    origin: Option<String>,
    /// The Accept header value, or None.
    accept: Option<String>,
    body: Vec<u8>,
}

impl HttpRequest {
    /// True when the client asked for the SSE event stream. Mirrors
    /// `HTTPRequest.wantsEventStream` in the Swift LoopbackHTTP library:
    /// accepts via the `text/event-stream` Accept header OR the `?stream=1`
    /// query flag.
    fn wants_event_stream(&self) -> bool {
        if let Some(a) = &self.accept {
            if a.contains("text/event-stream") {
                return true;
            }
        }
        self.query.split('&').any(|kv| kv == "stream=1")
    }
}

/// Serve one connection: read the request, route it, write the response.
/// Updates the 4xx, 5xx, and rpc counters for every call (serve_once path
/// uses this too; the gate and latency counters are managed by the caller
/// in run_http_loop's thread body).
///
/// SSE fast path: `GET /api/events` with `Accept: text/event-stream` (or
/// `?stream=1`) is intercepted here, before `route()`, and handed to
/// `drive_sse_stream()`. The CSRF/origin guard runs first. The SSE stream
/// is NOT counted as an RPC call but does hold the concurrency-gate slot
/// for its lifetime, mirroring the Swift `serve()` SSE branch.
fn serve_stream(stream: &mut TcpStream, dispatcher: &Dispatcher, max_body_bytes: usize, stats_store: Option<&StatsStore>) {
    let request = match read_request(stream, max_body_bytes) {
        Some(r) => r,
        None => return,
    };

    // SSE event-stream path — intercepted before route() because SSE requires
    // holding the socket open past a single request/response exchange.
    // Matches Swift HTTPServer.serve() SSE branch and driveSSEStream().
    if request.method == "GET" && request.path == "/api/events" && request.wants_event_stream() {
        if !is_origin_allowed(request.origin.as_deref()) {
            let body = br#"{"error":"forbidden_origin"}"#;
            let head = format!(
                "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(body);
            return;
        }
        drive_sse_stream(stream, SSE_HEARTBEAT_INTERVAL_MS);
        return;
    }

    let (status, body) = route(&request, dispatcher, stats_store);

    // Count by status class; mirror Swift HTTPServer.serve's counting logic.
    match status {
        400..=499 => { GLOBAL_4XX_COUNTER.fetch_add(1, Ordering::Relaxed); }
        500..=599 => { GLOBAL_5XX_COUNTER.fetch_add(1, Ordering::Relaxed); }
        _ => {}
    }
    // 202 is the notification path (no response per JSON-RPC spec); every
    // other status is a dispatched tool call.
    if status != 202 {
        GLOBAL_RPC_COUNTER.fetch_add(1, Ordering::Relaxed);
    }

    write_http_response(stream, status, &body);
}

/// Production SSE heartbeat interval (milliseconds). Matches Swift's 15-second
/// default. Tests override this by calling `drive_sse_stream` directly with a
/// shorter value.
pub const SSE_HEARTBEAT_INTERVAL_MS: u64 = 15_000;

/// Drive a Server-Sent-Events stream on `stream` until the peer disconnects.
///
/// Sends the SSE response head (200 + `text/event-stream` + `keep-alive`) then
/// enters a heartbeat loop: every `interval_ms` it sends a comment-line ping
/// (`: heartbeat\n\n`), which is invisible to EventSource `message` handlers
/// but keeps TCP/NAT state alive for idle connections.
///
/// The loop exits when a write fails (peer disconnected or TCP reset), after
/// which the caller closes the stream (via RAII on the `TcpStream`). Future
/// Brain-pump notifications will be forwarded here by extending this function
/// to accept a channel receiver; the heartbeat loop already forms the correct
/// scaffolding.
///
/// Mirrors Swift `HTTPServer.driveSSEStream`.
pub fn drive_sse_stream(stream: &mut TcpStream, interval_ms: u64) {
    // SSE response head: 200 + text/event-stream + no-cache + keep-alive.
    // No Content-Length (streaming response; the body grows indefinitely).
    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n";
    if stream.write_all(head.as_bytes()).is_err() {
        return;
    }
    // Heartbeat loop: send a comment-line ping on each interval tick.
    // SSE comment lines start with ":"; they are not dispatched to
    // EventSource message handlers but keep the connection alive.
    loop {
        std::thread::sleep(std::time::Duration::from_millis(interval_ms));
        if stream.write_all(b": heartbeat\n\n").is_err() {
            return;
        }
        // Flush after each frame so the event reaches the client without
        // waiting for Nagle coalescing.
        if stream.flush().is_err() {
            return;
        }
    }
}

/// Read one HTTP/1.1 request: request line + headers, then exactly
/// Content-Length body bytes bounded by `max_body_bytes`.
fn read_request(stream: &mut TcpStream, max_body_bytes: usize) -> Option<HttpRequest> {
    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 16 * 1024];

    // Read until the header terminator (CRLF CRLF).
    let header_end = loop {
        if let Some(pos) = find_subslice(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        if buf.len() > MAX_HEADER_BYTES {
            return None;
        }
        let n = stream.read(&mut tmp).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&tmp[..n]);
    };

    let header_text = std::str::from_utf8(&buf[..header_end]).ok()?;
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next()?;
    let method = request_line.split(' ').next()?.to_owned();

    // Extract path and query string from request target.
    // e.g. "GET /api/lattice?foo=bar HTTP/1.1" → path="/api/lattice", query="foo=bar"
    let target = request_line.split(' ').nth(1).unwrap_or("/");
    let (path, query) = if let Some(q) = target.find('?') {
        (target[..q].to_owned(), target[q + 1..].to_owned())
    } else {
        (target.to_owned(), String::new())
    };

    let mut content_length = 0usize;
    let mut origin: Option<String> = None;
    let mut accept: Option<String> = None;
    for line in lines {
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            let name = name.trim();
            if name.eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse().unwrap_or(0);
            } else if name.eq_ignore_ascii_case("origin") {
                origin = Some(value.trim().to_string());
            } else if name.eq_ignore_ascii_case("accept") {
                accept = Some(value.trim().to_string());
            }
        }
    }

    // Body: read up to min(Content-Length, max_body_bytes). A body larger than
    // the cap is bounded; callers set max_body_bytes high enough that a valid
    // MCP tools/call cannot be truncated (ADR-LOOPBACKHTTP-001 condition 2).
    let want = content_length.min(max_body_bytes);
    let mut body: Vec<u8> = buf[header_end..].to_vec();
    while body.len() < want {
        let n = stream.read(&mut tmp).ok()?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    if body.len() > want {
        body.truncate(want);
    }

    Some(HttpRequest { method, path, query, origin, accept, body })
}

/// Route one request to `(status, body)`. The parse → decode → dispatch → encode
/// path mirrors `server::handle_frame` so the JSON-RPC bytes match the stdio
/// transport. JSON-RPC-level failures return HTTP 200 with a JSON-RPC error
/// object (the error is in the body); a notification returns HTTP 202, empty.
fn route(request: &HttpRequest, dispatcher: &Dispatcher, stats_store: Option<&StatsStore>) -> (u16, Vec<u8>) {
    // DNS-rebinding / CSRF guard (runs first). Accept absent/loopback Origins
    // (native MCP clients send none); reject any other origin — that is a
    // cross-origin browser request. CSRF boundary, not authentication; mirrors
    // the Swift HTTPServer.isOriginAllowed and moot-mgr's HTTPReadAPI.
    if !is_origin_allowed(request.origin.as_deref()) {
        return (403, br#"{"error":"forbidden_origin"}"#.to_vec());
    }

    // GET routing for side-channel read endpoints — evaluated before the POST
    // guard so they are not rejected as method_not_allowed.
    // NOTE: GET /api/events (SSE) is intercepted in serve_stream() before
    // route() is called and is NOT listed here — it is long-lived and cannot
    // be modelled as a stateless request/response pair.
    // Mirrors Swift HTTPServer.route() which also evaluates GET before POST.
    if request.method == "GET" {
        return match request.path.as_str() {
            "/api/graph"         => get_graph_snapshot(&dispatcher.registry, stats_store),
            "/api/lattice"       => get_lattice_snapshot(&dispatcher.registry),
            "/api/admin/estates" => get_admin_estates_snapshot(&dispatcher.registry),
            _                    => (404, br#"{"error":"not_found"}"#.to_vec()),
        };
    }

    if request.method != "POST" {
        return (405, br#"{"error":"method_not_allowed"}"#.to_vec());
    }

    let parsed: serde_json::Value = match serde_json::from_slice(&request.body) {
        Ok(v) => v,
        Err(e) => {
            return (
                200,
                error_frame(JSONRPCErrorCode::PARSE_ERROR, &format!("Parse error: {e}")),
            );
        }
    };

    let rpc = match JSONRPCRequest::decode(&parsed) {
        Some(r) => r,
        None => {
            return (
                200,
                error_frame(
                    JSONRPCErrorCode::INVALID_REQUEST,
                    "Invalid Request: malformed JSON-RPC envelope",
                ),
            );
        }
    };

    if rpc.is_notification() {
        eprintln!("aria-mcp: notification: {}", rpc.method);
        return (202, Vec::new());
    }

    let response = dispatcher.handle(&rpc);
    match serde_json::to_vec(&response) {
        Ok(bytes) => (200, bytes),
        Err(e) => {
            eprintln!("aria-mcp: serialization error: {e}");
            (200, error_frame(JSONRPCErrorCode::INTERNAL_ERROR, "Internal error"))
        }
    }
}

/// Serialize a JSON-RPC error object (null id) to bytes.
fn error_frame(code: i64, message: &str) -> Vec<u8> {
    let response = JSONRPCResponse::failure(JsonValue::Null, JSONRPCError::new(code, message));
    serde_json::to_vec(&response).unwrap_or_else(|_| {
        br#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal error"}}"#.to_vec()
    })
}

/// Write an HTTP/1.1 response. `Content-Type: application/json` is sent only when
/// there is a body (matching the Swift transport's empty-202 shape); 405 carries
/// `Allow: POST`.
fn write_http_response(stream: &mut TcpStream, status: u16, body: &[u8]) {
    let reason = match status {
        200 => "OK",
        202 => "Accepted",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "OK",
    };
    let mut head = format!("HTTP/1.1 {status} {reason}\r\n");
    if !body.is_empty() {
        head.push_str("Content-Type: application/json\r\n");
    }
    head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    if status == 405 {
        head.push_str("Allow: POST\r\n");
    }
    head.push_str("Connection: close\r\n\r\n");
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body);
}

/// True if the Origin is acceptable: absent (native MCP clients send none) or a
/// loopback origin. Any other origin is a cross-origin browser request (the
/// DNS-rebinding vector) and is rejected. Mirrors the Swift
/// `HTTPServer.isOriginAllowed`.
fn is_origin_allowed(origin: Option<&str>) -> bool {
    match origin {
        None => true,
        Some(o) if o.is_empty() => true,
        Some(o) => {
            let l = o.to_ascii_lowercase();
            l.starts_with("http://127.0.0.1")
                || l.starts_with("http://localhost")
                || l.starts_with("https://127.0.0.1")
                || l.starts_with("https://localhost")
                || l.starts_with("http://[::1]")
                || l.starts_with("https://[::1]")
        }
    }
}

/// Find the first index of `needle` in `haystack`.
fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// GET /api/lattice — active lattice addresses (UDC/MDCC codes) with drawer counts.
/// Groups non-tombstoned drawers by udc_code, omits empty-string sentinel
/// (unanchored drawers), sorted by count descending.
/// On store failure, returns HTTP 503 with an error field — NOT a fabricated
/// empty-200. A `200 {"addresses":[]}` on a read fault is indistinguishable
/// from a genuinely empty estate and would tell the client "no lattice" when
/// the truth is "could not read the lattice". A genuinely empty estate (read
/// succeeds, zero anchored drawers) still returns 200 with an empty array.
/// Mirrors Swift HTTPServer.latticeSnapshot(dispatcher:).
fn get_lattice_snapshot(registry: &crate::estate_registry::EstateRegistry) -> (u16, Vec<u8>) {
    let drawers = match registry.default.store.all_drawers() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("aria-mcp: GET /api/lattice all_drawers failed: {e}");
            let body = serde_json::json!({
                "error": "lattice read failed",
                "degraded": true,
            });
            return (
                503,
                serde_json::to_vec(&body)
                    .unwrap_or_else(|_| br#"{"error":"lattice read failed","degraded":true}"#.to_vec()),
            );
        }
    };

    let mut counts: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for d in drawers.iter().filter(|d| d.tombstoned_at.is_none() && !d.udc_code.is_empty()) {
        *counts.entry(d.udc_code.clone()).or_insert(0) += 1;
    }

    // Sort by count desc, then code asc for determinism on ties.
    let mut entries: Vec<(String, usize)> = counts.into_iter().collect();
    entries.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));

    let items: Vec<serde_json::Value> = entries.iter()
        .map(|(code, cnt)| serde_json::json!({"code": code, "count": cnt}))
        .collect();
    let body = serde_json::json!({"addresses": items});
    (200, serde_json::to_vec(&body).unwrap_or_else(|_| br#"{"addresses":[]}"#.to_vec()))
}

/// GET /api/graph — serve the pre-computed topology snapshot from the stats store.
///
/// The autonomic governor recomputes topology on its own cadence (default 5 min)
/// and writes the payload to `stats_store.write_topology_snapshot`. This layer
/// reads from `topology_snapshots` via `latest_topology_snapshot` and returns
/// the stored bytes verbatim. There is NO compute-on-read fallback — the governor
/// is the single source of topology truth (mirrors Swift HTTPServer.graphSnapshot).
///
/// When `stats_store` is None (no store configured) or `latest_topology_snapshot`
/// returns None (governor has not fired yet), responds with `structurePending: true`.
///
/// Estate ID is the default estate's UUID string. The `?estate=` query param is
/// not parsed in this Rust leg (single-estate daemon); all reads use the registry
/// default. This matches the current Rust registry scope (one estate per process).
fn get_graph_snapshot(
    registry: &crate::estate_registry::EstateRegistry,
    stats_store: Option<&StatsStore>,
) -> (u16, Vec<u8>) {
    const PENDING: &[u8] =
        br#"{"nodes":[],"edges":[],"structurePending":true,"communities":[]}"#;

    let store = match stats_store {
        Some(s) => s,
        None => return (200, PENDING.to_vec()),
    };

    let estate_id = uuid::Uuid::from_bytes(registry.default.handle.estate_uuid).to_string();
    match store.latest_topology_snapshot(Some(&estate_id)) {
        Ok(Some(payload)) => (200, payload.into_bytes()),
        Ok(None) => (200, PENDING.to_vec()),
        Err(e) => {
            eprintln!("aria-mcp: GET /api/graph snapshot read failed: {e:?}");
            (200, PENDING.to_vec())
        }
    }
}

/// GET /api/admin/estates — list all estates in the registry.
/// Backend is inferred from env vars (ARIA_MCP_POSTGRES_URL / ARIA_MCP_SQLITE_PATH),
/// same as Swift. Mount state is always "mounted" (no mount-state enum in Rust
/// registry). estateName uses the estate UUID as a proxy — the Rust EstateRegistry
/// stores no separate human-readable name (Swift derives it via GeniusLocusKit).
/// Mirrors Swift HTTPServer.adminEstatesSnapshot(dispatcher:).
fn get_admin_estates_snapshot(registry: &crate::estate_registry::EstateRegistry) -> (u16, Vec<u8>) {
    // Backend inferred from env vars — same selection logic as ServerConfig::from_env.
    let backend = if std::env::var("ARIA_MCP_POSTGRES_URL").is_ok() {
        "PostgreSQL"
    } else if std::env::var("ARIA_MCP_SQLITE_PATH").is_ok() {
        "SQLite"
    } else {
        "InMemory"
    };

    let mut estates: Vec<serde_json::Value> = Vec::new();
    let default_uuid = registry.default.estate_id.to_string();
    estates.push(serde_json::json!({
        "estateUUID": default_uuid,
        "estateName": default_uuid,
        "kind": "GLK",
        "backend": backend,
        "mountState": "mounted"
    }));
    // Extras keyed by UUID; sort for deterministic output.
    let mut extra_uuids: Vec<String> = registry.extras.keys()
        .filter(|u| u.to_string() != default_uuid)
        .map(|u| u.to_string())
        .collect();
    extra_uuids.sort();
    for uuid in &extra_uuids {
        estates.push(serde_json::json!({
            "estateUUID": uuid, "estateName": uuid,
            "kind": "GLK", "backend": backend, "mountState": "mounted"
        }));
    }

    let body = serde_json::json!({"hosted": estates});
    (200, serde_json::to_vec(&body).unwrap_or_else(|_| br#"{"hosted":[]}"#.to_vec()))
}
