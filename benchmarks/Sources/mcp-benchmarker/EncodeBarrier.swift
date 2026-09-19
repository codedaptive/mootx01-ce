import Foundation

// EncodeBarrier.swift — encode-queue synchronization strategy for benchmark runners.
//
// The three benchmark runners (LongMemEval, LoCoMo, LMEB) ingest memories via
// moot_file_memory and then immediately query via moot_memory_search. A race
// exists: mootx01 encodes memories asynchronously in the background, so a query
// issued before encoding completes may surface un-encoded (lower-quality) results.
//
// Three strategies to close this race:
//
//   drain     Write without inline encoding, then poll moot_drain_status until
//   (default) all drains report "idle" before the first query. This is the
//             official methodology for 1.0.x: background encoding produces better
//             vectors than impatient inline-encoding on fresh estates, and the
//             drain barrier reliably serializes ingest → encode → query without
//             holding per-write latency hostage to inline encoding time.
//
//   impatient Write with impatient:true — inline encoding before write returns.
//             Each write serializes its own encoding; no post-ingest barrier
//             needed. Use for post-product-fix testing once the degenerate-
//             vector-on-fresh-estate bug is patched. Not recommended on 1.0.x.
//
//   none      No barrier. Writes proceed without inline encoding and without a
//             drain poll. Intentionally races the encode queue. Use only to
//             document the race condition, never as a methodology baseline.
//
// The chosen mode is recorded in every report JSON as the "encode_barrier" key
// so results are self-describing about their ingest methodology.

// MARK: - Barrier mode

/// The encode-queue synchronization strategy for a benchmark run.
/// Recorded as the "encode_barrier" key in every report JSON.
enum EncodeBarrier: String, Sendable, Codable {
    /// Write without inline encoding. After all ingest completes, poll
    /// `moot_drain_status` until all drains are idle before issuing any query.
    /// Default and recommended for 1.0.x product.
    case drain
    /// Write with `impatient: true` — inline encoding before each write returns.
    /// Correct key (previously the wrong key "n" was used, which was silently
    /// ignored). Use for post-product-fix testing on patched estates.
    case impatient
    /// No barrier. Documents the background-encoding race. Not a methodology baseline.
    case none
}

// MARK: - Drain response parsing

/// Result of parsing one `moot_drain_status` response.
///
/// The poller requires an *explicit* idle signal — not merely an absence of
/// the word "draining". Any response that does not match a known shape is a
/// fatal protocol error; the benchmark must abort rather than silently
/// proceed with under-encoded data.
///
/// `.idle` and `.noLanes` are deliberately DISTINCT cases. The corpus_encode
/// lane appears in drain status only once the Corpus is wired for the estate
/// (GeniusLocusKit `drainStatuses`: present iff `corpusKits[handle]` exists),
/// and it never deregisters afterwards. On a FRESH estate the first poll can
/// therefore beat lane wiring: "drains: none" is truthfully parseable but is
/// NOT evidence that encoding finished — it may mean encoding hasn't STARTED.
/// The barrier's state machine (`DrainBarrierState`) treats `.idle` (lane
/// listed, all counts zero) as proof and `.noLanes` as ambiguity that needs
/// a grace window.
enum DrainParseResult: Equatable {
    /// Shape B with every listed lane at state "idle", pending == 0,
    /// in_flight == 0. The lane is registered AND reports no work — this is
    /// positive evidence that encoding completed. Safe to issue recall queries.
    case idle
    /// At least one drain has pending or in-flight work, or explicitly reports
    /// the state word "draining". Keep polling.
    case draining
    /// Shape A — `"drains: none"`: no lane registered (yet). Ambiguous on a
    /// fresh estate: either the corpus lane has not wired yet (encoding still
    /// ahead of us) or this estate genuinely runs no drains. NOT proof of
    /// completion by itself.
    case noLanes
    /// The response did not match any recognised shape. The caller must abort
    /// the run — proceeding silently would produce invalid recall results.
    case unparseable
}

