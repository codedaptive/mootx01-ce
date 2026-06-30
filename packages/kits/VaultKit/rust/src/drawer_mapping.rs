//! DrawerMapping — `NoteIR` ⇄ substrate `Drawer`/`Tunnel` over the GLK
//! and LocusKit **public** API only.
//!
//! This is the layer where the bridge meets the substrate. It never reaches
//! a substrate primitive, schema, or bitmap directly — it constructs
//! `CaptureFrame` / `TunnelCaptureFrame` values and issues them through the
//! `EstateCoordinator` verb surface (`capture`, `recall`, `recall_tunnels`)
//! and, for standalone tunnel capture, through the `Estate` that the
//! coordinator exposes via `estate_for`.
//!
//! ## Invariant I-5 (binding)
//!
//! `capture` rejects any frame with an empty `content`, `room`, `added_by`,
//! `embedding_model_id`, or `lattice_anchor.udc_code`. Import therefore
//! supplies all five non-empty on every drawer, or the note is skipped before
//! a malformed frame is ever emitted.
//!
//! ## FNV-1a 128-bit lineage_id — conformance anchor
//!
//! The `lineage_id` derivation in `DrawerMapping::lineage_id` must produce
//! byte-identical output to Swift `DrawerMapping.lineageID(forStableSourceKey:)`
//! for the same input. Both implement FNV-1a 128-bit over the key's UTF-8
//! bytes using the standard offset basis and prime. No external dependency is
//! needed: FNV-1a is trivial portable arithmetic. The cross-language vector
//! test in `tests/fnv_vector.rs` asserts this invariant.
//!
//! FNV-1a 128-bit constants:
//!   offset basis: 0x6c62272e07bb0142_62b821756295c58d  (high, low)
//!   prime:        0x0000000001000000_000000000000013B  (high, low)

use crate::error::VaultKitError;
use crate::note_ir::{NoteIR, OccurredAt, WikiLink};
use crate::vault_export_scope::VaultExportScope;
use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle, intake::WriteMode};
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    drawer::Drawer,
    drawer_operational::{CaptureChannel, DrawerFeatureFlags},
    estate_types::LatticeAnchor,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::{CaptureFrame, TunnelCaptureFrame},
    kg_fact::KGFact,
    node_store::NodeStore,
    provenance::{Channel, SourceType},
    tunnel::Tunnel,
    tunnel_operational::{TunnelKind, TunnelOriginClass},
};
use std::sync::Arc;
use uuid::Uuid;

/// Resolve a batch of drawer parent_node_ids to (wing_name, room_name)
/// pairs using the estate's NodeStore. ADR-017 removed wing/room from
/// the Drawer struct; consumers obtain display names from the node tree.
///
/// Returns an empty map when the estate has no node store (legacy estates
/// opened before ADR-017). Callers fall back to empty strings for
/// unresolved IDs.
pub fn resolve_drawer_node_names(
    coordinator: &EstateCoordinator,
    handle: &EstateHandle,
    drawers: &[Drawer],
) -> std::collections::HashMap<String, (String, String)> {
    let estate = match coordinator.estate_for(handle) {
        Ok(e) => e,
        Err(_) => return std::collections::HashMap::new(),
    };
    let ns = match estate.node_store() {
        Some(ns) => ns,
        None => return std::collections::HashMap::new(),
    };
    build_node_name_map(ns, drawers)
}

/// Build a lookup map from parent_node_id → (wing_name, room_name)
/// for the given drawers. Each room node (depth 2) yields its
/// display_name as the room name; its parent wing node (depth 1)
/// yields the wing name.
fn build_node_name_map(
    ns: &Arc<NodeStore>,
    drawers: &[Drawer],
) -> std::collections::HashMap<String, (String, String)> {
    let mut map = std::collections::HashMap::new();
    for drawer in drawers {
        if map.contains_key(&drawer.parent_node_id) || drawer.parent_node_id.is_empty() {
            continue;
        }
        let room_uuid = match Uuid::parse_str(&drawer.parent_node_id) {
            Ok(u) => u,
            Err(_) => continue,
        };
        let room_node = match ns.get_node(room_uuid) {
            Ok(Some(n)) => n,
            _ => continue,
        };
        let wing_name = if let Some(wing_uuid) = room_node.parent_id {
            match ns.get_node(wing_uuid) {
                Ok(Some(w)) => w.display_name,
                _ => String::new(),
            }
        } else {
            String::new()
        };
        map.insert(drawer.parent_node_id.clone(), (wing_name, room_node.display_name));
    }
    map
}

// MARK: - ExportProjection

/// The notes an export projects plus the per-tier exclusion counts the
/// ADR-007 Decision 2 bulk-channel rules produced. Exclusions are reported,
/// never silent (zero-loss reporting symmetry with C-13). Mirrors Swift
/// `DrawerMapping.ExportProjection`.
#[derive(Debug, Clone, PartialEq)]
pub struct ExportProjection {
    /// Drawers that passed the scope filters AND the tier rules, projected
    /// to `NoteIR`.
    pub notes: Vec<NoteIR>,
    /// Secret-tier drawers the scope filters admitted but the bulk channel
    /// excluded. Secret never rides bulk export, under any scope.
    pub excluded_secret_tier: usize,
    /// Private-tier (`Restricted`) drawers the scope filters admitted but
    /// the bulk channel excluded because the scope does not carry the
    /// explicit private-tier opt-in (`includes_private_tier`).
    pub excluded_private_tier: usize,
}

// MARK: - ImportOutcome

/// Outcome of importing a single note. Mirrors Swift `DrawerMapping.ImportOutcome`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImportOutcome {
    /// A drawer was captured for a new lineage.
    Written { tunnels_created: usize, fdc_classified: bool },
    /// A re-import superseded the existing drawer for this lineage.
    Updated { tunnels_created: usize, fdc_classified: bool },
    /// The note could not be imported (e.g. empty content would violate I-5);
    /// nothing was written.
    Skipped { reason: String },
    /// Re-import of a note whose lineage exists and content is byte-identical
    /// to the active drawer. No supersession, no UUID rotation — idempotent
    /// no-op. Fixes FINDING-1a. Mirrors Swift `.skippedUnchanged`.
    SkippedUnchanged,
    /// Re-import of a note whose lineage was previously erased (withdrawn)
    /// in the estate. The tombstone is respected; the note is NOT resurrected.
    /// Fixes FINDING-1b. Mirrors Swift `.skippedTombstoned`.
    SkippedTombstoned,
    /// A DisciplineViolation was raised AFTER the supersession cascade already
    /// committed the successor drawer row (add_drawer_with_cascade Step 1:
    /// gated_capture) but before the predecessor belief-state flip (Step 4:
    /// mutate_state) completed. The estate contains an orphaned successor row
    /// alongside the un-flipped predecessor. This is NOT a clean skip — unlike
    /// `Skipped`, the write was partially applied. The count is surfaced in
    /// `ImportReport.drawers_skipped_partial_write` (zero-loss invariant C-13).
    /// Mirrors Swift `.skippedWithPartialWrite`. Only possible on the update
    /// path (is_update == true, i.e. an existing lineage was targeted).
    SkippedWithPartialWrite { reason: String },
}

// MARK: - DrawerMapping

/// Policy values for import. Mirrors Swift `DrawerMapping`.
#[derive(Debug, Clone)]
pub struct DrawerMapping {
    /// Default actor identifier stamped on imported drawers and tunnels.
    /// Non-empty so I-5's `added_by` guard always holds.
    pub added_by: String,

    /// Default embedding-model identifier stamped on imported drawers.
    /// Non-empty so I-5's `embedding_model_id` guard always holds.
    pub embedding_model_id: String,

    /// Reserved for future FDC classification. Stored but not read by import
    /// paths — notes always land with explicit frontmatter `udc` when present
    /// or the `fallback_udc` sentinel otherwise.
    pub classify_on_import: bool,

    /// The deterministic fallback UDC used when no live FDC anchor and no
    /// explicit frontmatter `udc` is available. `"000"` is the repo's
    /// sentinel for unclassified/migrated content.
    pub fallback_udc: String,
}

impl Default for DrawerMapping {
    fn default() -> Self {
        Self::new("vaultkit-import", "vaultkit-noembed-v1", true)
    }
}

impl DrawerMapping {
    pub fn new(
        added_by: impl Into<String>,
        embedding_model_id: impl Into<String>,
        classify_on_import: bool,
    ) -> Self {
        Self {
            added_by: added_by.into(),
            embedding_model_id: embedding_model_id.into(),
            classify_on_import,
            fallback_udc: "000".to_owned(),
        }
    }

    // MARK: - Export: estate → IR

