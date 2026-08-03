// conflict_projection_pass.rs — Rust twin of Brain/ConflictProjectionPass.swift.
//
// DCP M2 — the typed lane's projection step: KGFacts → ConflictSignatures
// plus the in-memory coordinate index that buckets signatures by
// (key, dimension) so evaluation is pairwise-within-bucket, never O(N²)
// over the whole fact table. Contract: docs_internal/analysis/
// DCP_M0_CONTRACT.md §2–§5; the value/identity types live in
// substrate_ml::conflict_projection (M1).
//
// This layer is PURE and deterministic: facts and per-drawer event times
// come in, signatures and diagnostics come out. No estate reads, no
// clock, no I/O — the estate-reading orchestration (drawer hydration,
// evaluator sweep, report lines) is M3's seam.

use locus_kit::adjectives::State;
use locus_kit::kg_fact::KGFact;
use std::collections::HashMap;
use substrate_ml::conflict_projection::{
    normalize, ConflictClaimStatus, ConflictRuleRegistry, ConflictSignature, TemporalBasis,
};

/// Why a scanned KGFact did not become a ConflictSignature. Counted per
/// pass and surfaced through the report's `coverage: <projected>/<scanned>`
/// and `unknown_or_invalid: N` lines (M0 §7) — never silently dropped.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConflictProjectionDiagnostics {
    /// Facts examined this pass.
    pub scanned: usize,
    /// Facts that produced a signature.
    pub projected: usize,
    /// Facts whose adjective state is not Active (withdrawn, rejected,
    /// superseded, tombstoned, pending, contested). Excluded before
    /// evaluation per M0 §1 — only active standing can prove.
    pub inactive: usize,
    /// Facts whose predicate resolves to no registered dimension. These
    /// stay in the lexical hunter's domain (UnknownRule never proves);
    /// they are NOT signatures in v0.1.
    pub unregistered: usize,
    /// Facts on a registered dimension whose object failed the rule's
    /// normalizer (ambiguous date, out-of-set enum token, malformed
    /// number). The typed lane refuses to guess: these count toward the
    /// report's `unknown_or_invalid` line.
    pub unparsed: usize,
}

/// One pass's output: the projected signatures plus the exclusion counts.
#[derive(Debug, Clone)]
pub struct ConflictProjectionResult {
    pub signatures: Vec<ConflictSignature>,
    pub diagnostics: ConflictProjectionDiagnostics,
}

/// Canonical scoped key for a fact's subject under a rule:
/// `<domain>:<canonical subject>` where domain is the ruleID's second
/// dot-component (`dim.person.employer` → `person`) and the canonical
/// subject is NFC + trimmed + whitespace-collapsed + lowercased. The
/// scope policy is exact-equal on this string (M0 §2), so two spellings
/// of one entity collide only when their canonical forms match — entity
/// RESOLUTION stays out of scope in v0.1.
pub fn conflict_key(rule_id: &str, subject: &str) -> String {
    let domain = rule_id.split('.').nth(1).unwrap_or("unknown");
    format!("{domain}:{}", normalize::enum_token(subject))
}

/// The evidence locator every projected signature carries for `fact_id`:
/// `kgfact:<fact id>` — the signature's back-pointer to the KGFact it was
/// projected from.
///
/// One source of truth on purpose. `run_sweep` joins signatures back to
/// their facts through this exact string to read each fact's own adjective
/// sensitivity. If the projection site and the sweep built the format
/// independently and ever drifted, every join would miss — and because an
/// unresolvable sensitivity fails closed, every finding in the estate
/// would silently redact to Secret with no error anywhere. Sharing one
/// function makes that divergence unrepresentable.
pub fn evidence_locator_for_fact(fact_id: &str) -> String {
    format!("kgfact:{fact_id}")
}

