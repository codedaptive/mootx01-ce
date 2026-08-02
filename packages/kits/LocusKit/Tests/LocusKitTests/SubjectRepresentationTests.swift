import Foundation
import PersistenceKit
import SubstrateTypes
import Testing
@testable import LocusKit

/// Subject trio on the drawer row (progressive recall PR-01).
///
/// The subject is the one-sentence AI-facing summary of a drawer's content —
/// three nullable columns (`subject`, `subject_pipeline_version`,
/// `subject_at`) written or cleared together. NULL `subject` is the
/// backfill-eligibility predicate; there is no presence bit in v1 (the
/// operational feature-flag region is full — see
/// PR01_SUBJECT_QUAD_BLAST_RADIUS.md) and no Bool stored property. Every
/// content-touching write NULLs the trio in the same statement, exactly as
/// it NULLs the distilled quad: derived text must not outlive the content
/// it summarizes.
///
/// The Rust suite `subject_representation_tests` mirrors this file
/// case-for-case (twin-parity gate).
@Suite("SubjectRepresentationTests")
struct SubjectRepresentationTests {

    // MARK: - Fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-subject-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func makeStore() async throws -> (DrawerStore, URL) {
        let url = makeTempURL()
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    private func sampleDrawer(id: String = "s1") -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "The quarterly planning meeting moved to Thursday. "
                + "Sarah sends updated invites Monday. Update travel plans.",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
    }

    /// An AI-facing register sample, within the 120-character contract.
    private let sampleSubject =
        "Quarterly planning moved to Thursday; Sarah sends invites Monday; travel plans need updating."

    // MARK: - Entity defaults and Codable

    @Test("Drawer subject fields default to nil")
    func drawerSubjectFieldsDefaultNil() {
        let d = sampleDrawer()
        #expect(d.subject == nil)
        #expect(d.subjectPipelineVersion == nil)
        #expect(d.subjectAt == nil)
    }

    @Test("Drawer Codable round-trips the three subject fields")
    func drawerCodableRoundTripsSubject() throws {
        let d = Drawer(
            id: TestStorage.tid("scodable"),
            content: "content",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6",
            subject: "Meeting moved Thursday; invites Monday.",
            subjectPipelineVersion: "ai-v1",
            subjectAt: t(1_700_000_100)
        )
        let decoded = try JSONDecoder().decode(
            Drawer.self, from: JSONEncoder().encode(d))
        #expect(decoded.subject == d.subject)
        #expect(decoded.subjectPipelineVersion == "ai-v1")
        #expect(decoded.subjectAt == d.subjectAt)
        #expect(decoded == d)
    }

    @Test("payloads encoded before the trio existed decode with nil subjects")
    func preTrioPayloadDecodesNilSubject() throws {
        // A drawer encoded WITHOUT subject keys (the pre-PR-01 wire shape):
        // strip the keys from a fresh encoding to simulate an old payload.
        let old = sampleDrawer()
        let data = try JSONEncoder().encode(old)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "subject")
        dict.removeValue(forKey: "subjectPipelineVersion")
        dict.removeValue(forKey: "subjectAt")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(Drawer.self, from: stripped)
        #expect(decoded.subject == nil)
        #expect(decoded.subjectPipelineVersion == nil)
        #expect(decoded.subjectAt == nil)
    }

    // MARK: - Store round-trip

    @Test("fresh row: all three subject columns read back NULL")
    func freshRowReadsNilSubject() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        let loaded = try await store.getDrawer(id: d.id)
        #expect(loaded?.subject == nil)
        #expect(loaded?.subjectPipelineVersion == nil)
        #expect(loaded?.subjectAt == nil)
    }

    @Test("a capture-time subject round-trips through addDrawer")
    func captureTimeSubjectRoundTrips() async throws {
        // PR-02's file_memory requirement lands the subject AT capture —
        // the row map must carry it on insert, not only via the setter.
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = Drawer(
            id: TestStorage.tid("scap"),
            content: "Commute plan: switch to the monthly transit pass.",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6",
            subject: "Commute: switch to monthly transit pass.",
            subjectPipelineVersion: "ai-v1",
            subjectAt: t(1_700_000_000))
        try await store.addDrawer(d)
        let loaded = try await store.getDrawer(id: d.id)
        #expect(loaded?.subject == "Commute: switch to monthly transit pass.")
        #expect(loaded?.subjectPipelineVersion == "ai-v1")
        #expect(loaded?.subjectAt == t(1_700_000_000))
    }

    @Test("setSubjectRepresentation populates all three columns atomically")
    func setSubjectPopulatesAllThree() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)

        let updated = try await store.setSubjectRepresentation(
            drawerId: d.id,
            subject: sampleSubject,
            pipelineVersion: "ai-v1",
            at: t(1_700_000_200))
        #expect(updated == 1)

        let loaded = try await store.getDrawer(id: d.id)
        #expect(loaded?.subject == sampleSubject)
        #expect(loaded?.subjectPipelineVersion == "ai-v1")
        #expect(loaded?.subjectAt == t(1_700_000_200))
    }

    @Test("setSubjectRepresentation replaces a prior subject")
    func setSubjectReplacesPrior() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        _ = try await store.setSubjectRepresentation(
            drawerId: d.id, subject: "First subject line.",
            pipelineVersion: "ai-v1", at: t(1_700_000_200))
        _ = try await store.setSubjectRepresentation(
            drawerId: d.id, subject: "Second subject line, regenerated.",
            pipelineVersion: "minillm-v1", at: t(1_700_000_300))
        let loaded = try await store.getDrawer(id: d.id)
        #expect(loaded?.subject == "Second subject line, regenerated.")
        #expect(loaded?.subjectPipelineVersion == "minillm-v1")
        #expect(loaded?.subjectAt == t(1_700_000_300))
    }

    @Test("setSubjectRepresentation on an unknown id updates zero rows")
    func setSubjectUnknownID() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let updated = try await store.setSubjectRepresentation(
            drawerId: "99999999-9999-4999-8999-999999999999",
            subject: "x-marks-the-spot subject", pipelineVersion: "ai-v1",
            at: t(1_700_000_200))
        #expect(updated == 0)
    }

    @Test("the 120-character length contract is enforced at the boundary")
    func lengthContractEnforced() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        let oversize = String(repeating: "x", count: DrawerStore.subjectLengthContract + 1)
        await #expect(throws: LocusKitError.self) {
            _ = try await store.setSubjectRepresentation(
                drawerId: d.id, subject: oversize,
                pipelineVersion: "ai-v1", at: t(1_700_000_200))
        }
        // Exactly at the contract: accepted.
        let exact = String(repeating: "y", count: DrawerStore.subjectLengthContract)
        let updated = try await store.setSubjectRepresentation(
            drawerId: d.id, subject: exact,
            pipelineVersion: "ai-v1", at: t(1_700_000_201))
        #expect(updated == 1)
    }

    // MARK: - NULL-on-content-write (regeneration trigger + erasure scrub)

    @Test("expungeGated clears the subject columns with the content")
    func expungeClearsSubject() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        _ = try await store.setSubjectRepresentation(
            drawerId: d.id, subject: "Derived subject line.",
            pipelineVersion: "ai-v1", at: t(1_700_000_200))

        _ = try await store.expungeGated(
            drawerId: d.id, changedBy: "test",
            reason: "erasure scrub covers derived subject",
            now: t(1_700_000_500))

        let after = try await store.getDrawer(id: d.id)
        #expect(after?.content == "")
        // The subject is content-derived text: it must not outlive the
        // erased content.
        #expect(after?.subject == nil)
        #expect(after?.subjectPipelineVersion == nil)
        #expect(after?.subjectAt == nil)
    }

    @Test("updateDatasetContent clears the subject columns (edit trigger)")
    func datasetContentUpdateClearsSubject() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        _ = try await store.setSubjectRepresentation(
            drawerId: d.id, subject: "Stale subject line.",
            pipelineVersion: "ai-v1", at: t(1_700_000_200))

        _ = try await store.updateDatasetContent(
            drawerId: d.id, content: "{\"patched\":true}")

        let after = try await store.getDrawer(id: d.id)
        #expect(after?.content == "{\"patched\":true}")
        // Content changed in place → subject is stale → NULL is the
        // regeneration trigger (no staleness flag, no Bool).
        #expect(after?.subject == nil)
        #expect(after?.subjectPipelineVersion == nil)
        #expect(after?.subjectAt == nil)
    }

    // MARK: - countMissingSubject (the debt counter)

    @Test("countMissingSubject counts NULL and version-mismatched rows only")
    func countMissingSubjectSemantics() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        // d1: no subject (counts). d2: current-contract subject (does not
        // count). d3: stale-contract subject (counts — regeneration
        // candidate). d4: tombstoned via expunge (does not count — its
        // content is scrubbed empty, which the predicate excludes).
        let d1 = sampleDrawer(id: "m1")
        let d2 = sampleDrawer(id: "m2")
        let d3 = sampleDrawer(id: "m3")
        let d4 = sampleDrawer(id: "m4")
        for d in [d1, d2, d3, d4] { try await store.addDrawer(d) }
        _ = try await store.setSubjectRepresentation(
            drawerId: d2.id, subject: "Current-contract subject.",
            pipelineVersion: "minillm-v1", at: t(1_700_000_200))
        _ = try await store.setSubjectRepresentation(
            drawerId: d3.id, subject: "Stale-contract subject.",
            pipelineVersion: "ai-v0-legacy", at: t(1_700_000_200))
        _ = try await store.expungeGated(
            drawerId: d4.id, changedBy: "test", reason: nil,
            now: t(1_700_000_500))

        let missing = try await store.countMissingSubject(pipelineVersion: "minillm-v1")
        #expect(missing == 2)  // d1 (NULL) + d3 (version mismatch)
    }
}
