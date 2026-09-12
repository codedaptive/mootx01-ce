import Foundation
import LocusKit
import PersistenceKit

/// Typed input for the one dataset filing sequence owned by GLK.
///
/// A dataset is durable only when its backend table and dataset-handle drawer
/// both exist.  The frame deliberately contains the fixed handle vocabulary;
/// it is not a generic storage or metadata escape hatch.
public struct DatasetFilingFrame: Sendable {
    public let datasetID: UUID
    public let schema: DatasetSchema
    public let rows: [[String: TypedValue]]
    public let columns: [DatasetColumnSummary]
    public let sourceDescription: String
    public let wing: String?
    public let room: String
    public let addedBy: String
    public let sensitivity: AdjectiveSensitivity
    /// Dataset handles are classified by their UDC code only. The common
    /// Swift/Rust filing contract remains UDC-only because the current Rust
    /// lower primitive cannot retain facets or QIDs; accepting a full anchor
    /// here would silently promise cross-port preservation it cannot provide.
    public let udcCode: String

    public init(
        datasetID: UUID,
        schema: DatasetSchema,
        rows: [[String: TypedValue]],
        columns: [DatasetColumnSummary],
        sourceDescription: String,
        wing: String? = nil,
        room: String,
        addedBy: String,
        sensitivity: AdjectiveSensitivity = .normal,
        udcCode: String
    ) {
        self.datasetID = datasetID
        self.schema = schema
        self.rows = rows
        self.columns = columns
        self.sourceDescription = sourceDescription
        self.wing = wing
        self.room = room
        self.addedBy = addedBy
        self.sensitivity = sensitivity
        self.udcCode = udcCode
    }
}

/// Stage-specific filing failures preserve ARIA's existing response contract
/// while keeping the create/append/capture rollback inside the GLK boundary.
public enum DatasetFilingError: Error, LocalizedError {
    case storageUnavailable(String)
    case createFailed(String)
    case appendFailed(String)
    case handleFailed(String)

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable(let detail): return detail
        case .createFailed(let detail): return detail
        case .appendFailed(let detail): return detail
        case .handleFailed(let detail): return detail
        }
    }
}

public extension GeniusLocusKit {
    /// File a backend dataset and its typed handle as one coordinated GLK
    /// operation.  A failed append or handle capture drops the newly-created
    /// table, preserving the pre-existing all-or-nothing filing intent.
    @discardableResult
    func fileDataset(_ handle: EstateHandle, _ frame: DatasetFilingFrame) async throws -> Drawer {
        try requireMounted(handle, verb: "fileDataset")
        let store: any DatasetStore
        do {
            store = try datasetStore(for: handle)
        } catch {
            throw DatasetFilingError.storageUnavailable(error.localizedDescription)
        }

        do {
            try await store.createDataset(id: frame.datasetID, schema: frame.schema, indexes: [])
        } catch {
            throw DatasetFilingError.createFailed(error.localizedDescription)
        }

        if !frame.rows.isEmpty {
            do {
                try await store.appendRows(id: frame.datasetID, rows: frame.rows)
            } catch {
                try? await store.dropDataset(id: frame.datasetID)
                throw DatasetFilingError.appendFailed(error.localizedDescription)
            }
        }

        do {
            return try await captureDatasetHandle(
                handle,
                datasetId: frame.datasetID,
                columns: frame.columns,
                rowCount: frame.rows.count,
                sourceDescription: frame.sourceDescription,
                wing: frame.wing,
                room: frame.room,
                addedBy: frame.addedBy,
                sensitivity: frame.sensitivity,
                udcCode: frame.udcCode)
        } catch {
            try? await store.dropDataset(id: frame.datasetID)
            throw DatasetFilingError.handleFailed(error.localizedDescription)
        }
    }
}
