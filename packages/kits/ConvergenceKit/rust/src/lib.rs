//! convergence-kit
//!
//! Sync abstraction layer mirroring the Swift ConvergenceKit package.
//! Core types, wire format, SyncEngine trait, and two backends:
//! None (passthrough) and Federation (Ed25519 peer-to-peer).
//!
//! CloudKit is Apple-only and is intentionally omitted from this
//! Rust port; the Swift side handles iCloud transport.

pub mod types;
pub mod record;
pub mod engine;
pub mod none;
pub mod federation;
pub mod pairing;

pub use types::*;
pub use record::*;
pub use engine::*;
pub use none::*;
pub use federation::*;
pub use pairing::*;
