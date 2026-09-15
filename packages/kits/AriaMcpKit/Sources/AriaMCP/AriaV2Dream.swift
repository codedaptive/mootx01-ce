import AriaMCPWire
import Foundation
import GeniusLocusKit
import NeuronKit

/// Typed Mission02 seam for `moot_dream`.  Selected-surface admission owns the
/// caller, selected estate, and clock; this file neither invokes a v1 runner
/// nor infers a scheduler state from a completed lower-engine receipt.
public enum AriaV2Dream {
    public static let toolName = "moot_dream"

    /// The v2 operation admits a caller-proposed clock instant and an
    /// association sweep mode.  The authority validates the proposed clock and
    /// may reject it; both fields are optional so existing callers that omit
    /// them continue to work without modification.
    public struct Request: Sendable, Equatable {
        public let estateID: UUID?
        /// A caller-proposed cycle clock.  Must be a valid ISO 8601 UTC string;
        /// malformed strings throw -32602 immediately.  The authority enforces a
        /// 24-hour future ceiling before admitting the instant.
        public let now: Date?
        /// Association sweep mode: "all" = full-estate pass (10_000 probe
        /// ceiling), "off" = skip the sweep entirely, nil or absent = default
        /// cadence (50 probes, defaultProbeLimit).
        public let associates: String?

        public init(arguments: JSONValue) throws {
            let decoder = try AriaV2ArgumentDecoder(
                arguments, allowedKeys: ["estate_id", "now", "associates"])
            estateID = try decoder.optionalUUID("estate_id")
            if let nowString = try decoder.optionalString("now") {
                let fmt = ISO8601DateFormatter()
                guard let parsed = fmt.date(from: nowString) else {
                    throw AriaV2InvalidArgument(
                        path: "now",
                        message: "Argument 'now' must be a valid ISO 8601 date-time string.",
                        correction: "Provide 'now' in the format YYYY-MM-DDTHH:MM:SSZ."
                    ).jsonRPCError
                }
                now = parsed
            } else {
                now = nil
            }
            // Normalise first, then validate. "OFF", "ALL", and "RECENT" are accepted
            // alongside their lowercase forms; any other value is refused with -32602
            // before the lower engine is reached, so no sweep runs on an unknown mode.
            if let rawAssociates = try decoder.optionalString("associates") {
                let normalised = rawAssociates.lowercased()
                guard normalised == "off" || normalised == "all" || normalised == "recent" else {
                    throw AriaV2InvalidArgument(
                        path: "associates",
                        message: "Argument 'associates' must be \"off\", \"all\", or \"recent\".",
                        allowed: ["off", "all", "recent"],
                        correction: "Use \"recent\" (default) for the 50-item cadence, \"all\" for a full-estate pass, or \"off\" to skip."
                    ).jsonRPCError
                }
                associates = normalised
            } else {
                associates = nil
            }
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
        /// Caller-supplied argument was structurally valid but semantically out
        /// of range (e.g. `now` more than 24 hours in the future).  In Swift,
        /// `executeV2Core` catches the thrown `JSONRPCError.invalidParams` and
        /// wraps it in a refusal envelope (isError: true).  In Rust, the service
        /// raises a transport-level -32602 error directly.  Both prevent
        /// destructive paths from being reached with an out-of-range clock.
        case invalidArgument(String)
    }

    /// Selection and generation checks belong to the selected surface.  A
    /// refusal is an operation result; an invalidArgument is a thrown error,
    /// distinct from both malformed input (thrown by Request.init) and runtime
    /// unavailability (returned as a refusal envelope).
    public protocol Authority: Sendable {
        func admit(requestedEstateID: UUID?, requestedNow: Date?) async -> Result<Admission, Failure>
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

        /// Full-estate association probe ceiling used when `associates="all"`.
        /// The named constant prevents the nil path (unbounded probing) while
        /// keeping the limit explicit and auditable.  Internal, not public:
        /// the tests reach it through `@testable import AriaMCP`, so the pin
        /// costs no public surface.  Parity with Rust:
        /// `DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE_PUB = 10_000` in recipe_tools.rs.
        static let allModeMaxProbe: Int = 10_000

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

