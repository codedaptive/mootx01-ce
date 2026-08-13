// EncodeMarkerDrainTests.swift
//
// A2 end-to-end (benchmark reset 2026-08-13): a captured drawer rides the
// encode drain; when `awaitEncodeDrain` returns, the estate audit log
// carries EXACTLY ONE `encodeComplete` marker for the drain unit, anchored
// on the unit's first drawer, with the queue session id and row count in
// the reason column. This is the harness-facing contract the INGEST-time
// derivation (C3) consumes.

import Testing
import Foundation
import LocusKit
@testable import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
@testable import GeniusLocusKit

@Suite("EncodeMarkerDrainTests")
struct EncodeMarkerDrainTests {

    private func provisionGLKEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-encode-marker-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Encode Marker Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        return (kit, handle)
    }

    private func captureFrame(_ content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "encode-marker-tests",
            latticeAnchor: .udc("000"),
            addedBy: "encode-marker-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    @Test("a drained capture leaves one encodeComplete marker with session and count")
    func drainSealsOneMarker() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        let estate = try await kit.estate(for: handle)

        // Capture through the GLK seam — the path that enqueues the encode
        // job. A raw LocusKit estate.capture inserts the row but never rides
        // the encode queue, so no drain unit and no marker exists for it.
        let drawer = try await kit.capture(
            handle,
            captureFrame("Encode marker end-to-end: this drawer's encode completion must be audited."),
            mode: .regular)
        try await kit.awaitEncodeDrain(for: handle)

        let rowID = try #require(UUID(uuidString: drawer.id))
        let events = try await estate.auditEventsForRow(rowID)
        let markers = events.filter { $0.verb == DrawerStore.encodeCompleteVerb }
        #expect(markers.count == 1,
            "exactly one marker per drain unit; trail verbs: \(events.map(\.verb))")
        let marker = try #require(markers.first)
        #expect(marker.actor == DrawerStore.encodeWorkerActor)
        // reason = "session=<queue session id> rows=<n>": the session id is
        // minted by the queue claim, so pin the shape, not the value.
        let reason = try #require(marker.reason)
        #expect(reason.hasPrefix("session="))
        #expect(reason.hasSuffix(" rows=1"), "single capture = drain unit of one row")
    }
}
