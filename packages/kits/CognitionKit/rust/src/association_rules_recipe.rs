//! AssociationRules — the conscious "what co-occurs with what" recipe
//! (Analytics). Rust version of the Swift `AssociationRules` in
//! `CognitionKit/Sources/CognitionKit/AssociationRules.swift`.
//! Paired with the Swift version (`Sources/CognitionKit/AssociationRules.swift`).
//!
//! Recalls a set of drawers, projects each drawer's categorical facets
//! (room, kind, channel, sensitivity) into a per-call label vocabulary,
//! builds the co-occurrence matrix O from the recalled set, and surfaces
//! NeuronKit's pairwise association-rule mining.
//!
//! Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): the recipe only SEQUENCES.
//!   - Estate read: one `coord.recall` call.
//!   - Label projection: derive the substrate's categorical facets as
//!     lowercase camelCase canonical strings (Swift case-name vocabulary,
//!     § 4.2). Rust PascalCase variant names are NOT used here; the
//!     canonical strings are the Swift lowercase names so both versions
//!     produce byte-identical label vocabularies.
//!   - MatrixO build: accumulate co-occurrence via `MatrixO::apply_row`.
//!   - Rule mining: one `mine_association_rules` call — the engine owns
//!     all metric computation; the recipe shapes inputs and relabels outputs.
//!
//! Packed-item mapping (mirrors the Swift implementation):
//!   1. Collect distinct labels from all recalled drawers, sorted
//!      alphabetically. Label format: "kind:{caseName}", "channel:{caseName}",
//!      "sensitivity:{caseName}", "room:{roomString}" using lowercase camelCase
//!      Swift canonical names.
//!   2. Assign field index 0..N-1 (N ≤ 64). If N > 64, cap at 64 and set
//!      `label_overflow = true`. `value` is always 1 (presence item).
//!   3. Build MatrixO: for each drawer, call `apply_row(1, &field_values)`.
//!   4. Call `mine_association_rules(matrix, drawer_count as i64, thresholds)`.
//!   5. Relabel Item.field indices back to label strings.
//!
//! Overflow rule: if sorted unique label count > 64, only the first 64 labels
//! (alphabetical order) are indexed; overflow labels are silently dropped per
//! row. Total and deterministic within a call.
//!
//! Read-only: no write verb. Capability gate: `AssociationRuleMining`.

use std::collections::BTreeSet;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::{CaptureChannel, ContentKind};
use locus_kit::filter::RecallFrame;
use neuron_kit::{mine_association_rules, MiningThresholds};
use substrate_types::MatrixO;

use crate::capability::{shipped_capabilities, verify_capabilities, NeuronKitCapability};
use crate::error::{RecipeRunError, SubstrateError};

// MARK: - Result type

/// One relabeled mined pairwise rule, with the five standard metrics.
/// `antecedent` and `consequent` are the original string labels
/// (e.g. "room:study", "kind:prose"), not the raw packed Item indices.
#[derive(Debug, Clone, PartialEq)]
pub struct AssociationRuleResult {
    /// The antecedent label string (e.g. "room:study").
    pub antecedent: String,
    /// The consequent label string (e.g. "kind:prose").
    pub consequent: String,
    pub support: f64,
    pub confidence: f64,
    pub lift: f64,
    pub conviction: f64,
    pub leverage: f64,
}

/// Output of the AssociationRules recipe.
#[derive(Debug, Clone, PartialEq)]
pub struct AssociationRulesOutput {
    /// Mined rules with string-relabeled antecedents and consequents,
    /// in ascending packed `(antecedent, consequent)` label-index order
    /// (deterministic within a call). Mirrors Swift `AssociationRules.Output.rules`.
    pub rules: Vec<AssociationRuleResult>,
    /// Number of drawers the matrix was built from.
    pub drawer_count: usize,
    /// True if the unique label count exceeded 64 and was capped.
    pub label_overflow: bool,
}

// MARK: - Recipe entry point

