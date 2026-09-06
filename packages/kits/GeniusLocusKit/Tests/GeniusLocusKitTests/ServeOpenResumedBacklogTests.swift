// ServeOpenResumedBacklogTests.swift
//
// Serve-open resumed-backlog regression.
//
// At serve open (`open` + `wireGLKSubstores` — no provision), the ingest-queue
// mount opens the persisted queue.sqlite and starts the drain worker, which
// resumes any encode backlog left by a previous process. `wireSubstores` must
// install the onEncoded encode rider (room rollup + structural fingerprint
// lane entry + A2 marker) BEFORE that mount: a batch the worker drains before
// the rider lands encodes WITHOUT the rider's work, leaving exactly those
// resumed rows out of the fingerprint lane. The lane entry is the evidence
// this test reads. Rust twin: estate_registry.rs `wire_sqlite_semantic_recall`
// (rider installed, then eager mount).
//
// Fixture mechanics: the backlog is constructed through the public capture
// path by holding the cross-process encode `DrainLease` from the test — the
// same stand-down a second process's drainer imposes in production — so the
// estate's own worker never claims the enqueued jobs before close. NOTE on
// discrimination: this test drives the exact defect path (persisted backlog
// resumed at serve open) and fails deterministically whenever the rider is
// missing for resumed batches, but the historical mount-then-wire ordering
// loses only a tiny in-actor race window, so that ordering fails this test
// racily rather than on every run. A deterministic ordering probe would need
// a CorpusKit-side "rider present at worker start" hook, which is outside
// this kit's scope; the source ordering itself is documented at the seam
// in `EstateLifecycle.wireSubstores`.

import Testing
import Foundation
import LocusKit
@testable import CorpusKit
import QueueKit
import PersistenceKit
import PersistenceKitSQLite
@testable import SubstrateML
@testable import GeniusLocusKit

@Suite("serve open — resumed encode backlog rides the drain-stage rider")
struct ServeOpenResumedBacklogTests {

    private let owner = OwnerCredentials(ownerIdentifier: "serve-resume-tests")

    private func captureFrame(_ content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "serve-resume-tests",
            latticeAnchor: .udc("000"),
            addedBy: "serve-resume-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    /// A persisted encode backlog resumed at serve open must carry the encode
    /// rider's fingerprint lane entry on every drawer once the drain barrier
    /// returns — no resumed drawer left out of the lane.
    @Test
    func resumedPersistedBacklogIsFullyFingerprintedAfterServeOpenDrain() async throws {
        // Dedicated directory: the encode drain lease is a per-directory file
        // (`encode.drain.lease`), so sharing the bare temp dir would contend
        // with unrelated durable-estate tests running in parallel.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-serve-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("estate.sqlite")

        // Simulated second-process drainer: hold the encode lease BEFORE the
        // estate exists so the estate's own drain worker stands down (T2) and
        // every enqueued job persists undrained. Long TTL keeps the lease
        // fresh across the whole backlog-construction phase without heartbeats.
        let foreignLease = DrainLease(
            directory: dir, stream: "encode",
            instanceToken: "serve-resume-foreign-drainer", ttl: 600)
        #expect(foreignLease.tryAcquire(now: Date()),
            "fresh directory — the foreign lease must acquire")

        // Phase 1 — build the persisted backlog through the public capture path.
        // Every body names people or places: the structural fingerprint is
        // built from the capitalisation-heuristic extractor, so a body with no
        // proper noun would yield a zero fingerprint and no lane entry.
        let bodies = [
            "The reactor maintenance window opens on March 3rd at the Geneva site.",
            "Sarah approved the vendor contract for the Geneva facility yesterday.",
            "Quarterly metrics from Geneva show the Meyrin reactor uptime improved by twelve percent.",
        ]
        var capturedIDs: [String] = []
        do {
            let kit = GeniusLocusKit()
            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .sqlite(url: url)))
            // lifetime .ephemeral keeps the identity key out of the real
            // login keychain (temp-dir SQLite counts as durable).
            let params = EstateProvisionParams(
                estateName: "Serve Resume Test Estate",
                kind: .glk,
                zoomWindowLow: 1,
                zoomWindowHigh: 10,
                frameworkProfile: "KnowledgeWork",
                syncMode: .none,
                lifetime: .ephemeral
            )
            let handle = try await kit.provision(
                storage: storage, owner: owner, params: params,
                embeddingModels: [.deterministic])

            for body in bodies {
                let drawer = try await kit.capture(handle, captureFrame(body), mode: .regular)
                capturedIDs.append(drawer.id)
            }

            // The backlog is real: jobs persisted, none drained (lease held by
            // the "foreign" drainer), rows stored but not yet in the lane.
            let corpus = try #require(await kit.corpusKits[handle])
            let depth = try await corpus.ingestQueueDepth()
            #expect(depth.pending >= bodies.count,
                "captures must persist as pending queue jobs while the foreign lease blocks the drain worker; got pending=\(depth.pending)")
            let vectorStore = try #require(await kit.vectorStores[handle])
            for id in capturedIDs {
                let lane = try await vectorStore.getVector(
                    itemID: id, modelID: GeniusLocusKit.distillationLaneModelID)
                #expect(lane == nil,
                    "pre-close, lease-blocked drawer \(id) must have no fingerprint lane entry")
            }

            // Close with the backlog still pending — the previous process exits.
            try await kit.close(handle)
        }

        // The previous process is gone; its would-be drainer never held the
        // lease. Release the foreign lease so the serve-open worker can claim.
        foreignLease.release()

        // Phase 2 — serve open: bare open + wireGLKSubstores (no provision).
        // The mount resumes the persisted backlog; the drain-stage rider must
        // see every resumed batch.
        let kit2 = GeniusLocusKit()
        let storage2 = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url)))
        let handle2 = try await kit2.open(
            storage: storage2, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        try await kit2.wireGLKSubstores(
            for: handle2, backingStorage: storage2,
            embeddingModels: [.deterministic])

        // Drain barrier: covers encode AND the onEncoded rider (the rider
        // fires before the terminal queue reply — CorpusKit ordering).
        try await kit2.awaitEncodeDrain(for: handle2, timeout: .seconds(60))

        // A fully drained estate is a fully fingerprinted estate — every
        // resumed drawer carries its lane entry (the bodies name people and
        // places, so each structural fingerprint is non-zero).
        let vectorStore2 = try #require(await kit2.vectorStores[handle2])
        for id in capturedIDs {
            let lane = try await vectorStore2.getVector(
                itemID: id, modelID: GeniusLocusKit.distillationLaneModelID)
            #expect(lane != nil,
                "resumed backlog drawer \(id) must carry a fingerprint lane entry after the serve-open drain — a missing entry means a batch encoded before the rider was installed")
        }

        // The queue is empty — the backlog actually drained (the assertions
        // above did not pass vacuously on an undrained queue).
        let corpus2 = try #require(await kit2.corpusKits[handle2])
        let depth2 = try await corpus2.ingestQueueDepth()
        #expect(depth2.pending == 0 && depth2.inFlight == 0,
            "serve-open drain must consume the entire resumed backlog; got \(depth2)")

        try await kit2.close(handle2)
    }
}
