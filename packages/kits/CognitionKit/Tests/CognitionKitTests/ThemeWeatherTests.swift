import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// ThemeWeather — topic lens (category 2, SPEC § 4.2). Recall a set,
/// and for each room compare its historical presence (raw count) to its
/// recent attention (decay-weighted mass by capture time) via NeuronKit
/// `themeWeather` — momentum, not just presence. Read-only. Swift peer
/// of run_theme_weather.
///
/// The heating/cooling direction needs capture-time spread, which the
/// Swift capture verb stamps from the wall clock — so the direction
/// claims live in NeuronKit's TopicLensTests over synthetic categories.
/// These tests assert the recipe's own sequencing layer: room
/// bucketing, the equal-recency wash (uniform capture time ⇒ recent
/// share ≈ historical share ⇒ momentum ≈ 0), deterministic ordering,
/// and the empty guard.
@Suite("ThemeWeatherTests")
struct ThemeWeatherTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "theme-weather-test"))
        return (kit, handle)
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, room: String
    ) async throws {
        let frame = CaptureFrame(
            content: "content",
            channel: .typed,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, frame)
    }

    private var unconfirmed: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.unconfirmed])
    }

    // CK-TW-A: every populated room reports a momentum; drawers captured
    // together (equal recency) give every room a recent share equal to
    // its historical share, so all momenta wash to ≈ 0 — presence alone
    // is not momentum.
    @Test("uniform capture time washes momentum to zero per room")
    func uniformCaptureTimeWashesMomentum() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<3 { try await capture(kit, handle, room: "alpha") }
        try await capture(kit, handle, room: "beta")

        let weather = try await ThemeWeather.run(
            kit: kit, handle: handle, frame: unconfirmed,
            halfLifeSeconds: 1_000_000_000, now: Date())

        #expect(Set(weather.map(\.category)) == Set(["alpha", "beta"]),
                "each populated room reports a momentum")
        for momentum in weather {
            #expect(abs(momentum.momentum) < 1e-6,
                    "equal recency ⇒ no momentum for \(momentum.category)")
        }
    }

    // (Hottest-first ordering and the exact-tie name tie-break are
    // asserted in NeuronKit's TopicLensTests over synthetic categories —
    // exact ties are not constructible through the wall-clock capture
    // verb, whose sub-millisecond filedAt spread leaves ~1e-12 momentum
    // differences.)

    // CK-TW-2: an empty estate yields no momentum (guarded).
    @Test("empty estate is guarded")
    func emptyEstateIsGuarded() async throws {
        let (kit, handle) = try await openEstate()

        let weather = try await ThemeWeather.run(
            kit: kit, handle: handle, frame: unconfirmed,
            halfLifeSeconds: 2_000, now: Date())

        #expect(weather.isEmpty)
    }

    // CK-TW-C: the result is a deterministic function of estate + now —
    // the same inputs rank identically on every run.
    @Test("result is deterministic for a fixed now")
    func resultIsDeterministicForFixedNow() async throws {
        let (kit, handle) = try await openEstate()
        for room in ["a", "b", "a"] { try await capture(kit, handle, room: room) }
        let now = Date().addingTimeInterval(60)

        let first = try await ThemeWeather.run(
            kit: kit, handle: handle, frame: unconfirmed,
            halfLifeSeconds: 2_000, now: now)
        let second = try await ThemeWeather.run(
            kit: kit, handle: handle, frame: unconfirmed,
            halfLifeSeconds: 2_000, now: now)

        #expect(first == second)
    }
}
