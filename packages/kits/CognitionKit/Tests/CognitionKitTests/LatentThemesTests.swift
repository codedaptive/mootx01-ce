import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// LatentThemesLens — topic lens (category 2, SPEC § 4.2). Recalls a
/// set of drawers, builds the co-occurrence of their metadata
/// field-value labels (`room:` / `kind:` / `channel:` / `sensitivity:`,
/// spelled as the Swift case names — the canonical label vocabulary
/// both versions emit), and factors it into soft latent themes — the
/// emergent topics in how the estate is filed, with mixed membership.
/// Read-only; deterministic for the lens's fixed seed. Swift peer of
/// run_latent_themes.
@Suite("LatentThemesTests")
struct LatentThemesTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "latent-themes-test"))
        return (kit, handle)
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        room: String, kind: ContentKind, channel: CaptureChannel,
        sensitivity: AdjectiveSensitivity
    ) async throws {
        var frame = CaptureFrame(
            content: "content",
            channel: channel,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        frame.kind = kind
        frame.sensitivity = sensitivity
        _ = try await kit.capture(handle, frame)
    }

    /// Admit elevated rows too — recall defaults to a normal sensitivity
    /// ceiling, which would otherwise drop the elevated work regime.
    // UserConfirmed: all rows written via Estate.capture are stamped at write time.
    private var allRows: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [
            .userConfirmed, .sensitivityAtMost(.secret),
        ])
    }

    private func dominant(_ themes: LatentThemes, _ label: String) throws -> Int {
        try #require(themes.loadings.first { $0.label == label }).dominantTheme
    }

    // CK-LT-1: two FULLY DISJOINT metadata regimes across the recalled
    // set — study drawers (room:study, prose, typed, normal) vs work
    // drawers (room:work, code, voiced, elevated), sharing no
    // field-value — separate into two latent themes. (Shared
    // field-values would correctly LINK the regimes; disjoint ones make
    // the separation clean.) End-to-end over a real estate.
    @Test("two disjoint filing regimes separate into two themes")
    func twoRegimesSeparateIntoThemes() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<3 {
            try await capture(kit, handle, room: "study",
                              kind: .prose, channel: .typed, sensitivity: .normal)
        }
        for _ in 0..<3 {
            try await capture(kit, handle, room: "work",
                              kind: .code, channel: .voiced, sensitivity: .elevated)
        }

        let themes = try await LatentThemesLens.run(
            kit: kit, handle: handle, frame: allRows, k: 2)

        #expect(themes.k == 2)
        // The study/prose field-values cluster together, distinct from work/code.
        let study = try dominant(themes, "room:study")
        #expect(try dominant(themes, "kind:prose") == study, "study & prose share a theme")
        let work = try dominant(themes, "room:work")
        #expect(try dominant(themes, "kind:code") == work, "work & code share a theme")
        #expect(study != work, "the two filing regimes are different latent themes")
    }

    // CK-LT-2: an empty estate yields no themes — guarded.
    @Test("empty estate has no themes")
    func emptyEstateHasNoThemes() async throws {
        let (kit, handle) = try await openEstate()

        let themes = try await LatentThemesLens.run(
            kit: kit, handle: handle, frame: allRows, k: 2)

        #expect(themes.loadings.isEmpty)
    }
}
