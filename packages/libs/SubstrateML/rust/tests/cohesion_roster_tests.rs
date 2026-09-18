// Pinned vectors shared with CohesionRosterTests.swift (ADR-026).
use substrate_ml::cohesion_roster::CohesionRoster;

const S: i32 = CohesionRoster::SCALE;

fn four() -> CohesionRoster {
    let mut r = CohesionRoster::default();
    r.add("a", "a1", &[]);
    r.add("b", "b1", &[S]);
    r.add("c", "c1", &[S, S]);
    r.add("d", "d1", &[0, 0, 0]);
    r
}

#[test]
fn add_remove_replace() {
    let mut r = four();
    let sums: Vec<(String, i64)> = r.entries().iter().map(|e| (e.id.clone(), e.sum)).collect();
    assert_eq!(sums, vec![("a".into(), 2 * S as i64), ("b".into(), 2 * S as i64), ("c".into(), 2 * S as i64), ("d".into(), 0)]);
    let before = r.clone();
    r.add("e", "e1", &[S / 2, S / 2, S / 2, 0]);
    r.remove("e", &[S / 2, S / 2, S / 2, 0]);
    assert_eq!(r, before, "remove restores the sums bit for bit");
    let mut via_replace = r.clone();
    via_replace.replace("d", "d2", &[0, 0, 0], &[S, S, S]);
    let mut via_steps = r.clone();
    via_steps.remove("d", &[0, 0, 0]);
    via_steps.add("d", "d2", &[S, S, S]);
    assert_eq!(via_replace, via_steps);
    assert!(via_replace.entries().iter().all(|e| e.sum == 3 * S as i64));
}

#[test]
fn flags_vector() {
    let r = four();
    let at = |t: f32| -> Vec<bool> { r.flags(t, 3).into_iter().map(|(_, a)| a).collect() };
    assert_eq!(at(1.5), vec![false, false, false, true]);
    assert_eq!(at(2.0), vec![false, false, false, false]);
    let mut small = CohesionRoster::default();
    small.add("x", "x", &[]);
    small.add("y", "y", &[0]);
    assert_eq!(small.flags(0.1, 3).into_iter().map(|(_, a)| a).collect::<Vec<_>>(), vec![false, false]);
}

#[test]
fn quantise_clamps_and_rounds() {
    assert_eq!(CohesionRoster::quantise(1.0), S);
    assert_eq!(CohesionRoster::quantise(0.5), S / 2);
    assert_eq!(CohesionRoster::quantise(-0.2), 0);
    assert_eq!(CohesionRoster::quantise(1.7), S);
    assert_eq!(CohesionRoster::quantise(f32::NAN), 0);
}
