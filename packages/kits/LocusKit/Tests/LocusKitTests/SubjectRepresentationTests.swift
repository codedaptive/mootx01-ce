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

// MARK: - Tier-aware debt enumeration (PR-10)

extension SubjectRepresentationTests {

    /// The regeneration ladder by construction: NULL rows and listed
    /// tiers enumerate; ai-v1 (above the requester) and the requester's
    /// own tier never do. Twin: Rust `tier_aware_debt_enumeration`.
    @Test func tierAwareDebtEnumeration() async throws {
        let store = try await freshStore()
        // Four rows: NULL, ai-v1, consolidation-v1, minillm-v1.
        let nullID = try await addSample(store, content: "row without subject")
        let aiID = try await addSample(store, content: "row by the filing AI")
        _ = try await store.setSubjectRepresentation(
            drawerId: aiID, subject: "Filing-AI subject.",
            pipelineVersion: "ai-v1", at: Date())
        let consID = try await addSample(store, content: "row by consolidation")
        _ = try await store.setSubjectRepresentation(
            drawerId: consID, subject: "Deterministic vague subject.",
            pipelineVersion: "consolidation-v1", at: Date())
        let modelID = try await addSample(store, content: "row by the model")
        _ = try await store.setSubjectRepresentation(
            drawerId: modelID, subject: "Model subject.",
            pipelineVersion: "minillm-v1", at: Date())

        // NULL-only (the PR-09 default): just the NULL row.
        #expect(try await store.countSubjectDebt() == 1)
        let nullOnly = try await store.subjectDebtBatch(limit: 10)
        #expect(nullOnly.map(\.id) == [nullID])

        // The Apple rider's view: NULL + the deterministic tiers;
        // ai-v1 and minillm-v1 NEVER enumerate.
        let riderView = try await store.subjectDebtBatch(
            limit: 10, includingPipelines: ["consolidation-v1", "seed-v1"])
        #expect(Set(riderView.map(\.id)) == Set([nullID, consID]))
        #expect(try await store.countSubjectDebt(
            includingPipelines: ["consolidation-v1", "seed-v1"]) == 2)
    }

    private func freshStore() async throws -> DrawerStore {
        // Same SQLite temp-file harness the rest of this suite uses.
        let (store, _) = try await makeStore()
        return store
    }

    private func addSample(_ store: DrawerStore, content: String) async throws -> String {
        let d = Drawer(
            content: content,
            parentNodeId: UUID().uuidString,
            addedBy: "tier-tests",
            filedAt: Date(),
            embeddingModelID: "test-v1",
            udcCode: "001")
        try await store.addDrawer(d, now: Date())
        return d.id
    }

    // MARK: - Custody audit row (MXE-SK — Codex cc90c5dcecb081918c159788e1ffb3d6)
    //
    // Cross-port equivalence: the Rust twin suite
    // (subject_representation_tests.rs) asserts the same
    // (verb, actor, reason, before == after) tuple for the same inputs.

    @Test("setSubjectRepresentation seals exactly one custody event carrying actor and note")
    func setSubjectSealsCustodyEventWithNote() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer(id: "scustody1")
        try await store.addDrawer(d)
        let rowID = try #require(UUID(uuidString: d.id))

        let before = try await store.auditEventsForRow(rowID).count
        _ = try await store.setSubjectRepresentation(
            drawerId: d.id,
            subject: sampleSubject,
            pipelineVersion: "ai-v1",
            at: t(1_700_000_200),
            changedBy: "test-actor",
            reason: "meeting moved; subject stale")

        let events = try await store.auditEventsForRow(rowID)
        #expect(events.count == before + 1, "exactly one custody event sealed")
        let e = try #require(events.last)
        #expect(e.verb == "setSubject")
        #expect(e.actor == "test-actor")
        #expect(e.reason == "meeting moved; subject stale")
        // setSubject changes no bitmap and no anchor: before == after on
        // every value field.
        let beforeBitmaps = try #require(e.beforeBitmaps)
        #expect(beforeBitmaps == e.afterBitmaps)
        #expect(e.beforeLatticeAnchor == e.afterLatticeAnchor)
    }

    @Test("setSubjectRepresentation without a note seals a custody event with an absent reason")
    func setSubjectWithoutNoteSealsRowWithAbsentReason() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer(id: "scustody2")
        try await store.addDrawer(d)
        let rowID = try #require(UUID(uuidString: d.id))

        let before = try await store.auditEventsForRow(rowID).count
        _ = try await store.setSubjectRepresentation(
            drawerId: d.id,
            subject: sampleSubject,
            pipelineVersion: "ai-v1",
            at: t(1_700_000_200),
            changedBy: "test-actor")

        let events = try await store.auditEventsForRow(rowID)
        #expect(
            events.count == before + 1,
            "an absent reason is not an absent row: the custody event still seals")
        let e = try #require(events.last)
        #expect(e.verb == "setSubject")
        #expect(e.reason == nil, "no note supplied ⇒ absent reason")
    }

    @Test("setSubjectRepresentation on an unknown id seals no custody event")
    func setSubjectUnknownIDSealsNoEvent() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let ghost = "99999999-9999-4999-8999-999999999999"
        let updated = try await store.setSubjectRepresentation(
            drawerId: ghost, subject: "x", pipelineVersion: "ai-v1",
            at: t(1_700_000_200), changedBy: "test-actor")
        #expect(updated == 0)
        let events = try await store.auditEventsForRow(try #require(UUID(uuidString: ghost)))
        #expect(events.isEmpty, "no row updated ⇒ no custody event")
    }

    @Test("a forced audit-append failure leaves the subject unchanged (atomicity)")
    func setSubjectFailedAuditAppendRollsBackSubjectWrite() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        // Wrap the real backend so the custody append fails at the
        // production call site INSIDE the transaction: the column write
        // must roll back with it. Genesis "capture" events still seal, so
        // the fixture drawer can be added normally.
        let failing = SetSubjectAuditFailingStorage(inner: TestStorage.sqlite(url))
        let store = try await DrawerStore(storage: failing)
        let d = sampleDrawer(id: "satomic1")
        try await store.addDrawer(d)

        await #expect(throws: (any Error).self, "injected audit failure must surface") {
            _ = try await store.setSubjectRepresentation(
                drawerId: d.id,
                subject: "Subject that must not persist.",
                pipelineVersion: "ai-v1",
                at: t(1_700_000_100),
                changedBy: "test-actor",
                reason: "note that must not persist")
        }

        // The subject trio must be unchanged (rolled back with the append).
        let after = try await store.getDrawer(id: d.id)
        #expect(after?.subject == nil, "subject column must roll back")
        #expect(after?.subjectPipelineVersion == nil)
        #expect(after?.subjectAt == nil)

        // And no setSubject custody event may exist.
        let events = try await store.auditEventsForRow(try #require(UUID(uuidString: d.id)))
        #expect(
            events.allSatisfy { $0.verb != "setSubject" },
            "no setSubject custody event may survive the rollback")
    }
}

