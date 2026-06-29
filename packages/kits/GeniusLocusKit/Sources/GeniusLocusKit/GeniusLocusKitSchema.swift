// GeniusLocusKitSchema.swift
//
// The explicit composite SchemaDeclaration for a GLK estate.
//
// A GeniusLocus estate is a composition of three kits plus GLK-owned tables:
//
//   LocusKit      — 15 tables (drawers, tunnels, diary, manifest, kg_facts,
//                   proposals, associations, learned_references, source_catalog,
//                   node_bundles, container_fingerprints, recall_trace, keys,
//                   snapshot_registry, snapshot_attestations)
//   VectorKit     — 1 table (vectors)
//   CorpusKit     — 2 tables (chunks, corpus_metadata)
//   GLK grants    — 1 table (grants)
//   GLK matrix    — 1 table (matrix_snapshot)
//
// Total: 20 user-visible tables. The PersistenceKit-internal tables
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
// IMPORTANT: matrix_snapshot MUST be in this composite so StorageReplicator.hydrate
// copies it from the durable SQLite backend into the in-memory backend before
// rebuildDerivedAccelerators runs. Without it, hydrated estates always cold-rebuild
// the matrix tier, discarding persisted calibration state.
//
// Kit ID and version: the composite uses "GeniusLocusKit" as the kit
// identifier and the sum of component versions plus the GLK-owned addends.
// Components: LocusKit v8 + VectorKit v3 + CorpusKit (BundleStore) v3
// + Grants v1 + MatrixSnapshot v1 = 16. (BasisStore is the
// separate "CorpusKitBasis" kit-ID schema, not part of this composite,
// so its version is not summed here.) The schema gate in the replication
// primitive checks this version on both the source and destination; both
// must be opened with this same declaration before a flush or hydrate.
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

    /// Composite schema version. Defined as the sum of component versions.
    /// Components: LocusKit v8 + VectorKit v3 + CorpusKit (BundleStore) v3
    ///             + Grants v1 + MatrixSnapshot v1 = 16.
    /// Component declarations are live references so a component bump
    /// self-corrects the composite without a hand-edited constant. (BasisStore
    /// is the separate "CorpusKitBasis" kit-ID schema, not part of this
    /// composite, so it is not summed.)
    public static let version =
        LocusKitSchema.version
        + VectorStore.schemaDeclaration.version
        + BundleStore.schemaDeclaration.version
        + grantsSchemaVersion
        + matrixSnapshotSchemaVersion

    /// The complete 20-table schema declaration for a GeniusLocus estate.
    ///
    /// Compose the component kit tables and indices into a single declaration
    /// under the "GeniusLocusKit" kit ID and composite version. The caller passes
    /// this to:
    ///   - `Storage.open(schema:)` — creates all 20 tables, indices, and
    ///     generated-column triggers in the target backend.
    ///   - `StorageReplicator.flush(from:into:schema:)` — copies all 20
    ///     tables plus audit events into the durable backend.
    ///   - `StorageReplicator.hydrate(into:from:schema:)` — copies all 20
    ///     tables plus audit events from the durable backend into a fresh
    ///     in-memory backend before `Estate.open` runs against it.
    ///
    /// The matrix_snapshot table is included here so hydration copies
    /// persisted matrix calibration state into the in-memory backend.
    /// Without it, rebuildDerivedAccelerators always cold-rebuilds the
    /// matrix tier, discarding saved calibration curves and timestamps.
    public static var estateSchemaDeclaration: SchemaDeclaration {
        SchemaDeclaration(
            kitID: kitID,
            version: version,
            tables: locusKitTables + vectorKitTables + corpusKitTables + grantsTables + matrixSnapshotTables,
            indices: locusKitIndices + vectorKitIndices + corpusKitIndices
        )
    }

    // MARK: - Component table lists

    /// The 15 LocusKit tables, extracted from `LocusKitSchema.schema`.
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

    /// The 2 CorpusKit tables, extracted from `BundleStore.schemaDeclaration`.
    private static var corpusKitTables: [TableDeclaration] {
        BundleStore.schemaDeclaration.tables
    }

    private static var corpusKitIndices: [IndexDeclaration] {
        BundleStore.schemaDeclaration.indices
    }

    /// The GLK grant authorization table. Grant issuance and revocation state is
    /// security-sensitive estate state, so hydrate/flush must snapshot it with
    /// drawers, vectors, and corpus rows.
    private static var grantsTables: [TableDeclaration] {
        [GrantStore.grantsTable]
    }

    /// Composite addend for GLK-owned grant authorization state.
    private static let grantsSchemaVersion = 1

    /// The matrix_snapshot table from MatrixSnapshotStore.
    ///
    /// Including this table in the composite schema ensures StorageReplicator.hydrate
    /// copies persisted matrix calibration snapshots from the durable SQLite backend
    /// into the in-memory backend. Without it, hydrated estates silently cold-rebuild
    /// their matrix tier, discarding calibration curves and decay timestamps.
    ///
    /// The table is created by MatrixSnapshotStore in rebuildDerivedAccelerators —
    /// this composite reference does NOT transfer schema ownership; it only ensures
    /// the replication path includes the table.
    private static var matrixSnapshotTables: [TableDeclaration] {
        MatrixSnapshotStore.schemaDeclaration.tables
    }

    /// Composite addend for the GLK matrix snapshot table.
    private static let matrixSnapshotSchemaVersion = MatrixSnapshotStore.schemaDeclaration.version

}
