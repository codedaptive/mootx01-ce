// verbs.rs
//
// The nine substrate verbs per cookbook § 10. Rust mirror of
// packages/libs/SubstrateLib/Sources/SubstrateLib/Verbs.swift.

use std::collections::HashMap;

use substrate_types::hlc::HLC;
use crate::substrate_lib_telemetry::{
    emit_verb_capture_count,
    emit_verb_mutate_count,
    emit_verb_withdraw_count,
    emit_verb_expunge_count,
    emit_verb_recall_count,
    emit_verb_reanchor_count,
};
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::{MatrixF, MatrixO, MatrixT, RowBitmaps};
// F11 consolidation (2026-05-27): the canonical RowState enum
// (cookbook §2.3 scale-gapped raws) lives in row_state.rs. This
// re-export keeps `crate::verbs::RowState` resolvable for any
// downstream that imported it from here historically; new code
// should `use crate::row_state::RowState` directly.
pub use crate::row_state::RowState;

// Phase 6.3 (decision 2026-05-28 §6.6): NounType and
// LatticeAnchor moved to substrate-types. Re-exported here so
// the existing `crate::verbs::NounType` / `crate::verbs::LatticeAnchor`
// paths in audit_gate.rs and other consumers keep resolving.
pub use substrate_types::{LatticeAnchor, NounType};

// ============================================================
// Row layout (NounType + LatticeAnchor live in substrate-types)
// ============================================================

// Phase 6.6 (decision 2026-05-28 §6.6): RowId + Row moved to
// substrate-types. Re-exported so `crate::verbs::Row` keeps
// resolving for code that historically imported it from here.
pub use substrate_types::row::{Row, RowId};

// ============================================================
// Errors
// ============================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubstrateError {
    InvalidStateTransition { from: RowState, to: RowState, verb: String },
    MissingLatticeAnchor,
    InvalidNounType,
    RowNotFound(RowId),
    ForbiddenStateCombination(String),
    AlreadyTombstoned(RowId),
}

impl std::fmt::Display for SubstrateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidStateTransition { from, to, verb } => {
                write!(f, "invalid transition {from:?} --{verb}--> {to:?}")
            }
            Self::MissingLatticeAnchor => write!(f, "missing lattice anchor (I-16)"),
            Self::InvalidNounType => write!(f, "invalid noun type"),
            Self::RowNotFound(id) => write!(f, "row not found: {id:?}"),
            Self::ForbiddenStateCombination(s) => write!(f, "forbidden combination: {s}"),
            Self::AlreadyTombstoned(id) => write!(f, "row already tombstoned: {id:?}"),
        }
    }
}

impl std::error::Error for SubstrateError {}

// ============================================================
// Audit event
// ============================================================

// Phase 6.6 (decision 2026-05-28 §6.6): AuditEvent moved to
// substrate-types. Re-exported so `crate::verbs::AuditEvent` keeps
// resolving. The canonical shared type is now in
// packages/libs/SubstrateTypes/rust/src/audit_event.rs.
pub use substrate_types::audit_event::AuditEvent;

// ============================================================
// Mutation kinds
// ============================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MutationKind {
    Confirm,
    Reject,
    Contest,
    Supersede,
    AutomatedConfirm,
    Decay,
    Expire,
    LineageAdvance,
    ActuatorConfirm,
}

impl MutationKind {
    pub fn token(&self) -> &'static str {
        match self {
            Self::Confirm => "confirm",
            Self::Reject => "reject",
            Self::Contest => "contest",
            Self::Supersede => "supersede",
            Self::AutomatedConfirm => "automated_confirm",
            Self::Decay => "decay",
            Self::Expire => "expire",
            Self::LineageAdvance => "lineage_advance",
            Self::ActuatorConfirm => "actuator_confirm",
        }
    }
}

// ============================================================
// Row-state automaton transition table (§ 9.3)
// ============================================================

pub fn can_transition(from: RowState, to: RowState, verb: &str) -> bool {
    transition(from, verb) == Some(to)
}

