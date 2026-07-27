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

// MARK: - Drain barrier

/// Polls `moot_drain_status` after ingest completes, waiting until all drains
/// report "idle" before the caller issues its first recall query.
///
/// Response format: `"drains: N"` followed by per-drain status lines:
///   `"  corpus_encode: draining — pending: N, in_flight: N"`
/// or
///   `"  corpus_encode: idle — pending: 0, in_flight: 0"`
/// When no corpus is registered: `"drains: none"` (treated as idle).
///
/// Returns `true` when all drains became idle within `timeoutSeconds`.
/// Returns `false` when the timeout expired without full convergence —
/// a WARNING is emitted to stderr and the run continues (honest failure,
/// not a hard abort, so latency measurements are still recorded).
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
            // "drains: none" — no corpus registered on this estate; treat as idle.
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == "drains: none" {
                return true
            }
            // Check whether any drain line reports "draining" state.
            // Line format: "  <name>: draining — ..." or "  <name>: idle — ..."
            let lines = text.components(separatedBy: "\n")
            let anyDraining = lines.contains { line in
                // The state word appears right after the colon: "  corpus_encode: draining"
                line.contains(": draining")
            }
            if !anyDraining {
                // All drains idle (or no drain lines at all — also idle).
                return true
            }
            // Still draining — log first pending count for visibility.
            if let drainingLine = lines.first(where: { $0.contains(": draining") }) {
                FileHandle.standardError.write(Data(
                    "[\(label)] drain barrier: waiting — \(drainingLine.trimmingCharacters(in: .whitespaces))\n".utf8))
            }
        } catch {
            // moot_drain_status RPC failed — log, then check for fatal transport death.
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
            let isFatal = (desc.contains("session") && desc.contains("closed"))
                || desc.contains("not connected")
                || desc.contains("disconnected")
                || desc.contains("broken pipe")
            if isFatal {
                FileHandle.standardError.write(Data(
                    "[\(label)] drain barrier: FATAL — MCP transport died (server exited). Aborting poll.\n".utf8))
                return false
            }
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanos)
    }

    // Timed out — emit honest warning and let the run proceed.
    let timeoutMsg = "[\(label)] drain barrier: WARNING — encode drain did not converge within "
        + "\(Int(timeoutSeconds))s. Proceeding with query; recall quality may be reduced.\n"
    FileHandle.standardError.write(Data(timeoutMsg.utf8))
    return false
}
