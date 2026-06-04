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
        // Two wikilinks, one aliased.
        #expect(note.links.count == 2)
        #expect(note.links.contains(WikiLink(target: "Organic Chemistry", alias: nil, raw: "Organic Chemistry")))
        #expect(note.links.contains(WikiLink(target: "Q11173", alias: "benzene", raw: "Q11173|benzene")))
        // Two tags; the `# heading` form is not a tag.
        #expect(note.tags == ["chemistry", "reference"])
    }

    @Test("toIR(fromIR(x)) == x for Obsidian-representable fields")
    func roundTripIsStable() throws {
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

        let adapter = ObsidianAdapter()
        let first = try adapter.toIR(vaultURL: source)
        try adapter.fromIR(first, to: dest)
        let second = try adapter.toIR(vaultURL: dest)

        #expect(first == second)
    }

    @Test("# heading is not parsed as a tag")
    func headingIsNotTag() {
        let tags = ObsidianAdapter.parseTags(in: "# Heading\nText #realtag here")
        #expect(tags == ["realtag"])
    }
}
