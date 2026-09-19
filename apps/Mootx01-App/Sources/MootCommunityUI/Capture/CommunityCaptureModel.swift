import Foundation
import Observation

public struct CommunityCaptureDestination: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public enum CommunityCaptureSensitivity: String, Sendable, Equatable, CaseIterable, Identifiable {
    case normal
    case elevated
    case restricted
    case secret

    public var id: String { rawValue }

    /// Human display name for default-visible UI (picker rows, receipts).
    /// The wire vocabulary ("normal", "elevated", …) stays in the daemon
    /// contract; it never reaches a label (census R-C2/R-C3).
    public var displayName: String {
        switch self {
        case .normal: String(localized: "Normal sensitivity")
        case .elevated: String(localized: "Elevated sensitivity")
        case .restricted: String(localized: "Restricted sensitivity")
        case .secret: String(localized: "Secret sensitivity")
        }
    }

    /// VoiceOver reads the same human name the eye sees.
    public var accessibilityLabel: String { displayName }

    public var accessibilityConsequence: String {
        String(
            localized: "The resident daemon applies this sensitivity to the capture's canonical policy."
        )
    }
}

public struct CommunityCapturePolicy: Sendable, Equatable {
    public let destination: CommunityCaptureDestination
    public let sensitivity: CommunityCaptureSensitivity
    public let exportEligible: Bool
    public let lanEligible: Bool

    public init(
        destination: CommunityCaptureDestination,
        sensitivity: CommunityCaptureSensitivity,
        exportEligible: Bool,
        lanEligible: Bool
    ) {
        self.destination = destination
        self.sensitivity = sensitivity
        self.exportEligible = exportEligible
        self.lanEligible = lanEligible
    }
}

public struct CommunityCaptureChoices: Sendable, Equatable {
    public let destinations: [CommunityCaptureDestination]
    public let sensitivities: [CommunityCaptureSensitivity]
    public let defaultPolicy: CommunityCapturePolicy

    public init(
        destinations: [CommunityCaptureDestination],
        sensitivities: [CommunityCaptureSensitivity],
        defaultPolicy: CommunityCapturePolicy
    ) {
        self.destinations = destinations
        self.sensitivities = sensitivities
        self.defaultPolicy = defaultPolicy
    }
}

public struct CommunityCaptureRequest: Sendable, Equatable {
    public let requestID: UUID
    public let subject: String
    public let body: String
    public let policy: CommunityCapturePolicy

    public init(
        requestID: UUID,
        subject: String,
        body: String,
        policy: CommunityCapturePolicy
    ) {
        self.requestID = requestID
        self.subject = subject
        self.body = body
        self.policy = policy
    }
}

public struct CommunityCaptureReceipt: Sendable, Equatable {
    public let recordID: UUID
    public let effectivePolicy: CommunityCapturePolicy

    public init(recordID: UUID, effectivePolicy: CommunityCapturePolicy) {
        self.recordID = recordID
        self.effectivePolicy = effectivePolicy
    }
}

public enum CommunityCaptureRefusedField: String, Sendable, Equatable {
    case destination
    case sensitivity
    case exportEligibility = "export-eligibility"
    case lanEligibility = "lan-eligibility"
    case content
    case daemon

    /// Human name of the refused capture setting, e.g. "Export eligibility".
    /// The wire slug ("export-eligibility") never reaches the display layer
    /// (census R-C4).
    public var displayName: String {
        switch self {
        case .destination: String(localized: "Destination")
        case .sensitivity: String(localized: "Sensitivity")
        case .exportEligibility: String(localized: "Export eligibility")
        case .lanEligibility: String(localized: "LAN sharing eligibility")
        case .content: String(localized: "Content")
        case .daemon: String(localized: "Resident daemon")
        }
    }
}

public enum CommunityCaptureOutcome: Sendable, Equatable {
    case applied(CommunityCaptureReceipt)
    case refused(field: CommunityCaptureRefusedField, reason: String)
    case failed(reason: String)
}

public protocol CommunityCaptureServicing: Actor, Sendable {
    func choices() async -> Result<CommunityCaptureChoices, CommunityCaptureServiceError>
    func capture(_ request: CommunityCaptureRequest) async -> CommunityCaptureOutcome
}

