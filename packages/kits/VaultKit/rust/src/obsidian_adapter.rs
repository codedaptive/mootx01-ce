//! ObsidianAdapter — Obsidian-flavoured Markdown ⇄ `NoteIR`, and a superset
//! of Google's Open Knowledge Format (OKF) v0.1 in default mode.
//!
//! One `.md` file is one `NoteIR`. The adapter handles:
//!
//! - **YAML frontmatter** (`--- … ---` at the top of the file) → the
//!   `frontmatter` map. A flat `key: value` reader; nested YAML is not an
//!   Obsidian frontmatter idiom and is out of scope.
//! - **Wikilinks** `[[Target]]` / `[[Target|Alias]]` → `links` (pure-Obsidian
//!   mode); standard Markdown links `[alias](path.md)` → `links` (OKF mode).
//! - **Tags** `#tag` (inline, not the `# heading` form) → `tags`.
//! - **Folder path** → `original_path` and `stable_source_key`.
//! - **index.md / log.md** are emitted in OKF mode and skipped on read.
//!
//! ## OKF compatibility (default mode: `pure_obsidian_links = false`)
//!
//! By default the adapter emits OKF v0.1-compatible output that is ALSO
//! readable by Obsidian:
//!
//! - A `type:` frontmatter key (OKF's only required field), derived from
//!   `NoteIR.kind`: `"note"→"Note"`, `"fact"→"Fact"`, `"journal"→"Journal"`,
//!   else the kind string with the first character uppercased.
//! - Relationship links rendered as standard markdown `[alias](relpath.md)`.
//! - A `tags: [a, b, c]` frontmatter key in addition to inline `#tag` tokens.
//! - One `index.md` per folder (OKF progressive-disclosure navigation).
//!   `index.md` and `log.md` are skipped on read.
//!
//! ## Pure-Obsidian mode (`pure_obsidian_links = true`)
//!
//! Emits `[[Target]]` / `[[Target|Alias]]` wikilinks (legacy behaviour).
//! `type:` and frontmatter `tags:` are still emitted in both modes.
//!
//! ## Round-trip contract
//!
//! Partial round-trip for the fields each flavour represents: core fields
//! (body, links, tags, stable key) survive. Raw link encoding may change
//! between OKF and pure-Obsidian mode; `type:` is not re-parsed into `kind`.
//!
//! This is a mechanical port of `ObsidianAdapter.swift`. Parsing logic is
//! reproduced with Rust idioms; deterministic sort order and
//! `.skipsHiddenFiles` equivalence are preserved.

use crate::error::VaultKitError;
use crate::note_ir::{Block, NoteIR, OccurredAt, WikiLink};
use crate::vault_adapter::VaultAdapter;
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

/// The first `VaultAdapter`: Obsidian-flavoured Markdown ⇄ `NoteIR`.
///
/// Default mode (`pure_obsidian_links = false`) emits OKF v0.1-compatible
/// output. Pass `pure_obsidian_links: true` for legacy wikilink output.
#[derive(Debug, Clone)]
pub struct ObsidianAdapter {
    /// When `false` (default), emit OKF-compatible standard-md links and inject
    /// the OKF `type:` and frontmatter `tags:` keys.
    /// When `true`, emit `[[wikilinks]]` (legacy behaviour). `type:` and
    /// `tags:` are still emitted in both modes.
    pub pure_obsidian_links: bool,
}

impl Default for ObsidianAdapter {
    /// Default: OKF-compatible mode (`pure_obsidian_links = false`).
    /// Mirrors Swift `ObsidianAdapter()`.
    fn default() -> Self {
        Self { pure_obsidian_links: false }
    }
}

impl ObsidianAdapter {
    /// Default constructor: OKF-compatible mode (`pure_obsidian_links = false`).
    /// Source-compatible with all existing call sites that used `ObsidianAdapter::new()`.
    pub fn new() -> Self {
        Self::default()
    }

    /// Explicit constructor for callers that need link-mode control.
    ///
    /// - `pure_obsidian_links = true`: emit `[[wikilinks]]` (legacy behaviour).
    /// - `pure_obsidian_links = false` (default): emit standard-md links.
    pub fn with_options(pure_obsidian_links: bool) -> Self {
        Self { pure_obsidian_links }
    }
}

impl VaultAdapter for ObsidianAdapter {
    // MARK: - Read: vault → IR

    fn to_ir(&self, vault_path: &Path) -> Result<Vec<NoteIR>, VaultKitError> {
        let mut notes: Vec<NoteIR> = Vec::new();
        collect_md_files(vault_path, vault_path, &mut notes)?;
        // Deterministic order so repeated reads and round-trip equality are
        // stable regardless of filesystem enumeration order.
        // Mirrors Swift: `notes.sort { $0.stableSourceKey < $1.stableSourceKey }`.
        notes.sort_by(|a, b| a.stable_source_key.cmp(&b.stable_source_key));
        Ok(notes)
    }

    // MARK: - Write: IR → vault

    fn from_ir(&self, notes: &[NoteIR], vault_path: &Path) -> Result<(), VaultKitError> {
        self.from_ir_with_progress(notes, vault_path, None)
    }

