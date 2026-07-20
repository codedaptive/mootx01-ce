// EstateManifestPolicyStore.swift
//
// Manifest-backed implementations of the dreaming and maintenance policy
// stores. These satisfy the daemon persistence seams by
// reading and writing the estate manifest THROUGH the public substrate
// interface (`GeniusLocusKit.estate(for:)` → `LocusKit.Estate.meta/setMeta`),
// so policy, bandit, and daemon cycle state survive a process restart.
//
// Why this lives in NeuronKit, not GeniusLocusKit: the policy-store protocols
// and the daemon-state types are declared in NeuronKit; a conformer must import
// NeuronKit. GeniusLocusKit sits BELOW NeuronKit (NK → GLK → LocusKit), so GLK
// cannot import NK without a circular dependency. NeuronKit is the only package
// that sees both the protocols and the GLK estate surface — the same rationale
// as EstateDreamingReader. The substrate OWNS the durable key-value storage;
// NeuronKit owns the typed serialization of what goes in it (Interface Rules:
// features owned at the lowest level; data flows through public interfaces).

import Foundation
import GeniusLocusKit
import LocusKit

/// Namespaced manifest keys for NeuronKit daemon state. Namespaced
/// to avoid collision with the typed v1 `ManifestKey` set.
enum NeuronKitManifestKey {
    static let dreamingPolicy = "neuronkit.dreaming.policy"
    static let dreamingBandit = "neuronkit.dreaming.bandit"
    static let dreamingState = "neuronkit.dreaming.state"
    static let maintenancePolicy = "neuronkit.maintenance.policy"
    static let maintenanceState = "neuronkit.maintenance.state"

    // Governor compute-cache keys avoid retaining full-estate state in memory.
    // Each duty persists its computed output + a change-detection watermark
    // so that the next cadence invocation can skip an expensive full-estate
    // load when the estate is unchanged.
    //
    // Key format: "governor.<duty>.scores.v1" (JSON blob of [String: Float])
    //             "governor.<duty>.count.v1"  (watermark string, format varies
    //                                          by duty — see below)
    //
    // Watermark formats by duty:
    //   centralityCount, topologyCount:
    //     Composite topology-change signature produced by
    //     `GeniusLocusKit.topologyChangeSignature(for:)`:
    //     "\(auditCount),\(tunnelCount),\(kgFactCount)" — three O(1) COUNT(*)
    //     values that together detect drawer, tunnel, AND KG-fact writes.
    //     Tunnel and KG-fact writes produce no audit event, so an audit-only
    //     watermark missed them (stale centrality / topology after
    //     tunnel-only or fact-only writes — Kong finding, resolved here).
    //     A bare-Int value written by the OLD watermark is treated as changed
    //     (format mismatch → one-time recompute on upgrade; safe and correct).
    //
    //   preferenceCount:
    //     Bare audit-event count as a decimal Int string, read via
    //     `hasAuditGrown(for:since:)`. Preferences model recall-trace reward
    //     history, which is driven by drawer captures (audited). Tunnels and
    //     KG-facts do not affect recall traces, so the audit-only watermark
    //     is correct and sufficient for the preference duty.
    static let centralityScores = "governor.centrality.scores.v1"
    static let centralityCount  = "governor.centrality.count.v1"
    static let preferenceScores = "governor.preference.scores.v1"
    static let preferenceCount  = "governor.preference.count.v1"
    static let topologyCount    = "governor.topology.count.v1"
}

/// Deterministic JSON encoder (sorted keys) so the persisted manifest value is
/// byte-stable across writes — matches the substrate's `.sortedKeys` convention.
private let neuronKitManifestEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
}()

/// Shared estate-manifest JSON load/save over the public `Estate` meta surface.
/// A present-but-undecodable value returns nil (fail-soft: the daemon falls back
/// to its defaults rather than crashing on a manifest written by a newer schema).
private enum EstateManifestCodec {
    static func load<T: Decodable>(
        _ type: T.Type, key: String, handle: EstateHandle, kit: GeniusLocusKit
    ) async throws -> T? {
        let estate = try await kit.estate(for: handle)
        guard let json = try await estate.meta(key: key),
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(
        _ value: T, key: String, handle: EstateHandle, kit: GeniusLocusKit
    ) async throws {
        let estate = try await kit.estate(for: handle)
        let data = try neuronKitManifestEncoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try await estate.setMeta(key: key, value: json)
    }
}

/// Manifest-backed `DreamingPolicyStore`: persists the dreaming policy, the
/// Thompson-Sampling bandit, and the daemon's cycle state to the estate manifest.
public struct EstateManifestDreamingPolicyStore: DreamingPolicyStore {

    private let handle: EstateHandle
    private let kit: GeniusLocusKit

    /// Construct a store bound to the addressed estate.
    public init(handle: EstateHandle, kit: GeniusLocusKit) {
        self.handle = handle
        self.kit = kit
    }

    public func loadPolicy() async throws -> DreamingPolicy? {
        try await EstateManifestCodec.load(
            DreamingPolicy.self, key: NeuronKitManifestKey.dreamingPolicy, handle: handle, kit: kit)
    }

    public func savePolicy(_ policy: DreamingPolicy) async throws {
        try await EstateManifestCodec.save(
            policy, key: NeuronKitManifestKey.dreamingPolicy, handle: handle, kit: kit)
    }

    public func loadBandit() async throws -> SolverBandit? {
        try await EstateManifestCodec.load(
            SolverBandit.self, key: NeuronKitManifestKey.dreamingBandit, handle: handle, kit: kit)
    }

    public func saveBandit(_ bandit: SolverBandit) async throws {
        try await EstateManifestCodec.save(
            bandit, key: NeuronKitManifestKey.dreamingBandit, handle: handle, kit: kit)
    }

    public func loadDaemonState() async throws -> DreamingDaemonState? {
        try await EstateManifestCodec.load(
            DreamingDaemonState.self, key: NeuronKitManifestKey.dreamingState, handle: handle, kit: kit)
    }

    public func saveDaemonState(_ state: DreamingDaemonState) async throws {
        try await EstateManifestCodec.save(
            state, key: NeuronKitManifestKey.dreamingState, handle: handle, kit: kit)
    }
}

/// Manifest-backed `MaintenancePolicyStore`: persists the maintenance policy and
/// the daemon's cycle state to the estate manifest.
public struct EstateManifestMaintenancePolicyStore: MaintenancePolicyStore {

    private let handle: EstateHandle
    private let kit: GeniusLocusKit

    /// Construct a store bound to the addressed estate.
    public init(handle: EstateHandle, kit: GeniusLocusKit) {
        self.handle = handle
        self.kit = kit
    }

    public func loadPolicy() async throws -> MaintenancePolicy? {
        try await EstateManifestCodec.load(
            MaintenancePolicy.self, key: NeuronKitManifestKey.maintenancePolicy, handle: handle, kit: kit)
    }

    public func savePolicy(_ policy: MaintenancePolicy) async throws {
        try await EstateManifestCodec.save(
            policy, key: NeuronKitManifestKey.maintenancePolicy, handle: handle, kit: kit)
    }

    public func loadDaemonState() async throws -> MaintenanceDaemonState? {
        try await EstateManifestCodec.load(
            MaintenanceDaemonState.self, key: NeuronKitManifestKey.maintenanceState, handle: handle, kit: kit)
    }

    public func saveDaemonState(_ state: MaintenanceDaemonState) async throws {
        try await EstateManifestCodec.save(
            state, key: NeuronKitManifestKey.maintenanceState, handle: handle, kit: kit)
    }
}
