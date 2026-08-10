// RecipeTools.swift
//
// The CognitionKit behaviour-recipe surface on ARIA_MCP. These tools sit
// ABOVE the lexicon projection (provenance `.recipe`, dispatched by name)
// exactly as the federation `cross_estate_recall` tool does. They are the
// conscious-mind surface: the MCP↔CognitionKit channel is R/W, so an
// agent reads what recipes exist and triggers them, and the human-in-the-
// loop confirms the migration promotion.
//
// Ten listed recipe tools ship here; two are dispatch-only (alias/stub):
//   - moot_list_lenses           → ProjectedTool descriptor enumeration
//                                   (LensTools + Tier 6 RecipeTools — read)
//   - moot_list_recipes          → RecipeCatalog descriptor enumeration
//                                   (catalog discovery)
//   - moot_synthesize            → GroundedSynthesis recipe (read)
//   - moot_recall_precise        → PreciseRecall recipe (read)
//   - moot_recall_shaped         → ShapedRecall recipe (read)
//   - moot_run_migration         → MigrationBenchmark.run (read; no
//                                   promotion — B-3)
//   - moot_confirm_migration     → MigrationBenchmark.confirmPromotion
//                                   by branch id (the human-gated write)
//   - moot_dream, moot_distill, moot_recall_distilled
//                                 → Brain-layer and distillation tools
//   - moot_recollect             → notice-only stub; tool removed; not listed
//
// The 23 lens tools (16 reasoning/federated, 4 temporal/information-theoretic,
// 3 analytics: moot_lens_associations, moot_lens_concepts, moot_lens_apriori)
// ship through LensTools.swift — same provenance (.recipe), dispatched
// through the lens surface per LENS_DISCOVERABILITY_DECISION v2.0.
//
// Stateless-boundary discipline: MCP `tools/call` is stateless across
// invocations, so the run tool cannot hand live `BranchHandle`s to a
// later confirm tool. The run tool surfaces branch *ids* in its result;
// the confirm tool takes those ids and re-resolves them through the
// long-lived kit's `GeniusLocusKit.branchHandle(for:)` accessor. This is
// the two-call run→confirm pattern the plan describes; webhook delivery
// of async completion is an additive transport, not needed for the
// synchronous behaviour.

import Foundation
import GeniusLocusKit
import NeuronKit
import LocusKit
import CognitionKit
import VaultKit

/// Namespace for the CognitionKit recipe tool surface. No instances.
enum RecipeTools {

    // MARK: - Tool names

    static let listRecipesToolName = "moot_list_lenses"
    /// Catalog discovery tool: returns name/version/description/capabilities
    /// for every shipped recipe in catalog order. Distinct from
    /// `moot_list_lenses` which enumerates ProjectedTool descriptors
    /// (schema + required args) for Tier 6 invokable tools.
    static let listRecipesCatalogToolName = "moot_list_recipes"
    static let groundedSynthesisToolName = "moot_synthesize"
    static let preciseRecallToolName = "moot_recall_precise"
    static let vagueRecallToolName = "moot_recall_vague"
    /// Shaped-recall tool: a single recall tool with a discoverable `preset` enum
    /// param selecting one named RecallShape from the GLK roster. Preferable to ~20
    /// tools (one per shape) — the AI picks a deterministic recipe by name instead
    /// of simulating steering.
    static let shapedRecallToolName = "moot_recall_shaped"
    /// Connected-recall tool: multi-hop retrieval by graph diffusion — a
    /// scored anchor grab seeds a deterministic walk-with-restart over the
    /// estate's tunnels ∪ pending associations, and the walk's visit ranking
    /// fuses with the anchor ranking. The EXPENSIVE recall path: the caller
    /// escalates here for hard bridge questions the similarity lanes miss.
    static let connectedRecallToolName = "moot_recall_connected"
    static let runMigrationBenchmarkToolName = "moot_run_migration"
    static let confirmMigrationPromotionToolName = "moot_confirm_migration"
    /// On-demand dream tool: rebuild the estate's derived accelerators (the
    /// co-occurrence/temporal matrix tier that feeds the `matrix`/`coOccurrence`
    /// recall lanes) and run one dreaming cycle (latent-alignment proposals +
    /// the cycle diary). The Brain's matrix is built by the dreaming pass, not
    /// by impatient encode, so a freshly-loaded estate has an EMPTY matrix until
    /// this runs — the reason the matrix-driven precise compositions score zero
    /// on an undreamt estate.
    static let dreamToolName = "moot_dream"
    /// On-demand distillation sweep (SPEC_DISTILLATION_STORAGE §3): populate
    /// the on-row distilled representation of every eligible item. Delegates
    /// to the Distill recipe → GeniusLocusKit.distillItemsSweep.
    static let distillToolName = "moot_distill"
    /// Distilled-payload recall (SPEC §10.3): exact-search geometry over
    /// originals with the hydration selector pinned to `distilled` —
    /// identical ranking to exact search, smaller payloads, per-hit token
    /// counts. ACK-gated (contract changed in Wave 1); token: "recall_distilled/v2".
    static let recallDistilledToolName = "moot_recall_distilled"
    /// Removed tool: its substrate (factoid drawers) was retired with the
    /// factoid tier. Reinstated as a dispatch-only notice stub so stale
    /// clients receive a clear explanation rather than a methodNotFound error.
    /// Never listed in tools/list; never executes regardless of arguments.
    static let recollectToolName = "moot_recollect"

    // MARK: - Contract-change notice texts
    //
    // These strings are wire text: they must be byte-identical between Swift
    // and Rust (see packages/kits/AriaMcpKit/rust/src/recipe_tools.rs).

    /// Notice returned when moot_recall_distilled is called without the correct
    /// ack token. Instructs the caller to reissue with ack: "recall_distilled/v2".
    static let recallDistilledContractNotice = #"CONTRACT CHANGE NOTICE: you called moot_recall_distilled. Its behavior changed: v2 returns normal exact-search results hydrated with distilled representations; it no longer queries a separate distilled tier; run moot_distill first if rows are undistilled. If the new behavior is what you want, reissue with ack: "recall_distilled/v2"."#

    /// Notice returned for every call to the removed moot_recollect tool.
    /// Returned regardless of any argument the caller supplies.
    static let recollectRemovedNotice = "moot_recollect was removed: its substrate (factoid drawers) was retired; recall hits now ARE source drawers; use moot_memory_search or moot_recall_distilled."
    /// On-demand contradiction hunt: one bounded sweep of the content-driven
    /// contradiction detector (BM25 lexical candidates + ConflictCue screen). Strong
    /// findings persist as proposed contradicts tunnels; borderline pairs are
    /// returned for the calling agent to adjudicate.
    static let huntContradictionsToolName = "moot_hunt_contradictions"

    /// True when `name` is one of the foundational recipe tools dispatched by name.
    ///
    /// Includes `moot_recollect` (notice-only stub — never executes) and the
    /// listed recipe tools.
    static func isRecipeTool(_ name: String) -> Bool {
        name == listRecipesToolName
            || name == listRecipesCatalogToolName
            || name == groundedSynthesisToolName
            || name == preciseRecallToolName
            || name == vagueRecallToolName
            || name == shapedRecallToolName
            || name == connectedRecallToolName
            || name == runMigrationBenchmarkToolName
            || name == confirmMigrationPromotionToolName
            || name == dreamToolName
            || name == distillToolName
            || name == recallDistilledToolName
            || name == recollectToolName
            || name == huntContradictionsToolName
    }

    // MARK: - tools/list projection

    /// All foundational recipe tool descriptors, advertised in `tools/list`
    /// after the lexicon projection and the federation tool. The analytics
    /// and reasoning-lens tools are projected by LensTools.
    static func tools() -> [ProjectedTool] {
        [
            listRecipesTool(),
            listRecipesCatalogTool(),
            groundedSynthesisTool(),
            preciseRecallTool(),
            shapedRecallTool(),
            connectedRecallTool(),
            runMigrationBenchmarkTool(),
            confirmMigrationPromotionTool(),
            dreamTool(),
            distillTool(),
            recallDistilledTool(),
            vagueRecallTool(),
            huntContradictionsTool(),
        ]
    }

    /// The roster listing the shaped-recall tool advertises in its description:
    /// one `name — description` line per preset, built from the GLK roster so a
    /// new preset is reflected automatically. This is the "AI lists the roster"
    /// surface — name + one-line description + which signals it emphasizes.
    private static func presetRosterListing() -> String {
        RecallShape.presetNames
            .map { "\($0) — \(RecallShape.presetDescription($0))" }
            .joined(separator: "; ")
    }

