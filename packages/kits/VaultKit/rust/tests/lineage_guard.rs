//! The boundary of the moot_id lineage-hijack guard, as a matched pair.
//!
//! Codex finding `de1284c737788191805d8063a94587a4` (path-based moot_id guard
//! allows same-path hijack). These two tests exist together, in one file, on
//! purpose: each alone is misleading, and the pair is the actual perimeter.
//!
//!   - `foreign_path_hostile_note_is_refiled_under_its_own_lineage` — the guard
//!     FIRES. A note at a path that is not the claimed lineage's export path,
//!     carrying that lineage's `moot_id` with a changed body, has its claim
//!     rejected and is filed under its own FNV-derived lineage. The victim is
//!     untouched.
//!
//!   - `same_path_hostile_content_is_indistinguishable_from_legitimate_edit` —
//!     the guard does NOT fire. A note at the claimed lineage's own expected
//!     export path keeps the claimed lineage and supersedes the drawer.
//!
//! **The second test documents a known limitation. It is NOT a defence.** A
//! changed file at the exported path is byte-for-byte indistinguishable from a
//! legitimate user edit of an exported note — export, edit, re-import is the
//! round-trip the feature exists to provide. No discriminator over the file can
//! separate "the user edited it" from "an attacker replaced it", because in both
//! cases the artifact is identical: a changed file at the exported path claiming
//! the exported `moot_id`. Strengthening the same-path check would either break
//! the round-trip or provide false assurance.
//!
//! Note also that `existing_stable_source_key_by_lineage` — the map the guard
//! compares against — is RECOMPUTED from current estate wing/room/slug on every
//! import. It is not persisted or authenticated provenance.
//!
//! Mirrors the Swift pair in `VaultBridgeTests`:
//! `mootIDHijackGuardBlocksBodyReplacement` (foreign path) and
//! `samepathHostileContentIsIndistinguishableFromLegitimateEdit` (same path).

use std::path::PathBuf;
use std::sync::Arc;

use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
use locus_kit::{
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::CaptureFrame,
};
use vault_kit::{DrawerMapping, ObsidianAdapter, VaultBridge, VaultExportScope};

/// Fixed operation instant (ms-since-epoch) so tests are deterministic.
const NOW: i64 = 1_765_000_000_000;

/// Open one in-memory estate and return the coordinator + handle.
///
/// Duplicated locally: `rust/tests/` has no shared support module, so every
/// integration test file carries its own fixtures.
fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let handle = coord
        .open(store, OwnerCredentials::new("vaultkit-lineage-guard-tests"), 0, 100)
        .expect("open");
    (coord, handle)
}

/// Write a minimal Markdown note to `vault/rel`.
fn write_note(vault: &PathBuf, rel: &str, text: &str) {
    let path = vault.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).expect("mkdir");
    std::fs::write(path, text).expect("write note");
}

/// Build a VaultBridge over the given coordinator. `classify_on_import` is
/// false so the tests exercise the lineage guard, not the classifier.
fn bridge(coord: &mut EstateCoordinator) -> VaultBridge<'_> {
    VaultBridge::new(
        coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::new("vaultkit-lineage-guard-tests", "test-v1", false),
    )
}

/// A unique temp vault path for one test.
fn temp_vault(tag: &str) -> PathBuf {
    std::env::temp_dir().join(format!("vaultkit-lineage-guard-{}-{}", tag, uuid::Uuid::new_v4()))
}

/// Recall currently-believed drawers (active, confirmed and unconfirmed, all
/// trust levels). Mirrors Swift `currentDrawers`.
fn current_drawers(coord: &EstateCoordinator, handle: &EstateHandle) -> Vec<locus_kit::drawer::Drawer> {
    let frame = RecallFrame {
        filter_chain: vec![
            Filter::CurrentlyBelieve,
            Filter::Any(vec![
                Filter::UserConfirmed,
                Filter::Unconfirmed,
                Filter::AutomatedConfirmedOnly,
            ]),
            Filter::Any(vec![Filter::Trustworthy, Filter::RequiresConfirmation]),
        ],
        hydration_level: HydrationLevel::Full,
        limit: Some(10_000_000),
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    coord.recall(handle, frame, NOW).expect("recall")
}

/// Walk all paths under `dir` recursively (files only).
fn walkdir_all(dir: &PathBuf) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                out.extend(walkdir_all(&p));
            } else {
                out.push(p);
            }
        }
    }
    out
}

/// Walk `.md` note files under `dir`, skipping OKF navigation files.
///
/// `index.md` and `log.md` are emitted by the adapter for progressive-
/// disclosure navigation and are not notes. Mirrors Swift `firstMDFile`.
fn walkdir_notes(dir: &PathBuf) -> Vec<PathBuf> {
    walkdir_all(dir)
        .into_iter()
        .filter(|p| p.extension().map_or(false, |e| e == "md"))
        .filter(|p| {
            let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
            stem != "index" && stem != "log"
        })
        .collect()
}

// ─────────────────────────────────────────────────────────────────
// Half 1 — FOREIGN path: the guard fires
// ─────────────────────────────────────────────────────────────────

