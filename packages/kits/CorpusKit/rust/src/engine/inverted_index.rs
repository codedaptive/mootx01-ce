//! Weighted inverted index with item-id-ordered posting lists, WAND and Block-Max WAND
//! (BMW) exact top-k retrieval.
//!
//! Lane D — Sparse Engine (SPLADE generalization).
//! Retrieval algorithms reference §2 is the authoritative spec.
//!
//! Design contract:
//! - Postings in each term list are sorted by item_id ascending (WAND
//!   pivoting invariant, §2.1).
//! - All impacts are i32 quantized integers (QUANT_SCALE=100,
//!   round-half-to-even). No float arithmetic on the query path (§2.2).
//! - WAND and BMW both return the EXACT same top-k as exhaustive DAAT
//!   full-scan. Interchangeable in result (§2.5).
//! - Universal tie-break: equal scores → smaller item_id wins (§0.3).
//!
//! Parity: Swift twin in CorpusKit/Sources/CorpusKit/Engine/InvertedIndex.swift.

use crate::engine::sparse_types::ImpactPosting;
use crate::engine::sparse_types::SparseHit;
use std::collections::HashMap;

/// Pinned constant from §2.2: QUANT_SCALE=100.
pub const QUANT_SCALE: i32 = 100;

/// Block size for Block-Max WAND. Pinned config for conformance.
pub const BLOCK_SIZE: usize = 128;

// MARK: — Posting cursor (internal)

/// Internal cursor over a posting list for WAND iteration.
#[derive(Debug, Clone)]
struct PostingCursor {
    term_id: u32,
    /// Global max_impact * query_weight (term upper bound for WAND).
    term_ub: i32,
    query_weight: i32,
    postings: Vec<ImpactPosting>,
    /// Per-block max impacts.
    block_max: Vec<i32>,
    /// Per-block last item_id (for BMW skip).
    block_last_id: Vec<String>,
    position: usize,
}

impl PostingCursor {
    fn current_id(&self) -> Option<&str> {
        self.postings.get(self.position).map(|p| p.item_id.as_str())
    }

    fn is_exhausted(&self) -> bool {
        self.position >= self.postings.len()
    }

    fn current_impact(&self) -> i32 {
        self.postings[self.position].impact
    }

    fn advance(&mut self) {
        self.position += 1;
    }

    /// Seek to the first posting with item_id >= target.
    fn seek(&mut self, target: &str) {
        while self.position < self.postings.len() && self.postings[self.position].item_id.as_str() < target {
            self.position += 1;
        }
    }

    /// Block-max upper-bound contribution at the given item_id.
    fn block_max_contribution(&self, item_id: &str) -> i64 {
        for (block_idx, last_id) in self.block_last_id.iter().enumerate() {
            if last_id.as_str() >= item_id {
                let bm = self.block_max.get(block_idx).copied().unwrap_or(0);
                return i64::from(bm) * i64::from(self.query_weight);
            }
        }
        0
    }
}

// MARK: — Algorithm selector

/// Algorithm choice for `InvertedIndex::top_k`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Algorithm {
    /// WAND with global max-impact upper bounds (§2.3).
    Wand,
    /// Block-Max WAND with per-block tighter upper bounds (§2.7).
    BlockMaxWand,
}

// MARK: — InvertedIndex

/// Weighted impact-ordered inverted index.
///
/// All impacts are i32 (quantized). All scoring arithmetic is integer-only.
/// Bit-identical to the Swift twin on shared conformance vectors.
pub struct InvertedIndex {
    /// term_id → sorted postings (item_id ascending).
    sorted_postings: HashMap<u32, Vec<ImpactPosting>>,
    /// term_id → global max impact.
    global_max_impact: HashMap<u32, i32>,
    /// term_id → per-block max impacts.
    block_max_impacts: HashMap<u32, Vec<i32>>,
    /// term_id → per-block last item_id.
    block_last_ids: HashMap<u32, Vec<String>>,
    /// Total document count (stored for persistence).
    pub num_docs: usize,
}

