import Testing
import SubstrateTypes
import Foundation
@testable import LocusKit

@Suite("Estate verb tests — capture, withdraw, recall, mutate, learn")
struct EstateVerbTests {

    /// Build a fresh estate on a unique temp path.
    private func makeEstate() async throws -> (Estate, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-verb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        let estate = try await Estate.create(storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
        return (estate, path)
    }

    @Test("capture round-trips a drawer with correct fields")
    func capture_roundTrip() async throws {
        let (estate, _) = try await makeEstate()
        // CaptureChannel has no `.manual` case in shipped code (see BRR);
        // `.typed` is the canonical typed-input channel.
        let frame = CaptureFrame(
            content: "Hello LocusKit",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        let drawer = try await estate.capture(frame)
        #expect(drawer.content == "Hello LocusKit")
        #expect(drawer.udcCode == "004")
        #expect(drawer.adjectiveBitmap & 0x3F == 0)
        #expect(drawer.operationalBitmap & 0x3F == Int64(CaptureChannel.typed.rawValue))
    }

    @Test("capture with default provenance leaves confirmation/confidence at raw 0")
    func capture_defaultProvenanceConfirmationConfidenceZero() async throws {
        let (estate, _) = try await makeEstate()
        // A frame that omits confirmation/confidence must produce the SAME
        // provenance bytes as before those slots existed: both fields default
        // to raw 0 (.unconfirmed / .null), so the confirmation window (bits
        // 18–23) and confidence window (bits 24–29) are both zero.
        let frame = CaptureFrame(
            content: "default provenance",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        let drawer = try await estate.capture(frame)
        #expect(drawer.confirmation == .unconfirmed)
        #expect(drawer.confidence == .null)
        // Confirmation window (bits 18–23) and confidence window (bits 24–29)
        // are zero — byte-identical to the pre-slot default.
        #expect(drawer.provenance & 0x3FFC0000 == 0)
    }

    @Test("capture records non-default confirmation and confidence and round-trips")
    func capture_nonDefaultProvenanceRoundTrips() async throws {
        let (estate, _) = try await makeEstate()
        // A daemon capturing with a known review status and confidence band
        // records them at birth — no separate confirm/enrichment mutation.
        let frame = CaptureFrame(
            content: "daemon-confirmed",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "daemon",
            embeddingModelID: "minilm-v6",
            confirmation: .automatedConfirmed,
            confidence: .high
        )
        let drawer = try await estate.capture(frame)
        #expect(drawer.confirmation == .automatedConfirmed)
        #expect(drawer.confidence == .high)
        // Re-read from the store to prove the bytes round-trip through SQLite.
        let refetched = try await estate._peekDrawer(id: drawer.id)
        guard let refetched else {
            Issue.record("drawer not found after capture")
            return
        }
        #expect(refetched.confirmation == .automatedConfirmed)
        #expect(refetched.confidence == .high)
        // The two new axes do not disturb the other provenance fields
        // (`sensitivity` decodes provenance bits 30–35).
        #expect(refetched.sourceType == .user)
        #expect(refetched.sensitivity == .normal)
    }

    @Test("capture with the same lineageID triggers the supersession cascade")
    func capture_supersessionByLineage() async throws {
        let (estate, _) = try await makeEstate()
        let lineage = UUID()
        let f1 = CaptureFrame(
            content: "v1",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6",
            lineageID: lineage
        )
        let d1 = try await estate.capture(f1)
        let f2 = CaptureFrame(
            content: "v2",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6",
            lineageID: lineage
        )
        _ = try await estate.capture(f2)

        let refetched = try await estate._peekDrawer(id: d1.id)
        guard let refetched else {
            Issue.record("d1 not found after supersession")
            return
        }
        #expect(refetched.adjectiveBitmap & 0x3F == Int64(State.superseded.rawValue))
    }

    @Test("withdraw moves a drawer's state to .withdrawn")
    func withdraw_changesState() async throws {
        let (estate, _) = try await makeEstate()
        let frame = CaptureFrame(
            content: "to be withdrawn",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        let drawer = try await estate.capture(frame)
        try await estate.withdraw(rowID: drawer.id, reason: "test")

        let refetched = try await estate._peekDrawer(id: drawer.id)
        guard let refetched else {
            Issue.record("drawer not found after withdraw")
            return
        }
        #expect((refetched.adjectiveBitmap & 0x3F) == Int64(State.withdrawn.rawValue))
    }

    @Test("recall yields a single page from an empty estate without throwing")
    func recall_emptyEstateSinglePage() async throws {
        let (estate, _) = try await makeEstate()
        // The explicit state/provenance filters keep this old page-shape
        // fixture focused on an empty unconfirmed inbox. Ordinary recall
        // would also return zero rows here.
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .unconfirmed])
        )
        var pageCount = 0
        for await page in stream {
            pageCount += 1
            #expect(page.rows.isEmpty)
            #expect(page.isLast)
        }
        #expect(pageCount == 1)
    }

    @Test("mutate(.confirm) transitions the confirmation axis to userConfirmed")
    func mutate_confirm_transitionsConfirmation() async throws {
        let (estate, _) = try await makeEstate()
        let frame = CaptureFrame(
            content: "to confirm",
            channel: .typed,
            room: "study",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        let drawer = try await estate.capture(frame)
        // Freshly captured rows are unconfirmed.
        #expect(drawer.confirmation == .unconfirmed)

        try await estate.mutate(rowID: drawer.id, kind: .confirm)

        // Re-read: confirmation is now userConfirmed; every other axis is
        // preserved (room/state unchanged).
        let after = try #require(try await estate.store.getDrawer(id: drawer.id))
        #expect(after.confirmation == .userConfirmed)
        #expect(after.adjectiveBitmap & 0x3F == 0)  // state still active
    }

    @Test("mutate(.confirm) on a missing row throws drawerNotFound")
    func mutate_confirm_missingRow_throwsNotFound() async throws {
        let (estate, _) = try await makeEstate()
        await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: "no-such-id", kind: .confirm, payload: String?.none)
        }
    }

