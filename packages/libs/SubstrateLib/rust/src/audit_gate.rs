// audit_gate.rs
//
// Rust mirror of AuditGate.swift — the single write gate plus the
// vocabulary validator that arms it. See the Swift leg for the full
// rationale. Conformance-gated against shared vectors (I-7/I-11, M8):
// the content-ID and the gate decisions are byte/branch identical
// across ports.
//
// Parity note: the Rust `AuditEvent` (verbs.rs) has no `event_id`
// field yet, where the Swift one does. `admit` therefore returns
// `(content_id, AuditEvent)`; adding `event_id: u128` to the Rust
// AuditEvent to fold the ID into the struct is the parity close, owed
// separately so as not to churn every AuditEvent constructor here.

use std::collections::HashSet;
use substrate_kernel::bit_field;
use substrate_kernel::sha256;
use crate::row_state::{self, BitmapFields, RowState, RowVerb};
use crate::verbs::{AuditEvent, LatticeAnchor, NounType, RowId};
use substrate_types::hlc::HLC;

// MARK: - SubstrateLib adjective vocabulary constants
//
// Rust-side counterparts of the Swift AuditState / AuditSensitivity /
// AuditExportability / AuditTrust enums. Rust has no CaseIterable, so
// typed const slices serve the same role: the basis() function below
// references these slices instead of inline integer literals, so adding
// a new adjective value means updating the constant in one place.
//
// Raw values must match LocusKit's types (State, AdjectiveSensitivity,
// AdjectiveExportability, Trust). Parity is verified by
// GuardianPairParityTests in LocusKit.

// @guardian-pair: state-basis AUDIT_STATE_VALUES <-> State.allCases (raw set equality)
const AUDIT_STATE_VALUES: &[i64] = &[0, 1, 2, 3, 16, 17, 18, 19, 32, 33];

// @guardian-pair: sensitivity-basis AUDIT_SENSITIVITY_VALUES <-> AdjectiveSensitivity.allCases (raw set equality)
const AUDIT_SENSITIVITY_VALUES: &[i64] = &[0, 16, 32, 48];

// @guardian-pair: exportability-basis AUDIT_EXPORTABILITY_VALUES <-> AdjectiveExportability.allCases (raw set equality)
const AUDIT_EXPORTABILITY_VALUES: &[i64] = &[0, 32];

// @guardian-pair: trust-basis AUDIT_TRUST_VALUES <-> Trust.allCases (raw set equality)
const AUDIT_TRUST_VALUES: &[i64] = &[0, 1, 2, 3, 4, 5, 6];

// MARK: - Field slots

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Column { Adjective, Operational, Provenance }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldSlot {
    pub column: Column,
    pub shift: u32,
    pub width: u32,
    pub label: String,
    /// Empty ⇒ any value that fits the width. Non-empty ⇒ enumerated.
    pub legal_values: HashSet<i64>,
}

impl FieldSlot {
    pub fn new(column: Column, shift: u32, width: u32, label: &str) -> Self {
        Self { column, shift, width, label: label.to_string(), legal_values: HashSet::new() }
    }
    pub fn with_values(column: Column, shift: u32, width: u32, label: &str, values: &[i64]) -> Self {
        Self { column, shift, width, label: label.to_string(),
               legal_values: values.iter().copied().collect() }
    }
    /// [0, 2^width). width>=63 ⇒ i64::MAX.
    pub fn capacity(&self) -> i64 { if self.width >= 63 { i64::MAX } else { 1i64 << self.width } }
    pub fn bit_mask(&self) -> u64 {
        if self.width == 0 { 0 }
        else if self.width >= 64 { u64::MAX }
        else { (((1u64 << self.width) - 1)) << self.shift }
    }
    pub fn admits_value(&self, value: i64) -> bool {
        if value < 0 || value >= self.capacity() { return false; }
        if self.legal_values.is_empty() { return true; }
        self.legal_values.contains(&value)
    }
    /// Same identity the Swift `slot(for:)` lookup uses: column+shift+width.
    fn addr_eq(&self, o: &FieldSlot) -> bool {
        self.column == o.column && self.shift == o.shift && self.width == o.width
    }
}

