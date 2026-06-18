import Foundation

/// The first `VaultAdapter`: Obsidian-flavoured Markdown ⇄ `NoteIR`, and a
/// superset of Google's Open Knowledge Format (OKF) v0.1 in default mode.
///
/// One `.md` file is one `NoteIR`. The adapter understands the four
/// Obsidian surface features the bridge round-trips in V1:
///
/// - **YAML frontmatter** (`--- … ---` at the top of the file) → the
///   `frontmatter` map. A flat `key: value` reader; nested YAML is not
///   an Obsidian frontmatter idiom and is out of scope.
/// - **Wikilinks** `[[Target]]` / `[[Target|Alias]]` → `links`.
/// - **Tags** `#tag` (inline, not the `# heading` form) → `tags`.
/// - **Folder path** → `originalPath` and `stableSourceKey`.
///
/// ## OKF compatibility (default mode: `pureObsidianLinks = false`)
///
/// By default the adapter emits **OKF v0.1-compatible** output that is
/// ALSO readable by Obsidian. Specifically:
///
/// - A `type:` frontmatter key (OKF's only required field) is emitted on
///   every note, derived from `NoteIR.kind`:
///   `"note"→"Note"`, `"fact"→"Fact"`, `"journal"→"Journal"`, else
///   the kind string with its first character uppercased.
/// - Relationship links are rendered as **standard markdown** `[alias](relpath.md)`
///   instead of wikilinks, so OKF consumers that do not understand `[[ ]]`
///   syntax still see valid hyperlinks.
/// - A `tags: [a, b, c]` frontmatter key is emitted in addition to any
///   inline `#tag` tokens already in the body — OKF consumers read the
///   frontmatter list; Obsidian reads both.
/// - One `index.md` per folder is written, listing child notes as
///   standard-markdown links (OKF progressive-disclosure navigation).
///   `index.md` and `log.md` files are **skipped** during read so they
///   never import as spurious notes.
///
/// ## Pure-Obsidian mode (`pureObsidianLinks = true`)
///
/// When `pureObsidianLinks` is `true` the adapter emits literal
/// `[[Target]]` / `[[Target|Alias]]` wikilinks (today's legacy behaviour).
/// The `type:` and frontmatter `tags:` keys are still emitted — they are
/// harmless to Obsidian and required for OKF. Only the link rendering
/// form changes.
///
/// ## Round-trip contract
///
/// `toIR(fromIR(x)) == x` for the fields each flavour represents.
/// - In default mode: standard-md links in the body are parsed back into
///   `links` on re-read; the `type:` and frontmatter `tags:` are stored as
///   frontmatter keys and survive the round-trip through the frontmatter map.
/// - In pure-Obsidian mode: wikilinks are parsed back as before.
public struct ObsidianAdapter: VaultAdapter {

    /// When `false` (default), the adapter writes OKF-compatible output:
    /// standard markdown links `[alias](relpath.md)` for relationships,
    /// a `type:` frontmatter key, and a frontmatter `tags:` array.
    ///
    /// When `true`, the adapter writes literal Obsidian wikilinks
    /// `[[Target]]` / `[[Target|Alias]]` (legacy behaviour). `type:` and
    /// frontmatter `tags:` are still emitted in both modes.
    public let pureObsidianLinks: Bool

    /// Default constructor: OKF-compatible mode (`pureObsidianLinks = false`).
    /// Source-compatible with all existing call sites that used `ObsidianAdapter()`.
    public init() {
        self.pureObsidianLinks = false
    }

    /// Designated constructor for callers that need explicit link-mode control.
    ///
    /// - Parameter pureObsidianLinks: pass `true` to emit `[[wikilinks]]`
    ///   (legacy behaviour); `false` (default) for OKF-compatible standard-md links.
    public init(pureObsidianLinks: Bool) {
        self.pureObsidianLinks = pureObsidianLinks
    }

    // MARK: - Read: vault → IR

    public func toIR(vaultURL: URL) throws -> [NoteIR] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var notes: [NoteIR] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            // Skip OKF navigation files — index.md and log.md are emitted by
            // fromIR for OKF progressive disclosure and diary purposes; they
            // are never notes and must not import as spurious NoteIR values.
            if filename == "index" || filename == "log" {
                continue
            }

            let raw = try String(contentsOf: fileURL, encoding: .utf8)
            // Vault-relative path with forward slashes, e.g. "Area/Note.md".
            let relativePath = ObsidianAdapter.relativePath(of: fileURL, under: vaultURL)
            let stableKey = ObsidianAdapter.dropMarkdownExtension(relativePath)
            // Folder portion only (the note's directory inside the vault).
            let folder = (relativePath as NSString).deletingLastPathComponent

