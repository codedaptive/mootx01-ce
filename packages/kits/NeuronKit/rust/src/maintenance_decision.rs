//! The deterministic DECISION CORE of the maintenance daemon's cycle
//! (NEURONKIT_SPEC § 3.2 + § 3.5 steps 0-3), the Rust side of NeuronKit's
//! Swift-parity Bucket A. Mirrors `MaintenanceDecision.swift` field for
//! field; both gate on the shared fixtures below.
//!
//! The Swift `MaintenanceDaemon` actor owns the async seam reads, the
//! GLK-owned `AuditChainVerifier.verify` call, the `now`-relative age
//! subtractions, the proposal emission, and the per-category
//! `ProposeFrame` + justification construction. This module — like its
//! Swift twin — owns only the DECISIONS that need no substrate type: the
//! four scan-category KEY FORMATS, the SCAN ORDERING into one emission
//! list, the threshold predicates (decay/tombstone strict `>`; byReference
//! `>=`), the crosser COUNTS, and the B-4 idempotency dedup.
//!
//! There is no Rust maintenance actor: the seam I/O and the bitmap /
//! audit-verify reads are estate-bound (Bucket B, waiting on the Rust
//! LocusKit estate + the GLK audit verifier's own Rust lane). The decision
//! logic is pure, so it ships in Rust now and is conformance-gated.

use std::collections::BTreeSet;

/// The scan category a decision came from, so the actor maps it to the
/// right proposal kind + justification. Declaration order is the emission
/// order within a cycle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Category {
    AuditIntegrity,
    Decay,
    Tombstone,
    ByReferenceDrift,
}

/// One emit decision: idempotency `key`, proposal `target`, `category`, and
/// an optional raw `detail_value` (the drift fraction for the
/// byReference-drift category, `None` otherwise) — a raw number, not formatted text, so it
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
    /// Number of entries `UnifiedAuditLog` rejected at ingress
    /// (content-hash mismatch) while building the snapshot this verdict
    /// is derived from. AUDIT-ALERT-RESTORE (2026-07-09): ingress
    /// rejection means a tampered entry never reaches the chain walk, so
    /// `valid` alone can no longer surface tampering — `decide` step 0
    /// alerts on this count independently of `valid`. Mirrors the Swift
    /// `MaintenanceDecision.AuditVerdict.rejectedEntryCount`.
    pub rejected_entry_count: usize,
}

/// An id paired with an age in seconds (the actor computes `now - filedAt`
/// / `now - tombstonedAt`), input to the decay and tombstone scans.
#[derive(Clone, Debug, PartialEq)]
pub struct AgedRow {
    pub id: String,
    pub age_seconds: f64,
}

/// A scope/reference key paired with a drift fraction in `[0, 1]`, input to
/// the byReference-validity scan.
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
    pub decay_candidates: usize,
    pub tombstone_candidates: usize,
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

/// Inputs to one maintenance cycle decision (steps 0-3). Grouped into a
/// struct so the call site stays readable; mirrors the Swift `decide`
/// parameter list one-for-one.
pub struct Inputs<'a> {
    pub audit: Option<AuditVerdict>,
    pub aged_active: &'a [AgedRow],
    pub decay_window_seconds: f64,
    pub aged_tombstoned: &'a [AgedRow],
    pub tombstone_grace_seconds: f64,
    pub reference_drift: &'a [DriftRow],
    pub by_reference_drift_threshold: f32,
    pub already_proposed_keys: &'a BTreeSet<String>,
}

