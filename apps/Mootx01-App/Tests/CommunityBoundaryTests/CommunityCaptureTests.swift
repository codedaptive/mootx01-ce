import Foundation
import MootCommunityUI
import Testing

@Suite("Community capture placement and privacy")
struct CommunityCaptureTests {
    private let destination = CommunityCaptureDestination(
        id: "personal/capture",
        title: "Personal / Capture",
        detail: "Private inbox"
    )

    @MainActor
    @Test("choices and defaults come only from the daemon")
    func daemonChoices() async {
        let choices = makeChoices()
        let model = CommunityCaptureModel(service: CaptureFixture(choices: .success(choices)))

        await model.loadChoices()
        #expect(model.choices == choices)
        #expect(model.selectedDestinationID == destination.id)
        #expect(model.sensitivity == .restricted)
        #expect(!model.exportEligible)
        #expect(!model.lanEligible)
    }

    @MainActor
    @Test("reconnect cannot silently widen an unsaved capture policy")
    func reconnectPreservesPrivacyPolicy() async {
        let service = CaptureFixture(choices: .success(makeChoices()))
        let model = CommunityCaptureModel(service: service)
        await model.loadChoices()
        model.body = "Unsaved private draft"
        model.sensitivity = .elevated
        model.exportEligible = false
        model.lanEligible = false

        let widerDefault = CommunityCaptureChoices(
            destinations: [destination],
            sensitivities: [.normal, .elevated, .restricted],
            defaultPolicy: CommunityCapturePolicy(
                destination: destination,
                sensitivity: .normal,
                exportEligible: true,
                lanEligible: true
            )
        )
        await service.setChoices(.success(widerDefault))

        await model.loadChoices()

        #expect(model.body == "Unsaved private draft")
        #expect(model.selectedDestinationID == destination.id)
        #expect(model.sensitivity == .elevated)
        #expect(!model.exportEligible)
        #expect(!model.lanEligible)
        #expect(!model.policyNeedsReview)
        #expect(model.canSubmit)
    }

    @MainActor
    @Test("removed daemon policy choices block capture until the user reviews replacements")
    func removedChoicesRequireReview() async {
        let service = CaptureFixture(choices: .success(makeChoices()))
        let model = CommunityCaptureModel(service: service)
        await model.loadChoices()
        model.body = "Unsaved restricted draft"

        let replacement = CommunityCaptureDestination(
            id: "archive/reference",
            title: "Archive / Reference",
            detail: "Long-term reference"
        )
        let replacementChoices = CommunityCaptureChoices(
            destinations: [replacement],
            sensitivities: [.normal],
            defaultPolicy: CommunityCapturePolicy(
                destination: replacement,
                sensitivity: .normal,
                exportEligible: true,
                lanEligible: true
            )
        )
        await service.setChoices(.success(replacementChoices))

        await model.loadChoices()

        #expect(model.body == "Unsaved restricted draft")
        #expect(model.selectedDestinationID == nil)
        #expect(model.sensitivity == .restricted)
        #expect(!model.exportEligible)
        #expect(!model.lanEligible)
        #expect(model.policyNeedsReview)
        #expect(!model.canSubmit)

        model.selectedDestinationID = replacement.id
        model.sensitivity = .normal
        #expect(model.canSubmit)
    }

    @MainActor
    @Test("refusal identifies the policy field and preserves the complete draft")
    func refusalPreservesDraft() async {
        let service = CaptureFixture(
            choices: .success(makeChoices()),
            outcome: .refused(field: .lanEligibility, reason: "restricted-content")
        )
        let model = CommunityCaptureModel(service: service)
        await model.loadChoices()
        model.subject = "Subject"
        model.body = "Draft body"
        model.lanEligible = true

        await model.submit()

        #expect(model.subject == "Subject")
        #expect(model.body == "Draft body")
        #expect(model.outcome == .refused(field: .lanEligibility, reason: "restricted-content"))
    }

    @MainActor
    @Test("success clears the draft only after the daemon returns its effective policy")
    func confirmedCaptureClearsDraft() async {
        let effective = CommunityCapturePolicy(
            destination: destination,
            sensitivity: .elevated,
            exportEligible: false,
            lanEligible: false
        )
        let receipt = CommunityCaptureReceipt(
            recordID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            effectivePolicy: effective
        )
        let service = CaptureFixture(
            choices: .success(makeChoices()),
            outcome: .applied(receipt)
        )
        let model = CommunityCaptureModel(service: service)
        await model.loadChoices()
        model.subject = "Subject"
        model.body = "Draft body"

        await model.submit()

        #expect(model.subject.isEmpty)
        #expect(model.body.isEmpty)
        #expect(model.outcome == .applied(receipt))
        #expect(await service.requests.count == 1)
    }

