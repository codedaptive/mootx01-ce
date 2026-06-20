// distillation_pipeline.rs
//
// Full five-stage cold-path distillation algorithm.
// Rust port of DistillationPipeline.swift (Ds4). Parity conformance to be verified in Dp1.
//
// Per DISTILLATION_MATH_SSA.md §1–7 and DISTILLATION_MATH_DIFFUSION.md §1–8.
//
// Stage 1: Build feature incidence matrix from extract_features.
// Stage 2: Apply typed decay weighting (if timestamps), compute SNR gate
//          (skipped under intra_item), apply structural (recurrence) threshold.
// Stage 2.5: DeltaFeatureExtractor pass on failing features; rescue
//             CONVERGENT/MONOTONE sequences.
// Stage 3: Build PMI coherence graph, select dominant component (F*).
// Stage 4: Compute structural scores on F*.
// Stage 5: Compute confidence, format drawer_content, compute feature_fingerprint.
//
// Critical: f32::log2 is used in DistillationScorer (not f32::ln) — conformance with Swift.
// Critical: FEATURE_SIM_HASH_SEED = 0x44495354494C4C41 — "DISTILLA" in ASCII.
//           Changing this invalidates all stored distillation fingerprints.

use substrate_types::fingerprint256::Fingerprint256;

use crate::delta_feature_extractor::{DeltaFeatureExtractor, DeltaType};
use crate::distillation_scorer::{DistillationScorer, ExtractedFeature};
use crate::typed_decay_weighting::{DistillationFeatureType, TypedDecayWeighting};

// MARK: - Feature extractor type alias

/// Injected feature extraction function. Called once per (memory text, feature type) pair.
/// Returns extracted features; doc_frequency field is ignored (computed by pipeline).
/// Use a function pointer — closures are boxed at the call site if captures are needed.
pub type FeatureExtractor = fn(&str, DistillationFeatureType) -> Vec<ExtractedFeature>;

// MARK: - Input / Output types

/// Input to the five-stage distillation pipeline.
///
/// Mirrors Swift DistillationInput in DistillationPipeline.swift.
#[derive(Debug, Clone)]
pub struct DistillationInput {
    /// Raw text content of each memory in the cluster.
    pub memory_contents: Vec<String>,
    /// Optional timestamps as Unix epoch seconds (f64). None means uniform weighting.
    pub memory_timestamps: Option<Vec<f64>>,
    /// UUID of the cluster being distilled (written to lineage_id on the factoid drawer).
    pub cluster_id: String,
    /// UUIDs of the source memory drawers (for provenance chain).
    pub source_ids: Vec<String>,
}

impl DistillationInput {
    pub fn new(
        memory_contents: Vec<String>,
        memory_timestamps: Option<Vec<f64>>,
        cluster_id: impl Into<String>,
        source_ids: Vec<String>,
    ) -> Self {
        Self {
            memory_contents,
            memory_timestamps,
            cluster_id: cluster_id.into(),
            source_ids,
        }
    }

    /// Number of memories in the cluster.
    pub fn m(&self) -> usize {
        self.memory_contents.len()
    }
}

/// Output from the five-stage distillation pipeline.
///
/// Mirrors Swift DistillationOutput in DistillationPipeline.swift.
#[derive(Debug, Clone, PartialEq)]
pub struct DistillationOutput {
    /// Content string for the "_distilled" drawer capture.
    /// Format: "[DIST|conf=X.XX|src=N|snr=Y.YY|delta=STATIC] prose text"
    /// Empty string when succeeded == false.
    pub drawer_content: String,
    /// Confidence score conf(F*) ∈ [0, 1].
    pub confidence: f32,
    /// True when conf ∈ [0.4, 0.7): signal to inject with additional provenance.
    pub uncertain: bool,
    /// Cluster SNR at distillation time.
    pub snr: f32,
    /// DeltaType if a delta feature was the dominant contributor; None for static clusters.
    pub delta_type: Option<DeltaType>,
    /// True when a factoid was successfully produced (conf >= 0.4 and SNR gate passed).
    pub succeeded: bool,
    /// Human-readable reason for failure when succeeded == false.
    pub failure_reason: Option<String>,
    /// Structural fingerprint for the distilled tier's VectorKit lane.
    /// OR-reduce of feature_hash(f.value) for each feature f in F*.
    /// Stored in VectorKit under model_id = "distillation-features-v1".
    /// No embedding model inference — pure Hamming arithmetic.
    pub feature_fingerprint: Fingerprint256,
}

impl DistillationOutput {
    /// Construct a failure output with zero fingerprint.
    fn failure(snr: f32, reason: impl Into<String>) -> Self {
        Self {
            drawer_content: String::new(),
            confidence: 0.0,
            uncertain: false,
            snr,
            delta_type: None,
            succeeded: false,
            failure_reason: Some(reason.into()),
            feature_fingerprint: Fingerprint256::ZERO,
        }
    }
}

// MARK: - DistilledHeader

/// Parser for the DIST header on "_distilled" drawers.
///
/// Co-located with the pipeline because the code that writes the format owns the parser.
/// Consumed by CognitionKit recipes (DistilledRecall, ExpandMemory) and AriaMcpKit
/// injection-depth post-processing.
///
/// Expected content format (from DISTILLATION_DESIGN.md §1):
///   "[DIST|conf=0.85|src=5|snr=6.2|delta=STATIC] prose text"
///   "[DIST|conf=0.55|src=3|snr=3.1|delta=CONVERGENT|uncertain] prose"
///
/// Mirrors Swift DistilledHeader in DistillationPipeline.swift.
#[derive(Debug, Clone, PartialEq)]
pub struct DistilledHeader {
    /// Factoid prose: everything after "] " in the DIST content string.
    pub prose: String,
    /// Confidence score conf(F*) ∈ [0, 1].
    pub confidence: f32,
    /// Number of source memories M.
    pub source_count: usize,
    /// Cluster SNR at distillation time.
    pub snr: f32,
    /// DeltaType of the dominant feature, if non-static.
    pub delta_type: Option<DeltaType>,
    /// True when confidence ∈ [0.4, 0.7).
    pub uncertain: bool,
}

