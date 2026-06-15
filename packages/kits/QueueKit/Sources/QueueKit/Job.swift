// Job.swift
//
// Per QUEUEKIT_SPEC §7. Job, identifier types, ArtifactRef,
// MissionContext, and the snake_case JSON wire format from §6.

import Foundation
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
import SubstrateTypes

public struct JobID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Create a fresh JobID as a UUID rendered to 32 lowercase hex
    /// characters with no hyphens, per spec §6.
    public static func generate() -> JobID {
        let uuid = UUID().uuid
        var hex = ""
        for byte in [uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7,
                     uuid.8, uuid.9, uuid.10, uuid.11, uuid.12, uuid.13, uuid.14, uuid.15] {
            hex += String(format: "%02x", byte)
        }
        return JobID(rawValue: hex)
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct StreamID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct SessionID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func mint() -> SessionID {
        SessionID(rawValue: UUID().uuidString.lowercased())
    }
}

public struct ToolName: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum ArtifactRef: Sendable, Hashable, Codable {
    case filePath(String)
    case commitHash(String)
    case signalFile(String)
    case trajectoryStepID(String)

    private enum CodingKeys: String, CodingKey { case type, value }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .filePath(let v):
            try c.encode("file_path", forKey: .type)
            try c.encode(v, forKey: .value)
        case .commitHash(let v):
            try c.encode("commit_hash", forKey: .type)
            try c.encode(v, forKey: .value)
        case .signalFile(let v):
            try c.encode("signal_file", forKey: .type)
            try c.encode(v, forKey: .value)
        case .trajectoryStepID(let v):
            try c.encode("trajectory_step_id", forKey: .type)
            try c.encode(v, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let value = try c.decode(String.self, forKey: .value)
        switch type {
        case "file_path": self = .filePath(value)
        case "commit_hash": self = .commitHash(value)
        case "signal_file": self = .signalFile(value)
        case "trajectory_step_id": self = .trajectoryStepID(value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown ArtifactRef type \(type)")
        }
    }
}

/// Caller-defined extensions blob. Strings, ints, doubles, booleans,
/// nulls, arrays, and nested objects survive a `send()`/`drain()`
/// round-trip verbatim per spec §6 and Area 5.
public indirect enum CodableValue: Sendable, Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([CodableValue])
    case object([String: CodableValue])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([CodableValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: CodableValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unrecognised CodableValue")
    }
}

public struct Job: Sendable, Codable, Identifiable, Hashable {
    public let id: JobID
    public let streamID: StreamID
    public let submittedAt: HLC
    public let priority: Int
    public let payload: Data
    public var extensions: [String: CodableValue]

    public init(
        id: JobID,
        streamID: StreamID,
        submittedAt: HLC,
        priority: Int = 50,
        payload: Data,
        extensions: [String: CodableValue] = [:]
    ) {
        self.id = id
        self.streamID = streamID
        self.submittedAt = submittedAt
        self.priority = priority
        self.payload = payload
        self.extensions = extensions
    }

    // MARK: - Wire format (spec §6)

    private enum CodingKeys: String, CodingKey {
        case id, stream_id, submitted_at, priority, payload, extensions
    }

    private enum HLCKeys: String, CodingKey {
        case physical_time, logical_count, node_id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = JobID(rawValue: try c.decode(String.self, forKey: .id))
        self.streamID = StreamID(
            rawValue: try c.decode(String.self, forKey: .stream_id))
        let h = try c.nestedContainer(keyedBy: HLCKeys.self, forKey: .submitted_at)
        let phys = try h.decode(Int64.self, forKey: .physical_time)
        let logical = try h.decode(Int32.self, forKey: .logical_count)
        let nodeUnsigned = try h.decode(UInt32.self, forKey: .node_id)
        self.submittedAt = HLC(
            physicalTime: phys,
            logicalCount: logical,
            nodeID: Int32(bitPattern: nodeUnsigned))
        self.priority = try c.decode(Int.self, forKey: .priority)
        let payloadB64 = try c.decode(String.self, forKey: .payload)
        self.payload = Self.base64urlDecode(payloadB64) ?? Data()
        self.extensions = try c.decode(
            [String: CodableValue].self, forKey: .extensions)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.rawValue, forKey: .id)
        try c.encode(streamID.rawValue, forKey: .stream_id)
        var h = c.nestedContainer(keyedBy: HLCKeys.self, forKey: .submitted_at)
        try h.encode(submittedAt.physicalTime, forKey: .physical_time)
        try h.encode(submittedAt.logicalCount, forKey: .logical_count)
        try h.encode(UInt32(bitPattern: submittedAt.nodeID), forKey: .node_id)
        try c.encode(priority, forKey: .priority)
        try c.encode(Self.base64urlEncode(payload), forKey: .payload)
        try c.encode(extensions, forKey: .extensions)
    }