/// Capacity constant: MatrixO requires field < 64 (6-bit field index).
const MAX_FIELD_COUNT: usize = 64;

/// Run the AssociationRules recipe: recall drawers via `frame`, build a
/// MatrixO from their field-value co-occurrence, and mine pairwise rules.
///
/// Mirrors Swift `AssociationRules.run(input:estate:kit:)`.
pub fn run_association_rules(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    thresholds: MiningThresholds,
    now: i64,
) -> Result<AssociationRulesOutput, RecipeRunError> {
    // B-5: verify capability before any estate touch.
    verify_capabilities(
        &[NeuronKitCapability::AssociationRuleMining],
        &shipped_capabilities(),
    )
    .map_err(|e| SubstrateError::new("capability_gate", format!("{e:?}")))?;

    // 1. Recall drawers.
    let drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
    let drawer_count = drawers.len();

    if drawer_count == 0 {
        return Ok(AssociationRulesOutput {
            rules: vec![],
            drawer_count: 0,
            label_overflow: false,
        });
    }

    // 2. Build per-call sorted label vocabulary.
    let (labels, label_overflow) = build_label_table(&drawers);

    // 3. Build MatrixO.
    let mut matrix = MatrixO::new();
    for drawer in &drawers {
        let field_values = drawer_field_values(drawer, &labels);
        matrix.apply_row(1, &field_values);
    }

    // 4. Mine association rules.
    let raw_rules = mine_association_rules(&matrix, drawer_count as i64, thresholds);

    // 5. Relabel Item field indices back to label strings.
    let rules: Vec<AssociationRuleResult> = raw_rules
        .into_iter()
        .filter_map(|rule| {
            let ai = rule.antecedent.field as usize;
            let ci = rule.consequent.field as usize;
            if ai < labels.len() && ci < labels.len() {
                Some(AssociationRuleResult {
                    antecedent: labels[ai].clone(),
                    consequent: labels[ci].clone(),
                    support: rule.support,
                    confidence: rule.confidence,
                    lift: rule.lift,
                    conviction: rule.conviction,
                    leverage: rule.leverage,
                })
            } else {
                None
            }
        })
        .collect();

    Ok(AssociationRulesOutput {
        rules,
        drawer_count,
        label_overflow,
    })
}

// MARK: - Label helpers

/// Canonical lowercase camelCase string for a `ContentKind` variant.
/// Uses the Swift case name — the substrate vocabulary (§ 4.2).
/// NOT the Rust Debug format (PascalCase); the Swift names are canonical.
fn content_kind_label(kind: ContentKind) -> &'static str {
    match kind {
        ContentKind::Prose => "kind:prose",
        ContentKind::Code => "kind:code",
        ContentKind::Transcript => "kind:transcript",
        ContentKind::List => "kind:list",
        ContentKind::StructuredJson => "kind:structuredJSON",
        ContentKind::ImageCaption => "kind:imageCaption",
        ContentKind::FingerprintOnly => "kind:fingerprintOnly",
    }
}

/// Canonical lowercase camelCase string for a `CaptureChannel` variant.
fn capture_channel_label(channel: CaptureChannel) -> &'static str {
    match channel {
        CaptureChannel::Typed => "channel:typed",
        CaptureChannel::Voiced => "channel:voiced",
        CaptureChannel::Ocr => "channel:ocr",
        CaptureChannel::ImportedFile => "channel:importedFile",
        CaptureChannel::Sensor => "channel:sensor",
        CaptureChannel::Actuator => "channel:actuator",
    }
}

/// Canonical lowercase camelCase string for an `AdjectiveSensitivity` variant.
fn sensitivity_label(sensitivity: AdjectiveSensitivity) -> &'static str {
    match sensitivity {
        AdjectiveSensitivity::Normal => "sensitivity:normal",
        AdjectiveSensitivity::Elevated => "sensitivity:elevated",
        AdjectiveSensitivity::Restricted => "sensitivity:restricted",
        AdjectiveSensitivity::Secret => "sensitivity:secret",
    }
}

