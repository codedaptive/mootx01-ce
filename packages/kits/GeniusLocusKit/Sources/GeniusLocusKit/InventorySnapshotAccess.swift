import PersistenceKit

public extension GeniusLocusKit {
    /// Capture the registered estate storage's bounded, immutable inventory.
    ///
    /// This intentionally vends the narrow snapshot primitive instead of the
    /// backing `Storage`, keeping raw persistence access inside the
    /// coordinator's handle registry.
    func captureInventorySnapshot(for handle: EstateHandle) async throws -> InventorySnapshot {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        return try await storage.captureInventorySnapshot(limits: .production)
    }
}