/// Lanes whose `pending` is a row-level ELIGIBILITY count rather than a
/// queue depth, and which therefore must never hold the encode barrier open.
///
/// This is a DENYLIST, not an allowlist, and the direction matters: an
/// unknown lane keeps gating. For a measurement tool a visible hang is a far
/// better failure than silently querying under-encoded data — a hang gets
/// noticed and fixed; invalid recall numbers get published. A lane earns a
/// place here only once its counts are shown not to be queue work.
///
/// `distillation` qualifies: its `pending` is
/// `countUndistilled(pipelineVersion:)` — drawers owing a representation —
/// and its `in_flight` is a hardcoded 0, so it can sit non-zero at a steady
/// state that no amount of draining resolves.
///
/// `subject_backfill` qualifies for the same reason (rider-default
/// ruling 2026-08-02: the Apple subject rider is on by default, so the
/// lane renders on Apple estates): its `pending` is the subject-debt
/// eligibility count (`countSubjectDebt`) with `in_flight` hardcoded 0,
/// and dreaming pays it down out-of-band — it can sit non-zero at a
/// steady state no encode drain resolves.
///
/// Twin of Rust `BARRIER_NON_GATING_LANES`.
let barrierNonGatingLanes: Set<String> = [
    "distillation", "subject_backfill",
    // fact_extraction is bit-28 row debt (drawers still owed extraction for
    // the active recipe), always rendered, paid down only by a dreaming
    // cycle's bounded batch — it sits non-zero across a measured session on
    // a healthy estate. The bulk build settles on it explicitly; the encode
    // barrier must not.
    "fact_extraction",
    // 2026-08-26: the dreaming queue became a visible drain lane. Its debt
    // is paid out-of-band (in-session dreamer / resident daemon / the T10
    // detached finisher), so it can sit non-zero across an entire measured
    // session on a healthy estate — gating would hang every encode barrier.
    "dreaming",
]

