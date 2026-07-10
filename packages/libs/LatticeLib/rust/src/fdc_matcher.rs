// fdc_matcher.rs — FDC runtime encoder Steps 4–5
//
// Port of FDCMatcher.swift.
//
// Step 4 (§5.2/§5.3): score[code] += bag[term] for every term shared with the
//                      code's signature (inverted-index single-pass scan).
//                      Empty score -> UNRESOLVED.
// Step 5 (§6):        start at argmax(score) (ties -> lowest code), then walk
//                      down children while a child's bag overlap meets
//                      stop_threshold; return the deepest such code.
//
// `encode` is a pure function of the input text and the pinned artifacts —
// the agreement property.
//
// PERFORMANCE — String→Int term interning (#31 Phase 2):
// The codebook (sig_terms / index / idf) is loaded once at init from the pinned
// FDCSignatures artifact and never mutated. Every term is assigned a dense usize
// id at init (ascending String order → Int-sort == String-sort, preserving all
// deterministic sort operations). The per-call hot path (encode_from_bag →
// score / raw_overlap) then operates on Int-keyed structures, eliminating the
// per-lookup String hash / HashMap find that dominated profiler samples on a
// 49k-drawer palace import. Mirrors Swift FDCMatcher.swift.
//
// SCORING MODES
// FDCMatcher supports four ScoreMode variants (mirrors Swift FDCMatcher.ScoreMode):
//   Raw:       Σ_{t∈O} bag[t]                     (direct-init default)
//   Idf:       Σ_{t∈O} bag[t] · idf(t)            (shipped runtime mode via FdcRuntime)
//   Cosine:    (Σ_{t∈O} bag[t]) / sqrt(|sig|)
//   IdfCosine: (Σ_{t∈O} bag[t] · idf(t)) / sqrt(Σ_{t∈sig} idf(t)²)
// where idf(t) = ln(N / df(t)), N = total code signatures, df(t) = # signatures
// containing t. The bag-side norm is dropped (constant across codes for a fixed
// query; cannot change any argmax). Per-signature norms are precomputed at init.
//
// DETERMINISM GUARANTEES
// - argmax tie-break: highest score wins; ties broken by lowest code
//   lexicographically. Same rule as Swift.
// - frame descent tie-break: highest mode score wins; ties broken by lowest
//   code lexicographically. Same rule as Swift.
// - Sorted summation: floating-point addition is non-associative. IDs are
//   assigned in ascending String order so sorting by TermID produces the same
//   sequence as sorting by String — all f64 sums that were previously computed
//   over sorted-String term slices are now computed over sorted-usize id slices,
//   with identical results. Mirrors Swift's init and score() sorted-term logic.
// - The descent cutoff (stop_threshold) is compared against the RAW integer
//   overlap, not the normalized score — mode-independent, as in Swift.
// - No HashMap iteration order dependencies: ties are resolved by explicit
//   comparison, not by iteration order.

use crate::concept_bag::{build_encoder_bag, ConceptBag};
use crate::fdc_frame::FdcFrame;
use crate::fdc_semantic_ranker::FdcSemanticRanker;
use crate::fdc_signatures::FdcSignatures;
use crate::lexicon::CanonicalizationLexicon;
use std::collections::HashMap;
use std::sync::Arc;

/// Scoring mode applied to both the Step-4 argmax and the Step-5 descent
/// ranking. Mirrors `FDCMatcher.ScoreMode` in Swift exactly.
///
/// The descent cutoff (`stop_threshold`) is always compared against the RAW
/// integer overlap regardless of mode — only the ranking of candidates that
/// clear the cutoff uses `score()`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ScoreMode {
    /// Σ bag[t] over the overlap. Integral, order-independent, reproduces the
    /// original ship behavior.
    Raw,
    /// Σ bag[t]·idf(t) over the overlap. IDF-weighted: distinctive terms
    /// (few signatures) contribute more than common terms.
    Idf,
    /// (Σ bag[t]) / sqrt(|sig|). Penalizes big signatures.
    Cosine,
    /// (Σ bag[t]·idf(t)) / sqrt(Σ_{t∈sig} idf(t)²). Combined IDF + signature
    /// L2 normalization.
    IdfCosine,
}

/// Maximum number of codes that may share the argmax score while still yielding
/// a classifiable result. When more codes than this are tied at the top IDF
/// score, the query bag is dominated by common cross-domain vocabulary (low-IDF
/// terms present in almost every signature) rather than subject-specific
/// vocabulary. The tie-break (lowest code lexicographically) then selects an
/// arbitrary code, not a semantically grounded one — that is a
/// confidently-wrong specific code, which is worse than the honest
/// "unclassified" sentinel "000".
///
/// Calibration (v1.0 frame, 1 071 code signatures):
///   • subject-specific text (e.g. "biology / physiology"): ≤ 2 codes tied at
///     the top IDF score — the winning code is in the correct domain.
///   • software/technical text (e.g. "wings ADR pipeline"): 10–13 codes tied
///     — the "winner" is an arbitrary code in an unrelated domain (235 =
///     angels/devotional, 621.2 = hydraulic engineering, etc.).
///
/// Setting the limit to 4 passes genuine subject-specific queries (≤ 2 ties
/// observed on the v1.0 frame) while correctly returning UNRESOLVED for
/// technical/generic text that would otherwise get a confidently-wrong code.
/// Mirrors Swift `FDCMatcher.maximumTiedWinnersForClassification`.
pub const MAX_TIED_WINNERS_FOR_CLASSIFICATION: usize = 4;