// MARK: - Vocabulary

/// Substrate-owned slots, universal across every instance and peer
/// (the federation minimum). Adjective layout per cookbook §2.3 (F11).
pub fn basis() -> Vec<FieldSlot> {
    vec![
        // Enumerated value sets per cookbook §2.3. Derived from the typed
        // constants above rather than inline integer literals, mirroring
        // the Swift CaseIterable derivation in Vocabulary.basis.
        FieldSlot::with_values(Column::Adjective, 0,  6, "state",         AUDIT_STATE_VALUES),
        FieldSlot::with_values(Column::Adjective, 6,  6, "sensitivity",   AUDIT_SENSITIVITY_VALUES),
        FieldSlot::with_values(Column::Adjective, 12, 6, "exportability", AUDIT_EXPORTABILITY_VALUES),
        FieldSlot::with_values(Column::Adjective, 18, 6, "trust",         AUDIT_TRUST_VALUES),
        // flags: a 3-bit bitset spanning adjective bits 24-26, any
        // value fits the width.
        //   bit 24 = state_extension     (cookbook §2.3)
        //   bit 25 = lineage_clustering  (cookbook §2.3)
        //   bit 26 = dreaming_recalc_required (cookbook §2.3, F17):
        //            worklist marker set on tombstone-via-expunge,
        //            cleared by the dreaming pass after graph
        //            reconciliation.
        // Widened from width 2 to width 3 in F17 second pass to admit
        // bit 26 as a gated write target. Per-bit meaning lives at the
        // kit-level accessor; the substrate carries the bits
        // transparently. Sealed (bit 27) is deliberately NOT in this
        // slot — its set-once integrity lifecycle is owned by the Clock
        // Triangle decision and the dreaming-pass wiring (see
        // DECISION_CAPTURE_GENESIS_EVENT_2026-05-28 line 92).
        FieldSlot::new(Column::Adjective, 24, 3, "flags"),
    ]
}

#[derive(Debug, Clone)]
pub struct Vocabulary {
    union: Vec<FieldSlot>, // validated; constructed only via freeze
}

