import CloudKit
import ConvergenceKit
import Foundation
import Testing
@testable import ConvergenceKitCloudKit

@Suite("SecretSync CloudKit database contract")
struct SecretSyncCloudKitDatabaseContractTests {
    @Test("immutable writes are same-zone atomic conditional creates")
    func immutableWriteContract() async throws {
        let database = U4RecordingDatabase()
        let record = try U4DatabaseFixture.immutableRecord(type: .deviceTrustRecord)

        let result = try await database.modifySecretSyncRecords(
            saving: [record],
            digester: U4DatabaseFixture.digester
        )
        let capture = try #require(await database.capture)

        #expect(capture.savePolicy == .ifServerRecordUnchanged)
        #expect(capture.atomically == true)
        #expect(capture.deletedIDs.isEmpty)
        #expect(capture.savedIDs == [record.recordID])
        #expect(result.saveResults[record.recordID] != nil)
        #expect(result.deleteResults.isEmpty)
    }

    @Test("raw per-item conflicts pass through without classification or suppression")
    func perItemErrorsPassThrough() async throws {
        let database = U4RecordingDatabase(mode: .perItemConflict)
        let record = try U4DatabaseFixture.immutableRecord(type: .deviceEnrollmentProof)

        let result = try await database.modifySecretSyncRecords(
            saving: [record],
            digester: U4DatabaseFixture.digester
        )
        let item = try #require(result.saveResults[record.recordID])

        switch item {
        case .success:
            Issue.record("expected the scripted per-item conflict")
        case .failure(let error):
            #expect((error as? CKError)?.code == .serverRecordChanged)
        }
    }

    @Test("missing per-item results fail closed")
    func missingResultsFailClosed() async throws {
        let database = U4RecordingDatabase(mode: .missingResults)
        let record = try U4DatabaseFixture.immutableRecord(type: .deviceTrustRecord)

        await #expect(throws: SecretSyncCloudKitError.incompleteModifyResults) {
            _ = try await database.modifySecretSyncRecords(
                saving: [record],
                digester: U4DatabaseFixture.digester
            )
        }
    }

    @Test("cross-zone and mixed-mutation batches are prohibited")
    func invalidBatchesFailClosed() async throws {
        let database = U4RecordingDatabase()
        let control = try U4DatabaseFixture.immutableRecord(type: .deviceTrustRecord)
        let payload = try U4DatabaseFixture.immutableRecord(type: .sealedPayload)
        let head = try CKRecordMapping.secretSyncScopeHeadRecord(
            SecretSyncCloudKitScopeHead(
                scopeID: SecretScopeID(U4DatabaseFixture.uuid(0x61)),
                policyEpoch: 1,
                headCommitDigest: U4DatabaseFixture.digest(0x62),
                policyDigest: U4DatabaseFixture.digest(0x63)
            )
        )

        await #expect(throws: SecretSyncCloudKitError.invalidWriteBatch) {
            _ = try await database.modifySecretSyncRecords(
                saving: [control, payload],
                digester: U4DatabaseFixture.digester
            )
        }
        await #expect(throws: SecretSyncCloudKitError.invalidWriteBatch) {
            _ = try await database.modifySecretSyncRecords(
                saving: [control, head],
                digester: U4DatabaseFixture.digester
            )
        }
        await #expect(throws: SecretSyncCloudKitError.invalidWriteBatch) {
            _ = try await database.modifySecretSyncRecords(
                saving: [],
                digester: U4DatabaseFixture.digester
            )
        }
    }

    @Test("raw records cannot bypass digest recomputation")
    func manufacturedDigestMismatchFailsClosed() async throws {
        let database = U4RecordingDatabase()
        let record = try U4DatabaseFixture.immutableRecord(type: .deviceTrustRecord)
        record["ss_canonical_bytes"] = Data([0x01, 0x02, 0x03]) as NSData

        await #expect(throws: SecretSyncCloudKitError.digestMismatch) {
            _ = try await database.modifySecretSyncRecords(
                saving: [record],
                digester: U4DatabaseFixture.digester
            )
        }
        #expect(await database.capture == nil)
    }
}

