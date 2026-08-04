//! LocusKit storage schema. Ports `LocusKitSchema.swift`.
//!
//! Declares the LocusKit schema as a single `SchemaDeclaration` over
//! `persistence-kit` primitives — tables, columns, generated columns,
//! append-only flags, indices. There is no migration ladder: each version
//! re-declares the full column set fresh (no estate data has shipped), the
//! same way the Swift port does. The prior `LOCI_V035_*` migration ladder was
//! development-time scaffolding for a store that never shipped, collapsed into
//! the v1 CREATE. v2 adds the nullable `.json` `ext` forward-compat slot to the
//! `keys` table, completing the one-`ext`-column-per-persistent-entity
//! convention; 1.0 writes NULL and never reads it.
//!
//! ## Bitmap reservation map (low bit = 0)
//!
//! Ranges marked FREE are documented headroom; consuming one is a value
//! change, not a migration.
//!
//! ```text
//! drawers.adjective_bitmap (Adjectives.swift / adjectives.rs)
//!   bits 0–3   state cluster (State raw 0..15)        ASSIGNED
//!   bits 4–6   sensitivity axis                       ASSIGNED
//!   bits 7–9   exportability axis                     ASSIGNED
//!   bits 10–11 trust axis                             ASSIGNED
//!   bits 12–63 FREE (52 bits headroom)
//!
//! drawers.operational_bitmap (DrawerOperational.swift)
//!   bits 0–3   capture channel                        ASSIGNED
//!   bits 4–7   content kind                           ASSIGNED
//!   bits 8–15  feature flags                          ASSIGNED
//!   bits 16–19 FREE (4 bits headroom)
//!   bit  20    is_vague (Wave-2 consolidation)        ASSIGNED
//!   bit  21    represented_by_vague (Wave-2)          ASSIGNED
//!   bits 22–23 vague_level 2-bit sub-field (Wave-2)   ASSIGNED
//!   bits 24–63 FREE (40 bits headroom)
//!
//! drawers.provenance
//!   bits 0–3   source type                            ASSIGNED
//!   bits 4–6   confirmation                           ASSIGNED
//!   bits 7–63  FREE (57 bits headroom)
//! ```
//!
//! The same headroom convention applies to the tunnel, kg_fact, and
//! diary bitmap columns; see each table's section comment.

use persistence_kit::generated_column::{GeneratedColumn, GeneratedExpression};
use persistence_kit::schema::{
    ColumnDeclaration, IndexDeclaration, Migration, SchemaDeclaration, SchemaOperation,
    TableDeclaration,
};
use persistence_kit::types::{ColumnType, TypedValue};

/// The kit identifier recorded in PersistenceKit's migrations table.
pub const KIT_ID: &str = "LocusKit";

/// Current schema version. v13 adds the kg_facts identity trio
/// (`addedBy`, `foreignSourceKey`, `foreignRecordID`, all TEXT NOT NULL
/// DEFAULT '') — the columns MXE-KH declared on the table but shipped
/// without a ladder entry, so populated v12 estates never gained them on
/// open. The `mootx01 upgrade` backfill (kg_fact_identity_backfill)
/// moves misfiled pre-existing `source_drawer_id` values into them after
/// this migration runs.
/// v12 adds the subject trio to `drawers`
/// (`subject`, `subject_pipeline_version`, `subject_at`, all nullable) —
/// the one-sentence AI-facing summary progressive recall returns in the
/// dense row. Nullable with no backfill: NULL `subject` IS the
/// backfill-eligibility predicate, so pre-v12 rows are simply subject
/// debt until a producer fills them.
/// v11 adds `operationalAND INT64 NOT NULL DEFAULT -1`
/// to `container_fingerprints` — the AND-reduction aggregate used by
/// `distillItemsSweep` to skip rooms where every active drawer already
/// has bit 19 (HAS_CURRENT_REPRESENTATION) set. Default -1 is the AND
/// identity; `rebuildAll` (called at estate open) tightens it to the true
/// AND. v10 adds a composite UNIQUE constraint on associations
/// (sourceWing, sourceRoom, sourceDrawerId, targetWing,
/// targetRoom, targetDrawerId, label) to prevent VectorSimilaritySignal
/// from accumulating duplicate association edges on every 300-second
/// pass (FINDING-3). Migration deduplicates existing rows then adds the
/// unique index. v9 added content_fingerprint BLOB nullable to drawers
/// (CRITICAL fix — `fingerprints_captured_in`/`fingerprint_bit_series`
/// previously recomputed every drawer's Fingerprint256 from scratch on
/// every call; the value is now computed once at write time and read
/// back from this column). v8 changes nodes.merkle_root from TEXT to
/// BLOB (NT-Q1 — eliminates hex encoding waste). v7 added content_hash
/// BLOB nullable to drawers (NT-L3) and snapshot_registry +
/// snapshot_attestations tables (NT-L3 Part 3). v6 added order_key
/// REAL nullable to tunnels (node-tree integrity, mission NT-L5). v5 added
/// erasure_ledger (NT-L4). v4 replaced wing/room with parent_node_id
/// (NT-L2). v3 added nodes (NT-L1). v2 added keys.ext.
/// Matches Swift `LocusKitSchema.version`.
pub const SCHEMA_VERSION: i32 = 13;

/// Build the complete LocusKit schema as a `SchemaDeclaration`.
///
/// `Storage::open(&schema)` creates every table, generated column,
/// append-only trigger, and index from this single value. Returns a
/// fresh declaration on each call so callers may pass it by value
/// downstream without sharing mutable state.
pub fn schema() -> SchemaDeclaration {
    SchemaDeclaration {
        kit_id: KIT_ID.to_string(),
        version: SCHEMA_VERSION,
        tables: vec![
            drawers_table(),
            tunnels_table(),
            diary_table(),
            manifest_table(),
            kg_facts_table(),
            proposals_table(),
            associations_table(),
            learned_references_table(),
            source_catalog_table(),
            node_bundles_table(),
            container_fingerprints_table(),
            recall_trace_table(),
            keys_table(),
            nodes_table(),
            erasure_ledger_table(),
            snapshot_registry_table(),
            snapshot_attestations_table(),
        ],
        indices: indices(),
        migrations: vec![
            // v12 → v13: add the kg_facts identity trio (MXE-KH declared
            // these on `kg_facts_table()` but shipped no ladder entry, so a
            // populated v12 estate never gained them and every write to
            // them — including the `mootx01 upgrade` backfill — would fail
            // with "no such column"). NOT NULL DEFAULT '' matches the
            // declaration contract: a locally-filed, unanchored fact writes
            // the same shape it always did. The DATA move (pre-KH
            // source_drawer_id values into their correct columns) is
            // deliberately NOT a schema operation — it needs the
            // drawers/lineage evidence and per-class counting that live in
            // kg_fact_identity_backfill, run only by `mootx01 upgrade`.
            // Matches the Swift v12 → v13 migration exactly.
            Migration {
                from_version: 12,
                to_version: 13,
                operations: vec![
                    SchemaOperation::AddColumn {
                        table: "kg_facts".to_string(),
                        column: ColumnDeclaration::text("addedBy")
                            .with_default(TypedValue::Text(String::new())),
                    },
                    SchemaOperation::AddColumn {
                        table: "kg_facts".to_string(),
                        column: ColumnDeclaration::text("foreignSourceKey")
                            .with_default(TypedValue::Text(String::new())),
                    },
                    SchemaOperation::AddColumn {
                        table: "kg_facts".to_string(),
                        column: ColumnDeclaration::text("foreignRecordID")
                            .with_default(TypedValue::Text(String::new())),
                    },
                ],
            },
            // v11 → v12: add the subject trio to drawers (progressive
            // recall dense row). All three nullable, no backfill — NULL
            // `subject` is the backfill-eligibility predicate, so pre-v12
            // rows surface as subject debt via `count_missing_subject`
            // rather than requiring a data migration. Without the
            // addColumns, a pre-v12 estate hits "no such column" on every
            // drawer read after the binary upgrades (the v8 → v9 failure
            // mode). Matches the Swift v11 → v12 migration exactly.
            Migration {
                from_version: 11,
                to_version: 12,
                operations: vec![
                    SchemaOperation::AddColumn {
                        table: "drawers".to_string(),
                        column: ColumnDeclaration::text("subject").nullable(),
                    },
                    SchemaOperation::AddColumn {
                        table: "drawers".to_string(),
                        column: ColumnDeclaration::text("subject_pipeline_version").nullable(),
                    },
                    SchemaOperation::AddColumn {
                        table: "drawers".to_string(),
                        column: ColumnDeclaration::timestamp("subject_at").nullable(),
                    },
                ],
            },
            // v10 → v11: add operationalAND to container_fingerprints.
            // Default -1 (AND identity).  rebuildAll at estate open tightens
            // the aggregate; no data migration of existing rows needed — the
            // default is a conservative under-approximation that only widens
            // the distillation sweep (never skips work falsely).
            Migration {
                from_version: 10,
                to_version: 11,
                operations: vec![SchemaOperation::AddColumn {
                    table: "container_fingerprints".to_string(),
                    column: ColumnDeclaration::new(
                        "operationalAND",
                        persistence_kit::types::ColumnType::Bitmap,
                    )
                    .with_default(TypedValue::Bitmap(-1)),
                }],
            },
            // v9 → v10 (FINDING-3): add natural-key uniqueness to associations.
            // Order matters: dedup FIRST, then CREATE UNIQUE INDEX (the index
            // creation would fail if duplicate rows still exist). Keeps the
            // earliest rowid for each natural-key tuple, matching the Swift
            // migration behaviour.
            Migration {
                from_version: 9,
                to_version: 10,
                operations: vec![
                    SchemaOperation::Custom {
                        sqlite: Some(
                            r#"DELETE FROM "associations" WHERE rowid NOT IN (
                                SELECT MIN(rowid) FROM "associations"
                                GROUP BY "sourceWing", "sourceRoom", "sourceDrawerId",
                                         "targetWing", "targetRoom", "targetDrawerId", "label"
                            )"#
                            .to_string(),
                        ),
                        postgresql: None,
                    },
                    SchemaOperation::AddIndex(
                        IndexDeclaration::new(
                            "idx_associations_natural_key",
                            "associations",
                            vec![
                                "sourceWing".to_string(),
                                "sourceRoom".to_string(),
                                "sourceDrawerId".to_string(),
                                "targetWing".to_string(),
                                "targetRoom".to_string(),
                                "targetDrawerId".to_string(),
                                "label".to_string(),
                            ],
                        )
                        .unique(),
                    ),
                ],
            },
        ],
    }
}