/// Project `facts` into signatures under `registry`.
///
/// `event_time_seconds_by_source_drawer` carries source-drawer event
/// times in EPOCH SECONDS (M0 §3 temporal bytes are `t:pt:<epoch-secs>`).
/// The caller owns the units conversion at the estate seam — the Rust
/// drawer clock is epoch-millisecond, so the M3 caller divides there,
/// and this parameter name carries the unit to keep the KI-003 ms/secs
/// trap out of this layer. A drawer absent from the map projects with
/// Unknown validity (M0 §5). `filed_at_seconds` per fact is derived here
/// from the fact's epoch-millisecond `filed_at` for the same reason.
pub fn project(
    facts: &[KGFact],
    event_time_seconds_by_source_drawer: &HashMap<String, i64>,
    registry: &ConflictRuleRegistry,
) -> ConflictProjectionResult {
    let mut diagnostics = ConflictProjectionDiagnostics::default();
    let mut signatures: Vec<ConflictSignature> = Vec::with_capacity(facts.len());

    for fact in facts {
        diagnostics.scanned += 1;
        if fact.state() != State::Active {
            diagnostics.inactive += 1;
            continue;
        }
        let dimension = normalize::dimension_key(&fact.predicate);
        let Some(rule) = registry.rule_for_dimension(&dimension) else {
            diagnostics.unregistered += 1;
            continue;
        };
        let Some(value) = (rule.normalize)(&fact.object) else {
            diagnostics.unparsed += 1;
            continue;
        };
        let validity = match event_time_seconds_by_source_drawer.get(&fact.source_drawer_id) {
            Some(&seconds) => TemporalBasis::Point { epoch_seconds: seconds },
            None => TemporalBasis::Unknown,
        };
        diagnostics.projected += 1;
        signatures.push(ConflictSignature {
            key: conflict_key(rule.rule_id, &fact.subject),
            dimension: rule.dimension.to_string(),
            value,
            source_drawer_id: fact.source_drawer_id.clone(),
            // Transaction time is the fact's filing instant. LocusKit's
            // Rust clock is epoch-millisecond (KI-003); the identity
            // domain is whole seconds, matching the Swift twin's floor.
            transaction_time: fact.filed_at.div_euclid(1000),
            validity,
            status: ConflictClaimStatus::Asserted,
            rule_id: rule.rule_id.to_string(),
            rule_version: rule.version,
            extractor_id: None,
            evidence_locator: Some(evidence_locator_for_fact(&fact.id)),
        });
    }
    ConflictProjectionResult { signatures, diagnostics }
}

/// Per-bucket signature cap (M0 §7 `truncated_buckets`). A coordinate
/// with more claims than this keeps its FIRST `bucket_cap` signatures in
/// insertion order and reports the bucket as truncated (F16) — bounded
/// work, visible loss, never a silent sample.
pub const DEFAULT_BUCKET_CAP: usize = 64;

/// In-memory coordinate index: signatures bucketed by (key, dimension).
/// Evaluation is pairwise WITHIN a bucket only — two claims on different
/// coordinates are Irrelevant by construction and never meet. Bucket
/// membership is insertion-ordered and the pair walk is deterministic.
#[derive(Debug, Clone)]
pub struct ConflictCoordinateIndex {
    pub bucket_cap: usize,
    /// Buckets keyed by `<key>|<dimension>`, insertion-ordered values.
    buckets: HashMap<String, Vec<ConflictSignature>>,
    /// Bucket keys that hit the cap, in first-truncation order.
    truncated_bucket_keys: Vec<String>,
}

impl Default for ConflictCoordinateIndex {
    fn default() -> Self {
        Self::new(DEFAULT_BUCKET_CAP)
    }
}

impl ConflictCoordinateIndex {
    pub fn new(bucket_cap: usize) -> Self {
        Self { bucket_cap, buckets: HashMap::new(), truncated_bucket_keys: Vec::new() }
    }

    /// Number of buckets currently truncated (report line: only when > 0).
    pub fn truncated_buckets(&self) -> usize {
        self.truncated_bucket_keys.len()
    }

    /// Bucket keys that hit the cap, in first-truncation order.
    pub fn truncated_bucket_keys(&self) -> &[String] {
        &self.truncated_bucket_keys
    }

    /// Coordinate bucket key for a signature.
    pub fn bucket_key(signature: &ConflictSignature) -> String {
        format!("{}|{}", signature.key, signature.dimension)
    }

    /// Insert one signature; drops it (and marks the bucket truncated)
    /// when the bucket is full.
    pub fn insert(&mut self, signature: ConflictSignature) {
        let key = Self::bucket_key(&signature);
        let bucket = self.buckets.entry(key.clone()).or_default();
        if bucket.len() >= self.bucket_cap {
            if !self.truncated_bucket_keys.contains(&key) {
                self.truncated_bucket_keys.push(key);
            }
            return;
        }
        bucket.push(signature);
    }

    /// Insert many, in order.
    pub fn insert_all(&mut self, signatures: impl IntoIterator<Item = ConflictSignature>) {
        for signature in signatures {
            self.insert(signature);
        }
    }

