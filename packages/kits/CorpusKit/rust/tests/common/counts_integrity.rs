//! counts_integrity.rs — store-invariant conformance for the provider counts
//! tables. Rust twin of Swift's `CountsIntegrityRunner`.
//!
//! WHY THIS EXISTS
//!
//! Four separate missions each found a different hole in the same store, and
//! each found it by collision rather than by test:
//!
//!   CT-01           the population guard could disagree with the rows it counted
//!   CT-02           deleting content left its term-dictionary entries behind
//!   CT-02 residual  deleting content left its count_references rows behind
//!   MG-01/m2        a migration-invalidated counts blob was restored as if valid
//!
//! Every one of those missions tested its own change and passed. None could
//! fail on someone else's defect, because no test asks the store whether it is
//! still COHERENT after a mutation. That is the gap this closes.
//!
//! All four defects were in WRITE and DELETE paths, and this port has its own.
//! A Swift-only runner would leave a Rust-side `remove_content` free to strand
//! references with nothing to catch it — the CT-02 residual reappearing one
//! port at a time. That, not symmetry, is why this file exists.
//!
//! USAGE
//!
//! Call `assert_integrity(&storage, "<label>")` at the tail of any test that
//! mutates the counts store. A fifth mission that breaks an invariant then
//! fails on a test it did not write.
//!
//! Each check returns its violations rather than panicking, so the falsification
//! suite can assert that a check DOES fire on the state it rejects. An assertion
//! nobody has seen fail is a claim, not a gate; see
//! `counts_integrity_runner_tests.rs` for the record.
//!
//! PARITY NOTE
//!
//! The Swift twin tests the invalidation sentinel inline (`blob.isEmpty`)
//! because the Swift port has no sentinel predicate. This port calls
//! `is_invalidated_counts`, which its own docs name as the only edit site if
//! the sentinel format ever changes. This port's I-4 is therefore the correct
//! version and Swift's is the compromise; when Swift grows the twin helper,
//! its inline test must become a call.

use corpus_kit::corpus_provider_counts_store::is_invalidated_counts;
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::storage::Storage;
use persistence_kit::types::{Column, TypedValue};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

/// Highest bit position the model registry can assign. Bit 63 is the sign bit
/// and is never assigned (house rule); a set bit at or above this position is
/// itself a defect and is reported as one.
const MAX_MODEL_BIT: u32 = 63;

/// Runs every invariant and panics with all violations if any hold.
///
/// This is the call a mutating test adds. Panicking with the FULL list rather
/// than the first violation matters: a delete path that strands both references
/// and dictionary entries should report both, not send the reader back for a
/// second run to discover the second one.
pub fn assert_integrity(storage: &Arc<dyn Storage>, label: &str) {
    let violations = verify_integrity(storage, label);
    assert!(
        violations.is_empty(),
        "{} counts-store integrity FAILED with {} violation(s):\n  - {}",
        label,
        violations.len(),
        violations.join("\n  - ")
    );
}

/// Runs every invariant and returns the violations found. Empty means coherent.
///
/// Ordering is deliberate: reference integrity first, because a stranded
/// reference is the cheapest to produce and the one whose failure explains the
/// population-guard mismatch that would otherwise be reported alongside it.
pub fn verify_integrity(storage: &Arc<dyn Storage>, label: &str) -> Vec<String> {
    let mut out = Vec::new();
    out.extend(reference_rows_have_live_counts_row(storage, label));
    out.extend(term_dictionary_has_no_orphan_model_bits(storage, label));
    out.extend(term_payload_matches_dictionary(storage, label));
    out.extend(invalidated_counts_has_no_surviving_term_rows(storage, label));
    out
}

// ─── I-1: every reference row has a live counts row ──────────────────────────

