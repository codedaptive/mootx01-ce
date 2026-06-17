// GeniusLocusKitSchema.swift
//
// The explicit composite SchemaDeclaration for a GLK estate.
//
// A GeniusLocus estate is a composition of three kits, each declaring its
// own per-kit SchemaDeclaration:
//
//   LocusKit  — 12 tables (drawers, tunnels, diary, manifest, kg_facts,
//               proposals, associations, learned_references, node_bundles,
//               container_fingerprints, recall_trace, keys)
//   VectorKit — 1 table (vectors)
//   CorpusKit — 1 table (chunks)
//
// Total: 14 user-visible tables. The PersistenceKit-internal tables
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
// identifier and the sum of the three GLK-composed component versions as
// the composite version. After the ADR-012 `ext` pre-provisioning bumps,
// that sum is LocusKit v2 + VectorKit v3 + CorpusKit (BundleStore) v2 = 7.
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

    /// Composite schema version. Defined as the sum of the three GLK-composed
    /// component versions: LocusKit v2 + VectorKit v3 + CorpusKit (BundleStore)
    /// v2 = 7 (the ADR-012 `ext` pre-provisioning bumped all three). Derived
    /// from the live component declarations, not a literal, so a future
    /// component bump self-corrects this composite without a hand-edited
    /// constant — and any drift between components and composite is impossible
    /// by construction. Advancing any component schema therefore forces a
    /// version bump here automatically, which causes the schema gate to reject
    /// a source/destination mismatch. (BasisStore is the separate
    /// "CorpusKitBasis" kit-ID schema, not part of this composite, so it is not
    /// summed.)
    public static let version =
        LocusKitSchema.version
        + VectorStore.schemaDeclaration.version
        + BundleStore.schemaDeclaration.version

    /// The complete 14-table schema declaration for a GeniusLocus estate.
    ///
    /// Compose the component kit tables and indices into a single declaration
    /// under the "GeniusLocusKit" kit ID and version 7. The caller passes this
    /// to:
    ///   - `Storage.open(schema:)` — creates all 14 tables, indices, and
    ///     generated-column triggers in the target backend.
    ///   - `StorageReplicator.flush(from:into:schema:)` — copies all 14
    ///     tables plus audit events into the durable backend.
    ///   - `StorageReplicator.hydrate(into:from:schema:)` — copies all 14
    ///     tables plus audit events from the durable backend into a fresh
    ///     in-memory backend before `Estate.open` runs against it.
    public static var estateSchemaDeclaration: SchemaDeclaration {
        SchemaDeclaration(
            kitID: kitID,
            version: version,
            tables: locusKitTables + vectorKitTables + corpusKitTables,
            indices: locusKitIndices + vectorKitIndices + corpusKitIndices
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
}
