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
        let drawer = Drawer(
            id: "drawer-1",
            content: "exported content",
            wing: "wing_owner",
            room: "research",
            addedBy: "tester",
            filedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embeddingModelID: "m",
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
        #expect(note.stableSourceKey == "wing_owner/research/drawer-1")
        #expect(note.flattenedBody == "exported content")
        #expect(note.frontmatter["udc"] == "004")
        #expect(note.frontmatter["wing"] == "wing_owner")
        #expect(note.frontmatter["room"] == "research")
        #expect(note.originalPath == "wing_owner/research")
        #expect(note.links == [WikiLink(target: "Benzene", alias: nil, raw: "Benzene")])
    }
}
