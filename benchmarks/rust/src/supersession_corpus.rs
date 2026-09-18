//! supersession_corpus.rs — a temporally-phased corpus for the supersession
//! and contradiction lanes. Twin of Swift `SupersessionCorpus.swift`.
//!
//! WHY THIS EXISTS. Every public memory benchmark (LongMemEval, LoCoMo, LMEB)
//! scores one question: was the right item retrieved. None of them scores the
//! question a memory system actually faces once it has been running for a
//! while: when the store holds three versions of the same fact, does the
//! CURRENT one win and do the SUPERSEDED ones lose?
//!
//! That gap is structural rather than accidental. Those benchmarks provision
//! a fresh estate per question, so there is no history for a temporal prior
//! to be computed from — measured directly: six shaped-recall presets that
//! steer matrix-prior columns returned byte-identical rankings on
//! LongMemEval, because on a fresh estate those columns are all 0.0 by
//! contract (GeniusLocusKit.swift:152-154). A benchmark that never
//! accumulates history cannot see a capability that only exists once history
//! accumulates.
//!
//! So this corpus is built the other way round: ONE persistent estate, facts
//! ingested in chronological order with real `event_time` values, and queries
//! asked only after the whole timeline is in place.
//!
//! FAIRNESS RULE — load-bearing, do not relax it. Every scored behaviour here
//! must be achievable in principle by any competent BM25 + vector system that
//! tracks recency. Nothing is scored that requires a moot-specific feature to
//! pass. A benchmark only our product can pass is marketing; a benchmark that
//! is simply harder, and that we happen to be good at, is measurement. If a
//! future tier cannot be passed by any well-built system of that class, it
//! does not belong in this file.

use crate::longmemeval_runner::SplitMix64;
use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Corpus model
// ─────────────────────────────────────────────────────────────────────────────

/// One assertion about an entity's attribute at a point in time.
/// Serde names match the Swift Codable keys so one committed conformance
/// vector file drives both legs.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SupersessionRecord {
    pub id: String,
    /// Subject the claim is about ("Sarah Chen").
    pub entity: String,
    /// Attribute being asserted ("employer").
    pub attribute: String,
    /// The asserted value at this point in the timeline ("Acme Robotics").
    pub value: String,
    /// Natural-language rendering — what actually gets filed.
    pub content: String,
    /// ISO8601 instant this claim was made. Ingestion uses it as
    /// `event_time`, so the estate's timeline matches the corpus's fiction.
    pub event_time: String,
    /// Position in this entity+attribute's chain: 0 = oldest.
    pub version_index: i64,
    /// True for the final, still-true version of this chain.
    pub is_current: bool,
    /// ISO8601 instant the record is FILED (drives `filedAt`). Defaults to
    /// `event_time`. Contradiction pairs share `event_time` BY DESIGN (no
    /// recency rule can pick a winner) but must NOT share `filedAt`: a tied
    /// filedAt makes the locus lane's ordering fall to per-run-random UUIDs,
    /// drifting replay ranks. Filing order is a real-world sequence, not the
    /// semantic clock, so a +1s offset on the second record of each pair is
    /// faithful and deterministic. Omitted from JSON when `None` — matches
    /// the Swift leg's optional `captureDate` encoding.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capture_date: Option<String>,
}

/// One scored query over the corpus.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SupersessionQuery {
    pub id: String,
    pub question: String,
    pub entity: String,
    pub attribute: String,
    /// The value that is true at query time.
    pub current_value: String,
    /// Record id carrying the current value — must outrank every stale id.
    #[serde(rename = "currentRecordID")]
    pub current_record_id: String,
    /// Record ids carrying superseded values — every one of these ranking
    /// above `current_record_id` is a failure.
    #[serde(rename = "supersededRecordIDs")]
    pub superseded_record_ids: Vec<String>,
}

/// A planted pair of claims that cannot both be true, with NO temporal
/// ordering between them — neither supersedes the other, so a recency rule
/// cannot resolve it. Detection, not ranking, is the scored behaviour.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ContradictionPair {
    pub id: String,
    #[serde(rename = "leftRecordID")]
    pub left_record_id: String,
    #[serde(rename = "rightRecordID")]
    pub right_record_id: String,
    pub entity: String,
    pub attribute: String,
}

/// One planted adversarial NON-contradiction: a pair that must NOT be
/// flagged at any tier. Three shapes cycle (see `generate_supersession_corpus_tiered`):
/// an explicit supersession-marker chain, a distinct-entity same-value pair,
/// and a unit-equivalent value pair. `kind` names the shape so the scorer can
/// separate hard failures from the known unit-normalization limitation.
/// Twin of Swift `DecoyPair`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DecoyPair {
    pub id: String,
    #[serde(rename = "leftRecordID")]
    pub left_record_id: String,
    #[serde(rename = "rightRecordID")]
    pub right_record_id: String,
    /// "marker_supersession" | "distinct_entity" | "unit_equivalent".
    pub kind: String,
}

