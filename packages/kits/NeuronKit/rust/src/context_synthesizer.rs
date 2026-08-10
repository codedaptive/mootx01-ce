//! ContextSynthesizer Rust version. Pure synthesis over a recall page —
//! reads only, produces a `ContextDocument` matching the Swift
//! `ContextSynthesisEngine` byte-for-byte against shared vectors.
//!
//! Per NEURONKIT_SPEC § 4.2 the synthesizer is reads-only and writes
//! nothing to the substrate (C-9). The Rust version mirrors this by
//! exposing only a pure function over a recall page; no estate
//! handle, no IO, no clocks.

use crate::hybrid_recall::{DrawerRow, RecallPage};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Ephemeral context document. Mirror of Swift's `ContextDocument`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ContextDocument {
    pub summary: String,
    pub patterns: Vec<String>,
    pub success_rate: f32,
    pub average_reward: f32,
    pub recommendations: Vec<String>,
    pub key_insights: Vec<String>,
}

/// Optional row-level metadata the Rust engine consumes alongside
/// `DrawerRow`. The Swift version reads these straight off
/// `LocusKit.Drawer`; the Rust engine accepts them as a parallel
/// vector so the version can be exercised without the full LocusKit
/// Rust type. Empty (or shorter than `rows`) means "treat as default
/// (active state, default wing/room)".
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DrawerRowMeta {
    /// Parent node id — the node-tree anchor the summary names. The Swift engine
    /// reads `LocusKit.Drawer.parentNodeId`; the Rust version accepts it as
    /// parallel metadata. Drives `make_summary`'s "dominant node {id}".
    pub parent_node_id: String,
    /// Wing/room remain as vestigial metadata (the summary no longer reads them
    /// after the node-tree migration; kept for parity with the Swift fixture,
    /// which still carries them).
    pub wing: String,
    pub room: String,
    /// Whether the drawer is "currently believed" per the LocusKit
    /// adjective-state cluster. The Swift engine reads
    /// `drawer.isCurrentlyBelieved`; the Rust version accepts the
    /// pre-computed boolean.
    pub is_currently_believed: bool,
}

impl Default for DrawerRowMeta {
    fn default() -> Self {
        Self {
            parent_node_id: "(no node)".to_string(),
            wing: "(no wing)".to_string(),
            room: "(no room)".to_string(),
            is_currently_believed: true,
        }
    }
}

/// Synthesize a `ContextDocument` from a recall page and the
/// per-row metadata vector. The metadata vector may be empty, in
/// which case every row is treated with `DrawerRowMeta::default()`.
///
/// `max_key_insights` bounds the excerpted rows. The historical digest
/// bound is 3. A cue-grounded caller passes its post-rank cap so every
/// ranked survivor is VISIBLE in the document — trial 3 measured 30/35
/// misses with the answer drawer ranked into the capped set but invisible
/// behind the 3-row excerpt. Twin of Swift
/// `ContextSynthesisEngine.synthesize(page:maxKeyInsights:)`.
pub fn synthesize(
    page: &RecallPage,
    meta: &[DrawerRowMeta],
    max_key_insights: usize,
) -> ContextDocument {
    let rows = &page.rows;
    if rows.is_empty() {
        return ContextDocument {
            summary: String::new(),
            patterns: Vec::new(),
            success_rate: 0.0,
            average_reward: 0.0,
            recommendations: Vec::new(),
            key_insights: Vec::new(),
        };
    }

    let summary = make_summary(rows, meta);
    let patterns = top_patterns(rows, 5);
    let success_rate = currently_believed_rate(rows, meta);
    let average_reward: f32 = 0.0; // No reward field on DrawerRow at v0.1 — see spec note.
    let recommendations = make_recommendations(&patterns);
    let key_insights = make_key_insights(rows, max_key_insights.max(1));

    ContextDocument {
        summary,
        patterns,
        success_rate,
        average_reward,
        recommendations,
        key_insights,
    }
}

fn meta_or_default(meta: &[DrawerRowMeta], idx: usize) -> DrawerRowMeta {
    meta.get(idx).cloned().unwrap_or_default()
}

/// One-line summary naming row count and the dominant parent node. Stable
/// across runs. Mirrors Swift `ContextSynthesisEngine.makeSummary`, which reads
/// `Drawer.parentNodeId` (node-tree anchor) — not wing/room.
pub fn make_summary(rows: &[DrawerRow], meta: &[DrawerRowMeta]) -> String {
    let count = rows.len();
    let nodes: Vec<String> = (0..rows.len())
        .map(|i| meta_or_default(meta, i).parent_node_id)
        .collect();
    let top_node = most_frequent(&nodes).unwrap_or_else(|| "(no node)".to_string());
    format!("{} drawers; dominant node {}.", count, top_node)
}