/// Parse one text response from `moot_drain_status` into a `DrainParseResult`.
///
/// Two recognised shapes (both produced by `AriaMcpKit.ToolDispatch.runDrainStatus`
/// across product versions 1.0.x and 1.1.x):
///
///   Shape A — no corpus registered:
///     `"drains: none"`
///
///   Shape B — one or more drain-status lines:
///     `"drains: N"`
///     `"  <name>: <state> — pending: N, in_flight: N[, <detail>]"`
///
/// where `<state>` is exactly `"draining"` or `"idle"`.
///
/// EVERY LANE GATES THE BARRIER except those in `barrierNonGatingLanes`,
/// whose `pending` is a row-level eligibility count rather than queue work
/// and can therefore sit non-zero forever on a healthy estate. Non-gating
/// lines are still parsed — a malformed one is still a protocol error —
/// they simply never hold the barrier open.
///
/// A gating drain is considered active when:
///   • its state word is `"draining"`, OR
///   • its `pending` count is non-zero, OR
///   • its `in_flight` count is non-zero.
///
/// Returns `.idle` only when ALL GATING drains explicitly report
/// `state == "idle"` with both counts at zero — and also when the response
/// contains only non-gating lanes (nothing queue-backed is outstanding).
/// Returns `.noLanes` for Shape A. Returns `.unparseable` for any response
/// that does not match Shape A or B.
///
/// This function is `internal` (not private) to allow direct unit testing.
func parseDrainResponse(_ text: String) -> DrainParseResult {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Shape A: "drains: none" — no lane registered. NOT idle-equivalent on a
    // fresh estate; the state machine decides what to do with it.
    if trimmed == "drains: none" {
        return .noLanes
    }

    // Shape B: multi-line beginning with "drains: N" (N >= 1).
    let lines = trimmed.components(separatedBy: "\n")
    guard let firstLine = lines.first else { return .unparseable }
    let headerPrefix = "drains: "
    guard firstLine.hasPrefix(headerPrefix) else { return .unparseable }
    let countStr = firstLine.dropFirst(headerPrefix.count)
    guard let drainCount = Int(countStr), drainCount > 0 else { return .unparseable }

    // Parse each drain-status line that follows the header.
    // Expected format (verbatim from ToolDispatch.runDrainStatus):
    //   "  <name>: <state> — pending: N, in_flight: N[, <detail>]"
    // The em-dash separator (U+2014) divides the state prefix from the counts.
    let emDashSep = " \u{2014} " // " — "
    var parsedLineCount = 0
    var nonGatingLineCount = 0
    for line in lines.dropFirst() {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { continue }

        // Split on the em-dash separator: left side is "<name>: <state>",
        // right side is "pending: N, in_flight: N[, <detail>]".
        guard let sepRange = stripped.range(of: emDashSep) else {
            return .unparseable
        }
        let nameStateStr = String(stripped[..<sepRange.lowerBound])
        let countsStr    = String(stripped[sepRange.upperBound...])

        // Extract the state word from "<name>: <state>" — split on first ": ".
        guard let colonSpace = nameStateStr.range(of: ": ") else {
            return .unparseable
        }
        let name  = String(nameStateStr[..<colonSpace.lowerBound])
        let state = String(nameStateStr[colonSpace.upperBound...])

        // Non-gating lane: parsed (so a malformed line is still caught) but
        // never allowed to hold the barrier open. See the doc-comment.
        guard !barrierNonGatingLanes.contains(name) else {
            guard parseIntField("pending: ", from: countsStr) != nil,
                  parseIntField("in_flight: ", from: countsStr) != nil,
                  state == "draining" || state == "idle" else {
                return .unparseable
            }
            nonGatingLineCount += 1
            continue
        }

        // Parse pending and in_flight numeric fields from the right side.
        guard let pending  = parseIntField("pending: ",   from: countsStr),
              let inFlight = parseIntField("in_flight: ", from: countsStr) else {
            return .unparseable
        }

        // A drain is active if state is "draining" OR either count is non-zero.
        // (Both conditions are checked defensively; the server always sets
        // state="draining" when pending+in_flight > 0, but belt-and-suspenders
        // here means future state-word changes cannot silently skip the barrier.)
        if state == "draining" || pending > 0 || inFlight > 0 {
            return .draining
        }

        // State must be one of the two known words; anything else is unparseable.
        guard state == "idle" else { return .unparseable }

        parsedLineCount += 1
    }

    // Every gating lane reported idle with zero counts — the ingest work is
    // done. This also covers a response carrying only non-gating lanes:
    // nothing queue-backed is outstanding, so the barrier is satisfied.
    if parsedLineCount > 0 || nonGatingLineCount > 0 {
        return .idle
    }
    // Header claimed N > 0 drains but we found no parseable drain lines.
    return .unparseable
}

/// v2-aware drain parse: reads structured `drainEntries` when available,
/// falls back to text parsing for v1 shape compatibility.
///
/// When the caller uses `.mootV2` format, `result.drainEntries` is populated
/// directly from `structuredContent.data.drains[]` — machine-readable and
/// unambiguous. When `drainEntries` is nil (v1 text response or a non-drain
/// call), falls back to `parseDrainResponse` on the joined text blocks.
func parseDrainResult(_ result: MCPToolResult) -> DrainParseResult {
    // Prefer structured data: v2 surface encodes drain state in
    // structuredContent.data.drains[], avoiding all the em-dash text parsing.
    if let entries = result.drainEntries {
        // An empty array means no lanes are registered (equivalent to "drains: none"
        // in the v1 text shape). NOT idle-equivalent on a fresh estate.
        guard !entries.isEmpty else { return .noLanes }
        for entry in entries {
            // Belt-and-suspenders: both state word AND pending count gate the
            // barrier, matching the logic in parseDrainResponse. The server sets
            // state="draining" when pending > 0, but both are checked defensively
            // so a future state-word change cannot silently skip the barrier.
            if entry.state == "draining" || entry.pending > 0 {
                return .draining
            }
            // Unrecognised state word is unparseable; do not accept it as idle.
            guard entry.state == "idle" else { return .unparseable }
        }
        return .idle
    }
    // Fall back to v1 text parsing when no structured data was decoded.
    return parseDrainResponse(result.textBlocks.joined(separator: "\n"))
}