    /// Read an estate's drawers and outgoing `.references` tunnels and project
    /// each drawer to a `NoteIR`, enforcing the ADR-007 Decision 2 privacy-tier
    /// rules and counting what they excluded. Mirrors Swift
    /// `DrawerMapping.export(kit:handle:scope:)`.
    ///
    /// Drawers are recalled using the `scope` parameter's filter chain plus an
    /// explicit `Filter::SensitivityAtMost(Secret)`. The explicit filter
    /// suppresses the recall evaluator's implicit `SensitivityAtMost(Elevated)`
    /// default and raises the ceiling to secret so all tiers are visible here.
    /// This makes secret/private exclusions countable: the tier rules are then
    /// enforced by partition — secret is always excluded, restricted is excluded
    /// unless `scope.includes_private_tier()`, and each exclusion is counted.
    ///
    /// `now` is the snapshot instant in milliseconds-since-epoch, passed by the
    /// caller so this function is deterministic (no internal wall-clock access).
    pub fn export(
        &self,
        coordinator: &EstateCoordinator,
        handle: &EstateHandle,
        now: i64,
        scope: VaultExportScope,
    ) -> Result<ExportProjection, VaultKitError> {
        // Export uses an explicit full-scan limit (see comment below) — the
        // earlier `limit: None` form was stale and has been superseded.
        let mut filter_chain = scope.filter_chain();
        filter_chain.push(Filter::SensitivityAtMost(AdjectiveSensitivity::Secret));
        // VK-EXPORT-FIX: pass an explicit limit so the recall scan is a full
        // projection of all believed drawers, not capped at the recall
        // candidate floor (256). Export is a pure filter scan (no query, no
        // scoring); returning the complete set in stable order is correct.
        // 10_000_000 (not usize::MAX) matches the Swift leg and is unreachable
        // by any realistic estate. trace_limit None: export does not
        // participate in the reward cycle.
        let recall_frame = RecallFrame {
            filter_chain,
            hydration_level: HydrationLevel::Full,
            limit: Some(10_000_000),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let recalled = coordinator
            .recall(handle, recall_frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;

        // VK-EXPORT-FAILOUD: if the filtered recall returned nothing, verify
        // whether the estate is genuinely empty (or all drawers legitimately
        // filtered out by scope) versus the corpus being bricked (all rows
        // skipped due to corrupt timestamps by the scan-resilience path).
        //
        // Strategy: two-step check.
        //   Step 1 — raw COUNT(*) on the drawers table. If 0, the estate is
        //            genuinely empty — zero recall is correct, no bricking.
        //   Step 2 — if rows exist in storage, probe with an unfiltered recall
        //            (no scope, no sensitivity filter, limit 1). If THAT also
        //            returns 0 and raw COUNT > 0, then ALL rows are corrupt and
        //            the export must fail loud. If the unfiltered probe returns
        //            >= 1, the scope/sensitivity filter legitimately excluded
        //            everything (e.g. all drawers are secret or unconfirmed).
        //
        // Mirrors Swift `DrawerMapping.export(kit:handle:scope:)`.
        if recalled.is_empty() {
            let raw_count = coordinator
                .count_drawer_rows(handle)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
            if raw_count > 0 {
                // Storage has rows. Probe with a minimal unfiltered recall
                // (no filters, limit 1, structured hydration — no blobs) to
                // distinguish "scope filtered everything out" from "all rows
                // are corrupt".
                let probe_frame = RecallFrame {
                    filter_chain: vec![],
                    hydration_level: HydrationLevel::Structured,
                    limit: Some(1),
                    ordering: Ordering::ByCaptureTimeDesc,
                    as_of: None,
                    trace_limit: None,
                };
                let probe = coordinator
                    .recall(handle, probe_frame, now)
                    .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
                if probe.is_empty() {
                    // Storage has rows but even an unfiltered scan returns
                    // nothing — all rows are corrupt. Fail loud.
                    return Err(VaultKitError::ExportBrickedEstate {
                        drawer_count: raw_count,
                        reason: format!(
                            "recall returned 0 drawers even without scope filters, but storage contains {} drawer rows — likely corrupt timestamps in the drawers table. Run a repair before exporting.",
                            raw_count
                        ),
                    });
                }
                // probe returned >= 1 row — scope or sensitivity filters
                // legitimately excluded all drawers. Not bricking.
            }
        }

        // ADR-007 Decision 2 tier partition. The predicates encode the
        // normative 4→3 mapping (Normal → normal+elevated, Private →
        // restricted, Secret → secret) — see `AdjectiveSensitivity` in
        // LocusKit's `adjectives.rs`.
        let mut drawers: Vec<Drawer> = Vec::with_capacity(recalled.len());
        let mut excluded_secret = 0usize;
        let mut excluded_private = 0usize;
        for drawer in recalled {
            // Hint drawers (AI_Charter_Hint room) are normal drawers — no export
            // exclusion. They carry user-visible memory content and are embedded
            // and recalled like any other drawer. CHARTER_ADDED_BY guard removed.
            let tier = drawer.adjective_sensitivity();
            if tier.is_excluded_from_bulk() {
                // Secret never rides bulk channels, under any scope.
                excluded_secret += 1;
            } else if tier.requires_owner_key_for_bulk() && !scope.includes_private_tier() {
                // Private tier rides bulk only under the explicit opt-in scope.
                excluded_private += 1;
            } else {
                drawers.push(drawer);
            }
        }

        // Resolve display names (wing, room) for all filtered drawers in one
        // batch. ADR-017 removed wing/room from the Drawer struct; consumers
        // obtain them from the node tree via Estate.node_store().
        let node_names = resolve_drawer_node_names(coordinator, handle, &drawers);

        // Fetch tunnels once per distinct source wing, not once per drawer.
        // Wing names are resolved from the node tree (ADR-017).
        let wings: std::collections::HashSet<String> = drawers
            .iter()
            .filter_map(|d| node_names.get(&d.parent_node_id).map(|(w, _)| w.clone()))
            .collect();
        let mut tunnels_by_wing: std::collections::HashMap<String, Vec<Tunnel>> =
            std::collections::HashMap::new();
        for wing in &wings {
            let tunnels = coordinator
                .recall_tunnels(handle, wing)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
            tunnels_by_wing.insert(wing.clone(), tunnels);
        }

        // Query all KG facts once for the estate, then group by source_drawer_id
        // so each drawer's tags and kind can be reconstructed without an N-per-drawer
        // round-trip. Drawers with no KG facts get an empty slice.
        // Mirrors Swift DrawerMapping.export kgFactsByDrawerID grouping.
        //
        // CAND-050: only include KG facts anchored to a drawer in the
        // scope-filtered `drawers` set. Facts anchored to excluded drawers (secret
        // tier, out-of-scope, etc.) must not appear in the export — they could
        // leak the existence of excluded content through the KG tag/kind surface.
        // Build the included-drawer ID set before the fact loop so the guard is O(1).
        let included_drawer_ids: std::collections::HashSet<&str> =
            drawers.iter().map(|d| d.id.as_str()).collect();
        let all_kg_facts = coordinator
            .recall_kg_facts(handle)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let mut kg_facts_by_drawer_id: std::collections::HashMap<String, Vec<&KGFact>> =
            std::collections::HashMap::new();
        for fact in &all_kg_facts {
            // Skip facts with no anchor (can't be attributed to any drawer).
            // Skip facts anchored to drawers not in the current export scope
            // (CAND-050: secret-tier or otherwise excluded drawer anchors must
            // not bleed KG metadata into the export).
            if fact.source_drawer_id.is_empty()
                || !included_drawer_ids.contains(fact.source_drawer_id.as_str())
            {
                continue;
            }
            kg_facts_by_drawer_id
                .entry(fact.source_drawer_id.clone())
                .or_default()
                .push(fact);
        }

        // CAND-EXP-PROV: Build the set of exportable "wing/room" pairs from the
        // already-scope-filtered `drawers` vec. Used below to filter `_distilled_from`
        // provenance tunnel targets so a normal exported factoid cannot leak the location
        // (wing/room) of a secret or scope-excluded restricted source drawer.
        //
        // Rationale: provenance tunnels carry only `target_wing`/`target_room` — not a
        // `target_drawer_id` (it is None in this path; see import at `target_drawer_id = None`).
        // The check must therefore be keyed on the wing+room pair rather than the drawer id.
        // The `included_drawer_ids` set above covers KG fact anchors (keyed by drawer.id);
        // this set covers provenance tunnel targets (keyed by wing/room display name).
        //
        // Round-trip note: dropping an excluded target from `distilled_from_sources`
        // means the provenance edge to that excluded drawer will NOT survive a vault
        // round-trip (export → re-import). This is the correct privacy behavior —
        // the excluded drawer's location must not be persisted in any exported artifact.
        let included_wing_rooms: std::collections::HashSet<String> = drawers
            .iter()
            .filter_map(|d| {
                node_names
                    .get(&d.parent_node_id)
                    .map(|(w, r)| format!("{}/{}", w, r))
            })
            .collect();

        let notes: Vec<NoteIR> = drawers
            .iter()
            .map(|drawer| {
                let (wing, room) = node_names
                    .get(&drawer.parent_node_id)
                    .cloned()
                    .unwrap_or_default();
                let refs: Vec<&Tunnel> = tunnels_by_wing
                    .get(&wing)
                    .map(|ts| {
                        ts.iter()
                            .filter(|t| {
                                if t.source_drawer_id.as_deref() != Some(&drawer.id) {
                                    return false;
                                }
                                if t.kind != TunnelKind::References {
                                    return false;
                                }
                                // Content-reference tunnels (non-provenance) are always included.
                                // Provenance tunnels (`_distilled_from`) are included only if their
                                // target drawer's wing/room pair is in the exportable set. This prevents
                                // a normal exported factoid from leaking the location of a secret or
                                // restricted-under-default-scope source drawer via frontmatter.
                                if t.label == "_distilled_from" {
                                    let target_key = format!("{}/{}", t.target_wing, t.target_room);
                                    return included_wing_rooms.contains(&target_key);
                                }
                                true
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let drawer_facts: Vec<KGFact> = kg_facts_by_drawer_id
                    .get(&drawer.id)
                    .map(|fs| fs.iter().map(|f| (*f).clone()).collect())
                    .unwrap_or_default();
                Self::note_ir_from(drawer, &wing, &room, &refs, &drawer_facts)
            })
            .collect();

        Ok(ExportProjection {
            notes,
            excluded_secret_tier: excluded_secret,
            excluded_private_tier: excluded_private,
        })
    }

    /// Pure projection of one drawer + its outgoing `.references` tunnels +
    /// its anchored KG facts to a `NoteIR`. Mirrors Swift
    /// `DrawerMapping.noteIR(from:references:kgFacts:)`.
    ///
    /// `kg_facts` is the subset of KG facts whose `source_drawer_id` matches
    /// `drawer.id`. The export path pre-fetches all facts once and groups by
    /// drawer id; this function reconstructs `NoteIR.tags` and `NoteIR.kind`
    /// from the facts:
    ///
    ///   - Facts with `subject.starts_with("tag:")` and `predicate == "tagged"`
    ///     become the drawer's tag list (hard-close #29-A round-trip).
    ///   - A fact with `subject == "record:kind"` and `predicate == "is"`
    ///     becomes the drawer's kind discriminator (hard-close #29-B round-trip).
    ///
    /// ADR-016 vault layout:
    ///   - stable_source_key: `"<wing>/<room>/<slug>"` — wing is the top-level
    ///     vault folder (ADR-016 Consequences: wing = top folder; all drawers
    ///     including hint memories in AI_Charter_Hint room export normally).
    ///     Layout is wing-aware and wing-scopable.
    ///   - frontmatter gains `moot_id`: the drawer's `lineage_id` UUID string
    ///     (the STABLE UUID, not `drawer.id` which the supersession cascade re-mints).
    ///   - original_path: the substrate room (not the vault path).
    ///   - NoteIR.moot_id: set to `drawer.lineage_id` for identity pass-through.
    ///
    /// Wing round-trip note (ADR-016): wing is preserved in the vault folder path
    /// AND in the `wing` frontmatter key. On re-import, `make_capture_frame` reads
    /// the wing from `frontmatter["wing"]` and (a) strips it from path_components
    /// used for the room value and (b) sets `CaptureFrame.wing` so the capture verb
    /// routes the drawer into the correct named wing. The round-trip is fully
    /// faithful: a drawer exported from "User Canon" re-imports into "User Canon",
    /// not into `DEFAULT_WING_NAME`.
    pub fn note_ir_from(drawer: &Drawer, wing: &str, room: &str, references: &[&Tunnel], kg_facts: &[KGFact]) -> NoteIR {
        // Human-readable slug from the drawer's content. Collision-safe via UUID suffix.
        let slug = Self::slug(&drawer.content, &drawer.id);
        // Path: <wing>/<room>/<slug> — wing is the top-level vault folder (ADR-016).
        // Wing and room are resolved from the node tree (ADR-017) and passed by the caller.
        let stable_key = format!("{}/{}/{}", wing, room, slug);

        let mut frontmatter: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        frontmatter.insert("wing".to_owned(), wing.to_owned());
        frontmatter.insert("room".to_owned(), room.to_owned());
        frontmatter.insert("udc".to_owned(), drawer.udc_code.clone());
        frontmatter.insert("addedBy".to_owned(), drawer.added_by.clone());
        frontmatter.insert("embeddingModelID".to_owned(), drawer.embedding_model_id.clone());
        // Parity with Swift DrawerMapping.noteIRFrom: capture channel and content
        // kind ride frontmatter as their integer raw values so a round-trip preserves
        // the operational-bitmap axes.
        frontmatter.insert("captureChannel".to_owned(), drawer.capture_channel().raw_value().to_string());
        frontmatter.insert("contentKind".to_owned(), drawer.content_kind().raw_value().to_string());
        // moot_id: the STABLE lineage UUID. On re-import this wins over the FNV
        // hash of the stable_source_key as the lineage_id for the capture frame.
        // Using lineage_id (not drawer.id) ensures renames and re-exports don't
        // mint a new lineage — the drawer is always found by its stable UUID.
        frontmatter.insert("moot_id".to_owned(), drawer.lineage_id.to_string());
        // Origin date rides frontmatter (no substrate origin-date column).
        // `created:` is the Obsidian key the adapter reads back.
        // drawer.event_time is epoch SECONDS (not milliseconds) — use
        // secs_to_iso8601 to avoid the ÷1000 double-conversion that
        // produced 1970-01-21 dates for typical second-range timestamps.
        let event_iso = secs_to_iso8601(drawer.event_time);
        frontmatter.insert("created".to_owned(), event_iso.clone());

        if let Some(qid) = &drawer.wikidata_qid {
            if !qid.is_empty() {
                frontmatter.insert("wikidataQID".to_owned(), qid.clone());
            }
        }
        // Sensitivity rides frontmatter so a round-trip preserves the tier
        // (ADR-007 Decision 2; import reads the key back into
        // `CaptureFrame.sensitivity`). `Normal` is omitted — it is the
        // capture default, so absence round-trips to the same value and
        // pre-existing exports stay byte-identical.
        let tier = drawer.adjective_sensitivity();
        if tier != AdjectiveSensitivity::Normal {
            frontmatter.insert("sensitivity".to_owned(), Self::sensitivity_label(tier).to_owned());
        }

        // Bug N fix: `_distilled_from` tunnels are provenance graph edges, not body
        // content. Rendering them as wikilinks (or standard-md links) into the note
        // body causes two problems: (a) the body text gets the literal markdown link
        // appended (e.g. `[_distilled_from](../../_distilled_from.md)`), and (b) on
        // re-import that appended text is stored as the drawer's content, permanently
        // corrupting the factoid. Provenance tunnels must be serialized as structured
        // frontmatter that the import path can reconstruct as tunnels without touching
        // the content field.
        //
        // Separation: filter into provenance tunnels (`label == "_distilled_from"`) and
        // regular content-reference tunnels. Only content-reference tunnels become
        // wikilinks in the `links` array; provenance tunnels ride the new frontmatter
        // key `distilled_from_sources` as "targetWing/targetRoom" entries (semicolon-
        // separated, deterministically sorted). The import path reads this key and
        // reconstructs the tunnels without injecting text into content.
        let provenance_tunnels: Vec<&&Tunnel> =
            references.iter().filter(|t| t.label == "_distilled_from").collect();
        let content_tunnels: Vec<&&Tunnel> =
            references.iter().filter(|t| t.label != "_distilled_from").collect();

        // Each content `.references` tunnel's label carries the raw wikilink text
        // that produced it on import, so export renders it back verbatim.
        let links: Vec<WikiLink> = content_tunnels
            .iter()
            .map(|t| WikiLink::new(t.label.clone(), None, t.label.clone()))
            .collect();

        // Provenance tunnels encoded as "targetWing/targetRoom" pairs so the import
        // path can reconstruct each `_distilled_from` tunnel from frontmatter alone.
        // Sorted for deterministic output so round-trip comparisons are stable.
        if !provenance_tunnels.is_empty() {
            let mut targets: Vec<String> = provenance_tunnels
                .iter()
                .map(|t| format!("{}/{}", t.target_wing, t.target_room))
                .collect();
            targets.sort();
            frontmatter.insert(
                "distilled_from_sources".to_owned(),
                targets.join(";"),
            );
        }

        // Reconstruct tags from KG facts (hard-close #29-A round-trip).
        // Facts with subject "tag:<t>" and predicate "tagged" were filed on
        // import; the tag value is the suffix after the "tag:" prefix.
        // Sorted for stable, deterministic output matching the Swift port.
        let mut tags: Vec<String> = kg_facts
            .iter()
            .filter(|f| f.subject.starts_with("tag:") && f.predicate == "tagged")
            .map(|f| f.subject["tag:".len()..].to_owned())
            .collect();
        tags.sort();

        // Reconstruct kind from KG facts (hard-close #29-B round-trip).
        // A fact with subject "record:kind" and predicate "is" was filed on
        // import when kind != "note"; absence means the default "note" kind.
        let kind = kg_facts
            .iter()
            .find(|f| f.subject == "record:kind" && f.predicate == "is")
            .map(|f| f.object.clone())
            .unwrap_or_else(|| "note".to_owned());

        let mut note = NoteIR::with_moot_id(
            stable_key,
            vec![crate::note_ir::Block::markdown(drawer.content.clone())],
            frontmatter,
            links,
            tags,
            room.to_owned(), // original_path: room only — no wing prefix (ADR-017: resolved from node tree)
            Some(OccurredAt::new(event_iso)),
            None,
            Some(drawer.lineage_id), // moot_id: the stable lineage UUID
        );
        note.kind = kind;
        note
    }

    // MARK: - Slug derivation (Decision B1)

    /// Derive a human-readable slug from a note's content for use in the
    /// vault filename. The slug is derived from the first Markdown heading
    /// (`# text`) encountered on any line, falling back to the first
    /// non-empty line. Sanitized to `[a-z0-9-]` max 60 characters.
    /// A UUID-prefix fallback is used when content is empty or all-whitespace.
    ///
    /// Mirrors Swift `DrawerMapping.slug(from:id:)`.
    pub fn slug(content: &str, id: &str) -> String {
        let mut first_line: Option<String> = None;
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Some(heading) = trimmed.strip_prefix("# ") {
                // First heading on any line wins.
                return Self::sanitize_slug(heading);
            }
            // Capture the first non-empty, non-heading line as fallback.
            if first_line.is_none() {
                first_line = Some(trimmed.to_owned());
            }
        }
        if let Some(line) = first_line {
            let s = Self::sanitize_slug(&line);
            if !s.is_empty() {
                return s;
            }
        }
        // UUID-prefix fallback for empty/whitespace-only content.
        // Truncate the id to a short prefix (8 hex chars) for readability.
        let prefix = id.replace('-', "");
        format!("note-{}", &prefix[..8.min(prefix.len())])
    }

    /// Sanitize a string into a slug: lowercase, collapse sequences of
    /// non-alphanumeric characters to a single `-`, trim leading/trailing
    /// `-`, truncate to 60 characters. Mirrors Swift `DrawerMapping.sanitizeSlug(_:)`.
    pub fn sanitize_slug(input: &str) -> String {
        let lowered = input.to_lowercase();
        // Replace any run of non-alphanumeric chars with a single `-`.
        let mut result = String::with_capacity(lowered.len());
        let mut last_was_sep = true; // start true to trim leading `-`
        for ch in lowered.chars() {
            if ch.is_alphanumeric() {
                result.push(ch);
                last_was_sep = false;
            } else if !last_was_sep {
                result.push('-');
                last_was_sep = true;
            }
        }
        // Trim trailing `-`
        let trimmed = result.trim_end_matches('-');
        // Truncate to 60 characters with trailing-hyphen trim.
        // Parity with Swift DrawerMapping.sanitizeSlug: `.prefix(60)`
        // hard-cut (no word-boundary seek), then strip trailing hyphens.
        if trimmed.len() <= 60 {
            trimmed.to_owned()
        } else {
            trimmed[..60].trim_end_matches('-').to_owned()
        }
    }

    // MARK: - Import: IR → estate via the capture seam

    /// Import one note: build a `CaptureFrame`, capture the drawer through the
    /// GLK verb surface, then create the note's `.references` tunnels (de-
    /// duplicated against `existing_tunnel_signatures` so a re-import adds no
    /// duplicates). Mirrors Swift `DrawerMapping.importNote(_:kit:handle:...)`.
    ///
    /// `now` is passed by the caller so this function is deterministic.
    ///
    /// `coordinator` is `&mut` because `capture_with_mode` (WriteMode::Regular)
    /// mounts and feeds the per-estate encode queue, which requires mutable access.
    /// The dual-path intake bug fix: import now routes through `capture_with_mode`
    /// so the drawer is enqueued for BM25/vector encoding — previously, the row-only
    /// `capture` was called here, leaving the BM25/vector lanes dark for all imports.
    ///
    /// ## Content-idempotent matching (FINDING-1a)
    ///
    /// When the note's lineage has an active drawer with byte-identical content
    /// AND no sensitivity upgrade is requested, returns `SkippedUnchanged` —
    /// no supersession, no UUID rotation. Only supersedes when body content or
    /// sensitivity tier actually changed. A sensitivity UPGRADE (incoming tier
    /// strictly higher than stored tier) is a meaningful change and bypasses the
    /// idempotent guard. `existing_content_by_lineage` is the `lineage_id →
    /// content` map built by the caller from the active-drawer snapshot.
    ///
    /// ## Tombstone-aware matching (FINDING-1b)
    ///
    /// When the note's lineage appears in `tombstoned_lineage_ids` (erased/withdrawn),
    /// returns `SkippedTombstoned`. The tombstone is respected; the note is NOT
    /// resurrected.
    pub fn import_note(
        &self,
        note: &NoteIR,
        coordinator: &mut EstateCoordinator,
        handle: &EstateHandle,
        existing_lineage_ids: &std::collections::HashSet<Uuid>,
        existing_sensitivity_by_lineage: &std::collections::HashMap<Uuid, AdjectiveSensitivity>,
        tombstoned_lineage_ids: &std::collections::HashSet<Uuid>,
        existing_content_by_lineage: &std::collections::HashMap<Uuid, String>,
        existing_stable_source_key_by_lineage: &std::collections::HashMap<Uuid, String>,
        existing_tunnel_signatures: &mut std::collections::HashSet<String>,
        now: i64,
    ) -> Result<ImportOutcome, VaultKitError> {
        let content = note.flattened_body();
        // I-5: empty content cannot be captured. Skip rather than emit a frame
        // the substrate will reject.
        if content.is_empty() {
            return Ok(ImportOutcome::Skipped {
                reason: "empty content (I-5: content must be non-empty)".to_owned(),
            });
        }

        let (mut frame, classified) = self.make_capture_frame(note, &content);

        // Security: moot_id lineage-hijack guard. Mirrors the path-identity
        // discriminator in build_note_frame — see that function for the full
        // rationale. Fires when (1) the claimed UUID targets an existing lineage,
        // (2) the note's vault path is FOREIGN to the claimed lineage (path does
        // not match the export path recorded for that lineage; FNV fallback when
        // no export path is recorded), AND (3) the incoming body DIFFERS (trimmed)
        // from what the estate has for that lineage. Condition 3 allows sensitivity-
        // only upgrades on unchanged content while blocking content-replacement
        // attacks via a spoofed moot_id. Content is compared after trimming because
        // the file parser may produce trailing whitespace the capture path strips.
        // Mirrors Swift DrawerMapping.importNote.
        let fnv_lineage = Self::lineage_id(note.stable_source_key.as_str());
        if let Some(claimed_id) = frame.lineage_id {
            let content_differs = existing_content_by_lineage
                .get(&claimed_id)
                .map(|ec| ec.trim() != content.trim())
                // No existing entry for this lineage → genuinely new lineage,
                // not a content-replacement hijack: allow the claim.
                .unwrap_or(false);
            if existing_lineage_ids.contains(&claimed_id) && content_differs {
                // Determine whether the note's vault path is foreign to the claimed
                // lineage. Primary check: path-identity against the recorded export
                // path. Fallback: FNV check when no export path is recorded.
                let is_path_foreign = match existing_stable_source_key_by_lineage.get(&claimed_id) {
                    Some(recorded_key) => recorded_key.as_str() != note.stable_source_key.as_str(),
                    None => claimed_id != fnv_lineage,
                };
                if is_path_foreign {
                    frame.lineage_id = Some(fnv_lineage);
                }
            }
        }

        let lineage = frame.lineage_id.unwrap_or(fnv_lineage);

        // TOMBSTONE-AWARE: if this lineage was previously erased (withdrawn),
        // do not resurrect it. The tombstone check runs BEFORE the active-lineage
        // check so a lineage that was active and then erased between import runs
        // does not fall through to supersession. Mirrors Swift importNote.
        if tombstoned_lineage_ids.contains(&lineage) {
            return Ok(ImportOutcome::SkippedTombstoned);
        }

        let is_update = existing_lineage_ids.contains(&lineage);

        // CONTENT-IDEMPOTENT: when the lineage already has an active drawer with
        // byte-identical content AND no sensitivity upgrade requested, skip —
        // no supersession, no UUID rotation. Only supersede when something
        // actually changed. Mirrors Swift importNote.
        //
        // Sensitivity exception: if the incoming note requests a HIGHER tier
        // than the stored tier, the upgrade is meaningful and must proceed even
        // when body content is identical (e.g. a note re-tagged `sensitivity:
        // secret` after it was originally captured as `.normal`). A LOWER
        // incoming tier is not meaningful because the floor (applied below)
        // would hold the tier at the existing level regardless.
        // Raw-value ordering: normal=0 < elevated=16 < restricted=32 < secret=48.
        let is_sensitivity_upgrade = existing_sensitivity_by_lineage
            .get(&lineage)
            .map(|existing_tier| frame.sensitivity.raw_value() > existing_tier.raw_value())
            .unwrap_or(false);
        if is_update && !is_sensitivity_upgrade {
            if let Some(existing_content) = existing_content_by_lineage.get(&lineage) {
                if existing_content.as_str() == content.as_str() {
                    return Ok(ImportOutcome::SkippedUnchanged);
                }
            }
        }

        // Sensitivity floor: a re-import never lowers an existing drawer's
        // tier (supersession-downgrade defense — a hostile vault file carrying
        // a victim's exposed `moot_id` plus `sensitivity: normal` must not be
        // able to declassify the drawer). Raw values are tier-ordered
        // (normal 0 < elevated 16 < restricted 32 < secret 48), so a numeric
        // max is the floor. Mirrors Swift `DrawerMapping.importNote`.
        if let Some(existing_tier) = existing_sensitivity_by_lineage.get(&lineage) {
            if existing_tier.raw_value() > frame.sensitivity.raw_value() {
                frame.sensitivity = *existing_tier;
            }
        }

        // Route through capture_with_mode(Regular) so the drawer is enqueued for
        // BM25/vector encoding (dual-path intake, G7). The row-only `capture` left
        // BM25/vector lanes dark for all imported content — this is the Rust side of
        // the same bug fixed in Swift DrawerMapping.importNote. WriteMode::Regular
        // is correct for batch import: the write returns immediately, the encode
        // drain ingests asynchronously. The caller (VaultBridge.import_notes) drives
        // `await_encode_drain` when a synchronous-encode guarantee is needed.
        //
        // Idempotency: re-importing an export that was already imported into the
        // same estate triggers a DisciplineViolation (e.g. Contested → Supersede
        // is an illegal belief-state transition). This is expected for idempotent
        // re-imports and must not abort the whole batch. Gracefully skip the note
        // and continue. Other errors (storage failures, I/O) propagate.
        // `now` is epoch-MILLISECONDS at the bridge boundary; the coordinator
        // capture path stores it directly into the drawer's epoch-SECONDS
        // `filed_at`/`event_time` columns, so divide by 1000 here — matching the
        // tunnel/fact writes below (which all do `now / 1000` for the same reason).
        // Without this, imported drawers carry a millisecond magnitude that
        // PersistenceKit's iso8601() clamps to the RFC-3339 max year (9999).
        let drawer = match coordinator.capture_with_mode(handle, frame, now / 1000, WriteMode::Regular) {
            Ok(d) => d,
            Err(e) => {
                let reason = format!("{e:?}");
                if reason.contains("DisciplineViolation") {
                    // Distinguish a clean rejection from a partial write. On the
                    // UPDATE path (existing lineage) the supersession cascade can
                    // commit the successor row before the predecessor belief-state
                    // flip raises the violation — leaving an orphaned successor.
                    // Surface that as SkippedWithPartialWrite so the import report
                    // makes the gap visible; a fresh-lineage rejection is a clean
                    // Skipped (no row was written). Mirrors Swift DrawerMapping.
                    if is_update {
                        return Ok(ImportOutcome::SkippedWithPartialWrite {
                            reason: format!(
                                "belief-state transition not permitted after successor write \
                                 (predecessor in non-Active state, supersession cascade failed): {reason}"
                            ),
                        });
                    }
                    return Ok(ImportOutcome::Skipped {
                        reason: format!(
                            "belief-state transition not permitted (capture rejected): {reason}"
                        ),
                    });
                }
                return Err(VaultKitError::VerbError(reason));
            }
        };

        // Apply KG facts from the note (ADR-007 Decision 1 / P0 BLOCKER
        // resolution: facts must land as substrate KG facts, not report-only).
        // Each FactIR triple becomes one KGFact anchored to the captured drawer.
        // Mirrors Swift DrawerMapping.importNote facts loop.
        for fact in &note.facts {
            coordinator
                .add_kg_fact(
                    handle,
                    &fact.subject,
                    &fact.predicate,
                    &fact.object,
                    &drawer.id,
                    now / 1000, // coordinator expects epoch-seconds
                )
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        }

        // Apply scope entries as KG facts (P0 BLOCKER resolution: scope must land
        // in the substrate, not as report-only drops). Each (key, value) pair
        // becomes a KGFact: subject = "scope:<key>", predicate = "has_value",
        // object = value, anchored to the captured drawer.
        // Mirrors Swift DrawerMapping.importNote scope loop.
        for (key, value) in &note.scope {
            coordinator
                .add_kg_fact(
                    handle,
                    &format!("scope:{key}"),
                    "has_value",
                    value,
                    &drawer.id,
                    now / 1000, // coordinator expects epoch-seconds
                )
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        }

        // Apply tags as KG facts (hard-close #29-A: user-authored tags must land
        // in a queryable/exportable durable form so they round-trip import→export).
        // Each tag t becomes a KGFact: subject = "tag:<t>", predicate = "tagged",
        // object = drawer.id (the stable drawer identifier), anchored to the drawer.
        // The export path reconstructs NoteIR.tags by querying for KG facts whose
        // subject has the "tag:" prefix. Mirrors Swift DrawerMapping.importNote tag loop.
        for tag in &note.tags {
            coordinator
                .add_kg_fact(
                    handle,
                    &format!("tag:{tag}"),
                    "tagged",
                    &drawer.id,
                    &drawer.id,
                    now / 1000,
                )
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        }

        // Apply kind discriminator as a KG fact when the note is not the default
        // "note" kind (hard-close #29-B: non-"note" kind must land in a typed
        // durable record, not as a report-only drop). The kind field carries the
        // exchange format's open discriminator vocabulary ("fact", "journal", …).
        // subject = "record:kind", predicate = "is", object = the kind string.
        // The export path reads this fact back to reconstruct NoteIR.kind.
        // Mirrors Swift DrawerMapping.importNote kind branch.
        if note.kind != "note" {
            coordinator
                .add_kg_fact(
                    handle,
                    "record:kind",
                    "is",
                    &note.kind,
                    &drawer.id,
                    now / 1000,
                )
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        }

        // The estate actor is needed for tunnel capture (both provenance tunnels
        // below and content wikilink tunnels after). Fetch once, shared by both paths.
        let estate = coordinator
            .estate_for(handle)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let mut tunnels_created = 0;

        // Resolve wing/room for tunnel endpoints from the node tree (ADR-017:
        // Drawer no longer stores wing/room). Fall back to note frontmatter
        // when node resolution fails (e.g. no NodeStore available).
        let (drawer_wing, drawer_room) = if let Some(ns) = estate.node_store() {
            let node_names = build_node_name_map(ns, &[drawer.clone()]);
            if let Some((w, r)) = node_names.get(&drawer.parent_node_id) {
                (w.clone(), r.clone())
            } else {
                (
                    non_empty(note.frontmatter.get("wing")).unwrap_or_default(),
                    non_empty(note.frontmatter.get("room")).unwrap_or_else(|| "imported".to_owned()),
                )
            }
        } else {
            (
                non_empty(note.frontmatter.get("wing")).unwrap_or_default(),
                non_empty(note.frontmatter.get("room")).unwrap_or_else(|| "imported".to_owned()),
            )
        };

        // Bug N fix — reconstruct _distilled_from provenance tunnels from frontmatter.
        // On export these tunnels were excluded from `note.links` (which rides into body
        // text) and encoded as "targetWing/targetRoom" pairs in the `distilled_from_sources`
        // frontmatter key (semicolon-separated). Reconstruct each pair as a real
        // TunnelCaptureFrame so the provenance graph survives the round-trip without
        // injecting any text into the drawer's content field.
        if let Some(sources_str) = note.frontmatter.get("distilled_from_sources") {
            if !sources_str.is_empty() {
                let added_by_val = non_empty(note.frontmatter.get("addedBy"))
                    .unwrap_or_else(|| self.added_by.clone());
                for source in sources_str.split(';') {
                    // Each entry is "targetWing/targetRoom"; split on the FIRST '/'
                    // only so room paths that contain '/' survive intact.
                    let mut parts = source.splitn(2, '/');
                    let target_wing = match parts.next() {
                        Some(w) if !w.is_empty() => w.to_owned(),
                        _ => continue,
                    };
                    let target_room = match parts.next() {
                        Some(r) if !r.is_empty() => r.to_owned(),
                        _ => continue,
                    };
                    let sig = Self::tunnel_signature(
                        &drawer_wing,
                        &drawer_room,
                        &target_room,
                        "_distilled_from",
                        TunnelKind::References,
                    );
                    if existing_tunnel_signatures.contains(&sig) {
                        continue;
                    }
                    let mut tunnel_frame = TunnelCaptureFrame::new(
                        drawer_wing.clone(),
                        drawer_room.clone(),
                        target_wing,
                        target_room,
                        "_distilled_from".to_owned(),
                        added_by_val.clone(),
                    );
                    tunnel_frame.source_drawer_id = Some(drawer.id.clone());
                    tunnel_frame.kind = TunnelKind::References;
                    tunnel_frame.origin_class = TunnelOriginClass::Imported;
                    estate
                        .capture_tunnel(tunnel_frame, now)
                        .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
                    existing_tunnel_signatures.insert(sig);
                    tunnels_created += 1;
                }
            }
        }

        // Create tunnels for each wikilink, skipping any whose stable
        // endpoint+label signature already exists.
        for link in &note.links {
            let target_room = if link.target.is_empty() {
                "unresolved".to_owned()
            } else {
                link.target.clone()
            };
            let sig = Self::tunnel_signature(
                &drawer_wing,
                &drawer_room,
                &target_room,
                &link.raw,
                TunnelKind::References,
            );
            if existing_tunnel_signatures.contains(&sig) {
                continue;
            }
            let added_by_val = non_empty(note.frontmatter.get("addedBy"))
                .unwrap_or_else(|| self.added_by.clone());
            let mut tunnel_frame = TunnelCaptureFrame::new(
                drawer_wing.clone(),
                drawer_room.clone(),
                drawer_wing.clone(), // target wing = same estate wing
                target_room,
                link.raw.clone(),
                added_by_val,
            );
            tunnel_frame.source_drawer_id = Some(drawer.id.clone());
            tunnel_frame.kind = TunnelKind::References;
            tunnel_frame.origin_class = TunnelOriginClass::Imported;

            estate
                .capture_tunnel(tunnel_frame, now)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
            existing_tunnel_signatures.insert(sig);
            tunnels_created += 1;
        }

        if is_update {
            Ok(ImportOutcome::Updated { tunnels_created, fdc_classified: classified })
        } else {
            Ok(ImportOutcome::Written { tunnels_created, fdc_classified: classified })
        }
    }

    /// Build the `CaptureFrame` for a note. Returns the frame plus whether a
    /// real classification (explicit frontmatter `udc`) was used. In the Rust
    /// V1 port, EideticLib's FDC lookup is not linked (equivalent to the
    /// feature-flag-off path in Swift), so only the frontmatter `udc` can
    /// produce `classified = true`. Mirrors Swift `DrawerMapping.makeCaptureFrame(for:content:)`.
    pub fn make_capture_frame(&self, note: &NoteIR, content: &str) -> (CaptureFrame, bool) {
        // Room resolution — priority order (mirrors Swift DrawerMapping.makeCaptureFrame):
        //   1. Explicit frontmatter `room` (round-trip identity; always wins).
        //   2. Wing-prefix stripping (ADR-016): if the first path_component matches
        //      the `wing` frontmatter value and there is more than one component,
        //      strip the wing prefix before joining the remainder as the room.
        //   3. Full hierarchy from `path_components` joined with "/" when more than
        //      one component is present (e.g. ["projects","alpha","notes"] →
        //      "projects/alpha/notes"). Maps vault hierarchy to room depth without
        //      loss.
        //   4. The leaf of `original_path` (back-compat for callers that supply
        //      only original_path).
        //   5. Hard default "imported" so I-5's non-empty room guard always holds.
        //
        // Wing resolution (ADR-016): `CaptureFrame.wing` routes the drawer into
        // the named wing at capture time. Priority order:
        //   1. Frontmatter `wing` key — written by VaultKit on export, so a
        //      round-trip import restores the original wing faithfully.
        //   2. None → DEFAULT_WING_NAME ("Agentic Memory") at the substrate seam.
        //      Human notes with no wing context land in the default wing.
        let room_candidate = if let Some(explicit) = non_empty(note.frontmatter.get("room")) {
            explicit
        } else {
            // Determine content_components, stripping the wing prefix if the first
            // component matches the `wing` frontmatter value (ADR-016 vault layout).
            let wing_key = note.frontmatter.get("wing").map(|s| s.as_str()).unwrap_or("");
            let content_components: &[String] =
                if !wing_key.is_empty()
                    && note.path_components.first().map(|s| s.as_str()) == Some(wing_key)
                    && note.path_components.len() > 1
                {
                    // First component is the wing folder — strip it; the rest is the room path.
                    &note.path_components[1..]
                } else {
                    &note.path_components
                };

            if content_components.len() > 1 {
                content_components.join("/")
            } else if let Some(first) = content_components.first() {
                first.clone()
            } else {
                note.original_path
                    .split('/')
                    .filter(|s| !s.is_empty())
                    .last()
                    .unwrap_or("")
                    .to_owned()
            }
        };
        let room = if room_candidate.is_empty() { "imported".to_owned() } else { room_candidate };

        let added_by_value = non_empty(note.frontmatter.get("addedBy"))
            .unwrap_or_else(|| self.added_by.clone());
        let model_value = non_empty(note.frontmatter.get("embeddingModelID"))
            .unwrap_or_else(|| self.embedding_model_id.clone());

        // UDC resolution (one-door principle):
        //   1. Explicit frontmatter `udc` (a pre-classified note): passed through
        //      unchanged — the GLK seam preserves any non-sentinel anchor.
        //   2. Deterministic fallback "000" (the unclassified sentinel): the GLK
        //      seam (`capture_with_mode`) classifies via Fdc::encode_anchor when
        //      it sees this sentinel and the content is non-empty. Classification
        //      happens once at the seam, not per caller.
        let resolved_udc = non_empty(note.frontmatter.get("udc"));
        let classified = resolved_udc.is_some();
        let udc_code = resolved_udc.unwrap_or_else(|| self.fallback_udc.clone());

        // Feature flags: hasLinks (bit 15), hasAttachments (bit 12) in the
        // operational bitmap. Values match `DrawerFeatureFlags` constants in
        // LocusKit's `drawer_operational.rs`.
        let mut feature_flags: i64 = 0;
        if !note.links.is_empty() {
            feature_flags |= DrawerFeatureFlags::HAS_LINKS;
        }
        if note.source.is_some() {
            feature_flags |= DrawerFeatureFlags::HAS_ATTACHMENTS;
        }

        let mut frame = CaptureFrame::new(
            content,
            // CaptureChannel::ImportedFile (raw 3) matches Swift `.importedFile`.
            CaptureChannel::ImportedFile,
            room,
            LatticeAnchor {
                udc_code,
                udc_facets: None,
                wikidata_qid: non_empty(note.frontmatter.get("wikidataQID")),
                wikidata_qids_secondary: None,
            },
            added_by_value,
            model_value,
        );
        // ContentKind::Prose (the default from CaptureFrame::new) is correct.
        // Provenance: SourceType::Imported + Channel::FileImport record the import origin.
        frame.source_type = SourceType::Imported;
        frame.provenance_channel = Channel::FileImport;
        // Sensitivity preserved from the IR when the adapter supplies it
        // (ADR-007 Decision 2 — import is ungated, but the tier rides in).
        // Absent or unrecognised labels land at the `Normal` capture default
        // rather than failing the import.
        if let Some(label) = non_empty(note.frontmatter.get("sensitivity")) {
            if let Some(tier) = Self::sensitivity_from_label(&label) {
                frame.sensitivity = tier;
            }
        }
        // Identity resolution priority (Decision B1):
        //   1. note.moot_id — explicit UUID from frontmatter `moot_id` (rename-safe).
        //   2. frontmatter["moot_id"] string → parse as UUID (fallback when adapter
        //      could not pre-parse).
        //   3. FNV-1a 128-bit hash of stable_source_key (original idempotency anchor).
        //
        // Using moot_id from the note ensures a re-import after a vault rename
        // still finds the existing drawer by lineage — the note's identity is the
        // substrate's lineage_id, not the file path.
        let lineage = note
            .moot_id
            .or_else(|| {
                note.frontmatter
                    .get("moot_id")
                    .and_then(|s| Uuid::parse_str(s).ok())
            })
            .unwrap_or_else(|| Self::lineage_id(note.stable_source_key.as_str()));
        frame.lineage_id = Some(lineage);
        frame.feature_flags = feature_flags;
        // Event time from origin date, if available. Clamp to the RFC-3339
        // round-trippable range (years 0001–9999) before passing to the capture
        // frame. The write side (iso8601() in PersistenceKit's sqlite.rs) also
        // clamps, so this is defence-in-depth: a vault with a wildly out-of-range
        // `created` frontmatter value (year < 0001 or > 9999) won't become a
        // poison timestamp in the drawers table. Values outside the range are
        // replaced with None so the substrate uses the insertion clock instead.
        //
        // Range in seconds (matching PersistenceKit's clamp constants):
        //   MIN_ROUND_TRIP_SECS = -62_135_596_800  (year 0001-01-01T00:00:00Z)
        //   MAX_ROUND_TRIP_SECS =  253_402_300_799  (year 9999-12-31T23:59:59Z)
        // In milliseconds:
        //   MIN = -62_135_596_800_000
        //   MAX =  253_402_300_799_000
        frame.event_time = note.origin_date.as_ref().and_then(|o| {
            let ms = iso8601_to_ms(&o.iso8601)?;
            const MIN_MS: i64 = -62_135_596_800_000;
            const MAX_MS: i64 = 253_402_300_799_000;
            if ms < MIN_MS || ms > MAX_MS {
                // Out of range: ignore the frontmatter timestamp, let the
                // substrate use its insertion clock.
                None
            } else {
                Some(ms)
            }
        });

        // Wing resolution (ADR-016, see comment above).
        // Frontmatter `wing` was written by VaultKit on export and is the
        // authoritative source for round-trip import. Human-authored notes
        // with no frontmatter wing get None → DEFAULT_WING_NAME at the seam.
        frame.wing = non_empty(note.frontmatter.get("wing"));

        (frame, classified)
    }

    // MARK: - FNV-1a 128-bit lineage_id — conformance anchor

    /// Derive a deterministic `lineage_id` from a note's stable source key.
    /// FNV-1a is the fallback lineage algorithm; `moot_id` frontmatter takes
    /// priority when present, and unchanged content skips supersession entirely.
    ///
    /// Implements FNV-1a (128-bit) over the key's UTF-8 bytes — the same
    /// algorithm as Swift `DrawerMapping.lineageID(forStableSourceKey:)`. The
    /// 128-bit hash is packed big-endian into a `Uuid` (high 8 bytes then low 8
    /// bytes), matching the Swift `uuid(fromHigh:low:)` helper. This is the
    /// cross-language conformance anchor: for any given `stable_source_key`, the
    /// Swift and Rust implementations must produce byte-identical UUIDs.
    ///
    /// FNV-1a 128-bit constants:
    ///   offset basis high = 0x6c62272e07bb0142
    ///   offset basis low  = 0x62b821756295c58d
    ///   prime high        = 0x0000000001000000
    ///   prime low         = 0x000000000000013B
    pub fn lineage_id(stable_source_key: &str) -> Uuid {
        let offset_high: u64 = 0x6c62272e07bb0142;
        let offset_low: u64 = 0x62b821756295c58d;
        let prime_high: u64 = 0x0000000001000000;
        let prime_low: u64 = 0x000000000000013B;

        let mut h_high = offset_high;
        let mut h_low = offset_low;

        for &byte in stable_source_key.as_bytes() {
            // FNV-1a: XOR the low byte before multiply.
            h_low ^= byte as u64;
            // 128-bit multiply h * prime (mod 2^128).
            // The full product is (h_high * prime_high * 2^128 + ...) mod 2^128.
            // Only terms that contribute to the low 128 bits survive:
            //   new_low  = (h_low * prime_low) mod 2^64  (the low 64 bits)
            //   new_high = floor((h_low * prime_low) / 2^64)   <- carry from low*low
            //            + (h_high * prime_low) mod 2^64       <- low needs h_high
            //            + (h_low * prime_high) mod 2^64       <- prime_high * h_low
            //   (h_high * prime_high is discarded — it overflows 2^128 and is
            //   mod-2^128 equivalent to 0 for our accumulation)
            //
            // Swift uses `multipliedFullWidth` which gives the exact 128-bit product
            // of two u64 values. We replicate that here via u128 arithmetic, which
            // Rust performs without overflow.
            let low_full = (h_low as u128).wrapping_mul(prime_low as u128);
            let new_low = low_full as u64;             // low 64 bits
            let carry_from_low = (low_full >> 64) as u64; // high 64 bits of low*low

            let new_high = h_high
                .wrapping_mul(prime_low)
                .wrapping_add(h_low.wrapping_mul(prime_high))
                .wrapping_add(carry_from_low);

            h_high = new_high;
            h_low = new_low;
        }

        // Pack 128-bit hash into a UUID (big-endian high then low), matching
        // Swift's `uuid(fromHigh:low:)` which writes each u64 byte-by-byte
        // from bit 56 down to bit 0 (big-endian).
        let high_bytes = h_high.to_be_bytes();
        let low_bytes = h_low.to_be_bytes();
        Uuid::from_bytes([
            high_bytes[0], high_bytes[1], high_bytes[2], high_bytes[3],
            high_bytes[4], high_bytes[5], high_bytes[6], high_bytes[7],
            low_bytes[0],  low_bytes[1],  low_bytes[2],  low_bytes[3],
            low_bytes[4],  low_bytes[5],  low_bytes[6],  low_bytes[7],
        ])
    }

    // MARK: - Sensitivity frontmatter labels

    /// Canonical frontmatter label for each sensitivity tier. The labels are
    /// shared verbatim with the Swift port (`DrawerMapping.sensitivityLabel`)
    /// so vaults round-trip across implementations.
    pub fn sensitivity_label(s: AdjectiveSensitivity) -> &'static str {
        match s {
            AdjectiveSensitivity::Normal => "normal",
            AdjectiveSensitivity::Elevated => "elevated",
            AdjectiveSensitivity::Restricted => "restricted",
            AdjectiveSensitivity::Secret => "secret",
        }
    }

    /// Inverse of `sensitivity_label`. Returns `None` for unrecognised
    /// labels; the caller falls back to the `Normal` capture default.
    /// Mirrors Swift `DrawerMapping.sensitivity(fromLabel:)`.
    pub fn sensitivity_from_label(label: &str) -> Option<AdjectiveSensitivity> {
        match label {
            "normal" => Some(AdjectiveSensitivity::Normal),
            "elevated" => Some(AdjectiveSensitivity::Elevated),
            "restricted" => Some(AdjectiveSensitivity::Restricted),
            "secret" => Some(AdjectiveSensitivity::Secret),
            _ => None,
        }
    }

    // MARK: - Batch helpers (GLK_BATCH1)

    /// Apply import guards and build a `CaptureFrame` for `note` without
    /// calling `capture`. Returns `None` (with `report` counters updated
    /// for the skip) when any guard fires. The caller increments
    /// `drawers_written`/`drawers_updated` on a non-`None` return.
    ///
    /// Mirrors Swift `DrawerMapping.buildNoteFrame(for:...)`.
    pub fn build_note_frame(
        &self,
        note: &NoteIR,
        existing_lineage_ids: &std::collections::HashSet<Uuid>,
        existing_sensitivity_by_lineage: &std::collections::HashMap<Uuid, AdjectiveSensitivity>,
        tombstoned_lineage_ids: &std::collections::HashSet<Uuid>,
        existing_content_by_lineage: &std::collections::HashMap<Uuid, String>,
        existing_stable_source_key_by_lineage: &std::collections::HashMap<Uuid, String>,
        items_skipped: &mut usize,
        drawers_skipped_unchanged: &mut usize,
        drawers_skipped_tombstoned: &mut usize,
    ) -> Option<(CaptureFrame, bool /* is_update */, bool /* classified */)> {
        let content = note.flattened_body();
        if content.is_empty() {
            *items_skipped += 1;
            return None;
        }
        let (mut frame, classified) = self.make_capture_frame(note, &content);

        // Security: moot_id lineage-hijack guard. Uses the path-identity
        // discriminator: fires when (1) the claimed UUID targets an existing
        // lineage, (2) the note's vault path is FOREIGN to the claimed lineage
        // (path does not match the recorded export path; FNV fallback when no
        // export path is recorded), AND (3) the incoming body DIFFERS (trimmed)
        // from the estate's content for that lineage. Condition 3 allows
        // sensitivity-only upgrades on unchanged content while blocking
        // body-replacement attacks. Mirrors Swift DrawerMapping.buildNoteFrame.
        let fnv_lineage = Self::lineage_id(note.stable_source_key.as_str());
        if let Some(claimed_id) = frame.lineage_id {
            let content_differs = existing_content_by_lineage
                .get(&claimed_id)
                .map(|ec| ec.trim() != content.trim())
                .unwrap_or(false); // new lineage (not in estate) → not a hijack
            if existing_lineage_ids.contains(&claimed_id) && content_differs {
                let is_path_foreign = match existing_stable_source_key_by_lineage.get(&claimed_id) {
                    Some(recorded_key) => recorded_key.as_str() != note.stable_source_key.as_str(),
                    None => claimed_id != fnv_lineage,
                };
                if is_path_foreign {
                    frame.lineage_id = Some(fnv_lineage);
                }
            }
        }

        let lineage = frame.lineage_id.unwrap_or(fnv_lineage);

        if tombstoned_lineage_ids.contains(&lineage) {
            *drawers_skipped_tombstoned += 1;
            return None;
        }

        let is_update = existing_lineage_ids.contains(&lineage);
        let is_sensitivity_upgrade = existing_sensitivity_by_lineage
            .get(&lineage)
            .map(|existing_tier| frame.sensitivity.raw_value() > existing_tier.raw_value())
            .unwrap_or(false);
        if is_update && !is_sensitivity_upgrade {
            if let Some(existing_content) = existing_content_by_lineage.get(&lineage) {
                if existing_content.as_str() == content.as_str() {
                    *drawers_skipped_unchanged += 1;
                    return None;
                }
            }
        }
        if let Some(existing_tier) = existing_sensitivity_by_lineage.get(&lineage) {
            if existing_tier.raw_value() > frame.sensitivity.raw_value() {
                frame.sensitivity = *existing_tier;
            }
        }
        Some((frame, is_update, classified))
    }

    /// Apply post-capture work (KG facts + tunnels) for a note whose drawer
    /// was already inserted by `capture_batch`. Called per-note AFTER the
    /// batch transaction commits so `drawer.id` is available.
    ///
    /// Returns the number of tunnels created.
    /// Mirrors Swift `DrawerMapping.applyNotePostCapture(note:frame:drawer:...)`.
    pub fn apply_note_post_capture(
        &self,
        note: &NoteIR,
        frame: &CaptureFrame,
        drawer: &locus_kit::drawer::Drawer,
        coordinator: &mut EstateCoordinator,
        handle: &EstateHandle,
        existing_tunnel_signatures: &mut std::collections::HashSet<String>,
        now: i64,
    ) -> Result<usize, VaultKitError> {
        // KG facts (facts, scope, tags, kind) — same logic as import_note.
        for fact in &note.facts {
            coordinator
                .add_kg_fact(handle, &fact.subject, &fact.predicate, &fact.object, &drawer.id, now / 1000)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        }
        for (key, value) in &note.scope {
            coordinator
                .add_kg_fact(handle, &format!("scope:{key}"), "has_value", value, &drawer.id, now / 1000)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        }
        for tag in &note.tags {
            coordinator
                .add_kg_fact(handle, &format!("tag:{tag}"), "tagged", &drawer.id, &drawer.id, now / 1000)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        }
        if note.kind != "note" {
            coordinator
                .add_kg_fact(handle, "record:kind", "is", &note.kind, &drawer.id, now / 1000)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        }

        let estate = coordinator
            .estate_for(handle)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let mut tunnels_created = 0;

        let (drawer_wing, drawer_room) = if let Some(ns) = estate.node_store() {
            let node_names = build_node_name_map(ns, &[drawer.clone()]);
            if let Some((w, r)) = node_names.get(&drawer.parent_node_id) {
                (w.clone(), r.clone())
            } else {
                (
                    non_empty(note.frontmatter.get("wing")).unwrap_or_default(),
                    non_empty(note.frontmatter.get("room")).unwrap_or_else(|| "imported".to_owned()),
                )
            }
        } else {
            (
                non_empty(note.frontmatter.get("wing")).unwrap_or_default(),
                non_empty(note.frontmatter.get("room")).unwrap_or_else(|| "imported".to_owned()),
            )
        };

        let added_by_val = non_empty(note.frontmatter.get("addedBy"))
            .unwrap_or_else(|| frame.added_by.clone());

        if let Some(sources_str) = note.frontmatter.get("distilled_from_sources") {
            if !sources_str.is_empty() {
                for source in sources_str.split(';') {
                    let mut parts = source.splitn(2, '/');
                    let target_wing = match parts.next() {
                        Some(w) if !w.is_empty() => w.to_owned(),
                        _ => continue,
                    };
                    let target_room = match parts.next() {
                        Some(r) if !r.is_empty() => r.to_owned(),
                        _ => continue,
                    };
                    let sig = Self::tunnel_signature(&drawer_wing, &drawer_room, &target_room, "_distilled_from", TunnelKind::References);
                    if existing_tunnel_signatures.contains(&sig) { continue; }
                    let mut tunnel_frame = TunnelCaptureFrame::new(
                        drawer_wing.clone(), drawer_room.clone(), target_wing, target_room,
                        "_distilled_from".to_owned(), added_by_val.clone(),
                    );
                    tunnel_frame.source_drawer_id = Some(drawer.id.clone());
                    tunnel_frame.kind = TunnelKind::References;
                    tunnel_frame.origin_class = TunnelOriginClass::Imported;
                    estate.capture_tunnel(tunnel_frame, now).map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
                    existing_tunnel_signatures.insert(sig);
                    tunnels_created += 1;
                }
            }
        }
        for link in &note.links {
            let target_room = if link.target.is_empty() { "unresolved".to_owned() } else { link.target.clone() };
            let sig = Self::tunnel_signature(&drawer_wing, &drawer_room, &target_room, &link.raw, TunnelKind::References);
            if existing_tunnel_signatures.contains(&sig) { continue; }
            let mut tunnel_frame = TunnelCaptureFrame::new(
                drawer_wing.clone(), drawer_room.clone(), drawer_wing.clone(), target_room,
                link.raw.clone(), added_by_val.clone(),
            );
            tunnel_frame.source_drawer_id = Some(drawer.id.clone());
            tunnel_frame.kind = TunnelKind::References;
            tunnel_frame.origin_class = TunnelOriginClass::Imported;
            estate.capture_tunnel(tunnel_frame, now).map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
            existing_tunnel_signatures.insert(sig);
            tunnels_created += 1;
        }
        Ok(tunnels_created)
    }

    /// Stable signature for tunnel de-duplication. Keyed on the endpoint
    /// wing/room, the target room, the raw label, and the kind — all stable
    /// across re-imports (unlike the source drawer id, which the supersession
    /// cascade re-mints). Mirrors Swift `DrawerMapping.tunnelSignature(...)`.
    pub fn tunnel_signature(
        source_wing: &str,
        source_room: &str,
        target_room: &str,
        label: &str,
        kind: TunnelKind,
    ) -> String {
        // U+001F UNIT SEPARATOR — the same separator used in the Swift port.
        let sep = '\u{001F}';
        format!(
            "{source_wing}{sep}{source_room}{sep}{target_room}{sep}{label}{sep}{}",
            kind.raw_value()
        )
    }
}

// MARK: - Internal helpers

fn non_empty(s: Option<&String>) -> Option<String> {
    s.filter(|s| !s.is_empty()).cloned()
}

/// Convert milliseconds-since-epoch to a LocusKit-compatible ISO8601 string
/// with fractional seconds, matching `OccurredAt(date:)` in Swift.
/// Format: `YYYY-MM-DDTHH:MM:SS.mmmZ`.
pub(crate) fn ms_to_iso8601(ms: i64) -> String {
    let secs = ms / 1000;
    let millis = (ms.unsigned_abs() % 1000) as u64;
    let (year, month, day, hour, min, sec) = secs_to_ymdhms(secs);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{min:02}:{sec:02}.{millis:03}Z")
}

/// Convert epoch SECONDS to a LocusKit-compatible ISO8601 string.
///
/// Use this when the input is already in seconds (e.g. `Drawer::event_time`,
/// `filed_at`). `ms_to_iso8601` divides by 1000 first, so calling it with
/// a seconds value yields a date ~1000× too early (1970-01-21 for a
/// typical 2020s timestamp).
///
/// Format: `YYYY-MM-DDTHH:MM:SS.000Z` (zero milliseconds — seconds
/// precision matches the substrate's filed_at/event_time resolution).
pub(crate) fn secs_to_iso8601(secs: i64) -> String {
    let (year, month, day, hour, min, sec) = secs_to_ymdhms(secs);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{min:02}:{sec:02}.000Z")
}

/// Parse an ISO8601 string of the form `YYYY-MM-DDTHH:MM:SS[.mmm]Z` to
/// milliseconds-since-epoch. Returns `None` on parse failure.
pub(crate) fn iso8601_to_ms(s: &str) -> Option<i64> {
    // Minimal parser for the LocusKit LKISO8601 form.
    if s.len() < 20 {
        return None;
    }
    let year: i64 = s[0..4].parse().ok()?;
    let month: i64 = s[5..7].parse().ok()?;
    let day: i64 = s[8..10].parse().ok()?;
    let hour: i64 = s[11..13].parse().ok()?;
    let min: i64 = s[14..16].parse().ok()?;
    let sec: i64 = s[17..19].parse().ok()?;
    let millis: i64 = if s.len() > 20 && s.as_bytes()[19] == b'.' {
        let frac_end = s[20..].find(|c: char| !c.is_ascii_digit()).map_or(s.len(), |i| 20 + i);
        let frac_str = &s[20..frac_end];
        // Pad or truncate to 3 decimal digits (milliseconds).
        let padded = format!("{:0<3}", frac_str);
        padded[..3.min(padded.len())].parse().ok()?
    } else {
        0
    };
    let days = days_since_epoch(year, month, day);
    let total_secs = days * 86400 + hour * 3600 + min * 60 + sec;
    Some(total_secs * 1000 + millis)
}

/// Days since 1970-01-01 for the given (year, month, day) in UTC.
fn days_since_epoch(year: i64, month: i64, day: i64) -> i64 {
    // Reuse the same Howard Hinnant algorithm inverted.
    let y = if month <= 2 { year - 1 } else { year };
    let m = if month <= 2 { month + 9 } else { month - 3 };
    let era = y / 400;
    let yoe = y - era * 400;
    let doy = (153 * m + 2) / 5 + (day - 1);
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// Decompose Unix seconds to (year, month, day, hour, minute, second) UTC.
/// Gregorian calendar computation using Howard Hinnant's algorithm —
/// no external dependencies.
fn secs_to_ymdhms(secs: i64) -> (i64, u8, u8, u8, u8, u8) {
    let sec = (secs.rem_euclid(60)) as u8;
    let min = ((secs / 60).rem_euclid(60)) as u8;
    let hour = ((secs / 3600).rem_euclid(24)) as u8;
    let days = secs.div_euclid(86400);

    // https://howardhinnant.github.io/date_algorithms.html
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    (year, m as u8, d as u8, hour, min, sec)
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lineage_id_is_deterministic() {
        let a1 = DrawerMapping::lineage_id("Area/Note");
        let a2 = DrawerMapping::lineage_id("Area/Note");
        let b = DrawerMapping::lineage_id("Area/Other");
        assert_eq!(a1, a2, "same key must produce same lineage_id");
        assert_ne!(a1, b, "distinct keys must produce distinct lineage_ids");
    }

    #[test]
    fn lineage_id_empty_key() {
        // The empty string leaves h at the FNV-1a offset basis — must not panic.
        let id = DrawerMapping::lineage_id("");
        assert_eq!(id, DrawerMapping::lineage_id(""));
    }

    #[test]
    fn ms_to_iso8601_round_trips() {
        // 1700000000 seconds = 2023-11-14T22:13:20.000Z
        let ms = 1_700_000_000_i64 * 1000 + 123;
        let s = ms_to_iso8601(ms);
        assert!(s.ends_with('Z'));
        assert!(s.contains('T'));
        assert!(s.contains('.'));
        let back = iso8601_to_ms(&s).expect("should parse back");
        assert_eq!(back, ms);
    }

    #[test]
    fn secs_to_iso8601_not_1970() {
        // Regression for the vault export 1970 bug: drawer.event_time is epoch
        // seconds. Feeding it directly to ms_to_iso8601 (which divides by 1000)
        // produced 1970-01-21 for a typical 2020s timestamp.
        // secs_to_iso8601 must produce the correct year — 2023, not 1970.
        let secs = 1_700_000_000_i64; // 2023-11-14T22:13:20Z
        let s = secs_to_iso8601(secs);
        assert!(
            s.starts_with("2023-"),
            "expected 2023-..., got: {s}"
        );
        assert_eq!(s, "2023-11-14T22:13:20.000Z");
        // Sanity-check: feeding the same value to ms_to_iso8601 (the old path)
        // would produce 1970 — confirm the functions differ.
        let wrong = ms_to_iso8601(secs);
        assert!(
            wrong.starts_with("1970-"),
            "ms_to_iso8601 with secs input should produce 1970, got: {wrong}"
        );
    }

    #[test]
    fn slug_from_heading() {
        let id = "12345678-0000-0000-0000-000000000001";
        assert_eq!(
            DrawerMapping::slug("# My Note Title\nbody text", id),
            "my-note-title"
        );
    }

    #[test]
    fn slug_from_first_line_no_heading() {
        let id = "12345678-0000-0000-0000-000000000001";
        assert_eq!(
            DrawerMapping::slug("Hello World!", id),
            "hello-world"
        );
    }

    #[test]
    fn slug_punctuation_collapse() {
        let id = "12345678-0000-0000-0000-000000000001";
        assert_eq!(
            DrawerMapping::slug("A note: with 'special' chars!", id),
            "a-note-with-special-chars"
        );
    }

    #[test]
    fn slug_empty_content_produces_uuid_prefix() {
        let id = "12345678-0000-0000-0000-000000000001";
        let result = DrawerMapping::slug("   ", id);
        assert!(result.starts_with("note-"), "expected 'note-' prefix, got: {result}");
    }

    #[test]
    fn slug_heading_on_any_line_wins() {
        // A heading on line 2 overrides a non-heading first line.
        let id = "12345678-0000-0000-0000-000000000001";
        assert_eq!(
            DrawerMapping::slug("intro\n# Real Title\n", id),
            "real-title"
        );
    }

    #[test]
    fn moot_id_wins_over_fnv_in_make_capture_frame() {
        use std::collections::HashMap;
        use crate::note_ir::Block;

        let mapping = DrawerMapping::new("tester", "model-v1", false);
        let lineage = Uuid::parse_str("aaaaaaaa-0000-0000-0000-000000000001").unwrap();
        let mut frontmatter = HashMap::new();
        frontmatter.insert("room".to_owned(), "r".to_owned());
        frontmatter.insert("moot_id".to_owned(), lineage.to_string());

        let note = NoteIR::with_moot_id(
            "some/other/path",
            vec![Block::markdown("content")],
            frontmatter,
            vec![],
            vec![],
            "",
            None,
            None,
            Some(lineage),
        );
        let (frame, _) = mapping.make_capture_frame(&note, "content");
        assert_eq!(
            frame.lineage_id,
            Some(lineage),
            "moot_id must override the FNV hash"
        );
    }

    #[test]
    fn absent_moot_id_falls_back_to_fnv() {
        use std::collections::HashMap;
        use crate::note_ir::Block;

        let mapping = DrawerMapping::new("tester", "model-v1", false);
        let mut frontmatter = HashMap::new();
        frontmatter.insert("room".to_owned(), "inbox".to_owned());

        let note = NoteIR::new(
            "inbox/my-note",
            vec![Block::markdown("some human note")],
            frontmatter,
            vec![],
            vec![],
            "inbox",
            None,
            None,
        );
        let (frame, _) = mapping.make_capture_frame(&note, "some human note");
        let expected = DrawerMapping::lineage_id("inbox/my-note");
        assert_eq!(
            frame.lineage_id,
            Some(expected),
            "absent moot_id must fall back to FNV derivation"
        );
    }
}