/// Decide one maintenance cycle over pre-gathered inputs (steps 0-3).
///
/// Decay/tombstone use a strict `>` age comparison; byReference uses an
/// inclusive `>=` drift comparison. A crosser whose key
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
            emitted.push(Decision {
                key,
                target,
                category,
                detail_value,
            });
        }
    }

    // Step 0: audit-chain integrity. Two independent alert conditions,
    // checked separately so a cycle that somehow trips both (a broken
    // chain AND ingress rejections) gets a proposal for each — they are
    // different failure modes with different remediation targets. Mirrors
    // `MaintenanceDecision.decide` step 0 (Swift).
    if let Some(audit) = input.audit {
        // (a) The walked chain itself broke (HLC reversal, or a
        // content-hash mismatch on an entry that somehow reached the
        // walk — defence in depth; ingress rejection normally prevents
        // this). Pre-existing behavior, unchanged.
        if !audit.valid {
            let tag = broken_tag(audit.first_broken_at_millis);
            consider(
                &mut proposed,
                &mut emitted,
                &mut suppressed,
                format!("audit_integrity|{tag}"),
                format!("audit-break-{tag}"),
                Category::AuditIntegrity,
                None,
            );
        }
        // (b) AUDIT-ALERT-RESTORE (2026-07-09): entries were rejected at
        // ingress before they ever reached the walk, so `valid` alone
        // cannot surface this. Keyed on the rejected count rather than a
        // fixed tag: a steady/unchanged count is suppressed like any
        // other B-4 duplicate (already alerted), but a NEW, larger count
        // (more tampering since the last alert) gets its own key and
        // proposes again.
        if audit.rejected_entry_count > 0 {
            consider(
                &mut proposed,
                &mut emitted,
                &mut suppressed,
                format!("audit_integrity_rejected|{}", audit.rejected_entry_count),
                format!("audit-rejected-{}", audit.rejected_entry_count),
                Category::AuditIntegrity,
                None,
            );
        }
    }

    // Step 1: decay-candidate scan (strict age > window).
    let mut decay_candidates = 0usize;
    for row in input.aged_active {
        if row.age_seconds > input.decay_window_seconds {
            decay_candidates += 1;
            consider(
                &mut proposed,
                &mut emitted,
                &mut suppressed,
                format!("decay|{}", row.id),
                row.id.clone(),
                Category::Decay,
                None,
            );
        }
    }

    // Step 2: tombstone/expunge scan (strict age > grace).
    let mut tombstone_candidates = 0usize;
    for row in input.aged_tombstoned {
        if row.age_seconds > input.tombstone_grace_seconds {
            tombstone_candidates += 1;
            consider(
                &mut proposed,
                &mut emitted,
                &mut suppressed,
                format!("tombstone|{}", row.id),
                row.id.clone(),
                Category::Tombstone,
                None,
            );
        }
    }

    // Step 3: byReference-validity scan (inclusive drift >= threshold).
    let mut by_reference_drifts = 0usize;
    for row in input.reference_drift {
        if row.drift_fraction >= input.by_reference_drift_threshold {
            by_reference_drifts += 1;
            consider(
                &mut proposed,
                &mut emitted,
                &mut suppressed,
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
        decay_candidates,
        tombstone_candidates,
        by_reference_drifts,
        updated_proposed_keys: proposed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn aged(id: &str, age: f64) -> AgedRow {
        AgedRow {
            id: id.to_string(),
            age_seconds: age,
        }
    }
    fn drift(key: &str, f: f32) -> DriftRow {
        DriftRow {
            key: key.to_string(),
            drift_fraction: f,
        }
    }

    // A cycle with one crosser in every scan category. Mirrors the Swift
    // C3 test: three proposals, one per category, in scan order.
    fn full_inputs<'a>(
        active: &'a [AgedRow],
        tombstoned: &'a [AgedRow],
        refs: &'a [DriftRow],
        seen: &'a BTreeSet<String>,
    ) -> Inputs<'a> {
        Inputs {
            audit: Some(AuditVerdict {
                valid: true,
                first_broken_at_millis: None,
                rejected_entry_count: 0,
            }),
            aged_active: active,
            decay_window_seconds: 2_592_000.0,
            aged_tombstoned: tombstoned,
            tombstone_grace_seconds: 604_800.0,
            reference_drift: refs,
            by_reference_drift_threshold: 0.25,
            already_proposed_keys: seen,
        }
    }

    // MD-1: all three scan categories emit, in scan order; a valid audit
    // chain adds no audit proposal. (Swift C3.)
    #[test]
    fn md1_all_three_categories_emit_in_order() {
        let active = vec![aged("d-old", 3_000_000.0), aged("d-new", 1.0)];
        let tombstoned = vec![aged("d-tomb", 700_000.0)];
        let refs = vec![drift("ref-1", 0.5)];
        let seen = BTreeSet::new();
        let out = decide(&full_inputs(&active, &tombstoned, &refs, &seen));

        assert_eq!(out.emitted.len(), 3, "one proposal per scan category");
        assert_eq!(out.decay_candidates, 1);
        assert_eq!(out.tombstone_candidates, 1);
        assert_eq!(out.by_reference_drifts, 1);
        // Scan order: decay, tombstone, byref (no audit decision because
        // the chain is valid).
        let cats: Vec<Category> = out.emitted.iter().map(|d| d.category).collect();
        assert_eq!(
            cats,
            vec![
                Category::Decay,
                Category::Tombstone,
                Category::ByReferenceDrift,
            ]
        );
        // The drift category carries its fraction; the others carry none.
        let ref_d = out
            .emitted
            .iter()
            .find(|d| d.category == Category::ByReferenceDrift)
            .unwrap();
        assert_eq!(ref_d.detail_value, Some(0.5));
        assert_eq!(ref_d.key, "byref|ref-1");
    }

    // MD-2: a tampered audit chain emits exactly the audit-integrity
    // decision; target is audit-break-<millis>. (Swift C4, broken at 2000.)
    #[test]
    fn md2_tampered_audit_emits_integrity_decision() {
        let no_aged: Vec<AgedRow> = vec![];
        let no_drift: Vec<DriftRow> = vec![];
        let seen = BTreeSet::new();
        let input = Inputs {
            audit: Some(AuditVerdict {
                valid: false,
                first_broken_at_millis: Some(2000),
                rejected_entry_count: 0,
            }),
            aged_active: &no_aged,
            decay_window_seconds: 2_592_000.0,
            aged_tombstoned: &no_aged,
            tombstone_grace_seconds: 604_800.0,
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

    // MD-2b: AUDIT-ALERT-RESTORE (2026-07-09) — a valid chain (ingress
    // already rejected the tampered entries, so the walk itself is clean)
    // still emits an audit-integrity decision when rejected_entry_count > 0,
    // keyed distinctly from the broken-chain case.
    #[test]
    fn md2b_valid_chain_with_rejections_emits_integrity_decision() {
        let no_aged: Vec<AgedRow> = vec![];
        let no_drift: Vec<DriftRow> = vec![];
        let seen = BTreeSet::new();
        let input = Inputs {
            audit: Some(AuditVerdict {
                valid: true,
                first_broken_at_millis: None,
                rejected_entry_count: 1,
            }),
            aged_active: &no_aged,
            decay_window_seconds: 2_592_000.0,
            aged_tombstoned: &no_aged,
            tombstone_grace_seconds: 604_800.0,
            reference_drift: &no_drift,
            by_reference_drift_threshold: 0.25,
            already_proposed_keys: &seen,
        };
        let out = decide(&input);
        assert_eq!(out.emitted.len(), 1, "exactly the ingress-rejection integrity proposal");
        let d = &out.emitted[0];
        assert_eq!(d.category, Category::AuditIntegrity);
        assert_eq!(d.target, "audit-rejected-1");
        assert_eq!(d.key, "audit_integrity_rejected|1");
    }

    // MD-2c: a second cycle with the SAME rejected count is suppressed as a
    // B-4 duplicate (already alerted); a cycle with a LARGER count proposes
    // again under a new key.
    #[test]
    fn md2c_same_rejected_count_suppressed_larger_count_proposes_again() {
        let no_aged: Vec<AgedRow> = vec![];
        let no_drift: Vec<DriftRow> = vec![];
        let seen = BTreeSet::new();
        let first = decide(&Inputs {
            audit: Some(AuditVerdict { valid: true, first_broken_at_millis: None, rejected_entry_count: 1 }),
            aged_active: &no_aged,
            decay_window_seconds: 2_592_000.0,
            aged_tombstoned: &no_aged,
            tombstone_grace_seconds: 604_800.0,
            reference_drift: &no_drift,
            by_reference_drift_threshold: 0.25,
            already_proposed_keys: &seen,
        });
        assert_eq!(first.emitted.len(), 1);

        let second = decide(&Inputs {
            audit: Some(AuditVerdict { valid: true, first_broken_at_millis: None, rejected_entry_count: 1 }),
            aged_active: &no_aged,
            decay_window_seconds: 2_592_000.0,
            aged_tombstoned: &no_aged,
            tombstone_grace_seconds: 604_800.0,
            reference_drift: &no_drift,
            by_reference_drift_threshold: 0.25,
            already_proposed_keys: &first.updated_proposed_keys,
        });
        assert_eq!(second.emitted.len(), 0, "identical rejected count already alerted");
        assert_eq!(second.suppressed_duplicates, 1);

        let third = decide(&Inputs {
            audit: Some(AuditVerdict { valid: true, first_broken_at_millis: None, rejected_entry_count: 2 }),
            aged_active: &no_aged,
            decay_window_seconds: 2_592_000.0,
            aged_tombstoned: &no_aged,
            tombstone_grace_seconds: 604_800.0,
            reference_drift: &no_drift,
            by_reference_drift_threshold: 0.25,
            already_proposed_keys: &second.updated_proposed_keys,
        });
        assert_eq!(third.emitted.len(), 1, "a larger rejected count is a new, unsuppressed alert");
        assert_eq!(third.emitted[0].key, "audit_integrity_rejected|2");
    }

    // MD-3: a clean chain proposes nothing for the audit category.
    // (Swift C4 clean.)
    #[test]
    fn md3_clean_audit_proposes_nothing() {
        let no_aged: Vec<AgedRow> = vec![];
        let no_drift: Vec<DriftRow> = vec![];
        let seen = BTreeSet::new();
        let out = decide(&full_inputs(&no_aged, &no_aged, &no_drift, &seen));
        assert_eq!(
            out.emitted.len(),
            0,
            "clean chain, no crossers, proposes nothing"
        );
    }

    // MD-4: a second cycle over unchanged state proposes nothing new — all
    // three are suppressed by the B-4 idempotency memory. (Swift B4.)
    #[test]
    fn md4_second_cycle_suppresses_all() {
        let active = vec![aged("d-old", 3_000_000.0), aged("d-new", 1.0)];
        let tombstoned = vec![aged("d-tomb", 700_000.0)];
        let refs = vec![drift("ref-1", 0.5)];
        let seen = BTreeSet::new();
        let first = decide(&full_inputs(&active, &tombstoned, &refs, &seen));
        assert_eq!(first.emitted.len(), 3);

        let second = decide(&full_inputs(
            &active,
            &tombstoned,
            &refs,
            &first.updated_proposed_keys,
        ));
        assert_eq!(
            second.emitted.len(),
            0,
            "already-proposed candidates suppressed"
        );
        assert_eq!(second.suppressed_duplicates, 3);
        // Counts still report the crossers even when all were suppressed.
        assert_eq!(second.decay_candidates, 1);
        assert_eq!(second.by_reference_drifts, 1);
    }

    // MD-5: the decay/tombstone gate is STRICT `>` — a row exactly at the
    // window is not a candidate; drift gate is INCLUSIVE `>=` — a row
    // exactly at the threshold is.
    #[test]
    fn md5_boundary_strictness() {
        let at_window = vec![aged("d", 2_592_000.0)]; // exactly the window
        let no_aged: Vec<AgedRow> = vec![];
        let at_thresh = vec![drift("s", 0.25)]; // exactly the threshold
        let no_drift: Vec<DriftRow> = vec![];
        let seen = BTreeSet::new();

        let decay = decide(&full_inputs(&at_window, &no_aged, &no_drift, &seen));
        assert_eq!(
            decay.decay_candidates, 0,
            "strict > excludes the exact window"
        );

        let byref = decide(&full_inputs(&no_aged, &no_aged, &at_thresh, &seen));
        assert_eq!(
            byref.by_reference_drifts, 1,
            "inclusive >= includes the exact threshold"
        );
    }
}
