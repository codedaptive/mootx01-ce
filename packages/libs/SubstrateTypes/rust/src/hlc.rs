// hlc.rs
//
// Hybrid Logical Clock per cookbook § 5.2.
//
// HLC gives partial ordering across replicas of an estate without
// requiring synchronized clocks. Every audit row carries an HLC
// timestamp; comparison is lexicographic on (physical, logical,
// node) and total within an estate.
//
// This is the mechanism that lets two replicas of an estate
// (e.g. iPhone + Mac sharing via CloudKit) exchange audit log
// entries in any order and project to identical visible state.
// The convergence proof in cookbook § 5.4 depends on HLC
// providing a total ordering that all replicas agree on.
//
// CONSTITUTIONAL: HLC supersedes v0.35's wall-clock `updated_at`
// ordering. Existing v0.35 audit rows are upgraded at migration
// by treating `updated_at` as physical_time, logical_count = 0,
// and node_id = legacy_node_id (cookbook § 16.2).

use std::cmp::Ordering;
use std::convert::TryInto;

/// Hybrid Logical Clock timestamp. Ordering is lexicographic over
/// (physical_time, logical_count, node_id), giving a total order
/// within an estate.
///
/// `physical_time`: wall-clock milliseconds since Unix epoch. May
///   be skewed across replicas; HLC tolerates skew up to the
///   logical-component cap.
///
/// `logical_count`: monotonic counter that increments when
///   physical time does not advance (or when receiving a message
///   with a higher physical time than ours).
///
/// `node_id`: per-replica identifier so two replicas with
///   identical (physical, logical) still order deterministically.
///   Typically the low 32 bits of a UUID-derived hash.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct HLC {
    #[cfg_attr(feature = "serde-support", serde(rename = "physicalTime"))]
    pub physical_time: i64,
    #[cfg_attr(feature = "serde-support", serde(rename = "logicalCount"))]
    pub logical_count: i32,
    // Swift's auto-synthesized Codable uses the literal property
    // name as the JSON key, so Swift HLC emits "nodeID" with
    // uppercase "ID" (not the camelCase-default "nodeId"). Match
    // exactly via an explicit per-field rename.
    #[cfg_attr(feature = "serde-support", serde(rename = "nodeID"))]
    pub node_id: i32,
}

impl HLC {
    pub const ZERO: HLC = HLC {
        physical_time: 0,
        logical_count: 0,
        node_id: 0,
    };

    pub const fn new(physical_time: i64, logical_count: i32, node_id: i32) -> Self {
        Self { physical_time, logical_count, node_id }
    }

    /// Alias for `HLC::ZERO` (callable form for symmetry with Swift
    /// HLC.zero).
    pub fn zero() -> Self { Self::ZERO }

    /// Advance the logical counter by one. The physical clock is
    /// untouched; node id preserved.
    pub fn advanced(self) -> Self {
        Self {
            physical_time: self.physical_time,
            logical_count: self.logical_count.wrapping_add(1),
            node_id: self.node_id,
        }
    }

    /// Physical time, converted from the canonical milliseconds-
    /// since-epoch representation to whole seconds.
    pub fn physical_seconds_since_epoch(self) -> i64 {
        self.physical_time / 1000
    }

    /// Pack to a canonical 8-byte representation per cookbook
    /// § 12.3 (wire-format for tier contribution fingerprints):
    ///
    ///   top 8 bits     = node_id (low 8 bits)
    ///   next 16 bits   = logical_count (low 16 bits)
    ///   bottom 40 bits = physical_time (low 40 bits)
    ///
    /// 40 bits of milliseconds covers ~34 years from a 1970 epoch
    /// or ~17 years past it; production systems re-rebase the epoch
    /// every decade. The wire_bytes() / from_wire_bytes() pair
    /// (16 bytes) is the lossless format; packed() is the lossy
    /// compact form federation messages use.
    pub fn packed(self) -> u64 {
        let node = (self.node_id as u64) & 0xFF;
        let logical = (self.logical_count as u64) & 0xFFFF;
        let phys = (self.physical_time as u64) & 0xFF_FFFF_FFFF;
        (node << 56) | (logical << 40) | phys
    }