/// Extract the integer value for a named field from a comma-separated counts string.
///
/// Scans for `prefix` within `s`, then reads the decimal digits immediately
/// following the prefix. Returns nil when the prefix is absent or no digits follow.
///
/// Examples:
///   parseIntField("pending: ",   "pending: 42, in_flight: 3")  → 42
///   parseIntField("in_flight: ", "pending: 0, in_flight: 0")   → 0
private func parseIntField(_ prefix: String, from s: String) -> Int? {
    guard let range = s.range(of: prefix) else { return nil }
    let digits = s[range.upperBound...].prefix(while: { $0.isNumber })
    guard !digits.isEmpty else { return nil }
    return Int(digits)
}

// MARK: - Barrier state machine

/// What the drain barrier concluded, returned to the runner and recorded in
/// the report JSON as the per-unit `drain_lane_observed` key.
public struct DrainBarrierOutcome: Equatable, Sendable {
    /// True when the barrier accepted an idle state (via lane evidence or the
    /// no-lanes grace window) within the timeout. False on timeout or fatal
    /// transport death.
    public let converged: Bool
    /// True when at least one poll returned Shape B (the corpus lane was
    /// registered — draining or idle). False means the barrier only ever saw
    /// "drains: none": ambiguous evidence, disclosed as such in the report.
    public let laneObserved: Bool
}

/// Grace-window policy for accepting `"drains: none"` as idle.
///
/// The corpus lane registers when the Corpus is wired for the estate and never
/// deregisters. On a fresh estate the first poll can precede wiring, so a
/// single no-lanes response proves nothing. Requiring BOTH a minimum number of
/// consecutive no-lanes polls AND a minimum elapsed time bounds the two
/// failure modes independently: a burst of fast polls cannot satisfy the
/// window by count alone, and one slow poll cannot satisfy it by time alone.
/// A tiny corpus that legitimately finished (or an estate that genuinely runs
/// no drains) still converges — 2 s later, with `laneObserved == false`
/// recorded so the ambiguity is visible in the report.
public struct DrainBarrierGrace: Sendable {
    /// Minimum consecutive `.noLanes` polls (uninterrupted by any other
    /// response or RPC error) before no-lanes may be accepted as idle.
    public var minConsecutiveNoLanes: Int
    /// Minimum seconds since the barrier started before no-lanes may be
    /// accepted as idle.
    public var minSeconds: Double

    /// Constructs a grace-window policy with the given thresholds.
    /// Both parameters default to the standard values (4 polls, 2.0 s) so
    /// call sites that want the defaults can use `DrainBarrierGrace()`.
    public init(minConsecutiveNoLanes: Int = 4, minSeconds: Double = 2.0) {
        self.minConsecutiveNoLanes = minConsecutiveNoLanes
        self.minSeconds = minSeconds
    }
}

/// The barrier's next action after observing one parsed poll response.
enum DrainBarrierDecision: Equatable {
    /// Accept: encoding is complete (or accepted via grace). Stop polling.
    case converged(laneObserved: Bool)
    /// Not enough evidence yet — poll again.
    case keepPolling
    /// Protocol error — the caller must abort the benchmark (exit 1).
    case abortUnparseable
}

/// Pure state machine for the drain barrier's evidence tracking. Extracted
/// from the async poll loop so the sequencing rules are unit-testable without
/// an MCPClient:
///
///   .idle      → converged immediately (the lane is listed and empty — proof).
///   .draining  → lane observed; keep polling.
///   .noLanes   → before any lane sighting: accept only after the grace window
///                (see DrainBarrierGrace); after a lane sighting: the lane
///                vanishing is anomalous — keep polling until timeout rather
///                than trust it.
///   .unparseable → abort.
///
/// RPC errors are reported via `noteError()`: they reset the consecutive
/// no-lanes counter because the evidence stream was interrupted.
struct DrainBarrierState {
    private(set) var laneObserved = false
    private var consecutiveNoLanes = 0
    /// Consecutive `moot_drain_status` RPC failures. A server that has crashed
    /// answers nothing, so every poll fails the same way — the count is what
    /// distinguishes a dead server from a transient hiccup, WITHOUT depending
    /// on the wording of the error.
    private(set) var consecutiveErrors = 0
    private let start: Date
    private let grace: DrainBarrierGrace

