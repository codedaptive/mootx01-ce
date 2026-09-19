//! gauntlet_corpus.rs — deterministic adversarial corpus data model, seeded
//! generator, and SplitMix64 PRNG.
//!
//! Ports `GauntletRNG.swift` + `GauntletCorpus.swift` + `GauntletGenerator.swift`.
//!
//! A `GauntletCorpus` is a pure function of one 64-bit seed: same seed → same
//! corpus, byte-for-byte. One `SplitMix64` threads through the entire generation
//! pass in a fixed draw order (tiers in `NoiseTier::all_cases()` order, needles
//! in sequence, distractors in plant order). The golden-pin conformance test in
//! this module's `#[cfg(test)]` section pins both ports to the identical
//! seed→corpus mapping.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// ─────────────────────────────────────────────────────────────────────────────
// SplitMix64 — port of GauntletRNG.swift
// ─────────────────────────────────────────────────────────────────────────────

/// A deterministic SplitMix64 PRNG. Same seed → same sequence. Not thread-safe
/// by design: one generator threads through one generation pass sequentially,
/// which is what guarantees reproducibility. Mirrors Swift `SplitMix64`.
///
/// The constants are the canonical SplitMix64 constants:
/// - `0x9E3779B97F4A7C15` is the 64-bit golden-ratio odd constant (Weyl step).
/// - `0xBF58476D1CE4E5B9` and `0x94D049BB133111EB` are the published mixing
///   multipliers. Do not change them — they lock every corpus ever emitted.
pub struct SplitMix64 {
    /// The 64-bit internal Weyl state. Advances by the golden-ratio increment
    /// on every draw, then is mixed to produce the output.
    state: u64,
    /// The seed this generator was created from, retained so callers can stamp
    /// it into output filenames and report headers.
    pub seed: u64,
}

impl SplitMix64 {
    /// Creates a generator seeded with `seed`. Two generators with the same
    /// seed produce the identical draw sequence.
    pub fn new(seed: u64) -> Self {
        Self { state: seed, seed }
    }

    /// Returns the next 64-bit value and advances the state. Mirrors Swift
    /// `next()`: advance the Weyl state by the golden-ratio increment
    /// (wrapping add, full 2^64 period), then apply the two-stage xor-shift-
    /// multiply finaliser to produce the output.
    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    /// Returns an integer uniformly in `0..bound` (exclusive, bound > 0).
    /// Uses the rejection-free Lemire-style multiply-high mapping over the
    /// 64-bit draw: a single multiply-and-shift maps the draw into the range
    /// with negligible bias for the small bounds this generator is asked for.
    /// Mirrors Swift `upTo(_:)`.
    pub fn up_to(&mut self, bound: usize) -> usize {
        assert!(bound > 0, "up_to bound must be positive");
        let draw = self.next_u64();
        // Multiply-high: (draw × bound) >> 64, computed via the 128-bit product.
        let product = (draw as u128) * (bound as u128);
        (product >> 64) as usize
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NoiseTier — port of GauntletCorpus.swift NoiseTier
// ─────────────────────────────────────────────────────────────────────────────

/// The five adversarial noise tiers. The raw value is the stable wire tag used
/// in `needles.json` and record metadata; do not renumber — conformance tests
/// and any pinned regression seeds depend on these exact strings. Mirrors Swift
/// `NoiseTier`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum NoiseTier {
    /// T1: distractors share the needle's salient tokens but assert a DIFFERENT
    /// fact. Defeats pure BM25/lexical-overlap retrievers.
    #[serde(rename = "T1")]
    Lexical,
    /// T2: paraphrases with CLOSE meaning but a WRONG value. Defeats a pure-
    /// vector retriever whose embedding sits near the needle's.
    #[serde(rename = "T2")]
    Semantic,
    /// T3: superseded earlier versions of the needle's own fact. Defeats a
    /// retriever with no recency/validity sense.
    #[serde(rename = "T3")]
    Temporal,
    /// T4: the answer is split across TWO records; neither alone is sufficient.
    #[serde(rename = "T4")]
    Split,
    /// T5: the needle is filed FAR from its topical neighbours; topical decoys
    /// occupy the expected location. Defeats a location-biased retriever.
    #[serde(rename = "T5")]
    Scatter,
}

impl NoiseTier {
    /// All five tiers in their canonical order (T1→T5). The draw order in
    /// `GauntletGenerator::generate` iterates these in this order, which is
    /// what makes the output byte-identical for a given seed.
    pub fn all_cases() -> [NoiseTier; 5] {
        [
            NoiseTier::Lexical,
            NoiseTier::Semantic,
            NoiseTier::Temporal,
            NoiseTier::Split,
            NoiseTier::Scatter,
        ]
    }