/// Minimum summed IDF from trusted code-owned sources required to certify a
/// displayable heading. Mirrors Swift `minimumTrustedEvidenceScore`.
const MINIMUM_TRUSTED_EVIDENCE_SCORE: f64 = 2.5;
const MINIMUM_BRANCH_DOMINANCE_RATIO: f64 = 1.15;

const SHELL_COMMAND_STARTS: &[&str] = &[
    "awk",
    "bash",
    "cargo",
    "chmod",
    "cp",
    "git",
    "grep",
    "jq",
    "mkdir",
    "mv",
    "node",
    "npm",
    "python",
    "python3",
    "rg",
    "rm",
    "sed",
    "set",
    "sh",
    "sqlite3",
    "swift",
    "xcodebuild",
    "yarn",
];

const CODE_LIKE_SIGNALS: &[&str] = &[
    "```",
    "#!/",
    ".git/",
    "index.lock",
    "read_signal",
    " set -",
    "$(",
    "&&",
    "||",
    "==",
    "!=",
    "=>",
    "->",
    "{",
    "}",
    ";",
    "func ",
    "let ",
    "var ",
    "class ",
    "struct ",
    "enum ",
    "import ",
    "return ",
    "const ",
    "function ",
];

const SOURCE_DECLARATION_MODIFIERS: &[&str] = &[
    "fileprivate",
    "final",
    "internal",
    "open",
    "override",
    "private",
    "public",
    "static",
];

const SOURCE_DECLARATION_STARTS: &[&str] = &[
    "class ",
    "const ",
    "enum ",
    "extension ",
    "func ",
    "function ",
    "import ",
    "interface ",
    "let ",
    "protocol ",
    "struct ",
    "typealias ",
    "var ",
];

fn special_classification(text: &str) -> Option<&'static str> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lowered = trimmed.to_ascii_lowercase();

    if lowered.contains("```")
        || lowered.contains("#!/")
        || lowered.contains(".git/")
        || lowered.contains("index.lock")
        || lowered.contains("read_signal")
    {
        return Some("000");
    }

    let lines: Vec<&str> = trimmed
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    let mut command_line_count = 0usize;
    for line in &lines {
        let mut command_text = line.trim_start();
        while let Some(first) = command_text.chars().next() {
            if "$#>%".contains(first) || first.is_whitespace() {
                command_text = command_text[first.len_utf8()..].trim_start();
            } else {
                break;
            }
        }
        let first = command_text.split_whitespace().next().unwrap_or("");
        let command = first
            .trim_matches(|c: char| !c.is_ascii_alphanumeric())
            .to_ascii_lowercase();
        if SHELL_COMMAND_STARTS.contains(&command.as_str()) {
            command_line_count += 1;
        }
    }
    if command_line_count >= 2 || (command_line_count == 1 && lines.len() <= 6) {
        return Some("000");
    }

    let declaration_line_count = lines
        .iter()
        .filter(|line| {
            let lowered_line = line.to_ascii_lowercase();
            let mut words = lowered_line.split_whitespace().peekable();
            while words.peek().is_some_and(|word| {
                let modifier = word.trim_matches(|c: char| !c.is_ascii_alphanumeric());
                SOURCE_DECLARATION_MODIFIERS.contains(&modifier)
            }) {
                words.next();
            }
            let body = words.collect::<Vec<_>>().join(" ");
            if !SOURCE_DECLARATION_STARTS
                .iter()
                .any(|prefix| body.starts_with(prefix))
            {
                return false;
            }
            let declarator_needs_syntax = body.starts_with("let ")
                || body.starts_with("var ")
                || body.starts_with("const ");
            let function_needs_syntax =
                body.starts_with("func ") || body.starts_with("function ");
            (!declarator_needs_syntax || line.contains(':') || line.contains('='))
                && (!function_needs_syntax || line.contains('('))
        })
        .count();
    if declaration_line_count >= 2 {
        return Some("005");
    }

    let signal_count = CODE_LIKE_SIGNALS
        .iter()
        .filter(|signal| lowered.contains(**signal))
        .count();
    if signal_count >= 3 {
        return Some("000");
    }

    let non_whitespace_count = trimmed.chars().filter(|c| !c.is_whitespace()).count();
    if non_whitespace_count == 0 {
        return None;
    }
    let symbol_count = trimmed
        .chars()
        .filter(|c| "{}[]();=$|/\\<>".contains(*c))
        .count();
    let code_like = lines.len() >= 2
        && signal_count >= 2
        && (symbol_count as f64 / non_whitespace_count as f64) > 0.08;
    code_like.then_some("000")
}