    // MARK: - base64url (RFC 4648 §5), no padding

    public static func base64urlEncode(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        var out = b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while out.hasSuffix("=") { out.removeLast() }
        return out
    }

    public static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        return Data(base64Encoded: b64)
    }
}

public struct MissionContext: Sendable, Codable, Hashable {
    public let missionPath: String
    public let worktree: String
    public let branch: String
    public let autonomyProfile: String
    public let riskClass: String
    public let baseCommit: String
    public let priorTrajectoryID: String?
    public let inheritedSkills: [String]

    public init(
        missionPath: String,
        worktree: String,
        branch: String,
        autonomyProfile: String,
        riskClass: String,
        baseCommit: String,
        priorTrajectoryID: String? = nil,
        inheritedSkills: [String] = []
    ) {
        self.missionPath = missionPath
        self.worktree = worktree
        self.branch = branch
        self.autonomyProfile = autonomyProfile
        self.riskClass = riskClass
        self.baseCommit = baseCommit
        self.priorTrajectoryID = priorTrajectoryID
        self.inheritedSkills = inheritedSkills
    }
}

// MARK: - Filename encoding (spec §6)

public enum WireFormat {
    /// Build the canonical filename for a job per spec §6.
    public static func filename(for job: Job) -> String {
        let hlc = sortableHLC(job.submittedAt)
        return "\(hlc)-\(job.streamID.rawValue)-\(job.id.rawValue)"
    }

    /// `{physicalTime:016d}-{logicalCount:08d}-{nodeID_unsigned:010d}`
    /// per spec §6 filename encoding.
    public static func sortableHLC(_ hlc: HLC) -> String {
        let phys = String(format: "%016lld", hlc.physicalTime)
        let logical = String(format: "%08d", hlc.logicalCount)
        let node = String(
            format: "%010u", UInt32(bitPattern: hlc.nodeID))
        return "\(phys)-\(logical)-\(node)"
    }

    /// Canonical JSON encoder used for both job and signal files.
    /// Sorted keys + no extra whitespace produce byte-stable output
    /// across Swift, Rust, and Python implementations.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}

// MARK: - Signal file encoding (spec §6)

public struct SignalFile: Sendable, Codable {
    public let jobID: JobID
    public let status: ObservationStatus
    public let artifacts: [ArtifactRef]
    public let completedAt: HLC

    public init(
        jobID: JobID,
        status: ObservationStatus,
        artifacts: [ArtifactRef],
        completedAt: HLC
    ) {
        self.jobID = jobID
        self.status = status
        self.artifacts = artifacts
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case job_id, status, artifacts, completed_at
    }

    private enum HLCKeys: String, CodingKey {
        case physical_time, logical_count, node_id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jobID = JobID(rawValue: try c.decode(String.self, forKey: .job_id))
        self.status = try c.decode(ObservationStatus.self, forKey: .status)
        self.artifacts = try c.decode([ArtifactRef].self, forKey: .artifacts)
        let h = try c.nestedContainer(
            keyedBy: HLCKeys.self, forKey: .completed_at)
        let phys = try h.decode(Int64.self, forKey: .physical_time)
        let logical = try h.decode(Int32.self, forKey: .logical_count)
        let nodeUnsigned = try h.decode(UInt32.self, forKey: .node_id)
        self.completedAt = HLC(
            physicalTime: phys,
            logicalCount: logical,
            nodeID: Int32(bitPattern: nodeUnsigned))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobID.rawValue, forKey: .job_id)
        try c.encode(status, forKey: .status)
        try c.encode(artifacts, forKey: .artifacts)
        var h = c.nestedContainer(keyedBy: HLCKeys.self, forKey: .completed_at)
        try h.encode(completedAt.physicalTime, forKey: .physical_time)
        try h.encode(completedAt.logicalCount, forKey: .logical_count)
        try h.encode(UInt32(bitPattern: completedAt.nodeID), forKey: .node_id)
    }
}