    @MainActor
    @Test("every daemon-supported destination and privacy combination is forwarded unchanged")
    func supportedPolicyMatrix() async {
        let archive = CommunityCaptureDestination(
            id: "archive/reference",
            title: "Archive / Reference",
            detail: "Long-term reference"
        )
        let choices = CommunityCaptureChoices(
            destinations: [destination, archive],
            sensitivities: CommunityCaptureSensitivity.allCases,
            defaultPolicy: CommunityCapturePolicy(
                destination: destination,
                sensitivity: .normal,
                exportEligible: false,
                lanEligible: false
            )
        )
        let service = CaptureFixture(choices: .success(choices))
        let model = CommunityCaptureModel(service: service)
        await model.loadChoices()

        var expectedCount = 0
        for candidateDestination in choices.destinations {
            for sensitivity in choices.sensitivities {
                for exportEligible in [false, true] {
                    for lanEligible in [false, true] {
                        model.selectedDestinationID = candidateDestination.id
                        model.sensitivity = sensitivity
                        model.exportEligible = exportEligible
                        model.lanEligible = lanEligible
                        model.body = "Matrix capture"

                        await model.submit()
                        expectedCount += 1

                        let request = await service.requests.last
                        #expect(request?.policy == CommunityCapturePolicy(
                            destination: candidateDestination,
                            sensitivity: sensitivity,
                            exportEligible: exportEligible,
                            lanEligible: lanEligible
                        ))
                    }
                }
            }
        }
        #expect(await service.requests.count == expectedCount)
    }

    @MainActor
    @Test("an unknown destination cannot be submitted")
    func invalidDestinationIsBlocked() async {
        let service = CaptureFixture(choices: .success(makeChoices()))
        let model = CommunityCaptureModel(service: service)
        await model.loadChoices()
        model.body = "Preserve me"
        model.selectedDestinationID = "not-supplied-by-daemon"

        await model.submit()

        #expect(!model.canSubmit)
        #expect(model.body == "Preserve me")
        #expect(await service.requests.isEmpty)
    }

    @MainActor
    @Test("daemon failure preserves the draft and a retry can succeed")
    func failureThenRetry() async {
        let receipt = CommunityCaptureReceipt(
            recordID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            effectivePolicy: makeChoices().defaultPolicy
        )
        let service = CaptureFixture(
            choices: .success(makeChoices()),
            outcomes: [.failed(reason: "daemon-restarting"), .applied(receipt)]
        )
        let model = CommunityCaptureModel(service: service)
        await model.loadChoices()
        model.subject = "Retry subject"
        model.body = "Retry body"

        await model.submit()
        #expect(model.subject == "Retry subject")
        #expect(model.body == "Retry body")
        #expect(model.outcome == .failed(reason: "daemon-restarting"))

        await model.submit()
        #expect(model.subject.isEmpty)
        #expect(model.body.isEmpty)
        #expect(model.outcome == .applied(receipt))
        #expect(await service.requests.count == 2)
        let requests = await service.requests
        #expect(requests[0].requestID == requests[1].requestID)
    }

    @MainActor
    @Test("an explicit refusal releases the idempotency key for a corrected request")
    func refusalStartsNewCorrectedRequest() async {
        let receipt = CommunityCaptureReceipt(
            recordID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            effectivePolicy: makeChoices().defaultPolicy
        )
        let service = CaptureFixture(
            choices: .success(makeChoices()),
            outcomes: [
                .refused(field: .content, reason: "subject-required"),
                .applied(receipt),
            ]
        )
        let model = CommunityCaptureModel(service: service)
        await model.loadChoices()
        model.body = "Draft body"

        await model.submit()
        model.subject = "Corrected subject"
        await model.submit()

        let requests = await service.requests
        #expect(requests.count == 2)
        #expect(requests[0].requestID != requests[1].requestID)
        #expect(model.outcome == .applied(receipt))
    }

    @MainActor
    @Test("placement and sensitivity expose labels, values, and consequences")
    func accessibilityVocabulary() async {
        let model = CommunityCaptureModel(service: CaptureFixture(choices: .success(makeChoices())))
        await model.loadChoices()

        #expect(!model.selectedDestinationAccessibilityValue.isEmpty)
        #expect(!model.selectedDestinationAccessibilityHint.isEmpty)
        for sensitivity in CommunityCaptureSensitivity.allCases {
            model.sensitivity = sensitivity
            #expect(!model.sensitivityAccessibilityValue.isEmpty)
            #expect(!model.sensitivityAccessibilityHint.isEmpty)
        }
    }

    private func makeChoices() -> CommunityCaptureChoices {
        let policy = CommunityCapturePolicy(
            destination: destination,
            sensitivity: .restricted,
            exportEligible: false,
            lanEligible: false
        )
        return CommunityCaptureChoices(
            destinations: [destination],
            sensitivities: [.normal, .elevated, .restricted],
            defaultPolicy: policy
        )
    }
}

private actor CaptureFixture: CommunityCaptureServicing {
    private var suppliedChoices: Result<CommunityCaptureChoices, CommunityCaptureServiceError>
    private var suppliedOutcomes: [CommunityCaptureOutcome]
    private(set) var requests: [CommunityCaptureRequest] = []

    init(
        choices: Result<CommunityCaptureChoices, CommunityCaptureServiceError>,
        outcome: CommunityCaptureOutcome = .failed(reason: "not-configured")
    ) {
        suppliedChoices = choices
        suppliedOutcomes = [outcome]
    }

    init(
        choices: Result<CommunityCaptureChoices, CommunityCaptureServiceError>,
        outcomes: [CommunityCaptureOutcome]
    ) {
        suppliedChoices = choices
        suppliedOutcomes = outcomes
    }

    func choices() async -> Result<CommunityCaptureChoices, CommunityCaptureServiceError> {
        suppliedChoices
    }

    func setChoices(_ choices: Result<CommunityCaptureChoices, CommunityCaptureServiceError>) {
        suppliedChoices = choices
    }

    func capture(_ request: CommunityCaptureRequest) async -> CommunityCaptureOutcome {
        requests.append(request)
        guard !suppliedOutcomes.isEmpty else { return .failed(reason: "fixture-exhausted") }
        if suppliedOutcomes.count == 1 { return suppliedOutcomes[0] }
        return suppliedOutcomes.removeFirst()
    }
}
