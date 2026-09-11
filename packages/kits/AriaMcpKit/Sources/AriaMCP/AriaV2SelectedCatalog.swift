import AriaMCPWire

/// The currently executable ARIA v2 catalog.  An operation is added here only
/// after its typed decoder and direct service adapter are present.  This keeps
/// the deliberately incomplete v2 tools/list honest while later families are
/// extracted.
enum AriaV2SelectedCatalog {
    static let coreCapability = AriaV2Capability(rawValue: "core")
    static let vaultCapability = AriaV2Capability(rawValue: "vault")

    static func registry(environment: [String: String]) -> AriaV2EffectiveRegistry {
        var capabilities: Set<AriaV2Capability> = [coreCapability]
        if ToolProjection.vaultEnabled(environment: environment) {
            capabilities.insert(vaultCapability)
        }
        return try! AriaV2EffectiveRegistry(
            descriptors: descriptors,
            inputs: .init(
                buildID: "aria-v2",
                lane: .public,
                capabilities: capabilities
            )
        )
    }

    static func capabilityDigest(environment: [String: String]) -> String {
        try! AriaV2CapabilityDigest.digest(registry: registry(environment: environment))
    }

    static var capabilityDigest: String {
        capabilityDigest(environment: [:])
    }

    static let descriptors: [AriaV2OperationDescriptor] = [
        descriptor(
            identity: "help",
            name: "moot_help",
            effect: .read,
            description: "Discover the callable operations in this incomplete ARIA v2 build or inspect one exact operation.",
            intents: ["help", "discover tools"],
            properties: [
                "intent": stringSchema(),
                "tool": stringSchema(),
            ], dataSchema: helpDataSchema()
        ),
        descriptor(
            identity: "file_memory",
            name: "moot_file_memory",
            effect: .write,
            description: "File a durable memory with explicit subject and placement.",
            intents: ["file memory", "remember"],
            properties: [
                "content": stringSchema(),
                "subject": stringSchema(),
                "location": stringSchema(),
                "wing": stringSchema(),
                "sensitivity": enumSchema(["normal", "elevated", "restricted", "secret"]),
                "exportability": enumSchema(["private", "public"]),
                "kind": enumSchema(["prose", "code", "transcript", "list", "structured_json", "image_caption"]),
                "event_time": dateSchema(),
                "impatient": booleanSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["content", "subject", "location"], dataSchema: fileMemoryDataSchema()
        ),
        descriptor(
            identity: "memory_get",
            name: "moot_memory_get",
            effect: .read,
            description: "Fetch one or a bounded batch of authorized memories by UUID.",
            intents: ["get memory", "fetch memory"],
            properties: [
                "memory_id": uuidSchema(),
                "memory_ids": .object([
                    "type": .string("array"),
                    "items": uuidSchema(),
                    "minItems": .integer(1),
                    "maxItems": .integer(Int64(AriaV2MemoryGetRequest.maximumIDs)),
                    "uniqueItems": .bool(true),
                ]),
                "depth": enumSchema(AriaV2MemoryDepth.allCases.map(\.rawValue)),
                "estate_id": uuidSchema(),
            ], inputSchemaAdditions: ["oneOf": exactlyOneOf("memory_id", "memory_ids")],
            dataSchema: memoryGetDataSchema()
        ),
        descriptor(
            identity: "memory_list",
            name: AriaV2MemoryListRequest.toolName,
            effect: .read,
            description: "Enumerate a complete authorized structural memory inventory with revision-bound pagination.",
            intents: ["list memories", "enumerate memory"],
            properties: [
                "wing": nonEmptyStringSchema(),
                "room": stringSchema(),
                "filter": enumSchema(["missing_subject"]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .integer(1),
                    "maximum": .integer(Int64(AriaV2MemoryListRequest.maximumLimit)),
                ]),
                "cursor": nonEmptyStringSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["wing"],
            dataSchema: memoryListDataSchema()
        ),
        descriptor(
            identity: "memory_search",
            name: "moot_memory_search",
            effect: .read,
            description: "Search memories by a query or an anchor, returning compact authorized rows.",
            intents: ["search memory", "recall"],
            properties: [
                "query": stringSchema(),
                "near": uuidSchema(),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .integer(1),
                    "maximum": .integer(Int64(AriaV2MemorySearchRequest.maximumLimit)),
                ]),
                // filter: constrains recall by confirmation state (unconfirmed, userConfirmed),
                // exportability (exportable, contained), or feature flag (pinned). Composable
                // with wing and media_type. 'pinned' activates the container-fingerprint
                // pruning path via hasFeatureFlag(.isPinned).
                "filter": .object([
                    "type": .string("string"),
                    "enum": .array(["unconfirmed", "userConfirmed", "exportable", "contained", "pinned"].map(JSONValue.string)),
                    "description": .string("Scope recall by confirmation state or feature flag. 'pinned' constrains to user-pinned memories. Composable with wing and media_type."),
                ]),
                // wing: scopes recall to a named wing of the estate (e.g. 'Agentic Memory').
                // Absent means recall spans all wings. Composable with filter and media_type.
                "wing": stringSchema(),
                // media_type: constrains recall to drawers carrying a specific media capture type.
                // 'voice' → hasVoice (bit 13), 'image' → hasImage (bit 14). Composable with filter and wing.
                "media_type": enumSchema(["voice", "image"]),
                // door: scoring-strategy adjective on the recall verb. 'guess' reads the
                // optimizer-provisioned A1 per-corpus DoorManifest; absent or unprovisioned
                // falls back to matrixAware. Direct scoring rawValues bypass the A1 config.
                // Overrides scoring when both are present.
                "door": .object([
                    "type": .string("string"),
                    "enum": .array(["guess", "raw", "rrf", "matrixAware", "discriminative"].map(JSONValue.string)),
                    "description": .string("Scoring strategy adjective. 'guess' reads the optimizer-provisioned A1 per-corpus config. Direct values (rrf, matrixAware, raw, discriminative) override it. Absent falls through to scoring, then A1 manifest, then matrixAware."),
                ]),
                // scoring: explicit scoring strategy, used when door is absent.
                // Fail-closed: unknown values throw invalidParams (not silently coerced).
                "scoring": enumSchema(["raw", "rrf", "matrixAware", "discriminative"]),
                // ordering: result ordering. 'byRelevanceDesc' is a compatibility spelling
                // for the scored recall path; results are already relevance-ordered by scores.
                // All other values map directly to LocusKit.Ordering cases.
                "ordering": .object([
                    "type": .string("string"),
                    "enum": .array(["byCaptureTimeDesc", "byCaptureTimeAsc", "byRoomAsc", "byRelevanceDesc"].map(JSONValue.string)),
                    "description": .string("Result ordering. 'byRelevanceDesc' routes through the scored recall pipeline (results are relevance-ordered by score). 'byCaptureTimeDesc' (default), 'byCaptureTimeAsc', 'byRoomAsc' use the LocusKit ordering field."),
                ]),
                // frontier_k: candidate-pool depth override. The GLK engine clamps to [64, 256].
                // Absent uses the engine default formula min(max(limit × 4, 64), 256).
                "frontier_k": positiveIntegerSchema(),
                // explain:true renders a discrimination line when the recall confidence signal
                // is low or medium — surfaces how clearly the top result separates from
                // the field. Absent means a clear, nominal result; opt-in because the
                // discrimination line adds tokens the caller may not want.
                "explain": .object([
                    "type": .string("boolean"),
                    "description": .string("Opt-in flag. When true, appends a discrimination: control line when recall confidence is low or medium, surfacing how clearly the top result separates from the field. Absent or false suppresses the line."),
                ]),
                // answer: selects the response shape adjective (packager mode):
                //   "never"  (default) — dense rows only, byte-identical to pre-packager path
                //   "always"           — compose answer block + rows (L1-full shape)
                //   "auto"             — server picks level by confidence gate (L0/L1/rowsOnly)
                // Unknown values fail closed with invalidParams (-32602).
                "answer": .object([
                    "type": .string("string"),
                    "enum": .array(["never", "always", "auto"].map(JSONValue.string)),
                    "description": .string("Response shape adjective. \"never\" (default) returns dense rows only. \"always\" composes an answer block and rows (requires estate content). \"auto\" lets the server choose the response level by confidence gate (L0 answer-only, L1 answer+rows, or rowsOnly)."),
                ]),
                "estate_id": uuidSchema(),
            ], inputSchemaAdditions: ["oneOf": exactlyOneOf("query", "near")],
            dataSchema: memorySearchDataSchema()
        ),
        descriptor(
            identity: "transcript_recall",
            name: AriaV2TranscriptRecallRequest.toolName,
            effect: .read,
            description: "Find previous conversations containing the answer to a question, including earlier decisions and troubleshooting.",
            intents: ["recall transcript", "search conversation"],
            properties: [
                "query": .object(["type": .string("string"), "minLength": .integer(1)]),
                "estate_id": uuidSchema(),
            ],
            required: ["query"], dataSchema: transcriptRecallDataSchema()
        ),
        descriptor(
            identity: "recall_precise", name: AriaV2RecallLensOperation.recallPrecise.rawValue,
            effect: .read, description: "Recall known-token answers with a named precision composition.",
            intents: ["Recall known-token answers with a named precision composition."],
            properties: recallProperties(pool: true, extras: ["composition": stringSchema()]),
            required: ["query"], dataSchema: recallDataSchema()
        ),
        descriptor(
            identity: "recall_temporal", name: AriaV2RecallLensOperation.recallTemporal.rawValue,
            effect: .read, description: "Recall memories using an explicit or parsed temporal window.",
            intents: ["Recall memories using an explicit or parsed temporal window."],
            properties: recallProperties(pool: true, extras: [
                "window": enumSchema(["loose", "tight"]), "from": stringSchema(), "to": stringSchema(), "grab": enumSchema(["pool", "dated"]),
            ]),
            required: ["query"], dataSchema: recallDataSchema()
        ),
        descriptor(
            identity: "recall_connected", name: AriaV2RecallLensOperation.recallConnected.rawValue,
            effect: .read, description: "Recall memories through bounded graph connections.",
            intents: ["Recall memories through bounded graph connections."],
            properties: recallProperties(extras: ["depth": positiveIntegerSchema()]),
            required: ["query"], dataSchema: recallDataSchema()
        ),
        descriptor(
            identity: "recall_shaped", name: AriaV2RecallLensOperation.recallShaped.rawValue,
            effect: .read, description: "Recall memories with the selected shaped-retrieval composition.",
            intents: ["Recall memories with the selected shaped-retrieval composition."],
            // frontier_k: candidate-pool depth override, same semantics as moot_memory_search.
            // The shaped-recall engine clamps the value to [64, 256].
            properties: recallProperties(extras: ["preset": stringSchema(), "frontier_k": positiveIntegerSchema()]),
            required: ["query"], dataSchema: recallDataSchema()
        ),
        descriptor(
            identity: "recall_distilled", name: AriaV2RecallLensOperation.recallDistilled.rawValue,
            effect: .read, description: "Recall compact distilled memory projections.",
            intents: ["Recall compact distilled memory projections."],
            // echo_query:true echoes the rewritten query in the result so the
            // caller can verify the server's interpretation of a vague or
            // expanded cue.
            properties: recallProperties(extras: ["echo_query": booleanSchema()]),
            required: ["query"], dataSchema: recallDataSchema()
        ),
        descriptor(
            identity: "recall_vague", name: AriaV2RecallLensOperation.recallVague.rawValue,
            effect: .read, description: "Recall memories from a vague cue.",
            intents: ["Recall memories from a vague cue."],
            properties: recallProperties(extras: ["echo_query": booleanSchema()]),
            required: ["query"], dataSchema: recallDataSchema()
        ),
        descriptor(
            identity: "recall_walk", name: AriaV2RecallLensOperation.recallWalk.rawValue,
            effect: .read, description: "Recall with the bounded escalation ladder.",
            intents: ["Recall with the bounded escalation ladder."],
            properties: recallProperties(extras: ["echo_query": booleanSchema()]),
            required: ["query"], dataSchema: recallDataSchema()
        ),
        descriptor(
            identity: "lens_keystones", name: AriaV2RecallLensOperation.lensKeystones.rawValue,
            effect: .read, description: "Identify hub memories by graph centrality.",
            intents: ["Identify hub memories by graph centrality."],
            properties: ["wing": stringSchema(), "topK": stringSchema(), "keystoneOnly": stringSchema(), "estate_id": uuidSchema()],
            required: ["wing"], dataSchema: lensDataSchema(.lensKeystones)
        ),
        descriptor(
            identity: "lens_constellation", name: AriaV2RecallLensOperation.lensConstellation.rawValue,
            effect: .read, description: "Detect community structure in the memory graph.",
            intents: ["Detect community structure in the memory graph."],
            properties: ["wing": stringSchema(), "estate_id": uuidSchema()],
            required: ["wing"], dataSchema: lensDataSchema(.lensConstellation)
        ),
        descriptor(
            identity: "lens_free_association", name: AriaV2RecallLensOperation.lensFreeAssociation.rawValue,
            effect: .read, description: "Run bounded spreading activation from one seed memory.",
            intents: ["Run bounded spreading activation from one seed memory."],
            properties: [
                "wing": stringSchema(), "seed_memory_id": uuidSchema(), "walkLength": stringSchema(),
                "k": stringSchema(), "estate_id": uuidSchema(),
            ],
            required: ["wing", "seed_memory_id"], dataSchema: lensDataSchema(.lensFreeAssociation)
        ),
        descriptor(
            identity: "lens_bias", name: AriaV2RecallLensOperation.lensBias.rawValue,
            effect: .read, description: "Compare representation against a reference distribution.",
            intents: ["Compare representation against a reference distribution."],
            properties: [
                "reference": .object(["type": .string("array")]), "estate_id": uuidSchema(),
            ], includeEmptyRequired: true, dataSchema: lensDataSchema(.lensBias)
        ),
        descriptor(
            identity: "lens_cohesion", name: AriaV2RecallLensOperation.lensCohesion.rawValue,
            effect: .read, description: "Find low-cohesion memories or dataset anomalies.",
            intents: ["Find low-cohesion memories or dataset anomalies."],
            properties: ["dataset_id": uuidSchema(), "estate_id": uuidSchema()],
            includeEmptyRequired: true, dataSchema: lensDataSchema(.lensCohesion)
        ),
        descriptor(
            identity: "lens_contradiction", name: AriaV2RecallLensOperation.lensContradiction.rawValue,
            effect: .read, description: "Surface recorded contradictions and proposed findings.",
            intents: ["Surface recorded contradictions and proposed findings."],
            properties: ["estate_id": uuidSchema()], includeEmptyRequired: true,
            dataSchema: lensDataSchema(.lensContradiction)
        ),
        descriptor(
            identity: "lens_theme_weather", name: AriaV2RecallLensOperation.lensThemeWeather.rawValue,
            effect: .read, description: "Measure temporal momentum for themes.",
            intents: ["Measure temporal momentum for themes."],
            properties: ["estate_id": uuidSchema()], includeEmptyRequired: true,
            dataSchema: lensDataSchema(.lensThemeWeather)
        ),
        descriptor(
            identity: "lens_latent_themes", name: AriaV2RecallLensOperation.lensLatentThemes.rawValue,
            effect: .read, description: "Extract latent topic clusters.",
            intents: ["Extract latent topic clusters."],
            properties: ["estate_id": uuidSchema()], includeEmptyRequired: true,
            dataSchema: lensDataSchema(.lensLatentThemes)
        ),
        descriptor(
            identity: "lens_drift", name: AriaV2RecallLensOperation.lensDrift.rawValue,
            effect: .read, description: "Measure distribution drift across a temporal split.",
            intents: ["Measure distribution drift across a temporal split."],
            properties: ["splitAt": stringSchema(), "estate_id": uuidSchema()], required: ["splitAt"],
            dataSchema: lensDataSchema(.lensDrift)
        ),
        descriptor(
            identity: "lens_trust_synthesis", name: AriaV2RecallLensOperation.lensTrustSynthesis.rawValue,
            effect: .read, description: "Recall and rank memories by trust signals.",
            intents: ["Recall and rank memories by trust signals."],
            properties: ["limit": positiveIntegerSchema(), "estate_id": uuidSchema()], includeEmptyRequired: true,
            dataSchema: lensDataSchema(.lensTrustSynthesis)
        ),
        descriptor(
            identity: "lens_partial_cue", name: AriaV2RecallLensOperation.lensPartialCue.rawValue,
            effect: .read, description: "Retrieve memories by partial-cue similarity to an anchor.",
            intents: ["Retrieve memories by partial-cue similarity to an anchor."],
            properties: ["anchor_memory_id": uuidSchema(), "limit": positiveIntegerSchema(), "estate_id": uuidSchema()],
            required: ["anchor_memory_id"], dataSchema: lensDataSchema(.lensPartialCue)
        ),
        descriptor(
            identity: "lens_anticipate", name: AriaV2RecallLensOperation.lensAnticipate.rawValue,
            effect: .read, description: "Predict next-likely actions from historical patterns.",
            intents: ["Predict next-likely actions from historical patterns."],
            properties: ["targetKind": stringSchema(), "limit": positiveIntegerSchema(), "estate_id": uuidSchema()],
            required: ["targetKind"], dataSchema: lensDataSchema(.lensAnticipate)
        ),
        descriptor(
            identity: "lens_node_motion", name: AriaV2RecallLensOperation.lensNodeMotion.rawValue,
            effect: .read, description: "Inspect one memory's movement and churn history.",
            intents: ["Inspect one memory's movement and churn history."],
            properties: ["memory_id": uuidSchema(), "estate_id": uuidSchema()],
            required: ["memory_id"], dataSchema: lensDataSchema(.lensNodeMotion)
        ),
        descriptor(
            identity: "lens_successors", name: AriaV2RecallLensOperation.lensSuccessors.rawValue,
            effect: .read, description: "Suggest probable successor memories by graph traversal.",
            intents: ["Suggest probable successor memories by graph traversal."],
            properties: ["wing": stringSchema(), "anchor_memory_id": uuidSchema(), "limit": positiveIntegerSchema(), "estate_id": uuidSchema()],
            required: ["wing", "anchor_memory_id"], dataSchema: lensDataSchema(.lensSuccessors)
        ),
        descriptor(
            identity: "lens_overlap", name: AriaV2RecallLensOperation.lensOverlap.rawValue,
            effect: .read, description: "Measure thematic overlap with a comparison estate.",
            intents: ["Measure thematic overlap with a comparison estate."],
            properties: ["comparison_estate_id": uuidSchema(), "estate_id": uuidSchema()],
            required: ["comparison_estate_id"], dataSchema: lensDataSchema(.lensOverlap)
        ),
        descriptor(
            identity: "lens_divergence", name: AriaV2RecallLensOperation.lensDivergence.rawValue,
            effect: .read, description: "Measure thematic divergence from a comparison estate.",
            intents: ["Measure thematic divergence from a comparison estate."],
            properties: ["comparison_estate_id": uuidSchema(), "estate_id": uuidSchema()],
            required: ["comparison_estate_id"], dataSchema: lensDataSchema(.lensDivergence)
        ),
        descriptor(
            identity: "lens_associations", name: AriaV2RecallLensOperation.lensAssociations.rawValue,
            effect: .read, description: "Mine association rules from memory facets or a dataset.",
            intents: ["Mine association rules from memory facets or a dataset."],
            properties: ["dataset_id": uuidSchema(), "limit": positiveIntegerSchema(), "estate_id": uuidSchema()],
            includeEmptyRequired: true, dataSchema: lensDataSchema(.lensAssociations)
        ),
        descriptor(
            identity: "lens_concepts", name: AriaV2RecallLensOperation.lensConcepts.rawValue,
            effect: .read, description: "Mine formal concepts from recalled memories or a dataset.",
            intents: ["Mine formal concepts from recalled memories or a dataset."],
            properties: ["recall_limit": positiveIntegerSchema(), "limit": positiveIntegerSchema(), "estate_id": uuidSchema()],
            includeEmptyRequired: true, dataSchema: lensDataSchema(.lensConcepts)
        ),
        descriptor(
            identity: "lens_apriori", name: AriaV2RecallLensOperation.lensApriori.rawValue,
            effect: .read, description: "Mine multi-antecedent association rules from the audit log.",
            intents: ["Mine multi-antecedent association rules from the audit log."],
            properties: ["limit": positiveIntegerSchema(), "estate_id": uuidSchema()],
            includeEmptyRequired: true, dataSchema: lensDataSchema(.lensApriori)
        ),
        descriptor(
            identity: "lens_moment", name: AriaV2RecallLensOperation.lensMoment.rawValue,
            effect: .read, description: "Measure memory-fingerprint similarity across time windows.",
            intents: ["Measure memory-fingerprint similarity across time windows."],
            properties: ["windowStart": stringSchema(), "windowEnd": stringSchema(), "comparison_windows": stringSchema(), "estate_id": uuidSchema()],
            required: ["windowStart", "windowEnd"], dataSchema: lensDataSchema(.lensMoment)
        ),
        descriptor(
            identity: "lens_rhythm", name: AriaV2RecallLensOperation.lensRhythm.rawValue,
            effect: .read, description: "Detect capture-rhythm patterns from fingerprint bit series.",
            intents: ["Detect capture-rhythm patterns from fingerprint bit series."],
            properties: ["bit": stringSchema(), "bucketSeconds": stringSchema(), "bucketCount": stringSchema(), "endingAt": stringSchema(), "estate_id": uuidSchema()],
            required: ["bit", "bucketSeconds", "bucketCount", "endingAt"], dataSchema: lensDataSchema(.lensRhythm)
        ),
        descriptor(
            identity: "lens_precedence", name: AriaV2RecallLensOperation.lensPrecedence.rawValue,
            effect: .read, description: "Discover temporal precedence from audit-event lags.",
            intents: ["Discover temporal precedence from audit-event lags."],
            properties: ["windowStart": stringSchema(), "windowEnd": stringSchema(), "targetField": stringSchema(), "targetValue": stringSchema(), "estate_id": uuidSchema()],
            required: ["windowStart", "windowEnd", "targetField", "targetValue"], dataSchema: lensDataSchema(.lensPrecedence)
        ),
        descriptor(
            identity: "lens_complexity", name: AriaV2RecallLensOperation.lensComplexity.rawValue,
            effect: .read, description: "Measure entropy and optional mutual information over a field.",
            intents: ["Measure entropy and optional mutual information over a field."],
            properties: ["fieldA": stringSchema(), "fieldB": stringSchema(), "dataset_id": uuidSchema(), "estate_id": uuidSchema()],
            required: ["fieldA"], dataSchema: lensDataSchema(.lensComplexity)
        ),
        descriptor(
            identity: "hunt_contradictions",
            name: AriaV2Contradictions.huntToolName,
            effect: .read,
            description: "Analyze authorized memories for contradiction candidates without filing links.",
            intents: ["Analyze authorized memories for contradiction candidates without filing links."],
            properties: [
                "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(1_000)]),
                "estate_id": uuidSchema(),
            ],
            dataSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "analysis_ref": nonEmptyStringSchema(), "expires_at": dateSchema(),
                    "candidates": .object([
                        "type": .string("array"),
                        "items": contradictionCandidateSchema(),
                    ]),
                ]),
                "required": .array([.string("analysis_ref"), .string("expires_at"), .string("candidates")]),
                "additionalProperties": .bool(false),
            ])
        ),
        descriptor(
            identity: "propose_contradictions",
            name: AriaV2Contradictions.proposeToolName,
            effect: .write,
            description: "Resolve explicitly selected contradiction candidates without rerunning analysis.",
            intents: ["Resolve explicitly selected contradiction candidates without rerunning analysis."],
            properties: [
                "analysis_ref": nonEmptyStringSchema(),
                "candidate_ids": .object([
                    "type": .string("array"), "minItems": .integer(1), "maxItems": .integer(1_000),
                    "uniqueItems": .bool(true), "items": nonEmptyStringSchema(),
                ]),
                "estate_id": uuidSchema(),
            ],
            required: ["analysis_ref", "candidate_ids"],
            dataSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "analysis_ref": nonEmptyStringSchema(), "expires_at": dateSchema(),
                    "candidates": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "candidate_id": nonEmptyStringSchema(),
                                "status": .object(["type": .string("string"), "enum": .array([.string("created"), .string("existing"), .string("settled")])]),
                                "tunnel_id": uuidSchema(), "lifecycle": stringSchema(),
                            ]),
                            "required": .array([.string("candidate_id"), .string("status")]),
                            "additionalProperties": .bool(false),
                        ]),
                    ]),
                ]),
                "required": .array([.string("analysis_ref"), .string("expires_at"), .string("candidates")]),
                "additionalProperties": .bool(false),
            ])
        ),
        descriptor(
            identity: "connection_search",
            name: AriaV2KnowledgeJournalOperation.connectionSearch.rawValue,
            effect: .read,
            description: "Find authorized connections adjacent to one memory.",
            intents: ["Find authorized connections adjacent to one memory."],
            properties: [
                "memory_id": uuidSchema(), "relationship": stringSchema(), "direction": stringSchema(),
                "limit": positiveIntegerSchema(), "estate_id": uuidSchema(),
            ],
            required: ["memory_id"], dataSchema: connectionEdgesDataSchema()
        ),
        descriptor(
            identity: "connection_map",
            name: AriaV2KnowledgeJournalOperation.connectionMap.rawValue,
            effect: .read,
            description: "Traverse the bounded authorized connection graph from one memory.",
            intents: ["Traverse the bounded authorized connection graph from one memory."],
            properties: [
                "memory_id": uuidSchema(), "depth": positiveIntegerSchema(), "limit": positiveIntegerSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["memory_id"], dataSchema: connectionEdgesDataSchema()
        ),
        descriptor(
            identity: "file_fact",
            name: AriaV2KnowledgeJournalOperation.fileFact.rawValue,
            effect: .write,
            description: "Store a typed fact, optionally grounded in a source memory.",
            intents: ["Store a typed fact, optionally grounded in a source memory."],
            properties: [
                "subject": stringSchema(), "predicate": stringSchema(), "object": stringSchema(),
                "source_memory_id": uuidSchema(), "event_time": dateSchema(), "estate_id": uuidSchema(),
            ],
            required: ["subject", "predicate", "object"], dataSchema: factDataSchema()
        ),
        descriptor(
            identity: "fact_search",
            name: AriaV2KnowledgeJournalOperation.factSearch.rawValue,
            effect: .read,
            description: "Search authorized facts by text or typed fact fields.",
            intents: ["Search authorized facts by text or typed fact fields."],
            properties: [
                "query": stringSchema(), "subject": stringSchema(), "predicate": stringSchema(), "object": stringSchema(),
                "limit": positiveIntegerSchema(), "estate_id": uuidSchema(),
            ],
            dataSchema: factsDataSchema()
        ),
        descriptor(
            identity: "retire_fact",
            name: AriaV2KnowledgeJournalOperation.retireFact.rawValue,
            effect: .write,
            description: "Retire one fact with an explicit reason.",
            intents: ["Retire one fact with an explicit reason."],
            properties: ["fact_id": uuidSchema(), "reason": stringSchema(), "estate_id": uuidSchema()],
            required: ["fact_id"], dataSchema: retireFactDataSchema()
        ),
        descriptor(
            identity: "fact_timeline",
            name: AriaV2KnowledgeJournalOperation.factTimeline.rawValue,
            effect: .read,
            description: "Read the ordered fact history for a subject.",
            intents: ["Read the ordered fact history for a subject."],
            properties: [
                "subject": stringSchema(), "predicate": stringSchema(), "limit": positiveIntegerSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["subject"], dataSchema: factsDataSchema()
        ),
        descriptor(
            identity: "write_journal",
            name: AriaV2KnowledgeJournalOperation.writeJournal.rawValue,
            effect: .write,
            description: "Write one durable journal entry.",
            intents: ["Write one durable journal entry."],
            properties: [
                "content": stringSchema(), "entry_time": stringSchema(), "tags": stringSchema(), "estate_id": uuidSchema(),
            ],
            required: ["content"], dataSchema: journalEntryDataSchema()
        ),
        descriptor(
            identity: "read_journal",
            name: AriaV2KnowledgeJournalOperation.readJournal.rawValue,
            effect: .read,
            description: "Read authorized journal entries in recorded order.",
            intents: ["Read authorized journal entries in recorded order."],
            properties: [
                "limit": positiveIntegerSchema(), "before": stringSchema(), "after": stringSchema(), "estate_id": uuidSchema(),
            ],
            dataSchema: journalEntriesDataSchema()
        ),
        descriptor(
            identity: "file_packet",
            name: AriaV2PacketFileRequest.toolName,
            effect: .write,
            description: "File a structured work packet and retain its durable drawer identity.",
            intents: ["file packet", "record work packet"],
            properties: [
                "objective": nonEmptyStringSchema(),
                "sources": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "description": nonEmptyStringSchema(),
                            "kind": nonEmptyStringSchema(),
                            "uri": stringSchema(),
                        ]),
                        "required": .array([.string("description")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
                "claims": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "statement": nonEmptyStringSchema(),
                            "confidence": .object([
                                "type": .string("number"),
                                "minimum": .integer(0),
                                "maximum": .integer(1),
                            ]),
                            "supportingSourceIDs": .object([
                                "type": .string("array"),
                                "items": stringSchema(),
                            ]),
                        ]),
                        "required": .array([.string("statement")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
                "uncertainties": stringArraySchema(),
                "next_steps": stringArraySchema(),
                "model": nonEmptyStringSchema(),
                "agent": nonEmptyStringSchema(),
                "sensitivity": enumSchema(["normal", "elevated", "restricted", "secret"]),
                "lineage_links": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "kind": enumSchema(["derivesFrom", "respondsTo"]),
                            "targetPacketID": uuidSchema(),
                        ]),
                        "required": .array([.string("kind"), .string("targetPacketID")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
                "wing": nonEmptyStringSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["objective", "model", "agent"], dataSchema: packetFileDataSchema()
        ),
        descriptor(
            identity: "packet_get",
            name: AriaV2PacketGetRequest.toolName,
            effect: .read,
            description: "Fetch one authorized work packet by its durable drawer UUID.",
            intents: ["get packet", "fetch work packet"],
            properties: ["drawer_id": uuidSchema(), "wing": nonEmptyStringSchema(), "estate_id": uuidSchema()],
            required: ["drawer_id"], dataSchema: packetGetDataSchema()
        ),
        descriptor(
            identity: "packet_list",
            name: AriaV2PacketListRequest.toolName,
            effect: .read,
            description: "List authorized work packets in newest-first capture order.",
            intents: ["list packets", "list work packets"],
            properties: [
                "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(100)]),
                "wing": nonEmptyStringSchema(), "estate_id": uuidSchema(),
            ], dataSchema: packetListDataSchema()
        ),
        descriptor(
            identity: "packet_lineage",
            name: AriaV2PacketLineageRequest.toolName,
            effect: .read,
            description: "Trace authorized packet antecedents breadth-first from a durable drawer UUID.",
            intents: ["packet lineage", "trace work packet"],
            properties: [
                "drawer_id": uuidSchema(),
                "max_depth": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(50)]),
                "wing": nonEmptyStringSchema(), "estate_id": uuidSchema(),
            ],
            required: ["drawer_id"], dataSchema: packetLineageDataSchema()
        ),
        descriptor(
            identity: "monitoring_set",
            name: AriaV2MonitoringSet.toolName,
            effect: .write,
            description: "Set daemon telemetry monitoring and return only its confirmed effective state.",
            intents: ["set monitoring", "enable monitoring", "disable monitoring"],
            properties: ["enabled": booleanSchema()],
            required: ["enabled"], dataSchema: monitoringSetDataSchema()
        ),
        descriptor(
            identity: "monitoring_status",
            name: AriaV2MonitoringInspection.toolName,
            effect: .read,
            description: "Inspect the current daemon telemetry monitoring state.",
            intents: ["monitoring status"],
            properties: [:], dataSchema: monitoringStatusDataSchema()
        ),
        descriptor(
            identity: "list_lenses",
            name: AriaV2CognitionCatalogService.lensesToolName,
            effect: .read,
            description: "List callable cognition lenses and recipes.",
            intents: ["list callable cognition lenses and recipes"],
            properties: ["verbose": booleanSchema(), "estate_id": uuidSchema()],
            dataSchema: cognitionLensesDataSchema()
        ),
        descriptor(
            identity: "list_recipes",
            name: AriaV2CognitionCatalogService.recipesToolName,
            effect: .read,
            description: "Browse non-callable recipe records and their callable tools.",
            intents: ["browse non-callable recipe records and their callable tools"],
            properties: ["verbose": booleanSchema(), "estate_id": uuidSchema()],
            dataSchema: cognitionRecipesDataSchema()
        ),
        descriptor(
            identity: "synthesize",
            name: AriaV2OrchestrationOperation.synthesize.rawValue,
            effect: .read,
            description: "Produce a grounded synthesis from authorized memories.",
            intents: ["Produce a grounded synthesis from authorized memories."],
            properties: [
                "query": stringSchema(),
                // filter: scope synthesis recall. "hasLinks" constrains to drawers with
                // citations/links — citation-scoped synthesis path (hasLinks feature flag).
                "filter": .object([
                    "type": .string("string"),
                    "description": .string("Filter kind: unconfirmed, userConfirmed, exportable, contained, hasLinks. 'hasLinks' scopes synthesis to drawers with links/citations. Composable with query. null is invalid."),
                ]),
                "limit": .object(["type": .string("integer"), "minimum": .integer(1)]),
                "estate_id": uuidSchema(),
            ],
            includeEmptyRequired: true,
            dataSchema: synthesisDataSchema()
        ),
        descriptor(
            identity: "dream",
            name: AriaV2Dream.toolName,
            effect: .write,
            description: "Run one on-demand maintenance and dreaming cycle.",
            intents: ["Run one on-demand maintenance and dreaming cycle."],
            properties: ["estate_id": uuidSchema()],
            includeEmptyRequired: true,
            dataSchema: dreamDataSchema()
        ),
        descriptor(
            identity: "migration_run",
            name: AriaV2OrchestrationOperation.runMigration.rawValue,
            effect: .read,
            description: "Evaluate migration plans and return candidates for a separate confirmation.",
            intents: ["Evaluate migration plans and return candidates for a separate confirmation."],
            properties: ["corpusName": stringSchema(), "entries": arraySchema(), "plans": arraySchema(), "estate_id": uuidSchema()],
            required: ["corpusName", "entries", "plans"],
            dataSchema: migrationRunDataSchema()
        ),
        descriptor(
            identity: "migration_confirm",
            name: AriaV2OrchestrationOperation.confirmMigration.rawValue,
            effect: .write,
            description: "Confirm one previously returned migration candidate.",
            intents: ["Confirm one previously returned migration candidate."],
            properties: ["winner_branch_id": uuidSchema(), "discard_branch_ids": uuidArraySchema(), "estate_id": uuidSchema()],
            required: ["winner_branch_id"],
            dataSchema: migrationConfirmDataSchema()
        ),
        descriptor(
            identity: "federated_recall",
            name: AriaV2OrchestrationOperation.federatedSearch.rawValue,
            effect: .read,
            description: "Search authorized peer estates from the requesting estate.",
            intents: ["Search authorized peer estates from the requesting estate."],
            properties: ["requester_estate_id": uuidSchema(), "filter": stringSchema(), "limit": positiveIntegerSchema(), "ordering": stringSchema(), "hydration_level": stringSchema()],
            includeEmptyRequired: true,
            dataSchema: federatedRecallDataSchema()
        ),
        descriptor(
            identity: "update_memory",
            name: "moot_update_memory",
            effect: .write,
            description: "Change an explicit mutable field of one memory.",
            intents: ["change an explicit mutable field of one memory"],
            properties: [
                "memory_id": uuidSchema(),
                "mutation": enumSchema(["confirm", "reject", "contest", "resolve", "supersede", "revive", "accept", "set_subject", "correct_sensitivity", "correct_exportability"]),
                "subject": .object([
                    "type": .string("string"),
                    "minLength": .integer(1),
                    "maxLength": .integer(120),
                ]),
                "sensitivity": enumSchema(["normal", "elevated", "restricted", "secret"]),
                "exportability": enumSchema(["private", "public"]),
                "note": stringSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["memory_id", "mutation"],
            inputSchemaAdditions: ["allOf": updateMemoryPayloadConditions()],
            dataSchema: mutationDataSchema()
        ),
        descriptor(
            identity: "withdraw_memory",
            name: "moot_withdraw_memory",
            effect: .write,
            description: "Withdraw one memory from ordinary recall while retaining audit history.",
            intents: ["withdraw one memory from ordinary recall while retaining audit history"],
            properties: ["memory_id": uuidSchema(), "reason": stringSchema(), "estate_id": uuidSchema()],
            required: ["memory_id"], dataSchema: idReceiptDataSchema()
        ),
        descriptor(
            identity: "erase_memory",
            name: "moot_erase_memory",
            effect: .write,
            description: "Permanently erase one memory after explicit confirmation.",
            intents: ["permanently erase one memory after explicit confirmation"],
            properties: [
                "memory_id": uuidSchema(),
                "confirmation": .object(["type": .string("boolean"), "const": .bool(true)]),
                "reason": stringSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["memory_id", "confirmation"], dataSchema: eraseMemoryDataSchema()
        ),
        descriptor(
            identity: "confirm_memory",
            name: "moot_confirm_memory",
            effect: .write,
            description: "Mark one memory as user-confirmed.",
            intents: ["mark one memory as user-confirmed"],
            properties: ["memory_id": uuidSchema(), "estate_id": uuidSchema()],
            required: ["memory_id"], dataSchema: confirmMemoryDataSchema()
        ),
        descriptor(
            identity: "move_memory",
            name: "moot_move_memory",
            effect: .write,
            description: "Move one memory to an explicit wing and room.",
            intents: ["move one memory to an explicit wing and room"],
            properties: ["memory_id": uuidSchema(), "wing": stringSchema(), "room": stringSchema(), "estate_id": uuidSchema()],
            required: ["memory_id", "wing", "room"], dataSchema: moveMemoryDataSchema()
        ),
        descriptor(
            identity: "link_memories",
            name: "moot_link_memories",
            effect: .write,
            description: "Create a directed typed connection between two memories.",
            intents: ["create a directed typed connection between two memories"],
            properties: [
                "from_id": uuidSchema(), "to_id": uuidSchema(),
                "relationship": enumSchema([
                    "blocks", "contradicts", "covers", "derives_from", "elaborates",
                    "exemplifies", "extends", "precedes", "references", "refines",
                    "relates", "responds_to", "supersedes", "supports", "validates",
                ]),
                "confidence": stringSchema(), "evidence": stringSchema(),
                // Default false, so an MCP-created link is ACTIVE — the caller
                // was told to make it. `true` files it in the proposed lifecycle
                // instead: the adjudication path, for a borderline candidate out
                // of moot_hunt_contradictions that the user should settle.
                "proposed": booleanSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["from_id", "to_id", "relationship"], dataSchema: tunnelReceiptSchema()
        ),
        descriptor(
            identity: "review_tunnel",
            name: "moot_review_tunnel",
            effect: .write,
            description: "Review a proposed connection and record its settled lifecycle.",
            intents: ["review a proposed connection and record its settled lifecycle"],
            properties: [
                "tunnel_id": uuidSchema(),
                "decision": enumSchema(["accept", "endorse", "reject"]),
                "note": stringSchema(),
                // Defaults to "user". Edge activation is user-only, so a model
                // reviewer passes its own id here and uses endorse or reject.
                "reviewed_by": stringSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["tunnel_id", "decision"], dataSchema: reviewTunnelDataSchema()
        ),
        descriptor(
            identity: "estate_ping",
            name: AriaV2EstateDiagnosticOperation.estatePing.rawValue,
            effect: .read,
            description: "Check whether the selected estate is reachable.",
            intents: ["estate ping", "check estate"],
            properties: ["estate_id": uuidSchema()],
            dataSchema: estatePingDataSchema()
        ),
        descriptor(
            identity: "estate_status",
            name: AriaV2EstateDiagnosticOperation.estateStatus.rawValue,
            effect: .read,
            description: "Inspect the selected estate status and effective surface metadata.",
            intents: ["estate status", "inspect estate"],
            properties: ["estate_id": uuidSchema()],
            dataSchema: estateStatusDataSchema()
        ),
        descriptor(
            identity: "estate_map",
            name: AriaV2EstateDiagnosticOperation.estateMap.rawValue,
            effect: .read,
            description: "Inspect the selected estate structural map.",
            intents: ["estate map", "map estate"],
            properties: ["estate_id": uuidSchema()],
            dataSchema: estateMapDataSchema()
        ),
        descriptor(
            identity: "drain_status",
            name: AriaV2EstateDiagnosticOperation.drainStatus.rawValue,
            effect: .read,
            description: "Inspect background drain progress.",
            intents: ["drain status", "background progress"],
            properties: ["estate_id": uuidSchema()],
            dataSchema: drainStatusDataSchema()
        ),
        descriptor(
            identity: "rebuild_status",
            name: AriaV2EstateDiagnosticOperation.rebuildStatus.rawValue,
            effect: .read,
            description: "Inspect background rebuild progress.",
            intents: ["rebuild status", "background rebuild"],
            properties: ["estate_id": uuidSchema()],
            dataSchema: rebuildStatusDataSchema()
        ),
        descriptor(
            identity: "timing_report",
            name: AriaV2EstateDiagnosticOperation.timingReport.rawValue,
            effect: .read,
            description: "Read the current timing report.",
            intents: ["timing report", "performance timing"],
            properties: ["estate_id": uuidSchema()],
            dataSchema: timingReportDataSchema()
        ),
        descriptor(
            identity: "reindex",
            name: "moot_reindex",
            effect: .write,
            description: "Request a bounded index backfill for the selected estate.",
            intents: ["Request a bounded index backfill for the selected estate."],
            properties: ["estate_id": uuidSchema()],
            includeEmptyRequired: true,
            dataSchema: reindexDataSchema()
        ),
        descriptor(
            identity: "reclassify_fdc",
            name: "moot_reclassify_fdc",
            effect: .write,
            description: "Reclassify stored field-density categories.",
            intents: ["Reclassify stored field-density categories."],
            properties: [
                "estate_id": uuidSchema(),
                "apply": booleanSchema(),
                "mode": enumSchema(["suspectOnly", "all"]),
                "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(50000)]),
            ],
            includeEmptyRequired: true,
            dataSchema: reclassifyFDCDataSchema()
        ),
        descriptor(
            identity: "palace_import",
            name: "moot_palace_import",
            effect: .write,
            description: "Import a MemPalace root containing palace/chroma.sqlite3 into the selected estate.",
            intents: ["Import a MemPalace root containing palace/chroma.sqlite3 into the selected estate."],
            properties: [
                "palace_path": stringSchema(),
                "mode": enumSchema(AriaV2DataMobilityRequest.ImportMode.allCases.map(\.rawValue)),
                "estate_id": uuidSchema(),
            ],
            required: ["palace_path"],
            requiredCapabilities: [vaultCapability],
            dataSchema: palaceImportDataSchema()
        ),
        descriptor(
            identity: "json_import",
            name: "moot_json_import",
            effect: .write,
            description: "Import a local JSON source into the selected estate.",
            intents: ["Import a local JSON source into the selected estate."],
            properties: [
                "path": stringSchema(),
                // return_id_map:true adds a second text block with a JSON map
                // {"id_map":{"<record id>":"<drawer id>"}} naming the drawer each
                // seed record became. Off by default (most callers want the receipt,
                // not N id pairs).
                "return_id_map": booleanSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["path"],
            requiredCapabilities: [vaultCapability],
            dataSchema: jsonImportDataSchema()
        ),
        descriptor(
            identity: "file_dataset",
            name: "moot_file_dataset",
            effect: .write,
            description: "File a structured dataset into the selected estate.",
            intents: ["File a structured dataset into the selected estate."],
            properties: [
                "name": stringSchema(),
                "location": stringSchema(),
                "columns": arraySchema(),
                "rows": arraySchema(),
                "csv_path": stringSchema(),
                "wing": stringSchema(),
                "sensitivity": enumSchema(["normal", "elevated", "restricted", "secret"]),
                "estate_id": uuidSchema(),
            ],
            required: ["name", "location"],
            inputSchemaAdditions: ["oneOf": exactlyOneOf("rows", "csv_path")],
            dataSchema: fileDatasetDataSchema()
        ),
        descriptor(
            identity: "dataset_query",
            name: "moot_dataset_query",
            effect: .read,
            description: "Query a dataset with a strict typed predicate.",
            intents: ["Query a dataset with a strict typed predicate."],
            properties: [
                "dataset_id": uuidSchema(),
                "where": .object(["$ref": .string("#/$defs/datasetPredicate")]),
                "order_by": .object(["type": .string("array"), "items": datasetOrderSchema()]),
                "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(1_000)]),
                "columns": .object(["type": .string("array"), "items": .object(["type": .string("string"), "minLength": .integer(1)])]),
                "estate_id": uuidSchema(),
            ],
            required: ["dataset_id"],
            inputSchemaAdditions: ["$defs": datasetPredicateDefinitions()],
            dataSchema: datasetQueryDataSchema()
        ),
        descriptor(
            identity: "dataset_stats",
            name: "moot_dataset_stats",
            effect: .read,
            description: "Read summary statistics for one dataset.",
            intents: ["Read summary statistics for one dataset."],
            properties: [
                "dataset_id": uuidSchema(),
                "column": stringSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["dataset_id"],
            dataSchema: datasetStatsDataSchema()
        ),
        descriptor(
            identity: "vault_status",
            name: "moot_vault_status",
            effect: .read,
            description: "Inspect local vault synchronization state.",
            intents: ["Inspect local vault synchronization state."],
            properties: ["vaultPath": stringSchema()],
            required: ["vaultPath"],
            requiredCapabilities: [vaultCapability],
            dataSchema: vaultStatusDataSchema()
        ),
        descriptor(
            identity: "vault_reconcile",
            name: "moot_vault_reconcile",
            effect: .write,
            description: "Compare a local vault with the estate and optionally apply reconciliation.",
            intents: ["Compare a local vault with the estate and optionally apply reconciliation."],
            properties: [
                "vaultPath": stringSchema(),
                "apply": booleanSchema(),
                "estate_id": uuidSchema(),
            ],
            required: ["vaultPath"],
            requiredCapabilities: [vaultCapability],
            dataSchema: vaultReconcileDataSchema()
        ),
        descriptor(
            identity: "vault_export",
            name: "moot_vault_export",
            effect: .read,
            description: "Export the authorized selected estate scope to a local vault.",
            intents: ["Export the authorized selected estate scope to a local vault."],
            properties: [
                "vaultPath": stringSchema(), "scope": stringSchema(), "estate_id": uuidSchema(),
            ],
            required: ["vaultPath"],
            requiredCapabilities: [vaultCapability],
            dataSchema: vaultLaunchDataSchema()
        ),
        descriptor(
            identity: "vault_import",
            name: "moot_vault_import",
            effect: .write,
            description: "Import a local vault into the selected estate.",
            intents: ["Import a local vault into the selected estate."],
            properties: [
                "vaultPath": stringSchema(), "mode": stringSchema(), "estate_id": uuidSchema(),
            ],
            required: ["vaultPath"],
            requiredCapabilities: [vaultCapability],
            dataSchema: vaultLaunchDataSchema()
        ),
        descriptor(
            identity: "vault_job",
            name: "moot_vault_job",
            effect: .read,
            description: "Fetch the status of one vault job. Returns running, complete, or failed status with progress details.",
            intents: ["Fetch the status of one vault job."],
            // job_id carries a description so the tools/list entry matches the v2 catalog
            // and Rust port exactly — both ports share the "Job ID returned by..." text.
            properties: ["job_id": .object([
                "type": .string("string"),
                "format": .string("uuid"),
                "description": .string("Job ID returned by moot_vault_import or moot_vault_export."),
            ])],
            required: ["job_id"],
            requiredCapabilities: [vaultCapability],
            dataSchema: vaultJobDataSchema()
        ),
    ]

    private static func descriptor(
        identity: String,
        name: String,
        effect: AriaV2OperationEffect,
        description: String,
        intents: [String],
        properties: [String: JSONValue],
        required: [String] = [],
        includeEmptyRequired: Bool = false,
        requiredCapabilities: Set<AriaV2Capability> = [coreCapability],
        inputSchemaAdditions: [String: JSONValue] = [:],
        dataSchema: JSONValue? = nil
    ) -> AriaV2OperationDescriptor {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty || includeEmptyRequired {
            schema["required"] = .array(required.map(JSONValue.string))
        }
        for (key, value) in inputSchemaAdditions {
            schema[key] = value
        }
        return AriaV2OperationDescriptor(
            identity: .init(rawValue: identity),
            publicName: name,
            effect: effect,
            availability: .init(requiredCapabilities: requiredCapabilities),
            inputSchema: .object(schema),
            projection: .init(
                outputSchema: outputSchema(tool: name, effect: effect, dataSchema: dataSchema),
                compactTextDescription: description
            ),
            help: .init(description: description, intents: intents)
        )
    }

    private static func outputSchema(
        tool: String,
        effect: AriaV2OperationEffect,
        dataSchema: JSONValue? = nil
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "surface_version": .object(["const": .string("v2")]),
                "tool": .object(["const": .string(tool)]),
                "data": dataSchema ?? .object(["type": .string("object"), "additionalProperties": .bool(true)]),
                "meta": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "completeness": .object(["const": .string("incomplete")]),
                        "effect": .object(["const": .string(effect.rawValue)]),
                    ]),
                    "required": .array([.string("completeness"), .string("effect")]),
                    "additionalProperties": .bool(true),
                ]),
            ]),
            "required": .array([.string("surface_version"), .string("tool"), .string("data"), .string("meta")]),
            "additionalProperties": .bool(false),
        ])
    }

    private static func exactlyOneOf(_ first: String, _ second: String) -> JSONValue {
        .array([
            .object([
                "required": .array([.string(first)]),
                "not": .object(["required": .array([.string(second)])]),
            ]),
            .object([
                "required": .array([.string(second)]),
                "not": .object(["required": .array([.string(first)])]),
            ]),
        ])
    }

    private static func updateMemoryPayloadConditions() -> JSONValue {
        func condition(mutation: String, payload: String) -> JSONValue {
            .object([
                "if": .object([
                    "properties": .object(["mutation": .object(["const": .string(mutation)])]),
                    "required": .array([.string("mutation")]),
                ]),
                "then": .object(["required": .array([.string(payload)])]),
                "else": .object(["not": .object(["required": .array([.string(payload)])])]),
            ])
        }
        return .array([
            condition(mutation: "set_subject", payload: "subject"),
            condition(mutation: "correct_sensitivity", payload: "sensitivity"),
            condition(mutation: "correct_exportability", payload: "exportability"),
            .object([
                "if": .object([
                    "properties": .object(["mutation": .object(["const": .string("confirm")])]),
                    "required": .array([.string("mutation")]),
                ]),
                "then": .object(["not": .object(["required": .array([.string("note")])])]),
            ]),
        ])
    }

    private static func memoryListDataSchema() -> JSONValue {
        let fetch = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "tool": .object(["const": .string("moot_memory_get")]),
                "arguments": .object([
                    "type": .string("object"),
                    "properties": .object(["memory_id": uuidSchema()]),
                    "required": .array([.string("memory_id")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "required": .array([.string("tool"), .string("arguments")]),
            "additionalProperties": .bool(false),
        ])
        let memory = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "memory_id": uuidSchema(),
                "subject": stringSchema(),
                "score": .object(["type": .string("number")]),
                "provenance": stringSchema(),
                "context": stringSchema(),
                "fetch": fetch,
            ]),
            "required": .array([.string("memory_id"), .string("fetch")]),
            "additionalProperties": .bool(false),
        ])
        return .object([
            "type": .string("object"),
            "properties": .object([
                "memories": .object(["type": .string("array"), "items": memory]),
                "has_more": booleanSchema(),
                "next_cursor": stringSchema(),
                "revision": stringSchema(),
            ]),
            "required": .array([.string("memories"), .string("has_more"), .string("revision")]),
            "additionalProperties": .bool(false),
        ])
    }

    private static func synthesisDataSchema() -> JSONValue {
        orderedExactObjectSchema([
            "summary": stringSchema(),
            "cues": .object(["type": .string("array"), "items": stringSchema()]),
            "results": .object(["type": .string("array"), "items": compactMemorySchema()]),
        ], required: ["summary", "results"])
    }

    private static func compactMemorySchema() -> JSONValue {
        let fetch = orderedExactObjectSchema([
            "tool": .object(["const": .string("moot_memory_get")]),
            "arguments": orderedExactObjectSchema(
                ["memory_id": uuidSchema()], required: ["memory_id"]),
        ], required: ["tool", "arguments"])
        return orderedExactObjectSchema([
            "memory_id": uuidSchema(),
            "subject": stringSchema(),
            "score": numberSchema(),
            "provenance": stringSchema(),
            "context": stringSchema(),
            "excerpt": .object(["type": .string("string"), "maxLength": .integer(512)]),
            "fetch": fetch,
        ], required: ["memory_id", "fetch"])
    }

    private static func lensDataSchema(_ operation: AriaV2RecallLensOperation) -> JSONValue {
        let stringArray = JSONValue.object(["type": .string("array"), "items": stringSchema()])
        switch operation {
        case .lensKeystones:
            return orderedExactObjectSchema([
                "keystones": .object([
                    "type": .string("array"),
                    "items": orderedExactObjectSchema(
                        ["id": stringSchema(), "centrality": numberSchema()],
                        required: ["id", "centrality"]),
                ]),
            ], required: ["keystones"])
        case .lensConstellation:
            return orderedExactObjectSchema([
                "communities": .object(["type": .string("array"), "items": stringArray]),
            ], required: ["communities"])
        case .lensFreeAssociation:
            return orderedExactObjectSchema([
                "associations": .object([
                    "type": .string("array"),
                    "items": orderedExactObjectSchema(
                        ["drawerID": stringSchema(), "activation": numberSchema()],
                        required: ["drawerID", "activation"]),
                ]),
            ], required: ["associations"])
        case .lensBias:
            let bias = orderedExactObjectSchema(
                ["label": stringSchema(), "bias": numberSchema()], required: ["label", "bias"])
            let dismissal = orderedExactObjectSchema(
                ["nodeId": stringSchema(), "rate": numberSchema()], required: ["nodeId", "rate"])
            let learned = orderedExactObjectSchema([
                "label": stringSchema(), "strength": numberSchema(),
                "endorsements": integerSchema(), "dismissals": integerSchema(),
            ], required: ["label", "strength", "endorsements", "dismissals"])
            return orderedExactObjectSchema([
                "biasedFor": .object(["type": .string("array"), "items": bias]),
                "biasedAgainst": .object(["type": .string("array"), "items": bias]),
                "dismissal": .object(["type": .string("array"), "items": dismissal]),
                "learned": .object(["type": .string("array"), "items": learned]),
            ], required: ["biasedFor", "biasedAgainst", "dismissal", "learned"])
        case .lensCohesion:
            return .object([
                "oneOf": .array([
                    orderedExactObjectSchema(
                        ["considered": integerSchema(), "outliers": stringArray],
                        required: ["considered", "outliers"]),
                    orderedExactObjectSchema([
                        "rowsScored": integerSchema(),
                        "topAnomalies": .object([
                            "type": .string("array"),
                            "items": orderedExactObjectSchema(
                                ["rowIndex": integerSchema(), "score": numberSchema()],
                                required: ["rowIndex", "score"]),
                        ]),
                    ], required: ["rowsScored", "topAnomalies"]),
                ]),
            ])
        case .lensContradiction:
            let tunnel = orderedExactObjectSchema([
                "id": stringSchema(), "sourceDrawerId": stringSchema(),
                "targetDrawerId": stringSchema(), "lifecycle": enumSchema(["active", "proposed"]),
            ], required: ["id", "lifecycle"])
            let fact = orderedExactObjectSchema([
                "subject": stringSchema(), "predicate": stringSchema(), "objects": stringArray,
            ], required: ["subject", "predicate", "objects"])
            return orderedExactObjectSchema([
                "contradictsTunnels": .object(["type": .string("array"), "items": tunnel]),
                "conflictingFacts": .object(["type": .string("array"), "items": fact]),
            ], required: ["contradictsTunnels", "conflictingFacts"])
        case .lensThemeWeather:
            let row = orderedExactObjectSchema(
                ["category": stringSchema(), "momentum": numberSchema()],
                required: ["category", "momentum"])
            return orderedExactObjectSchema([
                "weather": .object(["type": .string("array"), "items": row]),
            ], required: ["weather"])
        case .lensLatentThemes:
            let row = orderedExactObjectSchema(
                ["label": stringSchema(), "dominantTheme": integerSchema()],
                required: ["label", "dominantTheme"])
            return orderedExactObjectSchema([
                "k": integerSchema(),
                "loadings": .object(["type": .string("array"), "items": row]),
            ], required: ["k", "loadings"])
        case .lensDrift:
            let metric = orderedExactObjectSchema([
                "jensenShannon": numberSchema(), "klDivergence": numberSchema(),
            ], required: ["jensenShannon", "klDivergence"])
            return orderedExactObjectSchema([
                "beforeCount": integerSchema(), "afterCount": integerSchema(), "drift": metric,
            ], required: ["beforeCount", "afterCount", "drift"])
        case .lensTrustSynthesis:
            let context = orderedExactObjectSchema([
                "summary": stringSchema(),
                "patterns": .object(["type": .string("array"), "items": stringSchema()]),
                "successRate": numberSchema(), "averageReward": numberSchema(),
                "recommendations": .object(["type": .string("array"), "items": stringSchema()]),
                "keyInsights": .object(["type": .string("array"), "items": stringSchema()]),
            ], required: ["summary", "patterns", "successRate", "averageReward", "recommendations", "keyInsights"])
            let confidence = orderedExactObjectSchema([
                "claimed": numberSchema(), "calibrated": numberSchema(), "isCalibrated": booleanSchema(),
            ], required: ["claimed", "calibrated", "isCalibrated"])
            return orderedExactObjectSchema([
                "context": context,
                "rankedIDs": .object(["type": .string("array"), "items": stringSchema()]),
                "highTrustCount": integerSchema(),
                "calibratedConfidences": .object(["type": .string("array"), "items": confidence]),
            ], required: ["context", "rankedIDs", "highTrustCount"])
        case .lensPartialCue:
            return orderedExactObjectSchema([
                "results": .object(["type": .string("array"), "items": lensMemoryRowSchema()]),
                "capabilities": lensCapabilitiesSchema(),
            ], required: ["results"])
        case .lensAnticipate:
            let row = orderedExactObjectSchema([
                "action": integerSchema(), "successRate": numberSchema(), "count": integerSchema(),
            ], required: ["action", "successRate", "count"])
            return orderedExactObjectSchema([
                "actions": .object(["type": .string("array"), "items": row]),
            ], required: ["actions"])
        case .lensNodeMotion:
            return orderedExactObjectSchema([
                "rowID": stringSchema(), "volatility": numberSchema(), "eventCount": integerSchema(),
                "lastEventPhysicalMs": integerSchema(),
                "anchorTrajectory": .object(["type": .string("array"), "items": integerSchema()]),
                "reanchored": booleanSchema(), "currentAnchor": integerSchema(),
                "anomaly": enumSchema(["churning", "reanchored", "stable"]),
            ], required: ["rowID", "volatility", "eventCount", "anchorTrajectory", "reanchored", "anomaly"])
        case .lensSuccessors:
            let successor = orderedExactObjectSchema(
                ["id": stringSchema(), "weight": numberSchema()], required: ["id", "weight"])
            return orderedExactObjectSchema([
                "successors": .object(["type": .string("array"), "items": successor]),
            ], required: ["successors"])
        case .lensOverlap:
            return orderedExactObjectSchema([
                "overlap": numberSchema(), "aSufficient": booleanSchema(), "bSufficient": booleanSchema(),
            ], required: ["overlap", "aSufficient", "bSufficient"])
        case .lensDivergence:
            let metric = orderedExactObjectSchema([
                "jensenShannon": numberSchema(), "klDivergence": numberSchema(),
            ], required: ["jensenShannon", "klDivergence"])
            return orderedExactObjectSchema([
                "aCount": integerSchema(), "bCount": integerSchema(), "divergence": metric,
            ], required: ["aCount", "bCount", "divergence"])
        case .lensAssociations:
            let rule = orderedExactObjectSchema([
                "antecedent": stringSchema(), "consequent": stringSchema(), "support": numberSchema(),
                "confidence": numberSchema(), "lift": numberSchema(), "conviction": numberSchema(),
                "leverage": numberSchema(), "exemplarDrawerIDs": stringArray,
            ], required: ["antecedent", "consequent", "support", "confidence", "lift", "conviction", "leverage", "exemplarDrawerIDs"])
            return orderedExactObjectSchema([
                "rules": .object(["type": .string("array"), "items": rule]),
                "drawerCount": integerSchema(), "rowCount": integerSchema(), "labelOverflow": booleanSchema(),
            ], required: ["rules", "labelOverflow"])
        case .lensConcepts:
            let concept = orderedExactObjectSchema([
                "intent": stringArray, "extentDrawerIDs": stringArray,
                "support": integerSchema(), "stability": numberSchema(),
            ], required: ["intent", "extentDrawerIDs", "support"])
            let delta = orderedExactObjectSchema([
                "lowerIntent": stringArray, "addedAttributes": stringArray,
            ], required: ["lowerIntent", "addedAttributes"])
            let implication = orderedExactObjectSchema([
                "premise": stringArray, "conclusion": stringArray,
            ], required: ["premise", "conclusion"])
            return orderedExactObjectSchema([
                "concepts": .object(["type": .string("array"), "items": concept]),
                "drawerCount": integerSchema(),
                "coverDeltas": .object(["type": .string("array"), "items": delta]),
                "implications": .object(["type": .string("array"), "items": implication]),
                "implicationsTruncated": booleanSchema(),
            ], required: ["concepts", "drawerCount", "coverDeltas", "implications", "implicationsTruncated"])
        case .lensApriori:
            let rule = orderedExactObjectSchema([
                "antecedent": stringArray, "consequent": stringSchema(), "support": numberSchema(),
                "confidence": numberSchema(), "lift": numberSchema(), "evidenceCount": integerSchema(),
            ], required: ["antecedent", "consequent", "support", "confidence", "lift", "evidenceCount"])
            return orderedExactObjectSchema([
                "rules": .object(["type": .string("array"), "items": rule]),
            ], required: ["rules"])
        case .lensMoment:
            let ranking = orderedExactObjectSchema(
                ["hammingDistance": integerSchema()], required: ["hammingDistance"])
            return orderedExactObjectSchema([
                "windowCount": integerSchema(),
                "ranking": .object(["type": .string("array"), "items": ranking]),
            ], required: ["windowCount", "ranking"])
        case .lensRhythm:
            let period = orderedExactObjectSchema([
                "periodSeconds": integerSchema(), "relativeMagnitude": numberSchema(),
            ], required: ["periodSeconds", "relativeMagnitude"])
            return orderedExactObjectSchema([
                "bucketCount": integerSchema(),
                "periods": .object(["type": .string("array"), "items": period]),
            ], required: ["bucketCount", "periods"])
        case .lensPrecedence:
            let source = orderedExactObjectSchema(
                ["fieldPath": stringSchema(), "valueRepr": stringSchema()],
                required: ["fieldPath", "valueRepr"])
            let antecedent = orderedExactObjectSchema([
                "source": source, "lagBucket": integerSchema(), "count": integerSchema(),
            ], required: ["source", "lagBucket", "count"])
            return orderedExactObjectSchema([
                "entryCount": integerSchema(),
                "antecedents": .object(["type": .string("array"), "items": antecedent]),
            ], required: ["entryCount", "antecedents"])
        case .lensComplexity:
            let result = orderedExactObjectSchema([
                "entropyA": numberSchema(), "entropyB": numberSchema(), "mutualInformation": numberSchema(),
            ], required: ["entropyA"])
            return orderedExactObjectSchema([
                "totalCount": integerSchema(), "nonNullCount": integerSchema(), "nullCount": integerSchema(),
                "result": result,
            ], required: ["result"])
        default:
            preconditionFailure("only selected lens operations use the exact lens schema")
        }
    }

    private static func lensMemoryRowSchema() -> JSONValue {
        orderedExactObjectSchema([
            "id": stringSchema(), "subject": stringSchema(), "bestSpan": stringSchema(),
            "sscFacts": stringSchema(), "eventTime": stringSchema(), "score": numberSchema(),
            "room": stringSchema(), "retrievalSource": enumSchema(["anchor", "walk", "both"]),
            "distilled": stringSchema(), "representation": .object(["const": .string("distilled")]),
            "tier": enumSchema(["summary", "original"]),
        ], required: ["id", "eventTime"])
    }

    private static func lensCapabilitiesSchema() -> JSONValue {
        let temporal = orderedExactObjectSchema([
            "mode": enumSchema(["loose", "tight"]), "source": stringSchema(),
            "grab": enumSchema(["pool", "dated"]), "from": stringSchema(), "to": stringSchema(),
            "widenedDays": integerSchema(),
        ], required: ["mode", "source", "grab", "from", "to"])
        let walk = orderedExactObjectSchema([
            "stage": enumSchema(["stage1_session_hybrid", "stage2_precise_hamming"]),
            "stoppedEarly": booleanSchema(),
        ], required: ["stage", "stoppedEarly"])
        return orderedExactObjectSchema([
            "discrimination": enumSchema(["low", "medium"]), "temporal": temporal, "walk": walk,
        ], required: [])
    }

    private static func connectionEdgesDataSchema() -> JSONValue {
        exactObjectSchema([
            "edges": .object(["type": .string("array"), "items": tunnelSchema()]),
        ])
    }

    private static func tunnelSchema() -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "tunnel_id": uuidSchema(),
                // Room-level tunnel endpoints have no drawer UUID at the lower layer.
                "from_id": uuidSchema(),
                "to_id": uuidSchema(),
                "kind": stringSchema(),
                // Always present. Distinguishes a confirmed edge from an
                // unreviewed proposal filed by dreaming or the hunt.
                "lifecycle": enumSchema(["active", "proposed", "superseded", "withdrawn"]),
            ]),
            "required": .array([.string("tunnel_id"), .string("kind"), .string("lifecycle")]),
            "additionalProperties": .bool(false),
        ])
    }

    private static func factDataSchema() -> JSONValue { factSchema() }

    private static func factsDataSchema() -> JSONValue {
        exactObjectSchema([
            "facts": .object(["type": .string("array"), "items": factSchema()]),
        ])
    }

    private static func factSchema() -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "fact_id": uuidSchema(),
                "subject": stringSchema(),
                "predicate": stringSchema(),
                "object": stringSchema(),
                // Unanchored lower facts have no source drawer; omit the key.
                "source_memory_id": uuidSchema(),
                "event_time": dateSchema(),
                "state": stringSchema(),
            ]),
            "required": .array([
                .string("fact_id"), .string("subject"), .string("predicate"), .string("object"),
            ]),
            "additionalProperties": .bool(false),
        ])
    }

    private static func retireFactDataSchema() -> JSONValue {
        exactObjectSchema(["fact_id": uuidSchema()])
    }

    private static func journalEntryDataSchema() -> JSONValue {
        exactObjectSchema([
            "agent_name": stringSchema(), "entry": stringSchema(), "written_at": dateSchema(),
        ])
    }

    private static func journalEntriesDataSchema() -> JSONValue {
        exactObjectSchema([
            "entries": .object(["type": .string("array"), "items": journalEntryDataSchema()]),
        ])
    }

    private static func cognitionLensesDataSchema() -> JSONValue {
        let tool = exactObjectSchema([
            "name": stringSchema(),
            "description": stringSchema(),
            "input_schema": .object(["type": .string("object"), "additionalProperties": .bool(true)]),
        ])
        return exactObjectSchema([
            "tools": .object(["type": .string("array"), "items": tool]),
        ])
    }

    private static func cognitionRecipesDataSchema() -> JSONValue {
        return exactObjectSchema([
            "recipes": .object([
                "type": .string("array"),
                "items": .object(["$ref": .string("#/definitions/recipe")]),
            ]),
        ])
    }

    private static func helpOperationSchema() -> JSONValue {
        orderedExactObjectSchema([
            "id": stringSchema(), "name": stringSchema(), "description": stringSchema(),
            "effect": enumSchema(["read", "write"]), "input_schema": objectSchema(),
            "output_schema": objectSchema(), "intents": stringArraySchema(),
        ], required: ["id", "name", "description", "effect", "input_schema", "output_schema", "intents"])
    }

    private static func helpDataSchema() -> JSONValue {
        let operations = JSONValue.object(["type": .string("array"), "items": helpOperationSchema()])
        let record = orderedExactObjectSchema([
            "recipe_id": stringSchema(), "description": stringSchema(), "callable": .object(["const": .bool(false)]),
            "callable_tools": stringArraySchema(),
        ], required: ["recipe_id", "description", "callable", "callable_tools"])
        return .object(["oneOf": .array([
            orderedExactObjectSchema(["operation": helpOperationSchema()], required: ["operation"]),
            orderedExactObjectSchema(["intent": stringSchema(), "operations": operations], required: ["intent", "operations"]),
            orderedExactObjectSchema(["operations": operations, "directory_records": .object(["type": .string("array"), "items": record])], required: ["operations", "directory_records"]),
        ])])
    }

    private static func packetFileDataSchema() -> JSONValue {
        orderedExactObjectSchema([
            "drawer_id": uuidSchema(), "packet_id": uuidSchema(), "schema_version": positiveIntegerSchema(),
            "objective": stringSchema(), "sources": nonnegativeIntegerSchema(), "claims": nonnegativeIntegerSchema(),
            "uncertainties": nonnegativeIntegerSchema(), "next_steps": nonnegativeIntegerSchema(),
            "lineage_links": nonnegativeIntegerSchema(), "sensitivity": enumSchema(["normal", "elevated", "restricted", "secret"]),
        ], required: ["drawer_id", "packet_id", "schema_version", "objective", "sources", "claims", "uncertainties", "next_steps", "lineage_links", "sensitivity"])
    }

    private static func packetSchema() -> JSONValue {
        let source = orderedExactObjectSchema(["id": uuidSchema(), "description": stringSchema(), "uri": stringSchema(), "kind": stringSchema()], required: ["id", "description", "kind"])
        let claim = orderedExactObjectSchema(["id": uuidSchema(), "statement": stringSchema(), "confidence": numberSchema(), "supporting_source_ids": uuidArraySchema()], required: ["id", "statement", "confidence", "supporting_source_ids"])
        let provenance = orderedExactObjectSchema(["model": stringSchema(), "agent": stringSchema(), "created_at": dateSchema(), "updated_at": dateSchema()], required: ["model", "agent", "created_at", "updated_at"])
        let link = orderedExactObjectSchema(["kind": enumSchema(["derivesFrom", "respondsTo"]), "target_packet_id": uuidSchema()], required: ["kind", "target_packet_id"])
        return orderedExactObjectSchema([
            "drawer_id": uuidSchema(), "packet_id": uuidSchema(), "schema_version": positiveIntegerSchema(), "future_schema": booleanSchema(),
            "objective": stringSchema(), "sources": .object(["type": .string("array"), "items": source]),
            "claims": .object(["type": .string("array"), "items": claim]), "uncertainties": stringArraySchema(),
            "next_steps": stringArraySchema(), "provenance": provenance,
            "lineage_links": .object(["type": .string("array"), "items": link]),
        ], required: ["drawer_id", "packet_id", "schema_version", "future_schema", "objective", "sources", "claims", "uncertainties", "next_steps", "provenance", "lineage_links"])
    }

    private static func packetGetDataSchema() -> JSONValue { orderedExactObjectSchema(["packet": packetSchema()], required: ["packet"]) }
    private static func packetListDataSchema() -> JSONValue {
        let summary = orderedExactObjectSchema(["drawer_id": uuidSchema(), "packet_id": uuidSchema(), "objective": stringSchema(), "model": stringSchema(), "agent": stringSchema(), "lineage_count": nonnegativeIntegerSchema()], required: ["drawer_id", "packet_id", "objective", "model", "agent", "lineage_count"])
        return orderedExactObjectSchema(["packets": .object(["type": .string("array"), "items": summary]), "total": nonnegativeIntegerSchema()], required: ["packets", "total"])
    }
    private static func packetLineageDataSchema() -> JSONValue { orderedExactObjectSchema(["root": uuidSchema(), "antecedents": uuidArraySchema(), "count": nonnegativeIntegerSchema()], required: ["root", "antecedents", "count"]) }
    private static func monitoringSetDataSchema() -> JSONValue { orderedExactObjectSchema(["monitoring": enumSchema(["enabled", "disabled"])], required: ["monitoring"]) }
    private static func monitoringStatusDataSchema() -> JSONValue { orderedExactObjectSchema(["monitoring": enumSchema(["enabled", "disabled", "unavailable"])], required: ["monitoring"]) }

    private static func placementSchema() -> JSONValue {
        orderedExactObjectSchema(["wing": stringSchema(), "room": stringSchema()], required: ["wing", "room"])
    }

    private static func fetchSchema() -> JSONValue {
        orderedExactObjectSchema([
            "tool": .object(["const": .string("moot_memory_get")]),
            "arguments": orderedExactObjectSchema(["memory_id": uuidSchema()], required: ["memory_id"]),
        ], required: ["tool", "arguments"])
    }

    private static func contradictionCandidateSchema() -> JSONValue {
        let endpoint = orderedExactObjectSchema([
            "memory_id": uuidSchema(),
            "excerpt": stringSchema(),
            "fetch": fetchSchema(),
        ], required: ["memory_id", "excerpt", "fetch"])
        return orderedExactObjectSchema([
            "candidate_id": nonEmptyStringSchema(),
            "reason": nonEmptyStringSchema(),
            "source": endpoint,
            "target": endpoint,
        ], required: ["candidate_id", "reason", "source", "target"])
    }

    private static func fileMemoryDataSchema() -> JSONValue {
        orderedExactObjectSchema([
            "memory_id": uuidSchema(), "placement": placementSchema(), "fetch": fetchSchema(),
        ], required: ["memory_id", "placement", "fetch"])
    }

    private static func fullMemorySchema() -> JSONValue {
        orderedExactObjectSchema([
            "memory_id": uuidSchema(), "subject": stringSchema(), "distilled": stringSchema(),
            "content": stringSchema(), "placement": placementSchema(), "filed_at": dateSchema(),
            "event_time": dateSchema(), "state": stringSchema(), "trust": stringSchema(),
            "sensitivity": stringSchema(), "exportability": stringSchema(), "confirmation": stringSchema(),
            "lineage_id": uuidSchema(), "fetch": fetchSchema(),
        ], required: ["memory_id", "fetch"])
    }

    private static func memoryGetDataSchema() -> JSONValue {
        orderedExactObjectSchema([
            "memories": .object(["type": .string("array"), "items": fullMemorySchema()]),
        ], required: ["memories"])
    }

    private static func memorySearchDataSchema() -> JSONValue {
        // `results` is always present (even empty array for L0 answer-only mode).
        // `answer` is optional: absent for answer:never or when confidence is WEAK
        // or composedAnswer is unavailable. Its presence signals a non-empty answer block.
        let signalsSchema = orderedExactObjectSchema([
            "margin": numberSchema(),
            "lane_agreement": numberSchema(),
            "dense_spread": numberSchema(),
            "containment": booleanSchema(),
        ], required: ["margin", "lane_agreement", "dense_spread", "containment"])
        let answerSchema = orderedExactObjectSchema([
            "text": stringSchema(),
            "confidence": enumSchema(["confident", "intermediate"]),
            "citations": .object(["type": .string("array"), "items": uuidSchema()]),
            "signals": signalsSchema,
        ], required: ["text", "confidence", "citations", "signals"])
        return orderedExactObjectSchema([
            "results": .object(["type": .string("array"), "items": compactMemorySchema()]),
            "answer": answerSchema,
        ], required: ["results"])
    }

    private static func recallDataSchema() -> JSONValue {
        lensDataSchema(.lensPartialCue)
    }

    private static func transcriptRecallDataSchema() -> JSONValue {
        let match = orderedExactObjectSchema([
            "memory_id": uuidSchema(), "room": stringSchema(), "excerpt": stringSchema(),
            "score": numberSchema(), "fetch": fetchSchema(),
        ], required: ["memory_id", "room", "excerpt", "score", "fetch"])
        let evidence = orderedExactObjectSchema([
            "status": enumSchema(["applied", "unavailable"]), "policy_version": stringSchema(),
            "fresh_head_candidates": nonnegativeIntegerSchema(), "scored_head_candidates": nonnegativeIntegerSchema(),
            "freshness_verified": booleanSchema(), "reason": stringSchema(), "encoder_model_id": stringSchema(),
            "encoder_model_version": stringSchema(), "query_dimension": positiveIntegerSchema(),
            "classifier_profile": stringSchema(), "classifier_model_revision": stringSchema(),
            "pool": positiveIntegerSchema(), "head": positiveIntegerSchema(), "spans": positiveIntegerSchema(),
            "rrf_k": positiveIntegerSchema(), "serving_generation": nonnegativeIntegerSchema(),
        ], required: ["status", "policy_version", "fresh_head_candidates", "scored_head_candidates", "freshness_verified"])
        return orderedExactObjectSchema([
            "matches": .object(["type": .string("array"), "items": match]), "strict_rerank": evidence,
        ], required: ["matches", "strict_rerank"])
    }

    private static func dreamDataSchema() -> JSONValue {
        orderedExactObjectSchema([
            "candidatesConsidered": nonnegativeIntegerSchema(), "proposalsEmitted": stringArraySchema(),
            "suppressedDuplicates": nonnegativeIntegerSchema(), "belowThreshold": nonnegativeIntegerSchema(),
            "contradictionsProposed": nonnegativeIntegerSchema(), "contradictionCandidatesBorderline": nonnegativeIntegerSchema(),
            "subjectsBackfilled": nonnegativeIntegerSchema(), "associationsWritten": nonnegativeIntegerSchema(),
            "associationsNonUniqueProbes": nonnegativeIntegerSchema(),
        ], required: ["candidatesConsidered", "proposalsEmitted", "suppressedDuplicates", "belowThreshold", "contradictionsProposed", "contradictionCandidatesBorderline"])
    }

    private static func migrationRunDataSchema() -> JSONValue {
        let report = orderedExactObjectSchema([
            "branch_id": uuidSchema(), "query_count": nonnegativeIntegerSchema(), "recall_overlap": numberSchema(),
            "recall_precision": numberSchema(), "mean_reciprocal_rank": numberSchema(),
            "not_found_in_branch": stringArraySchema(), "new_in_branch": stringArraySchema(), "evaluated_at": dateSchema(),
        ], required: ["branch_id", "query_count", "recall_overlap", "recall_precision", "mean_reciprocal_rank", "not_found_in_branch", "new_in_branch", "evaluated_at"])
        let ranking = orderedExactObjectSchema([
            "branch_id": uuidSchema(), "plan_name": stringSchema(), "combined_score": numberSchema(),
            "recall_overlap": numberSchema(), "mean_reciprocal_rank": numberSchema(),
        ], required: ["branch_id", "plan_name", "combined_score", "recall_overlap", "mean_reciprocal_rank"])
        let disqualified = orderedExactObjectSchema([
            "branch_id": uuidSchema(), "plan_name": stringSchema(), "lost_concepts": stringArraySchema(),
        ], required: ["branch_id", "plan_name", "lost_concepts"])
        return orderedExactObjectSchema([
            "reports": .object(["type": .string("array"), "items": report]), "winner_branch_id": uuidSchema(),
            "winner_plan_name": stringSchema(), "rankings": .object(["type": .string("array"), "items": ranking]),
            "disqualified": .object(["type": .string("array"), "items": disqualified]),
        ], required: ["reports", "rankings", "disqualified"])
    }

    private static func migrationConfirmDataSchema() -> JSONValue {
        let outcome = orderedExactObjectSchema([
            "branch_id": uuidSchema(), "status": enumSchema(["discarded", "already_discarded", "winner_skipped", "unknown", "failed"]),
        ], required: ["branch_id", "status"])
        return orderedExactObjectSchema([
            "status": .object(["const": .string("promoted")]), "promoted_branch_id": uuidSchema(),
            "discarded_branch_ids": uuidArraySchema(), "discard_outcomes": .object(["type": .string("array"), "items": outcome]),
        ], required: ["status", "promoted_branch_id", "discarded_branch_ids", "discard_outcomes"])
    }

    private static func federatedRecallDataSchema() -> JSONValue {
        orderedExactObjectSchema([
            "source_estate_id": uuidSchema(), "requester_estate_id": uuidSchema(), "grant_id": uuidSchema(),
            "results": .object(["type": .string("array"), "items": compactMemorySchema()]),
        ], required: ["source_estate_id", "requester_estate_id", "grant_id", "results"])
    }

    private static func mutationDataSchema() -> JSONValue {
        orderedExactObjectSchema(["memory_id": uuidSchema(), "mutation": stringSchema()], required: ["memory_id", "mutation"])
    }
    private static func idReceiptDataSchema() -> JSONValue { orderedExactObjectSchema(["memory_id": uuidSchema()], required: ["memory_id"]) }
    private static func eraseMemoryDataSchema() -> JSONValue { orderedExactObjectSchema(["memory_id": uuidSchema(), "refused_sibling_memory_ids": uuidArraySchema()], required: ["memory_id", "refused_sibling_memory_ids"]) }
    private static func confirmMemoryDataSchema() -> JSONValue { orderedExactObjectSchema(["memory_id": uuidSchema(), "mutation": .object(["const": .string("confirm")])], required: ["memory_id", "mutation"]) }
    private static func moveMemoryDataSchema() -> JSONValue { orderedExactObjectSchema(["memory_id": uuidSchema(), "placement": placementSchema()], required: ["memory_id", "placement"]) }
    private static func tunnelReceiptSchema() -> JSONValue { orderedExactObjectSchema(["tunnel_id": uuidSchema(), "from_id": uuidSchema(), "to_id": uuidSchema(), "kind": stringSchema(), "lifecycle": enumSchema(["active", "proposed", "superseded", "withdrawn"])], required: ["tunnel_id", "kind", "lifecycle"]) }
    private static func reviewTunnelDataSchema() -> JSONValue {
        .object(["oneOf": .array([
            orderedExactObjectSchema(["tunnel_id": uuidSchema(), "new_endorser": booleanSchema(), "distinct_endorsers": nonnegativeIntegerSchema(), "contested": booleanSchema()], required: ["tunnel_id", "new_endorser", "distinct_endorsers", "contested"]),
            orderedExactObjectSchema(["tunnel_id": uuidSchema(), "withdrawn": booleanSchema(), "contested": booleanSchema()], required: ["tunnel_id", "withdrawn", "contested"]),
        ])])
    }

    private static func recallProperties(
        pool: Bool = false,
        extras: [String: JSONValue] = [:]
    ) -> [String: JSONValue] {
        var properties: [String: JSONValue] = [
            "query": stringSchema(), "limit": positiveIntegerSchema(),
            "filter": stringSchema(), "wing": stringSchema(), "estate_id": uuidSchema(),
        ]
        if pool {
            properties["pool"] = .object([
                "type": .string("integer"), "minimum": .integer(1), "maximum": .integer(500),
            ])
        }
        properties.merge(extras) { _, replacement in replacement }
        return properties
    }

    private static func drainEntrySchema() -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "name": stringSchema(),
                "state": enumSchema(["draining", "idle"]),
                "pending": .object(["type": .string("integer"), "minimum": .integer(0)]),
            ]),
            "required": .array([.string("name"), .string("state"), .string("pending")]),
            "additionalProperties": .bool(false),
        ])
    }

    private static func estatePingDataSchema() -> JSONValue {
        exactObjectSchema([
            "estate_id": uuidSchema(),
            "estate_name": stringSchema(),
            "state": .object(["const": .string("mounted")]),
            "build_serial": stringSchema(),
        ])
    }

    private static func estateStatusDataSchema() -> JSONValue {
        exactObjectSchema([
            "estate_id": uuidSchema(),
            "estate_name": stringSchema(),
            "memory_count": .object(["type": .string("integer"), "minimum": .integer(0)]),
            "fact_count": .object(["type": .string("integer"), "minimum": .integer(0)]),
            "drains": .object(["type": .string("array"), "items": drainEntrySchema()]),
            "fdc_recalculation": enumSchema(["current", "missing", "stale"]),
        ])
    }

    private static func estateMapDataSchema() -> JSONValue {
        let room = exactObjectSchema([
            "name": stringSchema(),
            "memory_count": .object(["type": .string("integer"), "minimum": .integer(0)]),
        ])
        let wing = exactObjectSchema([
            "name": stringSchema(),
            "rooms": .object(["type": .string("array"), "items": room]),
        ])
        return exactObjectSchema([
            "estate_id": uuidSchema(),
            "wings": .object(["type": .string("array"), "items": wing]),
        ])
    }

    private static func drainStatusDataSchema() -> JSONValue {
        exactObjectSchema([
            "drains": .object(["type": .string("array"), "items": drainEntrySchema()]),
        ])
    }

    private static func rebuildStatusDataSchema() -> JSONValue {
        exactObjectSchema([
            "state": enumSchema(["running", "idle"]),
        ])
    }

    private static func timingReportDataSchema() -> JSONValue {
        exactObjectSchema([
            "since_ms": .object(["const": .integer(0)]),
            "watermark_ms": .object(["type": .string("integer")]),
            "truncated": booleanSchema(),
        ])
    }

    private static func reindexDataSchema() -> JSONValue {
        exactObjectSchema(["state": enumSchema(["running", "already_running"])])
    }

    private static func palaceImportDataSchema() -> JSONValue {
        let count = nonnegativeIntegerSchema()
        return orderedExactObjectSchema([
            "drawers_written": count,
            "drawers_updated": count,
            "drawers_skipped_unchanged": count,
            "drawers_skipped_tombstoned": count,
            "drawers_skipped_partial_write": count,
            "tunnels_created": count,
            "items_skipped": count,
            "fdc_classified": count,
            "fdc_unclassified": count,
            "fields_dropped": .object([
                "type": .string("object"),
                "additionalProperties": count,
            ]),
            "enqueued_for_encode": count,
        ], required: [
            "drawers_written", "drawers_updated", "drawers_skipped_unchanged",
            "drawers_skipped_tombstoned", "drawers_skipped_partial_write", "tunnels_created",
            "items_skipped", "fdc_classified", "fdc_unclassified", "fields_dropped",
            "enqueued_for_encode",
        ])
    }

    private static func jsonImportDataSchema() -> JSONValue {
        let count = nonnegativeIntegerSchema()
        return orderedExactObjectSchema([
            "seed_name": stringSchema(),
            "drawers_written": count,
            "facts_written": count,
            "tunnels_created": count,
            "enqueued_for_encode": count,
            "subjects_provided": count,
            "subjects_debt": count,
            "seed_sha256": .object([
                "type": .string("string"),
                "pattern": .string("^[0-9a-f]{64}$"),
            ]),
            "id_map": .object([
                "type": .string("object"),
                "additionalProperties": uuidSchema(),
            ]),
        ], required: [
            "seed_name", "drawers_written", "facts_written", "tunnels_created",
            "enqueued_for_encode", "subjects_provided", "subjects_debt", "seed_sha256",
        ])
    }

    private static func reclassifyFDCDataSchema() -> JSONValue {
        // 18 properties per contract §3. 14 are always required; 4 are optional
        // (estate_recalced_data_version_before/after may be absent) so declared
        // but not in the required list. Uses orderedExactObjectSchema so the
        // optional keys can appear without being required.
        let count = nonnegativeIntegerSchema()
        let changeEntry = orderedExactObjectSchema([
            "id": nonEmptyStringSchema(),
            "old_code": nonEmptyStringSchema(),
            "new_code": nonEmptyStringSchema(),
            "old_qid": stringSchema(),
            "new_qid": stringSchema(),
        ], required: ["id", "old_code", "new_code"])
        return orderedExactObjectSchema([
            "applied": booleanSchema(),
            "mode": enumSchema(["suspectOnly", "all"]),
            "estate_id": uuidSchema(),
            "fdc_data_version": nonEmptyStringSchema(),
            "fdc_recalculation_version": nonEmptyStringSchema(),
            "scanned": count,
            "unchanged": count,
            "empty_content": count,
            "candidates": count,
            "updated": count,
            "would_update": count,
            "unclassified_after": count,
            "skipped_non_candidate_changes": count,
            "floor_stamp": stringSchema(),
            "estate_recalced_data_version_before": stringSchema(),
            "estate_recalced_data_version_after": stringSchema(),
            "changes": .object(["type": .string("array"), "items": changeEntry]),
            "changes_omitted": count,
        ], required: [
            "applied", "mode", "estate_id", "fdc_data_version",
            "fdc_recalculation_version", "scanned", "unchanged", "empty_content",
            "candidates", "updated", "would_update", "unclassified_after",
            "skipped_non_candidate_changes", "floor_stamp", "changes", "changes_omitted",
        ])
    }

    private static func fileDatasetDataSchema() -> JSONValue {
        let count = nonnegativeIntegerSchema()
        return orderedExactObjectSchema([
            "dataset_id": uuidSchema(), "handle_memory_id": uuidSchema(),
            "name": stringSchema(), "location": stringSchema(), "wing": stringSchema(),
            "columns": count, "rows": count, "source": stringSchema(),
            "sensitivity": enumSchema(["normal", "elevated", "restricted", "secret"]),
            "signatures": stringSchema(),
        ], required: [
            "dataset_id", "handle_memory_id", "name", "location", "columns", "rows",
            "source", "sensitivity", "signatures",
        ])
    }

    private static func datasetQueryDataSchema() -> JSONValue {
        let scalar = JSONValue.object([
            "type": .array([.string("string"), .string("integer"), .string("number"), .string("boolean"), .string("null")]),
        ])
        let row = orderedExactObjectSchema([:], required: [])
        guard case .object(var rowMembers) = row else { return row }
        rowMembers["additionalProperties"] = scalar
        return orderedExactObjectSchema([
            "dataset_id": uuidSchema(), "handle_memory_id": uuidSchema(),
            "state": stringSchema(),
            "sensitivity": enumSchema(["normal", "elevated", "restricted", "secret"]),
            "rows_returned": nonnegativeIntegerSchema(),
            "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(1000)]),
            "rows": .object(["type": .string("array"), "items": .object(rowMembers)]),
            "columns": .object(["type": .string("array"), "items": stringSchema()]),
            "handle_row_count": nonnegativeIntegerSchema(),
        ], required: [
            "dataset_id", "handle_memory_id", "state", "sensitivity", "rows_returned",
            "limit", "rows",
        ])
    }

    private static func datasetStatsDataSchema() -> JSONValue {
        let scalar = JSONValue.object([
            "type": .array([.string("string"), .string("integer"), .string("number"), .string("boolean"), .string("null")]),
        ])
        let stat = orderedExactObjectSchema([
            "count": nonnegativeIntegerSchema(), "distinct_count": nonnegativeIntegerSchema(),
            "null_count": nonnegativeIntegerSchema(), "min": scalar, "max": scalar,
        ], required: ["count", "distinct_count", "null_count", "min", "max"])
        return orderedExactObjectSchema([
            "dataset_id": uuidSchema(), "handle_memory_id": uuidSchema(),
            "stats": .object([
                "type": .string("object"), "properties": .object([:]),
                "required": .array([]), "additionalProperties": stat,
            ]),
        ], required: ["dataset_id", "handle_memory_id", "stats"])
    }

    private static func datasetPredicateDefinitions() -> JSONValue {
        let column = JSONValue.object(["type": .string("string"), "minLength": .integer(1)])
        let scalar = JSONValue.object(["type": .array([.string("string"), .string("integer"), .string("number")])])
        let leaf = orderedExactObjectSchema([
            "col": column, "op": enumSchema(["eq", "neq", "lt", "lte", "gt", "gte"]), "val": scalar,
        ], required: ["col", "op", "val"])
        let booleanLeaf = orderedExactObjectSchema([
            "col": column, "op": enumSchema(["eq", "neq"]), "val": booleanSchema(),
        ], required: ["col", "op", "val"])
        let nullLeaf = orderedExactObjectSchema([
            "col": column, "op": enumSchema(["is_null", "is_not_null"]),
        ], required: ["col", "op"])
        var definitions: [String: JSONValue] = [:]
        for depth in stride(from: 8, through: 1, by: -1) {
            var variants = [leaf, booleanLeaf, nullLeaf]
            if depth < 8 {
                let childName = depth == 1 ? "datasetPredicate2" : "datasetPredicate\(depth + 1)"
                let child = JSONValue.object(["$ref": .string("#/$defs/\(childName)")])
                variants.append(orderedExactObjectSchema([
                    "and": .object([
                        "type": .string("array"), "items": child,
                        "minItems": .integer(1), "maxItems": .integer(128),
                    ]),
                ], required: ["and"]))
                variants.append(orderedExactObjectSchema([
                    "or": .object([
                        "type": .string("array"), "items": child,
                        "minItems": .integer(1), "maxItems": .integer(128),
                    ]),
                ], required: ["or"]))
            }
            let name = depth == 1 ? "datasetPredicate" : "datasetPredicate\(depth)"
            definitions[name] = .object(["oneOf": .array(variants)])
        }
        return .object(definitions)
    }

    private static func datasetOrderSchema() -> JSONValue {
        orderedExactObjectSchema([
            "col": .object(["type": .string("string"), "minLength": .integer(1)]),
            "dir": enumSchema(["asc", "desc"]),
        ], required: ["col"])
    }

    private static func vaultLaunchDataSchema() -> JSONValue {
        orderedExactObjectSchema([
            "job_id": uuidSchema(), "kind": enumSchema(["export", "import"]), "vault_path": stringSchema(),
            "status": .object(["const": .string("running")]), "note_count": nonnegativeIntegerSchema(), "scope": stringSchema(),
        ], required: ["job_id", "kind", "vault_path", "status"])
    }

    private static func vaultJobDataSchema() -> JSONValue {
        let progress = orderedExactObjectSchema(["processed": nonnegativeIntegerSchema(), "total": nonnegativeIntegerSchema()], required: ["processed", "total"])
        let properties: [String: JSONValue] = [
            "job_id": uuidSchema(), "kind": enumSchema(["export", "import"]), "vault_path": stringSchema(),
            "elapsed_ms": nonnegativeIntegerSchema(), "status": enumSchema(["running", "complete", "failed"]),
            "progress": progress, "drawers_written": nonnegativeIntegerSchema(), "drawers_updated": nonnegativeIntegerSchema(),
            "items_skipped": nonnegativeIntegerSchema(), "tunnels_created": nonnegativeIntegerSchema(),
            "fdc_classified": nonnegativeIntegerSchema(), "fdc_unclassified": nonnegativeIntegerSchema(),
            "drawers_skipped_unchanged": nonnegativeIntegerSchema(), "drawers_skipped_tombstoned": nonnegativeIntegerSchema(),
            "note_count": nonnegativeIntegerSchema(), "exported_at": dateSchema(), "error": stringSchema(),
        ]
        return orderedExactObjectSchema(properties, required: ["job_id", "kind", "vault_path", "elapsed_ms", "status"])
    }

    private static func vaultStatusDataSchema() -> JSONValue {
        orderedExactObjectSchema([
            "manifest_present": booleanSchema(),
            "path": stringSchema(),
            "note_count": nonnegativeIntegerSchema(),
            "last_export": dateSchema(),
        ], required: ["manifest_present", "path"])
    }

    private static func vaultReconcileDataSchema() -> JSONValue {
        let count = nonnegativeIntegerSchema()
        let candidate = orderedExactObjectSchema([
            "stable_source_key": stringSchema(),
            "vault_path": stringSchema(),
            "sha256": stringSchema(),
        ], required: ["stable_source_key", "vault_path", "sha256"])
        let importReport = orderedExactObjectSchema([
            "drawers_written": count,
            "drawers_updated": count,
            "items_skipped": count,
            "tunnels_created": count,
            "fdc_classified": count,
            "fdc_unclassified": count,
            "drawers_skipped_unchanged": count,
            "drawers_skipped_tombstoned": count,
        ], required: [
            "drawers_written", "drawers_updated", "items_skipped", "tunnels_created",
            "fdc_classified", "fdc_unclassified", "drawers_skipped_unchanged",
            "drawers_skipped_tombstoned",
        ])
        return orderedExactObjectSchema([
            "added": stringArraySchema(),
            "modified": stringArraySchema(),
            "deleted": stringArraySchema(),
            "candidates": .object(["type": .string("array"), "items": candidate]),
            "missing": stringArraySchema(),
            "import_set_count": count,
            "candidate_count": count,
            "missing_count": count,
            "applied": booleanSchema(),
            "import_report": importReport,
        ], required: [
            "added", "modified", "deleted", "missing", "import_set_count",
            "candidate_count", "missing_count", "applied",
        ])
    }

    private static func exactObjectSchema(_ properties: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(properties.keys.sorted().map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static func orderedExactObjectSchema(
        _ properties: [String: JSONValue], required: [String]
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static func stringSchema() -> JSONValue { .object(["type": .string("string")]) }
    private static func numberSchema() -> JSONValue { .object(["type": .string("number")]) }
    private static func integerSchema() -> JSONValue { .object(["type": .string("integer")]) }
    private static func nonnegativeIntegerSchema() -> JSONValue {
        .object(["type": .string("integer"), "minimum": .integer(0)])
    }
    private static func positiveIntegerSchema() -> JSONValue {
        .object(["type": .string("integer"), "minimum": .integer(1)])
    }
    private static func booleanSchema() -> JSONValue { .object(["type": .string("boolean")]) }
    private static func nonEmptyStringSchema() -> JSONValue {
        .object(["type": .string("string"), "minLength": .integer(1)])
    }
    private static func arraySchema() -> JSONValue { .object(["type": .string("array")]) }
    private static func objectSchema() -> JSONValue { .object(["type": .string("object")]) }
    private static func stringArraySchema() -> JSONValue {
        .object(["type": .string("array"), "items": stringSchema()])
    }
    private static func uuidArraySchema() -> JSONValue {
        .object(["type": .string("array"), "items": uuidSchema()])
    }
    private static func uuidSchema() -> JSONValue { .object(["type": .string("string"), "format": .string("uuid")]) }
    private static func dateSchema() -> JSONValue { .object(["type": .string("string"), "format": .string("date-time")]) }
    private static func enumSchema(_ values: [String]) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
    }
}
