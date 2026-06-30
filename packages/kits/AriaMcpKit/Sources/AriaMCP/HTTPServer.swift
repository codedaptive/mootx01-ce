import Foundation
import GeniusLocusKit
import LocusKit
import Synchronization
import LoopbackHTTP

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// ============================================================
// MARK: - Global transport counters
//
// All counters are Atomic<Int> (lock-free) so the accept thread
// and serve tasks can update them without contention. The Atomic
// type is Sendable, requiring no isolation annotation.
//
// Counters are module-level (not on the struct) so ResidentDaemon
// can snapshot them without an HTTPServer reference.
// ============================================================

/// Cumulative RPC calls since process start (status != 202).
/// Read by ServerMetricsTelemetry to emit server.rpc_count.
public let globalRPCCounter: Atomic<Int> = Atomic(0)

/// Current number of requests in-flight (past the semaphore, not yet responded).
public let globalInflightCounter: Atomic<Int> = Atomic(0)

/// Cumulative 4xx responses emitted.
public let global4xxCounter: Atomic<Int> = Atomic(0)

/// Cumulative 5xx responses emitted (transport-level errors; JSON-RPC errors
/// are HTTP 200 per the spec and are NOT counted here).
public let global5xxCounter: Atomic<Int> = Atomic(0)

/// Cumulative requests shed because the accept queue was full (→ HTTP 503).
public let globalShedCounter: Atomic<Int> = Atomic(0)

/// High-water mark of simultaneous in-flight requests observed.
/// Updated with a compare-exchange loop so no request is double-counted.
public let globalInflightHighWater: Atomic<Int> = Atomic(0)

/// Cumulative sum of request service time in nanoseconds (dispatch → response
/// written). Used together with globalRPCCounter to derive mean latency.
/// Not a histogram — kept simple on purpose; p50/p95 proxies are derived
/// from the fast/mid/slow bucket counters below, present in both the Swift
/// and Rust implementations.
public let globalLatencyNsTotal: Atomic<Int> = Atomic(0)

/// Latency bucket counters. Three buckets cover the QOPT/T3b benchmark range:
///   fast (<1 ms), mid (1–50 ms), slow (>50 ms).
/// Updated atomically; read by ServerMetricsTelemetry for p50/p95 proxies.
public let globalLatencyBucketFast: Atomic<Int> = Atomic(0)   // <1 ms
public let globalLatencyBucketMid:  Atomic<Int> = Atomic(0)   // 1–50 ms
public let globalLatencyBucketSlow: Atomic<Int> = Atomic(0)   // >50 ms

/// Record the latency of one completed request (nanoseconds) into the
/// cumulative total and the appropriate fast/mid/slow bucket.
/// Atomic.add return values are discarded — we only need the side-effect.
@inline(__always)
func recordLatencyNs(_ ns: Int) {
    _ = globalLatencyNsTotal.add(ns, ordering: .relaxed)
    switch ns {
    case ..<1_000_000:        _ = globalLatencyBucketFast.add(1, ordering: .relaxed)
    case ..<50_000_000:       _ = globalLatencyBucketMid.add(1, ordering: .relaxed)
    default:                  _ = globalLatencyBucketSlow.add(1, ordering: .relaxed)
    }
}

/// Update the in-flight high-water mark if `current` exceeds the stored value.
/// Uses a compare-exchange loop so concurrent updaters converge on the true max.
/// `compareExchange` returns `(exchanged: Bool, original: Int)` — on failure the
/// `original` (current stored value) is the value to retry with.
@inline(__always)
func updateInflightHighWater(_ current: Int) {
    var stored = globalInflightHighWater.load(ordering: .relaxed)
    while current > stored {
        let (exchanged, original) = globalInflightHighWater.compareExchange(
            expected: stored, desired: current, ordering: .relaxed
        )
        if exchanged { break }
        // Another writer updated the HWM between our load and compare-exchange;
        // retry with the value that is now stored.
        stored = original
    }
}

// ============================================================
// MARK: - ConcurrencyGate
//
// A DispatchSemaphore-backed gate that bounds the number of
// simultaneous in-flight requests. It has two layers:
//
//   1. maxConcurrent: hard cap on simultaneous service tasks.
//      Requests that acquire the semaphore proceed immediately.
//   2. maxQueued: cap on additional accepted-but-waiting connections.
//      If `activeCount >= maxConcurrent + maxQueued`, the connection
//      is accepted and immediately shed (HTTP 503) rather than
//      stalled forever.
//
// IMPORTANT: The accept loop uses a TWO-PHASE protocol so it never
// parks inside the gate:
//
//   1. tryEnqueue() — NON-BLOCKING depth check on the accept thread.
//      Increments activeCount and returns true if within bounds, or
//      decrements and returns false (overflow → 503 shed immediately).
//   2. waitForSlot() — BLOCKING semaphore wait, called INSIDE the
//      spawned Task, not on the accept thread. This is the correct
//      backpressure point: connections wait for a concurrency slot
//      while the accept loop continues accepting new connections.
//
// Why the split matters:
//   Old (wrong): accept → tryAcquire (blocks on semaphore) → spawn Task
//     → accept loop parks on semaphore; OS TCP backlog silently absorbs
//     overflow; 503 cannot be returned promptly.
//   New (correct): accept → tryEnqueue (never blocks) → spawn Task →
//     Task calls waitForSlot (blocks if needed) → accept loop always
//     free to accept the next fd and count/shed overflow immediately.
//
// The gate must be Sendable so it can cross the accept-thread
// boundary; DispatchSemaphore and the Atomic counters satisfy
// that requirement.
//
// Default sizing rationale:
//   maxConcurrent = 64:  Each request calls an async dispatcher
//     that may hit SQLite; 64 keeps the thread pool healthy and
//     prevents a thundering-herd cascade during QOPT/T3b loops
//     (which fan out 10–20 parallel tool calls per benchmark
//     round). macOS SQLite WAL serializes writes but reads are
//     parallel, so 64 is well above practical throughput while
//     still preventing runaway spawning.
//   maxQueued = 256: A 256-deep queue absorbs the fastest possible
//     burst from a benchmark loop (each iteration ~5 ms → 200
//     req/s sustained, 256 slots = ~1.3 s burst headroom) without
//     growing memory unboundedly. At 257+, callers receive 503 with
//     Retry-After: 1 rather than stalling.
// ============================================================