    init(start: Date = Date(), grace: DrainBarrierGrace = DrainBarrierGrace()) {
        self.start = start
        self.grace = grace
    }

    /// Feed one parsed poll response; returns what the barrier should do next.
    mutating func observe(_ parse: DrainParseResult, at now: Date = Date()) -> DrainBarrierDecision {
        switch parse {
        case .draining:
            laneObserved = true
            consecutiveNoLanes = 0
            return .keepPolling

        case .idle:
            // Lane listed with zero counts — positive completion evidence.
            laneObserved = true
            return .converged(laneObserved: true)

        case .noLanes:
            if laneObserved {
                // The lane never deregisters in the product; seeing no-lanes
                // AFTER a lane sighting is anomalous. Do not trust it — keep
                // polling; the timeout bounds the worst case.
                return .keepPolling
            }
            consecutiveNoLanes += 1
            if consecutiveNoLanes >= grace.minConsecutiveNoLanes,
               now.timeIntervalSince(start) >= grace.minSeconds {
                return .converged(laneObserved: false)
            }
            return .keepPolling

        case .unparseable:
            return .abortUnparseable
        }
    }

    /// Note an RPC error between polls: the consecutive no-lanes evidence
    /// chain is broken, so the counter restarts.
    mutating func noteError() {
        consecutiveNoLanes = 0
        consecutiveErrors += 1
    }

    /// Called after any poll that produced a parseable response — the server
    /// is answering, so the failure streak is over.
    mutating func noteResponded() {
        consecutiveErrors = 0
    }
}

// MARK: - Drain barrier

/// Polls `moot_drain_status` after ingest completes, waiting until the corpus
/// lane reports "idle" before the caller issues its first recall query.
///
/// Response shapes handled:
///   "drains: none"  — no lane registered; accepted only via the grace window.
///   "drains: N"
///   "  <name>: draining — pending: N, in_flight: N[, <detail>]"
///   "  <name>: idle    — pending: 0, in_flight: 0[, <detail>]"
///
/// **Fresh-estate race:** the corpus lane appears in drain status only once
/// the Corpus is wired; a first poll that beats wiring sees "drains: none".
/// The barrier therefore accepts no-lanes as idle only after
/// `DrainBarrierGrace` is satisfied, and records whether the lane was ever
/// observed (`DrainBarrierOutcome.laneObserved` → report key
/// `drain_lane_observed`).
///
/// **FATAL on unknown shape.** If `moot_drain_status` returns a response that
/// does not match a known shape, the benchmark process aborts with exit(1) and
/// a diagnostic message on stderr naming the raw response. Silently treating
/// an unknown shape as idle would allow the benchmark to issue recall queries
/// before encoding is complete, producing invalid recall scores.
///
/// Returns `converged == false` when the timeout expired without convergence
/// or the transport died — a WARNING is emitted to stderr and the run
/// continues (the latency and quality degradation are then part of the
/// recorded result).
///
/// - Parameters:
///   - client: A connected `MCPClient` pointing at the estate to poll.
///   - label: Short label for stderr progress lines (e.g. "lme q42").
///   - timeoutSeconds: Maximum poll window. Default 300 s (5 min).
///   - grace: No-lanes acceptance policy. Defaults per DrainBarrierGrace.
/// - Returns: The barrier outcome (converged + lane evidence).
/// Consecutive failed polls after which the server is declared dead.
///
/// At the 500 ms poll interval this is ~5 s of total silence. A live server
/// answers `moot_drain_status` in milliseconds even while draining, so this
/// cannot be reached by load — only by a server that is gone.
private let deadServerPollThreshold = 10

