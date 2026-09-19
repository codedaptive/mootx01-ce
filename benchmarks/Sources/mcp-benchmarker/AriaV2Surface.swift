// AriaV2Surface.swift — ARIA v2 surface adapter for the benchmark harness.
//
// All MCP tool name constants and argument key constants used by the harness
// route through this file. After this change, `rg -n '"moot_[a-z_]+"' Sources`
// should show hits only in this file (plus EstateSeams.swift and MintCLI.swift,
// which are V2-E scope and untouched).
//
// The twin of this file on the Rust port is `aria_v2_surface.rs`.
//
// v1→v2 naming changes:
//   moot_federated_search  →  moot_federated_recall  (renamed in v2)
//   All other tool names are unchanged.
//
// v1→v2 argument changes (dropped or remapped by this adapter):
//   `ordering`  — accepted by moot_memory_search in v2 (catalog-confirmed accepted_key),
//                  but the harness omits it because v2 defaults to byRelevanceDesc;
//                  no caller currently passes it, and the adapter does not strip it
//   `mode`      — removed from moot_json_import (v2 accepts only path + estate_id)
//   `teachme`   — removed entirely; help is moot_help
//   `confirmed` — renamed to `confirmation` on moot_erase_memory (not used by runners)
//   `id`        — renamed to `memory_id` on moot_memory_get (scalar form)
//   `ids`       — renamed to `memory_ids` on moot_memory_get (batch form)
//   `location`  — renamed to `wing` on moot_memory_search (scope key changed in v2;
//                  moot_file_memory still uses `location`)
//   `ack`       — removed from moot_recall_distilled (v2 has no ack gate)
//
// v2 structured response shapes (read by parseMootV2 in MCPClient.swift):
//   moot_memory_search    → structuredContent.data.results[].{memory_id, excerpt}
//   moot_recall_*         → structuredContent.data.results[].{id, bestSpan}
//   moot_file_memory      → structuredContent.data.memory_id  (write receipt)
//   moot_memory_get       → structuredContent.data.memories[].{memory_id, content}
//   moot_memory_list      → structuredContent.data.memories[].{memory_id}
//
// moot_distill is a RETIRED ALIAS in v2 (negative_catalog_assertions
// absent_reason: "Retired alias."). Callers that need to gate on distillation
// must throw AriaV2SurfaceError.retiredOperation("moot_distill") — this adapter
// provides no constant for it because the operation does not exist on v2.

import Foundation

/// Typed error for this adapter's surface validation.
public enum AriaV2SurfaceError: Error, Sendable, CustomStringConvertible {
    /// The named operation is retired in ARIA v2 and must not be called.
    /// The dense-recall arm should propagate this error when moot_distill
    /// is required; both ports refuse identically (parity rule).
    case retiredOperation(String)

    public var description: String {
        switch self {
        case .retiredOperation(let op):
            return "\(op) is retired on the ARIA v2 surface "
                + "(negative_catalog_assertions absent_reason: \"Retired alias.\"). "
                + "No equivalent operation exists on v2; the dense arm refuses."
        }
    }
}

/// Centralised ARIA v2 surface constants for the benchmark harness.
///
/// Naming convention: every `static let` here is the v2 MCP tool name string.
/// Runners import this struct by name; no file outside this struct (except
/// EstateSeams.swift and MintCLI.swift, V2-E scope) should contain a
/// `"moot_*"` string literal after this migration.
public enum AriaV2Surface {

    // MARK: - Core memory tools

    /// File a durable memory with explicit subject and placement.
    /// v2 required args: `content`, `subject`, `location`. Optional: `wing`.
    public static let fileMemory = "moot_file_memory"

    /// Search memories by query, returning compact authorised rows.
    /// v2 scope key: `wing` (v1 used `location`, which is renamed in v2).
    /// v2 args: `query` OR `near` (oneOf), optional `wing`, `limit`, `ordering`, `estate_id`.
    /// Note: `ordering` is an accepted key in v2 (catalog-confirmed); the harness
    /// omits it because v2 defaults to byRelevanceDesc, which is the intended order.
    public static let memorySearch = "moot_memory_search"

    /// Fetch one or a bounded batch of authorised memories by UUID.
    /// v2 keys: `memory_id` (scalar) or `memory_ids` (batch); v1 used `id`/`ids`.
    public static let memoryGet = "moot_memory_get"

    /// Enumerate a complete authorised structural memory inventory.
    /// v2 accepts `wing`, `room`, `filter` (enum: "missing_subject"), `limit`, `cursor`.
    public static let memoryList = "moot_memory_list"

    // MARK: - Recall lenses

    /// Named precision composition recall.
    public static let recallPrecise = "moot_recall_precise"