    /// All within-bucket unordered pairs, deterministically ordered:
    /// buckets by sorted bucket key, pairs by (i, j) insertion index.
    /// Self-pairs from the same source drawer are skipped — one drawer
    /// restating its own claim is not a conflict candidate.
    pub fn pairs(&self) -> Vec<(ConflictSignature, ConflictSignature)> {
        let mut result = Vec::new();
        let mut keys: Vec<&String> = self.buckets.keys().collect();
        keys.sort();
        for key in keys {
            let bucket = &self.buckets[key];
            if bucket.len() < 2 {
                continue;
            }
            for i in 0..bucket.len() - 1 {
                for j in (i + 1)..bucket.len() {
                    if bucket[i].source_drawer_id == bucket[j].source_drawer_id {
                        continue;
                    }
                    result.push((bucket[i].clone(), bucket[j].clone()));
                }
            }
        }
        result
    }
}

// DCP M2 tests — Rust leg. The hardcoded key/transaction-time/stableID
// literals are the CROSS-PORT FIXTURE shared with
// ConflictProjectionPassTests.swift. Ledger case F16 lives here per
// DCP_M0_CONTRACT §10.
#[cfg(test)]
mod tests {
    use super::*;
    use substrate_ml::conflict_projection::{evaluate, ConflictOutcomeKind};

    fn fact(
        id: &str,
        subject: &str,
        predicate: &str,
        object: &str,
        source: &str,
        adjective_bitmap: i64,
    ) -> KGFact {
        let mut f = KGFact::new(
            id.into(),
            subject.into(),
            predicate.into(),
            object.into(),
            source.into(),
            // Epoch milliseconds (the LocusKit Rust clock).
            1_700_000_000_000,
        );
        f.adjective_bitmap = adjective_bitmap;
        f
    }

    fn default_fact() -> KGFact {
        fact("fact-1", "Sarah Chen C0", "Employer", "Acme Robotics", "drawer-a", 0)
    }

    /// Golden projection literals (generated once, pinned in both ports).
    #[test]
    fn golden_projection() {
        let mut times = HashMap::new();
        times.insert("drawer-a".to_string(), 1_690_000_000_i64);
        let result = project(&[default_fact()], &times, &ConflictRuleRegistry::v01());
        assert_eq!(result.diagnostics.scanned, 1);
        assert_eq!(result.diagnostics.projected, 1);
        let s = &result.signatures[0];
        assert_eq!(s.key, "person:sarah chen c0");
        assert_eq!(s.dimension, "employer");
        assert_eq!(s.transaction_time, 1_700_000_000);
        assert_eq!(s.validity, TemporalBasis::Point { epoch_seconds: 1_690_000_000 });
        assert_eq!(s.evidence_locator.as_deref(), Some("kgfact:fact-1"));
        assert_eq!(
            s.stable_id(),
            "714b2f821567fb1a93f23e6f03e205538a4c490306d64d142811f3e53ddbc018"
        );
    }

    /// Exclusions are counted, never silently dropped.
    #[test]
    fn exclusions_are_counted() {
        let facts = vec![
            fact("f-active", "Sarah Chen C0", "Employer", "Acme Robotics", "drawer-a", 0),
            // State bits 0–5: withdrawn = 18.
            fact("f-withdrawn", "Sarah Chen C0", "Employer", "Acme Robotics", "drawer-a", 18),
            fact("f-unregistered", "Sarah Chen C0", "favorite color", "red", "drawer-a", 0),
            // Registered dimension, object outside the closed enum set.
            fact("f-unparsed", "Sarah Chen C0", "Employer", "Globex Corp", "drawer-a", 0),
        ];
        let result = project(&facts, &HashMap::new(), &ConflictRuleRegistry::v01());
        assert_eq!(result.diagnostics.scanned, 4);
        assert_eq!(result.diagnostics.projected, 1);
        assert_eq!(result.diagnostics.inactive, 1);
        assert_eq!(result.diagnostics.unregistered, 1);
        assert_eq!(result.diagnostics.unparsed, 1);
        // No event time supplied → unknown validity (M0 §5), still projects.
        assert_eq!(result.signatures[0].validity, TemporalBasis::Unknown);
    }

    /// Predicate spelling folds through dimension_key.
    #[test]
    fn predicate_spelling_folds() {
        let f = fact("f1", "Sarah Chen C0", "  Primary   Language ", "Rust", "d1", 0);
        let result = project(&[f], &HashMap::new(), &ConflictRuleRegistry::v01());
        assert_eq!(result.diagnostics.projected, 1);
        assert_eq!(result.signatures[0].rule_id, "dim.person.primary_language");
    }

