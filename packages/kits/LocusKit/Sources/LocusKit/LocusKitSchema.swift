// LocusKitSchema.swift
//
// The LocusKit storage schema, declared in pure PersistenceKit
// primitives. This replaces the hand-rolled CREATE TABLE / CREATE
// INDEX / ALTER TABLE / CREATE TRIGGER strings that DrawerStore
// previously issued against the raw sqlite3 C API.
//
// Design notes for the v1 declaration:
//
//   - The schema declares at version 1 with every column present.
//     There is no incremental ALTER/backfill history: the prior
//     LOCI_V035_* migration ladder was development-time scaffolding
//     for a store that never shipped, so it is collapsed into the
//     v1 CREATE. (The five migration tests that exercised that
//     ladder were removed alongside this file.)
//
//   - The audit log lives in PersistenceKit, not as a LocusKit
//     table. Row history is the sealed-event sequence in
//     `audit_log`; LocusKit-tier reads fold it via
//     `AuditLogFold.projectStateAt` (cookbook § 5.3). The earlier
//     `bitmap_audit` and `provenance_audit` tables were retired in
//     the F13 audit-log migration.
//
//   - The bit-range functional indices (state-cluster on the low
//     nibble, provenance source/confirmation field extracts, the
//     operational capture-channel nibble) are declared as
//     `generatedColumns` with structured GeneratedExpression bit
//     algebra, then indexed by ordinary IndexDeclaration. This
//     replaces "CREATE INDEX ... ON drawers (provenance & 0xF)" and
//     its siblings, which were the one place LocusKit reached past
//     the storage abstraction into backend SQL text. No
//     SchemaOperation.custom anywhere.
//
//   - Reserve-space discipline (fleet-wide). The three Int64 bitmap
//     columns carry documented bit-range headroom; the reservation
//     map below records which ranges are assigned and which are free,
//     so a future flag is a bit that was always allocated rather than
//     a migration. Each persistent entity table also carries one
//     nullable `.json` extension column to absorb unforeseeable typed
//     attributes without a schema change. No speculative reserved
//     columns: the json column is the single width-independent
//     container for the unknown-future case. This `ext` slot is the
//     governing convention recorded in nullable entity ext slots (ext forward-compat
//     slot); 1.0 writes NULL and never reads it. The `keys` table
//     gained its `ext` column in schema v2, completing the
//     convention across every persistent LocusKit entity table.
//
// Bitmap reservation map (low bit = 0). Ranges marked FREE are
// documented headroom; consuming one is a value change, not a
// migration.
//
//   drawers.adjectiveBitmap (Adjectives.swift)
//     bits 0-3   state cluster (State raw 0..15)        ASSIGNED
//     bits 4-6   sensitivity axis                       ASSIGNED
//     bits 7-9   exportability axis                     ASSIGNED
//     bits 10-11 trust axis                             ASSIGNED
//     bits 12-63 FREE (52 bits headroom)
//
//   drawers.operationalBitmap (DrawerOperational.swift)
//     bits 0-3   capture channel                        ASSIGNED
//     bits 4-7   content kind                           ASSIGNED
//     bits 8-15  feature flags                          ASSIGNED
//     bits 16-19 FREE (4 bits headroom)
//     bit  20    is_vague (Wave-2 consolidation)        ASSIGNED
//     bit  21    represented_by_vague (Wave-2)          ASSIGNED
//     bits 22-23 vague_level 2-bit sub-field (Wave-2)   ASSIGNED
//     bits 24-26 isAnomalous etc.                       ASSIGNED
//     bit  27    spanIndexed (Encoder Rerank Program)   ASSIGNED
//     bits 28-30 FREE (3 bits headroom)
//     bits 31-63 FREE (33 bits headroom)
//
//   drawers.provenance
//     bits 0-3   source type                            ASSIGNED
//     bits 4-6   confirmation                           ASSIGNED
//     bits 7-63  FREE (57 bits headroom)
//
// The same headroom convention applies to the tunnel, kg_fact, and
// diary bitmap columns; see each table's section comment.

import Foundation
import SubstrateML
import PersistenceKit

public enum LocusKitSchema {

    /// The kit identifier recorded in PersistenceKit's migrations table.
    public static let kitID = "LocusKit"

    /// Current schema version.
    ///
    /// v20 (Distilled Fact Extraction, 2026-09-08). Delta from v19:
    /// `+ fact_extractor_models`, source-grounding and extractor-provenance
    /// columns on `kg_facts`, and the rebuildable `searchProjection` field.
    /// Drawer bit 28 records extraction completion for the active recipe.
    ///
    /// v19 (Encoder Rerank Program, 2026-09-05). Delta from v18:
    /// `+ encoder_models` (the span-encoder registry, one row per shipped
    /// model, exactly one `is_active = 1`), `+ drawers.ssc_facts` (the
    /// grammar-v1 fact anchors as a text column, NULL until the enrichment
    /// stage writes it), `+ operationalBitmap bit 27 = spanIndexed`;
    /// `− adornments`, `− adornment_minters`, `− drawers.adornment`,
    /// `− drawers.distilled`, `− distilled_pipeline_version`,
    /// `− distilled_token_count`, `− distilled_at`,
    /// `− distilled_source_digest`. `subject`, `subject_pipeline_version`
    /// and `subject_at` stay.
    ///
    /// Migration policy: TWO ladder entries — v10 → v19 and v19 → v20. CE
    /// 1.0.35 and 1.0.37 ship schema 10 (a supported version); estates already
    /// at 19 receive only the v19 → v20 hop. Development estates at 11–18
    /// are brought to a supported version by the SQL surgery script, never by
    /// this ladder. The v10 → v19 hop applies only the deltas that survive at
    /// 19 and never creates the v16–v18 adornment or distilled objects.
    /// `mootx01 upgrade` decides with `upgradePath(storedVersion:)` BEFORE
    /// opening the schema, because PersistenceKit's runner stamps the declared
    /// version whenever no ladder entry matches, which would silently mark an
    /// unsupported estate current.
    ///
    /// Version history (versions before the ladder live in the base CREATE):
    /// v2 keys.ext; v3 nodes; v4 parent_node_id replaces wing/room; v5
    /// erasure_ledger; v6 tunnels.order_key; v7 drawers.content_hash and the
    /// snapshot tables; v8 nodes.merkle_root BLOB; v9
    /// drawers.content_fingerprint; v10 associations natural-key UNIQUE
    /// (dedup then index); v11 container_fingerprints.operationalAND (AND
    /// identity default -1, recomputed at open); v12 subject trio; v13
    /// kg_facts identity trio; v14 idx_drawers_filedAt; v15 recall_trace
    /// door/composition/laneRanks; v16–v18 adornment and distilled storage,
    /// retired at v19.
    public static let version = 20