impl InvertedIndex {
    /// Build an inverted index from pre-computed impact postings.
    ///
    /// Postings need NOT be pre-sorted; this constructor sorts them.
    pub fn new(postings: HashMap<u32, Vec<ImpactPosting>>, num_docs: usize) -> Self {
        // Sort each posting list by item_id ascending.
        let mut sorted: HashMap<u32, Vec<ImpactPosting>> = HashMap::with_capacity(postings.len());
        let mut max_impact: HashMap<u32, i32> = HashMap::with_capacity(postings.len());
        for (term, mut posts) in postings {
            posts.sort_by(|a, b| a.item_id.cmp(&b.item_id));
            let mx = posts.iter().map(|p| p.impact).max().unwrap_or(0);
            max_impact.insert(term, mx);
            sorted.insert(term, posts);
        }

        let block_max_impacts = Self::build_block_max_impacts(&sorted);
        let block_last_ids = Self::build_block_last_ids(&sorted);

        InvertedIndex {
            sorted_postings: sorted,
            global_max_impact: max_impact,
            block_max_impacts,
            block_last_ids,
            num_docs,
        }
    }

    fn build_block_max_impacts(sorted: &HashMap<u32, Vec<ImpactPosting>>) -> HashMap<u32, Vec<i32>> {
        let mut result = HashMap::with_capacity(sorted.len());
        for (term, posts) in sorted {
            let mut blocks = Vec::new();
            let mut i = 0;
            while i < posts.len() {
                let end = (i + BLOCK_SIZE).min(posts.len());
                let bm = posts[i..end].iter().map(|p| p.impact).max().unwrap_or(0);
                blocks.push(bm);
                i = end;
            }
            result.insert(*term, blocks);
        }
        result
    }

    fn build_block_last_ids(sorted: &HashMap<u32, Vec<ImpactPosting>>) -> HashMap<u32, Vec<String>> {
        let mut result = HashMap::with_capacity(sorted.len());
        for (term, posts) in sorted {
            let mut ids = Vec::new();
            let mut i = 0;
            while i < posts.len() {
                let end = (i + BLOCK_SIZE).min(posts.len());
                ids.push(posts[end - 1].item_id.clone());
                i = end;
            }
            result.insert(*term, ids);
        }
        result
    }

    // MARK: — Public API

    /// Exact top-k retrieval, score descending, item_id ascending on ties.
    ///
    /// - `query`: (term_id, query_weight: i32) pairs, already quantized.
    /// - `k`: number of results.
    /// - `algorithm`: `Wand` or `BlockMaxWand`. Results are identical.
    pub fn top_k(&self, query: &[(u32, i32)], k: usize, algorithm: Algorithm) -> Vec<SparseHit> {
        if k == 0 || query.is_empty() {
            return Vec::new();
        }
        let mut cursors = self.build_cursors(query);
        if cursors.is_empty() {
            return Vec::new();
        }

        let raw = match algorithm {
            Algorithm::Wand => self.run_wand(&mut cursors, k),
            Algorithm::BlockMaxWand => self.run_bmw(&mut cursors, k),
        };

        // Convert integer scores to SparseHit float surface.
        raw.into_iter()
            .map(|(item_id, score)| SparseHit {
                item_id,
                impact: score as f32 / QUANT_SCALE as f32,
            })
            .collect()
    }

    /// Exhaustive DAAT full-scan for conformance gating.
    ///
    /// Scores every item in at least one query term's posting list.
    /// Used in tests to verify WAND/BMW correctness.
    pub fn exhaustive_scan(&self, query: &[(u32, i32)], k: usize) -> Vec<SparseHit> {
        if k == 0 || query.is_empty() {
            return Vec::new();
        }
        let mut scores: HashMap<&str, i64> = HashMap::new();
        for (term_id, qw) in query {
            let Some(posts) = self.sorted_postings.get(term_id) else { continue };
            for posting in posts {
                *scores.entry(posting.item_id.as_str()).or_insert(0) +=
                    i64::from(*qw) * i64::from(posting.impact);
            }
        }
        if scores.is_empty() {
            return Vec::new();
        }

        // Sort by score DESC, item_id ASC.
        let mut sorted: Vec<(&str, i64)> = scores.into_iter().collect();
        sorted.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
        sorted.truncate(k);

        sorted
            .into_iter()
            .map(|(item_id, score)| SparseHit {
                item_id: item_id.to_owned(),
                impact: score as f32 / QUANT_SCALE as f32,
            })
            .collect()
    }

    // MARK: — Build cursors

    fn build_cursors(&self, query: &[(u32, i32)]) -> Vec<PostingCursor> {
        let mut cursors = Vec::new();
        for (term_id, qw) in query {
            let Some(posts) = self.sorted_postings.get(term_id) else { continue };
            if posts.is_empty() { continue }
            let max_imp = self.global_max_impact.get(term_id).copied().unwrap_or(0);
            // Clamp to i32::MAX to prevent overflow.
            let ub = (i64::from(max_imp) * i64::from(*qw)).min(i64::from(i32::MAX)) as i32;
            let bm = self.block_max_impacts.get(term_id).cloned().unwrap_or_default();
            let bl = self.block_last_ids.get(term_id).cloned().unwrap_or_default();
            cursors.push(PostingCursor {
                term_id: *term_id,
                term_ub: ub,
                query_weight: *qw,
                postings: posts.clone(),
                block_max: bm,
                block_last_id: bl,
                position: 0,
            });
        }
        cursors
    }