    /// Recover an HLC from its 8-byte packed form. Inverse of
    /// `packed()`. Top-bit sign extension of physical_time is not
    /// performed; values are non-negative milliseconds.
    pub fn from_packed(packed: u64) -> Self {
        let node = ((packed >> 56) & 0xFF) as i8 as i32;
        let logical = ((packed >> 40) & 0xFFFF) as i32;
        let phys = (packed & 0xFF_FFFF_FFFF) as i64;
        Self::new(phys, logical, node)
    }

    /// 16-byte little-endian wire format: 8 bytes physical_time,
    /// 4 bytes logical_count, 4 bytes node_id.
    pub fn wire_bytes(&self) -> [u8; 16] {
        let mut out = [0u8; 16];
        out[0..8].copy_from_slice(&self.physical_time.to_le_bytes());
        out[8..12].copy_from_slice(&self.logical_count.to_le_bytes());
        out[12..16].copy_from_slice(&self.node_id.to_le_bytes());
        out
    }

    pub fn from_wire_bytes(bytes: &[u8]) -> Result<Self, HLCError> {
        if bytes.len() != 16 {
            return Err(HLCError::InvalidWireLength(bytes.len()));
        }
        Ok(Self::new(
            i64::from_le_bytes(bytes[0..8].try_into().unwrap()),
            i32::from_le_bytes(bytes[8..12].try_into().unwrap()),
            i32::from_le_bytes(bytes[12..16].try_into().unwrap()),
        ))
    }
}

impl Ord for HLC {
    fn cmp(&self, other: &Self) -> Ordering {
        self.physical_time.cmp(&other.physical_time)
            .then(self.logical_count.cmp(&other.logical_count))
            .then(self.node_id.cmp(&other.node_id))
    }
}

impl PartialOrd for HLC {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HLCError {
    InvalidWireLength(usize),
}

impl std::fmt::Display for HLCError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidWireLength(n) => {
                write!(f, "HLC wire length must be 16, got {n}")
            }
        }
    }
}

impl std::error::Error for HLCError {}

/// Per-replica HLC generator. Three operations follow the HLC
/// paper (Kulkarni et al., 2014):
///
///   send(now):            "I'm emitting an event at wall time `now`."
///   receive(remote, now): "I'm consuming an event; advance local."
///   current_time():       read-only snapshot.
///
/// Thread-safety: the substrate's audit-writer holds the generator
/// behind an actor / mutex; this struct itself is not internally
/// synchronized.
#[derive(Debug, Clone)]
pub struct HLCGenerator {
    pub node_id: i32,
    last_physical: i64,
    last_logical: i32,
}

impl HLCGenerator {
    pub fn new(node_id: i32) -> Self {
        Self { node_id, last_physical: 0, last_logical: 0 }
    }

    pub fn with_state(node_id: i32, last_physical: i64, last_logical: i32) -> Self {
        Self { node_id, last_physical, last_logical }
    }

    /// Generate a timestamp for a locally-originated event. `now`
    /// is the current wall-clock time in milliseconds.
    pub fn send(&mut self, now: i64) -> HLC {
        if now > self.last_physical {
            self.last_physical = now;
            self.last_logical = 0;
        } else {
            // Physical clock didn't advance; bump logical.
            self.last_logical = self.last_logical.wrapping_add(1);
        }
        HLC::new(self.last_physical, self.last_logical, self.node_id)
    }

