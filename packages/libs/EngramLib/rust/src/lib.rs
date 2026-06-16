//! EngramLib -- product-facing API for similarity, retrieval, and
//! aggregation over 256-bit engrams.
//!
//! Wraps the GeniusLocus substrate kernel layer behind a stable
//! surface. Consumers see `Engram`, `Match`, and the `EngramLib`
//! free functions. The underlying representation and kernel
//! selection are hidden.
//!
//! `Engram` is a type alias for `substrate_types::fingerprint256::
//! Fingerprint256` -- substrate primitives (`Engram::new`,
//! `Engram::ZERO`, the bit/block accessors) are the canonical
//! surface and used directly. EngramLib does not wrap them.
//!
//! ```ignore
//! use engram_lib::{Engram, EngramLib};
//!
//! let probe = Engram::new(0xDEAD, 0xBEEF, 0xCAFE, 0xBABE);
//! let estate: Vec<Engram> = load_from_store();
//! let matches = EngramLib::find_nearest(&probe, &estate, 10);
//! ```
//!
//! All free functions are stateless and thread-safe. For hot
//! loops, use `EngramLib::session()` to hold a kernel instance.

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::fingerprint256::Fingerprint256;
use substrate_kernel::kernel::{PortableKernel, SubstrateKernel};

/// 256-bit engram. Aliased to the substrate's `Fingerprint256`
/// (four 64-bit blocks). The alias is the stable public name;
/// future substrate versions may widen the representation without
/// breaking product code. Constructors and constants come from
/// the substrate: `Engram::new(b0, b1, b2, b3)` and `Engram::ZERO`
/// are the canonical entry points.
pub type Engram = Fingerprint256;

mod matchx;
pub use matchx::Match;

/// EngramLib free functions. Stateless. Thread-safe.
pub struct EngramLib;

impl EngramLib {
    // ----- Distance -----

    /// Hamming distance between two engrams. Range: 0..=256.
    pub fn distance(a: &Engram, b: &Engram) -> u32 {
        kernel().hamming_distance_256(a, b)
    }

    /// Hamming distance from probe to every candidate. Returns a
    /// vector with the same length and indexing as `candidates`.
    /// Returns an empty vector if `candidates` is empty.
    pub fn distances(probe: &Engram, candidates: &[Engram]) -> Vec<u32> {
        if candidates.is_empty() {
            return Vec::new();
        }
        let mut out = vec![0u32; candidates.len()];
        kernel().hamming_distance_batch(probe, candidates, &mut out);
        out
    }

    // ----- Nearest neighbor -----

    /// Find the k nearest candidates to the probe by Hamming
    /// distance. Returns up to k matches sorted by distance
    /// ascending, ties broken by candidate index ascending.
    ///
    /// Returns an empty vector if `candidates` is empty or
    /// `k == 0`. Returns `min(k, candidates.len())` matches.
    pub fn find_nearest(probe: &Engram,
                        candidates: &[Engram],
                        k: usize) -> Vec<Match> {
        if k == 0 || candidates.is_empty() {
            return Vec::new();
        }
        let raw = kernel().hamming_top_k(probe, candidates, k);
        raw.into_iter()
            .map(|(idx, dist)| Match { index: idx, distance: dist })
            .collect()
    }

    /// Find the single nearest candidate. Returns `None` for an
    /// empty candidate set.
    pub fn find_nearest_one(probe: &Engram,
                            candidates: &[Engram]) -> Option<Match> {
        Self::find_nearest(probe, candidates, 1).into_iter().next()
    }

    // ----- Filtering -----

    /// Find all candidates within `max_distance` of the probe.
    /// Returns matches sorted by distance ascending, ties broken
    /// by candidate index ascending.
    pub fn find_within(probe: &Engram,
                       candidates: &[Engram],
                       max_distance: u32) -> Vec<Match> {
        if candidates.is_empty() {
            return Vec::new();
        }
        let ds = Self::distances(probe, candidates);
        let mut hits: Vec<Match> = ds.iter()
            .enumerate()
            .filter(|(_, d)| **d <= max_distance)
            .map(|(i, d)| Match { index: i, distance: *d })
            .collect();
        hits.sort();
        hits
    }

    // ----- Aggregation -----

    /// Bitwise OR-reduction across a set of engrams. Returns the
    /// substrate's canonical zero engram for an empty input.
    pub fn union(engrams: &[Engram]) -> Engram {
        kernel().or_reduce_256(engrams)
    }

    /// Pairwise OR of two engrams.
    pub fn union_pair(a: &Engram, b: &Engram) -> Engram {
        Engram::new(a.block0 | b.block0, a.block1 | b.block1, a.block2 | b.block2, a.block3 | b.block3)
    }

    // ----- Session -----

    /// Create a reusable session that holds a kernel instance.
    /// Faster for hot loops; equivalent to the free functions
    /// for one-shot calls.
    pub fn session() -> Session {
        Session::new()
    }
}

/// A long-lived session holding one kernel instance. Methods
/// mirror the free `EngramLib` functions.
pub struct Session {
    k: Box<dyn SubstrateKernel>,
}

impl Session {
    pub fn new() -> Self {
        Self { k: PortableKernel::for_current_platform() }
    }

    pub fn distance(&self, a: &Engram, b: &Engram) -> u32 {
        self.k.hamming_distance_256(a, b)
    }

    pub fn distances(&self, probe: &Engram, candidates: &[Engram]) -> Vec<u32> {
        if candidates.is_empty() {
            return Vec::new();
        }
        let mut out = vec![0u32; candidates.len()];
        self.k.hamming_distance_batch(probe, candidates, &mut out);
        out
    }

    pub fn find_nearest(&self,
                        probe: &Engram,
                        candidates: &[Engram],
                        k: usize) -> Vec<Match> {
        if k == 0 || candidates.is_empty() {
            return Vec::new();
        }
        let raw = self.k.hamming_top_k(probe, candidates, k);
        raw.into_iter()
            .map(|(idx, dist)| Match { index: idx, distance: dist })
            .collect()
    }

    pub fn find_within(&self,
                       probe: &Engram,
                       candidates: &[Engram],
                       max_distance: u32) -> Vec<Match> {
        if candidates.is_empty() {
            return Vec::new();
        }
        let ds = self.distances(probe, candidates);
        let mut hits: Vec<Match> = ds.iter()
            .enumerate()
            .filter(|(_, d)| **d <= max_distance)
            .map(|(i, d)| Match { index: i, distance: *d })
            .collect();
        hits.sort();
        hits
    }

    pub fn union(&self, engrams: &[Engram]) -> Engram {
        self.k.or_reduce_256(engrams)
    }
}

impl Default for Session {
    fn default() -> Self { Self::new() }
}

#[inline]
fn kernel() -> Box<dyn SubstrateKernel> {
    PortableKernel::for_current_platform()
}