/// An intern-keyed bag: TermID → count. Used internally for all scoring
/// operations. Built from a ConceptBag in `encode_from_bag` by looking up
/// each term's dense integer id. Terms absent from the codebook have no id
/// and are silently dropped (they cannot match any signature).
type InternedBag = HashMap<usize, usize>;

struct SourceTermIds {
    label: Vec<usize>,
    alias: Vec<usize>,
    title: Vec<usize>,
    article: Vec<usize>,
}

#[derive(Clone)]
struct OwnedEvidence {
    code: String,
    score: f64,
    distinct_terms: usize,
    trusted_terms: usize,
    source_count: usize,
}

pub struct FdcMatcher {
    /// Pinned descent cutoff (cookbook §6.1). v1.0 default is 1.
    pub stop_threshold: usize,
    /// Active scoring mode. Default is Raw (reproduces original ship behavior).
    pub score_mode: ScoreMode,
    /// When true, production classification ranks source-owned evidence and
    /// returns the deepest supported common ancestor instead of allowing
    /// inherited/article recall terms to certify a narrow code. Mirrors Swift
    /// `useHierarchicalResolution`.
    pub use_hierarchical_resolution: bool,
    semantic_ranker: Option<Arc<FdcSemanticRanker>>,
    lexicon: CanonicalizationLexicon,
    frame: FdcFrame,

    // MARK: — Interning table (#31 Phase 2)
    //
    // Terms are interned to dense usize ids once at init so encode_from_bag
    // runs Int-keyed lookups instead of String-keyed ones. IDs are assigned in
    // ascending String order → usize-sort == String-sort.
    /// term → dense usize id. IDs are 0-based, contiguous, assigned in
    /// ascending String order. Mirrors Swift `termToID`.
    term_to_id: HashMap<String, usize>,

    // MARK: — Int-keyed internal structures (hot path)
    /// code → sorted Vec<TermID>. Replaces the old HashMap<String, HashSet<String>>.
    /// The Vec is sorted in ascending TermID order (== ascending String order)
    /// so iteration in TermID order == iteration in String order — required for
    /// deterministic floating-point sums. Mirrors Swift `sigTermIDs`.
    sig_term_ids: HashMap<String, Vec<usize>>,

    /// TermID → sorted Vec<String> codes (inverted index). Replaces the old
    /// HashMap<String, Vec<String>>. Key is a dense usize so lookup is a
    /// single integer hash. Mirrors Swift `indexByID`.
    index_by_id: Vec<Vec<String>>,

    /// TermID → idf value (dense Vec, indexed by TermID). Replaces the old
    /// HashMap<String, f64>. Indexed directly: `idf_by_id[id]`. Mirrors Swift
    /// `idfByID`.
    idf_by_id: Vec<f64>,

    // MARK: — Code-keyed norm tables (unchanged from pre-interning)
    /// code → sqrt(|sig|) — precomputed for ScoreMode::Cosine.
    sig_norm: HashMap<String, f64>,
    /// code → sqrt(Σ_{t∈sig} idf(t)²) — precomputed for ScoreMode::IdfCosine.
    /// Summed in SORTED TermID order (== sorted String order) to produce
    /// bit-identical results to the pre-interning init. Mirrors Swift `sigIDFNorm`.
    sig_idf_norm: HashMap<String, f64>,

    /// Code-owned source evidence from the source-separated artifact, excluding ancestors.
    source_term_ids: HashMap<String, SourceTermIds>,
    /// IDF computed across code-owned terms only.
    own_idf_by_id: Vec<f64>,
}

impl FdcMatcher {
    pub fn new(
        lexicon: CanonicalizationLexicon,
        frame: FdcFrame,
        signatures: &FdcSignatures,
        stop_threshold: usize,
    ) -> Self {
        Self::new_with_mode(lexicon, frame, signatures, stop_threshold, ScoreMode::Raw)
    }

    pub fn new_with_mode(
        lexicon: CanonicalizationLexicon,
        frame: FdcFrame,
        signatures: &FdcSignatures,
        stop_threshold: usize,
        score_mode: ScoreMode,
    ) -> Self {
        Self::new_with_mode_and_hierarchy(
            lexicon,
            frame,
            signatures,
            stop_threshold,
            score_mode,
            false,
        )
    }

    pub fn new_with_mode_and_hierarchy(
        lexicon: CanonicalizationLexicon,
        frame: FdcFrame,
        signatures: &FdcSignatures,
        stop_threshold: usize,
        score_mode: ScoreMode,
        use_hierarchical_resolution: bool,
    ) -> Self {
        Self::new_with_mode_hierarchy_and_semantic(
            lexicon,
            frame,
            signatures,
            stop_threshold,
            score_mode,
            use_hierarchical_resolution,
            None,
        )
    }

