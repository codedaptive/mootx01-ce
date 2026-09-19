//! artifact_recall.rs — thin vertical measurement slice for the NEW two-form
//! benchmark artifacts (LoCoMo lane only). Twin of Swift
//! `ArtifactRecallRunner.swift`.
//!
//! Unlike every other lane, artifact-recall does NOT provision a scratch
//! estate: the estate IS the artifact, pre-built in the external seeding
//! workspace and passed via
//! --estate-dir. The lane is strictly READ-ONLY against that estate — the
//! only tool it ever calls is moot_memory_search — which is why it does not
//! route through the /tmp scratch guard: that guard keeps WRITE lanes off
//! durable stores, and this lane's whole point is to measure a durable store
//! in place.
//!
//! Per question: moot_memory_search (wing-scoped when scope=wing), returned
//! drawer UUIDs are mapped back to seed ids via `<estate-dir>/id-map.json`,
//! and hit@k / MRR are scored against the question's answer_session_ids.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::json_value::JsonValue;
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use crate::scratch_posture::moot_serve_command;

// ─────────────────────────────────────────────────────────────────────────────
// Question model + loading
// ─────────────────────────────────────────────────────────────────────────────

/// One question from the artifact questions.jsonl.
///
/// Only the fields the recall slice consumes are modelled. The `answer` field
/// is deliberately ABSENT: it can be a string OR a bare number in the corpus
/// (e.g. `"answer": 2022`), and recall scoring never reads it. Twin of Swift
/// `ArtifactRecallQuestion`.
#[derive(Debug, Clone, PartialEq)]
pub struct ArtifactRecallQuestion {
    /// Question identity for the misses report — the dataset's own id field
    /// (locomo sample_id, convomem query_id, membench tid path, lme-s
    /// question_id).
    pub sample_id: String,
    /// Form-1 unit-estate stem (units/<stem>.json filename stem), derived
    /// per dataset from the question's own fields; drives per-unit grouping
    /// at unit target-scale.
    pub unit_stem: String,
    /// Wing the material was seeded under in the Form-2 estate. Empty for
    /// lme-s (the deduped estate has no instance wings).
    pub wing: String,
    /// The question text sent to moot_memory_search. Third person: a
    /// non-empty "question_3p" wins; "question" is the fallback.
    pub question: String,
    /// Per-dataset breakdown label (locomo category, convomem set, membench
    /// family/category, lme-s question_type).
    pub label: String,
    /// Ground-truth seed record ids. Empty for adversarial / abstention
    /// questions, which are excluded from scoring.
    pub answer_session_ids: Vec<String>,
}

/// The four rebuilt-artifact datasets the measure lane understands (#94
/// measure seam: one runner, per-dataset question adapters, scoring
/// identical everywhere). Twin of Swift `ArtifactDataset`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArtifactDataset {
    Locomo,
    Convomem,
    Membench,
    LmeS,
}

