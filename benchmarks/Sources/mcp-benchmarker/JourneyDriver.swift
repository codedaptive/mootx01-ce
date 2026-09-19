// JourneyDriver.swift — argument builders for the new PR-03 verb surfaces.
//
// These functions build the tool-call argument dictionaries for the three new
// harness exerciser patterns added in PR-03. They are PURE BUILDERS: they
// take typed parameters and return `[String: JSONValue]` argument maps ready
// to pass to `MCPClient.callTool`. No network I/O, no actor state.
//
// Why this layer exists. The benchmarker previously exercised only the two
// legacy call patterns (file_memory write, recall read). PR-03 added three
// new verb shapes that no existing runner exercises:
//
//   near pivots        — recall pivoting from a known anchor item outward,
//                        via the `near` argument (never a query string).
//   batch hydrate      — fetch multiple items at a configurable depth tier.
//   missing_subject    — enumerate id-only rows that lack a filed subject,
//                        scoped to a required wing.
//
// JourneyDriver provides the harness side of these shapes so they can be
// exercised in unit tests against canned fixture replies (no live product
// run required) and composed into scripted journeys in JourneySmokeSuite.

import Foundation

// MARK: - Hydration depth

/// The three depth tiers accepted by `moot_memory_get` (PR-03).
///
/// - `subject`: id and subject line only — the lowest token cost tier.
/// - `distilled`: id, subject, and FDC-distilled summary.
/// - `full`: id, subject, and full body content — the highest cost tier.
public enum HydrationDepth: String, Sendable, CaseIterable {
    /// Returns the id and subject line only.
    case subject = "subject"
    /// Returns the id, subject, and FDC-distilled summary.
    case distilled = "distilled"
    /// Returns the id, subject, and full body content.
    case full = "full"
}

// MARK: - Argument builders

/// Builds the argument map for a `moot_memory_search` call that pivots
/// from a known item UUID outward (the anchor-pivot pattern).
///
/// `near` is a first-class argument, mutually exclusive with `query`:
/// the server fetches the anchor, runs its verbatim content through the
/// same scored pipeline, and excludes the anchor row from the reply. That
/// is a different code path from text recall, which is the point of
/// exercising it here.
///
/// Emitting NO `query` key is load-bearing, not tidiness. `moot_memory_search`
/// rejects a call carrying both, and a call carrying only `query` runs an
/// ordinary text search — so a `query: "near:<uuid>"` string never reaches
/// the anchor path at all; it searches for that literal text.
///
/// - Parameter uuid: The UUID of the pivot item. Must be a valid UUID string;
///   no validation is performed here — the server will reject malformed values.
/// - Parameter extraArgs: Optional additional arguments (e.g. `limit`, `wing`).
///   These are merged after the required `near` key; callers may override.
///   Passing `query` here re-creates the mutual-exclusion violation and the
///   server will reject the call.
/// - Returns: Argument dictionary ready for `MCPClient.callTool`.
public func nearPivotSearchArgs(uuid: String,
                                extraArgs: [String: JSONValue] = [:]) -> [String: JSONValue] {
    var args: [String: JSONValue] = [
        "near": .string(uuid),
    ]
    for (k, v) in extraArgs { args[k] = v }
    return args
}

/// Builds the argument map for a `moot_recall_shaped` call that pivots
/// from a known item UUID outward.
///
/// Same contract as `nearPivotSearchArgs` — `near` instead of `query`,
/// exactly one of the two — but targets the shaped recall verb, which fans
/// the anchor out under the active RecallShape preset. Use this to exercise
/// both recall verbs in the same journey sequence.
///
/// - Parameter uuid: The UUID of the pivot item.
/// - Parameter extraArgs: Optional additional arguments (e.g. `preset`, `limit`).
/// - Returns: Argument dictionary ready for `MCPClient.callTool`.
public func nearPivotShapedArgs(uuid: String,
                                extraArgs: [String: JSONValue] = [:]) -> [String: JSONValue] {
    var args: [String: JSONValue] = [
        "near": .string(uuid),
    ]
    for (k, v) in extraArgs { args[k] = v }
    return args
}

/// Builds the argument map for a `moot_memory_get` call that batch-hydrates
/// a set of UUIDs at a specified depth tier (PR-03 `ids+depth` pattern).
///
/// The batch-hydrate verb returns the content of each requested UUID at
/// the named depth. This exercises the body-fetch path that a journey agent
/// uses after identifying the relevant items via recall.
///
/// - Parameter ids: UUIDs to hydrate. Order is preserved in the JSON array.
/// - Parameter depth: The hydration tier. Defaults to `.full`.
/// - Parameter extraArgs: Optional additional arguments.
/// - Returns: Argument dictionary ready for `MCPClient.callTool`.
public func batchHydrateArgs(ids: [String],
                              depth: HydrationDepth = .full,
                              extraArgs: [String: JSONValue] = [:]) -> [String: JSONValue] {
    // v2 renamed the batch key: `ids` (v1) → `memory_ids` (v2).
    var args: [String: JSONValue] = [
        "memory_ids": .array(ids.map { .string($0) }),
        "depth": .string(depth.rawValue),
    ]
    for (k, v) in extraArgs { args[k] = v }
    return args
}

/// Builds the argument map for a `moot_memory_list` call that enumerates
/// id-only rows lacking a filed subject (PR-03 `filter:missing_subject` pattern).
///
/// When the harness has ingested content without a subject (or with an empty
/// subject), the server can enumerate those rows. This exercises the
/// maintenance path: find missing-subject rows so they can be patched.
///
/// `wing` is required by `moot_memory_list` and has NO server-side default,
/// so it is a required parameter here rather than one with a harness default.
/// A default would be the same failure the count validation exists to
/// prevent: enumerating a wing the operator never asked for, then labelling
/// the result with the run they thought they configured.
///
/// - Parameter wing: The wing to enumerate. Required by the tool schema.
/// - Parameter extraArgs: Optional additional arguments (e.g. `room`).
/// - Returns: Argument dictionary ready for `MCPClient.callTool`.
public func missingSubjectArgs(wing: String,
                               extraArgs: [String: JSONValue] = [:]) -> [String: JSONValue] {
    var args: [String: JSONValue] = [
        "wing": .string(wing),
        "filter": .string("missing_subject"),
    ]
    for (k, v) in extraArgs { args[k] = v }
    return args
}