fn transition(from: RowState, verb: &str) -> Option<RowState> {
    use RowState::*;
    match (from, verb) {
        // From active:
        (Active, "contest") => Some(Contested),
        (Active, "supersede") => Some(Superseded),
        (Active, "withdraw") => Some(Withdrawn),
        (Active, "expunge") => Some(Tombstoned),
        (Active, "decay") => Some(Decayed),
        (Active, "expire") => Some(Expired),
        // From pending:
        (Pending, "confirm") => Some(Accepted),
        (Pending, "reject") => Some(Rejected),
        (Pending, "contest") => Some(Contested),
        (Pending, "automated_confirm") => Some(Accepted),
        (Pending, "actuator_confirm") => Some(Accepted),
        (Pending, "withdraw") => Some(Withdrawn),
        (Pending, "expunge") => Some(Tombstoned),
        // From contested:
        (Contested, "confirm") => Some(Accepted),
        (Contested, "reject") => Some(Rejected),
        (Contested, "supersede") => Some(Superseded),
        (Contested, "withdraw") => Some(Withdrawn),
        // From accepted:
        (Accepted, "contest") => Some(Contested),
        (Accepted, "supersede") => Some(Superseded),
        (Accepted, "withdraw") => Some(Withdrawn),
        (Accepted, "decay") => Some(Decayed),
        // From superseded:
        (Superseded, "withdraw") => Some(Withdrawn),
        (Superseded, "expunge") => Some(Tombstoned),
        (Superseded, "lineage_advance") => Some(Decayed),
        // revive surface (§9.3): every Cluster-B state confirms back to
        // active. The superseded lineage-conflict rule is enforced in
        // LocusKit's revive guard, not here (this table is stateless).
        (Superseded, "confirm") => Some(Active),
        // From decayed:
        (Decayed, "withdraw") => Some(Withdrawn),
        (Decayed, "expunge") => Some(Tombstoned),
        (Decayed, "confirm") => Some(Active),
        // From withdrawn:
        (Withdrawn, "confirm") => Some(Active),
        (Withdrawn, "expunge") => Some(Tombstoned),
        // From expired:
        (Expired, "withdraw") => Some(Withdrawn),
        (Expired, "expunge") => Some(Tombstoned),
        (Expired, "confirm") => Some(Active),
        // From rejected:
        (Rejected, "confirm") => Some(Accepted),
        (Rejected, "expunge") => Some(Tombstoned),
        // Tombstoned: terminal.
        _ => None,
    }
}

// ============================================================
// Substrate
// ============================================================

/// In-memory substrate. Production code persists to SQLite +
/// bit-slice tensor; this reference stays in memory for testability.
pub struct Substrate {
    pub estate_uuid: u128,
    pub rows: HashMap<RowId, Row>,
    pub audit_events: Vec<AuditEvent>,
    pub hlc: HLC,
    pub row_count_active: i64,
    /// Field-presence matrix (cookbook § 6.1). Mirrors Swift matrixF.
    pub matrix_f: MatrixF,
    /// Co-occurrence matrix (cookbook § 6.3). Mirrors Swift matrixO.
    pub matrix_o: MatrixO,
    /// Temporal-causality matrix (cookbook § 6.5). Declared but not
    /// mutated by verbs — matches Swift, which also declares matrixT
    /// without verb-level updates.
    pub matrix_t: MatrixT,
    /// Counter for the reference's deterministic RowId allocator.
    /// Production uses UUIDv4. The reference uses a counter so
    /// generation is reproducible across languages with the same
    /// verb sequence.
    next_row_seq: u64,
}

impl Substrate {
    pub fn new(estate_uuid: u128, hlc: HLC) -> Self {
        Self {
            estate_uuid,
            rows: HashMap::new(),
            audit_events: Vec::new(),
            hlc,
            row_count_active: 0,
            matrix_f: MatrixF::new(),
            matrix_o: MatrixO::new(),
            matrix_t: MatrixT::default(),
            next_row_seq: 0,
        }
    }

    fn alloc_row_id(&mut self) -> RowId {
        let seq = self.next_row_seq;
        self.next_row_seq = self.next_row_seq.wrapping_add(1);
        // Deterministic 128-bit id: estate_uuid (high 64) | seq (low 64).
        let high = (self.estate_uuid >> 64) as u64;
        RowId(((high as u128) << 64) | (seq as u128))
    }

    // ============================================================
    // § 10.1 — capture
    // ============================================================

