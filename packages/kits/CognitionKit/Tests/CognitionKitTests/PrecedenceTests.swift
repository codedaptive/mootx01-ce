import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateML
import SubstrateTypes
@testable import CognitionKit

/// PrecedenceTests — temporal causality antecedent recipe (Lens 3, Prediction).
/// Verifies the recipe result equals the lens result on the same shaped
/// input (C-3), and the degenerate paths are guarded (B-8).
@Suite("PrecedenceTests")
struct PrecedenceTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "precedence-test"))
        return (kit, handle)
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, room: String = "study"
    ) async throws {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "test",
            embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, frame)
    }

    // CK-PR-1: recipe result equals the lens result on the same shaped input.
    // Reads lag pairs, folds, and calls the lens directly, then asserts the
    // recipe produces the same output.
    @Test("recipe result matches direct lens call on same shaped input")
    func recipeResultMatchesDirectLensCall() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()

        // Capture a few drawers in the room field so audit entries exist.
        for i in 0..<3 {
            _ = try await capture(kit, handle, content: "prec-\(i)", room: "lab")
        }

        let window = Date(timeIntervalSinceNow: -3600)...now

        // Read lag pairs directly — same as the recipe's GLK read.
        let entries = try await kit.glkEventLagPairs(in: handle, window: window)

        // Fold with the same window used by the recipe.
        let foldResult = TemporalCausalityFold.fold(
            entries: entries,
            windowMinutes: 128,
            startWatermark: .zero)
        let deltas = foldResult.deltas

        // Pick any target if deltas exist, otherwise use a dummy.
        let target: TemporalFieldCoord
        if let first = deltas.first {
            target = first.0.target
        } else {
            target = TemporalFieldCoord(fieldPath: "room", valueRepr: "string:lab")
        }

        let expected = NeuronKit.precedence(pairs: deltas, target: target, k: 3)

        // Run the recipe.
        let out = try await Precedence.run(
            kit: kit, handle: handle,
            window: window,
            target: target,
            k: 3,
            now: now)

        #expect(out.antecedents == expected,
                "recipe result must equal the direct lens call on the same shaped input")
        #expect(out.entryCount == entries.count)
    }

    // CK-PR-2: empty estate → empty antecedent list and zero entries (B-8).
    @Test("empty estate is guarded")
    func emptyEstateIsGuarded() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        let window = Date(timeIntervalSinceNow: -3600)...now
        let target = TemporalFieldCoord(fieldPath: "room", valueRepr: "string:study")

        let out = try await Precedence.run(
            kit: kit, handle: handle,
            window: window,
            target: target,
            k: 5,
            now: now)

        #expect(out.antecedents.isEmpty)
        #expect(out.entryCount == 0)
    }

    // CK-PR-3: k = 0 → empty antecedent list (B-8).
    @Test("k zero is guarded")
    func kZeroIsGuarded() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        _ = try await capture(kit, handle, content: "data")
        let window = Date(timeIntervalSinceNow: -3600)...now
        let target = TemporalFieldCoord(fieldPath: "room", valueRepr: "string:study")

        let out = try await Precedence.run(
            kit: kit, handle: handle,
            window: window,
            target: target,
            k: 0,
            now: now)

        #expect(out.antecedents.isEmpty)
    }

    // CK-PR-4 (Wave C, Option A): drawer whose eventTime is outside the window
    // must not contribute audit entries to the precedence fold. Bob's ruling:
    // the window filter gates WHICH drawers participate by eventTime, not by
    // HLC ingest time.
    @Test("drawer outside eventTime window contributes zero entries")
    func drawerOutsideEventTimeWindowContributesZeroEntries() async throws {
        let (kit, handle) = try await openEstate()

        // Use a window anchored far in the future; any normally-captured drawer
        // (eventTime ≈ filedAt ≈ now) will be outside this range.
        let futureStart = Date(timeIntervalSinceNow: 7200)  // +2h from now
        let futureEnd   = Date(timeIntervalSinceNow: 10800) // +3h from now
        let window = futureStart...futureEnd

        // Capture a drawer — its eventTime defaults to filedAt (now), which is
        // outside the future window.
        _ = try await capture(kit, handle, content: "outside-window", room: "lab")

        let target = TemporalFieldCoord(fieldPath: "room", valueRepr: "string:lab")
        let out = try await Precedence.run(
            kit: kit, handle: handle,
            window: window,
            target: target,
            k: 5,
            now: Date())

        // The drawer is outside the eventTime window, so no entries flow to the
        // fold. Entry count must be zero.
        #expect(
            out.entryCount == 0,
            "drawer with eventTime outside the window must contribute 0 entries; got: \(out.entryCount)"
        )
    }
}