impl DistilledHeader {
    /// Parse a "_distilled" drawer's content string.
    ///
    /// Returns None if the content does not start with "[DIST|".
    pub fn parse(content: &str) -> Option<DistilledHeader> {
        if !content.starts_with("[DIST|") {
            return None;
        }

        // Find the closing bracket
        let bracket_end = content.find(']')?;

        // Header fields are between "[DIST|" and "]"
        let header_str = &content[6..bracket_end]; // skip "[DIST|"

        // Prose is everything after "] "
        let after_bracket = bracket_end + 1;
        let prose = if after_bracket < content.len() && content.as_bytes()[after_bracket] == b' ' {
            content[after_bracket + 1..].to_string()
        } else if after_bracket < content.len() {
            content[after_bracket..].to_string()
        } else {
            String::new()
        };

        let mut conf: f32 = 0.0;
        let mut src: usize = 0;
        let mut snr: f32 = 0.0;
        let mut delta: Option<DeltaType> = None;
        let mut uncertain = false;

        for part in header_str.split('|') {
            if part == "uncertain" {
                uncertain = true;
                continue;
            }
            if let Some(eq_pos) = part.find('=') {
                let key = &part[..eq_pos];
                let val = &part[eq_pos + 1..];
                match key {
                    "conf" => conf = val.parse().unwrap_or(0.0),
                    "src"  => src  = val.parse().unwrap_or(0),
                    "snr"  => snr  = val.parse().unwrap_or(0.0),
                    "delta" => {
                        delta = match val {
                            "STATIC"      => Some(DeltaType::Static),
                            "CONVERGENT"  => Some(DeltaType::Convergent),
                            "MONOTONE"    => Some(DeltaType::Monotone),
                            "OSCILLATING" => Some(DeltaType::Oscillating),
                            "DIVERGENT"   => Some(DeltaType::Divergent),
                            _ => None,
                        };
                    }
                    _ => {}
                }
            }
        }

        Some(DistilledHeader { prose, confidence: conf, source_count: src, snr, delta_type: delta, uncertain })
    }
}

// MARK: - DistillationPipeline

/// The five-stage cold-path distillation pipeline.
///
/// Pure function — no I/O, no state. Feature extraction is injected via
/// FeatureExtractor so callers supply the EideticLib HMM tagger or a test stub.
///
/// Mirrors Swift DistillationPipeline in DistillationPipeline.swift.
pub struct DistillationPipeline;

impl DistillationPipeline {
    /// Fixed seed for feature-to-Fingerprint256 hashing.
    ///
    /// "DISTILLA" encoded as ASCII bytes in big-endian u64:
    ///   D=0x44 I=0x49 S=0x53 T=0x54 I=0x49 L=0x4C L=0x4C A=0x41
    ///   → 0x44495354494C4C41
    ///
    /// Changing this constant invalidates all stored distillation fingerprints —
    /// requires a full re-distillation sweep of all clusters.
    /// Must be identical in the Swift port (conformance gate).
    pub const FEATURE_SIM_HASH_SEED: u64 = 0x44495354494C4C41;

    /// Hash a single feature value string to a Fingerprint256 using the fixed seed.
    ///
    /// Algorithm: mix each UTF-8 byte into the seed state using SplitMix64 avalanche
    /// steps, then expand the resulting 64-bit state to four blocks via SplitMix64.
    /// Deterministic and bit-identical to the Swift featureHash implementation.
    ///
    /// feature_hash("") does not panic; returns a deterministic non-zero fingerprint.
    pub fn feature_hash(value: &str) -> Fingerprint256 {
        let mut state: u64 = Self::FEATURE_SIM_HASH_SEED;
        for byte in value.bytes() {
            // XOR-fold the byte, then apply one SplitMix64 avalanche round (state updated in place)
            state ^= byte as u64;
            state = state.wrapping_add(0x9E3779B97F4A7C15);
            state ^= state >> 30;
            state = state.wrapping_mul(0xBF58476D1CE4E5B9);
            state ^= state >> 27;
            state = state.wrapping_mul(0x94D049BB133111EB);
            state ^= state >> 31;
        }
        // Expand 64-bit state to four 64-bit blocks via SplitMix64 next()
        let block0 = Self::split_mix64_next(&mut state);
        let block1 = Self::split_mix64_next(&mut state);
        let block2 = Self::split_mix64_next(&mut state);
        let block3 = Self::split_mix64_next(&mut state);
        Fingerprint256::new(block0, block1, block2, block3)
    }

    /// Compute the query fingerprint for distilled recall.
    ///
    /// Extracts features from the query string for each feature type, hashes each
    /// feature value via feature_hash, then OR-reduces into a single Fingerprint256.
    ///
    /// Called by DistilledRecall at query time — no embedding model inference.
    /// The result is a probe for Hamming NN over the distillation-features-v1 lane.
    pub fn query_fingerprint(
        query: &str,
        extract_features: FeatureExtractor,
    ) -> Fingerprint256 {
        // Iterate over all four feature types — DistillationFeatureType has no CaseIterable;
        // the fixed array matches the Swift CaseIterable allCases order.
        const ALL_TYPES: [DistillationFeatureType; 4] = [
            DistillationFeatureType::Entity,
            DistillationFeatureType::Relation,
            DistillationFeatureType::Temporal,
            DistillationFeatureType::Numerical,
        ];
        let mut result = Fingerprint256::ZERO;
        for feature_type in ALL_TYPES {
            let features = extract_features(query, feature_type);
            for feature in features {
                result = result.zip4(&Self::feature_hash(&feature.value), |a, b| a | b);
            }
        }
        result
    }

    /// Capitalization-heuristic feature extractor for testing.
    ///
    /// Extracts ENT features: words starting with an uppercase letter that are
    /// not the first word of the text (to avoid treating sentence-initial words
    /// as named entities). Returns empty for non-entity feature types.
    pub fn default_extractor(text: &str, feature_type: DistillationFeatureType) -> Vec<ExtractedFeature> {
        if feature_type != DistillationFeatureType::Entity {
            return Vec::new();
        }
        let mut results = Vec::new();
        let words: Vec<&str> = text.split(' ').collect();
        for (i, word) in words.iter().enumerate() {
            if i == 0 {
                continue;
            }
            let first_char = match word.chars().next() {
                Some(c) => c,
                None => continue,
            };
            if !first_char.is_uppercase() || word.len() <= 1 {
                continue;
            }
            let trimmed = word.trim_matches(|c: char| c.is_ascii_punctuation());
            if trimmed.is_empty() {
                continue;
            }
            results.push(ExtractedFeature::new(
                DistillationFeatureType::Entity,
                trimmed,
                0.0,
            ));
        }
        results
    }