// ---------------------------------------------------------------------------
// drawers
// ---------------------------------------------------------------------------

/// The drawer table. Primary key `id` is TEXT, not UUID: LocusKit
/// drawer ids are arbitrary content strings ("d1",
/// "supersedes:<a>:<b>"), never UUIDs, so the key is a plain text
/// column and the store does not rely on UUID key resolution.
///
/// Generated columns expose the indexed bit-range field extracts the
/// retrieval layer dispatches on. They are derived from the three
/// bitmap columns and indexed below like ordinary columns.
fn drawers_table() -> TableDeclaration {
    TableDeclaration {
        name: "drawers".to_string(),
        columns: vec![
            ColumnDeclaration::text("id"),
            ColumnDeclaration::text("content"),
            // FK to nodes.id (the room node containing this drawer).
            // Replaces the stored wing/room text columns (node-tree integrity NT-L2).
            ColumnDeclaration::text("parent_node_id"),
            ColumnDeclaration::text("sourceFile").nullable(),
            ColumnDeclaration::int("chunkIndex").nullable(),
            ColumnDeclaration::text("addedBy"),
            ColumnDeclaration::timestamp("filedAt"),
            ColumnDeclaration::timestamp("eventTime").nullable(),
            ColumnDeclaration::text("embeddingModelID"),
            ColumnDeclaration::timestamp("tombstonedAt").nullable(),
            ColumnDeclaration::text("removedByBatch").nullable(),
            ColumnDeclaration::bitmap("provenance"),
            ColumnDeclaration::bitmap("adjectiveBitmap"),
            ColumnDeclaration::bitmap("operationalBitmap"),
            // lineageID defaults to the empty string, which intentionally
            // does not parse as a UUID; the Rust drawer-from-row mapping
            // mints a fresh per-row UUID for that case so legacy or unset
            // rows never collide on a single lineage.
            ColumnDeclaration::new("lineageID", ColumnType::Text)
                .with_default(TypedValue::Text(String::new())),
            ColumnDeclaration::new("udcCode", ColumnType::Text)
                .with_default(TypedValue::Text(String::new())),
            ColumnDeclaration::text("udcFacets").nullable(),
            ColumnDeclaration::text("wikidataQID").nullable(),
            ColumnDeclaration::text("wikidataQidsSecondary").nullable(),
            // Reserve-space: single typed-flexible extension column,
            // present from v1, nullable, empty cost approaching zero.
            // Absorbs unforeseeable per-drawer typed attributes (future
            // axes, experimental fields) with no migration.
            ColumnDeclaration::json("ext").nullable(),
            // At-rest encryption key identifier (Mission ENC-01;
            // federation disclosure controls Appendix A.1).
            // NULL = plaintext row. Nullable so plaintext estates write
            // nothing here.
            ColumnDeclaration::text("keyID").nullable(),
            // Per-row content hash computed by the hash-on-write hook
            // (NT-P2 HashingRowStore). BLOB nullable: NULL for rows
            // written before hash-on-write was wired. The Merkle rollup
            // (NT-L3) reads this column to build room/wing/estate roots.
            ColumnDeclaration::blob("content_hash").nullable(),
            // The row's Fingerprint256 (32-byte little-endian wire
            // format via `Fingerprint256::wire_bytes()`), computed by
            // DrawerStore at every insert and refreshed at every update
            // that can change a fingerprint input (adjectiveBitmap,
            // operationalBitmap, provenance, udcCode, wikidataQID — see
            // `EstateFingerprintFamilies::fingerprint`).
            // `fingerprints_captured_in`/`fingerprint_bit_series` read
            // this column directly instead of recomputing per call.
            // Deliberately `ColumnType::Blob`, NOT the native
            // `ColumnType::Fingerprint`/`TypedValue::Fingerprint` pair:
            // the Postgres backend's `to_param` (postgres.rs) binds
            // `TypedValue::Fingerprint` as `Option::<i64>::None` — a
            // silent-NULL stub explicitly marked "not exercised by
            // Phase-1 conformance" — so using the native type here would
            // silently drop every fingerprint on a Postgres-backed
            // estate. `Blob` is fully wired on every backend (SQLite,
            // Postgres BYTEA, InMemory) today; DrawerStore encodes/decodes
            // the wire bytes explicitly (mirrors Swift, whose TypedValue
            // has no Fingerprint case at all). Nullable only so a row can
            // never fail a NOT NULL constraint if a future write path is
            // added without going through DrawerStore's refresh helper;
            // DrawerStore always populates it and treats a NULL/malformed
            // value at read time as a fail-loud LocusKitError, not a
            // silent fallback.
            ColumnDeclaration::blob("content_fingerprint").nullable(),
            // Distilled representation (SPEC_DISTILLATION_STORAGE §4).
            // A dense parallel rendering of `content` — a VIEW of this
            // row, not an item — plus its pipeline contract identifier,
            // approximate token count, and generation instant. The four
            // columns are NULL together or populated together (one
            // atomic UPDATE via `set_distilled_representation`); every
            // write that touches `content` NULLs all four in the same
            // statement (§7.3 regeneration trigger + erasure scrub).
            // NULL `distilled` is the sweep-eligibility predicate.
            // Landed in the v1 declaration with no migration ladder —
            // the 1.1.x schema is fluid (no estate data shipped); the
            // frozen-1.0.x migration is a separate later mission (SPEC
            // Appendix A). Excluded from the content digest/revision
            // that feed the index pipeline (§9). Mirrors the Swift
            // drawersTable declaration.
            ColumnDeclaration::text("distilled").nullable(),
            ColumnDeclaration::text("distilled_pipeline_version").nullable(),
            ColumnDeclaration::int("distilled_token_count").nullable(),
            // TEXT ISO8601 per the fleet date rule (timestamp column type).
            ColumnDeclaration::timestamp("distilled_at").nullable(),
            // Subject trio (progressive recall PR-01): the one-sentence
            // AI-facing summary. Same lifecycle contract as the distilled
            // quad — NULL together or populated together (one atomic
            // UPDATE via `set_subject_representation`); every write that
            // touches `content` NULLs all three in the same statement.
            // NULL `subject` is the backfill-eligibility predicate. The
            // subject is RETURNED on recall rows, never indexed or
            // searched (ranking math is content-only by ruling).
            // `subject_pipeline_version` carries the producer provenance
            // tier ("ai-v1" / "minillm-v1"). No token-count column: the
            // subject is length-contracted at every producer boundary.
            // Mirrors the Swift drawersTable declaration.
            ColumnDeclaration::text("subject").nullable(),
            ColumnDeclaration::text("subject_pipeline_version").nullable(),
            ColumnDeclaration::timestamp("subject_at").nullable(),
        ],
        primary_key: vec!["id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: vec![
            // (adjectiveBitmap & 0x3F), the state cluster. Indexed for
            // the active-predecessor lookup in the supersession cascade
            // and for state-filtered reads. The state field is 6 bits
            // (raw values run to 33), so the mask is 0x3F, not 0xF — a
            // 4-bit mask aliases superseded/tombstoned onto active.
            GeneratedColumn::new(
                "g_state_cluster",
                ColumnType::Int,
                GeneratedExpression::BitAnd(
                    Box::new(GeneratedExpression::Column("adjectiveBitmap".to_string())),
                    Box::new(GeneratedExpression::Literal(0x3F)),
                ),
            ),
            // (provenance & 0xF), the provenance source type.
            GeneratedColumn::new(
                "g_provenance_source",
                ColumnType::Int,
                GeneratedExpression::BitAnd(
                    Box::new(GeneratedExpression::Column("provenance".to_string())),
                    Box::new(GeneratedExpression::Literal(0xF)),
                ),
            ),
            // (provenance >> 4) & 0x7, the provenance confirmation.
            GeneratedColumn::new(
                "g_provenance_confirmation",
                ColumnType::Int,
                GeneratedExpression::BitAnd(
                    Box::new(GeneratedExpression::ShiftRight(
                        Box::new(GeneratedExpression::Column("provenance".to_string())),
                        4,
                    )),
                    Box::new(GeneratedExpression::Literal(0x7)),
                ),
            ),
            // (operationalBitmap & 0xF), the capture channel.
            GeneratedColumn::new(
                "g_operational_channel",
                ColumnType::Int,
                GeneratedExpression::BitAnd(
                    Box::new(GeneratedExpression::Column("operationalBitmap".to_string())),
                    Box::new(GeneratedExpression::Literal(0xF)),
                ),
            ),
        ],
        append_only: false,
        hashable: true,
    }
}

