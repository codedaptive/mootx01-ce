//! The integer bookkeeping behind the incremental anomaly sweep (ADR-026,
//! GeniusLocusKit spec § CHESTS). Twin of Swift `CohesionRoster.swift`; the
//! vectors in the tests pin both ports.
//!
//! WHY integers: floating-point sums depend on the order they were added
//! in, so an incremental roster and a batch recompute, or Swift and Rust,
//! would drift apart at the last bit and could flip a flag at the
//! threshold. Each pairwise similarity is quantised to 24-bit fixed point
//! once (`quantise`), and sums are exact i64 arithmetic: order-independent,
//! reversible, identical on both ports. The statistics are then f32 over
//! identical integers in the same operation order.
//!
//! The roster does no similarity computation and reads no storage. The
//! caller computes similarities in roster order and hands them in.

use crate::anomaly::AnomalyDetection;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RosterEntry {
    pub id: String,
    pub digest: String,
    pub sum: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CohesionRoster {
    /// Members in ascending id order. Every `similarities` argument below
    /// is aligned with this order.
    entries: Vec<RosterEntry>,
}

impl CohesionRoster {
    /// Similarities are quantised to 1/2²⁴; a similarity of 1.0 is `SCALE`.
    pub const SCALE: i32 = 1 << 24;

    pub fn new(mut entries: Vec<RosterEntry>) -> Self {
        entries.sort_by(|a, b| a.id.cmp(&b.id));
        Self { entries }
    }

    pub fn entries(&self) -> &[RosterEntry] {
        &self.entries
    }

    /// Quantise a similarity in 0..=1 to fixed point. Out-of-range input is
    /// clamped; NaN reads as 0.
    #[inline]
    pub fn quantise(similarity: f32) -> i32 {
        if !similarity.is_finite() {
            return 0;
        }
        let clamped = similarity.clamp(0.0, 1.0);
        (clamped * Self::SCALE as f32).round() as i32
    }

    /// Add a member. `similarities[i]` is its quantised similarity to
    /// `entries[i]` (before the add). Each existing sum gains its value; the
    /// new member's sum is their total.
    pub fn add(&mut self, id: &str, digest: &str, similarities: &[i32]) {
        assert_eq!(similarities.len(), self.entries.len(), "one similarity per existing member");
        let mut total: i64 = 0;
        for (entry, q) in self.entries.iter_mut().zip(similarities) {
            entry.sum += *q as i64;
            total += *q as i64;
        }
        let at = self.entries.iter().position(|e| e.id.as_str() > id).unwrap_or(self.entries.len());
        self.entries.insert(at, RosterEntry { id: id.to_string(), digest: digest.to_string(), sum: total });
    }

    /// Remove a member. `similarities[i]` is its quantised similarity to
    /// the i-th REMAINING member, in order. Exactly undoes the add.
    pub fn remove(&mut self, id: &str, similarities: &[i32]) {
        let Some(at) = self.entries.iter().position(|e| e.id == id) else { return };
        self.entries.remove(at);
        assert_eq!(similarities.len(), self.entries.len(), "one similarity per remaining member");
        for (entry, q) in self.entries.iter_mut().zip(similarities) {
            entry.sum -= *q as i64;
        }
    }

    /// Replace a member's content: remove with the old similarities, add
    /// with the new, under the new digest. Both lists are aligned with the
    /// roster without the member.
    pub fn replace(&mut self, id: &str, digest: &str, old_similarities: &[i32], new_similarities: &[i32]) {
        self.remove(id, old_similarities);
        self.add(id, digest, new_similarities);
    }

    /// The anomalous flag per member, in roster order: cohesion = sum /
    /// (peers × SCALE); z against the roster's mean and population standard
    /// deviation; anomalous when z ≤ −threshold. Fewer than `minimum_size`
    /// members has no cohesion baseline: every flag is false.
    pub fn flags(&self, threshold: f32, minimum_size: usize) -> Vec<(String, bool)> {
        let count = self.entries.len();
        if count < minimum_size {
            return self.entries.iter().map(|e| (e.id.clone(), false)).collect();
        }
        let peers = (count as f32 - 1.0) * Self::SCALE as f32;
        let cohesion: Vec<f32> = self.entries.iter().map(|e| e.sum as f32 / peers).collect();
        let n = count as f32;
        let mut mean: f32 = 0.0;
        for c in &cohesion { mean += *c; }
        mean /= n;
        let mut variance: f32 = 0.0;
        for c in &cohesion { let d = *c - mean; variance += d * d; }
        variance /= n;
        let stddev = variance.sqrt();
        self.entries
            .iter()
            .zip(&cohesion)
            .map(|(e, c)| (e.id.clone(), AnomalyDetection::z_score(*c, mean, stddev) <= -threshold))
            .collect()
    }
}
