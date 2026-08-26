import AriaMCPWire

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

/// Lets cancellation unblock the first-party lane's blocking raw request read.
///
/// The GCD worker is the only code that unregisters the descriptor; `serve`
/// remains the only closer. A cancellation handler only calls `shutdown`, so it
/// cannot close an fd that the kernel has already reused. Cancellation is
/// latched to cover the interval before the worker registers.
final class HTTPReadSocketOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false

    func register(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        descriptor = fd
        return true
    }

    /// Atomically publish a completed read only if cancellation did not win.
    ///
    /// Cancellation can arrive after the final byte but before the worker
    /// resumes its continuation. Clearing the descriptor and judging the latch
    /// under one lock prevents that cancelled request from reaching dispatch.
    func complete(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard descriptor == fd else { return false }
        descriptor = -1
        return !cancelled
    }

    func shutdownNow() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        guard descriptor >= 0 else { return }
        shutdown(descriptor, SHUT_RDWR)
    }
}

// ============================================================
// MARK: - AsyncSemaphore
//
// A counting semaphore whose `wait()` is an async function — it
// SUSPENDS the calling Task (freeing the cooperative-executor thread)
// instead of blocking it. This is the key property the gate fix
// depends on (finding 105e5a96).
//
// Implementation: an NSLock protects two mutable fields:
//   slots   — the count of free tokens (starts at `value`).
//   waiters — a FIFO queue of suspended continuations.
//
// `wait()`: if `slots > 0`, decrement and return immediately.
//   Otherwise, stash the continuation in `waiters` and let the
//   Task suspend (no thread is held).
//
// `signal()`: if `waiters` is non-empty, pull the first waiter and
//   resume it. Otherwise, increment `slots`. The waiter is resumed
//   OUTSIDE the lock to avoid holding the lock during callback
//   scheduling.
//
// `@unchecked Sendable` is justified: all mutable state is
// protected by `lock`. The Swift type system cannot verify this
// automatically because NSLock is not a protocol; the `@unchecked`
// annotation declares that we have verified it by inspection.
// ============================================================
private final class AsyncSemaphore: @unchecked Sendable {

    private let lock = NSLock()
    private var slots: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.slots = value
    }

    /// Acquire one token, suspending the calling Task if none is available.
    /// The Task suspension frees the cooperative-executor thread so other
    /// work can proceed while this Task waits.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var canResumeImmediately = false
            lock.lock()
            if slots > 0 {
                slots -= 1
                canResumeImmediately = true
            } else {
                // No slot available — enqueue the continuation. signal() will
                // resume it outside its own lock when a slot becomes free.
                waiters.append(continuation)
            }
            lock.unlock()
            if canResumeImmediately {
                // Resume outside the lock: continuation.resume() schedules the
                // caller back onto the cooperative executor without holding lock.
                continuation.resume()
            }
        }
    }

    /// Release one token. Resumes the longest-waiting suspended Task (FIFO),
    /// or increments the free-slot count if no Task is waiting.
    /// This method is synchronous so it can be called from `defer` blocks.
    func signal() {
        let waiter: CheckedContinuation<Void, Never>?
        lock.lock()
        if waiters.isEmpty {
            slots += 1
            waiter = nil
        } else {
            waiter = waiters.removeFirst()
        }
        lock.unlock()
        // Resume outside the lock: avoids holding the lock during cooperative
        // executor scheduling and eliminates any chance of re-entrancy.
        waiter?.resume()
    }
}

// ============================================================
// MARK: - ConcurrencyGate
//
// An AsyncSemaphore-backed gate that bounds the number of
// simultaneous in-flight requests. It has two layers:
//
//   1. maxConcurrent: hard cap on simultaneous service tasks.
//      Requests that acquire a slot proceed immediately.
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
//   2. waitForSlot() — ASYNC suspension, called INSIDE the spawned
//      Task, not on the accept thread. The Task SUSPENDS (freeing its
//      cooperative-executor thread) until a slot is available. This
//      is the correct backpressure point: connections wait while the
//      accept loop continues accepting new connections AND existing
//      Tasks' off-pool continuations can still resume.
//
// Why the split matters:
//   Old (wrong): accept → tryAcquire (blocks on semaphore) → spawn Task
//     → accept loop parks on semaphore; OS TCP backlog silently absorbs
//     overflow; 503 cannot be returned promptly.
//   Interim (#97 fix): accept → tryEnqueue (never blocks) → spawn Task
//     → Task calls waitForSlot (DispatchSemaphore.wait() — STILL blocks
//     a cooperative-pool thread). With enough queued Tasks, all pool
//     threads are occupied by waiters and off-pool read continuations
//     cannot resume → deadlock (finding 105e5a96).
//   Current (correct): accept → tryEnqueue (never blocks) → spawn Task
//     → Task calls await waitForSlot (AsyncSemaphore — Task SUSPENDS,
//     thread is freed) → accept loop and off-pool continuations always
//     have executor threads available.
//
// The gate must be Sendable so it can cross the accept-thread
// boundary; AsyncSemaphore and the Atomic counters satisfy that
// requirement via @unchecked Sendable.
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
/// returns `true` the caller spawns a Task that calls `await waitForSlot()`
/// before serving. When the request is done, call `release()`.
///
/// This two-phase design keeps the accept thread unblocked so it can
/// always accept new fds and count or shed overflow in-line with the
/// documented 503 + Retry-After behaviour. The async `waitForSlot()`
/// ensures queued Tasks SUSPEND rather than occupying cooperative-pool
/// threads, preventing the deadlock described in finding 105e5a96.
public final class ConcurrencyGate: @unchecked Sendable {

    public let maxConcurrent: Int
    public let maxQueued: Int

    /// Count of connections currently enqueued (waiting for a slot or
    /// actively being served) — incremented by tryEnqueue, decremented
    /// by release. Does NOT include connections that have been shed.
    private let activeCount: Atomic<Int> = Atomic(0)
    /// Async semaphore: starts at maxConcurrent free slots. waitForSlot()
    /// suspends the Task (freeing its thread) when slots == 0; release()
    /// signals the semaphore, resuming the next queued Task.
    private let semaphore: AsyncSemaphore

    public init(maxConcurrent: Int = 64, maxQueued: Int = 256) {
        self.maxConcurrent = maxConcurrent
        self.maxQueued = maxQueued
        self.semaphore = AsyncSemaphore(value: maxConcurrent)
    }

