// QueueBackend.swift
//
// Per QUEUEKIT_SPEC §4. The protocol every backend conforms to.
// The public QueueKit class delegates all operations to its mounted
// backend.

import Foundation

public protocol QueueBackend: Sendable {
    func write(_ job: Job) async throws

    func drainAvailable() async throws -> [(job: Job, sessionID: SessionID)]

    func watch(
        handler: @escaping @Sendable (Job, SessionID) async throws -> Void
    ) async throws

    func complete(
        _ jobID: JobID,
        status: ObservationStatus,
        artifacts: [ArtifactRef]
    ) async throws

    func inFlight() async throws -> [Job]

    func completed(streamID: StreamID?) async throws -> [Job]
}
