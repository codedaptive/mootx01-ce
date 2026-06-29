//! VK-TIER-01 — ADR-007 Decision 2 enforcement on the bulk channels.
//!
//! Fixture corpus (shared expectations with the Swift port's
//! `PrivacyTierAndReceiptTests.swift`): four drawers, one per sensitivity
//! value, in one room. Expected counts under the default scope: 2 exported
//! (normal + elevated = Normal tier), 1 excluded private (restricted),
//! 1 excluded secret. Under `BelievedIncludingPrivate`: 3 exported,
//! 0 excluded private, 1 excluded secret.

use std::path::PathBuf;
use std::sync::Arc;

use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    diary_operational::{DiaryActorClass, DiaryEventClass, DiarySeverity},
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::CaptureFrame,
};
use vault_kit::{DrawerMapping, ObsidianAdapter, VaultAdapter, VaultBridge, VaultExportScope};

/// Fixed operation instant (ms) so receipt assertions are deterministic.
const NOW: i64 = 1_765_000_000_000;

fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let handle = coord
        .open(store, OwnerCredentials::new("vk-tier-tests"), 0, 100)
        .expect("open");
    (coord, handle)
}

fn temp_vault(tag: &str) -> PathBuf {
    std::env::temp_dir().join(format!("vaultkit-tier-{tag}-{}", uuid::Uuid::new_v4()))
}

/// Capture the shared four-drawer tier corpus: one drawer per sensitivity
/// value, identical content strings in both ports.
fn capture_tier_corpus(coord: &EstateCoordinator, handle: &EstateHandle) {
    let tiers = [
        ("normal note", AdjectiveSensitivity::Normal),
        ("elevated note", AdjectiveSensitivity::Elevated),
        ("restricted note", AdjectiveSensitivity::Restricted),
        ("secret note", AdjectiveSensitivity::Secret),
    ];
    for (content, sensitivity) in tiers {
        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "tiers",
            LatticeAnchor::udc("000"),
            "tier-tests",
            "test-v1",
        );
        frame.sensitivity = sensitivity;
        coord.capture(handle, frame, NOW).expect("capture");
    }
}

// `&mut EstateCoordinator` required: VaultBridge::new takes &mut so that
// import_notes can route through capture_with_mode (dual-path intake fix, G7).
// Export-only tests still pass mut to bridge — export only reads the coord.
fn bridge(coord: &mut EstateCoordinator) -> VaultBridge<'_> {
    VaultBridge::new(
        coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::new("tier-tests", "test-v1", false),
    )
}

/// All `.md` file contents under a vault, concatenated.
fn all_markdown(vault: &PathBuf) -> String {
    let mut out = String::new();
    let mut stack = vec![vault.clone()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().map(|e| e == "md").unwrap_or(false) {
                if let Ok(text) = std::fs::read_to_string(&path) {
                    out.push_str(&text);
                    out.push('\n');
                }
            }
        }
    }
    out
}

fn write_note(vault: &PathBuf, rel: &str, text: &str) {
    let path = vault.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).expect("mkdir");
    std::fs::write(path, text).expect("write note");
}

// MARK: - Tier enforcement on export

#[test]
fn default_scope_enforces_tiers() {
    let (mut coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);
    let vault = temp_vault("default");

    let report = bridge(&mut coord)
        .export(&handle, &vault, NOW, VaultExportScope::Believed, None)
        .expect("export");

    assert_eq!(report.notes_exported, 2);
    assert_eq!(report.excluded_private_tier, 1);
    assert_eq!(report.excluded_secret_tier, 1);
    assert_eq!(report.scope, VaultExportScope::Believed);

    let exported = all_markdown(&vault);
    // Elevated is Normal tier per ADR-007 — its silent exclusion by the
    // evaluator's implicit `Normal` ceiling was the pre-mission defect.
    assert!(exported.contains("normal note"));
    assert!(exported.contains("elevated note"));
    assert!(!exported.contains("restricted note"));
    assert!(!exported.contains("secret note"));

    let _ = std::fs::remove_dir_all(&vault);
}