/// `corpus_provider_count_references` rows record work pending against a
/// provider generation. A reference whose `(model_id, model_version)` has no
/// counts row is stranded: it inflates the pending side of the population guard
/// against a generation that no longer exists.
///
/// This is the CT-02 residual, found only because a later mission happened to
/// read the delete path. Before the fix, `remove_content` cleared the term
/// dictionary and left these rows, so the guard saw 50 + 2 = 52 where the store
/// held 51.
pub fn reference_rows_have_live_counts_row(
    storage: &Arc<dyn Storage>,
    label: &str,
) -> Vec<String> {
    let rs = storage.row_store();
    let refs = rs
        .query("corpus_provider_count_references", None, &[], None, None)
        .expect("query count_references");
    if refs.is_empty() {
        return Vec::new();
    }

    // One query for the live generations, then a set-membership test per
    // reference — not a query per reference. A store with thousands of pending
    // references must not make this the slow part of a suite.
    let counts_rows = rs
        .query("corpus_provider_counts", None, &[], None, None)
        .expect("query counts");
    let mut live: BTreeSet<(String, String)> = BTreeSet::new();
    for row in &counts_rows {
        if let (Some(TypedValue::Text(m)), Some(TypedValue::Text(v))) =
            (row.get("model_id"), row.get("model_version"))
        {
            live.insert((m.clone(), v.clone()));
        }
    }

    let mut out = Vec::new();
    for row in &refs {
        let (m, v) = match (row.get("model_id"), row.get("model_version")) {
            (Some(TypedValue::Text(m)), Some(TypedValue::Text(v))) => (m.clone(), v.clone()),
            _ => continue,
        };
        if live.contains(&(m.clone(), v.clone())) {
            continue;
        }
        let content = match row.get("content_id") {
            Some(TypedValue::Text(c)) => c.clone(),
            _ => "?".to_string(),
        };
        out.push(format!(
            "{label} I-1: count_references row for content '{content}' names provider \
             ({m}, {v}), which has no counts row. A stranded reference inflates the \
             pending side of the population guard against a generation that no longer \
             exists. Whatever deleted the counts row must delete its references too."
        ));
    }
    out
}

// ─── I-2: no dictionary bit for a model with no payload ──────────────────────

/// `corpus_provider_term_dictionary.models` is a bitmask of which models claim
/// each term. A bit set for a model with no payload rows at all means the
/// dictionary outlived the payload it described — the shape CT-02 fixed for
/// deleted content.
///
/// A ZERO mask is explicitly NOT a violation: it is a name no model currently
/// claims, which `clear_term_payloads` produces deliberately and the next
/// persist re-sets if the term returns.
pub fn term_dictionary_has_no_orphan_model_bits(
    storage: &Arc<dyn Storage>,
    label: &str,
) -> Vec<String> {
    let rs = storage.row_store();
    let dict = rs
        .query("corpus_provider_term_dictionary", None, &[], None, None)
        .expect("query term_dictionary");
    if dict.is_empty() {
        return Vec::new();
    }

    let payloads = rs
        .query("corpus_provider_term_payload", None, &[], None, None)
        .expect("query term_payload");
    let mut models_with_payload: BTreeSet<i64> = BTreeSet::new();
    for row in &payloads {
        if let Some(TypedValue::Int(m)) = row.get("model_id") {
            models_with_payload.insert(*m);
        }
    }

    let mut out = Vec::new();
    for row in &dict {
        let mask = match row.get("models") {
            Some(TypedValue::Int(m)) if *m != 0 => *m,
            _ => continue,
        };
        let term = match row.get("term") {
            Some(TypedValue::Text(t)) => t.clone(),
            _ => "?".to_string(),
        };
        for bit in 0..MAX_MODEL_BIT {
            if mask & (1i64 << bit) == 0 {
                continue;
            }
            if models_with_payload.contains(&(bit as i64)) {
                continue;
            }
            out.push(format!(
                "{label} I-2: term '{term}' has model bit {bit} set in the dictionary, \
                 but model {bit} has no payload rows at all. The dictionary outlived \
                 the payload it describes — the shape that left deleted content's \
                 terms behind."
            ));
        }
    }
    out
}

// ─── I-3: every payload row is described by the dictionary ───────────────────

