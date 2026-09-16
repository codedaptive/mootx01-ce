/// Per-session mode sticky state and call counters for the modes coaching system.
///
/// ## Lifecycle
///
/// One `ModeSessionState` instance is created per `ToolDispatcher`. For the
/// stdio transport (one process per session), this gives per-session stickiness
/// for the session's lifetime. For the HTTP transport (resident process, multiple
/// clients), the dispatcher is shared; the session state is therefore shared too.
///
/// ## Extension point: per-client-id sticky state (HTTP)
///
/// The spec calls for per-client-id mode state with a TTL on the HTTP path. That
/// requires a per-client-id map keyed by the client's session ID, which the HTTP
/// server negotiates during `initialize`. The current implementation uses a single
/// shared instance — correct for stdio (one client per process) and advisory-
/// accurate for HTTP (shared state still applies the last-declared wins rule;
/// two clients may temporarily see each other's mode, which is harmless because
/// modes are advisory). A future HTTP session manager would inject a per-client
/// `ModeSessionState` by wrapping `ToolDispatcher` per request, following the
/// same pattern as `SensitivityGrantLedger`.
///
/// ## Preference keys
///
/// The spec defines two preference keys read from the estate manifest:
///   `modes.sticky_enabled` (default true)  — when false, mode declarations
///       are accepted and a hint is returned but the sticky state is never set.
///       Advisory-only mode is the result, same as absent sticky state. One code
///       path, two reasons (off by preference vs off by absence).
///   `modes.coaching_calls` (default 25, 0=off) — how often the coaching block
///       fires. The estate manifest equivalent of an explicit per-call counter
///       override.
///
/// Both preferences are read at session start via
/// `GeniusLocusKit.provisionedModesConfig(for:)` and applied by
/// `ToolDispatcher.dispatch` on the first tool call. `applyPreferences` is the
/// seam; `setCoachingCallsX` remains for tests that override the cadence
/// per-call without going through the estate manifest.
///
/// ## Bool and bitmap discipline
///
/// No Bool stored properties on session state. The `stickyEnabled` preference
/// is a computed accessor over bit 0 of `sessionPreferenceBitmap` (Int64) per
/// the fleet-wide bitmap rule. Bit 1 (`configuredFromEstate`) guards the
/// apply-once contract. This applies to non-persisted actors the same as
/// database entities.
///
/// ## Sendable conformance
///
/// `ModeSessionState` is an `actor`, making it `Sendable`. It is held as `let`
/// in the `Sendable` struct `ToolDispatcher`, satisfying the concurrency checker.

import Foundation

// MARK: - CoachingSnapshot

/// Immutable snapshot of per-session call counters, passed to `PeriodicCoach`
/// for deterministic block rendering.
public struct CoachingSnapshot: Sendable, Equatable {
    /// Total moot tool calls this session.
    public let totalCalls: Int
    /// Calls per tool name (canonical tool name → count).
    public let toolCounts: [String: Int]
    /// Bigram counts: "toolA→toolB" → how many times toolB immediately followed toolA.
    public let bigramCounts: [String: Int]
    /// Mode attribution counts: mode name → calls attributed to that mode.
    public let modeAttributionCounts: [String: Int]
}

// MARK: - ModeSessionState