// MARK: - Failure-injection storage (MXE-SK atomicity test support)

/// `AuditLog` wrapper that refuses to append `"setSubject"` events and
/// delegates everything else, so gated-capture genesis events still seal.
private struct SetSubjectAppendRefusingAuditLog: AuditLog {
    let inner: any AuditLog

    struct InjectedAuditFailure: Error {}

    func append(_ event: AuditEvent) async throws {
        if event.verb == "setSubject" { throw InjectedAuditFailure() }
        try await inner.append(event)
    }
    func appendBatch(_ events: [AuditEvent]) async throws {
        try await inner.appendBatch(events)
    }
    func iterate(after: HLC?, rowID: UUID?, limit: Int) async throws -> [AuditEvent] {
        try await inner.iterate(after: after, rowID: rowID, limit: limit)
    }
    func eventsForRow(_ rowID: UUID) async throws -> [AuditEvent] {
        try await inner.eventsForRow(rowID)
    }
    func count() async throws -> Int {
        try await inner.count()
    }
}

/// Transaction view handed to the block: same row/blob stores as the real
/// transaction, failing audit log.
private struct SetSubjectFailingTransaction: StorageTransaction {
    let inner: any StorageTransaction
    var rowStore: any RowStore { inner.rowStore }
    var blobStore: any BlobStore { inner.blobStore }
    var auditLog: any AuditLog { SetSubjectAppendRefusingAuditLog(inner: inner.auditLog) }
}

/// Storage wrapper over a real backend whose `auditLog` (both direct and
/// transactional) refuses `"setSubject"` appends.
private struct SetSubjectAuditFailingStorage: Storage {
    let inner: any Storage

    var configuration: EstateConfiguration { inner.configuration }
    var rowStore: any RowStore { inner.rowStore }
    var blobStore: any BlobStore { inner.blobStore }
    var auditLog: any AuditLog { SetSubjectAppendRefusingAuditLog(inner: inner.auditLog) }
    var observer: any StorageObserver { inner.observer }

    func open(schema: SchemaDeclaration) async throws {
        try await inner.open(schema: schema)
    }
    func close() async {
        await inner.close()
    }
    func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        try await inner.transaction(isolation: isolation) { txn in
            try await block(SetSubjectFailingTransaction(inner: txn))
        }
    }
    func currentSchemaVersion() async throws -> Int {
        try await inner.currentSchemaVersion()
    }
    func currentSchemaVersion(for kitID: String) async throws -> Int {
        try await inner.currentSchemaVersion(for: kitID)
    }
    func migrate(to schema: SchemaDeclaration) async throws {
        try await inner.migrate(to: schema)
    }
}