/// A note at a path that is NOT the claimed lineage's export path, claiming that
/// lineage's `moot_id` with a different body, has its claim rejected: the frame
/// is rewritten to the note's own FNV lineage and the victim drawer is untouched.
///
/// This is the half of the boundary that IS a defence.
#[test]
fn foreign_path_hostile_note_is_refiled_under_its_own_lineage() {
    let (mut coord, handle) = open_one();

    // 1. Capture the victim drawer through the normal path.
    let victim_content = "Victim body: original content that must not be replaced.";
    let victim_frame = CaptureFrame::new(
        victim_content,
        CaptureChannel::Typed,
        "target",
        LatticeAnchor::udc("000"),
        "owner",
        "test-v1",
    );
    let victim = coord.capture(&handle, victim_frame, NOW).expect("capture victim");

    // 2. Plant a hostile note at a FOREIGN path claiming the victim's moot_id.
    let vault = temp_vault("foreign");
    write_note(
        &vault,
        "attack/hostile.md",
        &format!(
            "---\nroom: target\nmoot_id: {}\n---\nAttacker-controlled replacement content.\n",
            victim.lineage_id
        ),
    );

    // 3. Import.
    let report = bridge(&mut coord)
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import hostile vault");

    // 4. The guard fires: the moot_id claim is rejected, so the note lands as a
    //    NEW drawer under its own FNV lineage rather than updating the victim.
    assert_eq!(
        report.drawers_written, 1,
        "foreign-path hostile note must land as a new drawer, not an update"
    );
    assert_eq!(
        report.drawers_updated, 0,
        "foreign-path hostile note must not update any existing drawer"
    );

    // 5. The victim is untouched.
    let all = current_drawers(&coord, &handle);
    assert_eq!(
        all.len(),
        2,
        "estate must hold the victim drawer + the isolated hostile drawer"
    );
    let victim_after = all
        .iter()
        .find(|d| d.lineage_id == victim.lineage_id)
        .expect("victim lineage must still exist");
    assert_eq!(
        victim_after.content, victim_content,
        "victim content must be unchanged after a foreign-path hostile import"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

// ─────────────────────────────────────────────────────────────────
// Half 2 — SAME path: the guard does NOT fire (known limitation)
// ─────────────────────────────────────────────────────────────────

/// A note at the claimed lineage's OWN expected export path, carrying that
/// lineage's `moot_id` with a different body, keeps the claimed lineage and
/// supersedes the drawer.
///
/// **This pins a known limitation, not a defence.** A passing run is not
/// evidence that same-path spoofing is blocked — it is not. See the module
/// header for why no discriminator can close this and why attempting one would
/// break the legitimate round-trip.
#[test]
fn same_path_hostile_content_is_indistinguishable_from_legitimate_edit() {
    let (mut coord, handle) = open_one();

    // 1. Capture the victim drawer normally, so its lineage_id is random rather
    //    than FNV-derived — the same shape a real user's drawer has.
    let victim_content = "Victim body: the content a hostile same-path note will replace.";
    let victim_frame = CaptureFrame::new(
        victim_content,
        CaptureChannel::Typed,
        "samepath-hijack",
        LatticeAnchor::udc("000"),
        "owner",
        "test-v1",
    );
    let victim = coord.capture(&handle, victim_frame, NOW).expect("capture victim");

    // 2. Export. This is what makes the attack possible at all: it writes the
    //    drawer to a deterministic vault path and stamps moot_id =
    //    victim.lineage_id into the frontmatter, so both the path and the UUID
    //    become predictable to anyone who can read the vault.
    let vault = temp_vault("samepath");
    bridge(&mut coord)
        .export(&handle, &vault, NOW, VaultExportScope::Believed, None)
        .expect("export victim to vault");

    let notes = walkdir_notes(&vault);
    assert_eq!(notes.len(), 1, "export must have produced exactly one note file");
    let exported_file = &notes[0];

    // 3. Replace the BODY in place, leaving the exported frontmatter — and
    //    therefore the victim's moot_id — untouched. This is the hostile note:
    //    planted at the victim's own export path, claiming the victim's
    //    lineage, carrying attacker content.
    let raw = std::fs::read_to_string(exported_file).expect("read exported note");
    assert!(
        raw.contains(victim_content),
        "exported note must carry the victim body verbatim"
    );
    let hostile_body = "Attacker-controlled replacement planted at the victim's export path.";
    std::fs::write(exported_file, raw.replace(victim_content, hostile_body))
        .expect("write hostile body at the same path");

    // 4. Re-import.
    let report = bridge(&mut coord)
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("re-import same-path hostile note");

    // 5. CURRENT, SHIPPING BEHAVIOUR — the guard does not fire. The note's
    //    stable_source_key equals the key recomputed for the claimed lineage, so
    //    is_path_foreign is false, the FNV rewrite is skipped, and the import is
    //    processed as an ordinary update.
    assert_eq!(
        report.drawers_updated, 1,
        "same-path note with a changed body is accepted as an update"
    );
    assert_eq!(
        report.drawers_written, 0,
        "same-path note is not isolated into a new drawer"
    );

    let all = current_drawers(&coord, &handle);
    assert_eq!(
        all.len(),
        1,
        "estate holds one drawer — the victim lineage was superseded, not duplicated"
    );
    assert_eq!(
        all[0].lineage_id, victim.lineage_id,
        "the CLAIMED lineage is retained: the moot_id claim was not rejected"
    );
    assert!(
        all[0].content.contains(hostile_body),
        "the victim's active body is now the attacker's content — this is the limitation"
    );

    let _ = std::fs::remove_dir_all(&vault);
}
