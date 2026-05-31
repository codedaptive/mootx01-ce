//! Bias — over/under-representation against a reference (Lens 4, Preference &
//! judgment): the NeuronKit reasoning surface for "what the estate leans
//! toward vs away from." Per category, the signed difference between the
//! estate's share and a reference share — positive = bias FOR (over-
//! represented), negative = bias AGAINST (under-represented, or avoided
//! entirely when the estate's share is zero).
//!
//! This is the DISTRIBUTIONAL half of the preference lens — what the corpus
//! over- and under-weights — and is honest about being a share difference, not
//! dressed-up math. The LEARNED-preference half (Bradley-Terry utility from
//! actual choices) is the deeper signal and needs a real preference/confirm
//! event source. The estate-side recipe also adds a dismissal signal
//! (withdrawal rates) for "bias against".

/// One category's representation bias. `bias = estate_share - reference_share`.
#[derive(Clone, Debug, PartialEq)]
pub struct CategoryBias {
    pub label: String,
    pub estate_share: f64,
    pub reference_share: f64,
    /// Signed: > 0 over-represented (for), < 0 under-represented (against).
    pub bias: f64,
}

fn normalize(counts: &[(String, f64)]) -> std::collections::BTreeMap<String, f64> {
    let total: f64 = counts.iter().map(|(_, c)| c).sum();
    let mut out = std::collections::BTreeMap::new();
    if total <= 0.0 {
        return out;
    }
    for (label, c) in counts {
        *out.entry(label.clone()).or_insert(0.0) += c / total;
    }
    out
}

/// Signed representation bias of `estate` against `reference`, per category
/// over the UNION of both label sets (a category present only in the reference
/// gets estate_share 0 ⇒ strongly negative = avoided). Sorted by bias
/// descending — most over-represented first, most avoided last. Ties by label.
pub fn representation_bias(
    estate: &[(String, f64)],
    reference: &[(String, f64)],
) -> Vec<CategoryBias> {
    let e = normalize(estate);
    let r = normalize(reference);
    let mut labels: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for k in e.keys().chain(r.keys()) {
        labels.insert(k.clone());
    }
    let mut out: Vec<CategoryBias> = labels
        .into_iter()
        .map(|label| {
            let estate_share = e.get(&label).copied().unwrap_or(0.0);
            let reference_share = r.get(&label).copied().unwrap_or(0.0);
            CategoryBias { label, estate_share, reference_share, bias: estate_share - reference_share }
        })
        .collect();
    out.sort_by(|a, b| {
        b.bias.partial_cmp(&a.bias).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.label.cmp(&b.label))
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(pairs: &[(&str, f64)]) -> Vec<(String, f64)> {
        pairs.iter().map(|(l, n)| (l.to_string(), *n)).collect()
    }
    fn bias_of(v: &[CategoryBias], label: &str) -> f64 {
        v.iter().find(|b| b.label == label).unwrap().bias
    }

    // BI-1: a category the estate over-weights relative to the reference is
    // bias FOR (positive, ranked first); one it under-weights is AGAINST.
    #[test]
    fn bi1_over_and_under_representation() {
        // Estate is 80% philosophy, 20% cooking; reference is 50/50.
        let estate = c(&[("philosophy", 8.0), ("cooking", 2.0)]);
        let reference = c(&[("philosophy", 5.0), ("cooking", 5.0)]);
        let b = representation_bias(&estate, &reference);
        assert_eq!(b[0].label, "philosophy", "the over-weighted category leads");
        assert!(bias_of(&b, "philosophy") > 0.0, "bias FOR");
        assert!(bias_of(&b, "cooking") < 0.0, "bias AGAINST");
    }

    // BI-2: a category present in the reference but ABSENT from the estate is
    // strongly biased-against (avoided) — estate_share 0, full negative.
    #[test]
    fn bi2_avoided_category_is_against() {
        let estate = c(&[("philosophy", 10.0)]);
        let reference = c(&[("philosophy", 5.0), ("finance", 5.0)]);
        let b = representation_bias(&estate, &reference);
        let finance = b.iter().find(|x| x.label == "finance").unwrap();
        assert_eq!(finance.estate_share, 0.0, "never captured");
        assert!(finance.bias < 0.0, "an avoided topic is biased against");
        assert!(b.last().unwrap().label == "finance", "the most-avoided is last");
    }

    // BI-3: an estate matching the reference has ~zero bias everywhere.
    #[test]
    fn bi3_matching_reference_is_unbiased() {
        let estate = c(&[("a", 3.0), ("b", 3.0)]);
        let reference = c(&[("a", 1.0), ("b", 1.0)]);
        let b = representation_bias(&estate, &reference);
        assert!(b.iter().all(|x| x.bias.abs() < 1e-9), "balanced ⇒ unbiased");
    }
}