    /// The stable wire tag (`"T1"` … `"T5"`). Mirrors Swift `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Lexical  => "T1",
            Self::Semantic => "T2",
            Self::Temporal => "T3",
            Self::Split    => "T4",
            Self::Scatter  => "T5",
        }
    }

    /// Parses the stable wire tag. Returns `None` for unknown tags.
    pub fn from_raw(s: &str) -> Option<Self> {
        match s {
            "T1" => Some(Self::Lexical),
            "T2" => Some(Self::Semantic),
            "T3" => Some(Self::Temporal),
            "T4" => Some(Self::Split),
            "T5" => Some(Self::Scatter),
            _    => None,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RecordRole — port of GauntletCorpus.swift RecordRole
// ─────────────────────────────────────────────────────────────────────────────

/// The role a record plays in the corpus. Mirrors Swift `RecordRole`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RecordRole {
    /// The single correct answer for its query.
    #[serde(rename = "needle")]
    Needle,
    /// A record planted to defeat retrieval (the wrong answer).
    #[serde(rename = "distractor")]
    Distractor,
    /// The second half of a T4 split fact — correct-but-insufficient on its own.
    #[serde(rename = "splitPartner")]
    SplitPartner,
}

// ─────────────────────────────────────────────────────────────────────────────
// GauntletRecord + Needle + GauntletCorpus
// ─────────────────────────────────────────────────────────────────────────────

/// One record in `corpus.jsonl`. Carries everything a backend write needs
/// (content + location) plus generator metadata so the scorer can classify a
/// returned hit without re-deriving it. Mirrors Swift `GauntletRecord`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GauntletRecord {
    /// Stable corpus-local id (e.g. `"n0007"` for a needle, `"n0007-t1-2"` for
    /// its second T1 distractor). NOT the backend-assigned id.
    pub id: String,
    /// The verbatim content filed into the backend. For a needle this is the
    /// exact string the completeness check byte-compares against.
    pub content: String,
    /// Filing location, `wing/room[/…]` form. Passed whole as the mootx01
    /// `location` arg.
    pub location: String,
    /// Which tier this record belongs to (needle and all distractors share the
    /// needle's tier).
    pub tier: NoiseTier,
    /// Whether this record is the needle, a distractor, or a split partner.
    pub role: RecordRole,
    /// The corpus id of the needle this record orbits (a needle points at itself).
    #[serde(rename = "needleID")]
    pub needle_id: String,
}

/// Ground truth for one needle: the single query that should retrieve it at
/// rank 1, its verbatim content, its tier, location, and the ids of planted
/// noise records. Mirrors Swift `Needle`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Needle {
    /// The needle's corpus id (matches the `id` of its needle record).
    pub id: String,
    /// The single query expected to retrieve this needle at rank 1.
    pub query: String,
    /// The needle's verbatim content. Completeness is derived from returned
    /// items; no separate full-record fetch is performed.
    pub content: String,
    /// The needle's tier.
    pub tier: NoiseTier,
    /// Where the needle was filed (for diagnosis; T5 scatters this).
    pub location: String,
    /// Ids of the distractor records planted around this needle.
    #[serde(rename = "distractorIDs")]
    pub distractor_ids: Vec<String>,
    /// For a T4 split needle, the id of the partner record. `None` for
    /// non-split needles.
    #[serde(rename = "splitPartnerID")]
    pub split_partner_id: Option<String>,
    /// Expected rank of the needle in a correct backend's results. Always 1.
    /// Renamed to match Swift's camelCase property name (`expectedRank`) so the
    /// JSON written by each port is byte-compatible; the Swift `Needle` has no
    /// `CodingKeys` and therefore encodes the property name verbatim.
    #[serde(rename = "expectedRank")]
    pub expected_rank: i64,
}

/// The complete generated corpus: ordered records, ground-truth needles, the
/// seed, and the difficulty parameters that produced them. Mirrors Swift
/// `GauntletCorpus`.
#[derive(Debug, Clone)]
pub struct GauntletCorpus {
    pub seed: u64,
    pub records: Vec<GauntletRecord>,
    pub needles: Vec<Needle>,
    /// The tier mix actually used (needle count per tier). Keyed by tier so
    /// the report header can state the difficulty profile exactly.
    pub tier_counts: HashMap<NoiseTier, usize>,
    /// Distractors planted per needle (the difficulty dial).
    pub distractors_per_needle: usize,
}

// ─────────────────────────────────────────────────────────────────────────────
// GauntletProfile — port of GauntletGenerator.swift GauntletProfile
// ─────────────────────────────────────────────────────────────────────────────

/// Difficulty profile for a generation run: needles per tier and distractors
/// per needle. Both are CLI-driven so one generator emits an easy or a brutal
/// corpus. Mirrors Swift `GauntletProfile`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GauntletProfile {
    /// Needles to generate per tier. A tier with count 0 is omitted entirely.
    pub tier_counts: HashMap<NoiseTier, usize>,
    /// Distractors planted around each needle (the difficulty dial). For T4
    /// the split partner is in addition to these; for T3 the superseded version
    /// is one of these. Minimum 1 (enforced by `new`).
    pub distractors_per_needle: usize,
}

impl GauntletProfile {
    /// Creates a profile with an explicit per-tier count map and distractor
    /// count. Enforces the minimum distractor count of 1. Mirrors Swift
    /// `init(tierCounts:distractorsPerNeedle:)`.
    pub fn new(tier_counts: HashMap<NoiseTier, usize>, distractors_per_needle: usize) -> Self {
        Self {
            tier_counts,
            distractors_per_needle: distractors_per_needle.max(1),
        }
    }

