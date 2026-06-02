// audit/mod.rs — Rust mirror of the unified audit log.
//
// Mission GLK-03. Parity-gated against the Swift reference under
// `GeniusLocusKit/Sources/GeniusLocusKit/Audit/`. The conformance
// shape is the same set of types and the same byte-stable content
// hash, exercised by `tests/audit_parity.rs`.
//
// Cookbook references (engineering cookbook v0.36):
//   §5.1  G-Set CRDT semantics
//   §5.2  HLC total order
//   §5.3  Projection rules — last-writer-wins per field-path
//   §5.5  Reconstruction from audit log

pub mod log;
pub mod projection;
pub mod recovery;

pub use log::{
    sha256, AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog, UnifiedAuditValue,
    UnifiedAuditVerb,
};
pub use projection::{
    AuditProjectionFold, UnifiedProjection, UnifiedProjectionKey, UnifiedRowProjection,
};
pub use recovery::{AuditRecovery, AuditRecoveryDivergence, AuditRecoveryResult, RowMismatch};
