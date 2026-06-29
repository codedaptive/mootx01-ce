// DrainStatus.swift
//
// A read-only status snapshot for a long-running background drain, plus the
// GeniusLocusKit accessor that assembles the status of every drain the estate
// currently runs.
//
// Today the substrate runs exactly ONE drain: the corpus encode/ingest drain
// (CorpusKit's CorpusIngestQueue worker, which encodes captured/imported text
// into the BM25 + vector lanes asynchronously). `drainStatuses(_:)` returns a
// LIST so that when additional long-running drains are added later, each
// appends its own entry and the report surfaces all of them with no wire
// reshape. There is no speculative drain machinery here — the list is built
// from the drains that actually exist, which today is one.

import CorpusKit
import Foundation
import LocusKit

/// The composition-layer encode-speed knob so consumers that import only
/// GeniusLocusKit (VaultKit's PalaceBridge, AriaMcpKit) can name the type and
/// its cases without depending on CorpusKit directly. `.foreground` /
/// `.background` select the drain's embedding QoS (the SPEED axis); write
/// strategy is size-gated separately. Maps 1:1 to `CorpusKit.EncodeSpeed` at the
/// `setEncodeSpeed` boundary below. (A distinct GLK enum — rather than a typealias
/// — is required because Swift forbids using an imported enum's cases in a
/// default argument value unless the defining module is imported by that file.)
public enum EncodeSpeed: Sendable {
    case foreground
    case background
}

/// A read-only status snapshot of one long-running background drain.
public struct DrainStatus: Sendable, Equatable {
    /// Stable identifier for the drain (e.g. `"corpus_encode"`). Lets a status
    /// reader tell drains apart when more than one exists.
    public let name: String

    /// Jobs submitted to the drain but not yet claimed for processing.
    public let pending: Int

    /// Jobs claimed and currently being processed.
    public let inFlight: Int

    /// Optional drain-specific context, human-readable (e.g. the corpus drain
    /// reports `"encoded_chunks: 7218"` so forward progress is visible). Nil
    /// when a drain has no extra detail to report.
    public let detail: String?

    public init(name: String, pending: Int, inFlight: Int, detail: String? = nil) {
        self.name = name
        self.pending = pending
        self.inFlight = inFlight
        self.detail = detail
    }

    /// True while the drain has outstanding work on either frontier. False
    /// means idle: everything submitted has been processed.
    public var isDraining: Bool { pending + inFlight > 0 }
}

extension GeniusLocusKit {
    /// Status of every long-running drain the estate addressed by `handle`
    /// currently runs, for AI/operator monitoring (the `moot_drain_status`
    /// tool and the `mootx01 query drain_status` CLI surface).
    ///
    /// Today the only drain is the corpus encode/ingest drain: it reports the
    /// queue depth (pending + in-flight encode jobs) and, as detail, the live
    /// encoded-chunk count so forward progress is visible while the queue
    /// drains. A bare LocusKit estate with no Corpus registered runs no encode
    /// drain, so its list is empty.
    ///
    /// Read-only: assembles the report by OBSERVING each drain's frontiers; it
    /// never claims, drains, or mutates, so it is safe to poll while drains run.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    public func drainStatuses(_ handle: EstateHandle) async throws -> [DrainStatus] {
        // Validate the handle up front so a stale handle surfaces estateNotOpen
        // rather than silently returning an empty list — an empty list means
        // "this estate runs no drains", which must not be confused with "this
        // handle is dead".
        _ = try estate(for: handle)

        var statuses: [DrainStatus] = []

        // Drain 1 of N: the corpus encode/ingest drain. Present only when a
        // Corpus is registered for this estate (a provisioned/wired GLK estate).
        // Future drains append their own entries below this one.
        if let corpus = corpusKits[handle] {
            let depth = try await corpus.ingestQueueDepth()
            let encodedChunks = try await corpus.count()
            statuses.append(DrainStatus(
                name: "corpus_encode",
                pending: depth.pending,
                inFlight: depth.inFlight,
                detail: "encoded_chunks: \(encodedChunks)"
            ))
        }

        return statuses
    }

    /// Set the encode SPEED (drain QoS) for the estate's corpus drain, mapping
    /// the `mode` arg of an import (`foreground` / `background`) onto the
    /// Corpus's `encodeSpeed`. No-op when no Corpus is registered (a bare
    /// estate has no encode drain). Affects embed task groups spawned after this
    /// call. Mirrors Rust `EstateCoordinator::set_encode_speed`.
    public func setEncodeSpeed(_ speed: EncodeSpeed, for handle: EstateHandle) async {
        // Map the GLK-facing enum onto CorpusKit's at the composition boundary.
        let corpusSpeed: CorpusKit.EncodeSpeed = (speed == .background) ? .background : .foreground
        await corpusKits[handle]?.setEncodeSpeed(corpusSpeed)
    }
}