public func waitForEncodeDrain(
    client: MCPClient,
    label: String,
    timeoutSeconds: Double = 300.0,
    grace: DrainBarrierGrace = DrainBarrierGrace()
) async -> DrainBarrierOutcome {
    let start = Date()
    let deadline = start.addingTimeInterval(timeoutSeconds)
    // 500 ms poll interval — frequent enough to detect convergence quickly
    // without hammering the estate with status RPCs.
    let pollIntervalNanos: UInt64 = 500_000_000
    var state = DrainBarrierState(start: start, grace: grace)

    while Date() < deadline {
        do {
            let result = try await client.callTool(
                AriaV2Surface.drainStatus,
                arguments: [:],
                format: .mootV2,
                // Status tier: a live server answers this from memory in
                // milliseconds even mid-drain. The client-wide deadline is
                // 120s (1800s on the LME lane, which raises it for its slowest
                // call), so without this a crashed server was indistinguishable
                // from a busy one for two minutes per poll.
                deadline: MCPDeadline.status
            )
            // parseDrainResult prefers structuredContent.data.drains[] (v2)
            // and falls back to text block parsing (v1) when absent.
            let text = result.textBlocks.joined(separator: "\n")
            let parsed = parseDrainResult(result)
            state.noteResponded()

            switch state.observe(parsed) {
            case .converged(let laneObserved):
                if !laneObserved {
                    // Grace-window acceptance: no lane was ever seen. Disclosed
                    // note — either a tiny corpus finished before the first
                    // poll, or the lane never wired. The report records it.
                    FileHandle.standardError.write(Data(
                        ("[\(label)] drain barrier: accepted no-lanes as idle after grace window "
                        + "(\(String(format: "%.1f", Date().timeIntervalSince(start)))s) — corpus lane "
                        + "never observed. drain_lane_observed=false\n").utf8))
                }
                return DrainBarrierOutcome(converged: true, laneObserved: laneObserved)

            case .keepPolling:
                switch parsed {
                case .draining:
                    // Still draining — log the trimmed response for visibility.
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    FileHandle.standardError.write(Data(
                        "[\(label)] drain barrier: waiting — \(trimmed)\n".utf8))
                case .noLanes where state.laneObserved:
                    FileHandle.standardError.write(Data(
                        ("[\(label)] drain barrier: WARNING — lane disappeared after being observed "
                        + "(drains: none). Continuing to poll.\n").utf8))
                default:
                    break  // pre-lane no-lanes polls are quiet; grace decides.
                }

            case .abortUnparseable:
                // Unknown shape — the benchmark MUST NOT proceed silently.
                // An unrecognised drain response means we cannot confirm that
                // encoding has completed; any recall queries would be invalid.
                let raw = text.isEmpty ? "(empty response — textBlocks were empty)" : text
                let msg = """
                    [\(label)] drain barrier: FATAL — moot_drain_status returned an \
                    unrecognised response shape. Cannot confirm encode completion; \
                    aborting to prevent invalid recall data.
                    Raw response:
                    \(raw)

                    """
                FileHandle.standardError.write(Data(msg.utf8))
                exit(1)
            }
        } catch {
            // moot_drain_status RPC failed — log, then check for fatal transport
            // death. Non-fatal (transient) failures are recoverable within the
            // timeout window and fall through to the retry sleep.
            state.noteError()
            FileHandle.standardError.write(Data(
                "[\(label)] drain barrier: moot_drain_status error: \(error)\n".utf8))
            // When the stdio session dies (server exited, broken stdin pipe, or
            // stream closed by EOF), all further polls return the same fatal error
            // until the timeout expires. Detect these conditions and abort
            // immediately with a clear diagnosis so the run fails fast rather than
            // spinning for timeoutSeconds and then emitting a misleading
            // "did not converge" warning. The MCPClient session-closed error
            // message is "stdio session for … closed"; broken-pipe and stream-
            // closed arrive as their respective OS error descriptions.
            let desc = String(describing: error).lowercased()
            // Wording-based detection, for the transports that announce death.
            let isFatal = (desc.contains("session") && desc.contains("closed"))
                || desc.contains("not connected")
                || desc.contains("disconnected")
                || desc.contains("broken pipe")
                // A crashed server does NOT announce itself: the request simply
                // never gets an answer, and every later poll times out the same
                // way. That is how a SynapseKit SIGTRAP presented as a ten-minute
                // silent stall rather than a failure (2026-08-15) — the wording
                // list above matched none of it.
                || desc.contains("response timeout")
            if isFatal {
                FileHandle.standardError.write(Data(
                    "[\(label)] drain barrier: FATAL — MCP transport died (server exited). Aborting poll.\n".utf8))
                return DrainBarrierOutcome(converged: false, laneObserved: state.laneObserved)
            }
            // Wording-INDEPENDENT backstop. Whatever a future transport calls
            // its failure, a server that has missed this many polls in a row is
            // not coming back, and polling it to the timeout only delays a
            // failure that has already happened. The threshold is deliberately
            // low: a live server answers moot_drain_status in milliseconds, so
            // consecutive failures are not a busy estate — they are silence.
            if state.consecutiveErrors >= deadServerPollThreshold {
                FileHandle.standardError.write(Data(
                    ("[\(label)] drain barrier: FATAL — moot_drain_status failed "
                    + "\(state.consecutiveErrors) polls in a row "
                    + "(\(String(format: "%.1f", Date().timeIntervalSince(start)))s). The server is "
                    + "not answering; treating it as dead rather than polling to the "
                    + "\(Int(timeoutSeconds))s timeout. Last error: \(error)\n").utf8))
                return DrainBarrierOutcome(converged: false, laneObserved: state.laneObserved)
            }
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanos)
    }

    // Timed out — emit an explicit warning and let the run proceed.
    let timeoutMsg = "[\(label)] drain barrier: WARNING — encode drain did not converge within "
        + "\(Int(timeoutSeconds))s. Proceeding with query; recall quality may be reduced.\n"
    FileHandle.standardError.write(Data(timeoutMsg.utf8))
    return DrainBarrierOutcome(converged: false, laneObserved: state.laneObserved)
}