    /// Writes notes to the vault with optional per-item progress reporting.
    ///
    /// Fires `progress(processed, total)` every 100 items and at the final item.
    fn from_ir_with_progress(
        &self,
        notes: &[NoteIR],
        vault_path: &Path,
        progress: Option<&crate::vault_adapter::VaultProgress<'_>>,
    ) -> Result<(), VaultKitError> {
        std::fs::create_dir_all(vault_path)?;

        // Build a name → stableSourceKey map for standard-md link resolution.
        // Key: last path component of stable_source_key (the note filename).
        // When two notes share a name, the first (alphabetical) wins — mirrors Swift.
        let mut key_by_name: HashMap<String, String> = HashMap::new();
        for note in notes {
            let name = last_path_component(&note.stable_source_key);
            key_by_name.entry(name).or_insert_with(|| note.stable_source_key.clone());
        }

        // Track which folders receive notes, for index.md emission.
        let mut folder_notes: HashMap<String, Vec<&NoteIR>> = HashMap::new();

        let total = notes.len();
        let mut processed = 0usize;
        for note in notes {
            // The note is written at `<stable_source_key>.md`, so the folder
            // tree mirrors the wing/room path that `DrawerMapping` encoded
            // into the key on export. Re-reading recovers the same
            // `stable_source_key` and `original_path`.
            let relative = format!("{}.md", note.stable_source_key);
            // Containment gate — two layers, matching the Swift implementation:
            // Layer 1 (lexical):  contained_vault_path rejects traversal
            //   components (.. / absolute / backslash) before touching the disk.
            // Layer 2 (symlink):  write_contained_file canonicalizes the parent
            //   after create_dir_all and verifies it stays inside the vault root,
            //   catching pre-existing symlinks in the vault tree.
            let file_path = contained_vault_path(vault_path, &relative)?;
            let text = render(note, self.pure_obsidian_links, &key_by_name);
            write_contained_file(vault_path, &file_path, text.as_bytes())?;

            // Record this note under its folder for index generation.
            let folder = parent_folder(&note.stable_source_key);
            folder_notes.entry(folder).or_default().push(note);

            processed += 1;
            if let Some(cb) = progress {
                if processed % 100 == 0 || processed == total {
                    cb(processed, total);
                }
            }
        }

        // Emit one index.md per folder that contains notes. Folders in sorted
        // order for deterministic output. Mirrors Swift fromIR index emission.
        let mut folders: Vec<String> = folder_notes.keys().cloned().collect();
        folders.sort();
        for folder in &folders {
            let mut child_notes: Vec<&&NoteIR> = folder_notes[folder].iter().collect();
            child_notes.sort_by(|a, b| a.stable_source_key.cmp(&b.stable_source_key));

            let mut index_content = String::from("# Index\n\n");
            for child in child_notes {
                let filename = last_path_component(&child.stable_source_key);
                // Link text is the filename; path is relative within the same folder.
                index_content.push_str(&format!("- [{filename}]({filename}.md)\n"));
            }

            // Same containment gate as note writes. The index folder already
            // exists (created when notes were written above), so
            // write_contained_file can canonicalize immediately.
            let index_relative = if folder.is_empty() {
                "index.md".to_owned()
            } else {
                format!("{folder}/index.md")
            };
            let index_path = contained_vault_path(vault_path, &index_relative)?;
            write_contained_file(vault_path, &index_path, index_content.as_bytes())?;
        }

        Ok(())
    }
}

// MARK: - Vault containment helpers

/// Resolve a vault-relative output path to an absolute `PathBuf` that remains
/// inside `vault_path`. Used for both note writes and index-file generation.
///
/// **Layer 1 — lexical**: each path component is validated via
/// `std::path::Component`. `ParentDir` (`..`), `RootDir` (`/`), `Prefix`
/// (Windows drive letter), `CurDir` (`.`), and embedded backslashes are
/// rejected before any filesystem access.
///
/// This function builds the target path but does NOT create directories or
/// write files. Call `write_contained_file` to perform the symlink-layer
/// check (Layer 2) after directory creation.
///
/// Mirrors Swift `ObsidianAdapter.containedVaultURL(forRelativePath:under:)`.
fn contained_vault_path(
    vault_path: &Path,
    relative: &str,
) -> Result<PathBuf, VaultKitError> {
    // Backslash is a path separator on Windows but valid in POSIX filenames.
    // Reject it unconditionally so imported Windows metadata cannot sneak a
    // traversal through a POSIX build.
    if relative.contains('\\') {
        return Err(VaultKitError::AdapterError(format!(
            "vault-relative path must use '/' separators only: '{relative}'"
        )));
    }
    let rel_path = Path::new(relative);
    if rel_path.is_absolute() {
        return Err(VaultKitError::AdapterError(format!(
            "vault-relative path must be relative, not absolute: '{relative}'"
        )));
    }
    let mut clean = PathBuf::new();
    for component in rel_path.components() {
        match component {
            Component::Normal(part) => clean.push(part),
            // Every other component class is a traversal or absolute-path
            // marker: CurDir (.), ParentDir (..), RootDir (/), Prefix (C:\).
            _ => {
                return Err(VaultKitError::AdapterError(format!(
                    "vault-relative path contains a forbidden component: '{relative}'"
                )));
            }
        }
    }
    if clean.as_os_str().is_empty() {
        return Err(VaultKitError::AdapterError(format!(
            "vault-relative path is empty after normalization: '{relative}'"
        )));
    }
    Ok(vault_path.join(clean))
}

/// Write `bytes` to `file_path`, verifying after parent-directory creation
/// that the canonicalized parent remains inside `vault_root`.
///
/// This is the **symlink layer** (Layer 2) of the two-layer containment check:
/// `contained_vault_path` is purely lexical; this function catches pre-existing
/// symlinks in the vault tree (e.g. `vault/link -> /tmp`) that would pass the
/// lexical check for `link/note.md` but redirect the write outside the vault.
///
/// The file path itself is also checked for a pre-existing symlink so an
/// attacker cannot redirect an otherwise-safe write by planting a symlink at
/// the exact output path.
///
/// Mirrors Swift `ObsidianAdapter.ensureContainedInVault(_:under:)`.
fn write_contained_file(
    vault_root: &Path,
    file_path: &Path,
    bytes: &[u8],
) -> Result<(), VaultKitError> {
    let canonical_root = vault_root.canonicalize()?;
    let parent = file_path.parent().ok_or_else(|| {
        VaultKitError::AdapterError(format!(
            "vault output path has no parent: '{}'",
            file_path.display()
        ))
    })?;
    std::fs::create_dir_all(parent)?;
    let canonical_parent = parent.canonicalize()?;
    if !canonical_parent.starts_with(&canonical_root) {
        return Err(VaultKitError::AdapterError(format!(
            "vault output path resolves outside vault root: '{}'",
            file_path.display()
        )));
    }
    // Reject a pre-planted symlink at the exact output file path — such a
    // symlink could redirect an otherwise-safe write outside the vault root.
    if std::fs::symlink_metadata(file_path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err(VaultKitError::AdapterError(format!(
            "vault output path is a pre-existing symlink: '{}'",
            file_path.display()
        )));
    }
    std::fs::write(file_path, bytes)?;
    Ok(())
}

// MARK: - Filesystem traversal

