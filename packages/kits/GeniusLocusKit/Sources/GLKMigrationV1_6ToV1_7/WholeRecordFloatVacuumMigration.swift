// GLK estate-format 1.6 → 1.7 migration capsule.
//
// Root cause of this capsule's existence: the whole-record dense float lane
// left the default build (ruling 2026-09-07; GENIUSLOCUSKIT_SPEC 3.6.0). A
// populated estate still carries the rows that lane read: one `vectors` row
// of kind 1 (a float32 payload at vector_index 1) per indexed unit and
// model, and the `hnsw_graph` rows of the float lane's approximate index.
// Nothing in the default product reads either any more. The CorpusKit engine
// also still held its representation claim on vector_index 1, and
// `reconcileConfiguredProviders` would keep it alive. Bob ruled the rows
// vacuumed by `mootx01 upgrade` rather than left for a later reclaim.
//
// What the capsule does (SYNAPSEKIT_SPEC `reclaimWholeRecordFloatRows`;
// GENIUSLOCUSKIT_SPEC I-26):
//   1. Delete every `vectors` row of kind 1 and every `hnsw_graph` row, then
//      rebuild the resident binary index and the `.vec` sidecar from the
//      surviving rows so the sidecar's live count and generation match the
//      serving table. Kind 0 (binary fingerprints) and kind 2 (Arctic spans)
//      are never touched.
//   2. Release the CorpusKit consumer's representation claims on
//      vector_index 1 so the engine's reconcile, whose default-build lane
//      list is `[0]`, finds its claims equal to its desires and re-creates
//      nothing.
//   3. Stamp the estate format v1_7.
//
// Under the WholeRecordDense trait the lane is live again, and an audition
// estate whose manifest names a whole-record provider (an `embedding_provider`
// value that is present, non-empty and not the span encoder) keeps its rows:
// the capsule stamps v1_7 without deleting anything, so the format still
// records that the vacuum decision was taken once. Every other estate is
// vacuumed under either build.
//
// Placement in the chain: LAST. The 1.5 → 1.6 capsule stamps v1_6 before this
// one runs, so a crash mid-chain never leaves an estate stamped v1_7 with an
// older capsule's work undone. `GLKMigrationCatalog.prepare` calls
// `runWholeRecordFloatVacuumMigration` after the 1.5 → 1.6 stamp and before
// `wireSubstores`, which is where the engine would otherwise reconcile its
// claims over the rows.
//
// Idempotent: a vacuumed estate deletes nothing, releases nothing and
// rewrites an identical sidecar; the stamp is a no-op at v1_7. A fresh
// estate is stamped current by the catalog without running the capsule and
// is born without the rows.
//
// Enabled by the MigrationV1_6ToV1_7 trait and every MigrationFloor trait
// and the GLK_MIGRATION_V1_6_TO_V1_7 compile-time define.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category "GeniusLocusKit".

import CorpusKit
import Foundation
import GeniusLocusKit
import PersistenceKit
import SynapseKit
import os.log

private let log = Logger(
    subsystem: "com.mootx01.kit",
    category: "GeniusLocusKit"
)

/// What the capsule left behind.
public struct WholeRecordFloatVacuumMigrationReport: Sendable, Equatable {
    /// `vectors` rows of kind 1 deleted by this run.
    public let floatRows: Int
    /// `hnsw_graph` rows deleted by this run.
    public let graphRows: Int
    /// CorpusKit representation claims on vector_index 1 released by this run.
    public let claimsReleased: Int
    /// True when the rows were vacuumed (every default-build run); false
    /// when the WholeRecordDense build found a whole-record provider named
    /// in the manifest and left an audition estate's rows in place.
    public let vacuumed: Bool
    /// The estate format the capsule stamped.
    public let format: EstateFormatVersion

    public init(
        floatRows: Int, graphRows: Int, claimsReleased: Int,
        vacuumed: Bool, format: EstateFormatVersion
    ) {
        self.floatRows = floatRows
        self.graphRows = graphRows
        self.claimsReleased = claimsReleased
        self.vacuumed = vacuumed
        self.format = format
    }
}

public extension GeniusLocusKit {

    /// Run the GLK 1.6 → 1.7 whole-record float vacuum migration for an
    /// estate.
    ///
    /// Deletes the whole-record float rows (`vectors` kind 1) and the
    /// `hnsw_graph` rows, rebuilds the binary sidecar from the surviving rows,
    /// releases the CorpusKit claims on vector_index 1, then stamps the
    /// estate format v1_7. Safe to call on any estate at v1_6 or later: a
    /// vacuumed estate deletes nothing and the stamp is a no-op at v1_7.
    ///
    /// - Parameters:
    ///   - handle: The estate handle for the storage to migrate.
    ///   - now: Wall-clock instant for the format stamp row.
    /// - Returns: The row and claim counts and the stamped format.
    @discardableResult
    func runWholeRecordFloatVacuumMigration(
        handle: EstateHandle,
        now: Date
    ) async throws -> WholeRecordFloatVacuumMigrationReport {
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) }
        catch {
            throw WholeRecordFloatVacuumMigrationError.storageUnavailable(
                reason: "no storage registered for estate: \(error)")
        }