    /// - `ts`: Caller-supplied epoch seconds for telemetry.
    ///   Pass `SystemTime::now()` at the verb boundary.
    ///   Default 0.0 is intentionally not provided here — Rust callers
    ///   must be explicit. SubstrateLib never reads a clock internally.
    pub fn capture(
        &mut self,
        noun_type: NounType,
        adjective_bitmap: i64,
        operational_bitmap: i64,
        provenance_bitmap: i64,
        lattice_anchor: LatticeAnchor,
        fingerprint: Fingerprint256,
        lineage_id: Option<RowId>,
        content: Option<Vec<u8>>,
        actor: &str,
        ts: f64,
    ) -> Result<RowId, SubstrateError> {
        if lattice_anchor.is_null() {
            return Err(SubstrateError::MissingLatticeAnchor);
        }

        let initial_state = if noun_type == NounType::Proposal {
            RowState::Pending
        } else {
            RowState::Active
        };

        if let Some(err) = is_legal_row_state(initial_state, adjective_bitmap, operational_bitmap) {
            return Err(err);
        }

        let row_id = self.alloc_row_id();
        let row = Row {
            id: row_id,
            noun_type,
            state: initial_state,
            adjective_bitmap,
            operational_bitmap,
            provenance_bitmap,
            fingerprint,
            lattice_anchor,
            lineage_id,
            content,
        };
        self.rows.insert(row_id, row);
        if initial_state != RowState::Tombstoned {
            self.row_count_active = self.row_count_active.wrapping_add(1);
        }

        // F-matrix increment: every (field, bit) the row has set
        // contributes +1. Mirrors Swift capture matrix update.
        let rb = RowBitmaps::new(adjective_bitmap, operational_bitmap, provenance_bitmap);
        self.matrix_f.apply_row(1, |f, b| rb.bit(f, b));
        // O-matrix increment: every ordered pair of (field, value)
        // in the row contributes +1.
        self.matrix_o.apply_row(1, &rb.field_values());

        self.append_audit(
            "capture", row_id, None,
            (adjective_bitmap, operational_bitmap, provenance_bitmap),
            None, lattice_anchor, actor);

        // Telemetry — off-path cost: single AtomicBool::load(Acquire) + branch.
        // StatSample is never constructed when monitoring is disabled.
        emit_verb_capture_count(&format!("{}", noun_type as u8), ts);

        Ok(row_id)
    }

    // ============================================================
    // § 10.2 — reanchor
    // ============================================================

    pub fn reanchor(
        &mut self,
        row_id: RowId,
        new_lattice_anchor: LatticeAnchor,
        actor: &str,
        ts: f64,
    ) -> Result<(), SubstrateError> {
        let row = self.rows.get(&row_id).ok_or(SubstrateError::RowNotFound(row_id))?;
        if row.state == RowState::Tombstoned {
            return Err(SubstrateError::AlreadyTombstoned(row_id));
        }
        if new_lattice_anchor.is_null() {
            return Err(SubstrateError::MissingLatticeAnchor);
        }
        let old_anchor = row.lattice_anchor;
        let before = (row.adjective_bitmap, row.operational_bitmap, row.provenance_bitmap);
        let after = before;
        let row_mut = self.rows.get_mut(&row_id).unwrap();
        row_mut.lattice_anchor = new_lattice_anchor;
        self.append_audit("reanchor", row_id, Some(before), after,
                           Some(old_anchor), new_lattice_anchor, actor);

        // Telemetry — off-path cost: single AtomicBool::load(Acquire) + branch.
        emit_verb_reanchor_count(ts);

        Ok(())
    }

    // ============================================================
    // § 10.3 — mutate
    // ============================================================

    pub fn mutate(
        &mut self,
        row_id: RowId,
        mutation_kind: MutationKind,
        new_adjective_bitmap: i64,
        new_operational_bitmap: Option<i64>,
        new_provenance_bitmap: Option<i64>,
        actor: &str,
        ts: f64,
    ) -> Result<(), SubstrateError> {
        let row = self.rows.get(&row_id).ok_or(SubstrateError::RowNotFound(row_id))?;
        if row.state == RowState::Tombstoned {
            return Err(SubstrateError::AlreadyTombstoned(row_id));
        }
        let new_state_raw = (new_adjective_bitmap & 0x3F) as u8;
        let new_state = RowState::from_raw(new_state_raw)
            .ok_or_else(|| SubstrateError::ForbiddenStateCombination(
                format!("unknown state raw {new_state_raw}")))?;
        let verb = mutation_kind.token();
        if !can_transition(row.state, new_state, verb) {
            return Err(SubstrateError::InvalidStateTransition {
                from: row.state, to: new_state, verb: verb.to_string(),
            });
        }
        let next_operational = new_operational_bitmap.unwrap_or(row.operational_bitmap);
        if let Some(err) = is_legal_row_state(new_state, new_adjective_bitmap, next_operational) {
            return Err(err);
        }
        let before = (row.adjective_bitmap, row.operational_bitmap, row.provenance_bitmap);
        let was_active = row.state != RowState::Tombstoned;
        let lattice_anchor = row.lattice_anchor;

        let row_mut = self.rows.get_mut(&row_id).unwrap();
        row_mut.state = new_state;
        row_mut.adjective_bitmap = new_adjective_bitmap;
        if let Some(op) = new_operational_bitmap {
            row_mut.operational_bitmap = op;
        }
        if let Some(pr) = new_provenance_bitmap {
            row_mut.provenance_bitmap = pr;
        }
        let after = (
            row_mut.adjective_bitmap,
            row_mut.operational_bitmap,
            row_mut.provenance_bitmap,
        );

        let now_active = row_mut.state != RowState::Tombstoned;
        if was_active && !now_active {
            self.row_count_active = self.row_count_active.wrapping_sub(1);
        } else if !was_active && now_active {
            self.row_count_active = self.row_count_active.wrapping_add(1);
        }

        // Matrix update: delta against old vs new bitmaps.
        // Mirrors Swift mutate matrix update.
        let before_rb = RowBitmaps::new(before.0, before.1, before.2);
        self.matrix_f.apply_row(-1, |f, b| before_rb.bit(f, b));
        let after_rb = RowBitmaps::new(after.0, after.1, after.2);
        self.matrix_f.apply_row(1, |f, b| after_rb.bit(f, b));
        self.matrix_o.apply_row(-1, &before_rb.field_values());
        self.matrix_o.apply_row(1, &after_rb.field_values());

        let verb_full = format!("mutate.{}", verb);
        self.append_audit(&verb_full, row_id, Some(before), after,
                           Some(lattice_anchor), lattice_anchor, actor);

        // Telemetry — off-path cost: single AtomicBool::load(Acquire) + branch.
        emit_verb_mutate_count(verb, ts);

        Ok(())
    }