#[test]
fn explicit_scope_includes_private_tier_never_secret() {
    let (mut coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);
    let vault = temp_vault("private");

    let report = bridge(&mut coord)
        .export(&handle, &vault, NOW, VaultExportScope::BelievedIncludingPrivate, None)
        .expect("export");

    assert_eq!(report.notes_exported, 3);
    assert_eq!(report.excluded_private_tier, 0);
    assert_eq!(report.excluded_secret_tier, 1);

    let exported = all_markdown(&vault);
    assert!(exported.contains("restricted note"));
    assert!(!exported.contains("secret note"));

    let _ = std::fs::remove_dir_all(&vault);
}

#[test]
fn secret_never_exports_under_any_scope() {
    let (mut coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);

    for scope in VaultExportScope::all_cases() {
        let vault = temp_vault(scope.as_str());
        bridge(&mut coord)
            .export(&handle, &vault, NOW, *scope, None)
            .expect("export");
        assert!(
            !all_markdown(&vault).contains("secret note"),
            "secret-tier content leaked under scope {}",
            scope.as_str()
        );
        let _ = std::fs::remove_dir_all(&vault);
    }
}

// MARK: - Sensitivity passthrough (import + round trip)

#[test]
fn import_preserves_sensitivity_from_frontmatter() {
    let (mut coord, handle) = open_one();
    let vault = temp_vault("arrival");
    write_note(
        &vault,
        "tiers/arrival.md",
        "---\nroom: tiers\nsensitivity: restricted\n---\nAn arriving private-tier note.\n",
    );

    let report = bridge(&mut coord)
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import");
    assert_eq!(report.drawers_written, 1);

    // Recall with an explicit sensitivity ceiling so the restricted drawer
    // is visible (the evaluator default would hide it).
    let frame = RecallFrame {
        filter_chain: vec![
            Filter::Unconfirmed,
            Filter::SensitivityAtMost(AdjectiveSensitivity::Secret),
        ],
        hydration_level: HydrationLevel::Full,
        limit: None,
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    let drawers = coord.recall(&handle, frame, NOW).expect("recall");
    assert_eq!(drawers.len(), 1);
    assert_eq!(
        drawers[0].adjective_sensitivity(),
        AdjectiveSensitivity::Restricted
    );

    let _ = std::fs::remove_dir_all(&vault);
}

#[test]
fn sensitivity_round_trips_via_frontmatter() {
    let (mut coord, handle) = open_one();
    let mut frame = CaptureFrame::new(
        "elevated note",
        CaptureChannel::Typed,
        "tiers",
        LatticeAnchor::udc("000"),
        "tier-tests",
        "test-v1",
    );
    frame.sensitivity = AdjectiveSensitivity::Elevated;
    coord.capture(&handle, frame, NOW).expect("capture");

    let vault = temp_vault("roundtrip");
    bridge(&mut coord)
        .export(&handle, &vault, NOW, VaultExportScope::Believed, None)
        .expect("export");
    assert!(all_markdown(&vault).contains("sensitivity: elevated"));

    // Re-import into a fresh estate; the tier must survive the trip.
    let (mut coord_b, handle_b) = open_one();
    bridge(&mut coord_b)
        .import_vault(&vault, &handle_b, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import");
    let recall_frame = RecallFrame {
        filter_chain: vec![
            Filter::Unconfirmed,
            Filter::SensitivityAtMost(AdjectiveSensitivity::Secret),
        ],
        hydration_level: HydrationLevel::Full,
        limit: None,
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    let drawers = coord_b.recall(&handle_b, recall_frame, NOW).expect("recall");
    assert_eq!(drawers.len(), 1);
    assert_eq!(
        drawers[0].adjective_sensitivity(),
        AdjectiveSensitivity::Elevated
    );

    let _ = std::fs::remove_dir_all(&vault);
}

// MARK: - Supersession-downgrade defense (sensitivity floor)

#[test]
fn reimport_cannot_downgrade_sensitivity() {
    let (mut coord, handle) = open_one();
    // A restricted (Private-tier) drawer is captured normally.
    let mut frame = CaptureFrame::new(
        "a restricted secret kept private",
        CaptureChannel::Typed,
        "tiers",
        LatticeAnchor::udc("000"),
        "owner",
        "test-v1",
    );
    frame.sensitivity = AdjectiveSensitivity::Restricted;
    let drawer = coord.capture(&handle, frame, NOW).expect("capture");

    // The attacker learns the lineage UUID (exposed as moot_id in exported
    // notes) and crafts a vault file claiming sensitivity: normal for it.
    let vault = temp_vault("attack");
    write_note(
        &vault,
        "tiers/attack.md",
        &format!(
            "---\nroom: tiers\nmoot_id: {}\nsensitivity: normal\n---\na restricted secret kept private\n",
            drawer.lineage_id
        ),
    );

    bridge(&mut coord)
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import");

    // The floor held: the drawer is still Restricted, not Normal.
    let frame = RecallFrame {
        filter_chain: vec![
            Filter::CurrentlyBelieve,
            Filter::Any(vec![
                Filter::UserConfirmed,
                Filter::Unconfirmed,
                Filter::AutomatedConfirmedOnly,
            ]),
            Filter::Any(vec![Filter::Trustworthy, Filter::RequiresConfirmation]),
            Filter::SensitivityAtMost(AdjectiveSensitivity::Secret),
        ],
        hydration_level: HydrationLevel::Full,
        limit: None,
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    let drawers = coord.recall(&handle, frame, NOW).expect("recall");
    let survivor = drawers
        .iter()
        .find(|d| d.lineage_id == drawer.lineage_id)
        .expect("drawer survives");
    assert_eq!(
        survivor.adjective_sensitivity(),
        AdjectiveSensitivity::Restricted
    );

    // And it still does not ride a default bulk export.
    let export_vault = temp_vault("attack-export");
    let report = bridge(&mut coord)
        .export(&handle, &export_vault, NOW, VaultExportScope::Believed, None)
        .expect("export");
    assert_eq!(report.excluded_private_tier, 1);
    assert!(!all_markdown(&export_vault).contains("a restricted secret kept private"));

    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_dir_all(&export_vault);
}

#[test]
fn reimport_may_raise_sensitivity() {
    let (mut coord, handle) = open_one();
    let mut frame = CaptureFrame::new(
        "started normal, becomes secret",
        CaptureChannel::Typed,
        "tiers",
        LatticeAnchor::udc("000"),
        "owner",
        "test-v1",
    );
    frame.sensitivity = AdjectiveSensitivity::Normal;
    let drawer = coord.capture(&handle, frame, NOW).expect("capture");

    let vault = temp_vault("raise");
    write_note(
        &vault,
        "tiers/raise.md",
        &format!(
            "---\nroom: tiers\nmoot_id: {}\nsensitivity: secret\n---\nstarted normal, becomes secret\n",
            drawer.lineage_id
        ),
    );

    bridge(&mut coord)
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import");

    let frame = RecallFrame {
        filter_chain: vec![
            Filter::CurrentlyBelieve,
            Filter::Any(vec![
                Filter::UserConfirmed,
                Filter::Unconfirmed,
                Filter::AutomatedConfirmedOnly,
            ]),
            Filter::Any(vec![Filter::Trustworthy, Filter::RequiresConfirmation]),
            Filter::SensitivityAtMost(AdjectiveSensitivity::Secret),
        ],
        hydration_level: HydrationLevel::Full,
        limit: None,
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    let drawers = coord.recall(&handle, frame, NOW).expect("recall");
    let survivor = drawers
        .iter()
        .find(|d| d.lineage_id == drawer.lineage_id)
        .expect("drawer survives");
    assert_eq!(
        survivor.adjective_sensitivity(),
        AdjectiveSensitivity::Secret
    );

    let _ = std::fs::remove_dir_all(&vault);
}

// MARK: - Receipts

#[test]
fn export_writes_exactly_one_receipt_with_counts_and_now() {
    let (mut coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);
    let vault = temp_vault("receipt-export");

    bridge(&mut coord)
        .export(&handle, &vault, NOW, VaultExportScope::Believed, None)
        .expect("export");

    let receipts = coord
        .diary_entries(&handle, VaultBridge::RECEIPT_AGENT_NAME, 10)
        .expect("read receipts");
    assert_eq!(receipts.len(), 1);
    let receipt = &receipts[0];
    // The diary's filed_at is epoch seconds; the bridge's now is ms.
    assert_eq!(receipt.filed_at, NOW / 1000);
    assert_eq!(receipt.topic, "vault-receipt");
    assert!(receipt.entry.contains("\"operation\":\"vault-export\""));
    assert!(receipt.entry.contains("\"scope\":\"believed\""));
    assert!(receipt.entry.contains("\"notesExported\":2"));
    assert!(receipt.entry.contains("\"excludedSecretTier\":1"));
    assert!(receipt.entry.contains("\"excludedPrivateTier\":1"));
    // Spec § 5.6 decode: migration event, info severity, migration-tool actor.
    assert_eq!(receipt.event_class(), DiaryEventClass::Migration);
    assert_eq!(receipt.severity(), DiarySeverity::Info);
    assert_eq!(receipt.actor_class(), DiaryActorClass::MigrationTool);

    let _ = std::fs::remove_dir_all(&vault);
}

#[test]
fn import_writes_exactly_one_receipt_with_counts() {
    let (mut coord, handle) = open_one();
    let vault = temp_vault("receipt-import");
    write_note(
        &vault,
        "research/arrival.md",
        "---\nroom: research\n---\nA note that arrives.\n",
    );

    bridge(&mut coord)
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import");

    let receipts = coord
        .diary_entries(&handle, VaultBridge::RECEIPT_AGENT_NAME, 10)
        .expect("read receipts");
    assert_eq!(receipts.len(), 1);
    let receipt = &receipts[0];
    assert_eq!(receipt.filed_at, NOW / 1000);
    assert!(receipt.entry.contains("\"operation\":\"vault-import\""));
    assert!(receipt.entry.contains("\"drawersWritten\":1"));
    assert!(receipt.entry.contains("\"drawersUpdated\":0"));
    assert!(receipt.entry.contains("\"itemsSkipped\":0"));
    assert_eq!(receipt.event_class(), DiaryEventClass::Migration);

    let _ = std::fs::remove_dir_all(&vault);
}

#[test]
fn receipts_accumulate_per_run() {
    let (mut coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);

    for i in 0..2 {
        let vault = temp_vault(&format!("accumulate-{i}"));
        bridge(&mut coord)
            .export(&handle, &vault, NOW, VaultExportScope::Believed, None)
            .expect("export");
        let _ = std::fs::remove_dir_all(&vault);
    }

    let receipts = coord
        .diary_entries(&handle, VaultBridge::RECEIPT_AGENT_NAME, 10)
        .expect("read receipts");
    assert_eq!(receipts.len(), 2);
}

// VK-EXPORT-01 — ADR-007 Decision 2 tier-partition exercised end-to-end
// through the exchange adapter write side (mirrors the Swift bridge tests in
// ExchangeAdapterTests.swift): the bridge filters tiers and writes the
// receipt BEFORE the adapter sees notes; the adapter serializes exactly
// what it is handed.
#[test]
fn bridge_export_through_exchange_write_side_enforces_tiers_and_writes_receipt() {
    let (mut coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);
    let out = std::env::temp_dir()
        .join(format!("vk-export-01-bridge-{}", uuid::Uuid::new_v4()))
        .join("estate.json");

    // mut: VaultBridge::new requires &mut EstateCoordinator (dual-path intake fix, G7).
    let bridge = VaultBridge::new(
        &mut coord,
        Box::new(vault_kit::ExchangeAdapter::new()),
        DrawerMapping::new("tier-tests", "test-v1", false),
    );
    let report = bridge
        .export(&handle, &out, NOW, VaultExportScope::Believed, None)
        .expect("export");

    // ADR-007 Decision 2 tier partition flowed through unchanged.
    assert_eq!(report.notes_exported, 2);
    assert_eq!(report.excluded_private_tier, 1);
    assert_eq!(report.excluded_secret_tier, 1);

    // The written document carries no excluded-tier content anywhere and
    // decodes through the adapter's own read side.
    let document = std::fs::read_to_string(&out).expect("read document");
    assert!(document.contains("normal note"));
    assert!(document.contains("elevated note"));
    assert!(!document.contains("restricted note"));
    assert!(!document.contains("secret note"));
    let reread = vault_kit::ExchangeAdapter::new()
        .to_ir(&out)
        .expect("re-read through read side");
    assert_eq!(reread.len(), 2);

    // The audit receipt landed in the estate diary (ADR-007 D2).
    let receipts = coord
        .diary_entries(&handle, VaultBridge::RECEIPT_AGENT_NAME, 10)
        .expect("read receipts");
    assert_eq!(receipts.len(), 1);
    assert!(receipts[0].entry.contains("\"operation\":\"vault-export\""));
    assert!(receipts[0].entry.contains("\"notesExported\":2"));

    let _ = std::fs::remove_dir_all(out.parent().unwrap());
}

/// CAND-050: KG facts anchored to a secret-tier drawer must not appear in a
/// default-scope export. Export of a normal drawer's KG fact must be
/// unaffected; only the secret-anchored fact is excluded.
#[test]
fn cand050_kg_facts_excluded_for_secret_anchored_drawers() {
    let (mut coord, handle) = open_one();

    // Capture a normal drawer and a secret drawer, then anchor one KG fact to each.
    let mut normal_frame = CaptureFrame::new(
        "normal drawer content",
        CaptureChannel::Typed,
        "tiers",
        LatticeAnchor::udc("000"),
        "cand050-test",
        "test-v1",
    );
    normal_frame.sensitivity = AdjectiveSensitivity::Normal;
    let normal_drawer = coord.capture(&handle, normal_frame, NOW).expect("capture normal");

    let mut secret_frame = CaptureFrame::new(
        "secret drawer content",
        CaptureChannel::Typed,
        "tiers",
        LatticeAnchor::udc("000"),
        "cand050-test",
        "test-v1",
    );
    secret_frame.sensitivity = AdjectiveSensitivity::Secret;
    let secret_drawer = coord.capture(&handle, secret_frame, NOW).expect("capture secret");

    // Anchor one KG fact (a tag) to each drawer.
    coord
        .add_kg_fact(
            &handle,
            "tag:normal-tag",
            "tagged",
            &normal_drawer.id,
            &normal_drawer.id,
            NOW / 1000,
        )
        .expect("add normal KG fact");
    coord
        .add_kg_fact(
            &handle,
            "tag:secret-tag",
            "tagged",
            &secret_drawer.id,
            &secret_drawer.id,
            NOW / 1000,
        )
        .expect("add secret KG fact");

    // Export under the default (Believed) scope: secret drawer is excluded.
    let vault = temp_vault("cand050");
    bridge(&mut coord)
        .export(&handle, &vault, NOW, VaultExportScope::Believed, None)
        .expect("export");

    let exported_md = all_markdown(&vault);

    // The normal drawer and its KG-backed tag must appear in the export.
    assert!(
        exported_md.contains("normal drawer content"),
        "CAND-050: normal drawer content must appear in export"
    );
    assert!(
        exported_md.contains("normal-tag"),
        "CAND-050: normal-tier KG tag must appear in export"
    );
    // Secret-anchored KG fact (tag) must NOT appear — the tag value
    // is derived from the KG fact's subject field ("tag:secret-tag").
    assert!(
        !exported_md.contains("secret-tag"),
        "CAND-050: secret-anchored KG tag must not appear in default-scope export"
    );

    let _ = std::fs::remove_dir_all(&vault);
}
