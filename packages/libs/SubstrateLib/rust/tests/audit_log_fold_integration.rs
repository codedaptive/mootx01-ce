// audit_log_fold_integration.rs
//
// Integration tests for AuditLogFold (the fold lives in substrate-ml
// after the 2026-05-29 four-package split). These exercise the fold
// against real audit-event streams produced by the verb orchestrator
// `Substrate`, which lives in substrate-lib (verbs). The fold itself
// is in packages/libs/SubstrateML/rust/src/audit_log_fold.rs; this
// integration test lives in substrate-lib to avoid inverting the
// substrate-ml → substrate-lib layering dependency.

use substrate_ml::audit_log_fold::AuditLogFold;
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hlc::HLC;
use substrate_lib::verbs::{LatticeAnchor, MutationKind, NounType, Substrate};

fn anchor() -> LatticeAnchor {
    LatticeAnchor::new(0x0a0a_0000_0000_0000, 0x1234)
}
fn fp() -> Fingerprint256 {
    Fingerprint256 { block0: 0, block1: 0, block2: 0, block3: 0 }
}

#[test]
fn project_single_capture() {
    let mut s = Substrate::new(0xabcd_0000_0000_0000_0000_0000_0000_0000, HLC::new(0, 0, 1));
    let id = s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    let proj = AuditLogFold::project_current_state(id, NounType::Drawer, &s.audit_events).unwrap();
    assert_eq!(proj.state_raw, 0); // active
    assert!(!proj.tombstoned);
}

#[test]
fn project_capture_then_expunge_tombstoned() {
    let mut s = Substrate::new(0xabcd_0000_0000_0000_0000_0000_0000_0000, HLC::new(0, 0, 1));
    let id = s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    s.expunge(id, "reason", "a", 0.0).unwrap();
    let proj = AuditLogFold::project_current_state(id, NounType::Drawer, &s.audit_events).unwrap();
    assert_eq!(proj.state_raw, 33);
    assert!(proj.tombstoned);
}

#[test]
fn project_at_earlier_time() {
    let mut s = Substrate::new(0xabcd_0000_0000_0000_0000_0000_0000_0000, HLC::new(0, 0, 1));
    let id = s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    let hlc_after_capture = s.hlc;
    s.expunge(id, "reason", "a", 0.0).unwrap();
    // At hlc_after_capture, the row was active.
    let earlier = AuditLogFold::project_state_at(
        id, NounType::Drawer, &s.audit_events, hlc_after_capture).unwrap();
    assert_eq!(earlier.state_raw, 0);
    assert!(!earlier.tombstoned);
    // Current state is tombstoned.
    let now = AuditLogFold::project_current_state(
        id, NounType::Drawer, &s.audit_events).unwrap();
    assert!(now.tombstoned);
}

#[test]
fn commutativity_under_permutation() {
    let mut s = Substrate::new(0xabcd_0000_0000_0000_0000_0000_0000_0000, HLC::new(0, 0, 1));
    let adj_pending: i64 = 1 | (2 << 18);
    let id = s.capture(NounType::Proposal, adj_pending, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    let adj_accepted: i64 = 3 | (2 << 18);
    s.mutate(id, MutationKind::Confirm, adj_accepted, None, None, "user", 0.0).unwrap();

    let p1 = AuditLogFold::project_current_state(id, NounType::Proposal, &s.audit_events).unwrap();
    let mut shuffled = s.audit_events.clone();
    shuffled.reverse();
    let p2 = AuditLogFold::project_current_state(id, NounType::Proposal, &shuffled).unwrap();
    assert_eq!(p1, p2); // order-independent
}

#[test]
fn project_all_returns_one_entry_per_row() {
    let mut s = Substrate::new(0xabcd_0000_0000_0000_0000_0000_0000_0000, HLC::new(0, 0, 1));
    let id1 = s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    let id2 = s.capture(NounType::AmbientSample, 0, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    let all = AuditLogFold::project_all(&s.audit_events, None, |rid| {
        if rid == id1 { NounType::Drawer } else { NounType::AmbientSample }
    });
    assert_eq!(all.len(), 2);
    assert!(all.contains_key(&id1));
    assert!(all.contains_key(&id2));
}