            let (frontmatter, body) = ObsidianAdapter.splitFrontmatter(raw)
            // Parse both wikilinks [[Target]] and standard-md [text](path.md)
            // so vaults written in either mode round-trip correctly.
            let links = ObsidianAdapter.parseAllLinks(in: body)
            let tags = ObsidianAdapter.parseTags(in: body)
            // Origin date rides frontmatter (`created:` preferred, `date:`
            // as the fallback Obsidian key). It is NOT separately
            // serialized, so it round-trips through the frontmatter map.
            let originISO = frontmatter["created"] ?? frontmatter["date"]
            let originDate = originISO.map { OccurredAt(iso8601: $0) }
            // moot_id: the stable substrate lineage UUID. When present, this
            // makes the re-import identity-preserving regardless of filename
            // changes — the UUID wins over the stable-source-key FNV hash as
            // the lineageID for the capture frame.
            let mootID = frontmatter["moot_id"].flatMap { UUID(uuidString: $0) }

            notes.append(NoteIR(
                stableSourceKey: stableKey,
                body: [Block(kind: "markdown", text: body)],
                frontmatter: frontmatter,
                links: links,
                tags: tags,
                originalPath: folder,
                originDate: originDate,
                source: nil,
                mootID: mootID
            ))
        }

        // Deterministic order so repeated reads and round-trip equality
        // are stable regardless of filesystem enumeration order.
        notes.sort { $0.stableSourceKey < $1.stableSourceKey }
        return notes
    }

    // MARK: - Write: IR → vault

    public func fromIR(_ notes: [NoteIR], to vaultURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        // Build a stable-source-key → note map for link resolution in default mode.
        // Key: the note name portion (last path component of stableSourceKey).
        // When two notes share a name but differ by folder, the first (sorted)
        // wins — this is a best-effort resolution that prefers the alphabetically
        // earlier note, matching what the Obsidian resolver does without an open vault.
        var keyByName: [String: String] = [:]
        for note in notes {
            let name = (note.stableSourceKey as NSString).lastPathComponent
            if keyByName[name] == nil {
                keyByName[name] = note.stableSourceKey
            }
        }

        // Track which folders receive at least one note, for index.md emission.
        var folderNotes: [String: [NoteIR]] = [:] // folder → notes in that folder

        for note in notes {
            // The note is written at `<stableSourceKey>.md`, so the folder
            // tree mirrors the wing/room path that `DrawerMapping` encoded
            // into the key on export. Re-reading recovers the same
            // `stableSourceKey` and `originalPath` — this is what makes the
            // round-trip path-faithful without a second source of truth.
            let relativePath = note.stableSourceKey + ".md"
            let fileURL = vaultURL.appendingPathComponent(relativePath)
            let folderURL = fileURL.deletingLastPathComponent()
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let text = ObsidianAdapter.render(note, pureObsidianLinks: pureObsidianLinks, keyByName: keyByName)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)

            // Record this note under its folder for index generation.
            let folder = (note.stableSourceKey as NSString).deletingLastPathComponent
            folderNotes[folder, default: []].append(note)
        }

        // Emit one index.md per folder that contains notes. The index lists
        // child notes as standard-md links (OKF progressive-disclosure nav).
        // Folders are processed in deterministic (sorted) order.
        for folder in folderNotes.keys.sorted() {
            let childNotes = folderNotes[folder]!.sorted { $0.stableSourceKey < $1.stableSourceKey }
            var indexContent = "# Index\n\n"
            for child in childNotes {
                let filename = (child.stableSourceKey as NSString).lastPathComponent
                // Link text is the filename; path is relative within the same folder.
                indexContent += "- [\(filename)](\(filename).md)\n"
            }
            let indexURL: URL
            if folder.isEmpty {
                indexURL = vaultURL.appendingPathComponent("index.md")
            } else {
                indexURL = vaultURL.appendingPathComponent(folder).appendingPathComponent("index.md")
            }
            try indexContent.write(to: indexURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Rendering

    /// Render one note to its on-disk Markdown text.
    ///
    /// In OKF mode (`pureObsidianLinks = false`):
    /// - A `type:` frontmatter key is injected, derived from `NoteIR.kind`.
    /// - A `tags: [a, b, c]` frontmatter key is injected when the note has tags.
    /// - Relationship links are rendered as standard markdown `[alias](relpath.md)`,
    ///   resolved relative to the note's own folder using `keyByName`.
    ///   If a target cannot be resolved, the fallback is `[target](slug.md)`.
    ///
    /// In pure-Obsidian mode (`pureObsidianLinks = true`):
    /// - Links are rendered as `[[Target]]` / `[[Target|Alias]]` (legacy behaviour).
    ///
    /// In both modes `type:` and frontmatter `tags:` are emitted so both OKF
    /// consumers and Obsidian can read them.
    ///
    /// A vault-origin note already carries its wikilink/tag markup in the body,
    /// so nothing is duplicated and the round-trip stays exact.
    static func render(_ note: NoteIR, pureObsidianLinks: Bool, keyByName: [String: String] = [:]) -> String {
        // Merge the note's own frontmatter with OKF-required injected keys.
        // Build the merged map here, then emit it sorted so the output is
        // deterministic regardless of insertion order.
        var fm = note.frontmatter

        // OKF required field: `type:`. Derived deterministically from NoteIR.kind.
        // Existing frontmatter `type:` is preserved when the producer already set it;
        // the OKF-derived value fills the gap when it is absent.
        if fm["type"] == nil {
            fm["type"] = ObsidianAdapter.okfType(from: note.kind)
        }

        // Frontmatter tags array — OKF idiom and harmless to Obsidian.
        // Emitted in addition to any inline #tag tokens in the body; both are
        // valid in Obsidian and OKF consumers read the frontmatter form.
        if !note.tags.isEmpty && fm["tags"] == nil {
            // OKF/Obsidian YAML list form: `[a, b, c]`.
            fm["tags"] = "[\(note.tags.joined(separator: ", "))]"
        }

        var out = ""
        if !fm.isEmpty {
            out += "---\n"
            // Sorted keys for deterministic output.
            for key in fm.keys.sorted() {
                out += "\(key): \(fm[key]!)\n"
            }
            out += "---\n"
        }

        var body = note.flattenedBody

        // Determine which links are missing from the body.
        // In pure-Obsidian mode we look for [[raw]] tokens.
        // In OKF mode we look for [alias](path.md) tokens — but since the body
        // was authored with wikilinks (for vault-origin notes), all links are in
        // the body already and missingLinks will be empty. For estate-origin notes
        // whose links live in the `links` array (not in the body), we emit the
        // correct form per mode.
        let missingLinks: [WikiLink]
        if pureObsidianLinks {
            // Wikilink mode: check for [[raw]] tokens in body.
            missingLinks = note.links.filter { !body.contains("[[\($0.raw)]]") }
        } else {
            // OKF mode: check for standard-md links in body. Estate-origin notes
            // have empty bodies or bodies without embedded links, so any link in
            // note.links that is NOT already present as a [text](path) pattern
            // needs to be appended. Vault-origin notes already carry their links
            // in the body verbatim (as wikilinks), so they pass through unchanged;
            // the existing wikilinks remain in the body and are parsed on re-read
            // by the unified parseAllLinks.
            //
            // Simple heuristic: if the body already contains a standard-md link
            // OR a wikilink for this target, treat it as present so we don't
            // double-emit.
            missingLinks = note.links.filter { link in
                let wikiPresent = body.contains("[[\(link.raw)]]")
                let mdTarget = resolveStandardMDLink(from: note.stableSourceKey, link: link, keyByName: keyByName)
                let mdPresent = body.contains(mdTarget)
                return !wikiPresent && !mdPresent
            }
        }

        if !missingLinks.isEmpty {
            out += body
            body = "" // consumed
            out += "\n\n"
            let renderedLinks = missingLinks.map { link in
                renderLink(link, pureObsidianLinks: pureObsidianLinks, sourceKey: note.stableSourceKey, keyByName: keyByName)
            }
            out += renderedLinks.joined(separator: " ")
            let missingTags = note.tags.filter { !out.contains("#\($0)") }
            if !missingTags.isEmpty {
                out += "\n\n" + missingTags.map { "#\($0)" }.joined(separator: " ")
            }
            return out
        }

        // No missing links to append; still append any tags missing from the body.
        out += body
        let missingTags = note.tags.filter { !body.contains("#\($0)") }
        if !missingTags.isEmpty {
            out += "\n\n" + missingTags.map { "#\($0)" }.joined(separator: " ")
        }
        return out
    }

    // MARK: - OKF helpers

    /// Derive the OKF `type:` value from a NoteIR kind string.
    ///
    /// Mapping: `"note"→"Note"`, `"fact"→"Fact"`, `"journal"→"Journal"`,
    /// else the kind with its first character uppercased. Deterministic and
    /// reversible: the kind string is preserved in the `kind` NoteIR field,
    /// not re-derived from `type:` on import.
    static func okfType(from kind: String) -> String {
        switch kind {
        case "note":    return "Note"
        case "fact":    return "Fact"
        case "journal": return "Journal"
        default:
            guard let first = kind.first else { return kind }
            return first.uppercased() + kind.dropFirst()
        }
    }

    /// Render a single WikiLink as either a wikilink or a standard-md link.
    private static func renderLink(
        _ link: WikiLink,
        pureObsidianLinks: Bool,
        sourceKey: String,
        keyByName: [String: String]
    ) -> String {
        if pureObsidianLinks {
            return "[[\(link.raw)]]"
        }
        // OKF mode: standard markdown link.
        let label = link.alias ?? link.target
        let path = resolveStandardMDLink(from: sourceKey, link: link, keyByName: keyByName)
        return "[\(label)](\(path))"
    }

    /// Compute the vault-relative path string for a standard-md link:
    /// `[alias](relpath.md)`.
    ///
    /// Strategy:
    /// 1. Look up the target name in the key map to find its `stableSourceKey`.
    /// 2. Compute the path from `sourceKey`'s folder to `targetKey + ".md"`.
    /// 3. If the target cannot be resolved, fall back to `slug(target).md` in
    ///    the same folder — never a dangling `[[ ]]`.
    static func resolveStandardMDLink(
        from sourceKey: String,
        link: WikiLink,
        keyByName: [String: String]
    ) -> String {
        let targetName = link.target
        let targetKey = keyByName[targetName] ?? slug(targetName)
        let targetPath = targetKey + ".md"

        // Compute relative path from source folder to target path.
        let sourceFolder = (sourceKey as NSString).deletingLastPathComponent
        return relativeMDPath(from: sourceFolder, to: targetPath)
    }

    /// Compute the relative path from a source folder to a target vault path.
    ///
    /// Both paths use forward slashes and are vault-relative.
    /// When sourceFolder is empty (root-level note), the relative path equals
    /// the target path. Otherwise we compute a `../`-prefixed relative path
    /// climbing from source to a common ancestor, then descending to target.
    static func relativeMDPath(from sourceFolder: String, to targetPath: String) -> String {
        if sourceFolder.isEmpty {
            // Source is at vault root — target path IS the relative path.
            return targetPath
        }

        let sourceParts = sourceFolder.split(separator: "/").map(String.init)
        let targetParts = targetPath.split(separator: "/").map(String.init)

        // Find common prefix depth.
        var commonDepth = 0
        while commonDepth < sourceParts.count && commonDepth < targetParts.count
              && sourceParts[commonDepth] == targetParts[commonDepth] {
            commonDepth += 1
        }

        // Climb from source to the common ancestor.
        let upCount = sourceParts.count - commonDepth
        let downParts = Array(targetParts[commonDepth...])

        var components: [String] = Array(repeating: "..", count: upCount)
        components.append(contentsOf: downParts)
        return components.joined(separator: "/")
    }

    /// A minimal slug for unresolved link targets.
    private static func slug(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    // MARK: - Parsing helpers

    /// Split a raw file into (frontmatter map, body). When the file opens
    /// with a `---` fence, everything up to the next `---` line is parsed
    /// as flat `key: value` YAML; the body is everything after. With no
    /// opening fence the whole file is the body and the map is empty.
    static func splitFrontmatter(_ raw: String) -> ([String: String], String) {
        // Normalise only for fence detection; the body is sliced from the
        // original so content bytes are preserved verbatim.
        guard raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") else {
            return ([:], raw)
        }
        let lines = raw.components(separatedBy: "\n")
        // lines[0] is the opening "---". Find the closing fence.
        var closingIndex: Int? = nil
        for i in 1..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if trimmed == "---" {
                closingIndex = i
                break
            }
        }
        guard let close = closingIndex else {
            // Unterminated fence — treat the whole file as body.
            return ([:], raw)
        }

        var map: [String: String] = [:]
        for i in 1..<close {
            let line = lines[i].trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            map[key] = value
        }

        let bodyLines = lines[(close + 1)...]
        return (map, bodyLines.joined(separator: "\n"))
    }

    /// Parse BOTH wikilinks `[[Target]]` / `[[Target|Alias]]` AND standard
    /// markdown links `[text](path.md)` from a body, returning a unified
    /// `[WikiLink]` with duplicates removed.
    ///
    /// Standard-md links use: `target = path basename without .md`,
    /// `alias = link text`, `raw = preserved inner text` so emission
    /// can reconstruct them. This lets vaults written in OKF mode
    /// (standard-md links) and vaults written in pure-Obsidian mode
    /// (wikilinks) both round-trip through the same `links` field.
    static func parseAllLinks(in body: String) -> [WikiLink] {
        var links: [WikiLink] = []
        var seenRaw: Set<String> = []

        // 1. Parse wikilinks.
        for link in parseWikiLinks(in: body) {
            if seenRaw.insert(link.raw).inserted {
                links.append(link)
            }
        }

        // 2. Parse standard-md links `[text](url)`.
        for link in parseStandardMDLinks(in: body) {
            if seenRaw.insert(link.raw).inserted {
                links.append(link)
            }
        }

        return links
    }

    /// Extract wikilinks `[[Target]]` / `[[Target|Alias]]` from a body.
    static func parseWikiLinks(in body: String) -> [WikiLink] {
        // `[[` then any chars that are not `]`, then `]]`. Non-greedy on
        // the inner run via the negated class.
        let pattern = "\\[\\[([^\\]]+)\\]\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var links: [WikiLink] = []
        for match in matches where match.numberOfRanges >= 2 {
            let inner = ns.substring(with: match.range(at: 1))
            if let pipe = inner.firstIndex(of: "|") {
                let target = String(inner[inner.startIndex..<pipe])
                let alias = String(inner[inner.index(after: pipe)...])
                links.append(WikiLink(target: target, alias: alias, raw: inner))
            } else {
                links.append(WikiLink(target: inner, alias: nil, raw: inner))
            }
        }
        return links
    }

    /// Extract standard markdown links `[text](path.md)` from a body.
    ///
    /// Only matches local `.md` links (not `http://…` or `#anchor`-only links)
    /// so that external hyperlinks don't pollute the `links` list. Each parsed
    /// link has:
    /// - `target`: the basename of the path without `.md` (e.g. `"Alpha"`)
    /// - `alias`: the link text (e.g. `"My Note"`)
    /// - `raw`: preserved verbatim as `"alias||path"` so round-trip emission
    ///   can reconstruct the correct standard-md form.
    static func parseStandardMDLinks(in body: String) -> [WikiLink] {
        // Pattern: [text](anything.md) where the path does not start with http
        // or a `#` anchor-only reference.
        let pattern = "\\[([^\\]]+)\\]\\(([^)]+\\.md)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var links: [WikiLink] = []
        for match in matches where match.numberOfRanges >= 3 {
            let text = ns.substring(with: match.range(at: 1))
            let path = ns.substring(with: match.range(at: 2))
            // Skip external links.
            if path.hasPrefix("http://") || path.hasPrefix("https://") { continue }
            // Target = basename without .md.
            let basename = (path as NSString).lastPathComponent
            let target = basename.hasSuffix(".md")
                ? String(basename.dropLast(3))
                : basename
            // Raw preserves enough info to reconstruct the link: "text||path"
            // so we can distinguish alias from path on re-emission.
            let raw = "\(text)||\(path)"
            links.append(WikiLink(target: target, alias: text, raw: raw))
        }
        return links
    }

    /// Extract inline `#tag` tokens from a body, excluding the `# heading`
    /// form (a `#` followed by whitespace). A tag starts with a letter
    /// and continues with word characters, `-`, `_`, or `/`. The `#` must
    /// not be preceded by a word character (so `C#` is not a tag).
    static func parseTags(in body: String) -> [String] {
        let pattern = "(?<![\\w])#([A-Za-z][\\w/-]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var tags: [String] = []
        var seen: Set<String> = []
        for match in matches where match.numberOfRanges >= 2 {
            let tag = ns.substring(with: match.range(at: 1))
            // Preserve first-seen order, drop duplicates.
            if seen.insert(tag).inserted {
                tags.append(tag)
            }
        }
        return tags
    }

    // MARK: - Path helpers

    /// Forward-slash vault-relative path of `fileURL` under `root`.
    static func relativePath(of fileURL: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        // Drop the shared prefix.
        var i = 0
        while i < rootComponents.count, i < fileComponents.count,
              rootComponents[i] == fileComponents[i] {
            i += 1
        }
        return fileComponents[i...].joined(separator: "/")
    }

    /// Drop a trailing `.md` extension from a vault-relative path.
    static func dropMarkdownExtension(_ path: String) -> String {
        path.hasSuffix(".md") ? String(path.dropLast(3)) : path
    }
}