    /// Signed-weight fusion recall (shaped retrieval).
    public static let recallShaped = "moot_recall_shaped"

    /// Compact distilled memory projections recall.
    /// v2: no `ack` argument — the gate was removed in v2.
    public static let recallDistilled = "moot_recall_distilled"

    /// Vague / low-signal recall.
    public static let recallVague = "moot_recall_vague"

    /// Graph-walk recall through bounded connections.
    public static let recallConnected = "moot_recall_connected"

    // MARK: - Maintenance operations

    /// Dream pass — generates associations and surfaces contradictions.
    public static let dream = "moot_dream"

    /// Reindex — rebuilds the vector and BM25 indices.
    public static let reindex = "moot_reindex"

    /// Synthesise — produce a grounded summary over a query window.
    public static let synthesize = "moot_synthesize"

    // NOTE: moot_distill is absent from this adapter. It is a retired alias
    // in ARIA v2 (negative_catalog_assertions absent_reason: "Retired alias.").
    // Callers should throw AriaV2SurfaceError.retiredOperation("moot_distill").

    // MARK: - Import tools

    /// JSON import from a local file path.
    /// v2 args: `path`, optional `estate_id`. `mode` is GONE in v2.
    /// Requires vault capability — not available on default scratch estates.
    public static let jsonImport = "moot_json_import"

    // MARK: - Facts and knowledge-graph

    /// File a KG fact.
    public static let fileFact = "moot_file_fact"

    /// Search KG facts.
    public static let factSearch = "moot_fact_search"

    /// Fact timeline query.
    public static let factTimeline = "moot_fact_timeline"

    /// Retire a KG fact.
    public static let retireFact = "moot_retire_fact"

    /// Hunt for contradictions across the estate.
    public static let huntContradictions = "moot_hunt_contradictions"

    // MARK: - Connections

    /// Search connections between memories.
    public static let connectionSearch = "moot_connection_search"

    /// Render a connection map around a memory.
    public static let connectionMap = "moot_connection_map"

    // MARK: - Diagnostics

    /// Estate status overview.
    public static let estateStatus = "moot_estate_status"

    /// Estate reachability ping.
    public static let estatePing = "moot_estate_ping"

    /// Estate knowledge map.
    public static let estateMap = "moot_estate_map"

    /// Encode-queue drain status.
    public static let drainStatus = "moot_drain_status"

    /// Per-operation timing report.
    public static let timingReport = "moot_timing_report"

    // MARK: - Vault

    /// Vault capability status.
    public static let vaultStatus = "moot_vault_status"

    /// Vault background job status.
    public static let vaultJob = "moot_vault_job"

    // MARK: - Cognition catalogue

    /// List available recall lenses.
    public static let listLenses = "moot_list_lenses"

    /// List available CognitionKit recipes.
    public static let listRecipes = "moot_list_recipes"

    // MARK: - Journal

    /// Read the estate journal.
    public static let readJournal = "moot_read_journal"

    // MARK: - Dataset tools

    /// Query a structured dataset.
    public static let datasetQuery = "moot_dataset_query"

    /// Read summary statistics for a dataset.
    public static let datasetStats = "moot_dataset_stats"

    // MARK: - Orchestration

    /// Federated recall across granted remote estates.
    /// v2 name: `moot_federated_recall` (was `moot_federated_search` in v1).
    public static let federatedRecall = "moot_federated_recall"

    // MARK: - Lens operations (used in the agentic read-only allowlist)

    public static let lensAnticipate = "moot_lens_anticipate"
    public static let lensApriori = "moot_lens_apriori"
    public static let lensAssociations = "moot_lens_associations"
    public static let lensBias = "moot_lens_bias"
    public static let lensCohesion = "moot_lens_cohesion"
    public static let lensComplexity = "moot_lens_complexity"
    public static let lensConcepts = "moot_lens_concepts"
    public static let lensConstellation = "moot_lens_constellation"
    public static let lensContradiction = "moot_lens_contradiction"
    public static let lensDivergence = "moot_lens_divergence"
    public static let lensDrift = "moot_lens_drift"
    public static let lensFreeAssociation = "moot_lens_free_association"
    public static let lensKeystones = "moot_lens_keystones"
    public static let lensLatentThemes = "moot_lens_latent_themes"
    public static let lensMoment = "moot_lens_moment"
    public static let lensNodeMotion = "moot_lens_node_motion"
    public static let lensOverlap = "moot_lens_overlap"
    public static let lensPartialCue = "moot_lens_partial_cue"
    public static let lensPrecedence = "moot_lens_precedence"
    public static let lensRhythm = "moot_lens_rhythm"
    public static let lensSuccessors = "moot_lens_successors"
    public static let lensThemeWeather = "moot_lens_theme_weather"
    public static let lensTrustSynthesis = "moot_lens_trust_synthesis"