impl ArtifactDataset {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "locomo" => Some(Self::Locomo),
            "convomem" => Some(Self::Convomem),
            "membench" => Some(Self::Membench),
            "lme-s" => Some(Self::LmeS),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Locomo => "locomo",
            Self::Convomem => "convomem",
            Self::Membench => "membench",
            Self::LmeS => "lme-s",
        }
    }

    /// Decodes one questions.jsonl row into the normalized question, or
    /// None when the dataset's required fields are missing. Twin of Swift
    /// `ArtifactDataset.question(from:)`.
    fn question(&self, obj: &serde_json::Value) -> Option<ArtifactRecallQuestion> {
        let s = |k: &str| obj.get(k).and_then(|v| v.as_str()).map(str::to_string);
        let ids = |k: &str| -> Vec<String> {
            obj.get(k)
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default()
        };
        // Third-person text wins; fall back to the primary field.
        let three_p = s("question_3p").unwrap_or_default();
        let primary = s("question").unwrap_or_default();
        let text = if three_p.is_empty() { primary } else { three_p };
        if text.is_empty() {
            return None;
        }
        match self {
            Self::Locomo => {
                let sample_id = s("sample_id")?;
                Some(ArtifactRecallQuestion {
                    unit_stem: sample_id.clone(),
                    sample_id,
                    wing: s("wing")?,
                    question: text,
                    label: obj
                        .get("category")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(0)
                        .to_string(),
                    answer_session_ids: ids("answer_session_ids"),
                })
            }
            Self::Convomem => {
                let query_id = s("query_id")?;
                let set = s("set")?;
                // query_id "scene_0_q_0" → unit "user_evidence__scene_0"
                // (units/<set>__<scene>.json).
                let mut comps = query_id.split('_');
                if comps.next() != Some("scene") {
                    return None;
                }
                let scene_n = comps.next()?;
                Some(ArtifactRecallQuestion {
                    sample_id: format!("{set}/{query_id}"),
                    unit_stem: format!("{set}__scene_{scene_n}"),
                    wing: s("wing")?,
                    question: text,
                    label: set,
                    answer_session_ids: ids("answer_session_ids"),
                })
            }
            Self::Membench => {
                let family = s("family")?;
                let category = s("category")?;
                let section = s("section")?;
                // tid is an Int or a String in the corpus; normalize to text.
                let tid = obj.get("tid").map(|v| match v {
                    serde_json::Value::String(t) => t.clone(),
                    other => other.to_string(),
                })?;
                Some(ArtifactRecallQuestion {
                    sample_id: format!("{family}/{category}/{section}/{tid}"),
                    unit_stem: format!("{family}__{category}__{section}__{tid}"),
                    wing: s("wing")?,
                    question: text,
                    label: format!("{family}/{category}"),
                    // MemBench Rule-2 ground truth is drawer-level.
                    answer_session_ids: ids("answer_drawer_ids"),
                })
            }
            Self::LmeS => {
                let qid = s("question_id")?;
                Some(ArtifactRecallQuestion {
                    sample_id: qid.clone(),
                    unit_stem: qid,
                    // The deduped lme estate carries no instance wings;
                    // questions run unscoped (two-form ruling).
                    wing: String::new(),
                    question: text,
                    label: s("question_type").unwrap_or_default(),
                    answer_session_ids: ids("answer_session_ids"),
                })
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit stem validation
// ─────────────────────────────────────────────────────────────────────────────

/// Longest unit stem accepted, in bytes. A stem names a unit seed file
/// (units/<stem>.json) and a unit estate directory; 128 keeps both well
/// inside every filesystem's name limit with room for the suffix.
pub const ARTIFACT_UNIT_STEM_MAX_LEN: usize = 128;

/// True iff `stem` may name a unit seed file or a unit estate directory.
///
/// Stems are corpus-derived (sample_id, question_id, tid path …), and at
/// unit scale a stem is resolved from the artifact catalog and interpolated into
/// the serve launch command, which the stdio launcher splits on whitespace. The
/// rule is therefore deliberately narrow: non-empty, at most
/// `ARTIFACT_UNIT_STEM_MAX_LEN` bytes, first character an ASCII letter or
/// digit, every later character an ASCII letter, digit, `.`, `_` or `-`,
/// and never "." or "..". A valid stem is exactly one plain path component
/// and exactly one launch-command token. Only ASCII passes, so the byte
/// count equals the character count. The seeders apply the same rule before
/// writing a unit file; the Swift twin is `isValidUnitStem`, and both ports
/// pin the same literal vectors in their tests.
pub fn is_valid_unit_stem(stem: &str) -> bool {
    let bytes = stem.as_bytes();
    if bytes.is_empty() || bytes.len() > ARTIFACT_UNIT_STEM_MAX_LEN {
        return false;
    }
    if stem == "." || stem == ".." {
        return false;
    }
    if !bytes[0].is_ascii_alphanumeric() {
        return false;
    }
    bytes[1..]
        .iter()
        .all(|&b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
}

/// The one-line statement of the stem rule, shared by every rejection
/// message so an operator reading a failed run sees what a stem must be.
pub const ARTIFACT_UNIT_STEM_RULE: &str = "a unit stem must be non-empty, at most 128 \
     characters, start with an ASCII letter or digit, and contain only ASCII letters, \
     digits, '.', '_' or '-'";

/// Resolves the unit estate directory for `stem` directly under `set_dir`.
///
/// Defense in depth behind the catalog resolver's validation: the stem is
/// checked again here, and the joined path must sit DIRECTLY under `set_dir` —
/// its parent equal to the set directory and its last component equal to the
/// stem — so no stem can address an estate outside its catalog set. Twin of the
/// Swift `artifactUnitEstateDir`.
pub fn artifact_unit_estate_dir(set_dir: &Path, stem: &str) -> Result<PathBuf, MCPError> {
    if !is_valid_unit_stem(stem) {
        return Err(MCPError {
            description: format!(
                "unit stem '{stem}' is not a valid unit stem: {ARTIFACT_UNIT_STEM_RULE}"
            ),
        });
    }
    let unit_dir = set_dir.join(stem);
    let parent_ok = unit_dir.parent() == Some(set_dir);
    let leaf_ok = unit_dir.file_name().and_then(|n| n.to_str()) == Some(stem);
    if !(parent_ok && leaf_ok) {
        return Err(MCPError {
            description: format!(
                "unit estate for '{}' resolved to {}, which is not directly under \
                 its set directory {}",
                stem,
                unit_dir.display(),
                set_dir.display()
            ),
        });
    }
    Ok(unit_dir)
}

/// Resolves the unit estate directory for `unit_id` from the artifact catalog
/// at `catalog_path`.
///
/// Walks the catalog's `sets` array in row order. For each set, the set
/// directory is `<base>/<path>` and the candidate unit directory is
/// `<set_dir>/<unit_id>`. A directory counts as an estate when it carries
/// `estate.sqlite` or `databases/default/estate.sqlite` (same two-location
/// check as `artifact_layout.py:estate_db`). The first row whose unit
/// directory exists and carries an estate database is returned; row order is
/// the tie-break when an id appears in two sets. The containment guard
/// (`artifact_unit_estate_dir`) is applied against the resolved set directory
/// to ensure the unit path sits directly under its set.
///
/// Error messages are byte-identical with the Swift twin:
///   "catalog not readable at <catalogPath>"
///   "unit '<id>' is not in the catalog at <catalogPath>"
pub fn resolve_unit_from_catalog(
    catalog_path: &Path,
    unit_id: &str,
) -> Result<PathBuf, MCPError> {
    // Validate the unit id as a stem first — an invalid stem cannot name an
    // estate directory in any set row.
    if !is_valid_unit_stem(unit_id) {
        return Err(MCPError {
            description: format!(
                "unit stem '{unit_id}' is not a valid unit stem: {ARTIFACT_UNIT_STEM_RULE}"
            ),
        });
    }

    let bytes = std::fs::read(catalog_path).map_err(|_| MCPError {
        description: format!("catalog not readable at {}", catalog_path.display()),
    })?;
    let catalog: serde_json::Value = serde_json::from_slice(&bytes).map_err(|_| MCPError {
        description: format!("catalog not readable at {}", catalog_path.display()),
    })?;
    let sets = catalog
        .get("sets")
        .and_then(|v| v.as_array())
        .ok_or_else(|| MCPError {
            description: format!("catalog not readable at {}", catalog_path.display()),
        })?;

    for set in sets {
        let base = set.get("base").and_then(|v| v.as_str());
        let path = set.get("path").and_then(|v| v.as_str());
        let (Some(base), Some(path)) = (base, path) else {
            continue; // malformed row — skip rather than abort
        };
        // Set directory is base + path (two-field join, exactly as the Python writer
        // computes it in artifact_layout.py:write_catalog). Different set rows may
        // carry different bases when the primary base was at capacity; the resolver
        // must honour each row's own base independently.
        let set_dir = Path::new(base).join(path);
        // Apply the containment guard. unit_id already passed is_valid_unit_stem;
        // the guard also prevents any path-normalisation escape edge cases.
        let unit_dir = match artifact_unit_estate_dir(&set_dir, unit_id) {
            Ok(d) => d,
            // A refusal — containment violation or invalid stem — is a
            // security-relevant rejection. Propagate it immediately rather
            // than silently continuing to the next set row, which would
            // misreport the refusal as a catalog miss.
            Err(e) => return Err(e),
        };
        // A directory counts as an estate only when it carries estate.sqlite or
        // databases/default/estate.sqlite (mirrors artifact_layout.py:estate_db).
        if unit_dir.join("estate.sqlite").exists()
            || unit_dir
                .join("databases")
                .join("default")
                .join("estate.sqlite")
                .exists()
        {
            return Ok(unit_dir);
        }
    }

    Err(MCPError {
        description: format!(
            "unit '{}' is not in the catalog at {}",
            unit_id,
            catalog_path.display()
        ),
    })
}

/// Parses questions.jsonl content into questions. Blank lines are skipped;
/// a line that is not JSON, or that is missing the dataset's required
/// fields, is a hard error. A row whose derived unit stem fails
/// `is_valid_unit_stem` is likewise a hard error naming the offending id:
/// the stem becomes a path and a launch-command token at unit scale, and a
/// corpus that smuggles anything else in must stop the run, never be
/// skipped. Twin of Swift `loadArtifactRecallQuestions`.
pub fn load_artifact_recall_questions(
    jsonl: &str,
    dataset: ArtifactDataset,
) -> Result<Vec<ArtifactRecallQuestion>, MCPError> {
    let mut questions = Vec::new();
    for (index, raw_line) in jsonl.lines().enumerate() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let obj: serde_json::Value = serde_json::from_str(line).map_err(|e| MCPError {
            description: format!("questions.jsonl line {} is not JSON: {e}", index + 1),
        })?;
        let question = dataset.question(&obj).ok_or_else(|| MCPError {
            description: format!(
                "questions.jsonl line {} missing required {} fields: {}",
                index + 1,
                dataset.as_str(),
                &line[..line.len().min(120)]
            ),
        })?;
        if !is_valid_unit_stem(&question.unit_stem) {
            return Err(MCPError {
                description: format!(
                    "questions.jsonl line {}: unit stem '{}' derived from id '{}' is not \
                     a valid unit stem: {ARTIFACT_UNIT_STEM_RULE}",
                    index + 1,
                    question.unit_stem,
                    question.sample_id
                ),
            });
        }
        questions.push(question);
    }
    Ok(questions)
}

/// Splits questions into (scored, no_evidence count): empty answer_session_ids
/// cannot be recall-scored and are counted separately rather than polluting
/// hit@k/MRR with guaranteed zeros. Twin of Swift `partitionArtifactQuestions`.
pub fn partition_artifact_questions(
    questions: Vec<ArtifactRecallQuestion>,
) -> (Vec<ArtifactRecallQuestion>, usize) {
    let total = questions.len();
    let scored: Vec<_> = questions
        .into_iter()
        .filter(|q| !q.answer_session_ids.is_empty())
        .collect();
    let no_evidence = total - scored.len();
    (scored, no_evidence)
}

/// Applies --limit: 0 means all, N > 0 keeps the first N in file order.
/// Twin of Swift `applyArtifactLimit`.
pub fn apply_artifact_limit(
    mut questions: Vec<ArtifactRecallQuestion>,
    limit: usize,
) -> Vec<ArtifactRecallQuestion> {
    if limit > 0 {
        questions.truncate(limit);
    }
    questions
}

/// At unit target-scale, a bounded fleet build (`make fleet-<ds> LIMIT=N` /
/// `UNITS=...`) writes a catalog holding fewer units than the dataset's
/// questions.jsonl has, and it is not an error for a question to name a unit
/// the catalog does not carry — it is simply out of the measured slice.
/// Splits `questions` into (in_catalog, outside_catalog_count): a question is
/// "outside the catalog" iff `resolve_unit_from_catalog` refuses its unit
/// stem specifically with the "is not in the catalog" refusal. Any OTHER
/// resolution failure — an invalid stem, a containment violation, an
/// unreadable catalog.json — is a real defect and propagates rather than
/// being swallowed as absence.
///
/// Distinct unit stems are resolved once and cached, so a corpus with many
/// questions per unit costs one catalog walk per unit, not one per question.
/// Order is preserved (file order in, file order out) so the caller can
/// apply --limit afterward and get a deterministic prefix of real,
/// catalog-backed questions. Twin of Swift `partitionQuestionsByCatalog`.
pub fn partition_questions_by_catalog(
    questions: Vec<ArtifactRecallQuestion>,
    catalog_path: &Path,
) -> Result<(Vec<ArtifactRecallQuestion>, usize), MCPError> {
    let not_in_catalog_suffix = format!("is not in the catalog at {}", catalog_path.display());
    let mut resolved_stems: HashMap<String, bool> = HashMap::new();
    let mut in_catalog = Vec::with_capacity(questions.len());
    let mut outside_count = 0usize;
    for question in questions {
        if let Some(&present) = resolved_stems.get(&question.unit_stem) {
            if present {
                in_catalog.push(question);
            } else {
                outside_count += 1;
            }
            continue;
        }
        match resolve_unit_from_catalog(catalog_path, &question.unit_stem) {
            Ok(_) => {
                resolved_stems.insert(question.unit_stem.clone(), true);
                in_catalog.push(question);
            }
            Err(e) if e.description.ends_with(&not_in_catalog_suffix) => {
                resolved_stems.insert(question.unit_stem.clone(), false);
                outside_count += 1;
            }
            // Any other error (invalid stem, containment violation,
            // unreadable catalog) is a real defect — propagate it.
            Err(e) => return Err(e),
        }
    }
    Ok((in_catalog, outside_count))
}

// ─────────────────────────────────────────────────────────────────────────────
// id-map
// ─────────────────────────────────────────────────────────────────────────────

/// Loads `<estate_dir>/id-map.json`: a flat JSON object mapping seed record id
/// ("conv-26/S1") → drawer UUID string. REQUIRED — its absence is a clear hard
/// error naming the expected path. Twin of Swift `loadArtifactIDMap`.
pub fn load_artifact_id_map(estate_dir: &Path) -> Result<HashMap<String, String>, MCPError> {
    let path = estate_dir.join("id-map.json");
    if !path.exists() {
        return Err(MCPError {
            description: format!(
                "id-map.json not found at {} — the artifact-recall lane requires \
                 the seed-id → drawer-UUID map written by the seeding pipeline; \
                 repair pre-id-map estates before measuring them",
                path.display()
            ),
        });
    }
    let data = std::fs::read(&path).map_err(|e| MCPError {
        description: format!("could not read {}: {e}", path.display()),
    })?;
    let obj: serde_json::Value = serde_json::from_slice(&data).map_err(|e| MCPError {
        description: format!("id-map.json at {} is not JSON: {e}", path.display()),
    })?;
    let map = obj.as_object().ok_or_else(|| MCPError {
        description: format!(
            "id-map.json at {} is not a flat {{seed-id: uuid}} object",
            path.display()
        ),
    })?;
    let mut out = HashMap::new();
    for (k, v) in map {
        let uuid = v.as_str().ok_or_else(|| MCPError {
            description: format!(
                "id-map.json at {}: value for '{k}' is not a string",
                path.display()
            ),
        })?;
        out.insert(k.clone(), uuid.to_string());
    }
    Ok(out)
}

/// Loads `id-map.json` if it exists; otherwise reconstructs the seed-id → UUID
/// map from the estate's `drawers` table using `sourceFile` and `chunkIndex`
/// columns (seed-id = `"<sourceFile>/<chunkIndex>"`). When that path yields no
/// rows and `seed_units_dir` is `Some`, a third path derives the map from
/// `drawers.lineageID` by matching FNV-1a-128 hashes of seed record ids
/// (JSON-import-lane estates store the FNV-1a-128 hash of each seed record id
/// as the drawer's lineageID UUID).
///
/// Priority: (1) id-map.json wins; (2) sourceFile/chunkIndex reconstruction;
/// (3) lineage derivation from seed-units JSON.
///
/// Returns `Err` with a descriptive message when all three sources fail.
/// Used by membench-spec when artifact estates are pre-existing and may lack
/// an `id-map.json`.
///
/// Twin of Swift `loadOrReconstructIDMap(estateDir:seedUnitsDir:)`.
pub fn load_or_reconstruct_id_map(
    estate_dir: &Path,
    seed_units_dir: Option<&Path>,
) -> Result<HashMap<String, String>, MCPError> {
    let id_map_path = estate_dir.join("id-map.json");
    // (1) id-map.json wins over all other sources.
    if id_map_path.exists() {
        return load_artifact_id_map(estate_dir);
    }
    // Attempt reconstruction from the estate SQLite database (sources 2 and 3).
    let db_path = crate::estate_cache::estate_database_path(estate_dir).ok_or_else(|| MCPError {
        description: format!(
            "id-map.json not found at {} and no estate.sqlite found in '{}' — \
             cannot reconstruct seed-id map",
            id_map_path.display(),
            estate_dir.display()
        ),
    })?;
    let conn = estate_encryption::open_raw(&db_path, None).map_err(|e| MCPError {
        description: format!(
            "id-map.json not found at {} and cannot open '{}': {e:?}",
            id_map_path.display(),
            db_path.display()
        ),
    })?;
    // (2) sourceFile/chunkIndex reconstruction.
    // A prepare failure (e.g. column absent on a JSON-import estate) is treated
    // as "no rows" — mirrors Swift's `sqlite3_prepare_v2(...) == SQLITE_OK` guard.
    let mut out = HashMap::new();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT id, sourceFile, chunkIndex FROM drawers \
         WHERE tombstonedAt IS NULL AND sourceFile IS NOT NULL AND chunkIndex IS NOT NULL",
    ) {
        if let Ok(mapped) = stmt.query_map([], |row| {
            let uuid: String = row.get(0)?;
            let source_file: String = row.get(1)?;
            let chunk_index: i64 = row.get(2)?;
            Ok((uuid, source_file, chunk_index))
        }) {
            for row in mapped.flatten() {
                let seed_id = format!("{}/{}", row.1, row.2);
                out.insert(seed_id, row.0);
            }
        }
    }
    if !out.is_empty() {
        return Ok(out);
    }
    // (3) Lineage derivation: match drawers.lineageID against FNV-1a-128 hashes
    // of seed record ids. Used by JSON-import-lane estates that populate lineageID
    // instead of sourceFile/chunkIndex.
    if let Some(seed_dir) = seed_units_dir {
        let estate_name = estate_dir
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        let seed_file = seed_dir.join(format!("{estate_name}.json"));
        if seed_file.exists() {
            if let Ok(lineage_map) =
                derive_id_map_from_lineage(&db_path, estate_name, &seed_file)
            {
                if !lineage_map.is_empty() {
                    return Ok(lineage_map);
                }
            }
        }
    }
    Err(MCPError {
        description: format!(
            "id-map derivation failed for estate '{}' — tried: \
             (1) id-map.json at {} — absent; \
             (2) sourceFile/chunkIndex in drawers — no rows; \
             (3) lineageID derivation — {}",
            estate_dir.file_name().and_then(|n| n.to_str()).unwrap_or(""),
            id_map_path.display(),
            if seed_units_dir.is_some() { "no matching lineage rows" } else { "seed-units-dir not provided" }
        ),
    })
}

/// Computes the FNV-1a 128-bit hash of a UTF-8 string and returns it as an
/// uppercase UUID string (`XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`).
///
/// Offset basis: high = 0x6c62272e07bb0142, low = 0x62b821756295c58d.
/// Prime: high = 0x0000000001000000, low = 0x000000000000013B.
/// Per byte: XOR byte into low word, then 128-bit multiply by prime (mod 2^128).
/// Result packed big-endian as 16 UUID bytes.
///
/// Twin of Swift `fnv1a128LineageID(for:)`.
pub fn fnv1a128_lineage_id(s: &str) -> String {
    // FNV-1a 128-bit prime: 309485009821345068724781371 (split into two u64 words).
    const PRIME_HIGH: u64 = 0x0000_0000_0100_0000;
    const PRIME_LOW: u64 = 0x0000_0000_0000_013B;
    let mut high: u64 = 0x6c62_272e_07bb_0142;
    let mut low: u64 = 0x62b8_2175_6295_c58d;
    for byte in s.bytes() {
        low ^= byte as u64;
        // 128-bit multiply by prime mod 2^128.
        // low_new  = (low * PRIME_LOW) mod 2^64
        // carry    = (low * PRIME_LOW) >> 64     — carry into high word
        // high_new = (high * PRIME_LOW + low_old * PRIME_HIGH + carry) mod 2^64
        // (high * PRIME_HIGH and higher cross-terms overflow 128 bits — discarded)
        let full = (low as u128).wrapping_mul(PRIME_LOW as u128);
        let product_low = full as u64;
        let carry = (full >> 64) as u64;
        high = high
            .wrapping_mul(PRIME_LOW)
            .wrapping_add(low.wrapping_mul(PRIME_HIGH))
            .wrapping_add(carry);
        low = product_low;
    }
    // Pack big-endian as UUID: 4-2-2-2-6 byte groups.
    format!(
        "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        (high >> 56) as u8, (high >> 48) as u8, (high >> 40) as u8, (high >> 32) as u8,
        (high >> 24) as u8, (high >> 16) as u8,
        (high >>  8) as u8,  high        as u8,
        (low  >> 56) as u8, (low  >> 48) as u8,
        (low  >> 40) as u8, (low  >> 32) as u8, (low  >> 24) as u8, (low  >> 16) as u8,
        (low  >>  8) as u8,  low         as u8,
    )
}

/// Derives seed-id → drawer-UUID map from `drawers.lineageID` by loading
/// seed unit records from `seed_file`, computing FNV-1a-128 of each record id,
/// and matching against lineageID values in the estate database at `db_path`.
///
/// Opens its own database connection so callers need not expose the
/// `rusqlite` type — `rusqlite` is not a direct dependency of this crate;
/// it comes in transitively through `estate-encryption`.
///
/// Returns an empty map (not an error) when the seed file cannot be parsed or
/// no lineage rows match — callers decide whether to escalate.
fn derive_id_map_from_lineage(
    db_path: &Path,
    _estate_name: &str,
    seed_file: &Path,
) -> Result<HashMap<String, String>, MCPError> {
    // Load seed records and build lineageUUID → seedRecordID lookup.
    let data = std::fs::read(seed_file).map_err(|e| MCPError {
        description: format!("lineage derive: read seed file {}: {e}", seed_file.display()),
    })?;
    let root: serde_json::Value = serde_json::from_slice(&data).map_err(|e| MCPError {
        description: format!("lineage derive: parse seed file {}: {e}", seed_file.display()),
    })?;
    let records = root
        .get("records")
        .and_then(|v| v.as_array())
        .ok_or_else(|| MCPError {
            description: format!(
                "lineage derive: seed file {} has no 'records' array",
                seed_file.display()
            ),
        })?;
    // Build lineageUUID (uppercase) → seed record id.
    let mut lineage_to_seed: HashMap<String, String> = HashMap::new();
    for record in records {
        if let Some(id) = record.get("id").and_then(|v| v.as_str()) {
            let lineage_uuid = fnv1a128_lineage_id(id);
            lineage_to_seed.insert(lineage_uuid.to_uppercase(), id.to_string());
        }
    }
    if lineage_to_seed.is_empty() {
        return Ok(HashMap::new());
    }
    // Open a fresh connection to the estate database.
    let conn = estate_encryption::open_raw(db_path, None).map_err(|e| MCPError {
        description: format!("lineage derive: open db {}: {e:?}", db_path.display()),
    })?;
    // Query drawers for non-tombstoned lineageID values.
    let mut stmt = conn
        .prepare(
            "SELECT id, lineageID FROM drawers WHERE tombstonedAt IS NULL AND lineageID IS NOT NULL",
        )
        .map_err(|e| MCPError {
            description: format!("lineage derive: prepare drawers query: {e}"),
        })?;
    let mut out = HashMap::new();
    let rows = stmt
        .query_map([], |row| {
            let drawer_uuid: String = row.get(0)?;
            let lineage_id: String = row.get(1)?;
            Ok((drawer_uuid, lineage_id))
        })
        .map_err(|e| MCPError {
            description: format!("lineage derive: drawers query: {e}"),
        })?;
    for row in rows {
        let (drawer_uuid, lineage_id) = row.map_err(|e| MCPError {
            description: format!("lineage derive: drawers row: {e}"),
        })?;
        // lineageID stored as UUID; normalise to uppercase for lookup.
        let key = lineage_id.to_uppercase();
        if let Some(seed_id) = lineage_to_seed.get(&key) {
            // Emit seed_id → drawer_uuid (same direction as id-map.json).
            out.insert(seed_id.clone(), drawer_uuid);
        }
    }
    Ok(out)
}

/// Builds the UUID → seed-id reverse map, lowercasing UUID keys so
/// serve-returned UUIDs match regardless of case. Twin of Swift
/// `artifactReverseIDMap`.
pub fn artifact_reverse_id_map(id_map: &HashMap<String, String>) -> HashMap<String, String> {
    id_map
        .iter()
        .map(|(seed_id, uuid)| (uuid.to_lowercase(), seed_id.clone()))
        .collect()
}

/// Maps ranked result UUIDs to seed ids, deduplicating repeated seed ids
/// (first rank wins). A UUID absent from the map keeps its rank slot as
/// "unmapped:<uuid>" — it is a real returned result that is not the answer,
/// so collapsing it would inflate the ranks below it. Twin of Swift
/// `artifactMapRankedUUIDs`.
pub fn artifact_map_ranked_uuids(
    uuids: &[String],
    reverse: &HashMap<String, String>,
) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut ranked = Vec::new();
    for uuid in uuids {
        let key = uuid.to_lowercase();
        let seed_id = reverse
            .get(&key)
            .cloned()
            .unwrap_or_else(|| format!("unmapped:{key}"));
        if seen.insert(seed_id.clone()) {
            ranked.push(seed_id);
        }
    }
    ranked
}

// ─────────────────────────────────────────────────────────────────────────────
// Scoring
// ─────────────────────────────────────────────────────────────────────────────

/// Per-question score: hit@k over the top k ranked seed ids, reciprocal rank
/// over the FULL ranked list (with top_k as the search limit the two windows
/// coincide; they diverge only if the server returns more rows than k).
/// Twin of Swift `scoreArtifactQuestion` — literal test vectors are asserted
/// identically in both ports.
pub fn score_artifact_question(
    ranked_seed_ids: &[String],
    expected: &[String],
    k: usize,
) -> (bool, f64) {
    let expected_set: HashSet<&str> = expected.iter().map(String::as_str).collect();
    for (index, id) in ranked_seed_ids.iter().enumerate() {
        if expected_set.contains(id.as_str()) {
            return (index < k, 1.0 / (index as f64 + 1.0));
        }
    }
    (false, 0.0)
}

// ─────────────────────────────────────────────────────────────────────────────
// Run configuration + live runner
// ─────────────────────────────────────────────────────────────────────────────

/// Whether the moot_memory_search call carries the question's wing.
/// Twin of Swift `ArtifactRecallScope`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArtifactRecallScope {
    /// Pass the question's "wing" as the search's wing argument.
    Wing,
    /// Omit the wing argument — search the whole estate.
    Estate,
}

