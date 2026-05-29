//! ContextSynthesizer Rust port. Pure synthesis over a recall page —
//! reads only, produces a `ContextDocument` matching the Swift
//! `ContextSynthesisEngine` byte-for-byte against shared vectors.
//!
//! Per NEURONKIT_SPEC § 4.2 the synthesizer is reads-only and writes
//! nothing to the substrate (C-9). The Rust port mirrors this by
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
/// `DrawerRow`. The Swift port reads these straight off
/// `LocusKit.Drawer`; the Rust engine accepts them as a parallel
/// vector so the port can be exercised without the full LocusKit
/// Rust type. Empty (or shorter than `rows`) means "treat as default
/// (active state, default wing/room)".
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DrawerRowMeta {
    pub wing: String,
    pub room: String,
    /// Whether the drawer is "currently believed" per the LocusKit
    /// adjective-state cluster. The Swift engine reads
    /// `drawer.isCurrentlyBelieved`; the Rust port accepts the
    /// pre-computed boolean.
    pub is_currently_believed: bool,
}

impl Default for DrawerRowMeta {
    fn default() -> Self {
        Self {
            wing: "(no wing)".to_string(),
            room: "(no room)".to_string(),
            is_currently_believed: true,
        }
    }
}

/// Synthesize a `ContextDocument` from a recall page and the
/// per-row metadata vector. The metadata vector may be empty, in
/// which case every row is treated with `DrawerRowMeta::default()`.
pub fn synthesize(page: &RecallPage, meta: &[DrawerRowMeta]) -> ContextDocument {
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
    let key_insights = make_key_insights(rows, 3);

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

/// One-line summary naming row count and dominant wing/room. Stable
/// across runs.
pub fn make_summary(rows: &[DrawerRow], meta: &[DrawerRowMeta]) -> String {
    let count = rows.len();
    let wings: Vec<String> = (0..rows.len()).map(|i| meta_or_default(meta, i).wing).collect();
    let rooms: Vec<String> = (0..rows.len()).map(|i| meta_or_default(meta, i).room).collect();
    let top_wing = most_frequent(&wings).unwrap_or_else(|| "(no wing)".to_string());
    let top_room = most_frequent(&rooms).unwrap_or_else(|| "(no room)".to_string());
    format!(
        "{} drawers; dominant wing {}; dominant room {}.",
        count, top_wing, top_room
    )
}

/// Top-N patterns. Frequency descending, ties broken by first
/// appearance, final tiebreak by token string. Identical ordering
/// to Swift.
pub fn top_patterns(rows: &[DrawerRow], max_count: usize) -> Vec<String> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut first_seen: BTreeMap<String, usize> = BTreeMap::new();
    let mut order = 0usize;
    for row in rows {
        for token in tokens(&row.content) {
            if token.chars().count() < 4 {
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
        return vec!["No dominant pattern detected; consider broadening the recall frame.".to_string()];
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
            wing: wing.to_string(),
            room: room.to_string(),
            is_currently_believed: believed,
        }
    }

    #[test]
    fn empty_page_produces_empty_document() {
        let page = RecallPage { rows: vec![], page_index: 0, is_last: true };
        let doc = synthesize(&page, &[]);
        assert_eq!(doc.summary, "");
        assert!(doc.patterns.is_empty());
        assert_eq!(doc.success_rate, 0.0);
        assert_eq!(doc.average_reward, 0.0);
        assert!(doc.recommendations.is_empty());
        assert!(doc.key_insights.is_empty());
    }

    #[test]
    fn summary_names_count_and_dominant_wing_and_room() {
        let rows = vec![row("a"), row("b"), row("c")];
        let m = vec![
            meta("alpha", "r1", true),
            meta("alpha", "r2", true),
            meta("beta", "r1", true),
        ];
        let page = RecallPage { rows, page_index: 0, is_last: true };
        let doc = synthesize(&page, &m);
        assert_eq!(doc.summary, "3 drawers; dominant wing alpha; dominant room r1.");
    }

    #[test]
    fn patterns_rank_by_frequency_then_first_seen() {
        let rows = vec![
            row("carbon organic compounds"),
            row("organic chemistry carbon"),
            row("physics waves photons"),
        ];
        let page = RecallPage { rows, page_index: 0, is_last: true };
        let doc = synthesize(&page, &[]);
        assert_eq!(
            doc.patterns,
            vec!["carbon", "organic", "compounds", "chemistry", "physics"]
        );
    }

    #[test]
    fn recommendations_match_pattern_count() {
        let rows = vec![row("alpha beta gamma delta")];
        let page = RecallPage { rows, page_index: 0, is_last: true };
        let doc = synthesize(&page, &[]);
        assert_eq!(doc.recommendations.len(), doc.patterns.len());
    }

    #[test]
    fn no_pattern_produces_neutral_recommendation() {
        let rows = vec![row("a bb ccc")];
        let page = RecallPage { rows, page_index: 0, is_last: true };
        let doc = synthesize(&page, &[]);
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
        let page = RecallPage { rows, page_index: 0, is_last: true };
        let doc = synthesize(&page, &[]);
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
        let page = RecallPage { rows, page_index: 0, is_last: true };
        let doc = synthesize(&page, &m);
        assert!((doc.success_rate - (2.0 / 3.0)).abs() < 1e-6);
    }
}
