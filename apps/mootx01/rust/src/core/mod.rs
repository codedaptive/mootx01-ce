//! core/mod.rs — installer-core for the Rust vertical.
//!
//! Exports: clients, daemon_client, depth, mcp_ownership, merge, paths,
//! permissions, release, sensitivity_crypto, sensitivity_hashes,
//! unlock_authority, and service — the full installer-core module set.

pub mod clients;
pub mod daemon_client;
pub mod depth;
pub mod desktop_ext;
pub mod mcp_ownership;
pub mod merge;
pub mod paths;
pub mod permissions;
pub mod release;
pub mod sensitivity_crypto;
/// Sidecar storage for per-tier PBKDF2-HMAC-SHA256 password hashes
/// (ADR-025 §2, Rust/Linux/Windows path).
pub mod sensitivity_hashes;
pub mod service;
/// Identity-verification seam for `mootx01 unlock/lock` (ADR-025 §2,
/// Rust/Linux/Windows path). Reads the sensitivity_hashes sidecar, prompts
/// for the tier-specific password with echo disabled, verifies via PBKDF2,
/// and on success POSTs to the daemon's /api/control/unlock endpoint.
pub mod unlock_authority;