    /// Phase 1 (accept thread, NON-BLOCKING): test whether the connection
    /// may be accepted into the gate. Returns `true` if the depth was within
    /// bounds (connection enqueued; caller MUST eventually call `release()`);
    /// returns `false` if the queue is full (caller should respond 503 and close).
    ///
    /// This method NEVER blocks. It increments activeCount and returns true
    /// when `depth <= maxConcurrent + maxQueued`; otherwise it undoes the
    /// increment and returns false. The async wait happens in
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

    /// Phase 2 (worker Task, ASYNC): suspend until a concurrency slot is
    /// free. Must be called after a successful `tryEnqueue()`, before
    /// beginning request service. The Task suspends (freeing its
    /// cooperative-executor thread) if all `maxConcurrent` slots are
    /// occupied, and resumes as soon as one is released by a finishing
    /// request. This suspension — not blocking — is what prevents the
    /// deadlock described in finding 105e5a96.
    public func waitForSlot() async {
        await semaphore.wait()
    }

    /// Release a previously acquired slot (decrement activeCount, signal
    /// the semaphore so the next queued Task can resume).
    /// Synchronous so it can be called from `defer` blocks.
    public func release() {
        _ = activeCount.add(-1, ordering: .relaxed)
        semaphore.signal()
    }

    /// Current number of enqueued connections (waiting for a slot + actively
    /// serving). Used for metrics.
    public var currentDepth: Int { activeCount.load(ordering: .relaxed) }

    // MARK: - Convenience one-shot path (test usage)