/// The inverse of I-2, and the one that catches a payload written without its
/// dictionary entry. `(model_id, term_id)` in the payload table must name a
/// `term_id` the dictionary knows, with this model's bit set.
///
/// Without this, a payload row is unreachable: nothing maps a term string to
/// it, so it is resident bytes no query can return.
pub fn term_payload_matches_dictionary(storage: &Arc<dyn Storage>, label: &str) -> Vec<String> {
    let rs = storage.row_store();
    let payloads = rs
        .query("corpus_provider_term_payload", None, &[], None, None)
        .expect("query term_payload");
    if payloads.is_empty() {
        return Vec::new();
    }

    let dict = rs
        .query("corpus_provider_term_dictionary", None, &[], None, None)
        .expect("query term_dictionary");
    let mut mask_by_term: BTreeMap<i64, i64> = BTreeMap::new();
    for row in &dict {
        if let (Some(TypedValue::Int(t)), Some(TypedValue::Int(m))) =
            (row.get("term_id"), row.get("models"))
        {
            mask_by_term.insert(*t, *m);
        }
    }

    let mut out = Vec::new();
    for row in &payloads {
        let (model, term_id) = match (row.get("model_id"), row.get("term_id")) {
            (Some(TypedValue::Int(m)), Some(TypedValue::Int(t))) => (*m, *t),
            _ => continue,
        };
        match mask_by_term.get(&term_id) {
            None => out.push(format!(
                "{label} I-3: payload row (model {model}, term_id {term_id}) has no \
                 dictionary entry. Nothing maps a term string to this row, so it is \
                 bytes no query can reach."
            )),
            Some(mask) if mask & (1i64 << model) == 0 => out.push(format!(
                "{label} I-3: payload row (model {model}, term_id {term_id}) exists, but \
                 the dictionary does not set model {model}'s bit for that term. The \
                 payload is unreachable through the dictionary meant to describe it."
            )),
            Some(_) => {}
        }
    }
    out
}

// ─── I-4: an invalidated counts blob has no surviving v3 term rows ───────────

/// `mootx01 upgrade` invalidates a provider's counts by writing the empty-blob
/// sentinel, and Step 1 of that migration DELETEs every `corpus_provider_vocab`
/// row (upgrade.rs, "legacy vocab rows must be gone"). A generation carrying
/// the sentinel alongside surviving v3 vocab rows therefore contradicts the
/// migration's own contract: a restore would find those rows and use them,
/// which is what the sentinel exists to prevent.
///
/// Scope is the v3 `corpus_provider_vocab` table ONLY. Surviving v4 term rows
/// are legal and expected — the migration leaves them deliberately, pinned by
/// T2 of `corpus_counts_blob_sentinel_tests.rs`. Widening this check to v4
/// would fail on a correctly migrated estate.
pub fn invalidated_counts_has_no_surviving_term_rows(
    storage: &Arc<dyn Storage>,
    label: &str,
) -> Vec<String> {
    let rs = storage.row_store();
    let counts_rows = rs
        .query("corpus_provider_counts", None, &[], None, None)
        .expect("query counts");

    let mut out = Vec::new();
    for row in &counts_rows {
        // The shared predicate, not an inline emptiness test: a future sentinel
        // format change stays a single-site edit in the store.
        match row.get("counts") {
            Some(TypedValue::Blob(b)) if is_invalidated_counts(b) => {}
            _ => continue,
        }
        let (m, v) = match (row.get("model_id"), row.get("model_version")) {
            (Some(TypedValue::Text(m)), Some(TypedValue::Text(v))) => (m.clone(), v.clone()),
            _ => continue,
        };

        let vocab_count = rs
            .count(
                "corpus_provider_vocab",
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::Eq(
                        Column::new("corpus_provider_vocab", "model_id"),
                        TypedValue::Text(m.clone()),
                    ),
                    StoragePredicate::Eq(
                        Column::new("corpus_provider_vocab", "model_version"),
                        TypedValue::Text(v.clone()),
                    ),
                ])),
            )
            .expect("count vocab");
        if vocab_count > 0 {
            out.push(format!(
                "{label} I-4: provider ({m}, {v}) carries the migration invalidation \
                 sentinel but still has {vocab_count} v3 vocab row(s). The migration \
                 deletes every one of them; a restore would find these and use them, \
                 which is precisely what the sentinel exists to prevent."
            ));
        }
    }
    out
}
