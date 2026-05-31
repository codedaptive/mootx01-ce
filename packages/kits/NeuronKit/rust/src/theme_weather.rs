//! ThemeWeather — recency momentum (Lens 2, Topics): the NeuronKit reasoning
//! surface over SubstrateML's exponential `decay`. A category's "attention
//! share" (its decay-weighted recent mass) compared to its "historical share"
//! (raw count) tells you whether it is heating up or cooling down — momentum,
//! not just presence. "Estate planning is rising; job search is fading."
//!
//! Layer B-1: the decay math lives in SubstrateML; this shapes per-category
//! masses into signed momentum. CognitionKit sequences it (gather per-category
//! raw counts + decay-weighted masses from the estate, then call this).

use substrate_ml::decay::decay_factor;

/// Recency weight of an event `elapsed_seconds` old under `half_life_seconds`
/// — 1.0 for "now", halving each half-life. A thin surface over SubstrateML's
/// `decay_factor` so the recipe weights recent memories more heavily.
pub fn recency_weight(elapsed_seconds: f64, half_life_seconds: f64) -> f64 {
    decay_factor(elapsed_seconds, half_life_seconds)
}

/// One category's momentum: positive = heating (recent attention exceeds its
/// historical presence), negative = cooling.
#[derive(Clone, Debug, PartialEq)]
pub struct CategoryMomentum {
    pub category: String,
    pub momentum: f64,
}

/// Compute momentum per category from `(category, raw_count, weighted_mass)`,
/// where `weighted_mass` is the sum of `recency_weight` over the category's
/// memories. Momentum = (weighted_mass / Σweighted) − (raw_count / Σraw): a
/// category whose recent attention share exceeds its historical share is
/// heating. Returned sorted by momentum descending (hottest first), ties by
/// category name.
pub fn theme_weather(categories: &[(String, f64, f64)]) -> Vec<CategoryMomentum> {
    let total_raw: f64 = categories.iter().map(|(_, r, _)| r).sum();
    let total_weighted: f64 = categories.iter().map(|(_, _, w)| w).sum();
    if total_raw <= 0.0 || total_weighted <= 0.0 {
        return Vec::new();
    }
    let mut out: Vec<CategoryMomentum> = categories
        .iter()
        .map(|(c, raw, weighted)| CategoryMomentum {
            category: c.clone(),
            momentum: (weighted / total_weighted) - (raw / total_raw),
        })
        .collect();
    out.sort_by(|a, b| {
        b.momentum
            .partial_cmp(&a.momentum)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.category.cmp(&b.category))
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // TW-1: recency weight halves each half-life, is 1.0 at "now".
    #[test]
    fn tw1_recency_weight_halves() {
        assert!((recency_weight(0.0, 100.0) - 1.0).abs() < 1e-9);
        assert!((recency_weight(100.0, 100.0) - 0.5).abs() < 1e-9);
        assert!(recency_weight(200.0, 100.0) < recency_weight(100.0, 100.0));
    }

    // TW-2: a category whose mass is recency-skewed (high weighted share vs its
    // raw share) is heating; an old-skewed one is cooling. Two categories, equal
    // raw counts; A's mass is recent (weight ~1), B's is old (weight ~0).
    #[test]
    fn tw2_recent_heats_old_cools() {
        let cats = vec![
            ("recent".to_string(), 3.0, 3.0 * 1.0),  // 3 memories, all "now"
            ("old".to_string(), 3.0, 3.0 * 0.1),     // 3 memories, heavily decayed
        ];
        let w = theme_weather(&cats);
        assert_eq!(w[0].category, "recent", "the recent category is hottest");
        assert!(w[0].momentum > 0.0, "recent is heating");
        assert!(w.iter().find(|m| m.category == "old").unwrap().momentum < 0.0, "old is cooling");
    }

    // TW-3: equal recency ⇒ zero momentum (presence == attention).
    #[test]
    fn tw3_uniform_is_flat() {
        let cats = vec![
            ("a".to_string(), 2.0, 2.0 * 0.5),
            ("b".to_string(), 2.0, 2.0 * 0.5),
        ];
        let w = theme_weather(&cats);
        assert!(w.iter().all(|m| m.momentum.abs() < 1e-9), "uniform recency ⇒ flat");
    }
}