/// Actor carrying sticky mode declaration and per-session call counters.
///
/// All mutations are async and actor-isolated — no external synchronization needed.
public actor ModeSessionState: Sendable {

    // MARK: - Preference bitmap
    // Bit assignments for sessionPreferenceBitmap (Int64):
    //   bit 0 — stickyEnabled         (default 1 = true): sticky state is recorded
    //   bit 1 — configuredFromEstate  (default 0 = false): applyPreferences has run
    //   bits 2-63 — reserved

    /// Preference flags for this session (bitmap per fleet-wide house-style rule).
    /// Default value 0b01 = stickyEnabled is on; configuredFromEstate starts false.
    private var sessionPreferenceBitmap: Int64 = 0b01

    /// When false, mode declarations are accepted and may produce hints, but the
    /// sticky state is never updated — same advisory-only code path as absent state.
    /// Default per spec: true. The estate manifest key is `modes.sticky_enabled`.
    public var stickyEnabled: Bool {
        get { sessionPreferenceBitmap & (1 << 0) != 0 }
        set {
            if newValue { sessionPreferenceBitmap |= (1 << 0) }
            else { sessionPreferenceBitmap &= ~(1 << 0) }
        }
    }

    /// Whether `applyPreferences` has been called at least once this session.
    ///
    /// Guards the apply-once contract in `ToolDispatcher.dispatch`: the first
    /// tool call reads the estate manifest and calls `applyPreferences`; all
    /// subsequent calls skip the read (the manifest is RAM-resident so the
    /// overhead is low, but idempotency is cleaner and avoids unnecessary
    /// async work on every call).
    ///
    /// Backed by bitmap bit 1 per fleet-wide house-style rule (no Bool stored
    /// properties, even on non-persisted session actors).
    var configuredFromEstate: Bool {
        get { sessionPreferenceBitmap & (1 << 1) != 0 }
        set {
            if newValue { sessionPreferenceBitmap |= (1 << 1) }
            else { sessionPreferenceBitmap &= ~(1 << 1) }
        }
    }

    /// How many moot tool calls between coaching blocks. 0 = off.
    /// Default per spec: 25. The estate manifest key is `modes.coaching_calls`.
    public var coachingCallsX: Int = 25

    // MARK: - Sticky state

    /// The last-declared mode declaration, retained as the session default.
    ///
    /// A bare mode name (no variant) clears any prior variant for that mode but
    /// keeps the mode name for attribution. A declaration for a *different* mode
    /// replaces the previous declaration entirely.
    ///
    /// Never set when `stickyEnabled == false`.
    private(set) var stickyDeclaration: ModeDeclaration? = nil

    // MARK: - Sticky recall answer mode

    /// The answer mode raw value for the current sticky Recall variant, or `nil`
    /// when no sticky Recall=<variant> is set.
    ///
    /// Injected as the `answer` argument by the pre-decode transform hook when
    /// `answer` is absent from the call arguments and the session has a sticky
    /// Recall variant. Per-call explicit `answer` always wins — the transform hook
    /// only injects when the argument is absent.
    ///
    /// Returns `"auto"` for `Recall=Auto`, `"never"` for `Recall=Rows`,
    /// `"always"` for `Recall=Answer`.
    public var stickyRecallAnswerMode: String? {
        stickyDeclaration?.recognizedRecallVariant?.answerModeRawValue
    }

    // MARK: - Call counters

    /// Total calls recorded this session.
    private(set) var totalCallCount: Int = 0

    /// Calls per tool name.
    private(set) var toolCallCounts: [String: Int] = [:]

    /// The tool name dispatched in the immediately preceding call (for bigram tracking).
    private var lastToolName: String? = nil

    /// Next-call bigram frequency: "toolA→toolB" → count.
    private(set) var bigramCounts: [String: Int] = [:]

    /// Mode attribution: mode name → calls attributed to that mode.
    /// Attribution uses the declared mode when present, otherwise infers from the
    /// tool name via `MootMode.inferredBundle(for:)`.
    private(set) var modeAttributionCounts: [String: Int] = [:]

    // MARK: - Init

    public init() {}

    // MARK: - Test seam

    /// Override the coaching cadence. Used by tests to trigger coaching quickly
    /// without going through the estate manifest. Sets `configuredFromEstate = true`
    /// so that `ToolDispatcher.dispatch` skips the provisioned-config read on the
    /// first tool call — the seam takes full precedence over the estate key.
    func setCoachingCallsX(_ value: Int) {
        coachingCallsX = value
        configuredFromEstate = true
    }

    // MARK: - Estate provisioned preferences

    /// Apply preferences read from the estate manifest (via
    /// `GeniusLocusKit.provisionedModesConfig(for:)`).
    ///
    /// Called by `ToolDispatcher.dispatch` on the first tool call of the session.
    /// Subsequent calls are no-ops (guarded by `configuredFromEstate`).
    ///
    /// - Parameters:
    ///   - stickyEnabled: from `ModesManifest.stickyEnabled`. `false` makes all
    ///     mode declarations advisory-only (no sticky state recorded).
    ///   - coachingCalls: from `ModesManifest.coachingCalls`. `0` suppresses all
    ///     coaching blocks. Replaces the spec-default `coachingCallsX = 25`.
    func applyPreferences(stickyEnabled: Bool, coachingCalls: Int) {
        guard !configuredFromEstate else { return }
        self.stickyEnabled = stickyEnabled
        self.coachingCallsX = coachingCalls
        configuredFromEstate = true
    }

    // MARK: - Recording a call

    /// Record a completed tool call and return the new total call count.
    ///
    /// - Parameters:
    ///   - toolName: The MCP tool name that was dispatched.
    ///   - mode: The parsed mode declaration from the `mode` arg, or nil when absent.
    /// - Returns: The updated `totalCallCount` after recording this call.
    @discardableResult
    public func recordCall(toolName: String, mode: ModeDeclaration?) -> Int {
        // Update sticky when a mode arg is present, sticky is enabled, AND the mode
        // name is recognized. An unrecognized mode declaration is IGNORED ENTIRELY for
        // sticky purposes (ruling W4): it must not clobber an existing valid sticky
        // declaration. The AI is still notified via a hint line (handled by the
        // dispatch layer), so the fail-open contract is preserved — only sticky state
        // is unaffected. This matches the Rust `record_call` implementation.
        if stickyEnabled, let m = mode, m.recognizedMode != nil {
            stickyDeclaration = m
        }

        // Increment total and per-tool counters.
        totalCallCount += 1
        toolCallCounts[toolName, default: 0] += 1

        // Bigram: record toolA→toolB pair from the previous call.
        if let last = lastToolName {
            let bigram = "\(last)→\(toolName)"
            bigramCounts[bigram, default: 0] += 1
        }
        lastToolName = toolName

        // Mode attribution: declared mode name beats inferred bundle.
        let attributedMode: String?
        if let m = mode, m.recognizedMode != nil {
            attributedMode = m.modeName
        } else {
            attributedMode = MootMode.inferredBundle(for: toolName)?.rawValue
        }
        if let m = attributedMode {
            modeAttributionCounts[m, default: 0] += 1
        }

        return totalCallCount
    }

    // MARK: - Coaching trigger

    /// Returns true when the current call count is an exact multiple of
    /// `coachingCallsX`. Returns false when `coachingCallsX` is 0 (off).
    ///
    /// Must be called AFTER `recordCall` so `totalCallCount` reflects the current call.
    public func shouldCoach() -> Bool {
        guard coachingCallsX > 0 else { return false }
        return totalCallCount % coachingCallsX == 0
    }

    // MARK: - Snapshot

    /// Return an immutable snapshot for deterministic block rendering by `PeriodicCoach`.
    public var snapshot: CoachingSnapshot {
        CoachingSnapshot(
            totalCalls: totalCallCount,
            toolCounts: toolCallCounts,
            bigramCounts: bigramCounts,
            modeAttributionCounts: modeAttributionCounts
        )
    }
}