    // ============================================================
    // § 10.4 — withdraw
    // ============================================================

    pub fn withdraw(&mut self, row_id: RowId, actor: &str, ts: f64) -> Result<(), SubstrateError> {
        let row = self.rows.get(&row_id).ok_or(SubstrateError::RowNotFound(row_id))?;
        if !can_transition(row.state, RowState::Withdrawn, "withdraw") {
            return Err(SubstrateError::InvalidStateTransition {
                from: row.state, to: RowState::Withdrawn, verb: "withdraw".into(),
            });
        }
        let before = (row.adjective_bitmap, row.operational_bitmap, row.provenance_bitmap);
        let lattice_anchor = row.lattice_anchor;
        let new_adj = set_state_field(row.adjective_bitmap, 18); // withdrawn
        let row_mut = self.rows.get_mut(&row_id).unwrap();
        row_mut.state = RowState::Withdrawn;
        row_mut.adjective_bitmap = new_adj;
        let after = (new_adj, before.1, before.2);

        // Matrix update: delta against old vs new bitmaps. Withdraw changes
        // the state field in the adjective bitmap, so both matrix_f (bit-slice)
        // and matrix_o (field-value ordinal) must reflect the new state or
        // downstream bitmap queries will produce stale bucket counts (WS2-F5).
        let before_rb = RowBitmaps::new(before.0, before.1, before.2);
        self.matrix_f.apply_row(-1, |f, b| before_rb.bit(f, b));
        self.matrix_o.apply_row(-1, &before_rb.field_values());
        let after_rb = RowBitmaps::new(after.0, after.1, after.2);
        self.matrix_f.apply_row(1, |f, b| after_rb.bit(f, b));
        self.matrix_o.apply_row(1, &after_rb.field_values());

        self.append_audit("withdraw", row_id, Some(before), after,
                           Some(lattice_anchor), lattice_anchor, actor);

        // Telemetry — off-path cost: single AtomicBool::load(Acquire) + branch.
        emit_verb_withdraw_count(ts);

        Ok(())
    }

    // ============================================================
    // § 10.5 — expunge
    // ============================================================

    pub fn expunge(
        &mut self,
        row_id: RowId,
        reason: &str,
        actor: &str,
        ts: f64,
    ) -> Result<(), SubstrateError> {
        let row = self.rows.get(&row_id).ok_or(SubstrateError::RowNotFound(row_id))?;
        if row.state == RowState::Tombstoned {
            return Err(SubstrateError::AlreadyTombstoned(row_id));
        }
        // S-3 (cookbook § 9.5): accepted rows are audit-grade and must
        // survive intact. The expunge path is closed for them.
        if row.state == RowState::Accepted {
            return Err(SubstrateError::InvalidStateTransition {
                from: RowState::Accepted,
                to: RowState::Tombstoned,
                verb: "expunge".to_string(),
            });
        }
        let before = (row.adjective_bitmap, row.operational_bitmap, row.provenance_bitmap);
        let lattice_anchor = row.lattice_anchor;
        let was_active = row.state != RowState::Tombstoned;
        let new_adj = set_state_field(row.adjective_bitmap, 33); // tombstoned
        let row_mut = self.rows.get_mut(&row_id).unwrap();
        row_mut.state = RowState::Tombstoned;
        row_mut.adjective_bitmap = new_adj;
        row_mut.content = None;
        let after = (new_adj, before.1, before.2);
        if was_active {
            self.row_count_active = self.row_count_active.wrapping_sub(1);
        }

        // Matrix decrement: row no longer contributes.
        // Mirrors Swift expunge matrix update.
        let before_rb = RowBitmaps::new(before.0, before.1, before.2);
        self.matrix_f.apply_row(-1, |f, b| before_rb.bit(f, b));
        self.matrix_o.apply_row(-1, &before_rb.field_values());

        let actor_with_reason = format!("{}:{}", actor, reason);
        self.append_audit("expunge", row_id, Some(before), after,
                           Some(lattice_anchor), lattice_anchor, &actor_with_reason);

        // Telemetry — off-path cost: single AtomicBool::load(Acquire) + branch.
        emit_verb_expunge_count(ts);

        Ok(())
    }

