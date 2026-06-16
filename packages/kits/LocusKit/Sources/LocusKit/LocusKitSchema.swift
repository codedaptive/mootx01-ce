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
//   - Reserve-space discipline (DECISION_BUNDLE_ALGEBRA_AND_ERASURE
//     section 10, fleet-wide). The three Int64 bitmap columns carry
//     documented bit-range headroom; the reservation map below
//     records which ranges are assigned and which are free, so a
//     future flag is a bit that was always allocated rather than a
//     migration. Each content table also carries one nullable
//     `.json` extension column from v1 to absorb unforeseeable typed
//     attributes without a schema change. No speculative reserved
//     columns: the json column is the single width-independent
//     container for the unknown-future case.
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
//     bits 16-63 FREE (48 bits headroom)
//
//   drawers.provenance (Q1_DECISION_PROVENANCE_BITMAP.md)
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

    /// Current schema version. v1 declares the full column set; there
    /// is no migration ladder behind it.
    public static let version = 1

    /// The complete LocusKit schema as a PersistenceKit declaration.
    /// `Storage.open(schema:)` creates every table, generated column,
    /// append-only trigger, and index from this single value.
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
                keysTable
            ],
            indices: indices
        )
    }

    // MARK: - drawers

    /// The drawer table. Primary key `id` is TEXT, not UUID: LocusKit
    /// drawer ids are arbitrary content strings ("d1",
    /// "supersedes:<a>:<b>"), never UUIDs, so the key is a plain text
    /// column and the store does not rely on UUID key resolution.
    ///
    /// Generated columns expose the indexed bit-range field extracts
    /// the retrieval layer dispatches on. They are derived from the
    /// three bitmap columns and indexed below like ordinary columns.
    static let drawersTable = TableDeclaration(
        name: "drawers",
        columns: [
            .text("id"),
            .text("content"),
            .text("wing"),
            .text("room"),
            .text("sourceFile", nullable: true),
            .int("chunkIndex", nullable: true),
            .text("addedBy"),
            .timestamp("filedAt"),
            // Two-clock ingest (ING-01). filedAt is the ingest instant;
            // eventTime is when the content happened/was authored in the
            // world. Declared nullable so a row written before this
            // column existed (or a raw insert that omits it) does not
            // violate a NOT NULL constraint; drawerFromRow backfills a
            // NULL/absent eventTime to that row's filedAt. New columns
            // land in the v1 declaration with no migration ladder, per
            // this file's design note — no estate data has shipped.
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
            // DECISION_FEDERATION_SHARING_MODEL_2026-05-21 Appendix A.1).
            // NULL = plaintext row (mode 1). Non-null references
            // keys.key_id and means the content column is ciphertext under
            // that key. Nullable so plaintext estates write nothing here.
            .text("keyID", nullable: true)
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
        ]
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

    /// Per-container OR-reductions of the three bitmap fields, the
    /// pruning fingerprints of spec section 11.5 that recall filter
    /// ordering (section 7.9.4 step 1) tests before any per-row scan.
    /// A room-level row (room non-empty) holds the OR of every active
    /// drawer's bitmaps in that room; a wing-level row (room == "") is
    /// the OR of its rooms. The OR is monotone, so a capture ORs the
    /// new row's bits in incrementally; bit-clearing mutations leave
    /// the row a sound over-approximation until a periodic rebuild
    /// tightens it (extra set bits never prune a container that holds
    /// a match, they only forgo a prune). Not append-only.
    static let containerFingerprintsTable = TableDeclaration(
        name: "container_fingerprints",
        columns: [
            .text("wing"),
            .text("room"),            // "" for the wing-level roll-up
            .bitmap("adjectiveOR"),
            .bitmap("operationalOR"),
            .bitmap("provenanceOR"),
            .timestamp("updatedAt")
        ],
        primaryKey: ["wing", "room"]
    )

    // MARK: - node bundles (bundle-algebra count-vector aggregates)

    /// Per-node count-vector bundles for the bundle algebra
    /// (DECISION_BUNDLE_ALGEBRA_AND_ERASURE_2026-05-20,
    /// DECISION_LOCUSKIT_BUNDLE_HIERARCHY_2026-05-20). The node is the
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
        primaryKey: ["id"]
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
            .json("ext", nullable: true)
        ],
        primaryKey: ["id"]
    )

    // MARK: - keys
    //
    // At-rest encryption key registry (Mission ENC-01;
    // DECISION_FEDERATION_SHARING_MODEL_2026-05-21 Appendix A.1). Maps a
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
            .timestamp("created_at")
        ],
        primaryKey: ["key_id"]
    )

    // MARK: - indices

    /// Every index from the prior hand-rolled schema, including the
    /// bit-range functional indices, which now name generated columns
    /// rather than inline "column & mask" SQL expressions.
    static let indices: [IndexDeclaration] = [
        // drawers
        IndexDeclaration(name: "idx_drawers_wing", table: "drawers", columns: ["wing"]),
        IndexDeclaration(name: "idx_drawers_room", table: "drawers", columns: ["room"]),
        IndexDeclaration(name: "idx_drawers_wing_room", table: "drawers", columns: ["wing", "room"]),
        IndexDeclaration(name: "idx_drawers_sourceFile", table: "drawers", columns: ["sourceFile"]),
        IndexDeclaration(name: "idx_drawers_tombstoned", table: "drawers", columns: ["tombstonedAt"]),
        IndexDeclaration(name: "idx_drawers_lineageID", table: "drawers", columns: ["lineageID"]),
        IndexDeclaration(name: "idx_drawers_udcCode", table: "drawers", columns: ["udcCode"]),
        // bit-range functional indices, now on generated columns
        IndexDeclaration(name: "idx_drawers_provenance_source", table: "drawers", columns: ["g_provenance_source"]),
        IndexDeclaration(name: "idx_drawers_provenance_confirmation", table: "drawers", columns: ["g_provenance_confirmation"]),
        IndexDeclaration(name: "idx_drawers_operational_channel", table: "drawers", columns: ["g_operational_channel"]),
        IndexDeclaration(name: "idx_drawers_state_cluster", table: "drawers", columns: ["g_state_cluster"]),
        // tunnels
        IndexDeclaration(name: "idx_tunnels_source", table: "tunnels", columns: ["sourceWing", "sourceRoom"]),
        IndexDeclaration(name: "idx_tunnels_target", table: "tunnels", columns: ["targetWing", "targetRoom"]),
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
        IndexDeclaration(name: "idx_recall_trace_recalledAt", table: "recall_trace", columns: ["recalledAt"])
    ]
}