// ---------------------------------------------------------------------------
// tunnels
// ---------------------------------------------------------------------------

/// Bitmap headroom mirrors the drawer convention: adjective_bitmap,
/// operational_bitmap, and provenance_bitmap each carry their assigned
/// low ranges with the high bits FREE. kind_id is the typed
/// TunnelKind vocabulary (default 1 = .references).
fn tunnels_table() -> TableDeclaration {
    TableDeclaration {
        name: "tunnels".to_string(),
        columns: vec![
            ColumnDeclaration::text("id"),
            ColumnDeclaration::text("sourceWing"),
            ColumnDeclaration::text("sourceRoom"),
            ColumnDeclaration::text("sourceDrawerId").nullable(),
            ColumnDeclaration::text("targetWing"),
            ColumnDeclaration::text("targetRoom"),
            ColumnDeclaration::text("targetDrawerId").nullable(),
            ColumnDeclaration::text("label"),
            ColumnDeclaration::text("addedBy"),
            ColumnDeclaration::timestamp("filedAt"),
            ColumnDeclaration::timestamp("tombstonedAt").nullable(),
            ColumnDeclaration::text("removedByBatch").nullable(),
            ColumnDeclaration::new("kind_id", ColumnType::Int).with_default(TypedValue::Int(1)),
            ColumnDeclaration::bitmap("adjectiveBitmap"),
            ColumnDeclaration::bitmap("operationalBitmap"),
            ColumnDeclaration::bitmap("provenanceBitmap"),
            // Fractional-index sibling ordering for Parent tunnels
            // (node-tree integrity, NT-L5). REAL nullable; None for non-parent kinds.
            ColumnDeclaration::float("order_key").nullable(),
            ColumnDeclaration::json("ext").nullable(),
        ],
        primary_key: vec!["id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// diary
// ---------------------------------------------------------------------------

/// operationalBitmap default 0 = eventClass .capture, severity .trace,
/// actorClass .user, batch .standalone, requiresFollowup false. Same
/// headroom convention as drawers.
///
/// `reward` (REAL nullable): explicit quality signal populated at write
/// time by callers that have a score (user rating, model confidence,
/// etc.). `None` = no explicit reward; daemon falls back to
/// `RecallTraceItem.used`. See NEURONKIT_SPEC § 3.1 step 1a.
///
/// `rewardProvenance` (TEXT nullable): human-readable tag for how
/// `reward` was derived. `None` when `reward` is `None`.
fn diary_table() -> TableDeclaration {
    TableDeclaration {
        name: "diary".to_string(),
        columns: vec![
            ColumnDeclaration::text("id"),
            ColumnDeclaration::text("agentName"),
            ColumnDeclaration::text("entry"),
            ColumnDeclaration::text("topic"),
            ColumnDeclaration::text("wing"),
            ColumnDeclaration::text("room"),
            ColumnDeclaration::timestamp("filedAt"),
            ColumnDeclaration::text("embeddingModelID"),
            ColumnDeclaration::timestamp("tombstonedAt").nullable(),
            ColumnDeclaration::text("removedByBatch").nullable(),
            ColumnDeclaration::bitmap("operationalBitmap"),
            // Explicit reward channel (NEURONKIT_SPEC § 3.1 step 1a).
            ColumnDeclaration::float("reward").nullable(),
            // Provenance tag for the reward value.
            ColumnDeclaration::text("rewardProvenance").nullable(),
            ColumnDeclaration::json("ext").nullable(),
        ],
        primary_key: vec!["id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// manifest
// ---------------------------------------------------------------------------

fn manifest_table() -> TableDeclaration {
    TableDeclaration {
        name: "manifest".to_string(),
        columns: vec![
            ColumnDeclaration::text("key"),
            ColumnDeclaration::text("value"),
        ],
        primary_key: vec!["key".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// kg_facts
// ---------------------------------------------------------------------------

/// KGFact persistence per spec section 4.1. Three Int64 bitmap columns
/// mirror the in-memory value type's adjective / operational /
/// provenance axes, same headroom convention as drawers.
fn kg_facts_table() -> TableDeclaration {
    TableDeclaration {
        name: "kg_facts".to_string(),
        columns: vec![
            ColumnDeclaration::text("id"),
            ColumnDeclaration::text("subject"),
            ColumnDeclaration::text("predicate"),
            ColumnDeclaration::text("object"),
            ColumnDeclaration::text("sourceDrawerID"),
            // Provenance columns that are deliberately NOT sourceDrawerID:
            // the filing host identity, and the foreign palace's own key and
            // record id for imported facts. sourceDrawerID carries a local
            // drawer id or "" and nothing else. All three default to "" so a
            // locally-filed, unanchored fact writes the same shape it always
            // did. The palace re-import dedup signature reads foreignSourceKey.
            ColumnDeclaration::text("addedBy"),
            ColumnDeclaration::text("foreignSourceKey"),
            ColumnDeclaration::text("foreignRecordID"),
            ColumnDeclaration::bitmap("adjectiveBitmap"),
            ColumnDeclaration::bitmap("operationalBitmap"),
            ColumnDeclaration::bitmap("provenanceBitmap"),
            ColumnDeclaration::timestamp("filedAt"),
            ColumnDeclaration::json("ext").nullable(),
        ],
        primary_key: vec!["id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: vec![
            // (adjectiveBitmap & 0x3F), the raw 6-bit RowState. Active
            // kgFact recall filters to the RowState Cluster-A set via
            // `g_state_cluster < RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW`
            // (the cluster-B floor, 16) — active/pending/contested/accepted
            // kept, retired B/C states (16+/32+) excluded — so the state
            // extract is indexed here as on drawers. 6-bit mask (0x3F) to
            // match the full state field, as on drawers.
            GeneratedColumn::new(
                "g_state_cluster",
                ColumnType::Int,
                GeneratedExpression::BitAnd(
                    Box::new(GeneratedExpression::Column("adjectiveBitmap".to_string())),
                    Box::new(GeneratedExpression::Literal(0x3F)),
                ),
            ),
        ],
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// proposals
// ---------------------------------------------------------------------------

/// Proposal persistence per mission NOUN-PRO-01 and cookbook §2.4.
/// Three Int64 bitmap columns mirror the in-memory value type's
/// adjective / operational / provenance axes; `candidateState` is a
/// fourth bitmap carrying the proposed adjective set the proposal would
/// apply to its target if accepted (cookbook §10.7 candidate_state).
/// The lattice anchor (cookbook §2.7 / I-16) is stored as the same four
/// columns drawers use — udcCode + udcFacets + wikidataQID +
/// wikidataQidsSecondary — with udcCode TEXT NOT NULL DEFAULT '';
/// `add_proposal` rejects an empty anchor before insert. Same headroom
/// convention as kg_facts.
fn proposals_table() -> TableDeclaration {
    TableDeclaration {
        name: "proposals".to_string(),
        columns: vec![
            ColumnDeclaration::text("id"),
            ColumnDeclaration::text("targetRowID"),
            ColumnDeclaration::text("justification").nullable(),
            ColumnDeclaration::bitmap("candidateState"),
            ColumnDeclaration::bitmap("adjectiveBitmap"),
            ColumnDeclaration::bitmap("operationalBitmap"),
            ColumnDeclaration::bitmap("provenanceBitmap"),
            ColumnDeclaration::new("udcCode", ColumnType::Text)
                .with_default(TypedValue::Text(String::new())),
            ColumnDeclaration::text("udcFacets").nullable(),
            ColumnDeclaration::text("wikidataQID").nullable(),
            ColumnDeclaration::text("wikidataQidsSecondary").nullable(),
            ColumnDeclaration::timestamp("filedAt"),
            ColumnDeclaration::json("ext").nullable(),
        ],
        primary_key: vec!["id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: vec![
            // (adjectiveBitmap & 0x3F), the state cluster. Proposals are
            // filtered by lifecycle state — pending while awaiting
            // confirmation vs accepted/rejected/withdrawn afterward — via
            // the per-cluster predicate `(state >> 4) & 0x3`; the field
            // extract is indexed here as on drawers and kg_facts. 6-bit
            // mask (0x3F) to match the full state field.
            GeneratedColumn::new(
                "g_state_cluster",
                ColumnType::Int,
                GeneratedExpression::BitAnd(
                    Box::new(GeneratedExpression::Column("adjectiveBitmap".to_string())),
                    Box::new(GeneratedExpression::Literal(0x3F)),
                ),
            ),
        ],
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// associations
// ---------------------------------------------------------------------------

/// Association persistence per mission NOUN-ASC-01 and cookbook §2.4. The
/// edge-shaped sibling of `tunnels`: source + target endpoints (wing +
/// room + optional drawer id), three Int64 bitmap columns, and the Rev 1.0
/// soft-delete reservation. Two differences from `tunnels`: there is no
/// `kind_id` (an association carries no typed-relationship vocabulary — all
/// semantics live in operationalBitmap, cookbook §2.4), and the lattice
/// anchor (cookbook §2.7 / I-16) is stored as the same four columns drawers
/// and proposals use — udcCode TEXT NOT NULL DEFAULT '' + udcFacets +
/// wikidataQID + wikidataQidsSecondary; `add_association` rejects an empty
/// anchor before insert. No generated columns — like `tunnels`, the edge
/// endpoints are the indexed query paths.
fn associations_table() -> TableDeclaration {
    TableDeclaration {
        name: "associations".to_string(),
        columns: vec![
            ColumnDeclaration::text("id"),
            ColumnDeclaration::text("sourceWing"),
            ColumnDeclaration::text("sourceRoom"),
            ColumnDeclaration::text("sourceDrawerId").nullable(),
            ColumnDeclaration::text("targetWing"),
            ColumnDeclaration::text("targetRoom"),
            ColumnDeclaration::text("targetDrawerId").nullable(),
            ColumnDeclaration::text("label"),
            ColumnDeclaration::text("addedBy"),
            ColumnDeclaration::timestamp("filedAt"),
            ColumnDeclaration::timestamp("tombstonedAt").nullable(),
            ColumnDeclaration::text("removedByBatch").nullable(),
            ColumnDeclaration::new("udcCode", ColumnType::Text)
                .with_default(TypedValue::Text(String::new())),
            ColumnDeclaration::text("udcFacets").nullable(),
            ColumnDeclaration::text("wikidataQID").nullable(),
            ColumnDeclaration::text("wikidataQidsSecondary").nullable(),
            ColumnDeclaration::bitmap("adjectiveBitmap"),
            ColumnDeclaration::bitmap("operationalBitmap"),
            ColumnDeclaration::bitmap("provenanceBitmap"),
            ColumnDeclaration::json("ext").nullable(),
        ],
        primary_key: vec!["id".to_string()],
        // v10 — FINDING-3: natural-key uniqueness prevents VectorSimilaritySignal
        // from accumulating duplicate association edges on every 300-second pass.
        // NULL != NULL in SQLite unique indexes, so wing/room-level associations
        // (NULL drawer IDs) do not conflict — acceptable because the signal always
        // produces drawer-level pairs with non-null IDs.
        unique_constraints: vec![vec![
            "sourceWing".to_string(),
            "sourceRoom".to_string(),
            "sourceDrawerId".to_string(),
            "targetWing".to_string(),
            "targetRoom".to_string(),
            "targetDrawerId".to_string(),
            "label".to_string(),
        ]],
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// learned_references
// ---------------------------------------------------------------------------

/// LearnedReference persistence per mission NOUN-LRF-01, arch spec §7.8.2,
/// and cookbook §2.4/§2.7. The substrate the grounding-driven `learn` verb
/// writes to (learnedReference is the only noun accepting learn). Mirrors
/// `associations` structurally — a required lattice anchor stored as the
/// same four columns (udcCode TEXT NOT NULL DEFAULT '' + udcFacets +
/// wikidataQID + wikidataQidsSecondary; `add_learned_reference` rejects an
/// empty anchor), three Int64 bitmap columns, and the Rev 1.0 soft-delete
/// reservation. Two content columns replace the edge endpoints:
/// `sourceCatalogID` (the SourceCatalogEntry reference, stored as an
/// identifier the way kg_facts stores sourceDrawerID) and `handle` (the
/// reference URI). No generated columns — the query paths are id, handle,
/// source, and the lattice anchor. The refresh_policy / drift_severity /
/// mode / source operational axes (cookbook §2.4) live in
/// operationalBitmap, not as columns.
fn learned_references_table() -> TableDeclaration {
    TableDeclaration {
        name: "learned_references".to_string(),
        columns: vec![
            ColumnDeclaration::text("id"),
            ColumnDeclaration::text("sourceCatalogID"),
            ColumnDeclaration::text("handle"),
            ColumnDeclaration::text("addedBy"),
            ColumnDeclaration::timestamp("filedAt"),
            ColumnDeclaration::timestamp("tombstonedAt").nullable(),
            ColumnDeclaration::text("removedByBatch").nullable(),
            ColumnDeclaration::new("udcCode", ColumnType::Text)
                .with_default(TypedValue::Text(String::new())),
            ColumnDeclaration::text("udcFacets").nullable(),
            ColumnDeclaration::text("wikidataQID").nullable(),
            ColumnDeclaration::text("wikidataQidsSecondary").nullable(),
            ColumnDeclaration::bitmap("adjectiveBitmap"),
            ColumnDeclaration::bitmap("operationalBitmap"),
            ColumnDeclaration::bitmap("provenanceBitmap"),
            ColumnDeclaration::json("ext").nullable(),
        ],
        primary_key: vec!["id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// source_catalog
// ---------------------------------------------------------------------------

/// SourceCatalogEntry persistence per arch spec §7.8.2. The durable,
/// queryable record of an external source from which references are
/// learned — the `source` slot of the grounding-driven `learn` verb. The
/// learn verb derives every `LearnedReference`'s genuine lattice anchor
/// from the matching catalog entry (never a sentinel), so the anchor lives
/// here as the same four columns every anchored noun uses (udcCode TEXT NOT
/// NULL DEFAULT '' + udcFacets + wikidataQID + wikidataQidsSecondary;
/// `add_source_catalog_entry` rejects an empty anchor). `kind` is the
/// `SourceKind` raw (Int). `handle` is the source's own canonical locator,
/// indexed for the learn verb's source-resolution probe.
fn source_catalog_table() -> TableDeclaration {
    TableDeclaration {
        name: "source_catalog".to_string(),
        columns: vec![
            ColumnDeclaration::text("id"),
            ColumnDeclaration::int("kind"),
            ColumnDeclaration::text("handle"),
            ColumnDeclaration::text("addedBy"),
            ColumnDeclaration::timestamp("firstSeen"),
            ColumnDeclaration::new("udcCode", ColumnType::Text)
                .with_default(TypedValue::Text(String::new())),
            ColumnDeclaration::text("udcFacets").nullable(),
            ColumnDeclaration::text("wikidataQID").nullable(),
            ColumnDeclaration::text("wikidataQidsSecondary").nullable(),
            ColumnDeclaration::json("ext").nullable(),
        ],
        primary_key: vec!["id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// node_bundles
// ---------------------------------------------------------------------------

/// Per-node count-vector bundles for the bundle algebra
/// (bundle algebra and erasure,
/// estate node containment). The node is the
/// wing/room grouping: a room-level row (room non-empty) bundles the
/// drawers in that room, and a wing-level row (room == "") is the
/// merge of its rooms. `bundleKind` is "A" for the active centroid
/// and "B" for the departed accumulator. `counts` holds the 256
/// per-bit counts as little-endian UInt32 (1024 bytes) and `n` the
/// member count. Not append-only: Bundle A rows are rewritten on each
/// recompute and Bundle B rows on each departure.
fn node_bundles_table() -> TableDeclaration {
    TableDeclaration {
        name: "node_bundles".to_string(),
        columns: vec![
            ColumnDeclaration::text("wing"),
            ColumnDeclaration::text("room"),
            ColumnDeclaration::text("bundleKind"),
            ColumnDeclaration::int("n"),
            ColumnDeclaration::blob("counts"),
            ColumnDeclaration::timestamp("updatedAt"),
        ],
        primary_key: vec![
            "wing".to_string(),
            "room".to_string(),
            "bundleKind".to_string(),
        ],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// container_fingerprints
// ---------------------------------------------------------------------------

/// Per-container OR-reductions of the three bitmap fields, the pruning
/// fingerprints of spec section 11.5 that recall filter ordering
/// (section 7.9.4 step 1) tests before any per-row scan. A room-level
/// row (room non-empty) holds the OR of every active drawer's bitmaps
/// in that room; a wing-level row (room == "") is the OR of its
/// rooms. The OR is monotone, so a capture ORs the new row's bits in
/// incrementally; bit-clearing mutations leave the row a sound
/// over-approximation until a periodic rebuild tightens it (extra set
/// bits never prune a container that holds a match, they only forgo a
/// prune). Not append-only.
fn container_fingerprints_table() -> TableDeclaration {
    TableDeclaration {
        name: "container_fingerprints".to_string(),
        columns: vec![
            ColumnDeclaration::text("wing"),
            ColumnDeclaration::text("room"),
            ColumnDeclaration::bitmap("adjectiveOR"),
            ColumnDeclaration::bitmap("operationalOR"),
            ColumnDeclaration::bitmap("provenanceOR"),
            ColumnDeclaration::timestamp("updatedAt"),
            // AND-reduction aggregate for operational bits (v11).
            // Default -1 is the AND identity; rebuildAll (called at estate
            // open) tightens it to the true AND of all active drawers in
            // the room.  Used by distillItemsSweep to skip rooms where
            // every active drawer already has bit 19 set.
            ColumnDeclaration::new("operationalAND", persistence_kit::types::ColumnType::Bitmap)
                .with_default(TypedValue::Bitmap(-1)),
        ],
        primary_key: vec!["wing".to_string(), "room".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// recall_trace
// ---------------------------------------------------------------------------

/// RecallTraceItem persistence per NEURONKIT_SPEC §3.1. One row per
/// drawer returned by a recall operation. The `used` flag (bit 0 of
/// operationalBitmap) is flipped to 1 when the reward path consumes
/// the row; Bradley-Terry uses this distinction when computing
/// tournament weights (cookbook §8.12).
///
/// operationalBitmap reservation:
///   bit 0   used                         ASSIGNED
///   bits 1–63  FREE (63 bits headroom)
///
/// `score` is REAL nullable: the recall may not produce a score for
/// every row (e.g. ordered-by-capture-time queries). `recalledAt` is
/// the TEXT ISO8601 timestamp (fleet date-storage rule); PersistenceKit
/// stores it as `ColumnType::Timestamp`.
fn recall_trace_table() -> TableDeclaration {
    TableDeclaration {
        name: "recall_trace".to_string(),
        columns: vec![
            ColumnDeclaration::text("id"),
            ColumnDeclaration::text("target"),
            ColumnDeclaration::timestamp("recalledAt"),
            ColumnDeclaration::float("score").nullable(),
            ColumnDeclaration::bitmap("operationalBitmap"),
            ColumnDeclaration::json("ext").nullable(),
        ],
        primary_key: vec!["id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// keys (ENC-01 encryption-key registry)
// ---------------------------------------------------------------------------

/// At-rest encryption key registry (Mission ENC-01;
/// federation disclosure controls Appendix A.1). Maps a
/// stable key identifier to the wrapped key bytes. `wrapped` holds the data
/// key wrapped by the platform keystore (Secure Enclave / TPM); the registry
/// must never hold a raw unwrapped key.
///
/// `created_at` is TEXT ISO8601 per the fleet date-storage rule — stored via
/// `ColumnType::Timestamp` (PersistenceKit emits TEXT ISO8601 for that type).
///
/// `drawers.keyID` references `key_id`. A drawer record under an absent key is
/// unreadable, not missing (Appendix A.1). Until the hardware-wrapping path is
/// implemented, this table is intentionally empty — populating `wrapped` with
/// an unwrapped key would be a security regression (ENC-01 scope note).
///
/// Column-for-column mirror of `LocusKitSchema.keysTable` in Swift:
///   key_id    TEXT NOT NULL PRIMARY KEY   — stable opaque identifier
///   algorithm TEXT NOT NULL               — e.g. "AES-GCM-256"
///   wrapped   BLOB NOT NULL               — key bytes from platform keystore
///   created_at TIMESTAMP (TEXT ISO8601)   — creation instant
///   ext       JSON (nullable)             — forward-compat slot (nullable entity ext slots, v2)
pub fn keys_table() -> TableDeclaration {
    TableDeclaration {
        name: "keys".to_string(),
        columns: vec![
            ColumnDeclaration::text("key_id"),
            ColumnDeclaration::text("algorithm"),
            ColumnDeclaration::blob("wrapped"),
            ColumnDeclaration::timestamp("created_at"),
            // Reserve-space forward-compat slot. Nullable `.json`,
            // present from schema v2. Reserves the slot, not a shape: future
            // key-registry metadata (rotation lineage, KMS provider tags)
            // serializes here migration-free. 1.0 writes NULL and never reads it.
            ColumnDeclaration::json("ext").nullable(),
        ],
        primary_key: vec!["key_id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// nodes
// ---------------------------------------------------------------------------

/// Container nodes for the estate's containment tree. Estate
/// (depth 0), wing (depth 1), room (depth 2). Drawers reference
/// their parent room via `parent_node_id` on the drawers table
/// (NT-L2). The `merkle_root` column stores a 32-byte BLOB
/// populated by the Merkle rollup on every capture, expunge,
/// and withdraw.
///
/// HLC columns (`created_hlc`, `tombstoned_hlc`) are tagged with
/// ColumnRole so PersistenceKit's as-of filter operates over nodes
/// identically to drawers.
fn nodes_table() -> TableDeclaration {
    TableDeclaration {
        name: "nodes".to_string(),
        columns: vec![
            ColumnDeclaration::text("id"),
            ColumnDeclaration::text("parent_id").nullable(),
            ColumnDeclaration::text("display_name"),
            ColumnDeclaration::text("lookup_name"),
            ColumnDeclaration::int("depth"),
            ColumnDeclaration::int("lifecycle"),
            ColumnDeclaration::created_hlc("created_hlc"),
            ColumnDeclaration::tombstoned_hlc("tombstoned_hlc"),
            ColumnDeclaration::timestamp("tombstoned_at").nullable(),
            ColumnDeclaration::blob("merkle_root").nullable(),
            ColumnDeclaration::timestamp("created_at"),
            ColumnDeclaration::timestamp("updated_at"),
            ColumnDeclaration::json("ext").nullable(),
        ],
        primary_key: vec!["id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// erasure_ledger (node-tree integrity, NT-L4)
// ---------------------------------------------------------------------------

/// Append-only ledger recording THAT a drawer was erased. Mirrors
/// Swift PersistenceKit ErasureLedgerSchema.ledgerTable.
fn erasure_ledger_table() -> TableDeclaration {
    TableDeclaration {
        name: "erasure_ledger".to_string(),
        columns: vec![
            ColumnDeclaration::text("drawer_id"),
            ColumnDeclaration::hlc("erased_hlc"),
        ],
        primary_key: vec!["drawer_id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: true,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// snapshot_registry + snapshot_attestations (NT-L3 Part 3)
// ---------------------------------------------------------------------------

/// Snapshot registry table. Mirrors Swift
/// `SnapshotSchema.registryTable`.
fn snapshot_registry_table() -> TableDeclaration {
    TableDeclaration {
        name: "snapshot_registry".to_string(),
        columns: vec![
            ColumnDeclaration::text("snapshot_id"),
            ColumnDeclaration::hlc("hlc"),
            ColumnDeclaration::text("label").nullable(),
            ColumnDeclaration::timestamp("created_at"),
        ],
        primary_key: vec!["snapshot_id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

/// Snapshot attestations table. Mirrors Swift
/// `SnapshotSchema.attestationsTable`.
fn snapshot_attestations_table() -> TableDeclaration {
    TableDeclaration {
        name: "snapshot_attestations".to_string(),
        columns: vec![
            ColumnDeclaration::text("snapshot_id"),
            ColumnDeclaration::text("subject_kind"),
            ColumnDeclaration::text("subject_id"),
            ColumnDeclaration::text("merkle_root"),
            ColumnDeclaration::int("key_version").nullable(),
        ],
        primary_key: vec![
            "snapshot_id".to_string(),
            "subject_kind".to_string(),
            "subject_id".to_string(),
        ],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

// ---------------------------------------------------------------------------
// indices
// ---------------------------------------------------------------------------

/// Every index from the prior hand-rolled schema, including the
/// bit-range functional indices, which now name generated columns
/// rather than inline "column & mask" SQL expressions.
fn indices() -> Vec<IndexDeclaration> {
    vec![
        // drawers — parent_node_id replaces the wing/room indices (node-tree integrity NT-L2)
        IndexDeclaration::new(
            "idx_drawers_parent_node_id",
            "drawers",
            vec!["parent_node_id".to_string()],
        ),
        IndexDeclaration::new(
            "idx_drawers_sourceFile",
            "drawers",
            vec!["sourceFile".to_string()],
        ),
        IndexDeclaration::new(
            "idx_drawers_tombstoned",
            "drawers",
            vec!["tombstonedAt".to_string()],
        ),
        IndexDeclaration::new(
            "idx_drawers_lineageID",
            "drawers",
            vec!["lineageID".to_string()],
        ),
        IndexDeclaration::new(
            "idx_drawers_udcCode",
            "drawers",
            vec!["udcCode".to_string()],
        ),
        // bit-range functional indices, now on generated columns
        IndexDeclaration::new(
            "idx_drawers_provenance_source",
            "drawers",
            vec!["g_provenance_source".to_string()],
        ),
        IndexDeclaration::new(
            "idx_drawers_provenance_confirmation",
            "drawers",
            vec!["g_provenance_confirmation".to_string()],
        ),
        IndexDeclaration::new(
            "idx_drawers_operational_channel",
            "drawers",
            vec!["g_operational_channel".to_string()],
        ),
        IndexDeclaration::new(
            "idx_drawers_state_cluster",
            "drawers",
            vec!["g_state_cluster".to_string()],
        ),
        // tunnels
        IndexDeclaration::new(
            "idx_tunnels_source",
            "tunnels",
            vec!["sourceWing".to_string(), "sourceRoom".to_string()],
        ),
        IndexDeclaration::new(
            "idx_tunnels_target",
            "tunnels",
            vec!["targetWing".to_string(), "targetRoom".to_string()],
        ),
        // Parent-edge lookup: find the parent tunnel for a child drawer,
        // and find all children of a parent drawer (node-tree integrity, NT-L5).
        IndexDeclaration::new(
            "idx_tunnels_kind_source_drawer",
            "tunnels",
            vec!["kind_id".to_string(), "sourceDrawerId".to_string()],
        ),
        IndexDeclaration::new(
            "idx_tunnels_kind_target_drawer",
            "tunnels",
            vec!["kind_id".to_string(), "targetDrawerId".to_string()],
        ),
        // diary
        IndexDeclaration::new("idx_diary_agent", "diary", vec!["agentName".to_string()]),
        IndexDeclaration::new("idx_diary_wing", "diary", vec!["wing".to_string()]),
        IndexDeclaration::new("idx_diary_filedAt", "diary", vec!["filedAt".to_string()]),
        // kg_facts
        IndexDeclaration::new(
            "idx_kg_facts_sourceDrawer",
            "kg_facts",
            vec!["sourceDrawerID".to_string()],
        ),
        IndexDeclaration::new(
            "idx_kg_facts_subject",
            "kg_facts",
            vec!["subject".to_string()],
        ),
        IndexDeclaration::new(
            "idx_kg_facts_state_cluster",
            "kg_facts",
            vec!["g_state_cluster".to_string()],
        ),
        // proposals — query paths: by target row, by lattice anchor
        // (anchor resolution), and by lifecycle state cluster
        IndexDeclaration::new(
            "idx_proposals_target",
            "proposals",
            vec!["targetRowID".to_string()],
        ),
        IndexDeclaration::new(
            "idx_proposals_udcCode",
            "proposals",
            vec!["udcCode".to_string()],
        ),
        IndexDeclaration::new(
            "idx_proposals_state_cluster",
            "proposals",
            vec!["g_state_cluster".to_string()],
        ),
        // associations — edge-lookup query paths mirror tunnels (source +
        // target endpoint), plus the lattice-anchor resolution index.
        IndexDeclaration::new(
            "idx_associations_source",
            "associations",
            vec!["sourceWing".to_string(), "sourceRoom".to_string()],
        ),
        IndexDeclaration::new(
            "idx_associations_target",
            "associations",
            vec!["targetWing".to_string(), "targetRoom".to_string()],
        ),
        IndexDeclaration::new(
            "idx_associations_udcCode",
            "associations",
            vec!["udcCode".to_string()],
        ),
        // learned_references — query paths: by handle (does this reference
        // already exist?), by source (refresh sweep over one source's
        // references), and by lattice anchor (anchor resolution).
        IndexDeclaration::new(
            "idx_learned_references_handle",
            "learned_references",
            vec!["handle".to_string()],
        ),
        IndexDeclaration::new(
            "idx_learned_references_source",
            "learned_references",
            vec!["sourceCatalogID".to_string()],
        ),
        IndexDeclaration::new(
            "idx_learned_references_udcCode",
            "learned_references",
            vec!["udcCode".to_string()],
        ),
        // source_catalog — query path: by handle (does this source already
        // have a catalog entry? — the learn verb's source-resolution probe).
        IndexDeclaration::new(
            "idx_source_catalog_handle",
            "source_catalog",
            vec!["handle".to_string()],
        ),
        // recall_trace — query paths: by target (reward lookup) and by
        // recalledAt (chronological reward sweep)
        IndexDeclaration::new(
            "idx_recall_trace_target",
            "recall_trace",
            vec!["target".to_string()],
        ),
        IndexDeclaration::new(
            "idx_recall_trace_recalledAt",
            "recall_trace",
            vec!["recalledAt".to_string()],
        ),
        // nodes — node-tree integrity: parent_id for child queries,
        // (parent_id, lookup_name) supports I-NT-4 active-uniqueness lookup
        // (app-layer enforcement only — partial unique not DB-enforceable),
        // (depth, lookup_name) for depth-scoped resolution.
        IndexDeclaration::new(
            "idx_nodes_parent_id",
            "nodes",
            vec!["parent_id".to_string()],
        ),
        IndexDeclaration::new(
            "idx_nodes_parent_lookup",
            "nodes",
            vec!["parent_id".to_string(), "lookup_name".to_string()],
        ),
        IndexDeclaration::new(
            "idx_nodes_depth_lookup",
            "nodes",
            vec!["depth".to_string(), "lookup_name".to_string()],
        ),
    ]
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// The kit identifier matches the Swift constant exactly.
    #[test]
    fn kit_id_matches_swift() {
        assert_eq!(KIT_ID, "LocusKit");
    }

    /// v13 adds the kg_facts identity trio (addedBy, foreignSourceKey,
    /// foreignRecordID) as a ladder entry so populated v12 estates gain
    /// the columns MXE-KH declared on the table.
    /// v12 adds the subject trio (subject, subject_pipeline_version,
    /// subject_at) to drawers for the progressive-recall dense row.
    /// v11 adds operationalAND (AND-reduction aggregate) to container_fingerprints
    /// for distillation-sweep room skipping. v10 added associations natural-key
    /// UNIQUE constraint + v9→v10 migration (FINDING-3 duplicate-edge fix). v9
    /// added content_fingerprint BLOB to drawers (CRITICAL persist-at-write fix).
    /// v8 changed nodes.merkle_root from TEXT to BLOB (NT-Q1). v7 added
    /// content_hash BLOB to drawers and snapshot tables (NT-L3). v6 added
    /// order_key to tunnels (node-tree integrity, NT-L5). v5 added
    /// erasure_ledger (NT-L4). v4 replaced wing/room with parent_node_id (NT-L2).
    #[test]
    fn schema_version_is_thirteen() {
        assert_eq!(SCHEMA_VERSION, 13);
        // Four migrations: v9 → v10 (FINDING-3 dedup + unique index),
        //                  v10 → v11 (operationalAND on container_fingerprints),
        //                  v11 → v12 (subject trio on drawers),
        //                  v12 → v13 (kg_facts identity trio).
        let m = schema();
        assert_eq!(m.migrations.len(), 4);
        // v12 → v13 is listed first (newest-first order).
        assert_eq!(m.migrations[0].from_version, 12);
        assert_eq!(m.migrations[0].to_version, 13);
        assert_eq!(m.migrations[0].operations.len(), 3);
        // v11 → v12 is listed second.
        assert_eq!(m.migrations[1].from_version, 11);
        assert_eq!(m.migrations[1].to_version, 12);
        assert_eq!(m.migrations[1].operations.len(), 3);
        // v10 → v11 is listed third.
        assert_eq!(m.migrations[2].from_version, 10);
        assert_eq!(m.migrations[2].to_version, 11);
        assert_eq!(m.migrations[2].operations.len(), 1);
        // v9 → v10 is listed fourth.
        assert_eq!(m.migrations[3].from_version, 9);
        assert_eq!(m.migrations[3].to_version, 10);
        assert_eq!(m.migrations[3].operations.len(), 2);
    }

    /// Tables in the declared order, matching the Swift declaration.
    /// `proposals` follows `kg_facts` (both noun tables). `keys` is the
    /// ENC-01 encryption-key registry. `nodes` is the node-tree integrity
    /// containment tree. `erasure_ledger` is the NT-L4 append-only
    /// erasure record. `snapshot_registry` and `snapshot_attestations`
    /// are the NT-L3 Part 3 snapshot tables. 17 tables total.
    #[test]
    fn table_count_and_order() {
        let names: Vec<String> = schema().tables.iter().map(|t| t.name.clone()).collect();
        assert_eq!(
            names,
            vec![
                "drawers",
                "tunnels",
                "diary",
                "manifest",
                "kg_facts",
                "proposals",
                "associations",
                "learned_references",
                "source_catalog",
                "node_bundles",
                "container_fingerprints",
                "recall_trace",
                "keys",
                "nodes",
                "erasure_ledger",
                "snapshot_registry",
                "snapshot_attestations",
            ]
        );
    }

    /// Drawers carries four generated columns named exactly like the
    /// Swift declaration, so retrieval filter ordering matches.
    #[test]
    fn drawers_generated_column_names() {
        let s = schema();
        let drawers = s.tables.iter().find(|t| t.name == "drawers").unwrap();
        let names: Vec<&str> = drawers
            .generated_columns
            .iter()
            .map(|g| g.name.as_str())
            .collect();
        assert_eq!(
            names,
            vec![
                "g_state_cluster",
                "g_provenance_source",
                "g_provenance_confirmation",
                "g_operational_channel",
            ]
        );
    }

    /// The provenance-confirmation generated expression is
    /// `(provenance >> 4) & 0x7`. Evaluating it against a synthetic
    /// row exercises both the shift and the mask in one go, matching
    /// the Swift `.bitAnd(.shiftRight(.column("provenance"), 4), .literal(0x7))`.
    #[test]
    fn provenance_confirmation_expression_evaluates() {
        use std::collections::BTreeMap;
        let s = schema();
        let drawers = s.tables.iter().find(|t| t.name == "drawers").unwrap();
        let conf = drawers
            .generated_columns
            .iter()
            .find(|g| g.name == "g_provenance_confirmation")
            .unwrap();
        // bits 4–6 of provenance = 0b101 = 5. Set higher bits too so the
        // mask actually has to clear them.
        let mut row = BTreeMap::new();
        row.insert(
            "provenance".to_string(),
            TypedValue::Bitmap(0b1111_0101_0000),
        );
        // (0b1111_0101_0000 >> 4) & 0x7 = 0b1111_0101 & 0x7 = 0b101 = 5
        assert_eq!(conf.expression.evaluate(&row), 5);
    }

    /// The drawers state-cluster expression masks the low 6 bits of
    /// `adjectiveBitmap` (Codex Pass #2 F2: was 0xF, now 0x3F so the
    /// full 6-bit state field is captured — a 4-bit mask aliased
    /// superseded/tombstoned onto active).
    #[test]
    fn state_cluster_expression_evaluates() {
        use std::collections::BTreeMap;
        let s = schema();
        let drawers = s.tables.iter().find(|t| t.name == "drawers").unwrap();
        let cluster = drawers
            .generated_columns
            .iter()
            .find(|g| g.name == "g_state_cluster")
            .unwrap();
        let mut row = BTreeMap::new();
        row.insert(
            "adjectiveBitmap".to_string(),
            TypedValue::Bitmap(0xFFFF_FFF5),
        );
        assert_eq!(cluster.expression.evaluate(&row), 0x35);
    }

    /// Operational channel masks the low nibble of `operationalBitmap`.
    #[test]
    fn operational_channel_expression_evaluates() {
        use std::collections::BTreeMap;
        let s = schema();
        let drawers = s.tables.iter().find(|t| t.name == "drawers").unwrap();
        let chan = drawers
            .generated_columns
            .iter()
            .find(|g| g.name == "g_operational_channel")
            .unwrap();
        let mut row = BTreeMap::new();
        row.insert("operationalBitmap".to_string(), TypedValue::Bitmap(0xAA));
        // 0xAA & 0xF = 0xA = 10
        assert_eq!(chan.expression.evaluate(&row), 0xA);
    }

    /// kg_facts carries the state-cluster generated column too, matching
    /// the Swift declaration.
    #[test]
    fn kg_facts_has_state_cluster() {
        let s = schema();
        let kg = s.tables.iter().find(|t| t.name == "kg_facts").unwrap();
        assert_eq!(kg.generated_columns.len(), 1);
        assert_eq!(kg.generated_columns[0].name, "g_state_cluster");
    }

    /// Drawer columns match the Swift declaration field-for-field.
    #[test]
    fn drawers_column_set() {
        let s = schema();
        let drawers = s.tables.iter().find(|t| t.name == "drawers").unwrap();
        let names: Vec<&str> = drawers.columns.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(
            names,
            vec![
                "id",
                "content",
                "parent_node_id",
                "sourceFile",
                "chunkIndex",
                "addedBy",
                "filedAt",
                "eventTime",
                "embeddingModelID",
                "tombstonedAt",
                "removedByBatch",
                "provenance",
                "adjectiveBitmap",
                "operationalBitmap",
                "lineageID",
                "udcCode",
                "udcFacets",
                "wikidataQID",
                "wikidataQidsSecondary",
                "ext",
                "keyID",
                "content_hash",
                "content_fingerprint",
                "distilled",
                "distilled_pipeline_version",
                "distilled_token_count",
                "distilled_at",
                "subject",
                "subject_pipeline_version",
                "subject_at",
            ]
        );
    }

    /// Manifest is the typed key-value table.
    #[test]
    fn manifest_table_shape() {
        let s = schema();
        let m = s.tables.iter().find(|t| t.name == "manifest").unwrap();
        let names: Vec<&str> = m.columns.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["key", "value"]);
        assert_eq!(m.primary_key, vec!["key".to_string()]);
    }

    /// Recall trace primary key is `id` and it carries the documented
    /// columns in the right shape.
    #[test]
    fn recall_trace_shape() {
        let s = schema();
        let r = s.tables.iter().find(|t| t.name == "recall_trace").unwrap();
        let names: Vec<&str> = r.columns.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(
            names,
            vec![
                "id",
                "target",
                "recalledAt",
                "score",
                "operationalBitmap",
                "ext"
            ]
        );
    }

    /// Keys table mirrors the Swift ENC-01 declaration column-for-column:
    /// key_id (TEXT PK), algorithm (TEXT), wrapped (BLOB), created_at (TIMESTAMP),
    /// ext (JSON nullable — nullable entity ext slots forward-compat slot, schema v2).
    /// No generated columns, no bitmap columns — a plain registry. Dates are
    /// TEXT ISO8601 (Timestamp type, fleet date-storage rule). `wrapped` is BLOB
    /// so raw key bytes survive a round-trip without encoding, matching Swift's
    /// `.blob("wrapped")`.
    #[test]
    fn keys_table_shape_matches_swift() {
        let s = schema();
        let k = s.tables.iter().find(|t| t.name == "keys").unwrap();
        // Primary key is the stable key identifier
        assert_eq!(k.primary_key, vec!["key_id".to_string()]);
        // Exactly five columns in the same order as the Swift declaration
        // (key_id, algorithm, wrapped, created_at, ext — ext added in v2).
        let names: Vec<&str> = k.columns.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["key_id", "algorithm", "wrapped", "created_at", "ext"]);
        // Column types: TEXT, TEXT, BLOB, Timestamp, Json
        use persistence_kit::types::ColumnType;
        assert_eq!(k.columns[0].column_type, ColumnType::Text);
        assert_eq!(k.columns[1].column_type, ColumnType::Text);
        assert_eq!(k.columns[2].column_type, ColumnType::Blob);
        assert_eq!(k.columns[3].column_type, ColumnType::Timestamp);
        // ext is the nullable JSON forward-compat slot.
        assert_eq!(k.columns[4].column_type, ColumnType::Json);
        assert!(k.columns[4].nullable, "keys.ext must be nullable");
        // No row-level boolean flags, no bitmaps — the registry is opaque;
        // encryption state lives in drawers.keyID (NULL = plaintext, else encrypted).
        for col in &k.columns {
            assert!(
                col.column_type != ColumnType::Bitmap,
                "keys table must not carry a bitmap column"
            );
            assert!(
                col.column_type != ColumnType::Bool,
                "keys table must not carry a Bool stored column"
            );
        }
        // No generated columns — the query path is key_id only
        assert!(k.generated_columns.is_empty());
        // Not append-only: keys can be rotated (replaced by a new key_id row)
        assert!(!k.append_only);
    }

    /// Container fingerprints uses a composite primary key (wing, room)
    /// so the wing-level roll-up row (room == "") and per-room rows
    /// coexist.
    #[test]
    fn container_fingerprints_composite_key() {
        let s = schema();
        let cf = s
            .tables
            .iter()
            .find(|t| t.name == "container_fingerprints")
            .unwrap();
        assert_eq!(cf.primary_key, vec!["wing".to_string(), "room".to_string()]);
    }

    /// Node bundles uses a three-part primary key so Bundle A and
    /// Bundle B rows coexist per (wing, room).
    #[test]
    fn node_bundles_composite_key() {
        let s = schema();
        let nb = s.tables.iter().find(|t| t.name == "node_bundles").unwrap();
        assert_eq!(
            nb.primary_key,
            vec![
                "wing".to_string(),
                "room".to_string(),
                "bundleKind".to_string()
            ]
        );
    }

    /// Index set carries every name from the Swift declaration in
    /// declaration order. The bit-range functional indices reference
    /// the generated columns by name.
    #[test]
    fn index_names_match_swift_order() {
        let names: Vec<String> = indices().iter().map(|i| i.name.clone()).collect();
        assert_eq!(
            names,
            vec![
                "idx_drawers_parent_node_id",
                "idx_drawers_sourceFile",
                "idx_drawers_tombstoned",
                "idx_drawers_lineageID",
                "idx_drawers_udcCode",
                "idx_drawers_provenance_source",
                "idx_drawers_provenance_confirmation",
                "idx_drawers_operational_channel",
                "idx_drawers_state_cluster",
                "idx_tunnels_source",
                "idx_tunnels_target",
                "idx_tunnels_kind_source_drawer",
                "idx_tunnels_kind_target_drawer",
                "idx_diary_agent",
                "idx_diary_wing",
                "idx_diary_filedAt",
                "idx_kg_facts_sourceDrawer",
                "idx_kg_facts_subject",
                "idx_kg_facts_state_cluster",
                "idx_proposals_target",
                "idx_proposals_udcCode",
                "idx_proposals_state_cluster",
                "idx_associations_source",
                "idx_associations_target",
                "idx_associations_udcCode",
                "idx_learned_references_handle",
                "idx_learned_references_source",
                "idx_learned_references_udcCode",
                "idx_source_catalog_handle",
                "idx_recall_trace_target",
                "idx_recall_trace_recalledAt",
                "idx_nodes_parent_id",
                "idx_nodes_parent_lookup",
                "idx_nodes_depth_lookup",
            ]
        );
    }

    /// SQL rendering of the provenance-confirmation expression must
    /// produce the SQLite-and-PostgreSQL-compatible bit-shift text.
    #[test]
    fn provenance_confirmation_renders_sql() {
        let s = schema();
        let drawers = s.tables.iter().find(|t| t.name == "drawers").unwrap();
        let conf = drawers
            .generated_columns
            .iter()
            .find(|g| g.name == "g_provenance_confirmation")
            .unwrap();
        assert_eq!(conf.expression.render_sql(), "((\"provenance\" >> 4) & 7)");
    }

}
