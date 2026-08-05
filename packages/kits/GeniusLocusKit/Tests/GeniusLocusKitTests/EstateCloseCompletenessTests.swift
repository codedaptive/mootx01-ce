// EstateCloseCompletenessTests.swift
//
// Estate-close registry completeness — Swift twin of
// `rust/tests/estate_close_completeness.rs`.
//
// Three jobs, in order of how durable they are.
//
// 1. REGRESSION. `reopenDoesNotResurrectSubjectProducer` is the regression test
//    for Codex finding `6ed2ab30948481919f147fae496f55b1`. It fails against
//    pre-fix code: `close` did not clear `subjectProducers`, and an
//    `EstateHandle` is equal across reopens of the same estate (its
//    `estateUUID` comes from the manifest, so estate identity belongs to the
//    substrate rather than to the open), so reopening resolved the stale
//    producer, rendered the `subject_backfill` drain lane as live, and let
//    `subjectBackfillSweep` — which authorises on map presence alone — hand
//    full `drawer.content` to a producer nobody had re-registered.
//
// 2. COMPLETENESS. `closeClearsEveryPerEstateRegistry` asserts that NO
//    per-estate registry holds an entry for the handle after close. It is
//    structural: `residentRegistries(for:)` reflects over the actor's stored
//    properties and selects `[EstateHandle: …]` dictionaries, so a registry
//    added in a later mission is covered with no edit to this file. The
//    generalisable defect was never the one missing line — it was that nothing
//    enforced close-path completeness, so every registry added since had been
//    one act of memory away from leaking. Four had.
//
// 3. PATH SYMMETRY. `errorCloseClearsTheSameRegistriesAsSuccessClose` compares
//    the two close paths at source level. See its own comment for why it is a
//    source scan and not a runtime test: the error path is currently
//    unreachable at runtime, and a runtime test for it would assert nothing.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// MARK: - Fixtures

/// Deterministic stub: derives a valid register subject from the content's
/// first line. Output text is a fixture, never a model claim.
private struct StubProducer: SubjectProducer {
    let pipelineVersion = "close-completeness-stub-v1"
    func subject(forContent content: String) async throws -> String {
        String(content.split(separator: "\n").first.map(String.init)!.prefix(120))
    }
}

/// Constant-score accelerator stubs. The values are irrelevant — these exist
/// only so the registries are non-empty before close.
private struct StubGraphCache: GraphCache {
    func graphScore(for drawerID: String) -> Float { 0.5 }
}

private struct StubPreferenceStore: PreferenceStore {
    func preferenceScore(for drawerID: String) -> Float { 0.25 }
}

@Suite("Estate close — per-estate registry completeness", .serialized)
struct EstateCloseCompletenessTests {

