// GeniusLocusKitSchema.swift
//
// The explicit composite SchemaDeclaration for a GLK estate.
//
// A GeniusLocus estate is a composition of three kits plus GLK-only tables:
//
//   LocusKit  — 12 tables (drawers, tunnels, diary, manifest, kg_facts,
//               proposals, associations, learned_references, node_bundles,
//               container_fingerprints, recall_trace, keys)
//   VectorKit — 1 table (vectors)
//   CorpusKit — 1 table (chunks)
//   GeniusLocusKit-only — 1 table (memory_clusters, distillation staging)
//
// Total: 15 user-visible tables. The PersistenceKit-internal tables
// (_storagekit_audit, _storagekit_migrations, _storagekit_blobs,
// _storagekit_vector_meta) are NOT declared here — they are created
// unconditionally by the backend on every open.
//
// This declaration is the input to `StorageReplicator.hydrate` and
// `StorageReplicator.flush`. The replication primitive iterates
// `schema.tables` for the row-snapshot path and requires an explicit,
// correct table list to copy the full estate state. Without this
// declaration the caller would have to assemble it ad-hoc; providing
// it here avoids drift between what is opened and what is replicated.
//
// Kit ID and version: the composite uses "GeniusLocusKit" as the kit
// identifier and the sum of component versions. The component sum after
// ADR-012 `ext` pre-provisioning is LocusKit v2 + VectorKit v3 +
// CorpusKit (BundleStore) v2 = 7. `glkVersion = 1` adds the GLK-only
// memory_clusters table (DG1), making the total composite version 8.
// (BasisStore is a separate kit-ID schema, "CorpusKitBasis", not part of
// this composite, so its version is not summed here.) The schema gate in
// the replication primitive checks this version on both the source and
// destination; both must be opened with this same declaration before a
// flush or hydrate.
//
// Reference: REPLICATION_GROUND_TRUTH.md §SchemaDeclaration tables enumeration.

import Foundation
import LocusKit
import VectorKit
import CorpusKit
import PersistenceKit

public enum GeniusLocusKitSchema {

    /// The kit identifier recorded in PersistenceKit's migrations table for
    /// the composite GLK estate schema. Distinct from "LocusKit", "VectorKit",
    /// and "CorpusKit" so the schema gate distinguishes a GLK-level open from
    /// a single-kit open against the same database.
    public static let kitID = "GeniusLocusKit"

    /// GLK-only schema version addend. Incremented when a table owned exclusively
    /// by GeniusLocusKit (i.e. not by a component kit) is added. Currently 1
    /// for the memory_clusters table (DG1). Component kit bumps self-correct the
    /// component portion of the sum; this constant tracks the GLK-only portion.
    private static let glkVersion: Int = 1

    /// Composite schema version. Defined as the sum of component versions plus
    /// `glkVersion`. Components: LocusKit v2 + VectorKit v3 + CorpusKit
    /// (BundleStore) v2 = 7 (ADR-012 `ext` pre-provisioning bumped all three).
    /// Adding `glkVersion = 1` (memory_clusters, DG1) gives total = 8.
    /// Component declarations are live references so a component bump
    /// self-corrects the composite without a hand-edited constant; `glkVersion`
    /// must be incremented manually when a GLK-only table is added. (BasisStore
    /// is the separate "CorpusKitBasis" kit-ID schema, not part of this
    /// composite, so it is not summed.)
    public static let version =
        LocusKitSchema.version
        + VectorStore.schemaDeclaration.version
        + BundleStore.schemaDeclaration.version
        + glkVersion

    /// The complete 15-table schema declaration for a GeniusLocus estate.
    ///
    /// Compose the component kit tables and indices plus GLK-only tables into a
    /// single declaration under the "GeniusLocusKit" kit ID and version 8. The
    /// caller passes this to:
    ///   - `Storage.open(schema:)` — creates all 15 tables, indices, and
    ///     generated-column triggers in the target backend.
    ///   - `StorageReplicator.flush(from:into:schema:)` — copies all 15
    ///     tables plus audit events into the durable backend.
    ///   - `StorageReplicator.hydrate(into:from:schema:)` — copies all 15
    ///     tables plus audit events from the durable backend into a fresh
    ///     in-memory backend before `Estate.open` runs against it.
    public static var estateSchemaDeclaration: SchemaDeclaration {
        SchemaDeclaration(
            kitID: kitID,
            version: version,
            tables: locusKitTables + vectorKitTables + corpusKitTables + glkTables,
            indices: locusKitIndices + vectorKitIndices + corpusKitIndices + glkIndices
        )
    }

    // MARK: - Component table lists

    /// The 12 LocusKit tables, extracted from `LocusKitSchema.schema`.
    ///
    /// These are listed verbatim from `LocusKitSchema` to avoid drift —
    /// if LocusKit adds a table it must update its own `schema` declaration
    /// and this property derives from it, so the GLK composite stays current.
    private static var locusKitTables: [TableDeclaration] {
        LocusKitSchema.schema.tables
    }

    private static var locusKitIndices: [IndexDeclaration] {
        LocusKitSchema.schema.indices
    }

    /// The 1 VectorKit table, extracted from `VectorStore.schemaDeclaration`.
    private static var vectorKitTables: [TableDeclaration] {
        VectorStore.schemaDeclaration.tables
    }

    private static var vectorKitIndices: [IndexDeclaration] {
        VectorStore.schemaDeclaration.indices
    }

    /// The 1 CorpusKit table, extracted from `BundleStore.schemaDeclaration`.
    private static var corpusKitTables: [TableDeclaration] {
        BundleStore.schemaDeclaration.tables
    }

    private static var corpusKitIndices: [IndexDeclaration] {
        BundleStore.schemaDeclaration.indices
    }

    // MARK: - GLK-only tables

    /// Tables owned exclusively by GeniusLocusKit (not by any component kit).
    ///
    /// `memory_clusters` — distillation staging table. Tracks cluster lifecycle
    /// from grouping through SNR computation to factoid production. A cluster
    /// moves open → held | distilling → distilled | failed. Not a retrieval
    /// table: distilled factoids are stored as ordinary drawers in room
    /// "_distilled" (DISTILLATION_DESIGN.md §0). This table is the
    /// coordination/staging structure the distillation daemon writes.
    private static var glkTables: [TableDeclaration] {
        [
            TableDeclaration(
                name: "memory_clusters",
                columns: [
                    .uuid("id"),
                    .text("status", nullable: false),          // open|held|distilling|distilled|failed
                    .float("snr", nullable: true),
                    .json("member_ids", nullable: false),      // JSON array of drawer UUIDs
                    .int("member_count", nullable: false),
                    .text("factoid_id", nullable: true),       // UUID of produced "_distilled" drawer
                    .text("held_reason", nullable: true),
                    .timestamp("filed_at", nullable: false),
                    .timestamp("updated_at", nullable: false),
                ],
                primaryKey: ["id"]
            )
        ]
    }

    /// Indices for GLK-only tables.
    private static var glkIndices: [IndexDeclaration] {
        [
            IndexDeclaration(name: "idx_memory_clusters_status",
                             table: "memory_clusters",
                             columns: ["status"],
                             unique: false),
            IndexDeclaration(name: "idx_memory_clusters_factoid",
                             table: "memory_clusters",
                             columns: ["factoid_id"],
                             unique: false),
        ]
    }
}
