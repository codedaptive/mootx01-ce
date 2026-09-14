// SensitivityCeilingTests.swift
//
// Security-boundary tests for GLK-CEILING.
//
// GeniusLocusKit imposes a sensitivity ceiling at .elevated: write verbs
// that resolve a target row must refuse .restricted/.secret targets and
// produce an error indistinguishable from what an absent-row target would
// produce, providing no existence oracle to the caller.
//
// These tests pin that guarantee for both affected write verbs:
//
//   P1 — expunge refuses a .restricted target with the absent-row error.
//        The row must survive unchanged after the refusal.
//   P2 — retireKGFact refuses a fact whose own adjectiveSensitivity is
//        .restricted (inherited from its .restricted source drawer via
//        captureKGFact's adjective-bitmap copy) with the absent-fact error.
//        The fact must survive active after the refusal.

import Testing
import Foundation
import LocusKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("Sensitivity ceiling — write verbs refuse above-ceiling targets")
struct SensitivityCeilingTests {

    // MARK: - Scaffolding

    /// Open a single LocusKit estate registered with GeniusLocusKit. KGFact
    /// operations are wired lazily by ensureKGStore on first use.
    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-sensitivity-ceiling-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Fixed timestamp shared across tests — 2026-01-01T00:00:00Z.
    private var testNow: Date { Date(timeIntervalSince1970: 1_735_689_600) }

    // MARK: - P1: expunge refuses .restricted target

    /// Expunge must refuse a .restricted target with the same error a
    /// genuinely missing row produces. No existence oracle is provided to the
    /// caller: the ceiling and absent-row paths both route through remap with
    /// LocusKitError.drawerNotFound, so the only observable difference is the
    /// row id. The row must remain in storage — non-tombstoned, content
    /// byte-identical — after the refusal.
    @Test
    func expungeRefusesRestrictedTargetWithAbsentRowError() async throws {
        let (kit, handle) = try await openOneEstate()

        // Seed a .restricted drawer: above the .elevated ceiling.
        var frame = CaptureFrame(
            content: "restricted drawer that must not be erasable by an .elevated caller",
            channel: .typed,
            room: "ceiling-tests",
            latticeAnchor: .udc("000"),
            addedBy: "sensitivity-ceiling-tests",
            embeddingModelID: "test-model-v1"
        )
        frame.sensitivity = .restricted
        let drawer = try await kit.capture(handle, frame)

        // Observe the absent-row error from a row that genuinely does not exist.
        // The ceiling and absent-row paths both route through remap, so this is
        // the ground truth: the ceiling error must be the same after id substitution.
        let absentID = UUID().uuidString
        var absentErrorRaw: Error?
        do {
            _ = try await kit.expunge(
                handle,
                ExpungeFrame(rowID: absentID, reason: "absent-row-probe", confirmation: true)
            )
        } catch {
            absentErrorRaw = error
        }
        let absentError = try #require(absentErrorRaw, "a genuinely absent row must produce an error")

        // Observe the ceiling error for the .restricted row.
        var ceilingErrorRaw: Error?
        do {
            _ = try await kit.expunge(
                handle,
                ExpungeFrame(rowID: drawer.id, reason: "ceiling-probe", confirmation: true)
            )
        } catch {
            ceilingErrorRaw = error
        }
        let ceilingError = try #require(ceilingErrorRaw, "expunge must throw for a .restricted target")

        // Normalize: replace the absent id with the restricted row id in the
        // observed absent error. Both paths go through remap; the only difference
        // is the id embedded in the reason. This assertion goes red if the two
        // paths ever diverge, regardless of what either string contains.
        let normalizedAbsent = String(describing: absentError)
            .replacingOccurrences(of: absentID, with: drawer.id)
        let ceilingStr = String(describing: ceilingError)
        #expect(
            normalizedAbsent == ceilingStr,
            "ceiling error must match absent-row error; absent='\(normalizedAbsent)' ceiling='\(ceilingStr)'"
        )