    /// Fixed epoch so nothing in the suite reads a wall clock (determinism I-6).
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Create an estate over a storage the caller keeps, so the SAME backing
    /// storage can be reopened into the SAME kit after close.
    ///
    /// Both halves of that matter. The kit must be the same instance because
    /// the stale entry lives on the kit's registries — a test that mints a
    /// fresh `GeniusLocusKit` for the second open throws the evidence away and
    /// passes against pre-fix code. The storage must be the same because the
    /// manifest is what carries `estateUUID`, and an equal handle is the
    /// precondition for the whole finding.
    private func makeEstate(
        owner: String
    ) async throws -> (GeniusLocusKit, any Storage, OwnerCredentials) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let creds = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: creds)
        return (kit, storage, creds)
    }

    private func open(
        _ kit: GeniusLocusKit, _ storage: any Storage, _ creds: OwnerCredentials
    ) async throws -> EstateHandle {
        try await kit.open(
            storage: storage, owner: creds,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    private func seedDebt(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, count: Int
    ) async throws {
        for i in 1...count {
            let frame = CaptureFrame(
                content: "Debt row number \(i) awaiting a subject.",
                channel: .typed,
                room: "close-completeness",
                latticeAnchor: LatticeAnchor(udcCode: "000"),
                addedBy: "close-completeness-tests",
                embeddingModelID: "test-model-v1")
            _ = try await kit.capture(handle, frame)
        }
    }

    // MARK: - 1. Regression: the reported finding

    @Test("reopen does not resurrect the subject producer")
    func reopenDoesNotResurrectSubjectProducer() async throws {
        let (kit, storage, creds) = try await makeEstate(owner: "reopen-rider")
        let handle = try await open(kit, storage, creds)
        try await seedDebt(kit, handle, count: 3)

        // Register the rider; the lane goes live for this open.
        try await kit.registerSubjectProducer(StubProducer(), for: handle)
        #expect(await kit.subjectProducerPipeline(for: handle)
                == "close-completeness-stub-v1",
                "precondition: the rider must be registered before close")

        try await kit.close(handle)

        // Reopen the same storage into the same kit. The handle is equal
        // across reopens by design — that stability is load-bearing and is NOT
        // what this mission changes.
        let reopened = try await open(kit, storage, creds)
        #expect(reopened == handle,
                "precondition for the whole finding: handles are equal across reopens")

        // The rider must be gone. Pre-fix this returned the stub's version.
        #expect(await kit.subjectProducerPipeline(for: reopened) == nil,
                "close must not leave a subject producer resolvable on the reopened handle")

        // The sweep refuses rather than handing drawer content to a producer
        // the caller never re-registered.
        await #expect(throws: GeniusLocusKitError.self) {
            _ = try await kit.subjectBackfillSweep(reopened, now: t0)
        }

        // And the drain lane is dark again — barrier safety: the benchmarker
        // gates unknown lanes, so a lane rendering as live is itself the damage.
        let drains = try await kit.drainStatuses(reopened)
        #expect(!drains.contains { $0.name == DrainStatus.subjectBackfillName },
                "subject_backfill lane must be dark on the reopened handle: \(drains)")

        try await kit.close(reopened)
    }

    // MARK: - 2. Durable: close-path completeness

    @Test("close clears every per-estate registry for the handle")
    func closeClearsEveryPerEstateRegistry() async throws {
        let (kit, storage, creds) = try await makeEstate(owner: "completeness")
        let handle = try await open(kit, storage, creds)

        // Guard the reflection scanner itself. If the stored-property shape
        // ever drifts far enough that reflection finds nothing, the emptiness
        // assertion below would pass vacuously and the enforcement would be
        // silently gone. 22 registries are declared as of this mission.
        let declared = await kit.declaredRegistryNames()
        let driftMessage = """
            reflection found only \(declared.count) per-estate registries — the \
            audit has drifted from the declaration block: \(declared)
            """
        #expect(declared.count >= 22, Comment(rawValue: driftMessage))

        // Populate every registry this test can reach through public API.
        // `open` itself has already populated registry, storages, mountStates.
        try await kit.registerSubjectProducer(StubProducer(), for: handle)
        await kit.registerGraphCache(StubGraphCache(), for: handle)
        await kit.registerPreferenceStore(StubPreferenceStore(), for: handle)
        await kit.registerDistillationFunction(
            GeniusLocusKit.defaultDistillFn, for: handle)
        // Minting the standing-signal scheduler is what populates `schedulers`.
        _ = try await kit.registerStandingSignal(
            SignalSpec(
                name: "close-completeness-signal",
                trigger: .interval(seconds: 30),
                emit: { _ in [] }),
            in: handle,
            now: t0)

        let residentBefore = await kit.residentRegistries(for: handle)
        // The four this mission closed, plus the three `open` populates.
        for expected in ["subjectProducers", "schedulers", "graphCaches",
                         "preferenceStores", "registry", "storages", "mountStates"] {
            let message = """
                precondition: \(expected) must hold an entry before close — \
                resident: \(residentBefore)
                """
            #expect(residentBefore.contains(expected), Comment(rawValue: message))
        }

        try await kit.close(handle)

        let residentAfter = await kit.residentRegistries(for: handle)
        let leakMessage = """
            close left \(residentAfter.count) per-estate registries holding an entry \
            for the handle: \(residentAfter).
            Handles are equal across reopens, so anything left here resolves on the \
            NEXT open of this estate as state the caller never registered. Clear it \
            in BOTH close paths in EstateCoordinator.swift, teardown-ordered if the \
            value owns a worker, a lease, or a connection.
            """
        #expect(residentAfter.isEmpty, Comment(rawValue: leakMessage))
    }

    // MARK: - 3. Path symmetry: the error close path

    /// `close`'s error path must clear exactly what its success path clears.
    ///
    /// This is a source comparison rather than a runtime test, deliberately.
    /// The error path runs only when `try await estate.close()` throws, and
    /// `LocusKit.Estate.close()` is an intentional no-op that cannot throw
    /// (`LocusKit/Sources/LocusKit/Estate.swift:436`). So there is no way to
    /// drive the error path at runtime today, and a runtime test for it would
    /// assert nothing while looking like coverage.
    ///
    /// The drift this DOES catch is the realistic one: a later mission adds a
    /// registry clear to the success path and forgets the error path. That
    /// matters because a close which fails partway is exactly when a stale
    /// producer is most likely to be reused.
    @Test("error close path clears the same registries as the success path")
    func errorCloseClearsTheSameRegistriesAsSuccessClose() throws {
        let source = try String(
            contentsOf: Self.estateCoordinatorURL, encoding: .utf8)

        // The error path is the `catch` block inside `close`; the success path
        // is everything after it up to the storage release. Slice on the two
        // landmarks that bracket them.
        guard let closeStart = source.range(of: "func close(_ handle: EstateHandle) async throws"),
              let catchStart = source.range(
                of: "} catch {", range: closeStart.upperBound..<source.endIndex),
              let throwPoint = source.range(
                of: "throw GeniusLocusKitError.underlyingEstateFailure",
                range: catchStart.upperBound..<source.endIndex),
              let successEnd = source.range(
                of: "Self.log.info(\"closed estate",
                range: throwPoint.upperBound..<source.endIndex)
        else {
            Issue.record("close's shape changed — update this test's landmarks")
            return
        }

        let errorPath = String(source[catchStart.upperBound..<throwPoint.lowerBound])
        let successPath = String(source[throwPoint.upperBound..<successEnd.lowerBound])

        /// Registry names cleared by `<name>[handle] = nil` in a block.
        func cleared(in block: String) -> Set<String> {
            Set(block.split(separator: "\n").compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"),
                      let bracket = trimmed.range(of: "[handle] = nil")
                else { return nil }
                let name = String(trimmed[trimmed.startIndex..<bracket.lowerBound])
                return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
                    && !name.isEmpty ? name : nil
            })
        }

        let errorCleared = cleared(in: errorPath)
        let successCleared = cleared(in: successPath)

        // Guard the scanner: if the slicing drifts, both sets go empty and the
        // symmetry assertion would pass vacuously.
        let scanDriftMessage = """
            the source scan found only \(successCleared.count) clears in the success \
            path — the scanner has drifted: \(successCleared.sorted())
            """
        #expect(successCleared.count >= 18, Comment(rawValue: scanDriftMessage))

        let successOnly = successCleared.subtracting(errorCleared).sorted()
        let errorOnly = errorCleared.subtracting(successCleared).sorted()
        let asymmetryMessage = """
            the two close paths clear different registry sets.
            Only in the success path: \(successOnly)
            Only in the error path: \(errorOnly)
            A close that fails partway is exactly when a stale entry is most likely \
            to be reused — both paths get every clear.
            """
        #expect(errorCleared == successCleared, Comment(rawValue: asymmetryMessage))
    }

    /// `EstateCoordinator.swift`, located relative to this test file so the
    /// scan does not depend on the working directory the suite runs from.
    private static var estateCoordinatorURL: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/GeniusLocusKitTests/<this file>
            .deletingLastPathComponent()          // …/Tests/GeniusLocusKitTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/GeniusLocusKit
            .appendingPathComponent("Sources/GeniusLocusKit/EstateCoordinator.swift")
    }
}
