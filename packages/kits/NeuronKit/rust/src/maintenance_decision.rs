//! The deterministic DECISION CORE of the maintenance daemon's cycle
//! (NEURONKIT_SPEC § 3.2 + § 3.5 steps 0-5), the Rust side of NeuronKit's
//! Swift-parity Bucket A. Mirrors `MaintenanceDecision.swift` field for
//! field; both gate on the shared fixtures below.
//!
//! The Swift `MaintenanceDaemon` actor owns the async seam reads, the I-3
//! forbidden-combination bitmap read on the substrate `Drawer` type, the
//! GLK-owned `AuditChainVerifier.verify` call, the `now`-relative age
//! subtractions, the proposal emission, and the per-category
//! `ProposeFrame` + justification construction. This module — like its
//! Swift twin — owns only the DECISIONS that need no substrate type: the
//! six scan-category KEY FORMATS, the SCAN ORDERING into one emission
//! list, the threshold predicates (decay/tombstone strict `>`; fingerprint
//! / byReference `>=`), the crosser COUNTS, and the B-4 idempotency dedup.
//!
//! There is no Rust maintenance actor: the seam I/O and the bitmap /
//! audit-verify reads are estate-bound (Bucket B, waiting on the Rust
//! LocusKit estate + the GLK audit verifier's own Rust lane). The decision
//! logic is pure, so it ports now and is conformance-gated.

use std::collections::BTreeSet;

/// The scan category a decision came from, so the actor maps it to the
/// right proposal kind + justification. Declaration order is the emission
/// order within a cycle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Category {
    AuditIntegrity,
    DisciplineViolation,
    Decay,
    Tombstone,
    FingerprintDrift,
    ByReferenceDrift,
}

/// One emit decision: idempotency `key`, proposal `target`, `category`, and
/// an optional raw `detail_value` (the drift fraction for the two drift
/// categories, `None` otherwise) — a raw number, not formatted text, so it
/// carries identically across the language boundary.
#[derive(Clone, Debug, PartialEq)]
pub struct Decision {
    pub key: String,
    pub target: String,
    pub category: Category,
    pub detail_value: Option<f32>,
}

/// The audit-chain monitor's pre-computed verdict for this cycle (step 0).
/// The Swift actor runs the GLK verifier and passes the result in; `None`
/// means the audit-check cadence had not elapsed, so no audit decision.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AuditVerdict {
    pub valid: bool,
    /// Epoch milliseconds of the first broken entry; `None` falls back to
    /// the `"unknown"` stable tag so a break is never lost.
    pub first_broken_at_millis: Option<i64>,
}

/// An id paired with an age in seconds (the actor computes `now - filedAt`
/// / `now - tombstonedAt`), input to the decay and tombstone scans.
#[derive(Clone, Debug, PartialEq)]
pub struct AgedRow {
    pub id: String,
    pub age_seconds: f64,
}

/// A scope/reference key paired with a drift fraction in `[0, 1]`, input to
/// the fingerprint-drift and byReference-validity scans.
#[derive(Clone, Debug, PartialEq)]
pub struct DriftRow {
    pub key: String,
    pub drift_fraction: f32,
}

/// The cycle's decisions. `emitted` is in scan order; the `*_candidates`
/// counts are threshold-crossers (counted whether or not the B-4 dedup
/// suppressed them — matching the daemon's report semantics).
#[derive(Clone, Debug, PartialEq)]
pub struct Outcome {
    pub emitted: Vec<Decision>,
    pub suppressed_duplicates: usize,
    pub forbidden_combinations: usize,
    pub decay_candidates: usize,
    pub tombstone_candidates: usize,
    pub fingerprint_drifts: usize,
    pub by_reference_drifts: usize,
    pub updated_proposed_keys: BTreeSet<String>,
}

/// The stable broken-entry tag for the audit key/target: the first-broken
/// epoch-milliseconds string, or `"unknown"`. Matches
/// `MaintenanceDecision.brokenTag`.
pub fn broken_tag(first_broken_at_millis: Option<i64>) -> String {
    match first_broken_at_millis {
        Some(ms) => ms.to_string(),
        None => "unknown".to_string(),
    }
}

