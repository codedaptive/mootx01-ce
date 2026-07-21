import CorpusKit
import PersistenceKit

/// Narrow package-only host seam used by optional migration targets.
/// Concrete migration code is intentionally unable to reach GLK registries
/// directly and does not compile into the normal `GeniusLocusKit` product.
package extension GeniusLocusKit {
    func migrationStorage(for handle: EstateHandle) throws -> any Storage {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        return storage
    }

    func migrationRegisteredCorpus(for handle: EstateHandle) -> CorpusContentEngine? {
        corpusKits[handle]
    }

    func migrationFaultToken() -> String? {
        _migrationFaultTokenStorage
    }

    func setMigrationFaultToken(_ token: String?) {
        _migrationFaultTokenStorage = token
    }
}