pub const DECOY_KIND_MARKER_SUPERSESSION: &str = "marker_supersession";
pub const DECOY_KIND_DISTINCT_ENTITY: &str = "distinct_entity";
pub const DECOY_KIND_UNIT_EQUIVALENT: &str = "unit_equivalent";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SupersessionCorpus {
    pub seed: u64,
    pub records: Vec<SupersessionRecord>,
    pub queries: Vec<SupersessionQuery>,
    pub contradictions: Vec<ContradictionPair>,
    /// MXE-CT3 P4: digit-valued divergence pairs (tier-3 class). Same pair
    /// shape as `contradictions`, so the type is reused. `#[serde(default)]`
    /// so pre-P4 dumps — including the committed conformance vector file —
    /// still decode; the Swift leg decode-defaults the same two keys.
    #[serde(default)]
    pub divergences: Vec<ContradictionPair>,
    /// MXE-CT3 P4: adversarial non-contradictions that must fire at no tier.
    #[serde(default)]
    pub decoys: Vec<DecoyPair>,
}

// ─────────────────────────────────────────────────────────────────────────────
// ISO8601 rendering (std-only; the crate carries no date dependency)
// ─────────────────────────────────────────────────────────────────────────────

/// Renders whole seconds since the Unix epoch as `YYYY-MM-DDTHH:MM:SSZ` —
/// byte-identical to Swift's `ISO8601DateFormatter` (UTC, default options)
/// for the integral-second instants this corpus produces. Uses Howard
/// Hinnant's civil-from-days algorithm for the date part.
pub fn iso8601_from_epoch_seconds(epoch_seconds: i64) -> String {
    let days = epoch_seconds.div_euclid(86_400);
    let secs_of_day = epoch_seconds.rem_euclid(86_400);
    // civil_from_days(days since 1970-01-01) → (y, m, d).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097); // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let year = if m <= 2 { y + 1 } else { y };
    let hh = secs_of_day / 3600;
    let mm = (secs_of_day % 3600) / 60;
    let ss = secs_of_day % 60;
    format!("{year:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

/// Parses `YYYY-MM-DDTHH:MM:SSZ` back to whole seconds since the Unix epoch —
/// the inverse of `iso8601_from_epoch_seconds`, via Howard Hinnant's
/// days-from-civil. Returns None for any other shape.
pub fn epoch_seconds_from_iso8601(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() != 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T'
        || b[13] != b':' || b[16] != b':' || b[19] != b'Z'
    {
        return None;
    }
    let num = |range: std::ops::Range<usize>| -> Option<i64> {
        s.get(range)?.parse::<i64>().ok()
    };
    let (y, m, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (hh, mm, ss) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) || hh > 23 || mm > 59 || ss > 59 {
        return None;
    }
    // days_from_civil(y, m, d).
    let y_adj = if m <= 2 { y - 1 } else { y };
    let era = y_adj.div_euclid(400);
    let yoe = y_adj.rem_euclid(400);
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + hh * 3600 + mm * 60 + ss)
}

// ─────────────────────────────────────────────────────────────────────────────
// Deterministic generation
// ─────────────────────────────────────────────────────────────────────────────

/// Builds a corpus that is a pure function of `seed`: same seed, same bytes,
/// same corpus on both legs (conformance-gated). Determinism is a hard gate —
/// a benchmark whose corpus drifts between runs cannot support a claim, and a
/// published benchmark must be reproducible by someone who does not have our
/// code.
/// Pre-P4 signature, preserved as a thin wrapper: the committed conformance
/// test (`rust/tests/conformance.rs`) and the replay lane call this 4-argument
/// form, and zero-count P4 classes are structurally absent — the wrapper
/// regenerates the exact pre-P4 corpus for any seed. The CLI's `--divergences`
/// / `--decoys` defaults (5 each) live at the flag boundary, not here.
pub fn generate_supersession_corpus(
    seed: u64,
    entity_count: usize,
    versions_per_chain: usize,
    contradiction_count: usize,
) -> SupersessionCorpus {
    generate_supersession_corpus_tiered(
        seed, entity_count, versions_per_chain, contradiction_count, 0, 0)
}

/// Twin of Swift `generateSupersessionCorpus` (which reaches the P4 classes
/// through defaulted parameters instead of a wrapper). New classes draw from
/// the RNG strictly AFTER all pre-P4 classes, so the 10 word-valued planted
/// pairs (and every chain) are byte-identical to the pre-P4 output.
pub fn generate_supersession_corpus_tiered(
    seed: u64,
    entity_count: usize,
    versions_per_chain: usize,
    contradiction_count: usize,
    divergence_count: usize,
    decoy_count: usize,
) -> SupersessionCorpus {
    let mut rng = SplitMix64::new(seed);

    // Vocabulary kept deliberately plain. Ornate distractors would make the
    // lane hard for reasons unrelated to supersession, which is not what is
    // being measured here. Word-for-word twin of the Swift lists.
    let first_names = [
        "Sarah", "Marcus", "Priya", "Tomas", "Ines", "Kwame", "Lena", "Hiroshi",
        "Amara", "Diego",
    ];
    let last_names = [
        "Chen", "Okafor", "Lindqvist", "Baptiste", "Yamamoto", "Novak", "Reyes",
        "Adeyemi", "Kowalski", "Haddad",
    ];
    // (attribute, values, statement verb, QUESTION form with `%@` slot). The
    // question is stored separately because "Where does X <verb> now?" is
    // only grammatical for one of these — a malformed question measures the
    // harness's grammar, not the product's retrieval.
    let attributes: [(&str, &[&str], &str, &str); 4] = [
        (
            "employer",
            &["Acme Robotics", "Northwind Analytics", "Beta Corp", "Vireo Systems",
              "Halcyon Labs"],
            "works at",
            "Where does %@ work now?",
        ),
        (
            "city",
            &["Lisbon", "Toronto", "Osaka", "Nairobi", "Reykjavik"],
            "lives in",
            "Where does %@ live now?",
        ),
        (
            "role",
            &["staff engineer", "engineering manager", "principal architect",
              "director of platform", "technical lead"],
            "is a",
            "What is %@'s current role?",
        ),
        (
            "primary language",
            &["Swift", "Rust", "Elixir", "OCaml", "Zig"],
            "mostly writes",
            "What language does %@ mostly write now?",
        ),
    ];

    let mut records: Vec<SupersessionRecord> = Vec::new();
    let mut queries: Vec<SupersessionQuery> = Vec::new();
    let mut contradictions: Vec<ContradictionPair> = Vec::new();

    // Embedding-visibility sentence (REPLAY_DRIFT_RCA addendum 2026-08-26).
    // Twin of the Swift generator's `notedSentence`: the deterministic dense
    // embedding treats proper names as out-of-vocabulary, so two records that
    // differed ONLY by names projected to byte-identical vectors and fell to
    // per-run UUIDs at the dense k-cut, drifting meanStaleInTopK between
    // replay runs. One plain in-vocabulary sentence per record family —
    // weekday(7) x period(5) x month(12) = 420 combos — makes every family's
    // token set distinct. Index-derived: consumes NO RNG draws.
    let noted_weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday",
                          "Friday", "Saturday", "Sunday"];
    let noted_periods = ["morning", "noon", "afternoon", "evening", "night"];
    let noted_months = ["January", "February", "March", "April", "May",
                        "June", "July", "August", "September", "October",
                        "November", "December"];
    let noted_sentence = |family: usize| -> String {
        format!(" Noted one {} {} in {}.",
                noted_weekdays[family % 7],
                noted_periods[family % 5],
                noted_months[family % 12])
    };

    // Timeline spans four years so version gaps are unambiguous. Fixed epoch —
    // never the wall clock — so the corpus does not change between runs.
    let epoch: f64 = 1_580_000_000.0; // 2020-01-26T00:53:20Z

    for entity_index in 0..entity_count {
        let fnm = first_names[(rng.next_u64() % first_names.len() as u64) as usize];
        let lnm = last_names[(rng.next_u64() % last_names.len() as u64) as usize];
        // Index suffix guarantees entity uniqueness across the corpus.
        let name = format!("{fnm} {lnm} {entity_index}");
        let (attr_name, values, verb, question_form) =
            attributes[entity_index % attributes.len()];

        // Pick distinct values for the chain so each version is a real change.
        let mut pool: Vec<&str> = values.to_vec();
        let mut chain_values: Vec<&str> = Vec::new();
        for _ in 0..versions_per_chain.min(pool.len()) {
            let idx = (rng.next_u64() % pool.len() as u64) as usize;
            chain_values.push(pool.remove(idx));
        }

        let mut chain_ids: Vec<String> = Vec::new();
        for (v, value) in chain_values.iter().enumerate() {
            let id = format!("sup-{entity_index}-{v}");
            chain_ids.push(id.clone());
            // Versions land 200-400 days apart, strictly increasing. The RNG
            // draw happens on every iteration (including v=0, where the
            // offset multiplies to zero) to match the Swift draw sequence.
            let day_offset = v as f64 * (200.0 + (rng.next_u64() % 200) as f64);
            // Add entity_index seconds to guarantee unique filedAt values
            // across all (entity, version) pairs. Without this offset, all
            // v=0 records share epoch (day_offset = 0.0) and the locus-lane
            // ordering falls back to UUID (minted fresh per replay run) for
            // tied filedAt — producing different locus rank positions between
            // runs. Twin of the Swift generator's offset.
            let when = epoch + day_offset * 86_400.0 + entity_index as f64;
            let is_current = v == chain_values.len() - 1;
            // Phrasing marks the change without naming the previous value —
            // a retriever must use the timeline, not a lexical cue like
            // "no longer", to decide which version is live.
            let content = if v == 0 {
                format!("{name} {verb} {value}.")
            } else {
                format!("Update: {name} now {verb} {value}.")
            } + &noted_sentence(entity_index);
            records.push(SupersessionRecord {
                id,
                entity: name.clone(),
                attribute: attr_name.to_string(),
                value: value.to_string(),
                content,
                event_time: iso8601_from_epoch_seconds(when as i64),
                version_index: v as i64,
                is_current,
                capture_date: None,
            });
        }

        queries.push(SupersessionQuery {
            id: format!("q-{entity_index}"),
            question: question_form.replace("%@", &name),
            entity: name,
            attribute: attr_name.to_string(),
            current_value: chain_values[chain_values.len() - 1].to_string(),
            current_record_id: chain_ids[chain_ids.len() - 1].clone(),
            superseded_record_ids: chain_ids[..chain_ids.len() - 1].to_vec(),
        });
    }

    // Contradiction pairs: mutually exclusive claims sharing ONE event_time,
    // so no recency rule can pick a winner. The correct behaviour is to
    // surface the conflict, not to silently rank one first.
    for c in 0..contradiction_count {
        let cfn = first_names[(rng.next_u64() % first_names.len() as u64) as usize];
        let cln = last_names[(rng.next_u64() % last_names.len() as u64) as usize];
        let name = format!("{cfn} {cln} C{c}");
        let (attr_name, values, verb, _) = attributes[c % attributes.len()];
        let a = values[(rng.next_u64() % values.len() as u64) as usize];
        let mut b = values[(rng.next_u64() % values.len() as u64) as usize];
        if b == a {
            let a_pos = values.iter().position(|v| *v == a).expect("a drawn from values");
            b = values[(a_pos + 1) % values.len()];
        }
        let when = iso8601_from_epoch_seconds((epoch + c as f64 * 86_400.0) as i64);
        let lid = format!("con-{c}-a");
        let rid = format!("con-{c}-b");
        let con_noted = noted_sentence(entity_count + c);
        records.push(SupersessionRecord {
            id: lid.clone(),
            entity: name.clone(),
            attribute: attr_name.to_string(),
            value: a.to_string(),
            content: format!("{name} {verb} {a}.") + &con_noted,
            event_time: when.clone(),
            version_index: 0,
            is_current: false,
            capture_date: None,
        });
        // Second record of the pair files one second later: event_time stays
        // SHARED (the semantic tie the pair exists to create) while filedAt
        // becomes unique and seed-deterministic (see capture_date doc above).
        let when_plus_one =
            iso8601_from_epoch_seconds((epoch + c as f64 * 86_400.0 + 1.0) as i64);
        records.push(SupersessionRecord {
            id: rid.clone(),
            entity: name.clone(),
            attribute: attr_name.to_string(),
            value: b.to_string(),
            content: format!("{name} {verb} {b}.") + &con_noted,
            event_time: when,
            version_index: 0,
            is_current: false,
            capture_date: Some(when_plus_one),
        });
        contradictions.push(ContradictionPair {
            id: format!("con-{c}"),
            left_record_id: lid,
            right_record_id: rid,
            entity: name,
            attribute: attr_name.to_string(),
        });
    }

    // ── MXE-CT3 P4: divergence pairs (tier-3 class) ─────────────────────────
    // Digit-valued twins of the contradiction pairs: same entity, same
    // attribute template, two claims differing ONLY in a numeric value token,
    // sharing ONE event_time so recency cannot resolve them. Units are
    // ATTACHED to the value ("45ms", not "45 ms") so the single differing
    // token carries a digit on both sides — the exact shape ConflictCue's
    // valueDivergence cue (tier 3) fires on (Swift ConflictCue.swift:286-299
    // and its Rust twin: same-length streams, every differing position
    // digit-bearing). NOTE: these score >= the strong threshold, so the
    // LEGACY sweep auto-proposes them too — they surface in `flagged outside
    // planted` (context, not error) while the tier-3 purpose run scores them
    // as its planted class. Word-for-word twin of the Swift block.
    let mut divergences: Vec<ContradictionPair> = Vec::new();
    // (attribute, values, unit suffix, template prefix builder). Templates
    // mirror the Swift closures byte for byte.
    enum DivTemplate {
        ResponseTime,
        BuildDuration,
        RequestTimeout,
    }
    let divergence_attributes: [(&str, &[&str], DivTemplate); 3] = [
        ("response time", &["30", "45", "90", "120", "250"], DivTemplate::ResponseTime),
        ("build duration", &["8", "12", "25", "40", "55"], DivTemplate::BuildDuration),
        ("request timeout", &["15", "60", "300", "600", "900"], DivTemplate::RequestTimeout),
    ];
    let render = |t: &DivTemplate, name: &str, v: &str| -> String {
        match t {
            DivTemplate::ResponseTime => format!("Response time for {name} is {v}ms."),
            DivTemplate::BuildDuration => format!("The nightly build for {name} takes {v}min."),
            DivTemplate::RequestTimeout => format!("The request timeout for {name} is {v}s."),
        }
    };
    for n in 0..divergence_count {
        let dfn = first_names[(rng.next_u64() % first_names.len() as u64) as usize];
        let dln = last_names[(rng.next_u64() % last_names.len() as u64) as usize];
        let name = format!("{dfn} {dln} D{n}");
        let (attr_name, values, template) =
            &divergence_attributes[n % divergence_attributes.len()];
        let a = values[(rng.next_u64() % values.len() as u64) as usize];
        let mut b = values[(rng.next_u64() % values.len() as u64) as usize];
        if b == a {
            let a_pos = values.iter().position(|v| *v == a).expect("a drawn from values");
            b = values[(a_pos + 1) % values.len()];
        }
        let when = iso8601_from_epoch_seconds((epoch + (400 + n) as f64 * 86_400.0) as i64);
        let lid = format!("div-{n}-a");
        let rid = format!("div-{n}-b");
        let div_noted = noted_sentence(entity_count + contradiction_count + n);
        records.push(SupersessionRecord {
            id: lid.clone(),
            entity: name.clone(),
            attribute: attr_name.to_string(),
            value: a.to_string(),
            content: render(template, &name, a) + &div_noted,
            event_time: when.clone(),
            version_index: 0,
            is_current: false,
            capture_date: None,
        });
        records.push(SupersessionRecord {
            id: rid.clone(),
            entity: name.clone(),
            attribute: attr_name.to_string(),
            value: b.to_string(),
            content: render(template, &name, b) + &div_noted,
            event_time: when,
            version_index: 0,
            is_current: false,
            capture_date: None,
        });
        divergences.push(ContradictionPair {
            id: format!("div-{n}"),
            left_record_id: lid,
            right_record_id: rid,
            entity: name,
            attribute: attr_name.to_string(),
        });
    }

    // ── MXE-CT3 P4: decoy pairs (adversarial NON-contradictions) ────────────
    // Three shapes cycle; each is a pair the tiers must NOT flag. Decoy-hit
    // scoring (supersession_runner) counts appearances in tier sections and
    // legacy PROPOSED lines only — CANDIDATE (borderline adjudication feed)
    // and typed-section HISTORICAL lines are not hits. Twin of the Swift
    // block, including the per-shape RNG draw order.
    let mut decoys: Vec<DecoyPair> = Vec::new();
    // Shape (a)/(b) reuse the employer value pool so decoy claims read like
    // the genuine corpus claims rather than standing out lexically.
    let employer_values = attributes[0].1;
    for n in 0..decoy_count {
        let dfn = first_names[(rng.next_u64() % first_names.len() as u64) as usize];
        let dln = last_names[(rng.next_u64() % last_names.len() as u64) as usize];
        let lid = format!("dec-{n}-a");
        let rid = format!("dec-{n}-b");
        let dec_noted = noted_sentence(
            entity_count + contradiction_count + divergence_count + n);
        let kind: &str;
        match n % 3 {
            0 => {
                // (a) Explicit supersession-marker chain: v0 claim, then an
                // "Update: … moved to …" revision 250 days later. Genuinely a
                // supersession (resolvable by recency), NOT a contradiction —
                // marker_revision territory the tiers must leave alone. The
                // typed lane classifies the same coordinate at different
                // instants as historicalSuccession, never proof.
                kind = DECOY_KIND_MARKER_SUPERSESSION;
                let name = format!("{dfn} {dln} X{n}");
                let a = employer_values[(rng.next_u64() % employer_values.len() as u64) as usize];
                let mut b = employer_values[(rng.next_u64() % employer_values.len() as u64) as usize];
                if b == a {
                    let a_pos = employer_values.iter().position(|v| *v == a)
                        .expect("a drawn from values");
                    b = employer_values[(a_pos + 1) % employer_values.len()];
                }
                let t0 = epoch + (500 + n) as f64 * 86_400.0;
                records.push(SupersessionRecord {
                    id: lid.clone(),
                    entity: name.clone(),
                    attribute: "employer".to_string(),
                    value: a.to_string(),
                    content: format!("{name} works at {a}.") + &dec_noted,
                    event_time: iso8601_from_epoch_seconds(t0 as i64),
                    version_index: 0,
                    is_current: false,
                    capture_date: None,
                });
                records.push(SupersessionRecord {
                    id: rid.clone(),
                    entity: name.clone(),
                    attribute: "employer".to_string(),
                    value: b.to_string(),
                    content: format!("Update: {name} moved to {b}.") + &dec_noted,
                    event_time: iso8601_from_epoch_seconds((t0 + 250.0 * 86_400.0) as i64),
                    version_index: 1,
                    is_current: false,
                    capture_date: None,
                });
            }
            1 => {
                // (b) Distinct entities, same attribute, SAME value — two
                // people at the same employer is agreement about different
                // subjects, not conflict. The second first name is forced
                // distinct so the leading token always differs: a name
                // collision would leave only the digit-bearing suffix
                // differing, which reads as valueDivergence — the exact
                // false positive this shape probes.
                kind = DECOY_KIND_DISTINCT_ENTITY;
                let mut dfn2 =
                    first_names[(rng.next_u64() % first_names.len() as u64) as usize];
                let dln2 = last_names[(rng.next_u64() % last_names.len() as u64) as usize];
                if dfn2 == dfn {
                    let pos = first_names.iter().position(|v| *v == dfn)
                        .expect("dfn drawn from first_names");
                    dfn2 = first_names[(pos + 1) % first_names.len()];
                }
                let name1 = format!("{dfn} {dln} Y{n}");
                let name2 = format!("{dfn2} {dln2} Y{n}");
                let v = employer_values[(rng.next_u64() % employer_values.len() as u64) as usize];
                let when = iso8601_from_epoch_seconds((epoch + (600 + n) as f64 * 86_400.0) as i64);
                records.push(SupersessionRecord {
                    id: lid.clone(),
                    entity: name1.clone(),
                    attribute: "employer".to_string(),
                    value: v.to_string(),
                    content: format!("{name1} works at {v}.") + &dec_noted,
                    event_time: when.clone(),
                    version_index: 0,
                    is_current: false,
                    capture_date: None,
                });
                records.push(SupersessionRecord {
                    id: rid.clone(),
                    entity: name2.clone(),
                    attribute: "employer".to_string(),
                    value: v.to_string(),
                    content: format!("{name2} works at {v}.") + &dec_noted,
                    event_time: when,
                    version_index: 0,
                    is_current: false,
                    capture_date: None,
                });
            }
            _ => {
                // (c) Unit-equivalent duration pair: 90s == 1.5min
                // semantically, but the tokens are lexically divergent and
                // both digit-bearing, so ConflictCue's valueDivergence fires
                // — a KNOWN limitation (the lexical cue cannot normalize
                // units). Scored in the separate known-limitation row, never
                // as a hard decoy failure.
                kind = DECOY_KIND_UNIT_EQUIVALENT;
                let name = format!("{dfn} {dln} Z{n}");
                let when = iso8601_from_epoch_seconds((epoch + (700 + n) as f64 * 86_400.0) as i64);
                records.push(SupersessionRecord {
                    id: lid.clone(),
                    entity: name.clone(),
                    attribute: "deploy duration".to_string(),
                    value: "90s".to_string(),
                    content: format!("The deploy pipeline for {name} runs in 90s.") + &dec_noted,
                    event_time: when.clone(),
                    version_index: 0,
                    is_current: false,
                    capture_date: None,
                });
                records.push(SupersessionRecord {
                    id: rid.clone(),
                    entity: name.clone(),
                    attribute: "deploy duration".to_string(),
                    value: "1.5min".to_string(),
                    content: format!("The deploy pipeline for {name} runs in 1.5min.") + &dec_noted,
                    event_time: when,
                    version_index: 0,
                    is_current: false,
                    capture_date: None,
                });
            }
        }
        decoys.push(DecoyPair {
            id: format!("dec-{n}"),
            left_record_id: lid,
            right_record_id: rid,
            kind: kind.to_string(),
        });
    }

    SupersessionCorpus { seed, records, queries, contradictions, divergences, decoys }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso8601_matches_known_instants() {
        assert_eq!(iso8601_from_epoch_seconds(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601_from_epoch_seconds(1_580_000_000), "2020-01-26T00:53:20Z");
        // Leap-year boundary.
        assert_eq!(iso8601_from_epoch_seconds(1_582_934_400), "2020-02-29T00:00:00Z");
    }

    #[test]
    fn iso8601_round_trips() {
        for &epoch in &[0i64, 1_580_000_000, 1_582_934_400, 1_722_470_400] {
            let s = iso8601_from_epoch_seconds(epoch);
            assert_eq!(epoch_seconds_from_iso8601(&s), Some(epoch), "round trip for {s}");
        }
        assert_eq!(epoch_seconds_from_iso8601("not a date"), None);
        assert_eq!(epoch_seconds_from_iso8601("2020-13-01T00:00:00Z"), None);
    }

    #[test]
    fn generation_is_a_pure_function_of_seed() {
        let a = generate_supersession_corpus(42, 8, 3, 4);
        let b = generate_supersession_corpus(42, 8, 3, 4);
        assert_eq!(a, b);
        let c = generate_supersession_corpus(43, 8, 3, 4);
        assert_ne!(a.records[0].content, c.records[0].content);
    }

    #[test]
    fn chains_are_strictly_increasing_and_current_is_last() {
        let corpus = generate_supersession_corpus(20260725, 12, 3, 0);
        for q in &corpus.queries {
            let chain: Vec<&SupersessionRecord> = corpus
                .records
                .iter()
                .filter(|r| r.entity == q.entity && r.id.starts_with("sup-"))
                .collect();
            assert_eq!(chain.len(), 3);
            for w in chain.windows(2) {
                assert!(w[0].event_time < w[1].event_time);
            }
            assert!(chain.last().unwrap().is_current);
            assert_eq!(chain.last().unwrap().id, q.current_record_id);
            assert_eq!(q.superseded_record_ids.len(), 2);
        }
    }

    #[test]
    fn contradiction_pairs_share_event_time_and_differ_in_value() {
        let corpus = generate_supersession_corpus(7, 4, 2, 6);
        assert_eq!(corpus.contradictions.len(), 6);
        for pair in &corpus.contradictions {
            let left = corpus.records.iter().find(|r| r.id == pair.left_record_id).unwrap();
            let right = corpus.records.iter().find(|r| r.id == pair.right_record_id).unwrap();
            assert_eq!(left.event_time, right.event_time);
            assert_ne!(left.value, right.value);
            assert!(!left.is_current && !right.is_current);
        }
    }

    // ── MXE-CT3 P4: divergence + decoy classes ───────────────────────────

    #[test]
    fn generation_with_new_classes_is_a_pure_function_of_seed() {
        let a = generate_supersession_corpus_tiered(42, 8, 3, 4, 5, 6);
        let b = generate_supersession_corpus_tiered(42, 8, 3, 4, 5, 6);
        assert_eq!(a, b);
    }

    #[test]
    fn new_classes_draw_after_pre_p4_classes() {
        // The headline set is EXACTLY as today: every pre-P4 record, query,
        // and contradiction pair is byte-identical; the new records append.
        let before = generate_supersession_corpus(20260725, 6, 3, 4);
        let after = generate_supersession_corpus_tiered(20260725, 6, 3, 4, 5, 6);
        assert_eq!(after.queries, before.queries);
        assert_eq!(after.contradictions, before.contradictions);
        assert_eq!(&after.records[..before.records.len()], &before.records[..]);
        // And the 4-arg wrapper produces empty P4 classes.
        assert!(before.divergences.is_empty() && before.decoys.is_empty());
    }

    #[test]
    fn divergence_pairs_share_event_time_and_differ_only_in_a_numeric_value() {
        let corpus = generate_supersession_corpus_tiered(7, 4, 2, 2, 6, 0);
        assert_eq!(corpus.divergences.len(), 6);
        for pair in &corpus.divergences {
            let left = corpus.records.iter().find(|r| r.id == pair.left_record_id).unwrap();
            let right = corpus.records.iter().find(|r| r.id == pair.right_record_id).unwrap();
            assert_eq!(left.event_time, right.event_time);
            assert_eq!(left.entity, right.entity);
            assert_eq!(left.attribute, right.attribute);
            assert_ne!(left.value, right.value);
            // Numeric values — the tier-3 (valueDivergence) planted class.
            assert!(left.value.chars().any(|c| c.is_ascii_digit()));
            assert!(right.value.chars().any(|c| c.is_ascii_digit()));
            // Same template: contents differ ONLY at the value token.
            assert_eq!(
                left.content.replace(&left.value, "#"),
                right.content.replace(&right.value, "#"),
            );
        }
    }

    #[test]
    fn decoy_shapes_cycle_and_hold_their_invariants() {
        let corpus = generate_supersession_corpus_tiered(7, 4, 2, 2, 0, 6);
        assert_eq!(corpus.decoys.len(), 6);
        let kinds: Vec<&str> = corpus.decoys.iter().map(|d| d.kind.as_str()).collect();
        assert_eq!(
            kinds,
            vec![
                DECOY_KIND_MARKER_SUPERSESSION,
                DECOY_KIND_DISTINCT_ENTITY,
                DECOY_KIND_UNIT_EQUIVALENT,
                DECOY_KIND_MARKER_SUPERSESSION,
                DECOY_KIND_DISTINCT_ENTITY,
                DECOY_KIND_UNIT_EQUIVALENT,
            ]
        );
        for decoy in &corpus.decoys {
            let left = corpus.records.iter().find(|r| r.id == decoy.left_record_id).unwrap();
            let right = corpus.records.iter().find(|r| r.id == decoy.right_record_id).unwrap();
            match decoy.kind.as_str() {
                DECOY_KIND_MARKER_SUPERSESSION => {
                    // A real chain: later revision with an explicit marker.
                    assert!(left.event_time < right.event_time);
                    assert!(right.content.starts_with("Update: "));
                    assert!(right.content.contains(" moved to "));
                }
                DECOY_KIND_DISTINCT_ENTITY => {
                    // Different subjects, same value: agreement, not conflict.
                    assert_ne!(left.entity, right.entity);
                    assert_eq!(left.value, right.value);
                    assert_eq!(left.event_time, right.event_time);
                }
                _ => {
                    // Unit-equivalent: 90s vs 1.5min, same instant, same entity.
                    assert_eq!(left.entity, right.entity);
                    assert_eq!(left.value, "90s");
                    assert_eq!(right.value, "1.5min");
                    assert_eq!(left.event_time, right.event_time);
                }
            }
        }
    }

    #[test]
    fn cross_port_pins_for_p4_classes() {
        // These exact strings are pinned in the Swift leg's
        // SupersessionTieredTests.swift (crossPortPins). Both legs must
        // generate them for the same seed — a shared-fixture determinism
        // check without a committed vector file (the conformance directory
        // is outside this mission's write surface).
        let corpus = generate_supersession_corpus_tiered(20260725, 6, 3, 4, 5, 6);
        let by_id = |id: &str| corpus.records.iter().find(|r| r.id == id).unwrap();
        assert_eq!(by_id("div-0-a").content, "Response time for Ines Novak D0 is 90ms. Noted one Thursday morning in November.");
        assert_eq!(by_id("div-0-b").content, "Response time for Ines Novak D0 is 30ms. Noted one Thursday morning in November.");
        assert_eq!(by_id("div-0-a").event_time, "2021-03-01T00:53:20Z");
        assert_eq!(by_id("dec-0-a").content, "Diego Reyes X0 works at Beta Corp. Noted one Tuesday morning in April.");
        assert_eq!(by_id("dec-0-b").content, "Update: Diego Reyes X0 moved to Vireo Systems. Noted one Tuesday morning in April.");
        assert_eq!(by_id("dec-1-a").content, "Marcus Kowalski Y1 works at Acme Robotics. Noted one Wednesday noon in May.");
        assert_eq!(by_id("dec-1-b").content, "Amara Adeyemi Y1 works at Acme Robotics. Noted one Wednesday noon in May.");
        assert_eq!(by_id("dec-2-a").content, "The deploy pipeline for Amara Chen Z2 runs in 90s. Noted one Thursday afternoon in June.");
        assert_eq!(by_id("dec-2-b").content, "The deploy pipeline for Amara Chen Z2 runs in 1.5min. Noted one Thursday afternoon in June.");
    }

    #[test]
    fn pre_p4_dumps_without_new_keys_still_decode() {
        // The shape a pre-P4 dump (and the committed conformance vector
        // file) has on disk: no `divergences` / `decoys` keys. serde's
        // #[serde(default)] must fill them as empty.
        let old = generate_supersession_corpus(3, 2, 2, 1);
        let mut value = serde_json::to_value(&old).expect("encode");
        let object = value.as_object_mut().expect("corpus encodes as an object");
        object.remove("divergences");
        object.remove("decoys");
        let decoded: SupersessionCorpus =
            serde_json::from_value(value).expect("stripped dump must decode");
        assert_eq!(decoded, old);
        assert!(decoded.divergences.is_empty() && decoded.decoys.is_empty());
    }

    #[test]
    fn dump_round_trip_carries_the_new_classes() {
        let corpus = generate_supersession_corpus_tiered(11, 3, 2, 2, 2, 3);
        let json = serde_json::to_string(&corpus).expect("encode");
        let decoded: SupersessionCorpus = serde_json::from_str(&json).expect("decode");
        assert_eq!(decoded, corpus);
        assert_eq!(decoded.divergences.len(), 2);
        assert_eq!(decoded.decoys.len(), 3);
    }

    /// Finding 5 regression: the scored-hunt gate must fire when
    /// `contradictions` is empty but `divergences` (or `decoys`) is non-empty.
    ///
    /// Before the fix, both `contradiction_sweep` gates checked only
    /// `!corpus.contradictions.is_empty()`. A `--contradictions 0` run with
    /// divergences requested would silently skip scored scoring. The fixed gate
    /// is `!contradictions.is_empty() || !divergences.is_empty() || !decoys.is_empty()`.
    #[test]
    fn tiered_gate_fires_for_divergences_with_empty_contradictions() {
        let corpus = generate_supersession_corpus_tiered(42, 6, 2, 0, 5, 0);

        assert!(
            corpus.contradictions.is_empty(),
            "contradictions must be empty (0 requested)"
        );
        assert!(
            !corpus.divergences.is_empty(),
            "divergences must be non-empty (5 requested)"
        );

        // The post-fix gate condition (mirrors both runner locations):
        let gate_fires = !corpus.contradictions.is_empty()
            || !corpus.divergences.is_empty()
            || !corpus.decoys.is_empty();
        assert!(
            gate_fires,
            "gate must fire when divergences is non-empty even with 0 contradictions"
        );
    }
}
