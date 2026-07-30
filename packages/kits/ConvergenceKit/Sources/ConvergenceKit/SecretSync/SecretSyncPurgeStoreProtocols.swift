import Foundation

/// Stable idempotency key for one requirement/category receipt.
public struct PurgeArtifactReceiptKey: Sendable, Hashable {
    public let requirementDigest: SecretRecordDigest
    public let category: PurgeArtifactCategory
    public let respondingCredentialID: DeviceCredentialID

    public init(
        requirementDigest: SecretRecordDigest,
        category: PurgeArtifactCategory,
        respondingCredentialID: DeviceCredentialID
    ) {
        self.requirementDigest = requirementDigest
        self.category = category
        self.respondingCredentialID = respondingCredentialID
    }
}

/// Structurally bound category-specific view of a signed purge receipt.
///
/// Construction proves exact record-field bindings only. A later validator
/// must still verify the receipt signature against the responding credential.
public struct PurgeArtifactCategoryReceipt: Sendable, Hashable {
    public let key: PurgeArtifactReceiptKey
    public let signedReceipt: SignedPurgeReceipt

    public init(
        requirement: PurgeRequirement,
        category: PurgeArtifactCategory,
        signedReceipt: SignedPurgeReceipt
    ) throws {
        guard
            signedReceipt.requirementDigest == requirement.recordDigest,
            signedReceipt.scopeID == requirement.scopeID,
            signedReceipt.policyEpoch == requirement.policyEpoch,
            signedReceipt.policyDigest == requirement.policyDigest,
            signedReceipt.supersededGenerationID
                == requirement.supersededGenerationID,
            signedReceipt.replacementGenerationID
                == requirement.replacementGenerationID,
            signedReceipt.respondingCredentialID
                == requirement.targetCredentialID,
            signedReceipt.signerCredentialID
                == requirement.targetCredentialID,
            requirement.requiredCategories.contains(category),
            signedReceipt.coveredCategories == requirement.requiredCategories,
            signedReceipt.status == .completed
        else {
            throw SecretSyncInterfaceError.invalidPurgeReceipt
        }
        self.key = PurgeArtifactReceiptKey(
            requirementDigest: requirement.recordDigest,
            category: category,
            respondingCredentialID: requirement.targetCredentialID
        )
        self.signedReceipt = signedReceipt
    }
}

/// Idempotent result of recording one artifact-category receipt.
public enum PurgeArtifactReceiptRecordingResult: Sendable, Hashable {
    case recorded
    case alreadyRecorded(PurgeArtifactCategoryReceipt)
}

/// Admission remains blocked until a future store proves all applicable purge.
public enum PurgeAdmissionStatus: Sendable, Hashable {
    case blocked
    case admitted
}

/// Immutable admission answer for one stable credential UUID.
///
/// The zero-argument initializer is intentionally fail-closed.
public struct PurgeAdmissionSnapshot: Sendable, Hashable {
    public let status: PurgeAdmissionStatus
    public let pendingRequirementDigests: [SecretRecordDigest]

    public init(
        status: PurgeAdmissionStatus = .blocked,
        pendingRequirementDigests: [SecretRecordDigest] = []
    ) throws {
        guard status != .admitted || pendingRequirementDigests.isEmpty else {
            throw SecretSyncInterfaceError.admissionWouldBypassPendingPurge
        }
        self.status = status
        self.pendingRequirementDigests = pendingRequirementDigests.sorted {
            $0.bytes.lexicographicallyPrecedes($1.bytes)
        }
    }
}

/// Observable fact that a target never reconnected after a requirement.
///
/// This is not a receipt and cannot satisfy the purge store's receipt method.
public struct NeverReconnectedPurgeFact: Sendable, Hashable {
    public let requirementDigest: SecretRecordDigest
    public let targetCredentialID: DeviceCredentialID

    public init(
        requirementDigest: SecretRecordDigest,
        targetCredentialID: DeviceCredentialID
    ) {
        self.requirementDigest = requirementDigest
        self.targetCredentialID = targetCredentialID
    }
}

/// Store seam for pending purge work, idempotent receipts, and admission gates.
public protocol SecretSyncPurgeStore: Sendable {
    func pendingRequirements(
        for credentialID: DeviceCredentialID
    ) async throws -> [PurgeRequirement]

    func recordArtifactReceipt(
        _ receipt: PurgeArtifactCategoryReceipt
    ) async throws -> PurgeArtifactReceiptRecordingResult

    func admissionSnapshot(
        for credentialID: DeviceCredentialID
    ) async throws -> PurgeAdmissionSnapshot
}