    /// The lowest stored schema version `mootx01 upgrade` brings to
    /// `version` in one hop: the version CE 1.0.35 and 1.0.37 shipped.
    public static let supportedUpgradeFloor = 10

    /// What an upgrade does with an estate whose LocusKit ledger row carries
    /// `storedVersion`. Read the ledger raw and call this BEFORE
    /// `Storage.open(schema:)`: the runner stamps `version` whenever no
    /// ladder entry matches, so an unsupported estate opened blind would be
    /// marked current with none of the v20 objects in place.
    public static func upgradePath(storedVersion: Int) -> SchemaUpgradePath {
        switch storedVersion {
        case 0: return .fresh
        case supportedUpgradeFloor, 19: return .upgrade(from: storedVersion)
        case version: return .current
        default: return .unsupported(found: storedVersion)
        }
    }

    /// The complete LocusKit schema as a PersistenceKit declaration.
    /// `Storage.open(schema:)` creates every table, generated column,
    /// and index from this single value. No trigger declarations are
    /// present; trigger-like behaviour (e.g. audit log rows) is
    /// implemented in Swift at the verb layer.
    public static var schema: SchemaDeclaration {
        SchemaDeclaration(
            kitID: kitID,
            version: version,
            tables: [
                drawersTable,
                tunnelsTable,
                diaryTable,
                manifestTable,
                kgFactsTable,
                proposalsTable,
                associationsTable,
                learnedReferencesTable,
                sourceCatalogTable,
                nodeBundlesTable,
                containerFingerprintsTable,
                recallTraceTable,
                keysTable,
                nodesTable,
                ErasureLedgerSchema.ledgerTable,
                SnapshotSchema.registryTable,
                SnapshotSchema.attestationsTable,
                // The span-encoder registry (Encoder Rerank Program, v19).
                encoderModelsTable,
                // Distilled Fact Extraction provider/model registry (v20).
                factExtractorModelsTable,
            ],
            indices: indices,
            migrations: [
                // TWO hops: v10 → v19 and v19 → v20. A v10 estate (CE 1.0.35/
                // 1.0.37) traverses both; a v19 estate receives only the second.
                // Every operation is idempotent — addColumn skips a present
                // column, the DDL is CREATE ... IF NOT EXISTS, addIndex is IF
                // NOT EXISTS — so a fresh estate, which the runner creates at
                // the current layout before replaying the ladder, is unchanged
                // by either hop. Populated estates exist at 10 or 19; nothing
                // in between is supported here (see `upgradePath(storedVersion:)`).
                Migration(fromVersion: 10, toVersion: 19, operations: [
                    // v11: AND-aggregate on container_fingerprints. Default -1
                    // (AND identity, all bits set) so an empty container never
                    // falsely satisfies an AND-check before the first
                    // rebuildAll; the table is derived and recomputed at open.
                    .addColumn(table: "container_fingerprints",
                               column: .bitmap("operationalAND", default: Int64(-1))),
                    // v12: the subject trio. All nullable, no backfill — NULL
                    // `subject` is the backfill-eligibility predicate, so
                    // pre-v12 rows are subject debt, not a data migration.
                    .addColumn(table: "drawers", column: .text("subject", nullable: true)),
                    .addColumn(table: "drawers", column: .text("subject_pipeline_version", nullable: true)),
                    .addColumn(table: "drawers", column: .timestamp("subject_at", nullable: true)),
                    // v13: the kg_facts identity trio, NOT NULL DEFAULT '' so a
                    // locally-filed, unanchored fact writes the shape it always
                    // did. The DATA move (pre-KH sourceDrawerID values into
                    // these columns) is KGFactIdentityBackfill, run only by
                    // `mootx01 upgrade`, never a schema operation.
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "addedBy", type: .text, nullable: false, defaultValue: .text(""))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "foreignSourceKey", type: .text, nullable: false, defaultValue: .text(""))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "foreignRecordID", type: .text, nullable: false, defaultValue: .text(""))),
                    // v14: idx_drawers_filedAt — the Director recall path sorts
                    // by `filedAt DESC LIMIT 256`; without the index SQLite
                    // sorts every row before truncating.
                    .addIndex(IndexDeclaration(
                        name: "idx_drawers_filedAt",
                        table: "drawers",
                        columns: ["filedAt"])),
                    // v15: recall_trace lane-attribution trio. Nullable TEXT,
                    // no backfill — NULL is the correct value for rows written
                    // before attribution existed; no query text is stored
                    // (privacy ruling 2026-08-20).
                    .addColumn(table: "recall_trace", column: .text("door", nullable: true)),
                    .addColumn(table: "recall_trace", column: .text("composition", nullable: true)),
                    .addColumn(table: "recall_trace", column: .text("laneRanks", nullable: true)),
                    // v19: the span-encoder registry. CREATE TABLE IF NOT EXISTS
                    // through .custom (the same idiom the v17 tables used) so
                    // the hop is a no-op when the declared-table pass has
                    // already created it; sqlite and postgresql strings are
                    // identical. Mirrors `encoderModelsTable`.
                    .custom(sqlite: encoderModelsDDL, postgresql: encoderModelsDDL),
                    // v19: ssc_facts — NULL on every existing row, which is the
                    // enrichment stage's "needs facts" predicate; no backfill.
                    .addColumn(table: "drawers", column: .text("ssc_facts", nullable: true)),
                ]),
                Migration(fromVersion: 19, toVersion: 20, operations: [
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "evidenceQuote", type: .text, nullable: false, defaultValue: .text(""))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "evidenceStart", type: .int, nullable: false, defaultValue: .int(-1))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "evidenceEnd", type: .int, nullable: false, defaultValue: .int(-1))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "evidenceStartUTF8Byte", type: .int, nullable: false, defaultValue: .int(-1))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "evidenceEndUTF8Byte", type: .int, nullable: false, defaultValue: .int(-1))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "sourceDigest", type: .text, nullable: false, defaultValue: .text(""))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "extractorProviderID", type: .text, nullable: false, defaultValue: .text(""))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "extractorModelID", type: .text, nullable: false, defaultValue: .text(""))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "extractorModelVersion", type: .text, nullable: false, defaultValue: .text(""))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "extractionSchemaVersion", type: .text, nullable: false, defaultValue: .text(""))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "searchProjection", type: .text, nullable: false, defaultValue: .text(""))),
                    .addColumn(table: "kg_facts", column: ColumnDeclaration(
                        name: "searchProjectionVersion", type: .text, nullable: false, defaultValue: .text(""))),
                    .custom(sqlite: factExtractorModelsDDL, postgresql: factExtractorModelsDDL),
                ]),
            ]
        )
    }

    // MARK: - drawers

    /// The drawer table. Primary key `id` is TEXT storing a UUID string.
    /// Current gated write paths (`DrawerStore.requireUuid`) validate that
    /// ids are well-formed UUIDs before any insert; `Drawer`'s initializer
    /// defaults `id` to `UUID().uuidString`.
    ///
    /// Generated columns expose the indexed bit-range field extracts
    /// the retrieval layer dispatches on. They are derived from the
    /// three bitmap columns and indexed below like ordinary columns.
    static let drawersTable = TableDeclaration(
        name: "drawers",
        columns: [
            .text("id"),
            .text("content"),
            // FK to nodes.id (the room node containing this drawer).
            // Replaces the stored wing/room text columns (node-tree integrity NT-L2).
            .text("parent_node_id"),
            .text("sourceFile", nullable: true),
            .int("chunkIndex", nullable: true),
            .text("addedBy"),
            .timestamp("filedAt"),
            // Two-clock ingest (ING-01). filedAt is the ingest instant;
            // eventTime is when the content happened/was authored in the
            // world. Declared nullable so a row written before this
            // column existed (or a raw insert that omits it) does not
            // violate a NOT NULL constraint; drawerFromRow backfills a
            // NULL/absent eventTime to that row's filedAt. This column
            // predates the migration-ladder discipline; columns added
            // from v13 on ship a ladder entry (populated estates exist).
            .timestamp("eventTime", nullable: true),
            .text("embeddingModelID"),
            .timestamp("tombstonedAt", nullable: true),
            .text("removedByBatch", nullable: true),
            .bitmap("provenance"),
            .bitmap("adjectiveBitmap"),
            .bitmap("operationalBitmap"),
            // lineageID defaults to the empty string, which
            // intentionally does not parse as a UUID; drawerFromRow
            // mints a fresh per-row UUID for that case so legacy or
            // unset rows never collide on a single lineage.
            ColumnDeclaration(name: "lineageID", type: .text,
                              nullable: false, defaultValue: .text("")),
            ColumnDeclaration(name: "udcCode", type: .text,
                              nullable: false, defaultValue: .text("")),
            .text("udcFacets", nullable: true),
            .text("wikidataQID", nullable: true),
            .text("wikidataQidsSecondary", nullable: true),
            // Reserve-space: single typed-flexible extension column,
            // present from v1, nullable, empty cost approaching zero.
            // Absorbs unforeseeable per-drawer typed attributes
            // (future axes, experimental fields) with no migration.
            .json("ext", nullable: true),
            // At-rest encryption key identifier (Mission ENC-01;
            // federation disclosure controls Appendix A.1).
            // NULL = plaintext row (mode 1). Non-null references
            // keys.key_id and means the content column is ciphertext under
            // that key. Nullable so plaintext estates write nothing here.
            .text("keyID", nullable: true),
            // Per-row content hash computed by the hash-on-write hook
            // (NT-P2 HashingRowStore). BLOB nullable: NULL for rows
            // written before hash-on-write was wired. The Merkle rollup
            // (NT-L3) reads this column to build room/wing/estate roots.
            .blob("content_hash", nullable: true),
            // The row's Fingerprint256 (32-byte little-endian wire
            // format, see Fingerprint256.wireBytes), computed by
            // DrawerStore at every insert and refreshed at every update
            // that can change a fingerprint input (adjectiveBitmap,
            // operationalBitmap, provenance, udcCode, wikidataQID —
            // see EstateFingerprintFamilies.fingerprint(of:)).
            // `fingerprintsCaptured`/`fingerprintBitSeries` read this
            // column directly instead of recomputing per call. Nullable
            // only so a row can never fail a NOT NULL constraint if a
            // future write path is added without going through
            // DrawerStore's refresh helper; DrawerStore always populates
            // it and treats a NULL/malformed value at read time as a
            // fail-loud LocusKitError, not a silent fallback.
            .blob("content_fingerprint", nullable: true),
            // SSC facts (Encoder Rerank Program §6): the grammar-v1 fact
            // anchors of `content` as inner text without the `(*[` `]*)`
            // delimiters, pairs comma-separated (`kind: hobby, entity:
            // painting, place: brazil`). NULL when the content has no fact
            // anchors, and NULL after every content write — the statement
            // that bumps content_hash clears it — which is the enrichment
            // stage's "needs facts" predicate. Written by
            // `DrawerStore.setSSCFacts(_:for:)`; read into the BM25 document
            // (SSCFacts.lexicalSupplement) and the candidate row. A plain
            // `drawers` column, so it rides the sync manifest unchanged.
            .text("ssc_facts", nullable: true),
            // Subject trio (progressive recall PR-01): the one-sentence
            // AI-facing summary of this drawer's content. The three columns
            // are NULL together or populated together (one atomic UPDATE via
            // DrawerStore.setSubjectRepresentation); every write that
            // touches `content` NULLs all three in the same statement
            // (regeneration trigger + erasure scrub). NULL `subject` is
            // the backfill-eligibility predicate. The subject is RETURNED
            // on recall rows, never indexed or searched (design ruling:
            // ranking math is content-only), so it is excluded from the
            // content digest/revision that feed the index pipeline.
            // `subject_pipeline_version` carries the producer provenance
            // tier ("ai-v1" filing/backfill AI; "minillm-v1" model rider).
            // No token-count column: the subject is length-contracted
            // (~120 chars) at every producer boundary.
            .text("subject", nullable: true),
            .text("subject_pipeline_version", nullable: true),
            .timestamp("subject_at", nullable: true),
        ],
        primaryKey: ["id"],
        generatedColumns: [
            // (adjectiveBitmap & 0x3F), the state field. Indexed for
            // the active-predecessor lookup in the supersession
            // cascade and for state-filtered reads. Cookbook §2.3
            // 6-bit field; the per-cluster predicate is
            // `(state >> 4) & 0x3` over this indexed value.
            GeneratedColumn(
                name: "g_state_cluster",
                type: .int,
                expression: .bitAnd(.column("adjectiveBitmap"), .literal(0x3F))
            ),
            // (provenance & 0xF), the provenance source type.
            GeneratedColumn(
                name: "g_provenance_source",
                type: .int,
                expression: .bitAnd(.column("provenance"), .literal(0xF))
            ),
            // (provenance >> 4) & 0x7, the provenance confirmation.
            GeneratedColumn(
                name: "g_provenance_confirmation",
                type: .int,
                expression: .bitAnd(.shiftRight(.column("provenance"), 4), .literal(0x7))
            ),
            // (operationalBitmap & 0xF), the capture channel.
            GeneratedColumn(
                name: "g_operational_channel",
                type: .int,
                expression: .bitAnd(.column("operationalBitmap"), .literal(0xF))
            )
        ],
        hashable: true
    )

    // MARK: - tunnels
    //
    // Bitmap headroom mirrors the drawer convention: adjectiveBitmap,
    // operationalBitmap, and provenanceBitmap each carry their
    // assigned low ranges with the high bits FREE. kind_id is the
    // typed TunnelKind vocabulary (default 1 = .references).
    static let tunnelsTable = TableDeclaration(
        name: "tunnels",
        columns: [
            .text("id"),
            .text("sourceWing"),
            .text("sourceRoom"),
            .text("sourceDrawerId", nullable: true),
            .text("targetWing"),
            .text("targetRoom"),
            .text("targetDrawerId", nullable: true),
            .text("label"),
            .text("addedBy"),
            .timestamp("filedAt"),
            .timestamp("tombstonedAt", nullable: true),
            .text("removedByBatch", nullable: true),
            ColumnDeclaration(name: "kind_id", type: .int,
                              nullable: false, defaultValue: .int(1)),
            .bitmap("adjectiveBitmap"),
            .bitmap("operationalBitmap"),
            .bitmap("provenanceBitmap"),
            // Fractional-index sibling ordering for .parent tunnels
            // (node-tree integrity, NT-L5). REAL nullable; nil for non-parent kinds.
            .float("order_key", nullable: true),
            .json("ext", nullable: true)
        ],
        primaryKey: ["id"]
    )

    // MARK: - diary
    //
    // operationalBitmap default 0 = eventClass .capture, severity
    // .trace, actorClass .user, batch .standalone,
    // requiresFollowup false. Same headroom convention.
    //
    // reward (REAL nullable): explicit quality signal written at
    // diary-entry time. Present from v1; nil = no explicit reward
    // (daemon falls back to RecallTraceItem.used). Populated by
    // callers that have a quality signal (user rating, model confidence,
    // etc.). See DiaryEntry.reward and NEURONKIT_SPEC § 3.1 step 1a.
    //
    // rewardProvenance (TEXT nullable): human-readable tag for how
    // `reward` was derived (e.g. "user-rating", "model-confidence").
    // Nil when reward is nil.
    static let diaryTable = TableDeclaration(
        name: "diary",
        columns: [
            .text("id"),
            .text("agentName"),
            .text("entry"),
            .text("topic"),
            .text("wing"),
            .text("room"),
            .timestamp("filedAt"),
            .text("embeddingModelID"),
            .timestamp("tombstonedAt", nullable: true),
            .text("removedByBatch", nullable: true),
            .bitmap("operationalBitmap"),
            // Explicit reward channel (NEURONKIT_SPEC § 3.1 step 1a).
            // REAL nullable: 0.0–1.0 quality score or nil.
            .float("reward", nullable: true),
            // Provenance tag for the reward value. TEXT nullable.
            .text("rewardProvenance", nullable: true),
            .json("ext", nullable: true)
        ],
        primaryKey: ["id"]
    )

    // MARK: - manifest

    static let manifestTable = TableDeclaration(
        name: "manifest",
        columns: [
            .text("key"),
            .text("value")
        ],
        primaryKey: ["key"]
    )

    // MARK: - kg_facts
    //
    // KGFact persistence per spec section 4.1. Three Int64 bitmap
    // columns mirror the in-memory value type's adjective /
    // operational / provenance axes, same headroom convention.
    // MARK: - container fingerprints (recall-pruning OR-reductions)

    /// Per-container bitmap aggregates used by two independent pruning
    /// mechanisms (spec § 11.5).
    ///
    /// **OR columns** (`adjectiveOR`, `operationalOR`, `provenanceOR`)
    /// hold the bitwise OR of every active drawer's bitmaps in that
    /// container. The OR is an over-approximation (a sound upper bound):
    /// a capture ORs the new row's bits in incrementally; bit-clearing
    /// mutations leave the row a harmless over-approximation until a
    /// periodic rebuild tightens it. Recall filter ordering (§ 7.9.4
    /// step 1) uses these to prune containers that cannot hold a match.
    ///
    /// **AND column** (`operationalAND`) holds the bitwise AND of every
    /// active drawer's `operationalBitmap`. The AND is an
    /// under-approximation (a sound lower bound): a false-absent bit
    /// merely prevents a prune (safe); a false-present bit would
    /// incorrectly skip a container with eligible work (UNSAFE). The
    /// default is -1 (AND-identity, all bits set) so an empty container
    /// does not falsely satisfy an AND-check. The distillation sweep
    /// uses `(operationalAND & (1<<19)) != 0` to skip rooms whose every
    /// drawer carries bit 19 (`hasCurrentRepresentation`). `rebuildAll`
    /// at estate open recomputes the AND from scratch to raise any stale
    /// under-approximation. Not append-only.
    static let containerFingerprintsTable = TableDeclaration(
        name: "container_fingerprints",
        columns: [
            .text("wing"),
            .text("room"),            // "" for the wing-level roll-up
            .bitmap("adjectiveOR"),
            .bitmap("operationalOR"),
            .bitmap("provenanceOR"),
            .timestamp("updatedAt"),
            // AND-aggregate: under-approximation (lower bound). Default
            // -1 = AND-identity (all bits set) so fresh/empty rows do
            // not falsely suppress skipping. See v11 comment above.
            // Column order matches Rust schema.rs to keep cross-port
            // layout signatures byte-identical (composite fixture gate).
            .bitmap("operationalAND", default: Int64(-1))
        ],
        primaryKey: ["wing", "room"]
    )

    // MARK: - node bundles (bundle-algebra count-vector aggregates)

    /// Per-node count-vector bundles for the bundle algebra
    /// (bundle algebra and erasure,
    /// estate node containment). The node is the
    /// wing/room grouping: a room-level row (room non-empty) bundles
    /// the drawers in that room, and a wing-level row (room == "") is
    /// the merge of its rooms. `bundleKind` is "A" for the active
    /// centroid and "B" for the departed accumulator. `counts` holds
    /// the 256 per-bit counts as little-endian UInt32 (1024 bytes) and
    /// `n` the member count. Not append-only: Bundle A rows are
    /// rewritten on each recompute and Bundle B rows on each departure.
    static let nodeBundlesTable = TableDeclaration(
        name: "node_bundles",
        columns: [
            .text("wing"),
            .text("room"),         // "" for the wing-level roll-up
            .text("bundleKind"),   // "A" active centroid, "B" departed accumulator
            .int("n"),
            .blob("counts"),       // 256 UInt32 little-endian = 1024 bytes
            .timestamp("updatedAt")
        ],
        primaryKey: ["wing", "room", "bundleKind"]
    )

    static let kgFactsTable = TableDeclaration(
        name: "kg_facts",
        columns: [
            .text("id"),
            .text("subject"),
            .text("predicate"),
            .text("object"),
            .text("sourceDrawerID"),
            // Provenance columns that are deliberately NOT sourceDrawerID:
            // the filing host identity, and the foreign palace's own key and
            // record id for imported facts. sourceDrawerID carries a local
            // drawer id or "" and nothing else. All three default to "" so a
            // locally-filed, unanchored fact writes the same shape it always
            // did. The palace re-import dedup signature reads foreignSourceKey.
            .text("addedBy"),
            .text("foreignSourceKey"),
            .text("foreignRecordID"),
            .text("evidenceQuote"),
            ColumnDeclaration(name: "evidenceStart", type: .int, nullable: false, defaultValue: .int(-1)),
            ColumnDeclaration(name: "evidenceEnd", type: .int, nullable: false, defaultValue: .int(-1)),
            ColumnDeclaration(name: "evidenceStartUTF8Byte", type: .int, nullable: false, defaultValue: .int(-1)),
            ColumnDeclaration(name: "evidenceEndUTF8Byte", type: .int, nullable: false, defaultValue: .int(-1)),
            .text("sourceDigest"),
            .text("extractorProviderID"),
            .text("extractorModelID"),
            .text("extractorModelVersion"),
            .text("extractionSchemaVersion"),
            .text("searchProjection"),
            .text("searchProjectionVersion"),
            .bitmap("adjectiveBitmap"),
            .bitmap("operationalBitmap"),
            .bitmap("provenanceBitmap"),
            .timestamp("filedAt"),
            .json("ext", nullable: true)
        ],
        primaryKey: ["id"],
        generatedColumns: [
            // (adjectiveBitmap & 0x3F), the raw 6-bit RowState. Active
            // kgFact recall filters to the RowState Cluster-A set via
            // `g_state_cluster < RowState.activeClusterUpperBoundRaw`
            // (the cluster-B floor, 16) — active/pending/contested/accepted
            // kept, retired B/C states (16+/32+) excluded; the field
            // extract is indexed here as on drawers. Cookbook §2.3 6-bit
            // field. The boundary is sourced from the RowState automaton,
            // never a bare literal — equivalent to RowState Cluster-A for
            // every defined raw.
            GeneratedColumn(
                name: "g_state_cluster",
                type: .int,
                expression: .bitAnd(.column("adjectiveBitmap"), .literal(0x3F))
            )
        ]
    )

    // MARK: - proposals
    //
    // Proposal persistence per mission NOUN-PRO-01 and cookbook §2.4.
    // Three Int64 bitmap columns mirror the in-memory value type's
    // adjective / operational / provenance axes; `candidateState` is a
    // fourth bitmap carrying the proposed adjective set the proposal
    // would apply to its target if accepted (cookbook §10.7
    // candidate_state). The lattice anchor (cookbook §2.7 / I-16) is
    // stored as the same four columns drawers use — udcCode +
    // udcFacets + wikidataQID + wikidataQidsSecondary — with udcCode
    // TEXT NOT NULL DEFAULT ''; `addProposal` rejects an empty anchor
    // before insert. Same headroom convention as kg_facts.
    static let proposalsTable = TableDeclaration(
        name: "proposals",
        columns: [
            .text("id"),
            .text("targetRowID"),
            .text("justification", nullable: true),
            .bitmap("candidateState"),
            .bitmap("adjectiveBitmap"),
            .bitmap("operationalBitmap"),
            .bitmap("provenanceBitmap"),
            ColumnDeclaration(name: "udcCode", type: .text,
                              nullable: false, defaultValue: .text("")),
            .text("udcFacets", nullable: true),
            .text("wikidataQID", nullable: true),
            .text("wikidataQidsSecondary", nullable: true),
            .timestamp("filedAt"),
            .json("ext", nullable: true)
        ],
        primaryKey: ["id"],
        generatedColumns: [
            // (adjectiveBitmap & 0x3F), the state field. Proposals are
            // filtered by lifecycle state — pending while awaiting
            // confirmation vs accepted/rejected/withdrawn afterward —
            // via the per-cluster predicate `(state >> 4) & 0x3`; the
            // field extract is indexed here as on drawers and kg_facts.
            // Cookbook §2.3 6-bit field.
            GeneratedColumn(
                name: "g_state_cluster",
                type: .int,
                expression: .bitAnd(.column("adjectiveBitmap"), .literal(0x3F))
            )
        ]
    )

    // MARK: - associations
    //
    // Association persistence per mission NOUN-ASC-01 and cookbook §2.4.
    // The edge-shaped sibling of `tunnels`: source + target endpoints
    // (wing + room + optional drawer id), three Int64 bitmap columns, and
    // the Rev 1.0 soft-delete reservation. Two differences from `tunnels`:
    // there is no `kind_id` (an association carries no typed-relationship
    // vocabulary — all semantics live in operationalBitmap, cookbook §2.4),
    // and the lattice anchor (cookbook §2.7 / I-16, anchored to the
    // lattice-midpoint of the endpoints) is stored as the same four columns
    // drawers and proposals use — udcCode TEXT NOT NULL DEFAULT '' +
    // udcFacets + wikidataQID + wikidataQidsSecondary; `addAssociation`
    // rejects an empty anchor before insert. Same headroom convention as
    // tunnels. No generated columns — like `tunnels`, the edge endpoints
    // (not a state cluster) are the indexed query paths.
    //
    // v10 (FINDING-3): unique constraint on the natural key
    // (sourceWing, sourceRoom, sourceDrawerId, targetWing, targetRoom,
    // targetDrawerId, label) prevents duplicate edges from accumulating.
    // `addAssociation` is INSERT-OR-IGNORE (swallows duplicateKey from
    // the constraint). SQLite treats NULL sourceDrawerId/targetDrawerId
    // as distinct values in the index, so the constraint is precise
    // for drawer-level associations (always produced by
    // VectorSimilaritySignal) and permissive for wing/room-level
    // associations (NULL drawer IDs, unusual case).
    static let associationsTable = TableDeclaration(
        name: "associations",
        columns: [
            .text("id"),
            .text("sourceWing"),
            .text("sourceRoom"),
            .text("sourceDrawerId", nullable: true),
            .text("targetWing"),
            .text("targetRoom"),
            .text("targetDrawerId", nullable: true),
            .text("label"),
            .text("addedBy"),
            .timestamp("filedAt"),
            .timestamp("tombstonedAt", nullable: true),
            .text("removedByBatch", nullable: true),
            ColumnDeclaration(name: "udcCode", type: .text,
                              nullable: false, defaultValue: .text("")),
            .text("udcFacets", nullable: true),
            .text("wikidataQID", nullable: true),
            .text("wikidataQidsSecondary", nullable: true),
            .bitmap("adjectiveBitmap"),
            .bitmap("operationalBitmap"),
            .bitmap("provenanceBitmap"),
            .json("ext", nullable: true)
        ],
        primaryKey: ["id"],
        uniqueConstraints: [
            // Natural-key uniqueness: one active edge per
            // (source endpoint, target endpoint, label) tuple.
            // Enforced for INSERT-OR-IGNORE semantics in
            // `addAssociation` (FINDING-3).
            ["sourceWing", "sourceRoom", "sourceDrawerId",
             "targetWing", "targetRoom", "targetDrawerId", "label"]
        ]
    )

    // MARK: - learned_references
    //
    // LearnedReference persistence per mission NOUN-LRF-01, arch spec
    // §7.8.2, and cookbook §2.4/§2.7. The substrate the grounding-driven
    // `learn` verb writes to (learnedReference is the only noun accepting
    // learn). Mirrors `associations` structurally — a required lattice
    // anchor stored as the same four columns (udcCode TEXT NOT NULL
    // DEFAULT '' + udcFacets + wikidataQID + wikidataQidsSecondary;
    // `addLearnedReference` rejects an empty anchor before insert), three
    // Int64 bitmap columns, and the Rev 1.0 soft-delete reservation. Two
    // content columns replace the edge endpoints: `sourceCatalogID` (the
    // SourceCatalogEntry reference, stored as an identifier the way
    // kg_facts stores sourceDrawerID) and `handle` (the reference URI).
    // No generated columns — the query paths are id, handle, source, and
    // the lattice anchor, not a state cluster. Same headroom convention.
    // The refresh_policy / drift_severity / mode / source operational
    // axes (cookbook §2.4) live in operationalBitmap, not as columns.
    static let learnedReferencesTable = TableDeclaration(
        name: "learned_references",
        columns: [
            .text("id"),
            .text("sourceCatalogID"),
            .text("handle"),
            .text("addedBy"),
            .timestamp("filedAt"),
            .timestamp("tombstonedAt", nullable: true),
            .text("removedByBatch", nullable: true),
            ColumnDeclaration(name: "udcCode", type: .text,
                              nullable: false, defaultValue: .text("")),
            .text("udcFacets", nullable: true),
            .text("wikidataQID", nullable: true),
            .text("wikidataQidsSecondary", nullable: true),
            .bitmap("adjectiveBitmap"),
            .bitmap("operationalBitmap"),
            .bitmap("provenanceBitmap"),
            .json("ext", nullable: true)
        ],
        primaryKey: ["id"]
    )

    // MARK: - source_catalog
    //
    // SourceCatalogEntry persistence per arch spec §7.8.2. The durable,
    // queryable record of an external source from which references are
    // learned — the `source` slot of the grounding-driven `learn` verb.
    // The learn verb derives every LearnedReference's genuine lattice
    // anchor from the matching catalog entry (never a sentinel), so the
    // anchor lives here as the same four columns every anchored noun uses
    // (udcCode TEXT NOT NULL DEFAULT '' + udcFacets + wikidataQID +
    // wikidataQidsSecondary; addSourceCatalogEntry rejects an empty
    // anchor). `kind` is the SourceKind raw (Int). `handle` is the
    // source's own canonical locator, indexed for the learn verb's
    // source-resolution probe.
    static let sourceCatalogTable = TableDeclaration(
        name: "source_catalog",
        columns: [
            .text("id"),
            .int("kind"),
            .text("handle"),
            .text("addedBy"),
            .timestamp("firstSeen"),
            ColumnDeclaration(name: "udcCode", type: .text,
                              nullable: false, defaultValue: .text("")),
            .text("udcFacets", nullable: true),
            .text("wikidataQID", nullable: true),
            .text("wikidataQidsSecondary", nullable: true),
            .json("ext", nullable: true)
        ],
        primaryKey: ["id"]
    )

    // MARK: - recall_trace
    //
    // RecallTraceItem persistence per NEURONKIT_SPEC §3.1. One row per
    // drawer returned by a recall operation. The `used` flag (bit 0 of
    // operationalBitmap) is flipped to 1 when the reward path consumes
    // the row; Bradley-Terry uses this distinction when computing
    // tournament weights (cookbook §8.12).
    //
    // operationalBitmap reservation:
    //   bit 0   used                         ASSIGNED
    //   bits 1–63  FREE (63 bits headroom)
    //
    // `score` is REAL nullable: the recall may not produce a score for
    // every row (e.g. ordered-by-capture-time queries).
    // `recalledAt` is TEXT ISO8601 (fleet date-storage rule).
    //
    // Lane-attribution trio (v15, W2.5 Track R(a)): `door` names the
    // tool/recipe that issued the recall, `composition` the lane
    // composition active at trace time, `laneRanks` the target's 1-based
    // per-lane rank packed as JSON (RecallTraceItem.packLaneRanks). All
    // nullable TEXT; NULL = written without attribution (pre-v15 rows,
    // plain locus-verb traces). No query text is stored (privacy ruling).
    static let recallTraceTable = TableDeclaration(
        name: "recall_trace",
        columns: [
            .text("id"),
            .text("target"),
            .timestamp("recalledAt"),
            // score: REAL nullable (TypedValue.float). PersistenceKit
            // exposes Double precision via the .float column type.
            .float("score", nullable: true),
            .bitmap("operationalBitmap"),
            .text("door", nullable: true),
            .text("composition", nullable: true),
            .text("laneRanks", nullable: true),
            .json("ext", nullable: true)
        ],
        primaryKey: ["id"]
    )

    // MARK: - keys
    //
    // At-rest encryption key registry (Mission ENC-01;
    // federation disclosure controls Appendix A.1). Maps a
    // stable key identifier to the wrapped key bytes. `wrapped` is intended
    // to hold the data key wrapped by the platform keystore (Secure Enclave
    // / TPM) — the registry must never hold a raw unwrapped key.
    // `created_at` is TEXT ISO8601 per the fleet date-storage rule.
    // drawers.keyID references key_id; a record under an absent key is
    // unreadable, not missing (Appendix A.1).
    //
    // Scope note (ENC-01): this mission declares the registry shape and
    // wires per-row content crypto, but does NOT yet populate this table.
    // The estate key currently lives only in memory
    // (EstateEncryptionConfig.key). Populating `wrapped` requires the
    // hardware-wrapping path (Secure Enclave / TPM), which is a follow-on
    // mission; writing a raw key here would be a regression. Until then the
    // registry is intentionally empty.
    static let keysTable = TableDeclaration(
        name: "keys",
        columns: [
            .text("key_id"),
            .text("algorithm"),     // e.g. "AES-GCM-256"
            .blob("wrapped"),       // key bytes wrapped by platform keystore
            .timestamp("created_at"),
            // Reserve-space forward-compat slot. Nullable
            // `.json`, present from schema v2. Reserves the slot, not a
            // shape: future key-registry metadata (rotation lineage,
            // KMS provider tags) serializes here migration-free. 1.0
            // writes NULL and never reads it.
            .json("ext", nullable: true)
        ],
        primaryKey: ["key_id"]
    )

    // MARK: - nodes

    /// Container nodes for the estate's containment tree. Estate
    /// (depth 0), wing (depth 1), room (depth 2). Drawers reference
    /// their parent room via `parent_node_id` on the drawers table
    /// (NT-L2). The `merkle_root` column stores a 32-byte BLOB
    /// populated by `MerkleRollup`; current capture paths defer the
    /// rollup rather than computing it inline on every write.
    ///
    /// HLC columns (`created_hlc`, `tombstoned_hlc`) are tagged with
    /// ColumnRole so PersistenceKit's as-of filter operates over nodes
    /// identically to drawers.
    static let nodesTable = TableDeclaration(
        name: "nodes",
        columns: [
            .text("id"),
            .text("parent_id", nullable: true),
            .text("display_name"),
            .text("lookup_name"),
            .int("depth"),
            .int("lifecycle"),
            .createdHlc("created_hlc"),
            .tombstonedHlc("tombstoned_hlc"),
            .timestamp("tombstoned_at", nullable: true),
            .blob("merkle_root", nullable: true),
            .timestamp("created_at"),
            .timestamp("updated_at"),
            .json("ext", nullable: true)
        ],
        primaryKey: ["id"]
    )

    // MARK: - indices

    /// Every index from the prior hand-rolled schema, including the
    /// bit-range functional indices, which now name generated columns
    /// rather than inline "column & mask" SQL expressions.
    static let indices: [IndexDeclaration] = [
        // drawers — parent_node_id replaces the wing/room indices (node-tree integrity NT-L2)
        IndexDeclaration(name: "idx_drawers_parent_node_id", table: "drawers", columns: ["parent_node_id"]),
        IndexDeclaration(name: "idx_drawers_sourceFile", table: "drawers", columns: ["sourceFile"]),
        IndexDeclaration(name: "idx_drawers_tombstoned", table: "drawers", columns: ["tombstonedAt"]),
        IndexDeclaration(name: "idx_drawers_lineageID", table: "drawers", columns: ["lineageID"]),
        IndexDeclaration(name: "idx_drawers_udcCode", table: "drawers", columns: ["udcCode"]),
        // filedAt — ORDER BY filedAt DESC LIMIT 256 on the Director recall path
        // scanned all ~53,000 rows without this index. With it, SQLite walks the
        // index in reverse order and stops after 256 entries.
        IndexDeclaration(name: "idx_drawers_filedAt", table: "drawers", columns: ["filedAt"]),
        // bit-range functional indices, now on generated columns
        IndexDeclaration(name: "idx_drawers_provenance_source", table: "drawers", columns: ["g_provenance_source"]),
        IndexDeclaration(name: "idx_drawers_provenance_confirmation", table: "drawers", columns: ["g_provenance_confirmation"]),
        IndexDeclaration(name: "idx_drawers_operational_channel", table: "drawers", columns: ["g_operational_channel"]),
        IndexDeclaration(name: "idx_drawers_state_cluster", table: "drawers", columns: ["g_state_cluster"]),
        // tunnels
        IndexDeclaration(name: "idx_tunnels_source", table: "tunnels", columns: ["sourceWing", "sourceRoom"]),
        IndexDeclaration(name: "idx_tunnels_target", table: "tunnels", columns: ["targetWing", "targetRoom"]),
        // Parent-edge lookup: find the parent tunnel for a child drawer,
        // and find all children of a parent drawer (node-tree integrity, NT-L5).
        IndexDeclaration(name: "idx_tunnels_kind_source_drawer", table: "tunnels", columns: ["kind_id", "sourceDrawerId"]),
        IndexDeclaration(name: "idx_tunnels_kind_target_drawer", table: "tunnels", columns: ["kind_id", "targetDrawerId"]),
        // diary
        IndexDeclaration(name: "idx_diary_agent", table: "diary", columns: ["agentName"]),
        IndexDeclaration(name: "idx_diary_wing", table: "diary", columns: ["wing"]),
        IndexDeclaration(name: "idx_diary_filedAt", table: "diary", columns: ["filedAt"]),
        // kg_facts
        IndexDeclaration(name: "idx_kg_facts_sourceDrawer", table: "kg_facts", columns: ["sourceDrawerID"]),
        IndexDeclaration(name: "idx_kg_facts_subject", table: "kg_facts", columns: ["subject"]),
        IndexDeclaration(name: "idx_kg_facts_state_cluster", table: "kg_facts", columns: ["g_state_cluster"]),
        // proposals — query paths: by target row (which proposals act
        // on a row), by lattice anchor (anchor resolution), and by
        // lifecycle state cluster (pending vs resolved)
        IndexDeclaration(name: "idx_proposals_target", table: "proposals", columns: ["targetRowID"]),
        IndexDeclaration(name: "idx_proposals_udcCode", table: "proposals", columns: ["udcCode"]),
        IndexDeclaration(name: "idx_proposals_state_cluster", table: "proposals", columns: ["g_state_cluster"]),
        // associations — edge-lookup query paths mirror tunnels (source +
        // target endpoint), plus the lattice-anchor resolution index.
        IndexDeclaration(name: "idx_associations_source", table: "associations", columns: ["sourceWing", "sourceRoom"]),
        IndexDeclaration(name: "idx_associations_target", table: "associations", columns: ["targetWing", "targetRoom"]),
        IndexDeclaration(name: "idx_associations_udcCode", table: "associations", columns: ["udcCode"]),
        // learned_references — query paths: by handle (does this reference
        // already exist?), by source (refresh sweep over one source's
        // references), and by lattice anchor (anchor resolution).
        IndexDeclaration(name: "idx_learned_references_handle", table: "learned_references", columns: ["handle"]),
        IndexDeclaration(name: "idx_learned_references_source", table: "learned_references", columns: ["sourceCatalogID"]),
        IndexDeclaration(name: "idx_learned_references_udcCode", table: "learned_references", columns: ["udcCode"]),
        // source_catalog — query path: by handle (does this source already
        // have a catalog entry? — the learn verb's source-resolution probe).
        IndexDeclaration(name: "idx_source_catalog_handle", table: "source_catalog", columns: ["handle"]),
        // recall_trace — query paths: by target (reward lookup) and by
        // recalledAt (chronological reward sweep)
        IndexDeclaration(name: "idx_recall_trace_target", table: "recall_trace", columns: ["target"]),
        IndexDeclaration(name: "idx_recall_trace_recalledAt", table: "recall_trace", columns: ["recalledAt"]),
        // nodes — node-tree integrity: parent_id for child queries,
        // (parent_id, lookup_name) supports I-NT-4 active-uniqueness lookup
        // (app-layer enforcement only — partial unique not DB-enforceable),
        // (depth, lookup_name) for depth-scoped resolution.
        IndexDeclaration(name: "idx_nodes_parent_id", table: "nodes", columns: ["parent_id"]),
        IndexDeclaration(name: "idx_nodes_parent_lookup", table: "nodes", columns: ["parent_id", "lookup_name"]),
        IndexDeclaration(name: "idx_nodes_depth_lookup", table: "nodes", columns: ["depth", "lookup_name"]),
    ]

    // MARK: - encoder_models (Encoder Rerank Program §2)

    /// The span-encoder registry: one row per shipped encoder per device,
    /// exactly one row with `is_active = 1` at a time. The active row is what
    /// the recall stage and the span-encode duty read; `EncoderModelStore` is
    /// the only writer (`upsert`, `activate`).
    ///
    /// Column notes. `model_id` is `<model>-w<window_words>`: the span
    /// window is part of the identity, so a different window is a different
    /// index and is never compared. `model_version` is the weights revision;
    /// a weights change is a new version and a re-index. `query_prefix` /
    /// `doc_prefix` are "" when the model card has none. `pooling` is "mean"
    /// or "cls". `tokenizer_hash` is the sha256 hex of the vendored vocab
    /// file, checked at load. `overlap_divisor` 2 = half overlap (step =
    /// window / 2). `max_spans` caps the spans per drawer (32). `max_sequence`
    /// is the model's token limit. `is_active` is INTEGER per house style
    /// (no Bool stored properties). `ext` is the fleet forward-compat slot.
    static let encoderModelsTable = TableDeclaration(
        name: "encoder_models",
        columns: [
            .text("model_id"),
            .text("model_version"),
            .int("dim"),
            .text("query_prefix"),
            .text("doc_prefix"),
            .text("pooling"),
            .text("tokenizer_hash"),
            .int("window_words"),
            .int("overlap_divisor"),
            .int("max_spans"),
            .int("max_sequence"),
            // is_active: 1 = the configured model on this device, 0 = shipped
            // but idle. INTEGER per house style; decoded by a computed Bool.
            ColumnDeclaration(name: "is_active", type: .int, nullable: false,
                              defaultValue: .int(0)),
            .json("ext", nullable: true),
        ],
        primaryKey: ["model_id"]
    )

    /// The `encoder_models` DDL the v10 → v19 hop issues (sqlite and
    /// postgresql identical). Column for column the same shape as
    /// `encoderModelsTable`; kept as text so the migration is a plain
    /// CREATE TABLE IF NOT EXISTS, idempotent against the declared-table
    /// pass that runs before the ladder.
    static let encoderModelsDDL = """
        CREATE TABLE IF NOT EXISTS "encoder_models" (
            "model_id"        TEXT NOT NULL,
            "model_version"   TEXT NOT NULL,
            "dim"             INTEGER NOT NULL,
            "query_prefix"    TEXT NOT NULL,
            "doc_prefix"      TEXT NOT NULL,
            "pooling"         TEXT NOT NULL,
            "tokenizer_hash"  TEXT NOT NULL,
            "window_words"    INTEGER NOT NULL,
            "overlap_divisor" INTEGER NOT NULL,
            "max_spans"       INTEGER NOT NULL,
            "max_sequence"    INTEGER NOT NULL,
            "is_active"       INTEGER NOT NULL DEFAULT 0,
            "ext"             TEXT NULL,
            PRIMARY KEY ("model_id")
        )
        """

    // MARK: - fact_extractor_models (Distilled Fact Extraction v20)

    static let factExtractorModelsTable = TableDeclaration(
        name: "fact_extractor_models",
        columns: [
            .text("recipe_id"),
            .text("provider_id"),
            .text("model_id"),
            .text("model_version"),
            .text("schema_version"),
            .text("extractor_kind"),
            .int("maximum_input_characters"),
            .int("maximum_facts_per_source"),
            ColumnDeclaration(name: "is_active", type: .int, nullable: false,
                              defaultValue: .int(0)),
            .json("ext", nullable: true),
        ],
        primaryKey: ["recipe_id"]
    )

    static let factExtractorModelsDDL = """
        CREATE TABLE IF NOT EXISTS "fact_extractor_models" (
            "recipe_id"                 TEXT NOT NULL,
            "provider_id"               TEXT NOT NULL,
            "model_id"                  TEXT NOT NULL,
            "model_version"             TEXT NOT NULL,
            "schema_version"            TEXT NOT NULL,
            "extractor_kind"            TEXT NOT NULL,
            "maximum_input_characters"  INTEGER NOT NULL,
            "maximum_facts_per_source"  INTEGER NOT NULL,
            "is_active"                 INTEGER NOT NULL DEFAULT 0,
            "ext"                       TEXT NULL,
            PRIMARY KEY ("recipe_id")
        )
        """
}

/// What `mootx01 upgrade` does with an estate whose LocusKit ledger row
/// carries a given stored version (`LocusKitSchema.upgradePath(storedVersion:)`).
/// Mirrors Rust `schema::SchemaUpgradePath`.
public enum SchemaUpgradePath: Equatable, Sendable {
    /// No ledger row (0): a fresh estate; opening creates the v20 layout.
    case fresh
    /// Stored version 10 or 19: opening applies the remaining migration hops.
    case upgrade(from: Int)
    /// Already at the current version: nothing to apply.
    case current
    /// Any other version. Newer than this build, or a pre-release development
    /// version (11–18) that only the surgery script moves. Refuse before the
    /// schema is opened, naming the version found.
    case unsupported(found: Int)
}