// MARK: - Distillation settle gate (2026-08-24)

/// Polls `moot_drain_status` until the `distillation` lane reports
/// `pending: 0, in_flight: 0` on TWO consecutive polls, then returns.
///
/// The encode barrier deliberately does NOT gate on the distillation lane
/// (`barrierNonGatingLanes`): its pending count is the standing distillation
/// debt that dreaming pays down out-of-band, so it can sit non-zero forever
/// during ingest. That exclusion is correct for the INGEST barrier — but a
/// determinism-sensitive lane that queries dreaming-derived state (distilled
/// text feeds the dense lane) must not fire queries until that debt is ZERO,
/// or two same-seed runs read the estate at different points of dreaming
/// completion and return different rankings (the 2026-08-24 replay-drift
/// root cause; same class B3-01/39f534353 fixed for MemBench/LMEB).
///
/// Called AFTER the lane's `moot_dream` pass — dream is what pays the debt;
/// this gate verifies it was fully paid. Two consecutive zero polls guard
/// against the returns-before-enqueue trap (`moot_reindex` precedent).
/// Throws on timeout: an unsettled estate must fail loudly, never measure.
func waitForDistillationSettle(
    client: MCPClient,
    label: String,
    timeoutSeconds: Double = 300.0
) async throws {
    let start = Date()
    let deadline = start.addingTimeInterval(timeoutSeconds)
    let pollIntervalNanos: UInt64 = 500_000_000
    var consecutiveZero = 0

    while Date() < deadline {
        let result = try await client.callTool(
            AriaV2Surface.drainStatus,
            arguments: [:],
            format: .mootV2,
            deadline: MCPDeadline.status)
        let text = result.textBlocks.joined(separator: "\n")
        // Reuse the barrier's line grammar: "  distillation: <state> — pending: N, in_flight: N".
        var sawLane = false
        var laneZero = false
        for line in text.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard stripped.hasPrefix("distillation: ") else { continue }
            sawLane = true
            let pending  = parseIntField("pending: ",   from: stripped)
            let inFlight = parseIntField("in_flight: ", from: stripped)
            laneZero = (pending == 0 && inFlight == 0)
        }
        // No distillation lane registered → nothing to settle (tiny or
        // pre-distillation estates); treat as settled.
        if !sawLane || laneZero {
            consecutiveZero += 1
            if consecutiveZero >= 2 { return }
        } else {
            consecutiveZero = 0
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanos)
    }
    throw MCPError(description:
        "[\(label)] distillation settle: debt did not reach zero within "
        + "\(Int(timeoutSeconds))s after dream — refusing to query an "
        + "unsettled estate (variable-ranking hazard).")
}