impl Vocabulary {
    pub fn slot_for(&self, target: &FieldSlot) -> Option<FieldSlot> {
        if let Some(b) = basis().into_iter().find(|b| b.addr_eq(target)) { return Some(b); }
        self.union.iter().find(|u| u.addr_eq(target)).cloned()
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum VocabularyError {
    Overlap(String, String),
    BasisCollision(String),
    MalformedWidth(String),
    ValueExceedsWidth(String, i64),
}

/// Validate a proposed consumer union and freeze it, or reject. Run
/// once at instantiation, before any data exists.
pub fn freeze(proposed: Vec<FieldSlot>) -> Result<Vocabulary, VocabularyError> {
    // 1. width-sane + enumerated values fit
    for s in &proposed {
        if s.width == 0 || (s.shift + s.width) > 64 {
            return Err(VocabularyError::MalformedWidth(s.label.clone()));
        }
        for v in &s.legal_values {
            if *v < 0 || *v >= s.capacity() {
                return Err(VocabularyError::ValueExceedsWidth(s.label.clone(), *v));
            }
        }
    }
    // 2. no basis collision
    for s in &proposed {
        for b in basis() {
            if b.column == s.column && (b.bit_mask() & s.bit_mask()) != 0 {
                return Err(VocabularyError::BasisCollision(s.label.clone()));
            }
        }
    }
    // 3. no union-internal overlap
    for i in 0..proposed.len() {
        for j in (i + 1)..proposed.len() {
            let (a, b) = (&proposed[i], &proposed[j]);
            if a.column == b.column && (a.bit_mask() & b.bit_mask()) != 0 {
                return Err(VocabularyError::Overlap(a.label.clone(), b.label.clone()));
            }
        }
    }
    Ok(Vocabulary { union: proposed })
}

// MARK: - Write request / result

pub struct FieldWrite { pub slot: FieldSlot, pub value: i64 }

#[derive(Debug)]
pub enum GateViolation {
    UndeclaredField(String),
    IllegalValue(String, i64),
    BasisViolation(row_state::RowStateError),
    /// State encoded in the write does not match what `verb` produces, or a
    /// capture used a non-capture verb or an illegal initial state.
    StateInconsistentWithVerb(String),
}

impl std::fmt::Display for GateViolation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // English messages used at the ARIA boundary. No internal type names
        // (BasisViolation, IllegalTransition, enum variant paths) must appear
        // in user-visible error text — this is the single format-to-Display
        // conversion point for all gate rejections. The Debug form ({:?}) leaks
        // Rust internal type chains; callers must use {} (this impl) at MCP
        // boundaries.
        match self {
            Self::UndeclaredField(label) => {
                write!(f, "undeclared field '{label}' in write request")
            }
            Self::IllegalValue(label, value) => {
                write!(f, "illegal value {value} for field '{label}'")
            }
            Self::BasisViolation(e) => {
                // RowStateError::Display for IllegalTransition emits "{state} --{verb}-->"
                // (e.g. "active --reject-->"). Prefixing with "illegal state transition: "
                // here produces the canonical form "illegal state transition: active --reject-->"
                // that the AriaMcpKit describe_gate_rejection parser expects.
                // RowStateError for ViolatesInvariant produces "safety invariant violation: ..."
                // which passes through as "illegal state transition: safety invariant violation: ...".
                write!(f, "illegal state transition: {e}")
            }
            Self::StateInconsistentWithVerb(verb) => {
                write!(f, "state encoded in write is inconsistent with verb '{verb}'")
            }
        }
    }
}

// MARK: - The gate