/// Bounded concurrency gate for the HTTP transport.
///
/// The accept thread calls `tryEnqueue()` (non-blocking). If it returns
/// `false` the caller sheds the connection immediately with 503. If it
/// returns `true` the caller spawns a Task that calls `waitForSlot()`
/// before serving. When the request is done, call `release()`.
///
/// This two-phase design keeps the accept thread unblocked so it can
/// always accept new fds and count or shed overflow in-line with the
/// documented 503 + Retry-After behaviour.
public final class ConcurrencyGate: @unchecked Sendable {

    public let maxConcurrent: Int
    public let maxQueued: Int

    /// Count of connections currently enqueued (waiting for a slot or
    /// actively being served) — incremented by tryEnqueue, decremented
    /// by release. Does NOT include connections that have been shed.
    private let activeCount: Atomic<Int> = Atomic(0)
    /// Semaphore: starts at maxConcurrent free slots. waitForSlot()
    /// decrements (blocks if 0); release() increments (wakes one waiter).
    private let semaphore: DispatchSemaphore

    public init(maxConcurrent: Int = 64, maxQueued: Int = 256) {
        self.maxConcurrent = maxConcurrent
        self.maxQueued = maxQueued
        self.semaphore = DispatchSemaphore(value: maxConcurrent)
    }

    /// Phase 1 (accept thread, NON-BLOCKING): test whether the connection
    /// may be accepted into the gate. Returns `true` if the depth was within
    /// bounds (connection enqueued; caller MUST eventually call `release()`);
    /// returns `false` if the queue is full (caller should respond 503 and close).
    ///
    /// This method NEVER blocks. It increments activeCount and returns true
    /// when `depth <= maxConcurrent + maxQueued`; otherwise it undoes the
    /// increment and returns false. The semaphore wait happens in
    /// `waitForSlot()`, which is called inside the spawned Task.
    public func tryEnqueue() -> Bool {
        let depth = activeCount.add(1, ordering: .relaxed).newValue
        if depth > maxConcurrent + maxQueued {
            // Queue depth exceeded: undo the increment and signal overflow.
            _ = activeCount.add(-1, ordering: .relaxed)
            return false
        }
        return true
    }

    /// Phase 2 (worker Task, BLOCKING): wait until a concurrency slot is
    /// free. Must be called after a successful `tryEnqueue()`, before
    /// beginning request service. Blocks if all `maxConcurrent` slots are
    /// occupied; returns as soon as one is released by a finishing request.
    public func waitForSlot() {
        semaphore.wait()
    }

    /// Release a previously acquired slot (decrement activeCount, signal
    /// semaphore so the next queued Task can proceed).
    public func release() {
        _ = activeCount.add(-1, ordering: .relaxed)
        semaphore.signal()
    }

    /// Current number of enqueued connections (waiting for a slot + actively
    /// serving). Used for metrics.
    public var currentDepth: Int { activeCount.load(ordering: .relaxed) }

    // MARK: - Legacy one-shot path (test/serve_once usage)

    /// Convenience: non-blocking enqueue + immediate blocking wait combined.
    /// Preserved for `serve_once`-style callers that call on a thread they
    /// control. Returns `true` if the slot was acquired (caller MUST release),
    /// `false` if the queue was full (no slot acquired).
    public func tryAcquire() -> Bool {
        guard tryEnqueue() else { return false }
        waitForSlot()
        return true
    }
}

/// The process-wide concurrency gate. A single shared instance so all
/// accepted connections respect the same cap regardless of how many
/// HTTPServer instances are created (tests create many short-lived ones,
/// but production runs one).
///
/// `maxConcurrent` and `maxQueued` can be overridden at process start
/// via `MOOTX01_HTTP_MAX_CONCURRENT` and `MOOTX01_HTTP_MAX_QUEUED`
/// before the gate is first accessed. After first access the values
/// are frozen; the gate does not re-read the environment.
public let globalConcurrencyGate: ConcurrencyGate = {
    let env = ProcessInfo.processInfo.environment
    let maxC = env["MOOTX01_HTTP_MAX_CONCURRENT"].flatMap(Int.init) ?? 64
    let maxQ = env["MOOTX01_HTTP_MAX_QUEUED"].flatMap(Int.init) ?? 256
    // Clamp to sane bounds: at least 1 concurrent, at most 1024; queue at most 4096.
    let clampedC = min(max(maxC, 1), 1024)
    let clampedQ = min(max(maxQ, 0), 4096)
    return ConcurrencyGate(maxConcurrent: clampedC, maxQueued: clampedQ)
}()