    pub fn new_with_mode_hierarchy_and_semantic(
        lexicon: CanonicalizationLexicon,
        frame: FdcFrame,
        signatures: &FdcSignatures,
        stop_threshold: usize,
        score_mode: ScoreMode,
        use_hierarchical_resolution: bool,
        semantic_ranker: Option<Arc<FdcSemanticRanker>>,
    ) -> Self {
        let sig_terms_orig = &signatures.sig_terms;

        // 1. Collect every unique term across all signatures, sort alphabetically
        //    (BTreeSet), assign dense usize ids. Ascending String order → usize
        //    sort == String sort. Mirrors Swift: `allTerms.sorted().enumerated()`.
        let mut all_terms_set: std::collections::BTreeSet<String> =
            std::collections::BTreeSet::new();
        for terms in sig_terms_orig.values() {
            for t in terms {
                all_terms_set.insert(t.clone());
            }
        }
        let term_count = all_terms_set.len();
        // BTreeSet is already sorted, so iteration gives ascending String order.
        let mut term_to_id: HashMap<String, usize> = HashMap::with_capacity(term_count);
        for (id, term) in all_terms_set.into_iter().enumerate() {
            term_to_id.insert(term, id);
        }

        // 2. Rebuild sig_term_ids: code → sorted Vec<TermID>.
        //    The Vec is sorted in ascending TermID order (== ascending String order)
        //    so `sig_term_ids[code].iter()` is already in the same order as
        //    `sig_terms[code].iter().sorted()` — no additional sort needed in
        //    score() overlap computation. Mirrors Swift `sigTermIDs`.
        let mut sig_term_ids: HashMap<String, Vec<usize>> =
            HashMap::with_capacity(sig_terms_orig.len());
        for (code, terms) in sig_terms_orig {
            let mut ids: Vec<usize> = terms
                .iter()
                .filter_map(|t| term_to_id.get(t.as_str()).copied())
                .collect();
            // Sort ascending — ascending TermID == ascending String order.
            ids.sort_unstable();
            sig_term_ids.insert(code.clone(), ids);
        }

        // 3. Build index_by_id: dense Vec<Vec<String>> indexed by TermID.
        //    Replaces the old HashMap<String, Vec<String>>. Direct integer
        //    indexing avoids hash computation on the hot inner loop.
        let mut index_by_id: Vec<Vec<String>> = vec![Vec::new(); term_count];
        for (code, ids) in &sig_term_ids {
            for &id in ids {
                index_by_id[id].push(code.clone());
            }
        }
        // Sort each code list for deterministic iteration order — same invariant
        // as the old `for codes in index.values_mut() { codes.sort(); }`.
        for codes in &mut index_by_id {
            codes.sort();
        }

        // 4. Compute IDF over the code signatures.
        //    df[id] = # signatures containing the term with that id.
        //    idf[id] = ln(N / df[id]). A term in every signature carries idf 0.
        //    Stored as a dense Vec<f64> indexed by TermID for O(1) access.
        let n = sig_terms_orig.len() as f64;
        let mut df: Vec<usize> = vec![0usize; term_count];
        for (code, _) in sig_terms_orig {
            // Use sig_term_ids (already built) to avoid iterating HashSet<String>.
            if let Some(ids) = sig_term_ids.get(code) {
                for &id in ids {
                    df[id] += 1;
                }
            }
        }
        let mut idf_by_id: Vec<f64> = vec![0.0f64; term_count];
        for id in 0..term_count {
            if df[id] > 0 {
                idf_by_id[id] = (n / df[id] as f64).ln();
            }
        }

        // 5. Per-signature norms (big-signature penalty).
        //    sig_norm[code]     = sqrt(|sig|)         for ScoreMode::Cosine
        //    sig_idf_norm[code] = sqrt(Σ idf(t)²)    for ScoreMode::IdfCosine
        //
        //    The IDF norm sum MUST be in SORTED TermID order (== sorted String
        //    order). sig_term_ids[code] is already sorted (step 2), so we iterate
        //    it directly — no additional sort. This produces bit-identical f64
        //    results to the pre-interning impl that did `terms.sorted()`.
        let mut sig_norm: HashMap<String, f64> = HashMap::with_capacity(sig_terms_orig.len());
        let mut sig_idf_norm: HashMap<String, f64> = HashMap::with_capacity(sig_terms_orig.len());
        for (code, ids) in &sig_term_ids {
            sig_norm.insert(
                code.clone(),
                if ids.is_empty() {
                    0.0
                } else {
                    (ids.len() as f64).sqrt()
                },
            );
            // ids is sorted → iterating gives ascending String order of terms,
            // identical to the pre-interning `sorted_terms` summation order.
            let mut ss = 0.0f64;
            for &id in ids {
                let w = idf_by_id[id];
                ss += w * w;
            }
            sig_idf_norm.insert(code.clone(), if ss > 0.0 { ss.sqrt() } else { 0.0 });
        }

        let mut source_term_ids: HashMap<String, SourceTermIds> =
            HashMap::with_capacity(signatures.source_terms.len());
        let mut own_df: Vec<usize> = vec![0; term_count];
        for (code, sources) in &signatures.source_terms {
            let encode = |terms: &std::collections::HashSet<String>| {
                let mut ids: Vec<usize> = terms
                    .iter()
                    .filter_map(|term| term_to_id.get(term.as_str()).copied())
                    .collect();
                ids.sort_unstable();
                ids.dedup();
                ids
            };
            let encoded = SourceTermIds {
                label: encode(&sources.label),
                alias: encode(&sources.alias),
                title: encode(&sources.title),
                article: encode(&sources.article),
            };
            let mut all: Vec<usize> = encoded
                .label
                .iter()
                .chain(encoded.alias.iter())
                .chain(encoded.title.iter())
                .chain(encoded.article.iter())
                .copied()
                .collect();
            all.sort_unstable();
            all.dedup();
            for id in all {
                own_df[id] += 1;
            }
            source_term_ids.insert(code.clone(), encoded);
        }
        let own_n = source_term_ids.len().max(1) as f64;
        let mut own_idf_by_id = vec![0.0f64; term_count];
        for (id, count) in own_df.into_iter().enumerate() {
            if count > 0 {
                own_idf_by_id[id] = (own_n / count as f64).ln();
            }
        }

        FdcMatcher {
            stop_threshold,
            score_mode,
            use_hierarchical_resolution,
            semantic_ranker,
            lexicon,
            frame,
            term_to_id,
            sig_term_ids,
            index_by_id,
            idf_by_id,
            sig_norm,
            sig_idf_norm,
            source_term_ids,
            own_idf_by_id,
        }
    }