public enum CommunityCaptureServiceError: Error, Sendable, Equatable {
    case unavailable
    case malformedResponse
}

public actor UnavailableCommunityCaptureService: CommunityCaptureServicing {
    public init() {}
    public func choices() async -> Result<CommunityCaptureChoices, CommunityCaptureServiceError> {
        .failure(.unavailable)
    }
    public func capture(_ request: CommunityCaptureRequest) async -> CommunityCaptureOutcome {
        .failed(reason: "daemon-unavailable")
    }
}

@MainActor
@Observable
public final class CommunityCaptureModel {
    public var subject = ""
    public var body = ""
    public var selectedDestinationID: String?
    public var sensitivity: CommunityCaptureSensitivity = .normal
    public var exportEligible = false
    public var lanEligible = false
    public private(set) var choices: CommunityCaptureChoices?
    public private(set) var outcome: CommunityCaptureOutcome?
    public private(set) var isLoading = false
    public private(set) var isSubmitting = false
    private let service: any CommunityCaptureServicing
    private var hasInitializedPolicy = false
    private var pendingRequestID: UUID?

    public init(service: any CommunityCaptureServicing) {
        self.service = service
    }

    public var selectedDestination: CommunityCaptureDestination? {
        choices?.destinations.first { $0.id == selectedDestinationID }
    }

    public var selectedDestinationAccessibilityValue: String {
        selectedDestination?.title ?? String(localized: "No destination selected")
    }

    public var selectedDestinationAccessibilityHint: String {
        selectedDestination?.detail
            ?? String(localized: "Choose a destination supplied by the resident daemon.")
    }

    public var sensitivityAccessibilityValue: String {
        sensitivity.accessibilityLabel
    }

    public var sensitivityAccessibilityHint: String {
        sensitivity.accessibilityConsequence
    }

    public var canSubmit: Bool {
        !isSubmitting
            && selectedDestination != nil
            && choices?.sensitivities.contains(sensitivity) == true
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var policyNeedsReview: Bool {
        guard let choices else { return false }
        return selectedDestination == nil || !choices.sensitivities.contains(sensitivity)
    }

    public func loadChoices() async {
        guard !isLoading else { return }
        isLoading = true
        switch await service.choices() {
        case .success(let supplied):
            let priorDestinationID = selectedDestinationID
            let priorSensitivity = sensitivity
            choices = supplied
            if hasInitializedPolicy {
                let destinationRemainsValid = supplied.destinations.contains {
                    $0.id == priorDestinationID
                }
                selectedDestinationID = destinationRemainsValid ? priorDestinationID : nil
                sensitivity = priorSensitivity
            } else {
                selectedDestinationID = supplied.defaultPolicy.destination.id
                sensitivity = supplied.defaultPolicy.sensitivity
                exportEligible = supplied.defaultPolicy.exportEligible
                lanEligible = supplied.defaultPolicy.lanEligible
                hasInitializedPolicy = true
            }
            outcome = nil
        case .failure:
            choices = nil
            outcome = .failed(reason: "daemon-unavailable")
        }
        isLoading = false
    }

    public func submit() async {
        guard canSubmit, let destination = selectedDestination else { return }
        isSubmitting = true
        let requestID = pendingRequestID ?? UUID()
        pendingRequestID = requestID
        let request = CommunityCaptureRequest(
            requestID: requestID,
            subject: subject,
            body: body,
            policy: CommunityCapturePolicy(
                destination: destination,
                sensitivity: sensitivity,
                exportEligible: exportEligible,
                lanEligible: lanEligible
            )
        )
        let result = await service.capture(request)
        outcome = result
        switch result {
        case .applied:
            pendingRequestID = nil
            subject = ""
            body = ""
        case .refused:
            // The daemon proved that no capture was applied. A corrected
            // request is a new attempt and receives a new idempotency key.
            pendingRequestID = nil
        case .failed:
            // Delivery may be uncertain. Preserve the request identity so the
            // daemon can recognize an exact retry where its contract supports
            // that check; this does not claim that every capture is exactly-once.
            break
        }
        isSubmitting = false
    }
}