/// The process-wide SSE concurrency gate. Separate from the normal
/// request/response gate so that long-lived SSE connections cannot starve
/// POST / JSON-RPC slots.
///
/// SSE connections hold a slot from THIS gate for their entire lifetime.
/// Normal requests hold a slot from `globalConcurrencyGate` only for the
/// duration of a single request/response exchange. The two pools are
/// completely independent — saturating SSE slots never queues normal
/// requests, and vice versa.
///
/// Default: 16 concurrent SSE streams, maxQueued=0 (shed immediately when
/// the cap is hit rather than queuing; SSE clients that cannot connect
/// retry on their own reconnect timer). Configurable via
/// `MOOTX01_HTTP_MAX_SSE` before first access.
public let globalSSEConcurrencyGate: ConcurrencyGate = {
    let env = ProcessInfo.processInfo.environment
    let maxC = env["MOOTX01_HTTP_MAX_SSE"].flatMap(Int.init) ?? 16
    // Clamp: at least 1, at most 256. maxQueued=0 — shed immediately; SSE
    // clients self-reconnect via EventSource retry so queuing adds no value
    // and would silently hold open sockets during backpressure.
    let clampedC = min(max(maxC, 1), 256)
    return ConcurrencyGate(maxConcurrent: clampedC, maxQueued: 0)
}()

/// The ARIA_MCP loopback HTTP transport (MCP "Streamable HTTP").
///
/// A resident, headless HTTP server bound to `127.0.0.1:<port>` that speaks the
/// SAME JSON-RPC 2.0 surface as `StdioServer`: a client POSTs one JSON-RPC frame
/// and receives one JSON-RPC frame as the response body. The wire bytes are
/// byte-identical to the stdio transport because both go through
/// `JSONValue.parse` on the way in and `JSONRPCResponse.asJSONValue.encoded()`
/// on the way out — only the framing differs (HTTP body vs newline-delimited).
///
/// This transport drives the existing, transport-neutral `ARIA_MCPDispatcher`
/// unchanged; the dispatcher does not know or care which transport invoked it.
/// stdio remains the default transport (testing, migrations); the resident HTTP
/// server is selected by `AriaMCPMain` when `MOOTX01_HTTP_PORT` is set.
///
/// SCOPE: request→response for JSON-RPC calls (POST) and read-only snapshots
/// (GET /api/graph, /api/lattice, /api/admin/estates). Server-Sent-Events are
/// available on `GET /api/events` (P2): the endpoint delivers a live keep-alive
/// stream via `LoopbackHTTP.SSEStream`, sending `: heartbeat` comment frames at
/// a 15-second interval to satisfy the MCP Streamable-HTTP GET event-stream
/// contract. Future Brain-pump notifications will be forwarded through this same
/// channel by extending `driveSSEStream` to accept a notification `AsyncStream`.
///
/// SECURITY: the listener binds loopback only (`POSIXSocket.listenLoopbackTCP`
/// hard-pins `INADDR_LOOPBACK`). Per ADR-LOOPBACKHTTP-001 there is no
/// authentication on the Community-Edition transport, but `route` enforces a
/// CSRF/DNS-rebinding guard: a request whose `Origin` is present and non-loopback
/// is rejected (403) before dispatch (`bearerToken` is read for logging only).
/// The Enterprise OAuth layer composes ABOVE this transport in v2, never inside it.
///
/// HARDENING: bounded concurrency via `globalConcurrencyGate` (default 64
/// concurrent / 256 queued). The accept loop uses a two-phase gate protocol:
/// `tryEnqueue()` (non-blocking depth check, runs on the accept thread) is
/// called immediately after `accept()`; overflow connections are shed inline
/// with HTTP 503 + Retry-After:1 without ever parking the accept thread.
/// `waitForSlot()` (the semaphore wait that enforces maxConcurrent) runs
/// inside the spawned Task so the accept loop is always free to accept the
/// next fd. Per-request latency is tracked in fast/mid/slow buckets and
/// 4xx/5xx/shed counts are exposed as module-level atomics, picked up by
/// `ServerMetricsTelemetry`.
///
/// SSE isolation (CAND-025): SSE streams (`GET /api/events`) use a SEPARATE
/// `globalSSEConcurrencyGate` (default 16 concurrent, maxQueued=0). A normal
/// gate slot is acquired at accept time for request parsing then released
/// immediately before the SSE stream starts; the SSE gate slot is then
/// acquired and held for the full stream lifetime. This prevents idle SSE
/// clients from exhausting the 64-slot normal pool and blocking all
/// POST/JSON-RPC traffic.
public struct HTTPServer: Sendable {

    public let dispatcher: ARIA_MCPDispatcher
    /// TCP port on 127.0.0.1 (0 = OS-assigned, used by tests).
    public let port: UInt16
    /// Maximum request body. MCP `tools/call` argument bodies can exceed
    /// LoopbackHTTP's 64 KiB default, which would silently truncate — so the
    /// transport sets a large cap (ADR-LOOPBACKHTTP-001 condition 2). Default
    /// 4 MiB; `AriaMCPMain` overrides from `MOOTX01_HTTP_MAX_BODY_BYTES`.
    public let maxBodyBytes: Int
    /// Returns the latest topology snapshot payload for the given estate ID string,
    /// or nil if no snapshot has been written yet. Injected at init by ResidentDaemon
    /// so the HTTP transport never imports ObserverSink. When nil, GET /api/graph
    /// returns structurePending:true (no snapshot in store).
    public let topologyReader: (@Sendable (String?) async -> Data?)?
    /// Concurrency gate for normal request/response cycles — injectable for testing
    /// (default: process-wide `globalConcurrencyGate`).
    public let concurrencyGate: ConcurrencyGate
    /// Concurrency gate for long-lived SSE streams — separate from the normal gate
    /// so SSE connections cannot starve POST / JSON-RPC traffic. Injectable for
    /// testing (default: process-wide `globalSSEConcurrencyGate`).
    public let sseConcurrencyGate: ConcurrencyGate

