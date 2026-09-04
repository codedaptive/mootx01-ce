//! Engine types for SynapseKit.
//!
//! Lane F: foundation types (hit, key, metric, payload, resident, seam) — the
//! shared types all parallel lanes depend on. A downstream lane that needs a new
//! field on any Lane F type files an FT-1 update to Lane F rather than adding it
//! locally.
//!
//! Lane A: binary brute-force index (the conformance oracle; MIH/Lane B is gated
//! against it) + `ResidentArrayStore` (the on-disk `.vec` sidecar).
//!
//! Lane B: `MIHIndex` — exact sub-linear Hamming k-NN via Multi-Index Hashing.
//! Gated against `BruteForceIndex` (Lane A oracle) in conformance tests.
//!
//! Lane C: float lane — `FloatBruteForceIndex` (exact brute-force for Float32),
//! the float lane's production path and oracle. Dense-embedding k-NN is a
//! SynapseKit concern; persistence-kit owns no vector engine.
//!
//! Lane D: `HNSWIndex` — approximate float-lane NN via Hierarchical Navigable
//! Small World graphs (Malkov & Yashunin 2018). Activates at/above 5,000 vectors
//! per modelID partition; `FloatBruteForceIndex` remains the oracle and the active
//! index below the threshold. Farthest queries always use `FloatBruteForceIndex`.

// Lane F — foundation types
pub mod hit;
pub mod key;
pub mod metric;
pub mod payload;
pub mod resident;
pub mod seam;

// Lane A — binary brute-force oracle + sidecar persistence
pub mod brute_force;
pub mod resident_store;

// Lane B — binary MIH (Multi-Index Hashing) sub-linear exact Hamming k-NN
pub mod mih;

// Lane C — float lane implementations
pub mod float_brute_force;

// Lane D — float lane HNSW approximate nearest-neighbour index
pub mod hnsw_index;

// Lane E1 — binary ColBERT MaxSim late interaction (Exact-A exhaustive scorer)
pub mod max_sim;

// Lane F re-exports
pub use hit::{DenseHit, LaneTag};
pub use key::VectorRecordKey;
pub use metric::{BinaryMetric, DenseMetric, FloatMetric};
pub use payload::{VectorKind, VectorPayload};
pub use resident::{ModelPartitionEntry, ResidentVectorArray};
pub use seam::{DenseIndex, IndexKind, MetadataFilter, SearchDirection};
// Lane A re-exports
pub use brute_force::BruteForceIndex;
pub use resident_store::ResidentArrayStore;
// Lane B re-exports
pub use mih::{MIHBandCount, MIHIndex};
// Lane C re-exports
pub use float_brute_force::FloatBruteForceIndex;
// Lane D re-exports
pub use hnsw_index::{GraphRow, HNSWIndex, HNSW_DEFAULT_THRESHOLD};
// Lane E1 re-exports
pub use max_sim::{MaxSimHit, MaxSimScorer};

/// FNV-1a 64 over a byte slice — the `vec_hash` content-derived tie key
/// (SYNAPSEKIT_SPEC 1.9.0 B-6), shared by the binary and float engines.
/// Same content → same deterministic embedding → same bytes → same hash,
/// so tied candidates order identically across estate provisionings
/// (item UUIDs do not). Twin of Swift `fnv1a64` in ContentTieBreak.swift;
/// standard FNV-1a offset basis and prime, bit-identical across ports.
pub(crate) fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

#[cfg(test)]
mod tie_break_tests {
    /// Cross-port golden pin: the vec_hash of Fingerprint256::new(1, 0, 0, 0)'s
    /// wire bytes is this exact literal in BOTH ports (Swift twin:
    /// `fnv1a64GoldenPin` in BruteForceIndexTests.swift). A drift here means
    /// the ports' tie orders have silently diverged.
    #[test]
    fn fnv1a64_golden_pin() {
        let e = substrate_types::fingerprint256::Fingerprint256::new(1, 0, 0, 0);
        assert_eq!(super::fnv1a64(&e.wire_bytes()), 0x0729_5d91_aa94_b524);
    }
}
