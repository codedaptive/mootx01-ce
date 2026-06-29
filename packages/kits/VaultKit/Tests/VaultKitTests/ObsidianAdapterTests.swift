import Testing
import Foundation
@testable import VaultKit

/// Round-trip and parsing tests for the Obsidian adapter against a real
/// on-disk fixture vault. All filesystem writes are confined to a unique
/// temp directory that is removed in the test body.
@Suite("ObsidianAdapter")
struct ObsidianAdapterTests {

    /// Create a unique temp directory; caller removes it.
    private func makeTempVault() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultkit-obsidian-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("parses frontmatter, wikilinks, tags, and nested folder path")
    func parsesFixture() throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        try write(
            """
            ---
            wing: wing_owner
            room: research
            created: 2024-03-04T05:06:07.000Z
            ---
            A note about [[Organic Chemistry]] and [[Q11173|benzene]].
            Filed under #chemistry and #reference.
            """,
            to: vault.appendingPathComponent("Area/Sub/Carbon.md")
        )

        let adapter = ObsidianAdapter()
        let notes = try adapter.toIR(vaultURL: vault)

        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(note.stableSourceKey == "Area/Sub/Carbon")
        #expect(note.originalPath == "Area/Sub")
        #expect(note.frontmatter["wing"] == "wing_owner")
        #expect(note.frontmatter["room"] == "research")
        #expect(note.originDate?.iso8601 == "2024-03-04T05:06:07.000Z")
        // Two wikilinks, one aliased — parsed by the unified parseAllLinks.
        #expect(note.links.count == 2)
        #expect(note.links.contains(WikiLink(target: "Organic Chemistry", alias: nil, raw: "Organic Chemistry")))
        #expect(note.links.contains(WikiLink(target: "Q11173", alias: "benzene", raw: "Q11173|benzene")))
        // Two tags; the `# heading` form is not a tag.
        #expect(note.tags == ["chemistry", "reference"])
    }

    // MARK: - Vault containment (path-traversal hardening)

    /// Corpus of wing/room values that must fail closed before any directory
    /// is created under the selected vault root.
    @Test("fromIR rejects stableSourceKey path traversal — full corpus")
    func fromIRRejectsPathTraversalCorpus() {
        // Each of these keys would escape the vault root if written naively
        // via appendingPathComponent. The containment gate must fail closed
        // before createDirectory is called, and no file must appear outside
        // the vault root.
        let maliciousKeys = [
            "../escape",                    // single parent traversal
            "notes/../../../escape",        // nested traversal
            "/absolute/escape",             // absolute path
            "~/tilde/escape",               // tilde expansion
            "folder\\backslash",            // Windows separator
            "a//double-slash",              // double slash (empty component)
        ]
        for key in maliciousKeys {
            let vault = makeTempVault()
            defer { try? FileManager.default.removeItem(at: vault) }
            #expect(throws: VaultKitError.self, "key '\(key)' must be rejected by containment gate") {
                try ObsidianAdapter().fromIR(
                    [NoteIR(stableSourceKey: key, body: [Block(kind: "markdown", text: "body")])],
                    to: vault)
            }
        }
    }

    // MARK: - Symlink boundary hardening (PR #42)

    @Test("toIR skips symlinked markdown files — following them could read outside the vault")
    func toIRSkipsSymlinkedMarkdownFiles() throws {
        // Place a legitimate note and a symlink inside the vault. The symlink
        // points outside the vault root to a file the importer must never read.
        let base = makeTempVault()
        let vault = base.appendingPathComponent("vault", isDirectory: true)
        let outside = base.appendingPathComponent("outside-secret.md")
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "EXFILTRATED_SECRET".write(to: outside, atomically: true, encoding: .utf8)
        // Pre-plant a symlink inside the vault pointing to the file outside.
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("secret.md"),
            withDestinationURL: outside)
        try write("safe", to: vault.appendingPathComponent("safe.md"))

        let notes = try ObsidianAdapter().toIR(vaultURL: vault)

        // Only the legitimate note must appear; the symlinked file must be skipped.
        #expect(notes.count == 1)
        #expect(notes.first?.stableSourceKey == "safe")
        #expect(notes.first?.flattenedBody == "safe")
    }

    @Test("fromIR rejects a pre-existing symlinked output file and does not follow it")
    func fromIRRejectsSymlinkedOutputFile() throws {
        // Attacker scenario: a symlink is pre-planted at the exact export path
        // (vault/note.md → /tmp/outside.md). The adapter must refuse the write
        // rather than following the link and modifying the target outside the vault.
        let base = makeTempVault()
        let vault = base.appendingPathComponent("vault", isDirectory: true)
        let outside = base.appendingPathComponent("outside.md")
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "original-outside-content".write(to: outside, atomically: true, encoding: .utf8)
        // Pre-plant the symlink at the export target path.
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("note.md"),
            withDestinationURL: outside)

        #expect(throws: VaultKitError.self, "fromIR must reject a pre-existing symlinked export path") {
            try ObsidianAdapter().fromIR(
                [NoteIR(stableSourceKey: "note",
                        body: [Block(kind: "markdown", text: "changed")])],
                to: vault)
        }
        // The file outside the vault must be untouched.
        #expect(try String(contentsOf: outside, encoding: .utf8) == "original-outside-content")
    }

    @Test("fromIR accepts legitimate non-symlink export and writes correctly")
    func fromIRAcceptsLegitimateExport() throws {
        // Baseline: a normal export to a clean vault directory must succeed.
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        try ObsidianAdapter().fromIR(
            [NoteIR(stableSourceKey: "Wing/Room/note",
                    body: [Block(kind: "markdown", text: "hello")])],
            to: vault)

        let expected = vault.appendingPathComponent("Wing/Room/note.md")
        #expect(FileManager.default.fileExists(atPath: expected.path),
                "legitimate export must create the note file inside the vault")
        let content = try String(contentsOf: expected, encoding: .utf8)
        #expect(content.contains("hello"), "exported note must contain the body text")
    }

    @Test("fromIR accepts legitimate nested paths and writes them correctly")
    func fromIRAcceptsLegitimateNestedPaths() throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let notes = [
            NoteIR(stableSourceKey: "Wing/Room/my-note",
                   body: [Block(kind: "markdown", text: "# Note")]),
            NoteIR(stableSourceKey: "root-note",
                   body: [Block(kind: "markdown", text: "# Root")]),
        ]
        // Must not throw; the containment gate must not block safe paths.
        try ObsidianAdapter().fromIR(notes, to: vault)
        #expect(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Wing/Room/my-note.md").path),
                "nested note must be written inside the vault")
        #expect(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("root-note.md").path),
                "root-level note must be written inside the vault")
        // Index files should also be present.
        #expect(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Wing/Room/index.md").path),
                "index for nested folder must be written inside the vault")
    }

    @Test("containedVaultURL rejects traversal paths before filesystem access")
    func containedVaultURLRejectsTraversal() {
        let root = URL(fileURLWithPath: "/tmp/vault-root", isDirectory: true)
        let traversalPaths = [
            "../escape.md",
            "notes/../../etc/passwd",
            "/absolute/path.md",
            "~/home/escape.md",
            "folder\\evil.md",
        ]
        for path in traversalPaths {
            #expect(throws: VaultKitError.self, "'\(path)' must be rejected") {
                try ObsidianAdapter.containedVaultURL(forRelativePath: path, under: root)
            }
        }
    }

    @Test("containedVaultURL accepts legitimate relative paths")
    func containedVaultURLAcceptsLegitimateRelativePaths() throws {
        let root = URL(fileURLWithPath: "/tmp/vault-root", isDirectory: true)
        let safePaths = [
            "Wing/Room/note.md",
            "note-at-root.md",
            "A/B/C/deep-note.md",
            "index.md",
        ]
        for path in safePaths {
            let url = try ObsidianAdapter.containedVaultURL(forRelativePath: path, under: root)
            #expect(url.path.hasPrefix("/tmp/vault-root/"), "'\(path)' must produce URL inside vault root")
        }
    }

    // MARK: - OKF default-mode (pureObsidianLinks = false)

    @Test("OKF default: emitted note carries type: frontmatter key derived from kind")
    func okfDefaultEmitsTypeKey() throws {
        let source = makeTempVault()
        let dest = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }

        try write(
            """
            ---
            room: research
            ---
            Body text.
            """,
            to: source.appendingPathComponent("Note.md")
        )

        let adapter = ObsidianAdapter() // default mode
        let notes = try adapter.toIR(vaultURL: source)
        try adapter.fromIR(notes, to: dest)

        // Read back the emitted file.
        let emitted = try String(contentsOf: dest.appendingPathComponent("Note.md"), encoding: .utf8)
        #expect(emitted.contains("type: Note"), "OKF type: key must be present")
    }

    @Test("OKF default: emitted note carries frontmatter tags: array when tags present")
    func okfDefaultEmitsFrontmatterTags() throws {
        let vault = makeTempVault()
        let dest = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: vault)
            try? FileManager.default.removeItem(at: dest)
        }

        try write(
            """
            ---
            room: notes
            ---
            A tagged note. #swift #testing
            """,
            to: vault.appendingPathComponent("Tagged.md")
        )

        let adapter = ObsidianAdapter()
        let notes = try adapter.toIR(vaultURL: vault)
        try adapter.fromIR(notes, to: dest)

        let emitted = try String(contentsOf: dest.appendingPathComponent("Tagged.md"), encoding: .utf8)
        #expect(emitted.contains("tags:"), "frontmatter tags: key must be emitted")
        #expect(emitted.contains("swift"), "swift tag must appear in frontmatter tags")
        #expect(emitted.contains("testing"), "testing tag must appear in frontmatter tags")
    }

    @Test("OKF default: every emitted note file carries a type: frontmatter key (OKF validity)")
    func okfValidityEveryNoteHasTypeKey() throws {
        let source = makeTempVault()
        let dest = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }

        try write("---\nroom: a\n---\nAlpha body.", to: source.appendingPathComponent("Alpha.md"))
        try write("---\nroom: b\n---\nBeta body.", to: source.appendingPathComponent("Folder/Beta.md"))

        let adapter = ObsidianAdapter()
        let notes = try adapter.toIR(vaultURL: source)
        try adapter.fromIR(notes, to: dest)

        // Every .md file that is NOT an index must carry type:.
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dest, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            Issue.record("could not enumerate dest vault"); return
        }
        var checkedCount = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
            let name = fileURL.deletingPathExtension().lastPathComponent
            if name == "index" || name == "log" { continue } // OKF nav files
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(content.contains("type:"), "every note file must carry type: (OKF required field) — failed for \(fileURL.lastPathComponent)")
            checkedCount += 1
        }
        #expect(checkedCount == 2, "expected exactly 2 non-index note files")
    }

    @Test("OKF default: relationship links are emitted as standard-md [alias](path.md)")
    func okfDefaultEmitsStandardMDLinks() throws {
        // Use the render helper directly: create a NoteIR with links and verify output.
        let alpha = NoteIR(
            stableSourceKey: "Folder/Alpha",
            body: [Block(text: "Body text.")],
            links: [WikiLink(target: "Beta", alias: nil, raw: "Beta")]
        )
        let keyByName = ["Beta": "Folder/Beta"]
        let output = ObsidianAdapter.render(alpha, pureObsidianLinks: false, keyByName: keyByName)
        #expect(output.contains("[Beta](Beta.md)"), "OKF mode must emit standard-md link, got: \(output)")
        #expect(!output.contains("[[Beta]]"), "OKF mode must NOT emit wikilink")
    }

    @Test("pureObsidianLinks=true: relationship links are emitted as [[wikilinks]]")
    func pureObsidianLinksEmitsWikilinks() throws {
        let alpha = NoteIR(
            stableSourceKey: "Folder/Alpha",
            body: [Block(text: "Body text.")],
            links: [WikiLink(target: "Beta", alias: "see beta", raw: "Beta|see beta")]
        )
        let output = ObsidianAdapter.render(alpha, pureObsidianLinks: true)
        #expect(output.contains("[[Beta|see beta]]"), "pure-Obsidian mode must emit wikilink, got: \(output)")
        #expect(!output.contains("[see beta]("), "pure-Obsidian mode must NOT emit standard-md link")
    }

    @Test("pureObsidianLinks=true still emits type: and frontmatter tags:")
    func pureObsidianLinksStillEmitsOKFMeta() throws {
        let note = NoteIR(
            stableSourceKey: "MyNote",
            body: [Block(text: "Body.")],
            tags: ["alpha"]
        )
        let output = ObsidianAdapter.render(note, pureObsidianLinks: true)
        #expect(output.contains("type: Note"), "pureObsidianLinks=true must still emit type:")
        #expect(output.contains("tags:"), "pureObsidianLinks=true must still emit frontmatter tags:")
    }

    // MARK: - index.md skip rule

    @Test("importer skips index.md files — they are OKF nav, not notes")
    func importerSkipsIndexMd() throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // Write a real note and an index.md alongside it.
        try write(
            "---\nroom: r\n---\nReal note body.",
            to: vault.appendingPathComponent("Folder/RealNote.md")
        )
        try write(
            "# Index\n\n- [RealNote](RealNote.md)\n",
            to: vault.appendingPathComponent("Folder/index.md")
        )

        let adapter = ObsidianAdapter()
        let notes = try adapter.toIR(vaultURL: vault)
        #expect(notes.count == 1, "index.md must be skipped; only RealNote should import")
        #expect(notes.first?.stableSourceKey == "Folder/RealNote")
    }

    @Test("importer skips log.md files")
    func importerSkipsLogMd() throws {
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        try write("Real body.", to: vault.appendingPathComponent("Real.md"))
        try write("# Log\n\nSome log entry.", to: vault.appendingPathComponent("log.md"))

        let adapter = ObsidianAdapter()
        let notes = try adapter.toIR(vaultURL: vault)
        #expect(notes.count == 1, "log.md must be skipped")
        #expect(notes.first?.stableSourceKey == "Real")
    }

    @Test("fromIR emits index.md per folder containing notes")
    func fromIREmitsIndexMdPerFolder() throws {
        let source = makeTempVault()
        let dest = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }

        try write("---\nroom: a\n---\nNote A.", to: source.appendingPathComponent("Folder/NoteA.md"))
        try write("---\nroom: b\n---\nNote B.", to: source.appendingPathComponent("Folder/NoteB.md"))
        try write("---\nroom: r\n---\nRoot note.", to: source.appendingPathComponent("Root.md"))

        let adapter = ObsidianAdapter()
        let notes = try adapter.toIR(vaultURL: source)
        try adapter.fromIR(notes, to: dest)

        // index.md at root level.
        let rootIndex = dest.appendingPathComponent("index.md")
        #expect(FileManager.default.fileExists(atPath: rootIndex.path), "root index.md must exist")

        // index.md at Folder/ level.
        let folderIndex = dest.appendingPathComponent("Folder/index.md")
        #expect(FileManager.default.fileExists(atPath: folderIndex.path), "Folder/index.md must exist")

        // Folder index must list NoteA and NoteB as standard-md links.
        let folderIndexContent = try String(contentsOf: folderIndex, encoding: .utf8)
        #expect(folderIndexContent.contains("[NoteA](NoteA.md)"), "folder index must link NoteA")
        #expect(folderIndexContent.contains("[NoteB](NoteB.md)"), "folder index must link NoteB")
    }

    // MARK: - Round-trip tests

    @Test("toIR(fromIR(x)) == x for Obsidian-representable fields (default OKF mode)")
    func roundTripIsStableDefaultMode() throws {
        let source = makeTempVault()
        let dest = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }

        // Note body contains an explicit [[Link]] wikilink and a #topic tag —
        // both are parsed into NoteIR.links and NoteIR.tags by toIR.
        try write(
            """
            ---
            room: inbox
            udc: 004
            ---
            Body with a [[Link]] and a #topic tag.
            Second line.
            """,
            to: source.appendingPathComponent("Folder/Alpha.md")
        )
        try write(
            """
            ---
            room: archive
            ---
            Plain note, no links.
            """,
            to: source.appendingPathComponent("Beta.md")
        )

        let adapter = ObsidianAdapter()
        let first = try adapter.toIR(vaultURL: source)
        try adapter.fromIR(first, to: dest)
        let second = try adapter.toIR(vaultURL: dest)

        // Core fields must survive the round-trip.
        #expect(first.count == second.count)
        for (a, b) in zip(first.sorted { $0.stableSourceKey < $1.stableSourceKey },
                          second.sorted { $0.stableSourceKey < $1.stableSourceKey }) {
            #expect(a.stableSourceKey == b.stableSourceKey)
            #expect(a.originalPath == b.originalPath)
            #expect(a.tags == b.tags)
            // Links: target names must survive even if raw encoding changes
            // (wikilink → standard-md → back).
            let aTargets = Set(a.links.map(\.target))
            let bTargets = Set(b.links.map(\.target))
            #expect(aTargets == bTargets, "link targets must survive OKF round-trip")
        }
    }

    @Test("toIR(fromIR(x)) == x for Obsidian-representable fields (pureObsidianLinks=true)")
    func roundTripIsStablePureObsidianMode() throws {
        let source = makeTempVault()
        let dest = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }

        try write(
            """
            ---
            room: inbox
            udc: 004
            ---
            Body with a [[Link]] and a #topic tag.
            Second line.
            """,
            to: source.appendingPathComponent("Folder/Alpha.md")
        )
        try write(
            """
            ---
            room: archive
            ---
            Plain note, no links.
            """,
            to: source.appendingPathComponent("Beta.md")
        )

        let adapter = ObsidianAdapter(pureObsidianLinks: true)
        let first = try adapter.toIR(vaultURL: source)
        try adapter.fromIR(first, to: dest)
        let second = try adapter.toIR(vaultURL: dest)

        // Partial round-trip check: compares count, stable key, body, links, and
        // tags. Full value equality is not asserted — frontmatter fields (type:,
        // tags:) injected on write are excluded.
        #expect(first.count == second.count)
        for (a, b) in zip(first.sorted { $0.stableSourceKey < $1.stableSourceKey },
                          second.sorted { $0.stableSourceKey < $1.stableSourceKey }) {
            #expect(a.stableSourceKey == b.stableSourceKey)
            #expect(a.body == b.body)
            #expect(a.links == b.links)
            #expect(a.tags == b.tags)
        }
    }

    // MARK: - okfType mapping

    @Test("okfType: known kinds map to capitalized names")
    func okfTypeMapping() {
        #expect(ObsidianAdapter.okfType(from: "note") == "Note")
        #expect(ObsidianAdapter.okfType(from: "fact") == "Fact")
        #expect(ObsidianAdapter.okfType(from: "journal") == "Journal")
    }

    @Test("okfType: unknown kind is capitalized")
    func okfTypeUnknownKind() {
        #expect(ObsidianAdapter.okfType(from: "flashcard") == "Flashcard")
        #expect(ObsidianAdapter.okfType(from: "task") == "Task")
    }

    // MARK: - Standard-md link parsing

    @Test("parseStandardMDLinks: extracts [text](path.md) links")
    func parseStandardMDLinksBasic() {
        let body = "See [Alpha](notes/Alpha.md) and [Organic Chemistry](chem/Organic-Chemistry.md)."
        let links = ObsidianAdapter.parseStandardMDLinks(in: body)
        #expect(links.count == 2)
        #expect(links.contains { $0.target == "Alpha" && $0.alias == "Alpha" })
        #expect(links.contains { $0.target == "Organic-Chemistry" && $0.alias == "Organic Chemistry" })
    }

    @Test("parseStandardMDLinks: does not parse external http links")
    func parseStandardMDLinksSkipsExternal() {
        let body = "See [example](https://example.com/page.md) for details."
        let links = ObsidianAdapter.parseStandardMDLinks(in: body)
        #expect(links.isEmpty, "external http links must not be parsed as local note links")
    }

    @Test("parseAllLinks: unifies wikilinks and standard-md links, deduplicates")
    func parseAllLinksUnifies() {
        let body = "[[Alpha]] and [Beta](Beta.md) and [[Alpha]]"
        let links = ObsidianAdapter.parseAllLinks(in: body)
        let targets = links.map(\.target)
        #expect(targets.contains("Alpha"))
        #expect(targets.contains("Beta"))
        #expect(targets.filter { $0 == "Alpha" }.count == 1, "duplicates must be removed")
    }

    // MARK: - relativeMDPath helper

    @Test("relativeMDPath: root-level source → target path as-is")
    func relativeMDPathFromRoot() {
        let result = ObsidianAdapter.relativeMDPath(from: "", to: "notes/Alpha.md")
        #expect(result == "notes/Alpha.md")
    }

    @Test("relativeMDPath: same folder → filename only")
    func relativeMDPathSameFolder() {
        let result = ObsidianAdapter.relativeMDPath(from: "Folder", to: "Folder/Beta.md")
        #expect(result == "Beta.md")
    }

    @Test("relativeMDPath: cross-folder → relative climb")
    func relativeMDPathCrossFolder() {
        let result = ObsidianAdapter.relativeMDPath(from: "A/B", to: "C/D.md")
        #expect(result == "../../C/D.md")
    }

    // MARK: - Tag parsing

    @Test("# heading is not parsed as a tag")
    func headingIsNotTag() {
        let tags = ObsidianAdapter.parseTags(in: "# Heading\nText #realtag here")
        #expect(tags == ["realtag"])
    }
}