        // The row must survive: non-tombstoned and content intact.
        let estate = try await kit.estate(for: handle)
        let rowAfter = try await estate.allDrawers().first { $0.id == drawer.id }
        #expect(rowAfter != nil, "the .restricted drawer must still exist after the refused expunge")
        #expect(
            rowAfter?.state != .tombstoned,
            "state must remain active, not tombstoned; got \(String(describing: rowAfter?.state))"
        )
        #expect(
            rowAfter?.content == drawer.content,
            "content must be byte-identical to what was captured"
        )
    }

    // MARK: - P2: retireKGFact refuses a fact with .restricted adjectiveSensitivity

    /// retireKGFact must refuse a fact whose adjectiveSensitivity is .restricted
    /// with the same error a genuinely missing fact produces. The adjectiveSensitivity
    /// is inherited from the source drawer: captureKGFact copies the source drawer's
    /// adjectiveBitmap onto the fact (the inheritance path the production check relies
    /// on). No existence oracle is provided to the caller. The fact must remain active
    /// in storage after the refusal.
    @Test
    func retireKGFactRefusesRestrictedSourceFactWithAbsentRowError() async throws {
        let (kit, handle) = try await openOneEstate()

        // Seed a .restricted source drawer so the KGFact inherits its
        // sensitivity via captureKGFact's adjective-bitmap inheritance path.
        var sourceFrame = CaptureFrame(
            content: "restricted source drawer for kg fact ceiling test",
            channel: .typed,
            room: "ceiling-tests",
            latticeAnchor: .udc("000"),
            addedBy: "sensitivity-ceiling-tests",
            embeddingModelID: "test-model-v1"
        )
        sourceFrame.sensitivity = .restricted
        let sourceDrawer = try await kit.capture(handle, sourceFrame)

        let fact = try await kit.captureKGFact(
            handle,
            subject: "RestrictedEntity",
            predicate: "hasProperty",
            object: "SensitiveValue",
            sourceDrawerID: sourceDrawer.id,
            now: testNow
        )

        // Pin the inheritance: captureKGFact copies the source drawer's
        // adjectiveBitmap. The production ceiling check reads the fact's OWN
        // adjectiveSensitivity. If this assertion fails, the inheritance path
        // has changed and the test is no longer exercising the ceiling check
        // for the intended reason.
        #expect(
            fact.adjectiveSensitivity == .restricted,
            "the fact must inherit .restricted adjectiveSensitivity from its source drawer"
        )

        // Observe the absent-fact error from a fact that genuinely does not exist.
        let absentFactID = UUID().uuidString
        var absentErrorRaw: Error?
        do {
            try await kit.retireKGFact(
                handle,
                rowID: absentFactID,
                changedBy: "sensitivity-ceiling-tests",
                now: testNow
            )
        } catch {
            absentErrorRaw = error
        }
        let absentError = try #require(absentErrorRaw, "a genuinely absent fact must produce an error")

        // Observe the ceiling error for the .restricted fact.
        var ceilingErrorRaw: Error?
        do {
            try await kit.retireKGFact(
                handle,
                rowID: fact.id,
                changedBy: "sensitivity-ceiling-tests",
                now: testNow
            )
        } catch {
            ceilingErrorRaw = error
        }
        let ceilingError = try #require(ceilingErrorRaw, "retireKGFact must throw for a .restricted fact")

        // Normalize: replace the absent fact id with the restricted fact id.
        // Both paths go through remap; the only difference is the id embedded
        // in the reason. This assertion goes red if the two paths ever diverge.
        let normalizedAbsent = String(describing: absentError)
            .replacingOccurrences(of: absentFactID, with: fact.id)
        let ceilingStr = String(describing: ceilingError)
        #expect(
            normalizedAbsent == ceilingStr,
            "ceiling error must match absent-fact error; absent='\(normalizedAbsent)' ceiling='\(ceilingStr)'"
        )

        // The fact must survive: still active, not withdrawn.
        let estate = try await kit.estate(for: handle)
        let allFacts = try await estate.allKGFactsIncludingRetired()
        let factAfter = allFacts.first { $0.id == fact.id }
        #expect(factAfter != nil, "the .restricted fact must still exist after the refused retire")
        #expect(
            factAfter?.state == .active,
            "state must remain .active, not .withdrawn; got \(String(describing: factAfter?.state))"
        )
    }

    // MARK: - P3: sibling above ceiling survives byte-identical through the lineage cascade

    /// The GLK erase verb passes .elevated as the sensitivity ceiling to the
    /// lineage cascade. A sibling whose tier exceeds .elevated is refused:
    /// left byte-identical (content verbatim, state unchanged, both bitmaps
    /// unchanged, tombstonedAt nil) and its id recorded in refusedSiblingIDs.
    /// The target, which is at or below the ceiling, is tombstoned normally.
    ///
    /// Two fixture values pinned so a reader can see which branch runs:
    ///   Target  id: targetID   tier: .normal  (raw 0 ≤ ceiling raw 16 — admitted)
    ///   Sibling id: siblingID  tier: .restricted (raw 32 > ceiling raw 16 — refused)
    @Test
    func expungeSiblingAboveCeilingIsRefusedByteIdentical() async throws {
        let (kit, handle) = try await openOneEstate()

        // Seed the target: a .normal drawer the erase verb admits.
        // The GLK step 0.5 ceiling check allows .normal (raw 0) through
        // because it is at or below .elevated (raw 16).
        let targetFrame = CaptureFrame(
            content: "normal-tier target that the erase verb admits — raw sensitivity 0",
            channel: .typed,
            room: "ceiling-sibling-tests",
            latticeAnchor: .udc("001"),
            addedBy: "sensitivity-ceiling-tests",
            embeddingModelID: "test-model-v1"
        )
        let targetDrawer = try await kit.capture(handle, targetFrame)
        let targetID = targetDrawer.id

        // Seed the sibling: a .restricted drawer in the SAME lineage.
        // Sensitivity raw 32 > ceiling raw 16, so the cascade must refuse it
        // and leave it byte-identical. The lineageID ties it to the target.
        var siblingFrame = CaptureFrame(
            content: "restricted-tier sibling that must survive the cascade byte-identical — raw sensitivity 32",
            channel: .typed,
            room: "ceiling-sibling-tests",
            latticeAnchor: .udc("002"),
            addedBy: "sensitivity-ceiling-tests",
            embeddingModelID: "test-model-v1"
        )
        siblingFrame.sensitivity = .restricted
        siblingFrame.lineageID = targetDrawer.lineageID
        let siblingDrawer = try await kit.capture(handle, siblingFrame)
        let siblingID = siblingDrawer.id

        // Snapshot the sibling's bitmaps before the erase so we can
        // prove byte-identity after (matching the assertion model in
        // LocusKitTests/ExpungeTests.swift:547–573).
        let sibContentBefore = siblingDrawer.content
        let sibAdjBefore = siblingDrawer.adjectiveBitmap
        let sibOpBefore = siblingDrawer.operationalBitmap

        // Call the GLK erase verb on the .normal target. The verb must
        // succeed for the target and refuse the .restricted sibling.
        let outcome = try await kit.expunge(
            handle,
            ExpungeFrame(rowID: targetID, reason: "ceiling-sibling-probe", confirmation: true),
            now: testNow
        )

        let estate = try await kit.estate(for: handle)
        let allAfter = try await estate.allDrawers()

        // The .normal target must be tombstoned.
        let targetAfter = allAfter.first { $0.id == targetID }
        #expect(targetAfter?.state == .tombstoned,
                "the .normal target (raw 0 ≤ ceiling raw 16) must be tombstoned after expunge")

        // The .restricted sibling must survive byte-identical.
        let sibAfter = allAfter.first { $0.id == siblingID }
        #expect(sibAfter != nil,
                "the .restricted sibling (\(siblingID)) must still exist after the expunge")
        #expect(
            sibAfter?.content == sibContentBefore,
            "sibling content must be byte-identical; got '\(sibAfter?.content ?? "<nil>")'"
        )
        #expect(
            sibAfter?.adjectiveBitmap == sibAdjBefore,
            "sibling adjectiveBitmap must be unchanged (ceiling refusal is write-free)"
        )
        #expect(
            sibAfter?.operationalBitmap == sibOpBefore,
            "sibling operationalBitmap must be unchanged (ceiling refusal is write-free)"
        )
        #expect(
            sibAfter?.tombstonedAt == nil,
            "sibling tombstonedAt must remain nil — it was not erased"
        )

        // The sibling must appear in refusedSiblingIDs so the partial
        // expunge is detectable to the caller (SPEC B-8b, MXE-FA).
        #expect(
            outcome.refusedSiblingIDs.contains(siblingID),
            "the .restricted sibling's id must appear in refusedSiblingIDs; got \(outcome.refusedSiblingIDs)"
        )
    }
}
