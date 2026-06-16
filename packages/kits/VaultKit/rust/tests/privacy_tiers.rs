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

fn bridge(coord: &EstateCoordinator) -> VaultBridge<'_> {
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
    let (coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);
    let vault = temp_vault("default");

    let report = bridge(&coord)
        .export(&handle, &vault, NOW, VaultExportScope::Believed)
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
    let (coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);
    let vault = temp_vault("private");

    let report = bridge(&coord)
        .export(&handle, &vault, NOW, VaultExportScope::BelievedIncludingPrivate)
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
    let (coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);

    for scope in VaultExportScope::all_cases() {
        let vault = temp_vault(scope.as_str());
        bridge(&coord)
            .export(&handle, &vault, NOW, *scope)
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
    let (coord, handle) = open_one();
    let vault = temp_vault("arrival");
    write_note(
        &vault,
        "tiers/arrival.md",
        "---\nroom: tiers\nsensitivity: restricted\n---\nAn arriving private-tier note.\n",
    );

    let report = bridge(&coord)
        .import_vault(&vault, &handle, NOW)
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
    let (coord, handle) = open_one();
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
    bridge(&coord)
        .export(&handle, &vault, NOW, VaultExportScope::Believed)
        .expect("export");
    assert!(all_markdown(&vault).contains("sensitivity: elevated"));

    // Re-import into a fresh estate; the tier must survive the trip.
    let (coord_b, handle_b) = open_one();
    bridge(&coord_b)
        .import_vault(&vault, &handle_b, NOW)
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
    let (coord, handle) = open_one();
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

    bridge(&coord)
        .import_vault(&vault, &handle, NOW)
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
    let report = bridge(&coord)
        .export(&handle, &export_vault, NOW, VaultExportScope::Believed)
        .expect("export");
    assert_eq!(report.excluded_private_tier, 1);
    assert!(!all_markdown(&export_vault).contains("a restricted secret kept private"));

    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_dir_all(&export_vault);
}

#[test]
fn reimport_may_raise_sensitivity() {
    let (coord, handle) = open_one();
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

    bridge(&coord)
        .import_vault(&vault, &handle, NOW)
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
    let (coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);
    let vault = temp_vault("receipt-export");

    bridge(&coord)
        .export(&handle, &vault, NOW, VaultExportScope::Believed)
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
    let (coord, handle) = open_one();
    let vault = temp_vault("receipt-import");
    write_note(
        &vault,
        "research/arrival.md",
        "---\nroom: research\n---\nA note that arrives.\n",
    );

    bridge(&coord)
        .import_vault(&vault, &handle, NOW)
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
    let (coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);

    for i in 0..2 {
        let vault = temp_vault(&format!("accumulate-{i}"));
        bridge(&coord)
            .export(&handle, &vault, NOW, VaultExportScope::Believed)
            .expect("export");
        let _ = std::fs::remove_dir_all(&vault);
    }

    let receipts = coord
        .diary_entries(&handle, VaultBridge::RECEIPT_AGENT_NAME, 10)
        .expect("read receipts");
    assert_eq!(receipts.len(), 2);
}

// VK-EXPORT-01 — the 0125 tier machinery exercised end-to-end through the
// exchange adapter write side (mirrors the Swift bridge tests in
// ExchangeAdapterTests.swift): the bridge filters tiers and writes the
// receipt BEFORE the adapter sees notes; the adapter serializes exactly
// what it is handed.
#[test]
fn bridge_export_through_exchange_write_side_enforces_tiers_and_writes_receipt() {
    let (coord, handle) = open_one();
    capture_tier_corpus(&coord, &handle);
    let out = std::env::temp_dir()
        .join(format!("vk-export-01-bridge-{}", uuid::Uuid::new_v4()))
        .join("estate.json");

    let bridge = VaultBridge::new(
        &coord,
        Box::new(vault_kit::ExchangeAdapter::new()),
        DrawerMapping::new("tier-tests", "test-v1", false),
    );
    let report = bridge
        .export(&handle, &out, NOW, VaultExportScope::Believed)
        .expect("export");

    // Tier partition (0125) flowed through unchanged.
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