                // Resolve association sweep probe limit from the `associates` mode:
                //   "all"    → full-estate pass, bounded by allModeMaxProbe (10_000)
                //   "off"    → skip the sweep entirely; associations fields are absent
                //   "recent" → same path as nil (defaultProbeLimit, 50 probes); named default
                //   nil      → same path as "recent"; absent value takes the default cadence
                // "recent" and nil are deliberately identical: the decoder admits "recent" and
                // stores it as "recent", but the runner's else-branch applies in both cases
                // because neither is "off" and neither is "all". Test
                // dreamAssociatesAbsentAndRecentAreIdentical in
                // DreamAssociatesDispatchTests.swift proves this through a
                // single-estate three-pass design: a first pass with associates absent
                // settles the estate, a second pass with "recent" probes the same
                // default window and adds zero new associations, a third pass with
                // "all" reaches past the default window and adds more. A probe-limit
                // divergence between the absent path and "recent" would cause the
                // second pass to reach drawers the first never probed, add more than
                // zero, and fail the gate.
                let associatesMode = request.associates?.lowercased()
                let associationsWritten: Int?
                let associationsNonUniqueProbes: Int?
                if associatesMode == "off" {
                    associationsWritten = nil
                    associationsNonUniqueProbes = nil
                } else {
                    let probeLimit = associatesMode == "all"
                        ? Self.allModeMaxProbe
                        : VectorSimilaritySignal.defaultProbeLimit
                    let sweep = try await kit.associateSweep(
                        in: admission.handle,
                        probeLimit: probeLimit,
                        now: admission.now)
                    associationsWritten = sweep.written
                    associationsNonUniqueProbes = sweep.nonUniqueProbes
                }

                let subjectsBackfilled: Int?
                if await kit.subjectProducerPipeline(for: admission.handle) != nil {
                    if try await kit.countSubjectDebt(in: admission.handle) > 0 {
                        subjectsBackfilled = try await kit.subjectBackfillSweep(
                            admission.handle, batchLimit: 32, now: admission.now).written
                    } else {
                        subjectsBackfilled = nil
                    }
                } else {
                    subjectsBackfilled = nil
                }
                return .success(.completed(.init(
                    candidatesConsidered: report.candidatesConsidered,
                    proposalsEmitted: report.proposalsEmitted.map(\.target),
                    suppressedDuplicates: report.suppressedDuplicates,
                    belowThreshold: report.belowThreshold,
                    contradictionsProposed: hunt.proposed.count,
                    contradictionCandidatesBorderline: hunt.borderline.count,
                    subjectsBackfilled: subjectsBackfilled,
                    associationsWritten: associationsWritten,
                    associationsNonUniqueProbes: associationsNonUniqueProbes)))
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
            switch await authority.admit(requestedEstateID: request.estateID, requestedNow: request.now) {
            case .success(let value): admission = value
            case .failure(.refusal(let r)):
                return AriaV2Envelope.refusal(tool: toolName, error: r)
            case .failure(.invalidArgument(let message)):
                // Semantic range violation on a structurally-valid argument: raise
                // -32602 so destructive paths (pruneRecallTraces, etc.) are never
                // reached with an out-of-range clock.
                throw AriaV2InvalidArgument(
                    path: "now",
                    message: message,
                    correction: "Provide a 'now' no more than 24 hours in the future."
                ).jsonRPCError
            }
            switch await lower.run(admission, request: request) {
            case .failure(.refusal(let r)):
                return AriaV2Envelope.refusal(tool: toolName, error: r)
            case .failure(.invalidArgument(let message)):
                throw AriaV2InvalidArgument(path: "now", message: message).jsonRPCError
            case .success(let outcome):
                switch await authority.revalidate(admission) {
                case .success: return render(outcome)
                case .failure(.refusal(let r)):
                    return AriaV2Envelope.refusal(tool: toolName, error: r)
                case .failure(.invalidArgument(let message)):
                    throw AriaV2InvalidArgument(path: "now", message: message).jsonRPCError
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
