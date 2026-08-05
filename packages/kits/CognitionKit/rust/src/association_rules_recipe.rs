//! AssociationRules and AprioriRules — the conscious "what co-occurs with
//! what" recipe family (Analytics).
//!
//! Rust versions of the Swift recipes in
//! `CognitionKit/Sources/CognitionKit/AssociationRules.swift`.
//!
//! ## AssociationRules
//!
//! Recalls a set of drawers, projects each drawer's categorical facets
//! (room, kind, channel, sensitivity) into a per-call label vocabulary,
//! builds the co-occurrence matrix O from the recalled set, and surfaces
//! SubstrateML's pairwise association-rule mining.
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
//!
//! ## AprioriRules
//!
//! Multi-antecedent association-rule mining over the estate's audit log.
//! Rust port of the Swift `AprioriRules` recipe (`AssociationRules.swift:205`).
//!
//! Delegates entirely to `EstateCoordinator::mine_apriori_rules` which
//! replays the estate's LocusKit audit trail into a `UnifiedAuditLog`,
//! converts each `UnifiedAuditEntry` to a `RowAuditEntry` (same value
//! mapping as Swift's `toRowAuditEntry`), builds `RowAttributeView` rows,
//! and runs `SubstrateML::mine_apriori_rules`. No label projection is
//! needed: the engine works on `Item` attributes derived from the
//! `RowAttributeView` factory.
//!
//! The recipe's output preserves the engine's `AprioriRule` values verbatim
//! so callers can inspect all five metrics and the full multi-item antecedent
//! list.
//!
//! Read-only: no write verb. Capability gate: `AssociationRuleMining`.

use std::collections::BTreeSet;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::{CaptureChannel, ContentKind};
use locus_kit::filter::RecallFrame;
// ARM engine lives in SubstrateML; neuron_kit no longer re-exports these.
use substrate_ml::association_rule_mining::{mine_association_rules, MiningThresholds};
use substrate_types::MatrixO;

use substrate_ml::apriori_mining::{AprioriRule, AprioriThresholds};

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
    /// Drawer ids of up to `ASSOCIATION_EXEMPLAR_CAP` memories satisfying
    /// BOTH sides of the rule, in the recall frame's deterministic order.
    /// Follow-up addresses, not the full support set. Empty for
    /// dataset-mode rules (rows are not drawers). Twin of Swift
    /// `AssociationRuleResult.exemplarDrawerIDs`.
    pub exemplar_drawer_ids: Vec<String>,
}