    // ============================================================
    // § 10.6 — recall (read-only)
    // ============================================================

    /// `ts`: Caller-supplied epoch seconds. Used only for telemetry tagging.
    /// SubstrateLib never reads a clock internally.
    pub fn recall<F>(&self, predicate: F, as_of: Option<HLC>, ts: f64) -> Vec<&Row>
    where
        F: Fn(&Row) -> bool,
    {
        let result: Vec<&Row> = if let Some(cutoff) = as_of {
            let mut visible: std::collections::HashSet<RowId> =
                std::collections::HashSet::new();
            for e in &self.audit_events {
                if e.hlc <= cutoff {
                    visible.insert(e.row_id);
                }
            }
            self.rows
                .values()
                .filter(|r| visible.contains(&r.id) && predicate(r))
                .collect()
        } else {
            self.rows.values().filter(|r| predicate(r)).collect()
        };

        // Telemetry — off-path cost: single AtomicBool::load(Acquire) + branch.
        emit_verb_recall_count(result.len(), ts);

        result
    }

    // ============================================================
    // § 10.7 — propose
    // ============================================================

    pub fn propose(
        &mut self,
        adjective_bitmap: i64,
        operational_bitmap: i64,
        provenance_bitmap: i64,
        lattice_anchor: LatticeAnchor,
        fingerprint: Fingerprint256,
        actor: &str,
        ts: f64,
    ) -> Result<RowId, SubstrateError> {
        self.capture(
            NounType::Proposal,
            adjective_bitmap,
            operational_bitmap,
            provenance_bitmap,
            lattice_anchor,
            fingerprint,
            None,
            None,
            actor,
            ts,
        )
    }

    // ============================================================
    // § 10.8 — associate
    // ============================================================

    pub fn associate(
        &mut self,
        _row_a: RowId,
        _row_b: RowId,
        _signal_sources_bitset: u16,
        _weight: f32,
        adjective_bitmap: i64,
        operational_bitmap: i64,
        provenance_bitmap: i64,
        lattice_anchor: LatticeAnchor,
        fingerprint: Fingerprint256,
        actor: &str,
        ts: f64,
    ) -> Result<RowId, SubstrateError> {
        // ADMIN — drop site for the association parameters. `_row_a`,
        // `_row_b`, `_signal_sources_bitset`, and `_weight` are accepted
        // and discarded: an Association is a noun-typed row and the
        // reference persists no endpoint or weight columns (production
        // adds the FK book-keeping). `_weight` arrives computed free from
        // the similarity signal's proximity-gate Hamming distance and is
        // VESTIGIAL past this gate; the parameter is retained on purpose
        // for a pre-2.0 gauntlet experiment on whether weight improves
        // recall. Mirrors Swift `Verbs.associate`.
        self.capture(
            NounType::Association,
            adjective_bitmap,
            operational_bitmap,
            provenance_bitmap,
            lattice_anchor,
            fingerprint,
            None,
            None,
            actor,
            ts,
        )
    }

    // ============================================================
    // § 10.9 — learn
    // ============================================================

    pub fn learn(
        &mut self,
        adjective_bitmap: i64,
        operational_bitmap: i64,
        provenance_bitmap: i64,
        lattice_anchor: LatticeAnchor,
        fingerprint: Fingerprint256,
        actor: &str,
        ts: f64,
    ) -> Result<RowId, SubstrateError> {
        self.capture(
            NounType::LearnedReference,
            adjective_bitmap,
            operational_bitmap,
            provenance_bitmap,
            lattice_anchor,
            fingerprint,
            None,
            None,
            actor,
            ts,
        )
    }

    // Internals

    fn append_audit(
        &mut self,
        verb: &str,
        row_id: RowId,
        before: Option<(i64, i64, i64)>,
        after: (i64, i64, i64),
        before_anchor: Option<LatticeAnchor>,
        after_anchor: LatticeAnchor,
        actor: &str,
    ) {
        self.hlc = self.hlc.advanced();
        let event_id = crate::audit_gate::content_id(
            self.estate_uuid, row_id, &self.hlc, verb, after, after_anchor);
        self.audit_events.push(AuditEvent {
            event_id,
            estate_uuid: self.estate_uuid,
            row_id,
            hlc: self.hlc,
            verb: verb.to_string(),
            before_bitmaps: before,
            after_bitmaps: after,
            before_lattice_anchor: before_anchor,
            after_lattice_anchor: after_anchor,
            actor: actor.to_string(),
            // `expunge` encodes reason into `actor_with_reason` in the
            // actor field; the dedicated `reason` field is left None.
            reason: None,
        });
    }
}