/// Inputs to one maintenance cycle decision (steps 0-5). Grouped into a
/// struct so the call site stays readable; mirrors the Swift `decide`
/// parameter list one-for-one.
pub struct Inputs<'a> {
    pub audit: Option<AuditVerdict>,
    pub forbidden_drawer_ids: &'a [String],
    pub aged_active: &'a [AgedRow],
    pub decay_window_seconds: f64,
    pub aged_tombstoned: &'a [AgedRow],
    pub tombstone_grace_seconds: f64,
    pub fingerprint_drift: &'a [DriftRow],
    pub fingerprint_drift_threshold: f32,
    pub reference_drift: &'a [DriftRow],
    pub by_reference_drift_threshold: f32,
    pub already_proposed_keys: &'a BTreeSet<String>,
}

/// Decide one maintenance cycle over pre-gathered inputs (steps 0-5).
///
/// Decay/tombstone use a strict `>` age comparison; fingerprint /
/// byReference use an inclusive `>=` drift comparison. A crosser whose key
/// is already proposed (prior cycle or earlier this cycle) is suppressed
/// and counted in `suppressed_duplicates` but still counted as a crosser
/// in its category total — mirroring the actor's count-then-register order.
pub fn decide(input: &Inputs) -> Outcome {
    let mut emitted: Vec<Decision> = Vec::new();
    let mut suppressed = 0usize;
    let mut proposed: BTreeSet<String> = input.already_proposed_keys.clone();

    // consider(): emit iff the key is new, else suppress. Insert-on-emit
    // gives both cross-cycle and within-cycle dedup. A free function (not a
    // closure) so it does not hold a long-lived borrow on the accumulators.
    fn consider(
        proposed: &mut BTreeSet<String>,
        emitted: &mut Vec<Decision>,
        suppressed: &mut usize,
        key: String,
        target: String,
        category: Category,
        detail_value: Option<f32>,
    ) {
        if proposed.contains(&key) {
            *suppressed += 1;
        } else {
            proposed.insert(key.clone());
            emitted.push(Decision { key, target, category, detail_value });
        }
    }

    // Step 0: audit-chain integrity.
    if let Some(audit) = input.audit {
        if !audit.valid {
            let tag = broken_tag(audit.first_broken_at_millis);
            consider(
                &mut proposed, &mut emitted, &mut suppressed,
                format!("audit_integrity|{tag}"),
                format!("audit-break-{tag}"),
                Category::AuditIntegrity,
                None,
            );
        }
    }

    // Step 1: forbidden-combination scan (invariant I-3).
    let forbidden_combinations = input.forbidden_drawer_ids.len();
    for id in input.forbidden_drawer_ids {
        consider(
            &mut proposed, &mut emitted, &mut suppressed,
            format!("discipline|{id}"), id.clone(), Category::DisciplineViolation, None,
        );
    }

    // Step 2: decay-candidate scan (strict age > window).
    let mut decay_candidates = 0usize;
    for row in input.aged_active {
        if row.age_seconds > input.decay_window_seconds {
            decay_candidates += 1;
            consider(
                &mut proposed, &mut emitted, &mut suppressed,
                format!("decay|{}", row.id), row.id.clone(), Category::Decay, None,
            );
        }
    }

    // Step 3: tombstone/expunge scan (strict age > grace).
    let mut tombstone_candidates = 0usize;
    for row in input.aged_tombstoned {
        if row.age_seconds > input.tombstone_grace_seconds {
            tombstone_candidates += 1;
            consider(
                &mut proposed, &mut emitted, &mut suppressed,
                format!("tombstone|{}", row.id), row.id.clone(), Category::Tombstone, None,
            );
        }
    }

    // Step 4: fingerprint-drift scan (inclusive drift >= threshold).
    let mut fingerprint_drifts = 0usize;
    for row in input.fingerprint_drift {
        if row.drift_fraction >= input.fingerprint_drift_threshold {
            fingerprint_drifts += 1;
            consider(
                &mut proposed, &mut emitted, &mut suppressed,
                format!("fingerprint_drift|{}", row.key),
                row.key.clone(),
                Category::FingerprintDrift,
                Some(row.drift_fraction),
            );
        }
    }

    // Step 5: byReference-validity scan (inclusive drift >= threshold).
    let mut by_reference_drifts = 0usize;
    for row in input.reference_drift {
        if row.drift_fraction >= input.by_reference_drift_threshold {
            by_reference_drifts += 1;
            consider(
                &mut proposed, &mut emitted, &mut suppressed,
                format!("byref|{}", row.key),
                row.key.clone(),
                Category::ByReferenceDrift,
                Some(row.drift_fraction),
            );
        }
    }

    Outcome {
        emitted,
        suppressed_duplicates: suppressed,
        forbidden_combinations,
        decay_candidates,
        tombstone_candidates,
        fingerprint_drifts,
        by_reference_drifts,
        updated_proposed_keys: proposed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn aged(id: &str, age: f64) -> AgedRow {
        AgedRow { id: id.to_string(), age_seconds: age }
    }
    fn drift(key: &str, f: f32) -> DriftRow {
        DriftRow { key: key.to_string(), drift_fraction: f }
    }

    // A cycle with one crosser in every scan category. Mirrors the Swift
    // C3 test: five proposals, one per category, in scan order.
    fn full_inputs<'a>(
        forbidden: &'a [String],
        active: &'a [AgedRow],
        tombstoned: &'a [AgedRow],
        fp: &'a [DriftRow],
        refs: &'a [DriftRow],
        seen: &'a BTreeSet<String>,
    ) -> Inputs<'a> {
        Inputs {
            audit: Some(AuditVerdict { valid: true, first_broken_at_millis: None }),
            forbidden_drawer_ids: forbidden,
            aged_active: active,
            decay_window_seconds: 2_592_000.0,
            aged_tombstoned: tombstoned,
            tombstone_grace_seconds: 604_800.0,
            fingerprint_drift: fp,
            fingerprint_drift_threshold: 0.25,
            reference_drift: refs,
            by_reference_drift_threshold: 0.25,
            already_proposed_keys: seen,
        }
    }

    // MD-1: all five scan categories emit, in scan order; a valid audit
    // chain adds no audit proposal. (Swift C3.)
    #[test]
    fn md1_all_five_categories_emit_in_order() {
        let forbidden = vec!["d-forbidden".to_string()];
        let active = vec![aged("d-old", 3_000_000.0), aged("d-forbidden", 1.0)];
        let tombstoned = vec![aged("d-tomb", 700_000.0)];
        let fp = vec![drift("wing_a/room_b", 0.5)];
        let refs = vec![drift("ref-1", 0.5)];
        let seen = BTreeSet::new();
        let out = decide(&full_inputs(&forbidden, &active, &tombstoned, &fp, &refs, &seen));

        assert_eq!(out.emitted.len(), 5, "one proposal per scan category");
        assert_eq!(out.forbidden_combinations, 1);
        assert_eq!(out.decay_candidates, 1);
        assert_eq!(out.tombstone_candidates, 1);
        assert_eq!(out.fingerprint_drifts, 1);
        assert_eq!(out.by_reference_drifts, 1);
        // Scan order: discipline, decay, tombstone, fingerprint, byref
        // (no audit decision because the chain is valid).
        let cats: Vec<Category> = out.emitted.iter().map(|d| d.category).collect();
        assert_eq!(
            cats,
            vec![
                Category::DisciplineViolation,
                Category::Decay,
                Category::Tombstone,
                Category::FingerprintDrift,
                Category::ByReferenceDrift,
            ]
        );
        // Drift categories carry their fraction; the others carry none.
        let fp_d = out.emitted.iter().find(|d| d.category == Category::FingerprintDrift).unwrap();
        assert_eq!(fp_d.detail_value, Some(0.5));
        assert_eq!(fp_d.key, "fingerprint_drift|wing_a/room_b");
    }

    // MD-2: a tampered audit chain emits exactly the audit-integrity
    // decision; target is audit-break-<millis>. (Swift C4, broken at 2000.)
    #[test]
    fn md2_tampered_audit_emits_integrity_decision() {
        let empty: Vec<String> = vec![];
        let no_aged: Vec<AgedRow> = vec![];
        let no_drift: Vec<DriftRow> = vec![];
        let seen = BTreeSet::new();
        let input = Inputs {
            audit: Some(AuditVerdict { valid: false, first_broken_at_millis: Some(2000) }),
            forbidden_drawer_ids: &empty,
            aged_active: &no_aged,
            decay_window_seconds: 2_592_000.0,
            aged_tombstoned: &no_aged,
            tombstone_grace_seconds: 604_800.0,
            fingerprint_drift: &no_drift,
            fingerprint_drift_threshold: 0.25,
            reference_drift: &no_drift,
            by_reference_drift_threshold: 0.25,
            already_proposed_keys: &seen,
        };
        let out = decide(&input);
        assert_eq!(out.emitted.len(), 1, "exactly the audit-integrity proposal");
        let d = &out.emitted[0];
        assert_eq!(d.category, Category::AuditIntegrity);
        assert_eq!(d.target, "audit-break-2000");
        assert_eq!(d.key, "audit_integrity|2000");
    }

    // MD-3: a clean chain proposes nothing for the audit category.
    // (Swift C4 clean.)
    #[test]
    fn md3_clean_audit_proposes_nothing() {
        let empty: Vec<String> = vec![];
        let no_aged: Vec<AgedRow> = vec![];
        let no_drift: Vec<DriftRow> = vec![];
        let seen = BTreeSet::new();
        let out = decide(&full_inputs(&empty, &no_aged, &no_aged, &no_drift, &no_drift, &seen));
        assert_eq!(out.emitted.len(), 0, "clean chain, no crossers, proposes nothing");
    }

    // MD-4: a second cycle over unchanged state proposes nothing new — all
    // five are suppressed by the B-4 idempotency memory. (Swift B4.)
    #[test]
    fn md4_second_cycle_suppresses_all() {
        let forbidden = vec!["d-forbidden".to_string()];
        let active = vec![aged("d-old", 3_000_000.0), aged("d-forbidden", 1.0)];
        let tombstoned = vec![aged("d-tomb", 700_000.0)];
        let fp = vec![drift("wing_a/room_b", 0.5)];
        let refs = vec![drift("ref-1", 0.5)];
        let seen = BTreeSet::new();
        let first = decide(&full_inputs(&forbidden, &active, &tombstoned, &fp, &refs, &seen));
        assert_eq!(first.emitted.len(), 5);

        let second = decide(&full_inputs(
            &forbidden, &active, &tombstoned, &fp, &refs, &first.updated_proposed_keys,
        ));
        assert_eq!(second.emitted.len(), 0, "already-proposed candidates suppressed");
        assert_eq!(second.suppressed_duplicates, 5);
        // Counts still report the crossers even when all were suppressed.
        assert_eq!(second.decay_candidates, 1);
        assert_eq!(second.forbidden_combinations, 1);
    }

    // MD-5: the decay/tombstone gate is STRICT `>` — a row exactly at the
    // window is not a candidate; drift gate is INCLUSIVE `>=` — a row
    // exactly at the threshold is.
    #[test]
    fn md5_boundary_strictness() {
        let empty: Vec<String> = vec![];
        let at_window = vec![aged("d", 2_592_000.0)]; // exactly the window
        let no_aged: Vec<AgedRow> = vec![];
        let at_thresh = vec![drift("s", 0.25)]; // exactly the threshold
        let no_drift: Vec<DriftRow> = vec![];
        let seen = BTreeSet::new();

        let decay = decide(&full_inputs(&empty, &at_window, &no_aged, &no_drift, &no_drift, &seen));
        assert_eq!(decay.decay_candidates, 0, "strict > excludes the exact window");

        let fp = decide(&full_inputs(&empty, &no_aged, &no_aged, &at_thresh, &no_drift, &seen));
        assert_eq!(fp.fingerprint_drifts, 1, "inclusive >= includes the exact threshold");
    }
}
