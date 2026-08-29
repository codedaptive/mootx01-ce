// ServeOpenResumedBacklogTests.swift
//
// Serve-open resumed-backlog regression (SPEC_DISTILLATION_STORAGE §7.1).
//
// At serve open (`open` + `wireGLKSubstores` — no provision), the ingest-queue
// mount opens the persisted queue.sqlite and starts the drain worker, which
// resumes any encode backlog left by a previous process. `wireSubstores` must
// install the onEncoded drain-stage rider (room rollup + distillation + dense
// recompose + A2 marker) BEFORE that mount: a batch the worker drains before
// the rider lands encodes WITHOUT distilling, violating "a fully drained
// estate is a fully distilled estate" (§7.1) for exactly those resumed rows.
// Rust twin: estate_registry.rs `wire_sqlite_semantic_recall` (rider installed,
// then eager mount).
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

    /// A persisted encode backlog resumed at serve open must be fully
    /// distilled once the drain barrier returns — no drawer left undistilled.
    @Test
    func resumedPersistedBacklogIsFullyDistilledAfterServeOpenDrain() async throws {
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
        let bodies = [
            "The reactor maintenance window opens on March 3rd at the Geneva site.",
            "Sarah approved the vendor contract for the Geneva facility yesterday.",
            "Quarterly metrics show reactor uptime improved by twelve percent.",
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
            // the "foreign" drainer), rows stored but undistilled.
            let corpus = try #require(await kit.corpusKits[handle])
            let depth = try await corpus.ingestQueueDepth()
            #expect(depth.pending >= bodies.count,
                "captures must persist as pending queue jobs while the foreign lease blocks the drain worker; got pending=\(depth.pending)")
            let estate = try await kit.estate(for: handle)
            for id in capturedIDs {
                let row = try #require(try await estate.getDrawers(ids: [id]).first)
                #expect(row.distilled == nil,
                    "pre-close, lease-blocked drawer \(id) must be undistilled")
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

        // §7.1: a fully drained estate is a fully distilled estate — every
        // resumed drawer carries its representation.
        let estate2 = try await kit2.estate(for: handle2)
        for id in capturedIDs {
            let row = try #require(try await estate2.getDrawers(ids: [id]).first)
            #expect(row.distilled != nil,
                "resumed backlog drawer \(id) must be distilled after the serve-open drain (§7.1) — an undistilled row means a batch encoded before the rider was installed")
            #expect(row.distilledPipelineVersion == DistillationPipelineVersion.current,
                "resumed drawer \(id) must carry the current distillation pipeline version")
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