#if MOOTX01_WHOLE_RECORD_DENSE
        // The audition build: an estate provisioned with a whole-record
        // provider keeps its float rows. The span encoder is a rerank stage,
        // never a whole-record provider, so "encoder" vacuums like the
        // default ensemble does.
        if let provisioned = try? await provisionedEmbeddingProvider(for: handle),
           !provisioned.isEmpty, provisioned != Self.encoderProviderID {
            do {
                try await EstateFormatStore(storage: storage).stamp(.v1_7, now: now)
            } catch {
                throw WholeRecordFloatVacuumMigrationError.stampFailed(reason: "\(error)")
            }
            log.info("GLK 1.6→1.7 migration: whole-record provider \(provisioned, privacy: .public) named in the manifest; float rows kept")
            return WholeRecordFloatVacuumMigrationReport(
                floatRows: 0, graphRows: 0, claimsReleased: 0, vacuumed: false, format: .v1_7)
        }
#endif

        // Step 1: the rows and the sidecar. The store is opened on the estate
        // storage with the conventional sidecar path so the rebuild rewrites
        // the file `serve` will load. Both SynapseKit declarations are brought
        // to their current ladder position first (SYNAPSEKIT_SPEC I-10: the
        // ledger preparation before every migrate), so an estate that never
        // registered the vector tier or the claims ledger gains the tables
        // empty rather than failing the delete.
        let floatRows: Int
        let graphRows: Int
        do {
            try await VectorStore.prepareSchemaLedger(storage: storage)
            try await storage.migrate(to: VectorStore.schemaDeclaration)
            try await VectorRepresentationClaims.prepareSchemaLedger(storage: storage)
            try await storage.migrate(to: VectorRepresentationClaims.schemaDeclaration)
            let vectors = VectorStore(
                storage: storage, sidecarURL: VectorStore.defaultSidecarURL(for: storage))
            (floatRows, graphRows) = try await vectors.reclaimWholeRecordFloatRows()
        } catch {
            throw WholeRecordFloatVacuumMigrationError.vacuumFailed(reason: "\(error)")
        }

        // Step 2: the representation claim on the float lane.
        var claimsReleased = 0
        do {
            let claims = VectorRepresentationClaims(storage: storage)
            for key in try await claims.claims(consumer: CorpusContentEngine.claimsConsumer)
            where key.vectorIndex == 1 {
                try await claims.releaseClaim(consumer: CorpusContentEngine.claimsConsumer, key: key)
                claimsReleased += 1
            }
        } catch {
            throw WholeRecordFloatVacuumMigrationError.claimReleaseFailed(reason: "\(error)")
        }

        // Step 3: advance the estate format to v1_7.
        do {
            try await EstateFormatStore(storage: storage).stamp(.v1_7, now: now)
        } catch {
            throw WholeRecordFloatVacuumMigrationError.stampFailed(reason: "\(error)")
        }
        log.info("GLK 1.6→1.7 migration complete (\(floatRows, privacy: .public) float rows, \(graphRows, privacy: .public) graph rows, \(claimsReleased, privacy: .public) claims released)")
        return WholeRecordFloatVacuumMigrationReport(
            floatRows: floatRows, graphRows: graphRows, claimsReleased: claimsReleased,
            vacuumed: true, format: .v1_7)
    }
}

/// Errors thrown by the whole-record float vacuum migration capsule.
public enum WholeRecordFloatVacuumMigrationError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    /// The estate's storage backend could not be accessed.
    case storageUnavailable(reason: String)
    /// The float or graph rows could not be deleted or the sidecar rebuilt.
    case vacuumFailed(reason: String)
    /// The representation claim on vector_index 1 could not be released.
    case claimReleaseFailed(reason: String)
    /// The estate-format stamp could not be written.
    case stampFailed(reason: String)

    public var description: String {
        switch self {
        case let .storageUnavailable(reason):
            return "whole-record float vacuum migration: storage unavailable — \(reason)"
        case let .vacuumFailed(reason):
            return "whole-record float vacuum migration: vacuum failed — \(reason)"
        case let .claimReleaseFailed(reason):
            return "whole-record float vacuum migration: claim release failed — \(reason)"
        case let .stampFailed(reason):
            return "whole-record float vacuum migration: estate-format stamp failed — \(reason)"
        }
    }
}
