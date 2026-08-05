// LensTools.swift
//
// The CognitionKit reasoning-lens surface on ARIA_MCP — one hard-bound
// tool per cataloged lens recipe (LENS_DISCOVERABILITY_DECISION v2.0:
// listing and invokability ship together; `moot_list_lenses` never
// advertises a behaviour an agent cannot reach). Same dispatch shape as
// RecipeTools: provenance `.recipe`, matched by name above the lexicon
// projection, no generic run-by-name dispatcher.
//
// Tool stem = moot_lens_ + catalog name: moot_lens_keystones … moot_lens_complexity.
// 23 lens tools total: 16 reasoning/federated lenses, 4 temporal/information-
// theoretic lenses (moot_lens_moment, moot_lens_rhythm, moot_lens_precedence,
// moot_lens_complexity), and 3 analytics lenses (moot_lens_associations,
// moot_lens_concepts, moot_lens_apriori). In tools(), the temporal/information-
// theoretic tools are listed before the analytics tools.
// The two federated lenses take a second estate via `estateIDB`,
// resolved through the dispatcher's own estate registry exactly like
// `estateID`.
//
// MX-TAB-7 addition (§4): three analytics lenses gain an optional `dataset_id`
// parameter. When absent → existing estate-drawer behavior is EXACTLY unchanged.
// When present → routes to the CognitionKit dataset-targeted twins:
//   DatasetComplexity.runColumn   (Shannon entropy over dataset column values)
//   DatasetAssociations.run       (association rules over column-value co-occurrence)
//   DatasetCohesion.run           (column-value anomaly scoring)

import Foundation
import GeniusLocusKit
import NeuronKit
import LocusKit
import CognitionKit
import SubstrateML
import PersistenceKit

/// Namespace for the reasoning-lens tool surface. No instances.
enum LensTools {

    // MARK: - Tool names (catalog name with the moot_lens_ stem)

    static let lensToolNames: Set<String> = [
        "moot_lens_keystones", "moot_lens_constellation", "moot_lens_free_association",
        "moot_lens_theme_weather", "moot_lens_latent_themes", "moot_lens_bias",
        "moot_lens_drift",
        // Diffusion node layer: a single memory's motion over time.
        "moot_lens_node_motion",
        // Renamed from moot_lens_contradiction (the lexical-cohesion outlier detector).
        "moot_lens_cohesion",
        // New: genuine contradiction detector — contradicts-tunnels + conflicting KG facts.
        "moot_lens_contradiction",
        "moot_lens_trust_synthesis",
        "moot_lens_partial_cue", "moot_lens_anticipate", "moot_lens_successors",
        "moot_lens_overlap", "moot_lens_divergence",
        // Analytics lenses (AR_FCA_CAPABILITY_001 + Apriori multi-antecedent).
        "moot_lens_associations", "moot_lens_concepts", "moot_lens_apriori",
        // Temporal lenses (Lenses 1–3, Time+Prediction).
        "moot_lens_moment", "moot_lens_rhythm", "moot_lens_precedence",
        // Information-theoretic lens (Lens 4, Topics).
        "moot_lens_complexity",
    ]

    /// True when `name` is one of the lens tools dispatched by name.
    static func isLensTool(_ name: String) -> Bool {
        lensToolNames.contains(name)
    }

    /// How many extent drawer ids a formal-concept row lists before
    /// truncating to "+N more". Twenty matches the default recall frame
    /// limit, so an untruncated extent is the common case; the cap exists so
    /// one giant concept cannot flood the reply. Parity: Rust
    /// `LENS_EXTENT_ID_CAP`.
    static let lensExtentIDCap = 20

    // MARK: - tools/list projection

