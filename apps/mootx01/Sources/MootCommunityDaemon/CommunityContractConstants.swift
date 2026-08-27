// Wave A1b — frozen community-contract constants.
//
// These three string constants mirror the corresponding fields in
// contracts/community/1.1/contract.json. They are embedded here so
// the daemon can answer `moot_community_contract_identity` without
// reading the contracts directory at runtime.
//
// `fixtureDigest` is verified by CommunityContractTests.A1b-CT1, which
// recomputes the SHA-256 fixture-bundle digest using the same algorithm
// as verify_contract.py and asserts it equals the frozen value here AND
// equals the golden value in contracts/community/1.1/fixture-bundle.sha256.
//
// DO NOT edit these constants without also running verify_contract.py to
// confirm the digest is still correct. A mismatch between the embedded
// constant and the live fixture files is caught immediately by the test
// suite and blocks the build.

/// Frozen constants for the community/1.1 contract, matching
/// contracts/community/1.1/contract.json exactly.
public enum CommunityContractConstants {

    /// JSON-LD-style identifier for this contract family.
    /// Source: contracts/community/1.1/contract.json "contractID".
    public static let contractID = "com.simple-machines.mootx01.community"

    /// Semantic version of the contract definition shipped in 1.1.
    /// Source: contracts/community/1.1/contract.json "contractVersion".
    public static let contractVersion = "1.1.0"

    /// The hash algorithm used for the fixture-bundle digest.
    /// Source: contracts/community/1.1/contract.json "fixtureDigestAlgorithm".
    public static let fixtureDigestAlgorithm = "sha256"

    /// SHA-256 hex digest of the 1.1 fixture bundle, computed by
    /// verify_contract.py and frozen at contract-commit time.
    ///
    /// Algorithm: SHA-256 over the concatenation of:
    ///   (relative-path-bytes + "\n" + canonical-JSON-bytes + "\n")
    /// for each file in order: contract.json, then fixtures/*.json sorted
    /// alphabetically. "Canonical JSON" means json.dumps with sort_keys=True,
    /// ensure_ascii=False, separators=(",",":") — the same as Python's
    /// json.dumps canonical form.
    ///
    /// CommunityContractTests.A1b-CT1 recomputes this value in Swift and
    /// asserts equality with this constant AND with the value in
    /// contracts/community/1.1/fixture-bundle.sha256.
    public static let fixtureDigest =
        "90c7877e0ecdddc90d8b35810a8f7f20232da37c65d5ad0c6b4861546e199d22"
}
