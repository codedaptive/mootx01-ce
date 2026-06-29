import Foundation
import Testing
@testable import LocusKit

/// Adjective bitmap coverage — enum raw values per spec § 5.5,
/// the four-axis composite encoding, the three state-cluster
/// predicates per spec § 6.1, and the default-zero behavior of
/// `Drawer.adjectiveBitmap` for callers that omit the parameter.
///
/// Covers pure value/accessor behavior: enum raw values,
/// bit-extraction accessors, predicates, and Codable equality.
/// Persistence coverage for `adjectiveBitmap` lives in
/// `DrawerStoreTests.swift`.
@Suite("AdjectiveBitmapTests")
struct AdjectiveBitmapTests {

    // MARK: - State enum raw values (spec § 5.5)

    @Test("State raw values are scale-gapped per cookbook §2.3")
    func stateRawValues() {
        // Cluster A — active / becoming.
        #expect(State.active.rawValue == 0)
        #expect(State.pending.rawValue == 1)
        #expect(State.contested.rawValue == 2)
        #expect(State.accepted.rawValue == 3)
        // Cluster B — superseded / historical.
        #expect(State.superseded.rawValue == 16)
        #expect(State.decayed.rawValue == 17)
        #expect(State.withdrawn.rawValue == 18)
        #expect(State.expired.rawValue == 19)
        // Cluster C — terminal.
        #expect(State.rejected.rawValue == 32)
        #expect(State.tombstoned.rawValue == 33)
    }

    // MARK: - Trust enum raw values + ordering (spec § 5.5)

    @Test("Trust raw values are 0…6 per cookbook §2.3 (ambient NEW in v0.6)")
    func trustRawValues() {
        #expect(Trust.verbatim.rawValue == 0)
        #expect(Trust.observed.rawValue == 1)
        #expect(Trust.imported.rawValue == 2)
        #expect(Trust.canonical.rawValue == 3)
        #expect(Trust.derived.rawValue == 4)
        #expect(Trust.proposed.rawValue == 5)
        #expect(Trust.ambient.rawValue == 6)
    }

    @Test("Trust is Comparable by rawValue")
    func trustComparable() {
        #expect(Trust.verbatim < Trust.canonical)
        #expect(Trust.canonical >= Trust.canonical)
        #expect(Trust.proposed > Trust.derived)
    }

    // MARK: - AdjectiveSensitivity enum raw values (spec § 5.5)

    @Test("AdjectiveSensitivity raw values are scale-gapped 0/16/32/48 per cookbook §2.3")
    func sensitivityRawValues() {
        #expect(AdjectiveSensitivity.normal.rawValue == 0)
        #expect(AdjectiveSensitivity.elevated.rawValue == 16)
        #expect(AdjectiveSensitivity.restricted.rawValue == 32)
        #expect(AdjectiveSensitivity.secret.rawValue == 48)
    }

    // MARK: - AdjectiveExportability enum raw values (spec § 5.5)

    @Test("AdjectiveExportability raw values are scale-gapped 0/32 per cookbook §2.3")
    func exportabilityRawValues() {
        #expect(AdjectiveExportability.private_.rawValue == 0)
        #expect(AdjectiveExportability.public_.rawValue == 32)
    }

    // MARK: - Composite bitmap encoding (spec § 5.5)

    /// Hand-verified composite under cookbook §2.3 6-bit field widths:
    /// state=.contested (raw 2, bits 0–5), sensitivity=.elevated (raw 16,
    /// shifted into bits 6–11), exportability=.private_ (raw 0, shifted
    /// into bits 12–17), trust=.observed (raw 1, shifted into bits 18–23).
    /// 2 | (16 << 6) | (0 << 12) | (1 << 18) = 263170 = 0x40402.
    @Test("Composite bitmap encodes all four axes at 0x40402 (cookbook §2.3)")
    func compositeBitmap() {
        let raw: Int64 =
            Int64(State.contested.rawValue)
            | (Int64(AdjectiveSensitivity.elevated.rawValue) << 6)
            | (Int64(AdjectiveExportability.private_.rawValue) << 12)
            | (Int64(Trust.observed.rawValue) << 18)
        #expect(raw == 0x40402)

        let drawer = makeDrawer(adjectiveBitmap: raw)
        #expect(drawer.adjectiveBitmap == 0x40402)
    }

    @Test("state accessor decodes bits 0–5 per cookbook §2.3")
    func stateAccessor() {
        let drawer = makeDrawer(adjectiveBitmap: 0x40402)
        #expect(drawer.state == .contested)
    }