    /// An even mix of all five tiers, `per_tier` needles each — the default
    /// when the CLI is given only a needle count. Mirrors Swift
    /// `evenMix(perTier:distractorsPerNeedle:)`.
    pub fn even_mix(per_tier: usize, distractors_per_needle: usize) -> Self {
        let mut counts = HashMap::new();
        for tier in NoiseTier::all_cases() {
            counts.insert(tier, per_tier);
        }
        Self::new(counts, distractors_per_needle)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// GauntletGenerator — port of GauntletGenerator.swift
// ─────────────────────────────────────────────────────────────────────────────

/// Attribute row: a (phrase, query noun, value-generator) triple. The value
/// generator turns an integer draw into a definite, checkable value. The pool
/// order is fixed — it is part of the deterministic draw space.
struct Attribute {
    phrase: &'static str,
    query_noun: &'static str,
    /// Pure function of `v`: integer draw → concrete value string.
    make_value: fn(usize) -> String,
}

/// The fixed pool of fictional subjects. Invented place/org names with no
/// real-world referent. Order is fixed — part of the deterministic draw space.
/// Mirrors Swift `GauntletGenerator.subjects`.
static SUBJECTS: &[&str] = &[
    "the Velrath Combine",   "Mirelle Station",        "the Korthane Accord",
    "Sundabar Holdings",     "the Ashfen Protocol",    "Caldwynn Foundry",
    "the Threnody Exchange", "Olwen Reservoir",        "the Pellucid Mandate",
    "Brackwater Hall",       "the Yarrow Concordat",   "Stillhaven Depot",
    "the Marrowgate Trust",  "Verisade Labs",          "the Quillon Charter",
    "Drossel Yards",         "the Ambergris League",   "Fenmark Atelier",
    "the Castellan Pact",    "Halloway Reach",
];

/// District values for the headquarters attribute. Mirrors the Swift closure pool.
static HQ_DISTRICTS: &[&str] = &["Tarn", "Vael", "Ostry", "Brenne", "Cawl", "Dunmere"];

/// Steward names. Mirrors the Swift closure pool.
static STEWARD_NAMES: &[&str] = &[
    "Oren Vask", "Lysa Crale", "Bertram Idle",
    "Nessa Pyke", "Calder Wren", "Imogen Strake",
];

/// Archive levels. Mirrors the Swift closure pool.
static ARCHIVE_LEVELS: &[&str] = &[
    "Sublevel Closed", "the Cinder Tier", "Vault Nine",
    "the Lower Stacks", "Gallery Zero", "the Deep Index",
];

/// The fixed pool of attributes (phrase, query noun, value generator). Order
/// is fixed — part of the deterministic draw space.
/// Mirrors Swift `GauntletGenerator.attributes`.
static ATTRIBUTES: &[Attribute] = &[
    Attribute {
        phrase:      "was chartered in the year",
        query_noun:  "charter year",
        make_value:  |v| format!("{}", 1700 + v % 320),
    },
    Attribute {
        phrase:      "is headquartered in the district of",
        query_noun:  "headquarters district",
        make_value:  |v| HQ_DISTRICTS[v % 6].to_string(),
    },
    Attribute {
        phrase:      "operates a fleet numbering exactly",
        query_noun:  "fleet size",
        make_value:  |v| format!("{} vessels", 12 + v % 488),
    },
    Attribute {
        phrase:      "is governed by the steward named",
        query_noun:  "presiding steward",
        make_value:  |v| STEWARD_NAMES[v % 6].to_string(),
    },
    Attribute {
        phrase:      "holds a reserve valued at",
        query_noun:  "reserve value",
        make_value:  |v| format!("{} million marks", 3 + v % 97),
    },
    Attribute {
        phrase:      "maintains its primary archive on the level called",
        query_noun:  "archive level",
        make_value:  |v| ARCHIVE_LEVELS[v % 6].to_string(),
    },
];

/// Topical wings a record can be filed under. The needle's home location is
/// derived from its subject index so topical neighbours cluster; T5 scatter
/// deliberately files the needle elsewhere. Mirrors Swift `GauntletGenerator.wings`.
static WINGS: &[&str] = &["Ledger", "Charter", "Fleet", "Steward", "Reserve", "Archive"];

/// Templates used by the T2 semantic distractor builder. The `%s` placeholder
/// is replaced with the wrong value. Mirrors the Swift `templates` array.
static SEMANTIC_TEMPLATES: &[&str] = &[
    "Records indicate that %s, as to its %s, shows %s.",
    "The %s attributed to %s is reported as %s.",
    "Per the filing, %s %s %s.",
    "It is widely noted that %s's %s stands at %s.",
];

/// The deterministic adversarial corpus generator. Mirrors Swift `GauntletGenerator`.
pub struct GauntletGenerator {
    pub profile: GauntletProfile,
}

impl GauntletGenerator {
    /// Creates a generator for the given difficulty profile.
    pub fn new(profile: GauntletProfile) -> Self {
        Self { profile }
    }

    /// Generates the corpus from `seed`. One `SplitMix64` seeded with `seed`
    /// threads the whole pass; the draw order is fixed (tiers in
    /// `NoiseTier::all_cases()` order, needles in sequence, distractors in
    /// plant order), which makes the output byte-identical for a given seed.
    /// Mirrors Swift `generate(seed:)`.
    pub fn generate(&self, seed: u64) -> GauntletCorpus {
        let mut rng = SplitMix64::new(seed);
        let mut records: Vec<GauntletRecord> = Vec::new();
        let mut needles: Vec<Needle> = Vec::new();
        let mut needle_serial = 0usize;

        // Iterate tiers in their canonical order so the emission order is stable.
        for &tier in &NoiseTier::all_cases() {
            let count = self.profile.tier_counts.get(&tier).copied().unwrap_or(0);
            for _ in 0..count {
                let nid = format!("n{:04}", needle_serial);
                needle_serial += 1;
                let (built_records, built_needle) = self.build_needle(&nid, tier, &mut rng);
                records.extend(built_records);
                needles.push(built_needle);
            }
        }

        // Retain only tiers with non-zero counts for the header.
        let mut tier_counts = HashMap::new();
        for (&tier, &count) in &self.profile.tier_counts {
            if count > 0 {
                tier_counts.insert(tier, count);
            }
        }

        GauntletCorpus {
            seed,
            records,
            needles,
            tier_counts,
            distractors_per_needle: self.profile.distractors_per_needle,
        }
    }

    // ── Needle construction ──────────────────────────────────────────────────

    /// Draws subject + attribute + value for a needle and dispatches to the
    /// tier-specific distractor constructor. Returns `(records, needle)`.
    /// Mirrors Swift `buildNeedle(id:tier:rng:)`.
    fn build_needle(
        &self,
        id: &str,
        tier: NoiseTier,
        rng: &mut SplitMix64,
    ) -> (Vec<GauntletRecord>, Needle) {
        let subject_idx  = rng.up_to(SUBJECTS.len());
        let attr_idx     = rng.up_to(ATTRIBUTES.len());
        let value_draw   = rng.up_to(10_000);

        let subject   = SUBJECTS[subject_idx];
        let attribute = &ATTRIBUTES[attr_idx];
        let value     = (attribute.make_value)(value_draw);

        // The needle states the fact in full.
        let content = format!("{} {} {}.", subject, attribute.phrase, value);
        // The query names the subject and attribute noun; the correct value
        // appears ONLY in the needle.
        let query = format!("What is the {} of {}?", attribute.query_noun, subject);
        // The home location clusters topical neighbours by attribute.
        let home_wing = WINGS[attr_idx % WINGS.len()];
        let home_location = format!("{}/{}", home_wing, subject_slug(subject));

        match tier {
            NoiseTier::Lexical =>
                self.build_lexical(id, subject, attr_idx, attribute, &value, &content, &query, &home_location, rng),
            NoiseTier::Semantic =>
                self.build_semantic(id, subject, attribute, &value, &content, &query, &home_location, rng),
            NoiseTier::Temporal =>
                self.build_temporal(id, subject, attribute, &value, &content, &query, &home_location, rng),
            NoiseTier::Split =>
                self.build_split(id, subject, attribute, &value, &content, &query, &home_location, rng),
            NoiseTier::Scatter =>
                self.build_scatter(id, subject, subject_idx, attr_idx, attribute, &value, &content, &query, &home_location, rng),
        }
    }

    // ── T1 lexical distractors ───────────────────────────────────────────────

    /// T1: distractors share the needle's subject token but assert a DIFFERENT
    /// fact (a different attribute of the same subject). Mirrors Swift
    /// `buildLexical`.
    fn build_lexical(
        &self,
        id: &str,
        subject: &str,
        attr_idx: usize,
        _attribute: &Attribute,
        _value: &str,
        content: &str,
        query: &str,
        location: &str,
        rng: &mut SplitMix64,
    ) -> (Vec<GauntletRecord>, Needle) {
        let needle_record = GauntletRecord {
            id: id.to_string(),
            content: content.to_string(),
            location: location.to_string(),
            tier: NoiseTier::Lexical,
            role: RecordRole::Needle,
            needle_id: id.to_string(),
        };
        let mut records = vec![needle_record];
        let mut distractor_ids = Vec::new();

        for k in 0..self.profile.distractors_per_needle {
            // Pick a DIFFERENT attribute of the SAME subject so the subject
            // token overlaps but the stated fact is unrelated to the query's
            // attribute. Mirrors Swift's modular offset logic.
            let other_attr_idx = (rng.up_to(ATTRIBUTES.len() - 1) + 1 + attr_idx) % ATTRIBUTES.len();
            let other_attr = &ATTRIBUTES[other_attr_idx];
            let other_value = (other_attr.make_value)(rng.up_to(10_000));
            let did = format!("{}-t1-{}", id, k);
            let d_content = format!("{} {} {}.", subject, other_attr.phrase, other_value);
            records.push(GauntletRecord {
                id: did.clone(),
                content: d_content,
                location: location.to_string(),
                tier: NoiseTier::Lexical,
                role: RecordRole::Distractor,
                needle_id: id.to_string(),
            });
            distractor_ids.push(did);
        }

        let needle = Needle {
            id: id.to_string(),
            query: query.to_string(),
            content: content.to_string(),
            tier: NoiseTier::Lexical,
            location: location.to_string(),
            distractor_ids,
            split_partner_id: None,
            expected_rank: 1,
        };
        (records, needle)
    }

    // ── T2 semantic distractors ──────────────────────────────────────────────

    /// T2: paraphrases with CLOSE meaning but a WRONG value. Mirrors Swift
    /// `buildSemantic`.
    fn build_semantic(
        &self,
        id: &str,
        subject: &str,
        attribute: &Attribute,
        value: &str,
        content: &str,
        query: &str,
        location: &str,
        rng: &mut SplitMix64,
    ) -> (Vec<GauntletRecord>, Needle) {
        let needle_record = GauntletRecord {
            id: id.to_string(),
            content: content.to_string(),
            location: location.to_string(),
            tier: NoiseTier::Semantic,
            role: RecordRole::Needle,
            needle_id: id.to_string(),
        };
        let mut records = vec![needle_record];
        let mut distractor_ids = Vec::new();

        for k in 0..self.profile.distractors_per_needle {
            let mut wrong_value = (attribute.make_value)(rng.up_to(10_000));
            // Guarantee the distractor's value differs from the needle's.
            // Re-draw deterministically until it differs; the value spaces are
            // large enough that this terminates immediately in practice.
            while wrong_value == value {
                wrong_value = (attribute.make_value)(rng.up_to(10_000));
            }
            let template = SEMANTIC_TEMPLATES[k % SEMANTIC_TEMPLATES.len()];
            let d_content = apply_semantic_template(template, subject, attribute.query_noun, &wrong_value);
            let did = format!("{}-t2-{}", id, k);
            records.push(GauntletRecord {
                id: did.clone(),
                content: d_content,
                location: location.to_string(),
                tier: NoiseTier::Semantic,
                role: RecordRole::Distractor,
                needle_id: id.to_string(),
            });
            distractor_ids.push(did);
        }

        let needle = Needle {
            id: id.to_string(),
            query: query.to_string(),
            content: content.to_string(),
            tier: NoiseTier::Semantic,
            location: location.to_string(),
            distractor_ids,
            split_partner_id: None,
            expected_rank: 1,
        };
        (records, needle)
    }

    // ── T3 temporal confusion ────────────────────────────────────────────────

    /// T3: superseded earlier versions of the needle's own fact, plus the
    /// current version (the needle). Mirrors Swift `buildTemporal`.
    fn build_temporal(
        &self,
        id: &str,
        subject: &str,
        attribute: &Attribute,
        value: &str,
        content: &str,
        query: &str,
        location: &str,
        rng: &mut SplitMix64,
    ) -> (Vec<GauntletRecord>, Needle) {
        // The needle carries an explicit currency marker so it reads as the
        // live version.
        let current_year = 2020 + rng.up_to(6);
        let needle_content = format!("{} (current as of {})", content, current_year);
        let needle_record = GauntletRecord {
            id: id.to_string(),
            content: needle_content.clone(),
            location: location.to_string(),
            tier: NoiseTier::Temporal,
            role: RecordRole::Needle,
            needle_id: id.to_string(),
        };
        let mut records = vec![needle_record];
        let mut distractor_ids = Vec::new();

        for k in 0..self.profile.distractors_per_needle {
            let mut stale_value = (attribute.make_value)(rng.up_to(10_000));
            while stale_value == value {
                stale_value = (attribute.make_value)(rng.up_to(10_000));
            }
            // Each superseded version is dated strictly before the current year.
            let stale_year = current_year - 1 - rng.up_to(20);
            let d_content = format!(
                "{} {} {}. (superseded; recorded {})",
                subject, attribute.phrase, stale_value, stale_year
            );
            let did = format!("{}-t3-{}", id, k);
            records.push(GauntletRecord {
                id: did.clone(),
                content: d_content,
                location: location.to_string(),
                tier: NoiseTier::Temporal,
                role: RecordRole::Distractor,
                needle_id: id.to_string(),
            });
            distractor_ids.push(did);
        }

        let needle = Needle {
            id: id.to_string(),
            query: query.to_string(),
            content: needle_content,
            tier: NoiseTier::Temporal,
            location: location.to_string(),
            distractor_ids,
            split_partner_id: None,
            expected_rank: 1,
        };
        (records, needle)
    }

    // ── T4 split facts ───────────────────────────────────────────────────────

    /// T4: the answer is split across TWO records. Mirrors Swift `buildSplit`.
    fn build_split(
        &self,
        id: &str,
        subject: &str,
        attribute: &Attribute,
        value: &str,
        _content: &str,
        query: &str,
        location: &str,
        rng: &mut SplitMix64,
    ) -> (Vec<GauntletRecord>, Needle) {
        let code = format!("REF-{:04}", rng.up_to(10_000));
        // The needle states the subject + existence of the fact under a code.
        let needle_content = format!(
            "{} records its {} under reference {}; see the matching reference entry for the value.",
            subject, attribute.query_noun, code
        );
        // The partner holds the actual value keyed by the same code.
        let partner_content = format!("Reference {}: the {} is {}.", code, attribute.query_noun, value);

        let needle_record = GauntletRecord {
            id: id.to_string(),
            content: needle_content.clone(),
            location: location.to_string(),
            tier: NoiseTier::Split,
            role: RecordRole::Needle,
            needle_id: id.to_string(),
        };
        let partner_id = format!("{}-partner", id);
        let partner_record = GauntletRecord {
            id: partner_id.clone(),
            content: partner_content,
            location: location.to_string(),
            tier: NoiseTier::Split,
            role: RecordRole::SplitPartner,
            needle_id: id.to_string(),
        };
        let mut records = vec![needle_record, partner_record];
        let mut distractor_ids = Vec::new();

        // Near-miss reference entries: same shape, different code + value.
        for k in 0..self.profile.distractors_per_needle {
            let other_code = format!("REF-{:04}", rng.up_to(10_000));
            let other_value = (attribute.make_value)(rng.up_to(10_000));
            let d_content = format!(
                "Reference {}: the {} is {}.",
                other_code, attribute.query_noun, other_value
            );
            let did = format!("{}-t4-{}", id, k);
            records.push(GauntletRecord {
                id: did.clone(),
                content: d_content,
                location: location.to_string(),
                tier: NoiseTier::Split,
                role: RecordRole::Distractor,
                needle_id: id.to_string(),
            });
            distractor_ids.push(did);
        }

        let needle = Needle {
            id: id.to_string(),
            query: query.to_string(),
            content: needle_content,
            tier: NoiseTier::Split,
            location: location.to_string(),
            distractor_ids,
            split_partner_id: Some(partner_id),
            expected_rank: 1,
        };
        (records, needle)
    }

    // ── T5 cross-location scatter ────────────────────────────────────────────

    /// T5: the needle is filed FAR from its topical home; topical decoys are
    /// filed where it "should" live. Mirrors Swift `buildScatter`.
    fn build_scatter(
        &self,
        id: &str,
        subject: &str,
        _subject_idx: usize,
        _attr_idx: usize,
        attribute: &Attribute,
        value: &str,
        content: &str,
        query: &str,
        home_location: &str,
        rng: &mut SplitMix64,
    ) -> (Vec<GauntletRecord>, Needle) {
        // Scatter the needle to a DISTANT wing/room, deliberately unrelated to
        // its attribute's topical home. The far wing is chosen to differ from home.
        let home_wing_name = home_location.split('/').next().unwrap_or("Ledger");
        let mut far_wing = WINGS[rng.up_to(WINGS.len())];
        while far_wing == home_wing_name {
            far_wing = WINGS[rng.up_to(WINGS.len())];
        }
        let far_location = format!("{}/Outpost-{}", far_wing, rng.up_to(900) + 100);

        let needle_record = GauntletRecord {
            id: id.to_string(),
            content: content.to_string(),
            location: far_location.clone(),
            tier: NoiseTier::Scatter,
            role: RecordRole::Needle,
            needle_id: id.to_string(),
        };
        let mut records = vec![needle_record];
        let mut distractor_ids = Vec::new();

        // Topical decoys at the HOME location: same attribute topic, same
        // subject, but a wrong value.
        for k in 0..self.profile.distractors_per_needle {
            let mut decoy_value = (attribute.make_value)(rng.up_to(10_000));
            while decoy_value == value {
                decoy_value = (attribute.make_value)(rng.up_to(10_000));
            }
            let d_content = format!("{} {} {}.", subject, attribute.phrase, decoy_value);
            let did = format!("{}-t5-{}", id, k);
            records.push(GauntletRecord {
                id: did.clone(),
                content: d_content,
                location: home_location.to_string(),
                tier: NoiseTier::Scatter,
                role: RecordRole::Distractor,
                needle_id: id.to_string(),
            });
            distractor_ids.push(did);
        }

        let needle = Needle {
            id: id.to_string(),
            query: query.to_string(),
            content: content.to_string(),
            tier: NoiseTier::Scatter,
            location: far_location,
            distractor_ids,
            split_partner_id: None,
            expected_rank: 1,
        };
        (records, needle)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// A filesystem-safe, deterministic slug for a subject (drop articles and
/// punctuation, hyphenate). Used to build a stable per-subject room name so
/// topical neighbours cluster under one room.
/// Mirrors Swift `GauntletGenerator.subjectSlug`.
pub fn subject_slug(subject: &str) -> String {
    let lowered = subject.to_lowercase().replace("the ", "");
    // Replace non-alphanumeric characters with hyphens.
    let kept: String = lowered.chars().map(|c| {
        if c.is_alphanumeric() { c } else { '-' }
    }).collect();
    // Collapse runs of hyphens and trim.
    let parts: Vec<&str> = kept.split('-').filter(|s| !s.is_empty()).collect();
    if parts.is_empty() { "room".to_string() } else { parts.join("-") }
}

/// Applies one of the T2 semantic templates. The Swift `String(format:, ...)`
/// `%@` placeholders correspond to the three arguments in fixed order.
/// Template formats:
///   0: "Records indicate that %s, as to its %s, shows %s."
///      → (subject, query_noun, wrong_value)
///   1: "The %s attributed to %s is reported as %s."
///      → (query_noun, subject, wrong_value)
///   2: "Per the filing, %s %s %s."
///      → (subject, attribute.phrase, wrong_value)
///   3: "It is widely noted that %s's %s stands at %s."
///      → (subject, query_noun, wrong_value)
fn apply_semantic_template(template: &str, subject: &str, query_noun: &str, wrong_value: &str) -> String {
    // The Swift implementation uses `String(format:template, wrongValue)` with
    // `%@` for a SINGLE argument (the wrong value), with the subject and noun
    // baked into the template string. The templates here ARE baked, so just
    // replace the `%s` with the wrong value in a fixed-position manner.
    // Actually looking at the Swift templates more carefully:
    //   "Records indicate that \(subject), as to its \(attribute.queryNoun), shows %@."
    // The subject and query_noun are string-interpolated IN THE TEMPLATE at
    // build time in Swift; `%@` is the ONLY format hole (for wrongValue).
    // In our static template list we use `%s` as the placeholder for subject,
    // query_noun, and wrong_value in the ORDER they appear in the template.
    // Let's fill left-to-right:
    template_fill(template, &[subject, query_noun, wrong_value])
}

/// Fills positional `%s` placeholders left-to-right with the given arguments.
fn template_fill(template: &str, args: &[&str]) -> String {
    let mut result = String::with_capacity(template.len() + 64);
    let mut arg_idx = 0;
    let mut chars = template.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '%' && chars.peek() == Some(&'s') {
            chars.next(); // consume 's'
            if arg_idx < args.len() {
                result.push_str(args[arg_idx]);
                arg_idx += 1;
            }
        } else {
            result.push(c);
        }
    }
    result
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── SplitMix64 ──────────────────────────────────────────────────────────

    #[test]
    fn splitmix64_deterministic_same_seed_same_sequence() {
        let mut a = SplitMix64::new(0xDEAD_BEEF);
        let mut b = SplitMix64::new(0xDEAD_BEEF);
        for _ in 0..1000 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn splitmix64_differs_across_seeds() {
        let mut a = SplitMix64::new(1);
        let mut b = SplitMix64::new(2);
        let any_differ = (0..10).any(|_| a.next_u64() != b.next_u64());
        assert!(any_differ, "expected at least one differing draw across seeds");
    }

    /// Canonical reference vector: the published SplitMix64 first outputs for
    /// state seeded at 0. These pin the exact constants so a future edit to
    /// the mixing function is caught. The same vector appears in the Swift
    /// GauntletGeneratorTests.canonicalVector test.
    #[test]
    fn splitmix64_canonical_vector_seed_zero() {
        let mut rng = SplitMix64::new(0);
        let expected: &[u64] = &[
            0xE220A8397B1DCDAF,
            0x6E789E6AA1B965F4,
            0x06C45D188009454F,
            0xF88BB8A8724C81EC,
            0x1B39896A51A8749B,
        ];
        for &e in expected {
            assert_eq!(rng.next_u64(), e, "SplitMix64 output mismatch vs canonical vector");
        }
    }

    #[test]
    fn splitmix64_up_to_in_range() {
        let mut rng = SplitMix64::new(42);
        for _ in 0..10_000 {
            let v = rng.up_to(7);
            assert!(v < 7, "up_to(7) returned out-of-range value {}", v);
        }
    }

    // ── Generator ───────────────────────────────────────────────────────────

    #[test]
    fn same_seed_produces_identical_corpus() {
        let gen = GauntletGenerator::new(GauntletProfile::even_mix(3, 4));
        let a = gen.generate(12345);
        let b = gen.generate(12345);
        assert_eq!(a.records, b.records, "records must be byte-identical for same seed");
        assert_eq!(a.needles, b.needles, "needles must be byte-identical for same seed");
    }

    #[test]
    fn different_seeds_produce_different_corpora() {
        let gen = GauntletGenerator::new(GauntletProfile::even_mix(3, 4));
        let a = gen.generate(1);
        let b = gen.generate(2);
        assert_ne!(a.records, b.records);
    }

    #[test]
    fn needle_count_matches_tier_profile() {
        let mut counts = HashMap::new();
        counts.insert(NoiseTier::Lexical, 2);
        counts.insert(NoiseTier::Semantic, 3);
        counts.insert(NoiseTier::Temporal, 1);
        counts.insert(NoiseTier::Split, 4);
        counts.insert(NoiseTier::Scatter, 2);
        let profile = GauntletProfile::new(counts, 3);
        let corpus = GauntletGenerator::new(profile).generate(7);
        assert_eq!(corpus.needles.len(), 2 + 3 + 1 + 4 + 2);
        for &tier in &NoiseTier::all_cases() {
            let expected_count = corpus.tier_counts.get(&tier).copied().unwrap_or(0);
            let actual_count = corpus.needles.iter().filter(|n| n.tier == tier).count();
            assert_eq!(actual_count, expected_count,
                "tier {:?}: expected {} needles, got {}", tier, expected_count, actual_count);
        }
    }

    #[test]
    fn each_needle_ground_truth_is_internally_consistent() {
        let gen = GauntletGenerator::new(GauntletProfile::even_mix(3, 4));
        let corpus = gen.generate(99);
        let record_by_id: HashMap<&str, &GauntletRecord> =
            corpus.records.iter().map(|r| (r.id.as_str(), r)).collect();
        for needle in &corpus.needles {
            let rec = record_by_id.get(needle.id.as_str())
                .unwrap_or_else(|| panic!("needle record {} not found", needle.id));
            assert_eq!(rec.role, RecordRole::Needle);
            assert_eq!(rec.content, needle.content, "needle {} content mismatch", needle.id);
            assert_eq!(rec.tier, needle.tier);
            assert_eq!(needle.expected_rank, 1);
            for did in &needle.distractor_ids {
                let d = record_by_id.get(did.as_str())
                    .unwrap_or_else(|| panic!("distractor {} not found", did));
                assert_eq!(d.role, RecordRole::Distractor,
                    "distractor {} wrong role", did);
                assert_eq!(d.needle_id, needle.id);
                assert_eq!(d.tier, needle.tier);
                assert_ne!(d.content, needle.content,
                    "distractor {} accidentally duplicates the needle answer", did);
            }
        }
    }

    #[test]
    fn difficulty_dial_drives_record_count() {
        let easy = GauntletGenerator::new(GauntletProfile::new(
            {let mut m = HashMap::new(); m.insert(NoiseTier::Lexical, 4); m}, 1,
        )).generate(8);
        let hard = GauntletGenerator::new(GauntletProfile::new(
            {let mut m = HashMap::new(); m.insert(NoiseTier::Lexical, 4); m}, 8,
        )).generate(8);
        assert!(hard.records.len() > easy.records.len());
        // easy: 4 needles × (1 needle + 1 distractor) = 8
        assert_eq!(easy.records.len(), 4 * (1 + 1));
        // hard: 4 × (1 + 8) = 36
        assert_eq!(hard.records.len(), 4 * (1 + 8));
    }

    #[test]
    fn t3_needle_marked_current_distractors_superseded() {
        let gen = GauntletGenerator::new(GauntletProfile::new(
            {let mut m = HashMap::new(); m.insert(NoiseTier::Temporal, 5); m}, 3,
        ));
        let corpus = gen.generate(4);
        let record_by_id: HashMap<&str, &GauntletRecord> =
            corpus.records.iter().map(|r| (r.id.as_str(), r)).collect();
        for needle in &corpus.needles {
            assert!(needle.content.contains("current as of"),
                "T3 needle must be marked current");
            for did in &needle.distractor_ids {
                let d = &record_by_id[did.as_str()];
                assert!(d.content.contains("superseded"),
                    "T3 distractor must be marked superseded");
            }
        }
    }

    #[test]
    fn t4_split_has_partner_with_value() {
        let gen = GauntletGenerator::new(GauntletProfile::new(
            {let mut m = HashMap::new(); m.insert(NoiseTier::Split, 5); m}, 2,
        ));
        let corpus = gen.generate(5);
        let record_by_id: HashMap<&str, &GauntletRecord> =
            corpus.records.iter().map(|r| (r.id.as_str(), r)).collect();
        for needle in &corpus.needles {
            assert!(needle.split_partner_id.is_some(), "T4 needle must have a split partner");
            let pid = needle.split_partner_id.as_ref().unwrap();
            let partner = &record_by_id[pid.as_str()];
            assert_eq!(partner.role, RecordRole::SplitPartner);
            assert!(needle.content.contains("reference"), "T4 needle must contain a reference code");
            assert!(partner.content.contains("Reference"), "T4 partner must contain the reference value");
        }
    }

    #[test]
    fn t5_scatter_files_needle_away_from_distractors() {
        let gen = GauntletGenerator::new(GauntletProfile::new(
            {let mut m = HashMap::new(); m.insert(NoiseTier::Scatter, 5); m}, 3,
        ));
        let corpus = gen.generate(6);
        let record_by_id: HashMap<&str, &GauntletRecord> =
            corpus.records.iter().map(|r| (r.id.as_str(), r)).collect();
        for needle in &corpus.needles {
            let needle_wing = needle.location.split('/').next().unwrap_or("");
            for did in &needle.distractor_ids {
                let d = &record_by_id[did.as_str()];
                let d_wing = d.location.split('/').next().unwrap_or("");
                assert_ne!(needle_wing, d_wing,
                    "T5 needle wing ({}) should differ from distractor wing ({})",
                    needle_wing, d_wing);
            }
        }
    }

    // ── GOLDEN PIN — cross-port determinism gate ─────────────────────────────
    //
    // Seed 42, even mix, 1 needle per tier, 1 distractor: the first record
    // emitted (corpus[0]) is the T1 lexical needle n0000. This literal content
    // string is pinned in BOTH the Rust and Swift ports so any change to the
    // generator, RNG constants, subject/attribute pools, or draw order is caught
    // here and in GauntletGeneratorTests.crossPortGoldenPin (Swift).
    //
    // DO NOT UPDATE this constant without also updating the Swift twin.
    // If the value changes, RE-DERIVE it by running the generator and verifying
    // BOTH ports agree on the new value before hardcoding.

    /// GOLDEN PIN SEED — fixed for the cross-port conformance test.
    pub const GOLDEN_PIN_SEED: u64 = 42;

    /// The verbatim content of `corpus.records[0]` for seed 42, even mix
    /// (per_tier=1, distractors=1). This value is byte-identical on the Swift
    /// port (GauntletGeneratorTests.crossPortGoldenPin).
    /// If this test fails, the two ports have diverged on corpus generation.
    pub const GOLDEN_PIN_RECORD0_CONTENT: &str =
        "the Quillon Charter was chartered in the year 1926.";

    #[test]
    fn cross_port_golden_pin_record0_content() {
        // Even mix: 1 needle per tier, 1 distractor per needle — minimal corpus
        // so the pin covers one full generation pass without being expensive.
        let gen = GauntletGenerator::new(GauntletProfile::even_mix(1, 1));
        let corpus = gen.generate(GOLDEN_PIN_SEED);
        assert_eq!(
            corpus.records[0].content,
            GOLDEN_PIN_RECORD0_CONTENT,
            "CROSS-PORT GOLDEN PIN FAILED: corpus[0].content for seed {} \
             must match the Swift twin's value. \
             If the generator logic changed deliberately, update BOTH ports and \
             GauntletGeneratorTests.crossPortGoldenPin before merging.",
            GOLDEN_PIN_SEED
        );
    }

    // ── Needle JSON schema — expectedRank field name ─────────────────────────
    //
    // Swift `Needle` has `expectedRank: Int` with no `CodingKeys` enum, so
    // `JSONEncoder` emits the property name verbatim as `"expectedRank"`.
    // This test pins the Rust serde serialization: the field name in the
    // on-disk JSON must be camelCase, not snake_case.
    //
    // Cross-port round-trip coverage (Swift writes → Rust reads, and Rust
    // writes → Swift reads) lives in tests/cross_port_gauntlet_corpus.rs,
    // which loads REAL fixture files produced by each port's writer.

    #[test]
    fn needle_expected_rank_serializes_as_camel_case() {
        // Use serde_json::to_string (the same encoder write_corpus uses for
        // the needles.json file) on a Needle produced by direct construction
        // — the simplest path to the real serde output without file I/O.
        let needle = Needle {
            id: "n1".to_string(),
            query: "q".to_string(),
            content: "c".to_string(),
            tier: NoiseTier::Lexical,
            location: "wing/room".to_string(),
            distractor_ids: vec![],
            split_partner_id: None,
            expected_rank: 7,
        };
        let json = serde_json::to_string(&needle).unwrap();
        // The key must be the Swift-compatible camelCase name; if it is
        // snake_case the cross-port schema is broken and any corpus written
        // by the Rust port is unreadable by the Swift port (and vice versa).
        assert!(
            json.contains(r#""expectedRank":7"#),
            "expected JSON to contain `\"expectedRank\":7`; got: {json}"
        );
        assert!(
            !json.contains("expected_rank"),
            "snake_case key must not appear in the JSON output; got: {json}"
        );
    }
}