    /// Score `code`'s overlap with the interned `bag` under the active
    /// `score_mode`. The numerator is summed over the overlap in sorted TermID
    /// order (== sorted String order by construction), producing bit-identical
    /// f64 results to the pre-interning impl. Returns 0.0 when there is no
    /// overlap. Mirrors Swift `FDCMatcher.score(code:bag:)`.
    fn score(&self, code: &str, bag: &InternedBag) -> f64 {
        let term_ids = match self.sig_term_ids.get(code) {
            Some(ids) => ids,
            None => return 0.0,
        };
        // term_ids is already sorted in ascending TermID order (== String order).
        // Filter by bag membership and collect — no additional sort needed.
        // This is the equivalent of the pre-interning `overlap.sort_unstable()`
        // over a Vec built from `terms.iter().filter(...)`.
        let overlap: Vec<usize> = term_ids
            .iter()
            .filter(|&&id| bag.contains_key(&id))
            .copied()
            .collect();
        // overlap is already sorted (term_ids is sorted, filter preserves order).

        let mut num = 0.0f64;
        match self.score_mode {
            ScoreMode::Raw | ScoreMode::Cosine => {
                // Raw numerator: Σ bag[t] over the overlap.
                for &id in &overlap {
                    num += *bag.get(&id).unwrap_or(&0) as f64;
                }
            }
            ScoreMode::Idf | ScoreMode::IdfCosine => {
                // IDF-weighted numerator: Σ bag[t]·idf(t) over the overlap.
                for &id in &overlap {
                    let n = *bag.get(&id).unwrap_or(&0) as f64;
                    // id is guaranteed to be in range (built from sig_term_ids
                    // which was built from term_to_id covering all sig terms).
                    let w = self.idf_by_id.get(id).copied().unwrap_or(0.0);
                    num += n * w;
                }
            }
        }
        match self.score_mode {
            ScoreMode::Raw | ScoreMode::Idf => num,
            ScoreMode::Cosine => {
                let d = self.sig_norm.get(code).copied().unwrap_or(0.0);
                if d > 0.0 {
                    num / d
                } else {
                    num
                }
            }
            ScoreMode::IdfCosine => {
                let d = self.sig_idf_norm.get(code).copied().unwrap_or(0.0);
                if d > 0.0 {
                    num / d
                } else {
                    num
                }
            }
        }
    }

    /// The RAW integer overlap Σ bag[t] over (bag ∩ sig), used for the
    /// mode-independent descent cutoff comparison (stop_threshold). Iterates
    /// the signature's TermID Vec and checks each in the interned bag — O(K)
    /// where K is signature size (typically 5–20). Mirrors Swift
    /// `FDCMatcher.rawOverlap(code:bag:)`.
    fn raw_overlap(&self, code: &str, bag: &InternedBag) -> usize {
        let term_ids = match self.sig_term_ids.get(code) {
            Some(ids) => ids,
            None => return 0,
        };
        let mut o = 0usize;
        for &id in term_ids {
            if let Some(&n) = bag.get(&id) {
                o += n;
            }
        }
        o
    }

    fn owned_evidence(&self, code: &str, bag: &InternedBag) -> OwnedEvidence {
        let Some(sources) = self.source_term_ids.get(code) else {
            return OwnedEvidence {
                code: code.to_owned(),
                score: 0.0,
                distinct_terms: 0,
                trusted_terms: 0,
                source_count: 0,
            };
        };
        let mut score = 0.0f64;
        let mut matched: std::collections::HashSet<usize> = std::collections::HashSet::new();
        let mut trusted: std::collections::HashSet<usize> = std::collections::HashSet::new();
        let mut source_count = 0usize;

        let mut add = |ids: &[usize], source_weight: f64, is_trusted: bool| -> bool {
            let mut found = false;
            for id in ids {
                if !bag.contains_key(id) {
                    continue;
                }
                let weight = self.own_idf_by_id.get(*id).copied().unwrap_or(0.0);
                if weight <= 0.0 {
                    continue;
                }
                score += source_weight * weight;
                matched.insert(*id);
                if is_trusted {
                    trusted.insert(*id);
                }
                found = true;
            }
            found
        };

        if add(&sources.label, 6.0, true) {
            source_count += 1;
        }
        if add(&sources.alias, 4.0, true) {
            source_count += 1;
        }
        if add(&sources.title, 3.0, true) {
            source_count += 1;
        }
        if add(&sources.article, 0.25, false) {
            source_count += 1;
        }
        OwnedEvidence {
            code: code.to_owned(),
            score,
            distinct_terms: matched.len(),
            trusted_terms: trusted.len(),
            source_count,
        }
    }

