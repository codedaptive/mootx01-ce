import Foundation

/// The first `VaultAdapter`: Obsidian-flavoured Markdown ⇄ `NoteIR`.
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
/// Round-trip contract: `toIR(fromIR(x)) == x` for the fields Obsidian
/// represents. The body string retains its wikilink and tag markup, so
/// links and tags are *views* over the body, not edits to it — emission
/// writes the body verbatim and re-parsing recovers the same views.
public struct ObsidianAdapter: VaultAdapter {

    public init() {}

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
            let raw = try String(contentsOf: fileURL, encoding: .utf8)
            // Vault-relative path with forward slashes, e.g. "Area/Note.md".
            let relativePath = ObsidianAdapter.relativePath(of: fileURL, under: vaultURL)
            let stableKey = ObsidianAdapter.dropMarkdownExtension(relativePath)
            // Folder portion only (the note's directory inside the vault).
            let folder = (relativePath as NSString).deletingLastPathComponent

            let (frontmatter, body) = ObsidianAdapter.splitFrontmatter(raw)
            let links = ObsidianAdapter.parseWikiLinks(in: body)
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

        for note in notes {
            // The note is written at `<stableSourceKey>.md`, so the folder
            // tree mirrors the wing/room path that `DrawerMapping` encoded
            // into the key on export. Re-reading recovers the same
            // `stableSourceKey` and `originalPath` — this is what makes the
            // round-trip path-faithful without a second source of truth.
            let relativePath = note.stableSourceKey + ".md"
            let fileURL = vaultURL.appendingPathComponent(relativePath)
            try fm.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let text = ObsidianAdapter.render(note)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Rendering

    /// Render one note to its on-disk Markdown text: frontmatter block
    /// (when present) followed by the body, with any links or tags that
    /// are not already embedded in the body appended so an
    /// estate-origin note (whose links live in tunnels, not body text)
    /// emits real wikilinks. A vault-origin note already carries its
    /// markup in the body, so nothing is duplicated and the round-trip
    /// stays exact.
    static func render(_ note: NoteIR) -> String {
        var out = ""
        if !note.frontmatter.isEmpty {
            out += "---\n"
            // Sorted keys for deterministic output.
            for key in note.frontmatter.keys.sorted() {
                out += "\(key): \(note.frontmatter[key]!)\n"
            }
            out += "---\n"
        }

        var body = note.flattenedBody
        let missingLinks = note.links.filter { !body.contains("[[\($0.raw)]]") }
        if !missingLinks.isEmpty {
            out += body
            body = "" // consumed
            out += "\n\n" + missingLinks.map { "[[\($0.raw)]]" }.joined(separator: " ")
            let missingTags = note.tags.filter { !out.contains("#\($0)") }
            if !missingTags.isEmpty {
                out += "\n\n" + missingTags.map { "#\($0)" }.joined(separator: " ")
            }
            return out
        }

        // No links to append; still append any tags missing from the body.
        out += body
        let missingTags = note.tags.filter { !body.contains("#\($0)") }
        if !missingTags.isEmpty {
            out += "\n\n" + missingTags.map { "#\($0)" }.joined(separator: " ")
        }
        return out
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