    // MARK: - Complete agentic read-only allowlist

    /// The set of ARIA v2 tools the agentic arm is allowed to call.
    ///
    /// This set is the v2 version of what was previously built from string
    /// literals. The one name change from v1: `moot_federated_search` (v1) →
    /// `moot_federated_recall` (v2). All other names are unchanged.
    public static let agenticReadOnlyTools: Set<String> = [
        // Estate diagnostics
        estateStatus, estatePing, drainStatus, timingReport,
        // Cognition catalogue
        listLenses, listRecipes,
        // Vault
        vaultStatus, vaultJob,
        // Core memory
        memorySearch, memoryGet, memoryList,
        // Recall lenses
        recallPrecise, recallShaped, recallDistilled, recallVague,
        // Facts
        factSearch, factTimeline,
        // Connections
        connectionSearch, connectionMap,
        // Estate
        estateMap, readJournal,
        // Federated (renamed from moot_federated_search in v1)
        federatedRecall,
        // Datasets
        datasetQuery, datasetStats,
        // Lens operations
        lensAnticipate, lensApriori, lensAssociations, lensBias,
        lensCohesion, lensComplexity, lensConcepts, lensConstellation,
        lensContradiction, lensDivergence, lensDrift, lensFreeAssociation,
        lensKeystones, lensLatentThemes, lensMoment, lensNodeMotion,
        lensOverlap, lensPartialCue, lensPrecedence, lensRhythm,
        lensSuccessors, lensThemeWeather, lensTrustSynthesis,
    ]

    // MARK: - Standard v2 VerbMaps

    /// Standard mootx01 v2 VerbMap for ingestion + exact recall queries.
    ///
    /// write:         moot_file_memory  (v2 requires subject+location+content)
    /// query:         moot_memory_search
    /// constantArgs:  { "location": <namespace> }  — applied to writes;
    ///                memorySearchArgs() remaps this to "wing" for queries.
    /// resultFormat:  .mootV2  (reads structuredContent.data.results[].memory_id)
    public static func lmeMootVerbMap(location: String) -> EndpointConfig.VerbMap {
        EndpointConfig.VerbMap(
            write: fileMemory,
            query: memorySearch,
            list: nil,
            constantArgs: ["location": location],
            resultFormat: .mootV2
        )
    }

    /// Standard mootx01 v2 VerbMap for dense recall (moot_recall_distilled).
    ///
    /// write:  moot_file_memory  (same ingest tool)
    /// query:  moot_recall_distilled
    /// v2: no `ack` argument — the v1 ack gate does not exist in v2.
    public static let denseMootVerbMap = EndpointConfig.VerbMap(
        write: fileMemory,
        query: recallDistilled,
        list: nil,
        constantArgs: [:],
        resultFormat: .mootV2
    )

    // MARK: - Request builders (adapter owns argument keys)

    /// Build the argument dict for a `moot_memory_search` call.
    ///
    /// v2 replaced the `location` scope key with `wing`. This builder remaps
    /// `constantArgs["location"]` → `"wing"` so every runner routes the
    /// translation through one place. All other constant args pass through
    /// unchanged.
    ///
    /// - Parameters:
    ///   - verbMap: The VerbMap governing this query. Its `constantArgs`
    ///              typically carry `"location": "benchmarks/<dataset>"`.
    ///   - query: The query string.
    /// - Returns: Argument dict ready for `callTool(_:arguments:format:)`.
    public static func memorySearchArgs(
        verbMap: EndpointConfig.VerbMap, query: String
    ) -> [String: JSONValue] {
        var args: [String: JSONValue] = [verbMap.queryArg: .string(query)]
        for (k, v) in verbMap.constantArgs {
            // v2 renamed the scope key: `location` (v1) → `wing` (v2)
            // on moot_memory_search. moot_file_memory still uses `location`.
            args[k == "location" ? "wing" : k] = .string(v)
        }
        return args
    }

    /// Build the argument dict for `moot_memory_get` (scalar form).
    /// v2 replaced the `id` key with `memory_id`.
    public static func memoryGetArgs(
        memoryId: String, depth: String? = nil
    ) -> [String: JSONValue] {
        var args: [String: JSONValue] = ["memory_id": .string(memoryId)]
        if let depth { args["depth"] = .string(depth) }
        return args
    }

    /// Build the argument dict for `moot_memory_get` (batch form).
    /// v2 replaced the `ids` key with `memory_ids`.
    public static func memoryGetBatchArgs(
        memoryIds: [String], depth: String? = nil
    ) -> [String: JSONValue] {
        var args: [String: JSONValue] = ["memory_ids": .array(memoryIds.map { .string($0) })]
        if let depth { args["depth"] = .string(depth) }
        return args
    }
}
