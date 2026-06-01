//! Theme weather — recency momentum (SPEC § 7.2, Lens 2 Topics). A category's
//! decay-weighted recent attention share, compared to its historical share,
//! signals whether it is heating up or cooling down. Surfaces SubstrateML's
//! exponential decay; owns no math (I-17), pure and total (I-18, B-8).

use substrate_ml::decay::decay_factor;

/// One category's momentum: recent attention share minus historical share.
/// Positive = heating; negative = cooling.
#[derive(Clone, Debug, PartialEq)]
pub struct CategoryMomentum {
    pub category: String,
    pub momentum: f64,
}

/// Recency weight of an event `elapsed_seconds` old under `half_life_seconds` —
/// 1.0 at "now", halving each half-life. A thin surface over SubstrateML's
/// `decay_factor`.
pub fn recency_weight(elapsed_seconds: f64, half_life_seconds: f64) -> f64 {
    decay_factor(elapsed_seconds, half_life_seconds)
}

/// Momentum per category from `(category, raw_count, weighted_mass)`, where
/// `weighted_mass` is the sum of `recency_weight` over the category's memories.
/// Momentum = (weighted_mass / Σweighted) − (raw_count / Σraw): a category whose
/// recent attention share exceeds its historical share is heating. Returned
/// sorted by momentum descending (hottest first), ties by ascending category
/// name. Empty input ⇒ empty result (C-16).
pub fn theme_weather(categories: &[(String, f64, f64)]) -> Vec<CategoryMomentum> {
    if categories.is_empty() {
        return Vec::new();
    }

    let total_raw: f64 = categories.iter().map(|(_, raw, _)| raw).sum();
    let total_weighted: f64 = categories.iter().map(|(_, _, w)| w).sum();
    // A side with no mass contributes a zero share (no division by zero).
    let raw_share = |x: f64| if total_raw > 0.0 { x / total_raw } else { 0.0 };
    let weighted_share = |x: f64| if total_weighted > 0.0 { x / total_weighted } else { 0.0 };

    let mut out: Vec<CategoryMomentum> = categories
        .iter()
        .map(|(category, raw, weighted)| CategoryMomentum {
            category: category.clone(),
            momentum: weighted_share(*weighted) - raw_share(*raw),
        })
        .collect();
    out.sort_by(|a, b| {
        b.momentum
            .partial_cmp(&a.momentum)
            .unwrap_or(std::cmp::Ordering::Equal) // descending momentum
            .then_with(|| a.category.cmp(&b.category)) // ties: ascending category name
    });
    out
}

#[cfg(test)]
mod tests {
    // Tests assert SPEC § 7.2's claims about theme weather: a category with an
    // outsized recent share heats up, the result is sorted hottest-first with
    // name tie-breaks, and the surface is total over edge inputs.
    use super::*;

    fn cats(xs: &[(&str, f64, f64)]) -> Vec<(String, f64, f64)> {
        xs.iter().map(|(c, r, w)| (c.to_string(), *r, *w)).collect()
    }

    #[test]
    fn recency_weight_halves_each_half_life() {
        let hl = 100.0;
        assert_eq!(recency_weight(0.0, hl), 1.0);
        assert!((recency_weight(hl, hl) - 0.5).abs() < 1e-9);
        assert!((recency_weight(2.0 * hl, hl) - 0.25).abs() < 1e-9);
    }

    #[test]
    fn recency_weight_is_monotonic() {
        let hl = 50.0;
        assert!(recency_weight(10.0, hl) > recency_weight(200.0, hl));
    }

    #[test]
    fn outsized_recent_share_heats_up() {
        // Equal historical counts; "rising" holds 90% of recent mass.
        let c = cats(&[("rising", 10.0, 9.0), ("fading", 10.0, 1.0)]);
        let w = theme_weather(&c);
        let rising = w.iter().find(|m| m.category == "rising").unwrap();
        let fading = w.iter().find(|m| m.category == "fading").unwrap();
        assert!(rising.momentum > 0.0);
        assert!(fading.momentum < 0.0);
        assert!((rising.momentum + fading.momentum).abs() < 1e-9, "shares zero-sum");
    }

    #[test]
    fn sorted_hottest_first_ties_by_name() {
        let c = cats(&[("b", 10.0, 5.0), ("a", 10.0, 5.0), ("hot", 10.0, 20.0)]);
        let w = theme_weather(&c);
        assert_eq!(w[0].category, "hot");
        for pair in w.windows(2) {
            assert!(pair[0].momentum >= pair[1].momentum, "descending");
        }
        let ai = w.iter().position(|m| m.category == "a").unwrap();
        let bi = w.iter().position(|m| m.category == "b").unwrap();
        assert!(ai < bi, "ties broken ascending name");
    }

    #[test]
    fn total_over_edge_inputs() {
        assert!(theme_weather(&[]).is_empty());
    }
}