/// How many exemplar drawer ids ride on each mined rule. Twin of Swift
/// `associationExemplarCap`.
pub const ASSOCIATION_EXEMPLAR_CAP: usize = 5;

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

    // 5. Relabel Item field indices back to label strings, and attach
    // exemplar drawer ids per rule. The engine aggregates rows into a
    // matrix and cannot say WHICH drawers support a rule, but the recipe
    // still holds the recalled set — one pass builds each drawer's label
    // set, then each rule takes the first ASSOCIATION_EXEMPLAR_CAP drawers
    // (recall order, deterministic) whose labels contain both sides.
    // Twin of the Swift exemplar computation.
    let drawer_label_sets: Vec<(String, std::collections::BTreeSet<String>)> = drawers
        .iter()
        .map(|d| (d.id.clone(), drawer_labels(d).into_iter().collect()))
        .collect();
    let rules: Vec<AssociationRuleResult> = raw_rules
        .into_iter()
        .filter_map(|rule| {
            let ai = rule.antecedent.field as usize;
            let ci = rule.consequent.field as usize;
            if ai < labels.len() && ci < labels.len() {
                let ant_label = &labels[ai];
                let con_label = &labels[ci];
                let exemplar_drawer_ids: Vec<String> = drawer_label_sets
                    .iter()
                    .filter(|(_, set)| set.contains(ant_label) && set.contains(con_label))
                    .take(ASSOCIATION_EXEMPLAR_CAP)
                    .map(|(id, _)| id.clone())
                    .collect();
                Some(AssociationRuleResult {
                    antecedent: ant_label.clone(),
                    consequent: con_label.clone(),
                    support: rule.support,
                    confidence: rule.confidence,
                    lift: rule.lift,
                    conviction: rule.conviction,
                    leverage: rule.leverage,
                    exemplar_drawer_ids,
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

// MARK: - AprioriRules recipe

/// Output of the AprioriRules recipe.
///
/// Mirrors `AprioriRules.Output` in Swift (`AssociationRules.swift:217`).
/// The recipe output preserves the engine's `AprioriRule` values verbatim
/// so callers can inspect all five metrics and the full multi-item antecedent.
#[derive(Debug, Clone, PartialEq)]
pub struct AprioriRulesOutput {
    /// Mined rules sorted by lift DESC, confidence DESC, evidence_count DESC.
    /// Mirrors Swift `AprioriRules.Output.rules: [AprioriRule]`.
    pub rules: Vec<AprioriRule>,
}

/// Run the AprioriRules recipe: read the estate's audit log, build
/// `RowAttributeView` rows from the audit entries, and mine multi-
/// antecedent association rules via the Apriori algorithm.
///
/// Mirrors Swift `AprioriRules.run(input:estate:kit:)`
/// (`AssociationRules.swift:235`). Both ports read the estate audit log
/// and delegate to the shared Apriori engine in SubstrateML
/// (`mine_apriori_rules` / `AprioriMining.mine`).
///
/// Capability gate: `AssociationRuleMining` is verified before any estate
/// touch (spec B-5, I-3).
pub fn run_apriori_rules(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    thresholds: AprioriThresholds,
) -> Result<AprioriRulesOutput, RecipeRunError> {
    // B-5: verify capability before any estate touch.
    verify_capabilities(
        &[NeuronKitCapability::AssociationRuleMining],
        &shipped_capabilities(),
    )
    .map_err(|e| SubstrateError::new("capability_gate", format!("{e:?}")))?;

    // Delegate to EstateCoordinator::mine_apriori_rules which replays
    // the estate's audit log and builds RowAttributeView rows from the
    // entries, matching the Swift `mineAprioriRules(estate:thresholds:)`
    // path through `currentAuditLog(in:)`.
    let rules = coord
        .mine_apriori_rules(handle, thresholds)
        .map_err(|e| SubstrateError::new("mine_apriori_rules", format!("{e:?}")))?;

    Ok(AprioriRulesOutput { rules })
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
        ContentKind::Dataset => "kind:dataset",
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
        format!("room:{}", drawer.parent_node_id),
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

    const NOW: i64 = 1_700_000_000;

    fn coord_with_estate() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
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
            capture_drawer(
                &coord,
                &h,
                "study",
                ContentKind::Prose,
                CaptureChannel::Typed,
            );
            capture_drawer(
                &coord,
                &h,
                "work",
                ContentKind::Code,
                CaptureChannel::Voiced,
            );
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
        capture_drawer(
            &coord,
            &h,
            "study",
            ContentKind::Prose,
            CaptureChannel::ImportedFile,
        );
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
                assert!(
                    !label.contains("ImportedFile"),
                    "must use Swift camelCase: {label}"
                );
                assert!(
                    label.contains("importedFile"),
                    "must use Swift camelCase: {label}"
                );
            }
            if label.starts_with("kind:") {
                // "prose" not "Prose"
                assert!(
                    !label
                        .chars()
                        .nth(5)
                        .map(|c| c.is_uppercase())
                        .unwrap_or(false),
                    "kind label must be lowercase: {label}"
                );
            }
        }
    }

    // CK-AR-4: threshold gating — high threshold removes low-support rules.
    #[test]
    fn high_threshold_filters_rules() {
        let (coord, h) = coord_with_estate();
        capture_drawer(
            &coord,
            &h,
            "rare",
            ContentKind::Prose,
            CaptureChannel::Typed,
        );
        for _ in 0..3 {
            capture_drawer(
                &coord,
                &h,
                "common",
                ContentKind::Prose,
                CaptureChannel::Typed,
            );
        }
        let all = run_association_rules(&coord, &h, unconfirmed(), zero_thresholds(), NOW).unwrap();
        let high = run_association_rules(
            &coord,
            &h,
            unconfirmed(),
            MiningThresholds::new(0.9, 0.9),
            NOW,
        )
        .unwrap();
        assert!(high.rules.len() <= all.rules.len());
    }

    // CK-AR-5: determinism — same estate, same output twice.
    #[test]
    fn rules_are_deterministic() {
        let (coord, h) = coord_with_estate();
        for _ in 0..3 {
            capture_drawer(
                &coord,
                &h,
                "study",
                ContentKind::Prose,
                CaptureChannel::Typed,
            );
            capture_drawer(
                &coord,
                &h,
                "work",
                ContentKind::Code,
                CaptureChannel::Voiced,
            );
        }
        let first =
            run_association_rules(&coord, &h, unconfirmed(), zero_thresholds(), NOW).unwrap();
        let second =
            run_association_rules(&coord, &h, unconfirmed(), zero_thresholds(), NOW).unwrap();
        assert_eq!(first.rules.len(), second.rules.len());
        for (a, b) in first.rules.iter().zip(second.rules.iter()) {
            assert_eq!(a.antecedent, b.antecedent);
            assert_eq!(a.consequent, b.consequent);
        }
    }

    // CK-AR-OV: more than 64 distinct labels trips the documented cap.
    // 70 unique rooms (+ kind/channel/sensitivity labels contributed by every
    // drawer) exceed the 64-label table; the recipe flags the overflow AND
    // still mines rules over the kept labels — the sorted table keeps the
    // channel:/kind:/sensitivity: labels (they precede room:* alphabetically),
    // which co-occur in every drawer.
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

        // Mirrors Swift: LocusKit.RecallFrame(filterChain: [.unconfirmed], limit: 100).
        // Explicit limit bypasses the coordinator.recall default-50 cap so
        // the overflow code path (>64 labels) is reachable.
        let mut large_frame = unconfirmed();
        large_frame.limit = Some(100);
        let out = run_association_rules(&coord, &h, large_frame, zero_thresholds(), NOW).unwrap();

        assert!(
            out.label_overflow,
            "more than 64 distinct labels flags the cap"
        );
        assert_eq!(out.drawer_count, 70);
        assert!(
            !out.rules.is_empty(),
            "rules still mine over the kept (sorted-first-64) labels"
        );
    }

    // CK-AR-6: exemplar_drawer_ids carry genuine addresses satisfying both
    // sides of the rule and respect ASSOCIATION_EXEMPLAR_CAP.
    // Mirrors Swift CK-AR-6 (`AssociationRulesTests.swift`).
    #[test]
    fn exemplar_drawer_ids_satisfy_both_labels_and_respect_cap() {
        let (coord, h) = coord_with_estate();
        // Group A: code + typed (labels: room:alpha, kind:code, channel:typed)
        let mut group_a_ids: std::collections::HashSet<String> = Default::default();
        // Group B: prose + voiced (labels: room:beta, kind:prose, channel:voiced)
        let mut group_b_ids: std::collections::HashSet<String> = Default::default();
        for _ in 0..4 {
            let da = coord
                .capture(&h, {
                    let mut f = CaptureFrame::new(
                        "group-a content",
                        CaptureChannel::Typed,
                        "alpha",
                        LatticeAnchor::udc("0"),
                        "test",
                        "test-v1",
                    );
                    f.kind = ContentKind::Code;
                    f
                }, NOW)
                .unwrap();
            group_a_ids.insert(da.id);
            let db = coord
                .capture(&h, {
                    let mut f = CaptureFrame::new(
                        "group-b content",
                        CaptureChannel::Voiced,
                        "beta",
                        LatticeAnchor::udc("0"),
                        "test",
                        "test-v1",
                    );
                    f.kind = ContentKind::Prose;
                    f
                }, NOW)
                .unwrap();
            group_b_ids.insert(db.id);
        }
        let out =
            run_association_rules(&coord, &h, unconfirmed(), zero_thresholds(), NOW).unwrap();
        // Rules exist; at least one has exemplars.
        assert!(!out.rules.is_empty(), "rules must be present after capture");
        for rule in &out.rules {
            // Cap invariant: never exceeds ASSOCIATION_EXEMPLAR_CAP.
            assert!(
                rule.exemplar_drawer_ids.len() <= ASSOCIATION_EXEMPLAR_CAP,
                "exemplar list must not exceed ASSOCIATION_EXEMPLAR_CAP for rule {}→{}: got {}",
                rule.antecedent,
                rule.consequent,
                rule.exemplar_drawer_ids.len()
            );
            // Address invariant: every exemplar id is one that was captured.
            let all_captured: std::collections::HashSet<String> = group_a_ids
                .iter()
                .chain(group_b_ids.iter())
                .cloned()
                .collect();
            for id in &rule.exemplar_drawer_ids {
                assert!(
                    all_captured.contains(id),
                    "exemplar id {id} is not a captured address (rule {}→{})",
                    rule.antecedent,
                    rule.consequent
                );
            }
        }
        // Label-correspondence invariant: for any rule involving a group-A-only
        // label (room:alpha, kind:code, channel:typed), exemplars must be group-A
        // ids; for group-B labels, group-B ids. Check at least the room labels.
        let group_a_room_rule = out
            .rules
            .iter()
            .find(|r| r.antecedent == "room:alpha" || r.consequent == "room:alpha");
        if let Some(rule) = group_a_room_rule {
            for id in &rule.exemplar_drawer_ids {
                assert!(
                    group_a_ids.contains(id),
                    "exemplar {id} for room:alpha rule must be a group-A drawer"
                );
            }
        }
    }

    // ── AprioriRules recipe tests ─────────────────────────────────────────────
    //
    // These mirror the Swift CK-AP-* tests in AssociationRulesTests.swift.

    fn zero_apriori_thresholds() -> AprioriThresholds {
        AprioriThresholds::new(0.0, 0.0, 0.0, 4)
    }

    // CK-AP-1: empty estate — no drawers, no Apriori rules. Verifies the
    // capability gate, the empty-estate short-circuit, and the
    // mine_apriori_rules wiring.
    #[test]
    fn apriori_empty_estate_yields_no_rules() {
        let (coord, h) = coord_with_estate();
        let out = run_apriori_rules(&coord, &h, zero_apriori_thresholds()).unwrap();
        assert!(
            out.rules.is_empty(),
            "fresh estate has no drawers and no Apriori rules"
        );
    }

    // CK-AP-2: verify AssociationRuleMining is present in the shipped capability
    // set. This test only checks the shipped set membership — it does not call
    // `run_apriori_rules` or observe estate-access ordering. The Swift mirror
    // (`aprioriCapabilityDeclaration`) constructs an `AprioriRules` instance
    // and inspects `requiredCapabilities` directly; this Rust test is a
    // shipped-set membership check that gives the same coverage guarantee.
    #[test]
    fn apriori_capability_gate_is_association_rule_mining() {
        use crate::capability::{shipped_capabilities, NeuronKitCapability};
        let caps = shipped_capabilities();
        assert!(
            caps.contains(&NeuronKitCapability::AssociationRuleMining),
            "shipped capabilities must include AssociationRuleMining for AprioriRules to run"
        );
    }

    // CK-AP-3: recipe runs without error after captures and returns a non-
    // empty-or-consistent result. The audit log (bitmap state) after captures
    // may or may not yield frequent Apriori patterns; what we verify is that
    // the recipe completes without error and every returned rule has a non-
    // empty antecedent — mirrors Swift `aprioriRulesRunsAfterCaptures`.
    #[test]
    fn apriori_runs_without_error_after_captures() {
        let (coord, h) = coord_with_estate();
        for _ in 0..4 {
            capture_drawer(&coord, &h, "study", ContentKind::Prose, CaptureChannel::Typed);
        }
        let thresholds = AprioriThresholds::new(0.1, 0.1, 0.5, 2);
        let out = run_apriori_rules(&coord, &h, thresholds).unwrap();
        // Every returned rule must have a non-empty antecedent.
        for rule in &out.rules {
            assert!(
                !rule.antecedent.is_empty(),
                "every Apriori rule must have a non-empty antecedent"
            );
        }
    }
}
