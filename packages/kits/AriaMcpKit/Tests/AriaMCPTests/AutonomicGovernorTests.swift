import Testing
import Foundation
import CognitionKit
import GeniusLocusKit
import LatticeLib
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
@testable import AriaMCP

/// Deterministic coverage for the resident Autonomic Governor: cadence firing
/// with an injected clock, and the benign no-scheduler skip for standing
/// signals. The loop itself (`run()`) is a thin Task.sleep wrapper over
/// `tick(now:)`; these drive `tick(now:)` directly so there are no wall-clock
/// sleeps.
@Suite("Autonomic governor", .serialized)
struct AutonomicGovernorTests {

    private func makeEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "autonomic-governor-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (kit, handle)
    }

    /// Seed the dreaming queue with one item so the REM-ALPHA pending-count gate
    /// (T9 / NEURONKIT_SPEC §12.2) opens: capture two distinct drawers, then fire
    /// one external-origin recall, which mounts the dreaming queue and enqueues a
    /// DreamingItem (pending → 1). The cycle drains the queue when it fires, so a
    /// later fire-tick must re-seed. Mirrors the Rust ag* governor-test seeding.
    private func seedDreamingQueue(
        _ kit: GeniusLocusKit, _ handle: EstateHandle
    ) async throws {
        _ = try await kit.capture(handle, CaptureFrame(
            content: "ag-dream-seed-alpha", channel: .typed, room: "ag-dream-room",
            latticeAnchor: .udc("000"), addedBy: "ag-test", embeddingModelID: "test-model-v1"))
        _ = try await kit.capture(handle, CaptureFrame(
            content: "ag-dream-seed-beta", channel: .typed, room: "ag-dream-room",
            latticeAnchor: .udc("000"), addedBy: "ag-test", embeddingModelID: "test-model-v1"))
        // External-origin recall enqueues one DreamingItem (B-10a: only external
        // recalls write dreaming items).
        _ = try await kit.recall(handle, GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc),
            mode: .locusOnly, scoring: .raw, limit: 50,
            fallback: .failClosed, origin: .external))
    }

    @Test func firstTickFiresDreamingAndMaintenance() async throws {
        let (kit, handle) = try await makeEstate()
        let governor = AutonomicGovernor(kit: kit, handle: handle, poolDirectory: nil, poolTableArtifactURL: nil)
        // v2 (T9): dreaming fires on the first due tick ONLY when the dreaming
        // queue has pending work. Seed one item so the REM-ALPHA gate opens.
        try await seedDreamingQueue(kit, handle)
        let report = await governor.tick(now: Date(timeIntervalSince1970: 1_000_000))
        #expect(report.dreamingFired)
        #expect(report.maintenanceFired)
    }

    @Test func dreamingRespectsCadence() async throws {
        let (kit, handle) = try await makeEstate()
        let governor = AutonomicGovernor(kit: kit, handle: handle, poolDirectory: nil, poolTableArtifactURL: nil)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        try await seedDreamingQueue(kit, handle)
        _ = await governor.tick(now: t0)                                  // first fires + drains
        let early = await governor.tick(now: t0.addingTimeInterval(29))   // < 30s default → cadence skip
        #expect(!early.dreamingFired)
        // Re-seed: the first tick drained the queue, so a fresh item is needed for
        // the due tick to have work AND pass the cadence gate.
        try await seedDreamingQueue(kit, handle)
        let due = await governor.tick(now: t0.addingTimeInterval(30))     // 30s + pending → fires
        #expect(due.dreamingFired)
    }

    @Test func signalTickBenignWhenNoSchedulerRegistered() async throws {
        let (kit, handle) = try await makeEstate()
        let governor = AutonomicGovernor(kit: kit, handle: handle, poolDirectory: nil, poolTableArtifactURL: nil)
        // No standing signal registered → signalTick throws schedulerNotStarted,
        // which the governor treats as a benign skip: tick returns normally with
        // signalsTicked == false, never throwing or spamming.
        let report = await governor.tick(now: Date(timeIntervalSince1970: 3_000_000))
        #expect(!report.signalsTicked)
    }

    // MARK: - § 4 — Graph analytics

    @Test func graphAnalyticsFiredOnFirstTick() async throws {
        let (kit, handle) = try await makeEstate()
        // graphAnalyticsIntervalMs: 0 → every tick fires immediately.
        let governor = AutonomicGovernor(kit: kit, handle: handle, graphAnalyticsIntervalMs: 0, poolDirectory: nil, poolTableArtifactURL: nil)
        let report = await governor.tick(now: Date(timeIntervalSince1970: 4_000_000))
        #expect(report.graphAnalyticsFired)
    }

    @Test func graphAnalyticsRespectsInterval() async throws {
        let (kit, handle) = try await makeEstate()
        // Default 10-minute interval — a second tick within the same second should NOT fire.
        let governor = AutonomicGovernor(kit: kit, handle: handle, poolDirectory: nil, poolTableArtifactURL: nil)
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        let first = await governor.tick(now: t0)
        #expect(first.graphAnalyticsFired)   // nil → true on first tick
        let immediate = await governor.tick(now: t0.addingTimeInterval(1))
        #expect(!immediate.graphAnalyticsFired)  // < 600 s → skipped
        let due = await governor.tick(now: t0.addingTimeInterval(600))
        #expect(due.graphAnalyticsFired)  // 600 s elapsed → fires
    }

    @Test func graphAnalyticsHandlerOnEmptyEstateCompletesWithoutError() async throws {
        // An estate with no drawers has no wings. The injected handler (the
        // CognitionKit-based Keystones + ConstellationLens closure) must return
        // without throwing when there are no wings — C-16: empty nodeIDs → empty
        // results, not an error. The handler is the injection seam that keeps
        // NeuronKit free of CognitionKit (CognitionKit imports NeuronKit, so the
        // reverse would invert the layer stack).
        let (kit, handle) = try await makeEstate()
        let handler: (@Sendable (GeniusLocusKit, EstateHandle, Date) async throws -> Void) = { kit, handle, now in
            let drawers = try await kit.allDrawers(in: handle)
            let activeDrawers = drawers.filter { $0.tombstonedAt == nil }
            let estate = try await kit.estate(for: handle)
            let nodeNames = try await estate.resolveNodeNames(parentNodeIds: activeDrawers.map(\.parentNodeId))
            let wings = Set(activeDrawers.compactMap { nodeNames[$0.parentNodeId]?.wing }).sorted()
            for wing in wings {
                // Thread `now` from the handler parameter so telemetry carries the correct timestamp.
                _ = try await Keystones.run(kit: kit, handle: handle, wing: wing, topK: 100, now: now)
                _ = try await ConstellationLens.run(kit: kit, handle: handle, wing: wing, now: now)
            }
        }
        try await handler(kit, handle, Date(timeIntervalSince1970: 6_000_000))
    }

    @Test func graphAnalyticsHandlerOnEstateWithWingCompletesWithoutError() async throws {
        // Capture a drawer so there is one wing. The injected handler must complete
        // without error: a wing with no tunnels yields empty Keystones / Constellation
        // results — not an error (C-16).
        let (kit, handle) = try await makeEstate()
        _ = try await kit.capture(handle, CaptureFrame(
            content: "test memory",
            channel: .typed,
            room: "room-a",
            latticeAnchor: .udc("004"),
            addedBy: "graph-analytics-test",
            embeddingModelID: "test-model-v1"))
        let handler: (@Sendable (GeniusLocusKit, EstateHandle, Date) async throws -> Void) = { kit, handle, now in
            let drawers = try await kit.allDrawers(in: handle)
            let activeDrawers = drawers.filter { $0.tombstonedAt == nil }
            let estate = try await kit.estate(for: handle)
            let nodeNames = try await estate.resolveNodeNames(parentNodeIds: activeDrawers.map(\.parentNodeId))
            let wings = Set(activeDrawers.compactMap { nodeNames[$0.parentNodeId]?.wing }).sorted()
            for wing in wings {
                // Thread `now` from the handler parameter so telemetry carries the correct timestamp.
                _ = try await Keystones.run(kit: kit, handle: handle, wing: wing, topK: 100, now: now)
                _ = try await ConstellationLens.run(kit: kit, handle: handle, wing: wing, now: now)
            }
        }
        try await handler(kit, handle, Date(timeIntervalSince1970: 7_000_000))
    }

    // MARK: - § 5 — Topology snapshot duty

    @Test func topologySnapshotFiredOnFirstTick() async throws {
        // topologyCadenceMs: 0 → fires on every tick.
        // topologyHandler captures calls; first tick must produce topologySnapshotFired = true.
        let (kit, handle) = try await makeEstate()
        let counter = CallCounter()
        let governor = AutonomicGovernor(
            kit: kit,
            handle: handle,
            topologyCadenceMs: 0,
            topologyHandler: { _, _, _, _ in await counter.increment() },
            poolDirectory: nil,
            poolTableArtifactURL: nil
        )
        let report = await governor.tick(now: Date(timeIntervalSince1970: 8_000_000))
        #expect(report.topologySnapshotFired)
    }

    @Test func topologySnapshotRespectsInterval() async throws {
        // Default 300 000 ms cadence — a second tick within the same second must NOT fire.
        let (kit, handle) = try await makeEstate()
        let governor = AutonomicGovernor(
            kit: kit,
            handle: handle,
            topologyCadenceMs: 300_000,
            topologyHandler: { _, _, _, _ in },
            poolDirectory: nil,
            poolTableArtifactURL: nil
        )
        let t0 = Date(timeIntervalSince1970: 9_000_000)
        let first = await governor.tick(now: t0)
        #expect(first.topologySnapshotFired)             // nil → fires immediately

        let early = await governor.tick(now: t0.addingTimeInterval(299))
        #expect(!early.topologySnapshotFired)            // 299 s < 300 s → skip

        let due = await governor.tick(now: t0.addingTimeInterval(300))
        #expect(due.topologySnapshotFired)               // 300 s elapsed → fires
    }

    @Test func topologySnapshotDutyProducesValidPayload() async throws {
        // Static duty called directly. With an empty estate the payload must be
        // decodable and carry structurePending = false and a non-empty generatedTs.
        let (kit, handle) = try await makeEstate()
        let now = Date(timeIntervalSince1970: 10_000_000)

        let capture = DataCapture()
        _ = try await AutonomicGovernor.topologySnapshotDuty(
            kit: kit,
            handle: handle,
            now: now
        ) { _, _, data, _ in await capture.set(data) }

        let data = try #require(await capture.value, "handler must be called with non-nil data")
        // Decode just enough to verify the wire shape.
        let decoded = try JSONDecoder().decode(TopologySnapshotWireShape.self, from: data)
        #expect(!decoded.structurePending)
        #expect(!decoded.generatedTs.isEmpty)
    }

    @Test func topologySnapshotMapsClassificationEdgesToPublicWireType() async throws {
        let (kit, handle) = try await makeEstate()
        for content in ["classification-edge-alpha", "classification-edge-beta"] {
            _ = try await kit.capture(handle, CaptureFrame(
                content: content, channel: .typed, room: "gov-test",
                latticeAnchor: .udc("362.4"),
                addedBy: "test", embeddingModelID: "test-model-v1"))
        }
        let capture = DataCapture()
        _ = try await AutonomicGovernor.topologySnapshotDuty(
            kit: kit, handle: handle,
            now: Date(timeIntervalSince1970: 10_000_100)
        ) { _, _, data, _ in await capture.set(data) }

        let data = try #require(await capture.value)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let edges = try #require(body["edges"] as? [[String: Any]])
        let edgeTypes = edges.compactMap { $0["edgeType"] as? String }
        #expect(edgeTypes.contains("nmf_bond"))
        #expect(!edgeTypes.contains("lattice"))
    }

    @Test func topologySnapshotDutyIsPayloadDeterministic() async throws {
        // Same estate + same now must produce byte-identical JSON payloads.
        // This verifies that no internal clock or UUID is embedded in the encoding.
        let (kit, handle) = try await makeEstate()
        let now = Date(timeIntervalSince1970: 11_000_000)

        let capture1 = DataCapture()
        let capture2 = DataCapture()

        _ = try await AutonomicGovernor.topologySnapshotDuty(kit: kit, handle: handle, now: now) {
            _, _, d, _ in await capture1.set(d)
        }
        _ = try await AutonomicGovernor.topologySnapshotDuty(kit: kit, handle: handle, now: now) {
            _, _, d, _ in await capture2.set(d)
        }

        let a = try #require(await capture1.value)
        let b = try #require(await capture2.value)
        #expect(a == b, "Same estate + same now must produce byte-identical payload")
    }

    @Test func topologySnapshotDutySkipsWhenInputUnchanged() async throws {
        // Dirty token: an unchanged estate between cadences must skip the
        // compute/encode/write — the handler fires once, not twice — and the
        // second call returns a token equal to the first.
        let (kit, handle) = try await makeEstate()
        let counter = CallCounter()
        let snapshotLoads = CallCounter()

        let token1 = try await AutonomicGovernor.topologySnapshotDuty(
            kit: kit, handle: handle, now: Date(timeIntervalSince1970: 12_000_000)
        ) { _, _, _, _ in await counter.increment() }
        let token2 = try await AutonomicGovernor.topologySnapshotDuty(
            kit: kit, handle: handle, now: Date(timeIntervalSince1970: 12_000_300),
            previousFingerprint: token1.fingerprint,
            previousSnapshotLoader: {
                await snapshotLoads.increment()
                return nil
            }
        ) { _, _, _, _ in await counter.increment() }

        #expect(token1 == token2, "Unchanged estate must yield an identical dirty token")
        #expect(await counter.count == 1, "Handler must not fire on the skipped cadence")
        #expect(await snapshotLoads.count == 0, "Skipped cadence must not load the prior snapshot")
    }

    @Test func topologySnapshotDutyRecomputesWhenEstateChanges() async throws {
        // A capture between cadences changes the dirty token and re-fires
        // the handler.
        let (kit, handle) = try await makeEstate()
        let counter = CallCounter()

        let token1 = try await AutonomicGovernor.topologySnapshotDuty(
            kit: kit, handle: handle, now: Date(timeIntervalSince1970: 13_000_000)
        ) { _, _, _, _ in await counter.increment() }

        _ = try await kit.capture(handle, CaptureFrame(
            content: "dirty-check wake", channel: .typed, room: "gov-test",
            latticeAnchor: .udc("510"),
            addedBy: "test", embeddingModelID: "test-model-v1"))

        let token2 = try await AutonomicGovernor.topologySnapshotDuty(
            kit: kit, handle: handle, now: Date(timeIntervalSince1970: 13_000_300),
            previousFingerprint: token1.fingerprint
        ) { _, _, _, _ in await counter.increment() }

        #expect(token1 != token2, "A new capture must change the dirty token")
        #expect(await counter.count == 2, "Handler must re-fire after an estate change")
    }

    @Test func topologyPayloadExcludesTokenFieldsButFingerprintIsDelivered() async throws {
        // F5: the duty now delivers a stable topology fingerprint as the handler's
        // 4th argument so the host persists it beside the snapshot (enabling the
        // post-restart skip). Two things must hold:
        //   1. The fingerprint IS delivered (non-empty, equals the returned token's
        //      fingerprint) — the host needs it to persist.
        //   2. The fingerprint and its inputs digest are NOT embedded in the served
        //      payload JSON (3rd arg) — /api/graph serves the snapshot wire shape
        //      verbatim, which carries no token fields.
        let (kit, handle) = try await makeEstate()
        // Non-empty estate so the order-independent inputs digest is a large,
        // stable value (an empty estate digests to 0, which would trivially appear
        // in any payload — a false positive).
        _ = try await kit.capture(handle, CaptureFrame(
            content: "fingerprint-delivery probe", channel: .typed, room: "gov-test",
            latticeAnchor: .udc("510"),
            addedBy: "test", embeddingModelID: "test-model-v1"))
        let sink = DataCapture()
        let fingerprintSink = StringCapture()

        let token = try await AutonomicGovernor.topologySnapshotDuty(
            kit: kit, handle: handle, now: Date(timeIntervalSince1970: 15_000_000)
        ) { _, _, data, fingerprint in
            await sink.set(data)
            await fingerprintSink.set(fingerprint)
        }

        // The digest must be non-trivial for the substring check to be meaningful.
        #expect(token.inputsDigest != 0, "Probe estate must produce a non-trivial inputs digest")

        // (1) The fingerprint is delivered for persistence.
        let deliveredFingerprint = try #require(await fingerprintSink.value)
        #expect(!deliveredFingerprint.isEmpty, "Handler must receive a non-empty fingerprint")
        #expect(deliveredFingerprint == token.fingerprint,
                "Delivered fingerprint must equal the returned token's fingerprint")

        // (2) The served payload is the topology wire shape only — no token fields.
        let body = try #require(await sink.value)
        let json = String(decoding: body, as: UTF8.self)
        #expect(!json.contains("inputsDigest"), "Token field name must not appear in served payload")
        #expect(!json.contains("\(token.inputsDigest)"),
                "Inputs digest must never be written into the served payload JSON")
        #expect(!json.contains(deliveredFingerprint),
                "Fingerprint must travel as a separate column, not embedded in the payload JSON")
        // What SHOULD be in the payload: the topology wire shape.
        #expect(json.contains("structurePending"), "Served payload must be the topology snapshot")
    }

    @Test func topologyGateFalseSkipsTheDuty() async throws {
        // Gate (the live monitoring flag) returning false must skip the duty
        // entirely — the handler never fires even at a due cadence.
        let (kit, handle) = try await makeEstate()
        let counter = CallCounter()
        let governor = AutonomicGovernor(
            kit: kit, handle: handle, baseTickMs: 0,
            topologyCadenceMs: 0,
            topologyHandler: { _, _, _, _ in await counter.increment() },
            topologyGate: { false },
            poolDirectory: nil,
            poolTableArtifactURL: nil,
            clock: { Date(timeIntervalSince1970: 14_000_000) })
        _ = await governor.tick(now: Date(timeIntervalSince1970: 14_000_000))
        // The duty runs in a detached Task; give it a bounded window to
        // (incorrectly) fire before asserting it did not.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await counter.count == 0, "Gate false must skip the topology duty")
    }

    @Test func topologyRestartLoadsFingerprintAndSkipsRecompute() async throws {
        // F5: a FRESH governor (simulating a process restart) loads the persisted
        // fingerprint on its first duty and skips the recompute when the estate is
        // unchanged. Proves the persist→load→skip chain holds across the governor's
        // in-memory state boundary. Mirrors Rust `ag15c`.
        let (kit, handle) = try await makeEstate()
        // Non-empty estate so the fingerprint is a meaningful, stable value.
        _ = try await kit.capture(handle, CaptureFrame(
            content: "restart-skip probe", channel: .typed, room: "gov-test",
            latticeAnchor: .udc("510"),
            addedBy: "test", embeddingModelID: "test-model-v1"))

        // Shared "disk" across both governor lifetimes: persisted fingerprint +
        // a write counter standing in for the snapshot generatedTs advancing.
        let disk = FingerprintStore()
        let handler: @Sendable (String, Date, Data, String) async -> Void = { _, _, _, fp in
            await disk.persist(fp)
        }
        let loader: @Sendable () async -> String? = { await disk.load() }

        // First "process": governor computes and persists the fingerprint.
        let governor1 = AutonomicGovernor(
            kit: kit, handle: handle, topologyCadenceMs: 0,
            topologyHandler: handler, topologyFingerprintLoader: loader,
            poolDirectory: nil, poolTableArtifactURL: nil)
        _ = await governor1.tick(now: Date(timeIntervalSince1970: 16_000_000))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await disk.writeCount == 1, "First governor must persist one snapshot")

        // Second "process": a brand-new governor (no in-memory fingerprint) on the
        // same disk + unchanged estate. Its first duty loads the persisted
        // fingerprint, finds it matches, and skips the write.
        let governor2 = AutonomicGovernor(
            kit: kit, handle: handle, topologyCadenceMs: 0,
            topologyHandler: handler, topologyFingerprintLoader: loader,
            poolDirectory: nil, poolTableArtifactURL: nil)
        _ = await governor2.tick(now: Date(timeIntervalSince1970: 16_000_600))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await disk.writeCount == 1,
                "Restart with unchanged estate must skip recompute (loaded fingerprint matched)")
    }

    // MARK: - § Autonomic-loop activation (OP-3)

    /// Force-test (A): once a scheduler is registered for the live estate, a
    /// governor tick drives the standing-signal scheduler — `signalsTicked` is
    /// true (schedulerNotStarted no longer fires on the live path) and the
    /// scheduler actually ran the registered signals (their `lastRunAt` is set).
    @Test func registeredSchedulerMakesSignalTickFireOnLivePath() async throws {
        let (kit, handle) = try await makeEstate()
        // Wire a VectorStore (resident mode always has one) and register the
        // architecture-spec §11.2 default standing signals — the bootstrap step
        // runResidentDaemon now performs.
        let vectorStore = VectorStore(storage: InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)))
        await kit.registerVectorStore(vectorStore, for: handle)
        let ids = try await kit.registerDefaultStandingSignals(
            in: handle, vectorStore: vectorStore, now: Date(timeIntervalSince1970: 1))

        let governor = AutonomicGovernor(kit: kit, handle: handle, poolDirectory: nil, poolTableArtifactURL: nil)
        let report = await governor.tick(now: Date(timeIntervalSince1970: 20_000_000))

        // The live path no longer benign-skips: signalsTicked is true.
        #expect(report.signalsTicked, "signalTick must succeed once a scheduler is registered")
        #expect(ids.count == GeniusLocusKit.defaultStandingSignalNames.count)
        // Every interval signal is due on first evaluation (no prior run), so the
        // scheduler ran them — lastRunAt is set on at least one.
        let reports = try await kit.signalStatus(in: handle)
        #expect(reports.contains { $0.lastRunAt != nil },
                "the scheduler must have run the registered signals on the tick")
    }

    /// Force-test (A, continued): a propose/associate emission dispatched by the
    /// scheduler on a governor tick is queryable afterward through signalStatus.
    /// Uses a custom diagnostic-emitting signal for a deterministic, estate-data-
    /// independent emission (the production propose/associate signals emit only
    /// when their estate scan finds candidates).
    @Test func governorTickDrivesQueryableEmission() async throws {
        let (kit, handle) = try await makeEstate()
        let emittingSpec = SignalSpec(
            name: "op3-emission-probe",
            trigger: .interval(seconds: 30),
            emit: { ctx in
                [.diagnostic(DiagnosticReport(
                    title: "op3.probe",
                    detail: "emission proof",
                    observedAt: ctx.now))]
            })
        _ = try await kit.registerStandingSignal(emittingSpec, in: handle, now: Date(timeIntervalSince1970: 1))

        let governor = AutonomicGovernor(kit: kit, handle: handle, poolDirectory: nil, poolTableArtifactURL: nil)
        let report = await governor.tick(now: Date(timeIntervalSince1970: 21_000_000))
        #expect(report.signalsTicked)

        let reports = try await kit.signalStatus(in: handle)
        let probe = reports.first { $0.name == "op3-emission-probe" }
        #expect(probe != nil)
        // The emission was applied and recorded — queryable after the tick.
        #expect((probe?.emissionCount ?? 0) >= 1,
                "the tick must drive a real, queryable emission")
        #expect(probe?.recentDiagnostics.isEmpty == false)
    }

    /// Force-test (B): the PoolReducer trigger fires on its cadence and is no-op
    /// safe on an empty pool, and idempotent on a re-run. Drives `tick` against a
    /// temp pool dir + writable table artifact.
    @Test func poolReducerTriggerFiresAndIsNoOpSafe() async throws {
        let (kit, handle) = try await makeEstate()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("op3-pool-\(UUID().uuidString)", isDirectory: true)
        let poolDir = tmp.appendingPathComponent("pool", isDirectory: true)
        try FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
        let tableURL = tmp.appendingPathComponent("WordClassTable.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed a minimal writable table the reducer merges into.
        let seedTable = """
        {"table_version":"1.0.0","min_os_version":"17.0","snapshot_date":"2026-01-01","nouns":["dog"],"verbs":["run"]}
        """.data(using: .utf8)!
        try seedTable.write(to: tableURL)

        // Cadence 0 → fires every tick. Empty pool → no-op (idempotent contract).
        let governor = AutonomicGovernor(
            kit: kit, handle: handle, poolReduceCadenceMs: 0,
            poolDirectory: poolDir, poolTableArtifactURL: tableURL)
        let r1 = await governor.tick(now: Date(timeIntervalSince1970: 22_000_000))
        #expect(r1.poolReduceFired, "pool reduce must fire on cadence 0")

        // Now seed a novel-token submission and reduce again: the token merges
        // into the writable artifact. This test asserts the MERGE (the artifact
        // contains the token + idempotence); the in-session LIVE-SWAP that makes
        // the running tagger classify it without a restart is proven separately
        // in inSessionLearningViaGovernorReduceAndSwap.
        let submission = """
        {"table_version":"1.0.0","platform":"test","tagger_version":"1","entries":[{"token":"flumph","tag":"NOUN"}]}
        """.data(using: .utf8)!
        try submission.write(to: poolDir.appendingPathComponent("pool_0001.json"))
        let r2 = await governor.tick(now: Date(timeIntervalSince1970: 22_000_001))
        #expect(r2.poolReduceFired)

        // The writable artifact now contains the merged token (a fresh load would
        // classify it as a NOUN). Idempotent: a third tick with the drained pool
        // changes nothing further.
        let merged = try JSONDecoder().decode(WordClassTableShape.self,
                                              from: Data(contentsOf: tableURL))
        #expect(merged.nouns.contains("flumph"),
                "reduce must merge the novel token into the writable table")
        let r3 = await governor.tick(now: Date(timeIntervalSince1970: 22_000_002))
        #expect(r3.poolReduceFired)
        let afterDrain = try JSONDecoder().decode(WordClassTableShape.self,
                                                  from: Data(contentsOf: tableURL))
        #expect(afterDrain.nouns.sorted() == merged.nouns.sorted(),
                "re-run on a drained pool must be idempotent")
    }

    /// Force-test (B): the trigger respects its cadence — it does NOT fire again
    /// before the cadence elapses.
    @Test func poolReducerTriggerNearRealtimeAndThrottle() async throws {
        let (kit, handle) = try await makeEstate()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("op3-pool-cad-\(UUID().uuidString)", isDirectory: true)
        let poolDir = tmp.appendingPathComponent("pool", isDirectory: true)
        try FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
        let tableURL = tmp.appendingPathComponent("WordClassTable.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // NEAR-REALTIME default (cadence 0): the reduce is considered on EVERY
        // tick — it does NOT wait an hour. This is the cookbook §2.2 rewrite:
        // the reduce latency floor is the base tick, not a fixed cadence.
        let nearRealtime = AutonomicGovernor(
            kit: kit, handle: handle,
            poolDirectory: poolDir, poolTableArtifactURL: tableURL)
        let t0 = Date(timeIntervalSince1970: 23_000_000)
        #expect(await nearRealtime.tick(now: t0).poolReduceFired)
        // A tick only 1 s later STILL fires (near-realtime), unlike the old
        // hourly contract where an early tick was suppressed.
        #expect(await nearRealtime.tick(now: t0.addingTimeInterval(1)).poolReduceFired,
                "near-realtime: the reduce fires every tick, not once an hour")

        // A positive MOOTX01_POOL_REDUCE_CADENCE_SECONDS reinstates a minimum
        // spacing (test determinism / load throttling): fire, then suppress an
        // early tick, then fire once the spacing elapses.
        let throttled = AutonomicGovernor(
            kit: kit, handle: handle, poolReduceCadenceMs: 3_600_000,
            poolDirectory: poolDir, poolTableArtifactURL: tableURL)
        #expect(await throttled.tick(now: t0).poolReduceFired)
        let early = await throttled.tick(now: t0.addingTimeInterval(30))
        #expect(!early.poolReduceFired, "throttled: must not re-fire before the spacing elapses")
        let due = await throttled.tick(now: t0.addingTimeInterval(3600))
        #expect(due.poolReduceFired, "throttled: must fire once the spacing has elapsed")
    }

    /// Force-test (C): the tick stays within budget — even with both loops active
    /// (standing signals registered + pool reduce firing) a single tick completes
    /// promptly (no runaway/perf regression).
    @Test func tickCompletesPromptlyWithBothLoopsActive() async throws {
        let (kit, handle) = try await makeEstate()
        let vectorStore = VectorStore(storage: InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)))
        await kit.registerVectorStore(vectorStore, for: handle)
        _ = try await kit.registerDefaultStandingSignals(
            in: handle, vectorStore: vectorStore, now: Date(timeIntervalSince1970: 1))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("op3-pool-budget-\(UUID().uuidString)", isDirectory: true)
        let poolDir = tmp.appendingPathComponent("pool", isDirectory: true)
        try FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
        let tableURL = tmp.appendingPathComponent("WordClassTable.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let governor = AutonomicGovernor(
            kit: kit, handle: handle, graphAnalyticsIntervalMs: 0, poolReduceCadenceMs: 0,
            poolDirectory: poolDir, poolTableArtifactURL: tableURL)
        let start = Date()
        _ = await governor.tick(now: Date(timeIntervalSince1970: 24_000_000))
        let elapsed = Date().timeIntervalSince(start)
        // Generous ceiling — the tick's synchronous work (pumps + cadence-gated
        // reduce on an empty pool) is sub-second; 5 s catches a runaway only.
        #expect(elapsed < 5.0, "a governor tick must complete promptly (was \(elapsed)s)")
    }

    /// IN-SESSION LEARNING (the proof that matters): in ONE running process, a
    /// novel-token pool submission is reduced near-realtime on a governor tick,
    /// the running word-class table is LIVE-SWAPPED at the post-reduce safe
    /// point, and the SAME live tagger then classifies the novel token from the
    /// table — WITHOUT a process restart. Distinct from the cross-reload
    /// foundation test.
    @Test func inSessionLearningViaGovernorReduceAndSwap() async throws {
        let (kit, handle) = try await makeEstate()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("op3-insession-\(UUID().uuidString)", isDirectory: true)
        let poolDir = tmp.appendingPathComponent("pool", isDirectory: true)
        try FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
        let tableURL = tmp.appendingPathComponent("WordClassTable.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A digit-bearing novel token: the live tagger returns .other for it
        // before learning (not in the table; HMM/Apple does not tag a
        // digit-bearing token as a noun). Using the bundled table_version so the
        // reducer accepts the submission.
        let bundled = try #require(WordClassTable.loadBundled())
        let novel = "zq8xlexeme"
        #expect(LatticeLib.wordClass(novel) != .noun,
                "precondition: the novel token must not be a table noun before learning")

        // Seed the writable artifact from the bundled table so the reducer merges
        // into a valid base, then drop a novel-token submission into the pool.
        let seed = WordClassTable(
            tableVersion: bundled.tableVersion, minOSVersion: bundled.minOSVersion,
            snapshotDate: bundled.snapshotDate, nouns: bundled.nouns, verbs: bundled.verbs)
        try JSONEncoder().encode(seed).write(to: tableURL)
        let submission = PoolSubmission(
            tableVersion: bundled.tableVersion, platform: "test", taggerVersion: "1",
            entries: [PoolEntry(token: novel, tag: "NOUN")])
        try JSONEncoder().encode(submission).write(
            to: poolDir.appendingPathComponent("pool_insession.json"))

        // Near-realtime reduce (cadence 0) + live swap on the tick.
        let governor = AutonomicGovernor(
            kit: kit, handle: handle, poolReduceCadenceMs: 0,
            poolDirectory: poolDir, poolTableArtifactURL: tableURL)
        let versionBefore = WordClassTableCache.version
        let report = await governor.tick(now: Date(timeIntervalSince1970: 25_000_000))

        #expect(report.poolReduceFired)
        #expect(report.tableSwapped, "a non-noop reduce must live-swap the running table")
        #expect(report.tableVersion == versionBefore + 1, "the live swap must advance the version")

        // THE PROOF: the SAME live tagger now classifies the token from the
        // table — learned in-session, no restart.
        #expect(LatticeLib.wordClass(novel) == .noun,
                "in-session: the running tagger must classify the merged token from the live-swapped table")

        // Restore the bundled seed so other suites see a clean table.
        WordClassTableCache.swap(WordClassTable.loadBundled())
    }
}