    @Test(".reject on an active drawer throws — automaton enforces pending-only source state")
    func mutate_reject_fromActive_throwsGateViolation() async throws {
        let (estate, _) = try await makeEstate()
        let frame = CaptureFrame(
            content: "x",
            channel: .typed,
            room: "r",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        let drawer = try await estate.capture(frame)
        // reject is implemented but the automaton only permits it from .pending.
        // Active rows raise a gate discipline violation.
        await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: drawer.id, kind: .reject, payload: String?.none)
        }
    }

    // MARK: - learn

    /// A genuine source catalog entry with a real (non-empty) anchor.
    private func sampleSource(
        id: String = "src-1",
        handle: String = "https://example.com",
        udc: String = "004"
    ) -> SourceCatalogEntry {
        SourceCatalogEntry(
            id: id,
            kind: .user,
            handle: handle,
            latticeAnchor: LatticeAnchor(udcCode: udc),
            firstSeen: Date(timeIntervalSince1970: 1_700_000_000),
            addedBy: "cataloger"
        )
    }

    @Test("learn writes a genuine reference anchored to its source — no sentinel")
    func learn_writesGenuineAnchor() async throws {
        let (estate, _) = try await makeEstate()
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let frame = LearnFrame(source: sampleSource(), handle: "https://example.com/page")
        let reference = try await estate.learn(frame, now: now)

        // Anchor is the source's genuine anchor, never a sentinel.
        #expect(reference.latticeAnchor.udcCode == "004")
        #expect(!reference.latticeAnchor.udcCode.isEmpty)
        #expect(reference.sourceCatalogID == "src-1")
        #expect(reference.handle == "https://example.com/page")
        #expect(reference.addedBy == "learn")
        // Operational axes decode back: defaults are byReference + weekly,
        // source = user (from the catalog kind).
        #expect(reference.mode == .byReference)
        #expect(reference.refreshPolicy == .weekly)
        #expect(reference.acquisitionSource == .user)

        // Durable + queryable.
        let fetched = try await estate.store.getLearnedReference(id: reference.id)
        #expect(fetched?.latticeAnchor.udcCode == "004")
        // The source was cataloged durably.
        let cataloged = try await estate.store.sourceCatalogEntry(forHandle: "https://example.com")
        #expect(cataloged?.id == "src-1")
    }

    @Test("learn encodes mode and refresh policy into the operational bitmap")
    func learn_encodesModeAndRefresh() async throws {
        let (estate, _) = try await makeEstate()
        let frame = LearnFrame(
            source: sampleSource(),
            handle: "https://example.com/doc",
            mode: .byIngestion,
            refreshPolicy: .daily
        )
        let reference = try await estate.learn(frame, now: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(reference.mode == .byIngestion)
        #expect(reference.refreshPolicy == .daily)
    }

    @Test("learn reuses an existing catalog entry keyed by source handle")
    func learn_reusesCatalogEntry() async throws {
        let (estate, _) = try await makeEstate()
        let r1 = try await estate.learn(
            LearnFrame(source: sampleSource(), handle: "https://example.com/a"),
            now: Date(timeIntervalSince1970: 1_700_000_300))
        // Same source handle, different id — the existing entry must be reused.
        let r2 = try await estate.learn(
            LearnFrame(source: sampleSource(id: "src-2"), handle: "https://example.com/b"),
            now: Date(timeIntervalSince1970: 1_700_000_400))
        #expect(r1.sourceCatalogID == "src-1")
        #expect(r2.sourceCatalogID == "src-1")
    }

    @Test("learn fails loud only on a genuinely invalid (empty) handle")
    func learn_failsLoudOnEmptyHandle() async throws {
        let (estate, _) = try await makeEstate()
        await #expect(throws: LocusKitError.self) {
            _ = try await estate.learn(
                LearnFrame(source: self.sampleSource(), handle: ""),
                now: Date(timeIntervalSince1970: 1_700_000_500))
        }
    }
}
