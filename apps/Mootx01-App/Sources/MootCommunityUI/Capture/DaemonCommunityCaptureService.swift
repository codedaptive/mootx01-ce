import Foundation
import MootCommunityGateway

/// The frozen Community capture wire adapter.
///
/// It carries policy choices and capture requests over the already
/// authenticated resident-daemon caller. Unknown or incomplete payloads fail
/// closed; there are no app-authored destinations or privacy defaults.
public actor DaemonCommunityCaptureService: CommunityCaptureServicing {
    private var caller: (any MootEstateCalling)?

    public init() {}

    public func attach(_ caller: (any MootEstateCalling)?) {
        self.caller = caller
    }

    public func choices() async -> Result<CommunityCaptureChoices, CommunityCaptureServiceError> {
        guard let caller else { return .failure(.unavailable) }
        let result = await caller.callToolFull("moot_community_capture_choices", arguments: [:])
        guard !result.isError,
              let object = result.structured?.objectValue,
              let destinationValues = object["destinations"]?.arrayValue,
              let sensitivityValues = object["sensitivities"]?.arrayValue,
              let defaults = object["defaultPolicy"]?.objectValue else {
            return .failure(.malformedResponse)
        }

        let destinations = destinationValues.compactMap(Self.destination)
        let sensitivities = sensitivityValues.compactMap { value in
            value.stringValue.flatMap(CommunityCaptureSensitivity.init(rawValue:))
        }
        guard destinations.count == destinationValues.count,
              sensitivities.count == sensitivityValues.count,
              let defaultDestinationID = defaults["destinationID"]?.stringValue,
              let defaultDestination = destinations.first(where: { $0.id == defaultDestinationID }),
              let defaultSensitivityRaw = defaults["sensitivity"]?.stringValue,
              let defaultSensitivity = CommunityCaptureSensitivity(rawValue: defaultSensitivityRaw),
              sensitivities.contains(defaultSensitivity),
              let exportEligible = defaults["exportEligible"]?.boolValue,
              let lanEligible = defaults["lanEligible"]?.boolValue else {
            return .failure(.malformedResponse)
        }

        let policy = CommunityCapturePolicy(
            destination: defaultDestination,
            sensitivity: defaultSensitivity,
            exportEligible: exportEligible,
            lanEligible: lanEligible
        )
        return .success(CommunityCaptureChoices(
            destinations: destinations,
            sensitivities: sensitivities,
            defaultPolicy: policy
        ))
    }

    public func capture(_ request: CommunityCaptureRequest) async -> CommunityCaptureOutcome {
        guard let caller else { return .failed(reason: "daemon-unavailable") }
        let result = await caller.callToolFull("moot_community_capture", arguments: [
            "requestID": .string(request.requestID.uuidString),
            "subject": .string(request.subject),
            "content": .string(request.body),
            "destinationID": .string(request.policy.destination.id),
            "sensitivity": .string(request.policy.sensitivity.rawValue),
            "exportEligible": .bool(request.policy.exportEligible),
            "lanEligible": .bool(request.policy.lanEligible),
        ])
        guard !result.isError, let object = result.structured?.objectValue,
              let outcome = object["outcome"]?.stringValue else {
            return .failed(reason: "daemon-call-failed")
        }

        if outcome == "refused",
           let fieldRaw = object["field"]?.stringValue,
           let field = CommunityCaptureRefusedField(rawValue: fieldRaw),
           let reason = object["reason"]?.stringValue {
            return .refused(field: field, reason: reason)
        }
        guard outcome == "applied",
              let recordRaw = object["recordID"]?.stringValue,
              let recordID = UUID(uuidString: recordRaw),
              let policyObject = object["effectivePolicy"]?.objectValue,
              let policy = Self.policy(policyObject) else {
            return .failed(reason: "malformed-daemon-response")
        }
        return .applied(CommunityCaptureReceipt(recordID: recordID, effectivePolicy: policy))
    }

    private static func destination(_ value: JSONValue) -> CommunityCaptureDestination? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let title = object["title"]?.stringValue,
              let detail = object["detail"]?.stringValue else { return nil }
        return CommunityCaptureDestination(id: id, title: title, detail: detail)
    }

    private static func policy(_ object: [String: JSONValue]) -> CommunityCapturePolicy? {
        guard let destinationValue = object["destination"],
              let destination = destination(destinationValue),
              let sensitivityRaw = object["sensitivity"]?.stringValue,
              let sensitivity = CommunityCaptureSensitivity(rawValue: sensitivityRaw),
              let exportEligible = object["exportEligible"]?.boolValue,
              let lanEligible = object["lanEligible"]?.boolValue else { return nil }
        return CommunityCapturePolicy(
            destination: destination,
            sensitivity: sensitivity,
            exportEligible: exportEligible,
            lanEligible: lanEligible
        )
    }
}