/// Admit a write. Pure. Returns the canonical event (with its
/// deterministic `event_id`) or a violation.
pub fn admit(
    estate_uuid: u128,
    row_id: RowId,
    _noun_type: NounType,
    verb: RowVerb,
    prior: Option<BitmapFields>,
    prior_lattice_anchor: Option<LatticeAnchor>,
    writes: &[FieldWrite],
    after_lattice_anchor: LatticeAnchor,
    vocabulary: &Vocabulary,
    hlc: HLC,
    actor: &str,
) -> Result<AuditEvent, GateViolation> {

    // 1. vocabulary + value gate
    for w in writes {
        match vocabulary.slot_for(&w.slot) {
            None => return Err(GateViolation::UndeclaredField(w.slot.label.clone())),
            Some(declared) => {
                if !declared.admits_value(w.value) {
                    return Err(GateViolation::IllegalValue(declared.label.clone(), w.value));
                }
            }
        }
    }

    // 2. read-modify-write, preserving unaddressed bits
    let base = prior.unwrap_or(BitmapFields { adjective: 0, operational: 0, provenance: 0 });
    let mut adjective = base.adjective as i64;
    let mut operational = base.operational as i64;
    let mut provenance = base.provenance as i64;
    for w in writes {
        match w.slot.column {
            Column::Adjective => adjective = bit_field::write_field(w.value, adjective, w.slot.shift, w.slot.width),
            Column::Operational => operational = bit_field::write_field(w.value, operational, w.slot.shift, w.slot.width),
            Column::Provenance => provenance = bit_field::write_field(w.value, provenance, w.slot.shift, w.slot.width),
        }
    }

    // 3. basis gate. State is verb-driven: the state the write encodes must
    //    be exactly what `verb` produces.
    let prior_state = RowState::from_raw((bit_field::extract_field(base.adjective as i64, 0, 6)) as u8)
        .unwrap_or(RowState::Active);
    let merged = BitmapFields { adjective: adjective as u64, operational: operational as u64, provenance: provenance as u64 };
    let written_state = RowState::from_raw((bit_field::extract_field(adjective, 0, 6)) as u8);
    if prior.is_none() {
        // Capture: require the capture verb and a legal initial state.
        match written_state {
            Some(ws) if verb == RowVerb::Capture && (ws == RowState::Active || ws == RowState::Pending) => {
                if let Err(e) = row_state::check_forbidden_combinations(ws, merged) {
                    return Err(GateViolation::BasisViolation(e));
                }
            }
            _ => return Err(GateViolation::StateInconsistentWithVerb(verb.token().to_string())),
        }
    } else {
        // Mutation: written state must equal the verb's transition result.
        match row_state::validate(prior_state, verb, merged) {
            Err(e) => return Err(GateViolation::BasisViolation(e)),
            Ok(next) => {
                if written_state != Some(next) {
                    return Err(GateViolation::StateInconsistentWithVerb(verb.token().to_string()));
                }
            }
        }
    }

    // 4. deterministic content-ID over the wire fields incl. verb name
    let cid = content_id(estate_uuid, row_id, &hlc, verb.token(),
                         (adjective, operational, provenance), after_lattice_anchor);

    let event = AuditEvent {
        event_id: cid,
        estate_uuid,
        row_id,
        hlc,
        verb: verb.token().to_string(),
        before_bitmaps: prior.map(|p| (p.adjective as i64, p.operational as i64, p.provenance as i64)),
        after_bitmaps: (adjective, operational, provenance),
        before_lattice_anchor: prior_lattice_anchor,
        after_lattice_anchor,
        actor: actor.to_string(),
        // reason is not set at the gate layer; it is threaded from the verb
        // call site (DrawerStore.expunge_gated / reanchor_gated) and injected
        // onto the event after the gate returns. None is correct here.
        reason: None,
    };
    Ok(event)
}

