// KGFactSearchProjectionBackfillGateway.swift
//
// Thin gateway that injects FactExtractionKit's FactSearchProjection into
// LocusKit's KGFactSearchProjectionBackfill. GeniusLocusKit depends on both
// LocusKit and FactExtractionKit, so it is the correct injection site —
// LocusKit sits below FactExtractionKit and must not import it directly.
//
// Run ONLY by `mootx01 upgrade` (Bob's ruling: upgrade is the sole
// migration vehicle).

import FactExtractionKit
import Foundation
import LocusKit
import PersistenceKit

/// Gateway that runs the search-projection backfill with FactExtractionKit's
/// concrete build function and version injected.
public enum KGFactSearchProjectionBackfillGateway {

    /// Run the search-projection backfill against `storage`, with the
    /// FactExtractionKit projection builder and version injected.
    ///
    /// - Parameter storage: The estate's storage backend, already keyed.
    /// - Returns: Scanned and updated counts for the upgrade transcript.
    public static func run(
        storage: any Storage
    ) async throws -> KGFactSearchProjectionBackfillReport {
        try await KGFactSearchProjectionBackfill.run(
            storage: storage,
            // FactExtractionKit's build function is injected here because
            // LocusKit sits below FactExtractionKit and must not depend on it.
            buildProjection: { subject, predicate, object in
                FactSearchProjection.build(
                    subject: subject,
                    predicate: predicate,
                    object: object,
                    aliases: []
                )
            },
            projectionVersion: FactSearchProjection.version
        )
    }
}
