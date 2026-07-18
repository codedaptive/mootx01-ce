// URLSessionRelayHTTPTransport.swift — ConvergenceKitFederation
//
// Production RelayHTTPTransport backed by URLSession.
//
// THREADING NOTE: Uses a DispatchSemaphore to bridge URLSession.dataTask
// (async callback) to the synchronous RelayHTTPTransport contract. This is
// valid when called from a background thread or Swift actor task — the semaphore
// blocks the calling thread/task until the response arrives. Do NOT call from
// the main thread (will deadlock on MainActor-associated URLSession delegates).
//
// The HostedRelay integration point (FederationStateActor.push/pull) runs on
// the actor's executor, which is a cooperative thread — blocking is safe for
// short-lived relay requests. A future async Relay protocol extension would
// remove this bridge; for v1.0 the synchronous contract is the law.

import Foundation
import os

private let logger = Logger(
    subsystem: "com.mootx01.synckit.federation",
    category: "URLSessionRelayTransport"
)

/// Production URLSession-backed transport for HostedRelay.
///
/// Uses `URLSession.dataTask` with a `DispatchSemaphore` to satisfy the
/// synchronous `RelayHTTPTransport` contract. Injected at `HostedRelay` init.
public final class URLSessionRelayHTTPTransport: RelayHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    /// - Parameter session: URLSession to use. Defaults to `.shared`.
    ///   Pass a custom session with a short timeout for test convenience.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: RelayHTTPRequest) throws -> RelayHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // ResponseBox: @unchecked Sendable captures for the dataTask callback.
        // Access is sequential by construction — semaphore.wait() guarantees
        // the callback completes before the box is read.
        final class ResponseBox: @unchecked Sendable {
            var data: Data?
            var statusCode: Int = 0
            var error: Error?
        }
        let box = ResponseBox()

        // DispatchSemaphore bridge: block until URLSession callback fires.
        // This is the intended pattern for synchronous URLSession use on
        // non-main threads. The relay cooperative task is blocked for the
        // round-trip duration (expected < 5 s for a healthy SyncServer).
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: urlRequest) { data, response, error in
            box.error = error
            box.data = data
            if let http = response as? HTTPURLResponse {
                box.statusCode = http.statusCode
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = box.error {
            logger.debug("relay transport: network error for \(request.url, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return RelayHTTPResponse(statusCode: box.statusCode, body: box.data ?? Data())
    }
}
