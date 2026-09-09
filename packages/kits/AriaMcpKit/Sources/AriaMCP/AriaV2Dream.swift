import AriaMCPWire
import Foundation
import GeniusLocusKit
import NeuronKit

/// Typed Mission02 seam for `moot_dream`.  Selected-surface admission owns the
/// caller, selected estate, and clock; this file neither invokes a v1 runner
/// nor infers a scheduler state from a completed lower-engine receipt.
public enum AriaV2Dream {
    public static let toolName = "moot_dream"

    /// The v2 operation deliberately has no caller-supplied clock.  The
    /// authority injects the instant it authorized, keeping direct dreaming
    /// deterministic without accepting an unbounded public time selector.
    public struct Request: Sendable, Equatable {
        public let estateID: UUID?

        public init(arguments: JSONValue) throws {
            let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["estate_id"])
            estateID = try decoder.optionalUUID("estate_id")
        }
    }

    /// The selected estate proof passed unchanged to the lower engine.
    public struct Admission: Sendable {
        public let estateID: UUID
        public let handle: EstateHandle
        public let callerBinding: String
        public let authorizationGeneration: String
        public let now: Date

        public init(
            estateID: UUID,
            handle: EstateHandle,
            callerBinding: String,
            authorizationGeneration: String,
            now: Date
        ) {
            self.estateID = estateID
            self.handle = handle
            self.callerBinding = callerBinding
            self.authorizationGeneration = authorizationGeneration
            self.now = now
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        case refusal(AriaV2OperationalRefusal)

        var refusal: AriaV2OperationalRefusal {
            switch self { case .refusal(let value): value }
        }
    }

    /// Selection and generation checks belong to the selected surface.  A
    /// refusal is an operation result, distinct from malformed arguments.
    public protocol Authority: Sendable {
        func admit(requestedEstateID: UUID?) async -> Result<Admission, Failure>
        func revalidate(_ admission: Admission) async -> Result<Void, Failure>
    }

    /// These are source statuses, not service-invented lifecycle states.  The
    /// direct kit adapter currently returns only `.completed`; a resident or
    /// queue owner may return its observed active, already-running, or queued
    /// state without having it rewritten to completed.
    public enum SourceStatus: String, Sendable, Equatable {
        case completed
        case active
        case alreadyRunning = "already_running"
        case queued
    }

    public struct CycleReceipt: Sendable, Equatable {
        public let candidatesConsidered: Int
        public let proposalsEmitted: [String]
        public let suppressedDuplicates: Int
        public let belowThreshold: Int
        public let contradictionsProposed: Int
        public let contradictionCandidatesBorderline: Int
        public let subjectsBackfilled: Int?
        public let associationsWritten: Int?
        public let associationsNonUniqueProbes: Int?

        public init(
            candidatesConsidered: Int,
            proposalsEmitted: [String],
            suppressedDuplicates: Int,
            belowThreshold: Int,
            contradictionsProposed: Int,
            contradictionCandidatesBorderline: Int,
            subjectsBackfilled: Int? = nil,
            associationsWritten: Int? = nil,
            associationsNonUniqueProbes: Int? = nil
        ) {
            self.candidatesConsidered = candidatesConsidered
            self.proposalsEmitted = proposalsEmitted
            self.suppressedDuplicates = suppressedDuplicates
            self.belowThreshold = belowThreshold
            self.contradictionsProposed = contradictionsProposed
            self.contradictionCandidatesBorderline = contradictionCandidatesBorderline
            self.subjectsBackfilled = subjectsBackfilled
            self.associationsWritten = associationsWritten
            self.associationsNonUniqueProbes = associationsNonUniqueProbes
        }

        init(
            report: DreamingCycleReport,
            hunt: ContradictionHuntReport,
            subjectsBackfilled: Int?,
            association: AssociateSweepReport
        ) {
            self.init(
                candidatesConsidered: report.candidatesConsidered,
                proposalsEmitted: report.proposalsEmitted.map(\.target),
                suppressedDuplicates: report.suppressedDuplicates,
                belowThreshold: report.belowThreshold,
                contradictionsProposed: hunt.proposed.count,
                contradictionCandidatesBorderline: hunt.borderline.count,
                subjectsBackfilled: subjectsBackfilled,
                associationsWritten: association.written,
                associationsNonUniqueProbes: association.nonUniqueProbes)
        }
    }

    public enum SourceOutcome: Sendable, Equatable {
        case completed(CycleReceipt)
        case active
        case alreadyRunning
        case queued

        var status: SourceStatus {
            switch self {
            case .completed: .completed
            case .active: .active
            case .alreadyRunning: .alreadyRunning
            case .queued: .queued
            }
        }

        var receipt: CycleReceipt? {
            guard case .completed(let receipt) = self else { return nil }
            return receipt
        }
    }

    /// Direct lower boundary.  Implementations receive a typed selected-estate
    /// admission and return lower status values; no legacy `ToolResult`, JSON,
    /// or rendered text crosses this boundary.
    public protocol Lower: Sendable {
        func run(_ admission: Admission, request: Request) async -> Result<SourceOutcome, Failure>
    }

    /// Source-faithful adapter over the live GeniusLocus/NeuronKit seams used
    /// by the existing dream cycle.  It performs the matrix rebuild and then
    /// returns the actual `DreamingCycleReport` receipt from the lower engine.
    public struct GeniusLocusLower: Lower {
        public let kit: GeniusLocusKit

        public init(kit: GeniusLocusKit) {
            self.kit = kit
        }

        public func run(
            _ admission: Admission,
            request: Request
        ) async -> Result<SourceOutcome, Failure> {
            guard request.estateID == nil || request.estateID == admission.estateID else {
                return .failure(.refusal(.init(
                    code: "estate_unavailable",
                    message: "The requested estate is not available to this caller.",
                    retryable: false)))
            }

            do {
                try await kit.rebuildDerivedAccelerators(for: admission.handle, now: admission.now)
                let daemon = NeuronKit.dreamingDaemon(
                    reader: EstateDreamingReader(handle: admission.handle, kit: kit),
                    sink: EstateDreamingSink(handle: admission.handle, kit: kit),
                    policyStore: InMemoryDreamingPolicyStore())
                let report = try await daemon.triggerDreamingCycle(now: admission.now)
                let hunt = try await kit.huntContradictions(
                    in: admission.handle, probeLimit: 500, now: admission.now)
                let association = try await kit.associateSweep(
                    in: admission.handle,
                    probeLimit: VectorSimilaritySignal.defaultProbeLimit,
                    now: admission.now)
                let subjectsBackfilled: Int?
                if await kit.subjectProducerPipeline(for: admission.handle) != nil {
                    let estate = try await kit.estate(for: admission.handle)
                    if try await estate.countSubjectDebt() > 0 {
                        subjectsBackfilled = try await kit.subjectBackfillSweep(
                            admission.handle, batchLimit: 32, now: admission.now).written
                    } else {
                        subjectsBackfilled = nil
                    }
                } else {
                    subjectsBackfilled = nil
                }
                return .success(.completed(.init(
                    report: report, hunt: hunt, subjectsBackfilled: subjectsBackfilled,
                    association: association)))
            } catch {
                return .failure(.refusal(.init(
                    code: "dream_unavailable",
                    message: "The selected estate could not complete its dreaming cycle.",
                    retryable: true)))
            }
        }
    }

    /// V2 envelope owner for the unregistered lower lane.  The status in the
    /// result comes exclusively from `Lower`, and authority is revalidated
    /// before a completed or scheduler-owned status leaves the process.
    public struct Service<A: Authority, L: Lower>: Sendable {
        public let authority: A
        public let lower: L

        public init(authority: A, lower: L) {
            self.authority = authority
            self.lower = lower
        }

        public func execute(arguments: JSONValue) async throws -> JSONValue {
            try await execute(try Request(arguments: arguments))
        }

        public func execute(_ request: Request) async throws -> JSONValue {
            let admission: Admission
            switch await authority.admit(requestedEstateID: request.estateID) {
            case .success(let value): admission = value
            case .failure(let failure): return AriaV2Envelope.refusal(tool: toolName, error: failure.refusal)
            }
            switch await lower.run(admission, request: request) {
            case .failure(let failure): return AriaV2Envelope.refusal(tool: toolName, error: failure.refusal)
            case .success(let outcome):
                switch await authority.revalidate(admission) {
                case .success: return render(outcome)
                case .failure(let failure): return AriaV2Envelope.refusal(tool: toolName, error: failure.refusal)
                }
            }
        }

        private func render(_ outcome: SourceOutcome) -> JSONValue {
            guard let receipt = outcome.receipt else {
                return AriaV2Envelope.refusal(
                    tool: toolName,
                    error: .init(
                        code: "dream_\(outcome.status.rawValue)",
                        message: compactText(for: outcome.status),
                        retryable: outcome.status != .alreadyRunning))
            }
            var data: [String: JSONValue] = [
                "candidatesConsidered": .integer(Int64(receipt.candidatesConsidered)),
                "proposalsEmitted": .array(receipt.proposalsEmitted.map(JSONValue.string)),
                "suppressedDuplicates": .integer(Int64(receipt.suppressedDuplicates)),
                "belowThreshold": .integer(Int64(receipt.belowThreshold)),
                "contradictionsProposed": .integer(Int64(receipt.contradictionsProposed)),
                "contradictionCandidatesBorderline": .integer(Int64(receipt.contradictionCandidatesBorderline)),
            ]
            if let value = receipt.subjectsBackfilled { data["subjectsBackfilled"] = .integer(Int64(value)) }
            if let value = receipt.associationsWritten { data["associationsWritten"] = .integer(Int64(value)) }
            if let value = receipt.associationsNonUniqueProbes { data["associationsNonUniqueProbes"] = .integer(Int64(value)) }
            return AriaV2Envelope.success(
                tool: toolName,
                effect: .write,
                data: .object(data),
                meta: ["completeness": .string("incomplete"), "status": .string(outcome.status.rawValue)],
                compactText: compactText(for: outcome.status))
        }

        private func compactText(for status: SourceStatus) -> String {
            switch status {
            case .completed: "Dreaming cycle completed."
            case .active: "Dreaming cycle is active."
            case .alreadyRunning: "A dreaming cycle is already running."
            case .queued: "Dreaming cycle is queued."
            }
        }
    }
}