// MARK: - Dream drain status (item 8)

/// Dream-drain status captured once at measurement run start.
///
/// `pending`: the `pending` count from the `dreaming` drain lane.
///   0 when the lane is absent or the estate reports "drains: none".
/// `settled`: true when the dreaming lane reports state "idle" or is absent;
///   false when it reports "draining".
///
/// This field is INFORMATIONAL — it documents how many unprocessed dreaming
/// jobs were outstanding at measurement time so readers can assess whether
/// dream-derived content influenced retrieved memories.  A non-zero pending
/// count is normal for LoCoMo-scale estates: the dreaming drain is in
/// `barrierNonGatingLanes` and never stalls the encode barrier.
struct DreamStatus: Sendable {
    /// Pending count from the `dreaming` drain lane at run start.
    let pending: Int
    /// True when the dreaming lane reports idle or is absent.
    let settled: Bool
}

/// Parses the `dreaming` lane state from a `moot_drain_status` text response.
///
/// Matches the same response shapes as `parseDrainResponse`:
///   Shape A — `"drains: none"` → pending=0, settled=true (no lanes active).
///   Shape B — scans for a line beginning with `"  dreaming:"`.
///     State word is "draining" → settled=false; anything else → settled=true.
///     `pending: N` is extracted with the same field parser used by the barrier.
///
/// If the dreaming lane line is absent (other lanes exist but dreaming is not
/// among them), returns pending=0, settled=true.
///
/// Internal visibility allows direct unit testing.
func dreamStatusFromDrainText(_ text: String) -> DreamStatus {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Shape A: "drains: none" — no lanes active, nothing dreaming.
    if trimmed == "drains: none" {
        return DreamStatus(pending: 0, settled: true)
    }
    // Shape B: multi-line — search for the dreaming lane entry.
    for line in trimmed.components(separatedBy: "\n") {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        guard stripped.hasPrefix("dreaming:") else { continue }
        // Format: "dreaming: <state> — pending: N, in_flight: M[, <detail>]"
        let settled = !stripped.contains("draining")
        let pending = parseIntField("pending: ", from: stripped) ?? 0
        return DreamStatus(pending: pending, settled: settled)
    }
    // Dreaming lane not listed — nothing outstanding.
    return DreamStatus(pending: 0, settled: true)
}

/// v2-aware dream status reader: reads structured `drainEntries` when available,
/// falls back to `dreamStatusFromDrainText` for v1 shape compatibility.
///
/// Uses the same precedence as `parseDrainResult`: structured data first,
/// text parsing as fallback. The dreaming lane carries `name: "dreaming"`.
func dreamStatusFromResult(_ result: MCPToolResult) -> DreamStatus {
    if let entries = result.drainEntries {
        if let dreaming = entries.first(where: { $0.name == "dreaming" }) {
            // settled: lane is idle AND no work is pending.
            let settled = dreaming.state != "draining" && dreaming.pending == 0
            return DreamStatus(pending: dreaming.pending, settled: settled)
        }
        // dreaming lane absent from the entries list — nothing outstanding.
        return DreamStatus(pending: 0, settled: true)
    }
    return dreamStatusFromDrainText(result.textBlocks.joined(separator: "\n"))
}

/// Calls `moot_drain_status` once and returns the dreaming drain lane state.
///
/// Non-throwing: if the RPC fails or the response is unparseable, returns a
/// conservative default (pending=0, settled=true) and logs to stderr.
/// The dream-status field is informational; it must never abort a measurement run.
func readDrainStatusOnce(client: MCPClient) async -> DreamStatus {
    do {
        let result = try await client.callTool(
            AriaV2Surface.drainStatus,
            arguments: [:],
            format: .mootV2,
            deadline: MCPDeadline.status
        )
        // dreamStatusFromResult prefers structuredContent.data.drains[] (v2)
        // and falls back to text block parsing (v1) when absent.
        return dreamStatusFromResult(result)
    } catch {
        FileHandle.standardError.write(Data(
            "[dream-status] moot_drain_status failed: \(error)\n".utf8))
        return DreamStatus(pending: 0, settled: true)
    }
}
