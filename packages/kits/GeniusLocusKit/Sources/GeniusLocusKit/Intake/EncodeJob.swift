// EncodeJob.swift
//
// Dual-Path Intake P2 — the encode-job payload.
//
// A capture on the regular write path enqueues one EncodeJob per drawer onto
// the estate's dedicated encode queue (P3). The drain worker (P4) decodes the
// job and calls `Corpus.ingest(text, sourceID: drawerID, now:)` — the single
// call that chunks the text, builds the BM25 index, and embeds vectors, lighting
// the previously-dark semantic-recall lanes for captured content.
//
// The payload carries exactly what the worker needs to perform that ingest
// deterministically, encoded into QueueKit's opaque `Job.payload` (base64url on
// the wire). It is a plain Codable value — no behavior — so the Swift and Rust
// queue wire formats can agree on it when the Rust twin lands (parity debt G7).

import Foundation
import QueueKit
import SubstrateTypes

/// The work item the encode queue carries: everything the drain worker needs to
/// ingest one captured drawer into the estate's Corpus.
///
/// `sourceID` is intentionally the DRAWER id (not a chunk id): `Corpus.ingest`
/// keys its internal vectors by `chunk.id` but `bm25TopKBySource` aggregates
/// chunk scores back to `sourceID`, and `RecallDirector` hydrates non-locus hits
/// by drawer id. Passing the drawer id as `sourceID` is what makes a recall hit
/// join back to a real `Drawer` row (G4).
public struct EncodeJob: Sendable, Codable, Hashable {
    /// The captured drawer's id — used as `sourceID` for `Corpus.ingest` so
    /// BM25/vector hits hydrate to this drawer (G4).
    public let drawerID: String
    /// The estate the drawer belongs to. Carried so a drained job can be routed
    /// to the correct estate's Corpus even if the worker is shared in future.
    public let estateUUID: UUID
    /// The verbatim text to encode (the drawer's content).
    public let text: String
    /// The embedding model id the drawer was captured under (I-4 model-tag
    /// contract). Carried for provenance; the Corpus uses its own configured
    /// provider model id when it writes vectors.
    public let embeddingModelID: String
    /// The capture instant, ISO8601. The worker passes this back into
    /// `Corpus.ingest(now:)` so vector filing timestamps are deterministic and
    /// reproduce the capture time rather than the (later) drain time.
    public let capturedAtISO8601: String

    /// Build an EncodeJob from a freshly captured drawer's fields.
    ///
    /// - Parameters:
    ///   - drawerID: The captured drawer's id (becomes `sourceID` at ingest).
    ///   - estateUUID: The estate the drawer belongs to.
    ///   - text: The drawer's verbatim content.
    ///   - embeddingModelID: The drawer's embedding model id.
    ///   - capturedAt: The capture instant; encoded ISO8601 for deterministic
    ///     re-hydration into `Corpus.ingest(now:)`.
    public init(
        drawerID: String,
        estateUUID: UUID,
        text: String,
        embeddingModelID: String,
        capturedAt: Date
    ) {
        self.drawerID = drawerID
        self.estateUUID = estateUUID
        self.text = text
        self.embeddingModelID = embeddingModelID
        self.capturedAtISO8601 = Self.makeISO8601().string(from: capturedAt)
    }

    /// The capture instant decoded back from `capturedAtISO8601`, or the Unix
    /// epoch if the stored string is unparseable (defensive — a malformed
    /// timestamp must not crash the worker; epoch keeps ingest deterministic).
    public var capturedAt: Date {
        Self.makeISO8601().date(from: capturedAtISO8601) ?? Date(timeIntervalSince1970: 0)
    }

    /// A fresh ISO8601 formatter for encode/decode. `internetDateTime` with
    /// fractional seconds so sub-second capture instants round-trip exactly.
    /// Built per call rather than cached as a static: `ISO8601DateFormatter` is
    /// not `Sendable`, so a shared mutable static would break strict
    /// concurrency. Encode/decode here is not hot (one call per capture).
    private static func makeISO8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    // MARK: - QueueKit Job bridging

    /// Encode this payload into a QueueKit `Job` ready to `send`.
    ///
    /// The payload is JSON-encoded into `Job.payload` (QueueKit base64url-wraps
    /// it on the wire). `streamID` is the estate-scoped encode stream so a
    /// drained job correlates to its estate; `submittedAt` is the supplied HLC.
    ///
    /// - Parameters:
    ///   - streamID: The estate's encode stream id.
    ///   - submittedAt: HLC stamp for queue ordering.
    ///   - priority: Job priority (defaults to QueueKit's 50).
    /// - Returns: A `Job` whose payload decodes back to this EncodeJob.
    /// - Throws: An encoding error if the payload cannot be JSON-encoded.
    public func toJob(
        streamID: StreamID,
        submittedAt: HLC,
        priority: Int = 50
    ) throws -> Job {
        let data = try JSONEncoder().encode(self)
        return Job(
            id: JobID.generate(),
            streamID: streamID,
            submittedAt: submittedAt,
            priority: priority,
            payload: data
        )
    }

    /// Decode an EncodeJob back from a drained QueueKit `Job`.
    ///
    /// - Parameter job: The job returned by `QueueKit.drain()`.
    /// - Returns: The decoded EncodeJob.
    /// - Throws: A decoding error if `job.payload` is not a valid EncodeJob.
    public static func from(job: Job) throws -> EncodeJob {
        try JSONDecoder().decode(EncodeJob.self, from: job.payload)
    }
}