private actor U4RecordingDatabase: CloudKitDatabaseProtocol {
    enum Mode: Sendable {
        case success
        case perItemConflict
        case missingResults
    }

    struct Capture: Sendable {
        let savedIDs: [CKRecord.ID]
        let deletedIDs: [CKRecord.ID]
        let savePolicy: CKModifyRecordsOperation.RecordSavePolicy
        let atomically: Bool
    }

    let mode: Mode
    private(set) var capture: Capture?

    init(mode: Mode = .success) {
        self.mode = mode
    }

    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> (
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]
    ) {
        capture = Capture(
            savedIDs: recordsToSave.map(\.recordID),
            deletedIDs: recordIDsToDelete,
            savePolicy: savePolicy,
            atomically: atomically
        )
        switch mode {
        case .success:
            return (
                Dictionary(uniqueKeysWithValues: recordsToSave.map {
                    ($0.recordID, .success($0))
                }),
                Dictionary(uniqueKeysWithValues: recordIDsToDelete.map {
                    ($0, .success(()))
                })
            )
        case .perItemConflict:
            let error = CKError(.serverRecordChanged)
            return (
                Dictionary(uniqueKeysWithValues: recordsToSave.map {
                    ($0.recordID, .failure(error))
                }),
                [:]
            )
        case .missingResults:
            return ([:], [:])
        }
    }

    func fetch(
        withRecordIDs _: [CKRecord.ID]
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        [:]
    }

    func fetchZoneChanges(
        inZoneWith _: CKRecordZone.ID,
        since _: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        CloudKitZoneChanges(modifiedRecords: [], deletedRecordIDs: [], changeToken: nil)
    }

    func modifyRecordZones(
        saving _: [CKRecordZone],
        deleting _: [CKRecordZone.ID]
    ) async throws -> (
        saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
        deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
    ) {
        ([:], [:])
    }

    func modifySubscriptions(
        saving _: [CKSubscription],
        deleting _: [CKSubscription.ID]
    ) async throws -> (
        saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>],
        deleteResults: [CKSubscription.ID: Result<Void, any Error>]
    ) {
        ([:], [:])
    }
}

private enum U4DatabaseFixture {
    static var digester: some SecretSyncDigesting { Digester() }

    static func immutableRecord(type: SecretSyncCloudKitRecordType) throws -> CKRecord {
        let bytes = try SecretSyncCanonicalEncoding.encode(
            domain: try #require(type.canonicalDomain),
            fields: minimumFields(for: type)
        )
        let digester = Digester()
        return try CKRecordMapping.secretSyncRecord(
            SecretSyncCloudKitImmutableRecord(
                type: type,
                digest: digester.digest(canonicalBytes: bytes),
                canonicalBytes: bytes,
                digester: digester
            )
        )
    }

    static func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (
            byte, byte, byte, byte, byte, byte, byte, byte,
            byte, byte, byte, byte, byte, byte, byte, byte
        ))
    }

    static func digest(_ byte: UInt8) throws -> SecretRecordDigest {
        try SecretRecordDigest(bytes: Data(repeating: byte, count: 32))
    }

    private static func minimumFields(
        for type: SecretSyncCloudKitRecordType
    ) -> [SecretSyncCanonicalField] {
        let id = Data(uuid(0x21).uuidString.lowercased().utf8)
        let digest = Data(repeating: 0x11, count: 32)
        let u64 = Data([0, 0, 0, 0, 0, 0, 0, 1])
        switch type {
        case .deviceTrustRecord:
            return [
                .init(tag: 1, value: digest), .init(tag: 2, value: id),
                .init(tag: 3, value: id), .init(tag: 4, value: Data("trusted".utf8)),
                .init(tag: 5, value: u64),
            ]
        case .deviceEnrollmentProof:
            return [
                .init(tag: 1, value: id), .init(tag: 2, value: Data([1])),
                .init(tag: 3, value: Data([2])), .init(tag: 4, value: Data([3])),
                .init(tag: 5, value: id),
            ]
        case .sealedPayload:
            return [
                .init(tag: 1, value: id), .init(tag: 2, value: digest),
                .init(tag: 3, value: u64), .init(tag: 4, value: digest),
                .init(tag: 5, value: id), .init(tag: 6, value: Data([0, 1])),
                .init(tag: 7, value: Data([0xAA])),
            ]
        default:
            return []
        }
    }

    private struct Digester: SecretSyncDigesting {
        func digest(canonicalBytes: Data) throws -> SecretRecordDigest {
            var output = [UInt8](repeating: 0, count: 32)
            for (index, byte) in canonicalBytes.enumerated() {
                output[index % 32] &+= byte
            }
            return try SecretRecordDigest(bytes: Data(output))
        }
    }
}
