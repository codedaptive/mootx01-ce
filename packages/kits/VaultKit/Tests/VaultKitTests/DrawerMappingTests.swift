import Testing
import Foundation
import LocusKit
@testable import VaultKit

/// Pure (substrate-free) tests for the `NoteIR` ⇄ frame/drawer mapping.
@Suite("DrawerMapping (pure)")
struct DrawerMappingTests {

    @Test("lineageID is deterministic and distinct per key")
    func lineageIDDeterminism() {
        let a1 = DrawerMapping.lineageID(forStableSourceKey: "Area/Note")
        let a2 = DrawerMapping.lineageID(forStableSourceKey: "Area/Note")
        let b = DrawerMapping.lineageID(forStableSourceKey: "Area/Other")
        #expect(a1 == a2)          // same key → same lineage (idempotency)
        #expect(a1 != b)           // distinct keys → distinct lineage
    }

    @Test("import frame uses .importedFile channel and the 000 fallback UDC")
    func importFrameFallbackUDC() {
        // classifyOnImport off → no FDC lookup → deterministic 000 fallback.
        let mapping = DrawerMapping(classifyOnImport: false)
        let note = NoteIR(
            stableSourceKey: "Inbox/Thought",
            body: [Block(text: "a thought worth keeping")],
            frontmatter: ["room": "inbox"],
            links: [WikiLink(target: "Other", alias: nil, raw: "Other")]
        )
        let (frame, classified) = mapping.makeCaptureFrame(for: note, content: note.flattenedBody)

        #expect(frame.channel == .importedFile)
        #expect(frame.latticeAnchor.udcCode == "000")
        #expect(classified == false)
        #expect(frame.room == "inbox")
        #expect(!frame.addedBy.isEmpty)             // I-5 guard inputs
        #expect(!frame.embeddingModelID.isEmpty)
        #expect(frame.sourceType == .imported)
        #expect(frame.provenanceChannel == .fileImport)
        // hasLinks set because the note carries a wikilink.
        #expect(frame.featureFlags.contains(.hasLinks))
    }

    @Test("explicit frontmatter udc counts as classified")
    func explicitUDCClassified() {
        let mapping = DrawerMapping(classifyOnImport: false)
        let note = NoteIR(
            stableSourceKey: "k",
            body: [Block(text: "x")],
            frontmatter: ["room": "r", "udc": "547"]
        )
        let (frame, classified) = mapping.makeCaptureFrame(for: note, content: "x")
        #expect(frame.latticeAnchor.udcCode == "547")
        #expect(classified == true)
    }

    @Test("room defaults to non-empty when frontmatter and path are absent")
    func roomNeverEmpty() {
        let mapping = DrawerMapping(classifyOnImport: false)
        let note = NoteIR(stableSourceKey: "k", body: [Block(text: "x")])
        let (frame, _) = mapping.makeCaptureFrame(for: note, content: "x")
        #expect(!frame.room.isEmpty)
    }

