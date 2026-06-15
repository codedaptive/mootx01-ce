//! DiaryEntry operational value types. Ports `DiaryOperational.swift`.
//!
//! Per `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 5.6.
//!
//! Four typed axes describe a diary entry's event semantics and
//! operational state, packed into the per-row `operational_bitmap`
//! Int64 column.
//!
//! ## Diary operational layout (low-to-high)
//!
//! ```text
//! bits 0–3   DiaryEventClass      (4 bits, contiguous, 12 cases)
//! bits 4–6   DiarySeverity        (3 bits, scale-gapped, 0/2/4/6)
//! bits 7–9   DiaryActorClass      (3 bits, contiguous, 5 cases)
//! bits 10–12 DiaryBatchMembership (3 bits, contiguous, 4 cases)
//! bit  13    requires_followup    (1 bit, exclusive)
//! bits 14–63 reserved
//! ```

use crate::diary_entry::DiaryEntry;
use std::cmp::Ordering;
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
use substrate_kernel::bit_field;

// MARK: - DiaryEventClass

/// What kind of substrate event this diary entry records. Per spec
/// § 5.6, bits 0–3. Contiguous encoding, 12 cases used, raw values
/// 12–15 reserved.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum DiaryEventClass {
    Capture = 0,         // a drawer or KGFact was written
    Mutation = 1,        // an adjective bitmap field was updated
    Withdraw = 2,        // state moved to the withdrew cluster
    Expunge = 3,         // hard removal from the estate
    Propose = 4,         // a proposal was emitted
    Associate = 5,       // an association tunnel was created
    Learn = 6,           // an agent updated a belief or model
    SignalEmission = 7,  // a standing signal fired
    Maintenance = 8,     // substrate maintenance pass completed
    Migration = 9,       // data migrated in or out of estate
    Training = 10,       // training event recorded
    AuditTombstone = 11, // an audit row was tombstoned
}

impl DiaryEventClass {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from the low 4 bits. Returns `Capture` for unrecognised
    /// raw values — surfacing an unknown future event class as the
    /// default "drawer / fact was written" is the safest baseline.
    pub fn from_raw(v: i64) -> DiaryEventClass {
        match v {
            0 => DiaryEventClass::Capture,
            1 => DiaryEventClass::Mutation,
            2 => DiaryEventClass::Withdraw,
            3 => DiaryEventClass::Expunge,
            4 => DiaryEventClass::Propose,
            5 => DiaryEventClass::Associate,
            6 => DiaryEventClass::Learn,
            7 => DiaryEventClass::SignalEmission,
            8 => DiaryEventClass::Maintenance,
            9 => DiaryEventClass::Migration,
            10 => DiaryEventClass::Training,
            11 => DiaryEventClass::AuditTombstone,
            _ => DiaryEventClass::Capture,
        }
    }
}

// MARK: - DiarySeverity

/// Log severity of this diary entry. Scale-gapped encoding (0/2/4/6)
/// so future intermediate tiers can slot in without disturbing masks.
/// Per spec § 5.6, bits 4–6. Sentinels at raws 1, 3, 5, 7 fall back to
/// `Trace`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum DiarySeverity {
    Trace = 0,
    Info = 2,
    Warning = 4,
    Error = 6,
}

impl DiarySeverity {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    pub fn from_raw(v: i64) -> DiarySeverity {
        match v {
            0 => DiarySeverity::Trace,
            2 => DiarySeverity::Info,
            4 => DiarySeverity::Warning,
            6 => DiarySeverity::Error,
            _ => DiarySeverity::Trace,
        }
    }
}

impl PartialOrd for DiarySeverity {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for DiarySeverity {
    fn cmp(&self, other: &Self) -> Ordering {
        self.raw_value().cmp(&other.raw_value())
    }
}

// MARK: - DiaryActorClass

/// What kind of actor produced this diary entry. Per spec § 5.6, bits
/// 7–9. Contiguous encoding, 5 cases used, raw values 5–7 reserved.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum DiaryActorClass {
    User = 0,
    SubstrateDaemon = 1,
    McpAgent = 2,
    MigrationTool = 3,
    FederationPeer = 4,
}

impl DiaryActorClass {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a 3-bit slice. Returns `User` for unrecognised
    /// raw values — the neutral baseline.
    pub fn from_raw(v: i64) -> DiaryActorClass {
        match v {
            0 => DiaryActorClass::User,
            1 => DiaryActorClass::SubstrateDaemon,
            2 => DiaryActorClass::McpAgent,
            3 => DiaryActorClass::MigrationTool,
            4 => DiaryActorClass::FederationPeer,
            _ => DiaryActorClass::User,
        }
    }
}

// MARK: - DiaryBatchMembership

/// Whether this entry is standalone or part of a batch operation. Per
/// spec § 5.6, bits 10–12. Contiguous encoding, 4 cases used, raws 4–7
/// reserved.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum DiaryBatchMembership {
    Standalone = 0,
    BatchStart = 1,
    BatchMember = 2,
    BatchEnd = 3,
}

impl DiaryBatchMembership {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    pub fn from_raw(v: i64) -> DiaryBatchMembership {
        match v {
            0 => DiaryBatchMembership::Standalone,
            1 => DiaryBatchMembership::BatchStart,
            2 => DiaryBatchMembership::BatchMember,
            3 => DiaryBatchMembership::BatchEnd,
            _ => DiaryBatchMembership::Standalone,
        }
    }
}

// MARK: - DiaryEntry accessors

impl DiaryEntry {
    /// Decode bits 0–3 of `operational_bitmap` as a `DiaryEventClass`.
    pub fn event_class(&self) -> DiaryEventClass {
        DiaryEventClass::from_raw(bit_field::extract_field(self.operational_bitmap, 0, 4))
    }