impl ArtifactRecallScope {
    /// The CLI/report spelling of the scope.
    pub fn as_str(&self) -> &'static str {
        match self {
            ArtifactRecallScope::Wing => "wing",
            ArtifactRecallScope::Estate => "estate",
        }
    }
}

/// Which artifact scale the run measures — the measure-side counterpart of
/// the seeding pipeline's three artifact scales. Questions and scoring are
/// identical at every scale; only which estate gets opened changes. Twin of
/// Swift `ArtifactTargetScale`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArtifactTargetScale {
    /// Form-1 estate-per-instance: questions grouped by unit stem, each
    /// group runs against its own estate resolved from the catalog.
    Unit,
    /// Form-2 one-estate-per-benchmark (`estate_dir`).
    BenchAggregate,
    /// The complete one-database estate (`estate_dir`); expected seed ids
    /// gain the dataset's build-plumbing prefix ("<dataset>/").
    CompleteAggregate,
}

impl ArtifactTargetScale {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "unit" => Some(Self::Unit),
            "bench-aggregate" => Some(Self::BenchAggregate),
            "complete-aggregate" => Some(Self::CompleteAggregate),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Unit => "unit",
            Self::BenchAggregate => "bench-aggregate",
            Self::CompleteAggregate => "complete-aggregate",
        }
    }
}