    @Test("export projects a drawer + references tunnel to a NoteIR")
    func exportProjection() {
        let knownLineage = UUID(uuidString: "12345678-0000-0000-0000-000000000001")!
        let drawer = Drawer(
            id: "drawer-1",
            content: "# Aromatics\nA study of arene rings.",
            wing: "wing_owner",
            room: "research",
            addedBy: "tester",
            filedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embeddingModelID: "m",
            lineageID: knownLineage,
            udcCode: "004"
        )
        let tunnel = Tunnel(
            id: "t-1",
            sourceWing: "wing_owner",
            sourceRoom: "research",
            sourceDrawerId: "drawer-1",
            targetWing: "wing_owner",
            targetRoom: "Benzene",
            label: "Benzene",
            kind: .references,
            addedBy: "tester",
            filedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let note = DrawerMapping.noteIR(from: drawer, references: [tunnel])
        // Path: <wing>/<room>/<slug>.md — ADR-016 vault layout; wing is the
        // top-level vault folder. Slug derived from first heading.
        #expect(note.stableSourceKey == "wing_owner/research/aromatics")
        #expect(note.flattenedBody.contains("A study of arene rings."))
        #expect(note.frontmatter["udc"] == "004")
        #expect(note.frontmatter["wing"] == "wing_owner")
        #expect(note.frontmatter["room"] == "research")
        // moot_id is the STABLE lineage UUID, not drawer.id.
        #expect(note.frontmatter["moot_id"] == knownLineage.uuidString)
        #expect(note.mootID == knownLineage)
        // originalPath is the substrate room (not the vault path).
        #expect(note.originalPath == "research")
        #expect(note.links == [WikiLink(target: "Benzene", alias: nil, raw: "Benzene")])
    }

    @Test("slug derived from first heading, else first line, else UUID fallback")
    func slugDerivation() {
        let id = UUID()
        // Heading case.
        #expect(DrawerMapping.slug(from: "# My Note Title\nbody", id: id) == "my-note-title")
        // First-line case (no heading).
        #expect(DrawerMapping.slug(from: "Hello World!", id: id) == "hello-world")
        // Punctuation collapse.
        #expect(DrawerMapping.slug(from: "A note: with 'special' chars!", id: id) == "a-note-with-special-chars")
        // Empty content → UUID prefix.
        let fallback = DrawerMapping.slug(from: "   ", id: id)
        #expect(fallback.hasPrefix("note-"))
        // Heading on any line wins over a preceding non-heading first line.
        #expect(DrawerMapping.slug(from: "intro\n# Real Title\n", id: id) == "real-title")
    }

    @Test("moot_id in frontmatter wins over stableSourceKey FNV for lineageID")
    func mootIDWinsOverFNV() {
        let mapping = DrawerMapping(classifyOnImport: false)
        let lineage = UUID()
        let note = NoteIR(
            stableSourceKey: "some/other/path",
            body: [Block(text: "content")],
            frontmatter: ["room": "r", "moot_id": lineage.uuidString],
            mootID: lineage
        )
        let (frame, _) = mapping.makeCaptureFrame(for: note, content: "content")
        // The mootID from NoteIR must win over the FNV hash of the stable key.
        #expect(frame.lineageID == lineage)
    }

    @Test("absent moot_id falls back to FNV lineage derivation")
    func absentMootIDFallsBack() {
        let mapping = DrawerMapping(classifyOnImport: false)
        let note = NoteIR(
            stableSourceKey: "inbox/my-note",
            body: [Block(text: "some human note")],
            frontmatter: ["room": "inbox"]
        )
        let (frame, _) = mapping.makeCaptureFrame(for: note, content: "some human note")
        let expected = DrawerMapping.lineageID(forStableSourceKey: "inbox/my-note")
        #expect(frame.lineageID == expected)
    }

    // MARK: - Fix 4: vault import timestamp validation

    /// A note with an in-range `created` ISO8601 timestamp must preserve its
    /// `eventTime` through the capture frame (no clamping occurs for valid dates).
    @Test("import: in-range created timestamp is preserved in eventTime")
    func importInRangeTimestampPreserved() {
        let mapping = DrawerMapping(classifyOnImport: false)
        // A normal 2024 timestamp — well within the RFC-3339 range.
        let iso = "2024-03-15T10:30:00.000Z"
        let note = NoteIR(
            stableSourceKey: "inbox/timestamped",
            body: [Block(text: "timestamped note")],
            frontmatter: ["room": "inbox"],
            originDate: OccurredAt(iso8601: iso)
        )
        let (frame, _) = mapping.makeCaptureFrame(for: note, content: "timestamped note")
        // The frame must preserve the event time — not clamp or drop it.
        let result = frame.eventTime
        #expect(result != nil, "in-range timestamp must survive into the capture frame")
        if let t = result {
            // Check the date is somewhere in 2024.
            #expect(t.timeIntervalSince1970 > 1_700_000_000, "preserved timestamp must be in 2024")
        }
    }

    /// A note whose `created` ISO8601 string cannot be parsed (returns nil from
    /// `OccurredAt.date`) must produce `eventTime = nil`, letting the substrate
    /// use the insertion clock. This covers the `+58432-...` poison format which
    /// `ISO8601DateFormatter` cannot parse.
    @Test("import: unparseable created timestamp yields nil eventTime (no poison write)")
    func importUnparseableTimestampYieldsNilEventTime() {
        let mapping = DrawerMapping(classifyOnImport: false)
        // A 5-digit year string — ISO8601DateFormatter cannot parse this.
        // OccurredAt(iso8601:) stores it as-is; .date returns nil.
        let poisonISO = "+58432-12-25T03:04:25.000Z"
        let note = NoteIR(
            stableSourceKey: "inbox/poison",
            body: [Block(text: "poison timestamp note")],
            frontmatter: ["room": "inbox"],
            originDate: OccurredAt(iso8601: poisonISO)
        )
        let (frame, _) = mapping.makeCaptureFrame(for: note, content: "poison timestamp note")
        // The frame must drop the poison timestamp, not pass it to the substrate.
        #expect(frame.eventTime == nil, "unparseable poison timestamp must produce nil eventTime")
    }
}