    fn is_main_class(code: &str) -> bool {
        let bytes = code.as_bytes();
        bytes.len() == 3
            && bytes.iter().all(u8::is_ascii_digit)
            && bytes[1] == b'0'
            && bytes[2] == b'0'
    }

    fn precision_is_supported(&self, evidence: &OwnedEvidence) -> bool {
        let depth = self.frame.ancestors(&evidence.code).len();
        if depth <= 2 {
            evidence.trusted_terms >= 1
                || evidence.distinct_terms >= 2
                || (Self::is_main_class(&evidence.code) && evidence.distinct_terms >= 1)
        } else {
            evidence.distinct_terms >= 2
                && evidence.trusted_terms >= 1
                && evidence.score >= MINIMUM_TRUSTED_EVIDENCE_SCORE
        }
    }

    fn broad_fallback(&self, code: &str) -> String {
        self.frame
            .ancestors(code)
            .into_iter()
            .rev()
            .find(|ancestor| Self::is_main_class(ancestor))
            .unwrap_or_else(|| "000".to_owned())
    }

    fn common_ancestor(&self, lhs: &str, rhs: &str) -> String {
        let mut left = self.frame.ancestors(lhs);
        left.push(lhs.to_owned());
        let mut right = self.frame.ancestors(rhs);
        right.push(rhs.to_owned());
        let mut common = "000".to_owned();
        for (a, b) in left.iter().zip(right.iter()) {
            if a != b {
                break;
            }
            common = a.clone();
        }
        common
    }

    fn fuse_semantic(
        &self,
        result: (Option<String>, Option<String>),
        text: &str,
        concept_bag: &ConceptBag,
    ) -> (Option<String>, Option<String>) {
        if !self.use_hierarchical_resolution {
            return result;
        }
        let Some(semantic_ranker) = &self.semantic_ranker else {
            return result;
        };
        let lexical_code = result.0.as_deref().unwrap_or("000");
        if lexical_code != "000" && self.has_reviewed_alias_evidence(lexical_code, concept_bag) {
            return result;
        }
        let candidates = semantic_ranker.rank(text, semantic_ranker.metadata.code_count);
        let Some(decision) =
            semantic_ranker.hierarchy_decision_from_candidates(&candidates, &self.frame)
        else {
            return result;
        };
        let lexical_main = if Self::is_main_class(lexical_code) {
            lexical_code.to_owned()
        } else {
            self.frame
                .ancestors(lexical_code)
                .into_iter()
                .rev()
                .find(|ancestor| Self::is_main_class(ancestor))
                .unwrap_or_else(|| "000".to_owned())
        };
        if lexical_code != "000" && lexical_main == decision.main_class {
            return result;
        }
        if lexical_code != "000" && self.has_reviewed_alias_evidence(lexical_code, concept_bag) {
            return result;
        }
        if lexical_code != "000" {
            if let (Some(top), Some(lexical_candidate)) = (
                candidates.first(),
                candidates
                    .iter()
                    .find(|candidate| candidate.code == lexical_code),
            ) {
                if lexical_candidate.score * 3 >= top.score * 2 {
                    return result;
                }
            }
        }
        (Some(decision.code), None)
    }

    fn has_reviewed_alias_evidence(&self, code: &str, bag: &ConceptBag) -> bool {
        let Some(sources) = self.source_term_ids.get(code) else {
            return false;
        };
        if sources.alias.is_empty() {
            return false;
        }
        bag.keys().any(|term| {
            self.term_to_id
                .get(term)
                .map(|id| sources.alias.contains(id))
                .unwrap_or(false)
        })
    }

    fn hierarchical_resolution(
        &self,
        candidates: &[String],
        bag: &InternedBag,
        concept_bag: &ConceptBag,
    ) -> (Option<String>, Option<String>) {
        let mut ranked: Vec<OwnedEvidence> = candidates
            .iter()
            .map(|code| self.owned_evidence(code, bag))
            .filter(|evidence| evidence.score > 0.0)
            .collect();
        ranked.sort_by(|a, b| {
            b.trusted_terms
                .cmp(&a.trusted_terms)
                .then_with(|| b.distinct_terms.cmp(&a.distinct_terms))
                .then_with(|| b.source_count.cmp(&a.source_count))
                .then_with(|| b.score.total_cmp(&a.score))
                .then_with(|| a.code.cmp(&b.code))
        });

        let Some(winner) = ranked.first() else {
            return (Some("000".to_owned()), None);
        };
        let mut chosen = if self.precision_is_supported(winner) {
            winner.code.clone()
        } else if winner.trusted_terms == 0 {
            "000".to_owned()
        } else {
            self.broad_fallback(&winner.code)
        };
        if let Some(runner_up) = ranked.get(1) {
            if winner.trusted_terms == runner_up.trusted_terms
                && winner.distinct_terms == runner_up.distinct_terms
                && winner.score < runner_up.score * MINIMUM_BRANCH_DOMINANCE_RATIO
            {
                chosen = self.common_ancestor(&winner.code, &runner_up.code);
            }
        }
        if chosen == "000" {
            return (Some(chosen), None);
        }
        let qid = self.dominant_qid(concept_bag, &chosen, bag);
        (Some(chosen), qid)
    }