    /// Convenience: non-blocking enqueue + async wait combined.
    /// Returns `true` if the slot was acquired (caller MUST release),
    /// `false` if the queue was full (no slot acquired, no release needed).
    public func tryAcquire() async -> Bool {
        guard tryEnqueue() else { return false }
        await waitForSlot()
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
/// hard-pins `INADDR_LOOPBACK`). Per bounded loopback HTTP there is no
/// authentication on the Community-Edition transport, but `route` enforces a
/// CSRF/DNS-rebinding guard: a request whose `Origin` is present and non-loopback
/// is rejected (403) before dispatch (`bearerToken` is read for logging only).
/// The Enterprise OAuth layer composes ABOVE this transport in v2, never inside it.
///
/// SECURITY AUDIT DISPOSITION — fixed-port loopback impersonation (codex
/// 7a245e3e, MEDIUM). SCOPE: this disposition covers the THIRD-PARTY lane only.
/// The first-party lane at `/mcp/first-party` authenticates endpoint ownership
/// cryptographically — the client verifies a descriptor MAC before dialing and
/// completes a mutual HKDF handshake — so a port squatter cannot impersonate the
/// daemon to a first-party caller. It remains true of the third-party lane, and
/// the reasoning below is why that is accepted there rather than fixed:
/// the client configs the installer writes point at a fixed
/// `http://127.0.0.1:4242`, and that lane does not authenticate endpoint
/// ownership — so a same-user local process that binds the port before the
/// daemon could impersonate it to MCP clients. ACCEPTED for CE, by design, not
/// unmitigated: (1) the daemon owns the port continuously via launchd
/// `RunAtLoad` + `KeepAlive` (auto-restart), closing the pre-start race in
/// normal use; (2) the listener sets `SO_REUSEADDR` only, NOT `SO_REUSEPORT`, so
/// the port cannot be stolen while the daemon is live-listening; (3) the
/// residual attacker (same-user code-exec who kills the daemon and wins a
/// sub-second rebind) already has direct filesystem read of the estate — CE is
/// single-user local-first — so impersonation grants ~nothing beyond existing
/// access. A real fix needs the CLIENT to verify the SERVER's identity, which
/// third-party MCP clients (Cursor, Claude Code, …) do not support and we do not
/// control; a client→server token does NOT help (the client would hand the
/// secret to whoever holds the port). For callers we DO control, this is now
/// solved: the first-party lane's mutual authentication is exactly the
/// client-verifies-server binding this paragraph says third-party clients cannot
/// perform. Extending it to off-localhost MCP hosting remains future work, and
/// is the context in which endpoint authentication becomes enforceable for
/// third-party clients too. Do not "fix" by reverting HTTP clients to
/// stdio: that is the unauthorized flip already reverted in commit 5c035e6, and
/// it undoes the shared-resident-daemon architecture mandate.
///
/// HARDENING: bounded concurrency via `globalConcurrencyGate` (default 64
/// concurrent / 256 queued). The accept loop uses a two-phase gate protocol:
/// `tryEnqueue()` (non-blocking depth check, runs on the accept thread) is
/// called immediately after `accept()`; overflow connections are shed inline
/// with HTTP 503 + Retry-After:1 without ever parking the accept thread.
/// `waitForSlot()` (async suspension that enforces maxConcurrent) runs inside
/// the spawned Task, freeing the cooperative-executor thread while the Task
/// waits; this prevents the deadlock described in finding 105e5a96 where
/// blocking waiters starved off-pool read continuations. Per-request latency
/// is tracked in fast/mid/slow buckets and 4xx/5xx/shed counts are exposed
/// as module-level atomics, picked up by `ServerMetricsTelemetry`.
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
    /// transport sets a large cap (bounded loopback HTTP condition 2). Default
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
    /// The first-party authenticated lane, or `nil` — the default, and what
    /// every production construction site gets.
    ///
    /// `nil` makes the ENTIRE `/mcp/first-party` subtree unavailable: no
    /// handshake route, no request route, and no capability advertisement. The
    /// resident daemon (`ResidentDaemon.swift`) and the CLI never pass one, so
    /// the lane is dark by construction rather than by a runtime flag someone
    /// remembered to leave off. MACD-2c supplies the signed provider that will
    /// eventually populate it.
    public let firstPartyAuth: FirstPartyAuthServer?

    public init(
        dispatcher: ARIA_MCPDispatcher,
        port: UInt16 = 4242,
        maxBodyBytes: Int = 4 * 1024 * 1024,
        topologyReader: (@Sendable (String?) async -> Data?)? = nil,
        concurrencyGate: ConcurrencyGate = globalConcurrencyGate,
        sseConcurrencyGate: ConcurrencyGate = globalSSEConcurrencyGate,
        firstPartyAuth: FirstPartyAuthServer? = nil
    ) {
        self.dispatcher = dispatcher
        self.port = port
        self.maxBodyBytes = maxBodyBytes
        self.topologyReader = topologyReader
        self.concurrencyGate = concurrencyGate
        self.sseConcurrencyGate = sseConcurrencyGate
        self.firstPartyAuth = firstPartyAuth
    }

    /// Bind the loopback listener and serve until the task is cancelled.
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
    ///   2. `gate.waitForSlot()` — async suspension that enforces
    ///      `maxConcurrent`; runs inside the spawned Task, not on the accept thread.
    ///      The Task suspends (freeing its cooperative-executor thread) until a slot
    ///      is free, preventing the deadlock described in finding 105e5a96.
    ///
    /// This split means the accept loop is always free to accept the next fd and
    /// count or shed overflow in-line with the documented 503 behaviour. Connections
    /// that would exceed `maxConcurrent + maxQueued` never stall or hit the OS TCP
    /// backlog — they are accepted and shed promptly. Queued Tasks' async suspension
    /// ensures cooperative-executor threads remain available for off-pool read
    /// continuations, preventing the deadlock described in finding 105e5a96.
    ///
    /// Cooperative shutdown: when the calling Task is cancelled, the accept thread
    /// exits because `shutdown(2)` + `close(2)` cause the blocking `accept()` to
    /// return an error, and the stop flag converts that nil into a loop break.
    /// `run()` does NOT return until the accept thread has exited, so any work
    /// that follows (e.g. `provider.shutdown()`) runs strictly after the last
    /// `accept()` call. The fd is closed here before returning.
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
        let firstParty = self.firstPartyAuth
        // Cooperative-shutdown state: set to true before closing the fd so the
        // accept loop knows the nil return from acceptOne is intentional (not a
        // transient EAGAIN) and should break rather than continue.
        let stopFlag = Atomic<Bool>(false)
        // Signals once after the accept thread's loop body exits (break or return).
        // Waited on by run() before returning, so any code that follows (e.g.
        // provider.shutdown()) runs strictly after the last accept() call.
        let threadDone = DispatchSemaphore(value: 0)
        let thread = Thread {
            defer { threadDone.signal() }
            while true {
                guard let cfd = POSIXSocket.acceptOne(listenFD) else {
                    // accept() returned an error. Two causes:
                    //   1. Cooperative shutdown: stopFlag is set — break cleanly.
                    //   2. Transient EAGAIN or similar: continue accepting.
                    if stopFlag.load(ordering: .relaxed) { break } else { continue }
                }

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
                        sseGate: sseGate,
                        firstPartyAuth: firstParty
                    )
                }
            }
        }
        thread.name = "com.mootx01.aria-mcp.http.accept"
        thread.start()
        // Park this async function until the task is cancelled (process shutdown).
        // A cancellable sleep loop avoids leaked continuations that the Swift
        // runtime flags as "continuation misuse." Task.sleep throws on cancel,
        // which exits the loop.
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000) }  // 1h, re-armed
            catch { break }
        }
        // Cooperative shutdown: set the stop flag, then interrupt the blocking
        // accept() call via shutdown(SHUT_RDWR) + close. The accept thread sees
        // a nil return from acceptOne, checks the flag, and exits its loop.
        // shutdown() before close() is deliberate: it wakes a blocking accept()
        // immediately without racing against the kernel's file-descriptor table.
        stopFlag.store(true, ordering: .relaxed)
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        // Wait for the accept thread to stop before returning. Bridging the
        // blocking DispatchSemaphore.wait() through DispatchQueue.global() keeps
        // the cooperative executor thread free during the wait.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                threadDone.wait()
                cont.resume()
            }
        }
    }

    /// Enter the accept loop on an ALREADY-BOUND file descriptor.
    ///
    /// Used by `CommunityResidentMain` (Wave A1b): it calls `bind()` on a minimal
    /// HTTPServer BEFORE `DaemonProvider.activate()` to reserve the port early, then
    /// constructs the real dispatcher (with live estate/instance UUIDs from the
    /// activation result) and calls `serve(withFD:)` on the real server. This avoids
    /// a TOCTOU gap between descriptor publication and the server accepting connections.
    ///
    /// The fd must already be listening (`listen(2)` has been called). Cooperative
    /// shutdown: when the calling Task is cancelled, the accept thread is signalled
    /// via `shutdown(2)` + `close(2)`, the stop flag converts the resulting nil
    /// return from `acceptOne` into a loop break, and `serve(withFD:)` does NOT
    /// return until the accept thread has exited. The fd is closed before returning.
    /// Any code that follows (e.g. `provider.shutdown()`) therefore runs strictly
    /// after the last `accept()` call.
    ///
    /// - Parameter fd: A loopback TCP file descriptor already in the LISTEN state.
    ///   Ownership is transferred to `serve(withFD:)` — the caller must NOT close
    ///   it; `serve(withFD:)` closes it during shutdown.
    public func serve(withFD fd: Int32) async {
        let dispatcher = self.dispatcher
        let maxBody = self.maxBodyBytes
        let reader = self.topologyReader
        let gate = self.concurrencyGate
        let sseGate = self.sseConcurrencyGate
        let firstParty = self.firstPartyAuth
        // Cooperative-shutdown state: set to true before closing the fd so the
        // accept loop knows the nil return from acceptOne is intentional (not a
        // transient EAGAIN) and should break rather than continue.
        let stopFlag = Atomic<Bool>(false)
        // Signals once after the accept thread's loop body exits.
        // Waited on before returning so provider.shutdown() runs strictly after.
        let threadDone = DispatchSemaphore(value: 0)
        let thread = Thread {
            defer { threadDone.signal() }
            while true {
                guard let cfd = POSIXSocket.acceptOne(fd) else {
                    // accept() returned an error. Two causes:
                    //   1. Cooperative shutdown: stopFlag is set — break cleanly.
                    //   2. Transient EAGAIN or similar: continue accepting.
                    if stopFlag.load(ordering: .relaxed) { break } else { continue }
                }
                if !gate.tryEnqueue() {
                    _ = globalShedCounter.add(1, ordering: .relaxed)
                    HTTPServer.sendShedResponse(cfd)
                    continue
                }
                Task {
                    await HTTPServer.serve(
                        cfd,
                        dispatcher: dispatcher,
                        maxBodyBytes: maxBody,
                        topologyReader: reader,
                        gate: gate,
                        sseGate: sseGate,
                        firstPartyAuth: firstParty
                    )
                }
            }
        }
        thread.name = "com.mootx01.aria-mcp.http.accept"
        thread.start()
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
            catch { break }
        }
        // Cooperative shutdown: signal the accept thread, then wait for it.
        stopFlag.store(true, ordering: .relaxed)
        shutdown(fd, SHUT_RDWR)
        close(fd)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                threadDone.wait()
                cont.resume()
            }
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
    /// (the accept loop does this). This function calls `await gate.waitForSlot()`
    /// first — the async suspension that limits actual concurrency without
    /// blocking a cooperative-executor thread — then proceeds to serve.
    /// The gate is released via defer on all exit paths.
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
    ///
    /// FIRST-PARTY LANE. When `firstPartyAuth` is nil — the default, and what
    /// every production caller and every pre-existing test passes — this method
    /// behaves EXACTLY as it did before the lane existed, down to reading the
    /// request through `LoopbackHTTP.HTTPRequest.read`. That is deliberate: the
    /// strongest possible guarantee that the third-party lane did not regress is
    /// that its code path is literally untouched. Only when a first-party server
    /// is configured does the raw, strictly-parsed read path engage.
    static func serve(
        _ fd: Int32,
        dispatcher: ARIA_MCPDispatcher,
        maxBodyBytes: Int,
        topologyReader: (@Sendable (String?) async -> Data?)? = nil,
        gate: ConcurrencyGate = globalConcurrencyGate,
        sseGate: ConcurrencyGate = globalSSEConcurrencyGate,
        firstPartyAuth: FirstPartyAuthServer? = nil
    ) async {
        // Phase 2: wait for a concurrency slot. This is the async suspension
        // point — the Task suspends (freeing its cooperative-pool thread)
        // until one of the maxConcurrent slots is free. The accept thread
        // already returned from tryEnqueue() and is back accepting new fds.
        // Suspension (not blocking) is what prevents the deadlock described
        // in finding 105e5a96: freed threads remain available to resume
        // off-pool read continuations held by active connections.
        await gate.waitForSlot()

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
        // Run the BLOCKING read on a GCD worker so it does not occupy a
        // cooperative-pool thread for the 30s window: under parallel load that
        // starves the pool and other connections' Tasks can't run promptly.
        // The `await` suspends this Task (freeing the cooperative thread) while
        // the read blocks — matching moot-mgr's readRequestOffPool and the Rust
        // dedicated-thread-per-connection model. The 30s SO_RCVTIMEO below still
        // bounds a slow-header attacker exactly as before.
        //
        // TWO VIEWS OF ONE BYTE STRING.
        //
        // With no first-party server configured — every production caller and
        // every pre-existing test — `HTTPRequest.read` runs verbatim and this
        // method is byte-for-byte what it was before the lane existed.
        //
        // With one configured, the bytes are read once and then interpreted
        // TWICE, by two different parsers, for two different purposes:
        //
        //   - the PUBLIC lane gets `legacyCollapsedRequest`, a faithful
        //     reproduction of `LoopbackHTTP.HTTPRequest.parse` including every
        //     laxity it has. The public lane must behave identically whether or
        //     not the first-party lane happens to be configured.
        //   - the FIRST-PARTY subtree gets `StrictHTTPParser`, which refuses
        //     duplicates, obsolete folding, framing mismatches, and everything
        //     else the legacy parser tolerates.
        //
        // Routing everything through the strict parser — which is what this did
        // before — turned previously-working third-party requests into 400s the
        // moment a first-party authenticator was supplied. The routing decision
        // is therefore taken from the LEGACY view, so which lane a request
        // reaches never depends on the strict grammar.
        var firstPartyRaw: Data?
        let request: HTTPRequest?
        if firstPartyAuth != nil {
            let raw = await Self.readRawRequestOffPool(fd: fd, maxBodyBytes: maxBodyBytes)
            guard let raw else { return }
            firstPartyRaw = raw
            // Unparseable even by the lenient parser: close without answering,
            // exactly as `HTTPRequest.read` returning nil does today.
            request = Self.legacyCollapsedRequest(raw, maxBodyBytes: maxBodyBytes)
        } else {
            request = await withCheckedContinuation { (cont: CheckedContinuation<HTTPRequest?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    var tv = timeval(tv_sec: 30, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    cont.resume(returning: HTTPRequest.read(fd: fd, maxBodyBytes: maxBodyBytes))
                }
            }
        }
        guard let request else { return }

        // The authenticated subtree. Handled before the origin guard, the GET
        // host guard, the SSE branch, and `route()`, so no side channel under
        // `/mcp/first-party` can be reached by any path that does not go through
        // the MAC middleware first.
        if let firstPartyAuth, let raw = firstPartyRaw, Self.isFirstPartyTarget(request.path) {
            // Strict judgment applies from here on. A first-party request that
            // the strict grammar refuses is a 400 — on this lane an ambiguous
            // request is a refused request.
            let response: HTTPResponse
            if let strict = StrictHTTPParser.parse(raw, maxBodyBytes: maxBodyBytes) {
                response = await Self.routeFirstParty(strict, dispatcher: dispatcher, auth: firstPartyAuth)
            } else {
                response = Self.firstPartyError(status: 400, code: "bad_request")
            }
            switch response.status {
            case 400..<500: _ = global4xxCounter.add(1, ordering: .relaxed)
            case 500..<600: _ = global5xxCounter.add(1, ordering: .relaxed)
            default: break
            }
            if response.status != 202 { _ = globalRPCCounter.add(1, ordering: .relaxed) }
            response.send(fd: fd)
            return
        }

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
            // (non-blocking); waitForSlot() async-suspends for a maxConcurrent
            // slot. For the SSE gate maxQueued=0, tryEnqueue() rejects
            // immediately when the SSE cap is hit — no queuing of SSE connections.
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
            await sseGate.waitForSlot()
            defer { sseGate.release() }

            await driveSSEStream(fd: fd)
            return
        }

        // `publicLane` strips any first-party identity unconditionally, so the
        // unauthenticated lane cannot advertise `authenticated-first-party` or
        // publish the daemon's instance and estate identifiers even if a caller
        // handed in an identity-bearing dispatcher.
        let response = await route(
            request, dispatcher: dispatcher.publicLane, topologyReader: topologyReader
        )

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
        // in LoopbackHTTP. Matches moot-mgr's
        // HTTPReadAPI.isOriginAllowed. The EE OAuth layer composes above this.
        guard Self.isOriginAllowed(request.origin) else {
            return HTTPResponse(
                status: 403,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"forbidden_origin"}"#.utf8)
            )
        }

        // The first-party subtree never reaches `route()` when a first-party
        // server is configured — `serve()` handles it before this point. So
        // arriving here means the lane is NOT configured, and the entire subtree
        // must be unavailable. Without this guard a POST to /mcp/first-party
        // would fall through to the JSON-RPC parser below and be dispatched
        // WITHOUT authentication, which is the precise failure the lane exists
        // to prevent.
        guard !Self.isFirstPartyTarget(request.path) else {
            return HTTPResponse(
                status: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"not_found"}"#.utf8)
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
            // GET-specific. Mirrors moot-mgr HTTPReadAPI.serve(_:) line ~347.
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
            // sensitivity-grant status, physically outside the
            // JSON-RPC / MCP surface so prompt-injected models cannot reach it.
            case "/api/control/grants":
                return await Self.controlGrants(dispatcher: dispatcher)
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

        // sensitivity-grant control routes. Handled BEFORE JSON-RPC
        // parsing so they are structurally unreachable from the MCP tool surface —
        // a prompt-injected model that calls tools/call cannot route here.
        if request.path == "/api/control/unlock" {
            return await Self.controlUnlock(request: request, dispatcher: dispatcher)
        }
        if request.path == "/api/control/lock" {
            return await Self.controlLock(dispatcher: dispatcher)
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

    // MARK: - First-party authenticated lane
    //
    // Everything below is reachable only when an `FirstPartyAuthServer` was
    // supplied. With none, `isFirstPartyTarget` is never consulted and the whole
    // subtree falls through to `route()`, which 404s it (see the guard there).

    /// True when a request target addresses the first-party subtree.
    ///
    /// Matched as the exact path or a path-segment prefix, so `/mcp/first-partyX`
    /// is NOT first-party and cannot smuggle a request past the gate by sharing
    /// a textual prefix.
    static func isFirstPartyTarget(_ target: String) -> Bool {
        let base = FirstPartyAuthProtocol.requestPath
        if target == base { return true }
        return target.hasPrefix(base + "/") || target.hasPrefix(base + "?")
    }

    /// Read a complete request as raw bytes, mirroring `HTTPRequest.read`'s
    /// framing: accumulate until CRLFCRLF, then read exactly `Content-Length`
    /// more. Returns the full byte string for the strict parser to judge.
    static func readRawRequest(
        fd: Int32,
        maxBodyBytes: Int,
        maxHeaderBytes: Int = 64 * 1024,
        timeoutNanoseconds: UInt64 = 30_000_000_000
    ) -> Data? {
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let (deadline, overflow) = started.addingReportingOverflow(timeoutNanoseconds)
        guard !overflow else { return nil }
        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            if let found = buffer.range(of: terminator) { headerEnd = found; break }
            if buffer.count >= maxHeaderBytes { return nil }
            // Read the head one byte at a time. Until CRLFCRLF arrives we do not
            // know whether the request is an unauthenticated handshake, whose
            // body cap is 8 KiB, or a regular authenticated RPC. A wide recv can
            // pull body bytes into memory before that decision and silently
            // defeat the smaller cap.
            guard let chunk = receiveBeforeDeadline(fd: fd, max: 1, deadline: deadline),
                  !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
        guard let headerEnd else { return nil }

        // How many body bytes to read is decided with EXACTLY the rule
        // `LoopbackHTTP.HTTPRequest.parse` uses, because this reader stands in
        // for its socket reads and must consume the same bytes from the wire.
        // In particular: names are whitespace-trimmed before lookup, duplicates
        // collapse last-wins, a non-numeric or non-positive value means "no
        // body", and an oversize length is TRUNCATED at the cap rather than
        // refused. Getting any of these wrong changes what the public lane
        // reads, which is a third-party regression regardless of what the
        // strict parser later decides.
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let requestTarget = headerText.components(separatedBy: "\r\n").first?
            .split(separator: " ").dropFirst().first.map(String.init)
        var collapsed: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            collapsed[name] = value
        }

        var body = Data(buffer[headerEnd.upperBound...])
        if let raw = collapsed["content-length"], let declared = Int(raw), declared > 0 {
            // Challenge and establishment are unauthenticated inputs. Their
            // 8-KiB protocol cap is applied to the socket read itself, not only
            // later by strictJSONObject after a larger allocation has happened.
            let routeCap: Int
            if requestTarget == FirstPartyAuthProtocol.challengePath
                || requestTarget == FirstPartyAuthProtocol.establishPath {
                routeCap = min(maxBodyBytes, FirstPartyAuthProtocol.handshakeMaxBodyBytes)
            } else {
                routeCap = maxBodyBytes
            }
            let want = min(declared, routeCap)
            while body.count < want {
                guard let chunk = receiveBeforeDeadline(
                    fd: fd, max: min(16 * 1024, want - body.count), deadline: deadline
                ), !chunk.isEmpty else { break }
                body.append(chunk)
            }
            if body.count > want { body = body.prefix(want) }
        }
        // With no usable Content-Length nothing further is read, matching the
        // legacy reader. Whatever already sat in the buffer is handed on: the
        // legacy view discards it exactly as before, and the strict view refuses
        // it, which is the correct answer on the authenticated lane.
        return Data(buffer[buffer.startIndex..<headerEnd.upperBound]) + body
    }

    /// Run the blocking first-party raw read off the cooperative executor while
    /// preserving Swift task cancellation. The cancellation handler shuts down
    /// the registered socket; the worker unregisters before returning, and the
    /// caller remains the sole closer.
    static func readRawRequestOffPool(
        fd: Int32,
        maxBodyBytes: Int,
        timeoutNanoseconds: UInt64 = 30_000_000_000,
        afterRegistration: (@Sendable () -> Void)? = nil
    ) async -> Data? {
        let owner = HTTPReadSocketOwner()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard owner.register(fd) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    afterRegistration?()
                    let raw = Self.readRawRequest(
                        fd: fd,
                        maxBodyBytes: maxBodyBytes,
                        timeoutNanoseconds: timeoutNanoseconds
                    )
                    continuation.resume(returning: owner.complete(fd) ? raw : nil)
                }
            }
        } onCancel: {
            owner.shutdownNow()
        }
    }

    /// Receive one chunk without letting a peer renew the request deadline by
    /// periodically sending a byte. SO_RCVTIMEO is reset to the time REMAINING
    /// on one absolute monotonic deadline before every blocking recv.
    private static func receiveBeforeDeadline(
        fd: Int32, max maximumBytes: Int, deadline: UInt64
    ) -> Data? {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        guard now < deadline, maximumBytes > 0 else { return nil }
        let remaining = deadline - now
        var tv = timeval(
            tv_sec: Int(remaining / 1_000_000_000),
            tv_usec: Int32(max(1, (remaining % 1_000_000_000) / 1_000))
        )
        guard setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { return nil }
        guard let chunk = POSIXSocket.recv(fd, max: maximumBytes), !chunk.isEmpty else { return nil }
        // A byte may arrive just after the absolute deadline even though the
        // kernel timeout was armed just before it. Never admit that byte into
        // the request buffer.
        guard clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) <= deadline else { return nil }
        return chunk
    }

    /// Parse raw bytes with the FROZEN semantics of
    /// `LoopbackHTTP.HTTPRequest.parse`, for the public lane.
    ///
    /// This is a faithful reproduction, not an improvement, and every apparent
    /// laxity below is deliberate. The public lane must behave byte-identically
    /// whether or not a first-party authenticator happens to be configured, so
    /// this reproduces the legacy parser's acceptances as well as its rejections:
    ///
    /// - field names are whitespace-trimmed before use, so `Name : v` is `name`;
    /// - duplicate fields collapse last-wins, including `Content-Length`;
    /// - a `Content-Length` above the cap TRUNCATES the body, it does not refuse;
    /// - a non-numeric or non-positive `Content-Length`, or none at all, DISCARDS
    ///   the body entirely;
    /// - `Transfer-Encoding` is ignored;
    /// - the request line is split on runs of spaces, so extra spaces are
    ///   tolerated and only the first two tokens are required.
    ///
    /// Routing the public lane through `StrictHTTPParser` instead — which refuses
    /// every one of those — silently turned previously-working third-party
    /// requests into 400s the moment the first-party lane was configured. That
    /// was a third-party regression, and this function exists to make it
    /// impossible.
    static func legacyCollapsedRequest(_ raw: Data, maxBodyBytes: Int) -> HTTPRequest? {
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerEnd = raw.range(of: terminator) else { return nil }
        // The legacy parser includes the terminator in the header text and then
        // stops at the first empty line; reproduced exactly.
        let headerData = raw[raw.startIndex..<headerEnd.upperBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let (path, query): (String, String) = {
            if let mark = target.firstIndex(of: "?") {
                return (String(target[target.startIndex..<mark]), String(target[target.index(after: mark)...]))
            }
            return (target, "")
        }()

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        var body = Data(raw[headerEnd.upperBound...])
        if let lenStr = headers["content-length"], let len = Int(lenStr), len > 0 {
            let want = min(len, maxBodyBytes)
            if body.count > want { body = body.prefix(want) }
        } else {
            body = Data()
        }
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    /// Collapse a strictly-parsed request into the `HTTPRequest` shape the
    /// third-party routes expect.
    ///
    /// Reproduces `LoopbackHTTP.HTTPRequest.parse`'s own semantics deliberately:
    /// lowercased names and last-wins on duplicates. The lossy behaviour is
    /// correct HERE — this value only ever reaches the third-party routes, which
    /// must behave exactly as they did before this lane existed. The lossless
    /// view is kept separately for the MAC check.
    static func collapsed(_ strict: StrictHTTPRequest) -> HTTPRequest {
        var headers: [String: String] = [:]
        for field in strict.headers { headers[field.name] = field.value }
        let path: String
        let query: String
        if let mark = strict.requestTarget.firstIndex(of: "?") {
            path = String(strict.requestTarget[strict.requestTarget.startIndex..<mark])
            query = String(strict.requestTarget[strict.requestTarget.index(after: mark)...])
        } else {
            path = strict.requestTarget
            query = ""
        }
        return HTTPRequest(
            method: strict.method, path: path, query: query, headers: headers, body: strict.body
        )
    }

    /// Route one request on the authenticated first-party lane.
    ///
    /// Only three targets exist: the two handshake steps and the request lane
    /// itself. Everything else under the subtree — GET, SSE, control, topology,
    /// unlock — is 404, because a side channel that skips the middleware is a
    /// side channel that skips authentication.
    static func routeFirstParty(
        _ request: StrictHTTPRequest,
        dispatcher: ARIA_MCPDispatcher,
        auth: FirstPartyAuthServer
    ) async -> HTTPResponse {
        // Only POST exists on this lane.
        guard request.method == FirstPartyAuthProtocol.requestMethod else {
            return firstPartyError(status: 405, code: "method_not_allowed")
        }

        switch request.requestTarget {
        case FirstPartyAuthProtocol.challengePath:
            return await firstPartyChallenge(request, auth: auth)
        case FirstPartyAuthProtocol.establishPath:
            return await firstPartyEstablish(request, auth: auth)
        case FirstPartyAuthProtocol.requestPath:
            return await firstPartyDispatch(request, dispatcher: dispatcher, auth: auth)
        default:
            return firstPartyError(status: 404, code: "not_found")
        }
    }

    /// A bounded error response. Carries a short code and nothing else — never a
    /// proof, a MAC, a key, or an internal error's description.
    static func firstPartyError(status: Int, code: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"\#(code)"}"#.utf8)
        )
    }

    /// Handshake step 1.
    static func firstPartyChallenge(
        _ request: StrictHTTPRequest, auth: FirstPartyAuthServer
    ) async -> HTTPResponse {
        guard let contentType = request.singleValue(for: "content-type"),
              FirstPartyAuthProtocol.isExactContentType(contentType) else {
            return firstPartyError(status: 415, code: "unsupported_media_type")
        }
        // The server reads this BEFORE any proof exists, so it is the most
        // exposed decode on the daemon side. Same strict shape the client
        // applies to responses: exact key set, no duplicates, size-capped.
        guard let object = FirstPartyAuthProtocol.strictJSONObject(
                  request.body, expected: ["clientNonce", "descriptorDigest"]
              ),
              let nonceRaw = object["clientNonce"] as? String,
              let digestRaw = object["descriptorDigest"] as? String,
              let clientNonce = FirstPartyAuthProtocol.base64URLDecode(nonceRaw),
              let digest = FirstPartyAuthProtocol.base64URLDecode(digestRaw),
              clientNonce.count == FirstPartyAuthProtocol.nonceByteCount,
              digest.count == FirstPartyAuthProtocol.macByteCount else {
            return firstPartyError(status: 400, code: "bad_request")
        }
        do {
            let issued = try await auth.challenge(clientNonce: clientNonce, descriptorDigest: digest)
            let payload: [String: Any] = [
                "sessionIdentifier": FirstPartyAuthProtocol.base64URLEncode(issued.sessionIdentifier),
                "serverNonce": FirstPartyAuthProtocol.base64URLEncode(issued.serverNonce),
                "issuedAt": issued.issuedAt,
                "idleExpiry": issued.idleExpiry,
                "absoluteExpiry": issued.absoluteExpiry,
                "serverProof": FirstPartyAuthProtocol.base64URLEncode(issued.serverProof),
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                return firstPartyError(status: 500, code: "internal_error")
            }
            return .json(status: 200, body: body)
        } catch {
            return firstPartyError(status: 401, code: "unauthorized")
        }
    }

    /// Handshake step 2.
    static func firstPartyEstablish(
        _ request: StrictHTTPRequest, auth: FirstPartyAuthServer
    ) async -> HTTPResponse {
        guard let contentType = request.singleValue(for: "content-type"),
              FirstPartyAuthProtocol.isExactContentType(contentType) else {
            return firstPartyError(status: 415, code: "unsupported_media_type")
        }
        guard let object = FirstPartyAuthProtocol.strictJSONObject(
                  request.body, expected: ["sessionIdentifier", "clientProof"]
              ),
              let sessionRaw = object["sessionIdentifier"] as? String,
              let proofRaw = object["clientProof"] as? String,
              let sessionIdentifier = FirstPartyAuthProtocol.base64URLDecode(sessionRaw),
              let clientProof = FirstPartyAuthProtocol.base64URLDecode(proofRaw),
              sessionIdentifier.count == FirstPartyAuthProtocol.sessionIdentifierByteCount,
              clientProof.count == FirstPartyAuthProtocol.macByteCount else {
            return firstPartyError(status: 400, code: "bad_request")
        }
        do {
            let proof = try await auth.establish(
                sessionIdentifier: sessionIdentifier, clientProof: clientProof
            )
            let payload = ["establishmentProof": FirstPartyAuthProtocol.base64URLEncode(proof)]
            guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                return firstPartyError(status: 500, code: "internal_error")
            }
            return .json(status: 200, body: body)
        } catch {
            return firstPartyError(status: 401, code: "unauthorized")
        }
    }

    /// The authenticated request lane.
    ///
    /// The middleware runs to completion before `JSONValue.parse` is reached —
    /// an unauthenticated peer never reaches the JSON parser, let alone the
    /// dispatcher. Every response leaving here is MACed, including the empty 204
    /// a notification receives and any error emitted after authenticated
    /// dispatch.
    static func firstPartyDispatch(
        _ request: StrictHTTPRequest,
        dispatcher: ARIA_MCPDispatcher,
        auth: FirstPartyAuthServer
    ) async -> HTTPResponse {
        let authenticated: FirstPartyAuthenticatedRequest
        do {
            authenticated = try await auth.authenticate(request)
        } catch let error as FirstPartyAuthError {
            // A replay is a conflict rather than a credential failure, and a
            // wrong media type is neither; everything else is 401. No branch
            // carries any detail beyond a short code.
            switch error {
            case .replayedSequence, .sequenceExhausted:
                return firstPartyError(status: 409, code: "conflict")
            case .malformedRequest:
                return firstPartyError(status: 415, code: "unsupported_media_type")
            default:
                return firstPartyError(status: 401, code: "unauthorized")
            }
        } catch {
            return firstPartyError(status: 401, code: "unauthorized")
        }

        // Authenticated. The identity reported by `initialize` on this lane is
        // taken from the authenticator that just verified the request — never
        // from the dispatcher the caller supplied — so the advertised capability
        // and the enforced authentication cannot disagree.
        let identified = dispatcher.withFirstPartyIdentity(await auth.identity)

        // Only now is the body parsed.
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(authenticated.body)
        } catch {
            return await sealed(
                auth: auth, authenticated: authenticated,
                response: jsonRPCError(.null, code: JSONRPCErrorCode.parseError, message: "Parse error")
            )
        }
        guard let rpc = JSONRPCRequest.decode(parsed) else {
            return await sealed(
                auth: auth, authenticated: authenticated,
                response: jsonRPCError(
                    .null, code: JSONRPCErrorCode.invalidRequest,
                    message: "Invalid Request: malformed JSON-RPC envelope"
                )
            )
        }
        guard let response = await identified.handle(rpc) else {
            // Notification. It receives a MACed empty 204 rather than the
            // third-party lane's bare 202: an unauthenticated "nothing happened"
            // is as useful to an attacker as a forged result.
            return await sealed(
                auth: auth, authenticated: authenticated, response: HTTPResponse(status: 204)
            )
        }
        return await sealed(auth: auth, authenticated: authenticated, response: encodedResponse(response))
    }

    /// Stamp the response MAC onto an outgoing first-party response.
    ///
    /// The MAC covers the status, the content type, and the exact body, bound to
    /// the request's sequence — so a response cannot be replayed as the answer
    /// to a different request, and a 200 cannot be downgraded to a 401 in
    /// flight.
    static func sealed(
        auth: FirstPartyAuthServer,
        authenticated: FirstPartyAuthenticatedRequest,
        response: HTTPResponse
    ) async -> HTTPResponse {
        var out = response
        // Case-insensitive lookup. HTTP field names are case-insensitive and
        // `HTTPResponse` stores them in a plain dictionary, so a response built
        // with "content-type" rather than "Content-Type" would MAC an empty
        // content type here while the client verified against the real one — a
        // spurious authentication failure that would be extremely hard to read
        // from the outside.
        let contentType = out.headers.first { $0.key.lowercased() == "content-type" }?.value ?? ""
        guard let mac = await auth.sealResponse(
            sessionIdentifier: authenticated.sessionIdentifier,
            sequence: authenticated.sequence,
            status: UInt16(out.status),
            contentType: contentType,
            body: out.body
        ) else {
            // The session vanished between authentication and sealing (an
            // expiry or a revocation). An unMACed body must never leave this
            // lane, so the request fails rather than answering in the clear.
            return firstPartyError(status: 401, code: "unauthorized")
        }
        out.headers[FirstPartyAuthProtocol.responseMACHeaderWireName] = FirstPartyAuthProtocol.base64URLEncode(mac)
        return out
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
    /// Groups non-tombstoned drawers by their `udcCode`, omits empty-string and
    /// "000" unclassified sentinels, and returns the result sorted by count
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
        // Community-only mode has no GeniusLocusKit tooling; lattice is unavailable.
        guard let tooling = dispatcher.tooling else {
            return HTTPResponse(
                status: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"not_found"}"#.utf8)
            )
        }
        do {
            let kit = tooling.kit
            let handle = tooling.handle
            let locus = try await kit.estate(for: handle)

            let drawers = try await locus.allDrawers().filter { $0.tombstonedAt == nil }

            // Group by udcCode; omit empty-string and "000" unclassified sentinels.
            var counts: [String: Int] = [:]
            for d in drawers where !d.udcCode.isEmpty && d.udcCode != "000" {
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
        // Community-only mode has no GeniusLocusKit tooling; admin estates unavailable.
        guard let tooling = dispatcher.tooling else {
            return HTTPResponse(
                status: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"not_found"}"#.utf8)
            )
        }
        let env = ProcessInfo.processInfo.environment
        let backend: String
        if env["ARIA_MCP_POSTGRES_URL"] != nil {
            backend = "PostgreSQL"
        } else if env["ARIA_MCP_SQLITE_PATH"] != nil {
            backend = "SQLite"
        } else {
            backend = "InMemory"
        }

        let kit = tooling.kit
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

    // MARK: - out-of-band sensitivity grants sensitivity-grant control endpoints

    /// GET /api/control/grants
    ///
    /// Returns the current sensitivity grant state. Loopback-only (enforced by
    /// the caller's CORS/origin gate). Never surfaced on the JSON-RPC/MCP layer.
    ///
    /// Response body (application/json):
    /// ```json
    /// {
    ///   "tier": "restricted"|"secret"|null,
    ///   "expiresAt": "<ISO8601 UTC string>"|null
    /// }
    /// ```
    /// `tier` and `expiresAt` are both null when neither tier is currently granted.
    private static func controlGrants(dispatcher: ARIA_MCPDispatcher) async -> HTTPResponse {
        // Community-only mode has no sensitivity ledger; return null state.
        guard let tooling = dispatcher.tooling else {
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"tier":null,"expiresAt":null}"#.utf8)
            )
        }
        let now = Date()
        let iso = iso8601Formatter()
        if let (tier, expiresAt) = await tooling.sensitivityUnlockLedger.grantStateSnapshot(now: now) {
            let expiresStr = iso.string(from: expiresAt)
            // Hand-construct JSON — struct encoding would be fine too, but the
            // shape is simple enough that raw concatenation avoids an import.
            let body = Data(
                #"{"tier":"\#(tier.rawValue)","expiresAt":"\#(expiresStr)"}"#.utf8
            )
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
        } else {
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"tier":null,"expiresAt":null}"#.utf8)
            )
        }
    }

    /// POST /api/control/unlock
    ///
    /// Grants the requested sensitivity tier. The caller (CLI) is responsible
    /// for authenticating the user (Swift: LA assertion; Rust: PBKDF2 password).
    /// The daemon validates only that the proof timestamp is fresh (within 10
    /// seconds of its own clock) to guard against replay over a stale socket —
    /// not a cryptographic guarantee, but loopback-only exposure limits the
    /// practical attack surface (out-of-band sensitivity grants "fail-closed, loopback only").
    ///
    /// Request body (application/json):
    /// ```json
    /// {
    ///   "tier": "restricted"|"secret",
    ///   "proof": {"ts": <unix ms integer>}
    /// }
    /// ```
    ///
    /// Response body (application/json):
    /// ```json
    /// {
    ///   "ok": true,
    ///   "tier": "restricted"|"secret",
    ///   "expiresAt": "<ISO8601 UTC string>"
    /// }
    /// ```
    private static func controlUnlock(request: HTTPRequest, dispatcher: ARIA_MCPDispatcher) async -> HTTPResponse {
        func badRequest(_ msg: String) -> HTTPResponse {
            let body = Data(("{\"error\":\"\(msg)\"}").utf8)
            return HTTPResponse(status: 400, headers: ["Content-Type": "application/json"], body: body)
        }

        // Parse request body as JSON.
        guard let root = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return badRequest("invalid_json")
        }

        // Validate tier field.
        guard let tierRaw = root["tier"] as? String,
              let tier = SensitivityTier(rawValue: tierRaw) else {
            return badRequest("invalid_tier — must be 'restricted' or 'secret'")
        }

        // Validate proof: must be a dict with a "ts" unix-millisecond timestamp.
        guard let proof = root["proof"] as? [String: Any],
              let proofTsMs = proof["ts"] as? Int else {
            return badRequest("missing_proof — proof.ts (unix ms) required")
        }

        // Freshness check: reject if proof timestamp is more than 10 seconds old
        // or more than 5 seconds in the future (clock skew allowance).
        // This is not a cryptographic proof — it is a replay-resistance measure
        // over the local loopback socket. The real authentication
        // happened on the CLI side (LA assertion on Swift, PBKDF2 on Rust).
        let now = Date()
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        let skewMs = proofTsMs - nowMs
        guard skewMs > -10_000 && skewMs < 5_000 else {
            return HTTPResponse(
                status: 403,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"proof_stale — timestamp outside ±10s window"}"#.utf8)
            )
        }

        // Community-only mode has no sensitivity ledger; unlock is unavailable.
        guard let tooling = dispatcher.tooling else {
            return HTTPResponse(
                status: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"not_found"}"#.utf8)
            )
        }

        // Grant the tier. Actor isolation requires await.
        switch tier {
        case .restricted:
            await tooling.sensitivityUnlockLedger.grantRestricted(now: now)
        case .secret:
            await tooling.sensitivityUnlockLedger.grantSecret(now: now)
        }

        // Read back the resulting expiry for the response.
        let iso = iso8601Formatter()
        if let (_, expiresAt) = await tooling.sensitivityUnlockLedger.grantStateSnapshot(now: now) {
            let expiresStr = iso.string(from: expiresAt)
            let body = Data(
                #"{"ok":true,"tier":"\#(tier.rawValue)","expiresAt":"\#(expiresStr)"}"#.utf8
            )
            Logging.stderr.log("\(tier.rawValue) grant issued, expires \(expiresStr)")
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
        } else {
            // Should not happen — we just granted. Return ok without expiry.
            Logging.stderr.log("grant issued but ledger returned nil snapshot immediately after")
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"ok":true,"tier":"\#(tier.rawValue)","expiresAt":null}"#.utf8)
            )
        }
    }

    /// POST /api/control/lock
    ///
    /// Drops all active sensitivity grants immediately. Idempotent — safe to
    /// call when no grants are active. Does not require a proof: the local user
    /// can always lock (dropping grants is never a privilege escalation).
    ///
    /// Response body (application/json): `{"ok":true}`
    private static func controlLock(dispatcher: ARIA_MCPDispatcher) async -> HTTPResponse {
        // Community-only mode has no sensitivity ledger; lock is a no-op (already locked).
        guard let tooling = dispatcher.tooling else {
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"ok":true}"#.utf8)
            )
        }
        await tooling.sensitivityUnlockLedger.lock()
        Logging.stderr.log("all sensitivity grants locked")
        return HTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"ok":true}"#.utf8)
        )
    }

    /// ISO8601 formatter for UTC timestamps in control endpoint responses.
    ///
    /// Returns a UTC `YYYY-MM-DDTHH:MM:SSZ` string — no fractional seconds,
    /// for compactness. Recipients can compare against `Date.now` to compute
    /// the remaining grant window.
    private static func iso8601Formatter() -> ISO8601DateFormatter {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        fmt.timeZone = TimeZone(identifier: "UTC")!
        return fmt
    }

}