/// Recursively collect `.md` files under `dir`, skipping hidden files and
/// directories (those whose name starts with `.`) and OKF nav files
/// (`index.md`, `log.md`). Mirrors Swift's
/// `FileManager.enumerator(at:includingPropertiesForKeys:options:[.skipsHiddenFiles])`.
fn collect_md_files(
    dir: &Path,
    vault_root: &Path,
    out: &mut Vec<NoteIR>,
) -> Result<(), VaultKitError> {
    let entries = std::fs::read_dir(dir).map_err(VaultKitError::Io)?;
    for entry in entries {
        let entry = entry.map_err(VaultKitError::Io)?;
        let file_name = entry.file_name();
        let name = file_name.to_string_lossy();
        // Skip hidden files and directories (name starts with `.`).
        if name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        let file_type = entry.file_type().map_err(VaultKitError::Io)?;
        // Skip symbolic links unconditionally — following a symlink on import
        // could read content from outside the vault root. On Unix, file_type()
        // uses lstat(2) semantics (does not follow symlinks), so a symlinked
        // directory would return is_dir() == false and be silently skipped. The
        // explicit is_symlink() check documents the intent and guards other
        // platforms where file_type() may follow symlinks.
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            collect_md_files(&path, vault_root, out)?;
        } else if file_type.is_file() && name.ends_with(".md") {
            // Skip OKF navigation files — index.md and log.md are emitted by
            // from_ir for OKF progressive disclosure; they are not notes.
            // Mirrors Swift `toIR` which skips files with stem "index" / "log".
            let stem = name.trim_end_matches(".md");
            if stem == "index" || stem == "log" {
                continue;
            }

            let raw = std::fs::read_to_string(&path).map_err(VaultKitError::Io)?;
            let relative = relative_path(&path, vault_root);
            let stable_key = drop_md_extension(&relative);
            // Folder portion only (the note's directory inside the vault).
            // Mirrors Swift: `(relativePath as NSString).deletingLastPathComponent`.
            let folder = {
                let p = std::path::Path::new(&relative);
                p.parent()
                    .map(|p| p.to_string_lossy().replace('\\', "/"))
                    .unwrap_or_default()
            };

            let (frontmatter, body) = split_frontmatter(&raw);
            // Parse both wikilinks and standard-md links for unified round-trip.
            let links = parse_all_links(&body);
            let tags = parse_tags(&body);
            // Origin date rides frontmatter (`created:` preferred, `date:` as
            // the fallback Obsidian key). Mirrors Swift adapter.
            let origin_date = frontmatter
                .get("created")
                .or_else(|| frontmatter.get("date"))
                .map(|s| OccurredAt::new(s.clone()));
            // moot_id: the stable substrate lineage UUID. When present, the
            // re-import identity uses this UUID rather than the FNV hash of
            // the stable_source_key — making the note rename-safe. Mirrors
            // Swift `ObsidianAdapter.toIR` where `mootID` is parsed from
            // frontmatter and passed to `NoteIR(mootID:)`.
            let moot_id = frontmatter
                .get("moot_id")
                .and_then(|s| uuid::Uuid::parse_str(s).ok());

            out.push(NoteIR::with_moot_id(
                stable_key,
                vec![Block::markdown(body)],
                frontmatter,
                links,
                tags,
                folder,
                origin_date,
                None,
                moot_id,
            ));
        }
    }
    Ok(())
}

// MARK: - Rendering

/// Render one note to its on-disk Markdown text.
///
/// In OKF mode (`pure_obsidian_links = false`):
/// - Injects `type:` frontmatter key (OKF required field).
/// - Injects `tags: [a, b, c]` frontmatter key when tags are present.
/// - Renders relationship links as standard-md `[alias](relpath.md)`.
///
/// In pure-Obsidian mode (`pure_obsidian_links = true`):
/// - Renders relationship links as `[[Target]]` / `[[Target|Alias]]`.
///
/// In both modes `type:` and frontmatter `tags:` are emitted.
/// Mirrors Swift `ObsidianAdapter.render(_:pureObsidianLinks:keyByName:)`.
pub fn render(
    note: &NoteIR,
    pure_obsidian_links: bool,
    key_by_name: &HashMap<String, String>,
) -> String {
    // Merge the note's own frontmatter with OKF-required injected keys.
    // Use a BTreeMap for deterministic key order (sorted output). Mirrors Swift
    // which uses `.keys.sorted()` before emitting frontmatter.
    let mut fm: std::collections::BTreeMap<String, String> = note
        .frontmatter
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();

    // OKF required field: `type:`. Derived from NoteIR.kind.
    // Existing `type:` frontmatter is preserved when the producer already set it.
    fm.entry("type".to_owned())
        .or_insert_with(|| okf_type(&note.kind));

    // Frontmatter tags array — OKF idiom. Emitted in addition to inline #tag tokens.
    // Format: `[a, b, c]` matching OKF/Obsidian YAML list convention.
    if !note.tags.is_empty() {
        fm.entry("tags".to_owned()).or_insert_with(|| {
            format!("[{}]", note.tags.join(", "))
        });
    }

    let mut out = String::new();
    if !fm.is_empty() {
        out.push_str("---\n");
        // BTreeMap iterates in sorted key order — deterministic. Mirrors Swift.
        // Values are YAML-quoted to prevent injection: a room/wing name containing
        // '\nmoot_id: evil' would forge an additional structural frontmatter key
        // if emitted raw. yaml_scalar_quote wraps unsafe values in double-quoted
        // scalars so every value is contained to its own key.
        // Mirrors Swift `ObsidianAdapter.yamlScalarQuote(_:)`.
        for (key, value) in &fm {
            out.push_str(&format!("{}: {}\n", key, yaml_scalar_quote(value)));
        }
        out.push_str("---\n");
    }

    let body = note.flattened_body();

    // Determine which links are missing from the body (need to be appended).
    let missing_links: Vec<&WikiLink> = if pure_obsidian_links {
        // Wikilink mode: links absent from body as [[raw]].
        note.links
            .iter()
            .filter(|link| !body.contains(&format!("[[{}]]", link.raw)))
            .collect()
    } else {
        // OKF mode: links absent both as [[wikilink]] and as [text](path).
        // Estate-origin notes have links in note.links but not in the body;
        // vault-origin notes carry wikilinks in body verbatim.
        note.links
            .iter()
            .filter(|link| {
                let wiki_present = body.contains(&format!("[[{}]]", link.raw));
                let md_target =
                    resolve_standard_md_link(&note.stable_source_key, link, key_by_name);
                let md_present = body.contains(&md_target);
                !wiki_present && !md_present
            })
            .collect()
    };

    if !missing_links.is_empty() {
        out.push_str(&body);
        // `body` is fully consumed above; no further reads needed.
        out.push_str("\n\n");
        let link_strs: Vec<String> = missing_links
            .iter()
            .map(|l| render_link(l, pure_obsidian_links, &note.stable_source_key, key_by_name))
            .collect();
        out.push_str(&link_strs.join(" "));
        let missing_tags: Vec<&str> = note
            .tags
            .iter()
            .filter(|t| !out.contains(&format!("#{t}")))
            .map(String::as_str)
            .collect();
        if !missing_tags.is_empty() {
            out.push_str("\n\n");
            let tag_strs: Vec<String> = missing_tags.iter().map(|t| format!("#{t}")).collect();
            out.push_str(&tag_strs.join(" "));
        }
        return out;
    }

    // No links to append; still append any tags missing from the body.
    out.push_str(&body);
    let missing_tags: Vec<&str> = note
        .tags
        .iter()
        .filter(|t| !body.contains(&format!("#{t}")))
        .map(String::as_str)
        .collect();
    if !missing_tags.is_empty() {
        out.push_str("\n\n");
        let tag_strs: Vec<String> = missing_tags.iter().map(|t| format!("#{t}")).collect();
        out.push_str(&tag_strs.join(" "));
    }
    out
}

