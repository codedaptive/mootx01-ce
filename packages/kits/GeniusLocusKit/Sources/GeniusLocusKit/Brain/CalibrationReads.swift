import Foundation

public extension GeniusLocusKit {
    /// Calibration is independent of disposable matrix generations.
    func glkCalibrationCurve(for handle: EstateHandle, modelID: String) async throws -> MatrixCalibrationCurve? {
        let store = try matrixRecords(for: handle)
        if matrixFrozenHandles.contains(handle) {
            guard try await store.state(estateID: handle.estateUUID) != nil else { return nil }
        } else { try await store.prepare() }
        return try await store.loadCalibration(estateID: handle.estateUUID).curves[modelID]
    }

    func glkRecordCalibrationOutcome(for handle: EstateHandle, modelID: String,
                                    claimedConfidence: Float, succeeded: Bool, at now: Date) async throws {
        guard !matrixFrozenHandles.contains(handle) else { throw MatrixRecordError.corrupt("frozen estate refuses calibration writes") }
        let store = try matrixRecords(for: handle)
        try await store.prepare()
        _ = try await store.recordCalibration(estateID: handle.estateUUID, modelID: modelID,
            confidence: claimedConfidence, outcome: succeeded ? .success : .failure, now: now)
    }
}

extension GeniusLocusKit {
    func matrixRecords(for handle: EstateHandle) throws -> MatrixRecordStore {
        guard registry[handle] != nil, mountStates[handle] != .draining, let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        if let store = matrixRecordStores[handle] { return store }
        let store = MatrixRecordStore(storage: storage)
        matrixRecordStores[handle] = store
        return store
    }
}