/// Configuration for one artifact-recall run. Twin of Swift
/// `ArtifactRecallConfig`.
pub struct ArtifactRecallConfig {
    /// Which dataset's questions.jsonl shape to decode.
    pub dataset: ArtifactDataset,
    /// Which artifact scale is being measured.
    pub target_scale: ArtifactTargetScale,
    /// The pre-built artifact estate directory. Set for
    /// the two aggregate scales; None at unit scale.
    pub estate_dir: Option<PathBuf>,
    /// Path to the dataset's catalog.json (set at unit scale; None otherwise).
    /// The catalog resolves each unit id to its estate directory under
    /// whichever base (primary or secondary) the builder chose.
    pub catalog_path: Option<PathBuf>,
    /// questions.jsonl path.
    pub questions_path: PathBuf,
    /// Search scoping mode. Ignored at unit scale (each unit estate IS the
    /// official per-instance scope).
    pub scope: ArtifactRecallScope,
    /// The per-call ARIA global modifier `chest_diversity` sent on every
    /// search: "on" / "off" overrides the estate preference
    /// chest_recall_diversity for the run (ADR-027 D3, the A/B switch);
    /// None sends nothing and the estate preference decides.
    pub chest_diversity: Option<String>,
    /// Prefix applied to expected seed ids before id-map lookup — the
    /// complete estate's record ids carry "<dataset>/" from build plumbing.
    pub id_prefix: String,
    /// Question cap (0 = all).
    pub limit: usize,
    /// Search result limit AND the k of hit@k.
    pub top_k: usize,
    /// Report output path.
    pub out_path: PathBuf,
    /// mootx01 binary path.
    pub moot_binary: String,
}

/// Per-question outcome retained for aggregation and the misses list.
struct ArtifactQuestionOutcome {
    question: ArtifactRecallQuestion,
    hit_at_k: bool,
    reciprocal_rank: f64,
    ranked_seed_ids: Vec<String>,
}

/// Asks one batch of questions against one estate: spawns a READ-ONLY serve
/// on `estate_dir`, runs every question through moot_memory_search, maps and
/// scores the results. Both target scales share this loop — the aggregate
/// scales call it once, unit scale calls it once per unit estate. Twin of
/// Swift `askArtifactQuestions`.
fn ask_artifact_questions(
    estate_dir: &Path,
    questions: Vec<ArtifactRecallQuestion>,
    config: &ArtifactRecallConfig,
) -> Result<Vec<ArtifactQuestionOutcome>, MCPError> {
    // Fail-fast input validation, cheapest first: the id-map requirement is
    // checked before serve is ever spawned.
    if crate::estate_cache::estate_database_path(estate_dir).is_none() {
        return Err(MCPError {
            description: format!(
                "no estate.sqlite in {} — the target-scale/dir arguments must \
                 point at a built artifact estate",
                estate_dir.display()
            ),
        });
    }
    let id_map = load_artifact_id_map(estate_dir)?;
    let reverse = artifact_reverse_id_map(&id_map);

    // READ-ONLY endpoint on the artifact estate, opened as a transient record
    // (`--db <dir>`): plaintext, identity keys in memory. Deliberately
    // NOT routed through the /tmp scratch guard: that guard pins WRITE lanes
    // to scratch, and this lane reads a durable artifact in place.
    let command = moot_serve_command(
        &config.moot_binary, &estate_dir, false, &["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"], None)
        .map_err(|e| MCPError { description: e.to_string() })?;
    // Bare search verb map: NO constant location arg — artifact estates are
    // wing-structured, so scoping is the wing argument (or nothing).
    let verb_map = VerbMap::new(
        crate::aria_v2_surface::FILE_MEMORY,
        crate::aria_v2_surface::MEMORY_SEARCH,
        None,
        None,
        None,
        None,
        Some(BTreeMap::new()),
        Some(ResultFormat::MootV2),
    );
    let endpoint = EndpointConfig {
        name: "mootx01-artifact-recall".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map,
        role: EndpointRole::Both,
    };
    let mut client = MCPClient::new(endpoint);
    client.connect()?;

    let mut outcomes: Vec<ArtifactQuestionOutcome> = Vec::with_capacity(questions.len());
    for question in questions {
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("query".to_string(), JsonValue::String(question.question.clone()));
        args.insert("limit".to_string(), JsonValue::Number(config.top_k as f64));
        // Unit scale never wing-scopes: the unit estate IS the official
        // per-instance scope. A question with no wing (lme-s) searches
        // unscoped in every mode.
        if config.target_scale != ArtifactTargetScale::Unit
            && config.scope == ArtifactRecallScope::Wing
            && !question.wing.is_empty()
        {
            args.insert("wing".to_string(), JsonValue::String(question.wing.clone()));
        }
        if let Some(chest_diversity) = &config.chest_diversity {
            args.insert("chest_diversity".to_string(), JsonValue::String(chest_diversity.clone()));
        }
        let result = client.call_tool(crate::aria_v2_surface::MEMORY_SEARCH, args, &ResultFormat::MootV2)?;
        let ranked = artifact_map_ranked_uuids(&result.ordered_ids, &reverse);
        // The complete estate's record ids carry the dataset prefix from
        // build plumbing; expected ids are prefixed to match its id-map.
        let expected: Vec<String> = question
            .answer_session_ids
            .iter()
            .map(|id| format!("{}{id}", config.id_prefix))
            .collect();
        let (hit_at_k, reciprocal_rank) =
            score_artifact_question(&ranked, &expected, config.top_k);
        outcomes.push(ArtifactQuestionOutcome {
            question,
            hit_at_k,
            reciprocal_rank,
            ranked_seed_ids: ranked,
        });
    }
    Ok(outcomes)
}

