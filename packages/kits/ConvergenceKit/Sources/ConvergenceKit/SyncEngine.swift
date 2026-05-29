// SyncEngine.swift
//
// Top-level protocol every ConvergenceKit backend conforms to.

import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
import PersistenceKit

public protocol SyncEngine: Sendable {
    /// Enable sync against the given manifest and storage. Must
    /// be called once before push/pull/subscribe. Establishes any
    /// remote subscriptions and starts observing the local
    /// PersistenceKit for outbound changes.
    func enable(manifest: SyncManifest, storage: any Storage) async throws

    /// Tear down subscriptions, stop observing, release resources.
    /// Idempotent.
    func disable() async throws

    /// One-shot push of pending local changes to the remote.
    /// Returns a receipt summarizing what moved.
    func push() async throws -> SyncReceipt

    /// One-shot pull of pending remote changes. Receiver applies
    /// them through PersistenceKit, which fires StorageObserver on
    /// the local side so downstream watchers wake naturally.
    func pull() async throws -> SyncReceipt

    /// Long-running subscription. The stream fires SyncEvent
    /// values as sync activity happens. Closing the stream stops
    /// the subscription.
    func subscribe() -> AsyncStream<SyncEvent>

    /// Current state for UI bindings.
    var state: SyncState { get async }
}
