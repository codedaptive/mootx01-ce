import Foundation
import OSLog
import SubstrateKernel

/// Custody of scope keys for one estate's issued grants.
///
/// Implements the three custody modes:
///
/// - **Mode 1 (mediated):** the scope key is derived at issue and held
///   inside the vault. It is never returned to the caller. Every read
///   is a live `access(grant:now:)` request the vault can refuse;
///   clawback is cryptographic — `revoke` drops the key so no further
///   session key can be minted.
/// - **Mode 2 (handed-over):** the scope key is derived once from the
///   estate's Ed25519 identity and returned to the caller at issue. The
///   vault keeps no copy, so it cannot serve `access` and clawback is
///   best-effort (recorded, not enforced).
/// - **Mode 3 (decay-derived):** with confirmed IP clearance the verb
///   surface permits issuance, so this mode reaches `issue`. The scope
///   key is reconstructed by Lagrange interpolation over K-of-N shares
///   (`LagrangeDecayKey`) and returned to the caller at issue; the vault
///   retains NOTHING (Appendix B.3 no-vault posture). Subsequent reads
///   reconstruct from shares until they drift past threshold K.
/// - **Mode 4 (time-aging):** the scope key is derived once and handed to
///   the recipient (same derivation as mode 2); the vault retains nothing.
///   The decay is a recall-path *content-level* attenuation, not a key
///   mechanic — the key stays valid while the grant's effective content
///   level halves over time toward its floor (`DecayPolicy`).
///
/// Scope keys live only in memory (per the mediated-custody contract);
/// they are not written to disk by this type.
public actor ScopeKeyVault {

    private static let logger = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")

    /// Mode-1 scope keys held in custody, keyed by grant id.
    /// 32-byte raw key material (AES-256 width). Stored as [UInt8] so the
    /// grant surface carries no CryptoKit dependency; callers that need a
    /// CryptoKit SymmetricKey can wrap with SymmetricKey(data:).
    private var mediatedKeys: [UUID: [UInt8]] = [:]

    /// Grant ids that have been revoked. Checked first in `access` so a
    /// revoked grant fails closed even if a key somehow lingers.
    private var revoked: Set<UUID> = []

    public init() {}

    // MARK: - Issue

    /// Derive the scope key for a freshly issued grant.
    ///
    /// - Mode 1: derive, retain in the vault, return `nil` (the key
    ///   never leaves custody).
    /// - Mode 2: derive, return to the caller, retain nothing.
    /// - Mode 3 (decay-derived): reconstruct the key from the share
    ///   provider, return it to the caller, retain NOTHING — the no-vault
    ///   guarantee. Reconstruction runs at the grant's issue instant, when
    ///   every share is still valid, so it always succeeds at issue.
    ///
    /// Modes 1 and 2 derive with HKDF-SHA256 (in-repo `GrantHKDF`) over the
    /// estate's Ed25519 identity key's raw bytes as input keying material,
    /// bound to the grant id (and, for mode 2, the grantee) via the `info`
    /// parameter so two grants never share a scope key. Mode 3's key comes
    /// from the Lagrange reconstruction, not HKDF.
    ///
    /// The parameter is the raw 32-byte Ed25519 private key (not a CryptoKit
    /// type) so this method carries no CryptoKit dependency; the signing op
    /// that produces the grant signature stays in the caller (`VerbSurface`).
    func issue(grant: Grant, identityKeyRawBytes: [UInt8]) throws -> Data? {
        switch grant.custodyMode {
        case .mediated:
            let key = Self.deriveKey(ikm: identityKeyRawBytes, info: Self.info(grantID: grant.id, grantee: nil))
            mediatedKeys[grant.id] = key
            return nil
        case .handedOver:
            let key = Self.deriveKey(ikm: identityKeyRawBytes, info: Self.info(grantID: grant.id, grantee: grant.granteeEstateID))
            return Data(key)
        case .decayDerived(let threshold, let totalShares, let driftRate, _):
            // Seed the reference share provider deterministically from the
            // estate identity key raw bytes and the grant id, so this grant's
            // decay-derived key is reproducible on demand and unique per
            // grant. (The production estate-internal share feed is out of
            // scope — ENC-03; this is the conformance reference provider.)
            let seed = Data(identityKeyRawBytes) + Data(grant.id.uuidString.utf8)
            let provider = ReferenceDecayShareProvider(
                threshold: threshold,
                totalShares: totalShares,
                driftRate: driftRate,
                createdAt: grant.issuedAt,
                seed: seed
            )
            let keyBytes = try LagrangeDecayKey.reconstruct(
                threshold: threshold, provider: provider, now: grant.issuedAt
            )
            // Retain nothing: no entry in mediatedKeys. Reads reconstruct
            // from shares until they drift past threshold K.
            return Data(keyBytes)
        case .timeAging:
            // Mode 4: the scope key is derived once and handed to the recipient
            // exactly as mode 2 — the time-aging policy attenuates the
            // *content level* on the recall path, not the key itself. Binding
            // the key to the grantee (like mode 2) keeps a mode-4 key from
            // being usable by any other estate. The vault retains nothing.
            let key = Self.deriveKey(ikm: identityKeyRawBytes, info: Self.info(grantID: grant.id, grantee: grant.granteeEstateID))
            return Data(key)
        }
    }

    // MARK: - Access (mode 1)

    /// Whether the vault currently holds a mode-1 scope key for `id`.
    public func holdsScopeKey(for id: UUID) -> Bool {
        mediatedKeys[id] != nil
    }

    /// Serve a mode-1 live read: return a session key derived from the
    /// held scope key, after checking the grant is neither revoked nor
    /// expired.
    ///
    /// Checks run fail-closed and in order: revoked first, then expired,
    /// then key presence. A mode-2 grant (no held key) raises
    /// `scopeKeyUnavailable`, matching the contract that the originating
    /// estate cannot serve a live read for a handed-over key.
    public func access(grant: Grant, now: Date) throws -> Data {
        if revoked.contains(grant.id) {
            throw GrantError.grantRevoked(id: grant.id)
        }
        if let expiry = grant.lifetime.expiry(issuedAt: grant.issuedAt), now > expiry {
            throw GrantError.grantExpired(id: grant.id)
        }
        guard let key = mediatedKeys[grant.id] else {
            throw GrantError.scopeKeyUnavailable(id: grant.id)
        }
        // Derive a per-read session key from the held scope key so the
        // long-lived scope key itself is never exposed to the read path.
        let session = Self.deriveKey(
            ikm: key,
            info: [UInt8]("session|\(grant.id.uuidString)".utf8)
        )
        return Data(session)
    }

    // MARK: - Revoke

    /// Cryptographic clawback for mode 1, best-effort record for mode 2.
    /// Drops any held scope key and marks the grant revoked so future
    /// `access` calls fail closed. Safe to call for a mode-2 grant the
    /// vault never held a key for.
    public func revoke(grantID: UUID) {
        mediatedKeys[grantID] = nil
        revoked.insert(grantID)
    }

    // MARK: - Derivation

    /// HKDF-SHA256 (in-repo `GrantHKDF`) to a 256-bit key (32 bytes).
    ///
    /// A fixed salt is used because the input keying material (the estate's
    /// Ed25519 raw private key bytes) is already high-entropy; per-grant
    /// separation comes from the `info` binding, not the salt. The salt string
    /// and the HKDF construction are byte-identical to the Rust port in
    /// `genius_locus_kit::grants::scope_key_vault::derive_key`, so a scope
    /// key derived on Apple Silicon is identical to one derived on Linux.
    private static func deriveKey(ikm: [UInt8], info: [UInt8]) -> [UInt8] {
        GrantHKDF.deriveKey(
            inputKeyMaterial: ikm,
            salt: "mootx01.grant.scope-key.v1",
            info: info,
            outputByteCount: 32
        )
    }

    /// The HKDF `info` binding for a grant's scope key. Includes the
    /// grantee for mode 2 so a handed-over key is bound to its recipient.
    private static func info(grantID: UUID, grantee: UUID?) -> [UInt8] {
        if let grantee {
            return [UInt8]("scope|\(grantID.uuidString)|\(grantee.uuidString)".utf8)
        }
        return [UInt8]("scope|\(grantID.uuidString)".utf8)
    }
}