// MARK: - OKF helpers

/// Derive the OKF `type:` value from a NoteIR kind string.
///
/// Mapping: `"note"→"Note"`, `"fact"→"Fact"`, `"journal"→"Journal"`,
/// else the kind with its first character uppercased.
/// Mirrors Swift `ObsidianAdapter.okfType(from:)`.
pub(crate) fn okf_type(kind: &str) -> String {
    match kind {
        "note" => "Note".to_owned(),
        "fact" => "Fact".to_owned(),
        "journal" => "Journal".to_owned(),
        other => {
            let mut chars = other.chars();
            match chars.next() {
                None => String::new(),
                Some(first) => {
                    let mut s = first.to_uppercase().to_string();
                    s.push_str(chars.as_str());
                    s
                }
            }
        }
    }
}

/// Render a single WikiLink as either a wikilink or a standard-md link.
/// Mirrors Swift `ObsidianAdapter.renderLink(_:pureObsidianLinks:sourceKey:keyByName:)`.
fn render_link(
    link: &WikiLink,
    pure_obsidian_links: bool,
    source_key: &str,
    key_by_name: &HashMap<String, String>,
) -> String {
    if pure_obsidian_links {
        format!("[[{}]]", link.raw)
    } else {
        let label = link.alias.as_deref().unwrap_or(&link.target);
        let path = resolve_standard_md_link(source_key, link, key_by_name);
        format!("[{label}]({path})")
    }
}

/// Compute the standard-md path string `alias.md` or `relpath/alias.md` for a link.
/// Mirrors Swift `ObsidianAdapter.resolveStandardMDLink(from:link:keyByName:)`.
fn resolve_standard_md_link(
    source_key: &str,
    link: &WikiLink,
    key_by_name: &HashMap<String, String>,
) -> String {
    let target_name = &link.target;
    let default_key = slug(target_name);
    let target_key = key_by_name.get(target_name).map(String::as_str).unwrap_or(&default_key);
    let target_path = format!("{}.md", target_key);
    let source_folder = parent_folder(source_key);
    relative_md_path(&source_folder, &target_path)
}

/// Compute the relative path from a source folder to a target vault path.
/// Mirrors Swift `ObsidianAdapter.relativeMDPath(from:to:)`.
fn relative_md_path(source_folder: &str, target_path: &str) -> String {
    if source_folder.is_empty() {
        // Source is at vault root — target path IS the relative path.
        return target_path.to_owned();
    }

    let source_parts: Vec<&str> = source_folder.split('/').collect();
    let target_parts: Vec<&str> = target_path.split('/').collect();

    // Find common prefix depth.
    let mut common = 0;
    while common < source_parts.len()
        && common < target_parts.len()
        && source_parts[common] == target_parts[common]
    {
        common += 1;
    }

    // Climb from source to common ancestor, then descend to target.
    let up_count = source_parts.len() - common;
    let mut components: Vec<&str> = vec![".."; up_count];
    components.extend_from_slice(&target_parts[common..]);
    components.join("/")
}

/// Minimal slug for unresolved link targets.
fn slug(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .map(|c| if c == ' ' { '-' } else { c })
        .filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_')
        .collect()
}

/// Return the last path component of a vault-relative key (no extension).
fn last_path_component(key: &str) -> String {
    key.split('/').last().unwrap_or(key).to_owned()
}

/// Return the parent folder portion of a vault-relative key (empty = root).
fn parent_folder(key: &str) -> String {
    match key.rfind('/') {
        Some(idx) => key[..idx].to_owned(),
        None => String::new(),
    }
}

// MARK: - Parsing helpers

/// Split a raw file into (frontmatter map, body). When the file opens with a
/// `---` fence, everything up to the next `---` line is parsed as flat
/// `key: value`; the body is everything after. With no opening fence the
/// whole file is the body and the map is empty.
/// Mirrors Swift `ObsidianAdapter.splitFrontmatter(_:)`.
pub fn split_frontmatter(raw: &str) -> (HashMap<String, String>, String) {
    if !raw.starts_with("---\n") && !raw.starts_with("---\r\n") {
        return (HashMap::new(), raw.to_owned());
    }
    let lines: Vec<&str> = raw.split('\n').collect();
    // lines[0] is the opening "---". Find the closing fence.
    let mut closing_index: Option<usize> = None;
    for (i, line) in lines.iter().enumerate().skip(1) {
        let trimmed = line.trim_end_matches('\r');
        if trimmed == "---" {
            closing_index = Some(i);
            break;
        }
    }
    let close = match closing_index {
        Some(i) => i,
        // Unterminated fence — treat the whole file as body.
        None => return (HashMap::new(), raw.to_owned()),
    };

    let mut map: HashMap<String, String> = HashMap::new();
    for line in &lines[1..close] {
        let line = line.trim_end_matches('\r');
        if let Some(colon_pos) = line.find(':') {
            let key = line[..colon_pos].trim().to_owned();
            let raw_value = line[colon_pos + 1..].trim().to_owned();
            if !key.is_empty() {
                // Decode double-quoted YAML scalars produced by yaml_scalar_quote.
                // A value wrapped in `"…"` has its outer quotes stripped and its
                // escape sequences decoded so values round-trip verbatim through
                // export→import. Non-quoted values pass through unchanged.
                // Mirrors Swift `ObsidianAdapter.decodeYamlDoubleQuoted(_:)`.
                map.insert(key, decode_yaml_double_quoted(&raw_value));
            }
        }
    }

    let body = lines[close + 1..].join("\n");
    (map, body)
}

