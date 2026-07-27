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
enum DrainParseResult: Equatable {
    /// All registered drains are idle (pending == 0, in_flight == 0), or no
    /// corpus is registered ("drains: none"). Safe to issue recall queries.
    case idle
    /// At least one drain has pending or in-flight work, or explicitly reports
    /// the state word "draining". Keep polling.
    case draining
    /// The response did not match any recognised shape. The caller must abort
    /// the run — proceeding silently would produce invalid recall results.
    case unparseable
}

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
/// A drain is considered active when:
///   • its state word is `"draining"`, OR
///   • its `pending` count is non-zero, OR
///   • its `in_flight` count is non-zero.
///
/// Returns `.idle` only when ALL drains in the response explicitly report
/// `state == "idle"` with both counts at zero.
/// Returns `.unparseable` for any response that does not match Shape A or B.
///
/// This function is `internal` (not private) to allow direct unit testing.
func parseDrainResponse(_ text: String) -> DrainParseResult {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Shape A: "drains: none" — no corpus registered; treat as idle.
    if trimmed == "drains: none" {
        return .idle
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
        let state = String(nameStateStr[colonSpace.upperBound...])

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

    // If the header declared N > 0 drains and we parsed at least one drain
    // line without finding any active work, all drains are idle.
    if parsedLineCount > 0 {
        return .idle
    }
    // Header claimed N > 0 drains but we found no parseable drain lines.
    return .unparseable
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

// MARK: - Drain barrier

/// Polls `moot_drain_status` after ingest completes, waiting until all drains
/// report "idle" before the caller issues its first recall query.
///
/// Response shapes handled:
///   "drains: none"  — no corpus registered; treat as idle.
///   "drains: N"
///   "  <name>: draining — pending: N, in_flight: N[, <detail>]"
///   "  <name>: idle    — pending: 0, in_flight: 0[, <detail>]"
///
/// **FATAL on unknown shape.** If `moot_drain_status` returns a response that
/// does not match a known shape, the benchmark process aborts with exit(1) and
/// a diagnostic message on stderr naming the raw response. Silently treating
/// an unknown shape as idle would allow the benchmark to issue recall queries
/// before encoding is complete, producing invalid recall scores.
///
/// Returns `true` when all drains became idle within `timeoutSeconds`.
/// Returns `false` when the timeout expired without full convergence —
/// a WARNING is emitted to stderr and the run continues (the latency
/// and quality degradation are then part of the recorded result).
///
/// - Parameters:
///   - client: A connected `MCPClient` pointing at the estate to poll.
///   - label: Short label for stderr progress lines (e.g. "lme q42").
///   - timeoutSeconds: Maximum poll window. Default 300 s (5 min).
/// - Returns: True when drained, false when timed out.
func waitForEncodeDrain(
    client: MCPClient,
    label: String,
    timeoutSeconds: Double = 300.0
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    // 500 ms poll interval — frequent enough to detect convergence quickly
    // without hammering the estate with status RPCs.
    let pollIntervalNanos: UInt64 = 500_000_000

    while Date() < deadline {
        do {
            let result = try await client.callTool(
                "moot_drain_status",
                arguments: [:],
                format: .mootText
            )
            let text = result.textBlocks.joined(separator: "\n")

            switch parseDrainResponse(text) {
            case .idle:
                return true

            case .draining:
                // Still draining — log the trimmed response for visibility.
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                FileHandle.standardError.write(Data(
                    "[\(label)] drain barrier: waiting — \(trimmed)\n".utf8))

            case .unparseable:
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
            // moot_drain_status RPC failed — log and retry; transient failures
            // are recoverable within the timeout window.
            FileHandle.standardError.write(Data(
                "[\(label)] drain barrier: moot_drain_status error: \(error)\n".utf8))
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanos)
    }

    // Timed out — emit honest warning and let the run proceed.
    let timeoutMsg = "[\(label)] drain barrier: WARNING — encode drain did not converge within "
        + "\(Int(timeoutSeconds))s. Proceeding with query; recall quality may be reduced.\n"
    FileHandle.standardError.write(Data(timeoutMsg.utf8))
    return false
}