    /// Index pairs only within a coordinate, never same-drawer pairs.
    #[test]
    fn index_pairs_within_coordinate_only() {
        let facts = vec![
            fact("f1", "Sarah Chen C0", "Employer", "Acme Robotics", "d1", 0),
            fact("f2", "Sarah Chen C0", "Employer", "Beta Corp", "d2", 0),
            // Same coordinate, same drawer as f1 — must not pair with f1.
            fact("f3", "Sarah Chen C0", "Employer", "Halcyon Labs", "d1", 0),
            // Different subject — different bucket, no pairs.
            fact("f4", "Noor Haddad C1", "Employer", "Vireo Systems", "d3", 0),
        ];
        let result = project(&facts, &HashMap::new(), &ConflictRuleRegistry::v01());
        let mut index = ConflictCoordinateIndex::default();
        index.insert_all(result.signatures);
        let pairs = index.pairs();
        // f1–f2, f2–f3 (f1–f3 same drawer, f4 alone in its bucket).
        assert_eq!(pairs.len(), 2);
        assert_eq!(index.truncated_buckets(), 0);
        for (a, b) in &pairs {
            assert_ne!(a.source_drawer_id, b.source_drawer_id);
            assert_eq!(
                ConflictCoordinateIndex::bucket_key(a),
                ConflictCoordinateIndex::bucket_key(b)
            );
        }
    }

    /// F16 — an oversized bucket keeps its first `bucket_cap` signatures
    /// and reports the truncation.
    #[test]
    fn f16_oversized_bucket_truncates() {
        let facts = vec![
            fact("f1", "Sarah Chen C0", "Employer", "Acme Robotics", "d1", 0),
            fact("f2", "Sarah Chen C0", "Employer", "Beta Corp", "d2", 0),
            fact("f3", "Sarah Chen C0", "Employer", "Halcyon Labs", "d3", 0),
        ];
        let result = project(&facts, &HashMap::new(), &ConflictRuleRegistry::v01());
        let mut index = ConflictCoordinateIndex::new(2);
        index.insert_all(result.signatures);
        assert_eq!(index.truncated_buckets(), 1);
        assert_eq!(index.truncated_bucket_keys(), ["person:sarah chen c0|employer"]);
        // First two kept in insertion order → exactly one pair.
        let pairs = index.pairs();
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].0.source_drawer_id, "d1");
        assert_eq!(pairs[0].1.source_drawer_id, "d2");
    }

    /// The pair walk is deterministic and bucket keys walk sorted.
    #[test]
    fn pair_walk_is_deterministic() {
        let facts = vec![
            fact("f1", "Sarah Chen C0", "Employer", "Acme Robotics", "d1", 0),
            fact("f2", "Sarah Chen C0", "Employer", "Beta Corp", "d2", 0),
            fact("f3", "Noor Haddad C1", "Employer", "Halcyon Labs", "d3", 0),
            fact("f4", "Noor Haddad C1", "Employer", "Vireo Systems", "d4", 0),
        ];
        let result = project(&facts, &HashMap::new(), &ConflictRuleRegistry::v01());
        let mut first = ConflictCoordinateIndex::default();
        first.insert_all(result.signatures.clone());
        let mut second = ConflictCoordinateIndex::default();
        second.insert_all(result.signatures);
        let a: Vec<String> = first
            .pairs()
            .iter()
            .map(|(x, y)| format!("{}+{}", x.stable_id(), y.stable_id()))
            .collect();
        let b: Vec<String> = second
            .pairs()
            .iter()
            .map(|(x, y)| format!("{}+{}", x.stable_id(), y.stable_id()))
            .collect();
        assert_eq!(a, b);
        assert_eq!(a.len(), 2);
        // Buckets walk in sorted key order: noor before sarah.
        assert_eq!(first.pairs()[0].0.key, "person:noor haddad c1");
    }

    /// End-to-end through the M1 evaluator: the pair the index yields
    /// evaluates to ProvenContradiction.
    #[test]
    fn indexed_pair_evaluates_to_proven_contradiction() {
        let facts = vec![
            fact("f1", "Sarah Chen C0", "Employer", "Acme Robotics", "d1", 0),
            fact("f2", "Sarah Chen C0", "Employer", "Beta Corp", "d2", 0),
        ];
        let mut times = HashMap::new();
        times.insert("d1".to_string(), 500_i64);
        times.insert("d2".to_string(), 500_i64);
        let reg = ConflictRuleRegistry::v01();
        let result = project(&facts, &times, &reg);
        let mut index = ConflictCoordinateIndex::default();
        index.insert_all(result.signatures);
        let pairs = index.pairs();
        assert_eq!(pairs.len(), 1);
        let outcome = evaluate(&pairs[0].0, &pairs[0].1, &reg, false);
        assert_eq!(outcome.kind, ConflictOutcomeKind::ProvenContradiction);
    }
}
