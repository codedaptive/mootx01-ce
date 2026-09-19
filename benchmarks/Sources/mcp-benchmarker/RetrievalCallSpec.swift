import Foundation

// Retrieval-call override seam. The lanes' query verb is normally fixed by
// their VerbMap; a caller may override the tool and attach constant
// arguments through the environment, the same instrument seam family as
// MOOT_BENCH_ANSWER_CMD / MOOT_BENCH_JUDGE_CMD / MOOT_BENCH_RERANK_CMD:
//
//   MOOT_BENCH_RETRIEVAL_TOOL  tool name to call instead of the verb map's
//                              query verb (e.g. moot_recall_precise)
//   MOOT_BENCH_RETRIEVAL_ARGS  JSON object of constant arguments merged
//                              into every query call; values pass through
//                              verbatim (string, number, bool, …) so tools
//                              with integer parameters (pool, limit) can be
//                              driven through the seam
//   MOOT_BENCH_UNIT_IDS        path to a unit-ID file (one per line);
//                              the lane runs exactly those units
//
// The seam is environment-only by design: it is an instrument extension
// point, not a documented lane option, and argv stays clean.

/// One retrieval call description: tool + constant extra arguments.
struct RetrievalCallSpec: Sendable {
    let tool: String
    let extraArgs: [String: JSONValue]
}

/// Parses a retrieval call spec from an explicit environment dictionary.
/// Called by `retrievalCallSpecFromEnvironment` and directly by unit tests.
/// A malformed `MOOT_BENCH_RETRIEVAL_ARGS` value is a hard error — a seam
/// that silently dropped its arguments would measure the wrong door.
func retrievalCallSpec(from env: [String: String]) throws -> RetrievalCallSpec? {
    guard let tool = env["MOOT_BENCH_RETRIEVAL_TOOL"], !tool.isEmpty else {
        return nil
    }
    var extra: [String: JSONValue] = [:]
    if let raw = env["MOOT_BENCH_RETRIEVAL_ARGS"], !raw.isEmpty {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
            throw MCPError(description:
                "MOOT_BENCH_RETRIEVAL_ARGS must be a JSON object")
        }
        extra = obj
    }
    return RetrievalCallSpec(tool: tool, extraArgs: extra)
}

/// Reads the retrieval-call seam from the process environment. Returns nil
/// when `MOOT_BENCH_RETRIEVAL_TOOL` is unset. Delegates to
/// `retrievalCallSpec(from:)` so the parse logic is unit-testable without
/// spawning a subprocess.
func retrievalCallSpecFromEnvironment() throws -> RetrievalCallSpec? {
    try retrievalCallSpec(from: ProcessInfo.processInfo.environment)
}

/// Reads the unit-ID seam from the environment. Returns nil when unset.
func unitIDsFromEnvironment() throws -> Set<String>? {
    guard let path = ProcessInfo.processInfo.environment["MOOT_BENCH_UNIT_IDS"],
          !path.isEmpty else { return nil }
    return try loadUnitIDs(path)
}

/// Executes one retrieval through the configured call: the override spec
/// when present, else the lane's standard verb-map query. All lanes share
/// this one seam; the scorer never knows which door answered.
///
/// A TOOL-LEVEL error result (`isError: true` — e.g. moot_recall_shaped
/// rejecting an unknown preset) is thrown here, not returned: the error
/// text parses as zero results, and a zero-result unit recorded under a
/// mislabeled door is the exact defect class D-2026-08-20-A exists to
/// prevent. Fail loud at the one seam every lane shares.
///
/// `arm` (PAYLOAD-ARMS) post-processes the returned textBlocks through the
/// payload-economics shape variant BEFORE any downstream capture, so every
/// judged-output / anscheck prompt fed from this seam's row text sees the
/// arm's field subset. `orderedIDs` and `items` were parsed from the FULL
/// ruled payload and pass through untouched — retrieval scoring is
/// arm-invariant by construction. nil (and .v4) are byte-identical to
/// pre-arm behaviour.
func retrieveThroughSeam(
    _ text: String,
    client: MCPClient,
    verbMap: EndpointConfig.VerbMap,
    spec: RetrievalCallSpec?,
    arm: PayloadArm? = nil
) async throws -> MCPToolResult {
    let result: MCPToolResult
    if let spec {
        var args: [String: JSONValue] = [verbMap.queryArg: .string(text)]
        for (k, v) in spec.extraArgs { args[k] = v }
        result = try await client.callTool(
            spec.tool, arguments: args, format: verbMap.resultFormat)
    } else {
        // Use the adapter builder so `location` is remapped to `wing` for
        // moot_memory_search queries; seam_call is query-only.
        let args = AriaV2Surface.memorySearchArgs(verbMap: verbMap, query: text)
        result = try await client.callTool(
            verbMap.query, arguments: args, format: verbMap.resultFormat)
    }
    guard !result.isError else {
        // Surface the refusal class (catalog code string) when present so callers
        // can assert the exact class rather than just catching a flat error string.
        // The class tag format mirrors the one used by the -32602 handler in
        // sendRequest so all refusal errors share the same [class=...] prefix.
        let classTag = result.refusal.map { " [class=\($0.code)]" } ?? ""
        throw MCPError(
            description: "retrieval tool returned an error result\(classTag) "
                + "(tool=\(spec?.tool ?? verbMap.query)): "
                + String(result.textBlocks.joined(separator: " ").prefix(300)),
            refusal: result.refusal)
    }
    guard let arm, arm != .v4 else { return result }
    return MCPToolResult(
        orderedIDs: result.orderedIDs,
        items: result.items,
        writeAssignedID: result.writeAssignedID,
        textBlocks: arm.apply(toTextBlocks: result.textBlocks),
        isError: result.isError)
}