    /// Encode `text` to an FDC code. Hierarchy mode returns `000` for nonempty
    /// unresolved text; legacy matcher instances retain the None behavior.
    pub fn encode(&self, text: &str) -> Option<String> {
        self.encode_anchor(text).0
    }

    /// Encode `text` and surface the dominant concept Q-ID.
    /// Returns (code, conceptQID).
    /// `code` is `000` for Generalities/unclassified in hierarchy mode.
    /// `conceptQID` is the highest-weighted Wikidata Q-ID in the bag, or None.
    pub fn encode_anchor(&self, text: &str) -> (Option<String>, Option<String>) {
        if text.trim().is_empty() {
            return (None, None);
        }
        if let Some(special_code) = special_classification(text) {
            return if self.use_hierarchical_resolution {
                (Some(special_code.to_owned()), None)
            } else {
                (None, None)
            };
        }
        // Read the LIVE process-global word-class table (cookbook §1.3/§2.2):
        // a post-reduce live swap is observed here in-session, exactly as the
        // Swift `BagBuilder.bag` path reads the live `LatticeLib.wordClass`
        // holder. The `Arc` is cloned once (brief read-lock) and the bag build
        // runs against the immutable snapshot — no torn read.
        let table = crate::word_class_table::global_table();
        let bag = build_encoder_bag(text, &self.lexicon, &table);
        let result = self.fuse_semantic(self.encode_from_bag(&bag), text, &bag);
        if self.use_hierarchical_resolution && result.0.is_none() {
            (Some("000".to_owned()), None)
        } else {
            result
        }
    }

    /// Non-recording variant of `encode_anchor` (secfix/fdc-pool).
    ///
    /// Identical FDC code and Q-ID result to `encode_anchor`. Novel tokens
    /// encountered while building the concept bag are NOT accumulated into
    /// `SHARED_NOVEL_CACHE`, so user-memory content classified here does not
    /// leak plaintext tokens to the pool pipeline.
    ///
    /// Called from `Fdc::encode_anchor_no_record` → `capture_with_mode` in
    /// GeniusLocusKit `intake.rs`. Mirrors Swift
    /// `FDCMatcher.encodeAnchor(_:recordNovel: false)`.
    pub fn encode_anchor_no_record(&self, text: &str) -> (Option<String>, Option<String>) {
        if text.trim().is_empty() {
            return (None, None);
        }
        if let Some(special_code) = special_classification(text) {
            return if self.use_hierarchical_resolution {
                (Some(special_code.to_owned()), None)
            } else {
                (None, None)
            };
        }
        let table = crate::word_class_table::global_table();
        // Non-recording bag build: SHARED_NOVEL_CACHE.record is not called for
        // novel tokens, so no user-memory content leaks to the pool pipeline.
        let bag = crate::concept_bag::build_encoder_bag_no_record(text, &self.lexicon, &table);
        let result = self.fuse_semantic(self.encode_from_bag(&bag), text, &bag);
        if self.use_hierarchical_resolution && result.0.is_none() {
            (Some("000".to_owned()), None)
        } else {
            result
        }
    }