    static func tools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_lens_keystones",
                description: "Reasoning lens: rank a wing's load-bearing memories by centrality over its drawer-to-drawer tunnel graph.",
                inputSchema: objectSchema(
                    properties: [
                        "wing": stringSchema("The wing whose tunnel graph to read."),
                        "topK": integerSchema("How many keystones to return (default 5)."),
                        "keystoneOnly": booleanSchema("When true, restrict returned candidates to drawers carrying the isKeystone flag (bit 17). Eigenvector centrality is computed over the full tunnel graph; only the surfaced results are filtered. Default false. Omit to use the default; null is invalid."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["wing"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_constellation",
                description: "Reasoning lens: recover the emergent communities of a wing's drawer-to-drawer tunnel graph.",
                inputSchema: objectSchema(
                    properties: [
                        "wing": stringSchema("The wing whose tunnel graph to read."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["wing"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_free_association",
                description: "Reasoning lens: from a seed memory, walk the wing's tunnel graph with restart and rank the memories the walk keeps landing on.",
                inputSchema: objectSchema(
                    properties: [
                        "wing": stringSchema("The wing whose tunnel graph to walk."),
                        "seedDrawerID": stringSchema("The drawer id to associate from."),
                        "walkLength": integerSchema("Walk steps (default 10000)."),
                        "k": integerSchema("How many associations to return (default 10)."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["wing", "seedDrawerID"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_theme_weather",
                description: "Reasoning lens: per-room momentum — recent attention share vs historical share; what's rising and what's fading.",
                inputSchema: objectSchema(
                    properties: [
                        "filter": filterSchema,
                        "halfLifeSeconds": numberSchema("Attention half-life in seconds (default 604800 = 7 days)."),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_latent_themes",
                description: "Reasoning lens: factor the recalled set's metadata co-occurrence into soft latent themes — the emergent topics in how the estate is filed.",
                inputSchema: objectSchema(
                    properties: [
                        "filter": filterSchema,
                        "k": integerSchema("How many themes to factor (default 3)."),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_bias",
                description: "Reasoning lens: representation bias vs a reference, per-room dismissal rates, and learned preference from real curation choices.",
                inputSchema: objectSchema(
                    properties: [
                        "reference": .object([
                            "type": .string("array"),
                            "description": .string("Reference distribution: objects with string label and number mass. Empty = report estate shares alone."),
                            "items": objectSchema(
                                properties: [
                                    "label": stringSchema("Room / category label."),
                                    "mass": numberSchema("Reference mass for the label."),
                                ],
                                required: ["label", "mass"]),
                        ]),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_drift",
                description: "Reasoning lens: how far the room distribution after a split instant has drifted from the distribution before it.",
                inputSchema: objectSchema(
                    properties: [
                        "splitAt": stringSchema("ISO8601 instant splitting the before/after windows."),
                        "filter": filterSchema,
                        "estateID": estateIDSchema,
                    ],
                    required: ["splitAt"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_node_motion",
                description: "Reasoning lens (diffusion, node layer): how a single memory has MOVED over time — its mutation volatility (decay-weighted recent-churn mass), its topic trajectory (the UDC anchors it has occupied), whether it reanchored, and a write-time anomaly verdict (churning / reanchored / stable). Reads the memory's fresh audit history.",
                inputSchema: objectSchema(
                    properties: [
                        "rowID": stringSchema("UUID of the memory (drawer) to read motion for."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["rowID"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_cohesion",
                description: "Reasoning lens: flag recalled memories whose content cohesion with peers is anomalously low (lexical odd-ones-out), or detect column-value anomalies in a dataset when dataset_id is supplied.",
                inputSchema: objectSchema(
                    properties: [
                        "threshold": numberSchema("Z-score magnitude threshold (default 1.5). Estate mode only; ignored when dataset_id is present."),
                        "filter": filterSchema,
                        "dataset_id": stringSchema("Optional UUID of a dataset (from moot_file_dataset). When supplied, scores column-value anomalies instead of lexical outliers."),
                        "top_n": integerSchema("Max anomaly rows to return in dataset mode (default 10). Ignored in estate mode."),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_contradiction",
                description: "Reasoning lens: surface recorded contradictions — drawer pairs connected by a contradicts tunnel (confirmed edges plus PROPOSED agent-derived findings from the contradiction hunter, flagged unreviewed), and KG facts with conflicting objects for the same subject+predicate. Reports recorded links only; to scan memory CONTENT for new conflicts run moot_hunt_contradictions (or moot_dream, which includes a hunt sweep). Settle proposed edges with moot_review_tunnel.",
                inputSchema: objectSchema(
                    properties: [
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_trust_synthesis",
                description: "Reasoning lens: recall, rank by provenance trust (canonical and user above derived), and synthesize the trust-ordered set.",
                inputSchema: objectSchema(
                    properties: [
                        "filter": filterSchema,
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_partial_cue",
                description: "Reasoning lens: one anchor memory, three recalls — feels-like, about-this, from-then — by per-block fingerprint matching. Results include a discrimination signal. Fingerprint-based scores produce narrower relative gaps on small estates (the discrimination signal classifies relative gap — low discrimination here is expected, not an error). For keyword/exact retrieval use moot_recall_precise instead.",
                inputSchema: objectSchema(
                    properties: [
                        "anchorID": stringSchema("The anchor drawer id (the cue)."),
                        "mode": stringSchema("Cue mode: feelsLike (default), aboutThis, fromThen."),
                        "k": integerSchema("How many matches to return (default 5)."),
                        "filter": filterSchema,
                        "estateID": estateIDSchema,
                    ],
                    required: ["anchorID"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_anticipate",
                description: "Reasoning lens: learn which capture actions tend to reach a target outcome, ranked by conservative success rate. Confirmation-level filters in the recall frame (userConfirmed/unconfirmed) are ignored — the lens performs its own dual recall (confirmed = success, unconfirmed = non-success) to compute a differentiated rate; sensitivity and other scoping filters are honored.",
                inputSchema: objectSchema(
                    properties: [
                        "targetKind": stringSchema("Target outcome as a content kind: prose, code, transcript, list, structuredJSON, imageCaption, fingerprintOnly, dataset (dataset targeting arrives in MX-TAB-6 — passing it returns an error for now)."),
                        "k": integerSchema("How many actions to return (default 5)."),
                        "minObservations": integerSchema("Minimum observations per action (default 1)."),
                        "filter": filterSchema,
                        "estateID": estateIDSchema,
                    ],
                    required: ["targetKind"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_successors",
                description: "Reasoning lens: the memories an anchor points onward to by explicit tunnels, ranked by frequency.",
                inputSchema: objectSchema(
                    properties: [
                        "wing": stringSchema("The wing whose tunnels to read."),
                        "anchorID": stringSchema("The anchor drawer id."),
                        "k": integerSchema("How many successors to return (default 5)."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["wing", "anchorID"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_overlap",
                description: "Reasoning lens (federated): privacy-preserving overlap of two estates via differentially-private fingerprint summaries.",
                inputSchema: objectSchema(
                    properties: [
                        "estateID": stringSchema("Optional UUID of estate A. Omit for the default estate."),
                        "estateIDB": stringSchema("UUID of estate B (must be a registered open estate)."),
                        "filter": filterSchema,
                    ],
                    required: ["estateIDB"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_divergence",
                description: "Reasoning lens (federated): how two estates' room distributions diverge, by Jensen-Shannon divergence.",
                inputSchema: objectSchema(
                    properties: [
                        "estateID": stringSchema("Optional UUID of estate A. Omit for the default estate."),
                        "estateIDB": stringSchema("UUID of estate B (must be a registered open estate)."),
                        "filter": filterSchema,
                    ],
                    required: ["estateIDB"]),
                provenance: .recipe),
            // Temporal lenses (Lenses 1–3, Time+Prediction).
            ProjectedTool(
                name: "moot_lens_moment",
                description: "Reasoning lens: OR-reduce the primary window's fingerprints into a temporal signature and rank comparison windows by Hamming proximity.",
                inputSchema: objectSchema(
                    properties: [
                        "windowStart": stringSchema("ISO8601 start of the primary window (inclusive)."),
                        "windowEnd": stringSchema("ISO8601 end of the primary window (inclusive)."),
                        "comparisonWindows": .object([
                            "type": .string("array"),
                            "description": .string("Windows to rank against the primary signature. Each is an object with string fields windowStart and windowEnd."),
                            "items": objectSchema(
                                properties: [
                                    "windowStart": stringSchema("ISO8601 start."),
                                    "windowEnd": stringSchema("ISO8601 end."),
                                ],
                                required: ["windowStart", "windowEnd"]),
                        ]),
                        "estateID": estateIDSchema,
                    ],
                    required: ["windowStart", "windowEnd"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_rhythm",
                description: "Reasoning lens: FFT over a time-bucketed fingerprint bit series to surface the dominant periodic activity patterns.",
                inputSchema: objectSchema(
                    properties: [
                        "bit": integerSchema("Fingerprint bit index to analyse (0–255)."),
                        "bucketSeconds": integerSchema("Duration of each time bucket in seconds."),
                        "bucketCount": integerSchema("Number of buckets back from endingAt."),
                        "endingAt": stringSchema("ISO8601 instant marking the end of the series."),
                        "topK": integerSchema("How many dominant periods to return (default 3)."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["bit", "bucketSeconds", "bucketCount", "endingAt"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_precedence",
                description: "Reasoning lens: fold the estate's audit trail into T-matrix deltas and rank the antecedents most predictive of a target field-value coordinate.",
                inputSchema: objectSchema(
                    properties: [
                        "windowStart": stringSchema("ISO8601 start of the audit window."),
                        "windowEnd": stringSchema("ISO8601 end of the audit window."),
                        "targetField": stringSchema("Field path of the target coordinate (e.g. \"room\")."),
                        "targetValue": stringSchema("Value repr of the target coordinate (e.g. \"string:study\")."),
                        "k": integerSchema("How many antecedents to return (default 5)."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["windowStart", "windowEnd", "targetField", "targetValue"]),
                provenance: .recipe),
            // Information-theoretic lens (Lens 4, Topics).
            ProjectedTool(
                name: "moot_lens_complexity",
                description: "Reasoning lens: Shannon entropy (and optional mutual information) over a label field across the recalled set, or over a dataset column when dataset_id is supplied.",
                inputSchema: objectSchema(
                    properties: [
                        "fieldA": stringSchema("Label field for entropy. Estate mode: room, wing, addedBy, embeddingModelID. Dataset mode (dataset_id present): column name in the dataset."),
                        "fieldB": stringSchema("Optional second label field (or column) for mutual information."),
                        "filter": filterSchema,
                        "dataset_id": stringSchema("Optional UUID of a dataset (from moot_file_dataset). When supplied, fieldA/fieldB are column names; filter is ignored."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["fieldA"]),
                provenance: .recipe),
            // Analytics lenses.
            ProjectedTool(
                name: "moot_lens_associations",
                description: "Recall a frame and mine pairwise association rules over drawer categorical facets, or mine rules over dataset column values when dataset_id is supplied.",
                inputSchema: objectSchema(
                    properties: [
                        "filter": filterSchema,
                        "limit": integerSchema("Max drawers to recall (estate mode) or max rows to scan (dataset mode, default 1000, capped at 10000)."),
                        "minSupport": .object(["type": .string("number"), "description": .string("Minimum rule support (0..1). Default 0.")]),
                        "minConfidence": .object(["type": .string("number"), "description": .string("Minimum rule confidence (0..1). Default 0.")]),
                        "dataset_id": stringSchema("Optional UUID of a dataset (from moot_file_dataset). When supplied, mines rules over dataset column values instead of drawer facets."),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_concepts",
                description: "Recall a frame, build a formal context where each drawer is a row with its categorical facets as attributes, and mine bounded formal concepts.",
                inputSchema: objectSchema(
                    properties: [
                        "filter": filterSchema,
                        "limit": integerSchema("Max drawers to recall."),
                        "minSupport": integerSchema("Minimum concept extent size. Default 1."),
                        "maxIntentSize": integerSchema("Maximum concept intent size. Default 8."),
                        "maxConcepts": integerSchema("Maximum concepts returned. Default 20."),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_lens_apriori",
                description: "Read the estate's audit log and mine multi-antecedent association rules via the Apriori algorithm.",
                inputSchema: objectSchema(
                    properties: [
                        "minSupport": .object(["type": .string("number"), "description": .string("Minimum rule support (0..1). Default 0.")]),
                        "minConfidence": .object(["type": .string("number"), "description": .string("Minimum rule confidence (0..1). Default 0.")]),
                        "minLift": .object(["type": .string("number"), "description": .string("Minimum lift (≥ 1.0 suppresses anti-correlated rules). Default 1.0.")]),
                        "maxK": integerSchema("Maximum total itemset size (antecedent + 1). Default 3."),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
        ]
    }

    // MARK: - Dispatch

    /// Run the named lens tool. Same contract as `RecipeTools.dispatch`:
    /// out-of-band faults throw `JSONRPCError`; lens-level refusals come
    /// back as `errorResult` so the client keeps the call id.
    ///
    /// `resolveHandle` resolves the primary estate from `estateID`; it is
    /// restricted to the default estate per Item 3 hardening.
    /// `resolvePeer` resolves a comparison estate from `estateID`; it is
    /// unrestricted because lens comparisons are read-only cross-estate
    /// operations that are explicitly opt-in via the `estateIDB` argument.
    static func dispatch(
        name: String,
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        defaultHandle: EstateHandle,
        resolveHandle: ([String: JSONValue]) throws -> EstateHandle,
        resolvePeer: ([String: JSONValue]) throws -> EstateHandle
    ) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        switch name {
        case "moot_lens_keystones":
            // Date() is permitted here: this is the ARIA MCP boundary, not a kit.
            // Kits and substrate must never read the clock — the caller provides `now`.
            let ranked = try await Keystones.run(
                kit: kit, handle: handle,
                wing: try requireString(args, "wing"),
                topK: try ToolDispatcher.clampLimit(
                    try integer(args, "topK", default: 5), argument: "topK"),
                now: Date())
            // isKeystone post-filter: when keystoneOnly is true, restrict the
            // returned candidate set to drawers that carry the isKeystone bit
            // (bit 17). Eigenvector centrality is computed over the full tunnel
            // graph (preserving rank ordering); only the surfaced candidates are
            // filtered. Drawers are loaded bitmapOnly — the bitmap check is the
            // only requirement; content is not needed.
            // Feature-flag adoption §3.
            let keystoneOnly = try optionalBool(args["keystoneOnly"], argument: "keystoneOnly") ?? false
            let estate = try await kit.estate(for: handle)
            let filtered: [Keystone]
            if keystoneOnly && !ranked.isEmpty {
                let loadResult = try await estate.getDrawers(
                    ids: ranked.map(\.id),
                    matchingFrame: RecallFrame(filterChain: []),
                    hydrationLevel: .bitmapOnly)
                let keystoneIDs = Set(loadResult.admissible
                    .filter { $0.hasFeatureFlag(.isKeystone) }
                    .map(\.id))
                filtered = ranked.filter { keystoneIDs.contains($0.id) }
            } else {
                filtered = ranked
            }
            // Dense-row citations: every keystone finding carries its drawer
            // address and lattice metadata so the caller can memory_get it
            // immediately (progressive-recall rule). The centrality score is
            // appended after the dense row as the lens-specific signal.
            let denseByID = try await RecipeTools.denseRowsByID(ids: filtered.map(\.id), estate: estate)
            return list("keystones", filtered.map {
                let row = denseByID[$0.id] ?? DenseRow.renderUnhydrated(id: $0.id)
                return "\(row) centrality=\($0.centrality)"
            })

        case "moot_lens_constellation":
            // Date() is permitted here: this is the ARIA MCP boundary, not a kit.
            // Kits and substrate must never read the clock — the caller provides `now`.
            let out = try await ConstellationLens.run(
                kit: kit, handle: handle, wing: try requireString(args, "wing"),
                now: Date())
            return list("constellation", out.communities.map { $0.joined(separator: ", ") })

        case "moot_lens_free_association":
            let out = try await FreeAssociationLens.run(
                kit: kit, handle: handle,
                wing: try requireString(args, "wing"),
                seedDrawerID: try requireString(args, "seedDrawerID"),
                // walkLength ceiling 100_000: walk steps are bounded separately from
                // result counts; the default (10_000) is well within the ceiling, but
                // an attacker can pass Int.max to exhaust CPU. Parity: Rust uses
                // clamp_limit(walk_length, "walkLength", 10_000, 100_000).
                walkLength: try ToolDispatcher.clampLimit(
                    try integer(args, "walkLength", default: 10_000),
                    argument: "walkLength", ceiling: 100_000),
                k: try ToolDispatcher.clampLimit(
                    try integer(args, "k", default: 10), argument: "k"))
            // free_association is a forward walk; a seed with no outgoing tunnels
            // (or one not present in the wing) yields no associations. Return a
            // hint rather than a bare "0 results" that reads as an empty estate.
            if out.isEmpty {
                return ToolDispatcher.textResult(
                    "free_association: 0 associations — the seed drawer has no outgoing tunnels to "
                    + "walk (this lens is a forward walk), or the seed is not in the given wing. Use "
                    + "moot_connection_map to see links pointing into this drawer.")
            }
            // Dense-row citations: each associated memory carries its address
            // and lattice metadata so the caller can memory_get it immediately
            // (progressive-recall rule). The activation score is appended after
            // the dense row as the lens-specific signal.
            let faEstate = try await kit.estate(for: handle)
            let faDenseByID = try await RecipeTools.denseRowsByID(
                ids: out.map(\.drawerID), estate: faEstate)
            return list("free_association", out.map {
                let row = faDenseByID[$0.drawerID] ?? DenseRow.renderUnhydrated(id: $0.drawerID)
                return "\(row) activation=\($0.activation)"
            })

        case "moot_lens_theme_weather":
            let weather = try await ThemeWeather.run(
                kit: kit, handle: handle, frame: try frame(args),
                halfLifeSeconds: try number(args, "halfLifeSeconds", default: 604_800),
                now: Date())
            return list("theme_weather", weather.map { "\($0.category) momentum=\($0.momentum)" })

        case "moot_lens_latent_themes":
            let themes = try await LatentThemesLens.run(
                kit: kit, handle: handle, frame: try frame(args),
                k: try integer(args, "k", default: 3))
            return list(
                "latent_themes (k=\(themes.k))",
                themes.loadings.map { "\($0.label) → theme \($0.dominantTheme)" })

        case "moot_lens_bias":
            let report = try await Bias.run(
                kit: kit, handle: handle, reference: try decodeReference(args["reference"]))
            var lines = ["bias"]
            lines.append("for:")
            lines += report.biasedFor.map { "  \($0.label) bias=\($0.bias)" }
            lines.append("against:")
            lines += report.biasedAgainst.map { "  \($0.label) bias=\($0.bias)" }
            lines.append("dismissal:")
            // DismissalRate carries nodeId (parentNodeId); resolve to display
            // room name via the node tree for human-readable output.
            let dismissalNodeNames = try await kit.estate(for: handle)
                .resolveNodeNames(parentNodeIds: report.dismissal.map(\.nodeId))
            lines += report.dismissal.map {
                let room = dismissalNodeNames[$0.nodeId]?.room ?? $0.nodeId
                return "  \(room) rate=\($0.rate)"
            }
            lines.append("learned:")
            lines += report.learned.map {
                "  \($0.label) strength=\($0.strength) (+\($0.endorsements)/−\($0.dismissals))"
            }
            return ToolDispatcher.textResult(lines.joined(separator: "\n"))

        case "moot_lens_drift":
            let out = try await Drift.run(
                kit: kit, handle: handle, frame: try frame(args),
                splitAt: try requireDate(args, "splitAt"))
            return ToolDispatcher.textResult("""
            drift: before=\(out.beforeCount) after=\(out.afterCount)
            jensenShannon: \(out.drift.jensenShannon)
            klDivergence: \(out.drift.klDivergence)
            """)

        case "moot_lens_cohesion":
            // Dataset mode: dataset_id present → column-value anomaly scoring (MX-TAB-7).
            // Calls DatasetCohesion.run over rows fetched from the DatasetStore.
            // When absent → estate-mode lexical outlier path below is EXACTLY unchanged.
            if let dsID = try optionalString(args["dataset_id"], argument: "dataset_id") {
                let resolved: (uuid: UUID, drawer: Drawer, content: DatasetHandleContent?, store: any DatasetStore)
                do {
                    resolved = try await resolveDataset(
                        idStr: dsID, kit: kit, handle: handle, toolName: "moot_lens_cohesion")
                } catch let e as DatasetResolutionError {
                    switch e {
                    case .refusal(let r): return r
                    case .fault(let f): throw f
                    }
                }
                let (uuid, _, content, datasetStore) = resolved
                // Column order from handle content is required: DatasetCohesion.run takes
                // [[DatasetColumnValue]] where each row is indexed by column position,
                // not by name. Without the schema, columns cannot be reliably ordered.
                guard let c = content else {
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.internalError,
                        message: "moot_lens_cohesion: cannot read dataset column schema (handle content missing or malformed)")
                }
                let colOrder = c.columns.map { $0.name }
                let topN = max(1, try integer(args, "top_n", default: 10))
                let rows: [StorageRow]
                do {
                    rows = try await datasetStore.queryRows(
                        id: uuid, predicate: nil, orderBy: [],
                        limit: datasetLensRowCap, offset: nil, columns: nil)
                } catch {
                    return ToolDispatcher.errorResult(
                        "moot_lens_cohesion: query failed: " + error.localizedDescription)
                }
                // Project each StorageRow as [DatasetColumnValue] in column-declaration order.
                // Numeric TypedValues (.int, .bitmap, .float) → .numeric(Double).
                // Bool/text/uuid/timestamp → .categorical(string). null → .null.
                let projectedRows: [[DatasetColumnValue]] = rows.map { row in
                    colOrder.map { colName -> DatasetColumnValue in
                        guard let tv = row.values[colName] else { return .null }
                        return typedValueToDatasetColumnValue(tv)
                    }
                }
                let dsOut = DatasetCohesion.run(rows: projectedRows, topN: topN)
                var dsLines = [
                    "dataset_cohesion: scored \(dsOut.rowsScored) row(s) of dataset \(uuid.uuidString) — top \(dsOut.topAnomalies.count) anomaly row(s):",
                ]
                if dsOut.topAnomalies.isEmpty {
                    dsLines.append("  (no rows scored)")
                } else {
                    for a in dsOut.topAnomalies {
                        // f64 shortest roundtrip: String(a.score) matches the Rust twin.
                        dsLines.append("  row[\(a.rowIndex)] score=\(String(a.score))")
                    }
                }
                return ToolDispatcher.textResult(dsLines.joined(separator: "\n"))
            }

            // Estate mode: lexical-cohesion outlier detector (formerly moot_lens_contradiction).
            // Surfaces memories whose content similarity with their peers is
            // anomalously low — the lexical odd-ones-out.
            let out = try await Contradiction.run(
                kit: kit, handle: handle, frame: try frame(args),
                threshold: Float(try number(args, "threshold", default: 1.5)))
            // Dense-row citations: each outlier memory carries its address and
            // lattice metadata so the caller can memory_get it immediately
            // (progressive-recall rule). The outlier ids are drawer ids.
            let cohEstate = try await kit.estate(for: handle)
            let cohDenseByID = try await RecipeTools.denseRowsByID(
                ids: out.outliers, estate: cohEstate)
            return list(
                "cohesion_outliers (considered \(out.considered))",
                out.outliers.map { cohDenseByID[$0] ?? DenseRow.renderUnhydrated(id: $0) })

        case "moot_lens_contradiction":
            // Genuine contradiction detector: (a) drawer pairs linked by a
            // `contradicts` tunnel; (b) KG facts with conflicting objects for
            // the same (subject.lowercased, predicate.lowercased) key.
            let estate = try await kit.estate(for: handle)
            let allTunnels = try await estate.allTunnels()
            // (a) Contradicts-tunnel pairs — non-tombstoned and within the MCP
            // disclosure ceiling. Drops Restricted/Secret tunnels before any output,
            // parity with the default BitmapEvaluator ceiling (SensitivityAtMost(Elevated))
            // that normal recall applies via insertDefaults. Filter at the ARIA tool
            // boundary only — allTunnels() has internal callers that need the full set.
            // Lifecycle tiers: ACTIVE edges are confirmed; PROPOSED edges (the
            // contradiction hunter's agent-derived findings, and agent-filed
            // proposed links) are shown by default but flagged unreviewed.
            // Withdrawn (rejected) and superseded edges are settled history
            // and never surface here.
            let contradictsTunnels = allTunnels.filter {
                $0.kind == .contradicts && $0.tombstonedAt == nil
                    && ($0.lifecycle == .active || $0.lifecycle == .proposed)
                    && $0.adjectiveSensitivity.isBulkExportable
            }
            // Source-ID gate: an exportable tunnel may still point at a
            // Restricted/Secret drawer. getDrawers with the default frame returns
            // admissible (within ceiling) + loadedIDs (all existing); the
            // difference is the blocked set. Wing-fallback strings are not drawer
            // ids, never load, and pass through. Parity with runFactSearch.
            let emittedTunnels = Array(contradictsTunnels.prefix(50))
            let endpointIDs = Set(emittedTunnels.flatMap {
                [$0.sourceDrawerId, $0.targetDrawerId].compactMap { $0 }
            })
            let hiddenTunnelEndpointIDs: Set<String>
            // isKeystone contradiction weighting: sort emitted tunnels so pairs
            // where either endpoint carries the isKeystone bit surface first.
            // Drawers are loaded structured alongside the existing admissibility
            // check; the sort uses those same loaded rows AND they seed the
            // dense-row map for Part B citations (reuses the structured fetch —
            // no second round-trip needed).
            // Feature-flag adoption §3.
            let keystoneEndpointIDs: Set<String>
            // Dense-row map: id → rendered row for admissible contradiction
            // endpoints. Admissible drawers are already .structured here, so
            // DenseRow.render() can be called directly — no extra fetch.
            var contradictionDenseByID: [String: String] = [:]
            if endpointIDs.isEmpty {
                hiddenTunnelEndpointIDs = []
                keystoneEndpointIDs = []
            } else {
                let result = try await estate.getDrawers(
                    ids: Array(endpointIDs),
                    matchingFrame: RecallFrame(filterChain: []),
                    hydrationLevel: .structured)
                let admissibleIDs = Set(result.admissible.map { $0.id })
                hiddenTunnelEndpointIDs = result.loadedIDs.subtracting(admissibleIDs)
                keystoneEndpointIDs = Set(result.admissible
                    .filter { $0.hasFeatureFlag(.isKeystone) }
                    .map(\.id))
                // Build the dense-row map from the same admissible drawers —
                // avoids a second getDrawers round-trip for citation rendering.
                contradictionDenseByID = Dictionary(uniqueKeysWithValues:
                    result.admissible.map { ($0.id, DenseRow.render($0)) })
            }
            // Stable sort: keystone-involving contradictions first, then original
            // order. `.stable` is not needed (sort is applied to the prefix slice
            // rather than the full list; the relative order within each group is
            // preserved because Swift's sort is stable per se since Swift 5).
            let keystoneFirst = emittedTunnels.sorted { lhs, rhs in
                let lhsHas = [lhs.sourceDrawerId, lhs.targetDrawerId]
                    .compactMap { $0 }.contains { keystoneEndpointIDs.contains($0) }
                let rhsHas = [rhs.sourceDrawerId, rhs.targetDrawerId]
                    .compactMap { $0 }.contains { keystoneEndpointIDs.contains($0) }
                return lhsHas && !rhsHas
            }
            var lines: [String] = []
            if contradictsTunnels.isEmpty {
                lines.append("contradicts_tunnels: none")
            } else {
                lines.append("contradicts_tunnels: \(contradictsTunnels.count)")
                for t in keystoneFirst {
                    // Dense-row citation: when the endpoint is a known drawer
                    // within the sensitivity ceiling, surface its full dense
                    // row so the caller can follow up via memory_get. When
                    // hidden (outside the ceiling) show the redaction marker;
                    // when the tunnel has no drawer id (wing-fallback) show the
                    // wing/room coordinate. Parity: Rust contradiction arm.
                    let src: String
                    if let sid = t.sourceDrawerId {
                        src = hiddenTunnelEndpointIDs.contains(sid)
                            ? "<hidden>"
                            : (contradictionDenseByID[sid] ?? DenseRow.renderUnhydrated(id: sid))
                    } else {
                        src = "\(t.sourceWing)/\(t.sourceRoom)"
                    }
                    let tgt: String
                    if let tid = t.targetDrawerId {
                        tgt = hiddenTunnelEndpointIDs.contains(tid)
                            ? "<hidden>"
                            : (contradictionDenseByID[tid] ?? DenseRow.renderUnhydrated(id: tid))
                    } else {
                        tgt = "\(t.targetWing)/\(t.targetRoom)"
                    }
                    let tier = t.lifecycle == .proposed
                        ? " [proposed (agent-derived, unreviewed) — accept/reject via moot_review_tunnel]"
                        : ""
                    lines.append("  \(src) contradicts \(tgt) (tunnel \(t.id))\(tier)")
                }
            }
            // (b) Conflicting KG facts — apply MCP disclosure ceiling before grouping.
            // Drops Restricted/Secret facts, parity with SensitivityAtMost(Elevated) that
            // normal recall applies. Filter at the ARIA tool boundary only — recallKGFacts
            // has internal callers that need the full set.
            // Group by (subject.lowercased, predicate.lowercased), flag groups where
            // >1 distinct active object exists.
            let allFacts = (try await kit.recallKGFacts(handle)).filter {
                $0.adjectiveSensitivity.isBulkExportable
            }
            var factsByKey: [String: [KGFact]] = [:]
            for fact in allFacts {
                let key = "\(fact.subject.lowercased())|\(fact.predicate.lowercased())"
                factsByKey[key, default: []].append(fact)
            }
            let conflicting = factsByKey.filter { _, facts in
                Set(facts.map { $0.object.lowercased() }).count > 1
            }
            // Source-ID gate for fact sources — same ceiling-difference method.
            let factSourceIDs = Set(allFacts.map { $0.sourceDrawerID })
            let hiddenFactSourceIDs: Set<String>
            if factSourceIDs.isEmpty {
                hiddenFactSourceIDs = []
            } else {
                let result = try await estate.getDrawers(
                    ids: Array(factSourceIDs),
                    matchingFrame: RecallFrame(filterChain: []),
                    hydrationLevel: .structured)
                let admissibleIDs = Set(result.admissible.map { $0.id })
                hiddenFactSourceIDs = result.loadedIDs.subtracting(admissibleIDs)
            }
            if conflicting.isEmpty {
                lines.append("conflicting_facts: none")
            } else {
                lines.append("conflicting_facts: \(conflicting.count) subject+predicate pair(s)")
                let formatter = ISO8601DateFormatter()
                for (key, facts) in conflicting.sorted(by: { $0.key < $1.key }).prefix(20) {
                    let parts = key.split(separator: "|", maxSplits: 1)
                    lines.append("  [\(parts.first ?? "")] \(parts.last ?? "")")
                    for fact in facts {
                        let filed = formatter.string(from: fact.filedAt)
                        let source = hiddenFactSourceIDs.contains(fact.sourceDrawerID)
                            ? "<hidden>" : fact.sourceDrawerID
                        lines.append(
                            "    \(fact.id)  object=[\(fact.object)]  "
                            + "source=\(source)  filed=\(filed)"
                        )
                    }
                }
            }
            // DCP M4 — route through the typed evaluator: the same
            // additive section (M0 §7) every contradiction surface
            // appends. The legacy grouped-objects view above remains
            // decodable and unchanged; the lens has no lexical lane, so
            // no candidates line.
            lines += try await RecipeTools.renderConflictProjection(
                kit: kit, handle: handle, estate: estate,
                lexicalCandidates: nil)
            return ToolDispatcher.textResult(lines.joined(separator: "\n"))

        case "moot_lens_trust_synthesis":
            let out = try await TrustLens.run(
                kit: kit, handle: handle, frame: try frame(args))
            // Dense-row citations: each ranked memory carries its address and
            // lattice metadata so the caller can memory_get it immediately
            // (progressive-recall rule). Ranked order is preserved — the first
            // row is the most trust-grounded hit.
            let tsEstate = try await kit.estate(for: handle)
            let tsDenseByID = try await RecipeTools.denseRowsByID(
                ids: out.rankedIDs, estate: tsEstate)
            var tsLines = [
                "trust_grounded_synthesis: \(out.rankedIDs.count) drawer(s), \(out.highTrustCount) high-trust",
            ]
            for id in out.rankedIDs {
                tsLines.append("  " + (tsDenseByID[id] ?? DenseRow.renderUnhydrated(id: id)))
            }
            tsLines.append("summary: \(out.context.summary)")
            return ToolDispatcher.textResult(tsLines.joined(separator: "\n"))

        case "moot_lens_partial_cue":
            do {
                let rawK = try integer(args, "k", default: 5)
                let k = max(0, rawK)
                let out = try await PartialCueRecall.run(
                    kit: kit, handle: handle, frame: try frame(args),
                    anchorID: try requireString(args, "anchorID"),
                    mode: try decodeCueMode(args["mode"]),
                    k: k)
                // Discrimination signal: partial_cue scores are fingerprint-based
                // and tend to be near-flat on small corpora — surface this honestly.
                let cueScores = out.map { $0.score }
                let cueDiscrimination = RecallDiscrimination.classify(cueScores)
                let discriminationLine = RecallDiscrimination.resultLine(for: cueDiscrimination)
                // Dense-row citations: each match carries its address and lattice
                // metadata so the caller can memory_get it immediately
                // (progressive-recall rule). The score is appended as the
                // lens-specific signal after the dense row.
                let pcEstate = try await kit.estate(for: handle)
                let pcDenseByID = try await RecipeTools.denseRowsByID(
                    ids: out.map(\.id), estate: pcEstate)
                let resultLines = out.map {
                    let row = pcDenseByID[$0.id] ?? DenseRow.renderUnhydrated(id: $0.id)
                    return "\(row) score=\($0.score)"
                }
                var body = "partial_cue_recall: \(resultLines.count) result(s)"
                for line in resultLines { body += "\n  - \(line)" }
                body += "\n\(discriminationLine)"
                return ToolDispatcher.textResult(body)
            } catch let error as AnchorNotInRecalledSetError {
                // The cue pointed at nothing — a lens-level refusal, not
                // a transport fault.
                return ToolDispatcher.errorResult(
                    "anchor '\(error.anchorID)' is not in the recalled set")
            }

        case "moot_lens_anticipate":
            guard let kind = decodeContentKind(try requireString(args, "targetKind")) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "targetKind is not a content kind name")
            }
            // dataset targeting is not yet supported — dataset-handle creation
            // and lens integration arrive in MX-TAB-6. Reject early with a
            // clear message so the caller understands the future-arrival intent.
            if kind == .dataset {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "dataset targeting is not yet supported (arrives in MX-TAB-6)")
            }
            let predictions = try await Anticipate.run(
                kit: kit, handle: handle, frame: try frame(args),
                targetOutcome: UInt8(kind.rawValue),
                k: try integer(args, "k", default: 5),
                minObservations: UInt32(try integer(args, "minObservations", default: 1)))
            return list("anticipate", predictions.map {
                "action=\(channelName($0.action)) successRate=\($0.successRate) n=\($0.count)"
            })

        case "moot_lens_node_motion":
            let rowID = try requireString(args, "rowID")
            // Sensitivity gate — mirrors the default BitmapEvaluator ceiling
            // (SensitivityAtMost(.elevated)) that normal recall applies. Without
            // this check, audit metadata (volatility, event count, UDC trajectory)
            // for restricted/secret rows would be visible to any caller regardless
            // of sensitivity tier, bypassing the access-control posture.
            //
            // Resolution order:
            //   1. Drawer not found (unknown id)          → not-found error
            //   2. Drawer tombstoned                      → not-found error
            //      (tombstoned = permanently erased; audit data must not surface)
            //   3. Sensitivity above .elevated (restricted or secret) → not-found
            //      (matches the BitmapEvaluator ceiling for default recall)
            //   4. Otherwise → proceed to motion fold
            let estate = try await kit.estate(for: handle)
            let resolved = try await estate.getDrawers(ids: [rowID])
            guard let drawer = resolved.first else {
                return ToolDispatcher.errorResult("memory not found: \(rowID)")
            }
            guard drawer.tombstonedAt == nil else {
                return ToolDispatcher.errorResult("memory not found: \(rowID)")
            }
            guard drawer.adjectiveSensitivity.isBulkExportable else {
                // Sensitivity above the default ceiling (restricted or secret) —
                // treat as not found to avoid leaking the existence of these
                // memories. isBulkExportable is true for normal + elevated, false
                // for restricted + secret, matching BitmapEvaluator's ceiling.
                return ToolDispatcher.errorResult("memory not found: \(rowID)")
            }
            let motion = try await NodeMotionLens.run(kit: kit, handle: handle, rowID: rowID)
            let anomaly = NodeMotionLens.classify(motion: motion)
            let trajectory = motion.anchorTrajectory.map(String.init).joined(separator: " → ")
            let verdict = anomaly.isChurning ? "churning"
                : (anomaly.reanchored ? "reanchored" : "stable")
            return ToolDispatcher.textResult("""
            node_motion: \(rowID)
              volatility: \(String(format: "%.3f", motion.volatility)) over \(motion.eventCount) event(s)
              topic trajectory: \(trajectory.isEmpty ? "(none)" : trajectory)
              reanchored: \(motion.reanchored)  current_anchor: \(motion.currentAnchor.map(String.init) ?? "none")
              anomaly: \(verdict)\(anomaly.isAnomalous ? "  ⚠" : "")
            """)

        case "moot_lens_successors":
            let out = try await TunnelSuccessor.run(
                kit: kit, handle: handle,
                wing: try requireString(args, "wing"),
                anchorID: try requireString(args, "anchorID"),
                k: try integer(args, "k", default: 5))
            // Dense-row citations: each successor carries its address and
            // lattice metadata so the caller can memory_get it immediately
            // (progressive-recall rule). The tunnel weight is appended as the
            // lens-specific signal after the dense row.
            let sucEstate = try await kit.estate(for: handle)
            let sucDenseByID = try await RecipeTools.denseRowsByID(
                ids: out.map(\.id), estate: sucEstate)
            return list("tunnel_successor", out.map {
                let row = sucDenseByID[$0.id] ?? DenseRow.renderUnhydrated(id: $0.id)
                return "\(row) weight=\($0.weight)"
            })

        case "moot_lens_overlap":
            // resolvePeer is used here (not resolveHandle) because estateIDB
            // is a legitimate cross-estate comparison target, not CRUD routing.
            let handleB = try resolvePeer(secondEstateArgs(args))
            // Reject self-comparison — overlap of an estate with itself always
            // produces a degenerate result (overlap=1.0) that provides no
            // useful signal and may confuse the caller.
            guard handleB.estateUUID != handle.estateUUID else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "estateIDB resolves to the same estate as estateID; self-comparison is not meaningful for overlap."
                )
            }
            let out = try await MindOverlapLens.run(
                kit: kit, handleA: handle,
                handleB: handleB,
                frame: try frame(args))
            return ToolDispatcher.textResult(
                "mind_overlap: \(out.overlap) "
                + "(a: \(out.aSufficient ? "sufficient" : "insufficient") data, "
                + "b: \(out.bSufficient ? "sufficient" : "insufficient") data)")

        case "moot_lens_divergence":
            // resolvePeer is used here (not resolveHandle) because estateIDB
            // is a legitimate cross-estate comparison target, not CRUD routing.
            let handleBD = try resolvePeer(secondEstateArgs(args))
            // Reject self-comparison — divergence of an estate with itself always
            // produces a degenerate result (JS=0) that provides no useful signal.
            guard handleBD.estateUUID != handle.estateUUID else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "estateIDB resolves to the same estate as estateID; self-comparison is not meaningful for divergence."
                )
            }
            let out = try await EstateDivergenceLens.run(
                kit: kit, handleA: handle,
                handleB: handleBD,
                frame: try frame(args))
            return ToolDispatcher.textResult("""
            estate_divergence: jensenShannon=\(out.divergence.jensenShannon) klDivergence=\(out.divergence.klDivergence)
            a=\(out.aCount) drawer(s), b=\(out.bCount) drawer(s)
            """)

        case "moot_lens_associations":
            // minSupport/minConfidence are parsed before the dataset-mode branch so that
            // type-validation errors are surfaced regardless of which path executes.
            let minSupport = try doubleArg(args["minSupport"], argument: "minSupport") ?? 0.0
            let minConfidence = try doubleArg(args["minConfidence"], argument: "minConfidence") ?? 0.0

            // Dataset mode: dataset_id present → mine rules over dataset column values (MX-TAB-7).
            // Projects each row as a {columnName: value} dictionary with nulls excluded.
            // When absent → estate-mode path below is EXACTLY unchanged.
            if let dsID = try optionalString(args["dataset_id"], argument: "dataset_id") {
                let resolved: (uuid: UUID, drawer: Drawer, content: DatasetHandleContent?, store: any DatasetStore)
                do {
                    resolved = try await resolveDataset(
                        idStr: dsID, kit: kit, handle: handle, toolName: "moot_lens_associations")
                } catch let e as DatasetResolutionError {
                    switch e {
                    case .refusal(let r): return r
                    case .fault(let f): throw f
                    }
                }
                let (uuid, _, _, datasetStore) = resolved
                // `limit` applies to dataset rows. When absent, default = cap = datasetLensRowCap
                // (10 000). clampLimit rejects negatives and enforces the ceiling.
                let rowLimit = try ToolDispatcher.clampLimit(
                    try optionalInt(args["limit"], argument: "limit"),
                    argument: "limit",
                    default: datasetLensRowCap,
                    ceiling: datasetLensRowCap)
                let rows: [StorageRow]
                do {
                    rows = try await datasetStore.queryRows(
                        id: uuid, predicate: nil, orderBy: [],
                        limit: rowLimit, offset: nil, columns: nil)
                } catch {
                    return ToolDispatcher.errorResult(
                        "moot_lens_associations: query failed: " + error.localizedDescription)
                }
                // Project rows as [[String: String]] — null values excluded (no natural label).
                // typedValueToLabelString produces bare values ("Chicago" not "\"Chicago\"")
                // so labels read as "columnName:value" without JSON escaping artifacts.
                let projectedRows: [[String: String]] = rows.map { row in
                    var dict: [String: String] = [:]
                    for (col, tv) in row.values {
                        if case .null = tv { continue }
                        dict[col] = typedValueToLabelString(tv)
                    }
                    return dict
                }
                let dsOut = DatasetAssociations.run(
                    rows: projectedRows,
                    thresholds: MiningThresholds(minSupport: minSupport, minConfidence: minConfidence))
                var dsLines = [
                    "dataset_associations: \(dsOut.rules.count) rule(s) from \(dsOut.rowCount) row(s) (dataset \(uuid.uuidString))",
                ]
                if dsOut.labelOverflow {
                    dsLines.append("note: label vocabulary was capped at 64; some column:value pairs were dropped")
                }
                for rule in dsOut.rules {
                    dsLines.append(
                        "  \(rule.antecedent) → \(rule.consequent): "
                        + "sup=\(String(format: "%.3f", rule.support)) "
                        + "conf=\(String(format: "%.3f", rule.confidence)) "
                        + "lift=\(String(format: "%.3f", rule.lift))")
                }
                return ToolDispatcher.textResult(dsLines.joined(separator: "\n"))
            }

            // Estate mode: recall drawers, mine rules over categorical drawer facets.
            let filterChain = try decodeFilterChain(args["filter"])
            // Route through clampLimit so negative and over-ceiling values are
            // rejected/clamped at the MCP boundary. Parity: Rust lens_tools.rs
            // moot_lens_associations uses clamp_limit with the same ceiling.
            let limit = try ToolDispatcher.clampLimit(
                try optionalInt(args["limit"], argument: "limit"), argument: "limit")
            let arFrame = LocusKit.RecallFrame(
                filterChain: filterChain,
                hydrationLevel: .structured,
                limit: limit,
                ordering: .byCaptureTimeDesc)
            let arOut = try await AssociationRules().run(
                input: .init(
                    frame: arFrame,
                    thresholds: MiningThresholds(minSupport: minSupport, minConfidence: minConfidence)),
                estate: handle, kit: kit)
            var arLines = [
                "association_rules: \(arOut.rules.count) rule(s) from \(arOut.drawerCount) drawer(s)",
            ]
            if arOut.labelOverflow {
                arLines.append("note: label vocabulary was capped at 64; some labels were dropped")
            }
            for rule in arOut.rules {
                arLines.append(
                    "  \(rule.antecedent) → \(rule.consequent): "
                    + "sup=\(String(format: "%.3f", rule.support)) "
                    + "conf=\(String(format: "%.3f", rule.confidence)) "
                    + "lift=\(String(format: "%.3f", rule.lift))")
                // Exemplar addresses so the rule's evidence is hydratable
                // (progressive-recall rule: findings carry cursors). Absent
                // for dataset-mode rules, whose rows are not drawers.
                if !rule.exemplarDrawerIDs.isEmpty {
                    arLines.append(
                        "    exemplars: \(rule.exemplarDrawerIDs.joined(separator: ", "))")
                }
            }
            return ToolDispatcher.textResult(arLines.joined(separator: "\n"))

        case "moot_lens_moment":
            let windowStart = try requireDate(args, "windowStart")
            let windowEnd = try requireDate(args, "windowEnd")
            // Window validation: requireWindowRange rejects reversed windows (Swift
            // ClosedRange would trap at runtime on start > end) and caps the span to
            // 3 years (DoS prevention — scanning decades exhausts memory).
            // Parity: Rust moot_lens_moment uses require_window_range with the same checks.
            let momentWindow = try requireWindowRange(start: windowStart, end: windowEnd)
            let compWindows = try decodeComparisonWindows(args["comparisonWindows"])
            let out = try await Moment.run(
                kit: kit, handle: handle,
                window: momentWindow,
                comparisonWindows: compWindows,
                now: Date())
            var momentLines = [
                "moment: window=\(out.windowCount) fingerprint(s), "
                    + "\(out.result.ranking.count) comparison(s) ranked",
            ]
            for (i, rank) in out.result.ranking.enumerated() {
                momentLines.append("  comparison[\(i)] hammingDistance=\(rank.hammingDistance)")
            }
            return ToolDispatcher.textResult(momentLines.joined(separator: "\n"))

        case "moot_lens_rhythm":
            let bit = try integer(args, "bit", default: 0)
            let bucketSeconds = try integer(args, "bucketSeconds", default: 86400)
            let bucketCount = try integer(args, "bucketCount", default: 32)
            let endingAt = try requireDate(args, "endingAt")
            let topK = try ToolDispatcher.clampLimit(
                try integer(args, "topK", default: 3), argument: "topK")
            let out = try await Rhythm.run(
                kit: kit, handle: handle,
                bit: bit,
                bucketSeconds: bucketSeconds,
                bucketCount: bucketCount,
                endingAt: endingAt,
                topK: topK,
                now: Date())
            return list(
                "rhythm (bucketCount=\(out.bucketCount))",
                out.periods.map {
                    "period=\($0.periodSeconds)s magnitude=\($0.relativeMagnitude)"
                })

        case "moot_lens_precedence":
            let windowStart = try requireDate(args, "windowStart")
            let windowEnd = try requireDate(args, "windowEnd")
            // Window validation: same guards as moot_lens_moment — ordering check
            // (ClosedRange would trap) plus 3-year cap.
            // Parity: Rust moot_lens_precedence uses require_window_range.
            let precedenceWindow = try requireWindowRange(start: windowStart, end: windowEnd)
            let targetField = try requireString(args, "targetField")
            let targetValue = try requireString(args, "targetValue")
            let k = try ToolDispatcher.clampLimit(
                try integer(args, "k", default: 5), argument: "k")
            let out = try await Precedence.run(
                kit: kit, handle: handle,
                window: precedenceWindow,
                target: TemporalFieldCoord(fieldPath: targetField, valueRepr: targetValue),
                k: k,
                now: Date())
            return list(
                "precedence (entryCount=\(out.entryCount))",
                out.antecedents.map {
                    "\($0.source.fieldPath)=\($0.source.valueRepr) "
                        + "lag=\($0.lagBucket)min count=\($0.count)"
                })

        case "moot_lens_complexity":
            let fieldA = try requireString(args, "fieldA")
            let fieldB = try optionalString(args["fieldB"], argument: "fieldB")

            // Dataset mode: dataset_id present → column entropy over dataset rows (MX-TAB-7).
            // fieldA/fieldB are column names; drawer-field validation is skipped entirely.
            // When absent → estate-mode path below is EXACTLY unchanged.
            if let dsID = try optionalString(args["dataset_id"], argument: "dataset_id") {
                let resolved: (uuid: UUID, drawer: Drawer, content: DatasetHandleContent?, store: any DatasetStore)
                do {
                    resolved = try await resolveDataset(
                        idStr: dsID, kit: kit, handle: handle, toolName: "moot_lens_complexity")
                } catch let e as DatasetResolutionError {
                    switch e {
                    case .refusal(let r): return r
                    case .fault(let f): throw f
                    }
                }
                let (uuid, _, content, datasetStore) = resolved
                // Column validation requires decoded content. If the handle content
                // is malformed (corrupted), fail fast with a clear internal-error.
                guard let c = content else {
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.internalError,
                        message: "moot_lens_complexity: cannot read dataset column schema (handle content missing or malformed)")
                }
                let colNames = Set(c.columns.map { $0.name })
                if !colNames.isEmpty && !colNames.contains(fieldA) {
                    let list = colNames.sorted().joined(separator: ", ")
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.invalidParams,
                        message: "moot_lens_complexity: fieldA '\(fieldA)' is not a column of dataset \(uuid.uuidString). Available: \(list)")
                }
                if let fb = fieldB, !colNames.isEmpty, !colNames.contains(fb) {
                    let list = colNames.sorted().joined(separator: ", ")
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.invalidParams,
                        message: "moot_lens_complexity: fieldB '\(fb)' is not a column of dataset \(uuid.uuidString). Available: \(list)")
                }
                let rows: [StorageRow]
                do {
                    rows = try await datasetStore.queryRows(
                        id: uuid, predicate: nil, orderBy: [],
                        limit: datasetLensRowCap, offset: nil, columns: nil)
                } catch {
                    return ToolDispatcher.errorResult(
                        "moot_lens_complexity: query failed: " + error.localizedDescription)
                }
                // Project column A values: TypedValue → String? (nil for .null).
                // DatasetTools.typedValueToString is used for f64 wire discipline
                // (String(d) shortest roundtrip) and consistent null representation.
                let colA: [String?] = rows.map { row -> String? in
                    guard let tv = row.values[fieldA] else { return nil }
                    if case .null = tv { return nil }
                    return DatasetTools.typedValueToString(tv)
                }
                let colB: [String?]? = fieldB.map { fb in
                    rows.map { row -> String? in
                        guard let tv = row.values[fb] else { return nil }
                        if case .null = tv { return nil }
                        return DatasetTools.typedValueToString(tv)
                    }
                }
                let dsOut = DatasetComplexity.runColumn(columnA: colA, columnB: colB)
                var dsLines = [
                    "dataset_complexity: dataset=\(uuid.uuidString) rows=\(rows.count) nonNull=\(dsOut.nonNullCount) null=\(dsOut.nullCount)",
                    "entropyA=\(dsOut.result.entropyA)",
                ]
                if let eb = dsOut.result.entropyB { dsLines.append("entropyB=\(eb)") }
                if let mi = dsOut.result.mutualInformation { dsLines.append("mutualInformation=\(mi)") }
                return ToolDispatcher.textResult(dsLines.joined(separator: "\n"))
            }

            // Estate mode: validate drawer field names, then run the Complexity recipe.
            // Validate field names before calling into the recipe. The complexity
            // recipe silently returns entropy=-0 for fields it does not recognise,
            // which would surface as a successful but meaningless result. Reject
            // early with the valid list so the caller can self-correct.
            let validComplexityFields: Set<String> = ["room", "wing", "addedBy", "embeddingModelID"]
            if !validComplexityFields.contains(fieldA) {
                let validList = validComplexityFields.sorted().joined(separator: ", ")
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "Unknown fieldA: \(fieldA). Valid fields: \(validList)"
                )
            }
            if let fb = fieldB, !validComplexityFields.contains(fb) {
                let validList = validComplexityFields.sorted().joined(separator: ", ")
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "Unknown fieldB: \(fb). Valid fields: \(validList)"
                )
            }

            let out = try await Complexity.run(
                kit: kit, handle: handle,
                frame: try frame(args),
                fieldA: fieldA,
                fieldB: fieldB,
                now: Date())
            var complexityLines = [
                "complexity: totalCount=\(out.totalCount)",
                "entropyA=\(out.result.entropyA)",
            ]
            if let eb = out.result.entropyB {
                complexityLines.append("entropyB=\(eb)")
            }
            if let mi = out.result.mutualInformation {
                complexityLines.append("mutualInformation=\(mi)")
            }
            return ToolDispatcher.textResult(complexityLines.joined(separator: "\n"))

        case "moot_lens_concepts":
            let fcFilterChain = try decodeFilterChain(args["filter"])
            // Route through clampLimit so negative and over-ceiling values are
            // rejected/clamped at the MCP boundary. Parity: Rust lens_tools.rs
            // moot_lens_concepts uses clamp_limit with the same ceiling.
            let fcLimit = try ToolDispatcher.clampLimit(
                try optionalInt(args["limit"], argument: "limit"), argument: "limit")
            let minSupport = try integer(args, "minSupport", default: 1)
            let maxIntentSize = try integer(args, "maxIntentSize", default: 8)
            let maxConcepts = try integer(args, "maxConcepts", default: 20)
            let fcFrame = LocusKit.RecallFrame(
                filterChain: fcFilterChain,
                hydrationLevel: .structured,
                limit: fcLimit,
                ordering: .byCaptureTimeDesc)
            let fcOut = try await FormalConcepts().run(
                input: .init(
                    frame: fcFrame,
                    miner: BoundedConceptMiner(
                        minSupport: minSupport,
                        maxIntentSize: maxIntentSize,
                        maxConcepts: maxConcepts)),
                estate: handle, kit: kit)
            var fcLines = [
                "formal_concepts: \(fcOut.concepts.count) concept(s) from \(fcOut.drawerCount) drawer(s)",
            ]
            for (i, concept) in fcOut.concepts.enumerated() {
                fcLines.append("  concept \(i + 1): support=\(concept.support)")
                fcLines.append("    intent: \(concept.intent.joined(separator: ", "))")
                // Extent lists the drawer ADDRESSES, not just a count: every
                // lens finding must be followable to its evidence
                // (progressive-recall rule — a result that names a grouping
                // but withholds the cursor strands the consumer). Capped so
                // one giant concept cannot flood the reply; the "+N more"
                // rows are reachable by tightening the frame filter.
                let extent = concept.extentDrawerIDs
                let shown = extent.prefix(lensExtentIDCap)
                let more = extent.count > lensExtentIDCap
                    ? " +\(extent.count - lensExtentIDCap) more" : ""
                fcLines.append(
                    "    extent (\(extent.count)): \(shown.joined(separator: ", "))\(more)")
            }
            return ToolDispatcher.textResult(fcLines.joined(separator: "\n"))

        case "moot_lens_apriori":
            let minSupport = try doubleArg(args["minSupport"], argument: "minSupport") ?? 0.0
            let minConfidence = try doubleArg(args["minConfidence"], argument: "minConfidence") ?? 0.0
            let minLift = try doubleArg(args["minLift"], argument: "minLift") ?? 1.0
            let maxK = try integer(args, "maxK", default: 3)
            let aprioriOut = try await AprioriRules().run(
                input: .init(
                    thresholds: AprioriThresholds(
                        minSupport: minSupport,
                        minConfidence: minConfidence,
                        minLift: minLift,
                        maxK: maxK)),
                estate: handle, kit: kit)
            var aprioriLines = ["apriori_rules: \(aprioriOut.rules.count) rule(s)"]
            for rule in aprioriOut.rules {
                let ant = rule.antecedent.map { "\($0)" }.joined(separator: " & ")
                aprioriLines.append(
                    "  [\(ant)] → \(rule.consequent): "
                    + "sup=\(String(format: "%.3f", rule.support)) "
                    + "conf=\(String(format: "%.3f", rule.confidence)) "
                    + "lift=\(String(format: "%.3f", rule.lift))")
            }
            return ToolDispatcher.textResult(aprioriLines.joined(separator: "\n"))

        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown lens tool: \(name)")
        }
    }

    // MARK: - Argument decoding

    /// The second federated estate, routed through the dispatcher's own
    /// registry: `estateIDB` is presented to the resolver as `estateID`.
    private static func secondEstateArgs(
        _ args: [String: JSONValue]
    ) -> [String: JSONValue] {
        guard let b = args["estateIDB"] else { return [:] }
        return ["estateID": b]
    }

    private static func requireString(
        _ args: [String: JSONValue], _ key: String
    ) throws -> String {
        guard let value = args[key]?.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Missing required string argument: \(key)")
        }
        return value
    }

    private static func requireDate(
        _ args: [String: JSONValue], _ key: String
    ) throws -> Date {
        let raw = try requireString(args, key)
        guard let date = ISO8601DateFormatter().date(from: raw) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Argument \(key) is not an ISO8601 instant: \(raw)")
        }
        return date
    }

    /// Build a validated `ClosedRange<Date>` from a start/end pair decoded from
    /// the lens tool arguments.
    ///
    /// Two guards are applied before constructing the range:
    ///   1. `start <= end` — a reversed window is a client error, not a silent
    ///      empty result. Swift's `...` operator would precondition-fail (crash)
    ///      on a reversed range; this check surfaces a proper `invalidParams`
    ///      instead.
    ///   2. Max range cap — a window spanning decades can scan the entire corpus
    ///      and exhaust memory. Cap is 3 years (≈ 94 608 000 seconds), which is
    ///      generous for any legitimate analytical query.
    private static func requireWindowRange(
        start: Date, end: Date
    ) throws -> ClosedRange<Date> {
        guard start <= end else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "windowStart must be ≤ windowEnd; got start=\(start) end=\(end)")
        }
        let maxDurationSeconds: TimeInterval = 3 * 365.25 * 24 * 60 * 60 // ~3 years
        guard end.timeIntervalSince(start) <= maxDurationSeconds else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "window span must not exceed 3 years; reduce the range")
        }
        return start...end
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

    private static func integer(
        _ args: [String: JSONValue], _ key: String, default fallback: Int
    ) throws -> Int {
        try optionalInt(args[key], argument: key) ?? fallback
    }

    private static func number(
        _ args: [String: JSONValue], _ key: String, default fallback: Double
    ) throws -> Double {
        guard let value = args[key] else { return fallback }
        switch value {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(key) must be a number; omit it to use the default")
        }
    }

    private static func decodeReference(
        _ value: JSONValue?
    ) throws -> [(label: String, mass: Double)] {
        guard let arr = value?.arrayValue else { return [] }
        return try arr.map { element in
            guard let obj = element.objectValue,
                  let label = obj["label"]?.stringValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "each reference entry needs string label and number mass")
            }
            let mass: Double
            switch obj["mass"] {
            case .double(let d): mass = d
            case .integer(let i): mass = Double(i)
            default:
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "each reference entry needs string label and number mass")
            }
            return (label: label, mass: mass)
        }
    }

    /// Decode a JSON array of window objects into `ClosedRange<Date>` values
    /// for `Moment.run`. Each element must have string fields `windowStart`
    /// and `windowEnd`. An absent or non-array value returns an empty list
    /// (B-8 total-over-edge-input posture).
    private static func decodeComparisonWindows(
        _ value: JSONValue?
    ) throws -> [ClosedRange<Date>] {
        guard let arr = value?.arrayValue else { return [] }
        let formatter = ISO8601DateFormatter()
        return try arr.map { element in
            guard let obj = element.objectValue,
                  let startStr = obj["windowStart"]?.stringValue,
                  let endStr = obj["windowEnd"]?.stringValue,
                  let start = formatter.date(from: startStr),
                  let end = formatter.date(from: endStr) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "each comparisonWindows entry needs ISO8601 windowStart and windowEnd")
            }
            return try requireWindowRange(start: start, end: end)
        }
    }

    private static func decodeCueMode(_ value: JSONValue?) throws -> CueMode {
        guard let name = try optionalString(value, argument: "mode") else { return .feelsLike }
        switch name {
        case "aboutThis": return .aboutThis
        case "fromThen": return .fromThen
        case "feelsLike": return .feelsLike
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown mode: \(name)")
        }
    }

    private static func decodeContentKind(_ name: String) -> ContentKind? {
        switch name {
        case "prose": return .prose
        case "code": return .code
        case "transcript": return .transcript
        case "list": return .list
        case "structuredJSON": return .structuredJSON
        case "imageCaption": return .imageCaption
        case "fingerprintOnly": return .fingerprintOnly
        case "dataset": return .dataset
        default: return nil
        }
    }

    /// Action labels for anticipate output (capture channel raw values).
    private static func channelName(_ raw: UInt8) -> String {
        CaptureChannel(rawValue: Int(raw)).map { "\($0)" } ?? "channel(\(raw))"
    }

    /// Recall frame for the recall-scoped lenses. Same filter vocabulary
    /// as `RecipeTools.decodeFilter` (a deliberate small copy — the
    /// helpers there are private; same precedent as the schema helpers).
    private static func frame(_ args: [String: JSONValue]) throws -> LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: try decodeFilterChain(args["filter"]))
    }

    /// Decode a filter kind string to a `LocusKit.Filter` chain. Used by the
    /// analytics lenses that take an explicit filter + limit frame.
    private static func decodeFilterChain(_ value: JSONValue?) throws -> [LocusKit.Filter] {
        guard let name = try optionalString(value, argument: "filter") else { return [] }
        switch name {
        case "unconfirmed": return [.unconfirmed]
        case "userConfirmed": return [.userConfirmed]
        case "exportable": return [.exportable]
        case "contained": return [.contained]
        case "currentlyBelieve": return [.currentlyBelieve]
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown filter: \(name)")
        }
    }

    /// Extract a `Double` from a `.double` or `.integer` JSON value.
    /// Returns `nil` for absent or non-numeric values.
    private static func doubleArg(_ value: JSONValue?, argument: String) throws -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be a number; omit it to use the default")
        }
    }

    // MARK: - Result shaping

    private static func list(_ heading: String, _ items: [String]) -> JSONValue {
        var lines = ["\(heading): \(items.count) result(s)"]
        lines += items.map { "  - \($0)" }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - Dataset resolution (MX-TAB-7 dataset-mode lens paths)

    /// Distinguishes soft refusals (withdrawn handle, not found) from hard faults
    /// (invalid UUID, estate inaccessible, storage unavailable) in resolveDataset.
    ///
    /// Callers catch this error and either return the refusal JSONValue or rethrow the fault:
    ///
    ///     do { resolved = try await resolveDataset(...) }
    ///     catch let e as DatasetResolutionError {
    ///         switch e {
    ///         case .refusal(let r): return r      // keeps the MCP call id
    ///         case .fault(let f): throw f         // surfaces as JSONRPC error
    ///         }
    ///     }
    private enum DatasetResolutionError: Error {
        /// Soft refusal: return this JSONValue as the tool result (isError:true).
        case refusal(JSONValue)
        /// Hard fault: rethrow as a JSONRPCError (transport-level error).
        case fault(JSONRPCError)
    }

    /// Row cap for all dataset-mode lens queries. Matches DatasetCohesion.scanCap
    /// (10 000 rows). Bounds scan cost; callers may supply a smaller `limit`.
    private static let datasetLensRowCap: Int = DatasetCohesion.scanCap

    /// Resolve a dataset_id string to its active handle drawer, decoded content
    /// (optional), and DatasetStore.
    ///
    /// - Soft refusals (withdrawn handle, not found) throw `.refusal(errorResult)`.
    /// - Hard faults (invalid UUID, estate inaccessible, storage absent) throw `.fault(JSONRPCError)`.
    /// - Content is returned as optional: callers that need column metadata check for nil
    ///   themselves; callers that only need rows (e.g. associations) can ignore it.
    private static func resolveDataset(
        idStr: String,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        toolName: String
    ) async throws -> (uuid: UUID, drawer: Drawer, content: DatasetHandleContent?, store: any DatasetStore) {
        guard let uuid = UUID(uuidString: idStr) else {
            throw DatasetResolutionError.fault(JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(toolName): dataset_id is not a valid UUID: \(idStr)"))
        }

        let estate: LocusKit.Estate
        do {
            // estate(for:) is actor-isolated on GeniusLocusKit; await is required
            // (matches the try await pattern used elsewhere in LensTools dispatch).
            estate = try await kit.estate(for: handle)
        } catch {
            throw DatasetResolutionError.fault(JSONRPCError(
                code: JSONRPCErrorCode.internalError,
                message: "\(toolName): estate not accessible: " + error.localizedDescription))
        }

        let drawer: Drawer
        do {
            drawer = try await estate.resolveActiveDatasetHandle(datasetId: uuid)
        } catch let lke as LocusKitError {
            // Withdrawn handle is a soft refusal: surface as errorResult so the client
            // keeps the JSONRPC call id. Mirrors DatasetTools.describeLocusKitError.
            throw DatasetResolutionError.refusal(
                ToolDispatcher.errorResult("\(toolName): " + lensDescribeLocusKitError(lke)))
        } catch {
            throw DatasetResolutionError.refusal(
                ToolDispatcher.errorResult(
                    "\(toolName): dataset handle not found: " + error.localizedDescription))
        }

        // Content is try? because callers decide if they need it:
        // - complexity and cohesion: guard-check for nil (need column schema)
        // - associations: ignores content (column names come from row keys)
        let content = try? DatasetHandleContent.decode(from: drawer.content)

        let store: any DatasetStore
        do {
            store = try await kit.datasetStore(for: handle)
        } catch {
            throw DatasetResolutionError.fault(JSONRPCError(
                code: JSONRPCErrorCode.internalError,
                message: "\(toolName): estate storage does not support datasets: " + error.localizedDescription))
        }

        return (uuid: uuid, drawer: drawer, content: content, store: store)
    }

    /// Describe a LocusKitError at the ARIA lens boundary.
    /// Mirrors DatasetTools.describeLocusKitError with lens-appropriate guidance.
    private static func lensDescribeLocusKitError(_ error: LocusKitError) -> String {
        switch error {
        case .withdrawnDatasetHandle(let datasetId):
            return "dataset is withdrawn (id: \(datasetId.uuidString)). " +
                "Restore it with moot_update_memory mutation=revive before using this lens."
        default:
            return error.localizedDescription
        }
    }

    /// Convert a TypedValue to a bare string for use as a categorical label in
    /// DatasetAssociations (no JSON-style quoting — labels must be human-readable).
    ///
    /// Contrast with DatasetTools.typedValueToString which wraps .text in quotes.
    /// Here, "Chicago" is the label, not "\"Chicago\"".
    ///
    /// Float discipline: Double uses String(d) (f64 shortest roundtrip) matching the Rust twin.
    /// Callers must exclude .null values before calling (null has no natural label).
    private static func typedValueToLabelString(_ v: TypedValue) -> String {
        switch v {
        case .null:          return ""         // caller should exclude; empty → no contribution
        case .bool(let b):   return b ? "true" : "false"
        case .int(let i):    return "\(i)"
        case .bitmap(let i): return "\(i)"
        case .float(let d):  return String(d)  // f64 shortest roundtrip
        case .text(let s):   return s          // bare — no JSON quoting
        case .uuid(let u):   return u.uuidString
        case .timestamp(let date):
            return ISO8601DateFormatter().string(from: date)
        default:
            // blob, json, hlc, fingerprint — use type description as fallback label.
            return "<\(v.typeDescription)>"
        }
    }

    /// Project a TypedValue to a DatasetColumnValue for DatasetCohesion.run.
    ///
    /// Column kind is inferred by DatasetCohesion from the first non-null value.
    /// Numeric types (.int, .bitmap, .float) → .numeric(Double).
    /// Bool/text/uuid/timestamp → .categorical(string).
    /// Null and unscoreable types (.blob, .json, etc.) → .null (zero anomaly signal).
    private static func typedValueToDatasetColumnValue(_ v: TypedValue) -> DatasetColumnValue {
        switch v {
        case .null:
            return .null
        case .int(let i):
            // Exact Int64 → Double conversion; no precision loss for typical dataset integers.
            return .numeric(Double(i))
        case .bitmap(let i):
            // Bitmaps are integer-valued; treat as numeric for MAD-based anomaly scoring.
            return .numeric(Double(i))
        case .float(let d):
            return .numeric(d)
        case .bool(let b):
            // Bool → categorical: "true"/"false" strings enable rarity-based scoring.
            return .categorical(b ? "true" : "false")
        case .text(let s):
            return .categorical(s)
        case .uuid(let u):
            return .categorical(u.uuidString)
        case .timestamp(let date):
            return .categorical(ISO8601DateFormatter().string(from: date))
        default:
            // blob, json, hlc, fingerprint — no scorable representation; contribute 0.
            return .null
        }
    }

    // MARK: - JSON schema helpers (same small copies as RecipeTools)

    private static var estateIDSchema: JSONValue {
        stringSchema("Optional UUID of the open estate to target. Omit for the default estate; null is invalid.")
    }

    private static var filterSchema: JSONValue {
        stringSchema("Filter kind: unconfirmed, userConfirmed, exportable, contained, currentlyBelieve. Omit for ordinary recall across any confirmation state. null is invalid.")
    }

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

    private static func numberSchema(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    private static func booleanSchema(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    // Validates that a JSONValue, if present, is a bool. Returns nil for absent,
    // throws invalidParams for a non-bool value. Mirrors ToolDispatch.optionalBool.
    private static func optionalBool(_ value: JSONValue?, argument: String) throws -> Bool? {
        guard let value else { return nil }
        guard let flag = value.boolValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be a boolean; omit it to use the default"
            )
        }
        return flag
    }
}
