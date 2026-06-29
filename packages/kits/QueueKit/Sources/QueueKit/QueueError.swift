// QueueError.swift
//
// Error vocabulary per QUEUEKIT_SPEC §7.

import Foundation

public enum QueueError: Error, Sendable {
    case directoryCreationFailed(path: String, underlying: Error)
    case writeFailed(underlying: Error)
    case renameFailed(from: String, to: String, underlying: Error)
    case decodingFailed(jobID: JobID, underlying: Error)
    case unknownTool(ToolName)
    case jobNotFound(JobID)
    case watcherFailed(underlying: Error)
    case staleTmpFile(path: String, age: TimeInterval)
    case backendUnavailable(detail: String)
    case invalidTerminalStatus(ObservationStatus)
    /// `awaitDrain(...)` exceeded its timeout with work still on either
    /// frontier. Carries the last-observed depths so a caller can log how
    /// far the queue was from empty when it gave up (a non-zero `inFlight`
    /// points at a stalled drain worker; a non-zero `pending` at a worker
    /// that never claimed).
    case drainTimeout(pending: Int, inFlight: Int)
    /// A stream_id, job id, or other caller-supplied identifier contains
    /// a path separator (`/`, `\`), equals `.` or `..`, or contains an
    /// ASCII control character. Such identifiers can escape the queue root
    /// when used as filename components. Planned security hardening.
    case invalidIdentifier(id: String, reason: String)
}
