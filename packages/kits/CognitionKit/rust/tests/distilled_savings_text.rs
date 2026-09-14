use cognition_kit::{distilled_savings_text, measure_distilled_savings};
use genius_locus_kit::hydration_representation::estimated_token_count as count;

#[test]
fn disabled() {
    assert_eq!(distilled_savings_text("private body", "body", false, Some("")), "");
}
#[test]
fn direct_and_skim() {
    let (original, reduced, preview) = ("alpha beta gamma delta epsilon", "alpha beta gamma", "alpha");
    assert_eq!(distilled_savings_text(original, reduced, true, None),
        measure_distilled_savings(count(original), count(reduced), None).display);
    assert_eq!(distilled_savings_text(original, reduced, true, Some(preview)),
        measure_distilled_savings(count(original), count(reduced), Some(count(reduced)-count(preview))).display);
}
#[test]
fn empty_unicode_and_growth() {
    assert_eq!(distilled_savings_text("", "", true, None),
        "🌱 Distilled: ~0 tokens returned vs ~0 original · ~0 saved (0%)");
    assert!(distilled_savings_text("é🙂", "é🙂", true, None).contains("~0 saved (0%)"));
    let growth = distilled_savings_text("a", "a", true, Some("a much longer preview"));
    assert!(growth.contains("increase"));
    assert!(!growth.contains("omitted"));
}