/// Emit a YAML scalar that safely contains `value` within its own
/// frontmatter key — no matter what characters the value carries.
///
/// A value is emitted bare when it contains ONLY printable ASCII characters
/// that are safe as YAML unquoted scalars (no newlines, no colon, no `#`,
/// no leading/trailing whitespace, no YAML indicator characters). All other
/// values are wrapped in double quotes with minimal escaping:
///   - `\` → `\\`
///   - `"` → `\"`
///   - LF → `\n`
///   - CR → `\r`
///   - TAB → `\t`
///   - Control characters (U+0000–U+001F, U+007F) → `\uXXXX`
///
/// Legitimate values round-trip verbatim: the quoted form reads back via
/// `decode_yaml_double_quoted` as exactly the original string.
///
/// Mirrors Swift `ObsidianAdapter.yamlScalarQuote(_:)`.
pub(crate) fn yaml_scalar_quote(value: &str) -> String {
    // Fast path: check whether the value can be emitted as a bare scalar.
    let needs_quoting = value.is_empty()
        || value.chars().any(yaml_char_needs_quoting)
        || value.starts_with(char::is_whitespace)
        || value.ends_with(char::is_whitespace);

    if !needs_quoting {
        return value.to_owned();
    }

    // Double-quoted form: wrap and escape minimally.
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"'  => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || c as u32 == 0x7F => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Returns `true` when a character must cause the surrounding YAML value to
/// be quoted. Mirrors Swift `ObsidianAdapter.yamlNeedsQuoting(_:)`.
fn yaml_char_needs_quoting(c: char) -> bool {
    // Control characters (U+0000–U+001F, U+007F) — newline is the injection vector.
    if (c as u32) < 0x20 || c as u32 == 0x7F {
        return true;
    }
    // YAML indicator characters that are not safe in bare scalars.
    // A colon embedded in a value is conservatively quoted so `key: ` patterns
    // within values cannot be mistaken for additional frontmatter keys.
    matches!(c,
        ':' | '#' | '{' | '}' | '[' | ']' | '|' | '>' | '!' | '&'
        | '*' | '\'' | '"' | '%' | '@' | '`'
    )
}

/// Decode a raw YAML value string that may be double-quoted.
///
/// If `raw` starts and ends with `"`, the outer quotes are stripped and the
/// escape sequences that `yaml_scalar_quote` produces are decoded. Non-quoted
/// values (no surrounding `"`) are returned unchanged (backward-compatible).
///
/// Mirrors Swift `ObsidianAdapter.decodeYamlDoubleQuoted(_:)`.
pub(crate) fn decode_yaml_double_quoted(raw: &str) -> String {
    if raw.len() < 2 || !raw.starts_with('"') || !raw.ends_with('"') {
        return raw.to_owned();
    }
    // Strip outer quotes.
    let inner = &raw[1..raw.len() - 1];
    let mut result = String::with_capacity(inner.len());
    let mut chars = inner.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\\' {
            result.push(c);
            continue;
        }
        match chars.next() {
            Some('"')  => result.push('"'),
            Some('\\') => result.push('\\'),
            Some('n')  => result.push('\n'),
            Some('r')  => result.push('\r'),
            Some('t')  => result.push('\t'),
            Some('u')  => {
                // \uXXXX — consume exactly 4 hex digits.
                let hex: String = (0..4).filter_map(|_| chars.next()).collect();
                if let Some(cp) = u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32) {
                    result.push(cp);
                } else {
                    // Malformed — emit as-is.
                    result.push_str("\\u");
                    result.push_str(&hex);
                }
            }
            Some(other) => {
                // Unknown escape — keep both characters.
                result.push('\\');
                result.push(other);
            }
            None => result.push('\\'),
        }
    }
    result
}

/// Parse both wikilinks `[[Target]]` / `[[Target|Alias]]` and standard-md
/// links `[text](path.md)` from a body, returning a unified `Vec<WikiLink>`
/// with duplicates removed (by `raw` field).
///
/// Mirrors Swift `ObsidianAdapter.parseAllLinks(in:)`.
pub(crate) fn parse_all_links(body: &str) -> Vec<WikiLink> {
    let mut links: Vec<WikiLink> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();

    for link in parse_wiki_links(body) {
        if seen.insert(link.raw.clone()) {
            links.push(link);
        }
    }
    for link in parse_standard_md_links(body) {
        if seen.insert(link.raw.clone()) {
            links.push(link);
        }
    }

    links
}

/// Extract wikilinks `[[Target]]` / `[[Target|Alias]]` from a body.
/// Mirrors Swift `ObsidianAdapter.parseWikiLinks(in:)`.
/// Uses manual scanning to avoid a regex dependency (zero external deps).
pub(crate) fn parse_wiki_links(body: &str) -> Vec<WikiLink> {
    let mut links: Vec<WikiLink> = Vec::new();
    let bytes = body.as_bytes();
    let mut i = 0;
    while i + 1 < bytes.len() {
        if bytes[i] == b'[' && bytes[i + 1] == b'[' {
            // Find closing `]]`.
            if let Some(close) = body[i + 2..].find("]]") {
                let inner = &body[i + 2..i + 2 + close];
                if let Some(pipe) = inner.find('|') {
                    let target = inner[..pipe].to_owned();
                    let alias = inner[pipe + 1..].to_owned();
                    links.push(WikiLink::new(target, Some(alias), inner));
                } else {
                    links.push(WikiLink::new(inner, None, inner));
                }
                i += 2 + close + 2; // skip past `]]`
                continue;
            }
        }
        // Advance by one UTF-8 character (not one byte).
        i += body[i..].chars().next().map_or(1, |c| c.len_utf8());
    }
    links
}

/// Extract standard markdown links `[text](path.md)` from a body.
///
/// Only matches local `.md` links (not `http://…`). Each parsed link carries:
/// - `target`: basename without `.md` (e.g. `"Alpha"`)
/// - `alias`: link text (e.g. `"My Note"`)
/// - `raw`: `"alias||path"` for round-trip reconstruction
///
/// Mirrors Swift `ObsidianAdapter.parseStandardMDLinks(in:)`.
/// Uses manual scanning to avoid a regex dependency.
pub(crate) fn parse_standard_md_links(body: &str) -> Vec<WikiLink> {
    let mut links: Vec<WikiLink> = Vec::new();
    let chars: Vec<char> = body.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        // Look for `[`.
        if chars[i] != '[' {
            i += 1;
            continue;
        }
        // Find closing `]`.
        let text_start = i + 1;
        let mut text_end = text_start;
        while text_end < chars.len() && chars[text_end] != ']' {
            text_end += 1;
        }
        if text_end >= chars.len() {
            i += 1;
            continue;
        }
        // Expect `(` immediately after `]`.
        if text_end + 1 >= chars.len() || chars[text_end + 1] != '(' {
            i += 1;
            continue;
        }
        // Find closing `)`.
        let path_start = text_end + 2;
        let mut path_end = path_start;
        while path_end < chars.len() && chars[path_end] != ')' {
            path_end += 1;
        }
        if path_end >= chars.len() {
            i += 1;
            continue;
        }

        let text: String = chars[text_start..text_end].iter().collect();
        let path: String = chars[path_start..path_end].iter().collect();

        // Skip external links.
        if !path.starts_with("http://") && !path.starts_with("https://") && path.ends_with(".md") {
            // Target = basename without .md.
            let basename = path.split('/').last().unwrap_or(&path);
            let target = if basename.ends_with(".md") {
                basename[..basename.len() - 3].to_owned()
            } else {
                basename.to_owned()
            };
            // `raw` = "text||path" so round-trip reconstruction can distinguish
            // alias from path — mirrors Swift `parseStandardMDLinks`.
            let raw = format!("{}||{}", text, path);
            links.push(WikiLink::new(target, Some(text), raw));
        }

        i = path_end + 1;
    }
    links
}