/// Runs the artifact-recall slice at the configured target scale and writes
/// the report. Scoring is identical at every scale; only which estate(s)
/// get opened changes (the #94 measure-side contract). Twin of Swift
/// `runArtifactRecallLane(config:)`.
pub fn run_artifact_recall_lane(config: &ArtifactRecallConfig) -> Result<(), MCPError> {
    let jsonl = std::fs::read_to_string(&config.questions_path).map_err(|e| MCPError {
        description: format!(
            "could not read questions at {}: {e}",
            config.questions_path.display()
        ),
    })?;
    let all = load_artifact_recall_questions(&jsonl, config.dataset)?;
    let total_loaded = all.len();
    let (scored_pool, no_evidence) = partition_artifact_questions(all);

    // At unit scale, a bounded fleet build can hold fewer units than the
    // dataset has: drop every question whose unit the catalog does not
    // carry BEFORE applying --limit, so a smoke of N questions on a bounded
    // set measures N real questions instead of refusing on the first
    // absent unit. Every other scale has no catalog, so nothing is outside
    // it.
    let (scored_in_catalog, questions_outside_catalog): (Vec<ArtifactRecallQuestion>, usize) =
        if config.target_scale == ArtifactTargetScale::Unit {
            match config.catalog_path.as_ref() {
                Some(catalog_path) => partition_questions_by_catalog(scored_pool, catalog_path)?,
                None => (scored_pool, 0),
            }
        } else {
            (scored_pool, 0)
        };
    let questions = apply_artifact_limit(scored_in_catalog, config.limit);
    if questions.is_empty() {
        return Err(MCPError {
            description: format!(
                "no scorable questions (loaded {total_loaded}, no_evidence {no_evidence}, \
                 outside_catalog {questions_outside_catalog})"
            ),
        });
    }

    eprintln!(
        "[artifact-recall] dataset={} scale={} questions={} scope={} top-k={} no_evidence={}",
        config.dataset.as_str(),
        config.target_scale.as_str(),
        questions.len(),
        config.scope.as_str(),
        config.top_k,
        no_evidence
    );

    let mut outcomes: Vec<ArtifactQuestionOutcome>;
    let mut unit_count = 1usize;
    match config.target_scale {
        ArtifactTargetScale::BenchAggregate | ArtifactTargetScale::CompleteAggregate => {
            let estate_dir = config.estate_dir.as_ref().ok_or_else(|| MCPError {
                description: format!("{} requires --estate-dir", config.target_scale.as_str()),
            })?;
            outcomes = ask_artifact_questions(estate_dir, questions, config)?;
        }
        ArtifactTargetScale::Unit => {
            let catalog_path = config.catalog_path.as_ref().ok_or_else(|| MCPError {
                description: "unit scale requires --catalog".to_string(),
            })?;
            // Group by unit stem in first-appearance order so runs are
            // deterministic and each unit estate is opened exactly once.
            let mut order: Vec<String> = Vec::new();
            let mut groups: BTreeMap<String, Vec<ArtifactRecallQuestion>> = BTreeMap::new();
            for q in questions {
                if !groups.contains_key(&q.unit_stem) {
                    order.push(q.unit_stem.clone());
                }
                groups.entry(q.unit_stem.clone()).or_default().push(q);
            }
            unit_count = order.len();
            outcomes = Vec::new();
            for (index, stem) in order.iter().enumerate() {
                let group = groups.remove(stem).unwrap_or_default();
                eprintln!(
                    "[artifact-recall] unit {}/{}: {stem} ({} questions)",
                    index + 1,
                    unit_count,
                    group.len()
                );
                outcomes.extend(ask_artifact_questions(
                    &resolve_unit_from_catalog(catalog_path, stem)?,
                    group,
                    config,
                )?);
            }
        }
    }

    let report = artifact_recall_report(
        config,
        &outcomes,
        no_evidence,
        unit_count,
        total_loaded,
        questions_outside_catalog,
    );
    let bytes = serde_json::to_vec_pretty(&report).map_err(|e| MCPError {
        description: format!("report serialization failed: {e}"),
    })?;
    std::fs::write(&config.out_path, bytes).map_err(|e| MCPError {
        description: format!("could not write report to {}: {e}", config.out_path.display()),
    })?;

    let hits = outcomes.iter().filter(|o| o.hit_at_k).count();
    let n = outcomes.len() as f64;
    eprintln!(
        "[artifact-recall] hit@{}={:.4} mrr={:.4} → {}",
        config.top_k,
        hits as f64 / n,
        outcomes.iter().map(|o| o.reciprocal_rank).sum::<f64>() / n,
        config.out_path.display()
    );
    Ok(())
}

