//! ObsidianAdapter — Obsidian-flavoured Markdown ⇄ `NoteIR`.
//!
//! One `.md` file is one `NoteIR`. The adapter understands the four Obsidian
//! surface features the bridge round-trips in V1:
//!
//! - **YAML frontmatter** (`--- … ---` at the top of the file) → the
//!   `frontmatter` map. A flat `key: value` reader; nested YAML is not an
//!   Obsidian frontmatter idiom and is out of scope.
//! - **Wikilinks** `[[Target]]` / `[[Target|Alias]]` → `links`.
//! - **Tags** `#tag` (inline, not the `# heading` form) → `tags`.
//! - **Folder path** → `original_path` and `stable_source_key`.
//!
//! Round-trip contract: `to_ir(from_ir(x)) == x` for the fields Obsidian
//! represents. The body string retains its wikilink and tag markup, so links
//! and tags are *views* over the body, not edits to it — emission writes the
//! body verbatim and re-parsing recovers the same views.
//!
//! This is a mechanical port of `ObsidianAdapter.swift`. All parsing logic
//! is reproduced with Rust idioms; the observable contract (round-trip
//! equality, deterministic sort order, `.skipsHiddenFiles` equivalence) is
//! identical.

use crate::error::VaultKitError;
use crate::note_ir::{Block, NoteIR, OccurredAt, WikiLink};
use crate::vault_adapter::VaultAdapter;
use std::collections::HashMap;
use std::path::Path;

/// The first `VaultAdapter`: Obsidian-flavoured Markdown ⇄ `NoteIR`.
#[derive(Debug, Default, Clone)]
pub struct ObsidianAdapter;

impl ObsidianAdapter {
    pub fn new() -> Self {
        Self
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
        std::fs::create_dir_all(vault_path)?;
        for note in notes {
            // The note is written at `<stable_source_key>.md`, so the folder
            // tree mirrors the wing/room path that `DrawerMapping` encoded
            // into the key on export. Re-reading recovers the same
            // `stable_source_key` and `original_path`.
            let relative = format!("{}.md", note.stable_source_key);
            let file_path = vault_path.join(&relative);
            if let Some(parent) = file_path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let text = render(note);
            std::fs::write(&file_path, text.as_bytes())?;
        }
        Ok(())
    }
}

// MARK: - Filesystem traversal

/// Recursively collect `.md` files under `dir`, skipping hidden files and
/// directories (those whose name starts with `.`). Mirrors Swift's
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
        if file_type.is_dir() {
            collect_md_files(&path, vault_root, out)?;
        } else if file_type.is_file() && name.ends_with(".md") {
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
            let links = parse_wiki_links(&body);
            let tags = parse_tags(&body);
            // Origin date rides frontmatter (`created:` preferred, `date:` as
            // the fallback Obsidian key). Mirrors Swift adapter.
            let origin_date = frontmatter
                .get("created")
                .or_else(|| frontmatter.get("date"))
                .map(|s| OccurredAt::new(s.clone()));

            out.push(NoteIR::new(
                stable_key,
                vec![Block::markdown(body)],
                frontmatter,
                links,
                tags,
                folder,
                origin_date,
                None,
            ));
        }
    }
    Ok(())
}

// MARK: - Rendering

/// Render one note to its on-disk Markdown text: frontmatter block (when
/// present) followed by the body, with any links or tags that are not already
/// embedded in the body appended so an estate-origin note (whose links live in
/// tunnels, not body text) emits real wikilinks. A vault-origin note already
/// carries its markup in the body, so nothing is duplicated and the round-trip
/// stays exact. Mirrors Swift `ObsidianAdapter.render(_:)`.
pub(crate) fn render(note: &NoteIR) -> String {
    let mut out = String::new();
    if !note.frontmatter.is_empty() {
        out.push_str("---\n");
        // Sorted keys for deterministic output. Mirrors Swift.
        let mut keys: Vec<&String> = note.frontmatter.keys().collect();
        keys.sort();
        for key in keys {
            out.push_str(&format!("{}: {}\n", key, note.frontmatter[key]));
        }
        out.push_str("---\n");
    }

    let body = note.flattened_body();
    let missing_links: Vec<&WikiLink> = note
        .links
        .iter()
        .filter(|link| !body.contains(&format!("[[{}]]", link.raw)))
        .collect();

    if !missing_links.is_empty() {
        out.push_str(&body);
        // `body` is fully consumed above; no further reads needed.
        out.push_str("\n\n");
        let link_strs: Vec<String> =
            missing_links.iter().map(|l| format!("[[{}]]", l.raw)).collect();
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

// MARK: - Parsing helpers

/// Split a raw file into (frontmatter map, body). When the file opens with a
/// `---` fence, everything up to the next `---` line is parsed as flat
/// `key: value`; the body is everything after. With no opening fence the
/// whole file is the body and the map is empty.
/// Mirrors Swift `ObsidianAdapter.splitFrontmatter(_:)`.
pub(crate) fn split_frontmatter(raw: &str) -> (HashMap<String, String>, String) {
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
            let value = line[colon_pos + 1..].trim().to_owned();
            if !key.is_empty() {
                map.insert(key, value);
            }
        }
    }

    let body = lines[close + 1..].join("\n");
    (map, body)
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
    fn round_trip_is_stable() {
        let source = temp_vault();
        let dest = temp_vault();

        write_note(
            &source,
            "Folder/Alpha.md",
            "---\nroom: inbox\nudc: 004\n---\nBody with a [[Link]] and a #topic tag.\nSecond line.\n",
        );
        write_note(&source, "Beta.md", "---\nroom: archive\n---\nPlain note, no links.\n");

        let adapter = ObsidianAdapter::new();
        let first = adapter.to_ir(&source).unwrap();
        adapter.from_ir(&first, &dest).unwrap();
        let second = adapter.to_ir(&dest).unwrap();

        std::fs::remove_dir_all(&source).ok();
        std::fs::remove_dir_all(&dest).ok();

        assert_eq!(first, second);
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
}