    /// Score a pre-built concept bag against the FDC signatures (Steps 4–5)
    /// and return the best matching code + dominant Q-ID.
    ///
    /// Converts the String-keyed ConceptBag to an Int-keyed InternedBag once,
    /// then all scoring and overlap operations use Int-keyed lookups. Terms
    /// absent from the codebook (no TermID) are silently dropped from the
    /// interned bag — they cannot match any signature, identical to the
    /// pre-interning `index.get(term) == None` skip.
    ///
    /// Mirrors Swift `FDCMatcher.encodeFromBag(_:)`.
    fn encode_from_bag(&self, bag: &ConceptBag) -> (Option<String>, Option<String>) {
        if bag.is_empty() {
            return if self.use_hierarchical_resolution {
                (Some("000".to_owned()), None)
            } else {
                (None, None)
            };
        }

        // Convert the String-keyed ConceptBag to an Int-keyed InternedBag.
        // Terms absent from the codebook have no TermID and are silently
        // dropped — they match no signature entry, identical behaviour to the
        // pre-interning path (which skipped them via `index.get(term) == None`).
        let mut interned_bag: InternedBag = HashMap::with_capacity(bag.len());
        for (term, &count) in bag {
            if let Some(&id) = self.term_to_id.get(term.as_str()) {
                *interned_bag.entry(id).or_insert(0) += count;
            }
        }

        if interned_bag.is_empty() {
            return if self.use_hierarchical_resolution {
                (Some("000".to_owned()), None)
            } else {
                (None, None)
            };
        }

        // Step 4 — match + score (§5.2/§5.3). The Int-keyed inverted index
        // gives the set of candidate codes (any code sharing ≥1 bag term); each
        // candidate is then scored under the active mode. For Raw the score is
        // exactly Σ bag[t] (integers held in f64 — comparisons exact),
        // reproducing the original ship behavior.
        let mut candidate_set: std::collections::HashSet<String> = std::collections::HashSet::new();
        for (&term_id, _) in &interned_bag {
            // term_id is guaranteed in-range: it came from term_to_id which
            // was built over the same domain as index_by_id.
            if let Some(codes) = self.index_by_id.get(term_id) {
                for code in codes {
                    candidate_set.insert(code.clone());
                }
            }
        }

        if candidate_set.is_empty() {
            return if self.use_hierarchical_resolution {
                (Some("000".to_owned()), None)
            } else {
                (None, None)
            };
        }

        // Sorted so the scan order is deterministic regardless of HashSet
        // hashing. This matters for the normalized modes: two codes can carry
        // equal (or float-rounding-equal) scores, and the lowest-code tie-break
        // only holds if the scan visits codes in a fixed order.
        let mut candidates: Vec<String> = candidate_set.into_iter().collect();
        candidates.sort();

        if self.use_hierarchical_resolution {
            return self.hierarchical_resolution(&candidates, &interned_bag, bag);
        }

        let mut score_by_code: HashMap<String, f64> = HashMap::with_capacity(candidates.len());
        for code in &candidates {
            score_by_code.insert(code.clone(), self.score(code, &interned_bag));
        }

        // argmax: highest score, ties broken by lowest code lexicographically.
        let mut node = String::new();
        let mut node_score = -f64::MAX;
        for code in &candidates {
            let s = score_by_code.get(code).copied().unwrap_or(0.0);
            if s > node_score || (s == node_score && (node.is_empty() || code < &node)) {
                node = code.clone();
                node_score = s;
            }
        }

        // Tie-count guard (MAX_TIED_WINNERS_FOR_CLASSIFICATION): when many
        // codes share the argmax score, the query bag is dominated by common
        // cross-domain Q-IDs with near-zero IDF weight. The tie-break
        // (lowest code) picks an arbitrary code rather than a semantically
        // grounded one — a confidently-wrong specific code is worse than the
        // honest "000" unclassified sentinel. UNRESOLVED when tied codes
        // exceed the allowed maximum. Mirrors Swift FDCMatcher.encodeAnchor.
        let tied_count = candidates
            .iter()
            .filter(|c| score_by_code.get(*c).copied().unwrap_or(0.0) == node_score)
            .count();
        if tied_count > MAX_TIED_WINNERS_FOR_CLASSIFICATION {
            return (None, None); // too many tied winners — no discriminating signal
        }

        // Step 5 — frame descent (§6.1). A child must clear the RAW overlap
        // cutoff (mode-independent) to be a candidate; among those, the highest
        // mode score wins (ties -> lowest code). Scoring the descent under the
        // same mode as the argmax keeps both on one footing.
        loop {
            let children = self.frame.children(&node);
            let mut best: Option<String> = None;
            let mut best_score = 0.0f64;

            for child in children {
                if self.sig_term_ids.get(&child.code).is_none() {
                    continue;
                }
                // Cutoff check uses raw integer overlap — mode-independent.
                if self.raw_overlap(&child.code, &interned_bag) < self.stop_threshold {
                    continue;
                }
                let s = self.score(&child.code, &interned_bag);
                if best.is_none()
                    || s > best_score
                    || (s == best_score && child.code < *best.as_ref().unwrap())
                {
                    best = Some(child.code.clone());
                    best_score = s;
                }
            }

            match best {
                Some(next) => node = next,
                None => break,
            }
        }

        let qid = self.dominant_qid(bag, &node, &interned_bag);
        (Some(node), qid)
    }

    /// Highest-count Q-ID in `bag` that also supports the winning code.
    /// Unresolved text returns no Q-ID, and a code never borrows an incidental
    /// Q-ID from another part of the bag. Mirrors Swift `dominantQID`.
    fn dominant_qid(
        &self,
        bag: &ConceptBag,
        code: &str,
        interned_bag: &InternedBag,
    ) -> Option<String> {
        let supporting_ids = self.sig_term_ids.get(code)?;
        let mut best: Option<String> = None;
        let mut best_n = 0usize;
        for (k, &n) in bag {
            if !k.starts_with('Q') {
                continue;
            }
            let Some(&id) = self.term_to_id.get(k.as_str()) else {
                continue;
            };
            if !supporting_ids.contains(&id) || !interned_bag.contains_key(&id) {
                continue;
            }
            if n > best_n || (n == best_n && (best.is_none() || k < best.as_ref().unwrap())) {
                best = Some(k.clone());
                best_n = n;
            }
        }
        best
    }
}
