import Foundation
import Testing
@testable import LocusKit

@Suite("TunnelKindTests")
struct TunnelKindTests {

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    // MARK: - TunnelKind raw values (spec Appendix A)

    @Test("TunnelKind raw values match spec Appendix A")
    func tunnelKindRawValues() {
        #expect(TunnelKind.supersedes.rawValue == 0)
        #expect(TunnelKind.references.rawValue == 1)
        #expect(TunnelKind.blocks.rawValue == 2)
        #expect(TunnelKind.validates.rawValue == 3)
        #expect(TunnelKind.contradicts.rawValue == 4)
        #expect(TunnelKind.derivesFrom.rawValue == 5)
        #expect(TunnelKind.covers.rawValue == 6)
        #expect(TunnelKind.elaborates.rawValue == 7)
        #expect(TunnelKind.respondsTo.rawValue == 8)
        #expect(TunnelKind.parent.rawValue == 9)
    }

    @Test("TunnelKind unrecognised raw value returns nil")
    func tunnelKindUnknownRawIsNil() {
        #expect(TunnelKind(rawValue: 10) == nil)
        #expect(TunnelKind(rawValue: -1) == nil)
    }

    @Test("TunnelKind round-trips through Codable")
    func tunnelKindCodableRoundTrip() throws {
        let original = TunnelKind.derivesFrom
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TunnelKind.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - TunnelDirection (spec § 5.6)

    @Test("TunnelDirection raw values match spec § 5.6")
    func tunnelDirectionRawValues() {
        #expect(TunnelDirection.directional.rawValue == 0)
        #expect(TunnelDirection.bidirectional.rawValue == 1)
        #expect(TunnelDirection.symmetric.rawValue == 2)
        #expect(TunnelDirection.hub.rawValue == 3)
    }

    // MARK: - TunnelLifecycle (spec § 5.6)

    @Test("TunnelLifecycle raw values match spec § 5.6")
    func tunnelLifecycleRawValues() {
        #expect(TunnelLifecycle.active.rawValue == 0)
        #expect(TunnelLifecycle.proposed.rawValue == 1)
        #expect(TunnelLifecycle.superseded.rawValue == 2)
        #expect(TunnelLifecycle.withdrawn.rawValue == 3)
    }

    // MARK: - TunnelOriginClass (spec § 5.6)

    @Test("TunnelOriginClass raw values match spec § 5.6")
    func tunnelOriginClassRawValues() {
        #expect(TunnelOriginClass.userExplicit.rawValue == 0)
        #expect(TunnelOriginClass.derived.rawValue == 1)
        #expect(TunnelOriginClass.imported.rawValue == 2)
        #expect(TunnelOriginClass.federatedSync.rawValue == 3)
        #expect(TunnelOriginClass.migration.rawValue == 4)
    }

    // MARK: - TunnelStrength (spec § 5.6, scale-gapped)

    @Test("TunnelStrength raw values use scale-gapped encoding 0/2/4/6")
    func tunnelStrengthRawValues() {
        #expect(TunnelStrength.weak.rawValue == 0)
        #expect(TunnelStrength.normal.rawValue == 2)
        #expect(TunnelStrength.strong.rawValue == 4)
        #expect(TunnelStrength.loadBearing.rawValue == 6)
    }

    @Test("TunnelStrength scale-gap sentinels — 1 and 3 are nil")
    func tunnelStrengthScaleGapSentinels() {
        #expect(TunnelStrength(rawValue: 1) == nil)
        #expect(TunnelStrength(rawValue: 3) == nil)
    }

    @Test("TunnelStrength is Comparable in scale order")
    func tunnelStrengthOrdering() {
        #expect(TunnelStrength.weak < TunnelStrength.normal)
        #expect(TunnelStrength.normal < TunnelStrength.strong)
        #expect(TunnelStrength.strong < TunnelStrength.loadBearing)
    }

    // MARK: - Tunnel.kind field

    @Test("Tunnel.kind defaults to .references when omitted")
    func tunnelKindDefaultsToReferences() {
        let now = t(1_700_000_000)
        let tunnel = Tunnel(
            id: "t-default",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "any",
            addedBy: "bilby", filedAt: now
        )
        #expect(tunnel.kind == .references)
    }

    @Test("Tunnel.kind round-trips when explicitly set")
    func tunnelKindExplicitlySet() {
        let now = t(1_700_000_000)
        let tunnel = Tunnel(
            id: "t-super",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "supersedes",
            kind: .supersedes,
            addedBy: "bilby", filedAt: now
        )
        #expect(tunnel.kind == .supersedes)
    }

    @Test("Tunnel.kind survives Codable round-trip")
    func tunnelKindCodableSurvives() throws {
        let now = t(1_700_000_000)
        let original = Tunnel(
            id: "t-codable",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "elaborates",
            kind: .elaborates,
            addedBy: "bilby", filedAt: now
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Tunnel.self, from: data)
        #expect(decoded.kind == .elaborates)
        #expect(decoded == original)
    }

    @Test("All ten TunnelKind cases round-trip on Tunnel")
    func allKindsRoundTripOnTunnel() {
        let now = t(1_700_000_000)
        let allKinds: [TunnelKind] = [
            .supersedes, .references, .blocks, .validates, .contradicts,
            .derivesFrom, .covers, .elaborates, .respondsTo, .parent,
        ]
        for k in allKinds {
            let tunnel = Tunnel(
                id: "t-\(k.rawValue)",
                sourceWing: "w", sourceRoom: "r",
                targetWing: "w2", targetRoom: "r2",
                label: "x",
                kind: k,
                addedBy: "bilby", filedAt: now
            )
            #expect(tunnel.kind == k)
        }
    }

    // MARK: - Sendable / Codable conformance smoke

    @Test("TunnelDirection is Codable")
    func tunnelDirectionCodable() throws {
        let data = try JSONEncoder().encode(TunnelDirection.bidirectional)
        let decoded = try JSONDecoder().decode(TunnelDirection.self, from: data)
        #expect(decoded == .bidirectional)
    }

    @Test("TunnelLifecycle is Codable")
    func tunnelLifecycleCodable() throws {
        let data = try JSONEncoder().encode(TunnelLifecycle.proposed)
        let decoded = try JSONDecoder().decode(TunnelLifecycle.self, from: data)
        #expect(decoded == .proposed)
    }

    @Test("TunnelOriginClass is Codable")
    func tunnelOriginClassCodable() throws {
        let data = try JSONEncoder().encode(TunnelOriginClass.federatedSync)
        let decoded = try JSONDecoder().decode(TunnelOriginClass.self, from: data)
        #expect(decoded == .federatedSync)
    }

    @Test("TunnelStrength is Codable")
    func tunnelStrengthCodable() throws {
        let data = try JSONEncoder().encode(TunnelStrength.loadBearing)
        let decoded = try JSONDecoder().decode(TunnelStrength.self, from: data)
        #expect(decoded == .loadBearing)
    }
}
