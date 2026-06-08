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
use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
use locus_kit::{
    drawer::Drawer,
    drawer_operational::{CaptureChannel, DrawerFeatureFlags},
    estate_types::LatticeAnchor,
    filter::{HydrationLevel, Ordering, RecallFrame},
    frames::{CaptureFrame, TunnelCaptureFrame},
    provenance::{Channel, SourceType},
    tunnel::Tunnel,
    tunnel_operational::{TunnelKind, TunnelOriginClass},
};
use uuid::Uuid;

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

    /// When `true`, import attempts FDC classification; when `false` (or
    /// when the lookup does not resolve), the note lands with the fallback
    /// UDC and provenance intact. The Rust port does not link EideticLib
    /// in V1, so this flag is honoured structurally but classification is
    /// always skipped (equivalent to the feature-flag-off path in Swift).
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
    /// each drawer to a `NoteIR`. Mirrors Swift `DrawerMapping.export(kit:handle:scope:)`.
    ///
    /// `scope` controls which drawers are included. Defaults to `.believed`
    /// when called via `export(coordinator, handle, now)` (through
    /// `VaultBridge::export`). Passing an explicit scope lets callers limit
    /// the export to confirmed, unconfirmed, or publicly-exportable drawers.
    ///
    /// `now` is the snapshot instant in milliseconds-since-epoch, passed by the
    /// caller so this function is deterministic (no internal wall-clock access).
    pub fn export(
        &self,
        coordinator: &EstateCoordinator,
        handle: &EstateHandle,
        now: i64,
        scope: VaultExportScope,
    ) -> Result<Vec<NoteIR>, VaultKitError> {
        // Build the recall frame from the scope's filter chain. The recall
        // evaluator supplies per-axis defaults (sensitivity, trust) for any
        // axis not addressed by the chain — sensitivity stays at normal so
        // export never surfaces elevated/restricted/secret content.
        //
        // VK-EXPORT-FIX parity note: `limit: None` is correct here and does NOT
        // apply a 50-cap in the Rust port. The coordinator's `recall` delegates to
        // `estate.recall(frame, now).collect_all()`, which drains all pages
        // regardless of `RecallStream::DEFAULT_PAGE_SIZE`. In the Swift port the
        // GLK convenience overload `recall(_:_:RecallFrame)` defaults the
        // `GLKRecallRequest.limit` to 50 when `frame.limit` is `None`; the Swift
        // fix is to set `frame.limit = 10_000_000`. No such default exists in the
        // Rust coordinator path, so `limit: None` is the correct unbounded form.
        let recall_frame = RecallFrame {
            filter_chain: scope.filter_chain(),
            hydration_level: HydrationLevel::Full,
            limit: None,
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
        };
        let drawers = coordinator
            .recall(handle, recall_frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;

        // Fetch tunnels once per distinct source wing, not once per drawer.
        let wings: std::collections::HashSet<&str> =
            drawers.iter().map(|d| d.wing.as_str()).collect();
        let mut tunnels_by_wing: std::collections::HashMap<String, Vec<Tunnel>> =
            std::collections::HashMap::new();
        for wing in wings {
            let tunnels = coordinator
                .recall_tunnels(handle, wing)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
            tunnels_by_wing.insert(wing.to_owned(), tunnels);
        }

        let notes: Vec<NoteIR> = drawers
            .iter()
            .map(|drawer| {
                let refs: Vec<&Tunnel> = tunnels_by_wing
                    .get(&drawer.wing)
                    .map(|ts| {
                        ts.iter()
                            .filter(|t| {
                                t.source_drawer_id.as_deref() == Some(&drawer.id)
                                    && t.kind == TunnelKind::References
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                Self::note_ir_from(drawer, &refs)
            })
            .collect();

        Ok(notes)
    }

    /// Pure projection of one drawer + its outgoing `.references` tunnels to a
    /// `NoteIR`. No substrate access — testable in isolation. Mirrors Swift
    /// `DrawerMapping.noteIR(from:references:)`.
    ///
    /// Decision B1 changes vs the V1 shape:
    ///   - stable_source_key: `"<room>/<slug>"` — no wing prefix, slug from content.
    ///   - frontmatter gains `moot_id`: the drawer's `lineage_id` UUID string
    ///     (the STABLE UUID, not `drawer.id` which the supersession cascade re-mints).
    ///   - original_path: the room only — no wing prefix (one vault, one owner).
    ///   - NoteIR.moot_id: set to `drawer.lineage_id` for identity pass-through.
    pub fn note_ir_from(drawer: &Drawer, references: &[&Tunnel]) -> NoteIR {
        // Human-readable slug from the drawer's content. Collision-safe via UUID suffix.
        let slug = Self::slug(&drawer.content, &drawer.id);
        // Path: room/slug — no wing prefix (wing rides frontmatter).
        let stable_key = format!("{}/{}", drawer.room, slug);

        let mut frontmatter: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        frontmatter.insert("wing".to_owned(), drawer.wing.clone());
        frontmatter.insert("room".to_owned(), drawer.room.clone());
        frontmatter.insert("udc".to_owned(), drawer.udc_code.clone());
        frontmatter.insert("addedBy".to_owned(), drawer.added_by.clone());
        frontmatter.insert("embeddingModelID".to_owned(), drawer.embedding_model_id.clone());
        // moot_id: the STABLE lineage UUID. On re-import this wins over the FNV
        // hash of the stable_source_key as the lineage_id for the capture frame.
        // Using lineage_id (not drawer.id) ensures renames and re-exports don't
        // mint a new lineage — the drawer is always found by its stable UUID.
        frontmatter.insert("moot_id".to_owned(), drawer.lineage_id.to_string());
        // Origin date rides frontmatter (no substrate origin-date column).
        // `created:` is the Obsidian key the adapter reads back.
        let event_ms = drawer.event_time;
        let event_iso = ms_to_iso8601(event_ms);
        frontmatter.insert("created".to_owned(), event_iso.clone());

        if let Some(qid) = &drawer.wikidata_qid {
            if !qid.is_empty() {
                frontmatter.insert("wikidataQID".to_owned(), qid.clone());
            }
        }

        // Each `.references` tunnel's label carries the raw wikilink text that
        // produced it on import, so export renders it back verbatim.
        let links: Vec<WikiLink> = references
            .iter()
            .map(|t| WikiLink::new(t.label.clone(), None, t.label.clone()))
            .collect();

        NoteIR::with_moot_id(
            stable_key,
            vec![crate::note_ir::Block::markdown(drawer.content.clone())],
            frontmatter,
            links,
            vec![],
            drawer.room.clone(), // original_path: room only — no wing prefix
            Some(OccurredAt::new(event_iso)),
            None,
            Some(drawer.lineage_id), // moot_id: the stable lineage UUID
        )
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
        // Truncate at word boundary up to 60 chars.
        if trimmed.len() <= 60 {
            trimmed.to_owned()
        } else {
            // Find the last `-` at or before char 60, or truncate hard.
            let end = &trimmed[..60];
            if let Some(pos) = end.rfind('-') {
                end[..pos].to_owned()
            } else {
                end.to_owned()
            }
        }
    }

    // MARK: - Import: IR → estate via the capture seam

    /// Import one note: build a `CaptureFrame`, capture the drawer through the
    /// GLK verb surface, then create the note's `.references` tunnels (de-
    /// duplicated against `existing_tunnel_signatures` so a re-import adds no
    /// duplicates). Mirrors Swift `DrawerMapping.importNote(_:kit:handle:...)`.
    ///
    /// `now` is passed by the caller so this function is deterministic.
    pub fn import_note(
        &self,
        note: &NoteIR,
        coordinator: &EstateCoordinator,
        handle: &EstateHandle,
        existing_lineage_ids: &std::collections::HashSet<Uuid>,
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

        let (frame, classified) = self.make_capture_frame(note, &content);
        let lineage = frame.lineage_id.unwrap_or_else(|| Self::lineage_id(note.stable_source_key.as_str()));
        let is_update = existing_lineage_ids.contains(&lineage);

        let drawer = coordinator
            .capture(handle, frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;

        // Create tunnels for each wikilink, skipping any whose stable
        // endpoint+label signature already exists.
        let estate = coordinator
            .estate_for(handle)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let mut tunnels_created = 0;
        for link in &note.links {
            let target_room = if link.target.is_empty() {
                "unresolved".to_owned()
            } else {
                link.target.clone()
            };
            let sig = Self::tunnel_signature(
                &drawer.wing,
                &drawer.room,
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
                drawer.wing.clone(),
                drawer.room.clone(),
                drawer.wing.clone(), // target wing = same estate wing
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
        // Room: explicit frontmatter wins; else the note's last path component;
        // else a non-empty default so I-5's room guard holds.
        let room_candidate = note
            .frontmatter
            .get("room")
            .cloned()
            .unwrap_or_else(|| {
                note.original_path
                    .split('/')
                    .filter(|s| !s.is_empty())
                    .last()
                    .unwrap_or("")
                    .to_owned()
            });
        let room = if room_candidate.is_empty() { "imported".to_owned() } else { room_candidate };

        let added_by_value = non_empty(note.frontmatter.get("addedBy"))
            .unwrap_or_else(|| self.added_by.clone());
        let model_value = non_empty(note.frontmatter.get("embeddingModelID"))
            .unwrap_or_else(|| self.embedding_model_id.clone());

        // UDC resolution:
        //   1. explicit frontmatter `udc` (a pre-classified note)
        //   2. no EideticLib in Rust V1 — skip lookup
        //   3. deterministic fallback "000"
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
        // Event time from origin date, if available.
        frame.event_time = note.origin_date.as_ref().and_then(|o| iso8601_to_ms(&o.iso8601));

        (frame, classified)
    }

    // MARK: - FNV-1a 128-bit lineage_id — conformance anchor

    /// Derive a deterministic `lineage_id` from a note's stable source key so a
    /// re-import of the same note supersedes its drawer instead of duplicating it.
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
fn ms_to_iso8601(ms: i64) -> String {
    let secs = ms / 1000;
    let millis = (ms.unsigned_abs() % 1000) as u64;
    let (year, month, day, hour, min, sec) = secs_to_ymdhms(secs);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{min:02}:{sec:02}.{millis:03}Z")
}

/// Parse an ISO8601 string of the form `YYYY-MM-DDTHH:MM:SS[.mmm]Z` to
/// milliseconds-since-epoch. Returns `None` on parse failure.
fn iso8601_to_ms(s: &str) -> Option<i64> {
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
