import Foundation
import Observation
import MootGateway

// MARK: - DiscoveryController  (A2 — the Engine tab's LAN browse state)
//
// Wraps LANDaemonBrowser for the Engine tab: a user-toggled browse (starting
// it is the attended action that triggers the Local Network prompt on iOS),
// the live set of advertised daemons, and tap-to-resolve endpoints. Browsing
// stops when toggled off or the view goes away — cancelling the stream task
// cancels the underlying NWBrowser.

@MainActor
@Observable
final class DiscoveryController {

    /// True while the browser runs. Toggled by the user, never implicitly.
    private(set) var isBrowsing = false

    /// Advertised `_mootx01._tcp` service names, live-updated.
    private(set) var serviceNames: [String] = []

    /// Resolution outcomes by service name: the endpoint URL, or the error.
    private(set) var resolved: [String: String] = [:]

    private var browser: LANDaemonBrowser?
    private var browseTask: Task<Void, Never>?

    func toggleBrowsing() {
        isBrowsing ? stop() : start()
    }

    func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        serviceNames = []
        resolved = [:]
        let browser = LANDaemonBrowser()
        self.browser = browser
        browseTask = Task { [weak self] in
            for await names in browser.serviceNames() {
                self?.serviceNames = names
            }
            // Stream ended: browser failed or was cancelled.
            self?.isBrowsing = false
        }
    }

    func stop() {
        browseTask?.cancel()   // terminates the stream → cancels the NWBrowser
        browseTask = nil
        browser = nil
        isBrowsing = false
    }

    func resolve(_ serviceName: String) async {
        guard let browser else { return }
        do {
            let url = try await browser.resolve(serviceName: serviceName)
            resolved[serviceName] = url.absoluteString
        } catch {
            resolved[serviceName] = "\(error)"
        }
    }
}