/// Deterministic event identity: SHA-256 over a stable wire encoding,
/// first 16 bytes folded to u128. Byte order MUST match AuditGate.swift
/// `contentID`: estate(16 BE) ++ row(16 BE) ++ hlc.wire_bytes(16)
/// ++ verb utf8 ++ 0 ++ after.{0,1,2} u64 BE ++ udc u64 BE ++ qid u64 BE.
pub fn content_id(
    estate_uuid: u128, row_id: RowId, hlc: &HLC, verb: &str,
    after: (i64, i64, i64), after_anchor: LatticeAnchor,
) -> u128 {
    let mut bytes: Vec<u8> = Vec::new();
    bytes.extend_from_slice(&estate_uuid.to_be_bytes());     // 16
    bytes.extend_from_slice(&row_id.0.to_be_bytes());        // 16
    bytes.extend_from_slice(&hlc.wire_bytes());              // 16
    bytes.extend_from_slice(verb.as_bytes());
    bytes.push(0);
    bytes.extend_from_slice(&(after.0 as u64).to_be_bytes());
    bytes.extend_from_slice(&(after.1 as u64).to_be_bytes());
    bytes.extend_from_slice(&(after.2 as u64).to_be_bytes());
    bytes.extend_from_slice(&after_anchor.udc_code.to_be_bytes());
    bytes.extend_from_slice(&after_anchor.qid_pointer.to_be_bytes());
    let h = sha256::hash(&bytes);
    let mut id = [0u8; 16];
    id.copy_from_slice(&h[0..16]);
    u128::from_be_bytes(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ch() -> FieldSlot { FieldSlot::with_values(Column::Operational, 0, 4, "captureChannel", &[0,1,2,3,4,5]) }
    fn anchor() -> LatticeAnchor { LatticeAnchor::new(1, 0) }
    fn hlc(p: i64) -> HLC { HLC::new(p, 0, 0) }
    fn voc(u: Vec<FieldSlot>) -> Vocabulary { freeze(u).unwrap() }

    #[test]
    fn no_clobber() {
        let prior_adj = bit_field::write_field(3, 0, 18, 6) as u64; // trust=3
        let prior = BitmapFields { adjective: prior_adj, operational: 0xFF, provenance: 0 };
        let r = admit(1, RowId(2), NounType::Drawer, RowVerb::Mutate, Some(prior), Some(anchor()),
            &[FieldWrite { slot: ch(), value: 5 }], anchor(), &voc(vec![ch()]), hlc(1), "t");
        let ev = r.unwrap();
        assert_eq!((ev.after_bitmaps.0 >> 18) & 0x3F, 3);   // trust preserved
        assert_eq!(ev.after_bitmaps.1 & 0xF, 5);            // channel written
        assert_eq!((ev.after_bitmaps.1 >> 4) & 0xF, 0xF);   // neighbor preserved
    }

    #[test]
    fn undeclared_field_rejected() {
        let bogus = FieldSlot::new(Column::Provenance, 0, 4, "undeclared");
        let r = admit(1, RowId(2), NounType::Drawer, RowVerb::Mutate, None, None,
            &[FieldWrite { slot: bogus, value: 1 }], anchor(), &voc(vec![ch()]), hlc(1), "t");
        assert!(matches!(r, Err(GateViolation::UndeclaredField(_))));
    }

    #[test]
    fn illegal_value_rejected() {
        let r = admit(1, RowId(2), NounType::Drawer, RowVerb::Mutate, None, None,
            &[FieldWrite { slot: ch(), value: 7 }], anchor(), &voc(vec![ch()]), hlc(1), "t");
        assert!(matches!(r, Err(GateViolation::IllegalValue(_, 7))));
    }

    #[test]
    fn over_width_value_rejected_not_truncated() {
        let wide = FieldSlot::new(Column::Operational, 0, 4, "wide");
        let r = admit(1, RowId(2), NounType::Drawer, RowVerb::Mutate, None, None,
            &[FieldWrite { slot: wide, value: 20 }], anchor(), &voc(vec![FieldSlot::new(Column::Operational,0,4,"wide")]), hlc(1), "t");
        assert!(matches!(r, Err(GateViolation::IllegalValue(_, 20))));
    }

    #[test]
    fn illegal_transition_rejected() {
        let prior_adj = bit_field::write_field(RowState::Tombstoned as i64, 0, 0, 6) as u64;
        let prior = BitmapFields { adjective: prior_adj, operational: 0, provenance: 0 };
        let state_slot = FieldSlot::new(Column::Adjective, 0, 6, "state");
        let r = admit(1, RowId(2), NounType::Drawer, RowVerb::Mutate, Some(prior), Some(anchor()),
            &[FieldWrite { slot: state_slot, value: RowState::Active as i64 }], anchor(), &voc(vec![]), hlc(1), "t");
        assert!(matches!(r, Err(GateViolation::BasisViolation(_))));
    }

    #[test]
    fn content_id_deterministic() {
        let mk = || admit(1, RowId(2), NounType::Drawer, RowVerb::Capture, None, None,
            &[FieldWrite { slot: ch(), value: 2 }], anchor(), &voc(vec![ch()]), hlc(7), "t").unwrap().event_id;
        assert_eq!(mk(), mk());
    }

    #[test]
    fn freeze_rejects_overlap() {
        let a = FieldSlot::new(Column::Operational, 0, 4, "a");
        let b = FieldSlot::new(Column::Operational, 2, 4, "b");
        assert!(matches!(freeze(vec![a, b]), Err(VocabularyError::Overlap(_, _))));
    }

    #[test]
    fn freeze_rejects_basis_collision() {
        let c = FieldSlot::new(Column::Adjective, 0, 6, "myState");
        assert!(matches!(freeze(vec![c]), Err(VocabularyError::BasisCollision(_))));
    }

    #[test]
    fn freeze_rejects_malformed_width() {
        let bad = FieldSlot::new(Column::Operational, 60, 8, "runsPast64");
        assert!(matches!(freeze(vec![bad]), Err(VocabularyError::MalformedWidth(_))));
    }

    #[test]
    fn freeze_accepts_clean() {
        assert!(freeze(vec![ch()]).is_ok());
    }

    #[test]
    fn state_inconsistent_with_verb_rejected() {
        let prior = BitmapFields { adjective: 0, operational: 0, provenance: 0 }; // active
        let state_slot = FieldSlot::with_values(Column::Adjective, 0, 6, "state", &[0,1,2,3,16,17,18,19,32,33]);
        // write accepted(3) but verb=mutate (active->active). Inconsistent.
        let r = admit(1, RowId(2), NounType::Drawer, RowVerb::Mutate, Some(prior), Some(anchor()),
            &[FieldWrite { slot: state_slot, value: RowState::Accepted as i64 }], anchor(), &voc(vec![]), hlc(1), "t");
        assert!(matches!(r, Err(GateViolation::StateInconsistentWithVerb(_))));
    }

    #[test]
    fn basis_value_rejected() {
        let prior = BitmapFields { adjective: 0, operational: 0, provenance: 0 };
        let sens = FieldSlot::with_values(Column::Adjective, 6, 6, "sensitivity", &[0,16,32,48]);
        let r = admit(1, RowId(2), NounType::Drawer, RowVerb::Mutate, Some(prior), Some(anchor()),
            &[FieldWrite { slot: sens, value: 7 }], anchor(), &voc(vec![]), hlc(1), "t");
        assert!(matches!(r, Err(GateViolation::IllegalValue(_, 7))));
    }

    #[test]
    fn capture_requires_capture_verb() {
        let r = admit(1, RowId(2), NounType::Drawer, RowVerb::Mutate, None, None,
            &[FieldWrite { slot: ch(), value: 1 }], anchor(), &voc(vec![ch()]), hlc(1), "t");
        assert!(matches!(r, Err(GateViolation::StateInconsistentWithVerb(_))));
    }

    // Basis legalValues are derived from the typed AUDIT_*_VALUES constants,
    // not inline literals. Verify each slot's value set equals the constant.
    #[test]
    fn basis_legal_values_derived_from_typed_constants() {
        let b = basis();
        let state = b.iter().find(|s| s.label == "state").unwrap();
        let sens  = b.iter().find(|s| s.label == "sensitivity").unwrap();
        let exp   = b.iter().find(|s| s.label == "exportability").unwrap();
        let trust = b.iter().find(|s| s.label == "trust").unwrap();
        assert_eq!(state.legal_values, AUDIT_STATE_VALUES.iter().copied().collect::<HashSet<_>>());
        assert_eq!(sens.legal_values,  AUDIT_SENSITIVITY_VALUES.iter().copied().collect::<HashSet<_>>());
        assert_eq!(exp.legal_values,   AUDIT_EXPORTABILITY_VALUES.iter().copied().collect::<HashSet<_>>());
        assert_eq!(trust.legal_values, AUDIT_TRUST_VALUES.iter().copied().collect::<HashSet<_>>());
    }

    // Shared cross-leg content-ID vector. The hex is asserted identically
    // in AuditGateTests.swift (M8 byte-parity).
    #[test]
    fn content_id_shared_vector() {
        let cid = content_id(1, RowId(2), &hlc(7), "mutate", (0, 2, 0), anchor());
        assert_eq!(format!("{:032x}", cid), SHARED_VECTOR_HEX);
    }
}

#[cfg(test)]
pub const SHARED_VECTOR_HEX: &str = "eba1f4509f84abe2a472d99fb621334b";