// Helpers

fn is_legal_row_state(state: RowState, adjective: i64, operational: i64) -> Option<SubstrateError> {
    let sensitivity = ((adjective >> 6) & 0x3F) as i32;
    let exportability = ((adjective >> 12) & 0x3F) as i32;
    let trust = ((adjective >> 18) & 0x3F) as i32;
    let _ = operational;

    // (1) No expunge_completed_flag check — this invariant is not
    // enforced in the scalar reference implementation.

    // (2) secret cannot be public.
    if sensitivity == 48 && exportability == 32 {
        return Some(SubstrateError::ForbiddenStateCombination(
            "secret cannot be public".into(),
        ));
    }
    // (3) accepted cannot be verbatim.
    if state == RowState::Accepted && trust == 0 {
        return Some(SubstrateError::ForbiddenStateCombination(
            "accepted cannot be verbatim".into(),
        ));
    }
    None
}

fn set_state_field(bitmap: i64, raw: u8) -> i64 {
    let cleared = bitmap & !0x3Fi64;
    cleared | (raw as i64)
}

// ============================================================
// Tests
// ============================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh_substrate() -> Substrate {
        let estate = 0x1234_5678_9abc_def0_0000_0000_0000_0000u128;
        Substrate::new(estate, HLC::new(0, 0, 1))
    }

    fn dummy_fp() -> Fingerprint256 {
        Fingerprint256 { block0: 0, block1: 0, block2: 0, block3: 0 }
    }

    fn anchor() -> LatticeAnchor {
        LatticeAnchor::new(0x0a0a_0000_0000_0000, 0x1234)
    }

    #[test]
    fn capture_creates_active_row() {
        let mut s = fresh_substrate();
        let id = s
            .capture(
                NounType::Drawer,
                0, 0, 0, anchor(), dummy_fp(), None, None, "test",
                0.0, // ts: non-telemetry test, 0.0 is discarded by any ts-filtered sink
            )
            .unwrap();
        assert_eq!(s.rows.get(&id).unwrap().state, RowState::Active);
        assert_eq!(s.row_count_active, 1);
        assert_eq!(s.audit_events.len(), 1);
        assert_eq!(s.audit_events[0].verb, "capture");
    }

    #[test]
    fn capture_proposal_creates_pending() {
        let mut s = fresh_substrate();
        let id = s
            .propose(1, 0, 0, anchor(), dummy_fp(), "agent", 0.0)
            .unwrap();
        assert_eq!(s.rows.get(&id).unwrap().state, RowState::Pending);
    }

    #[test]
    fn capture_without_anchor_fails() {
        let mut s = fresh_substrate();
        let res = s.capture(
            NounType::Drawer, 0, 0, 0,
            LatticeAnchor::new(0, 0), dummy_fp(), None, None, "test", 0.0,
        );
        assert_eq!(res, Err(SubstrateError::MissingLatticeAnchor));
    }

    #[test]
    fn mutate_confirm_pending_to_accepted() {
        let mut s = fresh_substrate();
        // Set adjective trust to "imported" (raw 2) so accepted+trust is legal.
        let adj_pending: i64 = 1 | (2 << 18); // state=pending(1), trust=imported(2)
        let id = s
            .capture(NounType::Proposal, adj_pending, 0, 0, anchor(), dummy_fp(), None, None, "a", 0.0)
            .unwrap();
        let adj_accepted: i64 = 3 | (2 << 18); // state=accepted(3), trust=imported(2)
        s.mutate(id, MutationKind::Confirm, adj_accepted, None, None, "user", 0.0).unwrap();
        assert_eq!(s.rows.get(&id).unwrap().state, RowState::Accepted);
        assert_eq!(s.audit_events.len(), 2);
        assert!(s.audit_events[1].verb.contains("confirm"));
    }

    #[test]
    fn mutate_rejects_invalid_transition() {
        let mut s = fresh_substrate();
        let adj_active: i64 = 0;
        let id = s
            .capture(NounType::Drawer, adj_active, 0, 0, anchor(), dummy_fp(), None, None, "a", 0.0)
            .unwrap();
        // Active → pending is not a legal transition.
        let adj_pending: i64 = 1;
        let res = s.mutate(id, MutationKind::Confirm, adj_pending, None, None, "user", 0.0);
        assert!(matches!(res, Err(SubstrateError::InvalidStateTransition { .. })));
    }

    #[test]
    fn forbidden_secret_public_combo_rejected() {
        let mut s = fresh_substrate();
        // sensitivity=48 (bits 6-11) AND exportability=32 (bits 12-17).
        let adj: i64 = (48i64 << 6) | (32i64 << 12);
        let res = s.capture(
            NounType::Drawer, adj, 0, 0, anchor(), dummy_fp(), None, None, "test", 0.0,
        );
        assert!(matches!(res, Err(SubstrateError::ForbiddenStateCombination(_))));
    }

    #[test]
    fn expunge_tombstones_and_clears_content() {
        let mut s = fresh_substrate();
        let id = s
            .capture(NounType::Drawer, 0, 0, 0, anchor(), dummy_fp(), None,
                      Some(b"hello".to_vec()), "test", 0.0)
            .unwrap();
        s.expunge(id, "GDPR-request", "user", 0.0).unwrap();
        let row = s.rows.get(&id).unwrap();
        assert_eq!(row.state, RowState::Tombstoned);
        assert!(row.content.is_none());
        assert_eq!(s.row_count_active, 0);
    }

    #[test]
    fn expunge_tombstoned_row_fails() {
        let mut s = fresh_substrate();
        let id = s
            .capture(NounType::Drawer, 0, 0, 0, anchor(), dummy_fp(), None, None, "test", 0.0)
            .unwrap();
        s.expunge(id, "first", "user", 0.0).unwrap();
        let res = s.expunge(id, "second", "user", 0.0);
        assert!(matches!(res, Err(SubstrateError::AlreadyTombstoned(_))));
    }

    #[test]
    fn withdraw_active_to_withdrawn() {
        let mut s = fresh_substrate();
        let id = s
            .capture(NounType::Drawer, 0, 0, 0, anchor(), dummy_fp(), None, None, "test", 0.0)
            .unwrap();
        s.withdraw(id, "user", 0.0).unwrap();
        assert_eq!(s.rows.get(&id).unwrap().state, RowState::Withdrawn);
        // Re-confirm to active per cookbook (withdrawn, confirm → active).
        let adj_active: i64 = 0;
        s.mutate(id, MutationKind::Confirm, adj_active, None, None, "user", 0.0).unwrap();
        assert_eq!(s.rows.get(&id).unwrap().state, RowState::Active);
    }

    #[test]
    fn recall_filters_by_predicate() {
        let mut s = fresh_substrate();
        s.capture(NounType::Drawer, 0, 0, 0, anchor(), dummy_fp(), None, None, "a", 0.0).unwrap();
        s.capture(NounType::AmbientSample, 0, 0, 0, anchor(), dummy_fp(), None, None, "a", 0.0).unwrap();
        let drawers = s.recall(|r| r.noun_type == NounType::Drawer, None, 0.0);
        assert_eq!(drawers.len(), 1);
    }

    #[test]
    fn audit_events_advance_hlc() {
        let mut s = fresh_substrate();
        let h0 = s.hlc;
        s.capture(NounType::Drawer, 0, 0, 0, anchor(), dummy_fp(), None, None, "a", 0.0).unwrap();
        let h1 = s.hlc;
        s.capture(NounType::Drawer, 0, 0, 0, anchor(), dummy_fp(), None, None, "a", 0.0).unwrap();
        let h2 = s.hlc;
        assert!(h0 < h1);
        assert!(h1 < h2);
    }

    #[test]
    fn deterministic_row_ids_across_calls() {
        // Same estate uuid + same call sequence → same row IDs.
        let mut s1 = Substrate::new(0xabcd_ef01_2345_6789_0000_0000_0000_0000, HLC::new(0, 0, 1));
        let mut s2 = Substrate::new(0xabcd_ef01_2345_6789_0000_0000_0000_0000, HLC::new(0, 0, 1));
        let id1 = s1.capture(NounType::Drawer, 0, 0, 0, anchor(), dummy_fp(), None, None, "a", 0.0).unwrap();
        let id2 = s2.capture(NounType::Drawer, 0, 0, 0, anchor(), dummy_fp(), None, None, "a", 0.0).unwrap();
        assert_eq!(id1, id2);
    }

    // ============================================================
    // Matrix parity tests — PAR-R2
    // ============================================================

    #[test]
    fn capture_updates_matrix_f_and_o() {
        let mut s = fresh_substrate();
        // adj=0x07 sets bits 0,1,2 of field 0. op=0x01 sets bit 0
        // of field 12. prov=0 contributes nothing.
        s.capture(NounType::Drawer, 0x07, 0x01, 0, anchor(), dummy_fp(),
                  None, None, "test", 0.0).unwrap();

        // F-matrix: field 0 bits 0,1,2 each have count 1.
        assert_eq!(s.matrix_f.get(0, 0), 1);
        assert_eq!(s.matrix_f.get(0, 1), 1);
        assert_eq!(s.matrix_f.get(0, 2), 1);
        assert_eq!(s.matrix_f.get(0, 3), 0);
        // Field 12 (operational column start) bit 0 has count 1.
        assert_eq!(s.matrix_f.get(12, 0), 1);

        // O-matrix: non-zero entry count > 0 after a capture with
        // non-zero bitmaps.
        assert!(s.matrix_o.entry_count() > 0);

        // T-matrix: untouched by verbs.
        assert_eq!(s.matrix_t, MatrixT::default());
    }

    #[test]
    fn mutate_updates_matrix_f_delta() {
        let mut s = fresh_substrate();
        // Capture as Proposal (Pending state). adj=0x01 (state=Pending).
        let id = s.capture(NounType::Proposal, 0x01, 0x01, 0, anchor(),
                           dummy_fp(), None, None, "test", 0.0).unwrap();
        // Field 0 bit 0 and field 12 bit 0 each have count 1.
        assert_eq!(s.matrix_f.get(0, 0), 1);
        assert_eq!(s.matrix_f.get(12, 0), 1);

        // Confirm: Pending→Accepted (raw 3). Trust field (bits 18-23)
        // must be non-zero for Accepted (forbidden-combo rule).
        // adj = 0x03 | (1 << 18) = 0x40003. Op stays 0x01.
        let new_adj: i64 = 0x03 | (1 << 18);
        s.mutate(id, MutationKind::Confirm, new_adj, Some(0x01), None,
                 "test", 0.0).unwrap();
        // Adj field 0: bit 0 stays (set in both old and new).
        // Bit 1 added by new adj (0x03 has bits 0,1).
        assert_eq!(s.matrix_f.get(0, 0), 1);
        assert_eq!(s.matrix_f.get(0, 1), 1);
        // Trust field at field 3 (bits 18-23, field_idx = 18/6 = 3),
        // bit 0 now set (was 0 before).
        assert_eq!(s.matrix_f.get(3, 0), 1);
        // Op field 12 bit 0 unchanged (still 0x01 before and after).
        assert_eq!(s.matrix_f.get(12, 0), 1);
    }

    #[test]
    fn expunge_decrements_matrix_f() {
        let mut s = fresh_substrate();
        let id = s.capture(NounType::Drawer, 0x01, 0, 0, anchor(),
                           dummy_fp(), None, None, "test", 0.0).unwrap();
        assert_eq!(s.matrix_f.get(0, 0), 1);

        s.expunge(id, "test-reason", "test", 0.0).unwrap();
        // F-matrix decremented back to zero for the captured bitmap.
        assert_eq!(s.matrix_f.get(0, 0), 0);
        assert_eq!(s.matrix_f.total_count(), 0);
    }

    #[test]
    fn matrix_f_net_zero_after_capture_expunge_cycle() {
        let mut s = fresh_substrate();
        let id1 = s.capture(NounType::Drawer, 0x3F, 0x3F, 0x3F, anchor(),
                            dummy_fp(), None, None, "a", 0.0).unwrap();
        let id2 = s.capture(NounType::Drawer, 0x07, 0x01, 0, anchor(),
                            dummy_fp(), None, None, "a", 0.0).unwrap();
        s.expunge(id1, "r", "a", 0.0).unwrap();
        s.expunge(id2, "r", "a", 0.0).unwrap();
        // All rows removed → F-matrix should be back to all zeros.
        assert_eq!(s.matrix_f.total_count(), 0);
    }

    // WS2-F5 regression: withdraw must update matrix_f and matrix_o.
    // Previously withdraw mutated adjective_bitmap but skipped the matrix
    // delta, leaving state-field bucket counts stale.
    #[test]
    fn withdraw_updates_matrix_f_and_o() {
        let mut s = fresh_substrate();
        let id = s.capture(NounType::Drawer, 0, 0, 0, anchor(),
                           dummy_fp(), None, None, "test", 0.0).unwrap();
        let f_before = s.matrix_f.clone();
        let o_before = s.matrix_o.clone();

        s.withdraw(id, "user", 0.0).unwrap();

        // Withdraw changes the state field in adjective bits 0-5 (from
        // 0/active to 18/withdrawn), so matrix_f and matrix_o must differ
        // from their pre-withdraw snapshots. A no-op delta (the pre-fix bug)
        // would leave them identical.
        assert_ne!(
            s.matrix_f, f_before,
            "WS2-F5: matrix_f must be updated by withdraw"
        );
        assert_ne!(
            s.matrix_o, o_before,
            "WS2-F5: matrix_o must be updated by withdraw"
        );
    }
}