/// Builds the report JSON value. Twin of Swift `artifactRecallReport`.
/// `questions_in_file` is the total row count of questions.jsonl (before the
/// no_evidence split or any catalog/limit filtering) — "how many questions
/// the file held". `questions_outside_catalog` is how many scored questions
/// named a unit stem the catalog does not carry (unit scale with a bounded
/// fleet build only; 0 at every other scale). `n_questions` remains the
/// count actually measured (== `outcomes.len()`); `questions_measured` is
/// the same value under the name the bounded-catalog contract names it by.
fn artifact_recall_report(
    config: &ArtifactRecallConfig,
    outcomes: &[ArtifactQuestionOutcome],
    no_evidence: usize,
    unit_count: usize,
    questions_in_file: usize,
    questions_outside_catalog: usize,
) -> serde_json::Value {
    use serde_json::json;
    let n = outcomes.len() as f64;
    let hit_at_k = outcomes.iter().filter(|o| o.hit_at_k).count() as f64 / n;
    let mrr = outcomes.iter().map(|o| o.reciprocal_rank).sum::<f64>() / n;

    // Per-label breakdown (locomo category, convomem set, membench
    // family/category, lme-s question_type).
    let mut by_label: BTreeMap<String, Vec<&ArtifactQuestionOutcome>> = BTreeMap::new();
    for o in outcomes {
        by_label.entry(o.question.label.clone()).or_default().push(o);
    }
    let per_category: serde_json::Map<String, serde_json::Value> = by_label
        .into_iter()
        .map(|(label, group)| {
            let gn = group.len() as f64;
            (
                label,
                json!({
                    "n": group.len(),
                    "hit_at_k": group.iter().filter(|o| o.hit_at_k).count() as f64 / gn,
                    "mrr": group.iter().map(|o| o.reciprocal_rank).sum::<f64>() / gn,
                }),
            )
        })
        .collect();

    // Misses capped at 50 (file order) so a bad run stays inspectable without
    // the report ballooning to corpus size.
    let misses: Vec<serde_json::Value> = outcomes
        .iter()
        .filter(|o| !o.hit_at_k)
        .take(50)
        .map(|o| {
            json!({
                "sample_id": o.question.sample_id,
                "question": o.question.question,
                "expected": o.question.answer_session_ids,
                "got_top3": o.ranked_seed_ids.iter().take(3).collect::<Vec<_>>(),
            })
        })
        .collect();

    json!({
        "config": {
            "dataset": config.dataset.as_str(),
            "target_scale": config.target_scale.as_str(),
            "chest_diversity": config.chest_diversity.clone().unwrap_or_default(),
            "estate_dir": config.estate_dir.as_ref()
                .map(|p| p.display().to_string()).unwrap_or_default(),
            "catalog_path": config.catalog_path.as_ref()
                .map(|p| p.display().to_string()).unwrap_or_default(),
            "questions": config.questions_path.display().to_string(),
            "scope": config.scope.as_str(),
            "id_prefix": config.id_prefix,
            "limit": config.limit,
            "top_k": config.top_k,
            "binary": config.moot_binary,
        },
        "n_questions": outcomes.len(),
        "n_units": unit_count,
        "no_evidence": no_evidence,
        "questions_in_file": questions_in_file,
        "questions_measured": outcomes.len(),
        "questions_outside_catalog": questions_outside_catalog,
        "hit_at_k": hit_at_k,
        "mrr": mrr,
        "per_category": per_category,
        "misses": misses,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Twin of Swift `idMapLoadsAndReverses`: a valid flat object loads.
    #[test]
    fn id_map_loads() {
        let dir = std::env::temp_dir().join(format!(
            "ar-idmap-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("id-map.json"),
            r#"{"conv-26/S1":"AAAA-1111","conv-26/S2":"BBBB-2222"}"#).unwrap();
        let map = load_artifact_id_map(&dir).unwrap();
        assert_eq!(map.get("conv-26/S1").map(String::as_str), Some("AAAA-1111"));
        assert_eq!(map.len(), 2);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// Twin of Swift `idMapMissingErrorsClearly`: absence is a hard error
    /// naming the expected path.
    #[test]
    fn id_map_missing_errors_clearly() {
        let dir = std::env::temp_dir().join(format!(
            "ar-idmap-missing-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let err = load_artifact_id_map(&dir).unwrap_err();
        assert!(err.description.contains("id-map.json"));
        assert!(err.description.contains(dir.to_str().unwrap()));
        std::fs::remove_dir_all(&dir).ok();
    }

    /// LITERAL twin of the Swift `scoringMath` test in
    /// ArtifactRecallTests.swift — same vectors, same expected values, both
    /// ports (dual-port conformance).
    #[test]
    fn scoring_math_parity() {
        let ids = |v: &[&str]| -> Vec<String> { v.iter().map(|s| s.to_string()).collect() };

        // Vector 1: expected id at rank 1 → hit, RR 1.0.
        let s1 = score_artifact_question(
            &ids(&["conv-26/S1", "conv-26/S2", "conv-26/S3"]),
            &ids(&["conv-26/S1"]),
            3,
        );
        assert_eq!(s1, (true, 1.0));

        // Vector 2: expected id at rank 3 → hit@3, RR 1/3.
        let s2 = score_artifact_question(
            &ids(&["conv-26/S9", "conv-26/S8", "conv-26/S2"]),
            &ids(&["conv-26/S2", "conv-26/S4"]),
            3,
        );
        assert!(s2.0);
        assert!((s2.1 - 1.0 / 3.0).abs() < 1e-12);

        // Vector 3: expected id at rank 4, k=3 → NO hit@3, but RR still 1/4
        // (MRR over the full list, hit@k over the top k).
        let s3 = score_artifact_question(
            &ids(&["a", "b", "c", "conv-26/S5"]),
            &ids(&["conv-26/S5"]),
            3,
        );
        assert!(!s3.0);
        assert!((s3.1 - 0.25).abs() < 1e-12);

        // Vector 4: no expected id anywhere → miss, RR 0.
        let s4 = score_artifact_question(&ids(&["a", "b"]), &ids(&["conv-26/S1"]), 3);
        assert_eq!(s4, (false, 0.0));
    }

    /// Twin of the Swift `rankedUUIDMappingDedupes` test: first rank wins for
    /// duplicate seed ids; unmapped UUIDs keep their rank slot.
    #[test]
    fn ranked_uuid_mapping_dedupes() {
        let mut reverse = HashMap::new();
        reverse.insert(
            "aaaaaaaa-0000-0000-0000-000000000001".to_string(),
            "conv-26/S1".to_string(),
        );
        reverse.insert(
            "aaaaaaaa-0000-0000-0000-000000000002".to_string(),
            "conv-26/S2".to_string(),
        );
        let ranked = artifact_map_ranked_uuids(
            &[
                "AAAAAAAA-0000-0000-0000-000000000001".to_string(),
                "BBBBBBBB-0000-0000-0000-000000000009".to_string(),
                "aaaaaaaa-0000-0000-0000-000000000001".to_string(),
                "AAAAAAAA-0000-0000-0000-000000000002".to_string(),
            ],
            &reverse,
        );
        assert_eq!(
            ranked,
            vec![
                "conv-26/S1".to_string(),
                "unmapped:bbbbbbbb-0000-0000-0000-000000000009".to_string(),
                "conv-26/S2".to_string(),
            ]
        );
    }

    /// Twin of the Swift `questionLoadingAndFiltering` test: question_3p
    /// fallback, non-string answers tolerated, no-evidence partitioning,
    /// limit semantics (0 = all).
    #[test]
    fn question_loading_and_filtering() {
        let jsonl = concat!(
            r#"{"sample_id": "conv-26", "wing": "Caroline & Melanie", "question": "When did Caroline go?", "answer": "7 May 2023", "category": 2, "evidence_dia_ids": ["D1:3"], "answer_session_ids": ["conv-26/S1"]}"#,
            "\n",
            r#"{"sample_id": "conv-26", "wing": "Caroline & Melanie", "question": "", "question_3p": "What did Melanie paint?", "answer": 2022, "category": 2, "evidence_dia_ids": ["D1:12"], "answer_session_ids": ["conv-26/S2"]}"#,
            "\n",
            r#"{"sample_id": "conv-26", "wing": "Caroline & Melanie", "question": "Adversarial: unanswerable", "answer": "n/a", "category": 5, "evidence_dia_ids": [], "answer_session_ids": []}"#,
        );
        let all = load_artifact_recall_questions(jsonl, ArtifactDataset::Locomo).expect("load");
        assert_eq!(all.len(), 3);
        assert_eq!(all[1].question, "What did Melanie paint?");
        assert_eq!(all[0].label, "2");
        // LoCoMo unit stem = sample_id (units/<sample_id>.json).
        assert_eq!(all[0].unit_stem, "conv-26");

        let (scored, no_evidence) = partition_artifact_questions(all);
        assert_eq!(scored.len(), 2);
        assert_eq!(no_evidence, 1);

        assert_eq!(apply_artifact_limit(scored.clone(), 1).len(), 1);
        assert_eq!(apply_artifact_limit(scored, 0).len(), 2);
    }

    /// Per-dataset question adapters (#94). One literal row per dataset,
    /// mirrored verbatim in the Swift twin (convomemAdapter /
    /// membenchAdapter / lmeSAdapter in ArtifactRecallTests.swift).
    #[test]
    fn question_adapter_parity() {
        // convomem: 3p text wins; unit stem from set + query_id scene.
        let q = load_artifact_recall_questions(
            r#"{"set": "user_evidence", "query_id": "scene_0_q_0", "persona": "Alex Calder", "wing": "Alex Calder", "question": "What furniture?", "question_3p": "Alex asks what furniture?", "answer_session_ids": ["user_evidence/scene_0_session_1"], "candidate_session_ids": ["user_evidence/scene_0_session_1"]}"#,
            ArtifactDataset::Convomem,
        )
        .expect("convomem")[0]
            .clone();
        assert_eq!(q.question, "Alex asks what furniture?");
        assert_eq!(q.sample_id, "user_evidence/scene_0_q_0");
        assert_eq!(q.unit_stem, "user_evidence__scene_0");
        assert_eq!(q.wing, "Alex Calder");
        assert_eq!(q.label, "user_evidence");
        assert_eq!(q.answer_session_ids, vec!["user_evidence/scene_0_session_1"]);

        // membench: drawer-level ground truth (Rule-2 topical drawers).
        let q = load_artifact_recall_questions(
            r#"{"family": "FirstAgent", "category": "aggregative", "section": "roles", "tid": "0", "persona": "Alex Calder", "wing": "Alex Calder", "question": "How many people?", "question_3p": "How many people?", "answer": "2 people", "choices": {"A": "2 people"}, "answer_drawer_ids": ["FirstAgent/aggregative/roles/0/brother-0"]}"#,
            ArtifactDataset::Membench,
        )
        .expect("membench")[0]
            .clone();
        assert_eq!(q.sample_id, "FirstAgent/aggregative/roles/0");
        assert_eq!(q.unit_stem, "FirstAgent__aggregative__roles__0");
        assert_eq!(q.wing, "Alex Calder");
        assert_eq!(q.label, "FirstAgent/aggregative");
        assert_eq!(
            q.answer_session_ids,
            vec!["FirstAgent/aggregative/roles/0/brother-0"]
        );

        // lme-s: no instance wings — always unscoped (two-form ruling).
        let q = load_artifact_recall_questions(
            r#"{"question_id": "q-123", "question_type": "multi-session", "persona": "Priya Calder", "question": "Where did I go?", "question_3p": "Where did Priya go?", "question_date": "2023-05-30", "answer": "Paris", "answer_session_ids": ["s-9"]}"#,
            ArtifactDataset::LmeS,
        )
        .expect("lme-s")[0]
            .clone();
        assert_eq!(q.sample_id, "q-123");
        assert_eq!(q.unit_stem, "q-123");
        assert!(q.wing.is_empty());
        assert_eq!(q.question, "Where did Priya go?");
        assert_eq!(q.label, "multi-session");

        // Missing required fields fail loud, never skip silently.
        assert!(load_artifact_recall_questions(
            r#"{"wing": "Alex Calder", "question": "orphan row"}"#,
            ArtifactDataset::Convomem,
        )
        .is_err());
    }

    /// Literal twin of the Swift `unitStemValidation` test. A stem becomes
    /// one path component under its set directory and one token in the
    /// whitespace-split serve launch command; the seeders pin the same
    /// vectors.
    #[test]
    fn unit_stem_validation() {
        assert!(is_valid_unit_stem("conv-26"));
        assert!(is_valid_unit_stem("user_evidence__scene_0"));
        assert!(is_valid_unit_stem(&"a".repeat(128)));
        assert!(!is_valid_unit_stem("foo sh -c x"));
        assert!(!is_valid_unit_stem("../x"));
        assert!(!is_valid_unit_stem(".hidden"));
        assert!(!is_valid_unit_stem(""));
        assert!(!is_valid_unit_stem(&"a".repeat(129)));
        assert!(!is_valid_unit_stem("."));
        assert!(!is_valid_unit_stem(".."));
    }

    /// Twin of Swift `corpusIDWithWhitespaceFailsLoud`: a question id
    /// carrying launch-command tokens stops the run at load time, naming
    /// the id.
    #[test]
    fn corpus_id_with_whitespace_fails_loud() {
        let err = load_artifact_recall_questions(
            r#"{"question_id": "foo sh -c x", "question_type": "single-session", "question": "Where?", "answer_session_ids": ["s-1"]}"#,
            ArtifactDataset::LmeS,
        )
        .expect_err("whitespace id must be rejected");
        assert!(err.description.contains("foo sh -c x"), "{}", err.description);
    }

    /// Twin of Swift `unitEstateDirStaysUnderSetDirectory`.
    #[test]
    fn unit_estate_dir_stays_under_set_directory() {
        let set = Path::new("/fleet/out-locomo/units");
        let dir = artifact_unit_estate_dir(set, "conv-26").expect("valid stem");
        assert_eq!(dir, PathBuf::from("/fleet/out-locomo/units/conv-26"));
        // Trailing slash on the set dir resolves to the same estate.
        let dir2 = artifact_unit_estate_dir(Path::new("/fleet/out-locomo/units/"), "conv-26")
            .expect("valid stem");
        assert_eq!(dir2, dir);
        // Defense in depth: the join site rejects what the loader rejects.
        assert!(artifact_unit_estate_dir(set, "../x").is_err());
        assert!(artifact_unit_estate_dir(set, "foo sh -c x").is_err());
    }

    /// A unit whose estate sits under the SECONDARY base (set row 2, different
    /// base from set row 1) resolves correctly and passes the containment guard.
    /// The guard measures containment against the unit's OWN set directory,
    /// so a set that failed over to another base folder is still contained.
    /// Measuring against one shared root instead would reject it.
    ///
    /// Three assertions:
    ///   1. A unit present only in the second set row resolves to
    ///      `<secondary-base>/<path>/<id>` and the containment guard passes.
    ///   2. A unit absent from every set row yields the "not in catalog" error
    ///      with the exact message contract.
    ///   3. The invalid stem `../x` is still refused before catalog lookup.
    #[test]
    fn unit_resolves_from_secondary_base() {
        let pid = std::process::id();
        let root = std::env::temp_dir().join(format!("catalog-secondary-{pid}"));

        // ── Build two-base fixture ────────────────────────────────────────────
        // Primary base: holds set 1 with "conv-primary".
        let base1 = root.join("base1");
        let set1_dir = base1.join("rust").join("locomo").join("estate_set1");
        let unit_primary = set1_dir.join("conv-primary");
        std::fs::create_dir_all(&unit_primary).unwrap();
        std::fs::write(unit_primary.join("estate.sqlite"), b"").unwrap();

        // Secondary base: holds set 2 with "conv-secondary".
        let base2 = root.join("base2");
        let set2_dir = base2.join("rust").join("locomo").join("estate_set2");
        let unit_secondary = set2_dir.join("conv-secondary");
        // Use the nested databases/default/estate.sqlite location for set 2.
        let nested_db_dir = unit_secondary.join("databases").join("default");
        std::fs::create_dir_all(&nested_db_dir).unwrap();
        std::fs::write(nested_db_dir.join("estate.sqlite"), b"").unwrap();

        // ── Write catalog.json ────────────────────────────────────────────────
        let catalog_json = serde_json::json!({
            "port": "rust",
            "dataset": "locomo",
            "written": "2026-01-01T00:00:00Z",
            "sets": [
                {
                    "name": "estate_set1",
                    "base": base1.to_str().unwrap(),
                    "path": "rust/locomo/estate_set1",
                    "estates": 1,
                    "state": "laid_out"
                },
                {
                    "name": "estate_set2",
                    "base": base2.to_str().unwrap(),
                    "path": "rust/locomo/estate_set2",
                    "estates": 1,
                    "state": "laid_out"
                }
            ]
        });
        let catalog_path = root.join("catalog.json");
        std::fs::write(&catalog_path,
            serde_json::to_vec_pretty(&catalog_json).unwrap()).unwrap();

        // ── Assertion 1: secondary-base unit resolves and passes the guard ────
        let resolved = resolve_unit_from_catalog(&catalog_path, "conv-secondary")
            .expect("unit in secondary set must resolve");
        assert_eq!(resolved, unit_secondary,
            "resolved path must be <secondary-base>/rust/locomo/estate_set2/conv-secondary");

        // ── Assertion 2: absent unit id yields the exact error message ────────
        let err = resolve_unit_from_catalog(&catalog_path, "conv-absent")
            .expect_err("absent id must error");
        assert_eq!(
            err.description,
            format!("unit 'conv-absent' is not in the catalog at {}", catalog_path.display()),
            "absent-unit error must match the exact contract"
        );

        // ── Assertion 3: invalid stem is refused before catalog lookup ─────────
        let stem_err = resolve_unit_from_catalog(&catalog_path, "../x")
            .expect_err("path-traversal stem must be refused");
        assert!(
            stem_err.description.contains("../x"),
            "stem rejection must name the offending stem; got: {}",
            stem_err.description
        );
        assert!(
            stem_err.description.contains("not a valid unit stem"),
            "stem rejection must use the standard message: {}",
            stem_err.description
        );

        std::fs::remove_dir_all(&root).ok();
    }

    /// A bounded fleet build (`make fleet-<ds> LIMIT=N` / `UNITS=...`) writes
    /// a catalog holding fewer units than the dataset's questions.jsonl has.
    /// `partition_questions_by_catalog` must keep every question whose unit
    /// the catalog carries, count the rest as "outside the catalog" rather
    /// than erroring, and preserve file order. A fixture catalog holds 2 of
    /// 3 units; the 3-question file must split 2 in / 1 outside. Twin of
    /// Swift `partitionQuestionsByCatalog` test.
    #[test]
    fn partition_questions_by_catalog_splits_absent_units() {
        let pid = std::process::id();
        let root = std::env::temp_dir().join(format!("catalog-bounded-{pid}"));
        let set_dir = root.join("estates");
        // Catalog holds ONLY unit-a and unit-b; unit-c is absent — the
        // bounded fleet build stopped before reaching it.
        for unit in ["unit-a", "unit-b"] {
            let unit_dir = set_dir.join(unit);
            std::fs::create_dir_all(&unit_dir).unwrap();
            std::fs::write(unit_dir.join("estate.sqlite"), b"").unwrap();
        }
        let catalog_json = serde_json::json!({
            "sets": [{"base": root.to_str().unwrap(), "path": "estates"}]
        });
        let catalog_path = root.join("catalog.json");
        std::fs::write(&catalog_path, serde_json::to_vec_pretty(&catalog_json).unwrap()).unwrap();

        let question = |id: &str| ArtifactRecallQuestion {
            sample_id: id.to_string(),
            unit_stem: id.to_string(),
            wing: String::new(),
            question: format!("about {id}"),
            label: "1".to_string(),
            answer_session_ids: vec![format!("{id}/S1")],
        };
        // File order: unit-a, unit-b (both built), unit-c (not built).
        let questions = vec![question("unit-a"), question("unit-b"), question("unit-c")];

        let (in_catalog, outside) =
            partition_questions_by_catalog(questions, &catalog_path).expect("resolves cleanly");
        assert_eq!(outside, 1, "unit-c has no built estate and must be counted outside");
        assert_eq!(
            in_catalog.iter().map(|q| q.unit_stem.as_str()).collect::<Vec<_>>(),
            vec!["unit-a", "unit-b"],
            "file order preserved; only catalog-backed units survive"
        );

        // A genuine defect — an invalid stem — must propagate rather than
        // being swallowed as "outside the catalog".
        let bad = vec![question("../x")];
        let err = partition_questions_by_catalog(bad, &catalog_path)
            .expect_err("an invalid stem is a real defect, not an absence");
        assert!(
            err.description.contains("not a valid unit stem"),
            "{}",
            err.description
        );

        std::fs::remove_dir_all(&root).ok();
    }

    // ── load_or_reconstruct_id_map (item 5) ───────────────────────────────────

    /// When id-map.json exists, load_or_reconstruct_id_map returns it verbatim.
    #[test]
    fn reconstruct_id_map_falls_through_to_json_when_present() {
        let dir = std::env::temp_dir().join(format!("recon_idmap_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let id_map = serde_json::json!({"seed-1": "uuid-aaa", "seed-2": "uuid-bbb"});
        std::fs::write(dir.join("id-map.json"), serde_json::to_string(&id_map).unwrap()).unwrap();

        let result = load_or_reconstruct_id_map(&dir, None).unwrap();
        assert_eq!(result.get("seed-1").map(|s| s.as_str()), Some("uuid-aaa"));
        assert_eq!(result.get("seed-2").map(|s| s.as_str()), Some("uuid-bbb"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// When id-map.json is absent and no estate.sqlite exists, returns Err.
    #[test]
    fn reconstruct_id_map_no_sqlite_returns_err() {
        let dir = std::env::temp_dir().join(format!("recon_nosqlite_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let err = load_or_reconstruct_id_map(&dir, None).unwrap_err();
        assert!(
            err.description.contains("no estate.sqlite found"),
            "unexpected: {}",
            err.description
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── fnv1a128_lineage_id (item 6) ──────────────────────────────────────────

    /// Verified vector from the mission spec.
    /// "ThirdAgent/noisy/places/331/lives-here" → "6DBBCF02-F3DE-3DA9-F66D-AB95699D4ABE"
    #[test]
    fn fnv1a128_verified_vector() {
        let result = fnv1a128_lineage_id("ThirdAgent/noisy/places/331/lives-here");
        assert_eq!(result, "6DBBCF02-F3DE-3DA9-F66D-AB95699D4ABE");
    }

    /// Empty-string vector: result equals the offset basis packed as a UUID.
    /// high = 0x6c62272e07bb0142, low = 0x62b821756295c58d
    #[test]
    fn fnv1a128_empty_string() {
        let result = fnv1a128_lineage_id("");
        assert_eq!(result, "6C62272E-07BB-0142-62B8-217562 95C58D".replace(' ', ""));
    }

    /// Lineage derivation produces the exact seed-id → drawer-UUID map when
    /// the estate has drawers whose lineageID matches FNV-1a-128 of the seed
    /// record id.
    #[test]
    fn lineage_derivation_produces_exact_map() {
        let pid = std::process::id();
        let estate_dir = std::env::temp_dir().join(format!("lineage_estate_{pid}"));
        let seed_dir = std::env::temp_dir().join(format!("lineage_seeds_{pid}"));
        std::fs::create_dir_all(&estate_dir).unwrap();
        std::fs::create_dir_all(&seed_dir).unwrap();

        // Build the estate SQLite with two drawers whose lineageID = FNV(seed_id).
        // Uses estate_encryption::open_raw (unkeyed) since rusqlite is not a direct dep.
        let db_path = estate_dir.join("estate.sqlite");
        let seed_id_a = "AgentAlpha/doc/42";
        let seed_id_b = "AgentBeta/doc/99";
        let lineage_a = fnv1a128_lineage_id(seed_id_a);
        let lineage_b = fnv1a128_lineage_id(seed_id_b);
        let drawer_uuid_a = "AAAAAAAA-0000-0000-0000-000000000001";
        let drawer_uuid_b = "BBBBBBBB-0000-0000-0000-000000000002";
        {
            let conn = estate_encryption::open_raw(&db_path, None).unwrap();
            estate_encryption::exec(&conn,
                "CREATE TABLE drawers (id TEXT NOT NULL, lineageID TEXT, tombstonedAt TEXT);",
                "create drawers").unwrap();
            estate_encryption::exec(&conn,
                &format!("INSERT INTO drawers (id, lineageID, tombstonedAt) VALUES ('{drawer_uuid_a}', '{lineage_a}', NULL);"),
                "insert a").unwrap();
            estate_encryption::exec(&conn,
                &format!("INSERT INTO drawers (id, lineageID, tombstonedAt) VALUES ('{drawer_uuid_b}', '{lineage_b}', NULL);"),
                "insert b").unwrap();
        }

        // Write seed-units JSON for this estate (estate dir name = estate name).
        let estate_name = estate_dir.file_name().unwrap().to_str().unwrap();
        let seed_json = serde_json::json!({
            "format_version": 1,
            "name": estate_name,
            "records": [
                {"id": seed_id_a, "content": "alpha content"},
                {"id": seed_id_b, "content": "beta content"},
            ]
        });
        std::fs::write(
            seed_dir.join(format!("{estate_name}.json")),
            serde_json::to_string(&seed_json).unwrap(),
        )
        .unwrap();

        let map = load_or_reconstruct_id_map(&estate_dir, Some(&seed_dir)).unwrap();
        assert_eq!(map.get(seed_id_a).map(|s| s.as_str()), Some(drawer_uuid_a));
        assert_eq!(map.get(seed_id_b).map(|s| s.as_str()), Some(drawer_uuid_b));

        let _ = std::fs::remove_dir_all(&estate_dir);
        let _ = std::fs::remove_dir_all(&seed_dir);
    }

    /// With no estate.sqlite at all the lookup stops at the database step
    /// and says so.
    #[test]
    fn missing_estate_database_is_named() {
        let dir = std::env::temp_dir().join(format!("lineage_nodb_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let err = load_or_reconstruct_id_map(&dir, None).unwrap_err();
        assert!(
            err.description.contains("no estate.sqlite found"),
            "unexpected: {}",
            err.description
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// When id-map.json is absent, the drawers table carries no
    /// sourceFile/chunkIndex rows and no seed-units-dir is given, the refusal
    /// names the estate and all three sources that were tried. Twin of the
    /// Swift `lineageDerivationRefusalNamingAllSources`.
    #[test]
    fn lineage_derivation_refusal_names_all_sources() {
        let estate_dir =
            std::env::temp_dir().join(format!("lineage_refusal_{}", std::process::id()));
        std::fs::create_dir_all(&estate_dir).unwrap();
        let db_path = estate_dir.join("estate.sqlite");
        {
            // Uses estate_encryption::open_raw (unkeyed) since rusqlite is not a direct dep.
            let conn = estate_encryption::open_raw(&db_path, None).unwrap();
            conn.execute_batch(
                "CREATE TABLE drawers (id TEXT NOT NULL, lineageID TEXT, sourceFile TEXT, chunkIndex INTEGER, tombstonedAt TEXT);",
            )
            .unwrap();
        }
        let err = load_or_reconstruct_id_map(&estate_dir, None).unwrap_err();
        let estate_name = estate_dir.file_name().unwrap().to_str().unwrap();
        for needle in [estate_name, "id-map.json", "sourceFile/chunkIndex", "lineageID derivation", "seed-units-dir not provided"] {
            assert!(
                err.description.contains(needle),
                "refusal text lacks {needle:?}: {}",
                err.description
            );
        }
        let _ = std::fs::remove_dir_all(&estate_dir);
    }

    /// When id-map.json exists, load_or_reconstruct_id_map returns it and
    /// ignores seed-units-dir entirely.
    #[test]
    fn id_map_json_wins_over_lineage() {
        let dir = std::env::temp_dir().join(format!("idmap_wins_{}", std::process::id()));
        let seed_dir =
            std::env::temp_dir().join(format!("idmap_wins_seeds_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::create_dir_all(&seed_dir).unwrap();
        let id_map = serde_json::json!({"canonical-seed": "canonical-uuid"});
        std::fs::write(dir.join("id-map.json"), serde_json::to_string(&id_map).unwrap()).unwrap();

        let result = load_or_reconstruct_id_map(&dir, Some(&seed_dir)).unwrap();
        assert_eq!(
            result.get("canonical-seed").map(|s| s.as_str()),
            Some("canonical-uuid")
        );
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&seed_dir);
    }

    // ── estate_database_path gate tests (Task 1) ──────────────────────────────
    //
    // Twin of Swift ArtifactDatabaseProbeTests. Three cases:
    //   estate_probe_root_layout    — estate.sqlite at root resolves
    //   estate_probe_nested_layout  — databases/default/estate.sqlite resolves
    //   estate_probe_absent         — neither exists → None (refusal gate)

    /// Swift-built artifacts keep estate.sqlite at the root.
    #[test]
    fn estate_probe_root_layout() {
        let dir = std::env::temp_dir()
            .join(format!("probe_root_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("estate.sqlite"), b"").unwrap();

        let result = crate::estate_cache::estate_database_path(&dir);
        assert!(result.is_some(), "root-layout estate.sqlite must resolve");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Rust-built artifacts keep estate.sqlite at databases/default/estate.sqlite.
    /// This is the discriminating case that validates the refactored helper.
    #[test]
    fn estate_probe_nested_layout() {
        let dir = std::env::temp_dir()
            .join(format!("probe_nested_{}", std::process::id()));
        let nested = dir.join("databases").join("default");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::write(nested.join("estate.sqlite"), b"").unwrap();

        let result = crate::estate_cache::estate_database_path(&dir);
        assert!(result.is_some(), "nested-layout estate.sqlite must resolve");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// When neither layout exists the helper returns None.
    /// This tests the helper in isolation; the call-site gate
    /// (ask_artifact_questions_estate_probe_refusal) verifies the error
    /// message ask_artifact_questions builds from this None.
    #[test]
    fn estate_probe_absent() {
        let dir = std::env::temp_dir()
            .join(format!("probe_absent_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();

        let result = crate::estate_cache::estate_database_path(&dir);
        assert!(result.is_none(), "absent estate.sqlite (both layouts) must return None");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── Call-site gate ─────────────────────────────────────────────────────
    // Gates the fail-fast guard at ask_artifact_questions rather than just
    // estate_database_path. The guard fires before serve launches, so no
    // binary is needed.
    //
    // What makes this go red: removing the guard
    //   if crate::estate_cache::estate_database_path(estate_dir).is_none() { return Err(...) }
    // causes the call to proceed to load_artifact_id_map, whose own error does
    // NOT contain "no estate.sqlite in", so the assert on the message fails.

    #[test]
    fn ask_artifact_questions_estate_probe_refusal() {
        let dir = std::env::temp_dir()
            .join(format!("ask_probe_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // No estate.sqlite anywhere under dir — both root and nested layouts absent.
        let config = ArtifactRecallConfig {
            dataset: ArtifactDataset::Locomo,
            target_scale: ArtifactTargetScale::BenchAggregate,
            estate_dir: None,
            catalog_path: None,
            questions_path: dir.join("questions.jsonl"),
            scope: ArtifactRecallScope::Estate,
            id_prefix: String::new(),
            limit: 0,
            top_k: 5,
            out_path: dir.join("report.json"),
            moot_binary: String::from("/dev/null"),
        };
        let result = super::ask_artifact_questions(&dir, vec![], &config);
        let _ = std::fs::remove_dir_all(&dir);
        match result {
            Err(e) => {
                assert!(
                    e.description.contains("no estate.sqlite in"),
                    "message must contain 'no estate.sqlite in' — got: {}",
                    e.description
                );
                assert!(
                    e.description.contains(&dir.display().to_string())
                        || e.description.contains(dir.to_str().unwrap_or("")),
                    "message must contain the estate directory path — got: {}",
                    e.description
                );
            }
            Ok(_) => panic!("expected MCPError for missing estate.sqlite; got Ok"),
        }
    }
}