    // MARK: — WAND (§2.3)

    fn run_wand(&self, cursors: &mut Vec<PostingCursor>, k: usize) -> Vec<(String, i64)> {
        let mut heap = TopKHeap::new(k);
        let mut threshold: i64 = 0;

        loop {
            // 1. Drop exhausted, sort by (current_id ASC, term_id ASC).
            cursors.retain(|c| !c.is_exhausted());
            if cursors.is_empty() { break; }
            cursors.sort_by(|a, b| {
                let aid = a.current_id().unwrap_or("");
                let bid = b.current_id().unwrap_or("");
                aid.cmp(bid).then(a.term_id.cmp(&b.term_id))
            });

            // 2. Find pivot.
            let Some((pivot_idx, pivot_id)) = Self::find_pivot(cursors, threshold) else { break };

            // 3. Alignment check.
            if cursors[0].current_id() == Some(pivot_id.as_str()) {
                let score = Self::score_aligned(cursors, &pivot_id);
                heap.offer(pivot_id, score, &mut threshold);
            } else {
                let pick = Self::choose_advance(cursors, pivot_idx, &pivot_id);
                cursors[pick].seek(&pivot_id);
            }
        }

        heap.sorted()
    }

    // MARK: — Block-Max WAND (§2.7)

    fn run_bmw(&self, cursors: &mut Vec<PostingCursor>, k: usize) -> Vec<(String, i64)> {
        let mut heap = TopKHeap::new(k);
        let mut threshold: i64 = 0;

        loop {
            cursors.retain(|c| !c.is_exhausted());
            if cursors.is_empty() { break; }
            cursors.sort_by(|a, b| {
                let aid = a.current_id().unwrap_or("");
                let bid = b.current_id().unwrap_or("");
                aid.cmp(bid).then(a.term_id.cmp(&b.term_id))
            });

            let Some((pivot_idx, pivot_id)) = Self::find_pivot(cursors, threshold) else { break };

            // BMW block-max refinement.
            let block_ub = Self::compute_block_ub(cursors, pivot_idx, &pivot_id);
            if block_ub <= threshold {
                // Block cannot beat threshold: seek past min block_last_id.
                let next_target = Self::next_block_target(cursors, pivot_idx, &pivot_id);
                let pick = Self::choose_advance(cursors, pivot_idx, &pivot_id);
                cursors[pick].seek(&next_target);
                continue;
            }

            if cursors[0].current_id() == Some(pivot_id.as_str()) {
                let score = Self::score_aligned(cursors, &pivot_id);
                heap.offer(pivot_id, score, &mut threshold);
            } else {
                let pick = Self::choose_advance(cursors, pivot_idx, &pivot_id);
                cursors[pick].seek(&pivot_id);
            }
        }

        heap.sorted()
    }

    // MARK: — Shared helpers

    /// Find the pivot: smallest prefix index where cumulative UB > threshold.
    fn find_pivot(cursors: &[PostingCursor], threshold: i64) -> Option<(usize, String)> {
        let mut acc: i64 = 0;
        for (i, cursor) in cursors.iter().enumerate() {
            let Some(cid) = cursor.current_id() else { continue };
            acc += i64::from(cursor.term_ub);
            if acc > threshold {
                return Some((i, cid.to_owned()));
            }
        }
        None
    }

    /// Score pivot_id: sum query_weight * impact for all lists at pivot_id;
    /// advance those lists.
    fn score_aligned(cursors: &mut [PostingCursor], pivot_id: &str) -> i64 {
        let mut score: i64 = 0;
        for cursor in cursors.iter_mut() {
            if cursor.current_id() == Some(pivot_id) {
                score += i64::from(cursor.query_weight) * i64::from(cursor.current_impact());
                cursor.advance();
            }
        }
        score
    }

    /// Among lists before pivot with current_id < pivot_id, return the index
    /// with the smallest term_id (PIN: §2.4.3).
    fn choose_advance(cursors: &[PostingCursor], pivot_idx: usize, pivot_id: &str) -> usize {
        let mut best_idx = 0usize;
        let mut found = false;
        for i in 0..pivot_idx {
            let Some(cid) = cursors[i].current_id() else { continue };
            if cid >= pivot_id { continue; }
            if !found || cursors[i].term_id < cursors[best_idx].term_id {
                best_idx = i;
                found = true;
            }
        }
        if found { best_idx } else { 0 }
    }