    /// Decode bits 4–6 of `operational_bitmap` as a `DiarySeverity`.
    /// Returns `Trace` for the intentionally-gapped scale raws (1, 3,
    /// 5, 7).
    pub fn severity(&self) -> DiarySeverity {
        DiarySeverity::from_raw(bit_field::extract_field(self.operational_bitmap, 4, 3))
    }

    /// Decode bits 7–9 of `operational_bitmap` as a `DiaryActorClass`.
    pub fn actor_class(&self) -> DiaryActorClass {
        DiaryActorClass::from_raw(bit_field::extract_field(self.operational_bitmap, 7, 3))
    }

    /// Decode bits 10–12 of `operational_bitmap` as a
    /// `DiaryBatchMembership`.
    pub fn batch_membership(&self) -> DiaryBatchMembership {
        DiaryBatchMembership::from_raw(bit_field::extract_field(self.operational_bitmap, 10, 3))
    }

    /// Decode bit 13 of `operational_bitmap`. True when this entry
    /// requires a follow-up action.
    pub fn requires_followup(&self) -> bool {
        bit_field::extract_flag(self.operational_bitmap, 13)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e_with(bits: i64) -> DiaryEntry {
        let mut e = DiaryEntry::new(
            "d".to_string(),
            "a".to_string(),
            "entry".to_string(),
            "topic".to_string(),
            "wing".to_string(),
            "room".to_string(),
            0,
            "test-v1".to_string(),
        );
        e.operational_bitmap = bits;
        e
    }

    #[test]
    fn event_class_all_twelve_cases_decode_correctly() {
        let expected = [
            DiaryEventClass::Capture,
            DiaryEventClass::Mutation,
            DiaryEventClass::Withdraw,
            DiaryEventClass::Expunge,
            DiaryEventClass::Propose,
            DiaryEventClass::Associate,
            DiaryEventClass::Learn,
            DiaryEventClass::SignalEmission,
            DiaryEventClass::Maintenance,
            DiaryEventClass::Migration,
            DiaryEventClass::Training,
            DiaryEventClass::AuditTombstone,
        ];
        for (raw, want) in expected.iter().enumerate() {
            assert_eq!(e_with(raw as i64).event_class(), *want);
        }
    }

    #[test]
    fn event_class_reserved_raws_fall_back_to_capture() {
        for raw in 12..=15i64 {
            assert_eq!(e_with(raw).event_class(), DiaryEventClass::Capture);
        }
    }

    #[test]
    fn severity_decodes_scale_gapped_raws() {
        assert_eq!(e_with(0).severity(), DiarySeverity::Trace);
        assert_eq!(e_with(2 << 4).severity(), DiarySeverity::Info);
        assert_eq!(e_with(4 << 4).severity(), DiarySeverity::Warning);
        assert_eq!(e_with(6 << 4).severity(), DiarySeverity::Error);
    }

    #[test]
    fn severity_scale_gap_sentinels_fall_back_to_trace() {
        for raw in [1i64, 3, 5, 7] {
            assert_eq!(e_with(raw << 4).severity(), DiarySeverity::Trace);
        }
    }

    #[test]
    fn severity_ordering_matches_raw_values() {
        assert!(DiarySeverity::Trace < DiarySeverity::Info);
        assert!(DiarySeverity::Info < DiarySeverity::Warning);
        assert!(DiarySeverity::Warning < DiarySeverity::Error);
    }

    #[test]
    fn actor_class_decodes_bits_seven_through_nine() {
        assert_eq!(e_with(0).actor_class(), DiaryActorClass::User);
        assert_eq!(
            e_with(1 << 7).actor_class(),
            DiaryActorClass::SubstrateDaemon
        );
        assert_eq!(e_with(2 << 7).actor_class(), DiaryActorClass::McpAgent);
        assert_eq!(e_with(3 << 7).actor_class(), DiaryActorClass::MigrationTool);
        assert_eq!(
            e_with(4 << 7).actor_class(),
            DiaryActorClass::FederationPeer
        );
        // raws 5–7 reserved → User fallback
        assert_eq!(e_with(5 << 7).actor_class(), DiaryActorClass::User);
        assert_eq!(e_with(7 << 7).actor_class(), DiaryActorClass::User);
    }

    #[test]
    fn batch_membership_decodes_bits_ten_through_twelve() {
        assert_eq!(
            e_with(0).batch_membership(),
            DiaryBatchMembership::Standalone
        );
        assert_eq!(
            e_with(1 << 10).batch_membership(),
            DiaryBatchMembership::BatchStart
        );
        assert_eq!(
            e_with(2 << 10).batch_membership(),
            DiaryBatchMembership::BatchMember
        );
        assert_eq!(
            e_with(3 << 10).batch_membership(),
            DiaryBatchMembership::BatchEnd
        );
        assert_eq!(
            e_with(4 << 10).batch_membership(),
            DiaryBatchMembership::Standalone
        );
    }

    #[test]
    fn requires_followup_is_bit_thirteen() {
        assert!(!e_with(0).requires_followup());
        assert!(e_with(1 << 13).requires_followup());
        assert!(!e_with((1 << 14) | (1 << 12)).requires_followup());
    }

    #[test]
    fn reserved_high_bits_are_ignored() {
        let e = e_with((1 << 30) | (1 << 50));
        assert_eq!(e.event_class(), DiaryEventClass::Capture);
        assert_eq!(e.severity(), DiarySeverity::Trace);
        assert_eq!(e.actor_class(), DiaryActorClass::User);
        assert_eq!(e.batch_membership(), DiaryBatchMembership::Standalone);
        assert!(!e.requires_followup());
    }
}
