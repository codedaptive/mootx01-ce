import Foundation

/// BenchClock — pinnable clock for the benchmark replay seam.
///
/// ## Purpose
///
/// Wall-clock time enters the MCP request path via `Date()` calls in tool
/// runners (filedAt timestamps, recency/decay scoring in `moot_memory_search`,
/// event-time bounds, etc.). Because each replay run ingests at a different
/// instant, decay and recency features shift between otherwise-identical runs
/// — ranks flip at close boundaries and the `meanCurrentRank` / `meanStaleInTopK`
/// metrics drift. This makes the "verdict: DETERMINISTIC" check fail for close
/// pairs even when seed and content are identical.
///
/// `BenchClock` pins the clock to a fixed base instant (read once at server
/// startup) so every replay run sees the same absolute timestamps for the
/// same logical sequence of tool calls.
///
/// ## Environment variable
///
/// Set `MOOT_BENCH_EPOCH_NOW` to an ISO8601 instant (e.g.
/// `"2026-07-25T00:00:00Z"`) before starting `mootx01 serve`. When the
/// variable is present and parseable:
///
///   `now = base_instant + call_index * 1 second`
///
/// The `call_index` increments atomically with each `now()` call, so
/// ordering, HLC advance, and `filedAt` uniqueness are all preserved.
///
/// When the variable is absent or empty, `now()` returns `Date()` —
/// byte-identical behavior to before this seam existed.
///
/// ## Contract
///
/// - NOT exposed on the MCP surface (no tool arg, no schema mention).
///   This is an internal measurement seam used exclusively by the
///   benchmarker to pin drawer timestamps across a benchmark run.
/// - SCOPE: the MCP request path only. Daemon/governor/background
///   clocks (dreaming, HLC self-advance, periodic coach) are NOT routed
///   through `BenchClock` — they must remain wall-clock for correctness.
/// - Thread-safe: `NSLock` guards the call counter. `ToolDispatcher` is a
///   `Sendable` struct carrying this class as a reference; `@unchecked Sendable`
///   is correct because all mutation goes through the lock.
///
/// ## Usage
///
/// ```swift
/// // Production (reads from ProcessInfo.processInfo.environment):
/// let clock = BenchClock()
///
/// // Tests (inject a custom environment dict):
/// let clock = BenchClock(environment: ["MOOT_BENCH_EPOCH_NOW": "2026-07-25T00:00:00Z"])
/// let t0 = clock.now()   // == 2026-07-25T00:00:00Z
/// let t1 = clock.now()   // == 2026-07-25T00:00:01Z
/// ```
///
/// See also: `ToolDispatcher.benchClock`.
public final class BenchClock: @unchecked Sendable {

    // MARK: - Environment key

    /// The environment variable name that pins the clock base.
    ///
    /// Value format: ISO8601 instant — `YYYY-MM-DDTHH:MM:SSZ` or
    /// `YYYY-MM-DDTHH:MM:SS.mmmZ`. Any suffix that `ISO8601DateFormatter`
    /// accepts (Z or ±HH:MM) is valid.
    public static let envKey = "MOOT_BENCH_EPOCH_NOW"

    // MARK: - State

    /// The pinned base instant, or `nil` when running in wall-clock mode.
    /// Nil means `MOOT_BENCH_EPOCH_NOW` was absent or empty at construction.
    private let base: Date?

    /// Monotonically incrementing call counter. Advances once per `now()` call
    /// when `base` is non-nil. Protected by `lock`.
    ///
    /// Each unit represents one tool call; one second is added per index
    /// position so filedAt values are unique and HLC can advance monotonically.
    private var callIndex: Int64 = 0

    /// Guards `callIndex`. Required because `ToolDispatcher.dispatch` can be
    /// called from multiple concurrent HTTP connections (HTTP mode) — each
    /// connection's `now()` call must see a strictly increasing index.
    private let lock = NSLock()

    // MARK: - Initialisation

    /// Build a clock from an environment dictionary.
    ///
    /// Reads `MOOT_BENCH_EPOCH_NOW`. If the key is present and parseable as
    /// ISO8601 the clock runs in pinned mode; otherwise wall-clock mode.
    ///
    /// - Parameter environment: The environment dictionary to inspect.
    ///   Defaults to `ProcessInfo.processInfo.environment` (i.e. the real
    ///   process environment). Pass a custom dict in tests.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let raw = environment[BenchClock.envKey], !raw.isEmpty {
            let fmt = ISO8601DateFormatter()
            // Accept "Z", "+00:00", and fractional-seconds variants.
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = fmt.date(from: raw) {
                base = parsed
            } else {
                // Fall back to the non-fractional formatter for bare "2026-07-25T00:00:00Z".
                let plain = ISO8601DateFormatter()
                base = plain.date(from: raw)
            }
        } else {
            base = nil
        }
    }

    // MARK: - Clock read

    /// Return the current logical time for one tool-call dispatch.
    ///
    /// - In pinned mode: returns `base + callIndex seconds`, then increments
    ///   `callIndex`. Guaranteed monotonically increasing across concurrent callers.
    /// - In wall-clock mode: returns `Date()`. Behavior is byte-identical to
    ///   calling `Date()` directly.
    ///
    /// Call once per MCP tool dispatch — not once per sub-step inside a runner.
    /// The ToolDispatcher calls `benchClock.now()` at the top of `dispatch()`
    /// and threads the result through to every runner for that call.
    public func now() -> Date {
        guard let base else { return Date() }
        lock.lock()
        let idx = callIndex
        callIndex &+= 1   // wrapping add: astronomically large session is not a trap
        lock.unlock()
        // One second per call index keeps filedAt stamps unique and gives HLC
        // enough headroom to advance without fractional-second ambiguity.
        return base.addingTimeInterval(Double(idx))
    }

    /// Whether this clock is running in pinned (deterministic) mode.
    ///
    /// `true` when `MOOT_BENCH_EPOCH_NOW` was set and parsed at construction.
    /// Exposed for diagnostic logging at server startup — the `mootx01 serve`
    /// command logs "bench clock pinned to <base>" when this is true.
    public var isPinned: Bool { base != nil }

    /// The pinned base instant, if any. Nil in wall-clock mode.
    /// Exposed for startup diagnostics only — runners must not inspect this;
    /// they call `now()` only.
    public var pinnedBase: Date? { base }
}