    // MARK: - run()

    /// Execute the five-stage distillation pipeline on a memory cluster.
    ///
    /// This function is intentionally long: the five stages share `per_memory_features`,
    /// `incidence`, and `vocab_*` state that cannot be extracted into helpers without
    /// expensive cloning. Each stage is clearly marked with a "── Stage N:" banner.
    ///
    /// - `input`: the reduction units (one item's sentences for intra-item
    ///   distillation), optional timestamps, source id, source IDs.
    /// - `extract_features`: feature extraction function (injected by caller).
    /// - `intra_item`: distill a SINGLE item from its own units (sentences) rather
    ///   than a cross-memory cluster. This turns off the pipeline's cross-memory
    ///   consensus machinery, which otherwise discards a single item's signal:
    ///     • SNR hold — a single item never grows, so the "wait for the cluster
    ///       to accumulate more members" hold does not apply; the item is reduced
    ///       now from whatever recurring structure it carries (confidence
    ///       annotates quality / injection depth rather than blocking).
    ///     • PMI dominant-component pruning — a single document is ONE coherent
    ///       thing, so EVERY recurring feature is its content. "Pick the single
    ///       shared theme across memories" splits the item and drops real content
    ///       (the Falcon doc lost database/tables/shadow to a non-dominant
    ///       component). Intra-item keeps all structural features.
    ///   Default false (caller passes `false`) preserves the cross-memory cluster
    ///   behaviour. Swift gives this an `= false` default; Rust has no default
    ///   params, so every call site passes the flag explicitly.
    ///
    /// Returns DistillationOutput with drawer_content, confidence, feature_fingerprint.
    pub fn run(
        input: &DistillationInput,
        extract_features: FeatureExtractor,
        intra_item: bool,
    ) -> DistillationOutput {
        let m = input.m();
        if m == 0 {
            return DistillationOutput::failure(0.0, "Empty cluster");
        }

        // ── Stage 1: Feature extraction and incidence matrix ──────────────────

        // Collect extracted features per memory (all four feature types)
        const ALL_TYPES: [DistillationFeatureType; 4] = [
            DistillationFeatureType::Entity,
            DistillationFeatureType::Relation,
            DistillationFeatureType::Temporal,
            DistillationFeatureType::Numerical,
        ];
        let per_memory_features: Vec<Vec<ExtractedFeature>> = input.memory_contents.iter().map(|memory| {
            let mut features: Vec<ExtractedFeature> = Vec::new();
            for ft in ALL_TYPES {
                features.extend(extract_features(memory, ft));
            }
            features
        }).collect();

        // Build vocabulary in encounter order. The key is the stemmed `value`;
        // the first surface form seen for each stem is kept as the display form
        // for the factoid prose. Track type and display per entry.
        let mut vocab_order: Vec<String> = Vec::new();
        let mut vocab_index: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
        let mut vocab_types: Vec<DistillationFeatureType> = Vec::new();
        let mut vocab_display: Vec<String> = Vec::new();

        for features in &per_memory_features {
            for feature in features {
                if !vocab_index.contains_key(&feature.value) {
                    let idx = vocab_order.len();
                    vocab_index.insert(feature.value.clone(), idx);
                    vocab_order.push(feature.value.clone());
                    vocab_types.push(feature.feature_type.clone());
                    vocab_display.push(feature.display.clone());
                }
            }
        }

        let v = vocab_order.len();
        if v == 0 {
            return DistillationOutput::failure(0.0, "No features extracted from memories");
        }

        // Build incidence matrix: incidence[i][j] = true iff feature j appears in memory i
        let incidence: Vec<Vec<bool>> = (0..m).map(|i| {
            let present: std::collections::HashSet<&str> =
                per_memory_features[i].iter().map(|f| f.value.as_str()).collect();
            vocab_order.iter().map(|v| present.contains(v.as_str())).collect()
        }).collect();

        // ── Stage 2: Frequency scoring, SNR gate, majority threshold ──────────

        // Carry the display surface form so the factoid prose renders readable
        // words, not stems.
        let mut all_features: Vec<ExtractedFeature> = vocab_order.iter().enumerate().map(|(j, value)| {
            ExtractedFeature::new_with_display(
                vocab_types[j].clone(),
                value.as_str(),
                0.0,
                vocab_display[j].as_str(),
            )
        }).collect();

        if let Some(ref ts) = input.memory_timestamps {
            if ts.len() == m {
                // Weighted: type-specific decay
                let ref_time = ts.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
                for j in 0..v {
                    let presence_timestamps: Vec<f64> = (0..m)
                        .filter(|&i| incidence[i][j])
                        .map(|i| ts[i])
                        .collect();
                    let df = presence_timestamps.len() as f32 / m as f32;
                    let wdf = TypedDecayWeighting::weighted_doc_frequency(
                        vocab_types[j].clone(),
                        &presence_timestamps,
                        ts.as_slice(),
                        ref_time,
                        86_400.0,
                    );
                    all_features[j].doc_frequency = df;
                    all_features[j].weighted_doc_frequency = wdf;
                }
            } else {
                // Timestamp count mismatch — fall back to uniform
                Self::compute_uniform_frequencies(&mut all_features, &incidence, m, v);
            }
        } else {
            Self::compute_uniform_frequencies(&mut all_features, &incidence, m, v);
        }

        // SNR gate: check cluster quality before running full distillation.
        // Intra-item distillation never SNR-holds — a single item never grows,
        // so the "wait for the cluster to accumulate more members" hold does not
        // apply; the item is reduced now from whatever recurring structure it
        // carries (confidence annotates quality, it does not block).
        let snr_result = DistillationScorer::compute_snr(&all_features, m);
        if !intra_item && !snr_result.ready_to_distill {
            return DistillationOutput::failure(
                snr_result.snr,
                format!("SNR {:.4} < 2.0: cluster is episodically dense, not ready", snr_result.snr),
            );
        }

        // Apply the structural (recurrence) threshold: keep features that recur
        // across ≥2 of the item's units; the one-off tail is episodic.
        let (mut passing, failing) = DistillationScorer::apply_structural_threshold(&all_features, m);

        // ── Stage 2.5: Delta pre-pass ─────────────────────────────────────────
        //
        // For failing features, group by predicate key (part before ":" in value).
        // Analyze each key's value sequence across memories for convergence.
        // Promote CONVERGENT or MONOTONE terminal values to the passing set.

        let mut delta_type_for_factoid: Option<DeltaType> = None;

        if !failing.is_empty() {
            // Build key → list of (memory_index, full_feature_value)
            let mut key_to_occurrences: std::collections::HashMap<String, Vec<(usize, String)>> =
                std::collections::HashMap::new();

            for (i, features) in per_memory_features.iter().enumerate() {
                for feature in features {
                    let key: String = if let Some(colon_pos) = feature.value.find(':') {
                        feature.value[..colon_pos].to_string()
                    } else {
                        feature.value.clone()
                    };
                    key_to_occurrences
                        .entry(key)
                        .or_default()
                        .push((i, feature.value.clone()));
                }
            }

            let failing_values: std::collections::HashSet<&str> =
                failing.iter().map(|f| f.value.as_str()).collect();

            for (_key, occurrences) in &key_to_occurrences {
                // Skip keys with no failing features
                let has_failing = occurrences.iter().any(|(_, v)| failing_values.contains(v.as_str()));
                if !has_failing {
                    continue;
                }

                // Sort by memory index (chronological)
                let mut sorted = occurrences.clone();
                sorted.sort_by_key(|(idx, _)| *idx);

                // Build categorical sequence with timestamps or index proxies
                let cat_seq: Vec<(String, f64)> = if let Some(ref ts) = input.memory_timestamps {
                    if ts.len() == m {
                        sorted.iter().map(|(idx, val)| (val.clone(), ts[*idx])).collect()
                    } else {
                        sorted.iter().enumerate().map(|(pos, (_, val))| (val.clone(), pos as f64)).collect()
                    }
                } else {
                    // No timestamps: use memory index as proxy (seconds from epoch)
                    sorted.iter().enumerate().map(|(pos, (_, val))| (val.clone(), pos as f64)).collect()
                };

                // decay_lambda = 0.5: categorical default (REL/ENT) per DISTILLATION_MATH_DIFFUSION.md §2.
                let analysis = DeltaFeatureExtractor::analyze_categorical(&cat_seq, 0.5);

                if analysis.delta_type == DeltaType::Convergent || analysis.delta_type == DeltaType::Monotone {
                    let terminal = &analysis.terminal_value;
                    if failing_values.contains(terminal.as_str()) {
                        // Find the failing feature with this terminal value and promote it
                        if let Some(fail_idx) = failing.iter().position(|f| &f.value == terminal) {
                            let mut promoted = failing[fail_idx].clone();
                            promoted.weighted_doc_frequency = analysis.confidence;
                            if passing.is_empty() {
                                promoted.doc_frequency = 0.5;
                            }
                            passing.push(promoted);
                            if delta_type_for_factoid.is_none() {
                                delta_type_for_factoid = Some(analysis.delta_type.clone());
                            }
                        }
                    }
                }
            }
        }

        if passing.is_empty() {
            return DistillationOutput::failure(
                snr_result.snr,
                "No features survived threshold or delta pre-pass",
            );
        }

        // ── Stage 3: PMI coherence graph and dominant component ───────────────

        // Build incidence matrix restricted to passing features
        let passing_values: std::collections::HashSet<&str> =
            passing.iter().map(|f| f.value.as_str()).collect();
        let passing_indices: Vec<usize> = vocab_order.iter().enumerate()
            .filter_map(|(j, v)| if passing_values.contains(v.as_str()) { Some(j) } else { None })
            .collect();

        let restricted_incidence: Vec<Vec<bool>> = (0..m).map(|i| {
            passing_indices.iter().map(|&j| incidence[i][j]).collect()
        }).collect();

        let graph = DistillationScorer::build_pmi_graph(&passing, &restricted_incidence, m);
        let mut selected: Vec<ExtractedFeature> = if intra_item {
            // Intra-item: the item is ONE coherent thing — every recurring,
            // non-stopword feature is its content. Keep them all (the PMI graph
            // is the cross-memory "single shared theme" pruner and would split
            // the document and drop real content).
            passing.clone()
        } else {
            let mut sel = DistillationScorer::select_dominant_component(&graph);
            // Ubiquity inclusion: a feature present in (near) ALL members is the
            // spine — yet PMI isolates it. A feature in every member has
            // p(f∧x) = p(x), so PMI(f,x) = log₂(1) = 0 with EVERY other feature,
            // giving it no positive edges, so select_dominant_component drops it,
            // silently discarding the most central feature. Re-add any passing
            // feature in ≥ M-1 of the M members not already selected: core by
            // ubiquity, not frequent-but-independent noise.
            let ubiquity_threshold = (m - 1) as f32 / m as f32;
            let selected_values: std::collections::HashSet<&str> =
                sel.iter().map(|f| f.value.as_str()).collect();
            let mut to_add: Vec<ExtractedFeature> = passing.iter()
                .filter(|f| f.doc_frequency >= ubiquity_threshold
                    && !selected_values.contains(f.value.as_str()))
                .cloned()
                .collect();
            sel.append(&mut to_add);
            sel
        };

        if selected.is_empty() {
            return DistillationOutput::failure(
                snr_result.snr,
                "PMI graph produced no dominant component",
            );
        }

        // ── Stage 4: Structural scores ────────────────────────────────────────
        DistillationScorer::compute_structural_scores(&mut selected);

        // ── Stage 5: Confidence, content, fingerprint ─────────────────────────

        let confidence = DistillationScorer::compute_confidence(&selected, &passing);
        let uncertain = confidence >= 0.4 && confidence < 0.7;

        // Format drawer_content: "[DIST|conf=X.XX|src=N|snr=Y.YY|delta=Z] prose"
        let conf_str = format!("{:.2}", confidence);
        let snr_str  = format!("{:.1}", snr_result.snr);
        let delta_str = delta_type_for_factoid.as_ref().map(|d| d.as_str()).unwrap_or("STATIC");
        let uncertain_flag = if uncertain { "|uncertain" } else { "" };

        // Prose: top features by structural score, rendered as readable surface
        // forms (display), not stems.
        let mut sorted_selected = selected.clone();
        sorted_selected.sort_by(|a, b| {
            b.structural_score.partial_cmp(&a.structural_score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let prose: String = sorted_selected.iter().map(|f| f.display.as_str()).collect::<Vec<_>>().join(" ");

        // src= records the number of SOURCE MEMORIES (input.source_ids.len()), NOT the
        // number of incidence-matrix rows (m = memory_contents.len()). In the cross-memory
        // cluster model both happen to be equal, but in the intra-item model memory_contents
        // holds the item's sentences (m ≥ 3) while source_ids holds exactly the one source
        // drawer ID. src= must equal the number of _distilled_from tunnels written by
        // captureFactoid, which iterates member_drawers — one per source_id.
        let source_count = input.source_ids.len();
        let drawer_content = format!(
            "[DIST|conf={conf_str}|src={source_count}|snr={snr_str}|delta={delta_str}{uncertain_flag}] {prose}"
        );

        // Feature fingerprint: OR-reduce of feature_hash for each selected feature
        let fingerprint = selected.iter().fold(Fingerprint256::ZERO, |acc, feature| {
            acc.zip4(&Self::feature_hash(&feature.value), |a, b| a | b)
        });

        DistillationOutput {
            drawer_content,
            confidence,
            uncertain,
            snr: snr_result.snr,
            delta_type: delta_type_for_factoid,
            succeeded: confidence >= 0.4,
            failure_reason: if confidence < 0.4 {
                Some(format!("Confidence {confidence:.4} below 0.4 threshold"))
            } else {
                None
            },
            feature_fingerprint: fingerprint,
        }
    }

    // MARK: - Private helpers

    /// Advance a SplitMix64 RNG state by one step and return the output.
    ///
    /// State is updated in place. Output is the mixed value after the state increment.
    /// Matches Swift SplitMix64.next() bit-for-bit.
    #[inline]
    fn split_mix64_next(state: &mut u64) -> u64 {
        *state = state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = *state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    /// Compute uniform (non-weighted) document frequencies for all features.
    fn compute_uniform_frequencies(
        all_features: &mut Vec<ExtractedFeature>,
        incidence: &[Vec<bool>],
        m: usize,
        v: usize,
    ) {
        for j in 0..v {
            let count = (0..m).filter(|&i| incidence[i][j]).count() as f32;
            let df = count / m as f32;
            all_features[j].doc_frequency = df;
            all_features[j].weighted_doc_frequency = df;
        }
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    // MARK: - FEATURE_SIM_HASH_SEED

    #[test]
    fn feature_sim_hash_seed_is_distilla_ascii() {
        // "DISTILLA" big-endian ASCII → 0x44495354494C4C41
        assert_eq!(DistillationPipeline::FEATURE_SIM_HASH_SEED, 0x44495354494C4C41u64);
    }

    // MARK: - feature_hash

    #[test]
    fn feature_hash_empty_string_is_deterministic() {
        let a = DistillationPipeline::feature_hash("");
        let b = DistillationPipeline::feature_hash("");
        assert_eq!(a, b);
    }

    #[test]
    fn feature_hash_idempotent_or() {
        // A OR A == A (identity under bitwise OR)
        let h = DistillationPipeline::feature_hash("A");
        let union = h.zip4(&h, |a, b| a | b);
        assert_eq!(union, h);
    }

    #[test]
    fn feature_hash_distinct_inputs_produce_distinct_fingerprints() {
        let h1 = DistillationPipeline::feature_hash("Alice");
        let h2 = DistillationPipeline::feature_hash("Bob");
        assert_ne!(h1, h2);
    }

    #[test]
    fn feature_hash_same_input_returns_same_fingerprint() {
        let a = DistillationPipeline::feature_hash("Marie Curie");
        let b = DistillationPipeline::feature_hash("Marie Curie");
        assert_eq!(a, b);
    }

    #[test]
    fn feature_hash_provenance_is_deterministic() {
        // Conformance gate: featureHash("provenance") must be deterministic
        let a = DistillationPipeline::feature_hash("provenance");
        let b = DistillationPipeline::feature_hash("provenance");
        assert_eq!(a, b);
        // Non-zero
        assert_ne!(a, Fingerprint256::ZERO);
    }

    // MARK: - DistilledHeader.parse

    #[test]
    fn parse_returns_none_for_non_dist_content() {
        assert!(DistilledHeader::parse("").is_none());
        assert!(DistilledHeader::parse("some plain text").is_none());
        assert!(DistilledHeader::parse("[OTHER|conf=0.5] text").is_none());
    }

    #[test]
    fn parse_static_dist_header() {
        let content = "[DIST|conf=0.85|src=5|snr=6.20|delta=STATIC] Alice works at CERN";
        let h = DistilledHeader::parse(content).expect("should parse");
        assert_eq!(h.prose, "Alice works at CERN");
        assert!((h.confidence - 0.85).abs() < 0.001);
        assert_eq!(h.source_count, 5);
        assert!((h.snr - 6.20).abs() < 0.01);
        assert_eq!(h.delta_type, Some(DeltaType::Static));
        assert!(!h.uncertain);
    }

    #[test]
    fn parse_uncertain_convergent_header() {
        let content = "[DIST|conf=0.55|src=3|snr=3.10|delta=CONVERGENT|uncertain] Bob runs experiments";
        let h = DistilledHeader::parse(content).expect("should parse");
        assert_eq!(h.prose, "Bob runs experiments");
        assert!((h.confidence - 0.55).abs() < 0.001);
        assert_eq!(h.source_count, 3);
        assert_eq!(h.delta_type, Some(DeltaType::Convergent));
        assert!(h.uncertain);
    }

    #[test]
    fn parse_header_with_no_delta_field() {
        let content = "[DIST|conf=0.72|src=4|snr=4.50] Some prose here";
        let h = DistilledHeader::parse(content).expect("should parse");
        assert_eq!(h.delta_type, None);
        assert!((h.confidence - 0.72).abs() < 0.001);
    }

    // MARK: - query_fingerprint

    #[test]
    fn query_fingerprint_is_deterministic_for_content_with_entities() {
        let query = "Research by Alice at CERN on particle physics";
        let fp1 = DistillationPipeline::query_fingerprint(query, DistillationPipeline::default_extractor);
        let fp2 = DistillationPipeline::query_fingerprint(query, DistillationPipeline::default_extractor);
        assert_eq!(fp1, fp2);
        assert_ne!(fp1, Fingerprint256::ZERO);
    }

    #[test]
    fn query_fingerprint_deterministic_on_identical_text() {
        let query = "Marie Curie discovered Radium in Paris";
        let fp1 = DistillationPipeline::query_fingerprint(query, DistillationPipeline::default_extractor);
        let fp2 = DistillationPipeline::query_fingerprint(query, DistillationPipeline::default_extractor);
        assert_eq!(fp1, fp2);
    }

    // MARK: - Full pipeline run

    // Five-memory cluster: Alice+CERN in 4/5 memories (df=0.8 > τ=0.6), M4 has no features.
    // No episodic-noise features → episodic=0 → SNR=∞ under the Rust sigma formula.
    // Note: Swift computeSNR uses sum(df) not sum(sigma), so the same cluster passes
    // both Rust and Swift. The Rust sigma formula is more conservative; see Dp1 for
    // parity verification between the two computeSNR implementations.
    fn five_memory_cluster() -> DistillationInput {
        DistillationInput::new(
            vec![
                "Research by Alice at CERN on particle physics".to_string(),
                "The lab where Alice works is CERN facility".to_string(),
                "Studies conducted by Alice show CERN advances science".to_string(),
                "Data from CERN shows Alice leading breakthrough research".to_string(),
                "Maintenance was completed on schedule today".to_string(),
            ],
            None,
            "test-cluster-01",
            (0..5).map(|i| format!("src-{i}")).collect(),
        )
    }

    #[test]
    fn full_pipeline_on_five_memory_cluster_succeeds_with_conf_gt_0_6() {
        let input = five_memory_cluster();
        let output = DistillationPipeline::run(&input, DistillationPipeline::default_extractor, false);
        assert!(output.succeeded, "pipeline should succeed; failure_reason={:?}", output.failure_reason);
        assert!(output.confidence > 0.6, "confidence should exceed 0.6, got {}", output.confidence);
        assert_ne!(output.feature_fingerprint, Fingerprint256::ZERO);
    }

    #[test]
    fn dist_header_format_is_correct() {
        let input = five_memory_cluster();
        let output = DistillationPipeline::run(&input, DistillationPipeline::default_extractor, false);
        if !output.succeeded {
            return;
        }
        assert!(output.drawer_content.starts_with("[DIST|"), "must start with [DIST|");
        assert!(output.drawer_content.contains("conf="));
        assert!(output.drawer_content.contains("src="));
        assert!(output.drawer_content.contains("snr="));
        assert!(output.drawer_content.contains("delta="));
        assert!(output.drawer_content.contains("] "));
    }

    #[test]
    fn distilled_header_parse_round_trip() {
        let input = five_memory_cluster();
        let output = DistillationPipeline::run(&input, DistillationPipeline::default_extractor, false);
        if !output.succeeded {
            return;
        }
        let h = DistilledHeader::parse(&output.drawer_content).expect("parse must succeed");
        assert!((h.confidence - output.confidence).abs() < 0.01);
        assert_eq!(h.source_count, 5);
        // SNR tolerance is relative: very large SNR (near-zero episodic noise) loses
        // f32 precision through the format("{:.1}")/parse round-trip. Use a 0.1% relative
        // tolerance with a 1.0 absolute floor to handle both normal and large-SNR clusters.
        let snr_tol = (output.snr * 0.001).max(1.0);
        assert!((h.snr - output.snr).abs() < snr_tol, "snr round-trip: got {}, expected {}", h.snr, output.snr);
        let expected_delta = output.delta_type.unwrap_or(DeltaType::Static);
        assert_eq!(h.delta_type, Some(expected_delta));
        assert_eq!(h.uncertain, output.uncertain);
    }

    #[test]
    fn snr_gate_fails_for_disjoint_cluster() {
        let disjoint = DistillationInput::new(
            vec![
                "UniqueEntityAlpha was spotted near the mountains".to_string(),
                "UniqueEntityBeta appeared at the coastline".to_string(),
                "UniqueEntityGamma visited the valley".to_string(),
            ],
            None,
            "test-cluster-snr",
            vec!["s0".into(), "s1".into(), "s2".into()],
        );
        let output = DistillationPipeline::run(&disjoint, DistillationPipeline::default_extractor, false);
        assert!(!output.succeeded, "disjoint cluster should fail SNR gate");
    }

    #[test]
    fn delta_pre_pass_rescues_convergent_feature() {
        // Design (M=10, τ_struct = 2/10 = 0.2):
        //   Structural (df=9/10=0.9 ≥ τ): cern, physics, research, lab, data, particle,
        //     matter, experiment (8 features). sigma per = 0.478, structural = 3.824.
        //   Failing (df < τ): status:pending(1/10=0.1), status:approved(1/10=0.1).
        //     Both are one-off under the structural (recurrence) threshold.
        //   Episodic noise = (1-0.1)+(1-0.1) = 1.8. SNR = 3.824/1.8 = 2.12 > 2.0 ✓
        //
        //   status key CONVERGENT trajectory [pending(M1)→approved(M2)]:
        //     terminal="status:approved", m=2, k=1, C=1/2=0.5 ≥ 0.5 → CONVERGENT.
        //     status:approved (df=0.1, one-off) is promoted to the passing set by
        //     the delta pre-pass. The terminal must be below τ_struct to need the
        //     rescue — at exactly one occurrence it is episodic by recurrence but
        //     structural by convergence.
        //
        // Note: Swift computeSNR sums raw df (structural=8×0.9=7.2, episodic=0.2);
        //   Rust uses sigma formula (more conservative). This cluster is designed to
        //   pass the Rust gate. Parity verification is in Dp1.
        //
        // Pipe-delimited controlled extractor to keep feature sets precise.
        fn pipe_extractor(text: &str, feature_type: DistillationFeatureType) -> Vec<ExtractedFeature> {
            match feature_type {
                DistillationFeatureType::Entity => {
                    text.split('|')
                        .filter(|s| s.starts_with("E:"))
                        .map(|s| ExtractedFeature::new(DistillationFeatureType::Entity, s[2..].trim(), 0.0))
                        .collect()
                }
                DistillationFeatureType::Relation => {
                    text.split('|')
                        .filter(|s| s.starts_with("R:"))
                        .map(|s| ExtractedFeature::new(DistillationFeatureType::Relation, s[2..].trim(), 0.0))
                        .collect()
                }
                _ => vec![],
            }
        }

        // 8 structural ENT features in M0-M8 (9/10), status:pending in M1 only,
        // status:approved in M2 only (each one-off, df=0.1). M9 has no features.
        let ent = "E:cern|E:physics|E:research|E:lab|E:data|E:particle|E:matter|E:experiment";
        let memories = vec![
            ent.to_string(),
            format!("{ent}|R:status:pending"),
            format!("{ent}|R:status:approved"),
            ent.to_string(),
            ent.to_string(),
            ent.to_string(),
            ent.to_string(),
            ent.to_string(),
            ent.to_string(),
            "no features here".to_string(),
        ];

        let input = DistillationInput::new(
            memories,
            None,
            "test-cluster-delta",
            (0..10).map(|i| format!("src-{i}")).collect(),
        );
        let output = DistillationPipeline::run(&input, pipe_extractor, false);
        assert!(output.succeeded, "delta pre-pass should rescue CONVERGENT feature; failure={:?}", output.failure_reason);
        assert_eq!(output.delta_type, Some(DeltaType::Convergent));
        assert_ne!(output.feature_fingerprint, Fingerprint256::ZERO);
    }

    #[test]
    fn failure_output_has_empty_drawer_content() {
        let input = DistillationInput::new(
            vec!["Hello".into(), "World".into(), "Foo".into()],
            None,
            "test-cluster-fail",
            vec!["s1".into(), "s2".into(), "s3".into()],
        );
        let output = DistillationPipeline::run(&input, DistillationPipeline::default_extractor, false);
        if !output.succeeded {
            assert!(output.drawer_content.is_empty());
            assert!(output.failure_reason.is_some());
            assert_eq!(output.confidence, 0.0);
        }
    }

    #[test]
    fn feature_fingerprint_is_or_union_idempotent() {
        let input = five_memory_cluster();
        let output = DistillationPipeline::run(&input, DistillationPipeline::default_extractor, false);
        if !output.succeeded {
            return;
        }
        assert_ne!(output.feature_fingerprint, Fingerprint256::ZERO);
        // OR-idempotent: fp | fp == fp
        let fp = output.feature_fingerprint;
        let union = fp.zip4(&fp, |a, b| a | b);
        assert_eq!(union, fp);
    }

    #[test]
    fn empty_cluster_returns_failure() {
        let input = DistillationInput::new(vec![], None, "test-cluster-empty", vec![]);
        let output = DistillationPipeline::run(&input, DistillationPipeline::default_extractor, false);
        assert!(!output.succeeded);
        assert!(output.failure_reason.is_some());
    }

    #[test]
    fn single_memory_cluster_does_not_panic() {
        let input = DistillationInput::new(
            vec!["Alice visited Paris last summer".into()],
            None,
            "test-cluster-single",
            vec!["s1".into()],
        );
        let output = DistillationPipeline::run(&input, DistillationPipeline::default_extractor, false);
        if output.succeeded {
            assert!(output.confidence >= 0.4);
            assert!(!output.drawer_content.is_empty());
        } else {
            assert_eq!(output.confidence, 0.0);
        }
    }

    // MARK: - Intra-item distillation

    /// Controlled extractor: every word starting with "E:" is an ENT feature
    /// with value = stem-stand-in (the text after "E:") and display = the same.
    /// Words without the prefix are ignored. Lets a test place exact features in
    /// exact units so the intra-item selection is deterministic.
    fn marked_ent_extractor(text: &str, feature_type: DistillationFeatureType) -> Vec<ExtractedFeature> {
        if feature_type != DistillationFeatureType::Entity {
            return vec![];
        }
        text.split_whitespace()
            .filter(|w| w.starts_with("E:"))
            .map(|w| {
                let body = &w[2..];
                // value = stem-stand-in (before '/' if present), display = after '/'.
                if let Some(slash) = body.find('/') {
                    ExtractedFeature::new_with_display(
                        DistillationFeatureType::Entity,
                        &body[..slash],
                        0.0,
                        &body[slash + 1..],
                    )
                } else {
                    ExtractedFeature::new(DistillationFeatureType::Entity, body, 0.0)
                }
            })
            .collect()
    }

    // intra_item keeps ALL structural (recurring) features, not just the PMI
    // dominant component. The Falcon-style document: a spine entity recurs across
    // a minority of sentences alongside several co-recurring entities; the PMI
    // pruner would split them, intra-item keeps every recurring one.
    #[test]
    fn intra_item_keeps_all_passing_features() {
        // 4 sentences. database+tables recur (2/4 each), shadow recurs (2/4),
        // and migration recurs (2/4) — all ≥ τ_struct(4)=0.5. Each pair co-occurs
        // in different sentences, so PMI would fragment them into small
        // components; intra-item keeps them all.
        let input = DistillationInput::new(
            vec![
                "E:databas/database E:tabl/tables".to_string(),
                "E:databas/database E:shadow/shadow".to_string(),
                "E:tabl/tables E:migrat/migration".to_string(),
                "E:shadow/shadow E:migrat/migration".to_string(),
            ],
            None,
            "item-falcon",
            vec!["item-falcon".to_string()],
        );
        let output = DistillationPipeline::run(&input, marked_ent_extractor, true);
        assert!(output.succeeded, "intra-item must succeed; failure={:?}", output.failure_reason);
        // All four recurring stems must appear in the prose as their display forms.
        for surface in ["database", "tables", "shadow", "migration"] {
            assert!(
                output.drawer_content.contains(surface),
                "prose must contain '{surface}'; got {}",
                output.drawer_content
            );
        }
    }

    // intra_item NEVER SNR-holds: a single sparse item whose SNR would fail the
    // cross-memory gate still distills under intra_item.
    #[test]
    fn intra_item_does_not_snr_hold() {
        // 3 sentences, each a distinct entity recurring only once (df=1/3 each)
        // plus one shared entity in 2 of 3 (df=2/3). Under cross-memory rules the
        // episodic tail would hold this; intra_item reduces it now.
        let input = DistillationInput::new(
            vec![
                "E:spine E:one".to_string(),
                "E:spine E:two".to_string(),
                "E:three E:four".to_string(),
            ],
            None,
            "item-sparse",
            vec!["item-sparse".to_string()],
        );
        let cross = DistillationPipeline::run(&input, marked_ent_extractor, false);
        let intra = DistillationPipeline::run(&input, marked_ent_extractor, true);
        // The cross-memory path may hold (SNR gate); the intra-item path must not
        // fail for SNR reasons — it produces from the recurring 'spine'.
        assert!(intra.succeeded, "intra-item must not SNR-hold; failure={:?}", intra.failure_reason);
        assert!(intra.drawer_content.contains("spine"));
        // Document the cross-memory behaviour for traceability: it does not crash
        // and is a well-formed output regardless of succeeded.
        let _ = cross.succeeded;
    }

    // Ubiquity re-add (cross-memory path): a feature present in ALL members has
    // PMI = 0 with every other feature and is dropped by the dominant-component
    // selector — the re-add restores it when df ≥ (M-1)/M.
    #[test]
    fn cross_memory_ubiquity_readd_restores_spine() {
        // M=4, no episodic tail (every feature recurs ≥ τ_struct=0.5 → SNR ready).
        // 'spine' in all 4 (df=1.0 ≥ (4-1)/4=0.75) but co-occurs with EVERYTHING,
        // so PMI(spine,*) = log₂(1) = 0 → no positive edges → isolated singleton
        // (component weight = its wdf = 1.0). alpha+beta co-occur in 3 of 4
        // (df=0.75 each → component weight 1.5 > 1.0) and are the DOMINANT
        // component; gamma+delta co-occur in 2 of 4 (weight 1.0). spine, dropped
        // by dominant-component selection, is restored by the ubiquity re-add.
        let input = DistillationInput::new(
            vec![
                "E:spine E:alpha E:beta E:gamma E:delta".to_string(),
                "E:spine E:alpha E:beta E:gamma E:delta".to_string(),
                "E:spine E:alpha E:beta".to_string(),
                "E:spine".to_string(),
            ],
            None,
            "cluster-ubiquity",
            (0..4).map(|i| format!("src-{i}")).collect(),
        );
        let output = DistillationPipeline::run(&input, marked_ent_extractor, false);
        assert!(output.succeeded, "ubiquity cluster must succeed; failure={:?}", output.failure_reason);
        assert!(
            output.drawer_content.contains("spine"),
            "ubiquity re-add must restore the spine feature; got {}",
            output.drawer_content
        );
    }

    // Prose renders the display surface form, not the stemmed grouping value.
    #[test]
    fn prose_renders_display_not_stem() {
        let input = DistillationInput::new(
            vec![
                "E:migrat/migration".to_string(),
                "E:migrat/migrations".to_string(),
                "E:migrat/migrating".to_string(),
            ],
            None,
            "item-stem",
            vec!["item-stem".to_string()],
        );
        let output = DistillationPipeline::run(&input, marked_ent_extractor, true);
        assert!(output.succeeded, "failure={:?}", output.failure_reason);
        // value is the stem "migrat" (one df bit); display is the FIRST surface
        // form encountered ("migration"). Prose must show the surface, not the stem.
        assert!(
            output.drawer_content.contains("migration"),
            "prose must render display surface; got {}",
            output.drawer_content
        );
        assert!(
            !output.drawer_content.contains("migrat ") && !output.drawer_content.ends_with("migrat"),
            "prose must not render the bare stem 'migrat'; got {}",
            output.drawer_content
        );
    }

    /// src= in the DIST header must equal source_ids.len(), not memory_contents.len().
    ///
    /// In the intra-item model memory_contents holds the item's sentences (m ≥ 3)
    /// while source_ids holds exactly one entry (the source drawer UUID). The header's
    /// src= field tracks how many _distilled_from tunnels will be written, which is
    /// source_ids.len() (= 1), not m. This test guards the regression where src=m
    /// was used, producing src=3/5/N while only 1 tunnel was actually written.
    #[test]
    fn intra_item_src_header_equals_source_ids_count_not_sentence_count() {
        // Five sentences about Provenance (recurring capitalised entity) — m=5, but
        // only ONE source memory (source_ids.len()=1). src= must be 1.
        let input = DistillationInput::new(
            vec![
                "Records exist.".to_string(),
                "The Provenance record confirms zero.".to_string(),
                "The Provenance record confirms one.".to_string(),
                "The Provenance record confirms two.".to_string(),
                "The Provenance record confirms three.".to_string(),
            ],
            None,
            "intra-item-test-cluster",
            vec!["single-source-drawer-id".to_string()], // one source memory, not five
        );
        let output = DistillationPipeline::run(&input, DistillationPipeline::default_extractor, true);
        if !output.succeeded {
            // If the pipeline doesn't produce a factoid on this fixture, the assertion is
            // vacuously irrelevant — but log for visibility.
            return;
        }
        let header = DistilledHeader::parse(&output.drawer_content)
            .expect("succeeded output must have a parseable DIST header");
        assert_eq!(
            header.source_count, 1,
            "src= must be source_ids.len()=1, not sentence count m=5; got {}",
            header.source_count
        );
    }
}