/// Extract inline `#tag` tokens from a body, excluding the `# heading` form
/// (a `#` followed by whitespace). A tag starts with a letter and continues
/// with word characters, `-`, `_`, or `/`. The `#` must not be preceded by a
/// word character (so `C#` is not a tag). Mirrors Swift `parseTags(in:)`.
pub(crate) fn parse_tags(body: &str) -> Vec<String> {
    let mut tags: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let chars: Vec<char> = body.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '#' {
            // The `#` must not be preceded by a word character.
            let preceded_by_word = i > 0
                && {
                    let prev = chars[i - 1];
                    prev.is_alphanumeric() || prev == '_'
                };
            if !preceded_by_word && i + 1 < chars.len() {
                let next = chars[i + 1];
                // Must start with a letter (not whitespace, not `#`).
                if next.is_alphabetic() {
                    // Consume the tag: letters, digits, `-`, `_`, `/`.
                    let start = i + 1;
                    let mut end = start;
                    while end < chars.len() {
                        let c = chars[end];
                        if c.is_alphanumeric() || c == '-' || c == '_' || c == '/' {
                            end += 1;
                        } else {
                            break;
                        }
                    }
                    let tag: String = chars[start..end].iter().collect();
                    if seen.insert(tag.clone()) {
                        tags.push(tag);
                    }
                    i = end;
                    continue;
                }
            }
        }
        i += 1;
    }
    tags
}

// MARK: - Path helpers

/// Forward-slash vault-relative path of `file_path` under `root`.
/// Mirrors Swift `ObsidianAdapter.relativePath(of:under:)`.
fn relative_path(file_path: &Path, root: &Path) -> String {
    file_path
        .strip_prefix(root)
        .unwrap_or(file_path)
        .to_string_lossy()
        .replace('\\', "/")
}