/// Standard English stopwords excluded from pattern extraction. High-frequency
/// function words and date literals provide no semantic signal and would
/// otherwise dominate the pattern list when present in a corpus.
///
/// Mirrors the Swift `ContextSynthesisEngine.stopwords` set byte-for-byte so
/// conformance test vectors produce identical output on both ports.
const STOPWORDS: &[&str] = &[
    "this", "that", "with", "from", "they", "them", "their", "there",
    "were", "have", "been", "will", "would", "could", "should", "about",
    "when", "then", "than", "also", "into", "your", "more", "some",
    "what", "which", "these", "those", "just", "like", "over", "such",
    "only", "very", "even", "most", "both", "each", "here", "after",
    "well", "back", "much", "many", "make", "time", "know", "take",
    "long", "made", "come", "want", "used", "same", "need",
];

/// True when `token` is a bare 4-digit year (1000–2999) or a pure numeric
/// string — neither carries semantic meaning as a pattern. Mirrors Swift
/// `ContextSynthesisEngine.isBareYearOrNumeric(_:)`.
///
/// Uses `char::is_numeric()` (Unicode numeric category: digits, superscripts,
/// fractions, circled numerals, ...) to match Swift's `Character.isNumber`,
/// which is the Unicode general category "Number". Using `is_ascii_digit()`
/// (0-9 only) would silently pass through Unicode numeric tokens that Swift
/// filters, causing cross-port divergence on non-ASCII input. (NK-3 planned hardening)
fn is_bare_year_or_numeric(token: &str) -> bool {
    if !token.chars().all(|c| c.is_numeric()) {
        return false;
    }
    // All-numeric strings of any length are pure numeric — exclude.
    true
}

/// Top-N patterns. Frequency descending, ties broken by first
/// appearance, final tiebreak by token string. Identical ordering
/// to Swift.
///
/// Excludes stopwords and bare numeric strings (including years)
/// so high-frequency function words and date literals do not dominate
/// the pattern list. Mirrors Swift `ContextSynthesisEngine.topPatterns`.
pub fn top_patterns(rows: &[DrawerRow], max_count: usize) -> Vec<String> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut first_seen: BTreeMap<String, usize> = BTreeMap::new();
    let mut order = 0usize;
    for row in rows {
        for token in tokens(&row.content) {
            if token.chars().count() < 4 {
                continue;
            }
            // Skip stopwords and bare numeric strings (including years).
            if STOPWORDS.contains(&token.as_str()) || is_bare_year_or_numeric(&token) {
                continue;
            }
            *counts.entry(token.clone()).or_insert(0) += 1;
            first_seen.entry(token.clone()).or_insert_with(|| {
                let v = order;
                order += 1;
                v
            });
        }
    }
    let mut keys: Vec<String> = counts.keys().cloned().collect();
    keys.sort_by(|lhs, rhs| {
        let cl = counts.get(lhs).copied().unwrap_or(0);
        let cr = counts.get(rhs).copied().unwrap_or(0);
        if cl != cr {
            return cr.cmp(&cl);
        }
        let fl = first_seen.get(lhs).copied().unwrap_or(usize::MAX);
        let fr = first_seen.get(rhs).copied().unwrap_or(usize::MAX);
        if fl != fr {
            return fl.cmp(&fr);
        }
        lhs.cmp(rhs)
    });
    keys.into_iter().take(max_count).collect()
}

/// Fraction of rows whose meta marks them "currently believed".
/// Treats missing meta as default (true).
pub fn currently_believed_rate(rows: &[DrawerRow], meta: &[DrawerRowMeta]) -> f32 {
    if rows.is_empty() {
        return 0.0;
    }
    let count = (0..rows.len())
        .filter(|&i| meta_or_default(meta, i).is_currently_believed)
        .count();
    count as f32 / rows.len() as f32
}

/// Recommendations from the top patterns; neutral fallback if none.
pub fn make_recommendations(patterns: &[String]) -> Vec<String> {
    if patterns.is_empty() {
        return vec![
            "No dominant pattern detected; consider broadening the recall frame.".to_string(),
        ];
    }
    patterns
        .iter()
        .map(|p| format!("Explore further evidence about '{}'.", p))
        .collect()
}

/// First-line excerpts from up to `max_count` rows.
pub fn make_key_insights(rows: &[DrawerRow], max_count: usize) -> Vec<String> {
    rows.iter()
        .take(max_count)
        .map(|row| match row.content.find('\n') {
            Some(idx) => row.content[..idx].to_string(),
            None => row.content.clone(),
        })
        .collect()
}