    /// Update local state from a remote timestamp received over
    /// the network (e.g. CloudKit sync), then generate the local
    /// timestamp at which we processed the receive. `now` is our
    /// current wall-clock.
    pub fn receive(&mut self, remote: &HLC, now: i64) -> HLC {
        let max_physical = self.last_physical.max(remote.physical_time).max(now);

        if max_physical == self.last_physical && max_physical == remote.physical_time {
            self.last_logical = self.last_logical.max(remote.logical_count)
                .wrapping_add(1);
        } else if max_physical == self.last_physical {
            self.last_logical = self.last_logical.wrapping_add(1);
        } else if max_physical == remote.physical_time {
            self.last_logical = remote.logical_count.wrapping_add(1);
        } else {
            // max_physical == now: physical advanced past both.
            self.last_logical = 0;
        }
        self.last_physical = max_physical;
        HLC::new(self.last_physical, self.last_logical, self.node_id)
    }

    /// Read-only snapshot of the current generator state.
    pub fn current_time(&self) -> HLC {
        HLC::new(self.last_physical, self.last_logical, self.node_id)
    }
}

// Properties
//
//   monotonic per replica: every send() returns an HLC > previous.
//   causality preserved:    if A → B (send before receive on
//                           another replica), then HLC(A) < HLC(B).
//   total order:            any two HLCs compare unambiguously.
//   skew tolerance:         physical-clock skew up to ~i32::MAX
//                           milliseconds (~25 days); beyond that
//                           logical counter wraps (via `wrapping_add`)
//                           and causality assertions weaken.
//
// In practice the substrate runs an NTP-synchronized wall clock
// across replicas; skew is bounded by seconds and HLC behaves
// indistinguishably from wall-clock with conflict resolution.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn monotonic_within_same_millisecond() {
        let mut g = HLCGenerator::new(7);
        let a = g.send(1000);
        let b = g.send(1000);
        let c = g.send(1000);
        assert!(a < b);
        assert!(b < c);
        assert_eq!(a.physical_time, 1000);
        assert_eq!(b.physical_time, 1000);
        assert_eq!(c.physical_time, 1000);
        assert_eq!(a.logical_count, 0);
        assert_eq!(b.logical_count, 1);
        assert_eq!(c.logical_count, 2);
    }

    #[test]
    fn physical_advance_resets_logical() {
        let mut g = HLCGenerator::new(7);
        let _ = g.send(1000);
        let _ = g.send(1000);
        let c = g.send(2000);
        assert_eq!(c.physical_time, 2000);
        assert_eq!(c.logical_count, 0);
    }

    #[test]
    fn receive_advances_past_remote() {
        let mut g = HLCGenerator::new(7);
        let _ = g.send(1000);
        let remote = HLC::new(5000, 10, 99);
        let t = g.receive(&remote, 500);
        // Our local wall (500) is behind both ours (1000) and remote (5000),
        // so max_physical = remote.physical_time = 5000.
        assert_eq!(t.physical_time, 5000);
        // logical = remote.logical + 1 = 11.
        assert_eq!(t.logical_count, 11);
        assert_eq!(t.node_id, 7);
    }

    #[test]
    fn total_order_uses_node_id_as_tiebreaker() {
        let a = HLC::new(1000, 5, 1);
        let b = HLC::new(1000, 5, 2);
        assert!(a < b);
    }

    #[test]
    fn wire_round_trip() {
        let t = HLC::new(0x1234_5678_9ABC, 42, 7);
        let wire = t.wire_bytes();
        let back = HLC::from_wire_bytes(&wire).unwrap();
        assert_eq!(t, back);
    }

    #[test]
    fn causality_preserved_across_replicas() {
        // Replica A sends event X. Replica B receives X then sends Y.
        // HLC(X) < HLC(Y) must hold.
        let mut a = HLCGenerator::new(1);
        let mut b = HLCGenerator::new(2);
        let x = a.send(1000);
        let _ = b.receive(&x, 900);  // B's clock is slightly behind
        let y = b.send(900);
        assert!(x < y);
    }
}