    public init(
        dispatcher: ARIA_MCPDispatcher,
        port: UInt16 = 4242,
        maxBodyBytes: Int = 4 * 1024 * 1024,
        topologyReader: (@Sendable (String?) async -> Data?)? = nil,
        concurrencyGate: ConcurrencyGate = globalConcurrencyGate,
        sseConcurrencyGate: ConcurrencyGate = globalSSEConcurrencyGate
    ) {
        self.dispatcher = dispatcher
        self.port = port
        self.maxBodyBytes = maxBodyBytes
        self.topologyReader = topologyReader
        self.concurrencyGate = concurrencyGate
        self.sseConcurrencyGate = sseConcurrencyGate
    }

    /// Bind the loopback listener and serve until the process is terminated.
    ///
    /// The blocking `accept()` loop runs on a dedicated thread so it never
    /// occupies the cooperative pool; each accepted connection is served on its
    /// own `Task`. The accept loop uses a two-phase gate protocol so it NEVER
    /// parks inside the gate:
    ///
    ///   1. `gate.tryEnqueue()` — non-blocking depth check on the accept thread.
    ///      If the gate is at `maxConcurrent + maxQueued` depth the connection is
    ///      shed immediately with HTTP 503 + `Retry-After: 1` before returning to
    ///      the accept call.
    ///   2. `gate.waitForSlot()` — blocking semaphore wait that enforces
    ///      `maxConcurrent`; runs inside the spawned Task, not on the accept thread.
    ///
    /// This split means the accept loop is always free to accept the next fd and
    /// count or shed overflow in-line with the documented 503 behaviour. Connections
    /// that would exceed `maxConcurrent + maxQueued` never stall or hit the OS TCP
    /// backlog — they are accepted and shed promptly.
    ///
    /// - Note: For the OS-assigned `port: 0` test path, call `bind()` directly;
    ///   `bind()` returns the bound port and `boundPort` reflects the assigned
    ///   port. `run()` has no return value.
    /// - Throws: `SocketError` if the loopback socket cannot be bound (e.g.
    ///   `EADDRINUSE` when the port is already taken).
    public func run() async throws {
        let listenFD = try bind().fd
        let dispatcher = self.dispatcher
        let maxBody = self.maxBodyBytes
        let reader = self.topologyReader
        let gate = self.concurrencyGate
        let sseGate = self.sseConcurrencyGate
        let thread = Thread {
            while true {
                guard let cfd = POSIXSocket.acceptOne(listenFD) else { continue }

                // Phase 1 (accept thread, NON-BLOCKING): check whether this
                // connection fits within the gate's depth limit. tryEnqueue()
                // only increments a counter — it never waits on the semaphore,
                // so the accept loop is always free to keep accepting fds.
                //
                // This is the correct place to count overflow: because we accept
                // unconditionally and then probe the gate, we always have the fd
                // in hand when we decide to shed, and the 503 + close is immediate
                // rather than silently pushed into the OS TCP backlog.
                if !gate.tryEnqueue() {
                    // Queue depth exceeded — shed inline on the accept thread.
                    _ = globalShedCounter.add(1, ordering: .relaxed)
                    HTTPServer.sendShedResponse(cfd)
                    continue
                }

                // Phase 2 (inside the spawned Task): waitForSlot() is the
                // semaphore wait — it blocks until one of the maxConcurrent
                // slots is free, but it runs on the cooperative pool, not on
                // the accept thread. The accept loop is already back at the
                // top waiting for the next fd.
                Task {
                    await HTTPServer.serve(
                        cfd,
                        dispatcher: dispatcher,
                        maxBodyBytes: maxBody,
                        topologyReader: reader,
                        gate: gate,
                        sseGate: sseGate
                    )
                }
            }
        }
        thread.name = "com.mootx01.aria-mcp.http.accept"
        thread.start()
        // Resident: the blocking accept loop runs on its own thread above. Park
        // this async function until the task is cancelled (process shutdown) with
        // a cancellable sleep loop — NOT a leaked continuation, which the Swift
        // runtime flags as "continuation misuse." Task.sleep throws on cancel,
        // which exits the loop cleanly.
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000) }  // 1h, re-armed
            catch { break }
        }
    }

    /// Bind the loopback listener without entering the accept loop. Used by tests
    /// (port 0) to drive a single connection deterministically; production uses
    /// `run()`.
    public func bind() throws -> (fd: Int32, port: UInt16) {
        let (fd, boundPort) = try POSIXSocket.listenLoopbackTCP(port: port)
        Logging.stderr.log("ARIA_MCP HTTP listening on 127.0.0.1:\(boundPort) (max body \(maxBodyBytes) bytes)")
        return (fd, boundPort)
    }

    /// Write an HTTP 503 Service Unavailable with Retry-After: 1 to the
    /// connection and close. Called on the accept thread when the concurrency
    /// queue is full; no dispatcher involvement.
    static func sendShedResponse(_ fd: Int32) {
        defer { close(fd) }
        let body = Data(#"{"error":"service_unavailable","retry_after":1}"#.utf8)
        let response = HTTPResponse(
            status: 503,
            headers: [
                "Content-Type": "application/json",
                "Retry-After": "1",
            ],
            body: body
        )
        response.send(fd: fd)
    }

    /// Serve one accepted connection: read the request, route it, write the
    /// response, close. Static so the accept thread captures only `Sendable`
    /// values, not the struct's storage. Records per-request latency and
    /// releases the concurrency gate slot on exit.
    ///
    /// Assumes the caller already called `gate.tryEnqueue()` successfully
    /// (the accept loop does this). This function calls `gate.waitForSlot()`
    /// first — the semaphore wait that limits actual concurrency — then
    /// proceeds to serve. The gate is released via defer on all exit paths.
    ///
    /// SSE fast path: `GET /api/events` with `Accept: text/event-stream` is
    /// intercepted here, before `route()`, and handed to `driveSSEStream()`.
    /// This is handled at the serve layer rather than inside route() because SSE
    /// requires holding the socket open past the end of a single
    /// request/response exchange; route() only handles stateless pairs.
    ///
    /// Two-gate protocol for SSE (CAND-025 hardening):
    /// Normal requests hold a `gate` slot for the request/response exchange only.
    /// SSE connections would hold that slot for their ENTIRE lifetime (minutes to
    /// hours), starving POST / JSON-RPC traffic. Fix: once SSE intent is detected,
    /// release the normal gate slot early and acquire a slot from the dedicated
    /// `sseGate` instead. The SSE gate is held for the full stream lifetime; the
    /// normal gate is free immediately.
    static func serve(
        _ fd: Int32,
        dispatcher: ARIA_MCPDispatcher,
        maxBodyBytes: Int,
        topologyReader: (@Sendable (String?) async -> Data?)? = nil,
        gate: ConcurrencyGate = globalConcurrencyGate,
        sseGate: ConcurrencyGate = globalSSEConcurrencyGate
    ) async {
        // Phase 2: wait for a concurrency slot. This is the semaphore
        // wait — it blocks on the cooperative pool until one of the
        // maxConcurrent slots is free. The accept thread already returned
        // from tryEnqueue() and is back accepting new fds.
        gate.waitForSlot()

        // Track in-flight depth for the high-water counter.
        // Atomic.add returns (oldValue:, newValue:) in Swift 6.3.
        let inFlight = globalInflightCounter.add(1, ordering: .relaxed).newValue
        updateInflightHighWater(inFlight)

        // Guard flag: set to true in the SSE path after we manually release the
        // normal gate early. The defer below checks this flag so the release is
        // not executed a second time on the SSE exit path.
        var normalSlotReleased = false
        defer {
            if !normalSlotReleased {
                _ = globalInflightCounter.add(-1, ordering: .relaxed)
                gate.release()
            }
        }

        // Start the per-request latency clock. clock_gettime_nsec_np is
        // available on Darwin and Glibc and returns a monotonic nanosecond
        // timestamp without a syscall on Apple Silicon (commpage path).
        let startNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

        defer {
            close(fd)
            let elapsed = Int(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - startNs)
            recordLatencyNs(elapsed)
        }

        // Bound blocking reads: a peer that trickles bytes cannot stall a cooperative-pool
        // task longer than this window. Mirrors moot-mgr's HTTPReadAPI.serve(_:) which sets
        // the same 30-second timeout via setsockopt before calling HTTPRequest.read. Without
        // this, a slow-header attacker can occupy a gate slot indefinitely, starving real
        // MCP clients. The gate slot is already held (waitForSlot above); the timeout ensures
        // it is released within a bounded window even if the read never returns.
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let request = HTTPRequest.read(fd: fd, maxBodyBytes: maxBodyBytes) else { return }

        // DNS-rebinding guard: applies to ALL GET requests including SSE. A browser from
        // a rebinding domain always sends a non-loopback Host; native MCP clients omit it.
        // Checked here (before the SSE branch and before route()) so that the SSE path
        // cannot be reached with a hostile Host. Mirrors moot-mgr HTTPReadAPI.serve(_:)
        // which checks isLoopbackHost before dispatching streamEvents.
        if request.method == "GET", !Self.isLoopbackHost(request.headers["host"]) {
            HTTPResponse(
                status: 421,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"misdirected_request"}"#.utf8)
            ).send(fd: fd)
            return
        }

        // SSE event-stream path. GET /api/events with the `text/event-stream`
        // Accept header (or ?stream=1 flag, parsed by HTTPRequest.wantsEventStream)
        // opens a keep-alive Server-Sent-Events stream. This branch is handled
        // before the normal route() call because SSE is long-lived: the socket
        // stays open as the server pushes heartbeat (and future notification) events
        // until the peer disconnects. The CSRF/origin guard runs first — cross-origin
        // browser tabs are not permitted on this endpoint either.
        //
        // Two-gate protocol (CAND-025):
        //   1. Release the normal gate slot early (before driving the stream) so
        //      normal request/response traffic is never blocked by idle SSE clients.
        //   2. Acquire the SSE gate slot instead. sseGate.tryEnqueue() is used here
        //      (non-blocking) because we are on the cooperative pool at this point
        //      and the SSE gate has maxQueued=0 by design — shed immediately if the
        //      SSE cap is hit.
        if request.method == "GET", request.path == "/api/events", request.wantsEventStream {
            guard Self.isOriginAllowed(request.origin) else {
                HTTPResponse(
                    status: 403,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":"forbidden_origin"}"#.utf8)
                ).send(fd: fd)
                return
            }

            // Release the normal concurrency slot before entering the long-lived stream.
            // Mark the flag so the outer defer does not double-release.
            normalSlotReleased = true
            _ = globalInflightCounter.add(-1, ordering: .relaxed)
            gate.release()

            // Acquire the SSE gate slot. tryEnqueue() + waitForSlot() is the
            // two-phase protocol: tryEnqueue() does the maxQueued depth check
            // (non-blocking); waitForSlot() waits for a maxConcurrent slot.
            // For the SSE gate maxQueued=0, so tryEnqueue() rejects immediately
            // when the SSE cap is hit — no silent queuing of SSE connections.
            guard sseGate.tryEnqueue() else {
                // SSE capacity exhausted — respond 503 and close.
                HTTPResponse(
                    status: 503,
                    headers: [
                        "Content-Type": "application/json",
                        "Retry-After": "5",
                    ],
                    body: Data(#"{"error":"sse_capacity_exceeded"}"#.utf8)
                ).send(fd: fd)
                return
            }
            sseGate.waitForSlot()
            defer { sseGate.release() }

            await driveSSEStream(fd: fd)
            return
        }

        let response = await route(request, dispatcher: dispatcher, topologyReader: topologyReader)

        // Count by status class.
        switch response.status {
        case 400..<500: _ = global4xxCounter.add(1, ordering: .relaxed)
        case 500..<600: _ = global5xxCounter.add(1, ordering: .relaxed)
        default: break
        }
        // 202 is the notification path (no response body per JSON-RPC spec).
        // Counts every non-202 response, including GET side-channel endpoints
        // such as /api/graph, /api/lattice, and /api/admin/estates — not
        // exclusively dispatched JSON-RPC tool calls.
        if response.status != 202 {
            _ = globalRPCCounter.add(1, ordering: .relaxed)
        }
        response.send(fd: fd)
    }

    /// Drive a Server-Sent-Events stream on `fd` until the peer disconnects or
    /// the task is cancelled.
    ///
    /// Sends the SSE response head (200 + `text/event-stream` + keep-alive) then
    /// enters a heartbeat loop: every `intervalNanoseconds` (default 15 s) it
    /// sends a comment-line ping (`: heartbeat`), which is invisible to
    /// EventSource message handlers but keeps NATs and proxies from closing the
    /// idle connection.
    ///
    /// The loop exits when a write fails (client disconnected or TCP reset) or
    /// when the calling Task is cancelled, after which `serve()` closes the fd
    /// via its defer block. Future notification events from the autonomic governor will be
    /// pushed into this loop by extending the function to accept a notification
    /// `AsyncStream`; the heartbeat loop already forms the correct scaffolding.
    ///
    /// `intervalNanoseconds` is exposed for testing so callers can verify a
    /// heartbeat arrives without waiting the production 15-second default.
    static func driveSSEStream(fd: Int32, intervalNanoseconds: UInt64 = 15_000_000_000) async {
        let stream = SSEStream(fd: fd)
        // Send the SSE response head. If the peer is already gone, exit early.
        guard stream.writeHead() else { return }
        // Heartbeat loop: write a comment-line ping on each interval tick.
        // SSE comment lines start with ":"; they are not dispatched to
        // EventSource `message` handlers but do keep TCP/NAT state alive.
        // Task.sleep throws CancellationError on task cancellation — catch it
        // to exit the loop cleanly (no stale fd write after cancellation).
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                // CancellationError or any other interruption: stop streaming.
                return
            }
            // Comment-line ping. SSEStream.send() wraps payloads in "data: …\n\n";
            // for a pure comment line we write the raw colon-prefixed frame
            // directly to avoid the "data:" prefix that send() always prepends.
            let ok = POSIXSocket.sendAll(fd, Data(": heartbeat\n\n".utf8))
            guard ok else { return }
        }
    }

    /// Route one HTTP request to an HTTP response carrying a JSON-RPC frame.
    ///
    /// MCP Streamable HTTP: the JSON-RPC request arrives as the POST body. The
    /// parse → decode → dispatch → encode path is identical to
    /// `StdioServer.handleFrame`, so the JSON-RPC bytes match across transports.
    /// JSON-RPC-level failures return HTTP 200 with a JSON-RPC error object (the
    /// error lives in the body, per JSON-RPC-over-HTTP convention); a
    /// notification (no id) gets HTTP 202 with no body.
    ///
    /// NOTE: `GET /api/events` (SSE event stream) is NOT routed here. It is
    /// handled earlier in `serve()` before `route()` is called, because SSE
    /// requires holding the socket open past the lifetime of a single
    /// request/response pair (the SSE loop writes to the fd until the client
    /// disconnects or the keep-alive heartbeat fails). `route()` only handles
    /// stateless request→response exchanges.
    static func route(
        _ request: HTTPRequest,
        dispatcher: ARIA_MCPDispatcher,
        topologyReader: (@Sendable (String?) async -> Data?)? = nil
    ) async -> HTTPResponse {
        // DNS-rebinding / CSRF guard (runs first). A loopback HTTP endpoint is
        // reachable from a browser tab via a domain that resolves to 127.0.0.1;
        // the page's request then carries that domain as its Origin. Native MCP
        // clients (Claude Code/Desktop, Codex CLI) send no Origin at all. So:
        // accept absent/loopback Origins, reject everything else. This is a CSRF
        // boundary, NOT authentication — it stays in the consumer (here), never
        // in LoopbackHTTP (ADR-LOOPBACKHTTP-001). Matches moot-mgr's
        // HTTPReadAPI.isOriginAllowed. The EE OAuth layer composes above this.
        guard Self.isOriginAllowed(request.origin) else {
            return HTTPResponse(
                status: 403,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"forbidden_origin"}"#.utf8)
            )
        }

        // GET routes: read-only topology, admin estate, and lattice address snapshots.
        // Served before the POST guard so the transport supports both JSON-RPC (POST)
        // and side-channel read endpoints (GET) on the same loopback listener.
        // GET /api/events is handled in serve() before route() is called — it is not
        // a stateless route but a long-lived SSE stream (see serve() SSE branch).
        if request.method == "GET" {
            // DNS-rebinding guard on GET routes: a browser page from a rebinding domain
            // always sends a Host header matching that domain. Native MCP clients and curl
            // omit Host or send the loopback address. Reject any GET whose Host header is
            // present and non-loopback; return 421 Misdirected Request (RFC 7540 §9.1.2).
            // POST routes are already protected by Origin + JSON-RPC framing; this guard is
            // GET-specific. Mirrors moot-mgr HTTPReadAPI.serve(_:) line ~336-339.
            guard Self.isLoopbackHost(request.headers["host"]) else {
                return HTTPResponse(
                    status: 421,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":"misdirected_request"}"#.utf8)
                )
            }
            switch request.path {
            case "/api/graph":
                // The ?estate= query param is intentionally NOT forwarded. The
                // graph endpoint always uses the default estate — matching the Rust
                // posture (get_graph_snapshot ignores ?estate= and reads
                // registry.default). Forwarding a caller-supplied estate selector
                // would let an unauthenticated caller select an arbitrary estate's
                // topology snapshot. The endpoint is loopback-only but its
                // authentication is posture-level, not credential-level, so the
                // caller must not influence estate selection here.
                return await Self.graphSnapshot(topologyReader: topologyReader)
            case "/api/admin/estates":
                return await Self.adminEstatesSnapshot(dispatcher: dispatcher)
            case "/api/lattice":
                return await Self.latticeSnapshot(dispatcher: dispatcher)
            default:
                return HTTPResponse(
                    status: 404,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":"not_found"}"#.utf8)
                )
            }
        }

        guard request.method == "POST" else {
            return HTTPResponse(
                status: 405,
                headers: ["Content-Type": "application/json", "Allow": "POST"],
                body: Data(#"{"error":"method_not_allowed"}"#.utf8)
            )
        }

        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(request.body)
        } catch {
            return jsonRPCError(.null, code: JSONRPCErrorCode.parseError, message: "Parse error: \(error)")
        }

        guard let rpc = JSONRPCRequest.decode(parsed) else {
            return jsonRPCError(.null, code: JSONRPCErrorCode.invalidRequest, message: "Invalid Request: malformed JSON-RPC envelope")
        }

        guard let response = await dispatcher.handle(rpc) else {
            // Notification: the JSON-RPC spec forbids a reply. HTTP carries that
            // as 202 Accepted with an empty body.
            return HTTPResponse(status: 202)
        }

        return encodedResponse(response)
    }

    /// Encode a JSON-RPC response into a 200 application/json HTTP response,
    /// matching `StdioServer.write`'s serialization exactly.
    static func encodedResponse(_ response: JSONRPCResponse) -> HTTPResponse {
        do {
            let body = try response.asJSONValue.encoded()
            return .json(status: 200, body: body)
        } catch {
            Logging.stderr.log("HTTP response encode failed: \(error)")
            return jsonRPCError(.null, code: JSONRPCErrorCode.internalError, message: "Internal error: \(error)")
        }
    }

    /// Build a 200 response whose body is a JSON-RPC error object.
    static func jsonRPCError(_ id: JSONValue, code: Int, message: String) -> HTTPResponse {
        let response = JSONRPCResponse.failure(id, JSONRPCError(code: code, message: message))
        let body = (try? response.asJSONValue.encoded())
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal error"}}"#.utf8)
        return .json(status: 200, body: body)
    }

    /// True if the request's Origin is acceptable: absent (native MCP clients
    /// send none) or a loopback origin. Any other origin is a cross-origin
    /// browser request (the DNS-rebinding vector) and is rejected. Mirrors
    /// moot-mgr's `HTTPReadAPI.isOriginAllowed`.
    ///
    /// The scheme+host prefix is matched exactly and the suffix validated to be
    /// empty or a port — this is equivalent to extracting the host and comparing
    /// it, without Foundation URL parsing quirks. Prefix-only comparison would
    /// accept attacker-owned names like `localhost.evil` or `127.0.0.1.evil`.
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
    /// Mirrors `HTTPReadAPI.isLoopbackHost` in moot-mgr and Rust `is_loopback_host`
    /// in moot-mgr's http_read_api.rs. Called from `route()` to block DNS-rebinding
    /// attacks on the unauthenticated GET endpoints.
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

    // MARK: - Private wire-shape types for GET endpoints (non-graph)

    /// Admin estate entry. Field `estateName` (not `name`) matches moot-mgr's
    /// `EstateAdminEntry.estateName` and the app.js `entry.estateName` binding.
    private struct ARIAAdminEstateEntry: Codable, Sendable {
        let estateUUID: String
        let estateName: String
        let kind: String
        let backend: String
        let mountState: String
    }

    private struct ARIAAdminEstatesPayload: Codable, Sendable {
        let hosted: [ARIAAdminEstateEntry]
    }

    // MARK: - GET /api/graph

    /// Serve the pre-computed topology snapshot from the stats store.
    ///
    /// The autonomic governor recomputes topology on its own cadence
    /// (default 5 min) and writes the payload to ObserverSink via the
    /// `topologyHandler` closure injected at AutonomicGovernor init.
    /// ResidentDaemon wires the matching `topologyReader` closure here.
    ///
    /// When `topologyReader` is nil (no store configured) or returns nil (no
    /// snapshot written yet), responds with `structurePending: true`. There is
    /// NO compute-on-read fallback — this is intentional: the governor is the
    /// single source of topology truth.
    ///
    /// Always reads the **default estate's** topology snapshot by passing `nil`
    /// to the reader. The `?estate=` query param from GET /api/graph is
    /// intentionally NOT forwarded here — an unauthenticated caller must not
    /// be able to select an arbitrary registered estate's snapshot. This matches
    /// the Rust `get_graph_snapshot` which always uses `registry.default` and
    /// explicitly documents that `?estate=` is ignored.
    ///
    /// Content-safety: the payload bytes come from the governor directly and
    /// contain only UUIDs, ordinals, floats, and ISO-8601 timestamps.
    private static func graphSnapshot(topologyReader: (@Sendable (String?) async -> Data?)?) async -> HTTPResponse {
        let pending = Data(#"{"nodes":[],"edges":[],"structurePending":true,"communities":[]}"#.utf8)
        guard let reader = topologyReader else {
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: pending)
        }
        // Pass nil so the reader uses the default estate. See doc comment above
        // for why a caller-supplied estate string is never accepted here.
        guard let body = await reader(nil) else {
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: pending)
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    // MARK: - GET /api/lattice

    /// One active lattice address (UDC/MDCC code) and the number of live
    /// drawers anchored to it. Sorted by count descending in the response.
    ///
    /// Content-safety: only the classification code (a compact decimal string)
    /// and a count cross this surface — no drawer text or rung content.
    private struct ARIALatticeAddress: Codable, Sendable {
        let code: String
        let count: Int
    }

    private struct ARIALatticePayload: Codable, Sendable {
        let addresses: [ARIALatticeAddress]
    }

    /// Return all active lattice addresses (udcCode) with drawer counts.
    ///
    /// Groups non-tombstoned drawers by their `udcCode`, omits the empty-string
    /// sentinel (unanchored drawers), and returns the result sorted by count
    /// descending. On an estate read failure, returns HTTP 503 with an error
    /// field — NOT a fabricated empty-200. A `200 {"addresses":[]}` on a read
    /// fault is indistinguishable from a genuinely empty estate and would tell
    /// the client "no lattice" when the truth is "could not read the lattice".
    /// A genuinely empty estate (read succeeds, zero anchored drawers) still
    /// returns 200 with an empty array. Mirrors Rust get_lattice_snapshot.
    ///
    /// Content-safety: only UDC/MDCC decimal codes and integer counts cross
    /// this surface (concepts §1.6). No drawer content is included.
    private static func latticeSnapshot(dispatcher: ARIA_MCPDispatcher) async -> HTTPResponse {
        do {
            let kit = dispatcher.tooling.kit
            let handle = dispatcher.tooling.handle
            let locus = try await kit.estate(for: handle)

            let drawers = try await locus.allDrawers().filter { $0.tombstonedAt == nil }

            // Group by udcCode; omit empty-string sentinel (unanchored drawers).
            var counts: [String: Int] = [:]
            for d in drawers where !d.udcCode.isEmpty {
                counts[d.udcCode, default: 0] += 1
            }

            // Sort by count descending, then by code ascending for determinism on ties.
            let addresses = counts
                .map { ARIALatticeAddress(code: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }

            let payload = ARIALatticePayload(addresses: addresses)
            let body = try JSONEncoder().encode(payload)
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
        } catch {
            Logging.stderr.log("GET /api/lattice estate read failed, returning 503: \(error)")
            // Surface the fault as a non-200 with an error field. Never a
            // fabricated empty-200 — that would be indistinguishable from a
            // genuinely empty estate.
            let body = Data(#"{"error":"lattice read failed","degraded":true}"#.utf8)
            return HTTPResponse(status: 503, headers: ["Content-Type": "application/json"], body: body)
        }
    }

    // MARK: - GET /api/admin/estates

    /// List all estates the kit is currently hosting: UUID, name, kind, backend,
    /// and mount state. ARIA_MCP always opens GLK estates via GeniusLocusKit.
    ///
    /// Backend is inferred from the process environment: `ARIA_MCP_POSTGRES_URL`
    /// → "PostgreSQL", `ARIA_MCP_SQLITE_PATH` → "SQLite", neither → "InMemory".
    private static func adminEstatesSnapshot(dispatcher: ARIA_MCPDispatcher) async -> HTTPResponse {
        let env = ProcessInfo.processInfo.environment
        let backend: String
        if env["ARIA_MCP_POSTGRES_URL"] != nil {
            backend = "PostgreSQL"
        } else if env["ARIA_MCP_SQLITE_PATH"] != nil {
            backend = "SQLite"
        } else {
            backend = "InMemory"
        }

        let kit = dispatcher.tooling.kit
        let handles = await kit.handles

        var entries: [ARIAAdminEstateEntry] = []
        for handle in handles {
            let mountStateRaw = await kit.mountState(for: handle)?.rawValue ?? "mounted"
            entries.append(ARIAAdminEstateEntry(
                estateUUID: handle.estateUUID.uuidString,
                estateName: handle.estateName,
                kind: "GLK",
                backend: backend,
                mountState: mountStateRaw
            ))
        }

        // Sort for byte-stable output.
        entries.sort { $0.estateUUID < $1.estateUUID }

        let payload = ARIAAdminEstatesPayload(hosted: entries)
        do {
            let body = try JSONEncoder().encode(payload)
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
        } catch {
            Logging.stderr.log("GET /api/admin/estates encode failed: \(error)")
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"hosted":[]}"#.utf8)
            )
        }
    }

}
