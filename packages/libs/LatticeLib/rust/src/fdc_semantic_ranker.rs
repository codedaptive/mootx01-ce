// fdc_semantic_ranker.rs
//
// Portable integer inference for the sparse FDC semantic-ranker artifact.
// Every byte-level feature, score, hierarchy threshold, and tie-break mirrors
// FDCSemanticRanker.swift so Swift and Rust return identical candidates and
// final FDC codes without a platform ML runtime or floating-point inference.

use std::collections::{BTreeSet, HashMap};

use serde::Deserialize;
use substrate_kernel::sha256;

use crate::fdc_frame::FdcFrame;

const MAGIC: &[u8] = b"FDCSMR1\0";
const FEATURE_SCHEMA: &str = "ascii-word-bigram-affix-fnv1a-v1";
const FNV_OFFSET: u64 = 14_695_981_039_346_656_037;
const FNV_PRIME: u64 = 1_099_511_628_211;
const MAXIMUM_TOKENS: usize = 256;
const MAXIMUM_FEATURES: usize = 1_024;
const AGGREGATE_CANDIDATE_LIMIT: usize = 5;
const MINIMUM_MATCHED_FEATURES: usize = 8;

const STOP_WORDS: &[&str] = &[
    "a", "about", "an", "and", "are", "as", "at", "be", "been", "by", "for", "from", "has", "have",
    "in", "into", "is", "it", "its", "of", "on", "or", "that", "the", "their", "this", "to", "was",
    "were", "with",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FdcSemanticCandidate {
    pub code: String,
    pub score: i64,
    pub matched_features: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FdcSemanticDecision {
    pub code: String,
    pub main_class: String,
    pub score: i64,
    pub runner_up_score: i64,
    pub matched_features: usize,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FdcSemanticMetadata {
    pub version: String,
    #[serde(rename = "feature_schema")]
    pub feature_schema: String,
    #[serde(rename = "feature_count")]
    pub feature_count: usize,
    #[serde(rename = "code_count")]
    pub code_count: usize,
    #[serde(rename = "entry_count")]
    pub entry_count: usize,
    pub codes: Vec<String>,
    pub norms: Vec<i64>,
    #[serde(rename = "model_sha256")]
    pub model_sha256: String,
}

#[derive(Debug, Clone)]
pub struct FdcSemanticRanker {
    pub metadata: FdcSemanticMetadata,
    offsets: Vec<u32>,
    code_indices: Vec<u16>,
    weights: Vec<u8>,
}

#[derive(Debug)]
struct AggregateBucket {
    key: String,
    score: i64,
    count: usize,
}

impl FdcSemanticRanker {
    pub fn from_artifacts(metadata_json: &[u8], model: &[u8]) -> Option<Self> {
        let metadata: FdcSemanticMetadata = serde_json::from_slice(metadata_json).ok()?;
        if metadata.feature_schema != FEATURE_SCHEMA
            || metadata.feature_count == 0
            || metadata.feature_count > 1_048_576
            || !metadata.feature_count.is_power_of_two()
            || metadata.code_count != metadata.codes.len()
            || metadata.code_count != metadata.norms.len()
            || metadata.code_count > u16::MAX as usize
            || metadata.entry_count == 0
            || metadata.entry_count > u32::MAX as usize
            || metadata.norms.iter().any(|norm| *norm <= 0)
            || expected_model_size(metadata.feature_count, metadata.entry_count)
                != Some(model.len())
            || sha256_hex(model) != metadata.model_sha256
        {
            return None;
        }

        let mut cursor = BinaryCursor::new(model);
        if cursor.read_bytes(MAGIC.len())? != MAGIC {
            return None;
        }
        let feature_count = cursor.read_u32()? as usize;
        let code_count = cursor.read_u32()? as usize;
        let entry_count = cursor.read_u32()? as usize;
        if feature_count != metadata.feature_count
            || code_count != metadata.code_count
            || entry_count != metadata.entry_count
        {
            return None;
        }

        let mut offsets = Vec::with_capacity(feature_count + 1);
        for _ in 0..=feature_count {
            offsets.push(cursor.read_u32()?);
        }
        if offsets.first().copied() != Some(0)
            || offsets.last().copied() != Some(entry_count as u32)
            || offsets.windows(2).any(|pair| pair[0] > pair[1])
        {
            return None;
        }

        let mut code_indices = Vec::with_capacity(entry_count);
        for _ in 0..entry_count {
            let value = cursor.read_u16()?;
            if value as usize >= code_count {
                return None;
            }
            code_indices.push(value);
        }
        let weights = cursor.read_bytes(entry_count)?.to_vec();
        if weights.contains(&0) || !cursor.is_at_end() {
            return None;
        }

        Some(Self {
            metadata,
            offsets,
            code_indices,
            weights,
        })
    }

    pub fn rank(&self, text: &str, limit: usize) -> Vec<FdcSemanticCandidate> {
        if limit == 0 {
            return Vec::new();
        }
        let features = features(text, self.metadata.feature_count);
        if features.is_empty() {
            return Vec::new();
        }

        let mut scores = vec![0i64; self.metadata.code_count];
        let mut matched = vec![0usize; self.metadata.code_count];
        for feature in features {
            let start = self.offsets[feature] as usize;
            let end = self.offsets[feature + 1] as usize;
            for index in start..end {
                let code_index = self.code_indices[index] as usize;
                scores[code_index] += self.weights[index] as i64;
                matched[code_index] += 1;
            }
        }

        let mut candidates = Vec::with_capacity(self.metadata.code_count);
        for index in 0..self.metadata.code_count {
            if scores[index] <= 0 {
                continue;
            }
            candidates.push(FdcSemanticCandidate {
                code: self.metadata.codes[index].clone(),
                score: scores[index] * 1_000_000 / self.metadata.norms[index],
                matched_features: matched[index],
            });
        }
        candidates.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| b.matched_features.cmp(&a.matched_features))
                .then_with(|| a.code.cmp(&b.code))
        });
        candidates.truncate(limit);
        candidates
    }

    pub fn hierarchy_decision(&self, text: &str, frame: &FdcFrame) -> Option<FdcSemanticDecision> {
        let candidates = self.rank(text, self.metadata.code_count);
        self.hierarchy_decision_from_candidates(&candidates, frame)
    }

    pub(crate) fn hierarchy_decision_from_candidates(
        &self,
        candidates: &[FdcSemanticCandidate],
        frame: &FdcFrame,
    ) -> Option<FdcSemanticDecision> {
        let top = candidates.first()?;
        if top.matched_features < MINIMUM_MATCHED_FEATURES {
            return None;
        }

        let top_main = main_class(&top.code, frame);
        let second_score = candidates.get(1).map(|item| item.score).unwrap_or(0);
        let dominant_top = ratio_at_least(top.score, second_score, 3, 2);
        let main_buckets = aggregate(candidates, |candidate| {
            Some(main_class(&candidate.code, frame))
        });
        let aggregate_winner = main_buckets.first()?;
        let aggregate_runner_score = main_buckets.get(1).map(|item| item.score).unwrap_or(0);

        let (selected_main, selected_score, selected_runner_score) = if dominant_top {
            (top_main, top.score, second_score)
        } else {
            if !ratio_at_least(aggregate_winner.score, aggregate_runner_score, 6, 5) {
                return None;
            }
            (
                aggregate_winner.key.clone(),
                aggregate_winner.score,
                aggregate_runner_score,
            )
        };

        let selected_candidates: Vec<FdcSemanticCandidate> = candidates
            .iter()
            .filter(|candidate| main_class(&candidate.code, frame) == selected_main)
            .cloned()
            .collect();
        let selected_top = selected_candidates.first().unwrap_or(top);
        let mut selected_code = selected_main.clone();
        let child_buckets = aggregate(&selected_candidates, |candidate| {
            child_on_path(&candidate.code, &selected_main, frame)
        });
        if let Some(child_winner) = child_buckets.first().filter(|item| item.count >= 2) {
            let child_runner_score = child_buckets.get(1).map(|item| item.score).unwrap_or(0);
            let ordinary_dominance = ratio_at_least(child_winner.score, child_runner_score, 4, 3);
            let strong_dominance = ratio_at_least(child_winner.score, child_runner_score, 8, 5);
            let leading_children: Vec<String> = selected_candidates
                .iter()
                .take(2)
                .filter_map(|candidate| child_on_path(&candidate.code, &selected_main, frame))
                .collect();
            let leading_consensus = leading_children.len() == 2
                && leading_children
                    .iter()
                    .all(|child| child == &child_winner.key);
            if ordinary_dominance && (leading_consensus || strong_dominance) {
                selected_code = child_winner.key.clone();
            }
        }

        Some(FdcSemanticDecision {
            code: selected_code,
            main_class: selected_main,
            score: selected_score,
            runner_up_score: selected_runner_score,
            matched_features: selected_top.matched_features,
        })
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    sha256::hash(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn expected_model_size(feature_count: usize, entry_count: usize) -> Option<usize> {
    20usize
        .checked_add(feature_count.checked_add(1)?.checked_mul(4)?)?
        .checked_add(entry_count.checked_mul(3)?)
}

fn aggregate<F>(candidates: &[FdcSemanticCandidate], key: F) -> Vec<AggregateBucket>
where
    F: Fn(&FdcSemanticCandidate) -> Option<String>,
{
    let mut scores: HashMap<String, Vec<i64>> = HashMap::new();
    for candidate in candidates {
        if let Some(bucket) = key(candidate) {
            scores.entry(bucket).or_default().push(candidate.score);
        }
    }
    let mut buckets: Vec<AggregateBucket> = scores
        .into_iter()
        .map(|(key, mut values)| {
            values.sort_by(|a, b| b.cmp(a));
            AggregateBucket {
                key,
                score: values.iter().take(AGGREGATE_CANDIDATE_LIMIT).sum(),
                count: values.len(),
            }
        })
        .collect();
    buckets.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.key.cmp(&b.key)));
    buckets
}

fn main_class(code: &str, frame: &FdcFrame) -> String {
    if is_main_class(code) {
        return code.to_owned();
    }
    frame
        .ancestors(code)
        .into_iter()
        .rev()
        .find(|ancestor| is_main_class(ancestor))
        .unwrap_or_else(|| "000".to_owned())
}

fn child_on_path(code: &str, node: &str, frame: &FdcFrame) -> Option<String> {
    let mut path = frame.ancestors(code);
    path.push(code.to_owned());
    let index = path.iter().position(|entry| entry == node)?;
    path.get(index + 1).cloned()
}

fn is_main_class(code: &str) -> bool {
    let bytes = code.as_bytes();
    bytes.len() == 3 && bytes.iter().all(u8::is_ascii_digit) && bytes[1] == b'0' && bytes[2] == b'0'
}

fn ratio_at_least(winner: i64, runner: i64, numerator: i64, denominator: i64) -> bool {
    winner > 0 && (runner == 0 || winner * denominator >= runner * numerator)
}

fn features(text: &str, dimension: usize) -> Vec<usize> {
    if dimension == 0 || !dimension.is_power_of_two() {
        return Vec::new();
    }
    let tokens = ascii_tokens(text);
    let mut values = BTreeSet::new();
    let mut previous: Option<Vec<u8>> = None;
    for token in tokens.into_iter().take(MAXIMUM_TOKENS) {
        if previous.as_ref() == Some(&token) {
            continue;
        }
        insert_feature(b"w:", &token, dimension, &mut values);
        for length in 3..=5 {
            if token.len() < length {
                continue;
            }
            let prefix = format!("p{length}:");
            let suffix = format!("s{length}:");
            insert_feature(prefix.as_bytes(), &token[..length], dimension, &mut values);
            insert_feature(
                suffix.as_bytes(),
                &token[token.len() - length..],
                dimension,
                &mut values,
            );
        }
        if let Some(previous_token) = &previous {
            let mut bigram = previous_token.clone();
            bigram.push(b'|');
            bigram.extend_from_slice(&token);
            insert_feature(b"b:", &bigram, dimension, &mut values);
        }
        previous = Some(token);
        if values.len() >= MAXIMUM_FEATURES {
            break;
        }
    }
    values.into_iter().take(MAXIMUM_FEATURES).collect()
}

fn ascii_tokens(text: &str) -> Vec<Vec<u8>> {
    let mut tokens = Vec::new();
    let mut current = Vec::new();
    for byte in text.as_bytes() {
        let value = match byte {
            b'A'..=b'Z' => Some(byte + 32),
            b'a'..=b'z' | b'0'..=b'9' => Some(*byte),
            _ => None,
        };
        if let Some(value) = value {
            current.push(value);
        } else if !current.is_empty() {
            append_token(&mut tokens, &mut current);
        }
    }
    if !current.is_empty() {
        append_token(&mut tokens, &mut current);
    }
    tokens
}

fn append_token(tokens: &mut Vec<Vec<u8>>, current: &mut Vec<u8>) {
    let token = std::mem::take(current);
    let is_stop_word = std::str::from_utf8(&token)
        .ok()
        .map(|value| STOP_WORDS.contains(&value))
        .unwrap_or(false);
    if !is_stop_word {
        tokens.push(token);
    }
}

fn insert_feature(prefix: &[u8], value: &[u8], dimension: usize, into: &mut BTreeSet<usize>) {
    let mut hash = FNV_OFFSET;
    for byte in prefix.iter().chain(value) {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    into.insert((hash as usize) & (dimension - 1));
}

struct BinaryCursor<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> BinaryCursor<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, offset: 0 }
    }

    fn is_at_end(&self) -> bool {
        self.offset == self.data.len()
    }

    fn read_bytes(&mut self, count: usize) -> Option<&'a [u8]> {
        let end = self.offset.checked_add(count)?;
        let bytes = self.data.get(self.offset..end)?;
        self.offset = end;
        Some(bytes)
    }

    fn read_u16(&mut self) -> Option<u16> {
        let bytes: [u8; 2] = self.read_bytes(2)?.try_into().ok()?;
        Some(u16::from_le_bytes(bytes))
    }

    fn read_u32(&mut self) -> Option<u32> {
        let bytes: [u8; 4] = self.read_bytes(4)?.try_into().ok()?;
        Some(u32::from_le_bytes(bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeated_tokens_collapse_to_the_same_features() {
        assert_eq!(
            features("mortgage lender credit", 16_384),
            features("mortgage mortgage lender credit", 16_384)
        );
    }

    #[test]
    fn non_ascii_bytes_are_token_boundaries() {
        assert_eq!(
            features("caf biology", 16_384),
            features("caf\u{e9} biology", 16_384)
        );
    }

    #[test]
    fn feature_extraction_caps_long_inputs() {
        let prefix = (0..300)
            .map(|index| format!("term{index}"))
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(
            features(&prefix, 16_384),
            features(&format!("{prefix} ignoredtail"), 16_384)
        );
    }

    #[test]
    fn artifact_hash_mismatch_fails_closed() {
        const METADATA: &[u8] =
            include_bytes!("../../Sources/LatticeLib/Resources/FDCSemanticRanker.json");
        let mut model =
            include_bytes!("../../Sources/LatticeLib/Resources/FDCSemanticRanker.bin").to_vec();
        assert!(FdcSemanticRanker::from_artifacts(METADATA, &model).is_some());
        let last = model.len() - 1;
        model[last] ^= 1;
        assert!(FdcSemanticRanker::from_artifacts(METADATA, &model).is_none());
    }
}