/// Most frequent element with ties broken by first appearance.
fn most_frequent(values: &[String]) -> Option<String> {
    if values.is_empty() {
        return None;
    }
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut first_seen: BTreeMap<String, usize> = BTreeMap::new();
    let mut order = 0usize;
    for v in values {
        *counts.entry(v.clone()).or_insert(0) += 1;
        first_seen.entry(v.clone()).or_insert_with(|| {
            let cur = order;
            order += 1;
            cur
        });
    }
    let mut best: Option<(String, usize, usize)> = None;
    for (k, c) in &counts {
        let fs = first_seen.get(k).copied().unwrap_or(usize::MAX);
        match &best {
            None => best = Some((k.clone(), *c, fs)),
            Some((_, bc, bfs)) => {
                if c > bc || (c == bc && fs < *bfs) {
                    best = Some((k.clone(), *c, fs));
                }
            }
        }
    }
    best.map(|(k, _, _)| k)
}

/// Lowercase alphanumeric tokens. Locale-free; identical to Swift's
/// `tokens` over ASCII conformance vectors.
pub fn tokens(s: &str) -> Vec<String> {
    let lower = s.to_lowercase();
    lower
        .split(|c: char| !(c.is_alphabetic() || c.is_numeric()))
        .filter(|t| !t.is_empty())
        .map(String::from)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(content: &str) -> DrawerRow {
        DrawerRow {
            id: format!("id-{}", content.len()),
            content: content.to_string(),
        }
    }

    fn meta(wing: &str, room: &str, believed: bool) -> DrawerRowMeta {
        DrawerRowMeta {
            parent_node_id: "(no node)".to_string(),
            wing: wing.to_string(),
            room: room.to_string(),
            is_currently_believed: believed,
        }
    }

    fn meta_node(node: &str) -> DrawerRowMeta {
        DrawerRowMeta {
            parent_node_id: node.to_string(),
            ..DrawerRowMeta::default()
        }
    }

    #[test]
    fn empty_page_produces_empty_document() {
        let page = RecallPage {
            rows: vec![],
            page_index: 0,
            is_last: true,
        };
        let doc = synthesize(&page, &[], 3);
        assert_eq!(doc.summary, "");
        assert!(doc.patterns.is_empty());
        assert_eq!(doc.success_rate, 0.0);
        assert_eq!(doc.average_reward, 0.0);
        assert!(doc.recommendations.is_empty());
        assert!(doc.key_insights.is_empty());
    }

    #[test]
    fn summary_names_count_and_dominant_node() {
        let rows = vec![row("a"), row("b"), row("c")];
        let m = vec![
            meta_node("node-x"),
            meta_node("node-x"),
            meta_node("node-y"),
        ];
        let page = RecallPage {
            rows,
            page_index: 0,
            is_last: true,
        };
        let doc = synthesize(&page, &m, 3);
        assert_eq!(doc.summary, "3 drawers; dominant node node-x.");
    }

    #[test]
    fn patterns_rank_by_frequency_then_first_seen() {
        let rows = vec![
            row("carbon organic compounds"),
            row("organic chemistry carbon"),
            row("physics waves photons"),
        ];
        let page = RecallPage {
            rows,
            page_index: 0,
            is_last: true,
        };
        let doc = synthesize(&page, &[], 3);
        assert_eq!(
            doc.patterns,
            vec!["carbon", "organic", "compounds", "chemistry", "physics"]
        );
    }

    #[test]
    fn recommendations_match_pattern_count() {
        let rows = vec![row("alpha beta gamma delta")];
        let page = RecallPage {
            rows,
            page_index: 0,
            is_last: true,
        };
        let doc = synthesize(&page, &[], 3);
        assert_eq!(doc.recommendations.len(), doc.patterns.len());
    }

    #[test]
    fn no_pattern_produces_neutral_recommendation() {
        let rows = vec![row("a bb ccc")];
        let page = RecallPage {
            rows,
            page_index: 0,
            is_last: true,
        };
        let doc = synthesize(&page, &[], 3);
        assert!(doc.patterns.is_empty());
        assert_eq!(doc.recommendations.len(), 1);
        assert!(doc.recommendations[0].contains("broadening the recall frame"));
    }

    #[test]
    fn key_insights_take_first_line_up_to_three_rows() {
        let rows = vec![
            row("line one\nbody body"),
            row("single line"),
            row("three\nthree body"),
            row("four — should not appear"),
        ];
        let page = RecallPage {
            rows,
            page_index: 0,
            is_last: true,
        };
        let doc = synthesize(&page, &[], 3);
        assert_eq!(doc.key_insights, vec!["line one", "single line", "three"]);
    }

    #[test]
    fn currently_believed_rate_counts_fraction() {
        let rows = vec![row("a"), row("b"), row("c")];
        let m = vec![
            meta("w", "r", true),
            meta("w", "r", true),
            meta("w", "r", false),
        ];
        let page = RecallPage {
            rows,
            page_index: 0,
            is_last: true,
        };
        let doc = synthesize(&page, &m, 3);
        assert!((doc.success_rate - (2.0 / 3.0)).abs() < 1e-6);
    }
}