    /// The shaped-recall tool. Runs the ShapedRecall recipe with a named
    /// RecallShape preset applied — one tool, a discoverable `preset` enum, the
    /// full roster in the description. Returns results in the same plain-text
    /// shape `moot_memory_search` uses so existing mootText parsers work unchanged.
    /// The four ARIA filtering adjectives compose orthogonally: the preset RANKS,
    /// the `filter` arg FILTERS.
    private static func shapedRecallTool() -> ProjectedTool {
        ProjectedTool(
            name: shapedRecallToolName,
            description: "Shaped recall: run recall with a named RecallShape preset that forwards, excludes, suppresses, or inverts individual fusion lanes (and bounds the candidate frontier). Pick ONE preset by name. Roster: \(presetRosterListing()). Accepts near:<uuid> instead of query to fan out from an anchor memory under the chosen preset. Returns dense rows in the same shape as moot_memory_search; a discrimination line appears only when the signal is low/medium (expected for associative/conceptual presets on small estates — switch to moot_recall_precise for precision).",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema("The search query text — drives BM25 + vector recall. Provide query OR near — exactly one."),
                    "near": stringSchema("UUID of an anchor memory — returns the memories most similar to it under the preset (the anchor itself is excluded). Alternative to query; pass exactly one of the two."),
                    "preset": .object([
                        "type": .string("string"),
                        "description": .string("The RecallShape preset to apply (how to steer the fusion). One of the roster names. balanced (or an omitted preset) is the unsteered default. Unknown names are rejected."),
                        // Discoverable enum: the exact roster the GLK ships.
                        "enum": .array(RecallShape.presetNames.map { .string($0) }),
                    ]),
                    "limit": integerSchema("Max ranked matches to return. Default 20. Omit to use the default; null is invalid."),
                    "filter": stringSchema("Filter kind: unconfirmed, userConfirmed, exportable, contained, currentlyBelieve. Omit for ordinary active recall across any confirmation state. null is invalid. Composes orthogonally with the preset — the preset ranks, the filter filters."),
                    "wing": stringSchema("Optional wing name to scope recall to a single wing. Omit to search across all wings. Example: \"Agentic Memory\", \"Source Corpus\". null is invalid."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate; null is invalid."),
                ],
                required: []),
            provenance: .recipe,
            outputSchema: ToolProjection.recallResultsOutputSchema())
    }

    /// The cognition-discovery tool. At runtime (`runListRecipes`), returns
    /// one block per Tier 6 tool drawn from `LensTools.tools()` and the four
    /// Tier 6 recipe tools (`moot_list_lenses`, `moot_synthesize`,
    /// `moot_recall_precise`, `moot_recall_shaped`) — not `RecipeCatalog`.
    /// Takes no arguments; it is the conscious mind enumerating its surface.
    private static func listRecipesTool() -> ProjectedTool {
        ProjectedTool(
            name: listRecipesToolName,
            description: "List the available reasoning lenses and CognitionKit behaviour recipes. Terse by default (name + one-liner per tool); pass verbose:true for full descriptions and required arguments.",
            inputSchema: objectSchema(
                properties: [
                    "verbose": .object([
                        "type": .string("boolean"),
                        "description": .string("Full catalogue with complete descriptions and required args. Omit for the terse default; null is invalid."),
                    ]),
                ],
                required: []),
            provenance: .recipe)
    }

    /// Catalog discovery tool: returns name, version, description, and required
    /// capabilities for every shipped recipe in `RecipeCatalog.all` order.
    /// Hard-codes nothing; reads the catalog directly so new registrations are
    /// automatically reflected.
    private static func listRecipesCatalogTool() -> ProjectedTool {
        ProjectedTool(
            name: listRecipesCatalogToolName,
            description: "List every shipped CognitionKit recipe in catalog order. Terse by default (name, version, one-liner); pass verbose:true for full descriptions and required capabilities.",
            inputSchema: objectSchema(
                properties: [
                    "verbose": .object([
                        "type": .string("boolean"),
                        "description": .string("Full catalogue with complete descriptions and capabilities. Omit for the terse default; null is invalid."),
                    ]),
                ],
                required: []),
            provenance: .recipe)
    }

    private static func groundedSynthesisTool() -> ProjectedTool {
        ProjectedTool(
            name: groundedSynthesisToolName,
            description: "Synthesize memories into a grounded context document: hybrid-recall and summarise into patterns, success rate, recommendations, and key insights.",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema("Free-text cue that grounds the synthesis: distinctive terms are extracted and matched (OR, case-insensitive) against memory content, so only cue-relevant memories feed the document. Omit to synthesize over the whole recalled set (an estate digest); null is invalid."),
                    "filter": stringSchema("Filter kind: unconfirmed, userConfirmed, exportable, contained, currentlyBelieve, hasLinks. Omit for ordinary recall across any confirmation state. \"hasLinks\" scopes synthesis to drawers with links/citations — citation-scoped synthesis. Composes (AND) with query when both are given. null is invalid."),
                    "limit": integerSchema("Max drawers to recall. Omit for no explicit cap; null is invalid."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate; null is invalid."),
                ],
                required: []),
            provenance: .recipe)
    }

    /// The precise-recall tool. Runs the PreciseRecall recipe: a generous
    /// coarse grab (matrixAware/unionBest, same lane as moot_memory_search)
    /// re-ranked by query-specific precision so the EXACT answer rises above
    /// its near-duplicate distractors. Returns results in the same plain-text
    /// shape moot_memory_search uses (`found N memory(s)` then one ranked
    /// line per hit) so existing mootText parsers work unchanged. Distinct
    /// from moot_memory_search, which is the fetch-only verb (left intact).
    private static func preciseRecallTool() -> ProjectedTool {
        ProjectedTool(
            name: preciseRecallToolName,
            description: "Precise recall: coarse-grab a generous candidate pool then re-rank by query-specific precision (distinctive number/proper-noun match) to surface the exact answer above near-duplicates. Lifts found@1/MRR without dropping found@10. Returns dense rows in the same shape as moot_memory_search; a discrimination line appears only when the signal is low/medium. Use when you need a specific known-token answer — exact names, numbers, identifiers — especially on small estates where semantic/associative modes produce low discrimination. This is the recommended mode when the discrimination signal from moot_memory_search or moot_recall_shaped is low.",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema("The search query text — drives BM25 + vector recall and the precision re-rank."),
                    "limit": integerSchema("Max ranked matches to return. Default 20. Omit to use the default; null is invalid."),
                    "pool": integerSchema("Coarse candidate-pool size grabbed before the precision re-rank. Default 30; clamped to be at least limit. Omit to use the default; null is invalid."),
                    "composition": stringSchema("Named reduction composition selecting how the coarse pool is re-ranked (the ablation selector). E.g. text (default), hamming, matrix, lattice, tokenExact, hamming+tokenExact, hamming+text, text+matrix, lattice+hamming, text+tokenExact, text+mmr, weighted-all. Omit for the default (text). Unknown names and null are rejected."),
                    "filter": stringSchema("Filter kind: unconfirmed, userConfirmed, exportable, contained, currentlyBelieve. Omit for ordinary active recall across any confirmation state. null is invalid."),
                    "wing": stringSchema("Optional wing name to scope recall to a single wing. Omit to search across all wings. Example: \"Agentic Memory\", \"Source Corpus\". null is invalid."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate; null is invalid."),
                ],
                required: ["query"]),
            provenance: .recipe,
            outputSchema: ToolProjection.recallResultsOutputSchema())
    }

    /// The connected-recall tool. Runs the ConnectedRecall recipe: a scored
    /// anchor grab seeds a deterministic walk-with-restart over the estate's
    /// connection graph — tunnels (validated) plus dream-produced pending
    /// associations — and the walk's visit ranking fuses with the anchor
    /// ranking. Same output shape as moot_memory_search.
    private static func connectedRecallTool() -> ProjectedTool {
        ProjectedTool(
            name: connectedRecallToolName,
            description: "Connected recall: multi-hop retrieval by graph diffusion. A scored anchor search seeds a deterministic random walk with restart over the estate's connection structure (tunnels plus pending associations), reaching bridge-linked memories that share no words with the query; the walk's visit ranking is fused with the anchor ranking. This is the EXPENSIVE recall path — use it for hard bridge questions (\"what did X's sister study\" when the sister's name only appears in the estate) after the similarity lanes (moot_memory_search, moot_recall_precise, moot_recall_shaped) miss. Returns dense rows in the same shape as moot_memory_search plus a lane-provenance summary line.",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema("The question text — drives the scored anchor search that seeds the walk."),
                    "wing": stringSchema("Optional wing whose tunnel graph joins the walk. Omit to walk pending associations only (tunnels are wing-scoped; associations are estate-wide). null is invalid."),
                    "limit": integerSchema("Max ranked matches to return. Default 20. Omit to use the default; null is invalid."),
                    "filter": stringSchema("Filter kind: unconfirmed, userConfirmed, exportable, contained, currentlyBelieve. Omit for ordinary active recall across any confirmation state. null is invalid."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate; null is invalid."),
                ],
                required: ["query"]),
            provenance: .recipe,
            outputSchema: ToolProjection.recallResultsOutputSchema())
    }

    private static func vagueRecallTool() -> ProjectedTool {
        ProjectedTool(
            name: vagueRecallToolName,
            description: "Vague recall (two-hop): ponder what the estate vaguely remembers. Hop 1 probes the consolidated vague tier's own fingerprint lane for VAGUE summary items; hop 2 hydrates each hit's original constituent memories through _consolidated_from tunnels (bounded per hit and in total). Use when normal recall is thin and the question is old — aged, similar memories may have consolidated into a vague summary whose originals remain fully preserved. Returns the vague summaries first, then the hydrated originals.",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema("The recall query text — fingerprinted for the vague-tier lane probe."),
                    "hit_limit": integerSchema("Max vague summary items from hop 1. Default 8. Omit for the default; null is invalid."),
                    "constituents_per_hit": integerSchema("Max original memories hydrated per vague hit (bound K). Default 8. Omit for the default; null is invalid."),
                    "total_constituents": integerSchema("Max original memories hydrated overall (bound M). Default 32. Omit for the default; null is invalid."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate; null is invalid."),
                ],
                required: ["query"]),
            provenance: .recipe)
    }

    private static func runMigrationBenchmarkTool() -> ProjectedTool {
        ProjectedTool(
            name: runMigrationBenchmarkToolName,
            description: "Run a migration benchmark: derive COW branches, populate from origin corpus, benchmark recall fidelity, and rank survivors. Returns branch ids for a separate confirm step. Never promotes automatically.",
            inputSchema: objectSchema(
                properties: [
                    "corpusName": stringSchema("Human-readable name for the origin corpus."),
                    "entries": .object([
                        "type": .string("array"),
                        "description": .string("Origin entries: objects with string fields id, content, and a string-array field tags."),
                        "items": objectSchema(
                            properties: [
                                "id": stringSchema("Stable source id."),
                                "content": stringSchema("Verbatim content."),
                                "tags": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("string")]),
                                ]),
                            ],
                            required: ["id", "content"]),
                    ]),
                    "plans": .object([
                        "type": .string("array"),
                        "description": .string("Candidate plans: objects with string fields name, room, latticeCode, embeddingModelID, and optional sensitivity (normal/elevated/restricted/secret)."),
                        "items": objectSchema(
                            properties: [
                                "name": stringSchema("Plan name (also the branch name)."),
                                "room": stringSchema("Room every migrated drawer is filed into."),
                                "latticeCode": stringSchema("UDC lattice code for every migrated drawer."),
                                "embeddingModelID": stringSchema("Embedding model id tagged on every drawer."),
                                "sensitivity": stringSchema("Optional sensitivity tier; default normal."),
                            ],
                            required: ["name", "room", "latticeCode", "embeddingModelID"]),
                    ]),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: ["corpusName", "entries", "plans"]),
            provenance: .recipe)
    }

    private static func confirmMigrationPromotionTool() -> ProjectedTool {
        ProjectedTool(
            name: confirmMigrationPromotionToolName,
            description: "Confirm a migration: promote the winning branch into the estate and discard the losers, by branch id. Refuses to promote any branch the run report disqualified.",
            inputSchema: objectSchema(
                properties: [
                    "winnerBranchID": stringSchema("UUID of the winning branch to promote (from the run report)."),
                    "discardBranchIDs": .object([
                        "type": .string("array"),
                        "description": .string("UUIDs of losing branches to discard."),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: ["winnerBranchID"]),
            provenance: .recipe)
    }

    /// The on-demand dream tool. Rebuilds the estate's derived accelerators
    /// (the matrix tier — co-occurrence and temporal causality — that the
    /// `matrix`/`coOccurrence` recall lanes score against) and runs one
    /// dreaming cycle (latent-alignment proposals + the cycle diary). Returns a
    /// small cycle summary. Idempotent: re-running over unchanged estate state
    /// rebuilds the same matrix and emits no duplicate proposals.
    private static func dreamTool() -> ProjectedTool {
        ProjectedTool(
            name: dreamToolName,
            description: "Dream the estate: rebuild the co-occurrence/temporal matrix tier (the Brain's association layer that the matrix recall lane scores against), run one dreaming cycle (latent-alignment proposals + cycle diary), run one contradiction-hunt sweep (content screen over lexically-near memory pairs; strong conflicts persist as PROPOSED contradicts links for review), file tier-labeled conflict-tunnel candidates across all three contradiction tiers (typed proof, structural lexical cue, value divergence — surviving the decline matrix), and optionally run one vector-similarity association sweep (proximity-based edge mining). The matrix is built by dreaming, not by capture, so a freshly-loaded estate has an empty matrix until this runs. Returns a cycle summary including contradiction, candidate-filing, and association counts plus a tiered synthesis digest.",
            inputSchema: objectSchema(
                properties: [
                    "now": stringSchema("Optional ISO8601 instant to run the cycle at, for deterministic runs (drives the diary timestamp and the reward window). Omit to use the current wall clock."),
                    "associates": stringSchema("Association sweep mode: 'all' = probe every item in the estate (full coverage, for post-import runs), 'recent' = probe the 50 most-recently-filed items (default, fast), 'off' = skip the association sweep entirely."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: []),
            provenance: .recipe)
    }

    // MARK: - hunt-contradictions descriptor

    /// The on-demand contradiction hunt. One bounded sweep of the
    /// content-driven detector: kNN candidate mining over the estate's
    /// vector index, then the deterministic ConflictCue screen. Strong
    /// findings persist as `contradicts` tunnels with lifecycle PROPOSED
    /// (reviewable via `moot_review_tunnel`, surfaced by
    /// `moot_lens_contradiction`); borderline pairs are returned with
    /// content snippets so the CALLING AGENT judges them — the
    /// adjudication feed for paraphrased conflicts the lexical screen
    /// cannot settle.
    private static func huntContradictionsTool() -> ProjectedTool {
        ProjectedTool(
            name: huntContradictionsToolName,
            description: "Hunt for contradictions in memory content: one bounded sweep that finds lexically-near memory pairs via the corpus keyword (BM25) index and screens them for lexical conflict (negation asymmetry, same-template value divergence, revision markers). Strong findings are persisted as PROPOSED contradicts links (review with moot_lens_contradiction, accept/reject with moot_review_tunnel; rejected pairs are never re-proposed). Borderline pairs are RETURNED with snippets for YOU to judge — if a pair genuinely conflicts, record it with moot_link_memories kind=contradicts proposed=true. With tier absent or \"all\", the sweep report is followed by a tiered synthesis digest (TIER 1 typed proofs, TIER 2 structural lexical cues, TIER 3 value divergence); with tier 1, 2, or 3 the call is a read-only purpose search of that lane alone — nothing is filed. Requires the corpus search index (run moot_reindex after bulk import).",
            inputSchema: objectSchema(
                properties: [
                    "probe_limit": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Maximum vector-indexed memories probed this sweep (default 500). "
                                + "Repeated calls converge: settled pairs are skipped."),
                    ]),
                    // Union domain (integer 1|2|3 or the string "all"), so no
                    // "type" key — the description carries the domain and the
                    // dispatch boundary validates it. Declared IDENTICALLY in
                    // the Rust twin (tool_list.rs hunt_contradictions_tool).
                    "tier": .object([
                        "description": .string(
                            "Optional tier filter: 1 (typed proven contradictions), "
                                + "2 (structural lexical conflict candidates), 3 (value "
                                + "divergence), or \"all\" (default — legacy sweep plus "
                                + "tiered synthesis digest). A single tier runs a "
                                + "read-only purpose search of that lane alone."),
                    ]),
                    "top_k": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Findings per tier section in the tiered digest "
                                + "(default 5, valid 1...50)."),
                    ]),
                    "now": stringSchema("Optional ISO8601 instant for deterministic runs. Omit to use the current wall clock."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: []),
            provenance: .recipe)
    }

    // MARK: - distill descriptor

    /// On-demand per-item distillation sweep (SPEC §3/§7.1). Delegates all
    /// work to the Distill recipe → GeniusLocusKit.distillItemsSweep, which
    /// populates the four representation columns on every eligible SOURCE
    /// drawer row (matrix path for ≥3 sentences, token compaction for
    /// shorter items). No factoid drawers, no tunnels. The `cluster_id` and
    /// `include_held` args are accepted for API stability but are not used
    /// by the per-item sweep model.
    private static func distillTool() -> ProjectedTool {
        ProjectedTool(
            name: distillToolName,
            description: "Distill working memory: populate the on-row distilled "
                + "representation (token-economical prose) of every active item whose "
                + "representation is missing or stale. Idempotent — already-distilled "
                + "items are skipped. Returns the count of items distilled this sweep.",
            inputSchema: objectSchema(
                properties: [
                    "cluster_id": stringSchema(
                        "Accepted for API stability; not used by the per-item sweep model."),
                    "include_held": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Accepted for API stability; not used by the per-item sweep model. "
                                + "Default false."),
                    ]),
                    "estateID": stringSchema(
                        "Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: []),
            provenance: .recipe)
    }

    // MARK: - recall_distilled descriptor

    /// Distilled-payload recall (SPEC §10.3): the exact-search recall path
    /// with the hydration selector pinned to `distilled`. Ranking is
    /// identical to moot_memory_search by construction; only payloads
    /// differ (smaller), with per-hit token counts for context budgeting.
    ///
    /// ACK-GATED: this tool's contract changed in Wave 1 (v2 semantics — exact-
    /// search geometry + distilled hydration, not a separate distilled tier).
    /// Calls without ack: "recall_distilled/v2" return a CONTRACT CHANGE NOTICE
    /// and do not execute. Pass ack: "recall_distilled/v2" to proceed.
    private static func recallDistilledTool() -> ProjectedTool {
        ProjectedTool(
            name: recallDistilledToolName,
            description: "Distilled recall (v2): normal search over originals, hydrated with "
                + "each hit's DISTILLED representation (token-economical prose) instead of "
                + "the full content — identical ranking to moot_memory_search, smaller "
                + "payloads, per-hit token counts for context budgeting. Hits are the "
                + "source memories themselves; call moot_memory_get with a returned id for "
                + "the full verbatim body. Rows not yet distilled fall back to full "
                + "content and are marked served_from_content (run moot_distill to "
                + "populate them). CONTRACT CHANGE (Wave 1): v2 no longer queries a "
                + "separate distilled tier; pass ack: \"recall_distilled/v2\" to confirm "
                + "you want the new behavior.",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema(
                        "Query text — drives BM25 + vector recall (same geometry as moot_memory_search)."),
                    "limit": integerSchema(
                        "Max results to return. Default 20. Omit to use the default; "
                            + "null is invalid."),
                    "filter": stringSchema(
                        "Filter kind: unconfirmed, userConfirmed, exportable, contained, "
                            + "currentlyBelieve. Omit for ordinary recall across any confirmation "
                            + "state. null is invalid."),
                    "echo_query": ToolProjection.booleanSchema(
                        "Optional. When true, appends the query text to the response header. "
                            + "Default false — the AI already knows what it queried. "
                            + "Omit to use the default; null is invalid."),
                    "ack": stringSchema(
                        "Contract-change acknowledgment token. This tool's behavior changed "
                            + "in Wave 1 (v2 semantics). Pass ack: \"recall_distilled/v2\" to "
                            + "confirm you want v2 behavior (normal exact-search geometry + "
                            + "distilled hydration). Without this token the call returns a "
                            + "CONTRACT CHANGE NOTICE and does not execute."),
                    "estateID": stringSchema(
                        "Optional UUID of the open estate to target. Omit for the default estate; "
                            + "null is invalid."),
                ],
                required: ["query"]),
            provenance: .recipe)
    }

    // MARK: - Dispatch

    /// Run the named recipe tool. `resolveHandle` is the dispatcher's own
    /// estateID→handle resolver (absent estateID ⇒ default handle), passed
    /// in so recipe tools honour the same multi-estate routing as lexicon
    /// tools. Out-of-band faults throw `JSONRPCError`; recipe-level
    /// refusals come back as `errorResult` (isError == true) so the client
    /// keeps the call id, matching the lexicon-tool discipline.
    static func dispatch(
        name: String,
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        defaultHandle: EstateHandle,
        resolveHandle: ([String: JSONValue]) throws -> EstateHandle
    ) async throws -> JSONValue {
        // Recipe discovery needs no estate; answer before resolving a handle
        // so discovery tools work even with no estate targeted.
        if name == listRecipesToolName {
            return try runListRecipes(args)
        }
        if name == listRecipesCatalogToolName {
            return try runListRecipesCatalog(args)
        }

        // MARK: ACK gates and notice-only stubs
        // These checks must come BEFORE resolveHandle() to guarantee zero
        // side effects when a caller hits a contract-change notice.

        // moot_recollect — notice-only stub. The tool was removed in Wave 1;
        // its substrate (factoid drawers) was retired. Never executes regardless
        // of what parameters are passed.
        if name == recollectToolName {
            return ToolDispatcher.textResult(recollectRemovedNotice)
        }

        // moot_recall_distilled — ACK-gated (v2 contract). Now performs normal
        // exact-search geometry + distilled hydration; no longer queries a
        // separate distilled tier. Callers must pass ack: "recall_distilled/v2".
        if name == recallDistilledToolName,
           args["ack"]?.stringValue != "recall_distilled/v2" {
            return ToolDispatcher.textResult(recallDistilledContractNotice)
        }

        let handle = try resolveHandle(args)
        switch name {
        case groundedSynthesisToolName:
            return try await runGroundedSynthesis(args, kit: kit, handle: handle)
        case preciseRecallToolName:
            return try await runPreciseRecall(args, kit: kit, handle: handle)
        case connectedRecallToolName:
            return try await runConnectedRecall(args, kit: kit, handle: handle)
        case vagueRecallToolName:
            return try await runVagueRecall(args, kit: kit, handle: handle)
        case shapedRecallToolName:
            return try await runShapedRecall(args, kit: kit, handle: handle)
        case runMigrationBenchmarkToolName:
            return try await runMigrationBenchmark(args, kit: kit, handle: handle)
        case confirmMigrationPromotionToolName:
            return try await runConfirmPromotion(args, kit: kit, handle: handle)
        case dreamToolName:
            return try await runDream(args, kit: kit, handle: handle)
        case distillToolName:
            return try await runDistill(args, kit: kit, handle: handle)
        case recallDistilledToolName:
            // Reaches here only when ack: "recall_distilled/v2" was present.
            return try await runRecallDistilled(args, kit: kit, handle: handle)
        case huntContradictionsToolName:
            return try await runHuntContradictions(args, kit: kit, handle: handle)
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown recipe tool: \(name)")
        }
    }

    // MARK: - list_lenses (cognition menu)

    /// Return a one-block-per-tool cognition menu drawn from the shipped
    /// `ProjectedTool` descriptors. Shows name, description, and required
    /// args for each Tier 6 cognition tool — the 23 lens tools plus four
    /// recipe tools (`moot_list_lenses`, `moot_synthesize`,
    /// `moot_recall_precise`, `moot_recall_shaped`) for 27 total.
    /// Migration and distillation tools (Tier 7) are intentionally excluded;
    /// they have their own teachme guides and a separate caller workflow.
    /// Decode the shared `verbose` flag for the two catalogue tools
    /// (PR-04). Absent → false (terse default); present-but-non-bool →
    /// invalidParams (omit-to-default contract).
    private static func decodeVerbose(_ args: [String: JSONValue]) throws -> Bool {
        guard let raw = args["verbose"] else { return false }
        guard let b = raw.boolValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "verbose must be a boolean; omit it for the terse default")
        }
        return b
    }

    /// First sentence of a tool description, for the terse catalogue rows
    /// (PR-04). Deterministic and byte-identical to the Rust twin: cut at
    /// the first ". " boundary, keeping the period.
    static func oneLiner(_ description: String) -> String {
        if let range = description.range(of: ". ") {
            return String(description[..<range.lowerBound]) + "."
        }
        return description
    }

    private static func runListRecipes(_ args: [String: JSONValue]) throws -> JSONValue {
        let verbose = try decodeVerbose(args)
        // Tier 6 recipe tools: list-lenses + synthesize + precise recall + shaped
        // recall (not migration or distillation, which are Tier 7).
        let tier6RecipeNames: Set<String> = [
            listRecipesToolName, groundedSynthesisToolName,
            preciseRecallToolName, shapedRecallToolName,
        ]
        let recipeTools = tools().filter { tier6RecipeNames.contains($0.name) }
        // All 23 lens tools from LensTools.
        let lensTools = LensTools.tools()
        let cognitionTools = recipeTools + lensTools

        var lines: [String] = ["\(listRecipesToolName): \(cognitionTools.count) cognition tools"]
        if verbose {
            for tool in cognitionTools {
                let required = requiredArgNames(from: tool.inputSchema)
                let requiredText = required.isEmpty ? "none" : required.joined(separator: ", ")
                lines.append("")
                lines.append(tool.name)
                lines.append("  \(tool.description)")
                lines.append("  Required: \(requiredText).")
            }
            lines.append("")
        } else {
            // Terse default (PR-04): one row per tool — name and first
            // sentence. The always-verbose ~8.8KB catalogue reply ends;
            // pass verbose:true for full descriptions + required args.
            for tool in cognitionTools {
                lines.append("\(tool.name) — \(Self.oneLiner(tool.description))")
            }
            lines.append("(terse — pass verbose:true for full descriptions and required args)")
        }
        lines.append("Call any tool with teachme:true for a full usage guide.")
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    /// Return every shipped recipe from `RecipeCatalog.all` — name, version,
    /// description, and required NeuronKit capabilities — in catalog order.
    /// Reads the catalog directly; hard-codes nothing. Terse by default
    /// (PR-04); verbose:true restores the full per-recipe block.
    private static func runListRecipesCatalog(_ args: [String: JSONValue]) throws -> JSONValue {
        let verbose = try decodeVerbose(args)
        let catalog = RecipeCatalog.all
        var lines: [String] = ["\(listRecipesCatalogToolName): \(catalog.count) recipe(s)"]
        if verbose {
            for recipe in catalog {
                lines.append("")
                lines.append(recipe.name)
                lines.append("  version: \(recipe.version)")
                lines.append("  \(recipe.description)")
                let caps = recipe.requiredCapabilities.map { "\($0)" }
                lines.append("  requires: \(caps.isEmpty ? "none" : caps.joined(separator: ", "))")
            }
        } else {
            for recipe in catalog {
                lines.append("\(recipe.name) \(recipe.version) — \(Self.oneLiner(recipe.description))")
            }
            lines.append("(terse — pass verbose:true for versions, capabilities, and full descriptions)")
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    /// Extract required argument names from a JSON Schema `required` array.
    private static func requiredArgNames(from schema: JSONValue) -> [String] {
        schema.objectValue?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    // MARK: - grounded_synthesis

    /// Maximum frame limit for grounded-synthesis cue-pool recall. When a
    /// query is present the FRAME widens to this bound so the lexical RRF
    /// lane can rank the full matched pool before the user limit caps synthesis.
    /// The contentMatches filter already scopes the pool; this constant only
    private static func runGroundedSynthesis(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let filterChain = try decodeFilterChain(args["filter"])
        // query — the grounding cue the recipe contract promises
        // ("hybrid-recall a QUERY and synthesize", GroundedSynthesis.swift).
        // The dispatch layer extracts the distinctive terms and validates;
        // the RECIPE owns both grounding lanes (the lexical cue predicate
        // and the scored BM25+vector search over the raw query) plus the
        // pool bounds — this layer passes the base kind-filter frame, the
        // raw query, the terms, and the user limit as the post-rank cap.
        // A query whose every token is a stopword is rejected rather than
        // silently ignored — a caller who sent a cue must never receive an
        // unscoped estate digest.
        let query = try optionalString(args["query"], argument: "query")
        var cueTerms: [String] = []
        if let query {
            let terms = groundingTerms(from: query)
            guard !terms.isEmpty else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "query contains no usable terms (all tokens are "
                    + "stopwords or too short); provide distinctive words to "
                    + "ground on")
            }
            cueTerms = terms
        }
        // Route through clampLimit so negative and over-ceiling values are
        // rejected/clamped at the MCP boundary. Parity: Rust recipe_tools.rs
        // run_grounded_synthesis_tool uses clamp_limit with the same ceiling.
        let userLimit = try ToolDispatcher.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        // Grounded runs pass the user limit as the recipe cap (synthesis is
        // bounded even when the recipe widens its lane pools); digest runs
        // keep the frame-limit semantics unchanged.
        let recipeCap: Int? = cueTerms.isEmpty ? nil : userLimit
        let frame = LocusKit.RecallFrame(
            filterChain: filterChain,
            hydrationLevel: .structured,
            limit: userLimit,
            ordering: .byCaptureTimeDesc)

        // excludeProvenanceSensitive: true silently removes rows whose
        // provenance sensitivity (bits 30–35) is Restricted or Secret before
        // the synthesizer runs. This is pool-removal, not redaction: the
        // output count reflects only surviving rows, and no redaction marker
        // appears in the response. This differs from the search surface
        // (moot_memory_search / moot_recall_precise) which emits a visible
        // "⛔ restricted" marker where a gated row would otherwise appear.
        // The RecallFrame adjective filter (bits 6–11) does not cover
        // provenance bits; this gate is the explicit provenance axis check.
        // See ToolDispatch.swift near_anchor: comments for the near-anchor
        // variant, which uses the same provenance-first ordering discipline.
        let out = try await GroundedSynthesis().run(
            input: .init(
                frame: frame,
                cueTerms: cueTerms,
                cap: recipeCap,
                query: query,
                excludeProvenanceSensitive: true),
            estate: handle, kit: kit)

        let doc = out.context
        // The cue is part of the document's identity: a grounded synthesis
        // and an estate digest are different measurements, so the response
        // names which one it is (line appears only when a query was given).
        let queryLine = query.map { "query: \($0)\n" } ?? ""
        let body = """
        grounded_synthesis: \(out.drawerCount) drawer(s)
        \(queryLine)summary: \(doc.summary)
        patterns: \(doc.patterns.joined(separator: ", "))
        successRate: \(doc.successRate)
        recommendations:
        \(doc.recommendations.map { "  - \($0)" }.joined(separator: "\n"))
        keyInsights:
        \(doc.keyInsights.map { "  - \($0)" }.joined(separator: "\n"))
        """
        return ToolDispatcher.textResult(body)
    }

    // MARK: - recall_precise

    /// Run the PreciseRecall recipe and serialize its matches in the SAME
    /// plain-text shape `moot_memory_search` emits: a `found N memory(s)`
    /// header line then up to `prefix(50)` `id  [room]  preview` lines.
    /// Mirroring that shape (including the 120-char content preview) keeps
    /// every mootText parser — the gauntlet's included — working unchanged.
    ///
    /// Composition validation is fail-CLOSED: an absent `composition` arg maps
    /// to nil → the recipe default (`text`), reproducing existing behavior.
    /// A present-but-unknown name is a caller error — the access surface rejects
    /// it with a tool error (isError: true) instead of silently degrading to
    /// `text` and returning surprising results under a name the caller did not
    /// realize was ignored.
    /// Parity: mirrors the Rust boundary contract (94a62696,
    /// `recall_precise_unknown_composition_fails_closed`).
    private static func runPreciseRecall(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let query = try requireString(args, "query")
        // Clamp to [1, 500]: reject negative/zero, cap absurdly-large values.
        // DoS prevention at the MCP boundary before the substrate is touched.
        // Parity: Rust run_precise_recall_tool uses clamp_limit with same ceiling.
        let limit = try ToolDispatcher.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        // Default coarse pool is CognitionKit's own default (30); honour an
        // explicit override. The recipe clamps pool >= limit internally.
        // Pool is also clamped: an unbounded pool drives an unbounded substrate scan.
        let pool = try ToolDispatcher.clampLimit(
            try optionalInt(args["pool"], argument: "pool"),
            argument: "pool",
            default: CognitionKit.PreciseRecall.defaultPool)
        // optional `wing` scopes recall to a single wing.
        // When present, compose with the explicit filter via Filter.all so both
        // constraints apply. When absent, the filter arg stands alone.
        let baseFilter = try decodeSingleFilter(args["filter"])
        let filter: LocusKit.Filter
        if let wingName = try optionalString(args["wing"], argument: "wing") {
            filter = .all([baseFilter, .inWing(wingName)])
        } else {
            filter = baseFilter
        }
        // The ablation selector: a named reduction composition.
        //   Absent  → nil → the recipe's default (`text`); absence ≠ unknown.
        //   Present → validated against the grid; unknown name → fail closed
        //             (tool error, not silent fall-through). The grid is the
        //             authoritative name set; callers that supply a bad name
        //             receive an explicit error rather than opaque text results.
        let composition: String?
        if let rawComposition = try optionalString(args["composition"], argument: "composition") {
            guard NeuronKit.CompositionGrid.names.contains(rawComposition) else {
                let valid = NeuronKit.CompositionGrid.names.joined(separator: ", ")
                return ToolDispatcher.errorResult(
                    "unknown composition '\(rawComposition)'; valid names: \(valid)")
            }
            composition = rawComposition
        } else {
            composition = nil
        }

        let matches = try await PreciseRecall.run(
            kit: kit, handle: handle, query: query,
            filter: filter, limit: limit, pool: pool, composition: composition)

        // Part 1a — distinctive-token containment gate.
        //
        // When the query carries distinctive tokens (numbers or proper nouns)
        // but NO returned candidate's content contains any of those tokens, the
        // result set is a confident NON-match: the re-ranker produced a ranked
        // list of things that are definitively NOT the queried entity. Returning
        // that list as-is would cause the calling AI to confidently report the
        // wrong answer. Instead: suppress results and emit not_found so the
        // caller knows to widen the search or confirm the content exists.
        //
        // When the query has NO distinctive tokens we cannot apply the gate
        // (every word is a stopword / generic term that cannot be required to be
        // present) — but we emit a coaching hint so the calling AI knows the
        // recall may be indiscriminate.
        let candidateContents = matches.map { $0.content }
        let hasDistinctive = NeuronKit.hasDistinctiveTokens(query)
        let satisfied = NeuronKit.containmentSatisfied(query: query, candidateContents: candidateContents)

        if hasDistinctive && !satisfied {
            // Containment gate fired — return zero results with not_found.
            // The structured block is the empty results array: the tool
            // declares an outputSchema, so every success reply carries the
            // typed twin, including the deliberate zero-result shape.
            let lines: [String] = [
                "found 0 memory(s)",
                RecallDiscrimination.resultLine(for: .notFound),
            ]
            return ToolDispatcher.structuredTextResult(
                lines.joined(separator: "\n"), results: [])
        }

        // Part 1b — discrimination is computed over composition precision
        // scores (PreciseMatch.score = candidate.precisionScore from the
        // weighted-sum fold), not the coarse fusion score, so the level
        // reflects re-rank quality rather than coarse-grab noise.
        let preciseScores = matches.map { $0.score }
        let preciseDiscrimination = RecallDiscrimination.classify(preciseScores)

        // Dense-row reply (PR-03): same row shape as moot_memory_search.
        // MXE-SS: ONE structured-tier fetch through the same gate feeds BOTH
        // blocks — the dense text rows (rendered locally, byte-identical to
        // the former denseRowsByID output: same admissible set, same
        // DenseRow.render) and the typed structured rows.
        let estate = try await kit.estate(for: handle)
        let shownMatches = Array(matches.prefix(50))
        let drawersByID = try await structuredDrawersByID(
            ids: shownMatches.map { $0.id }, estate: estate)
        let denseByID = drawersByID.mapValues { DenseRow.render($0) }
        // Room comes from the node tree, NOT from PreciseMatch.room — the
        // Swift recipe carries the raw parentNodeId there (ShapedRecall
        // builds it from hit.drawer?.parentNodeId), while the structured
        // field is the resolved display name in both ports.
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: drawersByID.values.map { $0.parentNodeId })

        var lines: [String] = ["found \(matches.count) memory(s)"]
        var results: [ToolDispatcher.StructuredRecallRow] = []
        for match in shownMatches {
            lines.append(denseByID[match.id] ?? DenseRow.renderUnhydrated(id: match.id))
            if let d = drawersByID[match.id] {
                // match.content is PRE-redaction (it fed the containment gate
                // above); the row builder's provenance switch decides whether
                // it enters the structured block.
                results.append(ToolDispatcher.structuredRecallRow(
                    id: match.id,
                    room: nodeNames[d.parentNodeId]?.room,
                    content: match.content, drawer: d))
            } else {
                // Gated id: the text shows the opaque unhydrated row, so the
                // structured block is exactly as opaque — the match's room
                // and content in hand are deliberately NOT emitted.
                results.append(ToolDispatcher.opaqueStructuredRow(id: match.id))
            }
        }
        // Deviation-only narration (PR-03): the discrimination line appears
        // only when the signal is low or medium; a clear result and the
        // single/zero "n/a" case stay silent.
        if preciseDiscrimination == .low || preciseDiscrimination == .medium {
            lines.append(RecallDiscrimination.resultLine(for: preciseDiscrimination))
        }
        if !hasDistinctive {
            lines.append("hint: query contains no distinctive tokens (numbers or proper nouns) — "
                + "results may be imprecise. Refine with specific identifiers for higher confidence.")
        }
        return ToolDispatcher.structuredTextResult(
            lines.joined(separator: "\n"), results: results)
    }

    // MARK: - recall_connected

    /// Run the ConnectedRecall recipe and serialize its matches in the SAME
    /// plain-text shape `moot_memory_search` emits (found-N header + one
    /// dense row per hit), so every mootText parser works unchanged. A
    /// trailing `connected:` line names the lane provenance (anchor / walk /
    /// both counts) — the walk lane is the tool's whole reason to exist, so
    /// the response says whether it contributed.
    private static func runConnectedRecall(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let query = try requireString(args, "query")
        let limit = try ToolDispatcher.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        let filter = try decodeSingleFilter(args["filter"])
        // Wing scopes the TUNNEL side of the walk graph; associations are
        // estate-wide. Omitted wing = association-only graph (tunnels are
        // wing-scoped reads and there is no all-wings tunnel verb).
        let wing = try optionalString(args["wing"], argument: "wing") ?? ""

        let matches = try await ConnectedRecall.run(
            kit: kit, handle: handle, query: query,
            wing: wing, filter: filter, limit: limit)

        // Same sensitivity-gated dense-row rendering the precise tool uses:
        // the structured-tier fetch decides what may be shown; the recipe's
        // in-hand content never bypasses the gate. The caller's filter rides
        // in the frame (Wave-3 G1): walk-discovered ids arrive here without
        // having passed the caller's filter at recall time, so render is the
        // second gate that keeps e.g. a non-exportable bridge drawer opaque
        // under filter:"exportable".
        let estate = try await kit.estate(for: handle)
        let shownMatches = Array(matches.prefix(50))
        let drawersByID = try await structuredDrawersByID(
            ids: shownMatches.map { $0.id }, estate: estate, filterChain: [filter])
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: drawersByID.values.map { $0.parentNodeId })

        var lines: [String] = ["found \(matches.count) memory(s)"]
        var results: [ToolDispatcher.StructuredRecallRow] = []
        for match in shownMatches {
            if let d = drawersByID[match.id] {
                lines.append(DenseRow.render(d))
                results.append(ToolDispatcher.structuredRecallRow(
                    id: match.id,
                    room: nodeNames[d.parentNodeId]?.room,
                    content: match.content, drawer: d))
            } else {
                lines.append(DenseRow.renderUnhydrated(id: match.id))
                results.append(ToolDispatcher.opaqueStructuredRow(id: match.id))
            }
        }
        let anchorCount = matches.filter { $0.source == "anchor" }.count
        let walkCount = matches.filter { $0.source == "walk" }.count
        let bothCount = matches.filter { $0.source == "both" }.count
        lines.append("connected: anchor=\(anchorCount) walk=\(walkCount) both=\(bothCount)")
        return ToolDispatcher.structuredTextResult(
            lines.joined(separator: "\n"), results: results)
    }

    // MARK: - recall_shaped

    /// Run the ShapedRecall recipe with a named RecallShape preset and serialize
    /// its matches in the SAME plain-text shape `moot_memory_search` emits: a
    /// `found N memory(s)` header then one `id  [room]  preview` line per match.
    /// Mirroring that shape keeps every mootText parser working unchanged.
    ///
    /// Preset validation is fail-CLOSED: an absent `preset` arg maps to "balanced"
    /// (the unsteered default). A present-but-unknown name is a caller error — the
    /// access surface rejects it with a tool error (isError: true) against the GLK
    /// roster instead of silently degrading to balanced and returning surprising
    /// results under a name the caller did not realize was ignored. (The recipe
    /// itself degrades to balanced; the access surface is where fail-closed
    /// validation lives — the same boundary discipline as the precise-recall
    /// composition arg.)
    private static func runShapedRecall(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        // Anchor pivot (PR-03): near:<uuid> as an alternative to query:,
        // identical contract to moot_memory_search — the anchor's content
        // runs through the SAME shaped pipeline (preset/filter/limit
        // inherited); the anchor row is excluded from the reply; a gated
        // anchor reads as not-found (default containment gate for adjective
        // sensitivity bits 6-11, plus an explicit `Drawer.sensitivity` check
        // for provenance sensitivity bits 30-35, which the frame does not
        // cover; no grant lift — oracle-free, byte-identical to an absent id).
        let queryArg = try optionalString(args["query"], argument: "query")
        let nearArg = try optionalString(args["near"], argument: "near")
        let query: String
        var anchorID: String? = nil
        switch (queryArg, nearArg) {
        case (nil, nil):
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Provide either query (text search) or near (UUID of an anchor "
                    + "memory — returns the memories most similar to it under the preset)."
            )
        case (.some, .some):
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "query and near are mutually exclusive — pass exactly one."
            )
        case (.some(let q), nil):
            query = q
        case (nil, .some(let anchor)):
            let anchorEstate = try await kit.estate(for: handle)
            let fetched = try await anchorEstate.getDrawers(
                ids: [anchor],
                matchingFrame: RecallFrame(filterChain: [], hydrationLevel: .full),
                hydrationLevel: .full)
            // The provenance reject is evaluated BEFORE the empty-content
            // check, so a gated row and an empty row collapse into the one
            // not-found shape below, byte-identical to the message an absent
            // id produces. Ordering discipline and defence in depth: this
            // fetch requests a single id, so `admissible` holds at most one
            // drawer and either order yields the same error today. Should
            // this ever resolve a set, provenance-first is the order that
            // cannot leak.
            let admissibleAnchor = fetched.admissible.first { d in
                switch d.sensitivity {
                case .restricted, .secret: return false
                case .normal, .elevated: return true
                }
            }
            guard let anchorDrawer = admissibleAnchor,
                  !anchorDrawer.content.isEmpty else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "near: anchor memory not found: \(anchor)"
                )
            }
            query = anchorDrawer.content
            anchorID = anchor
        }
        // Clamp to [1, 500]: reject negative/zero, cap absurdly-large values.
        // DoS prevention at the MCP boundary before the substrate is touched.
        // Parity: Rust run_shaped_recall_tool uses clamp_limit with same ceiling.
        let limit = try ToolDispatcher.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        // optional `wing` scopes recall to a single wing.
        // When present, compose with the explicit filter via Filter.all.
        let baseFilter = try decodeSingleFilter(args["filter"])
        let filter: LocusKit.Filter
        if let wingName = try optionalString(args["wing"], argument: "wing") {
            filter = .all([baseFilter, .inWing(wingName)])
        } else {
            filter = baseFilter
        }

        // The steering selector: a named RecallShape preset.
        //   Absent  → "balanced" → the unsteered default; absence ≠ unknown.
        //   Present → validated against the GLK roster; unknown name → fail closed
        //             (tool error, not silent fall-through to balanced).
        let preset: String
        if let rawPreset = try optionalString(args["preset"], argument: "preset") {
            guard RecallShape.presetNames.contains(rawPreset) else {
                let valid = RecallShape.presetNames.joined(separator: ", ")
                return ToolDispatcher.errorResult(
                    "unknown preset '\(rawPreset)'; valid presets: \(valid)")
            }
            preset = rawPreset
        } else {
            preset = "balanced"
        }

        let out = try await ShapedRecall().run(
            input: .init(query: query, preset: preset, filter: filter, limit: limit),
            estate: handle, kit: kit)

        // Discrimination is computed over the full ordered list before the
        // display prefix so the signal reflects all returned scores.
        let shapedScores = out.matches.map { $0.score }
        let shapedDiscrimination = RecallDiscrimination.classify(shapedScores)

        // Dense-row reply (PR-03): same row shape as moot_memory_search;
        // anchor excluded when near: pivoted.
        // MXE-SS: ONE structured-tier fetch through the same gate feeds BOTH
        // blocks — the dense text rows (rendered locally, byte-identical to
        // the former denseRowsByID output: same admissible set, same
        // DenseRow.render) and the typed structured rows.
        let estate = try await kit.estate(for: handle)
        let shownMatches = out.matches.filter { anchorID == nil || $0.id != anchorID }
        let displayedMatches = Array(shownMatches.prefix(50))
        let drawersByID = try await structuredDrawersByID(
            ids: displayedMatches.map { $0.id }, estate: estate)
        let denseByID = drawersByID.mapValues { DenseRow.render($0) }
        // Room comes from the node tree, NOT from PreciseMatch.room — the
        // Swift recipe carries the raw parentNodeId there (ShapedRecall
        // builds it from hit.drawer?.parentNodeId), while the structured
        // field is the resolved display name in both ports.
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: drawersByID.values.map { $0.parentNodeId })

        var lines: [String] = ["found \(shownMatches.count) memory(s)"]
        var results: [ToolDispatcher.StructuredRecallRow] = []
        for match in displayedMatches {
            lines.append(denseByID[match.id] ?? DenseRow.renderUnhydrated(id: match.id))
            if let d = drawersByID[match.id] {
                // match.content is PRE-redaction; the row builder's
                // provenance switch decides whether it enters the
                // structured block.
                results.append(ToolDispatcher.structuredRecallRow(
                    id: match.id,
                    room: nodeNames[d.parentNodeId]?.room,
                    content: match.content, drawer: d))
            } else {
                // Gated id: opaque in text, exactly as opaque in the
                // structured block.
                results.append(ToolDispatcher.opaqueStructuredRow(id: match.id))
            }
        }
        // Deviation-only narration (PR-03): line only on low/medium.
        if shapedDiscrimination == .low || shapedDiscrimination == .medium {
            lines.append(RecallDiscrimination.resultLine(for: shapedDiscrimination))
        }
        return ToolDispatcher.structuredTextResult(
            lines.joined(separator: "\n"), results: results)
    }

    /// Fetch dense rows for a set of hit ids in one structured-tier read.
    /// The structured tier carries every dense-row field (subject trio,
    /// lattice anchor, event time, provenance bitmap for redaction) without
    /// hauling content blobs.
    ///
    /// THIS IS THE SENSITIVITY BOUNDARY for every by-id dense-row caller —
    /// all six graph-lens arms in `LensTools` and the tunnel-citation arms
    /// in `ToolDispatch`. (The recall arms here fetch through
    /// `structuredDrawersByID` below — the same frame, the same gate — and
    /// render their dense rows from its result.) Gate here, once; never at
    /// the call sites. A per-arm check is how the hole reappears: the next
    /// arm that hydrates an id inherits whatever this helper does.
    ///
    /// THE EMPTY `filterChain` IS LOAD-BEARING, NOT AN ABSENT ARGUMENT.
    /// `BitmapEvaluator.insertDefaults` inserts `.sensitivityAtMost(.elevated)`
    /// into any chain carrying no sensitivity filter, and that predicate is
    /// evaluated against the ADJECTIVE bitmap (bits 4–7) — the same axis
    /// `AdjectiveSensitivity.isBulkExportable` tests. So a `.restricted` or
    /// `.secret` drawer never reaches `fetched.admissible`, and
    /// `DenseRow.render` is never called with one. No explicit sensitivity
    /// check appears below because it could never fire; the frame has already
    /// removed those rows.
    ///
    /// Do NOT "simplify" this to the frameless `estate.getDrawers(ids:
    /// hydrationLevel:)`. That read applies no ceiling at all, and these ids
    /// arrive from tunnel graphs whose edges carry the sensitivity their
    /// endpoints had AT LINK TIME — a drawer restricted after its tunnels
    /// were created is still reachable through a stale edge. Dropping the
    /// frame would emit that drawer's subject. (The Rust port carried exactly
    /// that defect at its raw-store lens sites; `dense_row::rows_by_id` is its
    /// twin of this method and reaches the ceiling through the same frame.)
    ///
    /// Gated rows are simply ABSENT from the returned map rather than
    /// substituted, so each arm's existing `DenseRow.renderUnhydrated`
    /// fallback produces the opaque row: the id and its ranking value still
    /// appear, the subject does not. Omitting the row entirely would change
    /// result counts and rankings and make the gate itself an oracle.
    static func denseRowsByID(ids: [String], estate: Estate) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let fetched = try await estate.getDrawers(
            ids: ids,
            matchingFrame: RecallFrame(filterChain: [], hydrationLevel: .structured),
            hydrationLevel: .structured)
        return Dictionary(uniqueKeysWithValues: fetched.admissible.map {
            ($0.id, DenseRow.render($0))
        })
    }

    /// Typed-drawer twin of `denseRowsByID` (MXE-SS): the SAME by-id read
    /// through the SAME gated `RecallFrame` — the load-bearing default gate
    /// documented on `denseRowsByID` — returning the drawers themselves so
    /// the structured block can take subject and provenance sensitivity from
    /// the row. `filterChain` carries the CALLER's filter when the tool
    /// surface accepts one (connected recall passes it so walk-reachable rows
    /// cannot bypass it at render, Wave-3 G1); insertDefaults rides alongside
    /// either way. Structured hydration: content blobs are NOT loaded here;
    /// recall-recipe content comes from the match and passes through the
    /// redaction switch in `ToolDispatcher.structuredRecallRow`. Gated ids
    /// are ABSENT from the map exactly as they are from `denseRowsByID`, and
    /// callers fall through to the opaque row (the twin of
    /// `DenseRow.renderUnhydrated`).
    static func structuredDrawersByID(
        ids: [String], estate: Estate, filterChain: [Filter] = []
    ) async throws -> [String: Drawer] {
        guard !ids.isEmpty else { return [:] }
        let fetched = try await estate.getDrawers(
            ids: ids,
            matchingFrame: RecallFrame(filterChain: filterChain, hydrationLevel: .structured),
            hydrationLevel: .structured)
        return Dictionary(uniqueKeysWithValues: fetched.admissible.map { ($0.id, $0) })
    }

    // MARK: - typed conflict projection section (DCP M4)

    /// Render the typed conflict-projection sweep as the ADDITIVE report
    /// section every contradiction surface appends (M0 §7):
    /// moot_hunt_contradictions, moot_dream, and moot_lens_contradiction
    /// all route through this one renderer so the lines never drift.
    ///
    /// Redaction (M0 §8, ceiling = MAX endpoint sensitivity, no grant
    /// plumbing in v0.1 — same fixed posture as the lexical hunter):
    /// - ceiling ≤ elevated (raw 16): full block incl. dense rows.
    /// - restricted (raw 32): one line naming only the coordinate
    ///   DIGEST — no source ids, no value digests (enum domains are
    ///   small, digests would be guessable), no dense rows.
    /// - secret (raw 48): counted in `proven: N`, no block at all.
    ///
    /// `lexicalCandidates` is the borderline count from the lexical
    /// hunter (the `candidates:` relabel); pass nil on surfaces with no
    /// lexical lane (the lens).
    static func conflictProjectionSection(
        _ sweep: ConflictProjectionSweepReport,
        denseRows: [String: String],
        lexicalCandidates: Int?
    ) -> [String] {
        var lines: [String] = [
            "proven: \(sweep.counts.provenContradiction)",
            "historical: \(sweep.counts.historicalSuccession)",
            "compatible: \(sweep.counts.compatiblePlurality)",
        ]
        if let candidates = lexicalCandidates {
            lines.append("candidates: \(candidates)")
        }
        // Unparsed facts and unjudgeable pairs share the line: both are
        // "the typed lane saw it and refused to guess".
        lines.append("unknown_or_invalid: "
            + "\(sweep.counts.unknownOrInvalid + sweep.diagnostics.unparsed)")
        lines.append("coverage: \(sweep.diagnostics.projected)/\(sweep.diagnostics.scanned)")
        if sweep.truncatedBuckets > 0 {
            // Deviation-only line (M0 §7): silence means no bucket hit
            // its cap.
            lines.append("truncated_buckets: \(sweep.truncatedBuckets)")
        }
        let secretRaw = AdjectiveSensitivity.secret.rawValue
        let restrictedRaw = AdjectiveSensitivity.restricted.rawValue
        for finding in sweep.proven {
            if finding.sensitivityCeilingRaw >= secretRaw { continue }
            let outcome = finding.outcome
            if finding.sensitivityCeilingRaw >= restrictedRaw {
                lines.append("  a conflicting claim exists at "
                    + "\(outcome.coordinateDigest) [restricted]")
                continue
            }
            lines.append("  PROVEN \(outcome.resultID)")
            lines.append("    rule: \(outcome.ruleID)@\(outcome.ruleVersion)")
            lines.append("    coordinate: \(outcome.key)|\(outcome.dimension)")
            lines.append("    values: \(outcome.valueDigests.joined(separator: " vs "))")
            lines.append("    time: \(outcome.temporalBases.joined(separator: " | "))")
            lines.append("    reasons: "
                + outcome.reasons.map(\.rawValue).joined(separator: ", "))
            for id in outcome.sourceDrawerIDs {
                lines.append("    \(denseRows[id] ?? "\(id) · - · - · - · -")")
            }
        }
        for finding in sweep.historical where finding.sensitivityCeilingRaw < restrictedRaw {
            let outcome = finding.outcome
            lines.append("  HISTORICAL \(outcome.resultID) "
                + "\(outcome.key)|\(outcome.dimension) ("
                + outcome.reasons.map(\.rawValue).joined(separator: ", ") + ")")
        }
        return lines
    }

    /// Run the typed sweep for a report surface and render its section,
    /// hydrating dense rows only for fully visible findings.
    static func renderConflictProjection(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        estate: Estate,
        lexicalCandidates: Int?
    ) async throws -> [String] {
        let sweep = try await kit.conflictProjectionSweep(in: handle)
        let restrictedRaw = AdjectiveSensitivity.restricted.rawValue
        let visibleIDs = sweep.proven
            .filter { $0.sensitivityCeilingRaw < restrictedRaw }
            .flatMap(\.outcome.sourceDrawerIDs)
        let denseRows = try await denseRowsByID(
            ids: Array(Set(visibleIDs)), estate: estate)
        return conflictProjectionSection(
            sweep, denseRows: denseRows, lexicalCandidates: lexicalCandidates)
    }

    // MARK: - tiered contradiction sections (MXE-CT3 P3)

    /// Exact tier section headers — the wire contract for every surface
    /// that renders a `TieredContradictionReport` (hunt and dream share
    /// this ONE renderer, M4 pattern: one renderer, lines never drift).
    /// Parity: Rust `recipe_tools::TIER1_HEADER` etc.
    static let tier1Header = "TIER 1 — CONTRADICTION (proven)"
    static let tier2Header = "TIER 2 — CONFLICT CANDIDATE"
    static let tier3Header = "TIER 3 — DIVERGENCE"

    /// Render a `TieredContradictionReport` as report lines. The ONE
    /// tiered renderer: `moot_hunt_contradictions` (both modes) and
    /// `moot_dream` (synthesis digest) both route through here so the
    /// sections never drift between surfaces or ports.
    ///
    /// Tier-1 blocks reuse the typed lane's rendering contract
    /// (`conflictProjectionSection`'s F13 redaction path): a secret
    /// finding is counted by the lane counts only (no block), a
    /// restricted finding renders ONLY the coordinate-digest line, and a
    /// finding at or below elevated renders result essentials plus the
    /// SAME gated dense rows (`denseRowsByID` — no parallel rendering
    /// path to drawer content). The tiered verb already ceiling-filters
    /// findings above elevated out of its tier-1 section
    /// (`tier1CeilingFiltered`), so the secret/restricted arms here are
    /// defense in depth, not the primary gate.
    ///
    /// Tiers 2/3 render the drawer pair plus cue kind and score — no
    /// content snippets: the legacy CANDIDATE feed is the snippet
    /// surface, and the digest must not become a second content
    /// disclosure path.
    ///
    /// `laneSeconds` is non-nil in SYNTHESIS mode only: per-tier lane
    /// counts (fetched/returned/promotedAway/backfilled) and the
    /// elapsed-seconds lines render only for a synthesis digest. The
    /// seconds are measured by the CALLER around each GLK call — the
    /// engines are deterministic (no clock reads inside), so wall-clock
    /// timing lives at this dispatch layer, the I/O boundary.
    static func tieredSectionLines(
        _ report: TieredContradictionReport,
        denseRows: [String: String],
        laneSeconds: [(label: String, seconds: Double)]?
    ) -> [String] {
        let synthesis = report.mode == .synthesis
        var lines: [String] = []
        let secretRaw = AdjectiveSensitivity.secret.rawValue
        let restrictedRaw = AdjectiveSensitivity.restricted.rawValue

        for tier in ContradictionTier.allCases {
            // Single-tier mode renders ONLY the requested lane's section;
            // the other sections are structurally empty and would render
            // as bare headers, which misreads as "lane ran, found none".
            if case .single(let requested) = report.mode, requested != tier { continue }
            switch tier {
            case .typedProven: lines.append(Self.tier1Header)
            case .lexicalStructural: lines.append(Self.tier2Header)
            case .lexicalValue: lines.append(Self.tier3Header)
            }
            if synthesis {
                let c = report.counts(for: tier)
                lines.append("  lane: fetched \(c.fetched), returned \(c.returned), "
                    + "promotedAway \(c.promotedAway), backfilled \(c.backfilled)")
            }
            for finding in report.findings(for: tier) {
                switch tier {
                case .typedProven:
                    let ceiling = finding.sensitivityCeilingRaw ?? secretRaw
                    if ceiling >= secretRaw { continue }
                    if ceiling >= restrictedRaw {
                        lines.append("  a conflicting claim exists at "
                            + "\(finding.coordinateDigest ?? "?") [restricted]")
                        continue
                    }
                    lines.append("  PROVEN \(finding.resultID ?? "?") "
                        + "at \(finding.coordinateDigest ?? "?") "
                        + "(rule \(finding.ruleID ?? "?"))")
                    for id in [finding.drawerA, finding.drawerB] {
                        lines.append("    \(denseRows[id] ?? "\(id) · - · - · - · -")")
                    }
                case .lexicalStructural, .lexicalValue:
                    lines.append("  \(finding.drawerA) vs \(finding.drawerB) "
                        + "(\(finding.cueKind ?? "?"), score \(finding.score ?? 0))")
                }
            }
        }
        if synthesis, let laneSeconds {
            // Per-lane elapsed + synthesis wall time (the sum of the GLK
            // calls this tool made). %.3f both ports for byte parity.
            let parts = laneSeconds.map { "\($0.label)=\(String(format: "%.3f", $0.seconds))" }
            lines.append("lane_seconds: " + parts.joined(separator: " "))
            let total = laneSeconds.reduce(0.0) { $0 + $1.seconds }
            lines.append("synthesis_wall_seconds: " + String(format: "%.3f", total))
        }
        return lines
    }

    /// Hydrate the gated dense rows for a tiered report's fully visible
    /// tier-1 findings and render its sections. The dense rows come from
    /// the SAME `denseRowsByID` fetch (structured hydration behind the
    /// default-gated RecallFrame) the typed projection section uses.
    static func renderTieredSections(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        report: TieredContradictionReport,
        laneSeconds: [(label: String, seconds: Double)]?
    ) async throws -> [String] {
        let restrictedRaw = AdjectiveSensitivity.restricted.rawValue
        let visibleIDs = report.tier1
            .filter { ($0.sensitivityCeilingRaw ?? restrictedRaw) < restrictedRaw }
            .flatMap { [$0.drawerA, $0.drawerB] }
        let denseRows = try await denseRowsByID(
            ids: Array(Set(visibleIDs)), estate: kit.estate(for: handle))
        return tieredSectionLines(report, denseRows: denseRows, laneSeconds: laneSeconds)
    }

    // MARK: - run_migration_benchmark

    private static func runMigrationBenchmark(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let corpusName = try requireString(args, "corpusName")
        guard let entriesValue = args["entries"], entriesValue.arrayValue != nil else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "entries must be an array")
        }
        let plans = try decodePlans(args["plans"])
        guard !plans.isEmpty else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "run_migration_benchmark requires at least one plan")
        }

        // data-movement privacy tiers (VK-ADAPT-01): VaultKit's adapter pipeline
        // owns the export-decode knowledge. Re-encode the wire entries as
        // an export document and run ExchangeAdapter → CorpusProjection —
        // the same consolidated path file import uses — instead of
        // decoding entries inline here. Tool name and input schema are
        // unchanged; the decode error maps to the same invalidParams
        // message clients saw before the re-plumb.
        let exportDocument = JSONValue.object([
            "name": .string(corpusName),
            "entries": entriesValue,
        ])
        let export: ExchangeExport
        do {
            export = try ExchangeAdapter().decode(exportDocument.encoded())
        } catch is DecodingError {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "each entry needs string id and content")
        }
        let origin = CorpusProjection.externalCorpus(name: export.name, notes: export.notes)
        let out = try await MigrationBenchmark().run(
            input: .init(origin: origin, plans: plans),
            estate: handle, kit: kit)

        let report = out.comparisonReport
        var lines: [String] = ["run_migration_benchmark"]
        if let wid = report.winnerBranchID, let wname = report.winnerPlanName {
            lines.append("winner: plan '\(wname)' branch \(wid)")
        } else {
            lines.append("winner: none (all plans disqualified or no plans)")
        }
        lines.append("rankings:")
        for r in report.rankings {
            lines.append("  - \(r.planName) [\(r.branchID)] score=\(r.combinedScore) overlap=\(r.recallOverlap) mrr=\(r.meanReciprocalRank)")
        }
        lines.append("disqualified:")
        for d in report.disqualified {
            lines.append("  - \(d.planName) [\(d.branchID)] lost: \(d.lostConcepts.joined(separator: ", "))")
        }
        lines.append("")
        // Disqualified branches were discarded server-side by the run; the
        // confirm tool refuses them regardless of what the caller sends.
        lines.append("To promote, call \(confirmMigrationPromotionToolName) with winnerBranchID and discardBranchIDs (the other ranking ids). Disqualified branches above were already discarded and cannot be promoted.")
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - confirm_migration_promotion

    private static func runConfirmPromotion(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let winner = try requireUUID(args, "winnerBranchID")
        let discard = try decodeUUIDArray(args["discardBranchIDs"])
        // NOTE: no client-supplied disqualification set. The C-5 verdict is
        // server-side: the run discarded disqualified branches, and the
        // confirm below refuses any non-active branch.

        do {
            try await MigrationBenchmark().confirmPromotion(
                winnerBranchID: winner,
                discardBranchIDs: discard,
                estate: handle, kit: kit)
        } catch let error as RecipeError {
            // Recipe-level refusal (e.g. silentConceptLoss on a
            // disqualified winner, or an unknown branch). The call reached
            // the recipe and was refused; surface it as a tool error so
            // the client keeps the call id and sees why.
            return ToolDispatcher.errorResult(error.description)
        }
        return ToolDispatcher.textResult(
            "confirm_migration_promotion: promoted \(winner); discarded \(discard.count) branch(es).")
    }

    // MARK: - dream

    /// Maximum probe count for `moot_dream` when `associates: "all"` is requested.
    ///
    /// "all" mode is intended for post-import full-estate coverage: after a bulk
    /// import the caller wants proximity associations mined across every item, not
    /// just the 50 most-recent. Without a cap, `probeLimit: nil` passes `Int.max`
    /// to `VectorStore.recentItemIDs(limit:)`, which scans the whole table and then
    /// runs O(N × k) kNN probes — on a pathologically large estate that could run
    /// for minutes inside an MCP tool call.
    ///
    /// 10_000 items is the bound:
    ///   - At HNSW scale (k = 5, O(k·log N)): ~700K similarity ops, a few seconds.
    ///   - Personal estates with >10K vector-indexed drawers are exceptional;
    ///     repeated calls converge anyway (existing associations are skipped).
    ///   - Consistent with the contradiction-hunt's 500-probe per-call bound:
    ///     the associate sweep is the "full-coverage" companion, so 20× is generous.
    ///
    /// Parity constant: Rust `DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE = 10_000`.
    private static let dreamAssociateAllModeMaxProbe: Int = 10_000

    /// Run `moot_dream`: rebuild the estate's derived accelerators, then run one
    /// dreaming cycle. Two distinct effects, both required for a fully "dreamt"
    /// estate:
    ///
    ///   1. MATRIX REBUILD — `kit.rebuildDerivedAccelerators(for:)` feeds the
    ///      estate's audit log into the GLK UnifiedAuditLog CRDT and rebuilds the
    ///      MatrixTier (field-presence F, co-occurrence C/O, temporal causality
    ///      T) then registers it on the estate. Before this call the estate has
    ///      no registered matrix tier, so the RecallDirector's `coOccurrence`
    ///      and temporal score columns read 0.0 and the matrix-driven precise
    ///      compositions (matrix, text+matrix, weighted-all's matrix term)
    ///      score nothing. This is THE step that un-starves them.
    ///   2. DREAMING CYCLE — a `DreamingDaemon` over the same estate seams the
    ///      AutonomicGovernor uses (`EstateDreamingReader` + `EstateDreamingSink`
    ///      + an in-memory policy store) runs one `triggerDreamingCycle(now:)`,
    ///      mining latent co-occurrence alignments into Tunnel proposals and
    ///      writing one cycle diary entry. This is the literal "dream".
    ///
    /// `now` is explicit (CLAUDE.md determinism): an optional ISO8601 arg drives
    /// the cycle's diary timestamp and reward window so a benchmark run is
    /// reproducible. Absent ⇒ wall clock, matching the other write tools.
    private static func runDream(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        // Deterministic `now` when supplied; otherwise the wall clock. A
        // malformed instant is an out-of-band client error.
        //
        // Upper-bound guard: a future `now` causes pruneRecallTraces(olderThan: now - 30.days)
        // to delete ALL recall traces (since every trace is older than a future minus 30 days).
        // Reject any `now` that is more than 24 hours in the future; this is generous enough
        // for timezone edge cases and deliberate benchmark offsets while closing the wipe vector.
        let now: Date
        if let raw = try optionalString(args["now"], argument: "now") {
            guard let parsed = ISO8601DateFormatter().date(from: raw) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "now is not a valid ISO8601 instant: \(raw)")
            }
            // Future-now guard: reject timestamps more than 86400s (24 h) ahead of
            // wall clock. A far-future `now` causes pruneRecallTraces(olderThan:
            // now − 30 days) to prune recent real recall traces, corrupting the
            // reward signal. Hard ceiling: 24 h. Parity: Rust run_dream_tool.
            guard parsed.timeIntervalSince(Date()) <= 86400 else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "now is more than 24 hours in the future; "
                        + "pass a timestamp close to the current time")
            }
            now = parsed
        } else {
            now = Date()
        }

        // Step 1 — rebuild + register the matrix tier (the un-starving step).
        try await kit.rebuildDerivedAccelerators(for: handle)

        // Step 2 — one dreaming cycle over the live estate seams, constructed
        // exactly as the AutonomicGovernor does for the resident process.
        let daemon = NeuronKit.dreamingDaemon(
            reader: EstateDreamingReader(handle: handle, kit: kit),
            sink: EstateDreamingSink(handle: handle, kit: kit),
            policyStore: InMemoryDreamingPolicyStore())
        let report = try await daemon.triggerDreamingCycle(now: now)

        // Step 3 — the content-driven phase: one contradiction-hunt sweep
        // (kNN candidates + ConflictCue screen; strong findings persist as
        // proposed contradicts tunnels; dedup is durable, so re-running
        // moot_dream never re-proposes). This is what makes post-import
        // dreaming produce content results on a never-recalled estate.
        // Bounded probe budget per call; repeated calls stay cheap because
        // settled pairs are skipped.
        // Sensitivity ceiling is hardcoded .elevated (fail-safe by design); huntContradictions does NOT consult SensitivityGrantLedger.
        let hunt = try await kit.huntContradictions(
            in: handle, probeLimit: 500, now: now)

        // Step 3.25 — MXE-CT3 P3: file tier-labeled conflict-tunnel
        // candidates at ALL three tiers (typed proof, structural lexical
        // cue, value divergence) out of one typed sweep + one shared
        // lexical pass, surviving the decline matrix (P2.5 contract:
        // model filing never activates — the user settles proposals via
        // moot_review_tunnel). Timed at this dispatch layer: the engine
        // is deterministic, clocks live at the I/O boundary.
        let proposeStart = Date()
        let candidates = try await kit.proposeConflictTunnels(in: handle, now: now)
        let proposeSeconds = Date().timeIntervalSince(proposeStart)

        // Step 3.5 — vector-similarity association sweep.
        //
        // Mines proximity pairs from the estate's VectorStore and writes
        // new associations directly (no scheduler round-trip). Dedup is
        // durable: existing active associations are skipped. Mirrors the
        // ContradictionHunt one-impl pattern: associateSweep is the same
        // core used by the resident VectorSimilaritySignal, exposed here
        // for on-demand coverage.
        //
        // Three modes decoded from the "associates" argument:
        //   "all"    — probeLimit nil = all items (full estate coverage)
        //   "recent" — probeLimit VectorSimilaritySignal.defaultProbeLimit (default)
        //   "off"    — skip the step entirely
        //
        // Default is "recent" (fast, mirrors the standing-signal cadence).
        // Use "all" after bulk imports for full-estate coverage.
        let associatesMode = (try? optionalString(args["associates"], argument: "associates")) ?? "recent"
        var assocLine = ""
        if associatesMode != "off" {
            // Server-side probe budget: "all" uses the named constant (10_000) rather
            // than nil (unbounded) — an unbounded MCP probe is a DoS vector on large
            // estates. "recent" uses the standing-signal default (50). Both are
            // finite; the nil path is intentionally removed. Parity: Rust
            // run_dream_tool uses DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE for "all".
            let assocProbeLimit: Int = associatesMode == "all"
                ? Self.dreamAssociateAllModeMaxProbe
                : VectorSimilaritySignal.defaultProbeLimit
            let assocReport = try await kit.associateSweep(
                in: handle, probeLimit: assocProbeLimit, now: now)
            if assocReport.probed > 0 || assocReport.written > 0 {
                assocLine = "\nassociationsWritten: \(assocReport.written) "
                    + "(probed: \(assocReport.probed), deduplicated: \(assocReport.deduplicated))"
            }
        }

        // Step 4 — subject backfill dispatch (rider-default ruling,
        // 2026-08-02): dreaming pays subject debt when a producer is
        // registered (on Apple the serve layer registers the miniLLM
        // rider by default). One bounded batch per dream call — the
        // sweep's settled-skip makes repeated dreams converge; estates
        // with no rider (disabled, non-Apple, kit-level tests) skip
        // silently and the interactive consent path remains the only
        // subject writer.
        var backfillLine = ""
        if await kit.subjectProducerPipeline(for: handle) != nil {
            let debt = try await kit.estate(for: handle).countSubjectDebt()
            if debt > 0 {
                let sweep = try await kit.subjectBackfillSweep(
                    handle, batchLimit: 32, now: now)
                backfillLine = "\nsubjectsBackfilled: \(sweep.written) "
                    + "(skipped: \(sweep.skippedInadmissible), remaining: \(sweep.remainingDebt))"
            }
        }

        var body = """
        moot_dream: matrix rebuilt, dreaming cycle complete
        consideredCandidates: \(report.candidatesConsidered)
        proposalsEmitted: \(report.proposalsEmitted.count)
        suppressedDuplicates: \(report.suppressedDuplicates)
        belowThreshold: \(report.belowThreshold)
        contradictionsProposed: \(hunt.proposed.count)
        contradictionCandidatesBorderline: \(hunt.borderline.count)
        """
        body += backfillLine
        body += assocLine
        if !hunt.vectorStoreAvailable {
            body += "\n(contradiction hunt skipped: no vector index for this estate — run moot_reindex first)"
        }
        if !hunt.proposed.isEmpty {
            body += "\nReview proposed contradictions with moot_lens_contradiction, then accept/reject via moot_review_tunnel."
        }
        // DCP M4 — the typed proving lane's additive section (M0 §7).
        let typedSection = try await renderConflictProjection(
            kit: kit, handle: handle,
            estate: kit.estate(for: handle),
            lexicalCandidates: hunt.borderline.count)
        body += "\n" + typedSection.joined(separator: "\n")

        // MXE-CT3 P3 — candidate-filing counts (step 3.25) and the
        // tiered synthesis digest, rendered through the SAME shared
        // renderer the hunt tool uses (one renderer, lines never drift).
        body += "\nconflictTunnelsFiled: tier1 \(candidates.proposedTunnelIDs.count), "
            + "tier2 \(candidates.proposedTier2IDs.count), "
            + "tier3 \(candidates.proposedTier3IDs.count) "
            + "(suppressed: \(candidates.suppressed), "
            + "ceilingSkipped: \(candidates.ceilingSkipped))"
        let tieredStart = Date()
        let tiered = try await kit.tieredContradictionSearch(
            in: handle, topK: 5, now: now)
        let tieredSeconds = Date().timeIntervalSince(tieredStart)
        let tieredLines = try await renderTieredSections(
            kit: kit, handle: handle, report: tiered,
            laneSeconds: [("propose", proposeSeconds), ("synthesis", tieredSeconds)])
        body += "\n" + tieredLines.joined(separator: "\n")
        return ToolDispatcher.textResult(body)
    }

    // MARK: - hunt contradictions

    /// Run `moot_hunt_contradictions`: one bounded contradiction-hunt sweep.
    /// Strong findings persist as proposed contradicts tunnels (the hunt does
    /// its own writes); borderline candidates come back with snippets for the
    /// calling agent to adjudicate.
    ///
    /// MXE-CT3 P3 tier modes:
    /// - `tier` absent or `"all"` (the default): today's exact legacy sweep
    ///   report, unchanged byte for byte, PLUS an appended tiered synthesis
    ///   digest (`tieredContradictionSearch` synthesis mode).
    /// - `tier` 1|2|3: a read-only purpose search of that single lane —
    ///   no legacy sweep, no tunnels filed, no writes of any kind.
    private static func runHuntContradictions(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let now: Date
        if let raw = try optionalString(args["now"], argument: "now") {
            guard let parsed = ISO8601DateFormatter().date(from: raw) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "now is not a valid ISO8601 instant: \(raw)")
            }
            now = parsed
        } else {
            now = Date()
        }
        var probeLimit = 500
        if let raw = args["probe_limit"] {
            guard case .integer(let n) = raw, n > 0, n <= 10_000 else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "probe_limit must be an integer in 1...10000")
            }
            probeLimit = Int(n)
        }
        // `tier`: integer 1|2|3 or the string "all"; anything else is
        // rejected at this public boundary with the valid domain named
        // (b77ec03e8/b96c01617 precedent). nil = synthesis ("all").
        var singleTier: ContradictionTier?
        if let raw = args["tier"] {
            switch raw {
            case .string("all"):
                singleTier = nil
            case .integer(let n):
                guard let t = ContradictionTier(rawValue: Int(n)) else {
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.invalidParams,
                        message: "tier must be 1, 2, 3, or \"all\"")
                }
                singleTier = t
            default:
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "tier must be 1, 2, 3, or \"all\"")
            }
        }
        // `top_k`: findings per tier section. 1...50 mirrors GLK's
        // `TieredContradictionCore.topKCeiling` clamp — the boundary
        // rejects what the engine would clamp, so the caller learns the
        // domain instead of silently getting less.
        var topK = 5
        if let raw = args["top_k"] {
            guard case .integer(let n) = raw, n >= 1, n <= 50 else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "top_k must be an integer in 1...50")
            }
            topK = Int(n)
        }

        // ---- Single-tier purpose search (read-only, nothing filed) ----
        if let tier = singleTier {
            let report = try await kit.tieredContradictionSearch(
                in: handle, tier: tier, topK: topK,
                probeLimit: probeLimit, now: now)
            // The lexical lanes (2/3) need the vector index; the typed
            // lane (1) does not — diagnostics report true for a
            // tier-1-only run, so this guard cannot misfire there.
            guard report.diagnostics.vectorStoreAvailable else {
                return ToolDispatcher.textResult(
                    "moot_hunt_contradictions: no vector index for this estate — "
                        + "run moot_reindex first, then hunt again.")
            }
            var lines = ["moot_hunt_contradictions: tier \(tier.rawValue) search complete"]
            lines += try await renderTieredSections(
                kit: kit, handle: handle, report: report, laneSeconds: nil)
            return ToolDispatcher.textResult(lines.joined(separator: "\n"))
        }

        // ---- Legacy sweep (tier absent / "all") — unchanged path ----
        // Wall-clock timing wraps the GLK calls at this dispatch layer:
        // the engines are deterministic (no Date() inside), so the I/O
        // boundary is the only place elapsed time may be measured.
        let huntStart = Date()
        // Sensitivity ceiling is hardcoded .elevated (fail-safe by design); huntContradictions does NOT consult SensitivityGrantLedger.
        let report = try await kit.huntContradictions(
            in: handle, probeLimit: probeLimit, now: now)
        let huntSeconds = Date().timeIntervalSince(huntStart)

        guard report.vectorStoreAvailable else {
            return ToolDispatcher.textResult(
                "moot_hunt_contradictions: no vector index for this estate — "
                    + "run moot_reindex first, then hunt again.")
        }

        var lines: [String] = [
            "moot_hunt_contradictions: sweep complete",
            "probesScanned: \(report.probesScanned)",
            "pairsScreened: \(report.pairsScreened)",
            "alreadySettled: \(report.deduplicated)",
            "proposed: \(report.proposed.count)",
        ]
        for p in report.proposed {
            lines.append("  PROPOSED \(p.sourceDrawerID) contradicts \(p.targetDrawerID) "
                + "(\(p.cueKind), score \(p.score), tunnel \(p.tunnelID))")
        }
        if !report.proposed.isEmpty {
            lines.append("Review with moot_lens_contradiction; accept/reject via moot_review_tunnel.")
        }
        lines.append("borderlineCandidates: \(report.borderline.count)")
        for c in report.borderline {
            lines.append("  CANDIDATE \(c.sourceDrawerID) vs \(c.targetDrawerID) "
                + "(\(c.cueKind), score \(c.score))")
            lines.append("    a: \(c.sourceSnippet)")
            lines.append("    b: \(c.targetSnippet)")
        }
        if !report.borderline.isEmpty {
            lines.append("Judge each CANDIDATE pair: if the two memories genuinely conflict, "
                + "record it with moot_link_memories kind=contradicts proposed=true; otherwise ignore it.")
        }
        // DCP M4 — the typed proving lane's additive section (M0 §7).
        lines += try await renderConflictProjection(
            kit: kit, handle: handle,
            estate: kit.estate(for: handle),
            lexicalCandidates: report.borderline.count)

        // MXE-CT3 P3 — appended tiered synthesis digest. Everything above
        // this line is the legacy report, byte-identical to the pre-P3
        // output (the benchmark parser matches the trimmed "PROPOSED "/
        // "CANDIDATE " prefixes and the count lines above — never touch
        // those emitters). Timed at this dispatch layer (I/O boundary).
        let tieredStart = Date()
        let tiered = try await kit.tieredContradictionSearch(
            in: handle, topK: topK, probeLimit: probeLimit, now: now)
        let tieredSeconds = Date().timeIntervalSince(tieredStart)
        lines += try await renderTieredSections(
            kit: kit, handle: handle, report: tiered,
            laneSeconds: [("hunt", huntSeconds), ("synthesis", tieredSeconds)])
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - distill

    /// Run `moot_distill`: trigger a
    /// per-item distillation sweep on demand.
    ///
    /// Decodes the optional `cluster_id` and `include_held` args (accepted
    /// for API stability, not used by the per-item model) and delegates to
    /// the Distill recipe, which calls GLK.distillItemsSweep. Returns a
    /// plain-text summary of items distilled this sweep (drawer rows whose
    /// representation columns were populated — SPEC §3).
    private static func runDistill(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let clusterID = try optionalString(args["cluster_id"], argument: "cluster_id")
        // include_held: boolean parameter — absent means false (the safe default).
        // Present non-bool values are rejected so the caller knows what went wrong.
        let includeHeld: Bool
        if let raw = args["include_held"] {
            guard let b = raw.boolValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "include_held must be a boolean; omit it to use the default (false)")
            }
            includeHeld = b
        } else {
            includeHeld = false
        }

        let out = try await Distill().run(
            input: .init(clusterID: clusterID, includeHeld: includeHeld),
            estate: handle, kit: kit)

        let body = """
        moot_distill: sweep complete
        itemsDistilled: \(out.itemsDistilled)
        """
        return ToolDispatcher.textResult(body)
    }

    // MARK: - recall_distilled

    /// Run `moot_recall_distilled`: exact-search geometry + distilled
    /// hydration (SPEC §10.3).
    ///
    /// Output format:
    ///   found N memory(s) [distilled]
    ///   {id}  [{room}]  {distilled text or content fallback}
    ///       tokens: N | source: distilled            (per-hit metadata)
    ///       tokens: — | source: content (run moot_distill)   (fallback rows)
    ///   discrimination: {level} — {description}
    ///
    /// Ranking is identical to moot_memory_search by construction; only the
    /// payloads differ. Fallback rows (§10.2) still return results — served
    /// from content, with a hint to run moot_distill.
    private static func runVagueRecall(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let query = try requireString(args, "query")
        // Clamp all three bounds at the MCP boundary (DoS prevention),
        // mirroring runPreciseRecall's posture; the verb re-applies D12.
        let hitLimit = try ToolDispatcher.clampLimit(
            try optionalInt(args["hit_limit"], argument: "hit_limit"),
            argument: "hit_limit", default: 8)
        let perHit = try ToolDispatcher.clampLimit(
            try optionalInt(args["constituents_per_hit"], argument: "constituents_per_hit"),
            argument: "constituents_per_hit", default: 8)
        let total = try ToolDispatcher.clampLimit(
            try optionalInt(args["total_constituents"], argument: "total_constituents"),
            argument: "total_constituents", default: 32)

        let out = try await kit.vagueRecall(
            handle, query: query,
            hitLimit: hitLimit,
            constituentsPerHit: perHit,
            totalConstituents: total)

        // Dense-row reply (PR-03): both the vague hits and the hydrated
        // originals travel as dense rows — the AI winnows on subjects and
        // pinpoints via moot_memory_get depth:distilled/full. The vague
        // hits keep a [vague L<n>] tier marker; the two sections are
        // separated by the existing "originals:" divider.
        var lines: [String] = [
            "found \(out.vagueHits.count) vague summary(ies), \(out.constituents.count) hydrated original(s)"
        ]
        for hit in out.vagueHits {
            lines.append("\(DenseRow.render(hit))  [vague L\(hit.vagueLevel)]")
        }
        if !out.constituents.isEmpty {
            lines.append("originals:")
            for c in out.constituents {
                lines.append(DenseRow.render(c))
            }
        }
        if out.vagueHits.isEmpty {
            lines.append("hint: no vague tier hits — the estate has no consolidated summaries matching this query. Normal recall (moot_memory_search / moot_recall_precise) covers current memories.")
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    private static func runRecallDistilled(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let query = try requireString(args, "query")
        // Clamp to [1, 500]: same DoS gate as moot_memory_search and the other
        // recall tools. Parity: Rust run_recall_distilled_tool uses clamp_limit.
        let limit = try ToolDispatcher.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        let filter = try decodeSingleFilter(args["filter"])
        // echo_query: opt-in to append the query text to the response header.
        // Default false — the AI client already knows what it queried.
        // Parity: Rust run_recall_distilled_tool uses the same flag.
        let echoQuery: Bool
        if let raw = args["echo_query"] {
            guard let b = raw.boolValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "echo_query must be a boolean; omit it to use the default (false)")
            }
            echoQuery = b
        } else {
            echoQuery = false
        }

        let out = try await DistilledRecall().run(
            input: .init(query: query, filter: filter, limit: limit),
            estate: handle, kit: kit)

        // Dense-row reply (PR-03): dense row THEN the distilled text — this
        // verb is the "confirm on distilled" tier, so the text stays, but
        // the [distilled] header tag and per-hit tokens:/source: metadata
        // lines are gone (deviation-only: distilled service is the NORM
        // here; only the fallback deviation gets a marker).
        let estate = try await kit.estate(for: handle)
        let denseByID = try await denseRowsByID(
            ids: out.matches.prefix(50).map { $0.id }, estate: estate)
        let header = echoQuery
            ? "found \(out.matches.count) memory(s) for: \(query)"
            : "found \(out.matches.count) memory(s)"
        var lines: [String] = [header]
        var anyFallback = false
        for match in out.matches.prefix(50) {
            lines.append(denseByID[match.id] ?? DenseRow.renderUnhydrated(id: match.id))
            if match.servedFromContent {
                anyFallback = true
                // Fallback marker on fallback hits ONLY (§10.2): the text
                // below is verbatim content, not a distillate.
                lines.append("source: content (not yet distilled)")
            }
            lines.append(match.text)
        }
        // Deviation-only narration (PR-03): discrimination line only on
        // low/medium; clear and single/zero stay silent.
        switch out.discrimination {
        case .medium:
            lines.append("discrimination: medium — partial separation.")
        case .low:
            lines.append("discrimination: low — top results are within epsilon; treat as effectively unranked. "
                + "Prefer moot_recall_precise / moot_memory_search (ordering: byRelevanceDesc) for "
                + "precision, or widen the query.")
        case .high, .single:
            break
        }
        if anyFallback {
            // The SPEC §10.3 fallback notice: results still return, served
            // from content, with a hint to populate the representations.
            lines.append("hint: some results are not yet distilled and were served from full "
                + "content. Run moot_distill to populate distilled representations.")
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - Argument decoding

    private static func requireString(
        _ args: [String: JSONValue], _ key: String
    ) throws -> String {
        guard let v = args[key]?.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Missing required string argument: \(key)")
        }
        return v
    }

    private static func requireUUID(
        _ args: [String: JSONValue], _ key: String
    ) throws -> UUID {
        let raw = try requireString(args, key)
        guard let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Argument \(key) is not a UUID: \(raw)")
        }
        return uuid
    }

    private static func optionalString(_ value: JSONValue?, argument: String) throws -> String? {
        guard let value else { return nil }
        guard let string = value.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be a string; omit it to use the default")
        }
        return string
    }

    private static func optionalInt(_ value: JSONValue?, argument: String) throws -> Int? {
        guard let value else { return nil }
        guard let integer = value.integerValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be an integer; omit it to use the default")
        }
        return Int(integer)
    }

    private static func decodeUUIDArray(_ value: JSONValue?) throws -> [UUID] {
        guard let arr = value?.arrayValue else { return [] }
        var out: [UUID] = []
        out.reserveCapacity(arr.count)
        for element in arr {
            guard let s = element.stringValue, let uuid = UUID(uuidString: s) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "Branch id array contains a non-UUID value")
            }
            out.append(uuid)
        }
        return out
    }

    /// Decode the candidate migration plans.
    private static func decodePlans(_ value: JSONValue?) throws -> [MigrationPlan] {
        guard let arr = value?.arrayValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "plans must be an array")
        }
        return try arr.map { element in
            guard let obj = element.objectValue,
                  let name = obj["name"]?.stringValue,
                  let room = obj["room"]?.stringValue,
                  let code = obj["latticeCode"]?.stringValue,
                  let model = obj["embeddingModelID"]?.stringValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "each plan needs name, room, latticeCode, embeddingModelID")
            }
            let sensitivity = try decodeSensitivity(obj["sensitivity"])
            return MigrationPlan(
                name: name, room: room, latticeCode: code,
                embeddingModelID: model, sensitivity: sensitivity)
        }
    }

    /// Recall filter-chain decode for grounded_synthesis. Omitted filter means
    /// ordinary recall: LocusKit inserts state/trust/sensitivity defaults, but
    /// no confirmation constraint.
    private static func decodeFilterChain(_ value: JSONValue?) throws -> [LocusKit.Filter] {
        guard let name = try optionalString(value, argument: "filter") else { return [] }
        switch name {
        case "unconfirmed": return [.unconfirmed]
        case "userConfirmed": return [.userConfirmed]
        case "exportable": return [.exportable]
        case "contained": return [.contained]
        case "currentlyBelieve": return [.currentlyBelieve]
        // hasLinks filter: constrains grounded synthesis recall to drawers
        // that contain links/citations (bit 15). Enables citation-scoped
        // synthesis — the synthesizer receives only link-bearing sources.
        // Feature-flag adoption §2.
        case "hasLinks": return [.hasFeatureFlag(.hasLinks)]
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown filter: \(name)")
        }
    }

    /// Stopwords excluded from grounding-term extraction: question scaffolding
    /// and function words that would match nearly every memory and destroy the
    /// cue's selectivity. Deliberately small — an over-eager list starts
    /// eating content words. MUST stay byte-identical to Rust
    /// `GROUNDING_STOPWORDS` in recipe_tools.rs (conformance-checked there).
    private static let groundingStopwords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "has", "have", "had",
        "did", "does", "not", "with", "that", "this", "from", "they",
        "their", "them", "then", "than", "there", "these", "those", "you",
        "your", "what", "when", "where", "which", "who", "whom", "why",
        "how", "will", "would", "could", "should", "about", "been", "being",
        "into", "over", "under", "after", "before", "between", "during",
        "any", "all", "each", "most", "some", "such", "can", "may", "might",
        "must", "shall", "its", "his", "her", "him", "she", "our", "out",
        "but", "per", "via", "also", "just", "only", "very", "much", "more",
    ]

    /// Extracts the distinctive grounding terms from a free-text query:
    /// alphanumeric runs, lowercased (content matching is case-insensitive on
    /// both ports), dropping stopwords and short fragments (< 3 chars unless
    /// they carry a digit — "42" or "3b" are distinctive, "at" is not),
    /// deduplicated in first-appearance order, capped at 12 terms so a pasted
    /// paragraph cannot degenerate into an unbounded OR. Deterministic pure
    /// function of the query — MUST stay behavior-identical to Rust
    /// `grounding_terms` in recipe_tools.rs.
    static func groundingTerms(from query: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = raw.lowercased()
            let hasDigit = token.contains { $0.isNumber }
            guard token.count >= 3 || hasDigit else { continue }
            guard !groundingStopwords.contains(token) else { continue }
            guard seen.insert(token).inserted else { continue }
            terms.append(token)
            if terms.count == 12 { break }
        }
        return terms
    }

    /// Shared single-filter decoder used by precise recall, shaped recall, and
    /// distilled recall. Omitted filter maps to the active-recall default
    /// (.currentlyBelieve) without adding a confirmation constraint.
    private static func decodeSingleFilter(_ value: JSONValue?) throws -> LocusKit.Filter {
        guard let name = try optionalString(value, argument: "filter") else { return .currentlyBelieve }
        switch name {
        case "unconfirmed": return .unconfirmed
        case "userConfirmed": return .userConfirmed
        case "exportable": return .exportable
        case "contained": return .contained
        case "currentlyBelieve": return .currentlyBelieve
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown filter: \(name)")
        }
    }

    private static func decodeSensitivity(_ value: JSONValue?) throws -> AdjectiveSensitivity {
        guard let name = try optionalString(value, argument: "sensitivity") else { return .normal }
        switch name {
        case "elevated": return .elevated
        case "restricted": return .restricted
        case "secret": return .secret
        case "normal": return .normal
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown sensitivity: \(name)")
        }
    }

    // MARK: - JSON schema helpers
    //
    // `booleanSchema` is internal on ToolProjection and called directly from
    // this type. `objectSchema`, `stringSchema`, and `integerSchema` below
    // are RecipeTools-local helpers; ToolProjection has no equivalents.

    private static func objectSchema(
        properties: [String: JSONValue], required: [String]
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    private static func stringSchema(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integerSchema(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
