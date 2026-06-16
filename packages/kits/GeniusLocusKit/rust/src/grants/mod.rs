// grants/mod.rs — Rust port of the GeniusLocusKit grant subsystem.
//
// Mirrors the Swift surface in:
//   Sources/GeniusLocusKit/Grants/Grant.swift        → grant.rs
//   Sources/GeniusLocusKit/Grants/LagrangeDecayKey.swift → lagrange.rs
//   Sources/GeniusLocusKit/Grants/ScopeKeyVault.swift   → scope_key_vault.rs
//   Sources/GeniusLocusKit/Grants/GrantStore.swift       → grant_store.rs
//
// Conformance contract (PAR-4-GL1):
//   - GF(p) Lagrange reconstruction: byte-identical to Swift on the same K-of-N shares.
//   - HKDF-SHA256 scope-key derivation: byte-identical to Swift (same salt, info, IKM).
//   - Both assertions are verified in tests/grants_parity.rs against shared
//     cross-port conformance vectors.
//
// Crypto primitives:
//   - SHA-256: substrate_kernel::sha256::hash (FIPS 180-4, in-repo, no crates).
//   - HKDF-SHA256: substrate_kernel::hkdf::derive_key (RFC 5869, in-repo).
//   - GF(p) Lagrange: local DecayFieldElement + LagrangeDecayKey — pure Rust,
//     exact mirror of the Swift GF(2^256−189) arithmetic.
//   - Ed25519: the estate identity key's RAW bytes are HKDF IKM; no signing
//     op in this path, so no Ed25519 crate is needed.

pub mod grant;
pub mod grant_store;
pub mod lagrange;
pub mod scope_key_vault;

pub use grant::{
    CustodyMode, DecayPolicy, DriftRate, Grant, GrantError, GrantLifetime, GrantOptions, GrantScope,
    IssueGrantResult, ReSharePermission, StoredGrant,
};
pub use grant_store::{GrantStore, GrantStoreError};
pub use lagrange::{DecayFieldElement, DecayShareProvider, LagrangeDecayKey, ReferenceDecayShareProvider};
pub use scope_key_vault::ScopeKeyVault;
