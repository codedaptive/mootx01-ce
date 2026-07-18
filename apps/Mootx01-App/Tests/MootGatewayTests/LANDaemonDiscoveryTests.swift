import Testing
import Foundation
import MootGateway

// MARK: - LANDaemonDiscovery tests
//
// The pure endpoint-mapping half of A2 discovery. Live NWBrowser browsing
// needs a LAN, an advertising daemon, and the Local Network grant — none of
// which exist headless — so the browse/resolve path is exercised on-device;
// these tests pin the URL construction HTTPTransport depends on.

@Suite("LANDaemonDiscovery — endpoint URL mapping")
struct LANDaemonDiscoveryTests {

    @Test("IPv4 host maps to a plain http URL")
    func ipv4() {
        let url = LANDaemonDiscovery.endpointURL(host: "192.168.1.20", port: 4242)
        #expect(url?.absoluteString == "http://192.168.1.20:4242")
    }

    @Test("hostname maps unbracketed")
    func hostname() {
        let url = LANDaemonDiscovery.endpointURL(host: "studio.local", port: 4242)
        #expect(url?.absoluteString == "http://studio.local:4242")
    }

    @Test("IPv6 literal gets bracketed")
    func ipv6() {
        let url = LANDaemonDiscovery.endpointURL(host: "fd00::a1", port: 4242)
        #expect(url?.absoluteString == "http://[fd00::a1]:4242")
    }

    @Test("link-local IPv6 scope suffix is percent-encoded per RFC 6874")
    func ipv6ScopedInterface() {
        let url = LANDaemonDiscovery.endpointURL(host: "fe80::1%en0", port: 4242)
        #expect(url?.absoluteString == "http://[fe80::1%25en0]:4242")
    }

    @Test("empty host and zero port are rejected, never guessed")
    func rejectsDegenerate() {
        #expect(LANDaemonDiscovery.endpointURL(host: "", port: 4242) == nil)
        #expect(LANDaemonDiscovery.endpointURL(host: "192.168.1.20", port: 0) == nil)
    }

    @Test("a mapped URL is accepted by HTTPTransport")
    func feedsTransport() throws {
        let url = try #require(LANDaemonDiscovery.endpointURL(host: "192.168.1.20", port: 4242))
        let transport = HTTPTransport(endpoint: url)
        #expect(transport.endpoint == url)
    }
}