/// The four categorical label strings for a single recalled drawer.
fn drawer_labels(drawer: &Drawer) -> Vec<String> {
    vec![
        content_kind_label(drawer.content_kind()).to_string(),
        capture_channel_label(drawer.capture_channel()).to_string(),
        sensitivity_label(drawer.adjective_sensitivity()).to_string(),
        format!("room:{}", drawer.room),
    ]
}

/// Build a sorted, deduplicated label array from the recalled drawer set.
/// Returns the label array (up to `MAX_FIELD_COUNT` entries) and whether
/// the distinct-label count exceeded the cap.
fn build_label_table(drawers: &[Drawer]) -> (Vec<String>, bool) {
    let mut seen: BTreeSet<String> = BTreeSet::new();
    for drawer in drawers {
        for label in drawer_labels(drawer) {
            seen.insert(label);
        }
    }
    let all: Vec<String> = seen.into_iter().collect(); // BTreeSet is sorted
    let overflow = all.len() > MAX_FIELD_COUNT;
    let capped = if overflow {
        all.into_iter().take(MAX_FIELD_COUNT).collect()
    } else {
        all
    };
    (capped, overflow)
}

/// The `(field, value)` presence items for a drawer under the given label table.
/// Each label present in the drawer contributes one item with `field = index`
/// and `value = 1`. Labels absent from the table (overflow) are silently dropped.
fn drawer_field_values(drawer: &Drawer, labels: &[String]) -> Vec<(u8, u8)> {
    let drawer_label_set = drawer_labels(drawer);
    let mut result = Vec::with_capacity(drawer_label_set.len());
    for label in &drawer_label_set {
        if let Some(idx) = labels.iter().position(|l| l == label) {
            result.push((idx as u8, 1u8));
        }
    }
    result
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};
    use locus_kit::frames::CaptureFrame;
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;

    fn coord_with_estate() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
        let h = coord.open(store, OwnerCredentials::new("owner"), 0, 100).unwrap();
        (coord, h)
    }

    fn capture_drawer(
        coord: &EstateCoordinator,
        h: &EstateHandle,
        room: &str,
        kind: ContentKind,
        channel: CaptureChannel,
    ) {
        let mut frame = CaptureFrame::new(
            "content",
            channel,
            room,
            LatticeAnchor::udc("0"),
            "test",
            "test-v1",
        );
        frame.kind = kind;
        coord.capture(h, frame, NOW).unwrap();
    }

    fn unconfirmed() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    fn zero_thresholds() -> MiningThresholds {
        MiningThresholds::new(0.0, 0.0)
    }

    // CK-AR-1: empty estate — no drawers recalled, no rules.
    #[test]
    fn empty_estate_yields_no_rules() {
        let (coord, h) = coord_with_estate();
        let out = run_association_rules(&coord, &h, unconfirmed(), zero_thresholds(), NOW).unwrap();
        assert!(out.rules.is_empty());
        assert_eq!(out.drawer_count, 0);
    }

    // CK-AR-2: co-occurring labels produce rules.
    //
    // 4 drawers with room "study" + kind:prose + channel:typed.
    // 4 drawers with room "work" + kind:code + channel:voiced.
    // Labels co-occurring within each drawer produce high-confidence rules.
    #[test]
    fn co_occurring_labels_produce_rules() {
        let (coord, h) = coord_with_estate();
        for _ in 0..4 {
            capture_drawer(&coord, &h, "study", ContentKind::Prose, CaptureChannel::Typed);
            capture_drawer(&coord, &h, "work", ContentKind::Code, CaptureChannel::Voiced);
        }
        let out = run_association_rules(&coord, &h, unconfirmed(), zero_thresholds(), NOW).unwrap();
        assert!(!out.rules.is_empty());
        assert_eq!(out.drawer_count, 8);
        // Every rule has non-empty string labels.
        for rule in &out.rules {
            assert!(!rule.antecedent.is_empty());
            assert!(!rule.consequent.is_empty());
            assert!(rule.support > 0.0);
        }
    }

    // CK-AR-3: canonical labels use lowercase camelCase Swift names.
    #[test]
    fn labels_use_canonical_swift_names() {
        let (coord, h) = coord_with_estate();
        capture_drawer(&coord, &h, "study", ContentKind::Prose, CaptureChannel::ImportedFile);
        let out = run_association_rules(&coord, &h, unconfirmed(), zero_thresholds(), NOW).unwrap();
        // All antecedent/consequent strings use the canonical vocabulary.
        let all_labels: Vec<&str> = out
            .rules
            .iter()
            .flat_map(|r| [r.antecedent.as_str(), r.consequent.as_str()])
            .collect();
        // "importedFile" (Swift camelCase), NOT "ImportedFile" (Rust PascalCase).
        for label in all_labels {
            if label.starts_with("channel:") {
                assert!(!label.contains("ImportedFile"), "must use Swift camelCase: {label}");
                assert!(label.contains("importedFile"), "must use Swift camelCase: {label}");
            }
            if label.starts_with("kind:") {
                // "prose" not "Prose"
                assert!(!label.chars().nth(5).map(|c| c.is_uppercase()).unwrap_or(false),
                    "kind label must be lowercase: {label}");
            }
        }
    }

    // CK-AR-4: threshold gating — high threshold removes low-support rules.
    #[test]
    fn high_threshold_filters_rules() {
        let (coord, h) = coord_with_estate();
        capture_drawer(&coord, &h, "rare", ContentKind::Prose, CaptureChannel::Typed);
        for _ in 0..3 {
            capture_drawer(&coord, &h, "common", ContentKind::Prose, CaptureChannel::Typed);
        }
        let all = run_association_rules(&coord, &h, unconfirmed(), zero_thresholds(), NOW).unwrap();
        let high = run_association_rules(
            &coord, &h, unconfirmed(),
            MiningThresholds::new(0.9, 0.9), NOW,
        ).unwrap();
        assert!(high.rules.len() <= all.rules.len());
    }

    // CK-AR-5: determinism — same estate, same output twice.
    #[test]
    fn rules_are_deterministic() {
        let (coord, h) = coord_with_estate();
        for _ in 0..3 {
            capture_drawer(&coord, &h, "study", ContentKind::Prose, CaptureChannel::Typed);
            capture_drawer(&coord, &h, "work", ContentKind::Code, CaptureChannel::Voiced);
        }
        let first = run_association_rules(&coord, &h, unconfirmed(), zero_thresholds(), NOW).unwrap();
        let second = run_association_rules(&coord, &h, unconfirmed(), zero_thresholds(), NOW).unwrap();
        assert_eq!(first.rules.len(), second.rules.len());
        for (a, b) in first.rules.iter().zip(second.rules.iter()) {
            assert_eq!(a.antecedent, b.antecedent);
            assert_eq!(a.consequent, b.consequent);
        }
    }

    // CK-AR-OV: more than 64 distinct labels trips the documented cap.
    // 70 unique rooms (+ kind/channel labels shared by every drawer)
    // exceed the 64-label table; the recipe flags the overflow AND still
    // mines rules over the kept labels — the sorted table keeps the
    // channel:/kind: labels (they precede room:* alphabetically), which
    // co-occur in every drawer.
    #[test]
    fn label_overflow_is_flagged_and_rules_still_mine() {
        let (coord, h) = coord_with_estate();
        for i in 0..70 {
            capture_drawer(
                &coord,
                &h,
                &format!("room{i:02}"),
                ContentKind::Prose,
                CaptureChannel::Typed,
            );
        }

        let out =
            run_association_rules(&coord, &h, unconfirmed(), zero_thresholds(), NOW).unwrap();

        assert!(out.label_overflow, "more than 64 distinct labels flags the cap");
        assert_eq!(out.drawer_count, 70);
        assert!(
            !out.rules.is_empty(),
            "rules still mine over the kept (sorted-first-64) labels"
        );
    }
}
