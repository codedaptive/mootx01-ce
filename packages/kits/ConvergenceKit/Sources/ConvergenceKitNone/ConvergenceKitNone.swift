// ConvergenceKitNone.swift
//
// Single-device passthrough. enable() and disable() succeed
// trivially; push() and pull() are no-ops returning empty
// receipts; subscribe() returns a stream that never emits
// (closes when the caller cancels).
//
// Used when sync is structurally not wanted (development,
// tests, deployments without iCloud or federation).

import Foundation
import SubstrateTypes
import ConvergenceKit
import PersistenceKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

public final class NoSyncEngine: SyncEngine, Sendable {
    let stateActor: StateActor

    public init() {
        self.stateActor = StateActor()
    }

    public func enable(manifest: SyncManifest, storage: any Storage) async throws {
        try await stateActor.enable(manifest: manifest)
    }

    public func disable() async throws {
        await stateActor.disable()
    }

    public func push() async throws -> SyncReceipt {
        guard await stateActor.isEnabled else { throw SyncError.notEnabled }
        return SyncReceipt.empty
    }

    public func pull() async throws -> SyncReceipt {
        guard await stateActor.isEnabled else { throw SyncError.notEnabled }
        return SyncReceipt.empty
    }

    public func subscribe() -> AsyncStream<SyncEvent> {
        AsyncStream { continuation in
            // Never emits. Caller cancels by cancelling its task.
        }
    }

    public var state: SyncState {
        get async { await stateActor.currentState }
    }
}

actor StateActor {
    private(set) var isEnabled: Bool = false
    private var manifest: SyncManifest?

    func enable(manifest: SyncManifest) throws {
        if isEnabled { throw SyncError.alreadyEnabled }
        self.manifest = manifest
        self.isEnabled = true
    }

    func disable() {
        isEnabled = false
        manifest = nil
    }

    var currentState: SyncState {
        if let m = manifest, isEnabled {
            return .enabled(zone: m.zoneIdentifier, lastPushAt: nil, lastPullAt: nil)
        }
        return .disabled
    }
}