    @Test("trust accessor decodes bits 18–23 per cookbook §2.3")
    func trustAccessor() {
        let drawer = makeDrawer(adjectiveBitmap: 0x40402)
        #expect(drawer.trust == .observed)
    }

    @Test("adjectiveSensitivity accessor decodes bits 6–11 per cookbook §2.3")
    func sensitivityAccessor() {
        let drawer = makeDrawer(adjectiveBitmap: 0x40402)
        #expect(drawer.adjectiveSensitivity == .elevated)
    }

    @Test("exportability accessor decodes bits 12–17 per cookbook §2.3")
    func exportabilityAccessor() {
        let drawer = makeDrawer(adjectiveBitmap: 0x40402)
        #expect(drawer.exportability == .private_)
    }

    // MARK: - State-cluster predicates (spec § 6.1)

    @Test("isCurrentlyBelieved is true for Cluster A (active/pending/contested/accepted) per cookbook §2.3")
    func currentlyBelievedTrue() {
        // F11 cascade: accepted moved into Cluster A per cookbook §2.3.
        for s: State in [.active, .pending, .contested, .accepted] {
            let drawer = makeDrawer(adjectiveBitmap: Int64(s.rawValue))
            #expect(drawer.isCurrentlyBelieved, "expected isCurrentlyBelieved for \(s)")
        }
    }

    @Test("isCurrentlyBelieved is false for Clusters B and C")
    func currentlyBelievedFalse() {
        for s: State in [.superseded, .decayed, .withdrawn, .expired, .rejected, .tombstoned] {
            let drawer = makeDrawer(adjectiveBitmap: Int64(s.rawValue))
            #expect(!drawer.isCurrentlyBelieved, "did not expect isCurrentlyBelieved for \(s)")
        }
    }

    @Test("isKnewPast is true for superseded, decayed, withdrawn, expired")
    func knewPastTrue() {
        for s: State in [.superseded, .decayed, .withdrawn, .expired] {
            let drawer = makeDrawer(adjectiveBitmap: Int64(s.rawValue))
            #expect(drawer.isKnewPast, "expected isKnewPast for \(s)")
        }
    }

    @Test("isKnewPast is false for Cluster A and Cluster C")
    func knewPastFalse() {
        for s: State in [.active, .pending, .contested, .accepted, .rejected, .tombstoned] {
            let drawer = makeDrawer(adjectiveBitmap: Int64(s.rawValue))
            #expect(!drawer.isKnewPast, "did not expect isKnewPast for \(s)")
        }
    }

    @Test("isTerminal is true for Cluster C (rejected, tombstoned) per cookbook §2.3")
    func terminalTrue() {
        // F11 cascade: accepted moved OUT of isTerminal into isCurrentlyBelieved.
        // Cluster C is "externally rejected/removed," not "no further transitions."
        for s: State in [.rejected, .tombstoned] {
            let drawer = makeDrawer(adjectiveBitmap: Int64(s.rawValue))
            #expect(drawer.isTerminal, "expected isTerminal for \(s)")
        }
    }

    @Test("isTerminal is false for Cluster A and Cluster B")
    func terminalFalse() {
        for s: State in [.active, .pending, .contested, .accepted, .superseded, .decayed, .withdrawn, .expired] {
            let drawer = makeDrawer(adjectiveBitmap: Int64(s.rawValue))
            #expect(!drawer.isTerminal, "did not expect isTerminal for \(s)")
        }
    }

    // MARK: - Default-zero behavior

    /// A Drawer constructed without `adjectiveBitmap` carries the zero
    /// field, and every adjective accessor returns its zero-mapped
    /// case (`.active` / `.normal` / `.private_` / `.verbatim`).
    @Test("Default-zero adjective bitmap yields all-zero accessors")
    func defaultZero() {
        let drawer = Drawer(
            content: "c",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
        #expect(drawer.adjectiveBitmap == 0)
        #expect(drawer.state == .active)
        #expect(drawer.adjectiveSensitivity == .normal)
        #expect(drawer.exportability == .private_)
        #expect(drawer.trust == .verbatim)
        #expect(drawer.isCurrentlyBelieved)
        #expect(!drawer.isKnewPast)
        #expect(!drawer.isTerminal)
    }

    // MARK: - Helpers

    private func makeDrawer(adjectiveBitmap: Int64) -> Drawer {
        Drawer(
            content: "c",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: adjectiveBitmap
        )
    }
}
