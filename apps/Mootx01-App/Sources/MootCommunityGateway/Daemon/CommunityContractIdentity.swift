import Foundation

/// Exact identity of the frozen Community 1.1 application/daemon contract.
///
/// These values are mirrored from `contracts/community/1.1` and locked there
/// by `verify_contract.py`. A production caller is not released to Community
/// features until the authenticated daemon reports all four values and the
/// descriptor-bound daemon and estate identities exactly.
public enum CommunityContractIdentity {
    public static let contractID = "com.simple-machines.mootx01.community"
    public static let contractVersion = "1.1.0"
    public static let fixtureDigestAlgorithm = "sha256"
    public static let fixtureDigest = "90c7877e0ecdddc90d8b35810a8f7f20232da37c65d5ad0c6b4861546e199d22"
    public static let method = "moot_community_contract_identity"

    public enum Verdict: Sendable, Equatable {
        case accepted
        case incompatible
        case failed
    }

    /// Verify the contract and bind its response to the descriptor that passed
    /// the authenticated readiness ceremony. Unknown, incomplete, or widened
    /// responses fail; version, digest, or identity disagreement is explicitly
    /// incompatible and never negotiated down.
    public static func verify(
        caller: any MootEstateCalling,
        descriptor: DaemonDescriptor
    ) async -> Verdict {
        let call = await caller.callToolFull(method, arguments: [:])
        guard !call.isError, let object = call.structured?.objectValue else {
            return .failed
        }
        let expectedKeys: Set<String> = [
            "contractID",
            "contractVersion",
            "fixtureDigestAlgorithm",
            "fixtureDigest",
            "daemonInstanceID",
            "estateID",
        ]
        guard Set(object.keys) == expectedKeys,
              let contractID = object["contractID"]?.stringValue,
              let contractVersion = object["contractVersion"]?.stringValue,
              let digestAlgorithm = object["fixtureDigestAlgorithm"]?.stringValue,
              let digest = object["fixtureDigest"]?.stringValue,
              let daemonInstanceRaw = object["daemonInstanceID"]?.stringValue,
              let daemonInstanceID = UUID(uuidString: daemonInstanceRaw),
              let estateRaw = object["estateID"]?.stringValue,
              let estateID = UUID(uuidString: estateRaw) else {
            return .failed
        }
        guard contractID == Self.contractID,
              contractVersion == Self.contractVersion,
              digestAlgorithm == Self.fixtureDigestAlgorithm,
              digest == Self.fixtureDigest,
              daemonInstanceID == descriptor.instanceIdentifier,
              estateID == descriptor.estateIdentifier else {
            return .incompatible
        }
        return .accepted
    }
}
