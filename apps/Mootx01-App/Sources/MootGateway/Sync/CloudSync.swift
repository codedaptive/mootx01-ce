import Foundation
import MootIntentKit
import OSLog
#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - CloudSync  (M-ING-4 Scenario A — the courier model)
//
// CloudKit is the TRANSPORT for the engine's existing vault export/import/
// reconcile pipeline, not a mirror of estate rows. The app exports a snapshot,
// uploads it to the user's PRIVATE CloudKit database, and other devices
// download it and let the ENGINE reconcile — so sync stays above the
// Swift/Rust parity boundary (ADR-005): the app orchestrates, the engine
// merges. No engine change, no CloudKit in the parity-bound storage layer.
//
// Two seams keep this testable and honest:
//   - EstateSnapshotCourier: produce/consume a snapshot. Production wraps the
//     vault tools; tests inject a recording mock. (The exact vault tool
//     contract is deliberately behind this seam, not guessed here.)
//   - CloudSyncBackend: the CloudKit private DB. The real adapter needs the
//     iCloud container entitlement (owner signing); tests use an in-memory mock.

// MARK: seams

/// Produces and consumes an estate snapshot for courier sync. The production
/// implementation drives the engine's vault export/import/reconcile tools
/// (moot_vault_export / moot_vault_import); importing lets the engine merge.
public protocol EstateSnapshotCourier: Sendable {
    func exportSnapshot() async throws -> Data
    func importSnapshot(_ data: Data) async throws
}

/// The cloud transport. Production is the user's private CloudKit database;
/// tests use an in-memory double. Never a shared/public database — the
/// estate is the owner's alone.
public protocol CloudSyncBackend: Sendable {
    func accountAvailable() async -> Bool
    func upload(key: String, data: Data) async throws
    func download(key: String) async throws -> Data?
}

// MARK: coordinator

public actor CloudSyncCoordinator {

    /// The single record key for the estate snapshot in the private DB.
    public static let snapshotKey = "estate-vault-snapshot"

    public enum Outcome: Sendable, Equatable {
        case skippedNoAccount        // not signed into iCloud — nothing done
        case pushed(bytes: Int)      // local snapshot uploaded
        case pulled(bytes: Int)      // remote snapshot imported (engine merged)
        case nothingRemote           // pull found no snapshot to import
    }

    private let courier: any EstateSnapshotCourier
    private let backend: any CloudSyncBackend
    private let log = Logger(subsystem: "com.codedaptive.mootx01", category: "cloud-sync")

    public init(courier: any EstateSnapshotCourier, backend: any CloudSyncBackend) {
        self.courier = courier
        self.backend = backend
    }

    /// Pull the remote snapshot (engine reconciles it), then push the local
    /// state back up. Courier sync is bidirectional per cycle; the engine's
    /// reconcile is the conflict authority, so pull-before-push means local
    /// edits merge on top of remote before we re-publish.
    @discardableResult
    public func sync() async throws -> [Outcome] {
        guard await backend.accountAvailable() else { return [.skippedNoAccount] }
        var outcomes: [Outcome] = []
        outcomes.append(try await pull())
        outcomes.append(try await push())
        return outcomes
    }

    /// Download the remote snapshot and hand it to the engine to merge. No
    /// remote snapshot yet (first device) is a normal outcome, not an error.
    @discardableResult
    public func pull() async throws -> Outcome {
        guard await backend.accountAvailable() else { return .skippedNoAccount }
        guard let data = try await backend.download(key: Self.snapshotKey) else {
            return .nothingRemote
        }
        try await courier.importSnapshot(data)
        log.info("cloud sync: pulled \(data.count) bytes and reconciled")
        return .pulled(bytes: data.count)
    }

    /// Export the local estate and upload it as the new snapshot.
    @discardableResult
    public func push() async throws -> Outcome {
        guard await backend.accountAvailable() else { return .skippedNoAccount }
        let data = try await courier.exportSnapshot()
        try await backend.upload(key: Self.snapshotKey, data: data)
        log.info("cloud sync: pushed \(data.count) bytes")
        return .pushed(bytes: data.count)
    }
}

// MARK: - CloudKit backend (real transport)

#if canImport(CloudKit)
/// The private-database CloudKit adapter. Stores the snapshot as a single
/// CKRecord with a CKAsset body in the user's private DB.
///
/// REQUIRES (owner signing, not buildable headless): the iCloud container
/// entitlement `com.apple.developer.icloud-container-identifiers` +
/// `com.apple.developer.icloud-services: CloudKit` on the app targets, and
/// the container provisioned in the developer account. Until those are in
/// place `accountAvailable()` returns false and the coordinator no-ops —
/// it never fabricates a sync.
public struct CloudKitSyncBackend: CloudSyncBackend {

    private let container: CKContainer
    private let recordType = "EstateSnapshot"

    public init(containerIdentifier: String = "iCloud.com.codedaptive.mootx01") {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    public func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    public func upload(key: String, data: Data) async throws {
        let recordID = CKRecord.ID(recordName: key)
        let database = container.privateCloudDatabase
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: recordType, recordID: recordID)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: tmp)
        record["snapshot"] = CKAsset(fileURL: tmp)
        _ = try await database.save(record)
        try? FileManager.default.removeItem(at: tmp)
    }

    public func download(key: String) async throws -> Data? {
        let recordID = CKRecord.ID(recordName: key)
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            guard let asset = record["snapshot"] as? CKAsset, let url = asset.fileURL else {
                return nil
            }
            return try Data(contentsOf: url)
        } catch let error as CKError where error.code == .unknownItem {
            return nil   // first device: no snapshot yet
        }
    }
}
#endif