    /// BMW: compute block-level upper bound at pivot_id.
    fn compute_block_ub(cursors: &[PostingCursor], pivot_idx: usize, pivot_id: &str) -> i64 {
        let mut ub: i64 = 0;
        for i in 0..=pivot_idx {
            let Some(cid) = cursors[i].current_id() else { continue };
            if cid > pivot_id { continue; }
            ub += cursors[i].block_max_contribution(pivot_id);
        }
        ub
    }

    /// BMW: 1 + min block_last_id among involved lists at pivot.
    fn next_block_target(cursors: &[PostingCursor], pivot_idx: usize, pivot_id: &str) -> String {
        let mut min_last: Option<String> = None;
        for i in 0..=pivot_idx {
            let Some(cid) = cursors[i].current_id() else { continue };
            if cid > pivot_id { continue; }
            for last in &cursors[i].block_last_id {
                if last.as_str() >= pivot_id {
                    if min_last.as_deref().map_or(true, |m: &str| last.as_str() < m) {
                        min_last = Some(last.clone());
                    }
                    break;
                }
            }
        }
        match min_last {
            Some(last) => {
                // Append U+0001 to safely exceed last.
                let mut next = last;
                next.push('\u{0001}');
                next
            }
            None => {
                let mut next = pivot_id.to_owned();
                next.push('\u{0001}');
                next
            }
        }
    }
}

// MARK: — TopKHeap (internal)

/// Bounded min-heap for WAND top-k collection.
///
/// Keeps k best (score DESC, item_id ASC) entries. Root = weakest candidate
/// (smallest score; on tie, largest item_id).
struct TopKHeap {
    entries: Vec<(String, i64)>,
    capacity: usize,
}

impl TopKHeap {
    fn new(capacity: usize) -> Self {
        TopKHeap {
            entries: Vec::with_capacity(capacity + 1),
            capacity,
        }
    }

    fn min_score(&self) -> i64 {
        self.entries.first().map(|(_, s)| *s).unwrap_or(0)
    }

    /// True if (score, item_id) would enter the top-k.
    fn would_enter(&self, score: i64, item_id: &str, threshold: i64) -> bool {
        if self.entries.len() < self.capacity { return true; }
        if score > threshold { return true; }
        if score == threshold {
            // Replace if this id is smaller than the weakest id at that score.
            let worst_id = self.entries.iter()
                .filter(|(_, s)| *s == score)
                .map(|(id, _)| id.as_str())
                .max()
                .unwrap_or("");
            return item_id < worst_id;
        }
        false
    }

    fn offer(&mut self, item_id: String, score: i64, threshold: &mut i64) {
        if self.entries.len() < self.capacity {
            self.entries.push((item_id, score));
            let last = self.entries.len() - 1;
            self.sift_up(last);
            if self.entries.len() == self.capacity {
                *threshold = self.min_score();
            }
        } else if self.would_enter(score, &item_id, *threshold) {
            self.entries[0] = (item_id, score);
            self.sift_down(0);
            *threshold = self.min_score();
        }
    }

    /// Return entries sorted (score DESC, item_id ASC).
    fn sorted(mut self) -> Vec<(String, i64)> {
        self.entries.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        self.entries
    }

    // Min-heap on (score ASC, id DESC) → root = weakest.
    fn is_weaker(a: &(String, i64), b: &(String, i64)) -> bool {
        if a.1 != b.1 { return a.1 < b.1; }
        a.0 > b.0  // larger id = weaker
    }

    fn sift_up(&mut self, mut i: usize) {
        while i > 0 {
            let parent = (i - 1) / 2;
            if Self::is_weaker(&self.entries[i], &self.entries[parent]) {
                self.entries.swap(i, parent);
                i = parent;
            } else { break; }
        }
    }

    fn sift_down(&mut self, mut i: usize) {
        let n = self.entries.len();
        loop {
            let l = 2 * i + 1;
            let r = 2 * i + 2;
            let mut weakest = i;
            if l < n && Self::is_weaker(&self.entries[l], &self.entries[weakest]) { weakest = l; }
            if r < n && Self::is_weaker(&self.entries[r], &self.entries[weakest]) { weakest = r; }
            if weakest == i { break; }
            self.entries.swap(i, weakest);
            i = weakest;
        }
    }
}
