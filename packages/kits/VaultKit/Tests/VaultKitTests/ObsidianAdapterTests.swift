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

        // Notes without explicit links in body — links live in NoteIR.links only.
        // In OKF mode, links are emitted as standard-md then re-parsed on read.
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

        // Full equality check — wikilink mode is byte-stable.
        // Exclude frontmatter difference: OKF keys (type:, tags:) are injected on
        // write and survive round-trip in the frontmatter map.
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