// MARK: - Test helper types

/// Minimal decoder for the writable WordClassTable artifact (force-test B).
private struct WordClassTableShape: Decodable {
    let nouns: [String]
    let verbs: [String]
}

/// Minimal wire shape decoder for topology snapshot payload tests.
private struct TopologySnapshotWireShape: Decodable {
    let structurePending: Bool
    let generatedTs: String
}

/// Actor-isolated call counter. Thread-safe capture for @Sendable handler closures.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Actor-isolated data capture. Thread-safe for @Sendable handler closures.
private actor DataCapture {
    private(set) var value: Data? = nil
    func set(_ data: Data) { value = data }
}

/// Actor-isolated string capture. Thread-safe for @Sendable handler closures.
/// Captures the topology fingerprint delivered as the handler's 4th argument.
private actor StringCapture {
    private(set) var value: String? = nil
    func set(_ s: String) { value = s }
}

/// Actor-isolated stand-in for the persisted topology fingerprint "disk" (F5).
/// `persist` mirrors the StatsStore write (counts writes so a skip is observable);
/// `load` mirrors the one-shot fingerprint loader a restarting governor calls.
private actor FingerprintStore {
    private(set) var value: String? = nil
    private(set) var writeCount = 0
    func persist(_ fp: String) { value = fp; writeCount += 1 }
    func load() -> String? { value }
}
