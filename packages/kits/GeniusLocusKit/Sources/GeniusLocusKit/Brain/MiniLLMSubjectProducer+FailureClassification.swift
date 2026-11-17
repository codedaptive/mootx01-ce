// MiniLLMSubjectProducer+FailureClassification.swift
//
// Maps any error the on-device model throws for one drawer to the
// sweep's two answers (SubjectProducerError): refused marks the drawer,
// unavailable stops the sweep for this cadence.
//
// Only the service's moment is unavailable: a rate limit, concurrent
// requests, a timeout, missing model assets, or cancellation. Those
// pass on their own, so the drawer stays debt and a later cadence
// retries it. Every other error, named or not, is refused with its
// text: an error the sweep cannot recognise as passing would otherwise
// stop every cadence at the same drawer, and the sweep would never
// drain the drawers behind it.

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
extension MiniLLMSubjectProducer {

    /// How many links of the NSUnderlyingErrorKey chain are inspected;
    /// bounds the walk should a chain loop back on itself.
    private static let underlyingChainLimit = 8

    /// The (domain, code) each typed service-moment case has once bridged
    /// to NSError. An error that crossed a process or framework boundary
    /// arrives as a plain NSError with only these two values left, so it
    /// is matched by them. Derived from constructed values so the codes
    /// follow the SDK's own bridging.
    private static let bridgedServiceMoments: [(domain: String, code: Int)] = [
        LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "")),
        LanguageModelError.timeout(.init(debugDescription: "")),
        SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "")),
        LanguageModelSession.Error.concurrentRequests,
    ].map { (error: any Error) in
        let bridged = error as NSError
        return (bridged.domain, bridged.code)
    }

    /// The sweep's answer for `error`, thrown by the model for one drawer:
    /// unavailable when `error` or any error in its underlying chain is a
    /// service moment, refused otherwise. Either answer carries the text
    /// of `error` itself.
    static func classify(failure error: any Error) -> SubjectProducerError {
        var link: (any Error)? = error
        for _ in 0..<underlyingChainLimit {
            guard let current = link else { break }
            if isServiceMoment(current) {
                return .unavailable(reason: "\(error)")
            }
            link = (current as NSError).userInfo[NSUnderlyingErrorKey] as? any Error
        }
        return .refused(reason: "\(error)")
    }

    /// Whether one link is a service moment: typed cases first, then the
    /// bridged (domain, code) of the typed cases.
    private static func isServiceMoment(_ error: any Error) -> Bool {
        if let generationError = error as? LanguageModelSession.GenerationError,
           case .unavailable = classify(generationError) {
            return true
        }
        if let modelError = error as? LanguageModelError {
            switch modelError {
            case .rateLimited, .timeout: return true
            default: break
            }
        }
        if let systemError = error as? SystemLanguageModel.Error,
           case .assetsUnavailable = systemError {
            return true
        }
        if let sessionError = error as? LanguageModelSession.Error,
           sessionError == .concurrentRequests {
            return true
        }
        if error is CancellationError { return true }
        let bridged = error as NSError
        return bridgedServiceMoments.contains {
            $0.domain == bridged.domain && $0.code == bridged.code
        }
    }
}
#endif