/// Drop a trailing `.md` extension from a vault-relative path.
/// Mirrors Swift `ObsidianAdapter.dropMarkdownExtension(_:)`.
fn drop_md_extension(path: &str) -> String {
    if path.ends_with(".md") {
        path[..path.len() - 3].to_owned()
    } else {
        path.to_owned()
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault_adapter::VaultAdapter;

    fn temp_vault() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("vaultkit-obsidian-{}", uuid_str()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn uuid_str() -> String {
        // Simple unique ID without uuid crate — time-based enough for tests.
        use std::time::{SystemTime, UNIX_EPOCH};
        let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        format!("{}{}", t.as_secs(), t.subsec_nanos())
    }

    fn write_note(vault: &std::path::Path, rel: &str, content: &str) {
        let path = vault.join(rel);
        if let Some(p) = path.parent() {
            std::fs::create_dir_all(p).unwrap();
        }
        std::fs::write(path, content).unwrap();
    }

    #[test]
    fn parses_frontmatter_wikilinks_tags_and_folder() {
        let vault = temp_vault();
        write_note(
            &vault,
            "Area/Sub/Carbon.md",
            "---\nwing: wing_owner\nroom: research\ncreated: 2024-03-04T05:06:07.000Z\n---\nA note about [[Organic Chemistry]] and [[Q11173|benzene]].\nFiled under #chemistry and #reference.\n",
        );

        let adapter = ObsidianAdapter::new();
        let notes = adapter.to_ir(&vault).unwrap();
        std::fs::remove_dir_all(&vault).ok();

        assert_eq!(notes.len(), 1);
        let note = &notes[0];
        assert_eq!(note.stable_source_key, "Area/Sub/Carbon");
        assert_eq!(note.original_path, "Area/Sub");
        assert_eq!(note.frontmatter.get("wing").map(String::as_str), Some("wing_owner"));
        assert_eq!(note.frontmatter.get("room").map(String::as_str), Some("research"));
        assert_eq!(
            note.origin_date.as_ref().map(|o| o.iso8601.as_str()),
            Some("2024-03-04T05:06:07.000Z")
        );
        assert_eq!(note.links.len(), 2);
        assert!(note.links.contains(&WikiLink::new(
            "Organic Chemistry",
            None,
            "Organic Chemistry"
        )));
        assert!(note.links.contains(&WikiLink::new(
            "Q11173",
            Some("benzene".to_owned()),
            "Q11173|benzene"
        )));
        assert_eq!(note.tags, vec!["chemistry", "reference"]);
    }

    #[test]
    fn round_trip_is_stable_pure_obsidian_mode() {
        // Pure-Obsidian mode: wikilinks in body are preserved byte-for-byte.
        let source = temp_vault();
        let dest = temp_vault();

        write_note(
            &source,
            "Folder/Alpha.md",
            "---\nroom: inbox\nudc: 004\n---\nBody with a [[Link]] and a #topic tag.\nSecond line.\n",
        );
        write_note(&source, "Beta.md", "---\nroom: archive\n---\nPlain note, no links.\n");

        let adapter = ObsidianAdapter::with_options(true); // pure-Obsidian mode
        let first = adapter.to_ir(&source).unwrap();
        adapter.from_ir(&first, &dest).unwrap();
        let second = adapter.to_ir(&dest).unwrap();

        std::fs::remove_dir_all(&source).ok();
        std::fs::remove_dir_all(&dest).ok();

        // Core fields must be equal.
        assert_eq!(first.len(), second.len());
        for (a, b) in first.iter().zip(second.iter()) {
            assert_eq!(a.stable_source_key, b.stable_source_key);
            assert_eq!(a.body, b.body);
            assert_eq!(a.tags, b.tags);
        }
    }

    #[test]
    fn round_trip_is_stable_default_okf_mode() {
        // OKF default mode: link targets survive the round-trip.
        let source = temp_vault();
        let dest = temp_vault();

        write_note(
            &source,
            "Folder/Alpha.md",
            "---\nroom: inbox\nudc: 004\n---\nBody with a [[Link]] and a #topic tag.\nSecond line.\n",
        );
        write_note(&source, "Beta.md", "---\nroom: archive\n---\nPlain note, no links.\n");

        let adapter = ObsidianAdapter::new(); // OKF default
        let first = adapter.to_ir(&source).unwrap();
        adapter.from_ir(&first, &dest).unwrap();
        let second = adapter.to_ir(&dest).unwrap();

        std::fs::remove_dir_all(&source).ok();
        std::fs::remove_dir_all(&dest).ok();

        assert_eq!(first.len(), second.len());
        for (a, b) in first.iter().zip(second.iter()) {
            assert_eq!(a.stable_source_key, b.stable_source_key);
            assert_eq!(a.tags, b.tags);
            // Link targets survive (raw encoding may change wiki→standard-md).
            let a_targets: std::collections::HashSet<_> =
                a.links.iter().map(|l| &l.target).collect();
            let b_targets: std::collections::HashSet<_> =
                b.links.iter().map(|l| &l.target).collect();
            assert_eq!(a_targets, b_targets, "link targets must survive OKF round-trip");
        }
    }

    #[test]
    fn heading_is_not_tag() {
        let tags = parse_tags("# Heading\nText #realtag here");
        assert_eq!(tags, vec!["realtag"]);
    }

    #[test]
    fn split_frontmatter_no_fence_returns_whole_as_body() {
        let (fm, body) = split_frontmatter("No frontmatter here.");
        assert!(fm.is_empty());
        assert_eq!(body, "No frontmatter here.");
    }

    #[test]
    fn split_frontmatter_unterminated_fence_is_body() {
        let raw = "---\nkey: val\nno closing fence";
        let (fm, body) = split_frontmatter(raw);
        assert!(fm.is_empty());
        assert_eq!(body, raw);
    }

    // MARK: - OKF tests

    #[test]
    fn okf_type_mapping() {
        assert_eq!(okf_type("note"), "Note");
        assert_eq!(okf_type("fact"), "Fact");
        assert_eq!(okf_type("journal"), "Journal");
        assert_eq!(okf_type("flashcard"), "Flashcard");
        assert_eq!(okf_type("task"), "Task");
    }

    #[test]
    fn okf_default_emits_type_key() {
        // A note rendered in OKF mode must carry `type:` in frontmatter.
        let note = NoteIR::with_moot_id(
            "TestNote".to_owned(),
            vec![Block::markdown("Body.".to_owned())],
            HashMap::new(),
            vec![],
            vec![],
            "".to_owned(),
            None,
            None,
            None,
        );
        let out = render(&note, false, &HashMap::new());
        assert!(out.contains("type: Note"), "OKF default must emit type: key, got: {out}");
    }

    #[test]
    fn okf_default_emits_frontmatter_tags() {
        let note = NoteIR::with_moot_id(
            "TaggedNote".to_owned(),
            vec![Block::markdown("Body.".to_owned())],
            HashMap::new(),
            vec![],
            vec!["swift".to_owned(), "testing".to_owned()],
            "".to_owned(),
            None,
            None,
            None,
        );
        let out = render(&note, false, &HashMap::new());
        assert!(out.contains("tags:"), "OKF default must emit frontmatter tags: key");
        assert!(out.contains("swift"), "swift tag must appear in frontmatter tags");
        assert!(out.contains("testing"), "testing tag must appear");
    }

    #[test]
    fn pure_obsidian_mode_still_emits_type_and_tags() {
        let note = NoteIR::with_moot_id(
            "MyNote".to_owned(),
            vec![Block::markdown("Body.".to_owned())],
            HashMap::new(),
            vec![],
            vec!["alpha".to_owned()],
            "".to_owned(),
            None,
            None,
            None,
        );
        let out = render(&note, true, &HashMap::new());
        assert!(out.contains("type: Note"), "pure-Obsidian mode must still emit type:");
        assert!(out.contains("tags:"), "pure-Obsidian mode must still emit frontmatter tags:");
    }

    #[test]
    fn okf_default_emits_standard_md_links() {
        // Estate-origin note whose links live in note.links (not in body).
        let note = NoteIR::with_moot_id(
            "Folder/Alpha".to_owned(),
            vec![Block::markdown("Body text.".to_owned())],
            HashMap::new(),
            vec![WikiLink::new("Beta", None, "Beta")],
            vec![],
            "Folder".to_owned(),
            None,
            None,
            None,
        );
        let key_by_name: HashMap<String, String> =
            [("Beta".to_owned(), "Folder/Beta".to_owned())].into_iter().collect();
        let out = render(&note, false, &key_by_name);
        assert!(out.contains("[Beta](Beta.md)"), "OKF mode must emit standard-md link, got: {out}");
        assert!(!out.contains("[[Beta]]"), "OKF mode must NOT emit wikilink");
    }

    #[test]
    fn pure_obsidian_mode_emits_wikilinks() {
        let note = NoteIR::with_moot_id(
            "Folder/Alpha".to_owned(),
            vec![Block::markdown("Body text.".to_owned())],
            HashMap::new(),
            vec![WikiLink::new("Beta", Some("see beta".to_owned()), "Beta|see beta")],
            vec![],
            "Folder".to_owned(),
            None,
            None,
            None,
        );
        let out = render(&note, true, &HashMap::new());
        assert!(out.contains("[[Beta|see beta]]"), "pure-Obsidian mode must emit wikilink");
        assert!(!out.contains("[see beta]("), "pure-Obsidian mode must NOT emit standard-md link");
    }

    #[test]
    fn importer_skips_index_md() {
        let vault = temp_vault();
        write_note(&vault, "Folder/RealNote.md", "---\nroom: r\n---\nReal note body.");
        // Write an index.md that must be skipped on import.
        write_note(&vault, "Folder/index.md", "# Index\n\n- [RealNote](RealNote.md)\n");

        let adapter = ObsidianAdapter::new();
        let notes = adapter.to_ir(&vault).unwrap();
        std::fs::remove_dir_all(&vault).ok();

        assert_eq!(notes.len(), 1, "index.md must be skipped; only RealNote should import");
        assert_eq!(notes[0].stable_source_key, "Folder/RealNote");
    }

    #[test]
    fn importer_skips_log_md() {
        let vault = temp_vault();
        write_note(&vault, "Real.md", "Real body.");
        write_note(&vault, "log.md", "# Log\n\nSome log entry.");

        let adapter = ObsidianAdapter::new();
        let notes = adapter.to_ir(&vault).unwrap();
        std::fs::remove_dir_all(&vault).ok();

        assert_eq!(notes.len(), 1, "log.md must be skipped");
        assert_eq!(notes[0].stable_source_key, "Real");
    }

    #[test]
    fn from_ir_emits_index_md_per_folder() {
        let source = temp_vault();
        let dest = temp_vault();

        write_note(&source, "Folder/NoteA.md", "---\nroom: a\n---\nNote A.");
        write_note(&source, "Folder/NoteB.md", "---\nroom: b\n---\nNote B.");
        write_note(&source, "Root.md", "---\nroom: r\n---\nRoot note.");

        let adapter = ObsidianAdapter::new();
        let notes = adapter.to_ir(&source).unwrap();
        adapter.from_ir(&notes, &dest).unwrap();

        // Root index.md must exist.
        assert!(dest.join("index.md").exists(), "root index.md must be emitted");

        // Folder/index.md must exist and list NoteA and NoteB.
        let folder_index = dest.join("Folder").join("index.md");
        assert!(folder_index.exists(), "Folder/index.md must be emitted");
        let content = std::fs::read_to_string(&folder_index).unwrap();
        assert!(content.contains("[NoteA](NoteA.md)"), "folder index must link NoteA");
        assert!(content.contains("[NoteB](NoteB.md)"), "folder index must link NoteB");

        std::fs::remove_dir_all(&source).ok();
        std::fs::remove_dir_all(&dest).ok();
    }

    #[test]
    fn okf_validity_every_note_has_type_key() {
        let source = temp_vault();
        let dest = temp_vault();

        write_note(&source, "Alpha.md", "---\nroom: a\n---\nAlpha body.");
        write_note(&source, "Folder/Beta.md", "---\nroom: b\n---\nBeta body.");

        let adapter = ObsidianAdapter::new();
        let notes = adapter.to_ir(&source).unwrap();
        adapter.from_ir(&notes, &dest).unwrap();

        // Every .md file that is NOT an index must carry type:.
        let mut checked = 0;
        let mut stack = vec![dest.clone()];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(&dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                } else if path.extension().map(|e| e == "md").unwrap_or(false) {
                    let stem = path.file_stem().unwrap().to_string_lossy();
                    if stem == "index" || stem == "log" { continue; }
                    let content = std::fs::read_to_string(&path).unwrap();
                    assert!(content.contains("type:"), "every note must have type: OKF key — failed for {path:?}");
                    checked += 1;
                }
            }
        }
        assert_eq!(checked, 2, "expected exactly 2 note files");

        std::fs::remove_dir_all(&source).ok();
        std::fs::remove_dir_all(&dest).ok();
    }

    #[test]
    fn parse_standard_md_links_basic() {
        let body = "See [Alpha](notes/Alpha.md) and [Organic Chemistry](chem/Organic-Chemistry.md).";
        let links = parse_standard_md_links(body);
        assert_eq!(links.len(), 2);
        assert!(links.iter().any(|l| l.target == "Alpha"));
        assert!(links.iter().any(|l| l.target == "Organic-Chemistry"));
    }

    #[test]
    fn parse_standard_md_links_skips_external() {
        let body = "See [example](https://example.com/page.md) for details.";
        let links = parse_standard_md_links(body);
        assert!(links.is_empty(), "external http links must not be parsed as local note links");
    }

    #[test]
    fn parse_all_links_unifies_and_deduplicates() {
        let body = "[[Alpha]] and [Beta](Beta.md) and [[Alpha]]";
        let links = parse_all_links(body);
        let targets: Vec<_> = links.iter().map(|l| l.target.as_str()).collect();
        assert!(targets.contains(&"Alpha"));
        assert!(targets.contains(&"Beta"));
        let alpha_count = targets.iter().filter(|&&t| t == "Alpha").count();
        assert_eq!(alpha_count, 1, "duplicates must be removed");
    }

    #[test]
    fn relative_md_path_from_root() {
        assert_eq!(relative_md_path("", "notes/Alpha.md"), "notes/Alpha.md");
    }

    #[test]
    fn relative_md_path_same_folder() {
        assert_eq!(relative_md_path("Folder", "Folder/Beta.md"), "Beta.md");
    }

    #[test]
    fn relative_md_path_cross_folder() {
        assert_eq!(relative_md_path("A/B", "C/D.md"), "../../C/D.md");
    }

    // MARK: - Symlink boundary hardening (PR #42 parity)

    /// to_ir must skip a symlinked markdown file inside the vault — following it
    /// could read content from outside the vault root.
    #[test]
    fn to_ir_skips_symlinked_markdown_files() {
        let base = temp_vault();
        let vault = base.join("vault");
        let outside = base.join("outside-secret.md");
        std::fs::create_dir_all(&vault).unwrap();
        std::fs::write(&outside, "EXFILTRATED_SECRET").unwrap();
        // Pre-plant a symlink inside the vault pointing to the file outside.
        std::os::unix::fs::symlink(&outside, vault.join("secret.md")).unwrap();
        write_note(&vault, "safe.md", "safe");

        let adapter = ObsidianAdapter::new();
        let notes = adapter.to_ir(&vault).unwrap();

        std::fs::remove_dir_all(&base).ok();

        // Only the legitimate note must be returned; the symlinked file must be skipped.
        assert_eq!(notes.len(), 1, "symlinked .md file must be skipped");
        assert_eq!(notes[0].stable_source_key, "safe");
        assert_eq!(notes[0].flattened_body(), "safe");
    }

    /// from_ir must refuse to write to a path that is already a symlink —
    /// write_contained_file guards this via symlink_metadata before fs::write.
    #[test]
    fn from_ir_rejects_pre_existing_symlinked_output_file() {
        let base = temp_vault();
        let vault = base.join("vault");
        let outside = base.join("outside.md");
        std::fs::create_dir_all(&vault).unwrap();
        std::fs::write(&outside, "original-outside-content").unwrap();
        // Pre-plant the symlink at the exact export target path.
        std::os::unix::fs::symlink(&outside, vault.join("note.md")).unwrap();

        let adapter = ObsidianAdapter::new();
        let result = adapter.from_ir(
            &[crate::note_ir::NoteIR::with_moot_id(
                "note".to_owned(),
                vec![crate::note_ir::Block::markdown("changed".to_owned())],
                std::collections::HashMap::new(),
                vec![],
                vec![],
                "".to_owned(),
                None,
                None,
                None,
            )],
            &vault,
        );

        // The write must fail because a symlink exists at the target path.
        assert!(result.is_err(), "from_ir must reject a pre-existing symlinked output path");
        // The file outside the vault must be untouched.
        let content = std::fs::read_to_string(&outside).unwrap();
        assert_eq!(content, "original-outside-content", "outside file must not be modified");

        std::fs::remove_dir_all(&base).ok();
    }

    /// from_ir must succeed for a normal (non-symlink) export to a clean vault.
    #[test]
    fn from_ir_accepts_legitimate_non_symlink_export() {
        let vault = temp_vault();

        let adapter = ObsidianAdapter::new();
        adapter
            .from_ir(
                &[crate::note_ir::NoteIR::with_moot_id(
                    "Wing/Room/note".to_owned(),
                    vec![crate::note_ir::Block::markdown("hello".to_owned())],
                    std::collections::HashMap::new(),
                    vec![],
                    vec![],
                    "Wing/Room".to_owned(),
                    None,
                    None,
                    None,
                )],
                &vault,
            )
            .unwrap();

        let expected = vault.join("Wing/Room/note.md");
        assert!(expected.exists(), "legitimate export must create the note file inside the vault");
        let content = std::fs::read_to_string(&expected).unwrap();
        assert!(content.contains("hello"), "exported note must contain the body text");

        std::fs::remove_dir_all(&vault).ok();
    }
}
